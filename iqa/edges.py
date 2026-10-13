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
    overshoot_median_pct: float = float("nan")
    mtf50_v_median: float = float("nan")     # edges running top-to-bottom (horizontal resolution)
    mtf50_h_median: float = float("nan")     # edges running left-to-right (vertical resolution)
    mtf50_center_median: float = float("nan")   # ROIs within 40 % of the half-diagonal
    mtf50_outer_median: float = float("nan")    # ROIs beyond 65 % of the half-diagonal
    n_center: int = 0
    n_outer: int = 0
    n_rejected: int = 0
    reject_reasons: dict = field(default_factory=dict)
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
            "overshoot_median_pct": self.overshoot_median_pct,
            "mtf50_v_median_cpp": self.mtf50_v_median,
            "mtf50_h_median_cpp": self.mtf50_h_median,
            "mtf50_center_median_cpp": self.mtf50_center_median,
            "mtf50_outer_median_cpp": self.mtf50_outer_median,
            "edges_center": self.n_center,
            "edges_outer": self.n_outer,
            "edges_rejected": self.n_rejected,
            "edges_reject_reasons": ";".join(f"{k}={v}" for k, v in sorted(self.reject_reasons.items())),
        }


def _candidate_segments(gray8: np.ndarray, scale: float, min_len_full: int,
                        min_slant: float, max_slant: float, max_candidates: int,
                        min_sep_px: int = 96):
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
    min_sep = float(min_sep_px)
    for c in cands:
        if all(hypot(c[2] - k[2], c[3] - k[3]) > min_sep for k in kept):
            kept.append(c)
        if len(kept) >= max_candidates:
            break
    return kept


def measure_natural_edges(lin_luma: np.ndarray, max_rois: int = 30, roi_len: int = 96,
                          roi_across: int = 64, min_step: float = 0.04,
                          max_plateau_noise: float = 0.05, max_shading: float = 0.4,
                          max_clipped: float = 0.005, det_long_side: int = 1600,
                          min_slant: float = 1.5, max_slant: float = 12.0,
                          max_candidates: int = 160) -> EdgeSummary:
    """Detect slanted straight edges and compute the SFR of each.

    ``lin_luma`` is scene-linear luminance (float, 0..1) at native resolution.

    An ROI is kept only when its ESF is a valid step: no saturated pixels
    (clipping inflates MTF50), an absolute step of at least ``min_step`` with
    plateau residual noise below ``max_plateau_noise`` of the step (edge SNR
    >= 20), shading below ``max_shading`` of the step after removal, Michelson
    contrast <= 1, a straight-line fit residual below 0.4 px, and a slant
    inside 1-16 degrees.  Rejection counts are returned in ``reject_reasons``.
    """
    h, w = lin_luma.shape
    scale = min(1.0, det_long_side / float(max(h, w)))
    gray8 = np.clip(np.power(np.clip(lin_luma, 0.0, 1.0), 1.0 / 2.2) * 255.0, 0, 255).astype(np.uint8)
    cands = _candidate_segments(gray8, scale, roi_len, min_slant, max_slant, max_candidates, min_sep_px=roi_len)

    measured: list[EdgeMeasurement] = []
    reasons: dict[str, int] = {}
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
            reasons["error"] = reasons.get("error", 0) + 1
            continue
        why = None
        if res.clipped_frac > max_clipped:
            why = "clipped"
        elif not np.isfinite(res.mtf50):
            why = "no_mtf50_below_nyquist"
        elif res.contrast > 1.0:
            why = "contrast_gt_1"
        elif res.step < min_step:
            why = "step_too_small"
        elif res.plateau_noise > max_plateau_noise:
            why = "plateau_noise"
        elif res.shading > max_shading:
            why = "shading"
        elif res.fit_rms_px > 0.4:
            why = "fit_residual"
        elif not (1.0 <= abs(res.slope_deg) <= 16.0):
            why = "slant"
        elif not np.isfinite(res.rise_10_90_px) or res.rise_10_90_px > 8.0:
            why = "rise_width"
        elif not (0.16 <= res.mtf50 * res.rise_10_90_px <= 1.2):
            # A step edge has MTF50 x (10-90 % rise) ~ 0.48 (Gaussian); sharpening raises it a little.
            # Far outside that band the ROI is not a step (a thin line, a double edge, a texture).
            why = "not_a_step"
        if why:
            reasons[why] = reasons.get(why, 0) + 1
            continue
        measured.append(EdgeMeasurement(x0, y0, rw, rh, orient, res))
        if len(measured) >= max_rois:
            break

    summ = EdgeSummary(n_candidates=len(cands), n_measured=len(measured), edges=measured,
                       n_rejected=int(sum(reasons.values())), reject_reasons=reasons)
    if measured:
        m50 = np.array([e.sfr.mtf50 for e in measured])
        summ.mtf50_median = float(np.median(m50))
        summ.mtf50_p80 = float(np.percentile(m50, 80))
        summ.mtf50_max = float(m50.max())
        summ.mtf50p_median = float(np.median([e.sfr.mtf50p for e in measured]))
        summ.rise_median_px = float(np.median([e.sfr.rise_10_90_px for e in measured]))
        nyq = [e.sfr.mtf_nyquist for e in measured if np.isfinite(e.sfr.mtf_nyquist)]
        summ.mtf_nyquist_median = float(np.median(nyq)) if nyq else float("nan")
        summ.overshoot_median_pct = float(np.median([e.sfr.overshoot_pct for e in measured]))
        v = [e.sfr.mtf50 for e in measured if e.orientation == "v"]
        hh = [e.sfr.mtf50 for e in measured if e.orientation == "h"]
        summ.mtf50_v_median = float(np.median(v)) if v else float("nan")
        summ.mtf50_h_median = float(np.median(hh)) if hh else float("nan")
        cy0, cx0 = h / 2.0, w / 2.0
        half_diag = float(np.hypot(cy0, cx0))
        r = np.array([np.hypot(e.y0 + e.h / 2.0 - cy0, e.x0 + e.w / 2.0 - cx0) / half_diag for e in measured])
        c = m50[r < 0.40]
        o = m50[r > 0.65]
        summ.n_center, summ.n_outer = int(c.size), int(o.size)
        summ.mtf50_center_median = float(np.median(c)) if c.size else float("nan")
        summ.mtf50_outer_median = float(np.median(o)) if o.size else float("nan")
    return summ


def lw_per_ph(mtf50_cpp: float, height_px: int) -> float:
    """Imatest-style line widths per picture height: 2 x MTF50 (c/px) x height."""
    return float(2.0 * mtf50_cpp * height_px)
