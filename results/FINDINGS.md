# Findings — Allison's Photos library, all 389 camera captures

Run: 2026-10-13 08:48 ET, `python -m iqa analyze --list captures.txt`, 389 images from 19 devices
(iPhone 17 Pro Max 206, iPhone 13 85, Nikon D850 36, iPhone XR 21, 8 older iPhones, SeaLife DC2000 5,
two Canon PowerShots), 578 s, 0 failures. `captures.txt` is every file in the library with an EXIF camera
model and at least 5 MP (1,035 files total; the other 646 are screenshots, saved images and thumbnails).
328 of 389 files carried a Display P3 profile and were converted to sRGB before measurement.

Five images were checked by eye against their numbers before writing this (the sharpest, the softest,
the two noisiest, the most clipped); see "Metrics I do not trust" for what that found.

## 1. The headline: phones flatten noise against ISO; the DSLR does not

`charts/snr_vs_iso_by_camera.png`

| camera | ISO ≤ 64 | 65–160 | 161–400 | 401–1000 | > 1000 | noise whiteness |
| --- | --- | --- | --- | --- | --- | --- |
| Nikon D850 (n=33) | 42.5 dB (3) | 39.1 (10) | 37.8 (5) | 35.8 (11) | 33.9 (4) | 0.20–0.30 |
| iPhone 17 Pro Max (n=172) | 33.3 (47) | 32.0 (73) | 36.7 (28) | 36.8 (16) | 30.8 (8) | 0.44–0.49 |
| iPhone 13 (n=79) | 33.1 (54) | 33.5 (9) | 30.5 (6) | 35.4 (5) | 31.3 (5) | 0.20–0.49 |

SNR at mid-grey, output-referred, medians with n in parentheses; rows exclude frames flagged as extrapolated or texture-suspect.

- The D850's in-camera JPEGs behave like a sensor: SNR falls monotonically, about 2 dB per ISO
  doubling, and the residual noise is close to white (whiteness 0.20 above ISO 160, where 0.14 is
  pure white noise). What the tool measures there is sensor noise.
- The iPhone 17 Pro Max does not: mid-ISO frames (161–1000) are 3–4 dB *cleaner* than base-ISO
  frames, and whiteness sits at 0.45–0.49 at every ISO, i.e. the noise has been spatially smoothed.
  Read together, that says the pipeline's noise reduction scales with ISO and holds output noise
  roughly constant, and at base ISO the "noise" the tool sees is mostly residual fine texture and
  compression, not sensor noise. Chroma noise is 0.4–0.6 (8-bit) everywhere: chroma NR is strong.
- The iPhone 13's noise is less smoothed (whiteness 0.27 at base ISO vs 0.47 on the 17 Pro Max)
  at the same SNR, consistent with a lighter-touch pipeline on the older phone.

Consequence for the tool: output-referred SNR compares *pipelines*, not sensors, across these
cameras. It is a valid comparison between the two iPhones' processing, and a valid sensor
measurement for the D850, but "the D850 is 6 dB cleaner than the 17 Pro Max at ISO 100" is a
statement about NR tuning, not photons.

## 2. Resolution: compare line widths per picture height, not cycles per pixel

`charts/lwph_by_camera.png` (73 images with ≥ 3 valid edges)

| camera | n | MTF50 p80 (c/px) | MTF50 p80 (LW/PH) | MP | centre / outer (c/px) | overshoot |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone 17 Pro Max | 43 | 0.252 | 2608 | 24.5 | 0.274 / 0.153 | 10.7 % |
| iPhone 13 | 20 | 0.308 | 2429 | 12.2 | 0.293 / 0.209 | 16.4 % |
| iPhone XR | 3 | 0.279 | 2247 | 12.2 | 0.274 / 0.175 | 12.7 % |

- Per pixel, the 12 MP iPhone 13 looks sharper (0.308 vs 0.252 c/px). In line widths per picture
  height the 24 MP 17 Pro Max resolves 7 % more (2608 vs 2429). Spreading similar optical resolution
  over twice the pixels lowers the per-pixel number while raising the total: the classic reason
  camera teams report LW/PH across sensors.
- Centre-to-outer falloff is steeper on the 17 Pro Max (0.274 → 0.153, −44 %) than the 13
  (0.293 → 0.209, −29 %). Caveat: outer-frame edges are also more often out of the focal plane in
  casual photos, so this mixes lens falloff with depth of field.
