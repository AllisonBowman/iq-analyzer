# IQ Coach feedback layers: the shipping spec

Spec date: 2026-10-15. Base: "One change first, the proof second, the method on demand" (judge totals 43 + 41 + 39 = 123; the experiments loop scored 108, Trust Layer 96, Moves 94).

**What is grafted in.** Every best idea that all three judges agreed on:
- "That is intended" with Undo, and a stated rule for when a set-aside card comes back.
- Before/after checks with intervals and verdict rules fixed in advance, limited to the high-count pixel metrics.
- Prevalence gating of the one-thing ranking.
- A not-comparable gate on analyzer version, and a caveat line on format mix.
- Representative example photos instead of extremes.
- No white-balance-preset advice on phones.
- "Check it yourself" lines.
- A list of checks that had nothing to say.
- Plain-word edge rejection reasons.
- Bands taken from the file's own p80 intervals.
- Per-photo intent tags.
- Coverage lines on every figure.
- "Skipped, and why" and a fixed edit order on the photo screen.
- Markdown checklist export with a provenance footer.

**What is dropped.** Everything any judge called untruthful (list in §8).

**How the numbers were checked.** Every number below was recomputed from `results/results.json` (fifth run, 389 rows, 19 cameras; rewritten 23 Oct 2026 04:36 after two corrections: `clip_low_pct` restored to the all-channels definition, and `mtf50_p80_lwph` put on the short side, FINDINGS §8 and §9) with `.venv/bin/python`. The first version of this spec (15 Oct) quoted the withdrawn any-channel shadow counts and height-based LW/PH; on current data the shadows rule fires for none of the four main cameras, which changes the one thing for the NIKON D850 and the iPhone XR and the "Next up" line for both iPhones. It was also checked against the Swift sources under `mac/IQCoach/Sources`. Two judge corrections did not reproduce:
- The gated sharpening halo on the iPhone 17 Pro Max is 10.7 % over 43 photos, not 11.1 % over 42. It matches FINDINGS §2.
- `mac/IQCoach/README.md` states no test count. The stale "43" is in `CLAUDE.md`; the real count is 77 `@Test`s.

The rendered screens in `/tmp/iqcoach-snaps5` (01:30) predate the fifth run. They still show "0.81 %" and "44 % of photos lose more than 1 %", and they also show the plural typo "4 lenss". Regenerate them before anyone reviews copy.

---

## 1. Thesis

Each camera screen opens with the one change most worth making. Next to it are a word and a photo count for how sure that is, and every number on screen carries its qualifier ("at least", "43 of 206", "1 edge").

The photographer can answer back ("that is intended", "dark on purpose"). She can also start a check that measures her next photos against a baseline frozen at the start. A rule she can read, set in advance, decides whether the change worked or whether it is too early to tell.

---

## 2. The layers, in order of attention

| # | Layer | Column | Question it answers |
|---|---|---|---|
| 1 | The one thing | Content, top of each camera | What single change would most improve my pictures from this camera, and can I trust it? |
| 2 | Your check | Content, under layer 1 (only once started) | Did the change work, or is it too early to tell? |
| 3 | Report card with coverage lines | Content | What are this camera's numbers, and how much of my library stands behind each? |
| 4 | Coaching cards | Content | Why does the app say that, what exactly do I do (at the camera, once in settings, in the editor), and why am I seeing it? |
| 5 | Photo: Do first, Also, Checked | Detail | What do I do to this picture, in what order, and what should I leave alone? |
| 6 | How sure (tooltip, then popover, then Glossary "Method") | Everywhere | What does this number mean, how sure is it, and how was it measured? |
| 7 | Library headline and sparse cameras | Content (Library), sidebar | Which camera does what, and why do some cameras get no coaching? |

The sidebar gains one structural change: a second section, "Too few photos", lists the 11 cameras with fewer than 5 photos.

### Layer 1: The one thing

**What she sees.** Under the camera name and a provenance line, above the report card, one card shows:
- One sentence that starts with a verb.
- One capsule (severity and evidence, with the photo count).
- An effort label.
- The single action, written in this camera's vocabulary.
- A "Next up" line.
- Buttons: **Start a Check…** (prominent), **Open the Proof**, and a "More" menu with **That Is Intended…**.

The same sentence appears as a "One thing" column in the Library table, as the `.help` tooltip on the camera's sidebar row, and first in the Markdown export.

**Question.** If I change one thing about how I shoot with this camera, what should it be, and how sure is the app?

