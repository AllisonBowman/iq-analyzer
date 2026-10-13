"""Exposure, clipping, tonal and colour statistics on a display-referred image."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class ExposureResult:
    clip_high_pct: float        # % of pixels with any channel >= 254
    clip_low_pct: float         # % of pixels with all channels <= 1
    mean_luma: float            # 0..255
    luma_p1: float
    luma_p50: float
    luma_p99: float
    tonal_range_stops: float    # log2 ratio of linear luminance at p99 vs p1
    colorfulness: float         # Hasler & Suesstrunk (2003) metric
    wb_r_over_g: float          # gray-world ratios of *linear* channel means; 1.0 = neutral
    wb_b_over_g: float
    wb_r_over_g_stops: float    # the same ratios in stops (log2)
    wb_b_over_g_stops: float
    saturation_mean: float      # HSV-style saturation, 0..1

    def as_dict(self) -> dict:
        return self.__dict__.copy()


def analyze_exposure(rgb8: np.ndarray, step: int = 2) -> ExposureResult:
    f = rgb8[::step, ::step].astype(np.float32)
    R, G, B = f[..., 0], f[..., 1], f[..., 2]
    Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
    mx = f.max(axis=2)
    mn = f.min(axis=2)
    clip_high = float(100.0 * np.mean(mx >= 254))
    clip_low = float(100.0 * np.mean(mx <= 1))
    p1, p50, p99 = (float(v) for v in np.percentile(Y, [1, 50, 99]))

    from .imageio import srgb_decode
    lin_p1 = float(srgb_decode(np.array(max(p1, 0.5) / 255.0)))
    lin_p99 = float(srgb_decode(np.array(max(p99, 0.5) / 255.0)))
    tonal = float(np.log2(lin_p99 / lin_p1)) if lin_p1 > 0 else float("nan")

    rg = R - G
    yb = 0.5 * (R + G) - B
    colorfulness = float(np.sqrt(rg.std() ** 2 + yb.std() ** 2) + 0.3 * np.sqrt(rg.mean() ** 2 + yb.mean() ** 2))
    # Gray-world white balance on scene-linear values (encoded ratios understate a cast ~2.4x).
    lin = srgb_decode(f / 255.0)
    lr, lg, lb = (float(lin[..., ch].mean()) for ch in range(3))
    lg = max(lg, 1e-6)
    with np.errstate(divide="ignore", invalid="ignore"):
        sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    return ExposureResult(
        clip_high_pct=clip_high,
        clip_low_pct=clip_low,
        mean_luma=float(Y.mean()),
        luma_p1=p1, luma_p50=p50, luma_p99=p99,
        tonal_range_stops=tonal,
        colorfulness=colorfulness,
        wb_r_over_g=lr / lg,
        wb_b_over_g=lb / lg,
        wb_r_over_g_stops=float(np.log2(max(lr, 1e-6) / lg)),
        wb_b_over_g_stops=float(np.log2(max(lb, 1e-6) / lg)),
        saturation_mean=float(sat.mean()),
    )
