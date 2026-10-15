"""Structure of a photograph: where the detail is, how it is oriented, how the frame is composed,
and which measured edges belong to the in-focus subject.

Method
------
1. **Focus map.** The luminance is split into a 4 x 6 grid of cells and each cell scores the
   variance of its Laplacian (how much fine detail it holds). The map is normalised to its peak.
   ``focus_region_fraction`` is the share of cells at or above half the peak: small for a subject
   against a smooth or blurred field, near one for a frame that is sharp everywhere. The
   detail-weighted centroid of those cells is the subject's position, and
   ``composition_thirds_distance`` is its distance from the nearest rule-of-thirds intersection
   in units of the centre-to-thirds distance: 0 on a thirds point, 1 at the frame centre, about
   2 in a corner.  Below 0.35 reads as "on a thirds point"; above 0.75 as "centred or at the edge".
2. **Orientation.** Sobel gradients on the strongest 30 % of pixels; the magnitude-weighted shares
   of gradient direction within 22.5 degrees of horizontal (vertical structure), of vertical
   (horizontal structure), and the rest (diagonal).
3. **Level-edge tilt** (``horizon_tilt_deg``). Probabilistic Hough segments on a Canny map;
   segments at least 40 % of the frame width long and within 10 degrees of level vote with their
   length; the weighted median angle is the tilt (positive = the right end lower, image
   coordinates). None when no such segment exists. The edge may be a horizon, a table top, a
   shelf or a window frame in perspective: it is "the longest near-level edge", and only the
   coaching layer decides whether straightening is wanted.
4. **Surface shares.** 32-px blocks classed as edge (Canny pixels present), texture (high-passed
   std above 4 levels) or flat; the three shares sum to one.
5. **Focus split** (``focus_split``) on the per-edge MTF50 values: a one-dimensional two-means
   split, accepted only when the two groups are well separated (gap above twice the pooled
   spread and the sharp group at least 1.5x the soft one). It reports the in-focus and background
   MTF50 and the share of edges in focus, the "two-cluster split for shallow-DOF frames" the first
   review asked for instead of the p80.

Everything here is descriptive, not a quality score; the coaching layer turns it into advice.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

GRID = (4, 6)


@dataclass
class StructureResult:
    focus_map: np.ndarray = field(default_factory=lambda: np.zeros(GRID))
    focus_peak_cell: tuple = (0, 0)
    focus_region_fraction: float = float("nan")
    focus_centroid: tuple = (float("nan"), float("nan"))    # normalised x, y of the detail centroid
    composition_thirds_distance: float = float("nan")      # 0 = on a thirds point, 1 = frame centre
    orientation_horizontal_share: float = float("nan")
    orientation_vertical_share: float = float("nan")
    orientation_diagonal_share: float = float("nan")
    horizon_tilt_deg: float | None = None
    flat_share: float = float("nan")
    texture_share: float = float("nan")
    edge_share: float = float("nan")

    def as_dict(self) -> dict:
        return {
            "structure_focus_fraction": self.focus_region_fraction,
            "structure_focus_cx": self.focus_centroid[0],
            "structure_focus_cy": self.focus_centroid[1],
            "structure_thirds_distance": self.composition_thirds_distance,
            "structure_orient_horizontal": self.orientation_horizontal_share,
            "structure_orient_vertical": self.orientation_vertical_share,
            "structure_orient_diagonal": self.orientation_diagonal_share,
            "structure_horizon_tilt_deg": float("nan") if self.horizon_tilt_deg is None else self.horizon_tilt_deg,
            "structure_flat_share": self.flat_share,
            "structure_texture_share": self.texture_share,
            "structure_edge_share": self.edge_share,
            "structure_focus_map": [[float(v) for v in row] for row in self.focus_map],
        }


def _luma(rgb8: np.ndarray, max_side: int = 1600) -> np.ndarray:
    f = rgb8.astype(np.float32)
    Y = 0.2126 * f[..., 0] + 0.7152 * f[..., 1] + 0.0722 * f[..., 2]
    h, w = Y.shape
    s = min(1.0, max_side / max(h, w))
    if s < 1.0:
        Y = cv2.resize(Y, (int(round(w * s)), int(round(h * s))), interpolation=cv2.INTER_AREA)
    return Y


def analyze_structure(rgb8: np.ndarray, grid: tuple[int, int] = GRID) -> StructureResult:
    Y = _luma(rgb8)
    h, w = Y.shape
    res = StructureResult()

    # 1. focus map
    lap = cv2.Laplacian(cv2.GaussianBlur(Y, (0, 0), 1.0), cv2.CV_32F, ksize=3)
    rows, cols = grid
    fm = np.zeros(grid)
    for r in range(rows):
        for c in range(cols):
            cell = lap[r * h // rows:(r + 1) * h // rows, c * w // cols:(c + 1) * w // cols]
            fm[r, c] = float(cell.var())
    peak = fm.max()
    if peak > 0:
        fm = fm / peak
    res.focus_map = fm
    pr, pc = np.unravel_index(int(np.argmax(fm)), fm.shape)
    res.focus_peak_cell = (int(pr), int(pc))
    sel = fm >= 0.5
    res.focus_region_fraction = float(sel.mean())
    cy, cx = np.mgrid[0:rows, 0:cols]
    wts = np.where(sel, fm, 0.0)
    if wts.sum() > 0:
        ncx = float(((cx + 0.5) / cols * wts).sum() / wts.sum())
        ncy = float(((cy + 0.5) / rows * wts).sum() / wts.sum())
        res.focus_centroid = (ncx, ncy)
        thirds = [(x, y) for x in (1 / 3, 2 / 3) for y in (1 / 3, 2 / 3)]
        centre_to_thirds = np.hypot(1 / 6, 1 / 6)
        res.composition_thirds_distance = float(min(np.hypot(ncx - x, ncy - y) for x, y in thirds) / centre_to_thirds)

    # 2. orientation
    gx = cv2.Sobel(Y, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(Y, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.hypot(gx, gy)
    thr = np.percentile(mag, 70)
    m = mag > max(thr, 1e-6)
    if m.any():
        ang = np.degrees(np.arctan2(np.abs(gy[m]), np.abs(gx[m])))     # 0 = gradient horizontal = vertical structure
        wgt = mag[m]
        vert = wgt[ang < 22.5].sum(); horiz = wgt[ang > 67.5].sum(); total = wgt.sum()
        res.orientation_vertical_share = float(vert / total)
        res.orientation_horizontal_share = float(horiz / total)
        res.orientation_diagonal_share = float(1.0 - (vert + horiz) / total)

    # 3. horizon tilt
    g8 = np.clip(Y, 0, 255).astype(np.uint8)
    edges = cv2.Canny(cv2.GaussianBlur(g8, (5, 5), 0), 50, 150)
    min_len = int(0.4 * w)
    segs = cv2.HoughLinesP(edges, 1, np.pi / 720, threshold=int(0.2 * w), minLineLength=min_len, maxLineGap=int(0.02 * w))
    if segs is not None:
        angles, weights = [], []
        for x1, y1, x2, y2 in np.asarray(segs).reshape(-1, 4):
            if x2 < x1:
                x1, y1, x2, y2 = x2, y2, x1, y1
            a = float(np.degrees(np.arctan2(y2 - y1, x2 - x1)))
            if abs(a) <= 10.0:
                angles.append(a); weights.append(float(np.hypot(x2 - x1, y2 - y1)))
        if angles:
            order = np.argsort(angles)
            a = np.array(angles)[order]; wv = np.cumsum(np.array(weights)[order])
            res.horizon_tilt_deg = float(a[int(np.searchsorted(wv, wv[-1] / 2.0))])

    # 4. surface shares
    B = 32
    hp = Y - cv2.GaussianBlur(Y, (0, 0), 8.0)
    nb_r, nb_c = h // B, w // B
    if nb_r and nb_c:
        e = (edges[:nb_r * B, :nb_c * B] > 0).reshape(nb_r, B, nb_c, B).mean(axis=(1, 3))
        s = hp[:nb_r * B, :nb_c * B].reshape(nb_r, B, nb_c, B).std(axis=(1, 3))
        is_edge = e > 0.02
        is_tex = ~is_edge & (s > 4.0)
        res.edge_share = float(is_edge.mean())
        res.texture_share = float(is_tex.mean())
        res.flat_share = float(1.0 - res.edge_share - res.texture_share)
    return res


def focus_split(mtf50: np.ndarray, min_n: int = 5) -> dict | None:
    """Two-means split of per-edge MTF50 into in-focus and background groups, or None."""
    v = np.sort(np.asarray(mtf50, dtype=np.float64))
    v = v[np.isfinite(v)]
    n = v.size
    if n < min_n:
        return None
    best, best_k = -1.0, None
    for k in range(2, n - 1):                       # both groups at least 2
        lo, hi = v[:k], v[k:]
        between = lo.size * hi.size * (hi.mean() - lo.mean()) ** 2 / n
        if between > best:
            best, best_k = between, k
    if best_k is None:
        return None
    lo, hi = v[:best_k], v[best_k:]
    pooled = np.sqrt((lo.var(ddof=1) * (lo.size - 1) + hi.var(ddof=1) * (hi.size - 1)) / max(n - 2, 1))
    gap = hi.mean() - lo.mean()
    if gap < 2.0 * max(pooled, 1e-9) or hi.mean() < 1.5 * lo.mean():
        return None
    return {"infocus_mtf50": float(hi.mean()), "background_mtf50": float(lo.mean()),
            "infocus_share": float(hi.size / n)}