- Sharpening halo: the iPhone 13 overshoots its edges by 16 % of the step, the 17 Pro Max by 11 %
  (max seen 61 %). MTF50P/MTF50 ≈ 0.93 on both: about 7 % of the per-pixel MTF50 is sharpening.
- Nikon D850: 36 frames, only 4 with any valid edge and none with three. These are surf and
  ocean photographs; there are no straight slanted edges in water. No D850 sharpness figure,
  by design, rather than a bad one.

## 3. Dynamic range: usable only where the frame has deep shadows

The noise floor was reached in 72 of 389 frames (18 %); the other 317 only give a lower bound and
are excluded from the medians. Where measured: iPhone 17 Pro Max 7.2 stops (n=36), iPhone 13 6.4
(n=17), iPhone XR 5.8 (n=10) at SNR 4, output-referred. The D850 reached the floor in 1 frame of
36: its JPEG shadows sit above the floor almost everywhere, so its DR is "≥ 8.6 stops" and not
comparable here. Cross-camera DR from this run is a scene statement, not a sensor statement.

## 4. Rendering

- Highlight clipping: median 0.81 % of pixels on the 17 Pro Max, 0.02 % on the D850. The D850's
  worst frame (14 %) is a blown overcast sky behind a portrait, checked by eye: correct, and the
  photographer's choice.
- Colour: gray-world balance is near neutral on the D850 (B/G −0.01 stop, R/G −0.05) and warm on
  the 17 Pro Max (B/G −0.17 stop); colorfulness 38.6 vs 21.0. The iPhone renders noticeably more
  saturated than the D850's standard JPEG profile. For ocean work this is a look, not an error.

## 5. Metrics I do not trust, and why

1. **Photos of screens read as noise: resolved by a spectral detector (second run, 13:56 ET).** The
   whiteness flag (> 0.7) catches smooth, heavily noise-reduced frames and 21 coarse screen photos, but a
   fine pixel grid photographed at noise amplitude has a *white-looking* residual (whiteness 0.10-0.16) and
   passed. `noise_spectral_peak` now averages the unit-power spectrum of every candidate patch, divides by
   the annulus median (radial envelope) and by the larger of the row and column medians at 2-4 bins (so an
   axis ridge from demosaicing, JPEG or oriented texture scores ~1), and takes the maximum over radius >= 3
   cycles/patch outside the Nyquist row and column. Threshold 6 is the geometric midpoint of the measured
   gap: the largest ordinary file scores 3.2, the weakest screen 11.3. On the full library it flags 6 of
   389 and nothing else: four screen photos at 11-127 (ISO 64-125, SNR 21-34 dB, one of which had sat in
   the noisiest-valid list at 20.8 dB), and two consecutive shots of a vehicle with striped bodywork at 8.3
   (a 5-px diagonal period on 10 % of the frame, excluded under the minority rule so the rest measures;
   the SNR of one screen photo moved 31.6 -> 32.7 dB the same way). The two flags are complementary and
   neither subsumes the other. The remaining 383 rows are byte-identical to the first run apart from the
   four new columns. A first version with a 7x7 block-median baseline had produced four false positives
   at 8-12 (a D850 water frame with a vertical ridge at the lowest radius, a SeaLife with demosaic energy on
   the Nyquist row and column, two iPhones with axis ridges next to Nyquist); looking at them produced the
   directional baseline. Tests: `tests/test_periodic.py`. Still open: a periodic pattern at the lowest
   radii (< 0.09 c/px) is not searched, and a full-frame pattern is flagged but its number is kept.
2. **Single-edge sharpness was unreliable.** The first run's "softest image" (MTF50 0.011 c/px) was
   a sharp aquarium photo whose one measured ROI straddled a thin acrylic seam, a line rather than a
   step. Two gates now remove this class: a step must satisfy MTF50 × rise ≈ 0.5 (49 ROIs rejected as
   `not_a_step`), and a per-image figure needs ≥ 3 valid edges (73 of 149 images with edges). The
   softest valid image is now 0.101 c/px, a plausibly soft frame.
