"""Find natural slanted edges in a photograph and measure their SFR.

This is a *natural-scene* sharpness estimate, not an ISO 12233 chart test:
real edges are rarely perfect step functions, so the absolute MTF50 is less
trustworthy than on a chart.  It is, however, consistent across images and
tracks focus, lens softness, shake, and sharpening well.  The sharpest edges
in a photo are normally in the plane of focus, so the upper percentiles of
the per-edge MTF50 distribution are the "in-focus sharpness" and the median is
the "overall sharpness".
"""
from __future__ import annotations

from dataclasses import dataclass, field
from math import atan2, degrees, hypot

import cv2
import numpy as np

from .sfr import SFRResult, compute_sfr


@dataclass
class EdgeMeasurement:
    x0: int
    y0: int
    w: int
    h: int
    orientation: str            # "v": edge runs top-to-bottom, "h": left-to-right
    sfr: SFRResult

    def as_dict(self) -> dict:
        d = {"x0": self.x0, "y0": self.y0, "w": self.w, "h": self.h, "orientation": self.orientation}
        d.update(self.sfr.summary())
        return d


@dataclass
class EdgeSummary:
    n_candidates: int
    n_measured: int
    mtf50_median: float = float("nan")
    mtf50_p80: float = float("nan")
    mtf50_max: float = float("nan")
    mtf50p_median: float = float("nan")
    rise_median_px: float = float("nan")
    mtf_nyquist_median: float = float("nan")
    edges: list[EdgeMeasurement] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "edges_candidates": self.n_candidates,
            "edges_measured": self.n_measured,
            "mtf50_median_cpp": self.mtf50_median,
            "mtf50_p80_cpp": self.mtf50_p80,
            "mtf50_max_cpp": self.mtf50_max,
            "mtf50p_median_cpp": self.mtf50p_median,
            "edge_rise_median_px": self.rise_median_px,
            "mtf_nyquist_median": self.mtf_nyquist_median,
        }


def _candidate_segments(gray8: np.ndarray, scale: float, min_len_full: int,
                        min_slant: float, max_slant: float, max_candidates: int):
    small = gray8 if scale >= 1.0 else cv2.resize(gray8, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    small = cv2.GaussianBlur(small, (0, 0), 2.0)   # detection only; the SFR uses the raw pixels
    edges = cv2.Canny(small, 25, 75)
    min_len_small = max(10, int(min_len_full * scale * 0.6))
    lines = cv2.HoughLinesP(edges, 1, np.pi / 720, threshold=30,
                            minLineLength=min_len_small, maxLineGap=2)
    if lines is None:
        return []
    lines = np.asarray(lines).reshape(-1, 4)       # OpenCV 4 returns (N,1,4); OpenCV 5 returns (N,4)
    cands = []
    for x1, y1, x2, y2 in lines:
        dx, dy = float(x2 - x1), float(y2 - y1)
        length = hypot(dx, dy)
        a = abs(degrees(atan2(dy, dx))) % 180.0           # 0 = horizontal
        slant_v, slant_h = abs(90.0 - a), min(a, 180.0 - a)
        if min_slant <= slant_v <= max_slant:
            orient = "v"
        elif min_slant <= slant_h <= max_slant:
            orient = "h"
        else:
            continue
        cx, cy = (x1 + x2) / 2.0 / scale, (y1 + y2) / 2.0 / scale
        cands.append((length / scale, orient, cx, cy))
    cands.sort(key=lambda c: -c[0])
    # Non-maximum suppression on segment centres so one long edge is not measured many times.
    kept = []
    min_sep = 48.0
    for c in cands:
        if all(hypot(c[2] - k[2], c[3] - k[3]) > min_sep for k in kept):
            kept.append(c)
        if len(kept) >= max_candidates:
            break
    return kept


def measure_natural_edges(lin_luma: np.ndarray, max_rois: int = 30, roi_len: int = 96,
                          roi_across: int = 64, min_contrast: float = 0.20,
                          det_long_side: int = 1600, min_slant: float = 1.5,
                          max_slant: float = 12.0, max_candidates: int = 160) -> EdgeSummary:
    """Detect slanted straight edges and compute the SFR of each.

    ``lin_luma`` is scene-linear luminance (float, 0..1) at native resolution.
    """
    h, w = lin_luma.shape
    scale = min(1.0, det_long_side / float(max(h, w)))
    gray8 = np.clip(np.power(np.clip(lin_luma, 0.0, 1.0), 1.0 / 2.2) * 255.0, 0, 255).astype(np.uint8)
    cands = _candidate_segments(gray8, scale, roi_len, min_slant, max_slant, max_candidates)

    measured: list[EdgeMeasurement] = []
    for length, orient, cx, cy in cands:
        L = int(max(32, min(roi_len, length * 0.9)))
        A = roi_across
        if orient == "v":
            x0, y0, rw, rh = int(cx - A / 2), int(cy - L / 2), A, L
        else:
            x0, y0, rw, rh = int(cx - L / 2), int(cy - A / 2), L, A
        if x0 < 0 or y0 < 0 or x0 + rw > w or y0 + rh > h:
            continue
        roi = lin_luma[y0:y0 + rh, x0:x0 + rw].astype(np.float64)
        if orient == "h":
            roi = roi.T
        try:
            res = compute_sfr(roi)
        except (ValueError, FloatingPointError):
            continue
        if not np.isfinite(res.mtf50):
            continue
        if res.contrast < min_contrast or res.plateau_noise > 0.15:
            continue
        if res.fit_rms_px > 0.4 or not (1.0 <= abs(res.slope_deg) <= 16.0):
            continue
        if res.rise_10_90_px > 8.0 or res.mtf50 > 0.6:
            continue
        measured.append(EdgeMeasurement(x0, y0, rw, rh, orient, res))
        if len(measured) >= max_rois:
            break

    summ = EdgeSummary(n_candidates=len(cands), n_measured=len(measured), edges=measured)
    if measured:
        m50 = np.array([e.sfr.mtf50 for e in measured])
        summ.mtf50_median = float(np.median(m50))
        summ.mtf50_p80 = float(np.percentile(m50, 80))
        summ.mtf50_max = float(m50.max())
        summ.mtf50p_median = float(np.median([e.sfr.mtf50p for e in measured]))
        summ.rise_median_px = float(np.median([e.sfr.rise_10_90_px for e in measured]))
        summ.mtf_nyquist_median = float(np.median([e.sfr.mtf_nyquist for e in measured]))
    return summ


def lw_per_ph(mtf50_cpp: float, height_px: int) -> float:
    """Imatest-style line widths per picture height: 2 x MTF50 (c/px) x height."""
    return float(2.0 * mtf50_cpp * height_px)
