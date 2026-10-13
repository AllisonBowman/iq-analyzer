"""Noise, SNR and an output-referred dynamic-range estimate from a single photo.

Method
------
1. Work on the display-referred image (sRGB, 0-255) so RAW and JPEG files are
   comparable.
2. High-pass the luminance with a wide Gaussian (sigma 8 px) so smooth
   gradients (skies, water) do not count as noise.  For white noise this
   removes a negligible fraction of the noise power.
3. Scan the image with ``patch`` x ``patch`` windows and keep windows that
   contain no Canny edges, are not clipped, and whose residual looks like
   noise rather than texture: smoothing the residual with a sigma-2 Gaussian
   shrinks white noise by ~0.14x but leaves low-frequency texture.  Real
   noise is not white after noise reduction or JPEG compression, so the
   acceptance threshold adapts to the image: patches are kept when their
   ratio is below ``max(texture_ratio, 1.3 x the 25th percentile of all
   candidate ratios)``.  The 25th-percentile ratio is reported as
   ``noise_whiteness`` (0.14 = white; 0.4+ = heavily correlated / NR'd).
3b. Periodic texture (screens, fabric, printed halftone) has an amplitude
   comparable to the noise and a *white-looking* residual, so the ratio gate
   misses it.  The power spectrum of every candidate patch is normalised to
   unit mean power and averaged; averaging over thousands of patches makes a
   pattern that repeats at one frequency stand out even when a single patch
   cannot show it.  The averaged spectrum is divided by the median of its
   annulus (removing the radial 1/f envelope and the NR roll-off) and then by
   the larger of the medians along its row and along its column at offsets
   2-4 bins (so a ridge along an axis, which demosaicing, JPEG and oriented
   texture leave behind, scores ~1 while a spot does not).  The largest value
   over bins at radius >= 3 cycles/patch, excluding the Nyquist row and
   column (a 2-pixel alternation along either axis, which any pipeline's
   sampling and sharpening can produce), is ``noise_spectral_peak``.  Pure
   noise averages to ~1; measured negatives (white, pink, smoothed,
   anisotropic, JPEG-blocked synthetics; 34 ordinary library files from five
   cameras, HEIC and JPEG, including the four that a block-median baseline
   had mis-scored at 8-12) reach 1.0-3.2; a noise-strength grid on 11 % of
   the frame reaches 16, a half-noise-amplitude sinusoid 15-48, and the
   library's screen photos 11-127.  Above
   ``PERIODIC_PEAK_THRESHOLD`` (6, the geometric midpoint of 3.2 and 11.3)
   the image is ``noise_periodic_suspect``,
   and candidate patches whose own power in the peak's 3x3 bins exceeds four
   times their local baseline are excluded before the noise floor is taken,
   provided they are a minority of the selected patches
   (``noise_periodic_fraction`` is the share of candidates flagged); when most
   of the selection is the pattern the full selection is kept and only the
   flag is raised.  When the image is not
   flagged the selection is exactly the one step 3 produces.  A noise-free
   gradient quantised to 8 bits is a staircase and is flagged too: its
   contour lines are periodic.
4. Bin the surviving windows by mean luminance and take a low percentile of
   the residual std in each bin as the noise floor (texture can only *raise*
   the std, so the lower envelope is the best single-frame estimate).
5. Report SNR at mid-grey (sRGB 118 = 18 % reflectance), a chroma-noise figure,
   and a dynamic-range estimate: the stops between near-white and the darkest
   level whose *scene-linear* SNR still exceeds 1, 2, 4 and 10 (the thresholds
   Imatest reports for low / medium / medium-high / high quality).

The dynamic range of a processed JPEG is bounded by its tone curve; the
figure is "output-referred DR", not sensor DR.  Everything here is an
estimate from one frame: there is no way to separate fine texture from noise
with certainty without a second exposure.
"""
from __future__ import annotations

import warnings
from dataclasses import dataclass, field

import cv2
import numpy as np

from .imageio import srgb_decode

