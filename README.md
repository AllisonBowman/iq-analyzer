# iq-analyzer

Image-quality analysis of real photographs: sharpness (ISO 12233-style slanted-edge MTF),
noise and SNR, an output-referred dynamic-range estimate, clipping, and colour statistics,
with CSV/JSON output, charts and a markdown report. Reads RAW (CR2/NEF/ARW/DNG/RAF…),
JPEG, HEIC, PNG and TIFF.

Built to be checked, not just plausible: every measurement is validated against synthetic
images with known ground truth (`tests/`), and `iqa demo` reproduces that check end to end.

## Quick start

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest -q                      # 51 tests: SFR vs analytic Gaussian MTF, noise vs injected sigma, ...
python -m iqa demo --out results_demo    # synthetic scenes with known blur/noise, analysed end to end
python -m iqa analyze ~/Pictures/export --out results --sample 60 -r
open results/report.md
```

Measure one slanted edge (for a printed ISO 12233 chart or a known edge in a photo):

```bash
python -m iqa sfr photo.jpg --roi 1820,940,64,110 --plot edge.png
```

## What it measures

| metric | method | validated by |
| --- | --- | --- |
| MTF50, MTF50P, MTF30, MTF at Nyquist, 10-90 % rise | ISO 12233:2014 e-SFR: per-row sub-pixel edge location, line fit, 4x oversampled ESF, Hamming-windowed LSF, FFT, derivative correction (`iqa/sfr.py`) | synthetic Gaussian-blurred edges: MTF50 within 4 % (noise-free) / 6 % (1 % noise) of the analytic value, across blur 0.7-2.5 px and slant 3-11 degrees |
| In-focus and overall sharpness per photo | Canny + Hough find slanted straight edges; each ROI is measured; the 80th percentile of MTF50 = in-focus sharpness, median = overall (`iqa/edges.py`) | synthetic scenes: median MTF50 within 8 % of truth; blurrier scenes measure softer |
| Luma/chroma noise, SNR at mid-grey, noise-vs-signal curve | flat-patch selection with gradient removal and a texture test; lower-envelope noise floor per brightness bin (`iqa/noise.py`) | injected Gaussian noise of 2, 5, 10 (8-bit) recovered within 12 %; a fine-texture patch does not inflate the figure |
| Dynamic range at SNR 1/2/4/10 (stops) | scene-linear SNR from the noise curve through the sRGB EOTF slope; output-referred | monotonic with injected noise |
| Clipping, tonal range, colorfulness, gray-world WB, saturation | histogram statistics (`iqa/exposure.py`) | synthetic clipped blocks counted correctly |

Limits worth knowing: natural edges are not chart edges, so absolute MTF50 is a consistent
*relative* measure (great for comparing lenses, focus, shake, sharpening, and processing across
images); single-frame noise cannot be separated from fine texture with certainty, which the
lower-envelope estimate mitigates but does not remove; dynamic range of a processed JPEG is
bounded by its tone curve.

## Layout

```
iqa/imageio.py   loading + EXIF, sRGB <-> linear
iqa/sfr.py       slanted-edge SFR (the core)
iqa/edges.py     natural-edge finder + per-image sharpness summary
iqa/noise.py     noise / SNR / dynamic range
iqa/exposure.py  clipping and colour statistics
iqa/analyze.py   one image -> flat record
iqa/report.py    CSV, JSON, charts, report.md
iqa/cli.py       `python -m iqa analyze | sfr | demo`
iqa/synth.py     synthetic ground-truth images
tests/           51 tests
```
