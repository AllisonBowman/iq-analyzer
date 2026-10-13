# Review — iq-analyzer

Read as a portfolio piece by a camera IQ engineer. `.venv/bin/python -m pytest -q` → **51 passed**.

The core maths is sound: the slanted-edge projection onto the edge normal (`sfr.py:124`) is the
correct perpendicular distance, the `sinc(f·Δ)` derivative correction (`sfr.py:219`) is right,
`gaussian_mtf50` (`sfr.py:250`) is algebraically correct and verified numerically, `lw_per_ph`
is Imatest's definition, the σ=8 px high-pass costs 0.19 % of white-noise power as the docstring
claims, and the EOTF-slope conversion in the DR estimate (`noise.py:161-166`) is dimensionally
correct. Below is what I measured by probing the code, not by reading it.

---

## 1. Correctness issues, ranked

### C1 — A clipped plateau inflates MTF50 by up to 113 %, and every quality filter passes it
`sfr.py:195-201`, filters at `edges.py:131-136`

A blown highlight on one side of an edge truncates the ESF. Measured, σ=1.5 px edge
(truth MTF50 = 0.1249 c/px), bright side driven into clipping:

| nominal high | MTF50 | error | contrast | plateau_noise | fit_rms | passes filters |
|---|---|---|---|---|---|---|
| 1.0 | 0.1251 | +0.1 % | 0.905 | 0.0000 | 0.010 | yes |
| 1.4 | 0.1820 | **+45.7 %** | 0.905 | 0.0000 | 0.020 | yes |
| 2.0 | 0.2245 | **+79.7 %** | 0.905 | 0.0000 | 0.017 | yes |
| 3.0 | 0.2663 | **+113.2 %** | 0.905 | 0.0000 | 0.030 | yes |

Clipping makes `plateau_noise` *better* (0.0000), so the filters actively prefer clipped edges.
Skies, speculars and window frames are the highest-contrast edges in a real photo and therefore
exactly the ones Hough ranks first — this will dominate the "sharpest images" table on the
Photos-library run.

**Fix:** in `compute_sfr`, record `sat_frac` = fraction of ROI pixels with `roi >= 0.995·roi.max()`
or `roi <= 0.005`; reject in `edges.py` when `sat_frac > 0.005`. Also reject `contrast > 1.0` —
Michelson contrast above 1 is impossible for a true step and is a free detector of both this and C2.

### C2 — A gradient across the ROI biases MTF50 down by up to 43 %, undetected
`sfr.py:119-143` (no baseline removal), `sfr.py:195-201`

Real edges sit on gradients (sky, wall falloff, vignetting). σ=1 px edge, linear shading added
across the 64-px ROI:

| shading (as % of step across ROI) | MTF50 err | plateau_noise | contrast | rise_10_90 |
|---|---|---|---|---|
| 0 % | +0.2 % | 0.0000 | 0.600 | 3.00 |
| 21 % | **−8.4 %** | 0.0088 | 0.707 | 4.00 |
| 53 % | **−20.8 %** | 0.0179 | 0.868 | 18.00 |
| 107 % | **−43.1 %** | 0.0274 | 1.139 | 30.00 |

`plateau_noise` never approaches its 0.15 threshold, so the 21 % case (−8.4 %) passes everything.
Note `contrast` rises *above* the true 0.600 and exceeds 1.0 — another reason to gate on it.

**Fix:** fit a straight line to the two ESF plateaus and subtract it before differentiating
(ISO 12233 does not need this because charts are uniform; natural scenes do). Report the fitted
plateau slope as a quality field.

### C3 — The texture gate silently voids the noise metrics for noise-reduced images
`noise.py:92,118-120` (`sS/sR < 0.30`, calibrated for white noise where the ratio is 0.141)

Injected σ=5 per channel (truth: luma σ = 3.75), noise given a correlation length:

| noise correlation σ | n_patches | luma noise | SNR |
|---|---|---|---|
| 0 px | 2889 | 3.676 | 30.1 dB |
| 0.8 px | 295 | 3.536 | 30.5 dB |
| 1.0 px | **1** | **nan** | **nan** |
| 1.5 px | **0** | **nan** | **nan** |

And through plausible delivery pipelines:

