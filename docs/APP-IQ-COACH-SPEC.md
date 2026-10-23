# IQ Coach: a macOS app that coaches photography and editing from iq-analyzer results

Spec written 2026-10-14. The app lives in `mac/IQCoach/`, is generated with XcodeGen from
`project.yml`, targets macOS 15, SwiftUI, Swift 6 strict concurrency, Swift Charts, Swift Testing.
No third-party packages. It reads `results.json` written by `python -m iqa analyze` and can run the
analyzer itself on a folder the user picks.

## Purpose, in the user's words

"I shot these photos on this camera. Tell me what it does well and badly, what to change when I
shoot, and what to do in my editing app to get the best out of each photo." The user is a
photographer, not an engineer: every metric is shown with a plain-language name, a one-line
meaning, a scale that says what good looks like, and the number.

## Inputs

1. **Open results…** (⌘O): a `results.json` from iqa. The repo's `results/results.json` is the
   demo data set (389 rows, 19 cameras). Rows are decoded with `JSONDecoder`; unknown keys ignored;
   NaN arrives as the JSON token `NaN` (Python wrote it): configure the decoder with
   `nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity",
   negativeInfinity: "-Infinity", nan: "NaN")`.
2. **Analyze folder…** (⌘⇧O): the user picks a folder; the app runs
   `<python> -m iqa analyze <folder> -r --out <AppSupport>/IQCoach/runs/<timestamp> --no-paths`
   through `Process`, streams progress lines (`[12/389] …`) into a progress sheet, then opens the
   results. `<python>` and the repo path are Settings (⌘,) with defaults
   `~/Developer/iq-analyzer/.venv/bin/python` and `~/Developer/iq-analyzer`; the app validates them
   (file exists, `python -c "import iqa"` succeeds) and shows a clear fix-it message otherwise.
   The sandbox is OFF for this app (it must run a user-chosen interpreter); say so in the README.
3. Photo thumbnails: when a row has `path` and the file exists, show the image (downsampled);
   otherwise a placeholder with the file name. Never fail on a missing file.

## Model (Sources/Model)

- `PhotoRecord: Codable, Identifiable, Sendable` with the fields the UI uses (file, path?,
  camera_make, camera_model, lens?, iso, exposure_s, f_number, focal_mm, width, height, format,
  is_raw, color_profile, edges_measured, mtf50_median_cpp, mtf50_median_ci_lo/hi, mtf50_p80_cpp,
  mtf50_p80_lwph, mtf50_center_median_cpp, mtf50_outer_median_cpp, mtf50p_median_cpp,
  overshoot_median_pct, snr_midgrey_db, snr_midgrey_extrapolated, noise_whiteness,
  noise_texture_suspect, noise_periodic_suspect, noise_spectral_peak, dr_snr4_stops,
  dr_snr4_lower_bound, clip_high_pct, clip_low_pct, luma_p50, tonal_range_stops,
  wb_r_over_g_stops, wb_b_over_g_stops, colorfulness, datetime). Optional everywhere a value can
  be NaN or missing; expose `Double?` after mapping NaN to nil.
- `CameraGroup`: key = camera_model; `lenses: [LensGroup]` keyed by `lens ?? "(lens not recorded)"`;
  photos; `summary: CameraSummary` (counts, medians, SNR by ISO band, p80 LW/PH by lens,
  centre/outer ratio, clipping rates, whiteness median, overshoot median, WB medians).
