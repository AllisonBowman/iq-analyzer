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
    "color_profile",
    "edges_candidates", "edges_measured", "edges_rejected", "edges_reject_reasons",
    "mtf50_median_cpp", "mtf50_p80_cpp", "mtf50_max_cpp", "mtf50p_median_cpp", "mtf50_p80_lwph",
    "mtf50_v_median_cpp", "mtf50_h_median_cpp", "mtf50_center_median_cpp", "mtf50_outer_median_cpp",
    "edges_center", "edges_outer", "edge_rise_median_px", "mtf_nyquist_median", "overshoot_median_pct",
    "noise_patches", "noise_candidate_patches", "noise_rejection_rate", "noise_whiteness", "noise_texture_suspect",
    "noise_spectral_peak", "noise_periodic_suspect", "noise_periodic_freq_cpp", "noise_periodic_fraction",
    "luma_noise_midgrey_8bit", "chroma_noise_midgrey_8bit", "snr_midgrey_db",
    "snr_midgrey_extrapolated", "snr_nearest_bin_level",
    "dr_snr1_stops", "dr_snr2_stops", "dr_snr4_stops", "dr_snr10_stops",
    "dr_snr1_lower_bound", "dr_snr2_lower_bound", "dr_snr4_lower_bound", "dr_snr10_lower_bound",
    "clip_high_pct", "clip_low_pct", "mean_luma", "luma_p1", "luma_p50", "luma_p99",
    "tonal_range_stops", "colorfulness", "wb_r_over_g", "wb_b_over_g", "wb_r_over_g_stops",
    "wb_b_over_g_stops", "saturation_mean", "analysis_s", "path",
]


def _fmt(v):
    if v is None:
        return ""
    if isinstance(v, float):
        if math.isnan(v):
            return ""
        return f"{v:.6g}"
    return v


def strip_paths(records: list[dict]) -> list[dict]:
    """Drop the ``path`` field (the absolute location of each source file) so results can be
    published; ``file`` (the basename) stays as the row key.  Returns new dicts."""
    return [{k: v for k, v in r.items() if k != "path"} for r in records]


def write_csv(records: list[dict], path: str) -> None:
    with open(path, "w", newline="") as fh:
        present = {k for r in records for k in r}
        w = csv.DictWriter(fh, fieldnames=[c for c in CSV_COLUMNS if c in present], extrasaction="ignore")
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


# Rows whose value for a key is a genuine measurement, not an extrapolation or a bound.
def _noise_ok(r):
    return (not r.get("snr_midgrey_extrapolated") and not r.get("noise_texture_suspect")
            and not r.get("noise_periodic_suspect"))


def _sharp_ok(r):
    return (r.get("edges_measured") or 0) >= 3


VALIDITY = {
    "snr_midgrey_db": _noise_ok,
    "luma_noise_midgrey_8bit": _noise_ok,
    "chroma_noise_midgrey_8bit": _noise_ok,
    "mtf50_p80_cpp": _sharp_ok,
    "mtf50_median_cpp": _sharp_ok,
    "mtf50p_median_cpp": _sharp_ok,
    "mtf50_p80_lwph": _sharp_ok,
    "mtf50_center_median_cpp": _sharp_ok,
    "mtf50_outer_median_cpp": _sharp_ok,
    "overshoot_median_pct": _sharp_ok,
    "edge_rise_median_px": _sharp_ok,
    "dr_snr1_stops": lambda r: not r.get("dr_snr1_lower_bound"),
    "dr_snr2_stops": lambda r: not r.get("dr_snr2_lower_bound"),
    "dr_snr4_stops": lambda r: not r.get("dr_snr4_lower_bound"),
    "dr_snr10_stops": lambda r: not r.get("dr_snr10_lower_bound"),
}


def valid_records(records, key):
    f = VALIDITY.get(key)
    return [r for r in records if f is None or f(r)]


