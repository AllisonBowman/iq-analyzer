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

`TEST_RUNNER_IQA_RESULTS` is how xcodebuild passes `IQA_RESULTS` to the test process; without it the real-data decoding test is skipped (returns early). `TEST_RUNNER_IQA_MEMORY=<path to a memory.sqlite>` does the same for the memory: every record in it must decode and carry a 64-hex content id. Point it at a copy or a scratch memory rather than the live one: the reader opens the file read-write with `query_only` on, so SQLite may create its `-wal` and `-shm` beside it. With `TEST_RUNNER_IQA_MEMORY_EXPECT=<out.json>` from `.venv/bin/python mac/IQCoach/scripts/memory_view.py <memory.sqlite> <out.json>` (run from the repository), the test also checks that the app's window and archive quantiles are the analyzer's own reading of the same file. The generated `IQCoach.xcodeproj` and `build/` are outputs, not sources.

## Sandbox is off

The app is not sandboxed (`ENABLE_APP_SANDBOX: NO`, ad-hoc signed) because Analyze Folder launches a user-chosen Python interpreter. Building from a sandboxed shell (for example an agent's) can also fail for xcodegen/xcodebuild itself; run them from a normal terminal.

## Pointing Settings at the Python venv

Create the environment once in the repo (`python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`). Then open Settings (⌘,) and set:

- Python interpreter: `~/Developer/iq-analyzer/.venv/bin/python` (the default)
- iq-analyzer folder: `~/Developer/iq-analyzer` (the default)

Press Validate: it checks the file exists and that `python -c "import iqa, iqa.memory"` works, reads the current analyzer key (`iqa.memory.analyzer_key()`), and says what to fix otherwise. Every analysis validates first and uses that key to decide what is already measured. Analyze Folder (⇧⌘O) runs `python -m iqa analyze <folder> -r --out <staging>/out --memory <memory.sqlite> --no-report`: the folder's files are measured where they are and never moved or deleted, and their real paths are what the app shows.

## Snapshot mode (check the UI without a GUI session)

```bash
build/Build/Products/Debug/IQCoach.app/Contents/MacOS/IQCoach --snapshot ../../results/results.json /tmp/iqcoach-snaps
```

Writes `library.png`, `camera-<first camera>.png`, `onething.png` (every coached camera's one-thing card), `check.png` (a fixture before-and-after check), `sparse-<camera>.png` (the most-photographed camera with fewer than 5 photos), `photo-<the most visibly clipped photo whose file is on disk>.png` (rendered with the Clipping overlay selected; when no photo's file exists it warns and shows a placeholder), `glossary.png` (Metrics and Method), at 1400 pt wide (900 for the card snapshots), 2x. Tall screens are drawn unrolled to full height. AppKit-backed controls (Table, List, GroupBox content, segmented Picker, Form) cannot draw off-screen, so snapshots substitute plain-view equivalents; the live app uses the real controls.

## The memory

The design is `docs/MEMORY-SPEC.md`; the schema is `iqa/memory_schema.sql`, which the tests execute to build their fixtures. The analyzer is the memory's only writer. The app opens it read-write with `PRAGMA query_only=ON` (a WAL file opened `SQLITE_OPEN_READONLY` fails when no `-wal`/`-shm` exist), reads, and closes; it never holds a connection.

- **What the library is.** At launch and after every analysis the library is the memory's window: the newest 500 measured photos of each camera (`meta.window`), source name "memory". Each photo's `id` is its content id (SHA-256 of the file's bytes), so two `IMG_0001.JPG` from different cameras no longer collide. Photos measured with an older analyzer key stay and are counted on the Library screen ("12 photos were measured with an earlier method; analyze them again to refresh"). Open Results… still opens any results.json as a file.
- **Photos (newest N).** One query loads the known PhotoKit sources. The 5 MP gate and the signature (`originalFilename|uti|WxH`) use the `.photo` resource's own pixel size (the asset's is the edited render's; it is used only when the resource reports none). A known asset measured with the current key whose signature is unchanged is skipped with no download and no copy, and so is one that failed twice with that key (a first failure is downloaded and tried once more); a remembered non-capture is skipped without counting; everything else is downloaded into staging under its original name and listed in the sources manifest (JSON Lines, spec §6) with the app's SHA-256 of the file, which the analyzer checks before measuring it. The skip rule is the pure `PhotosImporter.decide`.
- **Choose Photos.** The picker is created with `photoLibrary: .shared()` so items carry an `itemIdentifier` where the system allows it. When the library is readable without asking and the identifier names an asset with a `.photo` resource, the item goes the PhotoKit way: the same skip rule (a measured photo whose preview is missing is downloaded again), then the original is downloaded under its own name and listed as a `photokit` source with its signature. A picked photo is not held to the 5 MP and camera-model gate; a format the analyzer cannot read is listed as not a capture. Otherwise the bytes are loaded as the picker delivers them (the edited render once a photo has adjustments) and hashed with CryptoKit: a content known with the current key is linked by a `sha256`-only manifest line when nothing is gained by a copy (it is not measured, or its preview exists); anything else is staged as `photo-<first 8 hex>.<ext>`, the extension read from the bytes (JPEG, HEIF, TIFF, PNG magic) so a render is never named after a RAW original. Picker bytes never carry a signature.
- **After the run.** The `IQA-MEMORY <kind> <sha256> <file>` lines become the progress sheet's last line ("Remembered: 35 already measured, 5 new"). The run is finished on exit 0, or on exit 4 when every photo failed and said so; exit 5 (the measurement libraries cannot be imported) and every other code are errors. Previews are made for the staged contents that are remembered and have none (three at a time; a photo measured again keeps its own), also when the run was cancelled or failed after remembering some, then the staging folder is deleted and the previews are trimmed. No analysis starts while another is still stopping or the memory is compacted or forgotten.
- **Previews.** `<sha>.heic` (1600 px, quality 0.7; JPEG where HEIC cannot be encoded), `<sha>.mask.png` (the clipping mask computed from the original's 800 px thumbnail, as the overlay does; lossless because a lossy preview moves the blown-pixel count by up to 116 %) and `<sha>.vision.json` (Vision's result). A missing preview of a PhotoKit photo is rebuilt from `PHImageManager` (unadjusted, network off, never asking for access) when a view asks for it; otherwise the photo screen says the preview was not kept and how to bring it back.
- **Advice it adds.** A camera whose newest photo is more than 90 days old is Resting (more than 365: Dormant); its screen opens with a sentence saying so and its library tile carries the tag. The coaching itself is unchanged. A photo's screen compares its blown highlights, crushed shadows and clean SNR with the camera's other photos (mid-rank percentile, said only at or beyond the 10th or 90th with at least 20 others; the sentence states the share strictly beyond the photo, and only when it is 90 % or more, so ties at 0 % are never counted as "fewer") and claims sharpness only when the photo's whole 95 % range lies beyond the camera's 10th or 90th percentile and at least 9 in 10 others, counted, lie beyond it. Beside the memory's own window (not a results.json opened from a file), a camera with archived months shows "Earlier: 2,310 photos (Mar 2021 – Jun 2026), median sharpness 808 LW/PH, more than 1 % blown in 21 %" from buckets of the current analyzer key only.
- **Settings.** "What the coach remembers" shows the counts and bytes per tier, the window, the details budget, the database and previews sizes, the oldest and newest capture, and each camera's photos and state, with Compact Now, Clear Previews, Forget a Camera… (both through `python -m iqa memory`) and Forget Everything… (deletes `memory.sqlite`, its `-wal`/`-shm` and the previews; only while no analysis runs). Each asks first and says the consequence. When `~/Library/Application Support/IQCoach/photos` exists (the copies earlier versions made), an "Earlier copies" row offers Import and Remove…, which measures them into the memory, makes their previews and deletes only the copies whose content the memory now holds (measured with a preview, or not a capture) and the empty run folders. It runs only when clicked.

### Where files live, and their bounds

| What | Where | Bound |
|---|---|---|
| The memory | `~/Library/Application Support/IQCoach/memory.sqlite` (+ `-wal`, `-shm`) | records: newest 500 per camera; details: 8 MB; ledger about 530 B per photo (measured) |
| Previews | `~/Library/Caches/IQCoach/previews/` | 256 MB or the window's own previews, whichever is larger: least recently used first, never a photo in the window (a shown preview's date moves forward at most hourly); trimmed at launch and after every analysis |
| Staging | `~/Library/Caches/IQCoach/staging/<stamp>/` (`files/<index>/<name>`, `other/<index>/<name>`, `sources.jsonl`, `out/`, `.lock`) | the current batch, which holds an exclusive `flock` on its `.lock`; deleted after it; at launch every batch whose lock can be taken (its owner ended) is swept, so another instance's live batch is left alone; nothing outside it is ever deleted through it |
| Thumbnails in RAM | one `NSCache` | 96 MB by cost (bytes per row x height) and 600 entries |
| Clipping masks in RAM | `NSCache` | 32 MB |
| Vision results in RAM | `NSCache` | 2,000 summaries, 5,000 label lists |

## Layout

- `Sources/Model`: PhotoRecord (NaN-tolerant decoding, edge reject reasons, `PhotoKey`), Metric and bands (with "how sure" and per-camera/per-photo evidence text), camera/lens grouping and the gated `CameraSummary`, Wilson and Newcombe intervals (`Stats`), `UserPreferences`, `CaptureCheck`.
- `Sources/Coaching`: the evidence and effort vocabulary (`Evidence.swift`), intent tags and the device vocabulary (`RuleContext.swift`), twelve camera rules (noiseByISO, noiseCharacter, lensComparison, fieldSoftness, highlightDiscipline, shadowDiscipline, sharpeningCharacter, colourLean, slowShutter, apertureSweetSpot, levelEdgeLean, shallowDepthHabit) that each return a finding, a silent check with its numbers, or "not applicable"; the engine that picks the one thing; twelve photo editing rules sorted into Do first / Also / Checked / Not measured; capture checks; the sparse-camera summary. All pure functions.
- `Sources/Views`: the one-thing card, check card, report-card tiles, coaching cards, photo screen, library, sidebar, glossary (Metrics and Method), shared components (`MeasuredValue`, `EvidenceCapsule`, `ActionGroups`, `WhyButton`).
- `Sources/App`, `Sources/Support`: app entry, snapshot runner, analyzer process, preferences store, Markdown export, the Method text, formatting; the memory reader (`MemoryDatabase`, `MemoryStore`), previews (`PreviewStore`), staging, the sources manifest and IQA-MEMORY parsing (`ImportBatch`), earlier copies.
- `Sources/Model/ArchiveSummary.swift`, `Sources/Coaching/CameraFreshness.swift`, `Sources/Coaching/UsualComparison.swift`: the archive's bins and quantiles, Resting and Dormant cameras, this photo against your usual. Pure, and none of them feeds a coaching rule.
- `Tests/IQCoachTests`: 286 Swift Testing tests (every rule fires and stays silent with numbers, the one thing per real camera, evidence boundaries, every Newcombe row of the check table, photo lists, preferences, checks, exports, band boundaries, decoding; and for the memory: temporary databases built from the schema, raw-DEFLATE fixtures including a stored block and Python's own zlib output, the window, paths, archive quantiles within half a bin, freshness boundaries, the percentile thresholds, preview trimming, the skip rule, the manifest, IQA-MEMORY lines, the analyzer's exit codes, staging's path safety and owner lock, symlinked preview folders, and the app model's launch, maintenance and Forget Everything on temporary folders).

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
so no Photos permission is needed (with it, a picked photo is read as its original through PhotoKit and keeps its file name). New originals
are copied, EXIF intact, to staging, measured into the memory, given a preview and deleted; the library is
never modified. `IQCoach --analyze-photos N` (a launch flag for automation) uses PhotoKit to consider the N
newest camera captures and does ask for read access; known ones are not downloaded. A capture is what
`iqa/select_captures.py` keeps: a file with an EXIF camera model and at least 5 MP; screenshots, saved images
and thumbnails are skipped and scanning continues until N captures are considered.
