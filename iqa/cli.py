"""Command-line interface.

    python -m iqa analyze PATH [PATH ...] --out results [--sample N] [--recursive] [--memory DB]
    python -m iqa sfr IMAGE --roi X,Y,W,H [--horizontal]
    python -m iqa demo --out results_demo
    python -m iqa memory (stats | compact | forget | export | key) ...
"""
from __future__ import annotations

import argparse
import os
import random
import sys
import time
from dataclasses import dataclass

from . import __version__


def _collect(paths: list[str], recursive: bool) -> list[str]:
    from .imageio import is_image_file
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


def _measure(path: str, max_rois: int, max_side: int | None) -> dict:
    # Imported at the first photo that needs measuring, so a run of remembered photos loads no
    # imaging libraries (numpy, scipy, OpenCV) for the measurement's sake.
    from .analyze import analyze_file
    return analyze_file(path, max_rois=max_rois, max_side=max_side)


def _summary(rec: dict) -> str:
    m = rec.get("mtf50_p80_cpp")
    s = rec.get("snr_midgrey_db")
    c = rec.get("clip_high_pct")
    return (f"edges={rec.get('edges_measured')} mtf50_p80={m if m is None else round(m, 3)} "
            f"snr={s if s is None else round(s, 1)} dB clip_hi={float('nan') if c is None else c:.2f}%")


def _write_outputs(args: argparse.Namespace, records: list[dict], failed: list, t0: float) -> None:
    from .report import rehydrate, strip_paths, write_csv, write_json
    if args.no_paths:
        records = strip_paths(records)
    write_csv(records, os.path.join(args.out, "results.csv"))
    write_json(records, os.path.join(args.out, "results.json"))
    if not args.no_report:
        from .report import write_charts, write_markdown
        rehydrate(records)          # remembered records carry their noise curve as stored JSON
        charts = write_charts(records, os.path.join(args.out, "charts"))
        write_markdown(records, charts, os.path.join(args.out, "report.md"), title=args.title)
    if failed:
        with open(os.path.join(args.out, "failed.txt"), "w") as fh:
            fh.write("\n".join(f"{p}\t{e}" for p, e in failed))
    see = "results.json" if args.no_report else "report.md"
    print(f"done: {len(records)} analysed, {len(failed)} failed, {time.time() - t0:.1f}s. "
          f"See {os.path.join(args.out, see)}")


def cmd_analyze(args: argparse.Namespace) -> int:
    from . import memory as M
    from .imageio import is_image_file

    if not args.memory and (args.sources or args.refresh or args.retry_failed):
        print("--sources, --refresh and --retry-failed need --memory", file=sys.stderr)
        return 2
    files = _collect(args.paths, args.recursive)
    if args.list:
        with open(args.list) as fh:
            files += [ln.strip() for ln in fh if ln.strip() and is_image_file(ln.strip())]
        files = sorted(set(files))
    if not files and not args.memory:
        print("no image files found", file=sys.stderr)
        return 2
    if args.sample and len(files) > args.sample:
        rng = random.Random(args.seed)
        files = sorted(rng.sample(files, args.sample))
    os.makedirs(args.out, exist_ok=True)
    if args.memory:
        return _analyze_with_memory(args, files)
    key = M.analyzer_key(args.max_rois, args.max_side)
    print(f"iqa {__version__}: analysing {len(files)} images -> {args.out}")
    records, failed = [], []
    t0 = time.time()
    for i, f in enumerate(files, 1):
        try:
            sha = M.sha256_file(f)
            rec = _measure(f, args.max_rois, args.max_side)
            rec["sha256"] = sha.hex()
            rec["analyzer_key"] = key
            records.append(rec)
            print(f"[{i}/{len(files)}] {os.path.basename(f)}: {_summary(rec)} ({rec['analysis_s']}s)")
        except Exception as exc:  # keep going; one bad file must not sink the batch
            failed.append((f, repr(exc)))
            print(f"[{i}/{len(files)}] {os.path.basename(f)}: FAILED {exc!r}", file=sys.stderr)
    if not records:
        print("nothing analysed", file=sys.stderr)
        return 1
    _write_outputs(args, records, failed, t0)
    return 0


