"""Uncertainty on the per-image sharpness figures: a percentile bootstrap over the measured edges.

Ground truth for an interval is statistical: draw many "images" whose edges come from a known
distribution, and check how often the interval covers the true value.  A 95 % interval should
cover about 95 % of the time; with the small edge counts natural scenes give (around 7 valid
edges) the percentile bootstrap of a median is known to under-cover a little, so the acceptance
band is 0.85-0.99 at n = 10 and the 50 % interval must sit near 50 %.
"""
import numpy as np

from iqa.edges import measure_natural_edges
from iqa.sfr import gaussian_mtf50
from iqa.synth import synthetic_scene
from iqa.uncertainty import bootstrap_ci


def _edges(rng, n, median=0.20, spread=0.25):
    """Log-normal MTF50s around a known median: the across-frame spread a lens produces."""
    return median * np.exp(rng.normal(0.0, spread, n))


def test_coverage_of_the_true_median():
    rng = np.random.default_rng(0)
    hits95, hits50 = 0, 0
    trials = 300
    for t in range(trials):
        v = _edges(rng, 10)
        lo, hi = bootstrap_ci(v, np.median, level=0.95, n_boot=400, seed=t)
        hits95 += lo <= 0.20 <= hi
        lo, hi = bootstrap_ci(v, np.median, level=0.50, n_boot=400, seed=t)
        hits50 += lo <= 0.20 <= hi
    assert 0.85 <= hits95 / trials <= 0.99, hits95 / trials
    assert 0.38 <= hits50 / trials <= 0.64, hits50 / trials


def test_interval_narrows_with_more_edges_and_widens_with_spread():
    rng = np.random.default_rng(1)
    w = {}
    for n in (6, 12, 48):
        ws = []
        for t in range(40):
            lo, hi = bootstrap_ci(_edges(rng, n), np.median, n_boot=400, seed=t)
            ws.append(hi - lo)
        w[n] = float(np.median(ws))
    assert w[48] < w[12] < w[6], w
    ws_wide = [np.subtract(*bootstrap_ci(_edges(rng, 12, spread=0.5), np.median, n_boot=400, seed=t)[::-1]) for t in range(40)]
    assert float(np.median(ws_wide)) > 1.5 * w[12]


def test_interval_is_deterministic_and_ordered():
    v = _edges(np.random.default_rng(2), 9)
    a = bootstrap_ci(v, np.median, seed=7); b = bootstrap_ci(v, np.median, seed=7)
    assert a == b and a[0] <= np.median(v) <= a[1]


def test_too_few_edges_gives_no_interval():
    v = np.array([0.2, 0.25])
    lo, hi = bootstrap_ci(v, np.median)
    assert np.isnan(lo) and np.isnan(hi)
    lo, hi = bootstrap_ci(np.array([]), np.median)
    assert np.isnan(lo) and np.isnan(hi)


def test_p80_interval_can_be_bootstrapped_too():
    v = _edges(np.random.default_rng(3), 20)
    lo, hi = bootstrap_ci(v, lambda x: np.percentile(x, 80), seed=0)
    assert lo <= np.percentile(v, 80) <= hi and hi > lo


def test_summary_carries_intervals_that_contain_the_point_estimates():
    scene = synthetic_scene(size=1400, sigma_px=1.1, noise_8bit=3.0)
    from iqa.imageio import srgb_decode
    lin = srgb_decode(scene.astype(np.float64) / 255.0)
    lum = 0.2126 * lin[..., 0] + 0.7152 * lin[..., 1] + 0.0722 * lin[..., 2]
    s = measure_natural_edges(lum)
    assert s.n_measured >= 3
    assert s.mtf50_median_ci[0] <= s.mtf50_median <= s.mtf50_median_ci[1]
    assert s.mtf50_p80_ci[0] <= s.mtf50_p80 <= s.mtf50_p80_ci[1]
    d = s.as_dict()
    for k in ("mtf50_median_ci_lo_cpp", "mtf50_median_ci_hi_cpp", "mtf50_p80_ci_lo_cpp", "mtf50_p80_ci_hi_cpp"):
        assert np.isfinite(d[k]), k
    # the known blur is inside the interval of the overall figure
    truth = gaussian_mtf50(1.1)
    assert s.mtf50_median_ci[0] <= truth * 1.1 and s.mtf50_median_ci[1] >= truth * 0.9, (s.mtf50_median_ci, truth)


def test_summary_without_edges_has_nan_intervals():
    from iqa.synth import flat_field
    s = measure_natural_edges(flat_field(600, 600, 0.4, 0.01))
    assert s.n_measured == 0
    assert all(np.isnan(x) for x in (*s.mtf50_median_ci, *s.mtf50_p80_ci))
