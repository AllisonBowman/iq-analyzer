"""Command-line interface.

    python -m iqa analyze PATH [PATH ...] --out results [--sample N] [--recursive]
    python -m iqa sfr IMAGE --roi X,Y,W,H [--horizontal]
    python -m iqa demo --out results_demo
"""
from __future__ import annotations

import argparse
import os
import random
import sys
import time

from . import __version__
from .imageio import is_image_file


def _collect(paths: list[str], recursive: bool) -> list[str]:
    files: list[str] = []
    for p in paths:
        if os.path.isdir(p):
            if recursive:
                for root, _dirs, names in os.walk(p):
                    files += [os.path.join(root, n) for n in names if is_image_file(n) and not n.startswith(".")]
            else:
                files += [os.path.join(p, n) for n in sorted(os.listdir(p)) if is_image_file(n) and not n.startswith(".")]
        elif os.path.isfile(p) and is_image_file(p):
            files.append(p)
    return sorted(set(files))


def cmd_analyze(args: argparse.Namespace) -> int:
    from .analyze import analyze_file
    from .report import strip_paths, write_charts, write_csv, write_json, write_markdown

    files = _collect(args.paths, args.recursive)
    if args.list:
        with open(args.list) as fh:
            files += [ln.strip() for ln in fh if ln.strip() and is_image_file(ln.strip())]
        files = sorted(set(files))
    if not files:
        print("no image files found", file=sys.stderr)
        return 2
    if args.sample and len(files) > args.sample:
        rng = random.Random(args.seed)
        files = sorted(rng.sample(files, args.sample))
    os.makedirs(args.out, exist_ok=True)
    print(f"iqa {__version__}: analysing {len(files)} images -> {args.out}")
    records, failed = [], []
    t0 = time.time()
    for i, f in enumerate(files, 1):
        try:
            rec = analyze_file(f, max_rois=args.max_rois, max_side=args.max_side)
            records.append(rec)
            m = rec.get("mtf50_p80_cpp")
            s = rec.get("snr_midgrey_db")
            print(f"[{i}/{len(files)}] {os.path.basename(f)}: edges={rec['edges_measured']} "
                  f"mtf50_p80={m if m is None else round(m, 3)} snr={s if s is None else round(s, 1)} dB "
                  f"clip_hi={rec['clip_high_pct']:.2f}% ({rec['analysis_s']}s)")
        except Exception as exc:  # keep going; one bad file must not sink the batch
            failed.append((f, repr(exc)))
            print(f"[{i}/{len(files)}] {os.path.basename(f)}: FAILED {exc!r}", file=sys.stderr)
    if not records:
        print("nothing analysed", file=sys.stderr)
        return 1
    if args.no_paths:
        records = strip_paths(records)
    write_csv(records, os.path.join(args.out, "results.csv"))
    write_json(records, os.path.join(args.out, "results.json"))
    charts = write_charts(records, os.path.join(args.out, "charts"))
    write_markdown(records, charts, os.path.join(args.out, "report.md"), title=args.title)
    if failed:
        with open(os.path.join(args.out, "failed.txt"), "w") as fh:
            fh.write("\n".join(f"{p}\t{e}" for p, e in failed))
    print(f"done: {len(records)} analysed, {len(failed)} failed, {time.time() - t0:.1f}s. "
          f"See {os.path.join(args.out, 'report.md')}")
    return 0


def cmd_sfr(args: argparse.Namespace) -> int:
    import numpy as np
    from .imageio import load_image
    from .sfr import compute_sfr
    img = load_image(args.image)
    x, y, w, h = (int(v) for v in args.roi.split(","))
    roi = img.lin_luma[y:y + h, x:x + w].astype(np.float64)
    if args.horizontal:
        roi = roi.T
    r = compute_sfr(roi)
    print(f"MTF50 = {r.mtf50:.4f} c/px   MTF50P = {r.mtf50p:.4f}   MTF30 = {r.mtf30:.4f}   MTF@Nyquist = {r.mtf_nyquist:.3f}")
    print(f"edge angle {r.slope_deg:.2f} deg, fit rms {r.fit_rms_px:.3f} px, contrast {r.contrast:.2f}, "
          f"10-90% rise {r.rise_10_90_px:.2f} px")
    if args.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(1, 2, figsize=(10, 4))
        ax[0].plot(np.arange(r.esf.size) / r.oversample, r.esf); ax[0].set_title("ESF"); ax[0].set_xlabel("px")
        sel = r.freq <= 0.5
        ax[1].plot(r.freq[sel], r.mtf[sel]); ax[1].axhline(0.5, ls="--", c="gray"); ax[1].set_ylim(0, 1.1)
        ax[1].set_title(f"MTF (MTF50={r.mtf50:.3f} c/px)"); ax[1].set_xlabel("cycles/pixel")
        fig.tight_layout(); fig.savefig(args.plot, dpi=130)
        print(f"plot -> {args.plot}")
    return 0