# ---------------------------------------------------------------------------------------------
# analyze --memory (docs/MEMORY-SPEC.md section 6)
# ---------------------------------------------------------------------------------------------

@dataclass
class _SourceLine:
    """One line of the app's sources manifest. A staged file may come without a locator (a picker
    item the system gave no identifier, a copy left by an earlier version): it is measured and
    remembered by content, with no source, so staging paths never become aliases. On a staged
    line, ``sha256`` is the app's hash of the file it staged, which the analyzer's must equal."""
    kind: str
    locator: str | None
    path: str | None = None
    sha256: str | None = None
    signature: str | None = None
    status: str | None = None
    reason: str | None = None


def _read_manifest(path: str) -> tuple[dict, list, list]:
    """The manifest as (staged files by real path, not-capture lines, sha256-only lines). A line
    that cannot be understood is reported and skipped, never guessed at."""
    import json
    import re
    by_path: dict = {}
    not_capture: list = []
    sha_only: list = []
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            if not raw.strip():
                continue
            try:
                d = json.loads(raw)
            except ValueError as exc:
                print(f"iqa memory: {path} line {n} is not JSON ({exc}); skipped", file=sys.stderr)
                continue
            kind, locator = (d.get("kind"), d.get("locator")) if isinstance(d, dict) else (None, None)
            if not isinstance(locator, str) or not locator:
                locator = None
            staged = isinstance(d, dict) and isinstance(d.get("path"), str)
            if kind not in ("file", "photokit", "picker") or (locator is None and not staged):
                print(f"iqa memory: {path} line {n} needs a kind (file, photokit or picker) and a locator "
                      "(only a staged file may come without one); skipped", file=sys.stderr)
                continue
            status = d.get("status")
            if status not in (None, "not_capture"):
                print(f"iqa memory: {path} line {n}: unknown status {status!r} ignored", file=sys.stderr)
                status = None
            sha = d.get("sha256")
            valid_sha = isinstance(sha, str) and re.fullmatch(r"[0-9a-fA-F]{64}", sha) is not None
            line = _SourceLine(kind, locator, sha256=sha.lower() if valid_sha else None, signature=d.get("signature"),
                               status=status, reason=d.get("reason"))
            if isinstance(d.get("path"), str):
                line.path = d["path"]
                if sha is not None and not valid_sha:
                    # The app vouched for the bytes with a value no file can hash to: nothing to
                    # agree with, so the file is refused rather than measured unchecked.
                    print(f"iqa memory: {path} line {n}: sha256 {sha!r} is not 64 hex digits; the file will "
                          "not be remembered", file=sys.stderr)
                    line.sha256 = str(sha)
                if status == "not_capture":
                    not_capture.append(line)
                else:
                    by_path[os.path.realpath(line.path)] = line
            elif valid_sha:
                sha_only.append(line)
            else:
                print(f"iqa memory: {path} line {n} has neither a path nor a 64-hex sha256; skipped", file=sys.stderr)
    return by_path, not_capture, sha_only


def _memory_line(state: str, sha: bytes, path: str) -> None:
    # One machine-readable line per photo; the name is the rest of the line after the hash.
    name = os.path.basename(path).replace("\n", "?").replace("\r", "?")
    print(f"IQA-MEMORY {state} {sha.hex()} {name}", flush=True)


def _remembered_record(mem, asset, path: str) -> dict | None:
    """A stored record as a fresh measurement of this copy would read: this copy's name and path,
    the stored fields, then the detail when it is kept."""
    stored = mem.record(asset.id)
    if stored is None:
        return None
    detail = {k: stored.pop(k) for k in ("edges", "noise_curve") if k in stored}
    rec = {"file": os.path.basename(path), "path": path}
    rec.update((k, v) for k, v in stored.items() if k not in ("file", "path"))
    rec.update(sha256=asset.sha_hex, analyzer_key=asset.analyzer_key, memory_tier="record")
    rec.update(detail)
    return rec


def _ledger_record(asset, path: str) -> dict:
    """What the ledger still knows of a photo whose record was folded into the archive."""
    from .memory import HEADLINE_FIELDS
    rec = {"file": os.path.basename(path), "path": path, "camera_model": asset.camera or None,
           "datetime": asset.captured_at}
    for metric, (_col, name) in HEADLINE_FIELDS.items():
        rec[name] = asset.headline[metric]
    rec.update(sha256=asset.sha_hex, analyzer_key=asset.analyzer_key, memory_tier="ledger")
    return rec