| | n_patches | luma noise | SNR |
|---|---|---|---|
| raw-ish, σ=6 | 2842 | 4.407 | 28.6 dB |
| + light NR (σ=0.8 blur) | 338 | 1.506 (**−66 %**) | 37.9 dB |
| JPEG q85 (σ=5 source) | 2989 | 2.352 (**−37 %**) | 34.0 dB |
| JPEG q75 | 3002 | 2.024 (**−46 %**) | 35.3 dB |

The gate bites hardest on exactly the images whose noise matters most (high-ISO iPhone HEIC after
NR), and `_finite()` in `report.py:76` drops the NaNs without comment, so the SNR-vs-ISO chart —
the headline chart of the application — would be plotted over a subset biased toward clean, white-noise
images and would look flatter than reality.

**Fix:** estimate the residual's correlation length per patch and set the expected smoothing ratio
from it, rather than assuming white noise; keep the ratio as a reported metric (`noise_whiteness`)
instead of a hard gate. Always emit the patch-rejection rate so NaN is visible, and make
`report.py` print `n` alongside every chart.

### C4 — The DR search skips bins that fail the SNR threshold
`noise.py:171-177` — `ok = flatnonzero(snr_lin >= t); j = ok[0]` takes the *darkest* bin that passes,
not the darkest level above which the curve stays passing.

Constructed curve with one bad mid-tone bin (SNR 0.53 at level 24):
`snr = [8.0, 0.53, 11.3, 14.6, 17.9, 24.6, …]`. For t = 1, 2 and 4 the code picks bin 0 and reports
8.62 stops, flagged `lower_bound=True`, claiming clean data down to level 8 while level 24 has SNR 0.53.

**Fix:** scan from the brightest bin downward and stop at the first bin below `t`.

### C5 — "SNR at mid-grey" is silently extrapolated from whatever levels the image contains
`noise.py:152-156` falls back to the nearest bin. The comment says "flagged by the caller via n bins
if needed" — but `as_dict()` (`noise.py:55-65`) emits no such flag, nothing in `CSV_COLUMNS`
carries it, and `report.py:166-168` medians it with real measurements.

Measured on a frame with no mid-tones: the only bin is at level **23.9**, and the result is reported
as `snr_midgrey_db = 32.11` with `luma_noise_midgrey_8bit = 2.926`. A night shot will produce a
confident "mid-grey SNR" from its deep shadows.

**Fix:** add `snr_midgrey_extrapolated: bool` and `nearest_bin_level: float` to `as_dict()` and the
CSV; have `report.py` exclude flagged rows from the median and print how many were dropped.

### C6 — `rise_10_90_px` is biased high by its own smoothing and quantised to ¼ px
`sfr.py:146-158` smooths the ESF with σ=2 *samples* (= 0.5 px at 4× oversampling) and then takes
integer sample indices.

| blur σ | reported rise | truth (2.563σ) | error |
|---|---|---|---|
| 0.5 | 1.750 | 1.282 | **+36.6 %** |
| 0.7 | 2.250 | 1.794 | **+25.4 %** |
| 1.0 | 2.750 | 2.563 | +7.3 % |
| 2.5 | 6.750 | 6.408 | +5.3 % |

Every value is a multiple of 0.25. `tests/test_sfr.py:51-52` uses ±0.5/±0.7 px absolute tolerances,
which accommodate the bias instead of catching it. The same inflated width sets `halfwin` at
`sfr.py:185-186`.

**Fix:** `np.interp` the 10 % and 90 % crossings on the *unsmoothed* ESF, or deconvolve:
`sqrt(w² − (2.563·σ_sm/oversample)²)`. Tighten the test to a 5 % relative tolerance.

### C7 — `_rise_width` has two silent failure modes
`sfr.py:149-158`. The plateaus are the outer 20 % of samples, and `argmax(t >= 0.9)` returns 0 when
the level is never reached. Measured: an ESF that is mostly ramp (no left plateau) → **67 samples**;
a perfectly flat ESF → the full record (**15 px** after `/oversample`). Both propagate into
`halfwin` and into the reported `edge_rise_median_px`.

**Fix:** return `nan` when the plateaus are not separated or `t` never crosses 0.9, and skip the ROI.

### C8 — The Hamming window is circularly wrapped, not clamped
`sfr.py:208-210`: `win = 0.54 + 0.46·cos(2π(i−peak)/n)` with no restriction on `|i−peak|`.

