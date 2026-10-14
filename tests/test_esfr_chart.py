"""Chart mode, part 2: an ISO 12233:2014 e-SFR style chart of slanted squares.

Ground truth: a chart rendered from the analytic edge spread function (error function) with a
known Gaussian blur, so every edge's MTF is exp(-2 pi^2 sigma^2 f^2) and MTF50 is
``iqa.sfr.gaussian_mtf50(sigma)``.  A field-dependent blur (sigma growing with radius) checks
that the across-the-frame map orders centre and corners correctly.
"""
import numpy as np

from iqa.chart_sfr import find_slanted_squares, measure_esfr_chart
from iqa.sfr import gaussian_mtf50
from iqa.synth import flat_field, render_esfr_chart


def test_all_squares_and_edges_are_found_on_a_uniform_chart():
    lin, truth = render_esfr_chart(size=2000, cols=5, rows=4, angle_deg=5.0, sigma_px=1.0, noise=0.004)
    squares = find_slanted_squares(lin)
    assert len(squares) == 20, len(squares)
    got = np.array([s.centre for s in squares]); want = np.array([t["centre"] for t in truth])
    d = np.hypot(*(got[:, None, :] - want[None, :, :]).transpose(2, 0, 1)).min(axis=1)
    assert d.max() < 3.0, d
    res = measure_esfr_chart(lin)
    assert res.n_squares == 20 and res.n_edges >= 76, (res.n_squares, res.n_edges)


def test_every_edge_recovers_the_known_blur():
    lin, _ = render_esfr_chart(size=2000, cols=5, rows=4, angle_deg=5.0, sigma_px=1.0, noise=0.004)
    res = measure_esfr_chart(lin)
    want = gaussian_mtf50(1.0)
    m = np.array([e.mtf50 for s in res.squares for e in s.edges])
    assert np.all(np.abs(m - want) / want < 0.06), (m.min(), m.max(), want)
    assert abs(res.mtf50_median - want) / want < 0.03


def test_field_map_orders_centre_before_corners():
    """sigma = 0.8 + 1.2 r (r = 0 at the centre, 1 at the corner): a soft-cornered lens."""
    # 5 x 5 so the corner squares sit at r = 0.67, inside the outer field (r > 0.65)
    lin, truth = render_esfr_chart(size=2000, cols=5, rows=5, angle_deg=5.0,
                                   sigma_px=lambda r: 0.8 + 1.2 * r, noise=0.004)
    res = measure_esfr_chart(lin)
    assert res.n_squares == 25
    assert res.mtf50_center_median > 1.3 * res.mtf50_outer_median, (res.mtf50_center_median, res.mtf50_outer_median)
    # per square: the mean of its four edges matches the blur that square was rendered with
    truth_by_centre = {tuple(np.round(t["centre"])): t["sigma"] for t in truth}
    for s in res.squares:
        key = min(truth_by_centre, key=lambda k: np.hypot(k[0] - s.centre[0], k[1] - s.centre[1]))
        want = gaussian_mtf50(truth_by_centre[key])
        assert abs(s.mtf50_mean - want) / want < 0.08, (s.centre, s.mtf50_mean, want)


def test_radial_and_tangential_edges_are_labelled():
    lin, _ = render_esfr_chart(size=2000, cols=5, rows=4, angle_deg=5.0, sigma_px=1.0, noise=0.004)
    res = measure_esfr_chart(lin)
    dirs = [e.direction for s in res.squares for e in s.edges]
    assert set(dirs) <= {"radial", "tangential"}
    assert dirs.count("radial") > 20 and dirs.count("tangential") > 20
    # on an isotropic blur the two agree
    assert abs(res.mtf50_radial_median - res.mtf50_tangential_median) / res.mtf50_radial_median < 0.04


def test_axis_aligned_squares_are_not_usable_targets():
    lin, _ = render_esfr_chart(size=1200, cols=3, rows=2, angle_deg=0.0, sigma_px=1.0)
    assert len(find_slanted_squares(lin)) == 0


def test_no_squares_in_a_flat_field():
    lin = flat_field(900, 900, 0.4, 0.01)
    assert len(find_slanted_squares(lin)) == 0
    assert measure_esfr_chart(lin).n_squares == 0
