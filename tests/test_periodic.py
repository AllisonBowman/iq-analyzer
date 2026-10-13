"""Periodic-texture detector for the noise module (FINDINGS.md section 5, item 1).

Photographs of screens and fabric contain a repeating pattern whose amplitude is
comparable to the sensor noise.  The single-frame estimator reads it as noise, and
the smoothed/raw whiteness gate only catches the coarse cases.  The spectral detector
averages the normalised power spectrum of every candidate patch and looks for a bin
that stands far above both its annulus (the radial envelope) and its neighbourhood
(the local anisotropy).  Thresholds below come from measured distributions:

    synthetic negatives (white, pink, Gaussian-smoothed, anisotropic noise,
    JPEG q50/q75 blocking)                              peak 1.1 .. 3.8
    28 ordinary library files, four cameras, HEIC+JPEG   peak 1.6 .. 7.1
    sinusoid at half the noise amplitude, full frame      peak 33
    noise-strength grid on 11 % of the frame              peak 16
    the library's screen photo (whiteness 0.12)           peak 41

so ``PERIODIC_PEAK_THRESHOLD`` = 8 sits between every negative and every positive
with a factor of two to spare on each side.
"""
import numpy as np

from iqa.noise import PERIODIC_PEAK_THRESHOLD, analyze_noise

SIGMA = 3.0          # 8-bit luma noise of the synthetic scenes
SIZE = 1200


def _scene(seed: int = 1, size: int = SIZE) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """A gently lit grey field (so patches span several brightness bins) plus coordinates."""
    yy, xx = np.mgrid[:size, :size].astype(np.float32)
    base = 118.0 + 30.0 * np.sin(2 * np.pi * yy / size) + 20.0 * np.cos(2 * np.pi * xx / size)
    rng = np.random.default_rng(seed)
    noise = rng.normal(0.0, SIGMA, (size, size)).astype(np.float32)
    return base, noise, (yy, xx)


def _rgb(Y: np.ndarray) -> np.ndarray:
    return np.clip(np.round(np.stack([Y, Y, Y], axis=-1)), 0, 255).astype(np.uint8)


def _sine(coords, freq_cpp: float, angle_rad: float, amp: float) -> np.ndarray:
    yy, xx = coords
    return amp * np.sin(2 * np.pi * freq_cpp * (xx * np.cos(angle_rad) + yy * np.sin(angle_rad)))


# --- negatives: nothing periodic must be flagged -------------------------------------------

def test_white_noise_is_not_periodic():
    base, noise, _ = _scene()
    res = analyze_noise(_rgb(base + noise))
    assert res.n_patches > 500
    assert res.spectral_peak < 3.0, res.spectral_peak
    assert not res.periodic_suspect
    assert res.periodic_fraction == 0.0


def test_smoothed_noise_is_not_periodic():
    """Noise-reduced output has a coloured spectrum; the radial envelope must not read as a peak."""
    import cv2
    base, noise, _ = _scene()
    nr = cv2.GaussianBlur(noise, (0, 0), 1.5) * 3.0
    res = analyze_noise(_rgb(base + nr))
    assert res.spectral_peak < 3.0, res.spectral_peak
    assert not res.periodic_suspect


def test_anisotropic_noise_is_not_periodic():
    """Demosaic/sharpening make the spectrum stronger along the axes; a ridge is not a peak."""
    import cv2
    base, noise, _ = _scene()
    an = cv2.GaussianBlur(noise, (0, 0), sigmaX=0.3, sigmaY=1.8) * 2.5
    res = analyze_noise(_rgb(base + an))
    assert res.spectral_peak < PERIODIC_PEAK_THRESHOLD * 0.75, res.spectral_peak
    assert not res.periodic_suspect