3. **Natural scenes yield few valid steps.** 15,162 candidate edges were rejected across 382 images
   (plateau noise 4,294; SFR errors 3,024; clipped 1,924; contrast > 1 1,812; no MTF50 below
   Nyquist 1,149; step too small 901; fit residual 835; shading 812). About 7 valid ROIs per image
   where any exist. The per-image sharpness figures are therefore few-edge medians with wide
   spread; a chart test would settle the absolute numbers.
4. **HEIC vs JPEG in a Photos library is not "camera original vs processed".** 181 of the 17 Pro
   Max files are JPEG and 25 HEIC; the phone shoots HEIC by default, so the JPEGs are likely
   shared or re-exported copies with unknown provenance. The HEIC-vs-JPEG sharpness gap seen (0.193
   vs 0.254 c/px, n=7 vs 36) should not be read as a pipeline comparison without matched pairs.
5. **Whiteness as an NR-strength proxy is confounded at low noise.** When sensor noise is tiny
   (D850 at ISO 64), residual texture and compression dominate the residual and whiteness rises
   (0.30–0.47) even with no NR. It is a clean indicator only when noise is well above texture.
6. **DR is mostly lower bounds** (section 3) and should not be charted against ISO for this library.

## 6. What this run changed in the tool

Three validity gates were added after the eye check and the numbers re-run: `not_a_step`
(MTF50 × rise consistency), `noise_texture_suspect` (whiteness > 0.7), and a three-edge minimum for
per-image sharpness in the report. Nothing in the measurement code was changed to move a number.

**Second run, 2026-10-13 13:56 ET (741 s, 0 failures):** the spectral periodic-texture detector (section 5,
item 1) added `noise_spectral_peak`, `noise_periodic_suspect`, `noise_periodic_freq_cpp` and
`noise_periodic_fraction`; 6 images are flagged and leave the SNR medians; 383 rows are unchanged. The
tables above were computed on the first run and are unchanged by it except that the four screen photos
no longer appear among the noisiest valid images.

**Third run, 2026-10-13 ~16:40 ET (697 s, 0 failures):** 95 % percentile-bootstrap intervals on the
per-image MTF50 median and p80 (`mtf50_*_ci_lo/hi_cpp`, `iqa/uncertainty.py`); every other column is
identical to the second run. What the intervals say about this library: of the 73 images with a
sharpness figure, the median relative width of the interval on the median MTF50 is 0.57 (p90 1.05); by
edge count, 0.59 with 3-5 edges, 0.64 with 6-10, 0.40 with more than 10. A per-image sharpness figure
from natural edges is therefore good to about +/- 30 %, and the "sharpest image" rankings in report.md
should be read as bands, not an order; the per-camera medians over many images are much tighter.

## 7. Structure of the frames (fourth run, 2026-10-15, 978 s, 0 failures)

`iqa/structure.py` adds a 4x6 focus map, the detail centroid and its distance from the rule-of-thirds
points, orientation shares, the tilt of the longest near-level edge, surface shares, and a two-cluster
in-focus/background split of the edge MTF50s (the review's open item). Every earlier column is
unchanged. On this library:

- **Subjects, not fields.** The median focus fraction is 0.25: in 168 of 389 frames the fine detail
  occupies under a quarter of the 4x6 grid (a subject against a smooth or blurred field); only 7
  frames are sharp almost everywhere (fraction > 0.8).
- **Composition.** With the thirds distance in centre-to-thirds units (0 on a point, 1 at the frame
  centre), 49 frames put the detail on a thirds point (< 0.35), 93 centre it or push it to an edge
  (> 0.75), median 0.63. (The first scaling, in frame-diagonal units, called 342 of 389 "on a thirds
  point" because the frame centre itself scored 0.17; the unit was changed, the stored numbers rescaled
  by the constant 6.0 and the CSV rebuilt. It is a unit change, not a measurement change.)
- **Level edges.** A near-level edge at least 40 % of the width long exists in 177 frames; its median
  |tilt| is 2.3 degrees and 129 are tilted a degree or more. Most of those are not horizons: table
  edges, shelves and the whiteboard frame seen in perspective (the walkthrough photo reads 6.9
  degrees on the board's edge). The column is therefore named "level-edge tilt" in the report and the
  app, and straightening advice is offered, not asserted.
- **Shallow depth of field.** Of the 52 frames with five or more measured edges, 34 split cleanly into
  a sharp and a soft group; for those the p80 figure is the subject and the median mixes in the
  background, as the report's how-to-read section now says.