| peak position (n=250) | win[0] | win[-1] | window minimum |
|---|---|---|---|
| 125 (centred) | 0.080 | 0.080 | at i=0 ✓ |
| 60 | 0.569 | 0.557 | at i=185 ✗ |
| 30 | 0.875 | 0.867 | at i=155 ✗ |

With an off-centre edge the taper lands in the middle of a plateau and the record ends keep weight
up to 0.88, so the zero-padded FFT sees a step at the boundary. On flat synthetic plateaus the
effect is small (MTF50 error grew only 0.8 % → 1.5 % at 20 px off-centre with 1 % noise), but it
compounds C1/C2 and affects the user-supplied `iqa sfr --roi` path most.

**Fix:** `win = np.where(np.abs(i - peak) <= n/2, 0.54 + 0.46*np.cos(2*np.pi*(i-peak)/n), 0.0)`.

### C9 — `mtf_nyquist` is biased low and has a leakage floor
`sfr.py:233`

| blur σ | reported | analytic exp(−2π²σ²·0.25) | error |
|---|---|---|---|
| 0.7 | 0.08498 | 0.08909 | −4.6 % |
| 1.0 | 0.00616 | 0.00719 | −14.3 % |
| 1.5 | 0.00042 | 0.00002 | +2664 % (floor) |

The measurement floor is ~4×10⁻⁴–6×10⁻³, so any reported value below ~0.01 is window leakage, not
signal. `mtf_nyquist_median` is in the CSV and the report with no validity note, and nothing in
`tests/` checks it. **Fix:** add the analytic test above, and return `nan` below a stated floor.

### C10 — MTF50 is searched above the pixel Nyquist
`sfr.py:222-232` searches `freq ≤ max_freq = 1.0`; `edges.py:135` then accepts `mtf50 ≤ 0.6`. Values
between 0.5 and 0.6 c/px are above Nyquist and physically meaningless for a sampled system, yet they
would rank at the top of the "sharpest images" table. **Fix:** restrict `_first_crossing` for
MTF50/MTF30 to `freq ≤ 0.5` and return `nan` with a flag when there is no crossing below Nyquist.

### C11 — `min_contrast` guards the wrong quantity; `plateau_noise ≤ 0.15` is ~5× too loose
`edges.py:131`. Michelson contrast on linear data is dominated by the absolute level, not by edge SNR:

| edge | Michelson | plateau_noise | MTF50 bias | scatter (6 seeds) | passes |
|---|---|---|---|---|---|
| 0.02 → 0.05, noise 0.004 | 0.425 | 0.032 | **−9.7 %** | **19.9 %** | yes |
| 0.40 → 0.60, noise 0.004 | 0.200 | 0.004 | +0.3 % | 1.2 % | borderline reject |

A dark, noisy edge sails through while a clean mid-tone edge is rejected. **Fix:** drop
`min_contrast` in favour of edge SNR = step/plateau_std ≥ 30 (i.e. `plateau_noise ≤ 0.033`) plus a
minimum *absolute* step height.

### C12 — Gray-world WB is computed on gamma-encoded values
`exposure.py:55-56` averages 8-bit sRGB code values. The encoded ratio compresses a real cast by
roughly 2.4×: the synthetic scene's +15 % blue gain appears as `wb_b_over_g ≈ 1.059`. Labelled a
white-balance error, this understates it. **Fix:** `srgb_decode` before averaging; report the
R/G and B/G error in stops. (`test_noise_exposure.py:56` asserts only `> 1.02`, so it passes either way.)

### C13 — The report medians DR lower bounds together with real measurements
`report.py:169`, `report.py:196`. `dr_snr4_lower_bound` is carried in `CSV_COLUMNS` (`report.py:18`)
and never used anywhere in the markdown. Measured: a 3× noise difference produced *identical*
`dr_snr4 = 5.50` stops, both flagged `lower_bound=True` — 5.50 stops is just
`log2(white / lin(darkest bin 39.8))`, i.e. the scene's own tonal range, not a DR measurement.

**Fix:** exclude `lower_bound` rows from the DR median and the by-camera table, and print
"n of N frames contained shadows dark enough to find the floor".

*(Minor: `noise.py:105-106,121` computes `mx`/`mn` and deletes them unused.)*

---

## 2. Methodology caveats a reviewer would raise

