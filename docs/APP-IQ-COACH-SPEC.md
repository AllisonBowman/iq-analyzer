# IQ Coach: a macOS app that coaches photography and editing from iq-analyzer results

Spec written 2026-10-14; rewritten 2026-10-23 to describe the shipped app after the discrepancy fixes
(`docs/DISCREPANCIES.md`, commits 95bf2f1 and 5a1800f) and the feedback layers
(`docs/FEEDBACK-LAYERS-SPEC.md`, all twelve steps). The app lives in `mac/IQCoach/`, is generated with
XcodeGen from `project.yml`, targets macOS 15, SwiftUI, Swift 6 strict concurrency, Swift Charts,
Swift Testing. No third-party packages. It reads `results.json` written by `python -m iqa analyze` and
can run the analyzer itself on a folder or on photos picked from the Photos library.

## Purpose, in the user's words

"I shot these photos on this camera. Tell me what it does well and badly, what to change when I
shoot, and what to do in my editing app to get the best out of each photo." The user is a
photographer, not an engineer. Each camera screen therefore opens with the one change most worth
making, says how sure that is in a word and a photo count, and lets her answer back ("that is
intended") or start a check that measures her next photos against a frozen baseline. Every number on
screen carries its qualifier ("at least", "43 of 206", "1 edge"), and every number comes from the
results file with its count; the app never invents a statistic.

## Inputs

1. **Open Results…** (⌘O): a `results.json` from iqa. The repo's `results/results.json` is the demo
   data set (389 rows, 19 cameras, fifth run, rewritten 23 Oct 2026 04:36). NaN arrives as the JSON
   token `NaN`; the decoder maps it, `null` and missing keys to nil. The file's modification date is
   kept as `PhotoLibrary.sourceDate` for the provenance lines.
2. **Analyze Folder…** (⇧⌘O): runs `<python> -m iqa analyze <folder> -r --out
   <AppSupport>/IQCoach/runs/<timestamp> --no-paths` through `Process`, streams progress, then opens the
   results. Python and repo paths are Settings (⌘,), validated before use. The app sandbox is off.
3. **Choose Photos to Analyze…** (⇧⌘P): the system Photos picker (up to 20); originals are copied to
   `<AppSupport>/IQCoach/photos/<stamp>/` and analysed with paths kept.
4. Photo thumbnails come from `path` when the file exists; otherwise a placeholder. Never fails on a
   missing file.

## Model (Sources/Model)

- `PhotoRecord`: every column the UI uses, including `clip_gamut_pct`, `mtf50_p80_ci_lo/hi_cpp`,
  `edges_measured/center/outer/candidates`, `edges_reject_reasons` and the structure fields.
  Computed: `hasSharpnessFigure` (3 or more valid edges, iqa/report.py `_sharp_ok`), gated sharpness
  and overshoot, `p80RangeLWPH` (2 x c/px x the short side, the scale of `mtf50_p80_lwph` since 23 Oct
  2026), `p80RelativeWidth`, `rejectReasons` (plain words per analyzer key; unknown keys kept raw),
  `snrIsClean` and `snrExclusionReason`, `key: PhotoKey` ("<camera_model>|<file>|<datetime>").
- `CameraSummary`: one constant, `minRowsForFigure = 5`, gates every report-card figure.
  - Sharpness and halo: rows with 3 or more edges; counts of counted, rough (1-2 edges) and none;
    middle half (IQR); median p80 interval width.
  - Noise: clean rows only (not extrapolated, texture-suspect or periodic), with exclusions by reason;
    SNR by ISO band (bands of 3 or more clean photos are "rated").
  - `snrFollowsISO`: true when no rated band median rises more than 1 dB above the band below it (a
    design choice), false when one does, nil with fewer than two rated bands.
  - Dynamic range: exact median when 5 or more rows reached the noise floor; otherwise "at least" the
    median of all rows, with the exact rows' median in the caption.
  - Whiteness above ISO 160 when 5 or more clean rows are there (FINDINGS §5 item 5).
  - Clipping counts, `gamutCount` (photos with more than 1 % of pixels beyond sRGB), formats.
- `PhotoLibrary`: `sourceDate`, `hasNativeClipping` (any row carries `clip_gamut_pct`: clipping counted
  in the file's own encoding, fifth run), `hasStructure`, coached and sparse cameras, `provenance`.
- ISO bands: ≤64, 65-160, 161-400, 401-1000, >1000 (FINDINGS.md). ISO settings are written "ISO 1400".
- `Metric`: name, meaning, definition (results/report.md wording), what good looks like, **how sure**,
  and `evidenceText(camera:)` / `evidenceText(photo:)` for the ⓘ popover. Bands, colour always with a
  word:
  - Sharpness is banded on c/px only (poor < 0.12, fair < 0.20, good < 0.30, excellent ≥ 0.30). LW/PH
    carries no band of its own: it is capped by the short side, so the per-pixel figure bands both rows.
  - SNR mid-grey (dB), one scale everywhere: poor < 25, fair < 32, good < 38, excellent ≥ 38.
  - Highlight and shadow clipping (%): excellent < 0.1, good < 0.5, fair < 2, poor ≥ 2. The tile's band
    grades the typical photo; how often photos clip is graded by the 15 % line.
  - Overshoot (%): excellent < 3, good < 8, fair < 12, poor ≥ 12. 12 % is the one visible-halo mark,
    used by the band, the camera card and the photo advice.
  - White-balance lean (stops): excellent < 0.1, good < 0.2, fair < 0.4, poor ≥ 0.4 for one photo; the
    camera tile shows the larger of the median R/G and median B/G, unbanded (the camera's rendering).
  - Whiteness: informational; 0.14 white grain, 0.3 smoothed, 0.4 heavily smoothed, above 0.7 texture.
  - Dynamic range and tonal range: informational; "at least" when a lower bound.
- `UserPreferences` (`preferences.json`, below), `CaptureCheck`.

## Evidence and effort (Sources/Coaching/Evidence.swift)

Evidence words are counts, never probabilities, and never collide with band or severity words:

- **Solid**: at least 20 photos passed the rule's gates (10 for direct pixel counts), the rule measures
  something direct, and for a share the 95 % Wilson range stays on one side of the rule's line.
- **Moderate**: 8 to 19 photos; or the rule rests on natural edges (sharpness, halo, lens comparison)
  or on an assumption a scene can break (gray-world colour, level edges). Those kinds never rise above
  Moderate.
- **Thin**: fewer than 8 photos, or a share whose range crosses the line. Thin findings are never the
  one thing; they sit under "Needs more photos", say "Try this" and carry "What would change this".

Effort: **At the camera**, **Set up once**, **In the editor**. Camera-side wording comes from
`CameraVocabulary`, keyed by `CameraGroup.isPhone` (sun slider, Settings > Camera Grid and Level; no
white-balance preset and no sharpness setting on phones).

## Camera rules (Sources/Coaching/CameraRules.swift)

Each rule is a pure function of a camera and the intent tags (`RuleContext`) and returns `.fired(Insight)`,
`.silent(SilentCheck)` (a reason with its numbers) or `.notApplicable`. Every insight carries severity,
evidence grade and kind, counted of total (the side the claim rests on), exclusions, actions with
effort, a five-part "Why am I seeing this?" (`WhyShown`: the rule, what was counted, how sure, what it
cannot tell, check it yourself), and, where it can be the one thing, an imperative, a prevalence and a
check kind. Cameras under 5 photos get no rules.

1. **Noise by ISO** (was "ISO ceiling"). Clean rows, rated bands. If noise does not follow ISO: "Noise
   does not follow ISO on this phone/camera", Good to know, listing every band; when the top band has
   fewer than 10 photos it gives their range and says it is too few to say where grain starts; the
   at-camera line claims "every band up to ISO 1000 is 32 dB or more" only when it is true. If it
   follows: the ceiling is the top of the unbroken run of bands, from the lowest, at or above 32 dB; the
   open-ended band is checked at the highest ISO actually used (D850: clean to ISO 1400, the ISO 9000
   frame 29.6 dB); "clean at every ISO you have used" when nothing falls. "Visible at every ISO" is
   Important only when the lowest band is under 25 dB. "Higher ISO amplifies the grain" appears only for
   a camera whose noise follows ISO.
2. **Noise smoothing.** Whiteness above ISO 160 when 5 or more clean rows exist, otherwise all ISOs
   with the texture caveat. Editor actions only; "Keep ISO low for texture subjects" is gone.
3. **Lens comparison** (phones, back lenses only, each on rows with 3 or more edges; a lens needs 3).
   Gaps under 15 % are a tie. The front camera and lenses with no such rows are named "not compared".
4. **Field softness.** Rows with 3 or more edges in both centre and outer frame; a finding at 5 on one
   lens and a median under 0.80; a Thin card at 1 to 4 rows in all.
5. **Highlights** and **6. Shadows.** More than 15 % of photos over 1 %; Wilson range against the 15 %
   line decides Solid or Thin; photos tagged bright (or dark) on purpose are left out and the footer
   says how many; representative examples among the photos over 1 %; device wording. Clipping is
   described as "at the top of the range in at least one colour channel, counted in the file's own
   encoding", never as "pure white" (any channel at 254 is not pure white).
7. **Sharpening.** Median overshoot over 5 or more gated rows above 8 %; a visible halo from 12 %. No
   at-camera action on phones. Representative examples.
8. **Colour lean.** Median R/G or B/G beyond 0.15 stops, leaving out photos tagged "colour is the
   point". Gray-world, capped at Moderate. A white-balance preset only for non-phones.
9. **Slow shutter** (phones, back lenses). Photos at 1/30 s or slower against faster photos from the
   same lens, 3 or more edges on both sides. A finding at 8 slow photos and a 20 % gap; Thin below 8;
   no "hand-held" claim.
10. **Aperture** per lens on gated rows; silent with the apertures used when there is nothing to compare.
11. **Level-edge lean** (was "horizon lean"). "Level edges", left and right counts, a sign test: a habit
    (Worth acting on) only when the split is lopsided beyond chance (p < 0.05); otherwise Good to know.
    Set-up-once action. Photos tagged "not meant to be level" are left out.
12. **Shallow depth of field** at 30 % of photos with a sharp/soft split.

The former "Read single-photo sharpness loosely" card is removed; the p80 range lives in the
sharpness tile caption and popover.

## Engine output and the one thing (Sources/Coaching/CoachingEngine.swift)

`CoachingEngine.output(for:prefs:) -> CoachingOutput { oneThing, cards, needsMorePhotos, setAside, silent }`.

- Eligible for the one thing: Worth acting on or Important, not Thin, an action at the camera or set
  up once, not set aside, and a prevalence of at least 10 % of the camera's photos.
- Ranking: severity, evidence word, then a fixed order (highlights, shadows, ISO, level edges, lens
  choice, others). Highlights before shadows is a stated design choice.
- "Next up" is the second eligible card; otherwise "Also good to know" with the Solid card about
  shooting that comes first in the fixed order; otherwise nothing.
- Fallbacks: "No single change stands out yet" with the likeliest Thin candidate, or with "every
  finding rests on fewer than 8 photos"; "No single change stands out" with the clipping counts and,
  when there is no sharpness figure, why.
- Set-aside cards come back when their count grows 25 % or their severity or evidence word changes,
  carrying "Back because the evidence changed: …". Nothing is deleted.
- Library headline: cameras with 5 or more photos and two rated bands, split by `snrFollowsISO`.

On this library: the iPhone 17 Pro Max and iPhone 13 get "Expose for the highlights" (54 of 206, 23 of
85), each with "Also good to know: noise does not follow ISO…"; the D850, the iPhone XR (highlights
Thin: 6 of 21, range 14 to 50 %) and the SEALIFE get fallbacks; no camera fires the shadows rule.

## Photo advice (Sources/Coaching/EditingRules.swift)

`EditingRules.advice(for:context:) -> PhotoAdvice { doFirst, also, silenced, checked, notMeasured }`,
with `PhotoContext` (the camera's usual lean, the library's colourfulness median, Vision's horizon,
intent tags). Each `EditingAdvice` has a grade, an edit step and the intent tag that silences it.

- Grades: Solid for blown highlights, crushed shadows, exposure and flat tones (pixel counts); Moderate
  for noise (clean readings only), soft and halo (3 or more edges) and moiré; Thin for colour lean,
  level edge (Moderate when Vision's horizon agrees within 1°), composition and shallow depth of field.
- Do first: the top two non-Thin by evidence, then band (Poor before Fair), then edit order. Both lists
  are shown in the fixed edit order: white balance, exposure, highlights and shadows, noise,
  sharpening, straighten, composition. "Nothing here needs fixing" when Do first is empty.
- Colour lean fires only when the photo differs from its camera's usual rendering by more than 0.15
  stops, and says the subject's own colour is likely from colourfulness 60 (library median 39).
- Checked, nothing to do: only rules that did not fire, each with value and line; a value never
  rounds onto its line ("11.99 % (acts at 12 or above)").
- Not measured: sharpness with the candidate count and the plain-word rejection reasons; noise with
  its exclusion reason.
- Wording kept from the discrepancy fixes: clipping as "at the top of the range in at least one colour
  channel"; colour beyond sRGB is "in the file, not lost detail"; Apple Photos Black Point is lowered
  for crushed shadows and raised for flat tones; slider amounts say "starting around".

## Capture checks (Sources/Coaching/CheckComparison.swift, Sources/Views/CheckCard.swift)

Only shares are compared: highlights (`clip_high_pct > 1`), shadows (`clip_low_pct > 1`) and level
edges (a degree or more, among photos with a level edge). Sharpness, noise and dynamic range are not.

- **Start a Check…** freezes the baseline (with that moment's intent exclusions); it is disabled with
  the reason when the results lack native clipping or structure.
- Loading results counts new photos into active checks: same camera, dated after the start, not
  tagged with the check's intent; undated photos are counted apart; the same photo counts once.
- Verdicts, fixed in advance with Newcombe's 95 % range on after minus before: Keep shooting (under 10
  new photos), Not comparable, It worked (range below zero and a drop of 10 points or more), A small
  drop, Higher than before, Not settled yet (adds "about the same so far" within 5 points). A format
  caveat appears when the JPEG share differs by more than 30 points. No notifications, no badges.

## Preferences (Sources/Support/PreferencesStore.swift)

`~/Library/Application Support/IQCoach/preferences.json`: editor, set-aside cards (with a snapshot
for the come-back rule), intent tags by `PhotoKey`, checks. Atomic writes debounced by a second; a file
that does not decode is moved aside as `preferences.bad-<stamp>.json`. Settings has **Reset
Preferences…** behind a confirmation. Intent tags: Dark on purpose, Bright on purpose, Colour is the
point, Not meant to be level, Composed this way; each silences the matching photo advice and is left
out of the matching camera rule and checks. The report card still counts every photo.

## UI (HIG; SwiftUI; dark and light; VoiceOver labels)

- **Sidebar**: Library, then "Cameras" (5 or more photos) and "Too few photos". Each row's tooltip is
  its one-thing sentence.
- **Camera screen**, in order: header with provenance ("From results.json, written … · 206 photos,
  shot … to …"); **The one thing** (sentence, detail, severity, `EvidenceCapsule`, effort, the action,
  Next up, Start a Check…, Open the Proof, More > That Is Intended…); **Your check** cards; **Report
  card** (six tiles through `MeasuredValue`, each with a coverage caption, "Not enough photos" under 5);
  **Coaching** cards (header with severity and evidence, finding, Why, `ActionGroups` by effort,
  examples, What would change this, footer with Counted, Why Am I Seeing This? and More), then the
  disclosures Needs more photos, You set aside (Bring Back) and "n checks had nothing to say"; content;
  charts; the photos table. A camera with fewer than 5 photos shows its photos' own figures, "Coaching
  starts at 5 photos" and Choose Photos to Analyze….
- **Photo screen**: photo with overlay picker and caption (clipping caption separates blown pixels
  from colour beyond sRGB, which the colour-managed mask does not mark); file and settings; intent
  capsules; **Do first** with the editor picker and numbered steps; **Also**; **You marked as
  intended** (Show Anyway); **Checked, nothing to do**; **Not measured**; **Measurements** (every row a
  `MeasuredValue`; sharpness with the photo's own range); Structure; What is in the picture. Toolbar:
  **Copy Editing Steps**.
- **How sure**: hover a title for its meaning; the ⓘ popover has Meaning, What good looks like, How
  sure, In this camera / In this photo, and Open the Glossary. The Glossary window has **Metrics** and
  **Method** tabs; Method holds report.md's "How to read these numbers" verbatim, the evidence and
  effort definitions, the one-thing rules and the check rules.
- **Library**: provenance, the headline, a table with a "One thing" column and counted sharpness cells
  ("1,966 LW/PH · Good (43)"), camera tiles, the SNR-vs-ISO chart.
- **Share** (toolbar menu): the full coaching report and a five-line pocket card as Markdown.
- Every number is formatted with `formatted()` and a unit; colour is never the only signal.

## Snapshot mode

`IQCoach --snapshot <results.json> <outdir>` renders `library.png`, `camera-<first camera>.png`,
`onething.png` (every coached camera's one thing), `check.png` (a fixture check: 1 of 20 new photos
blown against 54 of 206, "It worked"), `sparse-<camera>.png` (the most-photographed camera under five
photos), `photo-<photo>.png` and `glossary.png`, then exits. AppKit-backed controls are replaced by
plain views and disclosures render expanded.

## Tests (Tests/IQCoachTests, Swift Testing)

189 tests. Real-data tests read `IQA_RESULTS` (passed as `TEST_RUNNER_IQA_RESULTS`) and return early
without it. They pin the gates (43 counted photos and 1,966 LW/PH on the 17 Pro Max, 20 and 1,861 on the
iPhone 13, the XR's "Not enough photos (3)", the D850's "At least 8.6 stops"), Wilson and every
Newcombe row of the check table, the evidence boundaries, every rule firing and staying silent with
numbers, the one thing per camera and the headline, the photo lists, preferences round trips, the
come-back rule, intent exclusions, checks and the three exports.

## Build and run

```bash
cd mac/IQCoach && xcodegen generate
xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -configuration Debug -derivedDataPath build build
TEST_RUNNER_IQA_RESULTS=$PWD/../../results/results.json \
  xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -derivedDataPath build test
build/Build/Products/Debug/IQCoach.app/Contents/MacOS/IQCoach --snapshot ../../results/results.json "$TMPDIR/snaps"
open build/Build/Products/Debug/IQCoach.app
```

## Still to confirm before shipping

- Eye checks the data cannot make: five 17 Pro Max frames among the 17 with crushed shadows; ten
  photos at colourfulness 60 or more; Vision's horizon sign on a real photo (the app assumes Vision's
  angle is counter-clockwise, so a right-end-lower edge agrees with a negative angle); the iPhone paths
  in `CameraVocabulary` on the phone.
- The c/px sharpness bands were set before LW/PH moved to the short side; they band c/px, which did not
  change, but a chart shoot is the real check.