_HEIF_EXT = frozenset({".heic", ".heif", ".hif"})


def _environmental(exc: BaseException) -> bool:
    """A failure of this machine or of the file's presence, not of its content: never remembered,
    so it cannot turn into a permanent skip. A decoder's "cannot identify image file" or "image
    file is truncated" is an OSError without an errno, and belongs to the file."""
    return isinstance(exc, (ImportError, MemoryError)) or (isinstance(exc, OSError) and exc.errno is not None)


def _unchanged(real: str, st: os.stat_result) -> bool:
    """The file is still the one that was hashed (False when it has gone or cannot be read)."""
    from .memory import stat_key
    try:
        return stat_key(os.stat(real)) == stat_key(st)
    except OSError:
        return False


def _decoder_missing(path: str) -> str | None:
    """Why this machine cannot decode the file, when its decoder is not installed. Read at measuring
    time, when the analyzer has loaded iqa.imageio already."""
    from . import imageio
    ext = os.path.splitext(path)[1].lower()
    if ext in _HEIF_EXT and not imageio.HAVE_HEIF:
        return "pillow-heif is not installed; cannot read HEIC files"
    if ext in imageio.RAW_EXT and not imageio.HAVE_RAWPY:
        return "rawpy is not installed; cannot read RAW files"
    return None


def _failed_photo(failed: list, i: int, n: int, f: str, sha: bytes, why: str, remembered: bool) -> None:
    failed.append((f, why))
    note = "" if remembered else "; not remembered"
    print(f"[{i}/{n}] {os.path.basename(f)}: FAILED {why}{note}", file=sys.stderr)
    _memory_line("failed", sha, f)


def _analyze_with_memory(args: argparse.Namespace, files: list[str]) -> int:
    """Exit codes (docs/MEMORY-SPEC.md section 6): 0 normal, an empty list included; 4 every photo
    of a non-empty batch failed; 5 the measurement libraries cannot be imported; 2 an unreadable
    manifest; 3 the memory cannot be used or a database error stopped the run. 1 is left to an
    uncaught crash, which the app must not read as a finished run."""
    import sqlite3
    from . import memory as M
    try:
        manifest = _read_manifest(args.sources) if args.sources else ({}, [], [])
    except (OSError, UnicodeDecodeError) as exc:
        print(f"iqa: cannot read the sources manifest: {exc}", file=sys.stderr)
        return 2
    try:
        mem = M.Memory.open(args.memory)
    except (M.MemoryFileError, sqlite3.Error, OSError) as exc:
        print(f"iqa: cannot use the memory: {exc}", file=sys.stderr)
        return 3
    try:
        return _memory_run(args, files, mem, manifest)
    except sqlite3.Error as exc:
        # A full disk or a damaged file: stop rather than measure photos that cannot be remembered.
        # Each photo is its own transaction, so the ones before this point are remembered intact.
        print(f"iqa: memory database error, stopping: {exc!r}. Photos finished before this point are "
              "remembered; no other photo was marked.", file=sys.stderr)
        return 3
    finally:
        mem.close()