def write_charts(records: list[dict], out_dir: str) -> list[str]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    made = []
    os.makedirs(out_dir, exist_ok=True)

    def scatter_vs_iso(key, ylabel, fname, logy=False):
        rows = valid_records(records, key)
        pts = [(r["iso"], r[key]) for r in rows
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
        ax.set_title(f"n = {len(pts)} of {len(records)} images with a valid measurement and ISO")
        ax.grid(True, which="both", alpha=0.3)
        fig.tight_layout()
        p = os.path.join(out_dir, fname)
        fig.savefig(p, dpi=130)
        plt.close(fig)
        made.append(p)

    def hist(key, xlabel, fname, bins=20):
        v = _finite(valid_records(records, key), key)
        if v.size < 3:
            return
        fig, ax = plt.subplots(figsize=(7, 4.2))
        ax.hist(v, bins=bins, alpha=0.85)
        ax.set_xlabel(xlabel)
        ax.set_ylabel("images")
        ax.set_title(f"n = {v.size} of {len(records)} images")
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

    # Per-camera views: the pooled SNR-vs-ISO cloud hides that phones flatten noise with ISO-dependent NR.
    cams = {}
    for r in records:
        cams.setdefault(r.get("camera_model") or "unknown", []).append(r)
    top = [c for c, rs in sorted(cams.items(), key=lambda kv: -len(kv[1]))[:5] if len(rs) >= 8]
    if len(top) >= 2:
        fig, ax = plt.subplots(figsize=(7.5, 4.4))
        for cam in top:
            rs = valid_records(cams[cam], "snr_midgrey_db")
            pts = [(r["iso"], r["snr_midgrey_db"]) for r in rs
                   if isinstance(r.get("iso"), (int, float)) and r["iso"] and isinstance(r.get("snr_midgrey_db"), (int, float))
                   and not math.isnan(r["snr_midgrey_db"])]
            if len(pts) < 5:
                continue
            x, y = zip(*pts)
            ax.scatter(x, y, s=20, alpha=0.6, label=f"{cam} (n={len(pts)})")
            # running median in log-ISO bins
            lx = np.log10(np.array(x)); ly = np.array(y)
            bins = np.linspace(lx.min(), lx.max(), 7)
            cx, cy = [], []
            for b0, b1 in zip(bins[:-1], bins[1:]):
                m = (lx >= b0) & (lx <= b1)
                if m.sum() >= 4:
                    cx.append(10 ** ((b0 + b1) / 2)); cy.append(np.median(ly[m]))
            if len(cx) >= 2:
                ax.plot(cx, cy, "-", lw=2, alpha=0.9)
        ax.set_xscale("log"); ax.set_xlabel("ISO"); ax.set_ylabel("SNR at mid-grey (dB), output-referred")
        ax.set_title("SNR vs ISO by camera (points) with binned medians (lines)")
        ax.grid(True, which="both", alpha=0.3); ax.legend(fontsize=8)
        fig.tight_layout(); p = os.path.join(out_dir, "snr_vs_iso_by_camera.png"); fig.savefig(p, dpi=130); plt.close(fig); made.append(p)

        fig, ax = plt.subplots(figsize=(7.5, 4.4))
        data, labels = [], []
        for cam in top:
            v = _finite(valid_records(cams[cam], "mtf50_p80_lwph"), "mtf50_p80_lwph")
            if v.size >= 3:
                data.append(v); labels.append(f"{cam}\n(n={v.size})")
        if data:
            ax.boxplot(data, tick_labels=labels, showfliers=True)
            ax.set_ylabel("in-focus MTF50, line widths / picture height")
            ax.set_title("Resolution by camera (LW/PH is comparable across sensor sizes; cycles/px is not)")
            ax.grid(True, axis="y", alpha=0.3)
            fig.tight_layout(); p = os.path.join(out_dir, "lwph_by_camera.png"); fig.savefig(p, dpi=130); plt.close(fig); made.append(p)

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
    rows = [r for r in valid_records(records, key) if isinstance(r.get(key), (int, float)) and not math.isnan(r[key])]
    rows.sort(key=lambda r: r[key], reverse=reverse)
    return "\n".join(f"| {r['file']} | {fmt.format(r[key])} | {r.get('camera_model') or ''} | {r.get('iso') or ''} |" for r in rows[:n])


def write_markdown(records: list[dict], charts: list[str], path: str, title: str = "Image quality report") -> None:
    n = len(records)
    with_edges = [r for r in records if r.get("edges_measured")]
    lines = [f"# {title}", "", f"Generated {datetime.now():%Y-%m-%d %H:%M} by iqa on {n} images.", ""]

    def stat(key, label, fmt="{:.3f}"):
        v = _finite(valid_records(records, key), key)
        if v.size:
            lines.append(f"| {label} | {fmt.format(np.median(v))} | {fmt.format(v.min())} | {fmt.format(v.max())} | {v.size} |")
        else:
            lines.append(f"| {label} | not measurable | | | 0 |")

    lines += ["## Summary", "", "| metric | median | min | max | n |", "| --- | --- | --- | --- | --- |"]
    stat("mtf50_p80_cpp", "In-focus sharpness, MTF50 (cycles/px)")
    stat("mtf50_median_cpp", "Overall sharpness, MTF50 (cycles/px)")
    stat("mtf50_center_median_cpp", "Centre-of-frame MTF50 (cycles/px)")
    stat("mtf50_outer_median_cpp", "Outer-frame MTF50 (cycles/px)")
    stat("overshoot_median_pct", "Edge overshoot / sharpening halo (% of step)", "{:.1f}")
    stat("edge_rise_median_px", "Edge 10-90 % rise (px)", "{:.2f}")
    stat("snr_midgrey_db", "SNR at mid-grey (dB)", "{:.1f}")
    stat("luma_noise_midgrey_8bit", "Luma noise at mid-grey (8-bit std)", "{:.2f}")
    stat("chroma_noise_midgrey_8bit", "Chroma noise at mid-grey (8-bit std)", "{:.2f}")
    stat("dr_snr4_stops", "Dynamic range @ SNR 4 (stops, output-referred)", "{:.1f}")
    stat("clip_high_pct", "Highlight clipping (% pixels)", "{:.2f}")
    stat("clip_low_pct", "Shadow clipping (% pixels)", "{:.2f}")
    stat("noise_whiteness", "Noise whiteness (0.14 = white; higher = NR / compression)", "{:.2f}")
    stat("colorfulness", "Colorfulness (Hasler-Suesstrunk)", "{:.1f}")
    lines.append("")
    n_extrap = sum(1 for r in records if r.get("snr_midgrey_extrapolated"))
    n_tex = sum(1 for r in records if r.get("noise_texture_suspect") or r.get("noise_periodic_suspect"))
    n_per = sum(1 for r in records if r.get("noise_periodic_suspect"))
    n_dr_lb = sum(1 for r in records if r.get("dr_snr4_lower_bound"))
    n_no_noise = sum(1 for r in records if not r.get("noise_patches"))
    n_sharp = sum(1 for r in records if _sharp_ok(r))
    rej = [r for r in records if r.get("edges_rejected")]
    lines += ["## What was and was not measurable", "",
              f"- Sharpness: usable slanted edges in **{len(with_edges)} of {n}** images, and **{n_sharp}** had the three or more edges needed for a per-image figure (the medians and rankings use only those). Images without edges (open water, sky, bokeh) have no sharpness figure; "
              f"{sum(r.get('edges_rejected', 0) for r in rej)} candidate edges across {len(rej)} images were rejected as clipped, shaded, too noisy, too small a step, or not a step at all (counts per image in the CSV).",
              f"- Noise: **{n - n_extrap - n_no_noise - n_tex} of {n}** images had flat patches near mid-grey with noise that looks like noise; {n_extrap} report the nearest level instead, {n_tex} are flagged as periodic texture or extreme noise reduction (screens, fabric; {n_per} of them by the spectral detector), and both groups are excluded from the SNR medians and charts; {n_no_noise} had no usable patches.",
              f"- Dynamic range: the noise floor was reached in **{n - n_dr_lb} of {n}** images; the other {n_dr_lb} contained no shadows dark enough and give only a lower bound, which is excluded from the DR medians.",
              ""]

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
        lines += ["## By camera", "", "| camera | images | MTF50 p80 median (n) | SNR mid-grey dB median (n) | DR@SNR4 stops median (n) |", "| --- | --- | --- | --- | --- |"]

        def cell(rs, key, fmt):
            v = _finite(valid_records(rs, key), key)
            return f"{fmt.format(np.median(v))} ({v.size})" if v.size else "- (0)"

        for cam, rs in sorted(cams.items(), key=lambda kv: -len(kv[1])):
            lines.append(f"| {cam} | {len(rs)} | {cell(rs, 'mtf50_p80_cpp', '{:.3f}')} | {cell(rs, 'snr_midgrey_db', '{:.1f}')} | {cell(rs, 'dr_snr4_stops', '{:.1f}')} |")
        lines.append("")

    if charts:
        lines += ["## Charts", ""]
        for c in charts:
            lines.append(f"![{os.path.basename(c)}]({os.path.relpath(c, os.path.dirname(path))})")
            lines.append("")

    lines += ["## How to read these numbers", "",
              "- **MTF50** is the spatial frequency (cycles per pixel, along the edge normal) at which contrast falls to 50 %. Higher is sharper; 0.25-0.35 is very sharp (often sharpened), 0.10-0.15 is soft. Measured on natural slanted edges with the ISO 12233 e-SFR method: a real edge is never a perfect step, so every figure is a scene-dependent *lower bound* on the system MTF, consistent across images of similar subjects but not a chart-grade absolute. The 'sharpest images' ranking compares scenes as much as lenses.",
              "- **In-focus sharpness (p80)** assumes at least a fifth of the measured edges are in the plane of focus; on a shallow-depth-of-field frame with few in-focus edges it reports the background. Check `edges_measured` and `mtf50_max_cpp`.",
              "- **Overshoot** is how far the edge profile overshoots its bright plateau, in % of the step: a direct measure of sharpening halo. MTF50P (relative to the MTF peak) is the sharpening-robust companion of MTF50.",
              "- **SNR at mid-grey** is 20·log10(118 / noise std) on the 8-bit luminance of flat patches; 35+ dB is clean, below 25 dB is visibly noisy. 8-bit quantisation alone caps it at about 52 dB. The figure is output-referred: noise reduction and JPEG/HEIC compression lower it as much as the sensor does, so SNR-vs-ISO across formats is partly a chart of processing. `noise_whiteness` near 0.14 means white noise; 0.3+ means the noise has been smoothed by NR or compression. `noise_spectral_peak` is how far the strongest frequency in the averaged patch spectrum stands above its surroundings: about 1 for noise, above 8 (`noise_periodic_suspect`) the flat patches contain a repeating pattern (a screen's pixel grid, a weave, halftone) at `noise_periodic_freq_cpp` cycles per pixel, and the SNR is of the pattern, not the sensor.",
              "- **Dynamic range** is output-referred: the stops between near-white and the darkest level whose scene-linear SNR still exceeds the threshold. A JPEG's tone curve bounds it, and the floor can only be found in frames that contain near-black flat areas; 'lower bound' rows are excluded from the medians.",
              "- **Clipping** is the share of pixels at the top (any channel >= 254) or bottom (all channels <= 1) of the range.",
              "- **White balance** is the gray-world ratio of linear channel means (and in stops); it describes the scene's cast as rendered, which for sunsets and underwater work is intent, not error.",
              ""]
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
