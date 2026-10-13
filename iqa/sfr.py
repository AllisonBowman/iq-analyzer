"""ISO 12233-style slanted-edge spatial frequency response (e-SFR).

Given a region of interest (ROI) containing one straight, slightly slanted
edge, compute the edge spread function (ESF), line spread function (LSF) and
modulation transfer function (MTF).  The method follows ISO 12233:2014
Annex D / Burns' ``sfrmat``:

1. locate the edge in every row to sub-pixel precision (centroid of |d/dx|),
2. fit a straight line to those locations,
3. project every pixel onto the edge normal and bin at ``oversample`` samples
   per pixel to build a super-sampled ESF,
4. differentiate (LSF), apply a Hamming window centred on the edge,
5. FFT, normalise at DC, and correct for the discrete derivative.

Conventions
-----------
* The ROI is a 2-D array with the edge running roughly top-to-bottom, i.e. the
  intensity transition is along the x axis.  Transpose a horizontal edge first.
* Pixel values must be linear in scene luminance (apply the inverse OECF before
  calling).  Gamma-encoded data gives a biased MTF.
* Frequencies are in cycles per pixel; Nyquist is 0.5.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.ndimage import gaussian_filter1d


@dataclass
class SFRResult:
    freq: np.ndarray        # cycles / pixel
    mtf: np.ndarray         # normalised to 1.0 at DC, derivative-corrected
    mtf50: float            # first frequency where MTF falls to 0.5 (c/px)
    mtf50p: float           # first frequency where MTF falls to half its peak
    mtf30: float            # first frequency where MTF falls to 0.3
    mtf_nyquist: float      # MTF at 0.5 c/px
    slope_deg: float        # edge angle from vertical (degrees)
    fit_rms_px: float       # RMS residual of the straight-line edge fit (px)
    contrast: float         # Michelson contrast between the two ESF plateaus
    plateau_noise: float    # worst plateau std divided by the step height
    rise_10_90_px: float    # 10-90 % edge rise width in pixels
    esf: np.ndarray
    lsf: np.ndarray
    oversample: int

    def summary(self) -> dict:
        return {
            "mtf50": self.mtf50,
            "mtf50p": self.mtf50p,
            "mtf30": self.mtf30,
            "mtf_nyquist": self.mtf_nyquist,
            "slope_deg": self.slope_deg,
            "fit_rms_px": self.fit_rms_px,
            "contrast": self.contrast,
            "plateau_noise": self.plateau_noise,
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


def _first_crossing(freq: np.ndarray, mtf: np.ndarray, level: float) -> float:
    """Frequency at which ``mtf`` first drops below ``level`` (linear interpolation)."""
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


def _rise_width(esf: np.ndarray) -> float:
    """10-90 % rise width of an ESF, in ESF samples (robust to direction and noise)."""
    sm = gaussian_filter1d(esf, sigma=2.0, mode="nearest")
    k = max(4, sm.size // 5)
    lo, hi = sorted([float(sm[:k].mean()), float(sm[-k:].mean())])
    if hi - lo <= 0:
        return float(sm.size)
    t = (sm - lo) / (hi - lo)
    if sm[0] > sm[-1]:
        t = 1.0 - t
    i10 = int(np.argmax(t >= 0.1))
    i90 = int(np.argmax(t >= 0.9))
    return float(max(1, i90 - i10))


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

    rows = np.arange(h, dtype=np.float64)
    kc = max(2, w // 8)
    sign = 1.0 if roi[:, -kc:].mean() >= roi[:, :kc].mean() else -1.0
    cent = _row_edge_positions(roi)
    slope, intercept, fit_rms = _fit_line(rows, cent)
    # Refine with the signed derivative inside a window scaled to the edge width.
    esf0, _ = _project(roi, slope, intercept, oversample)
    width = _rise_width(esf0) / oversample
    halfwin = float(np.clip(1.2 * width, 4.0, 16.0))
    for hw in (halfwin * 1.5, halfwin):
        prior = slope * rows + intercept
        cent = _row_edge_positions(roi, prior=prior, halfwin=hw, sign=sign)
        slope, intercept, fit_rms = _fit_line(rows, cent)
    theta = np.arctan(slope)                       # angle from vertical
    esf, delta = _project(roi, slope, intercept, oversample)
    nb = esf.size

    # Plateaus (outer 20 % of samples on each side) for contrast / flatness.
    k = max(4, nb // 5)
    left, right = esf[:k], esf[-k:]
    lo, hi = sorted([float(left.mean()), float(right.mean())])
    step = hi - lo
    contrast = step / (hi + lo) if (hi + lo) > 0 else 0.0
    plateau_noise = float(max(left.std(), right.std()) / step) if step > 0 else float("inf")

    # LSF: discrete derivative with spacing delta; Hamming window centred on the peak.
    lsf = np.diff(esf)
    n = lsf.size
    # Locate the edge on a smoothed |LSF| so single-bin noise spikes cannot win.
    peak = int(np.argmax(gaussian_filter1d(np.abs(lsf), sigma=float(oversample), mode="nearest")))
    i = np.arange(n)
    win = 0.54 + 0.46 * np.cos(2.0 * np.pi * (i - peak) / n)
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
    nyq = freq <= 0.5
    peak_mtf = float(mtf[nyq].max())

    return SFRResult(
        freq=freq,
        mtf=mtf,
        mtf50=_first_crossing(freq, mtf, 0.5),
        mtf50p=_first_crossing(freq, mtf, 0.5 * peak_mtf),
        mtf30=_first_crossing(freq, mtf, 0.3),
        mtf_nyquist=float(np.interp(0.5, freq, mtf)),
        slope_deg=float(np.degrees(theta)),
        fit_rms_px=fit_rms,
        contrast=float(contrast),
        plateau_noise=plateau_noise,
        rise_10_90_px=_rise_width(esf) / oversample,
        esf=esf,
        lsf=lsf,
        oversample=oversample,
    )


def gaussian_mtf50(sigma_px: float) -> float:
    """Analytic MTF50 (c/px) of a Gaussian blur with standard deviation ``sigma_px``.

    MTF(f) = exp(-2 pi^2 sigma^2 f^2)  =>  MTF50 = sqrt(ln 2 / 2) / (pi sigma).
    """
    return float(np.sqrt(np.log(2.0) / 2.0) / (np.pi * sigma_px))