MIDGREY_8BIT = 118.0   # sRGB encoding of 18 % reflectance
PERIODIC_PEAK_THRESHOLD = 6.0   # see module docstring, step 3b, for the measured distributions
PERIODIC_MIN_RADIUS = 3.0       # cycles per patch; below this the sigma-8 high-pass still shapes the spectrum
PERIODIC_PATCH_FACTOR = 4.0     # per-patch exclusion: 3x3 peak power vs local baseline (Gamma(9) tail ~1e-6)
PERIODIC_MAX_EXCLUDED_FRACTION = 0.5   # exclude flagged patches only while they are a minority of the selected set


@dataclass
class NoiseResult:
    n_patches: int
    bin_centers: np.ndarray = field(default_factory=lambda: np.array([]))
    luma_noise: np.ndarray = field(default_factory=lambda: np.array([]))     # 8-bit units per bin
    chroma_noise: np.ndarray = field(default_factory=lambda: np.array([]))
    bin_counts: np.ndarray = field(default_factory=lambda: np.array([]))
    luma_noise_midgrey: float = float("nan")
    chroma_noise_midgrey: float = float("nan")
    snr_midgrey_db: float = float("nan")
    dr_stops: dict = field(default_factory=dict)          # {"snr1": .., "snr2": .., "snr4": .., "snr10": ..}
    dr_is_lower_bound: dict = field(default_factory=dict)
    darkest_bin: float = float("nan")
    snr_midgrey_extrapolated: bool = False      # no flat patches near mid-grey; value is from the nearest bin
    nearest_bin_level: float = float("nan")
    noise_whiteness: float = float("nan")      # 25th-pct smoothed/raw residual std ratio (0.14 = white noise)
    texture_suspect: bool = False              # whiteness > 0.7: periodic texture (screens, fabric) or extreme NR, not sensor noise
    candidate_patches: int = 0
    rejection_rate: float = float("nan")       # share of candidate (edge-free, unclipped) patches rejected as texture
    spectral_peak: float = float("nan")        # averaged-spectrum peak over its annular+local baseline (~1 for noise)
    periodic_suspect: bool = False             # spectral_peak > PERIODIC_PEAK_THRESHOLD
    periodic_freq_cpp: float = float("nan")    # radial frequency of the peak, cycles/pixel (nan when not flagged; up to 0.66 on a diagonal)
    periodic_fraction: float = 0.0             # share of candidate patches excluded as periodic

    def as_dict(self) -> dict:
        d = {
            "noise_patches": self.n_patches,
            "noise_candidate_patches": self.candidate_patches,
            "noise_rejection_rate": self.rejection_rate,
            "noise_whiteness": self.noise_whiteness,
            "noise_texture_suspect": bool(self.texture_suspect),
            "noise_spectral_peak": self.spectral_peak,
            "noise_periodic_suspect": bool(self.periodic_suspect),
            "noise_periodic_freq_cpp": self.periodic_freq_cpp,
            "noise_periodic_fraction": self.periodic_fraction,
            "luma_noise_midgrey_8bit": self.luma_noise_midgrey,
            "chroma_noise_midgrey_8bit": self.chroma_noise_midgrey,
            "snr_midgrey_db": self.snr_midgrey_db,
            "snr_midgrey_extrapolated": bool(self.snr_midgrey_extrapolated),
            "snr_nearest_bin_level": self.nearest_bin_level,
        }
        for k, v in self.dr_stops.items():
            d[f"dr_{k}_stops"] = v
            d[f"dr_{k}_lower_bound"] = bool(self.dr_is_lower_bound.get(k, False))
        return d


def _local_stats(resid: np.ndarray, patch: int) -> tuple[np.ndarray, np.ndarray]:
    k = (patch, patch)
    m = cv2.blur(resid, k)
    m2 = cv2.blur(resid * resid, k)
    var = np.clip(m2 - m * m, 0.0, None)
    return m, np.sqrt(var)


def _annular_baseline(S: np.ndarray, rbin: np.ndarray) -> np.ndarray:
    B = np.ones_like(S)
    for r in np.unique(rbin):
        m = rbin == r
        B[m] = np.median(S[m])
    return np.maximum(B, 1e-12)


