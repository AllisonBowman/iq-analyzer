"""Chart mode, part 1: colour accuracy.

Ground truth comes from two places: the CIEDE2000 test pairs published with the formula
(Sharma, Wu & Dalal 2005, Table 1: 34 pairs with the correct dE00 to four decimals), and a
synthetic ColorChecker rendered from the chart's reference L*a*b* values, photographed through
a known homography, blurred, noised and JPEG-compressed.
"""
import numpy as np
import pytest

from iqa.color import (COLORCHECKER_LAB, OUT_OF_SRGB_GAMUT, delta_e_2000, lab_to_srgb8, srgb8_to_lab,
                       find_colorchecker, measure_colorchecker)
from iqa.synth import render_colorchecker

# (L1, a1, b1, L2, a2, b2, dE00) -- Sharma, Wu & Dalal 2005, Table 1.
SHARMA_PAIRS = [
    (50.0000, 2.6772, -79.7751, 50.0000, 0.0000, -82.7485, 2.0425),
    (50.0000, 3.1571, -77.2803, 50.0000, 0.0000, -82.7485, 2.8615),
    (50.0000, 2.8361, -74.0200, 50.0000, 0.0000, -82.7485, 3.4412),
    (50.0000, -1.3802, -84.2814, 50.0000, 0.0000, -82.7485, 1.0000),
    (50.0000, -1.1848, -84.8006, 50.0000, 0.0000, -82.7485, 1.0000),
    (50.0000, -0.9009, -85.5211, 50.0000, 0.0000, -82.7485, 1.0000),
    (50.0000, 0.0000, 0.0000, 50.0000, -1.0000, 2.0000, 2.3669),
    (50.0000, -1.0000, 2.0000, 50.0000, 0.0000, 0.0000, 2.3669),
    (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0009, 7.1792),
    (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0010, 7.1792),
    (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0011, 7.2195),
    (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0012, 7.2195),
    (50.0000, -0.0010, 2.4900, 50.0000, 0.0009, -2.4900, 4.8045),
    (50.0000, -0.0010, 2.4900, 50.0000, 0.0010, -2.4900, 4.8045),
    (50.0000, -0.0010, 2.4900, 50.0000, 0.0011, -2.4900, 4.7461),
    (50.0000, 2.5000, 0.0000, 50.0000, 0.0000, -2.5000, 4.3065),
    (50.0000, 2.5000, 0.0000, 73.0000, 25.0000, -18.0000, 27.1492),
    (50.0000, 2.5000, 0.0000, 61.0000, -5.0000, 29.0000, 22.8977),
    (50.0000, 2.5000, 0.0000, 56.0000, -27.0000, -3.0000, 31.9030),
    (50.0000, 2.5000, 0.0000, 58.0000, 24.0000, 15.0000, 19.4535),
    (50.0000, 2.5000, 0.0000, 50.0000, 3.1736, 0.5854, 1.0000),
    (50.0000, 2.5000, 0.0000, 50.0000, 3.2972, 0.0000, 1.0000),
    (50.0000, 2.5000, 0.0000, 50.0000, 1.8634, 0.5757, 1.0000),
    (50.0000, 2.5000, 0.0000, 50.0000, 3.2592, 0.3350, 1.0000),
    (60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644),
    (63.0109, -31.0961, -5.8663, 62.8187, -29.7946, -4.0864, 1.2630),
    (61.2901, 3.7196, -5.3901, 61.4292, 2.2480, -4.9620, 1.8731),
    (35.0831, -44.1164, 3.7933, 35.0232, -40.0716, 1.5901, 1.8645),
    (22.7233, 20.0904, -46.6940, 23.0331, 14.9730, -42.5619, 2.0373),
    (36.4612, 47.8580, 18.3852, 36.2715, 50.5065, 21.2231, 1.4146),
    (90.8027, -2.0831, 1.4410, 91.1528, -1.6435, 0.0447, 1.4441),
    (90.9257, -0.5406, -0.9208, 88.6381, -0.8985, -0.7239, 1.5381),
    (6.7747, -0.2908, -2.4247, 5.8714, -0.0985, -2.2286, 0.6377),
    (2.0776, 0.0795, -1.1350, 0.9033, -0.0636, -0.5514, 0.9082),
]


def test_ciede2000_matches_the_published_pairs():
    lab1 = np.array([p[:3] for p in SHARMA_PAIRS]); lab2 = np.array([p[3:6] for p in SHARMA_PAIRS])
    want = np.array([p[6] for p in SHARMA_PAIRS])
    got = delta_e_2000(lab1, lab2)
    assert np.allclose(got, want, atol=1e-4), np.c_[got, want]
    # symmetric
    assert np.allclose(delta_e_2000(lab2, lab1), want, atol=1e-4)