def cmd_demo(args: argparse.Namespace) -> int:
    """Generate synthetic scenes with known blur/noise and analyse them end to end."""
    import numpy as np
    from PIL import Image
    from .synth import synthetic_scene
    from .sfr import gaussian_mtf50

    src = os.path.join(args.out, "synthetic")
    os.makedirs(src, exist_ok=True)
    truth = []
    for k, (sigma, noise) in enumerate([(0.8, 1.5), (1.1, 3.0), (1.6, 6.0), (2.4, 10.0)]):
        rgb = synthetic_scene(size=1400, sigma_px=sigma, noise_8bit=noise, seed=k)
        p = os.path.join(src, f"scene_sigma{sigma}_noise{noise}.png")
        Image.fromarray(rgb).save(p)
        truth.append((os.path.basename(p), gaussian_mtf50(sigma), noise * 0.75))  # luma noise = 0.75 * per-channel
    ns = argparse.Namespace(paths=[src], list=None, out=args.out, sample=0, seed=0, recursive=False,
                            max_rois=30, max_side=None, title="iqa demo on synthetic scenes")
    rc = cmd_analyze(ns)
    print("\nground truth:  file | expected MTF50 | expected luma noise (8-bit)")
    for name, m, nz in truth:
        print(f"  {name} | {m:.4f} | {nz:.2f}")
    return rc


def cmd_report(args: argparse.Namespace) -> int:
    """Rebuild charts and report.md from an existing results.json without re-analysing."""
    import json
    import numpy as np
    from .noise import NoiseResult
    from .report import strip_paths, write_charts, write_csv, write_markdown

    with open(args.json) as fh:
        records = json.load(fh)
    if args.no_paths:
        records = strip_paths(records)
    for r in records:
        nc = r.pop("noise_curve", None)
        r.pop("edges", None)
        if nc:
            n = NoiseResult(n_patches=r.get("noise_patches", 0))
            n.bin_centers = np.array(nc["luma_8bit"]); n.luma_noise = np.array(nc["luma_noise_8bit"])
            n.chroma_noise = np.array(nc["chroma_noise_8bit"]); n.bin_counts = np.array(nc["patches"])
            r["_noise"] = n
    out = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out, exist_ok=True)
    write_csv(records, os.path.join(out, "results.csv"))
    charts = write_charts(records, os.path.join(out, "charts"))
    write_markdown(records, charts, os.path.join(out, "report.md"), title=args.title)
    print(f"rebuilt {len(charts)} charts and report.md in {out} from {len(records)} records")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="iqa", description="Image-quality analysis of real photographs.")
    ap.add_argument("--version", action="version", version=f"iqa {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("analyze", help="analyse a folder or files; writes CSV, JSON, charts and a report")
    a.add_argument("paths", nargs="*")
    a.add_argument("--list", default=None, help="text file with one image path per line (added to PATHS)")
    a.add_argument("--out", default="results")
    a.add_argument("--sample", type=int, default=0, help="random sample of N files (0 = all)")
    a.add_argument("--seed", type=int, default=1)
    a.add_argument("--recursive", "-r", action="store_true")
    a.add_argument("--max-rois", type=int, default=30, help="edges measured per image")
    a.add_argument("--max-side", type=int, default=None, help="downsample long side (changes sharpness; avoid)")
    a.add_argument("--title", default="Image quality report")
    a.add_argument("--no-paths", action="store_true", help="omit the source file paths from results.csv and results.json (for publishing)")
    a.set_defaults(func=cmd_analyze)

    s = sub.add_parser("sfr", help="slanted-edge SFR of one ROI in one image")
    s.add_argument("image")
    s.add_argument("--roi", required=True, help="x,y,w,h in pixels; the edge should run top-to-bottom")
    s.add_argument("--horizontal", action="store_true", help="the edge runs left-to-right")
    s.add_argument("--plot", default=None, help="write an ESF/MTF plot to this PNG")
    s.set_defaults(func=cmd_sfr)

    rp = sub.add_parser("report", help="rebuild charts and report.md from results.json without re-analysing")
    rp.add_argument("json")
    rp.add_argument("--out", default=None)
    rp.add_argument("--title", default="Image quality report")
    rp.add_argument("--no-paths", action="store_true", help="omit the source file paths from the rebuilt results.csv")
    rp.set_defaults(func=cmd_report)

    d = sub.add_parser("demo", help="synthetic end-to-end run with known ground truth")
    d.add_argument("--out", default="results_demo")
    d.set_defaults(func=cmd_demo)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
