"""ISO 12233-style slanted-edge spatial frequency response (e-SFR).

Given a region of interest (ROI) containing one straight, slightly slanted
edge, compute the edge spread function (ESF), line spread function (LSF) and
modulation transfer function (MTF).  The method follows ISO 12233:2014
Annex D / Burns' ``sfrmat``:

1. locate the edge in every row to sub-pixel precision,
2. fit a straight line to those locations,
3. project every pixel onto the edge normal and bin at ``oversample`` samples
   per pixel to build a super-sampled ESF,
4. remove any linear shading shared by the two plateaus (natural scenes are
   not uniform charts; a gradient across the ROI biases the MTF low),
5. differentiate (LSF), apply a Hamming window centred on the edge,
6. FFT, normalise at DC, and correct for the discrete derivative.

Validity
--------
A clipped plateau truncates the ESF and *inflates* MTF50 (up to 2x), and it
makes the plateau look perfectly flat, so clipping cannot be caught by a
flatness test.  ``SFRResult.clipped_frac`` reports the share of saturated
pixels; callers should reject ROIs above about 0.5 %.  ``shading`` reports the
removed gradient as a fraction of the step; ``contrast`` above 1.0 is
impossible for a real step and marks a corrupted ESF.

Conventions
-----------
* The ROI is a 2-D array with the edge running roughly top-to-bottom, i.e. the
  intensity transition is along the x axis.  Transpose a horizontal edge first.
* Pixel values must be linear in scene luminance (apply the inverse OECF before
  calling).  Gamma-encoded data gives a biased MTF.
* Frequencies are cycles per pixel measured along the edge normal; Nyquist is
  0.5.  MTF50/MTF30 are searched below Nyquist only and are NaN when the curve
  does not cross there.  ``mtf_nyquist`` is NaN below the window-leakage floor
  (0.01).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.ndimage import gaussian_filter1d

NYQUIST = 0.5
MTF_NYQUIST_FLOOR = 0.01


@dataclass
class SFRResult:
    freq: np.ndarray        # cycles / pixel (along the edge normal)
    mtf: np.ndarray         # normalised to 1.0 at DC, derivative-corrected
    mtf50: float            # first frequency below Nyquist where MTF falls to 0.5 (NaN if none)
    mtf50p: float           # first frequency where MTF falls to half its peak (sharpening-robust)
    mtf30: float            # first frequency where MTF falls to 0.3
    mtf_nyquist: float      # MTF at 0.5 c/px (NaN below the leakage floor)
    overshoot_pct: float    # ESF overshoot beyond the bright plateau, % of step (sharpening)
    slope_deg: float        # edge angle from vertical (degrees)
    fit_rms_px: float       # RMS residual of the straight-line edge fit (px)
    contrast: float         # Michelson contrast between the two (de-shaded) ESF plateaus
    step: float             # absolute step height in linear units
    plateau_noise: float    # worst plateau residual std divided by the step height
    shading: float          # removed linear gradient across the ESF, as a fraction of the step
    clipped_frac: float     # fraction of ROI pixels at the saturation limits
    rise_10_90_px: float    # 10-90 % edge rise width in pixels (NaN if undefined)
    esf: np.ndarray         # de-shaded ESF at ``oversample`` samples per pixel
    lsf: np.ndarray
    oversample: int

    def summary(self) -> dict:
        return {
            "mtf50": self.mtf50,
            "mtf50p": self.mtf50p,
            "mtf30": self.mtf30,
            "mtf_nyquist": self.mtf_nyquist,
            "overshoot_pct": self.overshoot_pct,
            "slope_deg": self.slope_deg,
            "fit_rms_px": self.fit_rms_px,
            "contrast": self.contrast,
            "step": self.step,
            "plateau_noise": self.plateau_noise,
            "shading": self.shading,
            "clipped_frac": self.clipped_frac,
            "rise_10_90_px": self.rise_10_90_px,
        }


def _row_edge_positions(roi: np.ndarray, prior: np.ndarray | None = None,
                        halfwin: float = 4.0, sign: float = 1.0) -> np.ndarray:
    """Sub-pixel edge location for every row.

    Without a ``prior``: the peak of a smoothed |d/dx| per row, refined by a
    local centroid of |d/dx| within 3 px.  With a ``prior`` line: the centroid
    of the *signed* derivative (``sign`` = direction of the step) within
    ``halfwin`` px of the prior.  Using the signed derivative matters: the
    centroid of |noise| is biased toward the window centre, which shrinks the
    fitted slope on noisy edges; signed noise averages to zero.

    Smoothing is applied *only* for localisation, never to the ESF data.
    """
    sm = gaussian_filter1d(roi, sigma=1.0, axis=1, mode="nearest")
    d = np.diff(sm, axis=1)                      # d[r, i] sits at x = i + 0.5
    x = np.arange(d.shape[1]) + 0.5
    if prior is None:
        sm2 = gaussian_filter1d(roi, sigma=2.0, axis=1, mode="nearest")
        d2 = np.abs(np.diff(sm2, axis=1))
        prior = x[np.argmax(d2, axis=1)]
        halfwin = 3.0
        wgt = np.abs(d)
    else:
        wgt = d * sign
    mask = np.abs(x[None, :] - prior[:, None]) <= halfwin
    wgt = np.where(mask, wgt, 0.0)
    wsum = wgt.sum(axis=1)
    with np.errstate(invalid="ignore", divide="ignore"):
        cent = (wgt * x).sum(axis=1) / np.where(wsum > 0, wsum, np.nan)
    return cent


def _fit_line(rows: np.ndarray, cent: np.ndarray) -> tuple[float, float, float]:
    good = np.isfinite(cent)
    if good.sum() < 4:
        raise ValueError("too few rows with a detectable edge")
    A = np.vstack([rows[good], np.ones(int(good.sum()))]).T
    (slope, intercept), *_ = np.linalg.lstsq(A, cent[good], rcond=None)
    resid = cent[good] - (slope * rows[good] + intercept)
    return float(slope), float(intercept), float(np.sqrt(np.mean(resid ** 2)))


def _first_crossing(freq: np.ndarray, mtf: np.ndarray, level: float, fmax: float = NYQUIST) -> float:
    """Frequency at which ``mtf`` first drops below ``level`` within ``freq <= fmax``.

    Linear interpolation between samples; NaN when there is no crossing in range.
    """
    sel = freq <= fmax
    freq, mtf = freq[sel], mtf[sel]
    below = np.flatnonzero(mtf < level)
    if below.size == 0:
        return float("nan")
    i = int(below[0])
    if i == 0:
        return 0.0
    f0, f1 = freq[i - 1], freq[i]
    m0, m1 = mtf[i - 1], mtf[i]
    if m0 == m1:
        return float(f0)
    return float(f0 + (level - m0) * (f1 - f0) / (m1 - m0))


def _project(roi: np.ndarray, slope: float, intercept: float, oversample: int):
    """Super-sampled ESF: project pixels onto the edge normal and bin at 1/oversample px."""
    h, w = roi.shape
    theta = np.arctan(slope)
    yy, xx = np.mgrid[0:h, 0:w]
    dist = (xx - (slope * yy + intercept)) * np.cos(theta)
    delta = 1.0 / oversample
    dmin = dist.min()
    idx = np.floor((dist - dmin) / delta).astype(np.int64)
    nb = int(idx.max()) + 1
    sums = np.bincount(idx.ravel(), weights=roi.ravel(), minlength=nb)
    cnts = np.bincount(idx.ravel(), minlength=nb)
    # Drop the sparsely populated bins at both ends (ROI corners): a bin built
    # from one or two pixels is pure noise and would dominate the LSF peak search.
    support = max(2.0, 0.3 * float(np.median(cnts[cnts > 0])))
    ok = np.flatnonzero(cnts >= support)
    lo_bin, hi_bin = int(ok[0]), int(ok[-1]) + 1
    sums, cnts = sums[lo_bin:hi_bin], cnts[lo_bin:hi_bin]
    nb = hi_bin - lo_bin
    nz = cnts > 0
    esf = np.empty(nb)
    esf[nz] = sums[nz] / cnts[nz]
    if (~nz).any():
        esf[~nz] = np.interp(np.flatnonzero(~nz), np.flatnonzero(nz), esf[nz])
    return esf, delta


def _plateau_fit(esf: np.ndarray) -> tuple[float, float, float, float, float, int]:
    """Fit a line to each outer-20 % plateau.

    Returns (left_level, right_level, shared_slope_per_sample, left_resid_std,
    right_resid_std, k) where the levels are evaluated at the ESF centre so the
    step is independent of the shading, and ``k`` is the plateau length.
    """
    nb = esf.size
    k = max(4, nb // 5)
    i = np.arange(nb, dtype=np.float64)
    mid = (nb - 1) / 2.0
    il, ir = i[:k], i[-k:]
    (al, bl) = np.polyfit(il, esf[:k], 1)
    (ar, br) = np.polyfit(ir, esf[-k:], 1)
    slope = 0.5 * (al + ar)
    left = float(np.mean(esf[:k]) + slope * (mid - il.mean()))
    right = float(np.mean(esf[-k:]) + slope * (mid - ir.mean()))
    sl = float(np.std(esf[:k] - (al * il + bl)))
    sr = float(np.std(esf[-k:] - (ar * ir + br)))
    return left, right, float(slope), sl, sr, k


def _rise_width(esf: np.ndarray, oversample: int) -> float:
    """10-90 % rise width in *pixels*, from interpolated crossings of a lightly smoothed ESF.

    NaN when the plateaus are not separated or the 10 %/90 % levels are never
    crossed in order.  Smoothing is 0.75 samples (0.19 px at 4x) so the width
    bias is negligible, and crossings are interpolated so the result is not
    quantised to the sample spacing.
    """
    sm = gaussian_filter1d(esf, sigma=0.75, mode="nearest")
    left, right, _slope, _sl, _sr, k = _plateau_fit(sm)
    lo, hi = sorted([left, right])
    if hi - lo <= 0:
        return float("nan")
    t = (sm - lo) / (hi - lo)
    if sm[:k].mean() > sm[-k:].mean():
        t = 1.0 - t
    i10 = np.flatnonzero(t >= 0.1)
    if i10.size == 0 or i10[0] == 0:
        return float("nan")
    i10 = int(i10[0])
    after = np.flatnonzero(t[i10:] >= 0.9)
    if after.size == 0:
        return float("nan")
    i90 = i10 + int(after[0])
    if i90 == 0:
        return float("nan")

    def interp(i, level):
        t0, t1 = t[i - 1], t[i]
        return (i - 1) + (level - t0) / (t1 - t0) if t1 != t0 else float(i)

    x10, x90 = interp(i10, 0.1), interp(i90, 0.9)
    w = max(x90 - x10, 1e-6) / oversample
    # Remove the known blur of the 0.75-sample smoothing (10-90 % width of a Gaussian = 2.563 sigma).
    w_sm = 2.563 * 0.75 / oversample
    return float(np.sqrt(max(w * w - w_sm * w_sm, 1e-12)))


def compute_sfr(roi: np.ndarray, oversample: int = 4, max_freq: float = 1.0) -> SFRResult:
    """Slanted-edge SFR of a ROI whose edge runs top-to-bottom.

    Parameters
    ----------
    roi : 2-D array, linear intensity.  Needs at least 8 rows and 16 columns
          and a few pixels of flat plateau on each side of the edge.
    oversample : samples per pixel for the ESF (ISO 12233 uses 4).
    max_freq : highest frequency kept in ``freq``/``mtf`` (c/px).
    """
    roi = np.asarray(roi, dtype=np.float64)
    if roi.ndim != 2:
        raise ValueError("roi must be 2-D")
    h, w = roi.shape
    if h < 8 or w < 16:
        raise ValueError("roi too small (need >= 8 rows and >= 16 columns)")

    rmax = float(roi.max())
    clipped_frac = float(np.mean((roi >= 0.99) | (roi <= 0.001))) if rmax > 0 else 1.0

    rows = np.arange(h, dtype=np.float64)
    kc = max(2, w // 8)
    sign = 1.0 if roi[:, -kc:].mean() >= roi[:, :kc].mean() else -1.0
    cent = _row_edge_positions(roi)
    slope, intercept, fit_rms = _fit_line(rows, cent)
    # Refine with the signed derivative inside a window scaled to the edge width.
    esf0, _ = _project(roi, slope, intercept, oversample)
    width = _rise_width(esf0, oversample)
    halfwin = float(np.clip(1.2 * width, 4.0, 16.0)) if np.isfinite(width) else 6.0
    for hw in (halfwin * 1.5, halfwin):
        prior = slope * rows + intercept
        cent = _row_edge_positions(roi, prior=prior, halfwin=hw, sign=sign)
        slope, intercept, fit_rms = _fit_line(rows, cent)
    theta = np.arctan(slope)                       # angle from vertical
    esf, delta = _project(roi, slope, intercept, oversample)
    nb = esf.size

    # Remove the linear shading shared by both plateaus, then measure them.
    left, right, sh_slope, _sl, _sr, k = _plateau_fit(esf)
    i = np.arange(nb, dtype=np.float64)
    esf = esf - sh_slope * (i - (nb - 1) / 2.0)
    left, right, _zero, sl, sr, k = _plateau_fit(esf)
    lo, hi = sorted([left, right])
    step = hi - lo
    contrast = step / (hi + lo) if (hi + lo) > 0 else 0.0
    plateau_noise = float(max(sl, sr) / step) if step > 0 else float("inf")
    shading = float(abs(sh_slope) * nb / step) if step > 0 else float("inf")

    # Overshoot: how far a smoothed ESF exceeds the bright plateau (sharpening halo).
    sm = gaussian_filter1d(esf, sigma=2.0, mode="nearest")
    bright_side = sm[-k:] if right >= left else sm[:k]
    inner = sm[k:-k] if nb > 2 * k else sm
    overshoot = float((inner.max() - hi) / step * 100.0) if step > 0 else float("nan")
    overshoot = max(0.0, overshoot)
    del bright_side

    # LSF: discrete derivative with spacing delta; Hamming window centred on the
    # peak and clamped to zero beyond half the record, so an off-centre edge does
    # not leave the record ends weighted.
    lsf = np.diff(esf)
    n = lsf.size
    peak = int(np.argmax(gaussian_filter1d(np.abs(lsf), sigma=float(oversample), mode="nearest")))
    j = np.arange(n)
    win = np.where(np.abs(j - peak) <= n / 2.0, 0.54 + 0.46 * np.cos(2.0 * np.pi * (j - peak) / n), 0.0)
    lsf_w = lsf * win

    nfft = max(2048, (1 << int(np.ceil(np.log2(max(n, 2))))) * 4)
    spec = np.abs(np.fft.rfft(lsf_w, n=nfft))
    freq = np.fft.rfftfreq(nfft, d=delta)        # cycles per pixel
    if spec[0] <= 0:
        raise ValueError("degenerate ESF (no step)")
    mtf = spec / spec[0]
    # The [1, -1] derivative attenuates by sinc(f*delta) relative to an ideal derivative.
    corr = np.sinc(freq * delta)
    mtf = mtf / np.where(np.abs(corr) > 1e-6, corr, 1.0)

    sel = freq <= max_freq
    freq, mtf = freq[sel], mtf[sel]
    peak_mtf = float(mtf[freq <= NYQUIST].max())
    m_nyq = float(np.interp(NYQUIST, freq, mtf))

    return SFRResult(
        freq=freq,
        mtf=mtf,
        mtf50=_first_crossing(freq, mtf, 0.5),
        mtf50p=_first_crossing(freq, mtf, 0.5 * peak_mtf),
        mtf30=_first_crossing(freq, mtf, 0.3),
        mtf_nyquist=m_nyq if m_nyq >= MTF_NYQUIST_FLOOR else float("nan"),
        overshoot_pct=overshoot,
        slope_deg=float(np.degrees(theta)),
        fit_rms_px=fit_rms,
        contrast=float(contrast),
        step=float(step),
        plateau_noise=plateau_noise,
        shading=shading,
        clipped_frac=clipped_frac,
        rise_10_90_px=_rise_width(esf, oversample),
        esf=esf,
        lsf=lsf,
        oversample=oversample,
    )


def gaussian_mtf50(sigma_px: float) -> float:
    """Analytic MTF50 (c/px) of a Gaussian blur with standard deviation ``sigma_px``.

    MTF(f) = exp(-2 pi^2 sigma^2 f^2)  =>  MTF50 = sqrt(ln 2 / 2) / (pi sigma).
    """
    return float(np.sqrt(np.log(2.0) / 2.0) / (np.pi * sigma_px))


def gaussian_pixel_mtf(freq: np.ndarray, sigma_px: float) -> np.ndarray:
    """MTF of a Gaussian blur followed by a 100 %-fill square pixel aperture: exp(-2 pi^2 s^2 f^2) * sinc(f)."""
    freq = np.asarray(freq, dtype=np.float64)
    return np.exp(-2.0 * np.pi ** 2 * sigma_px ** 2 * freq ** 2) * np.abs(np.sinc(freq))


def gaussian_pixel_mtf50(sigma_px: float) -> float:
    """MTF50 of :func:`gaussian_pixel_mtf`, found numerically."""
    f = np.linspace(0.0, 0.5, 50001)
    m = gaussian_pixel_mtf(f, sigma_px)
    i = int(np.flatnonzero(m < 0.5)[0])
    return float(np.interp(0.5, [m[i], m[i - 1]], [f[i], f[i - 1]]))
