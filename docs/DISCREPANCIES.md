# Confirmed data discrepancies (adversarial sweep, 2026-10-23)

Each was confirmed by at least two of three independent skeptics (reproduce; definitions and units; user impact).

## CLIP-1 [high] stale-number

- **A:** results/FINDINGS.md:73 (§4 Rendering): "Highlight clipping: median 0.81 % of pixels on the 17 Pro Max"
- **B:** results/results.csv (fifth run): median clip_high_pct over the 206 iPhone 17 Pro Max rows = 0.475 %. The IQ Coach camera tile shows 0.47 % (snapshot /private/tmp/claude-501/snaps/camera-iPhone-17-Pro-Max.png).
- **Evidence:** Recomputed from results.csv. The median of clip_high_pct + clip_gamut_pct (the pre-fix sRGB measure) is 0.812 %, so §4 still carries the old figure. §8 (line 168) says "Every other column is unchanged" but never updates §4. The D850's 0.02 % is unchanged (0.019, no gamut on sRGB JPEGs).
- **Fix:** Change §4 to "median 0.47 % of pixels on the 17 Pro Max (0.81 % before the §8 fix)".
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F01 [high] stale-number

- **A:** results/FINDINGS.md:73 (section 4): 'Highlight clipping: median 0.81 % of pixels on the 17 Pro Max'
- **B:** results/results.json / results.csv clip_high_pct for camera_model == 'iPhone 17 Pro Max' (n=206), and the fifth-run note in FINDINGS section 8
- **Evidence:** Recomputed median clip_high_pct for the 206 iPhone 17 Pro Max rows: 0.475 %. The median of clip_high_pct + clip_gamut_pct, which equals the pre-fifth-run definition (measured after the P3 to sRGB conversion), is 0.812 %. So 0.81 % is the withdrawn gamut-inflated figure. The D850 figure (0.019 % gives 0.02 %) and its worst frame (13.92 %, '14 %') still match.
- **Fix:** Change section 4 to 'median 0.48 % of pixels on the 17 Pro Max', and add a pointer to section 8 saying the earlier 0.81 % included gamut clipping.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F02 [high] wrong-claim

- **A:** results/FINDINGS.md:59-61 (section 2): 'Nikon D850: 36 frames, only 4 with any valid edge and none with three ... No D850 sharpness figure, by design'
- **B:** results/report.md 'By camera' table: 'NIKON D850 | 36 | 0.391 (1)'; results.json edges_measured
- **Evidence:** D850 edges_measured over frames with any valid edge: [1, 1, 1, 4]. One D850 frame passes the >= 3 edge gate (report.py _sharp_ok), with mtf50_p80_cpp 0.391 and mtf50_p80_lwph 2377. 'None with three' is false, and the report does print a D850 sharpness figure.
- **Fix:** Change the text to say that 4 frames have any valid edge, one of them has 4 edges (p80 0.391 c/px, 2377 LW/PH), and a single frame is not a camera figure.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F03 [high] stale-table

- **A:** results/FINDINGS.md:19 (section 1 table): 'iPhone 17 Pro Max (n=172) | 33.3 (47) | 32.0 (73) | ...'. Line 22 footnote: rows exclude extrapolated or texture-suspect only. Line 128 (section 6): tables 'unchanged' by the periodic detector.
- **B:** iqa/report.py:96-98 _noise_ok, which also excludes noise_periodic_suspect; results/report.md By camera 'iPhone 17 Pro Max ... 34.5 (167)'; deck library.html:10 'frames flagged as extrapolated or periodic are excluded'; mac/IQCoach/Sources/Model/PhotoRecord.swift:183 snrIsClean, which also excludes periodic frames
- **Evidence:** Recomputed with the report's exclusions (extrapolated, texture, periodic) for the 17 Pro Max: n=167; ISO <=64 33.6 dB (44); 65-160 32.0 (71); 161-400 36.7 (28); 401-1000 36.8 (16); >1000 30.8 (8). The FINDINGS values 33.3 (47), 32.0 (73), n=172 come back exactly only if the five periodic-flagged 17 Pro Max frames are kept. The D850 and iPhone 13 rows match. The IQ Coach app, which uses snrIsClean, shows 33.6 (44) for the same cell.
- **Fix:** Recompute the 17 Pro Max row with the periodic exclusion (n=167, 33.6 (44), 32.0 (71)). Make the footnote say that periodic frames are excluded too. Remove the 'unchanged' claim in section 6. The 'mid-ISO 3-4 dB cleaner' prose still holds (3.1-3.2 dB).
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F05 [high] wrong-claim

- **A:** results/FINDINGS.md:89 'the largest ordinary file scores 3.2, the weakest screen 11.3'; deck periodic-catch.html:6 'nothing ordinary scored above 3.2, nothing periodic below 11'; iqa/noise.py:38 docstring; media/make_explainer.py:161-165 (34 library files 1.3 to 3.2, threshold factor 1.9 each side)
- **B:** results.json noise_spectral_peak over the full 389-image library
- **Evidence:** Unflagged library files reach 5.53 (90F984E2, iPhone 17 Pro Max JPEG), 5.16 and 5.15 (two SeaLife DC2000 JPEGs), 4.55 and 4.40. Flagged periodic frames include the striped-vehicle shots at 8.32 and 8.39, which are below 11 even though the same slide counts them as periodic. On this library the real gap is 5.53 to 8.32 (geometric midpoint 6.78). Threshold 6 is only 1.08x above the top negative, not 1.9x. The 3.2 figure comes from a 34-file sample, not the library.
- **Fix:** Restate the claim: on the 34-file development sample the negatives reach 3.2; on the full library unflagged files reach 5.5 and the weakest flagged frame is 8.3, and threshold 6 sits in that narrower gap. Update the deck slide, the explainer slide text and the noise.py docstring to match.
- **Files:** results/FINDINGS.md, iqa/noise.py, media/make_explainer.py, deck slide periodic-catch.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** analyzer

## F06 [high] wrong-threshold

- **A:** iqa/report.py:331, written to results/report.md 'How to read these numbers': 'about 1 for noise, above 8 (`noise_periodic_suspect`)'
- **B:** iqa/noise.py:73 PERIODIC_PEAK_THRESHOLD = 6.0 and :99 'spectral_peak > PERIODIC_PEAK_THRESHOLD'; CLAUDE.md 'threshold 6'; FINDINGS section 5 item 1; deck periodic.html 'above 6 the image is flagged'
- **Evidence:** The code flags at > 6.0. The two vehicle frames flagged at 8.32 and 8.39 would sit right at the stated '8' boundary. The report states a threshold that does not exist in the code.
- **Fix:** In report.py, build the sentence from noise.PERIODIC_PEAK_THRESHOLD ('above 6'), then re-render report.md.
- **Files:** iqa/report.py, results/report.md
- **Area:** analyzer

## F07 [high] wrong-number

- **A:** results/FINDINGS.md:107 'About 7 valid ROIs per image where any exist'; deck caveats.html:7 'About 7 valid edges where any exist'; deck edges.html:21 'a typical photo gives about 7'; media/make_explainer.py:232 'about seven valid edges per image where any exist'
- **B:** results.json edges_measured
- **Evidence:** Over the 149 images with at least one valid edge: mean 4.94, median 2. Over the 73 images with 3 or more edges: median 6, mean 8.75. No grouping gives about 7.
- **Fix:** Replace with 'about 5 on average (median 2) where any exist; median 6 among the 73 frames with a sharpness figure' in all four places.
- **Files:** results/FINDINGS.md, media/make_explainer.py, deck slides caveats.html and edges.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** results/docs

## F08 [high] stale-number

- **A:** deck exposure.html:4 (alt text) and :7 'This photo: 0.29 % high, 0.18 % low'; deck the-row.html:12 'clip_high_pct · clip_low_pct 0.29 · 0.18'
- **B:** results.json row C6220E43-6150-4717-A941-87DFFFA014BC: clip_high_pct 0.2368, clip_low_pct 0.1762, clip_gamut_pct 0.0501
- **Evidence:** High clipping is now 0.24 %. 0.29 equals clip_high + clip_gamut (0.237 + 0.050 = 0.287), the old after-conversion figure that the fifth run replaced. The low figure 0.18 matches the clip_low_pct restored in commit 076ef98. All other walkthrough figures match the row: 27 edges, 0.401, 0.440, 5,025, 41.2 dB, 0.34, 1.8, 6.7 lower bound, +0.16 and -0.20.
- **Fix:** Change the walkthrough high-clipping value to 0.24 % on both slides and in the histogram alt text. Optionally note 0.05 % gamut clipping separately.
- **Files:** deck slides exposure.html and the-row.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** deck/video/other

## F09 [high] stale-count

- **A:** deck cover.html:6 '389 photos · 19 cameras · 95 tests' and tests.html:14 '95 tests run in about 16 seconds'; docs/RESUME-NOTE.md:18 '(95 tests)' and :36 'Safe: ... 95 tests'
- **B:** pytest --collect-only at HEAD 076ef98: 103 tests (README.md:9,21,89 and CLAUDE.md:18 say 102)
- **Evidence:** With a clean working tree at HEAD, 'pytest --collect-only -q' reports '103 tests collected'. Commit 076ef98 added test_native_shadow_clipping_needs_every_channel_at_the_floor, taking 102 to 103. The deck cover the viewer is on and the resume note both give 95.
- **Fix:** Update the deck cover and tests slide and both RESUME-NOTE lines to the current count (103), or reword to 'over 100' so the claim stays true as tests are added.
- **Files:** docs/RESUME-NOTE.md, deck slides cover.html and tests.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** results/docs

## F12 [high] wrong-app-number

- **A:** mac/IQCoach/Sources/Model/CameraGroup.swift:47-48 (sharpnessLWPH, sharpnessCPP), :8 (LensGroup.p80Sharpness), :56 (centreOuterRatio); CameraRules.swift:211 fieldSoftness. These take medians over every row with a finite mtf50_p80, with no edge-count gate.
- **B:** iqa/report.py:101-102 _sharp_ok (edges_measured >= 3); results/FINDINGS.md section 5 item 2 (a per-image figure needs >= 3 valid edges); results/report.md By camera
- **Evidence:** 76 of the 149 rows with a finite mtf50_p80_lwph have 1-2 edges. Recomputed with the app's rule against the report's rule: iPhone 17 Pro Max 2045 LW/PH (n=85) vs 2608 (n=43), 0.200 vs 0.252 c/px; iPhone XR 801 LW/PH (n=10) vs 2247 (n=3), so the app bands the XR 'Poor' (<1500) where FINDINGS has it 'Fair'; iPhone 13 2334 (38) vs 2429 (20); D850 0.386 (n=4) vs 0.391 (1).
- **Fix:** Add PhotoRecord.hasSharpnessFigure (edgesMeasured >= 3) and filter on it in CameraSummary, LensGroup, centreOuterRatio, fieldSoftness, slowShutter, apertureSweetSpot and the photo-level soft/halo rules, matching report.py. Add a test that a 2-edge row is ignored.
- **Files:** mac/IQCoach/Sources/Model/CameraGroup.swift, mac/IQCoach/Sources/Model/PhotoRecord.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Tests/IQCoachTests/CameraRuleTests.swift
- **Area:** app

## APP-01 [high] validity-filter

- **A:** iqa/report.py:101-122 (_sharp_ok: edges_measured >= 3 gates mtf50_p80_cpp, mtf50_p80_lwph, overshoot_median_pct, centre/outer); results/FINDINGS.md:122 and §5 item 2 ('a per-image figure needs >= 3 valid edges (73 of 149 images with edges)'); FINDINGS.md:59 (D850: 'No D850 sharpness figure, by design')
- **B:** mac/IQCoach/Sources/Model/CameraGroup.swift:8,47-48,66 (LensGroup.p80Sharpness, CameraSummary sharpness and overshoot use every finite row); CameraRules.swift:309-332 (slowShutter), 160-202 (lensComparison), 263-275 (sharpeningCharacter); EditingRules.swift:57-87 (soft, halo); PhotoDetailView.swift:34 (bands shown for any row). The app never reads edgesMeasured (grep: only PhotoRecord.swift).
- **Evidence:** Recomputed from results/results.json: 149 rows carry mtf50_p80_lwph but only 73 have edges_measured >= 3 (55 rows have 1 edge, 21 have 2). Camera tiles the app shows vs the analyzer's gated figures: iPhone 17 Pro Max 2045 LW/PH 'Fair' (n=85) vs FINDINGS §2 2608 (n=43, would be 'Good'); iPhone XR 801 'Poor' (n=10) vs 2247 (n=3); NIKON D850 2624 'Good' from 4 rows vs FINDINGS 'no D850 sharpness figure'; iPhone 6 Plus 1172 'Poor' from 2 rows vs report '- (0)'. Overshoot medians: iPhone 13 12.5 % ('Fair') vs FINDINGS 16.4 %; iPhone XR 7.3 % (sharpening rule silent) vs 12.7 % (rule would fire). The 17 Pro Max lens ranking flips (app: 'back triple camera 2' 2130 > 'camera 6' 2018; gated: camera 6 2608 > camera 2 2532), and the slow-shutter insight fires for the 17 Pro Max ('40 % softer', 3 slow photos) only because of ungated rows (gated: 1 slow photo, so the rule stays silent). Per-photo 'Sharpness is low' advice fires on 54 photos, 39 of them with fewer than 3 edges.
- **Fix:** Add PhotoRecord.hasSharpness (edgesMeasured >= 3) and gate every sharpness/overshoot/centre-outer use on it: CameraSummary, LensGroup, lensComparison, slowShutter, apertureSweetSpot, sharpeningCharacter, fieldSoftness, EditingRules.soft/halo, and the PhotoDetailView/PhotoTable rows (show 'only N edges: not enough' instead of a band). Pin it with a test that a 1-edge row does not move a camera median.
- **Files:** mac/IQCoach/Sources/Model/PhotoRecord.swift, mac/IQCoach/Sources/Model/CameraGroup.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Views/PhotoDetailView.swift, mac/IQCoach/Sources/Views/PhotoTable.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## APP-02 [high] threshold-logic

- **A:** mac/IQCoach/Sources/Coaching/CameraRules.swift:72-104 (isoCeiling takes the LAST band with median >= 32 dB and says 'Noise stays clean up to ISO {top}', or 'Noise is clean at every ISO you have used' when that band is the highest); docs/APP-IQ-COACH-SPEC.md:69-73
- **B:** The same card's own evidence rows (CameraRules.swift:67), computed from results/results.json with the app's snrIsClean filter
- **Evidence:** iPhone XR (21 photos): bands with >= 3 rows are ISO <=64 31.989 dB (6), 161-400 31.794 dB (6), 401-1000 35.289 dB (6). The rule picks 401-1000, which is also the highest band, so the card reads 'Noise is clean at every ISO you have used' while two of its three evidence rows are under its own 32 dB mark ('32.0 dB' is 31.989). iPhone 13: <=64 33.07 (54), 65-160 33.52 (9), 161-400 30.54 (6), 401-1000 35.37 (5), >1000 31.33 (5). The card says 'Keep ISO at or below ISO 1000 ... Noise stays clean up to ISO 1000 (35.4 dB over 5 photos)' while its ISO 161-400 row shows 30.5 dB.
- **Fix:** Define the ceiling as the highest band such that every band at or below it is >= the threshold, and say 'clean at every ISO' only when all bands pass. Otherwise name the failing band. Add XR-like and iPhone-13-like fixtures to the tests and fix the spec wording.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, docs/APP-IQ-COACH-SPEC.md, mac/IQCoach/Tests/IQCoachTests
- **Area:** app

## APP-03 [high] threshold