def _local_baseline(S: np.ndarray, valid: np.ndarray, lo: int = 2, hi: int = 4) -> np.ndarray:
    """Directional baseline: the larger of the medians along the row and along the column at
    offsets lo..hi on both sides, over valid bins only (the spectrum is periodic in k, so np.roll
    wraps correctly).  A sharp spot stands above both; a ridge along an axis (what demosaicing,
    JPEG and strongly oriented texture leave behind) is high along one of them and scores ~1."""
    Sm = np.where(valid, S, np.nan)
    offs = list(range(-hi, -lo + 1)) + list(range(lo, hi + 1))
    with np.errstate(all="ignore"), warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)      # all-NaN slices next to excluded bins
        rows = np.nanmedian(np.stack([np.roll(Sm, d, axis=1) for d in offs]), axis=0)
        cols = np.nanmedian(np.stack([np.roll(Sm, d, axis=0) for d in offs]), axis=0)
    B = np.fmax(rows, cols)
    return np.where(np.isfinite(B) & (B > 0), B, 1e-12)


def periodic_texture(resid: np.ndarray, cand_y: np.ndarray, cand_x: np.ndarray, patch: int,
                     threshold: float = PERIODIC_PEAK_THRESHOLD, chunk: int = 2048
                     ) -> tuple[float, float, np.ndarray]:
    """Spectral periodic-texture detector over the candidate patches (module docstring, 3b).

    Returns ``(peak, freq_cpp, exclude)``: the normalised peak of the averaged spectrum, the
    peak's frequency in cycles/pixel (nan when ``peak <= threshold``), and a boolean mask over
    the candidates marking the patches to exclude (all False when not flagged).
    """
    N = patch
    half = N // 2
    M = int(cand_y.size)
    exclude = np.zeros(M, dtype=bool)
    if M == 0:
        return float("nan"), float("nan"), exclude
    k = np.fft.fftfreq(N) * N
    KY, KX = np.meshgrid(k, k, indexing="ij")
    rad = np.sqrt(KY ** 2 + KX ** 2)
    rbin = np.rint(rad).astype(int)
    nyq_line = (np.abs(KY) == half) | (np.abs(KX) == half)      # a 2-px alternation along either axis
    base_valid = (rad >= 2.0) & ~nyq_line                       # the sigma-8 high-pass transmits 99 % at r=2
    valid = (rad >= PERIODIC_MIN_RADIUS) & ~nyq_line            # where a peak may be declared
    ar = np.arange(N)

    def spectra(sl):
        yy, xx = cand_y[sl], cand_x[sl]
        iy = (yy[:, None] - half) + ar[None, :]
        ix = (xx[:, None] - half) + ar[None, :]
        P = resid[iy[:, :, None], ix[:, None, :]].astype(np.float32)
        P -= P.mean(axis=(1, 2), keepdims=True)
        S = np.abs(np.fft.fft2(P)) ** 2
        tot = S.sum(axis=(1, 2), keepdims=True) / (N * N)
        return S / np.maximum(tot, 1e-12)

    acc = np.zeros((N, N), dtype=np.float64)
    for i in range(0, M, chunk):
        acc += spectra(slice(i, i + chunk)).sum(axis=0)
    Sbar = acc / M
    A = _annular_baseline(Sbar, rbin)
    R = Sbar / A
    R = R / _local_baseline(R, base_valid)
    Rv = np.where(valid & np.isfinite(R), R, 0.0)
    iy, ix = np.unravel_index(int(np.argmax(Rv)), R.shape)
    peak = float(Rv[iy, ix])
    if not np.isfinite(peak) or peak <= threshold:
        return peak, float("nan"), exclude
    freq = float(rad[iy, ix] / N)

    # Per-patch exclusion: power in the 3x3 bins around the peak (and the conjugate peak),
    # annulus-normalised, against the same bins' local baseline, summed.
    core = np.zeros((N, N), dtype=bool)
    for cy, cx in ((iy, ix), ((-iy) % N, (-ix) % N)):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                core[(cy + dy) % N, (cx + dx) % N] = True
    Lb = _local_baseline(Sbar / A, base_valid)
    expected = float((Lb * A)[core].sum())          # what a periodic-free patch would put there
    for i in range(0, M, chunk):
        S = spectra(slice(i, i + chunk))
        got = S[:, core].sum(axis=1)
        exclude[i:i + chunk] = got > PERIODIC_PATCH_FACTOR * expected
    return peak, freq, exclude