def test_srgb_to_lab_anchors():
    """sRGB white is L* 100 and neutral after the D65->D50 adaptation; mid-grey 118 is L* ~ 49.5."""
    white = srgb8_to_lab(np.array([[[255, 255, 255]]], dtype=np.uint8))[0, 0]
    assert abs(white[0] - 100.0) < 0.05 and abs(white[1]) < 0.2 and abs(white[2]) < 0.2, white
    grey = srgb8_to_lab(np.array([[[118, 118, 118]]], dtype=np.uint8))[0, 0]
    assert abs(grey[0] - 49.5) < 0.5 and abs(grey[1]) < 0.2 and abs(grey[2]) < 0.2, grey
    black = srgb8_to_lab(np.zeros((1, 1, 3), dtype=np.uint8))[0, 0]
    assert abs(black[0]) < 1e-6


def test_lab_srgb_round_trip_on_the_chart():
    rgb = lab_to_srgb8(COLORCHECKER_LAB)
    back = srgb8_to_lab(rgb.reshape(1, 24, 3)).reshape(24, 3)
    de = delta_e_2000(back, COLORCHECKER_LAB)
    inside = np.ones(24, bool); inside[list(OUT_OF_SRGB_GAMUT)] = False
    assert de[inside].max() < 0.8, de    # 8-bit quantisation only (black is the worst, 0.7)
    assert de[~inside].min() > 1.0       # cyan cannot be rendered in sRGB: the gamut clip shows


def _photo(seed=0, cast=(1.0, 1.0, 1.0), sigma=1.2, noise=2.0, quality=90, tilt=0.15):
    """A synthetic photograph of the chart: perspective, blur, noise, JPEG, optional RGB cast."""
    import cv2
    from iqa.imageio import srgb_decode, srgb_encode
    img, centres = render_colorchecker(size=1600, tilt=tilt, seed=seed)
    lin = srgb_decode(img.astype(np.float64) / 255.0) * np.array(cast, dtype=np.float64)   # gain in linear light
    f = (srgb_encode(np.clip(lin, 0, 1)) * 255.0).astype(np.float32)
    f = cv2.GaussianBlur(f, (0, 0), sigma)
    rng = np.random.default_rng(seed)
    f = f + rng.normal(0.0, noise, f.shape).astype(np.float32)
    u8 = np.clip(np.round(f), 0, 255).astype(np.uint8)
    enc = cv2.imencode(".jpg", u8[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, quality])[1]
    return np.ascontiguousarray(cv2.imdecode(enc, cv2.IMREAD_COLOR)[..., ::-1]), centres


def test_colorchecker_is_found_and_patch_centres_are_right():
    rgb, centres = _photo()
    chart = find_colorchecker(rgb)
    assert chart is not None, "chart not found"
    assert chart.centres.shape == (24, 2)
    err = np.hypot(*(chart.centres - centres).T)
    assert err.max() < 4.0, err          # pixels, on a 1600-px frame


def test_colorchecker_measures_near_zero_error_on_a_faithful_rendering():
    rgb, _ = _photo()
    chart = find_colorchecker(rgb)
    m = measure_colorchecker(rgb, chart)
    assert m.de00.shape == (24,)
    inside = np.ones(24, bool); inside[list(OUT_OF_SRGB_GAMUT)] = False
    assert m.de00[inside].mean() < 1.0, m.de00
    assert m.de00[inside].max() < 2.0, m.de00
    assert 2.0 < m.de00[~inside].max() < 4.0        # cyan: the sRGB gamut clip, not a measurement error
    assert abs(m.wb_r_over_g_stops) < 0.03 and abs(m.wb_b_over_g_stops) < 0.03, (m.wb_r_over_g_stops, m.wb_b_over_g_stops)


def test_colorchecker_reports_a_colour_cast():
    """A +0.3 stop red gain on the rendering must show up as a red white-balance error of that
    size on the neutral patches, and raise the chromatic patches' dE00."""
    rgb, _ = _photo(cast=(2 ** 0.3, 1.0, 1.0), noise=1.0)
    chart = find_colorchecker(rgb)
    m = measure_colorchecker(rgb, chart)
    assert abs(m.wb_r_over_g_stops - 0.3) < 0.05, m.wb_r_over_g_stops
    assert abs(m.wb_b_over_g_stops) < 0.05, m.wb_b_over_g_stops
    assert m.de00_mean > 3.0, m.de00_mean


def test_no_chart_in_a_plain_scene():
    from iqa.synth import synthetic_scene
    assert find_colorchecker(synthetic_scene(size=900)) is None


def test_colorchecker_survives_rotation_and_small_scale():
    rgb, centres = _photo(seed=3, tilt=0.25)
    chart = find_colorchecker(rgb)
    assert chart is not None
    assert np.hypot(*(chart.centres - centres).T).max() < 5.0
