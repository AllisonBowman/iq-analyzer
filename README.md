# iq-analyzer

Image-quality analysis of real photographs: sharpness (ISO 12233-style slanted-edge MTF),
noise and SNR, an output-referred dynamic-range estimate, clipping, and colour statistics,
with CSV/JSON output, charts and a markdown report. Reads RAW (CR2/NEF/ARW/DNG/RAF…),
JPEG, HEIC, PNG and TIFF.

Built to be checked, not just plausible: every measurement is validated against synthetic
images with known ground truth (`tests/`, 64 tests), `iqa demo` reproduces that check end to
end, and the tool reports what it could *not* measure (clipped or shaded edges, extrapolated
noise levels, dynamic-range lower bounds) instead of printing a number anyway. A first
adversarial review by a separate Claude Code session (`REVIEW.md`) found 13 issues; the
correctness ones are fixed and pinned by `tests/test_adversarial.py`, the methodology caveats
are stated in the report's "How to read these numbers".

## Quick start

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest -q                      # 88 tests: SFR vs analytic MTF (with pixel aperture), noise vs injected sigma, CIEDE2000 vs the published pairs, synthetic charts, adversarial cases
python -m iqa demo --out results_demo    # synthetic scenes with known blur/noise, analysed end to end
python -m iqa analyze ~/Pictures/export --out results --sample 60 -r
open results/report.md
```

Measure one slanted edge (for a printed ISO 12233 chart or a known edge in a photo):

```bash
python -m iqa sfr photo.jpg --roi 1820,940,64,110 --plot edge.png
```

Chart mode: a photograph of a ColorChecker Classic and/or an e-SFR chart of slanted squares
(both are found automatically; `--cc-only` / `--esfr-only` to restrict):

```bash
python -m iqa chart chart_shot.heic --plot chart.png --json chart.json
```

## What it measures

| metric | method | validated by |
| --- | --- | --- |
| MTF50, MTF50P, MTF30, MTF at Nyquist, 10-90 % rise, overshoot | ISO 12233:2014 e-SFR: per-row sub-pixel edge location (signed-derivative centroid), line fit, 4x oversampled ESF, shared-shading removal, clamped Hamming-windowed LSF, FFT, derivative correction (`iqa/sfr.py`) | Gaussian-blurred edges rendered *through a 100 %-fill pixel aperture* (truth = Gaussian x sinc): MTF50 within 1.5 % and the whole curve within 0.02; point-sampled edges within 4 % (6 % at 1 % noise) across blur 0.7-2.5 px and slant 1.5-14 degrees; sharpening halo shows as overshoot and MTF50P < MTF50 |
| In-focus and overall sharpness per photo, centre vs outer frame, horizontal vs vertical | Canny + Hough find slanted straight edges; each ROI is measured and kept only if its ESF is a valid step (no clipping, step >= 0.04, edge SNR >= 20, shading < 0.4 of step, contrast <= 1); p80 of MTF50 = in-focus, median = overall (`iqa/edges.py`) | synthetic scenes: median MTF50 within 8 % of truth; a blown-out square's edges are rejected as clipped; ROIs do not overlap |
| Luma/chroma noise, SNR at mid-grey, noise-vs-signal curve, noise whiteness | flat-patch selection with gradient removal and an *adaptive* texture test; lower-envelope noise floor per brightness bin (`iqa/noise.py`) | injected Gaussian noise of 2, 5, 10 (8-bit) recovered within 12 %; spatially correlated (noise-reduced) noise still measured within 20 % and reported as non-white; a fine-texture patch does not inflate the figure; mid-grey extrapolation is flagged |
| Dynamic range at SNR 1/2/4/10 (stops) | scene-linear SNR from the noise curve through the sRGB EOTF slope, scanning down from white; output-referred; lower bounds flagged | monotonic with injected noise; a noisy mid-tone band stops the scan where it should |
| Clipping, tonal range, colorfulness, gray-world WB (linear, in stops), saturation | histogram statistics (`iqa/exposure.py`) | synthetic clipped blocks counted correctly |
| Periodic texture in the noise patches (screens, weaves, halftone) | averaged unit-power patch spectra, annular then directional baseline, peak > 6 flags the image and excludes the patches when they are a minority (`iqa/noise.py`) | white / pink / smoothed / anisotropic / JPEG-blocked noise not flagged; a 4-px grid at noise amplitude, a half-amplitude slanted weave and a screen on 11 % of the frame flagged with the frequency recovered within one bin |
| Colour accuracy on a ColorChecker Classic: CIEDE2000 per patch, mean / max / chromatic / neutral, white-balance error in stops | OpenCV's ColorChecker detector plus a patch-centroid homography refit; sRGB -> XYZ -> Bradford D50 -> L*a*b* against the chart's reference values (`iqa/color.py`) | CIEDE2000 reproduces all 34 published Sharma-Wu-Dalal test pairs to 1e-4; a rendered chart through perspective, blur, noise and JPEG: centres within 4 px, dE00 < 1 on every in-gamut patch (cyan is outside sRGB); a 0.3-stop red gain in linear light reads as +0.30 stops |
| Sharpness across the field on an e-SFR chart: per-square MTF50, centre vs outer, radial vs tangential | Otsu + contour squares with a 2-15 degree slant; all four sides measured with the same e-SFR code (`iqa/chart_sfr.py`) | a rendered 5x5 chart with a known Gaussian blur: all 25 squares and 100 edges found, every edge within 6 % of the analytic MTF50; a field-dependent blur reproduces each square's own blur within 8 % and orders centre before corners |
| Colour management | embedded ICC profiles (Display P3 iPhone HEICs, Adobe RGB JPEGs) are converted to sRGB before any measurement (`iqa/imageio.py`) | sRGB-tagged and untagged paths tested; P3 conversion to be confirmed on the real HEIC run |

Limits worth knowing: natural edges are not chart edges, so every MTF50 is a scene-dependent
lower bound on the system MTF and a consistent *relative* measure (lenses, focus, shake,
sharpening, processing); frequencies are cycles/px along the edge normal; the p80 "in-focus"
summary needs at least a fifth of the edges in focus; single-frame noise cannot be separated from
fine texture with certainty, the lower-envelope estimate mitigates that; noise is output-referred,
so NR and compression lower it as much as the sensor does; 8-bit quantisation caps SNR near 52 dB;
dynamic range of a processed JPEG is bounded by its tone curve and by whether the frame has
near-black flat areas.

## IQ Coach, the Mac app

`mac/IQCoach/` is a SwiftUI app (macOS 15, Swift 6, Swift Charts) that reads `results.json` and
coaches: per camera, what it does well and badly and what to change when shooting (ISO ceiling,
lens choice, corner softness, highlight discipline, sharpening, colour lean, slow-shutter softness),
and per photo, what to do in Apple Photos, Lightroom or any editor to get the best out of it. Every
metric is shown with a plain-language meaning, a band word and colour, and a scale. Build with
`cd mac/IQCoach && xcodegen generate && xcodebuild -scheme IQCoach -project IQCoach.xcodeproj build`;
see `mac/IQCoach/README.md`. The spec is `docs/APP-IQ-COACH-SPEC.md`.

## Layout

```
iqa/imageio.py   loading + EXIF, sRGB <-> linear
iqa/sfr.py       slanted-edge SFR (the core)
iqa/edges.py     natural-edge finder + per-image sharpness summary
iqa/noise.py     noise / SNR / dynamic range
iqa/exposure.py  clipping and colour statistics
iqa/color.py     ColorChecker detection, CIEDE2000, white-balance error
iqa/chart_sfr.py e-SFR chart (slanted squares) sharpness across the field
iqa/analyze.py   one image -> flat record
iqa/report.py    CSV, JSON, charts, report.md
iqa/cli.py       `python -m iqa analyze | sfr | chart | report | demo`
iqa/synth.py     synthetic ground-truth images (edges, scenes, both charts)
media/           the narrated explainer video generator
mac/IQCoach/     the macOS coaching app (SwiftUI; 43 tests)
tests/           88 tests (test_adversarial.py pins the review's findings)
```

## License

MIT, see `LICENSE`.