def _memory_run(args: argparse.Namespace, files: list[str], mem, manifest) -> int:
    import sqlite3
    import zlib
    from . import memory as M
    by_path, not_capture, sha_only = manifest
    key = M.analyzer_key(args.max_rois, args.max_side)
    t0 = time.time()
    if mem.moved_aside:
        print(f"memory: the old file was damaged and moved aside to {mem.moved_aside}; starting a new memory")

    # Not-captures are remembered without measuring and are not part of the batch.
    skipped = set()
    for line in not_capture:
        try:
            st = os.stat(line.path)
            hashed_at = time.time()
            sha = M.sha256_file(line.path)
        except OSError as exc:
            print(f"iqa memory: cannot read not-capture {line.path}: {exc}", file=sys.stderr)
            continue
        if line.sha256 is not None and line.sha256 != sha.hex():
            # Not the bytes the app judged: the verdict cannot be tied to this content.
            print(f"iqa memory: not-capture {line.path} does not hash to the app's sha256; not remembered",
                  file=sys.stderr)
            skipped.add(os.path.realpath(line.path))
            _memory_line("failed", sha, line.path)
            continue
        mem.put_status(sha, "not_capture", line.reason, byte_size=st.st_size, file=os.path.basename(line.path),
                       key=key, sources=[M.Source(line.kind, line.locator, signature=line.signature,
                                                  verified_at=hashed_at)] if line.locator else [])
        skipped.add(os.path.realpath(line.path))
        _memory_line("skip", sha, line.path)
    batch = [f for f in files if os.path.realpath(f) not in skipped]
    for real in sorted(set(by_path) - {os.path.realpath(f) for f in batch}):
        print(f"iqa memory: manifest names {real}, which is not in this batch; ignored", file=sys.stderr)
    print(f"iqa {__version__}: analysing {len(batch)} images -> {args.out} (memory {mem.path}, {key})")

    records, failed = [], []
    measured = 0
    analyzer_loaded = False
    for i, f in enumerate(batch, 1):
        name, real, n = os.path.basename(f), os.path.realpath(f), len(batch)
        line = by_path.get(real)
        try:
            st = os.stat(real)
            # Staged copies are known by their manifest source; a file stays where it is, so its
            # real path is a source and its stat key can stand in for the hash.
            sha = None if line else mem.sha_from_stat(real, st)
            hashed_at = None
            if sha is None:
                hashed_at = time.time()
                sha = M.sha256_file(real)
        except OSError as exc:
            failed.append((f, repr(exc)))
            print(f"[{i}/{n}] {name}: FAILED {exc!r}", file=sys.stderr)
            continue
        if line is not None and line.sha256 is not None and line.sha256 != sha.hex():
            # Not the bytes the app staged (replaced or damaged since): measuring them would tie
            # the app's source to another content.
            _failed_photo(failed, i, n, f, sha, "the staged file does not hash to the sha256 the app recorded",
                          False)
            continue
        try:
            if hashed_at is None:
                sources = []            # nothing was verified, so the file source stays as it was
            elif line is not None:
                sources = ([M.Source(line.kind, line.locator, signature=line.signature, verified_at=hashed_at)]
                           if line.locator else [])
            else:
                sources = [M.Source("file", real, M.stat_key(st), verified_at=hashed_at)]

            asset = mem.asset(sha)
            if asset is None:
                state = "miss"
            elif asset.analyzer_key != key:
                state = "stale"
            elif asset.status == "measured":
                state = "hit" if asset.has_record else ("miss" if args.refresh else "archived")
            elif asset.status == "failed" and (args.retry_failed or not asset.final):
                state = "miss"          # a first failure is tried once more: its cause may have passed
            else:
                state = "skip"

            rec = None
            if state == "hit":
                try:
                    rec = _remembered_record(mem, asset, f)
                except (zlib.error, ValueError) as exc:
                    # A stored record that no longer decodes (a damaged blob) is no reason to fail the photo on
                    # every run: its file is here, so it is measured again and the record replaced.
                    print(f"[{i}/{n}] {name}: the remembered record is damaged ({exc!r}); measuring it again",
                          file=sys.stderr)
                    state = "stale"
            if state == "hit" and rec is None:
                # Archived or forgotten by another process since the lookup.
                asset = mem.asset(sha)
                state = "archived" if asset is not None and asset.status == "measured" else "miss"
            if state == "hit":
                mem.touch(sha, sources)
                records.append(rec)
                print(f"[{i}/{n}] {name}: {_summary(rec)} (remembered)")
                _memory_line("hit", sha, f)
                continue
            if state == "archived":
                records.append(_ledger_record(asset, f))
                mem.touch(sha, sources)
                print(f"[{i}/{n}] {name}: (remembered; archived, headline figures only)")
                _memory_line("archived", sha, f)
                continue
            if state == "skip":
                mem.touch(sha, sources)
                what = "not a capture" if asset.status == "not_capture" else f"failed {asset.attempts} times"
                print(f"[{i}/{n}] {name}: (remembered: {what}: {asset.reason})")
                _memory_line("skip", sha, f)
                continue

            if not analyzer_loaded:
                # Checked once, before any photo is measured: without the imaging libraries every
                # photo would fail for the machine's sake, so none is marked and the run stops.
                try:
                    from .analyze import analyze_file  # noqa: F401
                except ImportError as exc:
                    print(f"iqa: the measurement libraries cannot be imported: {exc}; nothing was marked",
                          file=sys.stderr)
                    return 5
                analyzer_loaded = True
            missing = _decoder_missing(f)
            if missing:
                _failed_photo(failed, i, n, f, sha, missing, False)
                continue

            t_wall, t_cpu = time.perf_counter(), time.process_time()
            try:
                rec = _measure(f, args.max_rois, args.max_side)
            except Exception as exc:
                # A failure of the file is remembered (final at the second attempt); one of the
                # machine, or of a file that moved or changed meanwhile, is not.
                wall, cpu = time.perf_counter() - t_wall, time.process_time() - t_cpu
                remember = not _environmental(exc) and _unchanged(real, st)
                if remember:
                    mem.put_status(sha, "failed", repr(exc), byte_size=st.st_size, file=name, key=key,
                                   sources=sources, wall_s=wall, cpu_s=cpu)
                _failed_photo(failed, i, n, f, sha, repr(exc), remember)
                continue
            wall, cpu = time.perf_counter() - t_wall, time.process_time() - t_cpu
            if not _unchanged(real, st):
                # The bytes measured may not be the bytes hashed: remember nothing, so the next run
                # measures the file as it is then.
                _failed_photo(failed, i, n, f, sha, "the file changed or vanished during analysis", False)
                continue
            from .report import detail_dict
            rec["sha256"] = sha.hex()
            rec["analyzer_key"] = key
            mem.put_measured(sha, rec, detail_dict(rec), sources, wall, cpu, rec.get("dhash256"),
                             byte_size=st.st_size, key=key)
            if measured == 0:
                mem.record_provenance()
            measured += 1
            records.append(rec)
            print(f"[{i}/{n}] {name}: {_summary(rec)} ({rec['analysis_s']}s)")
            _memory_line(state, sha, f)
        except sqlite3.Error:
            raise                       # the memory itself: stop the run (exit 3)
        except Exception as exc:  # anything else costs this photo, not the rest of the batch
            _failed_photo(failed, i, n, f, sha, repr(exc), False)

    for line in sha_only:
        if not mem.add_source(bytes.fromhex(line.sha256), line.kind, line.locator, signature=line.signature):
            print(f"iqa memory: unknown sha256 {line.sha256} for {line.kind} {line.locator}; ignored", file=sys.stderr)
    rep = mem.compact()
    mem.set_meta("current_analyzer_key", key)
    print(f"memory: {measured} measured, {len(records) - measured} remembered, {len(failed)} failed; "
          f"compacted ({rep['folded']} records archived, {rep['details_dropped']} details dropped)")
    if not records:
        print("no records to write", file=sys.stderr)
        # 4, not 1: an uncaught crash exits 1, and the app must never read a crash as a finished run.
        return 4 if batch and len(failed) == len(batch) else 0
    _write_outputs(args, records, failed, t0)
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
                            max_rois=30, max_side=None, title="iqa demo on synthetic scenes", no_paths=False,
                            no_report=False, memory=None, sources=None, refresh=False, retry_failed=False)
    rc = cmd_analyze(ns)
    print("\nground truth:  file | expected MTF50 | expected luma noise (8-bit)")
    for name, m, nz in truth:
        print(f"  {name} | {m:.4f} | {nz:.2f}")
    return rc