- **A:** results/report.md:132 and iqa/report.py:331 ('35+ dB is clean, below 25 dB is visibly noisy'), copied verbatim into mac/IQCoach/Sources/Model/Metric.swift:75 and echoed by CameraReportView.swift:46 ('35 dB and up is clean')
- **B:** Metric.swift:99 ('Clean from 38 dB') and :150 (bands 25/32/38, so 32-38 is 'Good'); CameraRules.swift:72,77,78,88,101 and Charts.swift:33,49,164 ('the 32 dB mark for clean'); EditingRules.swift:46,50 ('Noise is visible ... under the 30 dB mark')
- **Evidence:** There are four 'clean/noisy' cut-offs: 30, 32, 35 and 38 dB. The Glossary detail pane for SNR shows Metric.definition ('35+ dB is clean') directly above goodLooksLike ('Clean from 38 dB'). On the iPhone 17 Pro Max report card the tile reads 34.5 dB 'Good' with detail '35 dB and up is clean', and the ISO card on the same page calls the ISO <=64 band (33.6 dB, 44 photos) and the 65-160 band (32.008 dB, 71 photos) clean. In results.json 36 photos have SNR in [30,32): band 'Fair', but no noise advice. Another 68 are in [32,35): band 'Good' and called clean by the ISO rule, but not clean per the report and the tile text.
- **Fix:** Choose one scale and use it everywhere. For example, keep the bands 25/32/38 and rewrite the report and Glossary text as 'below 25 noisy, 32+ clean, 38+ excellent', or move the bands to the report's 25/35. Make the editing rule's 30 dB a named constant with stated wording. Update iqa/report.py so report.md regenerates with the same numbers.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Views/CameraReportView.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Views/Charts.swift, iqa/report.py, results/report.md, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## APP-04 [high] threshold-units

- **A:** mac/IQCoach/Sources/Model/Metric.swift:148 (LW/PH bands 1500/2500/3500), :97 ('Excellent from 3500 LW/PH')
- **B:** Metric.swift:149 (c/px bands 0.12/0.20/0.30), :73 and results/report.md:128 ('0.25-0.35 is very sharp'); iqa/edges.py:225-226 (LW/PH = 2 x MTF50 x height); iqa/sfr.py MTF50 searched below Nyquist (0.5 c/px)
- **Evidence:** The same p80 MTF50 gets two different band words on PhotoDetailView (rows at PhotoDetailView.swift:34). This happens on 84 of the 149 rows (71 one level apart, 13 two levels apart); e.g. 500964B6...jpeg is 0.386 c/px 'Excellent' and 2334 LW/PH 'Fair'. On the 73 gated rows: c/px median 0.267 ('Good', 31 rows 'Excellent') vs LW/PH median 2381 ('Fair', 10 'Excellent'). Library gated LW/PH quartiles: q25 1853, median 2381, q75 3011, p90 4048. Per camera (gated): iPhone 17 Pro Max 1923/2608/3439 (n43), iPhone 13 1685/2429/2658 (n20), iPhone XR 1837/2247/2280 (n3). Because MTF50 is capped below 0.5 c/px, LW/PH <= picture height: 'Excellent' (3500) is unreachable for the 25 rows with height < 3500. A 12 MP landscape frame (3024 px) peaks at 3024 LW/PH and needs >= 0.413 c/px even for 'Good'.
- **Fix:** Band sharpness on one scale only: c/px, or LW/PH as a fraction of the picture height (LW/PH / height = 2 x c/px). Alternatively drop the band from the LW/PH row and keep LW/PH for cross-camera comparison. Recalibrate the spec and Glossary 'what good looks like' to the measured quartiles.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Views/PhotoDetailView.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## APP-05 [high] unit

- **A:** iqa/structure.py:11-13,113-114 and results/FINDINGS.md:149-152 (thirds distance is in centre-to-thirds units: 0 on a point, 1 at the centre, ~2 in a corner; the earlier frame-diagonal unit was withdrawn and values rescaled x6); Structure.swift:11 matches
- **B:** mac/IQCoach/Sources/Coaching/EditingRules.swift:169 ('The subject sits \(d) frame-diagonals from the nearest rule-of-thirds point')
- **Evidence:** The thirdsCrop advice fires on 79 photos (thirds_distance > 0.75 and focus_fraction < 0.4), e.g. 075078D1...jpeg reads 'The subject sits 0.93 frame-diagonals from the nearest rule-of-thirds point'. In frame-diagonal units no point in the frame is more than about 0.33 from a thirds point, and 0.93 centre-to-thirds units is about 0.155 diagonals. The stated unit overstates the distance about 6x and is the unit FINDINGS §7 withdrew. docs/FEEDBACK-LAYERS-SPEC.md:384 already uses '(1 is the centre)'.
- **Fix:** Change the sentence to '... sits 0.93 from the nearest rule-of-thirds point (0 is on the point, 1 is the frame centre)' and assert the wording in StructureTests.thirdsCropFires.
- **Files:** mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Tests/IQCoachTests/StructureTests.swift
- **Area:** app

## APP-06 [high] validity-filter

- **A:** iqa/noise.py:84,289 (noise_texture_suspect = whiteness > 0.7: 'periodic texture (screens, fabric) or extreme NR, not sensor noise'); iqa/report.py:96-98 (_noise_ok excludes extrapolated, texture and periodic rows); PhotoRecord.swift:183-185 (snrIsClean, used for the camera medians)
- **B:** mac/IQCoach/Sources/Coaching/EditingRules.swift:46 (noisy() excludes only noisePeriodicSuspect); PhotoDetailView.swift:37-41 (SNR row banded; a warning appears only for periodic)
- **Evidence:** In results.json the 'Noise is visible ... under the 30 dB mark' advice, with its noise-reduction recipe, fires on 108 photos. Of these, 14 are noise_texture_suspect (whiteness 0.72-0.93, e.g. ADFD2DAA...jpeg 19.4 dB at whiteness 0.93, 0F68B352...jpeg 18.3 dB) and 5 are snr_midgrey_extrapolated (e.g. A70A8D98...jpeg 25.4 dB, measured at level 55.8 rather than 118). The analyzer excludes both groups as not a sensor-noise reading, and the app's own camera medians exclude them too. Their per-photo SNR rows still show a 'Poor'/'Fair' band with no caveat.
- **Fix:** Gate EditingRules.noisy on photo.snrIsClean (or add texture and extrapolated exclusions). In PhotoDetailView, show a caution label for noiseTextureSuspect ('the flat areas are texture or heavy smoothing') and for snrMidgreyExtrapolated ('measured at a different grey level'), and omit the band for those rows.
- **Files:** mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Views/PhotoDetailView.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## APP-07 [high] lower-bound

- **A:** results/FINDINGS.md:66-69 ('The D850 reached the floor in 1 frame of 36 ... its DR is "≥ 8.6 stops" and not comparable here')
- **B:** mac/IQCoach/Sources/Model/CameraGroup.swift:69-76 plus CameraReportView.swift:52-54 (uses the exact-row median whenever one exact row exists and presents it without 'At least': 'Stops of brightness above the noise floor ... it describes the camera'); results/report.md:86 ('NIKON D850 ... 3.9 (1)')
- **Evidence:** NIKON D850 dr_snr4: one exact row, 3.92 stops; 35 lower-bound rows, median 8.63, and 34 of the 35 are above 3.9. The app's report card therefore shows 'Dynamic range 3.9 stops' as the D850's figure, with no 'at least'. Its own data proves the DR is above that in 34 frames, and FINDINGS states >= 8.6.
- **Fix:** When lower-bound rows exceed the exact median (or exact rows are fewer than about 3), show 'At least {median of lower bounds}' or 'not measurable' and say how many frames reached the floor. Apply the same rule to report.py's By-camera cell so report.md and FINDINGS agree.
- **Files:** mac/IQCoach/Sources/Model/CameraGroup.swift, mac/IQCoach/Sources/Views/CameraReportView.swift, iqa/report.py, results/report.md, results/FINDINGS.md
- **Area:** app

## APP-08 [high] stale-number

- **A:** results/FINDINGS.md:73 ('Highlight clipping: median 0.81 % of pixels on the 17 Pro Max'); FINDINGS.md:76 (D850 'B/G −0.01 stop')
- **B:** results/results.json / results.csv after the fifth run (native-encoding clipping), which the app shows on the iPhone 17 Pro Max report card (CameraReportView.swift:47, clipHighMedian)
- **Evidence:** Median clip_high_pct for the iPhone 17 Pro Max is now 0.475 % (the app shows '0.47 %'), not 0.81 %. §8 updated the >1 % counts (54 of 206) but not this §4 median. The D850 median B/G is +0.009 stop, not −0.01 (R/G −0.045 matches). Colorfulness 38.61 vs 20.96 and D850 clip 0.019 % still match.
- **Fix:** Recompute the §4 rendering numbers from the current results.json (17 Pro Max median 0.48 % of pixels; D850 B/G +0.01) and add a note that §4 predates the fifth run.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F1 [high] threshold

- **A:** results/report.md:132 (written by iqa/report.py:331, 'How to read these numbers'): noise_spectral_peak 'above 8 (`noise_periodic_suspect`)' means the patches hold a repeating pattern
- **B:** iqa/noise.py:73 PERIODIC_PEAK_THRESHOLD = 6.0 (docstring line 38: '6, the geometric midpoint of 3.2 and 11.3'); results/FINDINGS.md section 5 item 1 says 'Threshold 6'; media/make_explainer.py:126 and :172 also say six
- **Evidence:** Read the constant and the report text. In results.json the 6 flagged frames have peaks 8.32, 8.39, 11.28, 14.42, 15.01 and 126.94, and the highest unflagged peak is 5.53, so the data cannot settle 6 versus 8. The flag in the code is peak > 6. A reader of report.md would wrongly treat a frame scoring 7 as clean.
- **Fix:** Change 'above 8' to 'above 6' in the how-to-read string, or better, build it from noise.PERIODIC_PEAK_THRESHOLD. Then regenerate report.md with `python -m iqa report results/results.json --no-paths --title ...`.
- **Files:** iqa/report.py, results/report.md
- **Area:** analyzer

## F2 [high] count

- **A:** results/FINDINGS.md:59-61: 'Nikon D850: 36 frames, only 4 with any valid edge and none with three ... No D850 sharpness figure, by design'
- **B:** results/report.md 'By camera' table: 'NIKON D850 | 36 | 0.391 (1)'; results.csv row 06FC357F-89B6-4CC3-952E-3A18B22BFBBE.jpeg has edges_measured=4, mtf50_p80_cpp=0.3909, mtf50_p80_lwph=2377
- **Evidence:** 4 D850 frames have edges, with edges_measured 4, 1, 1 and 1. The 4-edge frame passes the >=3 gate (_sharp_ok), so the report prints a D850 sharpness figure. The CSVs from all five commits (9c97e74, 268d1d2, 221f68d, bd6b877, a51ef50) show 4 edges for that file, so the FINDINGS sentence was never true.
- **Fix:** Rewrite the D850 bullet: 4 frames with any valid edge, one with four (06FC357F, p80 0.391 c/px, 2377 LW/PH), too few to characterise the camera. Optionally add a D850 row with n=1 to the section 2 table.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F3 [high] stale-number

