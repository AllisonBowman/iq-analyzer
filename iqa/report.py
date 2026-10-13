"""CSV, charts and a markdown report for a batch of analysed images."""
from __future__ import annotations

import csv
import json
import math
import os
from datetime import datetime

import numpy as np

CSV_COLUMNS = [
    "file", "format", "is_raw", "camera_make", "camera_model", "lens", "iso", "exposure_s", "f_number",
    "focal_mm", "datetime", "width", "height",
    "edges_candidates", "edges_measured", "mtf50_median_cpp", "mtf50_p80_cpp", "mtf50_max_cpp",
    "mtf50p_median_cpp", "mtf50_p80_lwph", "edge_rise_median_px", "mtf_nyquist_median",
    "noise_patches", "luma_noise_midgrey_8bit", "chroma_noise_midgrey_8bit", "snr_midgrey_db",
    "dr_snr1_stops", "dr_snr2_stops", "dr_snr4_stops", "dr_snr10_stops", "dr_snr4_lower_bound",
    "clip_high_pct", "clip_low_pct", "mean_luma", "luma_p1", "luma_p50", "luma_p99",
    "tonal_range_stops", "colorfulness", "wb_r_over_g", "wb_b_over_g", "saturation_mean",
    "analysis_s", "path",
]


def _fmt(v):
    if v is None:
        return ""
    if isinstance(v, float):
        if math.isnan(v):
            return ""
        return f"{v:.6g}"
    return v


def write_csv(records: list[dict], path: str) -> None:
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in records:
            w.writerow({k: _fmt(r.get(k)) for k in CSV_COLUMNS})


def write_json(records: list[dict], path: str) -> None:
    clean = []
    for r in records:
        d = {k: v for k, v in r.items() if not k.startswith("_")}
        edges = r.get("_edges")
        if edges is not None:
            d["edges"] = [e.as_dict() for e in edges.edges]
        noise = r.get("_noise")
        if noise is not None and noise.bin_centers.size:
            d["noise_curve"] = {
                "luma_8bit": noise.bin_centers.tolist(),
                "luma_noise_8bit": noise.luma_noise.tolist(),
                "chroma_noise_8bit": noise.chroma_noise.tolist(),
                "patches": noise.bin_counts.tolist(),
            }
        clean.append(d)

    def default(o):
        if isinstance(o, (np.floating, np.integer)):
            return o.item()
        if isinstance(o, np.ndarray):
            return o.tolist()
        return str(o)

    with open(path, "w") as fh:
        json.dump(clean, fh, indent=1, default=default, allow_nan=True)


def _finite(records, key):
    xs = [r.get(key) for r in records]
    return np.array([x for x in xs if isinstance(x, (int, float)) and x is not None and not math.isnan(x)], dtype=float)


def write_charts(records: list[dict], out_dir: str) -> list[str]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    made = []
    os.makedirs(out_dir, exist_ok=True)

    def scatter_vs_iso(key, ylabel, fname, logy=False):
        pts = [(r["iso"], r[key]) for r in records
               if isinstance(r.get("iso"), (int, float)) and isinstance(r.get(key), (int, float))
               and not math.isnan(r[key]) and r["iso"] and r["iso"] > 0]
        if len(pts) < 3:
            return
        x, y = zip(*pts)
        fig, ax = plt.subplots(figsize=(7, 4.2))
        ax.scatter(x, y, s=22, alpha=0.75)
        ax.set_xscale("log")
        if logy:
            ax.set_yscale("log")
        ax.set_xlabel("ISO")
        ax.set_ylabel(ylabel)
        ax.grid(True, which="both", alpha=0.3)
        fig.tight_layout()
        p = os.path.join(out_dir, fname)
        fig.savefig(p, dpi=130)
        plt.close(fig)
        made.append(p)

    def hist(key, xlabel, fname, bins=20):
        v = _finite(records, key)
        if v.size < 3:
            return
        fig, ax = plt.subplots(figsize=(7, 4.2))
        ax.hist(v, bins=bins, alpha=0.85)
        ax.set_xlabel(xlabel)
        ax.set_ylabel("images")
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        p = os.path.join(out_dir, fname)
        fig.savefig(p, dpi=130)
        plt.close(fig)
        made.append(p)

    hist("mtf50_p80_cpp", "in-focus sharpness: MTF50 (cycles/pixel, 80th pct of edges)", "mtf50_hist.png")
    hist("snr_midgrey_db", "SNR at mid-grey (dB)", "snr_hist.png")
    scatter_vs_iso("snr_midgrey_db", "SNR at mid-grey (dB)", "snr_vs_iso.png")
    scatter_vs_iso("luma_noise_midgrey_8bit", "luma noise at mid-grey (8-bit std)", "noise_vs_iso.png", logy=True)
    scatter_vs_iso("dr_snr4_stops", "dynamic range @ SNR 4 (stops, output-referred)", "dr_vs_iso.png")
    scatter_vs_iso("mtf50_p80_cpp", "MTF50 (c/px, 80th pct of edges)", "mtf50_vs_iso.png")
    hist("clip_high_pct", "highlight clipping (% of pixels)", "clip_hist.png")

    # Noise curves overlay: luminance noise vs. level for every image (a camera's "noise profile").
    curves = [(r["file"], r["_noise"]) for r in records if r.get("_noise") is not None and r["_noise"].bin_centers.size >= 3]
    if curves:
        fig, ax = plt.subplots(figsize=(7, 4.2))
        for name, nz in curves[:60]:
            ax.plot(nz.bin_centers, nz.luma_noise, "-", alpha=0.35, lw=1)
        ax.set_xlabel("mean luminance (8-bit)")
        ax.set_ylabel("luma noise (8-bit std)")
        ax.set_title("noise vs. signal level, one line per image")
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        p = os.path.join(out_dir, "noise_curves.png")
        fig.savefig(p, dpi=130)
        plt.close(fig)
        made.append(p)
    return made