def cmd_chart(args: argparse.Namespace) -> int:
    """Chart mode: colour accuracy on a ColorChecker Classic and/or sharpness across the field
    on an e-SFR chart of slanted squares, whichever the image contains."""
    import json
    import numpy as np
    from .chart_sfr import measure_esfr_chart
    from .color import COLORCHECKER_NAMES, find_colorchecker, measure_colorchecker
    from .imageio import load_image
    img = load_image(args.image)
    out: dict = {"file": args.image}
    found = 0

    cc = None if args.esfr_only else find_colorchecker(img.rgb8)
    if cc is not None:
        found += 1
        m = measure_colorchecker(img.rgb8, cc)
        print(f"ColorChecker found: patch pitch {cc.patch_px:.0f} px, corners "
              + " ".join(f"({x:.0f},{y:.0f})" for x, y in cc.box))
        print(f"dE00 mean {m.de00_mean:.2f}  max {m.de00_max:.2f}  chromatic {m.de00_chromatic_mean:.2f}  "
              f"neutral {m.de00_neutral_mean:.2f}   WB error R/G {m.wb_r_over_g_stops:+.2f} stops, B/G {m.wb_b_over_g_stops:+.2f} stops")
        print(f"{'patch':14s} {'measured sRGB':>16s}  {'L*':>6s} {'a*':>6s} {'b*':>6s}   dE00")
        for i, name in enumerate(COLORCHECKER_NAMES):
            r, g, b = m.measured_srgb[i]; L, a, bb = m.measured_lab[i]
            print(f"{name:14s} {r:5.0f} {g:5.0f} {b:5.0f}  {L:6.1f} {a:6.1f} {bb:6.1f}   {m.de00[i]:.2f}")
        out.update({"cc_box": cc.box.tolist(), "cc_patch_px": cc.patch_px, "cc_names": COLORCHECKER_NAMES, **m.as_dict()})
    elif not args.esfr_only:
        print("no ColorChecker found")

    es = None if args.cc_only else measure_esfr_chart(img.lin_luma)
    if es is not None and es.n_squares:
        found += 1
        print(f"e-SFR chart: {es.n_squares} slanted squares, {es.n_edges} valid edges"
              + (f", rejected {es.reject_reasons}" if es.reject_reasons else ""))
        print(f"MTF50 median {es.mtf50_median:.4f} c/px   centre {es.mtf50_center_median:.4f}   outer {es.mtf50_outer_median:.4f}   "
              f"radial {es.mtf50_radial_median:.4f}   tangential {es.mtf50_tangential_median:.4f}   "
              f"MTF50P {es.mtf50p_median:.4f}   overshoot {es.overshoot_median_pct:.1f} %")
        print(f"{'square':>6s} {'x':>6s} {'y':>6s} {'r':>5s} {'edges':>5s} {'MTF50 mean':>10s}")
        for i, sq in enumerate(es.squares):
            print(f"{i:6d} {sq.centre[0]:6.0f} {sq.centre[1]:6.0f} {sq.radius:5.2f} {len(sq.edges):5d} {sq.mtf50_mean:10.4f}")
        out.update(es.as_dict())
    elif not args.cc_only:
        print("no e-SFR chart (slanted squares) found")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(out, fh, indent=1)
        print(f"json -> {args.json}")
    if args.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        panels = 1 + (cc is not None) + (es is not None and es.n_squares > 0)
        fig, axes = plt.subplots(1, panels, figsize=(6 * panels, 5.5))
        axes = np.atleast_1d(axes)
        ax = axes[0]; ax.imshow(img.rgb8); ax.set_title("detections"); ax.axis("off")
        k = 1
        if cc is not None:
            ax.plot(*np.vstack([cc.box, cc.box[:1]]).T, "y-", lw=1.5)
            ax.scatter(cc.centres[:, 0], cc.centres[:, 1], s=10, c="yellow")
            from .color import COLORCHECKER_LAB, lab_to_srgb8
            ref = lab_to_srgb8(COLORCHECKER_LAB)
            tile = np.zeros((4 * 60, 6 * 60, 3), dtype=np.uint8)
            for i in range(24):
                r0, c0 = (i // 6) * 60, (i % 6) * 60
                tile[r0:r0 + 60, c0:c0 + 30] = np.clip(m.measured_srgb[i], 0, 255).astype(np.uint8)
                tile[r0:r0 + 60, c0 + 30:c0 + 60] = ref[i]
                dark = m.measured_lab[i][0] < 55
                axes[k].text(c0 + 30, r0 + 55, f"{m.de00[i]:.1f}", ha="center", fontsize=8, color="w" if dark else "k")
            axes[k].imshow(tile); axes[k].set_title(f"measured | reference, dE00 (mean {m.de00_mean:.2f})"); axes[k].axis("off")
            k += 1
        if es is not None and es.n_squares:
            for sq in es.squares:
                for e in sq.edges:
                    ax.add_patch(plt.Rectangle((e.x0, e.y0), e.w, e.h, fill=False, ec="cyan", lw=0.8))
            xs = [sq.centre[0] for sq in es.squares]; ys = [sq.centre[1] for sq in es.squares]
            vals = [sq.mtf50_mean for sq in es.squares]
            sc = axes[k].scatter(xs, ys, c=vals, s=240, cmap="viridis", edgecolor="k")
            for x, y, v in zip(xs, ys, vals):
                axes[k].text(x, y, f"{v:.3f}", ha="center", va="center", fontsize=7, color="w")
            axes[k].set_xlim(0, img.width); axes[k].set_ylim(img.height, 0); axes[k].set_aspect("equal")
            axes[k].set_title("MTF50 across the field (c/px, mean of 4 edges)"); plt.colorbar(sc, ax=axes[k], fraction=0.046)
        fig.tight_layout(); fig.savefig(args.plot, dpi=130)
        print(f"plot -> {args.plot}")
    return 0 if found else 1


def cmd_report(args: argparse.Namespace) -> int:
    """Rebuild charts and report.md from an existing results.json without re-analysing."""
    import json
    from .report import rehydrate, strip_paths, write_charts, write_csv, write_markdown

    with open(args.json) as fh:
        records = json.load(fh)
    if args.no_paths:
        records = strip_paths(records)
    rehydrate(records)
    out = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out, exist_ok=True)
    write_csv(records, os.path.join(out, "results.csv"))
    charts = write_charts(records, os.path.join(out, "charts"))
    write_markdown(records, charts, os.path.join(out, "report.md"), title=args.title)
    print(f"rebuilt {len(charts)} charts and report.md in {out} from {len(records)} records")
    return 0