- ISO bands: ≤64, 65-160, 161-400, 401-1000, >1000 (the same as FINDINGS.md).
- `Metric` enum with `displayName`, `shortMeaning`, `definition` (the deck's glossary wording),
  `unit`, `scale: ClosedRange<Double>`, `goodDirection`, and `band(for:)` → .poor/.fair/.good/.excellent
  with these thresholds:
  - sharpness p80 (LW/PH): poor < 1500, fair < 2500, good < 3500, excellent ≥ 3500. Since 2026-10-23
    `mtf50_p80_lwph` uses the short side (FINDINGS §9); these bands were set on the earlier height-based
    figures, which read 1.33x higher on portrait frames, so they are due a re-check.
  - sharpness p80 (c/px): poor < 0.12, fair < 0.20, good < 0.30, excellent ≥ 0.30
  - SNR mid-grey (dB): poor < 25, fair < 32, good < 38, excellent ≥ 38
  - highlight clipping (%): excellent < 0.1, good < 0.5, fair < 2, poor ≥ 2 (lower is better)
  - shadow clipping (%): same bands
  - overshoot (%): excellent < 3, good < 8, fair < 15, poor ≥ 15 (lower is better; "sharpening halo")
  - white-balance lean (|stops|, max of R/G and B/G): excellent < 0.1, good < 0.2, fair < 0.4, poor ≥ 0.4
  - whiteness: informational, not banded (0.14 white … 0.5+ heavily smoothed)
  - dynamic range (stops): informational; show "at least" when lower-bound.
  Bands use colour AND a word (HIG: never colour alone).

## Coaching engine (Sources/Coaching), pure functions, unit-tested

`Insight { id, scope: .camera(model) | .lens(model, lens) | .photo(file), severity: .info/.notice/.important,
title, finding (one sentence with the numbers), why (one or two sentences, plain), actions: [String],
evidence: [EvidenceItem(metric, value, n)] }`.

### Camera-level rules (run per camera with ≥ 5 photos; each rule states its evidence count)

1. **ISO ceiling.** Median SNR per ISO band (exclude extrapolated/periodic/texture rows). Find the
   highest band whose median ≥ 32 dB ("good"). Finding: "Noise stays clean up to ISO {band top}
   ({median} dB over {n} photos); above that it drops to {next median} dB." Actions: shoot freely up to
   that ISO; above it, prefer a slower shutter on a support or more light; if the highest band is
   also ≥ 32 dB say "clean at every ISO you have used".
2. **Noise reduction character.** Median whiteness: < 0.2 → "noise is left as fine grain (little
   smoothing)"; 0.2-0.4 → "moderate smoothing"; ≥ 0.4 → "strong smoothing: fine texture (hair,
   foliage, fabric) softens at higher ISO even though the noise number looks good". Actions for the
   ≥ 0.4 case: keep ISO low for texture subjects; do not add noise reduction in editing.
3. **Lens comparison** (phones with ≥ 2 lenses having ≥ 3 sharpness rows each). Median p80 LW/PH per
   lens; name the sharpest; for each other lens state the % gap. Actions: "for detail, move closer
   with the {sharpest lens} rather than zooming with {other}"; name lenses in human terms
   (main / ultra-wide / telephoto / front) derived from focal_mm rank and "front" in the lens string.
4. **Field softness.** Median of (outer / centre) MTF50 over rows with both. < 0.80 → "corners
   are {pct}% softer than the centre". Actions: keep the subject in the central area; DSLR: stop down
   one or two stops; phone: avoid the ultra-wide for edge detail.
5. **Highlight discipline.** Share of photos with clip_high_pct > 1. If > 15 %: finding with the
   share; actions: dial exposure compensation to −0.3 … −0.7 EV in bright scenes; use the
   histogram or zebra; on iPhone tap and drag the sun slider down. Also "{n} photos lost shadow
   detail" if clip_low share > 15 %, with the mirror advice (lift EV, or accept dark blacks).
6. **Sharpening character.** Median overshoot > 8 % → "this camera sharpens hard ({pct}% halo)".
   Actions: turn down the in-camera style/sharpness if the camera offers it; never add sharpening in
   editing; downsize with a soft resampler for the web.
7. **Colour lean.** Median WB stops: |R/G| or |B/G| > 0.15 → "renders {warm/cool, magenta/green}
   by {stops}". Actions: set a white-balance preset instead of auto in that light; shoot a grey card;
   fix in editing with Temperature/Tint.
