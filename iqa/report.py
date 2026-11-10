"""CSV, charts and a markdown report for a batch of analysed images."""
from __future__ import annotations

import csv
import json
import math
import os
from datetime import datetime

import numpy as np

# How each rejection reason in ``edges_reject_reasons`` reads in the report.
REJECT_REASON_LABELS = {
    "plateau_noise": "plateau too noisy", "error": "SFR failed", "clipped": "clipped",
    "contrast_gt_1": "contrast > 1", "no_mtf50_below_nyquist": "no MTF50 below Nyquist",
    "step_too_small": "step too small", "fit_residual": "edge not straight (fit residual)",
    "shading": "shaded", "rise_width": "rise too wide", "not_a_step": "not a step",
    "slant": "slant out of range", "out_of_frame": "out of frame",
}

CSV_COLUMNS = [
    "file", "format", "is_raw", "camera_make", "camera_model", "lens", "iso", "exposure_s", "f_number",
    "focal_mm", "datetime", "width", "height",
    "color_profile",
    "edges_candidates", "edges_measured", "edges_rejected", "edges_unexamined", "edges_reject_reasons",
    "mtf50_median_cpp", "mtf50_median_ci_lo_cpp", "mtf50_median_ci_hi_cpp",
    "mtf50_p80_cpp", "mtf50_p80_ci_lo_cpp", "mtf50_p80_ci_hi_cpp", "mtf50_max_cpp", "mtf50p_median_cpp", "mtf50_p80_lwph",
    "mtf50_v_median_cpp", "mtf50_h_median_cpp", "mtf50_center_median_cpp", "mtf50_outer_median_cpp",
    "edges_center", "edges_outer", "edge_rise_median_px", "mtf_nyquist_median", "overshoot_median_pct",
    "mtf50_infocus_cpp", "mtf50_background_cpp", "infocus_edge_share",
    "structure_focus_fraction", "structure_focus_cx", "structure_focus_cy", "structure_thirds_distance",
    "structure_orient_horizontal", "structure_orient_vertical", "structure_orient_diagonal",
    "structure_horizon_tilt_deg", "structure_flat_share", "structure_texture_share", "structure_edge_share",
    "noise_patches", "noise_candidate_patches", "noise_rejection_rate", "noise_whiteness", "noise_texture_suspect",
    "noise_spectral_peak", "noise_periodic_suspect", "noise_periodic_freq_cpp", "noise_periodic_fraction",
    "luma_noise_midgrey_8bit", "chroma_noise_midgrey_8bit", "snr_midgrey_db",
    "snr_midgrey_extrapolated", "snr_nearest_bin_level",
    "dr_snr1_stops", "dr_snr2_stops", "dr_snr4_stops", "dr_snr10_stops",
    "dr_snr1_lower_bound", "dr_snr2_lower_bound", "dr_snr4_lower_bound", "dr_snr10_lower_bound",
    "clip_high_pct", "clip_low_pct", "clip_gamut_pct", "mean_luma", "luma_p1", "luma_p50", "luma_p99",
    "tonal_range_stops", "colorfulness", "wb_r_over_g", "wb_b_over_g", "wb_r_over_g_stops",
    "wb_b_over_g_stops", "saturation_mean", "analysis_s", "cpu_s", "dhash256", "sha256", "analyzer_key",
    "memory_tier", "path",
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


def detail_dict(r: dict) -> dict:
    """The per-edge list and the noise curve of a freshly analysed record, as results.json and the
    memory's detail tier carry them; empty for a record read back from JSON."""
    d: dict = {}
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
    return d


def write_json(records: list[dict], path: str) -> None:
    clean = []
    for r in records:
        d = {k: v for k, v in r.items() if not k.startswith("_")}
        d.update(detail_dict(r))
        clean.append(d)

    def default(o):
        if isinstance(o, (np.floating, np.integer)):
            return o.item()
        if isinstance(o, np.ndarray):
            return o.tolist()
        return str(o)

    with open(path, "w") as fh:
        json.dump(clean, fh, indent=1, default=default, allow_nan=True)


def rehydrate(records: list[dict]) -> list[dict]:
    """Rebuild the noise curve that the charts read from a record's stored ``noise_curve`` (a
    results.json row or a remembered record), in place. ``noise_curve`` and ``edges`` stay on the
    record, so write_json writes them back unchanged."""
    from .noise import NoiseResult
    for r in records:
        nc = r.get("noise_curve")
        if nc and r.get("_noise") is None:
            n = NoiseResult(n_patches=r.get("noise_patches", 0))
            n.bin_centers = np.array(nc["luma_8bit"]); n.luma_noise = np.array(nc["luma_noise_8bit"])
            n.chroma_noise = np.array(nc["chroma_noise_8bit"]); n.bin_counts = np.array(nc["patches"])
            r["_noise"] = n
    return records


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
            ax.set_title("Resolution by camera, LW/PH on the short side\n(comparable across sensor sizes and orientations; cycles/px is not)", fontsize=10)
            ax.grid(True, axis="y", alpha=0.3)
            fig.tight_layout(); p = os.path.join(out_dir, "lwph_by_camera.png"); fig.savefig(p, dpi=130); plt.close(fig); made.append(p)

    # Noise curves overlay: luminance noise vs. level for every image (a camera's "noise profile").
    # Frames flagged as periodic texture or extreme NR are left out: their curve is not noise.
    curves = [(r["file"], r["_noise"]) for r in records
              if r.get("_noise") is not None and r["_noise"].bin_centers.size >= 3
              and not r.get("noise_texture_suspect") and not r.get("noise_periodic_suspect")]
    if curves:
        fig, ax = plt.subplots(figsize=(7, 4.2))
        for name, nz in curves:
            ax.plot(nz.bin_centers, nz.luma_noise, "-", color="C0", alpha=0.12, lw=0.8)
        ax.set_xlabel("mean luminance (8-bit)")
        ax.set_ylabel("luma noise (8-bit std)")
        ax.set_title(f"noise vs. signal level, one line per image: {len(curves)} of {len(records)} images\n"
                     "(frames flagged as periodic texture or extreme NR left out)", fontsize=10)
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
    # Imported here, not at the top: iqa.noise loads OpenCV, which writing results.json and
    # results.csv from remembered records does not need.
    from .noise import PERIODIC_PEAK_THRESHOLD, WHITENESS_HEAVY, WHITENESS_SMOOTHED
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
    reason_totals: dict[str, int] = {}
    for r in records:
        for part in str(r.get("edges_reject_reasons") or "").split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                reason_totals[k] = reason_totals.get(k, 0) + int(v)
    reason_text = ", ".join(f"{REJECT_REASON_LABELS.get(k, k.replace('_', ' '))} {v:,}"
                            for k, v in sorted(reason_totals.items(), key=lambda kv: -kv[1]))
    n_unexamined = sum(int(r.get("edges_unexamined") or 0) for r in records)
    n_unrecorded = sum(max(0, int(r.get("edges_candidates") or 0) - int(r.get("edges_measured") or 0)
                           - int(r.get("edges_rejected") or 0) - int(r.get("edges_unexamined") or 0))
                       for r in records)
    edge_tail = ""
    if n_unexamined:
        edge_tail += f" {n_unexamined} further candidates were not examined because the image had already given its maximum number of edges."
    if n_unrecorded:
        edge_tail += (f" {n_unrecorded} candidates have no recorded outcome: results written before 2026-10-23 did not count"
                      " candidates whose ROI fell outside the frame or that were left once the edge cap was reached.")
    lines += ["## What was and was not measurable", "",
              f"- Sharpness: usable slanted edges in **{len(with_edges)} of {n}** images, and **{n_sharp}** had the three or more edges needed for a per-image figure (the medians and rankings use only those). Images without edges (open water, sky, bokeh) have no sharpness figure; "
              f"{sum(r.get('edges_rejected', 0) for r in rej)} candidate edges across {len(rej)} images were rejected ({reason_text}; counts per image in the CSV).{edge_tail}",
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
              "- **In-focus sharpness (p80)** assumes at least a fifth of the measured edges are in the plane of focus; on a shallow-depth-of-field frame with few in-focus edges it reports the background. Check `edges_measured` and `mtf50_max_cpp`. `mtf50_*_ci_lo/hi_cpp` are 95 % percentile-bootstrap intervals over the measured edges: how far the figure would move with a different handful of edges from the same frame. With few edges they are wide and reach the sample's extremes; they do not include the scene-dependent bias of natural edges.",
              "- **Structure** columns describe the frame, not its quality: `structure_focus_fraction` is the share of a 4x6 grid holding at least half the frame's peak fine detail (small = a subject against a smooth or blurred field), `structure_focus_cx/cy` is where that detail sits (0-1), `structure_thirds_distance` its distance from the nearest rule-of-thirds point (0 on the point, 1 at the frame centre), the `structure_orient_*` shares say whether strong gradients run horizontally, vertically or diagonally, `structure_horizon_tilt_deg` is the tilt of the longest near-level edge when one exists (a horizon, a table, a shelf; positive = right end lower), and the flat/texture/edge shares say what the surface is made of. `mtf50_infocus_cpp` / `mtf50_background_cpp` appear when the measured edges split cleanly into a sharp and a soft group (a shallow-depth-of-field frame), with `infocus_edge_share` the sharp share; the p80 figure should then be read as the in-focus value.",
              "- **Overshoot** is how far the edge profile overshoots its bright plateau, in % of the step: a direct measure of sharpening halo. MTF50P (relative to the MTF peak) is the sharpening-robust companion of MTF50.",
              "- **SNR at mid-grey** is 20·log10(118 / noise std) on the 8-bit luminance of flat patches; 38+ dB is excellent, 32+ clean, below 25 dB visibly noisy (the same scale IQ Coach uses). 8-bit quantisation alone caps it at about 52 dB. The figure is output-referred: noise reduction and JPEG/HEIC compression lower it as much as the sensor does, so SNR-vs-ISO across formats is partly a chart of processing. `noise_whiteness` near 0.14 means white noise; " + f"{WHITENESS_SMOOTHED:g}+ means the noise has been smoothed by NR or compression, {WHITENESS_HEAVY:g}+ heavily (at very low noise, fine texture and compression raise it too). `noise_spectral_peak` is how far the strongest frequency in the averaged patch spectrum stands above its surroundings: about 1 for noise, above {PERIODIC_PEAK_THRESHOLD:g} (`noise_periodic_suspect`) the flat patches contain a repeating pattern (a screen's pixel grid, a weave, halftone) at `noise_periodic_freq_cpp` cycles per pixel, and the SNR is of the pattern, not the sensor.",
              "- **Dynamic range** is output-referred: the stops between near-white and the darkest level whose scene-linear SNR still exceeds the threshold. A JPEG's tone curve bounds it, and the floor can only be found in frames that contain near-black flat areas; 'lower bound' rows are excluded from the medians.",
              "- **Clipping** is the share of pixels at the top (any channel >= 254) or bottom (all channels <= 1) of the range, measured in the file's own encoding before any profile conversion. `clip_gamut_pct` is the extra share that saturates only after converting Display P3 or Adobe RGB to sRGB, counted on the same pixels (0 when the file needed no conversion): colour outside the sRGB gamut, not lost detail.",
              "- **White balance** is the gray-world ratio of linear channel means (and in stops); it describes the scene's cast as rendered, which for sunsets and underwater work is intent, not error.",
              ""]
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
