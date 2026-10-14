"""Sharpness across the field from an ISO 12233:2014 e-SFR chart (or any chart of slanted squares).

Method
------
1. Find slanted squares: threshold the display-referred luminance (Otsu, both polarities so
   dark-on-light and light-on-dark targets work), take external contours, keep convex
   four-vertex polygons whose sides agree within 15 % and whose rotation from the pixel axes is
   2-15 degrees (the ISO method needs a slant; an axis-aligned square is not a usable target).
2. Measure each of the four sides with the same e-SFR code the natural-edge path uses
   (``iqa.sfr.compute_sfr`` on an ROI centred on the side's midpoint, transposed for the
   near-horizontal sides) on scene-linear luminance, and keep the ones that pass the same
   step-validity gates.
3. Label every edge by the angle between its normal and the line to the image centre:
   ``radial`` when the normal is within 45 degrees of that line (the MTF measured across it is the
   radial / sagittal MTF), ``tangential`` otherwise.  Astigmatism shows as the two diverging
   away from the centre.
4. Summarise: per square the mean of its edges; per image the medians overall, for the centre
   (r < 0.4) and the outer field (r > 0.65), and radial vs tangential.

What the number means: on a chart the edge is a true step of known contrast, so MTF50 here is
the system MTF (lens, sensor, demosaic, sharpening) at that position in the frame, not the
scene-dependent lower bound the natural-edge path reports.  Shoot the chart square to the
camera, filling the frame, with the squares at least 80 px across; measure at base ISO and,
for a lens map, at each aperture.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from .sfr import SFRResult, compute_sfr


@dataclass
class SquareTarget:
    centre: tuple[float, float]
    corners: np.ndarray          # 4 x 2, ordered around the square
    side_px: float
    angle_deg: float             # rotation from the pixel axes, 0..45


@dataclass
class ChartEdge:
    square: int
    side: int                    # 0..3, corner i -> corner i+1
    x0: int
    y0: int
    w: int
    h: int
    orientation: str             # "v": edge runs top-to-bottom; "h": left-to-right
    direction: str               # "radial" | "tangential"
    radius: float                # normalised distance of the edge midpoint from the image centre
    mtf50: float
    mtf50p: float
    mtf_nyquist: float
    rise_10_90_px: float
    overshoot_pct: float
    sfr: SFRResult | None = None


@dataclass
class SquareResult:
    centre: tuple[float, float]
    side_px: float
    radius: float
    edges: list[ChartEdge] = field(default_factory=list)
    mtf50_mean: float = float("nan")


@dataclass
class ESFRChartResult:
    n_squares: int = 0
    n_edges: int = 0
    squares: list[SquareResult] = field(default_factory=list)
    reject_reasons: dict = field(default_factory=dict)
    mtf50_median: float = float("nan")
    mtf50_center_median: float = float("nan")
    mtf50_outer_median: float = float("nan")
    mtf50_radial_median: float = float("nan")
    mtf50_tangential_median: float = float("nan")
    mtf50p_median: float = float("nan")
    overshoot_median_pct: float = float("nan")

    def as_dict(self) -> dict:
        return {
            "esfr_squares": self.n_squares, "esfr_edges": self.n_edges,
            "esfr_mtf50_median_cpp": self.mtf50_median,
            "esfr_mtf50_center_median_cpp": self.mtf50_center_median,
            "esfr_mtf50_outer_median_cpp": self.mtf50_outer_median,
            "esfr_mtf50_radial_median_cpp": self.mtf50_radial_median,
            "esfr_mtf50_tangential_median_cpp": self.mtf50_tangential_median,
            "esfr_mtf50p_median_cpp": self.mtf50p_median,
            "esfr_overshoot_median_pct": self.overshoot_median_pct,
            "esfr_field": [{"x": s.centre[0], "y": s.centre[1], "r": s.radius, "mtf50": s.mtf50_mean,
                            "edges": len(s.edges)} for s in self.squares],
        }


def _order_corners(pts: np.ndarray) -> np.ndarray:
    c = pts.mean(axis=0)
    ang = np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0])
    return pts[np.argsort(ang)]


def find_slanted_squares(lin_luma: np.ndarray, min_side_px: int = 40, min_slant: float = 2.0,
                         max_slant: float = 15.0, det_long_side: int = 2400) -> list[SquareTarget]:
    """Slanted square targets in a scene-linear luminance image (float 0..1)."""
    h, w = lin_luma.shape
    scale = min(1.0, det_long_side / float(max(h, w)))
    g8 = np.clip(np.power(np.clip(lin_luma, 0.0, 1.0), 1.0 / 2.2) * 255.0, 0, 255).astype(np.uint8)
    if scale < 1.0:
        g8 = cv2.resize(g8, (int(round(w * scale)), int(round(h * scale))), interpolation=cv2.INTER_AREA)
    g8 = cv2.GaussianBlur(g8, (0, 0), 1.0)
    out: list[SquareTarget] = []
    seen: list[tuple[float, float]] = []
    for polarity in (cv2.THRESH_BINARY_INV, cv2.THRESH_BINARY):
        _, bw = cv2.threshold(g8, 0, 255, polarity + cv2.THRESH_OTSU)
        contours, _ = cv2.findContours(bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for cnt in contours:
            per = cv2.arcLength(cnt, True)
            if per < 4 * min_side_px * scale:
                continue
            poly = cv2.approxPolyDP(cnt, 0.03 * per, True).reshape(-1, 2).astype(np.float64)
            if poly.shape[0] != 4 or not cv2.isContourConvex(poly.astype(np.float32)):
                continue
            pts = _order_corners(poly) / scale
            sides = np.array([np.hypot(*(pts[(i + 1) % 4] - pts[i])) for i in range(4)])
            if sides.min() < min_side_px or sides.max() / sides.min() > 1.15:
                continue
            # area vs side^2: a square's contour area is close to side^2 (a thin rectangle is not)
            area = cv2.contourArea(pts.astype(np.float32))
            if not (0.85 <= area / sides.mean() ** 2 <= 1.15):
                continue
            v = pts[1] - pts[0]
            ang = abs(np.degrees(np.arctan2(v[1], v[0]))) % 90.0
            ang = min(ang, 90.0 - ang)
            if not (min_slant <= ang <= max_slant):
                continue
            c = (float(pts[:, 0].mean()), float(pts[:, 1].mean()))
            if any(np.hypot(c[0] - sx, c[1] - sy) < 0.5 * sides.mean() for sx, sy in seen):
                continue
            seen.append(c)
            out.append(SquareTarget(centre=c, corners=pts, side_px=float(sides.mean()), angle_deg=float(ang)))
    out.sort(key=lambda s: (round(s.centre[1] / max(1.0, s.side_px)), s.centre[0]))
    return out


def measure_esfr_chart(lin_luma: np.ndarray, roi_across: int = 64, max_clipped: float = 0.005,
                       keep_sfr: bool = False) -> ESFRChartResult:
    """Find the slanted squares and measure all four edges of each."""
    h, w = lin_luma.shape
    cy0, cx0 = h / 2.0, w / 2.0
    half_diag = float(np.hypot(cy0, cx0))
    res = ESFRChartResult()
    squares = find_slanted_squares(lin_luma)
    res.n_squares = len(squares)
    reasons: dict[str, int] = {}
    for si, sq in enumerate(squares):
        sr = SquareResult(centre=sq.centre, side_px=sq.side_px,
                          radius=float(np.hypot(sq.centre[1] - cy0, sq.centre[0] - cx0) / half_diag))
        for k in range(4):
            p, q = sq.corners[k], sq.corners[(k + 1) % 4]
            mid = 0.5 * (p + q)
            d = q - p
            L = int(max(32, min(0.7 * sq.side_px, 160)))
            A = int(min(roi_across, max(24, 0.5 * sq.side_px)))
            vertical = abs(d[1]) >= abs(d[0])
            if vertical:
                x0, y0, rw, rh = int(round(mid[0] - A / 2)), int(round(mid[1] - L / 2)), A, L
            else:
                x0, y0, rw, rh = int(round(mid[0] - L / 2)), int(round(mid[1] - A / 2)), L, A
            if x0 < 0 or y0 < 0 or x0 + rw > w or y0 + rh > h:
                reasons["outside"] = reasons.get("outside", 0) + 1
                continue
            roi = lin_luma[y0:y0 + rh, x0:x0 + rw].astype(np.float64)
            if not vertical:
                roi = roi.T
            try:
                r = compute_sfr(roi)
            except (ValueError, FloatingPointError):
                reasons["error"] = reasons.get("error", 0) + 1
                continue
            why = None
            if r.clipped_frac > max_clipped:
                why = "clipped"
            elif not np.isfinite(r.mtf50):
                why = "no_mtf50_below_nyquist"
            elif r.fit_rms_px > 0.4:
                why = "fit_residual"
            elif not (0.16 <= r.mtf50 * r.rise_10_90_px <= 1.2):
                why = "not_a_step"
            if why:
                reasons[why] = reasons.get(why, 0) + 1
                continue
            # edge normal vs the radial direction at the midpoint
            n = np.array([-d[1], d[0]]) / max(np.hypot(*d), 1e-9)
            rad = np.array([mid[0] - cx0, mid[1] - cy0])
            rn = np.hypot(*rad)
            cosang = abs(float(n @ rad / rn)) if rn > 1e-6 else 1.0
            direction = "radial" if cosang >= np.cos(np.radians(45.0)) else "tangential"
            sr.edges.append(ChartEdge(square=si, side=k, x0=x0, y0=y0, w=rw, h=rh,
                                      orientation="v" if vertical else "h", direction=direction,
                                      radius=float(rn / half_diag), mtf50=float(r.mtf50), mtf50p=float(r.mtf50p),
                                      mtf_nyquist=float(r.mtf_nyquist), rise_10_90_px=float(r.rise_10_90_px),
                                      overshoot_pct=float(r.overshoot_pct), sfr=r if keep_sfr else None))
        if sr.edges:
            sr.mtf50_mean = float(np.mean([e.mtf50 for e in sr.edges]))
        res.squares.append(sr)
    res.reject_reasons = reasons
    edges = [e for s in res.squares for e in s.edges]
    res.n_edges = len(edges)
    if edges:
        m = np.array([e.mtf50 for e in edges]); r = np.array([e.radius for e in edges])
        res.mtf50_median = float(np.median(m))
        res.mtf50p_median = float(np.median([e.mtf50p for e in edges]))
        res.overshoot_median_pct = float(np.median([e.overshoot_pct for e in edges]))
        c, o = m[r < 0.40], m[r > 0.65]
        res.mtf50_center_median = float(np.median(c)) if c.size else float("nan")
        res.mtf50_outer_median = float(np.median(o)) if o.size else float("nan")
        rad = [e.mtf50 for e in edges if e.direction == "radial"]
        tan = [e.mtf50 for e in edges if e.direction == "tangential"]
        res.mtf50_radial_median = float(np.median(rad)) if rad else float("nan")
        res.mtf50_tangential_median = float(np.median(tan)) if tan else float("nan")
    return res