def analyze_noise(rgb8: np.ndarray, patch: int = 32, stride: int = 16, n_bins: int = 16,
                  floor_percentile: float = 15.0, texture_ratio: float = 0.30,
                  min_patches_per_bin: int = 6, max_side: int = 4000) -> NoiseResult:
    """Noise analysis on a display-referred sRGB uint8 image (HxWx3)."""
    img = rgb8
    h, w = img.shape[:2]
    if max(h, w) > max_side:
        # Noise statistics at 1:1 need native pixels, but a very large image can be
        # analysed on a central crop without changing the answer.
        y0, x0 = (h - min(h, max_side)) // 2, (w - min(w, max_side)) // 2
        img = img[y0:y0 + min(h, max_side), x0:x0 + min(w, max_side)]
        h, w = img.shape[:2]

    f = img.astype(np.float32)
    Y = 0.2126 * f[..., 0] + 0.7152 * f[..., 1] + 0.0722 * f[..., 2]
    resid = Y - cv2.GaussianBlur(Y, (0, 0), 8.0)
    resid_sm = cv2.GaussianBlur(resid, (0, 0), 2.0)
    rg = (f[..., 0] - f[..., 1]); rg -= cv2.GaussianBlur(rg, (0, 0), 8.0)
    bg = (f[..., 2] - f[..., 1]); bg -= cv2.GaussianBlur(bg, (0, 0), 8.0)

    meanY = cv2.blur(Y, (patch, patch))
    _, stdR = _local_stats(resid, patch)
    _, stdS = _local_stats(resid_sm, patch)
    _, stdRG = _local_stats(rg, patch)
    _, stdBG = _local_stats(bg, patch)

    g8 = np.clip(Y, 0, 255).astype(np.uint8)
    edges = cv2.Canny(cv2.GaussianBlur(g8, (3, 3), 0), 60, 160)
    edge_density = cv2.blur((edges > 0).astype(np.float32), (patch, patch))
    clipped_hi = cv2.blur((f.max(axis=2) >= 252).astype(np.float32), (patch, patch))
    clipped_lo = cv2.blur((f.min(axis=2) <= 3).astype(np.float32), (patch, patch))

    half = patch // 2
    ys = np.arange(half, h - half, stride)
    xs = np.arange(half, w - half, stride)
    if ys.size == 0 or xs.size == 0:
        return NoiseResult(n_patches=0)
    Yg, Xg = np.meshgrid(ys, xs, indexing="ij")
    cand = (edge_density[Yg, Xg] == 0) & (clipped_hi[Yg, Xg] == 0) & (clipped_lo[Yg, Xg] == 0)
    sR, sS = stdR[Yg, Xg], stdS[Yg, Xg]
    with np.errstate(invalid="ignore", divide="ignore"):
        ratio = np.where(sR > 1e-6, sS / sR, np.inf)
    cand &= sR > 0.05
    n_cand = int(cand.sum())
    whiteness = float(np.percentile(ratio[cand], 25)) if n_cand >= min_patches_per_bin else float("nan")
    thr = max(texture_ratio, 1.3 * whiteness) if np.isfinite(whiteness) else texture_ratio
    sel = cand & (ratio < thr)

    # Step 3b: periodic texture over the candidate set.
    cy, cx = Yg[cand], Xg[cand]
    peak, pfreq, pexcl = periodic_texture(resid, cy, cx, patch)
    periodic_fraction = float(pexcl.mean()) if pexcl.size else 0.0
    if pexcl.any():
        # A pattern on part of the frame (a screen in a room) is excluded so the rest measures
        # cleanly.  When most of the selected patches are the pattern, the remainder is not
        # representative: keep the full selection and let the flag speak, as the whiteness flag does.
        drop = np.zeros_like(sel)
        drop.flat[np.flatnonzero(cand)[pexcl]] = True
        n_sel = int(sel.sum())
        if n_sel and (sel & drop).sum() <= PERIODIC_MAX_EXCLUDED_FRACTION * n_sel:
            sel &= ~drop

    pm = meanY[Yg, Xg][sel]
    pstd = sR[sel]
    pchroma = np.sqrt(0.5 * (stdRG[Yg, Xg][sel] ** 2 + stdBG[Yg, Xg][sel] ** 2))
    n = int(pm.size)
    res = NoiseResult(n_patches=n, candidate_patches=n_cand, noise_whiteness=whiteness,
                      rejection_rate=float(1.0 - n / n_cand) if n_cand else float("nan"),
                      texture_suspect=bool(np.isfinite(whiteness) and whiteness > 0.7),
                      spectral_peak=peak, periodic_suspect=bool(np.isfinite(pfreq)),
                      periodic_freq_cpp=pfreq, periodic_fraction=periodic_fraction)
    if n < min_patches_per_bin:
        return res

    edges_b = np.linspace(0.0, 255.0, n_bins + 1)
    centers, ln, cn, counts = [], [], [], []
    for b in range(n_bins):
        m = (pm >= edges_b[b]) & (pm < edges_b[b + 1])
        if m.sum() >= min_patches_per_bin:
            centers.append(0.5 * (edges_b[b] + edges_b[b + 1]))
            ln.append(float(np.percentile(pstd[m], floor_percentile)))
            cn.append(float(np.percentile(pchroma[m], floor_percentile)))
            counts.append(int(m.sum()))
    if not centers:
        return res
    res.bin_centers = np.array(centers)
    res.luma_noise = np.array(ln)
    res.chroma_noise = np.array(cn)
    res.bin_counts = np.array(counts)

    c, nz = res.bin_centers, res.luma_noise
    lo_c, hi_c = float(c.min()), float(c.max())
    bin_w = 255.0 / n_bins
    j = int(np.argmin(np.abs(c - MIDGREY_8BIT)))
    res.nearest_bin_level = float(c[j])
    if lo_c - bin_w <= MIDGREY_8BIT <= hi_c + bin_w:
        res.luma_noise_midgrey = float(np.interp(MIDGREY_8BIT, c, nz))
        res.chroma_noise_midgrey = float(np.interp(MIDGREY_8BIT, c, res.chroma_noise))
        res.snr_midgrey_extrapolated = bool(abs(c[j] - MIDGREY_8BIT) > bin_w)
    else:
        # No flat patches anywhere near mid-grey: report the nearest bin, flagged.
        res.luma_noise_midgrey = float(nz[j])
        res.chroma_noise_midgrey = float(res.chroma_noise[j])
        res.snr_midgrey_extrapolated = True
    if res.luma_noise_midgrey > 0:
        res.snr_midgrey_db = float(20.0 * np.log10(MIDGREY_8BIT / res.luma_noise_midgrey))

    # Scene-linear SNR per bin: noise in encoded units -> linear via the local slope of the EOTF.
    lin = srgb_decode(c / 255.0)
    dv = 1.0 / 255.0
    slope = (srgb_decode((c + 0.5) / 255.0) - srgb_decode((c - 0.5) / 255.0)) / dv  # d lin / d (v in 0..1)
    noise_lin = (nz / 255.0) * slope
    with np.errstate(divide="ignore", invalid="ignore"):
        snr_lin = np.where(noise_lin > 0, lin / noise_lin, np.inf)
    white = float(srgb_decode(np.array(250.0 / 255.0)))
    res.darkest_bin = lo_c
    for t in (1.0, 2.0, 4.0, 10.0):
        key = f"snr{int(t)}"
        # Walk down from the brightest bin; the floor is the first bin that fails
        # the threshold, so a bad mid-tone bin cannot be skipped over.
        if snr_lin[-1] < t:
            res.dr_stops[key] = float("nan")
            res.dr_is_lower_bound[key] = False
            continue
        j = len(snr_lin) - 1
        while j > 0 and snr_lin[j - 1] >= t:
            j -= 1
        if j == 0:
            # Every measured bin passes: the floor is below the darkest flat patch found.
            level = float(lin[0])
            res.dr_is_lower_bound[key] = True
        else:
            # Interpolate the crossing in log-SNR between bins j-1 (fails) and j (passes).
            s0, s1 = np.log(max(snr_lin[j - 1], 1e-9)), np.log(snr_lin[j])
            l0, l1 = np.log(lin[j - 1]), np.log(lin[j])
            frac = (np.log(t) - s0) / (s1 - s0) if s1 != s0 else 0.0
            level = float(np.exp(l0 + frac * (l1 - l0)))
            res.dr_is_lower_bound[key] = False
        res.dr_stops[key] = float(np.log2(white / level)) if level > 0 else float("nan")
    return res