def _top(records, key, n=5, reverse=True, fmt="{:.3f}"):
    rows = [r for r in records if isinstance(r.get(key), (int, float)) and not math.isnan(r[key])]
    rows.sort(key=lambda r: r[key], reverse=reverse)
    return "\n".join(f"| {r['file']} | {fmt.format(r[key])} | {r.get('camera_model') or ''} | {r.get('iso') or ''} |" for r in rows[:n])


def write_markdown(records: list[dict], charts: list[str], path: str, title: str = "Image quality report") -> None:
    n = len(records)
    with_edges = [r for r in records if r.get("edges_measured")]
    lines = [f"# {title}", "", f"Generated {datetime.now():%Y-%m-%d %H:%M} by iqa on {n} images.", ""]

    def stat(key, label, fmt="{:.3f}"):
        v = _finite(records, key)
        if v.size:
            lines.append(f"| {label} | {fmt.format(np.median(v))} | {fmt.format(v.min())} | {fmt.format(v.max())} | {v.size} |")

    lines += ["## Summary", "", "| metric | median | min | max | n |", "| --- | --- | --- | --- | --- |"]
    stat("mtf50_p80_cpp", "In-focus sharpness, MTF50 (cycles/px)")
    stat("mtf50_median_cpp", "Overall sharpness, MTF50 (cycles/px)")
    stat("edge_rise_median_px", "Edge 10-90 % rise (px)", "{:.2f}")
    stat("snr_midgrey_db", "SNR at mid-grey (dB)", "{:.1f}")
    stat("luma_noise_midgrey_8bit", "Luma noise at mid-grey (8-bit std)", "{:.2f}")
    stat("chroma_noise_midgrey_8bit", "Chroma noise at mid-grey (8-bit std)", "{:.2f}")
    stat("dr_snr4_stops", "Dynamic range @ SNR 4 (stops, output-referred)", "{:.1f}")
    stat("clip_high_pct", "Highlight clipping (% pixels)", "{:.2f}")
    stat("clip_low_pct", "Shadow clipping (% pixels)", "{:.2f}")
    stat("colorfulness", "Colorfulness (Hasler-Suesstrunk)", "{:.1f}")
    lines.append("")
    lines.append(f"Edges were found and measured in {len(with_edges)} of {n} images. "
                 "Images without usable slanted edges (open water, sky, bokeh) have no sharpness figure.")
    lines.append("")

    lines += ["## Sharpest images (MTF50, 80th percentile of edges)", "", "| file | MTF50 c/px | camera | ISO |", "| --- | --- | --- | --- |",
              _top(records, "mtf50_p80_cpp"), "",
              "## Softest images", "", "| file | MTF50 c/px | camera | ISO |", "| --- | --- | --- | --- |",
              _top(records, "mtf50_p80_cpp", reverse=False), "",
              "## Cleanest images (SNR at mid-grey)", "", "| file | SNR dB | camera | ISO |", "| --- | --- | --- | --- |",
              _top(records, "snr_midgrey_db", fmt="{:.1f}"), "",
              "## Noisiest images", "", "| file | SNR dB | camera | ISO |", "| --- | --- | --- | --- |",
              _top(records, "snr_midgrey_db", reverse=False, fmt="{:.1f}"), "",
              "## Most highlight clipping", "", "| file | % clipped | camera | ISO |", "| --- | --- | --- | --- |",
              _top(records, "clip_high_pct", fmt="{:.2f}"), ""]

    # Per-camera breakdown.
    cams = {}
    for r in records:
        cams.setdefault(r.get("camera_model") or "unknown", []).append(r)
    if len(cams) > 1:
        lines += ["## By camera", "", "| camera | images | MTF50 p80 (median) | SNR mid-grey dB (median) | DR@SNR4 (median) |", "| --- | --- | --- | --- | --- |"]
        for cam, rs in sorted(cams.items(), key=lambda kv: -len(kv[1])):
            m = _finite(rs, "mtf50_p80_cpp"); s = _finite(rs, "snr_midgrey_db"); d = _finite(rs, "dr_snr4_stops")
            lines.append(f"| {cam} | {len(rs)} | {np.median(m):.3f} | {np.median(s):.1f} | {np.median(d):.1f} |" if m.size and s.size and d.size
                         else f"| {cam} | {len(rs)} | | | |")
        lines.append("")

    if charts:
        lines += ["## Charts", ""]
        for c in charts:
            lines.append(f"![{os.path.basename(c)}]({os.path.relpath(c, os.path.dirname(path))})")
            lines.append("")

    lines += ["## How to read these numbers", "",
              "- **MTF50** is the spatial frequency (cycles per pixel) at which contrast falls to 50 %. Higher is sharper; 0.25-0.35 is very sharp (often sharpened), 0.10-0.15 is soft. Measured on natural slanted edges with the ISO 12233 e-SFR method, so treat it as a consistent *relative* measure rather than a chart-grade absolute.",
              "- **SNR at mid-grey** is 20·log10(118 / noise std) on the 8-bit luminance of flat patches; 35+ dB is clean, below 25 dB is visibly noisy.",
              "- **Dynamic range** is output-referred: the stops between near-white and the darkest level whose scene-linear SNR still exceeds the threshold. A JPEG's tone curve bounds it; a 'lower bound' flag means the image had no shadows dark enough to find the floor.",
              "- **Clipping** is the share of pixels at the top (any channel >= 254) or bottom (all channels <= 1) of the range.",
              ""]
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