8. **Slow-shutter softness** (phones): rows with exposure_s ≥ 1/30 vs faster; if the slow group's
   median p80 is ≥ 20 % lower (≥ 3 rows each): "hand-held frames at 1/30 s or slower were {pct}%
   softer". Actions: brace, use burst, raise ISO one stop (the ISO rule says how far you can go).
9. **Aperture sweet spot** (cameras with f_number spread; ≥ 3 rows per aperture): sharpest aperture by
   median p80; state it and the softest.
10. **Sharpness confidence.** If the median relative CI width across the camera's rows is > 0.5:
    info insight explaining that per-photo sharpness figures are ±30 % bands on natural scenes and
    the per-camera numbers are the trustworthy ones.

### Photo-level editing advice (run per photo; grouped by editor: Apple Photos, Lightroom, Any editor)

Each rule yields an `EditingAdvice { metric, finding, apple: String, lightroom: String, generic: String,
caution: String? }`. Rules:

- **Blown highlights** clip_high > 0.5 %: Photos: Adjust → Light → Highlights −, Brilliance; Lightroom:
  Highlights −40…−80, Whites −; generic: "lower highlights, then whites". Caution: on JPEG/HEIC the
  pixels at 255 hold no detail; RAW can recover 1-2 stops.
- **Crushed shadows** clip_low > 0.5 %: Shadows +, Black Point / Blacks +. Caution: lifting shadows
  raises noise; check the SNR advice.
- **Noisy** SNR < 30 dB: Photos: Noise Reduction (moderate); Lightroom: Denoise (AI) 30-50 or Luminance
  NR 20-40, Detail 50; generic: luminance NR before sharpening; if whiteness ≥ 0.4 add caution "already
  smoothed by the camera; more NR will smear texture".
- **Soft** p80 < 0.18 c/px and overshoot < 8 %: Photos: Sharpen 20-40, Definition 10; Lightroom:
  Sharpening 40-60, Radius 1.0, Masking 40-70; generic: sharpen on luminance, mask flat areas.
  If overshoot ≥ 8 %: instead "already sharpened; do not add more; downsize for the web with care".
- **Halo** overshoot ≥ 12 %: Lightroom: reduce Sharpening to 0-20, Clarity 0; Photos: Sharpen 0;
  generic: avoid any further sharpening.
- **Colour lean** max |WB stops| > 0.15: direction and amount; Photos: Color → Cast / White Balance
  (neutral gray picker); Lightroom: Temp/Tint toward {direction}; generic: white-balance picker on a
  neutral. Caution: a sunset or stage light is intent.
- **Flat tones** tonal_range < 7 stops and both clip < 0.2 %: Photos: Light → Contrast +, Black Point;
  Lightroom: Contrast +15…+30 or a tone curve; generic: S-curve.
- **Dark / bright exposure** luma_p50 < 70 → Exposure +0.3…+0.7 (check the shadow caution);
  luma_p50 > 190 and no clipping → Exposure −0.3.
- **Moiré / pattern** noise_periodic_suspect: explain moiré; Lightroom: Moiré brush; Photos: none;
  generic: re-shoot at a different distance or angle.
