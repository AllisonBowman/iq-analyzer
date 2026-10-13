# CLAUDE.md — iq-analyzer

## Why this project exists

Allison is applying for **Apple — Camera & Photos, Image Quality Engineer** (req 200686669,
https://jobs.apple.com/en-us/details/200686669-0836/camera-and-photos-image-quality-engineer?team=SFTWR,
posted Sep 30 2026). The posting's minimum qualifications ask for automation built with coding
harnesses like Claude Code, Python/MATLAB, photography knowledge, imaging-pipeline familiarity,
and ISO image-quality metrics. This repo is the portfolio artifact that turns the one gap (ISO IQ
metrics) into a demonstrated strength, measured on his own photographs. It was scaffolded
overnight on 2026-10-13 by Claude from a cloud session; Claude Code on this Mac continues it.

Keep that audience in mind: a camera-team engineer will read this code. Prefer correctness,
clear method notes with the ISO reference, and validation against ground truth over features.

## State of the project (as of 2026-10-13 ~03:00 ET)

Done and validated (51 tests pass: `python3 -m pytest -q`):
- `iqa/sfr.py` ISO 12233 e-SFR slanted-edge MTF. Validated against analytic Gaussian MTF:
  within 4 % noise-free, 6 % with 1 % noise. Key robustness fixes already made: per-row edge
  location uses the *signed* derivative inside a window scaled to the edge width (|noise|
  centroids bias the slope); sparse corner bins are dropped; the LSF peak is found on a smoothed
  |LSF|.
- `iqa/edges.py` natural-edge finder (Canny sigma-2 + probabilistic Hough, slant 1.5-12 deg,
  quality filters on contrast / plateau flatness / fit residual / rise width).
- `iqa/noise.py` flat-patch noise with gradient removal, texture rejection (smoothed-residual
  ratio < 0.30), lower-envelope noise floor per brightness bin, SNR at mid-grey (sRGB 118),
  chroma noise, output-referred DR at SNR 1/2/4/10.
- `iqa/exposure.py`, `iqa/imageio.py` (RAW via rawpy, HEIC via pillow-heif, EXIF via Pillow +
  exifread), `iqa/report.py` (CSV/JSON/charts/report.md), `iqa/cli.py` (`analyze`, `sfr`, `demo`).
- `results_demo/` is the synthetic end-to-end run with ground truth printed by `iqa demo`.

Not done yet:
- **Run on Allison's real photos.** His library is Apple Photos:
  `~/Pictures/Photos Library.photoslibrary/originals/**` (HEIC/JPEG/DNG). macOS needs a one-time
  "allow access to Photos" approval for the process that reads it; the overnight session was
  blocked on that prompt behind the lock screen. See "First task" below.
- No chart mode beyond `iqa sfr --roi` (no automatic ColorChecker / ISO 12233 chart detection).
- Not packaged (`pyproject.toml` is minimal); no CI.

## Environment on this Mac

- Python: `/opt/homebrew/bin/python3` (3.14). Create a venv in the repo: `python3 -m venv .venv &&
  source .venv/bin/activate && pip install -r requirements.txt`. If a wheel is missing for 3.14
  (rawpy, pillow-heif, opencv), use `brew install python@3.12` and build the venv with that.
- Do not read the Photos library in place with `find` across all of it: it is large. Build a
  file list once (`find "…/originals" -type f \( -iname '*.heic' -o -iname '*.jpg' -o -iname
  '*.jpeg' -o -iname '*.dng' \) > photo_list.txt`) and sample from that.
- Never modify anything inside the Photos library. Read only. Write results to `results/`.

## First task for Claude Code (the morning prompt)

> Set up the venv, run the tests, then run `python -m iqa analyze` on a 60-image random sample
> from `~/Pictures/Photos Library.photoslibrary/originals` (recursive, seed 1) into `results/`.
> If macOS asks for Photos access, I'll click Allow. Then read `results/report.md`, sanity-check
> five images by eye against their numbers (open the sharpest, softest, noisiest), and write a
> short `results/FINDINGS.md`: which camera/lens/ISO combinations are sharpest and cleanest,
> anything surprising, and any metric that looks wrong. Do not change the measurement code to
> make numbers look better; if a metric is wrong, say so and propose the fix.

## Roadmap (in priority order)

1. Real-photo run + FINDINGS.md (above). This is what goes in the application.
2. Per-lens / per-camera comparison charts (MTF50 and SNR vs ISO, grouped by `camera_model` and
   `lens`), and MTF50 across the frame (centre vs edge ROIs) for lens-softness maps.
3. Chart mode: detect an ISO 12233:2014 e-SFR chart or a ColorChecker in a photo; add colour
   accuracy (ΔE2000 vs reference patches) and white-balance error. This completes the ISO
   metric set the posting names.
4. HEIC vs RAW (DNG) pairs from the same shot: quantify what the iPhone pipeline does to noise,
   sharpening (MTF50P vs MTF50 overshoot) and dynamic range.
5. A one-page write-up with the three best charts, for the application and LinkedIn.
6. Packaging (`pip install -e .`), CI running the tests, type hints clean under mypy.

## Conventions

- Measurements on *linear* data for SFR (ISO 12233), on *display-referred* sRGB for noise and
  clipping so RAW and JPEG are comparable. Keep that split.
- Every new metric gets a synthetic ground-truth test in `tests/` before it ships.
- Report both the number and its caveat in `report.md` ("How to read these numbers").
- Commit messages: imperative, one line, what and why.