1. **The ground truth omits the detector MTF.** `synth.slanted_edge` point-samples an analytic erf,
   so the "truth" is `exp(−2π²σ²f²)`. A real sensor integrates over the pixel aperture, adding
   `sinc(f)`. I built an area-integrated edge (8× supersample, box-averaged, 100 % fill, σ=1): the
   code returns **0.1796** c/px against blur×sinc = **0.1800** (0.2 %), while the test's analytic
   truth is 0.1874. The pipeline is right; the *test's* reference is the thing missing detector MTF.
   So README's "within 4 %" demonstrates curve recovery, not absolute accuracy against a camera —
   and the stronger claim is available for free.
2. **Colour space is assumed sRGB.** `imageio.py:191-198` ignores the embedded ICC profile. Apple
   HEICs are routinely Display P3 (and HDR ones HLG/PQ), so both the linearisation and the Rec.709
   luma weights (`imageio.py:41`) are wrong for most of the target library. This is the first
   question a camera-team reviewer will ask.
3. **The 80th percentile recovers the in-focus plane only if enough edges are in focus.** Mixed bag
   of σ=1.0 (in focus) and σ=3.0 (defocused) edges, truth 0.1874 / 0.0625:

   | in-focus fraction | p80 | median | max |
   |---|---|---|---|
   | 10/20 | 0.1875 ✓ | 0.1252 | 0.1887 |
   | 6/20 | 0.1870 ✓ | 0.0636 | 0.1887 |
   | 3/20 | **0.0637 (−66 %)** | 0.0636 | 0.1875 |
   | 1/20 | **0.0637 (−66 %)** | 0.0635 | 0.1875 |

   A fixed percentile over a sample whose composition varies per photo is not a stable estimator:
   below ~20 % in-focus edges (a shallow-DOF portrait with a busy background) p80 reports the
   *background*. `max` was correct in all four cases. It is defensible only if reported with `n`,
   the spread, and a stated minimum `n`; `p95` or a two-cluster split would be more honest. Where
   p80 was well-posed it was stable and accurate (6 seeds, same optics: +1.0 % bias, 1.0 % spread).
4. **Natural edges are not step targets.** MTF50 convolves the system MTF with the subject's own
   edge profile, so every figure is a scene-dependent *lower bound* on system MTF. The README says
   this; the report's "Sharpest images" ranking across different scenes does not.