def _mib(n: int) -> str:
    return f"{n / 1048576:.1f} MiB"


def cmd_memory(args: argparse.Namespace) -> int:
    """The memory's own commands. The analyzer is the memory's only writer; IQ Coach runs these
    for its Settings screen."""
    import json
    import re
    import sqlite3
    from . import memory as M
    if args.mcmd == "key":
        print(M.analyzer_key(args.max_rois, args.max_side))
        return 0
    if not os.path.exists(args.db):
        print(f"iqa memory: no memory at {args.db}", file=sys.stderr)
        return 2
    sha = None
    if args.mcmd == "forget" and args.sha is not None:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha):
            print("iqa memory: --sha takes the 64 hex digits of a SHA-256", file=sys.stderr)
            return 2
        sha = bytes.fromhex(args.sha)
    try:
        with M.Memory.open(args.db, create=False) as mem:
            if args.mcmd == "stats":
                st = mem.stats()
                if args.json:
                    print(json.dumps(st, indent=1))
                    return 0
                t = st["tiers"]
                print(f"memory {st['path']} ({_mib(st['file_bytes'])} on disk)")
                print(f"  ledger   {t['ledger']['assets']:,} photos, {t['ledger']['sources']:,} sources, "
                      f"{_mib(t['ledger']['bytes'])}")
                print(f"  records  {t['record']['count']:,}, {_mib(t['record']['bytes'])} "
                      f"(window {st['window']} per camera)")
                print(f"  detail   {t['detail']['count']:,}, {_mib(t['detail']['payload_bytes'])} of "
                      f"{_mib(st['detail_budget_bytes'])}")
                print(f"  archive  {t['archive']['buckets']:,} buckets holding {t['archive']['photos']:,} photos, "
                      f"{_mib(t['archive']['bytes'])}")
                s = st["status"]
                print(f"  status   {s['measured']:,} measured, {s['failed']:,} failed, {s['not_capture']:,} not "
                      f"captures; {st['stale']:,} measured with an earlier method")
                print(f"  captures {st['oldest_capture']} to {st['newest_capture']}")
                print(f"  analyzer {st['code_analyzer_key']} (last run {st['current_analyzer_key']})")
                for cam in st["cameras"]:
                    print(f"    {cam['camera'] or '(no camera model)'}: {cam['measured']:,} photos "
                          f"({cam['records']:,} records, {cam['archived']:,} archived), "
                          f"{cam['oldest_capture']} to {cam['newest_capture']}")
            elif args.mcmd == "compact":
                budget = None if args.detail_mb is None else int(round(args.detail_mb * 1048576))
                rep = mem.compact(window=args.window, detail_budget=budget)
                print(f"compacted: {rep['folded']} records archived into {rep['buckets_touched']} buckets, "
                      f"{rep['details_dropped']} details dropped over the budget; window {rep['window']}, "
                      f"detail budget {_mib(rep['detail_budget_bytes'])}; "
                      f"{_mib(rep['bytes_before'])} -> {_mib(rep['bytes_after'])}")
            elif args.mcmd == "forget":
                rep = mem.forget(camera=args.camera, before=args.before, sha=sha, all=args.all)
                print(f"forgot {rep['assets']:,} photos; {rep['buckets_deleted']:,} archive buckets deleted, "
                      f"{rep['buckets_adjusted']:,} photos taken out of the buckets that stay")
            elif args.mcmd == "export":
                n = mem.export(args.out, camera=args.camera)
                print(f"exported {n} records -> {args.out}")
    except ValueError as exc:
        print(f"iqa memory: {exc}", file=sys.stderr)
        return 2
    except (M.MemoryFileError, sqlite3.Error) as exc:
        print(f"iqa memory: {exc}", file=sys.stderr)
        return 3
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
    a.add_argument("--no-report", action="store_true", help="write results.json and results.csv only (no charts, no report.md)")
    a.add_argument("--memory", default=None, metavar="DB",
                   help="remember measurements in this SQLite file and reuse them for byte-identical photos")
    a.add_argument("--sources", default=None, metavar="FILE",
                   help="JSON Lines manifest of where each staged photo came from (written by IQ Coach)")
    a.add_argument("--refresh", action="store_true", help="with --memory: measure archived photos again")
    a.add_argument("--retry-failed", action="store_true",
                   help="with --memory: measure photos that failed before again, also those that failed twice")
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

    c = sub.add_parser("chart", help="chart mode: ColorChecker colour accuracy (CIEDE2000, white balance) and/or e-SFR slanted-square sharpness across the field")
    c.add_argument("image")
    c.add_argument("--cc-only", action="store_true", help="only look for a ColorChecker")
    c.add_argument("--esfr-only", action="store_true", help="only look for slanted squares")
    c.add_argument("--json", default=None, help="write the per-patch results to this JSON file")
    c.add_argument("--plot", default=None, help="write a detection + swatch comparison PNG")
    c.set_defaults(func=cmd_chart)

    d = sub.add_parser("demo", help="synthetic end-to-end run with known ground truth")
    d.add_argument("--out", default="results_demo")
    d.set_defaults(func=cmd_demo)

    mp = sub.add_parser("memory", help="what the analyzer remembers: stats, compact, forget, export, key")
    msub = mp.add_subparsers(dest="mcmd", required=True)
    ms = msub.add_parser("stats", help="counts and bytes per tier, oldest and newest capture, per camera")
    ms.add_argument("db")
    ms.add_argument("--json", action="store_true")
    mc = msub.add_parser("compact", help="archive records beyond the window, trim detail, reclaim space")
    mc.add_argument("db")
    mc.add_argument("--window", type=int, default=None, help="records kept per camera (saved)")
    mc.add_argument("--detail-mb", type=float, default=None, help="detail budget in MiB (saved)")
    mf = msub.add_parser("forget", help="forget a camera, photos before a date, one photo, or everything")
    mf.add_argument("db")
    which = mf.add_mutually_exclusive_group(required=True)
    which.add_argument("--camera", default=None,
                       help="the measured photos of this camera model as recorded ('' for photos without one); "
                            "failed and not-capture verdicts stay")
    which.add_argument("--before", default=None, metavar="YYYY-MM-DD", help="photos captured before this date")
    which.add_argument("--sha", default=None, metavar="HEX", help="one content, by its SHA-256")
    which.add_argument("--all", action="store_true", help="everything (the settings stay)")
    me = msub.add_parser("export", help="write the window as a results.json, for iqa report")
    me.add_argument("db")
    me.add_argument("--out", required=True)
    me.add_argument("--camera", default=None)
    mk = msub.add_parser("key", help="print the current analyzer key")
    mk.add_argument("--max-rois", type=int, default=30)
    mk.add_argument("--max-side", type=int, default=None)
    mp.set_defaults(func=cmd_memory)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
