"""Uncertainty on summary figures: a percentile bootstrap over the measured edges.

A per-image sharpness figure is a median (or 80th percentile) of a handful of edges whose
MTF50 values spread across the frame (focus, field position, subject contrast).  The bootstrap
resamples the measured edges with replacement ``n_boot`` times, recomputes the statistic, and
reports the central ``level`` of the resulting distribution.  It is a statement about how much
the figure would move if a different handful of edges had been found in the same frame; it is
not the measurement error of one edge (that is tiny on a chart and set by noise), and it says
nothing about the scene-dependent bias of natural edges (every natural-edge MTF50 is a lower
bound on the system MTF).  With n < 3 edges there is no interval; with 3-6 the interval is
wide and often reaches the extremes of the sample, which is the honest answer.
"""
from __future__ import annotations

from typing import Callable

import numpy as np

MIN_N = 3


def bootstrap_ci(values: np.ndarray, stat: Callable[[np.ndarray], float], level: float = 0.95,
                 n_boot: int = 2000, seed: int = 0) -> tuple[float, float]:
    """Percentile bootstrap interval of ``stat`` over ``values``.  (nan, nan) when n < MIN_N."""
    v = np.asarray(values, dtype=np.float64)
    v = v[np.isfinite(v)]
    n = v.size
    if n < MIN_N:
        return float("nan"), float("nan")
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, n, size=(n_boot, n))
    samples = v[idx]
    stats = np.apply_along_axis(stat, 1, samples) if stat is not np.median else np.median(samples, axis=1)
    alpha = 0.5 * (1.0 - level)
    lo, hi = np.percentile(stats, [100.0 * alpha, 100.0 * (1.0 - alpha)])
    return float(lo), float(hi)