5. **Noise is output-referred and measures the codec as much as the sensor** (C3's table). Any
   SNR-vs-ISO comparison across HEIC/JPEG/DNG is partly a chart of compression quality and NR
   strength. For roadmap item 4 this is the confound, not a detail.
6. **SNR saturates at ~52 dB.** A noise-free 8-bit image measures `luma_noise = 0.281`
   (quantisation, 1/√12 = 0.289) → 52.5 dB. Any frame near 52 dB is quantisation-limited, not clean.
   State the ceiling in "How to read these numbers".
7. **The σ=8 px high-pass discards low-frequency noise by design.** Correct for white noise (0.19 %
   of power) but it removes precisely the blotchy chroma noise and banding that dominate high-ISO
   NR'd output — the noise a viewer actually objects to.
8. **DR is bounded by the scene, not the camera.** The floor comes from the darkest flat patch the
   frame happens to contain, so most frames yield a lower bound (C13). Cross-image DR comparison is
   valid only among frames containing near-black flat areas.
9. **RAW and HEIC are not rendered comparably.** `imageio.py:182-187` uses `gamma=(1,1)`,
   `no_auto_bright=True`, so a DNG's "display-referred" image has no tone curve while its HEIC
   sibling does. Roadmap item 4 would measure exposure/tone differences, not pipeline differences,
   unless the pair is first matched on a grey patch.
10. **Frequency axis convention.** `sfr.py:124` scales by `cos θ`, so frequencies are cycles/px along
    the edge *normal*; `sfrmat`/Imatest report cycles/px along the scan direction. 0.4 % at 5°,
    2.2 % at 12° — small, but state which one you report.
11. **Sagittal/tangential and field position are pooled.** `edges.py` puts "v" and "h" ROIs, and
    centre and corner ROIs, into one distribution, averaging away astigmatism and field curvature —
    the two things a per-lens comparison is for.
12. **No overshoot metric.** `mtf50p` is computed (and does diverge correctly: a USM amount of 2.0
    gave peak MTF 1.289, mtf50 0.2470, mtf50p 0.2263) but ISO 12233 / Imatest's overshoot % is the
    number that actually shows sharpening — the headline for the HEIC-vs-RAW study.
13. **No uncertainty is reported anywhere.** No CI on MTF50, no `n` in the by-camera table
    (`report.py:194-197`), no scatter. `min_sep = 48 px < roi_len = 96 px` (`edges.py:90`) also lets
    ROIs sample the same physical edge, so `n_measured` overstates the independent sample size (only
    1 overlapping pair of 78 on the synthetic scene, but long architectural edges will do worse).

---

## 3. Tests: what they would and would not catch

They are real ground-truth tests, which already puts this above most portfolio code — but they
exercise the happy path. Every bug in section 1 survives all 51 of them.

What is **untested**: clipped plateaus (C1); shaded plateaus (C2); correlated/NR'd noise (C3);
non-monotonic SNR curves (C4); the mid-grey extrapolation path (C5); `mtf_nyquist` against any
reference (C9); the `_rise_width` failure modes (C7); off-centre ROIs (C8); slants outside 3–11°
although production accepts 1–16° (`edges.py:133`); `mtf50p` on an overshooting edge, so the
sharpening metric is never exercised at all; the `n_patches < 6` and `edges_measured == 0`
NaN paths that `report.py` then aggregates; `load_image` for RAW and HEIC, i.e. the loader most
likely to break on the actual Photos library; EXIF extraction on either path; and any golden/regression
check on `results_demo`, so a refactor can change every number silently.

Two tolerances are too loose to constrain what they claim:
- `test_sfr.py:36-37` asserts `max|MTF − truth| < 0.03` *absolute* over 0.02–0.4 c/px. At f=0.4 the
  true MTF for σ=1.2 is 0.0106, so 0.03 absolute is a 280 % relative tolerance — the test does not
  constrain the high-frequency end at all, which is why C9 went unnoticed.
- `test_sfr.py:51-52` accommodates C6's +25–37 % rise-width bias.

Also: the SFR tests use 120×80 ROIs while production uses 96×64 (`edges.py:99-101`). At the
production size errors stay small (noise 1 %: +0.3 % mean, +1.7 % worst; noise 3 %: +1.1 % mean,
+6.3 % worst over 8 seeds) — worth pinning as a test rather than leaving implicit.

---

## 4. The five changes that would most increase credibility with a hiring engineer

1. **Cross-validate the SFR against something external and publish the plot.** Add the
   area-integrated (pixel-aperture) synthetic edge and assert against blur×sinc — I measured 0.2 %
   agreement, a far stronger and more knowledgeable claim than the current 4 %. Then shoot one
   ISO 12233:2014 e-SFR chart (or a razor blade) and overlay your MTF curve on `sfrmat`'s or
   Imatest's in the README. One plot answers "do I trust your numbers", and the pixel-aperture
   discussion signals you know what detector MTF is.
2. **Never print a number the code knows is not a measurement.** Clipped plateau, shaded plateau,
   extrapolated mid-grey, DR lower bound, zero usable patches — each is a validity flag that exists
   or is one line away (C1, C2, C5, C13). Propagate them through `as_dict`, the CSV and `report.md`,
   and have the report say "not measurable in 14 of 60 frames" instead of medianing a biased subset.
   A tool that declines to answer earns far more trust than one that always returns a float.
3. **Add the eight adversarial tests from section 3** — clipped edge, shaded edge, overshooting
   edge, correlated noise, non-monotonic SNR, off-centre ROI, slant at the accepted limits, and a
   ramp with analytically known DR. Each is ~10 lines, each pins a bug found above, and the README
   can name the failure each one guards. That converts "51 tests pass" into evidence.
4. **Fix the colour pipeline and split the sharpness statistics by orientation and field position.**
   Honour the ICC profile for P3/HDR HEICs (caveat 2), then report MTF50 for centre vs corner ROIs
   and sagittal vs tangential separately (roadmap item 2). A centre-to-corner MTF50 falloff map with
   `n` and error bars reads as camera-team work; a single pooled MTF50 per photo reads as a generic
   script.
5. **Do the real-photo run, and make `FINDINGS.md` include "metrics I do not trust, and why".**
   Name the NR/compression confound in SNR-vs-ISO, the DR lower bounds, and the clipped-edge bias,
   with the counts. Reporting your own tool's limits accurately is the single strongest signal of
   an IQ engineer — and per the morning prompt, fix the metric rather than the number.
