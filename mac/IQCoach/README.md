# IQ Coach

A macOS app (SwiftUI, Swift Charts, Swift Testing, macOS 15) that turns `results.json` from `python -m iqa analyze` into plain-language coaching: what each camera does well and badly, what to change when shooting, and what to do in Apple Photos, Lightroom or any editor to each photo. Spec: `docs/APP-IQ-COACH-SPEC.md`.

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

Writes `library.png`, `camera-<first camera>.png`, `photo-<first photo>.png`, `glossary.png` at 1400 pt wide, 2x. Tall screens are drawn unrolled to full height. AppKit-backed controls (Table, List, GroupBox content, segmented Picker, Form) cannot draw off-screen, so snapshots substitute plain-view equivalents; the live app uses the real controls.

## Layout

- `Sources/Model`: PhotoRecord (NaN-tolerant decoding), Metric and bands, camera/lens grouping and summaries.
- `Sources/Coaching`: the twelve camera rules and twelve photo editing rules, pure functions.
- `Sources/Views`, `Sources/App`, `Sources/Support`: UI, app entry and snapshot runner, analyzer process and formatting.
- `Tests/IQCoachTests`: Swift Testing tests (every rule fires and stays quiet, band boundaries, decoding).

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
newest camera photos and does ask for read access.
