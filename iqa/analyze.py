"""Run every measurement on one image and return a flat record."""
from __future__ import annotations

import os
import time

from .edges import lw_per_ph, measure_natural_edges
from .exposure import analyze_exposure
from .imageio import LoadedImage, load_image
from .noise import analyze_noise

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
    rec.update(analyze_exposure(img.rgb8).as_dict())
    rec["analysis_s"] = round(time.time() - t0, 2)
    rec["_edges"] = edges
    rec["_noise"] = noise
    return rec


def analyze_file(path: str, max_rois: int = 30, max_side: int | None = None) -> dict:
    img = load_image(path, max_side=max_side)
    return analyze_loaded(img, max_rois=max_rois)