- **A:** results/FINDINGS.md:73: 'Highlight clipping: median 0.81 % of pixels on the 17 Pro Max, 0.02 % on the D850'
- **B:** results/results.csv (fifth run, clipping in the file's own encoding): median clip_high_pct over the 206 iPhone 17 Pro Max rows = 0.475 %; FINDINGS section 8 says clipping was re-measured
- **Evidence:** Recomputed from results.json. The 17 Pro Max median clip_high_pct is 0.475, and the median of clip_high_pct + clip_gamut_pct is 0.812. The fourth-run CSV (bd6b877) also gives 0.812. So 0.81 % is the pre-fix figure that counted gamut clipping, the error section 8 withdraws for the 44 % claim. The D850 figure of 0.019 is unchanged.
- **Fix:** Change section 4 to 'median 0.48 % ... (0.81 % before the gamut fix, section 8)'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F1 [high] walkthrough-photo-figure

- **A:** Deck slides 'exposure' (card 'Clipping': 'This photo: 0.29 % high, 0.18 % low'; image alt '0.29 percent ... clipped high and 0.18 percent low') and 'the-row' (clip_high_pct · clip_low_pct = 0.29 · 0.18)
- **B:** results/results.json row C6220E43-6150-4717-A941-87DFFFA014BC.jpeg (fifth run): clip_high_pct = 0.2368, clip_low_pct = 0.4186, clip_gamut_pct = 0.0501; iqa/analyze.py:28-32 now replaces the sRGB-measured clipping with native_clip_*
- **Evidence:** Read the row from results.json. The deck's 0.29/0.18 come from analyze_exposure on the converted sRGB image (media/deck_figures.py step 8), which was the method before the fifth run. Now 0.29 - 0.24 = 0.05 is gamut clipping, and shadow clipping in the file's own encoding is 0.42 %, not 0.18 %. The 08_exposure.png figure title on the slide also carries the old values.
- **Fix:** Re-render 08_exposure.png from the stored row (or from native clip stats) and change the exposure and the-row slides to 0.24 % high, 0.42 % low, with 0.05 % gamut clipping as a separate figure. Give media/deck_figures.py step 8 the same native/gamut split that iqa/analyze.py uses.
- **Files:** deck project/slides/exposure.html, deck project/slides/the-row.html, media/deck_figures.py
- **Area:** deck/video/other

## F2 [high] threshold-claim

- **A:** Deck 'periodic-catch' footer: 'nothing ordinary scored above 3.2, nothing periodic below 11'. Narration slide 9 bullet: 'Threshold 6 is the geometric midpoint ... a factor of 1.9 on each side'. FINDINGS.md:88-89: 'the largest ordinary file scores 3.2, the weakest screen 11.3'
- **B:** results/results.json, full library: 14 unflagged files score above 3.2 (max 5.53 for 90F984E2 iPhone 17 Pro Max; 5.16 and 5.15 for two SeaLife DC2000 frames). Two of the six flagged files (the striped vehicle, 596A3A82 and A48003D9) score 8.32 and 8.39, which is below 11. The same slide counts them as correct flags.
- **Evidence:** Sorted noise_spectral_peak over unflagged rows: 5.53, 5.16, 5.15, 4.55, 4.40, ... (14 of them above 3.2). Flagged peaks: 8.32, 8.39, 11.28, 14.42, 15.01, 126.94. The 1.0-3.2 range in the iqa/noise.py:32-37 docstring comes from a 34-file subset. On the whole library the margin below the threshold is 6/5.53 = 1.08, not 1.9.
- **Fix:** Say that the 3.2 / 11.3 gap was measured on 34 files. Give the full-library numbers: unflagged up to 5.5, flagged from 8.3. Remove 'nothing periodic below 11' and 'factor of 1.9 each side', or limit them to the 34-file calibration set.
- **Files:** deck project/slides/periodic-catch.html, media/make_explainer.py, results/FINDINGS.md
- **Area:** results/docs

## F3 [high] threshold

- **A:** iqa/report.py:331, rendered into results/report.md:132: 'about 1 for noise, above 8 (`noise_periodic_suspect`)'
- **B:** iqa/noise.py:73 PERIODIC_PEAK_THRESHOLD = 6.0. Deck slides 'periodic' and 'periodic-catch' say threshold 6. Narration slides 7 and 9 say 6.
- **Evidence:** Read both lines. The two flagged vehicle frames at 8.32 and 8.39 are below the '8' that report.md states, yet they are flagged.
- **Fix:** Format the report text from PERIODIC_PEAK_THRESHOLD instead of the hard-coded 8, then regenerate report.md with `python -m iqa report results/results.json`.
- **Files:** iqa/report.py, results/report.md
- **Area:** analyzer

## F4 [high] walkthrough-figure

- **A:** Deck 'periodic-catch' title ('a Nikon water shot stays at 2.3'), its body and image alt ('peak map reading 2.3'). Narration slide 7 ('Normalised peak: 15 for the screen, 2.3 for the Nikon').
- **B:** The figure the slide shows, media/build/assets/fig_crops_spectra.png, reads 'max = 1.7 (threshold 6)' for the D850 panel. media/figures.py:24 uses D850 file 014D71F2, and results.json gives that file noise_spectral_peak = 1.706 with 50,895 candidate patches.
- **Evidence:** Viewed the PNG: the D850 panel says max = 1.7 over 50,895 patches. In results.json the D850 files near 2.3 (2F3693E6, 8A8F3312, 9EA8A780, D493EABB) have 35,556 to 54,987 patches, never 50,895. The narration pairs '50,895 patches' with '2.3', which no single file matches.
- **Fix:** Change 2.3 to 1.7 in the deck title, body and alt text and in narration slide 7 (bullets and spoken text).
- **Files:** deck project/slides/periodic-catch.html, media/make_explainer.py
- **Area:** deck/video/other

## F1 [high] validity-gate

- **A:** iqa/report.py:101-116 (VALIDITY: mtf50_p80_lwph, mtf50_p80_cpp, centre/outer medians and overshoot_median_pct count only rows with edges_measured >= 3) and results/FINDINGS.md:103 and :42-48 (per-image sharpness needs at least 3 valid edges; iPhone 17 Pro Max 0.252 c/px = 2608 LW/PH n=43; iPhone 13 2429 LW/PH n=20, overshoot 16.4 %); results/report.md:84-86 (0.252 (43), 0.308 (20), 0.391 (1))
- **B:** mac/IQCoach/Sources/Model/CameraGroup.swift:8-9 and :47-48, :66 (LensGroup.p80Sharpness, CameraSummary.sharpnessLWPH/CPP and overshoot are medians over every row, with no edge-count gate; edgesMeasured is decoded but never used anywhere in Sources). Rendered report card (snapshot camera-iPhone-17-Pro-Max.png): 'In-focus sharpness 2,045 LW/PH · Fair, 0.20 c/px'; iPhone 13 page: '2,334 LW/PH · Fair, 0.29 c/px', 'Sharpening halo 12.5 %'; D850 page: '2,624 LW/PH · Good' (n=4)
- **Evidence:** Recomputed from results/results.json. iPhone 17 Pro Max: 85 rows have mtf50_p80_lwph and 42 of them have only 1-2 edges. Median over all 85 is 2045 LW/PH (0.200 c/px), which is what the app shows. Over the 43 rows with 3+ edges it is 2608 LW/PH (0.252 c/px), which is what report.md and FINDINGS show. The band changes from Fair to Good. iPhone 13: 2334 (n=38) vs 2429 (n=20). Overshoot: 12.50 % (n=38) vs 16.44 % (n=20). D850: 2624 LW/PH (n=4) vs 2377 (n=1), while FINDINGS:59-61 says there is 'No D850 sharpness figure, by design'. The same ungated medians feed the lens, slow-shutter and sharpening cards (F2, F3, F11).
- **Fix:** Add a PhotoRecord.sharpIsValid (edgesMeasured >= 3) that mirrors report.py _sharp_ok. Apply it in LensGroup.p80Sharpness/sharpnessCount, CameraSummary.sharpnessLWPH/CPP/overshoot/centreOuterRatio, and every CameraRules value closure that reads mtf50P80LWPH, overshootMedianPct or centre/outer MTF50. Below a minimum count, show 'Not enough photos' instead of a median, as docs/FEEDBACK-LAYERS-SPEC.md:158-169 already proposes.
- **Files:** mac/IQCoach/Sources/Model/PhotoRecord.swift, mac/IQCoach/Sources/Model/CameraGroup.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Views/CameraReportView.swift
- **Area:** app

## F2 [high] coaching-rule

- **A:** Analyzer data plus FINDINGS gate. In results/results.json every front-camera row with sharpness has edges_measured < 3: 17 Pro Max front 4/4 rows (1,1,1,2 edges), iPhone 13 front 6/6 rows. Gated (>= 3 edges), the 17 Pro Max main camera leads: 2608 LW/PH (n=33) vs ultra-wide 2532 (n=10); the front and telephoto have 0 valid rows.
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:160-202 (lensComparison) as rendered. 17 Pro Max card: 'The ultra-wide camera resolves 2,130 LW/PH (28 photos); the main camera is 5 % lower (2,018 LW/PH); the front camera is 32 % lower (1,447 LW/PH)' and 'For detail, use the ultra-wide camera and main camera rather than the front camera.' iPhone 13 card: 'the front camera is 69 % lower (785 LW/PH)', with the same advice.
- **Evidence:** Snapshots rendered with the built IQCoach binary (17 Pro Max from results.json; iPhone 13 and D850 from per-camera subsets written to $TMPDIR). Recomputed per-lens medians match the app exactly: 2130/2018/1447/773 and 2531/2365/785. These come from rows the analyzer's own gate rejects. 18 of the 28 ultra-wide rows have 1-2 edges. The front camera is ranked as if it were an alternative back lens for the same shot. The two front-camera example thumbnails on the 17 Pro Max card are A2DD282F (1 edge, 1,471 LW/PH) and 86C74E78 (2 edges, 1,424 LW/PH, overshoot 206.5 %).
- **Fix:** In lensComparison, exclude isFront lenses, or report them separately and never as 'use X rather than the front camera'. Apply the three-edge gate from F1 before the sharpnessCount >= 3 check, so that on this library the card compares only the main and ultra-wide cameras. Also update the spec wording in docs/APP-IQ-COACH-SPEC.md:78-81.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Model/CameraGroup.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## F3 [high] coaching-rule

- **A:** results/results.json, iPhone 17 Pro Max rows with exposure_s >= 1/30 and mtf50_p80_lwph: ADDA431E (front camera, 1/15 s, 1 edge, 580 LW/PH), A2DD282F (front camera, 1/15 s, 1 edge, 1471 LW/PH), 5A6BEA3E (ultra-wide, 1/7 s, ISO 1250, 7 edges, 1231 LW/PH). The 82 faster rows are almost all back-camera frames.
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:309-332 (slowShutter) as rendered on the 17 Pro Max page: 'Hand-held frames at 1/30 s or slower were 40 % softer (1,231 LW/PH over 3 photos, against 2,069 LW/PH over 82 at faster speeds)'. Its examples are '1/15 s, 580 LW/PH', '1/7 s, 1,231 LW/PH' and '1/15 s, 1,471 LW/PH'.
- **Evidence:** Recomputed: slow n=3, median 1230.9; fast n=82, median 2068.5; gap 40.5 %. Two of the three slow rows are front-camera selfies, a lens whose median is already 32 % below the best back lens at any speed. Excluding the front camera leaves 1 slow row. Applying the three-edge gate also leaves 1 slow row (vs 42 fast, median 2615). Either way the rule's own minimum of 3 per group fails and the card should not appear. Nothing in the data marks the frames as hand-held.
- **Fix:** In slowShutter, compare within back lenses only (drop isFront rows, ideally pairing by lens), apply the three-edge gate, and drop the 'Hand-held' wording unless something in the data supports it.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## F4 [high] coaching-rule

- **A:** results/results.json, iPhone 13 clean-SNR band medians: ISO <=64 33.1 dB (54), 65-160 33.5 (9), 161-400 30.5 (6; rows 24.3, 28.2, 29.5, 31.6, 32.4, 34.4), 401-1000 35.4 (5), >1000 31.3 (5). The app's own 'Noise against ISO' chart on the same page draws the 161-400 point below the dashed 32 dB line.
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:72 (`bands.last(where: { $0.median >= 32 })`) and docs/APP-IQ-COACH-SPEC.md:69-70. Rendered iPhone 13 card: 'Keep ISO at or below ISO 1000 for clean pictures. Noise stays clean up to ISO 1000 (35.4 dB over 5 photos); above that it drops to 31.3 dB.' and 'Shoot freely up to ISO 1000.'
- **Evidence:** Re-ran the rule's logic in Python with the snrIsClean exclusions. The ceiling chosen is the 401-1000 band only because the rule takes the last band at or above 32 dB and never checks the bands below it. The ISO 161-400 band, below that ceiling, has a median of 30.5 dB: under the 32 dB mark the card itself calls clean.
- **Fix:** Define the ceiling as the top of the last band in an unbroken run of bands, starting from the lowest, that are all at or above 32 dB. Alternatively, say that the curve is not monotonic and list the band that falls below 32 dB. Update the rule text in the spec to match.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## F5 [high] coaching-rule

- **A:** results/results.json: of the 15 iPhone 17 Pro Max rows with both centre and outer MTF50, 12 are the main camera 6.765 mm (median outer/centre 0.638) and 3 are the ultra-wide 2.22 mm (median 0.931). Only 3 rows have >= 3 edges in both regions (0.47, 0.55, 0.63). results/FINDINGS.md:54-56 gives the falloff as -44 % for the 17 Pro Max (0.274 -> 0.153) and -29 % for the iPhone 13.
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:210-229 (fieldSoftness; phone action at :218-219) as rendered, the top 'Important' card on the 17 Pro Max page: 'Corners are 31 % softer than the centre (outer-to-centre sharpness 0.69, over 15 photos)' with 'Avoid the ultra-wide for detail near the edges of the frame.' Examples: 0.23, 0.26, 0.47, 0.55 outer/centre. The iPhone 13 page shows no such card.
- **Evidence:** All four example photos are main-camera frames. The two most extreme have a single outer edge: 0.23 has centre 12 edges, outer 1; 0.26 has centre 2, outer 1. The ultra-wide is the lens whose corners hold up, so the advice points at the wrong lens. The numbers also disagree with FINDINGS. 17 Pro Max: app 31 % (median of per-photo ratios, n=15) vs FINDINGS 44 % (ratio of medians, 25 centre / 30 outer gated rows). iPhone 13: FINDINGS -29 %, but the app's paired median is 0.839, so no card fires.
- **Fix:** Compute field softness per lens and name the lens whose ratio is low instead of hard-coding the ultra-wide. Require >= 3 edges in both the centre and outer regions (edges_center/edges_outer, which need adding to PhotoRecord). Use one statistic, and make FINDINGS §2 quote the same one the app uses.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Model/PhotoRecord.swift, results/FINDINGS.md
- **Area:** app

## F6 [high] coaching-rule

- **A:** results/results.json, NIKON D850: 06FC357F at ISO 9000 has snr_midgrey_db 29.6 and is a clean row (not extrapolated, texture-suspect or periodic). It is the only D850 frame above ISO 1400. The >1000 band (ISO 1100, 1250, 1400, 9000) has a median of 33.9.
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:82-91 (isHighest branch) as rendered on the D850 page: 'Noise is clean at every ISO you have used', 'Noise stays clean at every ISO you have used, up to above ISO 1000 (33.9 dB over 4 photos)', 'raise ISO rather than risk a blurred shot'. The first example thumbnail on that same card is captioned '29.6 dB'.
- **Evidence:** Recomputed the band medians: 42.5 (3), 39.1 (10), 37.8 (5), 35.8 (11), 33.9 (4). The open-ended 'above ISO 1000' band pools ISO 1100 with ISO 9000. The highest ISO actually used gives 29.6 dB, below the card's own 32 dB mark, so 'clean at every ISO you have used' is contradicted by the card's own example.
- **Fix:** For the open-ended band, state the highest ISO actually used and check that ISO's frames against 32 dB, or cap the claim at the highest ISO whose photos are at or above 32 dB. Fix the 'up to above ISO 1000' wording at the same time.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Model/Stats.swift
- **Area:** app

## F7 [high] report-card

- **A:** results/FINDINGS.md:66-69: the D850 reached the noise floor in 1 frame of 36, 'so its DR is "≥ 8.6 stops" and not comparable here.'
- **B:** mac/IQCoach/Sources/Model/CameraGroup.swift:69-76 (uses the exact-row median whenever at least one exact row exists) as rendered on the D850 report card: 'Dynamic range 3.9 stops. Stops of brightness above the noise floor. No pass mark; it describes the camera.'
- **Evidence:** Recomputed: D850 dr_snr4 has 1 exact row (3.916) and 35 lower-bound rows (median 8.63). The tile presents the single exact frame as the camera's dynamic range, without an 'at least' qualifier, contradicting the ≥ 8.6 stops lower bound stated in FINDINGS.
- **Fix:** Require a minimum number of exact rows (for example 5) before showing an exact median. Otherwise show 'At least <median of all rows>' with the lower-bound caption.
- **Files:** mac/IQCoach/Sources/Model/CameraGroup.swift, mac/IQCoach/Sources/Views/CameraReportView.swift
- **Area:** app

## library-run-is-local-originals-subset [high] coverage-claim

- **A:** results/FINDINGS.md:1 and results/report.md:1 say 'Allison's Photos library, all 389 camera captures'. FINDINGS.md:5-6 says '`captures.txt` is every file in the library with an EXIF camera model and at least 5 MP (1,035 files total...)'. CLAUDE.md:54 says 'all 389 camera captures in the Photos library'.
- **B:** The app's PhotoKit export of the 40 newest photos (photos/20261015T040500, run 20261015T040506), which downloads iCloud originals (PhotosImporter.swift:58, isNetworkAccessAllowed = true), and the library's own database (Photos.sqlite, read with mode=ro&immutable=1).
- **Evidence:** Only 20 of the 40 app photos (19 from the PhotoKit run, plus 3 picker photos with 2 overlapping) match a library-run row. Of the 21 unmatched: 12 (IMG_0443-0454) were taken after photo_list.txt was built (2026-10-13 08:29). F96473AD is a 1320x2346 image with no EXIF, which select_captures excludes. The other 8 are camera captures taken before the list existed: IMG_0426-0429 (2026-10-10), IMG_9933.heic (2026-09-30) and IMG_7144-7148 (iPhone 17 Pro, 2026-09-26). I mapped each to its Photos.sqlite asset (ZFILENAME); none of those files is in photo_list.txt, meaning their originals were not on local disk (optimized iCloud storage). The database holds 66,128 non-trashed photos created before the list was built. 54,099 of them have an EXIF camera model and at least 5 MP, from 55 camera models, for example NIKON D850 27,220, iPhone 13 8,483 and iPhone 17 Pro Max 406. The run analysed 389 of these from 19 models: the 17 Pro Max 206, the D850 36 and the iPhone 13 85. So the run covers the roughly 1,035 originals cached locally on 2026-10-13, not the library's camera captures.
- **Fix:** Reword the claims to 'the 389 camera captures whose originals were stored locally on 2026-10-13 (1,035 local files; the iCloud library holds about 54,000 camera captures)'. Re-render report.md with a corrected --title. In FINDINGS, note that the per-camera samples are whatever Photos had cached, not a random sample. Optionally, build future runs from a PhotoKit export (the app's path) so they cover iCloud-only originals.
- **Files:** results/FINDINGS.md, results/report.md, CLAUDE.md
- **Area:** results/docs

## NEW-1 [high] stale-number

- **A:** docs/FEEDBACK-LAYERS-SPEC.md (committed in 076ef98, the same commit as the shadow-clipping fix). Its crushed-shadow copy uses the withdrawn any-channel counts. :109 and :249 give the iPhone 17 Pro Max as '117 of 206 photos (57 %) have more than 1 % pure black'. :115 gives the iPhone 13 as '35 of 85 (41 %)'. :118 builds the D850's layer-1 'one thing' on '**Check your shadows.** 12 of your 36 photos (33 %)'. :124 does the same for the iPhone XR with '13 of your 21 photos (62 %)'. :304 and :764-765 are worked examples starting at 117/206. Per-photo copy: :364 5375AE66 '1.5 % ... pure black'; :381 E07C5F37 'crushed shadows (3.1 %)'; :390 0364AD55 '2.9 %'; :401 C6220E43 'Crushed shadows 0.42 %'; :468 iPhone 13 mini 'Crushed shadows 1.9 % and 3.0 % (both over the 1 % line)'.
- **B:** results/results.json at HEAD (clip_low_pct restored to the all-channels definition) and results/FINDINGS.md:182-190, which withdraws the any-channel figures ('189 frames over 1 % instead of 24; iPhone 17 Pro Max 117 of 206 instead of 17; Nikon D850 12 of 36 instead of 0').
- **Evidence:** I recomputed clip_low_pct > 1 from results.json: 17 Pro Max 17 of 206, iPhone 13 6 of 85, D850 0 of 36, iPhone XR 0 of 21. Per photo: 5375AE66 0.037 %, E07C5F37 0.000 %, 0364AD55 0.00007 %, C6220E43 0.176 %, and the iPhone 13 mini rows 0C2CB4A3 0.0012 % and 468CABF6 0.044 %. On current data the shadow rule (clip_low > 1 % share > 15 %) would not fire for the D850 or the XR, so the spec's chosen 'one thing' for those cameras, and the 17 Pro Max and iPhone 13 'Next up' lines, rest on withdrawn numbers. The spec's other per-camera figures do still reproduce: highlights 54/206, 23/85, 3/36, 6/21; SNR 167 with 17/17/5 excluded; DR 7.2 over 36 rows with the other 170 at a median of at least 6.7; sharpness 43/42/121 edges; gamut over 1 % in 47 photos. So only the shadow figures are stale.
- **Fix:** Recompute every clip_low figure in docs/FEEDBACK-LAYERS-SPEC.md from the current results.json. Rewrite the D850 and iPhone XR layer-1 examples, since shadows no longer qualify. Replace the 117/206 worked examples in the check section, and fix the per-photo 'Crushed shadows' lines. If those photos no longer trigger the rule, drop the lines.
- **Files:** docs/FEEDBACK-LAYERS-SPEC.md
- **Area:** results/docs

## CLIP-3 [medium] overlay-vs-caption

- **A:** mac/IQCoach/Sources/Views/OverlayImage.swift:125: the caption under the Clipping overlay reads "Red: blown highlights (<analyzer clip_high_pct> of pixels)". That is the analyzer's full-resolution figure in the file's own encoding (iqa/analyze.py:28-32, iqa/imageio.py:225,238).
- **B:** mac/IQCoach/Sources/Support/ClippingMask.swift:34-44: the red mask is computed on an 800 px ImageIO thumbnail drawn into an sRGB context, so P3 colours are matched to sRGB (gamut-clipped) and downsampled before counting.
- **Evidence:** On real iPhone originals still on disk: EC07D805 analyzer-equivalent (PIL full, native) 1.117 % vs mask (sRGB context) 1.323 %; own-space thumbnail 1.036 %, so 0.29 point is gamut clipping that the analyzer now excludes. B81258B7: 0.888 vs 0.954 %. E0409232: 0.270 vs 0.246 %. CC0AE4B7 (sRGB, iPhone 13 mini): 1.308 vs 0.598 %, entirely downsampling. Python 800 px INTER_AREA gives 0.134 %, so ImageIO's thumbnail filter also differs from INTER_AREA (B81258B7 0.919 vs 0.554 %). Device RGB and sRGB contexts gave identical counts on this Mac.
- **Fix:** Draw the mask in the thumbnail's own colour space (source.colorSpace) to match native_clip_stats. Also either caption the mask with its own highCount/(w*h), or state that the red area is an 800 px preview and the % is the analyzer's full-resolution figure.
- **Files:** mac/IQCoach/Sources/Support/ClippingMask.swift, mac/IQCoach/Sources/Views/OverlayImage.swift
- **Area:** app

## CLIP-4 [medium] definition-mismatch

- **A:** The app calls highlight clipping pure white: Metric.swift:58 "Share of the picture that is pure white with no detail", CameraReportView.swift:48 "Median share of pixels at pure white", CameraRules.swift:240 "blown to pure white", EditingRules.swift:27 "is blown to pure white".
- **B:** The measure is any channel >= 254: iqa/imageio.py:239-242, iqa/exposure.py:11, ClippingMask.swift:22, Metric.swift:77.
- **Evidence:** On the seven iPhone originals on disk, the share with all three channels >= 254 is 0.000-0.023 %. The any-channel share is up to 1.308 % (EC07D805: 1.117 % any vs 0.001 % all three; B81258B7: 0.888 % vs 0.000 %). In ImageIO thumbnails, all-three >= 254 was 0.000 % on every iPhone 17 Pro Max file. The pixels counted are almost never pure white; they are one saturated channel.
- **Fix:** Reword the four strings to "at the top of the range in at least one channel" (or "blown in at least one colour channel"). Or report a separate all-channel share if pure white is the intended meaning.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Views/CameraReportView.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift
- **Area:** app

## CLIP-5 [medium] spec-vs-app / internal contradiction

- **A:** docs/APP-IQ-COACH-SPEC.md:142 specifies the report-card tile as "highlight clipping (% of photos)".
- **B:** mac/IQCoach/Sources/Views/CameraReportView.swift:47-48 and CameraGroup.swift:61 show clipHighMedian, the median % of pixels, banded with the pixel bands in Metric.swift:151 (0.1/0.5/2). The chart (Charts.swift:95-120) and the insight (CameraRules.swift:232-244) use the share of photos over 1 %.
- **Evidence:** iPhone 17 Pro Max from results.csv: median clip_high_pct = 0.475 %, shown as 0.47 % with a green "Good" band (under 0.5). Photos over 1 % = 54 of 206 = 26.2 %. The chart bar reads 26 %, orange past the 15 % line ("exposure routinely loses highlight ... detail"). The insight reads "Highlights are often blown out ... 26 % (54 of 206)". All three agree with the CSV, but the tile shows Good while the chart and insight on the same screen warn. iPhone 13 has the same pattern (median 0.42 % Good; 23/85 = 27 %).
- **Fix:** Either make the tile the share of photos over 1 % with a 15 % threshold, as the spec says, or keep the pixel median and change the spec. In the second case, add to the tile detail that the band grades the typical photo while the 15 % rule grades how often photos clip.
- **Files:** mac/IQCoach/Sources/Views/CameraReportView.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## F04 [medium] stale-number

- **A:** results/FINDINGS.md:18 D850 whiteness '0.20–0.30'; :28 17 Pro Max 'whiteness sits at 0.45–0.49 at every ISO'; :19 table '0.44–0.49'; :32 '0.47 on the 17 Pro Max'; :116 'D850 at ISO 64 ... (0.30–0.47)'
- **B:** results.json noise_whiteness, median per ISO band on the same valid rows
- **Evidence:** D850 band medians (valid rows): 0.30, 0.47, 0.21, 0.20, 0.20, so the range is 0.20–0.47, not 0.20–0.30. The 65–160 band holds 10 frames with a median of 0.47. The valid ISO-64 D850 frames (0.17, 0.30, 0.54) have a median of 0.30, so the 0.47 quoted 'at ISO 64' is really the 65–160 band. 17 Pro Max band medians: 0.48, 0.49, 0.45, 0.46, 0.44, so the prose '0.45–0.49' contradicts its own table, and the base-ISO value is 0.48 under the report's exclusions (0.47 only without the periodic exclusion).
- **Fix:** Set the D850 whiteness cell to 0.20–0.47. Change the prose to 0.44–0.49 and the base ISO value to 0.48. Reword item 5 of section 5 to 'ISO 64-160 (0.30-0.47)'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F11 [medium] stale-count

- **A:** media/make_explainer.py:33 '73 tests, every metric validated...' and :204 'Seventy-three tests pass in about twelve seconds'
- **B:** pytest --collect-only at HEAD: 103; CLAUDE.md to-do 1 tells Allison to watch this video
- **Evidence:** The narration was pinned to the periodic-detector commit, but the video is presented as current prep material. The suite now has 103 tests. The same script's last slide (lines ~262-273) also lists chart mode and the bootstrap interval as 'next', and both are done.
- **Fix:** Update the test count and the 'what is next' slide in make_explainer.py, then rebuild the video. Otherwise label the video in CLAUDE.md as reflecting the 2026-10-13 state.
- **Files:** media/make_explainer.py, CLAUDE.md
- **Area:** results/docs

## F13 [medium] wrong-definition

- **A:** mac/IQCoach/Sources/Model/Metric.swift:73 'LW/PH is line widths per picture height: the c/px figure times the picture height in pixels.'
- **B:** deck glossary.html and sharpening.html, and media/make_explainer.py 'Definitions' slide: '2 x cycles per pixel x image height'; results.json data
- **Evidence:** For C6220E43, mtf50_p80_cpp 0.43988 x 2 x 5712 = 5025.2, which equals the stored mtf50_p80_lwph 5025.23. The app's glossary text omits the factor 2, so it understates LW/PH by half.
- **Fix:** Change the sentence to 'twice the c/px figure times the picture height in pixels (two line widths per cycle)'.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift
- **Area:** app

## F14 [medium] inconsistent-claim

- **A:** results/FINDINGS.md:89-91 'four screen photos ... one of which had sat in the noisiest-valid list at 20.8 dB'; :128 'the four screen photos no longer appear among the noisiest'
- **B:** media/make_explainer.py:108-118 'the two noisiest images in the whole library were photographs of a monitor ... one screen photo ... whiteness 0.12 ... 21 dB, ISO 125'; :163/:171 'screen photos: 11, 15 and 127'; deck periodic.html:12 'two screen photos had ranked as the noisiest'
- **Evidence:** Noisiest list rebuilt without the periodic exclusion (the pre-detector rule): #1 9AE754E4 20.8 dB ISO 64 whiteness 0.156; #2 6721B8DA 21.1 dB ISO 125 whiteness 0.125. Both are screen photos and both passed the 0.7 whiteness gate. So two, not one, were in the list. FINDINGS (20.8 dB) and the explainer (21 dB, ISO 125) name different photos as 'the one'. The other two screen photos (32.7 and 34.0 dB) were never in the list. There are four screen photos (peaks 11.3, 14.4, 15.0, 126.9), not the three values the explainer gives.
- **Fix:** FINDINGS: say 'two of which (20.8 dB, ISO 64; 21.1 dB, ISO 125) had been the two noisiest valid images'. Fix section 6 to say the two former entries left the list. Explainer: say 'two passed at whiteness 0.13-0.16' and list four peaks (11, 14, 15, 127).
- **Files:** results/FINDINGS.md, media/make_explainer.py
- **Area:** results/docs

## F15 [medium] wrong-number

- **A:** results/FINDINGS.md:156-157 (section 7) 'the walkthrough photo reads 6.9 degrees on the board's edge'
- **B:** results.json C6220E43 structure_horizon_tilt_deg = -7.9008
- **Evidence:** The stored level-edge tilt for the walkthrough photo is -7.90 degrees (|tilt| 7.9), not 6.9. The other section 7 counts match: 177 level edges, median 2.33, 129 at 1 degree or more, 49 and 93 thirds counts, median 0.628, 168 under 0.25, 7 over 0.8, 52 frames with five or more edges, 34 splits.
- **Fix:** Change to '7.9 degrees' (or 'about 8 degrees'), and say the sign is right end higher.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F16 [medium] wrong-number

- **A:** media/make_explainer.py:126 'Normalised peak: 15 for the screen, 2.3 for the Nikon' and narration 'two point three for the Nikon'; deck periodic-catch.html:3 'a Nikon water shot stays at 2.3'; media/figures.py:66 caption 'Nikon D850 JPEG, ISO 100'
- **B:** media/figures.py:24 D850 = _resolve('014D71F2'); results.json row 014D71F2: noise_spectral_peak 1.706, iso 720, noise_candidate_patches 50,895 (the '50,895 patches' in the explainer)
- **Evidence:** The figure's D850 frame is 014D71F2. Its stored spectral peak is 1.71, not 2.3, and its ISO is 720, not 100. The screen frame 6721B8DA matches: stored peak 15.01, 6,597 candidates, freq 0.25 c/px.
- **Fix:** Change the Nikon peak to 1.7 in the slide title and narration, and fix the caption in figures.py to ISO 720. Or regenerate the figure and quote the stored value.
- **Files:** media/make_explainer.py, media/figures.py, deck slide periodic-catch.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** deck/video/other

## F17 [medium] wrong-count

- **A:** results/FINDINGS.md:3-5 '389 images from 19 devices (iPhone 17 Pro Max 206, iPhone 13 85, Nikon D850 36, iPhone XR 21, 8 older iPhones, SeaLife DC2000 5, two Canon PowerShots)'
- **B:** results.json camera_model counts
- **Evidence:** Besides the 17 Pro Max, 13 and XR there are 12 other iPhone models, not 8: 6 Plus 8, 12 mini 8, 6 6, 13 mini 2, 17 Pro 2, SE 2, 14 1, 12 1, 4S 1, 4 1, XS 1, 15 Pro 1 (34 images). 4 + 12 + SeaLife + 2 Canons = 19 devices. With '8' the list adds up to 15. Two of the twelve (17 Pro, 15 Pro) are not 'older'.
- **Fix:** Change to '12 other iPhones (34 images)'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F18 [medium] wrong-count

- **A:** deck the-row.html:3 'Sixty-seven columns per photo' and :17 'The CSV has 67 columns'
- **B:** results/results.csv header (HEAD 076ef98)
- **Evidence:** The results.csv header has 87 columns. The structure, focus-split and clip_gamut columns were added after the deck was written.
- **Fix:** Change to 'Eighty-seven columns' and 'The CSV has 87 columns'.
- **Files:** deck slide the-row.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** deck/video/other

## F19 [medium] overclaim

- **A:** docs/RESUME-NOTE.md:31-32 'bootstrap uncertainty on every per-image figure'; :12 'the commit history shows the work was done in two days'; :36 'two full days (Oct 12-13, 2026)'
- **B:** results/results.csv columns; git log dates
- **Evidence:** Only mtf50_median and mtf50_p80 carry intervals (mtf50_*_ci_lo/hi_cpp, 4 columns). SNR, noise, DR, clipping and WB have none. The git history has 18 commits on 2026-10-13, 3 on 10-14, 7 on 10-15 and 1 on 10-23, and none on Oct 12. A reader checking the history will not find 'two days (Oct 12-13)'.
- **Fix:** Change to 'bootstrap uncertainty on every per-image sharpness figure' and 'built over three days (Oct 13-15, 2026)'.
- **Files:** docs/RESUME-NOTE.md
- **Area:** results/docs

## F20 [medium] regression

- **A:** results/report.md:1 '# x' (committed in 076ef98)
- **B:** previous committed report.md title and FINDINGS.md title 'Allison's Photos library, all 389 camera captures'; CLAUDE.md:60 re-render with --title "..."
- **Evidence:** git show HEAD -- results/report.md shows the title changed from 'Allison's Photos library, all 389 camera captures' to 'x' when the report was re-rendered for the clip_low fix. The body regenerates identically from results.json apart from the title and timestamp.
- **Fix:** Re-render with python -m iqa report results/results.json --title "Allison's Photos library, all 389 camera captures".
- **Files:** results/report.md
- **Area:** results/docs

## APP-09 [medium] threshold

- **A:** iqa/noise.py:18 ('0.14 = white; 0.4+ = heavily correlated / NR'd'); CameraRules.swift:112-136 (<0.2 fine grain, 0.2-0.4 moderate, >=0.4 'Strong noise smoothing'); EditingRules.swift:47 (>=0.4 'already smoothed')
- **B:** mac/IQCoach/Sources/Model/Metric.swift:103 ('0.5 and above is heavily smoothed') and docs/APP-IQ-COACH-SPEC.md:57 ('0.5+ heavily smoothed'); Metric.swift:85 and results/report.md:132 ('0.3+ means the noise has been smoothed')
- **Evidence:** Whiteness distribution in results.json: <0.2: 40, 0.2-0.3: 56, 0.3-0.4: 84, 0.4-0.5: 94, >=0.5: 115. The 94 photos in 0.4-0.5 are 'heavily NR'd' per noise.py and 'strong smoothing' per the app's rules, yet below the Glossary's 0.5 'heavily smoothed' line. The iPhone 17 Pro Max median, 0.47, gets the card 'Strong noise smoothing softens fine texture' while the Glossary says heavy smoothing starts at 0.5. Separately, 54 photos are above the Glossary scale's 0.6 end (Metric.swift:130).
- **Fix:** Use one set of whiteness cut-offs (e.g. 0.14 white, 0.3 smoothed, 0.4 heavy, 0.7 texture-suspect, matching noise.py) in Metric.goodLooksLike, the spec, report.py's how-to-read and the coaching rules.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift, docs/APP-IQ-COACH-SPEC.md, iqa/report.py, iqa/noise.py
- **Area:** app

## APP-10 [medium] interpretation

- **A:** results/FINDINGS.md:24-26 (D850 noise 'close to white (whiteness 0.20 above ISO 160) ... What the tool measures there is sensor noise') and :114-116 (whiteness rises to 0.30-0.47 at low noise 'even with no NR')
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:120-127 (median whiteness 0.2-0.4 gives 'Moderate noise smoothing ... moderate smoothing by the camera')
- **Evidence:** NIKON D850 median noise_whiteness over all 36 rows is 0.243, so the D850 coaching card says 'moderate smoothing by the camera'. By ISO the medians are >160: 0.20 (n20), 65-160: 0.47 (n12), <=64: 0.42 (n4). The high values are the low-noise texture confound FINDINGS §5.5 describes, not NR. The analyzer calls 0.14 white, while the app's 'fine grain' cut-off is 0.2.
- **Fix:** Compute the character rule on clean rows above base ISO (or where SNR < ~38 dB) so the texture confound does not count as smoothing. Also say 'moderate smoothing or residual texture' and cite the 0.14 white-noise reference.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## APP-11 [medium] threshold

- **A:** mac/IQCoach/Sources/Coaching/EditingRules.swift:79,82 (overshoot >= 12 % gives 'a visible sharpening halo')
- **B:** Metric.swift:101,152 ('poor from 15 %'; 8-15 is 'Fair') and CameraReportView.swift:50 ('Under 3 % is natural; over 15 % is a visible halo'); CameraRules.swift:265 (>8 % 'This camera sharpens hard')
- **Evidence:** 15 photos have overshoot_median_pct in [12,15) (8 of them with >= 3 edges). On their detail page the Sharpening halo row reads 'Fair', the report-card text says a halo is visible only over 15 %, yet the advice card says 'a visible sharpening halo'. Control check: on synthetic unsharpened edges with noise up to 5 % of the step, the analyzer's overshoot is median 0.55 %, p90 1.46 %; USM amount 1.0 gives 2.0 % and amount 2.0 gives 6.6 %. So the 3 % 'natural' line is sound, but the visible-halo line is stated as both 12 and 15.
- **Fix:** Use one 'visible halo' threshold (15, matching the band, or move the band's poor edge to 12) in EditingRules.halo, Metric bands/goodLooksLike, the report-card detail and the spec.
- **Files:** mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Views/CameraReportView.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## APP-12 [medium] definition

- **A:** iqa/edges.py:225-226 (lw_per_ph = 2 x MTF50 (c/px) x height)
- **B:** mac/IQCoach/Sources/Model/Metric.swift:73 ('LW/PH is line widths per picture height: the c/px figure times the picture height in pixels')
- **Evidence:** mtf50_p80_lwph / (mtf50_p80_cpp x height) = 2.000 on all 149 rows of results.json. Following the Glossary, a reader would compute half the number the app shows (e.g. 0.267 c/px x 4032 = 1077, but the app shows 2153 LW/PH).
- **Fix:** Change the Glossary sentence to 'two times the c/px figure times the picture height in pixels (one cycle is two line widths)'.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift
- **Area:** app

## APP-13 [medium] derived-metric

- **A:** mac/IQCoach/Sources/Model/PhotoRecord.swift:193-197 (per-photo 'Colour lean' = max(|wb_r_over_g_stops|, |wb_b_over_g_stops|)); analyzer writes only the two separate columns (iqa/exposure.py:21-22,62-63)
- **B:** mac/IQCoach/Sources/Model/CameraGroup.swift:40-43,67-68 and CameraReportView.swift:41,51 (camera 'Colour lean' tile = max of the per-channel medians, under the subtitle 'Medians over all N photos'); LibraryOverviewView.swift:67,77; MarkdownExport.swift:15
- **Evidence:** The camera tile does not agree with the median of the per-photo values the app shows in each photo. iPhone 17 Pro Max: tile 0.17 stops 'Good' vs median per-photo lean 0.30 'Fair' (67 % of photos >= 0.2). iPhone 13: tile 0.04 'Excellent' vs 0.30 'Fair' (72 % >= 0.2). NIKON D850: 0.05 'Excellent' vs 0.21 'Fair'. iPhone XR: 0.37 'Fair' vs 0.44 'Poor'. The Glossary definition (Metric.swift:83, copied from report.md:135) describes the channel ratios and never says the number is the larger of the two. The colour-lean advice fires on 311 of 389 photos (lean > 0.15).
- **Fix:** Either compute the camera lean as the median of per-photo wbLeanStops, or relabel the tile 'Cast of the median R/G and B/G' and stop banding it against the per-photo scale. State in the Glossary that 'lean' is max(|R/G|, |B/G|) in stops.
- **Files:** mac/IQCoach/Sources/Model/CameraGroup.swift, mac/IQCoach/Sources/Views/CameraReportView.swift, mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Views/LibraryOverviewView.swift
- **Area:** app

## APP-14 [medium] definition

- **A:** iqa/exposure.py:11,35 and iqa/imageio.py:239-243 (clip_high_pct = % of pixels with ANY channel >= 254); Metric.swift:77 (the app's own Glossary repeats 'any channel at 254 or above')
- **B:** mac/IQCoach/Sources/Model/Metric.swift:58 ('pure white with no detail'); EditingRules.swift:27 ('of the picture is blown to pure white'); CameraRules.swift:240 ('blown to pure white')
- **Evidence:** On Photos' 1024-px derivatives of the most-clipped frames, the any-channel share reproduces the stored figure while the all-channels-at-254 ('pure white') share is far smaller: 61B631F3...jpeg stored 13.92 %, derivative any 14.11 % vs all 2.38 %; 70B6E13D...jpeg 7.59 % stored, 7.35 % any vs 0.00 % all; A25A41B7...heic 7.10 %, 7.30 % vs 0.00 %; 9BD2881A...jpeg 10.97 %, 11.69 % vs 2.41 %. The app therefore tells the user that up to 14 % of the picture is 'pure white' when about 2 % is.
- **Fix:** Reword to 'has at least one colour channel at full scale (lost detail in that channel)'. Alternatively, add an all-channels column in exposure.py/imageio.py and use it for 'pure white'.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift
- **Area:** app

## APP-15 [medium] label

- **A:** results/report.md:130 ('the p80 figure should then be read as the in-focus value'); CameraRules.swift:409 ('The p80 figure is the subject'); Metric.swift:39 (p80 labelled 'In-focus sharpness')
- **B:** iqa/structure.py:163-184 / results.json mtf50_infocus_cpp (the sharp group's mean, shown by Structure.splitText as 'sharp group ...'); report.md:129 (p80 'assumes at least a fifth of the measured edges are in the plane of focus')
- **Evidence:** On 4 of the 34 split frames, p80 sits well below the in-focus group even though the sharp share is 0.25-0.33: 7F12DAF1...jpeg p80 0.172 vs in-focus 0.293 (ratio 0.59, share 0.25, 8 edges); F2A3BD81 0.189 vs 0.271 (0.70); F545A532 0.193 vs 0.249 (0.78); 4B77D821 0.212 vs 0.256 (0.83). For 7F12DAF1 the same detail page shows 'Sharpness is low (0.17 c/px, under 0.18)' and 'Shallow depth of field: the sharp group measures 0.29 c/px' side by side.
- **Fix:** When hasFocusSplit is true, use mtf50InfocusCPP for the 'In-focus sharpness' row and suppress EditingRules.soft. Alternatively, rename the p80 metric '80th-percentile edge sharpness'. Also correct report.py's 'read as the in-focus value' sentence and the 'a fifth' assumption (linear interpolation needs more than 20 % + 1/n).
- **Files:** mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, iqa/report.py
- **Area:** app

## APP-16 [medium] label

- **A:** results/FINDINGS.md:154-158 ('Most of those are not horizons ... The column is therefore named "level-edge tilt" in the report and the app')
- **B:** mac/IQCoach/Sources/Views/ContentSections.swift:206,208 (row and info title 'Horizon tilt'); PhotoDetailView.swift:133 (advice title 'Horizon'); CameraRules.swift:387-393 (title 'Your horizons lean {side} by x°', 'the median horizon is tilted', evidence 'Median horizon tilt')
- **Evidence:** The app labels structure_horizon_tilt_deg as a horizon throughout. The horizon-lean card fires for iPhone 13 (26 photos, median −2.09°: 'Your horizons lean left by 2.1°') and for iPhone 12 mini (7 photos, +1.30°). Per FINDINGS §7, most of the 177 level edges are table edges, shelves and frames.
- **Fix:** Rename these to 'Level-edge tilt' and 'Your level edges lean ...', as docs/FEEDBACK-LAYERS-SPEC.md:689 already plans. If the app wording stays, correct FINDINGS §7.
- **Files:** mac/IQCoach/Sources/Views/ContentSections.swift, mac/IQCoach/Sources/Views/PhotoDetailView.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, results/FINDINGS.md
- **Area:** app

## APP-17 [medium] stale-number

- **A:** results/FINDINGS.md:19,22,127-129 (iPhone 17 Pro Max n=172; ISO<=64 33.3 dB (47); 65-160 32.0 (73); footnote excludes only extrapolated/texture rows; 'tables above ... are unchanged by it')
- **B:** Current results.json with the app's snrIsClean filter (PhotoRecord.swift:183-185, also iqa/report.py:96-98), as shown in the app's ISO-ceiling evidence (CameraRules.swift:67); results/report.md:84 (SNR n=167)
- **Evidence:** Recomputed: iPhone 17 Pro Max clean rows n=167. Bands: <=64 33.59 dB (44), 65-160 32.01 (71), 161-400 36.74 (28), 401-1000 36.77 (16), >1000 30.83 (8). After the periodic exclusion the first two bands lost 3 and 2 rows and the <=64 median moved 33.3 -> 33.6, so the claim that the tables are unchanged is false. iPhone 13 and D850 rows match exactly. The ISOBand comment (Stats.swift:17, 'The same ISO bands as FINDINGS.md') holds for the edges, not the values.
- **Fix:** Regenerate the §1 table from the current results (n=167; 33.6 (44); 32.0 (71)), add periodic rows to the footnote, and correct the sentence at line 127-129.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## APP-18 [medium] count

- **A:** results/FINDINGS.md:59 ('Nikon D850: 36 frames, only 4 with any valid edge and none with three')
- **B:** results/results.json and results/report.md:86 ('NIKON D850 | 36 | 0.391 (1)'); docs/FEEDBACK-LAYERS-SPEC.md:190 ('1 of 36 photos had 3 or more usable edges (it measured 2,377 LW/PH)')
- **Evidence:** D850 rows with a finite p80: 06FC357F...jpeg 4 edges (0.391 c/px, 2377 LW/PH), 3266EF90 1, 446158BA 1, A25416B2 1. So one D850 frame does have three or more edges, and the report prints it.
- **Fix:** Change FINDINGS §2 to 'only 4 with any valid edge and one with three or more (0.391 c/px, 2377 LW/PH)'. Keep the 'no camera figure' conclusion only if a minimum frame count is stated.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## APP-19 [medium] threshold

- **A:** iqa/noise.py:38-40,73 (PERIODIC_PEAK_THRESHOLD = 6.0) and results/FINDINGS.md:88 ('Threshold 6 is the geometric midpoint')
- **B:** iqa/report.py:331 -> results/report.md:132 ('about 1 for noise, above 8 (`noise_periodic_suspect`) the flat patches contain a repeating pattern')
- **Evidence:** The code flags above 6. In results.json the flagged peaks are 8.3, 8.4, 11.3, 14.4, 15.0 and 126.9, and the largest unflagged peak is 5.53, so no current row falls between 6 and 8. The report's how-to-read text still states the wrong threshold.
- **Fix:** Change 'above 8' to 'above 6' in iqa/report.py (or interpolate PERIODIC_PEAK_THRESHOLD) and regenerate report.md.
- **Files:** iqa/report.py, results/report.md
- **Area:** analyzer

## F4 [medium] stale-table

- **A:** results/FINDINGS.md:19, section 1 table: 'iPhone 17 Pro Max (n=172) | 33.3 (47) | 32.0 (73) | ...' (footnote: excludes extrapolated or texture-suspect rows only)
- **B:** results/report.md 'By camera': 'iPhone 17 Pro Max ... SNR mid-grey dB median 34.5 (167)'. report.py _noise_ok also excludes noise_periodic_suspect, and FINDINGS section 6 says the 6 periodic frames 'leave the SNR medians'
- **Evidence:** 5 of the 6 periodic-flagged frames are iPhone 17 Pro Max: 596A3A82, 6721B8DA, 7CF48ECB, 9AE754E4, A48003D9. With the report's gate the 17 Pro Max row is n=167, ISO<=64 33.6 (44), 65-160 32.0 (71). Without the periodic gate it is the published 172 / 33.3 (47) / 32.0 (73). The D850 and iPhone 13 rows are unaffected.
- **Fix:** Recompute the section 1 table with the same validity gate as report.py (add noise_periodic_suspect to the footnote): 17 Pro Max n=167, 33.6 (44), 32.0 (71), 36.7 (28), 36.8 (16), 30.8 (8).
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F5 [medium] range

- **A:** results/FINDINGS.md:18, section 1 table, D850 'noise whiteness' column: '0.20–0.30'
- **B:** results/FINDINGS.md:112-113 (section 5 item 5): D850 at low ISO 'whiteness rises (0.30–0.47)'. results.json: D850 valid-row whiteness medians per ISO bin are 0.30, 0.47, 0.21, 0.20, 0.20
- **Evidence:** Recomputed the median noise_whiteness per ISO bin over D850 rows passing _noise_ok. The 65–160 bin (n=10) is 0.47, outside the table's 0.20–0.30 range. The two parts of FINDINGS disagree on the same quantity.
- **Fix:** Change the D850 whiteness cell to '0.20–0.47', or footnote that the column covers ISO > 160 only.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F6 [medium] count

- **A:** results/FINDINGS.md:107-108: 'About 7 valid ROIs per image where any exist'; media/make_explainer.py:232 narration: 'natural scenes give about seven valid edges per image where any exist'
- **B:** results.csv edges_measured: 736 valid ROIs over the 149 images with any, mean 4.94, median 2. Over the 73 images with >=3 edges the mean is 8.75 and the median 6
- **Evidence:** Summed edges_measured from results.json, and the CSVs of all earlier commits give the same 4.94. No reading of 'where any exist' gives 7: per image with any edge it is 4.9 (median 2).
- **Fix:** Change to 'about 5 valid ROIs per image where any exist (median 2)' in FINDINGS, and in the narration and slide text, then rebuild the explainer.
- **Files:** results/FINDINGS.md, media/make_explainer.py
- **Area:** results/docs

## F7 [medium] chart-title

- **A:** iqa/report.py:236 chart title on results/charts/noise_curves.png: 'noise vs. signal level, one line per image' (report.md lists it among the library charts)
- **B:** iqa/report.py:232 plots `for name, nz in curves[:60]`, but 389 images have a noise curve with >=3 bins
- **Evidence:** Counted noise_curve entries with >=3 bins in results.json: 389. The chart draws only the first 60 in file order, chosen by filename, and the title gives no n. Opening the PNG shows about 60 lines. Those 60 also include texture- and periodic-suspect frames that every other noise chart excludes.
- **Fix:** Title it f'noise vs. signal level, {k} of {len(records)} images (one line each)', or plot all valid_records(records,'snr_midgrey_db') curves.
- **Files:** iqa/report.py, results/charts/noise_curves.png
- **Area:** analyzer

## F8 [medium] definition

- **A:** iqa/report.py:224 lwph_by_camera chart title: 'LW/PH is comparable across sensor sizes; cycles/px is not'; results/FINDINGS.md:47-49: 'the 24 MP 17 Pro Max resolves 7 % more (2608 vs 2429)'
- **B:** iqa/analyze.py:24 computes mtf50_p80_lwph with img.height after EXIF transpose, so picture height is the long side for portrait frames and the short side for landscape ones
- **Evidence:** Verified that mtf50_p80_lwph = 2*mtf50_p80_cpp*height on all 149 rows; 108 are portrait and 41 landscape. Within one camera the figure depends on orientation. iPhone 13: portrait median 2501 (n=15), landscape 1556 (n=5). iPhone 17 Pro Max: 2615 (n=36) vs 2121 (n=7). Normalising to the short side gives 1966 vs 1861, a 5.6 % gap, not 7 %. Normalising to the long side gives 2621 vs 2481.
- **Fix:** Compute LW/PH on a fixed dimension, such as min(width, height), or report per orientation. Update the chart title or caption and the FINDINGS section 2 LW/PH column to say which dimension is used.
- **Files:** iqa/analyze.py, iqa/report.py, results/FINDINGS.md, results/results.csv
- **Area:** analyzer

## F9 [medium] range

- **A:** iqa/structure.py:11-13 docstring and mac/IQCoach/Sources/Model/Structure.swift:11 (user-facing definition): thirds distance is '0 on the point, 1 at the frame centre, about 2 in a corner'; report.md says structure_focus_cx/cy is '0-1'
- **B:** structure.py computes the centroid from cell centres of a 4x6 grid, so cx is in [1/12, 11/12] and cy in [1/8, 7/8], and the largest possible thirds distance is 1.381
- **Evidence:** Recomputed focus fraction, centroid and thirds distance from structure_focus_map for all 389 rows: all match exactly. Observed ranges: cx 0.0833–0.9167, cy 0.125–0.875, thirds distance 0.096–1.3807. The analytic maximum, with all weight in a corner cell, is 1.3807. No frame can score 'about 2'.
- **Fix:** Change 'about 2 in a corner' to 'at most about 1.4 (detail in a corner cell)' in structure.py and Structure.swift, and give the cx/cy range as cell-centre bounds in report.py's how-to-read.
- **Files:** iqa/structure.py, mac/IQCoach/Sources/Model/Structure.swift, iqa/report.py
- **Area:** app

## F10 [medium] count

- **A:** results/FINDINGS.md:3-5: '389 images from 19 devices (iPhone 17 Pro Max 206, iPhone 13 85, Nikon D850 36, iPhone XR 21, 8 older iPhones, SeaLife DC2000 5, two Canon PowerShots)'
- **B:** results.csv camera_model: besides 17 Pro Max, 13 and XR there are 12 other iPhone models with 34 frames (6 Plus 8, 12 mini 8, 6 6, 13 mini 2, 17 Pro 2, SE 2, 14, 12, 4S, 4, XS, 15 Pro 1 each)
- **Evidence:** Counter over camera_model: 19 distinct values. 4 + 12 + SeaLife + 2 Canons = 19, so the total is right, but '8 older iPhones' fits neither the model count (12) nor the frame count (34), and the list includes the iPhone 17 Pro, 15 Pro and 14.
- **Fix:** Change to '12 other iPhone models (34 frames)'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F5 [medium] test-count

- **A:** Deck 'cover' ('95 tests') and 'tests' ('95 tests run in about 16 seconds'). Narration slide 1 ('73 tests'), slide 11 title ('73 in total') and narration ('Seventy-three tests pass in about twelve seconds').
- **B:** `python -m pytest --collect-only -q` reports 103 tests collected. CLAUDE.md says 102.
- **Evidence:** Ran the collection with the repo venv: '103 tests collected in 24.70s'.
- **Fix:** Change the deck to 103 tests and its run time to the measured value. In the narration, either mark 73 as the count at that commit or change it to the current count. Change CLAUDE.md 102 to 103.
- **Files:** deck project/slides/cover.html, deck project/slides/tests.html, media/make_explainer.py, CLAUDE.md
- **Area:** results/docs

## F6 [medium] test-description

- **A:** Deck 'tests' row 'Chart sharpness': 'a drawn 5 x 5 chart with blur growing to the corners → 25 squares, 100 edges, each within 6 % of its blur'
- **B:** tests/test_esfr_chart.py: the 6 % per-edge check (line 31) and the edge count (line 23, n_edges >= 76) run on a uniform 5x4 chart, which has 20 squares. The 5x5 graded chart (lines 38-48) checks each square's mean within 8 %. Deck slide 'chart-sfr' itself says 'within 8 %'.
- **Evidence:** Read the three test functions: 20 squares and >= 76 edges at 6 %, then 25 squares at 8 % per square on the graded chart.
- **Fix:** Change the row to: uniform 5x4 chart, 20 squares, >= 76 edges, each within 6 %; graded 5x5 chart, each square within 8 % and centre > 1.3x corners.
- **Files:** deck project/slides/tests.html
- **Area:** deck/video/other

## F7 [medium] column-count

- **A:** Deck 'the-row' heading 'Sixty-seven columns per photo' and notes 'The CSV has 67 columns'
- **B:** results/results.csv header has 87 columns. The structure and clip_gamut columns were added in the fourth and fifth runs.
- **Evidence:** `head -1 results/results.csv | tr ',' '\n' | wc -l` gives 87.
- **Fix:** Change 67 to 87 on the slide and in its notes.
- **Files:** deck project/slides/the-row.html
- **Area:** deck/video/other

## F8 [medium] edge-count

- **A:** Deck 'edges' notes ('a typical photo gives about 7') and 'caveats' ('About 7 valid edges where any exist'). Narration slide 13 ('about seven valid edges per image where any exist'). FINDINGS.md:107-108.
- **B:** results/results.json: 736 edges measured over 149 images with any edge, a mean of 4.94 and a median of 2. Over the 73 images with 3 or more edges the mean is 8.75 and the median 6.
- **Evidence:** Computed from edges_measured in results.json.
- **Fix:** Change to 'about 5 on average, median 2, where any exist', or recompute the figure and state what it is the mean of. Apply the same change in FINDINGS.md section 5 item 3.
- **Files:** deck project/slides/edges.html, deck project/slides/caveats.html, media/make_explainer.py, results/FINDINGS.md
- **Area:** results/docs

## F9 [medium] definition

- **A:** Deck 'glossary' ('Noise whiteness: 0.14 sand-like noise; 0.4+ smoothed by noise reduction') and 'noise' ('0.4 and up'). Narration slide 5. iqa/noise.py:18 docstring ('0.4+ = heavily correlated / NR'd').
- **B:** results/report.md:132 (from iqa/report.py:331): 'noise_whiteness near 0.14 means white noise; 0.3+ means the noise has been smoothed by NR or compression'
- **Evidence:** The glossary footer points to report.md for 'full definitions', but report.md uses 0.3 and the glossary uses 0.4. The walkthrough photo (0.34) is 'smoothed' by report.md and below the deck's smoothing level.
- **Fix:** Choose one cut-off. Either make report.py say 0.4+ to match the noise.py docstring, or make the glossary and noise slides say 0.3+.
- **Files:** iqa/report.py, results/report.md, deck project/slides/glossary.html, deck project/slides/noise.html
- **Area:** analyzer

## F10 [medium] claim-about-source

- **A:** Deck 'caveats': six limits. The notes say 'These are the same limits the findings file lists', and the footer cites 'results/FINDINGS.md, section 5'.
- **B:** results/FINDINGS.md:80-117, section 5, lists: 1 screen photos, 2 single-edge sharpness, 3 few valid steps, 4 HEIC vs JPEG, 5 whiteness confounded at low noise, 6 DR lower bounds.
- **Evidence:** Three of the deck's six are not in section 5: natural edges are lower bounds (that is in report.md), noise compares pipelines (FINDINGS section 1), and chart mode is unproven on a print. Section 5 items 1, 2 and 5 are missing from the slide.
- **Fix:** Either cite the right sources (report.md 'How to read', FINDINGS sections 1 and 5, CLAUDE.md) and drop 'the same limits', or rewrite the slide to list FINDINGS section 5's six items.
- **Files:** deck project/slides/caveats.html
- **Area:** deck/video/other

## F11 [medium] stale-status

- **A:** Narration slide 16 ('What is next') lists as future work: strip paths / --no-paths, chart mode, bootstrap CI on MTF50, and the two-cluster split. Slide 13 says 'chart mode is roadmap item 3 / the next roadmap item'.
- **B:** CLAUDE.md marks --no-paths, chart mode (synthetic), uncertainty (iqa/uncertainty.py) and the structure two-cluster split (iqa/structure.py, the mtf50_infocus_cpp column) as done. results.csv has no path column and carries mtf50_*_ci_* and mtf50_infocus_cpp.
- **Evidence:** The CSV header has no 'path' column and does contain mtf50_median_ci_lo_cpp and mtf50_infocus_cpp. The deck's own chart-color, chart-sfr and one-number slides present these features as done.
- **Fix:** Update narration slides 13 and 16 to the current state (the remaining items are a real chart shoot and matched RAW/HEIC pairs), then rebuild the video.
- **Files:** media/make_explainer.py
- **Area:** deck/video/other

## F12 [medium] walkthrough-figure

- **A:** results/FINDINGS.md:156: 'the walkthrough photo reads 6.9 degrees on the board's edge'
- **B:** results/results.json row C6220E43 (the walkthrough photo): structure_horizon_tilt_deg = -7.90
- **Evidence:** Read the row. The magnitude differs by 1.0 degree.
- **Fix:** Change FINDINGS section 7 to 7.9 degrees, or re-check which run the 6.9 came from.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F8 [medium] coaching-rule

- **A:** results/FINDINGS.md:154-158: most near-level edges 'are not horizons: table edges, shelves and the whiteboard frame seen in perspective... The column is therefore named "level-edge tilt" in the report and the app, and straightening advice is offered, not asserted.' Also mac/IQCoach/Sources/Model/Structure.swift:13 (the definition says the same). Data: the iPhone 13's 26 tilts are 16 negative and 10 positive; at |tilt| >= 1° it is 15 left vs 7 right (sign test, two-sided p ≈ 0.13).
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:378-395 (horizonLean) as rendered on the iPhone 13 page: 'Your horizons lean left by 2.1°', 'the median horizon is tilted 2.1°', 'A consistent lean points to a habit in how the camera is held or mounted'. Examples: −7.7°, −7.5°, −7.0°, +6.2°.
- **Evidence:** Recomputed: n=26, median −2.09°, matching the card. The card calls every level edge a horizon and asserts a habit, which is the framing FINDINGS says was removed. 38 % of the frames lean the other way, and the fourth example (60842562, +6.2°) is a counter-example. The examples are chosen by |tilt| regardless of sign, and the extreme values (7-8°) sit near the 10° acceptance limit that table edges in perspective reach. The photos could not be checked by eye: 0 of the 389 result paths exist on disk now.
- **Fix:** Rename the card to 'level edges', state the left/right counts, and only claim a habit when the sign split is significant. Choose examples on the same side as the median.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift
- **Area:** app

## F9 [medium] evidence-count

- **A:** The counts the findings actually rest on, recomputed from results.json. 17 Pro Max ISO card: 167 clean rows across 5 bands (the cited band has 16). Lens card: 84 rows over the 3 compared lenses. Slow-shutter card: 85 rows (3 slow + 82 fast). iPhone 13 ISO card: 79 clean rows (the cited band has 5). D850 ISO card: 33 clean rows (the cited band has 4). docs/APP-IQ-COACH-SPEC.md:66 says 'each rule states its evidence count'.
- **B:** mac/IQCoach/Sources/Coaching/Insight.swift:48-49 (`basedOn` = the largest single evidence n), rendered as 'Based on 71 photos' (17 Pro Max ISO), 'Based on 52 photos' (lens), 'Based on 82 photos' (slow shutter), 'Based on 54 photos' (iPhone 13 ISO), 'Based on 11 photos' (D850 ISO).
- **Evidence:** Read in the snapshot PNGs. Each footer equals the largest band or group count, not the photos behind the finding. For the slow-shutter card the footer (82) is the comparison group, while the finding rests on 3 photos.
- **Fix:** Let each rule set an explicit basedOn: the sum over the groups it compares, or the count of the deciding group. Render 'Counted: n of N photos'.
- **Files:** mac/IQCoach/Sources/Coaching/Insight.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Views/InsightCard.swift, mac/IQCoach/Sources/Support/MarkdownExport.swift
- **Area:** app

## F10 [medium] definition

- **A:** Every sharpness number on the camera page is p80: the tile, the lens card and the slow-shutter card use mtf50_p80_lwph. The p80 interval in results.json (mtf50_p80_ci_lo/hi_cpp) has a median relative width of 0.357 for the 17 Pro Max (n=43) and 0.355 for the iPhone 13.
- **B:** mac/IQCoach/Sources/Model/PhotoRecord.swift:188-191 (relativeCIWidth uses mtf50_median_ci_lo/hi over mtf50_median_cpp) and CameraRules.swift:363-375. Rendered 17 Pro Max card: 'Read single-photo sharpness loosely. The median confidence interval on a photo's sharpness is 61 % of the value itself (over 43 photos).'
- **Evidence:** Recomputed: the median-MTF50 relative CI is 0.607, which matches the card, but the p80 relative CI is 0.357. That is below the rule's 0.5 trigger, so the card describes a different metric from the 'sharpness' it qualifies and would not fire for p80.
- **Fix:** Decode mtf50_p80_ci_lo/hi_cpp and base relativeCIWidth on p80, or drop the card as docs/FEEDBACK-LAYERS-SPEC.md:196 proposes.
- **Files:** mac/IQCoach/Sources/Model/PhotoRecord.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift
- **Area:** app

## F11 [medium] threshold

- **A:** Coaching and chart thresholds. 32 dB is 'clean' at CameraRules.swift:77,88,101 and Charts.swift:33,49. Overshoot above 8 % 'shows as a bright halo' at CameraRules.swift:265,270.
- **B:** On the same screen, CameraReportView.swift:46 says '35 dB and up is clean'; Metric.swift:75 says '35+ dB is clean'; Metric.swift:99 says 'Clean from 38 dB'; and the band thresholds at Metric.swift:150 are 25/32/38. For halo, CameraReportView.swift:50 says 'over 15 % is a visible halo' and Metric.swift:101,152 give fair as 8-15, poor from 15.
- **Evidence:** Snapshot of the 17 Pro Max page. The SNR tile reads '34.5 dB · Good' with the caption '35 dB and up is clean' (implying not clean), while the ISO card says noise 'stays clean' and the chart marks 32 dB as clean. The halo tile tags 10.7 % (17 Pro Max), 12.5 % (iPhone 13) and 10.5 % (D850) as 'Fair' under 'over 15 % is a visible halo', while the coaching card on the same page says each 'shows as a bright halo'.
- **Fix:** Choose one clean-SNR mark and one visible-halo mark, and use them in the tile captions, Metric.definition/goodLooksLike, the band thresholds, the chart and the rules.
- **Files:** mac/IQCoach/Sources/Views/CameraReportView.swift, mac/IQCoach/Sources/Model/Metric.swift, mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Views/Charts.swift
- **Area:** app

## F12 [medium] coaching-rule

- **A:** results/FINDINGS.md:114-116: whiteness is 'confounded at low noise... whiteness rises (0.30–0.47) even with no NR'. Data: iPhone 17 Pro Max median whiteness by ISO band is 0.486 (<=64), 0.495 (65-160), 0.437 (161-400), 0.457 (401-1000), 0.457 (>1000). It is highest at base ISO, and 147 of the 206 frames are ISO <= 160. Metric.swift:103 says '0.5 and above is heavily smoothed'.
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:128-135 as rendered: 'Strong noise smoothing softens fine texture. Noise whiteness is 0.47: strong smoothing. Fine texture (hair, foliage, fabric) softens at higher ISO even though the noise number looks good', with the action 'Keep ISO low for texture subjects.'
- **Evidence:** Recomputed: median whiteness 0.4725 over 206 photos, matching the card. Whiteness does not rise with ISO on this camera, so the data does not support 'softens at higher ISO' or 'keep ISO low'. The median sits in the range FINDINGS says occurs without noise reduction, and is below the app's own 0.5 'heavily smoothed' mark.
- **Fix:** Compute whiteness only above ISO 160 (0.440 over 59 photos), drop the 'keep ISO low' action, and align the 0.4 rule threshold with the 0.5 glossary mark (or the reverse).
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift, mac/IQCoach/Sources/Model/Metric.swift
- **Area:** app

## F13 [medium] example-selection

- **A:** Analyzer validity flags in results.json. iPhone 13 19417229 (ISO 12500, 31.3 dB) has snr_midgrey_extrapolated=true and is excluded from the band medians. The 17 Pro Max overshoot outliers 86C74E78 (206.5 %, front camera, 2 edges), A2DD282F (88.0 %, front, 1 edge) and 14EA1C94 (43.2 %, 1 edge) fail report.py:116 (overshoot needs >= 3 edges).
- **B:** mac/IQCoach/Sources/Coaching/CameraRules.swift:92-93 (ISO examples drawn from `above` with no snrIsClean filter) and :266 (sharpening examples via extremes over all rows). Rendered: the iPhone 13 ISO examples '22.8, 27.1, 31.3, 31.3 dB' (the fourth is the extrapolated row); the 17 Pro Max 'sharpens hard' examples '206.5 %, 88.0 %, 45.1 %, 43.2 %'.
- **Evidence:** Sorted the rows the same way the Swift code does. The extrapolated D4804990/19417229 pair (31.326 vs 31.329 dB) both appear. Three of the four halo examples are 1-2-edge frames, two of them front-camera selfies, so the 'extreme' evidence comes from rows the medians are meant to exclude.
- **Fix:** Filter example candidates with the same validity predicate as the statistic (snrIsClean for noise, three-edge gate for sharpness and overshoot), and prefer representative examples over extremes, as docs/FEEDBACK-LAYERS-SPEC.md:204 proposes.
- **Files:** mac/IQCoach/Sources/Coaching/CameraRules.swift
- **Area:** app

## F14 [medium] count

- **A:** results/FINDINGS.md:59-61: 'Nikon D850: 36 frames, only 4 with any valid edge and none with three... No D850 sharpness figure, by design.'
- **B:** results/results.json: D850 06FC357F has edges_measured=4 (p80 2377 LW/PH); results/report.md:86 shows 'NIKON D850 | 36 | 0.391 (1)'. The app renders a D850 sharpness tile (2,624 LW/PH, n=4) and the card 'This camera sharpens hard: edges overshoot by 10.5 % (median over 4 photos)', from CameraRules.swift:263-275, which has no minimum count.
- **Evidence:** D850 edge counts: 06FC357F 4, 3266EF90 1, 446158BA 1, A25416B2 1. So one frame does have three or more edges, contradicting FINDINGS. The app's sharpening card fires on 4 photos, 3 of them single-edge. Gated, it is one photo (9.9 %).
- **Fix:** Correct FINDINGS §2 to '4 with any valid edge, 1 with three or more'. Give sharpeningCharacter a minimum gated count (for example 5) so the D850 card does not appear.
- **Files:** results/FINDINGS.md, mac/IQCoach/Sources/Coaching/CameraRules.swift
- **Area:** app

## F15 [medium] definition

- **A:** iqa/edges.py:225-227 ('Imatest-style line widths per picture height: 2 x MTF50 (c/px) x height') and media/make_explainer.py:257,264 ('2 x cycles per pixel x image height').
- **B:** mac/IQCoach/Sources/Model/Metric.swift:73 (the glossary shown in the app): 'LW/PH is line widths per picture height: the c/px figure times the picture height in pixels.'
- **Evidence:** In results.json, mtf50_p80_lwph / mtf50_p80_cpp = 2.0 x img.height on every row (for example 2 x 4032 = 8064 for 3024x4032 frames). The app's definition omits the factor 2, so a reader recomputing LW/PH from the shown c/px gets half the displayed value.
- **Fix:** Change the glossary to 'two times the c/px figure times the picture height in pixels'.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift
- **Area:** app

## app-camera-photos-includes-non-camera-image [medium] selection-definition

- **A:** mac/IQCoach/Sources/Support/PhotosImporter.swift:39 says 'Copies the `count` newest camera photos (screenshots skipped)'. mac/IQCoach/README.md:61-62 says '--analyze-photos N ... take the N newest camera photos'. The error text at PhotosImporter.swift:16 says 'No camera photos were found'. The filter itself (lines 46-49) only skips the .photoScreenshot subtype.
- **B:** iqa/select_captures.py:43-47 (used for the library run) keeps a file only if it has an EXIF camera model and at least 5 MP; FINDINGS.md:5-6 calls everything else 'screenshots, saved images and thumbnails'.
- **Evidence:** Runs 20261015T040506 and 20261015T041618 include 015-F96473AD-25B2-4529-8D62-C0805E39A1D7.jpg: 1320x2346 (3.1 MP), camera_make, camera_model, lens and ISO all None, color_profile 'assumed-sRGB', snr_midgrey_db 51.0. Photos.sqlite lists it with ZKINDSUBTYPE 0, a saved image rather than a screenshot. It is in photo_list.txt but not in captures.txt. In the app it becomes an 'Unknown camera' group (PhotoRecord.swift:170-173), so the app's '40 newest camera photos' are 39 captures plus one saved image.
- **Fix:** In exportNewest, skip assets whose original has no EXIF camera model or is under 5 MP, matching select_captures, and keep scanning until N captures are found. Alternatively, reword the README and docstring to 'the N newest non-screenshot photos'.
- **Files:** mac/IQCoach/Sources/Support/PhotosImporter.swift, mac/IQCoach/README.md
- **Area:** app

## findings-device-breakdown-sums-to-15 [medium] count

- **A:** results/FINDINGS.md:3-5 says '389 images from 19 devices (iPhone 17 Pro Max 206, iPhone 13 85, Nikon D850 36, iPhone XR 21, 8 older iPhones, SeaLife DC2000 5, two Canon PowerShots)'.
- **B:** results/results.json camera_model counts.
- **Evidence:** I count 19 distinct models. Besides the four named, there are 12 other iPhone models, not 8: 6 Plus 8, 12 mini 8, 6 6, 13 mini 2, 17 Pro 2, SE 2, 14 1, 12 1, 4S 1, 4 1, XS 1, 15 Pro 1, which is 34 frames. Two of them (17 Pro and 15 Pro) are not 'older'. As written, the breakdown adds up to 4 + 8 + 1 + 2 = 15 devices, not 19.
- **Fix:** Change the text to '12 other iPhones (34 frames, iPhone 4 to iPhone 17 Pro)', so the breakdown adds up to 19.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## NEW-2 [medium] definition-mismatch

- **A:** iqa/noise.py:274-281. When periodic patches are a minority of the selected set, they are dropped 'so the rest measures cleanly', and the row's SNR then comes from the non-pattern patches. results/FINDINGS.md:91-94 says the same: the striped-vehicle frames were 'excluded under the minority rule so the rest measures; the SNR of one screen photo moved 31.6 -> 32.7 dB the same way'. README.md:49 says the detector 'excludes the patches when they are a minority'.
- **B:** results/report.md:132 (from iqa/report.py:331): for noise_periodic_suspect rows 'the SNR is of the pattern, not the sensor'. mac/IQCoach/Sources/Views/PhotoDetailView.swift:39: 'the noise figure describes the pattern'. mac/IQCoach/Sources/Coaching/EditingRules.swift:145: 'the noise figure reflects the pattern rather than the sensor'. iqa/report.py:96-98 _noise_ok and PhotoRecord.snrIsClean also drop every periodic row from the SNR medians, including rows whose pattern patches were already removed.
- **Evidence:** From results.json, the six periodic-flagged rows have noise_periodic_fraction 0.188 (19AF39A4, SNR 32.7, the screen photo FINDINGS says moved 31.6 -> 32.7), 0.100 and 0.101 (596A3A82 and A48003D9, the striped vehicle FINDINGS says was excluded so the rest measures), 0.417 (6721B8DA), 0.439 (7CF48ECB) and 0.813 (9AE754E4). By noise.py's own logic and FINDINGS' own statement, at least three of these rows report an SNR with the pattern removed. Yet the report text and both app strings tell the reader that the figure is the pattern's.
- **Fix:** Make the wording depend on whether exclusion happened. Either export a flag (for example noise_periodic_excluded) from noise.py and word the report and app captions from it, or change report.py:331, PhotoDetailView.swift:39 and EditingRules.swift:145 to say the pattern was found and, when it covered a minority of patches, removed before measuring. Then decide whether _noise_ok and snrIsClean should keep rows whose pattern was excluded, and update the FINDINGS §6 sentence that says all 6 'leave the SNR medians'.
- **Files:** iqa/report.py, results/report.md, iqa/noise.py, mac/IQCoach/Sources/Views/PhotoDetailView.swift, mac/IQCoach/Sources/Coaching/EditingRules.swift, mac/IQCoach/Sources/Model/PhotoRecord.swift, results/FINDINGS.md
- **Area:** app

## NEW-3 [medium] test-claim-mismatch

- **A:** README.md:51 (validation column of the method table): 'a rendered 5x5 chart with a known Gaussian blur: all 25 squares and 100 edges found, every edge within 6 % of the analytic MTF50'
- **B:** tests/test_esfr_chart.py:15-23 and :26-31. The find-all and 6 %-per-edge tests render cols=5, rows=4, so the chart has 20 squares (assert len(squares) == 20, n_edges >= 76). The only 5x5 chart (:35-48) has a field-dependent blur and checks each square's mean within 8 %, not each edge within 6 %.
- **Evidence:** I read both test functions. render_esfr_chart(size=2000, cols=5, rows=4, ...) is used for the 6 % check, with the assertions n_squares == 20 and n_edges >= 76. The 25-square chart asserts n_squares == 25 and abs(s.mtf50_mean - want)/want < 0.08. No test asserts 25 squares with 100 edges each within 6 %. The earlier F6 named only the deck's 'tests' slide. README is a separate, portfolio-facing source with the same overstatement.
- **Fix:** Change README.md:51 to: 'a rendered 5x4 chart with a known blur: all 20 squares and at least 76 of 80 edges found, every edge within 6 %; a 5x5 chart with blur growing to the corners reproduces each square's blur within 8 %.' Alternatively, change the test to match the claim.
- **Files:** README.md
- **Area:** results/docs

## NEW-4 [medium] advice-contradiction

- **A:** mac/IQCoach/Sources/Coaching/EditingRules.swift:34-40 (crushedShadows): 'Adjust > Light: drag Shadows up and lower Black Point.' docs/FEEDBACK-LAYERS-SPEC.md:365 repeats it.
- **B:** mac/IQCoach/Sources/Coaching/EditingRules.swift:107-113 (flatTones, fired when tonal_range < 7 stops with room at both ends): 'Adjust > Light: Contrast up, and lower Black Point.' docs/APP-IQ-COACH-SPEC.md:114 says crushed shadows take 'Black Point / Blacks +', and flat tones take 'Contrast +, Black Point'.
- **Evidence:** The same file prescribes the same Black Point move, 'lower', for two opposite problems: blacks already crushed (clip_low > 0.5 %) and blacks with headroom (clip_low < 0.2 %, tonal range under 7 stops). Moving one control the same way cannot both lift crushed blacks and deepen flat ones. The spec also gives 'Black Point +' for crushed shadows, which is the opposite of the code's 'lower'. Whichever direction Apple Photos uses, one of the two rules, or the spec, points the wrong way.
- **Fix:** Choose the direction from Apple Photos' Black Point slider, where raising it darkens the blacks. Keep 'lower Black Point' for crushedShadows and change flatTones to 'raise Black Point'. Make docs/APP-IQ-COACH-SPEC.md (crushed shadows: Black Point down / Lightroom Blacks +) agree with the code.
- **Files:** mac/IQCoach/Sources/Coaching/EditingRules.swift, docs/APP-IQ-COACH-SPEC.md
- **Area:** app

## CLIP-6 [low] doc-vs-behaviour

- **A:** SnapshotRunner.swift:19-20 says the photo screen "shows a clipped photo that has a file ... the one whose 800 px thumbnail really has the most blown pixels". mac/IQCoach/README.md:37 says photo-<the most visibly clipped photo>.png.
- **B:** SnapshotRunner.swift:59 filters only path != nil, not file existence, and blown() returns 0 when the thumbnail fails. With every candidate original offloaded, max(by:) returns the first candidate, the analyzer's top-clipped 6721B8DA.
- **Evidence:** /private/tmp/claude-501/snaps/photo-6721B8DA-E5D3-4B54-B807-8DB95C9B4FCE.png (Oct 23 02:56) shows the Clipping overlay selected on a placeholder reading "File not found at its recorded path", captioned "14.70 % of pixels". originals/6/ is empty, and none of the 389 analyzed originals remain on disk.
- **Fix:** Filter candidates with FileManager.fileExists, and fall back to a photo with a file or print a warning when none has one.
- **Files:** mac/IQCoach/Sources/App/SnapshotRunner.swift, mac/IQCoach/README.md
- **Area:** app

## F10 [low] stale-count

- **A:** README.md:9, :21, :89 '102 tests'; CLAUDE.md:18 '102 tests pass'
- **B:** pytest --collect-only at HEAD 076ef98: 103 tests collected
- **Evidence:** Commit 076ef98 updated the README counts to 102 and in the same commit added a sixth test to tests/test_noise_exposure.py (5 at a51ef50, 6 now), so HEAD collects 103.
- **Fix:** Change 102 to 103 in README.md (3 places) and CLAUDE.md.
- **Files:** README.md, CLAUDE.md
- **Area:** results/docs

## F21 [low] wrong-number

- **A:** results/FINDINGS.md:37 and deck library.html:8 'the D850 is 6 dB cleaner than the 17 Pro Max at ISO 100'
- **B:** results.json SNR medians on valid rows
- **Evidence:** In the 65–160 band: D850 39.1 dB vs 17 Pro Max 32.0 dB, a 7.1 dB gap. At exactly ISO 100: 38.6 dB (n=3) vs 30.8 dB (n=12), a 7.8 dB gap. The illustrative figure does not match the data it illustrates.
- **Fix:** Use '7 dB' (or 'about 7 dB in the 65-160 band').
- **Files:** results/FINDINGS.md, deck slide library.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** results/docs

## F22 [low] wrong-number

- **A:** results/FINDINGS.md:76 'near neutral on the D850 (B/G −0.01 stop, R/G −0.05)'
- **B:** results.json wb_b_over_g_stops for the 36 D850 rows
- **Evidence:** The median D850 B/G is +0.009 stop (sign reversed). R/G is -0.045, and 17 Pro Max B/G is -0.170, both consistent.
- **Fix:** Change to 'B/G +0.01 stop'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F23 [low] inconsistent-threshold

- **A:** mac/IQCoach/Sources/Model/Metric.swift:99 goodLooksLike 'Clean from 38 dB'
- **B:** Metric.swift:75 definition '35+ dB is clean'; results/report.md How to read '35+ dB is clean'; deck noise.html '35 dB and up is clean'
- **Evidence:** The same metric popover gives two different 'clean' thresholds (35 and 38 dB). 38 is the app's 'Excellent' band edge, not 'clean'.
- **Fix:** Change goodLooksLike to 'Excellent from 38 dB; clean from 35 dB; visibly noisy below 25 dB'.
- **Files:** mac/IQCoach/Sources/Model/Metric.swift
- **Area:** app

## F24 [low] stale-count

- **A:** CLAUDE.md:101 '43 Swift tests' and :104 '60 Swift tests'
- **B:** mac/IQCoach/Tests (77 @Test: ExampleFile 14, EditingRule 11, CameraRule 24, Structure 17, Model 8, ClippingMask 3); README.md:88 '77 tests'; commit 0a1473e '77 Swift tests'
- **Evidence:** grep -c '@Test' across Tests/IQCoachTests totals 77.
- **Fix:** Change CLAUDE.md to 77 Swift tests, or drop the historical counts.
- **Files:** CLAUDE.md
- **Area:** results/docs

## F25 [low] inconsistent-count

- **A:** README.md:12 'A first adversarial review ... found 13 issues; the correctness ones are fixed ... the methodology caveats are stated'
- **B:** REVIEW.md: correctness issues C1-C13 (section 1) plus 13 numbered methodology caveats (section 2); CLAUDE.md:20 '13 correctness issues and 13 methodology caveats'
- **Evidence:** REVIEW.md has 13 C-headings and 13 numbered caveats (26 items). The README's '13 issues' with a correctness/caveat split implies 13 in total.
- **Fix:** Change README to 'found 13 correctness issues and 13 methodology caveats'.
- **Files:** README.md
- **Area:** results/docs

## F26 [low] stale-number

- **A:** CLAUDE.md:90 'Watch media/build/iq-analyzer-explainer.mp4 (12 min 51 s ...)'
- **B:** ffmpeg (imageio-ffmpeg) on media/build/iq-analyzer-explainer.mp4
- **Evidence:** ffmpeg reports 'Duration: 00:13:31.63'.
- **Fix:** Change to '13 min 32 s', or drop the duration.
- **Files:** CLAUDE.md
- **Area:** results/docs

## F27 [low] stale-number

- **A:** deck pipeline.html:21 'Stages 1 to 9 run once per photo in about 1.5 seconds'
- **B:** results.json analysis_s; FINDINGS section 7 run time
- **Evidence:** The median analysis_s over 389 rows is 2.03 s. The fourth run took 978 s for 389 images (2.5 s each). 1.5 s matches only the first run (578 s / 389), before the structure and uncertainty stages.
- **Fix:** Change to 'about 2 to 2.5 seconds'.
- **Files:** deck slide pipeline.html (artifact 'How iq-analyzer Reads a Photo')
- **Area:** deck/video/other

## APP-20 [low] two-sources-one-screen

- **A:** mac/IQCoach/Sources/Support/ContentIdentifier.swift:31,115 (Vision line 'horizon N° off level', magnitude only)
- **B:** mac/IQCoach/Sources/Model/Structure.swift:61-65 / ContentSections.swift:200-209 (analyzer 'Horizon tilt' row, 'N° off level, right/left end lower')
- **Evidence:** VNDetectHorizonRequest (the app's code path: 1600-px thumbnail with transform) was run on Photos' 1024-px derivatives of the 177 photos that have a level edge, because the originals are no longer on disk. Vision returned a horizon for 81 of them. The two angles differ by 2° or more on 28 of the 81 (e.g. 72B231CE: analyzer 3.7° left end lower vs Vision 6.4°; ADEAC6D6: 5.8° vs 1.5°; 9EE30E45: 8.8° vs 1.0°). The detail page then shows two different 'horizon ... off level' figures. The sign conventions do agree (see notes), so this is a disagreement about which line was found, not a sign error.
- **Fix:** Label the Vision figure as Vision's ('Vision horizon'), or show it only when it agrees with the level edge within 1°, as docs/FEEDBACK-LAYERS-SPEC.md:333,397 plans.
- **Files:** mac/IQCoach/Sources/Support/ContentIdentifier.swift, mac/IQCoach/Sources/Views/ContentSections.swift
- **Area:** app

## APP-21 [low] definition

- **A:** iqa/structure.py:140-146 (tilt = length-weighted median angle of all Hough segments >= 40 % of width within 10° of level)
- **B:** mac/IQCoach/Sources/Model/Structure.swift:13 ('Tilt of the longest nearly level edge'); iqa/structure.py:21 and results/report.md:130 ('the longest near-level edge')
- **Evidence:** Synthetic check with analyze_structure on a 1200x800 image holding one 1080-px edge at +3° and two 624-px level edges: the reported tilt is 0.0°, not the longest edge's 3.0°.
- **Fix:** Describe the value as 'the length-weighted median tilt of the long near-level edges' in the app Glossary, the structure.py docstring and report.py.
- **Files:** mac/IQCoach/Sources/Model/Structure.swift, iqa/structure.py, iqa/report.py
- **Area:** app

## F11 [low] chart-caption

- **A:** results/FINDINGS.md:42: '`charts/lwph_by_camera.png` (73 images with ≥ 3 valid edges)'
- **B:** results/charts/lwph_by_camera.png (iqa/report.py:216-226): boxes for iPhone 17 Pro Max n=43, iPhone 13 n=20 and iPhone XR n=3, so 66 images
- **Evidence:** The chart keeps the top-5 cameras by frame count and drops any box with fewer than 3 values. That removes the D850 (1) and the 6 single-image cameras (iPhone 12, 17 Pro, 12 mini, XS, SE, G7 X), 7 of the 73. I read the PNG to confirm the n labels.
- **Fix:** Caption it '66 of the 73 images with >= 3 valid edges (cameras with >= 3 such images)'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F12 [low] sign

- **A:** results/FINDINGS.md:76: 'gray-world balance is near neutral on the D850 (B/G −0.01 stop, R/G −0.05)'
- **B:** results.csv: median wb_b_over_g_stops over the 36 D850 rows = +0.009; R/G = −0.045
- **Evidence:** Recomputed from results.json, and the CSVs of all earlier commits give the same +0.009. The B/G sign is wrong. The R/G figure and the 17 Pro Max −0.17 are right.
- **Fix:** Change to 'B/G +0.01 stop'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F13 [low] claim

- **A:** results/FINDINGS.md:90-91: four screen photos at 11-127 '(ISO 64-125, SNR 21-34 dB, one of which had sat in the noisiest-valid list at 20.8 dB)'; section 6 line 128: 'the four screen photos no longer appear among the noisiest valid images'
- **B:** results.csv: the screen frames are 19AF39A4 (iPhone XR, ISO 50, peak 11.28), 6721B8DA (ISO 125), 7CF48ECB (ISO 80) and 9AE754E4 (ISO 64). The first-run report.md (git 9c97e74) lists two of them in Noisiest: 9AE754E4 at 20.8 and 6721B8DA at 21.1. media/make_explainer.py:111 cites the 21 dB, ISO 125 one
- **Evidence:** Listed the noise_periodic_suspect rows and read the first-run report via `git show 9c97e74:results/report.md`.
- **Fix:** Change to 'ISO 50-125' and 'two of which had sat in the noisiest-valid list (20.8 and 21.1 dB)'.
- **Files:** results/FINDINGS.md
- **Area:** results/docs

## F14 [low] definition

- **A:** results/report.md:134 / iqa/report.py: '`clip_gamut_pct` is the extra share that saturates only after converting Display P3 or Adobe RGB to sRGB'
- **B:** results.csv: 23 rows with color_profile 'assumed-sRGB' (no conversion) have clip_gamut_pct > 0, up to 0.057 % (61B631F3, D850; E602D5AB, iPhone 6 Plus 0.026)
- **Evidence:** The cause is in the code. iqa/imageio.py:225 native_clip_stats counts clipping at full resolution, while iqa/exposure.py:30 analyze_exposure subsamples [::2, ::2]. iqa/analyze.py:30 subtracts the two, so clip_gamut_pct holds sampling noise even where nothing was converted, and for converted files it is biased by the same amount. No row crosses the 1 % threshold.
- **Fix:** Compute both counts on the same pixel set: call native_clip_stats on rgb8[::2, ::2], or pass step=1 to analyze_exposure for the clip counts. Set clip_gamut_pct = 0 when the profile was not converted.
- **Files:** iqa/analyze.py, iqa/imageio.py, iqa/exposure.py
- **Area:** analyzer

## F16 [low] accounting

- **A:** results.csv columns edges_candidates / edges_measured / edges_rejected / edges_reject_reasons, and report.md:22: rejected edges were 'clipped, shaded, too noisy, too small a step, or not a step at all'
- **B:** results.json: in 76 rows candidates != measured + rejected (128 candidates unaccounted). Reject reasons include error=3,024 (20 % of the 15,162), rise_width=347 and slant=15, which the report sentence does not name
- **Evidence:** iqa/edges.py:156-157 drops ROIs that fall outside the frame with a bare `continue` and records no reason, so they are counted in neither measured nor rejected. Summed edges_reject_reasons across rows: plateau_noise 4294, error 3024, clipped 1924, contrast_gt_1 1812, no_mtf50 1149, step_too_small 901, fit_residual 835, shading 812, rise_width 347, not_a_step 49, slant 15 (total 15162, matching the report).
- **Fix:** Count out-of-frame ROIs as reasons['out_of_frame'] in edges.py. Add 'SFR failures' to the report sentence, or generate the list from the reason keys.
- **Files:** iqa/edges.py, iqa/report.py
- **Area:** analyzer

## F18 [low] claim-vs-output

- **A:** results/FINDINGS.md:117: 'DR is mostly lower bounds (section 3) and should not be charted against ISO for this library'
- **B:** results/report.md:114 embeds charts/dr_vs_iso.png, which iqa/report.py:186 always draws (72 non-lower-bound points)
- **Evidence:** Read both, and the report's chart list includes dr_vs_iso.png.
- **Fix:** Either drop dr_vs_iso from write_charts when most rows are lower bounds, or soften the FINDINGS sentence to say the chart shows only the 72 frames where the floor was reached.
- **Files:** iqa/report.py, results/FINDINGS.md
- **Area:** analyzer

## F19 [low] range

- **A:** iqa/structure.py docstring step 4: the flat, texture and edge shares 'sum to one' (each a share in 0..1)
- **B:** results.csv row 6AD0A76F-9445-4A27-BD48-5A989989B890.jpeg: structure_flat_share = -2.77556e-17
- **Evidence:** Range check over all 389 rows. structure.py:159 computes flat = 1 - edge - texture in floating point, which goes negative when texture + edge = 1.
- **Fix:** Clamp the share: max(0.0, 1.0 - edge - texture), or compute flat as the mean of the flat mask.
- **Files:** iqa/structure.py
- **Area:** analyzer

## F13 [low] definition

- **A:** Deck 'one-number' and 'the-row': p80 is 'in-focus sharpness', 0.440. Glossary: p80 is 'taken as the in-focus figure'.
- **B:** results.json for the walkthrough photo has a separate column mtf50_infocus_cpp = 0.410 from the two-cluster split (iqa/analyze.py:37-40). report.md:130 describes it as the in-focus value when the edges split.
- **Evidence:** The same photo has two 'in-focus' figures (0.440 and 0.410). The deck shows only p80 and does not mention the column that is named in-focus.
- **Fix:** On the one-number and the-row slides, name the p80 as 'in-focus (p80)' and add mtf50_infocus_cpp = 0.410, or explain that the two-cluster value is the one named in-focus.
- **Files:** deck project/slides/one-number.html, deck project/slides/the-row.html, deck project/slides/glossary.html
- **Area:** deck/video/other

## F14 [low] method-statement

- **A:** Deck 'periodic': 'The analyzer averages the power spectrum of every flat patch'. The noise slide defines a flat patch as one of the 33,609 kept, texture-free patches.
- **B:** iqa/noise.py:270-271 runs periodic_texture over cand (edge-free, unclipped candidates), before the texture-ratio selection. The slide's own alt text says '46,213 patches', which is the candidate count.
- **Evidence:** Read noise.py. cy, cx = Yg[cand], Xg[cand], not Yg[sel].
- **Fix:** Change to 'every candidate patch (edge-free and unclipped)'.
- **Files:** deck project/slides/periodic.html
- **Area:** deck/video/other

## F15 [low] exclusion-rule

- **A:** Deck 'library' footer: 'frames flagged as extrapolated or periodic are excluded'
- **B:** iqa/report.py:97-98 excludes extrapolated, noise_texture_suspect and noise_periodic_suspect. FINDINGS.md:22 says its table excludes 'extrapolated or texture-suspect'.
- **Evidence:** Read report.py _snr_ok and FINDINGS line 22. The slide leaves out texture-suspect (21 frames).
- **Fix:** Change to 'extrapolated, texture-suspect or periodic'.
- **Files:** deck project/slides/library.html
- **Area:** deck/video/other

## F16 [low] timing

- **A:** Deck 'pipeline' footer: 'Stages 1 to 9 run once per photo in about 1.5 seconds'
- **B:** results/results.json analysis_s: median 2.03 s (p25 1.55 s, p75 2.77 s). FINDINGS gives later runs of 741 to 978 s for 389 images (1.9 to 2.5 s per photo). The 1.5 s is the first run's 578 s / 389.
- **Evidence:** Computed percentiles of analysis_s.
- **Fix:** Change to 'about 2 seconds'.
- **Files:** deck project/slides/pipeline.html
- **Area:** deck/video/other

## F17 [low] count

- **A:** Narration slide 9: 'the library's screen photos score eleven, fifteen and one hundred twenty-seven' (three values)
- **B:** results.json has four flagged screen photos: 11.28 (19AF39A4), 14.42 (7CF48ECB), 15.01 (6721B8DA), 126.94 (9AE754E4). FINDINGS.md:90 says 'four screen photos at 11-127'.
- **Evidence:** Listed noise_periodic_suspect rows.
- **Fix:** List all four values (11, 14, 15, 127), or say 'four screen photos, 11 to 127'.
- **Files:** media/make_explainer.py
- **Area:** deck/video/other

## F16 [low] definition

- **A:** results/FINDINGS.md:40-53 (LW/PH presented as the resolution-neutral way to compare cameras and lenses).
- **B:** iqa/analyze.py:24 (lw_per_ph(edges.mtf50_p80, img.height)): img.height is the long side for portrait frames and the short side for landscape frames.
- **Evidence:** In results.json, LW/PH/c-px equals 2 x the long side on 106 portrait rows and 2 x the short side on 37 landscape rows, so identical optics read 1.33x higher in portrait. On the 17 Pro Max this changes the gated lens order the app would use: with height, main 2608 vs ultra-wide 2532; with the short side, ultra-wide 2158 vs main 1956.
- **Fix:** Normalise LW/PH to the short side (or to the landscape picture height), or compare lenses in c/px within a single output resolution, and say which in FINDINGS §2.
- **Files:** iqa/analyze.py, iqa/edges.py, results/FINDINGS.md
- **Area:** analyzer

## format-column-jpg-vs-jpeg-same-bytes [low] metadata

- **A:** In the app Photos runs, format is 'jpg' for 38 of 40 rows (files named from PhotoKit's originalFilename, for example 013-IMG_0436.JPG).
- **B:** In the library run (results/results.json), format is 'jpeg' for 324 rows (Photos' internal UUID.jpeg names) and 'heic' for 65.
- **Evidence:** For 16 matched pairs with identical bytes and identical values in every other metric column, format differs only as jpg vs jpeg. It comes from the file extension (iqa/imageio.py:203, `meta = {"format": ext.lstrip(".")}`). A combined table or any HEIC-vs-JPEG split would therefore show three formats where there are two.
- **Fix:** Normalize the extension in load_image (jpg/jpe -> jpeg, heif -> heic) so the format column names the container, not the file name.
- **Files:** iqa/imageio.py
- **Area:** analyzer

## claude-md-pickers-not-exercised [low] state-claim

- **A:** CLAUDE.md:106-107 says 'Not yet exercised live by a session: the pickers, Table sorting, the Vision section in the running window.'
- **B:** ~/Library/Application Support/IQCoach/runs/20261015T043404 (4 photos, 00:34) and 20261015T053032 (3 photos, 01:30) on 2026-10-15.
- **Evidence:** Their copies are named NNN-photo.jpeg, a pattern that only PhotosImporter.export(picked:) produces (PhotosImporter.swift:85), so the system picker ran end to end twice; run 043404 started one minute after commit d5eba6e (00:33:21). The picker copies 001-photo.jpeg and 002-photo.jpeg are byte-identical to the PhotoKit originals IMG_0448 and IMG_0453, which confirms the README's 'original data with EXIF intact' claim. Their metrics match run 040506 in every column except format.
- **Fix:** Update CLAUDE.md to say the picker has been run on 7 photos (two runs on 2026-10-15) and that its copies are byte-identical to the PhotoKit originals. Leave Table sorting and the Vision section on the not-yet-exercised list if they still are.
- **Files:** CLAUDE.md
- **Area:** results/docs

## NEW-5 [low] count

- **A:** mac/IQCoach/README.md:42: '`Sources/Coaching`: the twelve camera rules and twelve photo editing rules'
- **B:** mac/IQCoach/Sources/Coaching/CoachingEngine.swift:7-21 runs 13 camera rules: isoCeiling, noiseCharacter, lensComparison, fieldSoftness, highlightDiscipline, shadowDiscipline, sharpeningCharacter, colourLean, slowShutter, horizonLean, shallowDepthHabit, apertureSweetSpot and sharpnessConfidence. EditingRules.advice (EditingRules.swift:8-9) runs 12 rules.
- **Evidence:** I counted the rule calls in CoachingEngine.insights: 11 in the array literal, plus apertureSweetSpot, plus sharpnessConfidence, for 13. The 12 editing rules match the README.
- **Fix:** Change 'twelve camera rules' to 'thirteen camera rules' in mac/IQCoach/README.md:42.
- **Files:** mac/IQCoach/README.md
- **Area:** app