- **Nothing to fix**: if no rule fires, say so ("this photo is clean, sharp and well exposed; edit
  for taste") rather than showing an empty list.

## UI (HIG; SwiftUI; dark and light; Dynamic Type; VoiceOver labels)

- `NavigationSplitView` with three columns.
  - **Sidebar**: "Cameras" section listing camera models (SF Symbol `camera`), with photo count
    badges; a "Library" item at top for the all-cameras overview. Search field filters.
  - **Content** (for a camera): a scrolling report with:
    1. Header: camera name, lenses used, photo count, date range.
    2. **Report card**: a `LazyVGrid` of `MetricTile`s: in-focus sharpness (LW/PH), noise (SNR dB),
       highlight clipping (% of photos), sharpening halo, colour lean, dynamic range. Each tile: large
       number (SF rounded, `.font(.system(.largeTitle, design: .rounded))`), label, band word +
       colour capsule, a horizontal `ScaleBar` showing where the value sits between poor and
       excellent, and an ⓘ `Button` opening a `.popover` with the definition and "what good looks
       like". Tiles are `accessibilityElement(children: .combine)` with a spoken summary.
    3. **Charts** (Swift Charts): SNR vs ISO (points + per-band median line, log x-axis); sharpness by
       lens (bar); clipping share (bar). Each chart has a one-sentence caption that says what to see.
    4. **Coaching**: the camera-level insights as cards (`GroupBox`), icon by severity, title,
       finding in regular weight with the numbers in `.monospacedDigit()`, "Why" in secondary colour,
       "Do this" as a bulleted list, "Based on n photos" footer.
    5. **Photos**: a `Table` (file, date, lens, ISO, sharpness, SNR, clipping) sortable, selection
       drives the detail column.
  - **Detail** (for a photo): thumbnail (or placeholder), metric list (`Form` with `.grouped`
    style) each row with band capsule and ⓘ popover, then **Editing advice** with a `Picker`
    (segmented: Apple Photos / Lightroom / Any editor) and the advice cards; cautions in a
    `Label` with `exclamationmark.triangle`.
  - **Library overview** (all cameras): one table of cameras with their report-card numbers, the
    SNR-vs-ISO chart with one series per camera, and the headline sentence computed from the data
    (which camera holds noise flat, which falls).
- Toolbar: Open results…, Analyze folder…, Share (export the current camera's coaching as Markdown
  via `ShareLink`). Menu bar: File (Open, Analyze), View (Toggle sidebar), Help (Glossary window:
  every metric, definition and scale, in a `Table`).
- Empty state (no results loaded): a centred `ContentUnavailableView` with the two actions and one
  sentence on what the app does.
- Settings scene: Python path, repo path, "Validate" button with result text.
- Typography: system fonts only; sizes from the HIG text styles; 8-pt grid spacing; `.controlSize`
  defaults; no custom colours beyond the band colours (use `.green`, `.yellow`, `.orange`, `.red`
  with words, and `.secondary` for meaning text). Window min size 1100 x 700.
- Every number is formatted with `formatted()` and a unit; never raw doubles.

## Snapshot mode (for verification without a GUI session)

`IQCoach --snapshot <results.json> <outdir>`: on launch, decode the file, render with `ImageRenderer`
at 1400 x 900 @2x: `library.png`, `camera-<first camera>.png`, `photo-<first photo>.png`,
`glossary.png`; then exit 0. Build this first; it is how the build is checked.

## Tests (Tests/IQCoachTests, Swift Testing)

- Decoding the repo's `results/results.json` (path from an environment variable
  `IQA_RESULTS`, skipped if unset): 389 rows, 19 camera groups, NaN mapped to nil.
- Each camera rule on a hand-built fixture that must fire and one that must not.
- Each editing rule likewise; "nothing to fix" on a clean fixture.
- Band thresholds at the boundaries.

## Build and run

```bash
cd mac/IQCoach && xcodegen generate
xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -configuration Debug -derivedDataPath build build
xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -derivedDataPath build test
build/Build/Products/Debug/IQCoach.app/Contents/MacOS/IQCoach --snapshot ../../results/results.json /tmp/iqcoach-snaps
open build/Build/Products/Debug/IQCoach.app
```

`project.yml`: one app target `IQCoach` (macOS 15.0, bundle id `com.allisonbowman.iqcoach`,
`GENERATE_INFOPLIST_FILE: YES`, `SWIFT_STRICT_CONCURRENCY: complete`, app sandbox disabled,
`CODE_SIGN_IDENTITY: "-"`), one test target depending on it. Assets: an app icon is not required for
the first build (a placeholder `AppIcon` set may be empty).