**Data and rules.**
- Input is `CoachingEngine.output(for: CameraGroup, prefs: UserPreferences) -> CoachingOutput`; its `oneThing: OneThing?` is chosen from `cards` (§4.5).
- An insight is eligible only if all of these hold:
  - `severity >= .notice`.
  - `grade != .thin`.
  - It has an action with effort `.atCamera` or `.setUpOnce`.
  - It is not set aside.
  - Its `prevalence` (the share of the camera's photos showing the behaviour the action changes) is at least 10 %. This is why an ISO ceiling is never offered to a camera whose photos are almost all under it. On the 17 Pro Max, 197 of 206 photos are at ISO 1000 or below.
- Ranking order:
  1. Severity.
  2. Evidence word.
  3. A fixed rule order: highlights, shadows, ISO ceiling, level edges, lens choice, others.

  Highlights come before shadows as a stated design choice: bright areas draw the eye, while dark areas are often the look. The Glossary says so.
- "Next up" is the second eligible insight. If none exists, the line reads "Also good to know" with the strongest Solid info card. If no card at all is eligible, the fallback sentence below is used.
- Columns used:
  - `clip_high_pct` and `clip_low_pct` against the 1 % line.
  - `iso`.
  - `structure_horizon_tilt_deg`.
  - `edges_measured`.
  - `mtf50_p80_lwph` (only through the eligible rules).

**UI.**
- New `Sources/Views/OneThingCard.swift`:
  - A `GroupBox` labelled `Label("The one thing", systemImage: "scope")`.
  - The sentence in `.title2.weight(.semibold)` with `.fixedSize(horizontal: false, vertical: true)`.
  - `EvidenceCapsule` and `EffortLabel`, then the action in `.body`, then a `Divider`, then "Next up" in `.callout` `.secondary`.
  - An `HStack` of three controls:
    - `Button("Start a Check…")` with `.borderedProminent`, the one default action per view. It appears only when the insight has a `checkKind`.
    - `Button("Open the Proof")`, which calls `proxy.scrollTo(insight.id, anchor: .top)` from a `ScrollViewReader` wrapping the camera column. Cards get `.id(insight.id)`.
    - A trailing `Menu { Button("That Is Intended…") } label: { Image(systemName: "ellipsis.circle") }` with `.menuStyle(.borderlessButton)`.
- A 4 pt accent bar on the leading edge marks the card. Meaning is never carried by colour alone.
- Accessibility: `.accessibilityElement(children: .combine)`, with the label spelled out (see copy) and `.accessibilityAddTraits(.isHeader)`.
- Button titles use title-style capitalisation, per the macOS HIG.
- Snapshot mode renders plain views, following the existing `isSnapshot` pattern.

**Copy, with this library's numbers.**

*iPhone 17 Pro Max:*
- Sentence: "**Expose for the highlights.** 54 of your 206 photos (26 %) have more than 1 % of the frame blown to pure white, and a JPEG or HEIC cannot bring that back."
- Capsule: "Worth acting on · Solid · 206 photos". Effort: "At the camera".
- Action: "On bright scenes, tap the subject and drag the sun slider down before you shoot."
- Next up: no second card is eligible (shadows are silent at 17 of 206 photos, 8 %; the smoothing and sharpening cards have only editor actions), so the line reads: "Also good to know: noise does not follow ISO on this phone; up to ISO 1000 every ISO band has a median of 32 dB or more."
- VoiceOver: "The one thing for iPhone 17 Pro Max. Expose for the highlights. 54 of your 206 photos, 26 percent, have more than 1 percent of the frame blown to pure white. Worth acting on. Solid evidence, 206 photos. At the camera."

*iPhone 13:*
- "**Expose for the highlights.** 23 of your 85 photos (27 %) have more than 1 % of the frame blown to pure white…"
- Capsule: "Worth acting on · Solid · 85 photos".
- Next up: "your level edges lean left by 2.1° (26 photos with a long level edge)." Shadows are silent here: 6 of 85 photos (7 %).

*NIKON D850 (fallback).* No card is eligible. Highlights do not fire: 3 of 36 is under the 15 % line. Shadows do not fire: no photo has more than 1 % crushed to pure black. Only one photo has a long level edge and only one has a sharpness figure, so the level-edge and sharpness rules are silent or Thin.
- "**No single change stands out.** Your 36 photos rarely clip: 3 have more than 1 % blown to white and none loses its shadows. Sharpness needs scenes with straight edges; water, sky and foliage give the method nothing to measure."
- "Also good to know: noise falls with ISO the way a sensor's does, and every ISO band you used has a median above 32 dB."

*iPhone XR (fallback).* Highlights are Thin here: with 21 photos the 95 % range is 14 to 50 %, which straddles the 15 % line. Shadows do not fire (none of 21 photos over 1 %), and the 12 level edges show no lean (median 0.0°).
- "**No single change stands out yet.** The likeliest candidate, blown highlights, needs more photos: 6 of your 21 have more than 1 % blown to white, and with 21 photos the share could be anywhere from 14 to 50 %."
- "Needs more photos: blown highlights (6 of 21; with 21 photos the share could be anywhere from 14 to 50 %)."

*SEALIFE DC2000, 5 photos (fallback):* "**No single change stands out yet.** Every finding for this camera rests on fewer than 8 photos, so they are listed under Needs more photos. Add photos from this camera with Choose Photos to Analyze… to get coaching you can act on."

**Caveat it carries.** The capsule always shows the photo count, and evidence words are defined as counts (§4.2), never as probabilities. The sentence comes from a rule whose "Why am I seeing this?" popover states its threshold and limits.

### Layer 2: Your check (before and after)

**What she sees.** Once she starts a check, a card sits directly under layer 1. It shows:
- The baseline share with its 95 % range.
- The new photos counted so far (with a progress bar to the first look at 10).
- Once there are 10 or more: the after share, the difference with its range, and a verdict in words.
- A strip of the new photos with each one's value, worst first.
- A "How I decide" disclosure.

The full design is in §5.

**Question.** I changed how I shoot. Did it work?

**Caveat it carries.** The rule is shown verbatim. Ten photos give only a first look, and a lower share can also mean different scenes (fewer white pages or screens). The photo strip lets her see which.

### Layer 3: Report card with coverage lines

**What she sees.**
- The six tiles stay: in-focus sharpness, noise, blown highlights, sharpening halo, colour lean, dynamic range.
- Each tile's number is drawn by one `MeasuredValue` view, so a qualifier cannot be dropped.
- Each tile ends in a caption that says what the median is a median of, what was left out, and the one caveat that matters.
- When fewer than 5 photos pass a metric's gate, the tile shows "Not enough photos" and says what to shoot instead of showing a median.
- The section subtitle becomes "Each figure says how many of the 206 photos it rests on."

**Question.** What are this camera's numbers, how much of my library is behind each one, and which ones should I read loosely?

**Data and rules.** The rules live in `CameraSummary` in `Sources/Model/CameraGroup.swift`. One constant, `CameraSummary.minRowsForFigure = 5`, applies to every figure.

| Tile | Gate (rows that count) | Columns |
|---|---|---|
| In-focus sharpness | `edges_measured >= 3` (matches report.md and FINDINGS §5 item 2) | `mtf50_p80_lwph`, `mtf50_p80_cpp`, `edges_measured` |
| Noise | `snrIsClean` (not extrapolated, texture-suspect or periodic) | `snr_midgrey_db`, `snr_midgrey_extrapolated`, `noise_texture_suspect`, `noise_periodic_suspect` |
| Blown highlights | All rows | `clip_high_pct`, `clip_gamut_pct` |
| Sharpening halo | `edges_measured >= 3` | `overshoot_median_pct` |
| Colour lean | Rows with WB, minus photos tagged "Colour is the point" | `wb_r_over_g_stops`, `wb_b_over_g_stops` |
| Dynamic range | Exact median when at least 5 rows have `dr_snr4_lower_bound == false`. Otherwise "At least" the median of all rows. | `dr_snr4_stops`, `dr_snr4_lower_bound` |

`LensGroup.p80Sharpness` and `sharpnessCount` use the same three-edge gate.

**UI.**
- `MetricTile` replaces `detail` with:
  - `evidence: String` (a caption, `.secondary`).
  - `qualifier` (rendered by `MeasuredValue` as a prefix such as "At least ").
  - `notEnough: String?` (replaces the value, scale and band).
- `minHeight` rises from 176 to 196 pt.
- `spokenSummary` appends the evidence sentence.
- Colour stays paired with the band word, as today.

**Copy (iPhone 17 Pro Max).** Today's screen shows 1,604 LW/PH (Fair) for sharpness, over 85 rows including 42 rows with one or two edges.

- **In-focus sharpness.** "1,966 LW/PH · Fair". Caption: "From the 43 of 206 photos with 3 or more usable edges; 42 more had only 1 or 2 and are not counted, 121 had none. Read from real edges in your scenes, so it is a lower bound on the lens."
- **Noise (SNR).** "34.5 dB · Good". Caption: "167 of 206 photos; 39 left out (17 where mid-grey had to be estimated, 17 with textured flat areas, 5 with a repeating pattern). Compares this phone's processing, not its sensor."
- **Blown highlights.** "0.47 % · Good (median)". Caption: "Counted pixel by pixel in the file's own encoding. 54 of 206 photos (26 %) lose more than 1 %. 47 photos also hold colour that sRGB cannot show; that is not lost detail."
- **Sharpening halo.** "10.7 % · Fair". Caption: "Median over the 43 photos with 3 or more usable edges. Above 8 % the phone is sharpening hard, and part of the sharpness figure is that sharpening."
- **Colour lean.** "0.2 stops · Good". Caption: "Renders slightly warm: B/G −0.17 stops, R/G +0.04, over 206 photos. Gray-world: single-colour scenes push it."
- **Dynamic range.** "7.2 stops". Caption: "From the 36 photos dark enough to reach the noise floor; the other 170 only show 'at least' (median at least 6.7). No pass mark."

**Copy (NIKON D850).**
- **In-focus sharpness.** "Not enough photos". Caption: "1 of 36 photos had 3 or more usable edges (it measured 2,377 LW/PH); 3 had 1 or 2, and 32 had none. Scenes without straight edges, such as water, sky and foliage, give the method nothing to measure. Photograph something with straight edges, such as a building, a sign or a bookshelf, to get a figure."
- **Dynamic range.** "At least 8.6 stops". Caption: "Only 1 of 36 photos reached the noise floor (3.9 stops in that frame); the other 35 only set a lower bound. Not comparable with other cameras." Today the tile shows "3.9 stops" from that one row.

**Copy (iPhone XR).** Today: 601 LW/PH, Poor.
- **In-focus sharpness.** "Not enough photos". Caption: "3 of 21 photos had 3 or more usable edges (median 1,685 LW/PH); 7 more had 1 or 2, and 11 had none. A camera figure needs 5."

**Caveat it carries.** Per-tile, as written. The sharpness tile's ⓘ popover holds the per-photo band (layer 6). The separate "Read single-photo sharpness loosely" card is removed: it quoted the median-MTF50 interval width (0.61) while every figure on screen is p80 (0.36 wide).

### Layer 4: Coaching cards (claim, proof, what to do)

**What she sees.** Cards are sorted by severity, then evidence word. Each card has:
- **Header.** Severity symbol and title; at the trailing edge, the severity word and `EvidenceCapsule` ("Solid · 206 photos").
- **Body.** The finding with numbers, then "Why" in `.secondary`.
- **Actions.** "What to do", grouped under up to three effort headings: "At the camera", "Set up once", "In the editor". Thin cards say "Try this" instead.
- **Examples strip.** Representative photos, not extremes.
- **"What would change this".** Thin cards only.
- **Footer row.**
  - "Counted: n of N photos" (plus "k you marked … are left out" when intent tags apply).
  - **Why Am I Seeing This?** (`questionmark.circle`, opens a popover).
  - A "More" menu holding **That Is Intended…** and, for cards with a `checkKind`, **Start a Check…**.

Below the cards come three disclosures:
- "Needs more photos (n)".
- "You set aside (n)".
- "n checks had nothing to say".

**Question.** Why does the app say this, which of my photos show it, how sure is it, and what exactly do I do, and where?

**Data and rules.** Rule-by-rule changes are in §4.6. The "Why am I seeing this?" popover is filled from `Insight.why: WhyShown` (§4.4).

**UI.**
- `InsightCard` keeps `Card`/`GroupBox` and gains:
  - `EvidenceCapsule(grade:counted:)`.
  - `ActionGroups(actions:)`: one `Label(effort.word, systemImage: effort.symbol)` heading per effort in use, with bullets under each.
  - `WhyButton` and `WhyPopover` (360 pt wide, the same style as `MetricDefinition`; Esc closes it).
  - The "More" `Menu`.
- `CameraReportView` then shows:
  - `DisclosureGroup("Needs more photos (\(n))")`.
  - `DisclosureGroup("You set aside (\(n))")`, where each card is collapsed to title, date, note and a **Bring Back** button.
  - `DisclosureGroup("\(n) checks had nothing to say")`.
- In snapshot mode each disclosure renders expanded, as plain views.
- Accessibility: `.accessibilityElement(children: .contain)` on the card. The header is one element: "Worth acting on. Highlights are often blown out. Solid evidence, 206 photos."

**Copy (iPhone 17 Pro Max, as shipped).**

1. **Highlights are often blown out.** Worth acting on · Solid · 206 photos.
   - Finding: "54 of your 206 photos (26 %) have more than 1 % of the frame blown to pure white."
   - Why: "Pure white holds no detail, and a JPEG or HEIC cannot bring it back. The camera exposes for the average of the scene, so skies, windows and white pages run out first."
   - At the camera: "On bright scenes, tap the subject and drag the sun slider down before you shoot."
   - In the editor: "For photos you already have, follow each photo's Highlights step."
   - Examples: four photos closest to the median of the 54 (1.6 %, 1.6 %, 1.6 %, 1.7 %), not the 14.7 % white page.
   - Footer: "Counted: 206 of 206 photos."
   - Why Am I Seeing This? popover:
     - "**The rule.** Appears when more than 15 % of a camera's photos have over 1 % of the frame at pure white (any channel at 254 or above, counted in the file's own encoding)."
     - "**What was counted.** All 206 photos; clipping is counted on every pixel, so none is left out."
     - "**How sure.** Solid: 206 photos, and allowing for chance the share is between 21 and 33 %, clear of the 15 % line."
     - "**What it cannot tell.** Whether the white was a sky you wanted, a white page or a screen; the examples show which kind yours are."
     - "**Check it yourself.** Shoot the same bright scene twice, once as it comes and once with the sun slider pulled down, and analyze both."
2. **The phone smooths grain away.** Worth acting on · Solid · 59 photos.
   - Finding: "Noise smoothing is 0.44 above ISO 160 (median over 59 photos; untouched grain reads 0.14): the phone removes grain by blurring it."
   - Why: "Blurring cannot tell grain from fine texture such as hair, foliage and fabric, so a clean noise figure can hide lost texture. Below ISO 160 this measure is unreliable: the noise is too faint to separate from the scene's own fine detail."
   - In the editor: "Do not add noise reduction to photos that look clean; the phone has already applied it."
   - The current action "Keep ISO low for texture subjects" is removed: the data cannot support it (§8).
3. **This phone sharpens hard.** Worth acting on · Moderate · 43 photos.
   - Finding: "Edges overshoot by 10.7 % (median over the 43 photos with 3 or more usable edges), which shows as a bright fringe when enlarged."
   - Why: "Part of the sharpness figure is this sharpening, not the lens."
   - In the editor: "Do not add sharpening." and "Downsize for the web with a soft resampler so the fringes do not double."
   - No at-camera action on phones; the Camera app has no sharpness setting.
4. **Noise does not follow ISO on this phone.** Good to know · Solid · 167 photos.
   - Finding: "Median noise is 33.6 dB at ISO 64 and below (44 photos), 32.0 dB at ISO 65–160 (71), 36.7 dB at 161–400 (28) and 36.8 dB at 401–1000 (16); above ISO 1000 your 8 photos range from 21.6 to 40.8 dB, too few to say where grain starts."
   - Why: "The phone's noise reduction rises with ISO and holds the output roughly level, so this figure compares its processing, not its sensor; that is why mid-ISO frames read cleaner than base ISO."
   - At the camera: "Do not chase a low ISO for clean pictures on this phone: up to ISO 1000 every ISO band has a median of 32 dB or more."
   - What would change this: "10 or more photos above ISO 1000."
   - Check it yourself: "Photograph the same plain wall in bright light and in dim light and analyze both; the phone will pick different ISOs."
5. **Your main and ultra-wide cameras resolve the same detail.** Good to know · Moderate · 10 photos.
   - Finding: "Counting only photos with 3 or more usable edges, the ultra-wide reads 2,158 LW/PH (10 photos) and the main camera 1,956 LW/PH (33 photos): a 9 % gap, inside the 15 % measurement band. The telephoto and front cameras have no photo with 3 usable edges, so they are not compared."
   - What would change this: "5 telephoto photos of scenes with straight edges."
   - Today this card ranks the ultra-wide first at 1,778 and lists the front camera at 1,269; both figures include one- and two-edge rows.
   - With the height-based LW/PH used before 23 Oct the order was reversed (main 2,608, ultra-wide 2,532): portrait frames, most of the main camera's, read 1.33x higher. The short side puts both on one scale.
6. **Colours lean slightly warm.** Good to know · Moderate · 206 photos.
   - Finding: "Across 206 photos the gray-world balance leans warm: B/G −0.17 stops, R/G +0.04."
   - Why: "Part of any lean is the light you shoot in; a lean that holds across many scenes is the phone's rendering."
   - In the editor: "Where greys should look neutral, use the white-balance picker on something grey or white."
   - No white-balance-preset action on phones; the Camera app has none.
   - Check it yourself: "Photograph a sheet of white paper in daylight; if it comes out warm, the lean is the phone."

**Needs more photos (2).**
- **Corners may be softer than the centre.** Thin · 3 photos.
  - "Only 3 photos have 3 or more usable edges in both the centre and the outer frame; on those, the outer edges measured 47 %, 55 % and 63 % of the centre. Edges near the frame's edge are also more often out of focus, so three photos cannot separate the lens from depth of field."
  - Try this: "Photograph a bookshelf, a brick wall or a page of text filling the frame, square on, and analyze it."
  - What would change this: "5 photos with straight edges both in the middle and near the corners."
- **Slow shutter speeds may cost sharpness.** Thin · 1 photo.
  - "16 of your 206 photos were taken at 1/30 s or slower; only 1 had 3 or more usable edges (923 LW/PH, against 1,995 LW/PH over 42 faster photos). One photo cannot show a pattern."
  - Try this: "In dim light, take the same scene twice, once hand-held and once braced against a wall, and analyze both."
  - What would change this: "5 slow photos of scenes with straight edges."

**4 checks had nothing to say.**
- "Crushed shadows: 17 of 206 photos (8 %; between 5 and 13 % allowing for chance) have more than 1 % pure black, under the 15 % line."
- "Level-edge habit: in the 119 photos with a long level edge, 43 lean left and 42 lean right by a degree or more (median 0.0°), so there is no habit to correct. Each photo's own note still gives its angle."
- "Shallow depth of field: 25 of 206 photos (12 %) split into a sharp subject and a soft background; this note appears at 30 %."
- "Aperture: each lens with measurable photos was used at one aperture (main f/1.8, ultra-wide f/2.2), so there is nothing to compare."

**Copy (iPhone 13 level edges).** "**Your level edges lean left by 2.1°.**" Worth acting on · Moderate · 26 photos.
- Finding: "In the 26 photos with a long level edge, 15 lean left by a degree or more and 7 lean right (median 2.1°, left end lower)."
- Why: "A lean that consistent points to how the phone is held. A level edge is not always a horizon: table tops, shelves and window frames seen at an angle count too, so check the examples."
- Set up once: "Settings > Camera: turn on Grid and Level, and line a straight edge up with them before you shoot."
- In the editor: "Straighten only photos whose edge should be level; each photo's note gives the angle."

**Set-aside copy.**
- The sheet: "This card moves to You set aside and stops being the one thing. It stays counted in the report card. It comes back on its own if the evidence changes: the photo count grows by a quarter, or its severity or evidence word changes."
- Collapsed card: "Highlights are often blown out · set aside 15 Oct 2026 · 'snow and beach days' · Bring Back."
- On return: "Back because the evidence changed: you set this aside at 54 of 206 photos (26 %); it is now {k} of {n} ({p} %)."

**Caveat it carries.** Every card states its counted photos. Edge-based cards say "lower bound". The ISO and noise cards say "processing, not sensor". Level-edge cards say "not always a horizon". Colour cards say "gray-world".

### Layer 5: Photo screen: Do first, Also, Checked

**What she sees.** Order in the detail column:
1. The photo with its overlay picker and caption.
2. File name and settings.
3. Intent capsules (if any).
4. **Do first.** Up to two numbered steps, shown in edit order.
5. **Also (n).** Collapsed.
6. **Checked, nothing to do (n)** and **Not measured (n)**. Collapsed.
7. **Measurements.** Sharpness / Noise / Exposure and colour, each row a `MeasuredValue`.
8. Structure.
9. What is in the picture.

The editor picker (Apple Photos / Lightroom / Any editor) sits at the top of Do first.

**Question.** What do I do to this picture, in my editor, in what order, and what should I leave alone?

**Data and rules.** `EditingRules.advice(for: PhotoRecord, context: PhotoContext) -> PhotoAdvice { doFirst, also, checked, notMeasured }`, with `PhotoContext { cameraLeanR, cameraLeanB, visionHorizonDeg: Double?, intents: Set<IntentTag> }`.

- **Evidence per advice.**

  | Grade | Advice |
  |---|---|
  | Solid | Blown highlights, crushed shadows, exposure (`luma_p50`), flat tones: direct pixel counts |
  | Moderate | Noise (`snrIsClean` only), soft and halo (only when `edges_measured >= 3`), moiré |
  | Thin | Colour lean (gray-world on one scene), level edge (Moderate only when Vision's horizon agrees within 1°), composition (thirds), shallow depth of field |

  Thin advice never goes in Do first.
- **Ranking.** Evidence, then band severity (Poor before Fair; exposure counts as Fair), then edit order. Do first takes the top two. Both lists are displayed in the fixed edit order: white balance, exposure, highlights and shadows, noise, sharpening, straighten, composition.
- **Gates that change counts on the 17 Pro Max.**
  - "Soft" needs ≥3 edges: 35 cards become 11.
  - "Halo" needs ≥3 edges: 37 become 17.
  - Colour lean fires only when the photo differs from the camera's own median lean by more than 0.15 stops. That leaves 132 notes, all Thin, so all in Also; there are 157 cards today.
  - Colour lean switches to the "probably the subject's own colour" wording at `colorfulness >= 60` (library median 39; to be eye-checked before shipping).
  - Straighten (85 photos) stays in Also unless Vision agrees.
- **Results on the 17 Pro Max.** The median is 2 non-Thin steps per photo. 19 photos reach "Nothing here needs fixing"; today no photo on this camera does.
- **Checked** lists only rules that did not fire, each with the row's value and the rule's threshold. **Not measured** gives the reason, built from `edges_candidates` and `edges_reject_reasons` (plain-word map in §3.1), or from the SNR flags.
- **Columns used.** `clip_high_pct`, `clip_low_pct`, `clip_gamut_pct`, `luma_p50`, `tonal_range_stops`, `snr_midgrey_db` and its flags, `noise_whiteness`, `mtf50_p80_cpp`, `mtf50_p80_ci_lo_cpp`, `mtf50_p80_ci_hi_cpp`, `edges_measured`, `edges_candidates`, `edges_reject_reasons`, `overshoot_median_pct`, `wb_r_over_g_stops`, `wb_b_over_g_stops`, `colorfulness`, `structure_horizon_tilt_deg`, `structure_thirds_distance`, `structure_focus_fraction`, `mtf50_infocus_cpp`, `mtf50_background_cpp`. Vision's `ContentSummary.horizonDegrees` is also used.

**UI.**
- `PhotoDetailView` keeps `Form(.grouped)` and gets the section order above.
- Each step header is `Text("\(n). \(title)")` followed by `EvidenceCapsule`, and the step keeps its 96 pt overlay thumbnail.
- Each advice card has a trailing `Menu` (`ellipsis.circle`) with one matching intent, for example "Dark on Purpose". Choosing it collapses the card to one line with **Show Anyway**.
- Intent capsules under the title use `Label(tag.word, systemImage: "hand.raised")` and have a remove button.
- A toolbar button **Copy Editing Steps** exports the steps (§6).
- `PhotoTable`'s sharpness cell shows "3,769 · 27 edges", or "— · 1 edge" in `.secondary`, which sorts as missing.

**Copy.**

*5375AE66 (iPhone 17 Pro Max, ISO 125), editor Apple Photos.*

Do first:
1. **Blown highlights.** "2.2 % of the picture is pure white."
   - "Adjust > Light: drag Highlights down, then add Brilliance to open the bright areas."
   - Caution: "On a JPEG or HEIC, pixels at pure white hold no detail: this softens the glare but cannot bring detail back."
   - Note: "A further 1.9 % of pixels hold colour sRGB cannot show; that colour is in the file and is not lost detail."
2. **Sharpening halo.** "Edges overshoot by 14.9 %: a visible fringe. Do not add sharpening; leave Adjust > Sharpen off."

Also (2):
- **Colour lean.** "This picture leans warm by 0.52 stops; your iPhone 17 Pro Max usually leans 0.17, so most of this is the light or the subject. It is a colourful picture (colourfulness 69; your library's median is 39), so the figure may describe the subject's own colour. Correct it only if greys should look neutral."
- **Level edge.** "A long level edge is 3.8° off level, left end lower. It may be a horizon or a table edge seen at an angle; straighten only if it should be level."

Checked, nothing to do: "Crushed shadows 0.04 % (acts above 0.5) · Noise 41.2 dB (acts below 30) · Middle tone 102 of 255 (acts below 70 or above 190) · Tonal range 8.3 stops (acts below 7) · Sharpness 0.32 c/px (acts below 0.18) · Subject 0.47 from a thirds point (acts above 0.75) · No repeating pattern."

Measurements: "In-focus sharpness 1,956 LW/PH · Fair · 5 edges · this photo's range 1,833–1,999."

*E07C5F37, the petunia (iPhone 13, ISO 40, 1/193 s, f/1.6).*
- Overlay caption today: "13.12 % blown". New caption: "Red: pure white in this preview. The file itself has 1.4 % blown; up to 11.7 % more is colour beyond sRGB, which the preview clips and paints red although the file holds it. No pixel is crushed to pure black."
- Do first (one step; nothing else is above Thin):
  1. **Blown highlights.** "1.4 % of the picture is pure white." Extra line: "11.7 % of pixels hold colour outside sRGB: keep the original, or export with a Display P3 profile where your app offers one."
- Checked, nothing to do, includes: "Crushed shadows 0.00 % (acts above 0.5) · Noise 36.2 dB (acts below 30)."
- Also (2):
  - **Colour lean.** "This picture reads warm and magenta by 1.46 stops, far from your iPhone 13's usual rendering. It is a very colourful picture (colourfulness 125; your library's median is 39), so the figure most likely describes the subject's own colour, not the light. Leave white balance alone unless greys look tinted." Menu: "Colour Is the Point".
  - **Composition.** "The detail sits 0.93 from the nearest rule-of-thirds point (1 is the centre). Composition is taste; a centred bloom can be the point."
- Not measured: "Sharpness: 7 candidate edges were found and none could be used (2 too noisy on either side; one each not straight enough, too little contrast, uneven light across the edge, an invalid contrast reading, a measurement that could not be computed). Petals and leaves rarely give the straight edges the method needs; this says nothing about whether the photo is sharp."
- Measurements: "Dynamic range: at least 8.6 stops (no shadow deep enough to reach the floor)."

*0364AD55 (iPhone 17 Pro Max ultra-wide, ISO 3200, 1/24 s).* Do first, in this order:
1. **Exposure: dark.** "The middle tone sits at 27 of 255." "Adjust > Light: Exposure up, starting around +0.3 to +0.7." Caution: "Brighten before you judge noise; brightening raises it."
2. **Noise.** "This photo measures 27.2 dB (Fair), and the phone has already smoothed it (0.48): add only gentle noise reduction after brightening."

Also: Colour lean ("warm and green by 1.03 stops; your phone usually leans 0.17, so most of this is the light"). Checked includes "Crushed shadows 0.00 % (acts above 0.5)".

*C6220E43 (iPhone 17 Pro Max, ISO 200).*
- Do first: **Sharpening halo** (12.0 %).
- Also: the level edge, with one of two wordings:
  - "Vision finds a horizon {x}° off level, which agrees: probably a real horizon."
  - "Vision found no horizon, so it is probably a table, a roof line or a slope; straighten only if it should be level."

  Plus Shallow depth of field.
- Checked: "Blown highlights 0.24 % (acts above 0.5) · Crushed shadows 0.18 % (acts above 0.5) · Noise 41.2 dB · Middle tone 166 · Tonal range 9.9 stops · Colour within 0.15 stops of this camera's usual · Sharpness 0.44 c/px."
- Sharpness row: "3,769 LW/PH · Excellent · 27 edges · this photo's range 3,582–3,892."

**Caveat it carries.**
- Every sharpness row shows the photo's own p80 range and edge count. The popover adds the comparison rule: treat two photos as different only past 30 %, because the range covers edge sampling, not the scene (FINDINGS §6).
- Clipping rows say "in the file's own encoding".
- Dynamic-range rows say "at least" when they are a lower bound.
- Colour and level-edge notes are always Thin and say why.
- Slider ranges are labelled "starting around"; the measurement never sets them.

### Layer 6: How sure (tooltip, then popover, then Glossary "Method")

**What she sees.**
1. Hovering a tile title or row label shows the one-line meaning (`.help`).
2. The ⓘ popover has four blocks: **Meaning**, **What good looks like**, **How sure**, and **In this camera** or **In this photo**. A button, **Open the Glossary**, sits at the bottom.
3. The Glossary window gains a **Method** tab next to Metrics. It holds:
   - The paragraphs from `results/report.md` "How to read these numbers" verbatim, including ISO 12233 e-SFR, the SNR formula, output-referred dynamic range, clipping in the file's own encoding and the structure fields.
   - The evidence and effort word definitions (§4.2, §4.3).
   - The check rules (§5).

**Data.**
- `Metric.howSure: String` (new) and `Metric.evidenceText(camera:)` / `evidenceText(photo:)`.
- `Structure.levelEdgeHowSure`.
- `Method.text`, a string constant with a comment naming report.md as its source.

**UI.**
- `MetricDefinition` in `Components.swift` becomes a `VStack` of four blocks separated by `Divider`s.
- **Open the Glossary** sets `AppModel.glossaryMetric` and calls `openWindow(id: "glossary")`. That window already exists in `IQCoachApp.swift`.
- `GlossaryView` becomes a `TabView` with "Metrics" and "Method" tabs. The Method tab is a `ScrollView` of headed paragraphs.

**Copy.**
- **Sharpness, How sure.** "Measured on real edges in your photos with the ISO 12233 slanted-edge method, so every figure is a lower bound that depends on the scene. One photo's figure carries its own range (on this phone typically 36 % of the value wide, from which edges happened to be measured); compare two photos only when they differ by more than 30 %. A camera median over many photos is the figure to trust."
- **Sharpness, In this camera.** "1,966 LW/PH is the median of 43 photos with 3 or more usable edges; the middle half lies between 1,489 and 2,680."
- **Noise, How sure.** "Output-referred: noise reduction and HEIC or JPEG compression lower it as much as the sensor does, so it compares processing across ISO and cameras, not sensors. Photos whose mid-grey had to be estimated, or whose flat areas were textured or held a repeating pattern, are left out."
- **Dynamic range, How sure.** "Often only a lower bound: the floor can be found only in frames with deep, flat shadows, and a JPEG's tone curve caps it."
- **Clipping, How sure.** "A direct count of pixels at the top (any channel 254 or above) or bottom (all channels 1 or below), in the file's own encoding: the most certain figure here. It cannot tell a blown sky from a white page."
- **Colour lean, How sure.** "Gray-world: assumes the scene averages to grey. A one-colour subject, a sunset or stage light moves it; a lean that holds across many scenes is the camera."
- **Level edge, How sure.** "The longest nearly level edge: a horizon only sometimes; table tops, shelves and frames seen at an angle count too."
- **Structure, How sure.** "Describes the frame, not its quality."

**Caveat it carries.** This layer is where the caveats live.

### Layer 7: Library headline and sparse cameras

**What she sees.**
- **Library.** The headline is rewritten, the table gains a "One thing" column, and the sharpness cell shows its count ("1,966 LW/PH · Fair (43)" or "Not enough photos (1)"). A provenance line names the file and when it was written.
- **Sparse cameras.** A camera with fewer than 5 photos shows its photos' own figures (not medians), what is missing, the count needed, and a **Choose Photos to Analyze…** button. Its sidebar row sits under "Too few photos".

**Question.** Which camera behaves how, and why do some get no coaching?

**Data and rules.**
- Rated cameras are those with at least 5 photos and at least two ISO bands that each have 3 or more clean photos.
- "Follows ISO" means no band median rises more than 1 dB above the band below it. The 1 dB tolerance is a stated design choice.
- Results on this library:
  - D850 follows ISO (42.5, 39.1, 37.8, 35.8, 33.9).
  - The 17 Pro Max, iPhone 13 and XR do not (rises of 4.7, 4.9 and 3.5 dB).
- Today's headline instead names the iPhone 13 as "flattest" from its endpoints alone (−1.7 dB).
- Sparse-camera figures come straight from `PhotoRecord`.

**UI.**
- `LibraryOverviewView`: the headline `Text`, a `TableColumn("One thing")` with `.lineLimit(2)`, and the sharpness cell text.
- `SidebarView` gets a `Section("Too few photos")`.
- `CameraReportView` branches to a sparse body when `photos.count < CameraRules.minPhotos`. The body is a `GroupBox("What these photos say")` plus `ContentUnavailableView("Coaching starts at 5 photos", systemImage: "camera.metering.unknown")` with the picker button, then the table.

**Copy.**
- **Headline.** "The NIKON D850's noise follows ISO the way a sensor's does: 42.5 dB at ISO 64 and below, falling to 33.9 dB above ISO 1000. On the iPhone 17 Pro Max, iPhone 13 and iPhone XR it does not fall steadily with ISO, which points to processing: noise figures here compare each camera's processing, not its sensor."
- **Provenance.** "From results.json, written 23 Oct 2026 at 04:36 · 389 photos from 19 cameras."
- **iPhone 13 mini (2 photos).** "Coaching starts at 5 photos; this camera has 2, so here are the photos' own figures rather than medians. Noise 28.4 and 42.7 dB. Blown highlights 1.4 % and 0.5 %. Crushed shadows 0.00 % and 0.04 % (both well under the 1 % line). No sharpness figure: neither photo had a usable straight edge. Add photos taken with this camera with Choose Photos to Analyze… (⇧⌘P)."
- **SEALIFE DC2000.** It has 5 photos, so it gets the normal screen with the layer 1 fallback. It is not shown as sparse; the "coaching starts at 5" sentence never appears on a 5-photo camera.

**Caveat it carries.** The headline itself carries "processing, not sensor". Sparse figures are labelled per photo, never as medians.

---

## 3. Data-model additions and storage

### 3.1 Results model (`Sources/Model`)

**`PhotoRecord` decodes columns already in results.json:**
- `clip_gamut_pct`, `mtf50_p80_ci_lo_cpp`, `mtf50_p80_ci_hi_cpp`.
- `edges_candidates`, `edges_center`, `edges_outer`.
- `edges_reject_reasons` (a `String` such as `"plateau_noise=2;shading=1"`).

**New computed properties on `PhotoRecord`:**
- `hasSharpnessFigure` (`edgesMeasured >= 3`).
- `p80RangeLWPH: ClosedRange<Double>?` (2 × c/px × the short side, min(width, height), the same scale as `mtf50_p80_lwph` since 23 Oct 2026).
- `p80RelativeWidth`.
- `rejectReasons: [(EdgeRejectReason, Int)]`. Unknown keys are kept, with their raw name.
- `key: PhotoKey`.

`EdgeRejectReason` maps analyzer keys (from `iqa/edges.py`) to plain words:

| Key | Plain words |
|---|---|
| `plateau_noise` | too noisy on either side |
| `clipped` | touched pure white or black |
| `contrast_gt_1` | an invalid contrast reading |
| `step_too_small` | too little contrast |
| `shading` | uneven light across the edge |
| `fit_residual` | not straight enough |
| `no_mtf50_below_nyquist` | could not be read within the pixel grid |
| `slant` | at the wrong angle (the method needs 1 to 16°) |
| `rise_width` | blurred over too many pixels |
| `not_a_step` | a thin line or double edge, not a step |
| `error` | the measurement could not be computed |

**`CameraSummary` gains:**
- Counts: `sharpnessCounted`, `sharpnessRough` (1–2 edges), `sharpnessNone`.
- `sharpnessIQR`.
- Gated `overshoot`.
- `snrCounted` and `snrExcluded: [(reason, count)]`.
- `drExactCount`, `drLowerBoundCount`, and `dynamicRangeIsLowerBound` under the 5-row rule.
- `whitenessAbove160` (used when 5 or more rows exist).
- `snrFollowsISO: Bool?`.
- `p80RelativeWidthMedian`.
- `clipHighCount`, `clipLowCount`, `gamutCount`.
- `formats: [String: Int]`.

**`PhotoLibrary` gains:**
- `sourceDate: Date?` (the file's modification date, read in `AppModel.load(url:)`).
- `hasNativeClipping`: true when any row carries `clip_gamut_pct`. That column exists only in results written after clipping moved to the file's own encoding (fifth run, FINDINGS §8).
- `hasStructure`.

### 3.2 User preferences, dismissals, intent tags, checks

**Storage.** One file, `~/Library/Application Support/IQCoach/preferences.json`, next to the existing `runs/` and `photos/`. The app is unsandboxed, so the path is literal. If the app is ever sandboxed, it moves into the container.

**Model and store.**
- `UserPreferences: Codable, Sendable` lives in new `Sources/Model/UserPreferences.swift`.
- `PreferencesStore` (`@MainActor @Observable`) lives in new `Sources/Support/PreferencesStore.swift`. It is owned by `AppModel` and injected with `.environment`.

**Write and read policy.**
- Writes go through `Data.write(to:options: .atomic)`, debounced 1 s.
- Loads happen at launch.
- `version` is migrated on read.
- A file that does not decode is renamed `preferences.bad-<stamp>.json`, and the app starts clean.
- Settings gets **Reset Preferences…**, behind a confirmation dialog.

```swift
struct UserPreferences: Codable, Sendable {
    var version = 1
    var editor: Editor = .applePhotos
    var setAside: [String: Dismissal] = [:]          // key: Insight.id, e.g. "shadow-discipline:iPhone 17 Pro Max"
    var intents: [PhotoKey: Set<IntentTag>] = [:]
    var checks: [CaptureCheck] = []                  // §5
}
struct Dismissal: Codable, Sendable {
    var date: Date; var note: String
    var counted: Int; var severity: Severity; var grade: EvidenceGrade   // snapshot for the come-back rule
}
/// "<camera_model>|<file>|<datetime>": survives --no-paths; the datetime separates repeated DSLR names such as DSC_0001.
struct PhotoKey: Codable, Hashable, Sendable, RawRepresentable { var rawValue: String }
enum IntentTag: String, Codable, CaseIterable, Sendable {
    case darkOnPurpose, brightOnPurpose, colourIsThePoint, notMeantToBeLevel, composedThisWay
}
```

**Intent tags: what each one does.** The effect is always visible and always reversible.

| Tag (UI word) | Silences on the photo | Left out of the camera rule (and the card says how many) |
|---|---|---|
| Dark on purpose | Crushed shadows; Exposure: dark | `shadowDiscipline`; shadows checks |
| Bright on purpose | Blown highlights; Exposure: bright | `highlightDiscipline`; highlights checks |
| Colour is the point | Colour lean | `colourLean` medians |
| Not meant to be level | Level edge | `levelEdgeLean`; level-edge checks |
| Composed this way | Composition | (none) |

Card footer example: "Counted: 203 of 206 photos (3 you marked bright on purpose are left out)." The report-card tiles still count every photo, because they describe the files rather than the coaching.

**Known limit.** A copy of a photo analyzed from the Photos picker may carry a different file name than the same photo in `results/results.json`, so a tag does not carry across. The capsule shows where a tag is.

---

## 4. Coaching-engine changes (`Sources/Coaching`)

### 4.1 New Insight fields

```swift
enum EvidenceGrade: Int, Codable, Comparable, Sendable { case thin, moderate, solid }   // word, symbol, definition
enum EvidenceKind: Sendable { case pixelCount, measured, edgeBased, sceneDependent }
enum Effort: String, Codable, Sendable { case atCamera, setUpOnce, inEditor }          // word, symbol
struct Action: Hashable, Sendable { let text: String; let effort: Effort }
struct WhyShown: Hashable, Sendable { let rule: String; let counted: String; let howSure: String; let cannotTell: String; let checkYourself: String }
enum CheckKind: String, Codable, Sendable { case highlights, shadows, levelEdges }

struct Insight {               // existing fields kept: id, scope, severity, title, finding, why, examples
    var grade: EvidenceGrade
    var kind: EvidenceKind
    var counted: Int; var total: Int
    var excluded: [(reason: String, count: Int)]
    var share: (hits: Int, of: Int)?           // share rules only: Wilson range, check baseline
    var actions: [Action]                       // replaces [String]; `actionTexts` keeps old call sites compiling
    var imperative: String?                     // "Expose for the highlights." (one-thing eligible rules only)
    var prevalence: Double?                     // share of photos showing the behaviour the action changes
    var whyShown: WhyShown
    var whatWouldChange: String?
    var checkKind: CheckKind?
}
```

`basedOn` (the largest evidence n) is removed. The footer shows `counted of total`, the count of the side the claim rests on.

### 4.2 Evidence words (counts, not probabilities)

The Glossary prints these definitions verbatim.

- **Solid.**
  - At least 20 photos passed the rule's gates (10 for direct pixel counts).
  - The rule measures something direct: pixel counts, or SNR on clean patches.
  - For share rules, the 95 % range of the share (Wilson) stays on one side of the rule's own line.
- **Moderate.**
  - 8 to 19 photos.
  - Or the rule rests on natural edges (sharpness, halo, lens comparison: lower bounds read from the scene).
  - Or it rests on an assumption the scene can break (colour lean: gray-world; level edges: not always horizons).
  - Edge-based and scene-dependent rules never rise above Moderate.
- **Thin.**
  - Fewer than 8 photos, or a share whose 95 % range crosses the rule's line.
  - Thin findings are never the one thing.
  - They sit under "Needs more photos", say "Try this" instead of "What to do", and carry "What would change this".

`EvidenceGrade.grade(counted:kind:shareRange:line:)` is a pure function.

The words are chosen not to collide with band words (Poor/Fair/Good/Excellent) or severity words (Important / Worth acting on / Good to know). Symbols are `checkmark.seal`, `circle.lefthalf.filled` and `questionmark.circle`, always shown with the word.

### 4.3 Effort

- **At the camera.** A habit at the moment of shooting.
- **Set up once.** A setting changed once, such as grid or level.
- **In the editor.** Photos already taken.

Symbols: `camera`, `gearshape`, `slider.horizontal.3`.

Device wording comes from one `CameraVocabulary` table keyed by `CameraGroup.isPhone`. Every entry is confirmed on the iOS of the user's phone before shipping.

| Action | iPhone (Camera app) | Other cameras |
|---|---|---|
| Less exposure on bright scenes | Tap the subject, drag the sun slider down | Exposure compensation −0.3 to −0.7 EV; turn on the highlight warning in playback |
| Expose for shadows | Tap the darker subject | Exposure compensation +0.3 to +0.7 EV |
| Level | Settings > Camera: Grid and Level | The camera's grid or electronic level, if it has one |
| White balance | None in the Camera app; edit instead | A white-balance preset for that light, or a grey card |
| Sharpening | None; edit instead | Lower in-camera sharpening or picture style |

### 4.4 "Why am I seeing this?"

Every rule fills `WhyShown` with five sentences:
- **The rule.** Trigger and threshold.
- **What was counted.** n of N, with exclusions by reason.
- **How sure.** The evidence word, its reason, and the Wilson range for share rules.
- **What it cannot tell.** The standing caveat.
- **Check it yourself.** One concrete shot that would confirm or overturn the claim.

The popover is the only place the full mechanics appear. Cards stay short.

### 4.5 Engine output

```swift
struct CoachingOutput {
    var oneThing: OneThing?            // insight + sentence + nextUp, or the fallback text
    var cards: [Insight]               // not thin, not set aside
    var needsMorePhotos: [Insight]     // thin
    var setAside: [(Insight, Dismissal)]
    var silent: [SilentCheck]          // rule name + reason with numbers
}
static func output(for cam: CameraGroup, prefs: UserPreferences) -> CoachingOutput
```

- Rules return `RuleResult` (`.fired(Insight)` or `.silent(SilentCheck)`). An `insight` accessor keeps existing tests readable.
- **Come-back rule for set-aside cards.** The card returns when:
  - `counted` has grown 25 % or more since it was set aside, or
  - its severity word changes, or
  - its evidence word changes.

  It then carries "Back because the evidence changed". Nothing is deleted.

### 4.6 Rule changes (`CameraRules.swift`)

| Rule | Change | Kind | Check |
|---|---|---|---|
| `isoCeiling` → `noiseByISO` | Clean rows; bands ≥3. If `snrFollowsISO`, either a ceiling (Worth acting on, at the camera, eligible when ≥10 % of photos are above it) or "clean at every ISO you used" (Good to know). Otherwise "Noise does not follow ISO on this {phone/camera}" (Good to know), listing all bands; when the top band has <10 photos, a "too few to say where grain starts" line. The phrase "Higher ISO amplifies the grain" is removed for non-following cameras. | measured | (none) |
| `noiseCharacter` | Whiteness median over ISO > 160 when ≥5 such rows, because FINDINGS §5 item 5 says whiteness is confounded at low noise. "Keep ISO low for texture" removed. Editor action only. | measured | (none) |
| `lensComparison` | Rows with ≥3 edges per lens. Lenses with no such row are named "not compared". | edgeBased | (none) |
| `fieldSoftness` | Rows with `edges_center >= 3 && edges_outer >= 3`. A finding at ≥5 such rows; a Thin card at 1–4. | edgeBased | (none) |
| `highlightDiscipline`, `shadowDiscipline` | Intent exclusions; Wilson range; representative examples among photos over 1 %; device actions. | pixelCount | highlights, shadows |
| `sharpeningCharacter` | Rows with ≥3 edges. No at-camera action on phones. Representative examples, so the 206 % QR-sign extreme no longer leads. | edgeBased | (none) |
| `colourLean` | Intent exclusions. No preset action on phones. | sceneDependent | (none) |
| `slowShutter` | Rows with ≥3 edges on both sides. Thin when the slow side has <8. | edgeBased | (none) |
| `apertureSweetSpot` | Rows with ≥3 edges. | edgeBased | (none) |
| `sharpnessConfidence` | Removed. Its content moves to the sharpness tile popover, using the p80 range. | (none) | (none) |
| `horizonLean` → `levelEdgeLean` | "Level edges" wording; left and right counts; intent exclusions; set-up-once action. | sceneDependent | levelEdges |
| `shallowDepthHabit` | Unchanged. | sceneDependent | (none) |

### 4.7 Editing advice (`EditingRules.swift`)

- `EditingAdvice` gains `grade`, `step: EditStep` (white balance, exposure, tone, noise, sharpening, geometry, composition) and `silencedBy: IntentTag?`.
- New gates and wording are as in layer 5.
- The noise advice uses `snrIsClean`. An extrapolated or textured row goes to Not measured with that reason.

---

## 5. Run comparison: capture checks

**Scope.** Only three metrics are compared, all shares with a deterministic per-photo test and high counts:
- Highlights: `clip_high_pct > 1`.
- Shadows: `clip_low_pct > 1`.
- Level edges: `abs(structure_horizon_tilt_deg) >= 1`, among photos that have a level edge.

Sharpness, noise and dynamic range are deliberately not compared (§8).

**Model.** `CaptureCheck` is stored in `preferences.json`.

```swift
struct CaptureCheck: Codable, Identifiable, Sendable {
    let id: UUID; let camera: String; let kind: CheckKind; let started: Date
    let baseline: Baseline          // hits, count, formats, source file name, sourceDate, intent-excluded count
    var after: [PhotoKey: AfterRow] // hit, format, file, path?; accumulated across runs, de-duplicated by key
    var undated: Int
    var status: Status              // active, finished, dropped
}
```

**Starting a check.**
- **Start a Check…** opens a sheet. The baseline is frozen from the loaded library at that moment, with that moment's intent exclusions.
- Start is disabled, with the reason given, when:
  - `hasNativeClipping` is false (for clipping kinds), or
  - `hasStructure` is false (for level edges).

**Counting new photos.**
- `AppModel.load(url:)` calls `preferences.ingest(library)`.
- For each active check, rows count when all hold:
  - `camera_model` matches.
  - The EXIF `datetime` is after `started`.
  - The row is not tagged with the check's intent.
  - For level edges, the row has a level edge.
- Undated rows are counted separately and left out.
- Picks and runs accumulate across sessions. The library is replaced on every load, which is why `after` is stored.

**Statistics.** Pure functions in `Sources/Model/Stats.swift`:
- `wilson(k:n:)` gives the 95 % score interval, z = 1.96.
- `newcombeDifference(k1:n1:k2:n2:)` gives the hybrid score interval for after − before.

No bootstrap is needed. Thresholds are design choices and are printed as such.

**Verdicts.** Rules are fixed in advance and evaluated by `CheckComparison.evaluate(_:) -> CheckResult` in new `Sources/Coaching/CheckComparison.swift`.

| Condition | Verdict word | Symbol |
|---|---|---|
| Fewer than 10 counted new photos | Keep shooting (k of 10) | `camera` |
| Results lack the fifth-run clipping column or structure columns | Not comparable | `exclamationmark.triangle` |
| Range entirely below 0 and drop ≥ 10 points | It worked | `checkmark.seal` |
| Range entirely below 0, drop < 10 points | A small drop | `arrow.down.right` |
| Range entirely above 0 | Higher than before | `arrow.up.right` |
| Range includes 0 | Not settled yet (adds "about the same so far" when the point difference is within 5 points) | `hourglass` |

**Worked examples on this library.** Recomputed; these are the test fixtures.

| Before | After | After − before, points (95 % range) | Verdict |
|---|---|---|---|
| 54/206 highlights (26 %; 21–33 %) | 0/10 | −26 (−33 to +2) | Not settled yet |
| 54/206 | 1/10 | −16 (−27 to +15) | Not settled yet |
| 54/206 | 0/20 | −26 (−33 to −9) | It worked |
| 54/206 | 1/20 | −21 (−29 to −2) | It worked |
| 54/206 | 2/20 | −16 (−26 to +5) | Not settled yet |
| 54/206 | 6/24 | −1 (−16 to +19) | Not settled yet, about the same so far |
| 17/206 shadows (8 %; 5–13 %) | 0/10 | −8 (−13 to +20) | Not settled yet |
| 17/206 | 0/60 | −8 (−13 to −2) | A small drop |
| 17/206 | 4/12 | +25 (+5 to +53) | Higher than before |
| 22/26 level edges, iPhone 13 (85 %; 66–94 %) | 2/10 | −65 (−82 to −29) | It worked |

**UI.**
- New `Sources/Views/CheckCard.swift`, placed under the one-thing card. It is a `GroupBox` labelled `Label("Your check: blown highlights", systemImage: "flag.checkered")` and contains:
  - A `Grid` with rows Before, After and Difference (`.monospacedDigit()`).
  - `ProgressView(value: k, total: 10)` while under 10.
  - The verdict `Label`.
  - A strip of `PhotoThumb`s (64 pt) of the new photos, each with its value, hits first, each opening the photo.
  - `DisclosureGroup("How I Decide")`.
  - A `Menu` with **Finish Check** and **Drop Check…** (behind a `confirmationDialog`).
- No notifications and no badges. A check never nags.
- `SnapshotRunner` renders `check.png` from a fixture.

**Copy.**
- **Start sheet.** "Check: blown highlights on iPhone 17 Pro Max. Before: 54 of 206 photos (26 %; between 21 and 33 % allowing for chance) have more than 1 % blown to white. Shoot as you normally would, using the sun slider on bright scenes, then choose the new photos with Choose Photos to Analyze…. Only photos taken after today count. I give a first look at 10 new photos; more give a firmer answer." Buttons: **Start Check** (default), **Cancel**.
- **Progress.** "4 of 10 new photos so far. No hurry: the check waits."
- **Not settled yet (0 of 10).** "Not settled yet. Before: 26 % of 206. After: 0 of 10 new photos. That looks better, but with 10 photos the difference could be anywhere from 33 points lower to 2 points higher. Keep going: more photos narrow it."
- **It worked (1 of 20).** "It worked. Before: 26 % of 206. After: 1 of 20 (5 %). The drop is 21 points; allowing for chance it is somewhere between 2 and 29 points."
- **About the same (6 of 24).** "Not settled yet, and about the same so far. After: 6 of 24 (25 %) against 26 % before; the difference could be anywhere from 16 points lower to 19 points higher. Look at the six photos below: white pages and screens clip whatever you do."
- **A small drop.** "A small drop. Before: 17 of 206 (8 %). After: 0 of 60. Allowing for chance the drop is between 2 and 13 points, under the 10 points I count as a change that worked."
- **Format caveat.** Shown when the JPEG/HEIC mix differs by more than 30 points. "Before was mostly JPEG copies of unknown origin (181 of 206; 25 HEIC); after is HEIC originals. Clipping is counted the same way in both, but a copy may have been edited before it was saved."
- **Not comparable.** "Not comparable: these results were written before clipping was measured in each file's own encoding (15 Oct 2026). Re-analyze the photos, then start the check again."
- **Undated photos.** "2 new photos carry no date and are not counted."
- **How I Decide.** "I compare the share of your new photos with the share before, and allow for chance with a 95 % range (Newcombe's method). 'It worked' means the whole range is below zero and the drop is at least 10 points; 10 points is a choice I made so that small wobbles do not count. I give a first look at 10 new photos; at 10 only a large change can show. A lower share can also mean different scenes, so look at the photos."

---

## 6. Export

`MarkdownExport` (`Sources/Support/MarkdownExport.swift`) gains three outputs, reached from a toolbar `ShareLink` menu and the photo toolbar. Nothing in an export is computed separately, so a sheet can never disagree with the screen.

1. **`coaching(for:output:checks:)`**, the full camera report:

```
# iPhone 17 Pro Max: coaching from IQ Coach
From results.json, written 23 Oct 2026 04:36 · 206 photos, shot 19 Jun to 12 Oct 2026

## The one thing
Expose for the highlights. 54 of 206 photos (26 %) have more than 1 % of the frame blown to pure white.
Worth acting on · Solid · 206 photos · At the camera
- [ ] On bright scenes, tap the subject and drag the sun slider down before you shoot.
Also good to know: noise does not follow ISO on this phone; up to ISO 1000 every band has a median of 32 dB or more.

## Report card
- In-focus sharpness: 1,966 LW/PH (Fair), from 43 of 206 photos with 3 or more usable edges
- Noise: 34.5 dB (Good), 167 of 206 photos; compares processing, not sensors
- Blown highlights: 0.47 % median; 54 of 206 photos over 1 %
- Sharpening halo: 10.7 % (Fair), 43 photos
- Colour lean: warm, B/G −0.17 stops, 206 photos
- Dynamic range: 7.2 stops, 36 photos reached the floor; 170 are lower bounds

## Coaching
### Highlights are often blown out (Worth acting on · Solid · 206 photos)
…At the camera / In the editor as "- [ ]" items…

## Needs more photos
- Corners may be softer than the centre: 3 photos (47 %, 55 %, 63 % of the centre)
- Slow shutter speeds may cost sharpness: 1 photo with a figure

## Set aside by you
## Checks
- Blown highlights, started 15 Oct 2026: 4 of 10 new photos so far

---
Measured by iq-analyzer. One photo's sharpness is a range; camera medians over many photos are the figures to trust. Noise is measured on the finished file, so it compares processing as much as sensors.
```

2. **`pocketCard(for:)`**, five plain lines for a phone note:

```
iPhone 17 Pro Max · 15 Oct 2026
1. Bright scenes: tap, drag the sun slider down (26 % of photos blew highlights)
2. Do not chase a low ISO for clean pictures: up to ISO 1000 every band is 32 dB or more
3. Do not add sharpening or noise reduction in editing (the phone does both)
From 206 photos.
```

3. **`editingSteps(for:editor:)`**, the photo's Do first and Also lists as "- [ ]" items in edit order, followed by "Checked, nothing to do" and the provenance line.

PDF export is out of scope. Ticks are made in Notes or Obsidian, not stored by the app.

---

## 7. Implementation plan

The plan has 12 steps totalling about 20 hours, so two focused days. Every step builds and passes `TEST_RUNNER_IQA_RESULTS=… xcodebuild … test` on its own. If time runs short, stop after step 9: the app is consistent at every step, and steps 10 and 11 ship a day later.

**1. Model gates and provenance (2 h).**
- Files: `Model/PhotoRecord.swift` (new columns, `hasSharpnessFigure`, `p80RangeLWPH`, `rejectReasons`, `key`), `Model/CameraGroup.swift` (gated summary, the 5-row figure rule, the dynamic-range rule, `whitenessAbove160`, `snrFollowsISO`, `formats`), `App/AppModel.swift` (`sourceDate`), `Tests/IQCoachTests/Fixtures.swift` (default `edgesMeasured = 5` and p80 range so existing sharpness tests keep firing).
- Tests in `ModelTests.swift`:
  - A 1-edge row is left out of the medians and the lens median.
  - Reject-reason parsing keeps an unknown key raw.
  - The p80 LW/PH conversion is right.
  - Real data: 17 Pro Max sharpness 1,966 over 43; iPhone 13 1,861 over 20; XR returns "not enough" (3); D850 dynamic range is "at least 8.6" with 1 exact row; `hasNativeClipping` is true.

**2. Statistics and the evidence vocabulary (1 h).**
- Files: `Model/Stats.swift` (`wilson`, `newcombeDifference`), new `Coaching/Evidence.swift` (`EvidenceGrade`, `EvidenceKind`, `Effort`), `Coaching/Insight.swift` (new fields with defaults; `actionTexts`).
- New `StatsTests.swift`:
  - Wilson 54/206 gives 0.207–0.326; 0/10 gives 0–0.278.
  - Newcombe gives every row of the §5 table.
- New `EvidenceTests.swift`:
  - Boundaries at 7/8 and 19/20, and 9/10 for pixel counts.
  - XR 6/21 is Thin because its range crosses 15 %.
  - Edge-based and scene-dependent rules are capped at Moderate.

**3. Camera rules (3 h).**
- Files: `Coaching/CameraRules.swift`, following the §4.6 table, including `RuleResult`, `WhyShown`, the vocabulary table, representative examples and removal of `sharpnessConfidence`.
- Tests in `CameraRuleTests.swift`:
  - A non-following fixture gives "Noise does not follow ISO".
  - A D850-shaped fixture gives "follows ISO".
  - The lens tie is computed on gated rows.
  - Field softness with 3 gated rows is Thin.
  - Slow shutter with 1 gated slow row is Thin.
  - The phone colour lean has no preset action.
  - The noise-smoothing card has no texture action.
  - Every silent rule gives a reason with numbers.
- Update `ExampleFileTests.swift` so highlights and sharpening pick representative photos.
- Delete the two confidence tests.

**4. Engine output and the one thing (1.5 h).**
- Files: `Coaching/CoachingEngine.swift` (`output(for:prefs:)`, ranking, prevalence gate, fallback, headline rewrite).
- New `CoachingEngineTests.swift`:
  - Highlights beat shadows at equal grade.
  - A Thin card is never the one thing.
  - A set-aside card is skipped.
  - Real data: 17 Pro Max gives `highlight-discipline` with no eligible next up (the "Also good to know" line names `noise-by-iso`); iPhone 13 gives `highlight-discipline` with next up `level-edge-lean`; D850 gives the fallback; XR gives the fallback (highlights Thin); no camera fires `shadow-discipline`; SEALIFE gives the fallback.
  - The headline names the D850 as following ISO and the three iPhones as not.

**5. Editing rules (1.5 h).**
- Files: `Coaching/EditingRules.swift`, `Coaching/Insight.swift` (`EditingAdvice` fields).
- Tests in `EditingRuleTests.swift`:
  - A 1-edge soft row gives no card.
  - A petunia-shaped row puts the lean note in Also with the subject wording.
  - Straighten is Thin without Vision and Moderate with agreement within 1°, with the sign mapping pinned.
  - Do first holds at most two steps and never a Thin one.
  - The C6220E43-shaped row's Checked list holds no rule that fired.
  - Real data: 17 Pro Max soft cards are 11 and halo cards 17.

**6. Shared components and "How sure" (1 h).**
- Files: `Views/Components.swift` (`MeasuredValue`, `EvidenceCapsule`, `ActionGroups`, `WhyButton`/`WhyPopover`, the 4-block `MetricDefinition`, snapshot variants), `Model/Metric.swift` (`howSure`, `evidenceText`), `Model/Structure.swift` (`levelEdgeHowSure`), `Support/Formatting.swift` (fix the "lenss" plural).
- Tests in `ModelTests.swift`:
  - The `MeasuredValue` text builder gives "At least 8.6 stops" and "— · 1 edge".
  - `Fmt.count(4, "lens")` gives "4 lenses".
  - Every metric has a non-empty `howSure`.

**7. Camera screen (2 h).**
- Files: new `Views/OneThingCard.swift`; `Views/CameraReportView.swift` (provenance line, order, `ScrollViewReader`, the three disclosures, the sparse branch, charts after coaching); `Views/InsightCard.swift`; `Views/MetricTile.swift`.
- Test: a `--snapshot` render. In `SnapshotRunner.swift`, add `onething.png` and a `sparse-<camera>.png` for the iPhone 13 mini.

**8. Photo screen (1.5 h).**
- Files: `Views/PhotoDetailView.swift` (the section order, Do first / Also / Checked / Not measured, `MeasuredValue` rows), `Views/OverlayImage.swift` (the blown versus beyond-sRGB caption), `Views/PhotoTable.swift` (sharpness cell and sort key).
- Test: `OverlayImage.caption` on the petunia fixture gives the 1.4 % and 11.7 % sentence.

**9. Library, sidebar, glossary (1 h).**
- Files: `Views/LibraryOverviewView.swift`, `Views/RootView.swift` ("Too few photos" section, `.help(oneThing)`), `Views/GlossaryView.swift` (Method tab, evidence, effort and check rules), new `Support/Method.swift`.
- Test: `Method.text` contains "ISO 12233" and every evidence word.

**10. Preferences: set aside and intent tags (2 h).**
- Files: new `Model/UserPreferences.swift` and `Support/PreferencesStore.swift`; the engine and editing rules read `prefs`; `InsightCard` set-aside sheet; `PhotoDetailView` intent menu and capsules; `SettingsView` reset.
- New `PreferencesTests.swift`:
  - Round-trip through a temporary directory.
  - A corrupt file is moved aside.
  - The `PhotoKey` format is right.
  - The come-back rule fires at 25 % growth and on a severity or grade change, and not otherwise.
  - "Bright on purpose" removes a photo from the highlights count, and the footer says so.

**11. Capture checks (2.5 h).**
- Files: new `Coaching/CheckComparison.swift` and `Views/CheckCard.swift`; `App/AppModel.swift` (`ingest` on load); the start sheet; `SnapshotRunner` adds `check.png`.
- New `CheckTests.swift`:
  - Every row of the §5 table.
  - Rows dated before the start are left out.
  - Undated rows are counted separately.
  - The same photo loaded twice counts once.
  - A library without `clip_gamut_pct` gives Not comparable.
  - The format-mix caveat appears at a difference above 30 points.

**12. Export, verification, docs (1.5 h).**
- Files: `Support/MarkdownExport.swift` (the three outputs); new `ExportTests.swift` (the full export begins with the one thing and ends with the provenance footer; the pocket card has five lines or fewer; editing steps follow edit order).
- Re-render snapshots into a fresh directory and delete `/tmp/iqcoach-snaps5`.
- Pre-ship eye checks:
  - Five 17 Pro Max frames among the 17 crushed-shadow photos.
  - Ten photos at colourfulness ≥ 60.
  - Vision's horizon sign mapping on a real photo.
  - The iOS paths in the vocabulary table, on the phone.
- Update `docs/APP-IQ-COACH-SPEC.md`, `mac/IQCoach/README.md` (layout, gates, preferences file, test count) and the `CLAUDE.md` state section (77 tests, plus the new ones).

---

## 8. Not in scope, and why

**Dropped as untruthful by at least one judge.**
- Slider amounts tiered on the measurement (for example blown 0.5–2 % mapped to Highlights −30): an invented mapping.
- The Publish Picker's output-size cap, "cannot separate photos above 1,350 LW/PH": an overclaim. Sharpness rankings also compare scenes as much as lenses.
- "Keep ISO at or below 160 for hair and foliage", and the existing "Keep ISO low for texture subjects": whiteness is 0.49 at ISO 160 and below and 0.44–0.46 above, and is confounded at low noise.
- Auto ISO 3200 on the D850: nothing was shot between ISO 1400 and 9000, and the ISO 9000 frame read 29.6 dB.
- Using `structure_orient_horizontal >= 0.4` as horizon evidence.
- "A p80 figure means 3 or more edges": false for 42 of 85 rows.
- Median intervals paired with p80 values.
- Hand-assigned evidence grades.
- White-balance presets on phones.
- Single-photo superlatives such as "the noisiest photo".
- A "Nothing to fix" list that included fired rules.
- "One such photo gives 20 or more edges": unverified.

**Sharpness, noise and dynamic range in checks.**
- Natural-edge sharpness is a scene-dependent lower bound with a per-photo range, and ten dim-light shots rarely yield five measurable frames.
- Noise compares pipelines, and the 17 Pro Max baseline is 181 JPEG copies against HEIC originals (FINDINGS §5 item 4).
- Dynamic range is a lower bound in 170 of 206 rows.

**The per-photo re-check drop zone.** It needs a single-file analyzer run and its own store. It is the next feature after checks, not part of these two days.

**Other cut features.**
- Capture One and darktable vocabularies, PDF export and stored tick states: maintenance cost and scope.
- Bootstrap medians: unnecessary once checks are limited to shares.
- An evidence inspector drawer with charts and a "show these photos" filter: two of three judges wanted it, and it does not fit the budget.
- Merging runs into a library history.
- Notifications or reminders: the HIG says do not nag.
- Vision labels driving rules, such as excluding documents from highlights: it needs file paths, and the classification is not validated.

**Native-encoding clipping overlay mask.** `ClippingMask` still draws from the sRGB preview. This spec fixes the caption only; decoding the file in its own profile is a later ImageIO task.

**Any change to the Python measurements.** That includes asking iqa to write a strict-sharpness flag so the CSV cannot drift from the app again; that is a separate proposal.

**Sandboxing and distribution.** Analyze Folder's user-chosen Python rules out the App Store sandbox regardless of this work.

Nothing was written to the repository. The scratch statistics scripts are in `/private/tmp/claude-501/-Users-allisonbowman-Developer-iq-analyzer/1663baf0-112c-4b35-8339-69159c46a1f5/scratchpad/`.