def test_jpeg_blocking_is_not_periodic():
    """8x8 block edges are periodic at 1/8 c/px on the axes but must stay below threshold."""
    import cv2
    base, noise, _ = _scene()
    rgb = _rgb(base + 2.0 * noise)
    enc = cv2.imencode(".jpg", rgb[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, 50])[1]
    dec = cv2.imdecode(enc, cv2.IMREAD_COLOR)[..., ::-1]
    res = analyze_noise(np.ascontiguousarray(dec))
    assert res.spectral_peak < PERIODIC_PEAK_THRESHOLD * 0.75, res.spectral_peak
    assert not res.periodic_suspect


# --- positives: a repeating pattern comparable to the noise must be flagged ------------------

def test_full_frame_grid_is_flagged_and_located():
    """A 4-pixel pixel grid at noise amplitude (the screen-photo case)."""
    base, noise, (yy, xx) = _scene()
    grid = SIGMA * (np.sin(2 * np.pi * 0.25 * xx) + np.sin(2 * np.pi * 0.25 * yy))
    res = analyze_noise(_rgb(base + noise + grid))
    assert res.periodic_suspect
    assert res.spectral_peak > 20.0, res.spectral_peak
    assert abs(res.periodic_freq_cpp - 0.25) <= 1.0 / 32, res.periodic_freq_cpp
    assert res.periodic_fraction > 0.8, res.periodic_fraction
    # The whole frame is the pattern: flagged, but the measurement is kept, not destroyed.
    assert res.n_patches > 500 and np.isfinite(res.snr_midgrey_db)


def test_half_amplitude_slanted_sinusoid_is_flagged():
    """A fabric-like weave at half the noise amplitude, 17 degrees off axis."""
    base, noise, coords = _scene()
    res = analyze_noise(_rgb(base + noise + _sine(coords, 0.23, 0.3, 0.5 * SIGMA)))
    assert res.periodic_suspect
    assert res.spectral_peak > 2 * PERIODIC_PEAK_THRESHOLD, res.spectral_peak
    assert abs(res.periodic_freq_cpp - 0.23) <= 1.0 / 32, res.periodic_freq_cpp


def test_near_nyquist_sinusoid_is_flagged():
    base, noise, coords = _scene()
    res = analyze_noise(_rgb(base + noise + _sine(coords, 0.42, 0.0, SIGMA)))
    assert res.periodic_suspect
    assert abs(res.periodic_freq_cpp - 0.42) <= 1.0 / 32, res.periodic_freq_cpp


def test_partial_frame_grid_is_flagged_and_excluded():
    """A screen covering 11 % of the frame: flagged, and the noise figure recovers to the
    value measured on the same noise without the screen because its patches are excluded."""
    base, noise, (yy, xx) = _scene()
    clean = analyze_noise(_rgb(base + noise))
    mask = np.zeros_like(noise); mask[:400, :400] = 1.0
    grid = SIGMA * (np.sin(2 * np.pi * 0.25 * xx) + np.sin(2 * np.pi * 0.25 * yy)) * mask
    res = analyze_noise(_rgb(base + noise + grid))
    assert res.periodic_suspect
    assert res.spectral_peak > PERIODIC_PEAK_THRESHOLD, res.spectral_peak
    assert 0.05 < res.periodic_fraction < 0.25, res.periodic_fraction
    # Without exclusion the grid patches (std ~ 3.9x noise) would not lower the 15th-percentile
    # floor, but they would be counted as noise patches; with exclusion the floor is unchanged.
    assert abs(res.luma_noise_midgrey - clean.luma_noise_midgrey) / clean.luma_noise_midgrey < 0.05


def test_unflagged_image_results_are_unchanged():
    """When nothing is periodic the detector must not touch the selection or the figures."""
    base, noise, _ = _scene(seed=7)
    res = analyze_noise(_rgb(base + noise))
    d = res.as_dict()
    assert d["noise_periodic_suspect"] is False
    assert d["noise_periodic_fraction"] == 0.0
    assert np.isfinite(d["noise_spectral_peak"])
    assert np.isnan(d["noise_periodic_freq_cpp"])
    # The three legacy counts are exactly what the pre-detector selection gives.
    assert res.n_patches == res.candidate_patches - round(res.rejection_rate * res.candidate_patches)
