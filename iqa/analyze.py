"""Run every measurement on one image and return a flat record."""
from __future__ import annotations

import os
import time

from .edges import lw_per_ph, measure_natural_edges
from .exposure import analyze_exposure
from .imageio import LoadedImage, load_image
from .noise import analyze_noise
from .structure import analyze_structure, focus_split

META_KEYS = ("format", "camera_make", "camera_model", "lens", "iso", "exposure_s",
             "f_number", "focal_mm", "datetime", "width", "height", "color_profile")


def analyze_loaded(img: LoadedImage, max_rois: int = 30) -> dict:
    t0 = time.time()
    rec: dict = {"file": os.path.basename(img.path), "path": img.path, "is_raw": img.is_raw}
    for k in META_KEYS:
        rec[k] = img.meta.get(k)
    edges = measure_natural_edges(img.lin_luma, max_rois=max_rois)
    rec.update(edges.as_dict())
    rec["mtf50_p80_lwph"] = lw_per_ph(edges.mtf50_p80, img.height) if edges.n_measured else float("nan")
    noise = analyze_noise(img.rgb8)
    rec.update(noise.as_dict())
    exposure = analyze_exposure(img.rgb8).as_dict()
    if img.meta.get("native_clip_high_pct") is not None:
        # Report clipping as the file encodes it; the sRGB-measured excess is gamut clipping.
        exposure["clip_gamut_pct"] = max(0.0, exposure["clip_high_pct"] - img.meta["native_clip_high_pct"])
        exposure["clip_high_pct"] = img.meta["native_clip_high_pct"]
        exposure["clip_low_pct"] = img.meta["native_clip_low_pct"]
    else:
        exposure["clip_gamut_pct"] = 0.0
    rec.update(exposure)
    rec.update(analyze_structure(img.rgb8).as_dict())
    split = focus_split([e.sfr.mtf50 for e in edges.edges]) if edges.n_measured else None
    rec["mtf50_infocus_cpp"] = split["infocus_mtf50"] if split else float("nan")
    rec["mtf50_background_cpp"] = split["background_mtf50"] if split else float("nan")
    rec["infocus_edge_share"] = split["infocus_share"] if split else float("nan")
    rec["analysis_s"] = round(time.time() - t0, 2)
    rec["_edges"] = edges
    rec["_noise"] = noise
    return rec


def analyze_file(path: str, max_rois: int = 30, max_side: int | None = None) -> dict:
    img = load_image(path, max_side=max_side)
    return analyze_loaded(img, max_rois=max_rois)
