"""Colour accuracy on a ColorChecker Classic (24-patch) chart.

Method
------
1. Find the chart.  OpenCV's ``mcc`` module (Macbeth ColorChecker detector, built into the
   wheel this project installs) returns the chart's bounding quadrilateral with its orientation
   resolved by colour matching.  The 24 patch centres are then placed with a homography from the
   chart's canonical 6 x 4 layout, and the order is verified on the neutral row (it runs white to
   black); a reversed box is flipped.
2. Sample each patch's inner 50 % (mean sRGB), convert sRGB -> linear -> XYZ (D65) -> Bradford
   -> XYZ (D50) -> CIE L*a*b*, and compare with the chart's published reference L*a*b* (D50)
   with CIEDE2000 (Sharma, Wu & Dalal 2005; the implementation is checked against their 34
   published test pairs in ``tests/test_color.py``).
3. White-balance error from the four mid neutrals (patches 20-23, the 8 / 6.5 / 5 / 3.5 greys):
   the gray-world ratios of the linear channel means, in stops, relative to the same ratios of
   the reference patches' faithful rendering (the chart's greys are slightly green, a* ~ -0.5,
   so "no error" is not R/G = 1).

What the number means: for a camera JPEG or HEIC this is the colour rendering of the *whole*
pipeline (white balance, colour matrix, tone curve, look) under the illuminant the chart was
shot in, compared with a faithful sRGB rendering of the chart.  It is the right figure for
"how accurate is this camera's colour out of the box", not for the sensor alone; a RAW decoded
with a neutral profile isolates the sensor and matrix.  Shoot the chart filling at least a
tenth of the frame, evenly lit, in focus, at base ISO.

Reference values are X-Rite's published L*a*b* (D50, 2 degree observer) for the ColorChecker
Classic manufactured before November 2014.  Charts made after that date differ by up to about
2 dE on a few patches; set ``COLORCHECKER_LAB`` for the chart in hand if that matters.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .imageio import srgb_decode, srgb_encode

# ---------------------------------------------------------------------------------------------
# Colour science
# ---------------------------------------------------------------------------------------------

# sRGB (linear, D65) -> XYZ, IEC 61966-2-1.
_M_RGB2XYZ = np.array([[0.4124564, 0.3575761, 0.1804375],
                       [0.2126729, 0.7151522, 0.0721750],
                       [0.0193339, 0.1191920, 0.9503041]])
# Bradford chromatic adaptation D65 -> D50 (Lindbloom).
_M_D65_D50 = np.array([[1.0478112, 0.0228866, -0.0501270],
                       [0.0295424, 0.9904844, -0.0170491],
                       [-0.0092345, 0.0150436, 0.7521316]])
_M_SRGB_TO_XYZ50 = _M_D65_D50 @ _M_RGB2XYZ
_M_XYZ50_TO_SRGB = np.linalg.inv(_M_SRGB_TO_XYZ50)
_WHITE_D50 = np.array([0.96422, 1.0, 0.82521])

# X-Rite ColorChecker Classic, pre-Nov-2014, L*a*b* D50/2 deg.  Row-major, 6 per row:
# dark skin .. bluish green / orange .. cyan-ish / blue .. cyan / white .. black.
COLORCHECKER_LAB = np.array([
    [37.99, 13.56, 14.06], [65.71, 18.13, 17.81], [49.93, -4.88, -21.93],
    [43.14, -13.10, 21.91], [55.11, 8.84, -25.40], [70.72, -33.40, -0.20],
    [62.66, 36.07, 57.10], [40.02, 10.41, -45.96], [51.12, 48.24, 16.25],
    [30.33, 22.98, -21.59], [72.53, -23.71, 57.26], [71.94, 19.36, 67.86],
    [28.78, 14.18, -50.30], [55.26, -38.34, 31.37], [42.10, 53.38, 28.19],
    [81.73, 4.04, 79.82], [51.94, 49.99, -14.57], [51.04, -28.63, -28.64],
    [96.54, -0.43, 1.19], [81.26, -0.64, -0.34], [66.77, -0.73, -0.50],
    [50.87, -0.15, -0.27], [35.66, -0.42, -1.23], [20.46, -0.08, -0.97],
])
COLORCHECKER_NAMES = [
    "dark skin", "light skin", "blue sky", "foliage", "blue flower", "bluish green",
    "orange", "purplish blue", "moderate red", "purple", "yellow green", "orange yellow",
    "blue", "green", "red", "yellow", "magenta", "cyan",
    "white", "neutral 8", "neutral 6.5", "neutral 5", "neutral 3.5", "black",
]
NEUTRAL_PATCHES = (19, 20, 21, 22)       # the four mid greys used for white balance
OUT_OF_SRGB_GAMUT = (17,)                # cyan: its reference colour cannot be shown in sRGB (R clips at 0)


def _xyz_to_lab(xyz: np.ndarray, white: np.ndarray = _WHITE_D50) -> np.ndarray:
    t = xyz / white
    eps, kappa = 216.0 / 24389.0, 24389.0 / 27.0
    f = np.where(t > eps, np.cbrt(t), (kappa * t + 16.0) / 116.0)
    L = 116.0 * f[..., 1] - 16.0
    a = 500.0 * (f[..., 0] - f[..., 1])
    b = 200.0 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], axis=-1)


def _lab_to_xyz(lab: np.ndarray, white: np.ndarray = _WHITE_D50) -> np.ndarray:
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16.0) / 116.0
    fx = a / 500.0 + fy
    fz = fy - b / 200.0
    eps, kappa = 216.0 / 24389.0, 24389.0 / 27.0

    def inv(f):
        f3 = f ** 3
        return np.where(f3 > eps, f3, (116.0 * f - 16.0) / kappa)
    yr = np.where(L > kappa * eps, ((L + 16.0) / 116.0) ** 3, L / kappa)
    return np.stack([inv(fx), yr, inv(fz)], axis=-1) * white


def srgb8_to_lab(rgb8: np.ndarray) -> np.ndarray:
    """sRGB uint8 (..., 3) -> CIE L*a*b* under D50 (Bradford-adapted)."""
    lin = srgb_decode(rgb8.astype(np.float64) / 255.0)
    xyz = lin @ _M_SRGB_TO_XYZ50.T
    return _xyz_to_lab(xyz)


def lab_to_srgb8(lab: np.ndarray) -> np.ndarray:
    """CIE L*a*b* (D50) -> sRGB uint8, clipped to gamut."""
    xyz = _lab_to_xyz(np.asarray(lab, dtype=np.float64))
    lin = np.clip(xyz @ _M_XYZ50_TO_SRGB.T, 0.0, 1.0)
    return np.clip(np.round(srgb_encode(lin) * 255.0), 0, 255).astype(np.uint8)


def delta_e_2000(lab1: np.ndarray, lab2: np.ndarray, kL: float = 1.0, kC: float = 1.0,
                 kH: float = 1.0) -> np.ndarray:
    """CIEDE2000 colour difference, vectorised over leading dimensions."""
    lab1 = np.asarray(lab1, dtype=np.float64); lab2 = np.asarray(lab2, dtype=np.float64)
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.hypot(a1, b1); C2 = np.hypot(a2, b2)
    Cbar = 0.5 * (C1 + C2)
    G = 0.5 * (1.0 - np.sqrt(Cbar ** 7 / (Cbar ** 7 + 25.0 ** 7)))
    a1p = (1.0 + G) * a1; a2p = (1.0 + G) * a2
    C1p = np.hypot(a1p, b1); C2p = np.hypot(a2p, b2)

    def hue(ap, b):
        h = np.degrees(np.arctan2(b, ap))
        h = np.where(h < 0, h + 360.0, h)
        return np.where((ap == 0) & (b == 0), 0.0, h)
    h1p = hue(a1p, b1); h2p = hue(a2p, b2)
    dLp = L2 - L1
    dCp = C2p - C1p
    dh = h2p - h1p
    dh = np.where(dh > 180.0, dh - 360.0, dh)
    dh = np.where(dh < -180.0, dh + 360.0, dh)
    dh = np.where(C1p * C2p == 0, 0.0, dh)
    dHp = 2.0 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2.0))
    Lbp = 0.5 * (L1 + L2)
    Cbp = 0.5 * (C1p + C2p)
    hsum = h1p + h2p
    hbp = np.where(C1p * C2p == 0, hsum,
                   np.where(np.abs(h1p - h2p) <= 180.0, 0.5 * hsum,
                            np.where(hsum < 360.0, 0.5 * (hsum + 360.0), 0.5 * (hsum - 360.0))))
    T = (1.0 - 0.17 * np.cos(np.radians(hbp - 30.0)) + 0.24 * np.cos(np.radians(2.0 * hbp))
         + 0.32 * np.cos(np.radians(3.0 * hbp + 6.0)) - 0.20 * np.cos(np.radians(4.0 * hbp - 63.0)))
    dtheta = 30.0 * np.exp(-((hbp - 275.0) / 25.0) ** 2)
    RC = 2.0 * np.sqrt(Cbp ** 7 / (Cbp ** 7 + 25.0 ** 7))
    SL = 1.0 + 0.015 * (Lbp - 50.0) ** 2 / np.sqrt(20.0 + (Lbp - 50.0) ** 2)
    SC = 1.0 + 0.045 * Cbp
    SH = 1.0 + 0.015 * Cbp * T
    RT = -np.sin(np.radians(2.0 * dtheta)) * RC
    return np.sqrt((dLp / (kL * SL)) ** 2 + (dCp / (kC * SC)) ** 2 + (dHp / (kH * SH)) ** 2
                   + RT * (dCp / (kC * SC)) * (dHp / (kH * SH)))


# ---------------------------------------------------------------------------------------------
# Chart geometry
# ---------------------------------------------------------------------------------------------

# Canonical layout in chart units: 6 columns x 4 rows, patch pitch 1, chart box from (0,0) to
# (6,4) around the patch field (the box OpenCV's detector returns encloses the patches, not the
# chart's outer frame).
_GRID_COLS, _GRID_ROWS = 6, 4


def canonical_centres() -> np.ndarray:
    cx, cy = np.meshgrid(np.arange(_GRID_COLS) + 0.5, np.arange(_GRID_ROWS) + 0.5)
    return np.stack([cx.ravel(), cy.ravel()], axis=1).astype(np.float64)


@dataclass
class ColorCheckerChart:
    box: np.ndarray                 # 4 x 2 image corners of the patch field: TL, TR, BR, BL (chart orientation)
    centres: np.ndarray             # 24 x 2 image coordinates, row-major (dark skin first, black last)
    homography: np.ndarray          # 3 x 3 chart units -> image pixels
    patch_px: float                 # mean patch pitch in pixels
    detector: str = "opencv-mcc"


def _order_box(box: np.ndarray) -> np.ndarray:
    """TL, TR, BR, BL in image axes (y down), for a convex quadrilateral."""
    c = box.mean(axis=0)
    ang = np.arctan2(box[:, 1] - c[1], box[:, 0] - c[0])
    order = np.argsort(ang)                       # counter-clockwise in image axes = clockwise on screen
    b = box[order]
    # start at the corner with the smallest x+y (top-left)
    k = int(np.argmin(b.sum(axis=1)))
    return np.roll(b, -k, axis=0)


def _homography(box: np.ndarray) -> np.ndarray:
    import cv2
    src = np.array([[0, 0], [_GRID_COLS, 0], [_GRID_COLS, _GRID_ROWS], [0, _GRID_ROWS]], dtype=np.float64)
    H, _ = cv2.findHomography(src, box.astype(np.float64))
    return H


def _project(H: np.ndarray, pts: np.ndarray) -> np.ndarray:
    p = np.c_[pts, np.ones(len(pts))] @ H.T
    return p[:, :2] / p[:, 2:3]


def sample_patches(rgb8: np.ndarray, chart: ColorCheckerChart, inner: float = 0.5) -> np.ndarray:
    """Mean sRGB (24 x 3, float) of the inner ``inner`` fraction of each patch, sampled through
    the homography so perspective is respected."""
    import cv2
    H = chart.homography
    out = np.zeros((24, 3))
    n = 9
    for i, (u, v) in enumerate(canonical_centres()):
        gu, gv = np.meshgrid(np.linspace(-inner / 2, inner / 2, n), np.linspace(-inner / 2, inner / 2, n))
        pts = _project(H, np.c_[u + gu.ravel(), v + gv.ravel()])
        # bilinear samples
        vals = cv2.remap(rgb8, pts[:, 0].astype(np.float32).reshape(1, -1),
                         pts[:, 1].astype(np.float32).reshape(1, -1), cv2.INTER_LINEAR)
        out[i] = vals.reshape(-1, 3).mean(axis=0)
    return out


def _orientation_ok(rgb8: np.ndarray, chart: ColorCheckerChart) -> bool:
    """The neutral row (18..23) must run bright to dark; the top row must not."""
    s = sample_patches(rgb8, chart, inner=0.4).mean(axis=1)
    bottom = s[18:24]; top = s[0:6]
    return np.all(np.diff(bottom) < 0) and bottom[0] > top.max()


def _refine_centres(rgb8: np.ndarray, chart: ColorCheckerChart) -> ColorCheckerChart:
    """The detector's box is a coarse outline (its corners can be a tenth of a patch off).  Refine:
    around each predicted centre, take the connected region of pixels within half the patch-to-
    gutter contrast of the patch's own median colour, use its centroid, and refit the homography
    to the 24 centroids (RANSAC, so one bad patch cannot pull the rest)."""
    import cv2
    h, w = rgb8.shape[:2]
    r = int(max(6, 0.75 * chart.patch_px))
    f = rgb8.astype(np.float32)
    cents, keep = [], []
    for (x, y) in chart.centres:
        x0, y0 = int(round(x)), int(round(y))
        xa, xb, ya, yb = max(0, x0 - r), min(w, x0 + r + 1), max(0, y0 - r), min(h, y0 + r + 1)
        win = f[ya:yb, xa:xb]
        if win.size == 0:
            continue
        c = int(min(win.shape[0] - 1, max(0, y0 - ya))), int(min(win.shape[1] - 1, max(0, x0 - xa)))
        inner = win[max(0, c[0] - 4):c[0] + 5, max(0, c[1] - 4):c[1] + 5].reshape(-1, 3)
        colour = np.median(inner, axis=0)
        dist = np.abs(win - colour).sum(axis=2)
        # gutter contrast: the window's median distance among pixels far from the patch colour
        far = dist[dist > np.percentile(dist, 60)]
        thr = 0.5 * (np.median(far) if far.size else 60.0)
        mask = (dist < max(thr, 12.0)).astype(np.uint8)
        n, lab, stats, cen = cv2.connectedComponentsWithStats(mask, connectivity=4)
        k = int(lab[c[0], c[1]])
        if k == 0 or stats[k, cv2.CC_STAT_AREA] < 0.1 * chart.patch_px ** 2:
            continue
        cents.append([xa + cen[k, 0], ya + cen[k, 1]]); keep.append(True)
    if len(cents) < 8:
        return chart
    src = canonical_centres()[[i for i, _ in enumerate(chart.centres) if i < len(chart.centres)]]
    # pair refined centroids with the canonical centres whose prediction they came from
    pairs_src, pairs_dst = [], []
    j = 0
    for i, (x, y) in enumerate(chart.centres):
        x0, y0 = int(round(x)), int(round(y))
        if 0 <= x0 < w and 0 <= y0 < h and j < len(cents) and np.hypot(cents[j][0] - x, cents[j][1] - y) < chart.patch_px:
            pairs_src.append(canonical_centres()[i]); pairs_dst.append(cents[j]); j += 1
        elif j < len(cents) and np.hypot(cents[j][0] - x, cents[j][1] - y) >= chart.patch_px:
            j += 1
    if len(pairs_src) < 8:
        return chart
    H, inl = cv2.findHomography(np.array(pairs_src), np.array(pairs_dst), cv2.RANSAC, 0.08 * chart.patch_px)
    if H is None or inl.sum() < 8:
        return chart
    box = _project(H, np.array([[0, 0], [_GRID_COLS, 0], [_GRID_COLS, _GRID_ROWS], [0, _GRID_ROWS]], dtype=np.float64))
    return ColorCheckerChart(box=box, centres=_project(H, canonical_centres()), homography=H,
                             patch_px=float(np.hypot(*(box[1] - box[0])) / _GRID_COLS), detector=chart.detector)


def find_colorchecker(rgb8: np.ndarray) -> ColorCheckerChart | None:
    """Locate a ColorChecker Classic in an sRGB uint8 image.  None when no chart is found."""
    import cv2
    bgr = np.ascontiguousarray(rgb8[..., ::-1])
    det = cv2.mcc.CCheckerDetector_create()
    det.setColorChartType(cv2.mcc.MCC24)
    try:
        ok = det.process(bgr, 1)              # OpenCV 5 signature: (image, number of charts)
    except cv2.error:
        return None
    if not ok:
        return None
    checkers = det.getListColorChecker()
    if not checkers:
        return None
    box = np.array(checkers[0].getBox(), dtype=np.float64).reshape(-1, 2)
    if box.shape[0] != 4:
        return None
    box = _order_box(box)
    best = None
    # Try the four rotations of the box; keep the one whose neutral row runs white -> black.
    for r in range(4):
        b = np.roll(box, -r, axis=0)
        H = _homography(b)
        chart = ColorCheckerChart(box=b, centres=_project(H, canonical_centres()), homography=H,
                                  patch_px=float(np.hypot(*(b[1] - b[0])) / _GRID_COLS))
        if _orientation_ok(rgb8, chart):
            best = chart
            break
    if best is None:
        return None
    best = _refine_centres(rgb8, best)
    h, w = rgb8.shape[:2]
    if (best.centres < 0).any() or (best.centres[:, 0] >= w).any() or (best.centres[:, 1] >= h).any():
        return None
    return best


@dataclass
class ColorCheckerResult:
    measured_srgb: np.ndarray       # 24 x 3
    measured_lab: np.ndarray        # 24 x 3 (D50)
    de00: np.ndarray                # 24
    de00_mean: float
    de00_max: float
    de00_chromatic_mean: float      # patches 0..17
    de00_neutral_mean: float        # patches 18..23
    wb_r_over_g_stops: float
    wb_b_over_g_stops: float
    names: list = field(default_factory=lambda: list(COLORCHECKER_NAMES))

    def as_dict(self) -> dict:
        return {
            "cc_de00_mean": self.de00_mean, "cc_de00_max": self.de00_max,
            "cc_de00_chromatic_mean": self.de00_chromatic_mean, "cc_de00_neutral_mean": self.de00_neutral_mean,
            "cc_wb_r_over_g_stops": self.wb_r_over_g_stops, "cc_wb_b_over_g_stops": self.wb_b_over_g_stops,
            "cc_de00": [float(x) for x in self.de00],
            "cc_measured_srgb": [[float(v) for v in row] for row in self.measured_srgb],
        }


def measure_colorchecker(rgb8: np.ndarray, chart: ColorCheckerChart,
                         reference_lab: np.ndarray = COLORCHECKER_LAB) -> ColorCheckerResult:
    srgb = sample_patches(rgb8, chart)
    lab = srgb8_to_lab(np.clip(srgb, 0, 255))
    de = delta_e_2000(lab, reference_lab)
    idx = list(NEUTRAL_PATCHES)
    lin = srgb_decode(np.clip(srgb, 0, 255) / 255.0)[idx]
    # The chart's neutrals are not perfectly neutral (a* ~ -0.5): measure against their own
    # faithful rendering, so a perfect camera reads 0.00 stops.
    ref_lin = srgb_decode(lab_to_srgb8(reference_lab[idx]).astype(np.float64) / 255.0)
    r_g = float(np.log2(lin[:, 0].mean() / lin[:, 1].mean()) - np.log2(ref_lin[:, 0].mean() / ref_lin[:, 1].mean()))
    b_g = float(np.log2(lin[:, 2].mean() / lin[:, 1].mean()) - np.log2(ref_lin[:, 2].mean() / ref_lin[:, 1].mean()))
    return ColorCheckerResult(measured_srgb=srgb, measured_lab=lab, de00=de,
                              de00_mean=float(de.mean()), de00_max=float(de.max()),
                              de00_chromatic_mean=float(de[:18].mean()), de00_neutral_mean=float(de[18:].mean()),
                              wb_r_over_g_stops=r_g, wb_b_over_g_stops=b_g)
