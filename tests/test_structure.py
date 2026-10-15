"""Structure analysis: where the detail is, how it is oriented, how the frame is composed, and
which edges belong to the in-focus subject.

Ground truth: scenes drawn with the sharp region, the stripe direction, the horizon tilt and the
focus split chosen in advance.
"""
import numpy as np

from iqa.structure import analyze_structure, focus_split
from iqa.synth import synthetic_scene


def _scene(size=1200, seed=0):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[:size, :size].astype(np.float32)
    base = 120.0 + 20.0 * np.sin(2 * np.pi * yy / size)
    return base, rng.normal(0.0, 2.0, (size, size)).astype(np.float32), (yy, xx)


def _rgb(Y):
    return np.clip(np.round(np.stack([Y, Y, Y], -1)), 0, 255).astype(np.uint8)


def test_focus_map_finds_the_sharp_region_and_its_thirds_position():
    """A sharp checker texture in the top-right third of an otherwise smooth frame."""
    import cv2
    base, noise, (yy, xx) = _scene()
    tex = 40.0 * np.sign(np.sin(2 * np.pi * xx / 12) * np.sin(2 * np.pi * yy / 12))
    mask = np.zeros_like(base); mask[150:450, 750:1050] = 1.0            # cell row 1, col 4 of 4x6 (top-right third)
    Y = base + noise + tex * mask
    s = analyze_structure(_rgb(Y))
    assert s.focus_map.shape == (4, 6)
    r, c = s.focus_peak_cell
    assert r in (0, 1) and c in (3, 4), (r, c)
    assert s.focus_region_fraction < 0.25, s.focus_region_fraction      # the subject is a small part of the frame
    assert s.composition_thirds_distance < 0.2, s.composition_thirds_distance   # it sits on a thirds point
    # a frame that is sharp everywhere has a large in-focus fraction
    Y2 = base + noise + tex
    s2 = analyze_structure(_rgb(Y2))
    assert s2.focus_region_fraction > 0.8, s2.focus_region_fraction


def test_orientation_shares_follow_the_stripes():
    base, noise, (yy, xx) = _scene()
    v = base + noise + 30.0 * np.sign(np.sin(2 * np.pi * xx / 40))      # vertical stripes: horizontal gradients
    s = analyze_structure(_rgb(v))
    assert s.orientation_vertical_share > 0.7, (s.orientation_vertical_share, s.orientation_horizontal_share)
    h = base + noise + 30.0 * np.sign(np.sin(2 * np.pi * yy / 40))
    s = analyze_structure(_rgb(h))
    assert s.orientation_horizontal_share > 0.7
    d = base + noise + 30.0 * np.sign(np.sin(2 * np.pi * (xx + yy) / 56))
    s = analyze_structure(_rgb(d))
    assert s.orientation_diagonal_share > 0.7


def test_horizon_tilt_is_recovered():
    base, noise, (yy, xx) = _scene()
    for tilt in (0.0, 1.5, -2.5):
        th = np.radians(tilt)
        line = (yy - 600) * np.cos(th) - (xx - 600) * np.sin(th)          # a long horizon-like edge
        Y = base + noise + np.where(line > 0, -40.0, 40.0)
        s = analyze_structure(_rgb(Y))
        assert s.horizon_tilt_deg is not None
        assert abs(s.horizon_tilt_deg - tilt) < 0.4, (tilt, s.horizon_tilt_deg)


def test_no_horizon_in_a_busy_frame_without_a_long_level_edge():
    s = analyze_structure(synthetic_scene(size=1000))
    assert s.horizon_tilt_deg is None or abs(s.horizon_tilt_deg) < 12   # squares are slanted 4-9 degrees, no horizon claimed


def test_texture_flat_edge_shares_sum_to_one():
    s = analyze_structure(synthetic_scene(size=1000))
    assert abs(s.flat_share + s.texture_share + s.edge_share - 1.0) < 1e-6
    assert s.flat_share > 0.3                                           # the gradient background is flat


def test_focus_split_separates_two_clusters_and_declines_one():
    vals = np.array([0.30, 0.32, 0.29, 0.31, 0.12, 0.10, 0.13, 0.11, 0.12])
    fs = focus_split(vals)
    assert fs is not None
    assert abs(fs["infocus_mtf50"] - 0.305) < 0.01 and abs(fs["background_mtf50"] - 0.116) < 0.01
    assert abs(fs["infocus_share"] - 4 / 9) < 1e-6
    assert focus_split(np.array([0.20, 0.21, 0.19, 0.22, 0.20, 0.21])) is None   # one cluster: no split
    assert focus_split(np.array([0.2, 0.3])) is None                              # too few
