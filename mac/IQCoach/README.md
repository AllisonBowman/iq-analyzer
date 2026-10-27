# IQ Coach

A macOS app (SwiftUI, Swift Charts, Swift Testing, macOS 15) that turns `results.json` from `python -m iqa analyze` into plain-language coaching: what each camera does well and badly, what to change when shooting, and what to do in Apple Photos, Lightroom or any editor to each photo. Each camera screen opens with the one change most worth making, with a word and a photo count for how sure it is; the photographer can mark a finding as intended or start a check that measures his next photos against a frozen baseline. Spec: `docs/APP-IQ-COACH-SPEC.md` (shipped behaviour) and `docs/FEEDBACK-LAYERS-SPEC.md` (the design of the feedback layers).

## Build

```bash
cd mac/IQCoach
xcodegen generate
xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -configuration Debug -derivedDataPath build build
TEST_RUNNER_IQA_RESULTS=$PWD/../../results/results.json \
  xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -derivedDataPath build test
open build/Build/Products/Debug/IQCoach.app
```

`TEST_RUNNER_IQA_RESULTS` is how xcodebuild passes `IQA_RESULTS` to the test process; without it the real-data decoding test is skipped (returns early). The generated `IQCoach.xcodeproj` and `build/` are outputs, not sources.

## Sandbox is off

The app is not sandboxed (`ENABLE_APP_SANDBOX: NO`, ad-hoc signed) because Analyze Folder launches a user-chosen Python interpreter. Building from a sandboxed shell (for example an agent's) can also fail for xcodegen/xcodebuild itself; run them from a normal terminal.

## Pointing Settings at the Python venv

Create the environment once in the repo (`python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`). Then open Settings (⌘,) and set:

- Python interpreter: `~/Developer/iq-analyzer/.venv/bin/python` (the default)
- iq-analyzer folder: `~/Developer/iq-analyzer` (the default)

Press Validate: it checks the file exists and that `python -c "import iqa"` works, and says what to fix otherwise. Analyze Folder (⇧⌘O) runs `python -m iqa analyze <folder> -r --out ~/Library/Application Support/IQCoach/runs/<timestamp> --no-paths`. Because of `--no-paths` (the spec's choice) those results carry no file paths, so thumbnails show placeholders; results opened from a file that has `path` show real thumbnails.

## Snapshot mode (check the UI without a GUI session)

```bash
build/Build/Products/Debug/IQCoach.app/Contents/MacOS/IQCoach --snapshot ../../results/results.json /tmp/iqcoach-snaps
```

Writes `library.png`, `camera-<first camera>.png`, `onething.png` (every coached camera's one-thing card), `check.png` (a fixture before-and-after check), `sparse-<camera>.png` (the most-photographed camera with fewer than 5 photos), `photo-<the most visibly clipped photo whose file is on disk>.png` (rendered with the Clipping overlay selected; when no photo's file exists it warns and shows a placeholder), `glossary.png` (Metrics and Method), at 1400 pt wide (900 for the card snapshots), 2x. Tall screens are drawn unrolled to full height. AppKit-backed controls (Table, List, GroupBox content, segmented Picker, Form) cannot draw off-screen, so snapshots substitute plain-view equivalents; the live app uses the real controls.

## Layout

- `Sources/Model`: PhotoRecord (NaN-tolerant decoding, edge reject reasons, `PhotoKey`), Metric and bands (with "how sure" and per-camera/per-photo evidence text), camera/lens grouping and the gated `CameraSummary`, Wilson and Newcombe intervals (`Stats`), `UserPreferences`, `CaptureCheck`.
- `Sources/Coaching`: the evidence and effort vocabulary (`Evidence.swift`), intent tags and the device vocabulary (`RuleContext.swift`), twelve camera rules (noiseByISO, noiseCharacter, lensComparison, fieldSoftness, highlightDiscipline, shadowDiscipline, sharpeningCharacter, colourLean, slowShutter, apertureSweetSpot, levelEdgeLean, shallowDepthHabit) that each return a finding, a silent check with its numbers, or "not applicable"; the engine that picks the one thing; twelve photo editing rules sorted into Do first / Also / Checked / Not measured; capture checks; the sparse-camera summary. All pure functions.
- `Sources/Views`: the one-thing card, check card, report-card tiles, coaching cards, photo screen, library, sidebar, glossary (Metrics and Method), shared components (`MeasuredValue`, `EvidenceCapsule`, `ActionGroups`, `WhyButton`).
- `Sources/App`, `Sources/Support`: app entry, snapshot runner, analyzer process, preferences store, Markdown export, the Method text, formatting.
- `Tests/IQCoachTests`: 189 Swift Testing tests (every rule fires and stays silent with numbers, the one thing per real camera, evidence boundaries, every Newcombe row of the check table, photo lists, preferences, checks, exports, band boundaries, decoding).

## Gates

Every figure uses the analyzer's validity gates: three valid edges for sharpness, halo and centre/outer; a clean SNR reading (not extrapolated, textured or periodic) for noise; frames that reached the noise floor for an exact dynamic range. A report-card figure needs 5 photos that pass its gate (`CameraSummary.minRowsForFigure`); fewer shows "Not enough photos" with the counts. Coaching starts at 5 photos per camera; a finding resting on fewer than 8 photos, or on a share whose 95 % range crosses its line, is Thin and goes under "Needs more photos".

## Preferences

Set-aside cards, intent tags (dark on purpose, bright on purpose, colour is the point, not meant to be level, composed this way), the editor and capture checks are kept in `~/Library/Application Support/IQCoach/preferences.json` (atomic writes, debounced a second). A file that does not decode is moved aside as `preferences.bad-<stamp>.json` and the app starts clean. Settings has Reset Preferences…. Tags are keyed by camera, file name and EXIF date, so a copy analysed from the Photos picker under another file name does not carry its tags across.

## Live-window captures

`IQCoach --window-shots results.json <outdir>` runs the real app, opens the library, the first camera
and its first photo, and screenshots the window with `screencapture -l` after each step. It needs an
awake, unlocked display and Screen Recording permission for IQCoach (System Settings > Privacy &
Security > Screen Recording); without the permission `screencapture` exits with status 1 and
`window-shots.log` says so. The in-process `cacheDisplay` route was tried first and draws only the
detail pane: SwiftUI's split view does not render through it.

## Photos

"Choose Photos to Analyze…" (⇧⌘P, also on the toolbar and the empty screen) opens the system Photos
picker with previews of the library; up to 20 photos can be selected. The picker runs out of process,
so no Photos permission is needed. The chosen originals are copied, EXIF intact, to
`~/Library/Application Support/IQCoach/photos/<stamp>/` and analysed from there; the library is never
modified. `IQCoach --analyze-photos N` (a launch flag for automation) still uses PhotoKit to take the N
newest camera captures and does ask for read access. A capture is what `iqa/select_captures.py` keeps: a file
with an EXIF camera model and at least 5 MP; screenshots, saved images and thumbnails are skipped and scanning
continues until N captures are copied.
