"""The slanted-edge SFR must recover a known Gaussian blur."""
import numpy as np
import pytest

from iqa.sfr import compute_sfr, gaussian_mtf50
from iqa.synth import slanted_edge


@pytest.mark.parametrize("sigma", [0.7, 1.0, 1.5, 2.5])
@pytest.mark.parametrize("angle", [3.0, 5.0, 8.0, 11.0])
def test_mtf50_matches_analytic_noise_free(sigma, angle):
    img = slanted_edge(h=120, w=80, angle_deg=angle, sigma_px=sigma)
    r = compute_sfr(img)
    expected = gaussian_mtf50(sigma)
    assert abs(r.mtf50 - expected) / expected < 0.04
    assert abs(r.slope_deg - angle) < 0.15
    assert r.fit_rms_px < 0.05
    assert abs(r.contrast - 0.6) < 0.02


@pytest.mark.parametrize("sigma", [0.7, 1.0, 1.5, 2.5])
@pytest.mark.parametrize("angle", [3.0, 8.0, 11.0])
@pytest.mark.parametrize("seed", [0, 1])
def test_mtf50_with_noise(sigma, angle, seed):
    img = slanted_edge(h=120, w=80, angle_deg=angle, sigma_px=sigma, noise=0.01, seed=seed)
    r = compute_sfr(img)
    expected = gaussian_mtf50(sigma)
    assert abs(r.mtf50 - expected) / expected < 0.06


def test_whole_mtf_curve_matches_gaussian():
    sigma = 1.2
    img = slanted_edge(h=140, w=90, angle_deg=6.0, sigma_px=sigma)
    r = compute_sfr(img)
    sel = (r.freq > 0.02) & (r.freq < 0.4)
    expected = np.exp(-2 * np.pi ** 2 * sigma ** 2 * r.freq[sel] ** 2)
    assert np.max(np.abs(r.mtf[sel] - expected)) < 0.02
    # Relative accuracy where the curve carries signal (MTF > 0.1): within 5 %.
    strong = expected > 0.1
    assert np.max(np.abs(r.mtf[sel][strong] - expected[strong]) / expected[strong]) < 0.05


def test_dark_to_bright_and_bright_to_dark_agree():
    a = slanted_edge(h=120, w=80, angle_deg=5.0, sigma_px=1.0, low=0.2, high=0.8)
    b = slanted_edge(h=120, w=80, angle_deg=5.0, sigma_px=1.0, low=0.8, high=0.2)
    ra, rb = compute_sfr(a), compute_sfr(b)
    assert abs(ra.mtf50 - rb.mtf50) < 0.003


def test_rise_width_tracks_blur():
    r1 = compute_sfr(slanted_edge(sigma_px=1.0))
    r2 = compute_sfr(slanted_edge(sigma_px=2.0))
    # 10-90 % rise of a Gaussian ESF is 2.563 sigma; 5 % relative.
    assert abs(r1.rise_10_90_px - 2.563) / 2.563 < 0.05
    assert abs(r2.rise_10_90_px - 5.126) / 5.126 < 0.05


def test_rejects_tiny_roi():
    with pytest.raises(ValueError):
        compute_sfr(np.zeros((4, 10)))
