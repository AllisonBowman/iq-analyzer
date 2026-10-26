# The analyzer's memory: design (2026-10-26)

The memory remembers every photo the analyzer has measured, by a fingerprint of its bytes. A photo is never copied or
measured twice. Disk, RAM and CPU stay bounded as the library grows, and the coach advises from the photographer's
recent work instead of from all of it.

The evidence behind each choice (measured costs on this Mac, the hash benchmark on her own photos, and the cited
methods) is in `docs/MEMORY-RESEARCH.md`. The schema is `iqa/memory_schema.sql`, the single source of truth that both
the analyzer and the app's tests execute.

## 1. The problem, measured (2026-10-23, this Mac)

- `~/Library/Application Support/IQCoach/photos` held 93 copied originals (444 MB) after five runs. They are only 50
  distinct contents: 196.6 MB (44 %) were byte-identical duplicates.
- Every run measured every photo again. A 24 MP measurement costs about 2.7 s quiet (3.6-4.3 s under load) and peaks at
  1.7-2.9 GB of RAM. A SHA-256 of the same file costs 2 ms, about 1/1,600 of that.
- The app loads one run's `results.json` and replaces its library each time, so nothing carries over between runs.
  At 54,000 photos a results.json would be about 225 MB and take 3-9 s to decode.
- `ThumbnailStore` limits its cache by count (600) but not by bytes. An 800 px entry is about 1.9 MB, so the worst case
  is about 1.1 GB. `ClippingMaskStore` and the Vision cache have no limit.
- `analysis_s` uses `time.time()`, which counts system sleep: 22 of 389 library rows read 900-1,063 s.

## 2. Requirements, as testable properties

1. **Zero false skips.** A photo is reused only when its bytes match a stored SHA-256 exactly and it was measured with
   the current analyzer key. No perceptual hash, file name, size, date or partial hash ever causes a skip.
2. **A hit is O(1).** A known photo costs a lookup (microseconds) plus, at most, one hash (2 ms). A known PhotoKit
   asset costs no download and no copy.
3. **Bounded disk.** Copies of originals are deleted once measured. The record tier holds at most `window` photos per
   camera (default 500); the detail tier at most `detail_budget` bytes (default 8 MB); previews at most
   `preview_budget` bytes (default 256 MB, never evicting a preview of a photo in the window, so the bound is the
   larger of the budget and the window's own previews). Only the ledger grows with the library: about 530 B per
   photo as the app fills it (527-531 B measured, about 29 MB at 54,000 photos; MEMORY-RESEARCH.md §3.12).
4. **Bounded RAM.** The app holds at most `window` records per camera. In-memory image caches are limited by bytes.
5. **Bounded CPU on past work.** A photo already measured is never measured again unless the analyzer's method
   changed and the photo is presented again. Nothing sweeps the archive.
6. **Advice tracks current habits.** The coach reasons over the newest `window` photos of each camera, and a camera
   unused for 90 days says so before its advice.
7. **Read only toward the Photos library.** Nothing in the library is modified, as today.
8. **Every input works:** PhotoKit (newest N), the system picker, a folder, the CLI; with and without `--no-paths`.
9. **Explainable and forgettable.** Settings show what is remembered (counts, bytes, oldest and newest) and can forget
   a camera, compact, clear previews, or forget everything.

## 3. Identity

| Name | What | Used for |
|---|---|---|
| content id | SHA-256 of the exact bytes the analyzer reads (32 B; 64 hex in JSON) | The only key that decides reuse |
| analyzer key | `m<MEASUREMENT_VERSION>-r<max_rois>-s<max_side or 0>`, e.g. `m1-r30-s0` | Validity of a stored measurement |
| source | (kind, locator): a real file path, a PhotoKit `localIdentifier`, or a picker `itemIdentifier` | Cheap pre-checks; several per asset |
| dHash256 | 256-bit difference hash of a 17x16 grey downsample of the display-oriented pixels | Advisory near-duplicate grouping only |

- **Why SHA-256:** collision odds are about 10^-68 at 54,000 photos. It runs at about 2.6 GB/s in both hashlib and
  CryptoKit (ARMv8 SHA-2 instructions), faster than BLAKE2b here. xxHash is not cryptographic and would save 1.5 ms of
  a 2,700 ms miss.
- **Why not a perceptual hash for reuse:** a sigma-0.7 blur moved MTF50 by -18.5 % (median) while dHash64 stayed at
  0-1 and pHash64 at 0. A perceptual match means "same picture" precisely when the IQ numbers differ. Burst frames 0.67 s
  apart had pHash64 0.
- **Why not a Bloom filter for "seen":** a false positive silently skips a new photo forever. Exact 32-byte keys cost
  1.7 MB at 54,000 photos.
- **MEASUREMENT_VERSION** (in `iqa/__init__.py`) is bumped whenever a change to the measurement code changes any
  output. A tripwire test hashes the AST of the measurement modules (docstrings removed, so method notes can change
  freely) and fails when the code changes without a bump or a re-pin. Re-pin only after the golden outputs are
  bit-identical. Measurement modules: `imageio`, `sfr`, `edges`, `noise`, `exposure`, `structure`, `uncertainty`, and
  `analyze`. One version for all of them: decoding is 44 % of a measurement, so partial invalidation would save
  little.
- **Library versions** (numpy, scipy, opencv, Pillow, pillow-heif/libheif, rawpy/LibRaw) are recorded in `meta` as
  provenance but are not in the key. Determinism was checked: the same bytes gave 0 differing fields twice, and a
  byte-identical copy under another name gave 0 differing fields.

## 4. Tiers and budgets

| Tier | Holds | Bound | Lifetime |
|---|---|---|---|
| Ledger (`asset`, `source`) | content id, size, camera, capture time, status, analyzer key, timings, failed attempts, five headline figures, dHash256; every source | about 530 B per photo (measured) | Until forgotten |
| Record | the full scalar record (results.json row minus `path`, `edges`, `noise_curve`), raw-DEFLATE JSON, about 1.1 KB | newest `window` (500) measured photos per camera, by capture time | Folded into the archive, then deleted |
| Detail | `edges` and `noise_curve`, raw-DEFLATE JSON, 0.3-2.3 KB | `detail_budget` (8 MB), newest capture first | Deleted |
| Archive | per camera, month and analyzer key: fixed-bin histograms and exact share counts | O(cameras x months), about 1-3 KB per bucket | Until forgotten |
| Previews (app, `~/Library/Caches/IQCoach/previews`) | `<sha>.heic` 1600 px, `<sha>.mask.png` clipping mask, `<sha>.vision.json` | `preview_budget` (256 MB), least recently used first, photos outside the window first; window previews are never evicted | Evictable; rebuilt from PhotoKit when possible |
| Staging (`~/Library/Caches/IQCoach/staging/<stamp>`) | originals being measured | the current batch only | Deleted after the batch; leftovers swept at launch |

Ordering inside a camera uses `captured_ts`, and undated photos sort by `first_seen` after the dated ones' oldest
(they leave the window first). The window is per camera, so a camera used rarely (36 D850 photos over three years)
keeps all its photos; a time-based decay would have cut it to an effective 3.

`compact()` runs at the end of every `analyze --memory` and on demand. It folds records beyond the window into the
archive and deletes them, deletes detail beyond the budget, then runs `PRAGMA incremental_vacuum` stepped to
completion (unstepped it reclaims nothing). Compaction is idempotent.

## 5. The archive

A bucket is `{"metrics": {name: {"counts": {"<bin>": n}, "zero": n, "under": n, "over": n, "n": n}}, "shares":
{name: [hits, of]}}`, raw-DEFLATE JSON. Counts are exact integers, so merging buckets is exact and order-free.

| Metric | Field and gate | Bins |
|---|---|---|
| `sharpness_lwph` | `mtf50_p80_lwph` when `edges_measured >= 3` | log, ratio 1.02 (about 1 % relative), from 50 LW/PH |
| `snr_db` | `snr_midgrey_db` when clean (not extrapolated, not texture suspect, not periodic suspect) | linear 0.25 dB from 0 dB |
| `clip_high_pct`, `clip_low_pct` | the field | exact zero bin, then log ratio 1.05 from 0.001 % |
| `tilt_deg` | `structure_horizon_tilt_deg` | linear 0.25 degrees from -45 |

Bin index for a log metric: `floor(ln(x / lo) / ln(ratio))`; for a linear one: `floor((x - lo) / width)`. Values below
`lo` count in `under` (or `zero` when exactly 0 for clipping), values above a hard top (10,000 LW/PH, 80 dB, 100 %,
+45 degrees) in `over`. A quantile is read from the cumulative counts at the bin's representative value (geometric
centre for log bins, mid-point for linear), so its error is at most half a bin: about 1 % relative for sharpness,
0.125 dB for SNR. Shares: `clip_high_gt1` (`clip_high_pct > 1`), `clip_low_gt1`, `tilt_ge1` (`|tilt| >= 1`), each
`[hits, of]` over the photos that have the field.

The archive answers "your earlier photos with this camera" in fixed space. It never feeds the coaching rules, which
read the window.

## 6. The pipeline (`python -m iqa analyze ... --memory DB`)

For each candidate file, cheapest check first; each step can stop the pipeline:

1. **Stat check** (about 2 µs): a `file` source whose `stat_key` matches and whose `mtime_ns` is older than
   `verified_at - 1 s` (git's racy-clean rule) gives the content id without reading the file.
2. **Hash** (about 2 ms): `hashlib.file_digest(f, "sha256")`.
3. **Lookup** by content id (microseconds):
   - measured, current key, record present: **hit**. Emit the stored record (plus detail if kept); update `last_seen`;
     add the source.
   - measured, current key, record archived: **archived hit**. Do not measure (past work). Emit a ledger record:
     file, camera, datetime, `sha256`, the headline figures, `"memory_tier": "ledger"`. `--refresh` measures it again.
   - `not_capture` or `failed` with the current key: **remembered skip**. `--retry-failed` measures failed rows again.
   - another analyzer key: **stale**. Measure again (the file is here) and replace.
   - absent: **miss**. Measure.
4. **Measure** with `analyze_file`; record `wall_s` (`time.perf_counter`) and `cpu_s` (`time.process_time`).
5. **Commit** one `BEGIN IMMEDIATE` transaction per photo (asset upsert, record, detail, sources).

Each photo prints one machine-readable line: `IQA-MEMORY <hit|archived|skip|stale|miss|failed> <sha256 hex> <file>`.
After the loop: `compact()`, then the usual outputs. `--no-report` skips the charts and report.md (1.5 s of CPU per run,
and 14-15 s when matplotlib's font cache cannot be written); results.json and results.csv are still written. With
`--memory`, an empty file list is not an error, since a sources manifest alone can be ingested.

A measurement exception that belongs to the file (it cannot be decoded, the measurement raises) marks the photo
`failed` with its reason and counts an attempt. The photo is measured again the next time it is presented; after a
second failure with the same analyzer key it is final and not tried again (`--retry-failed` overrides). Environmental
failures are never remembered, so they cannot turn into a permanent skip: a missing module (`ImportError`),
`MemoryError`, any `OSError` with an errno (a vanished, unreadable or locked file; a decoder's "cannot identify image"
has no errno and is the file's own fault), a file that changed or vanished during its measurement, a HEIC without
pillow-heif, a RAW without rawpy, and a staged copy whose bytes no longer hash to what the app recorded. (The
research's real runs cached a `FileNotFoundError` from a swept staging file as `failed` in 2 of 2 tries before this
rule.) A database error (full disk, damage) stops the run with a clear message and never marks a photo.

**Sources manifest** (`--sources FILE`, JSON Lines, written by the app). Each line is one of:

```json
{"path": "/…/staging/…/IMG_0453.JPG", "sha256": "<64 hex>", "kind": "photokit", "locator": "ABC…/L0/001", "signature": "IMG_0453.JPG|public.jpeg|5712x4284"}
{"path": "/…/staging/…/IMG_0460.PNG", "kind": "photokit", "locator": "…", "signature": "…", "status": "not_capture", "reason": "no EXIF camera model"}
{"sha256": "<64 hex>", "kind": "picker", "locator": "<itemIdentifier>"}
```

A line with `path` names a staged file in this batch; its source row is added after the file is hashed. When the
line carries the app's `sha256` of the staged file, the analyzer measures it only if its own hash agrees. A staged
line may omit `locator` (a picker item the system gave no identifier, a copy an earlier version left): the photo is
measured and remembered by content with no source, so staging paths never become aliases. A `not_capture` line is
hashed and remembered without measuring. A line with only `sha256` links a source to a known content without a file.
A staged file gets only its manifest source; a file analysed in place gets a `file` source under its real path.

Exit codes: 0 normal (an empty list with `--memory` included); 4 every photo of a non-empty batch failed; 5 the
measurement libraries cannot be imported (nothing was marked); 2 a usage error or an unreadable manifest; 3 the memory
file cannot be used or a database error stopped the run; 1 only for an uncaught crash. The app reads 0 and 4 as a
finished run and everything else as an error, so a crash part-way through a batch is never shown as finished.

**Opening the database:** `PRAGMA quick_check` on an existing file (about 15 ms at 54,000 rows). A damaged file is moved
aside as `memory.bad-<stamp>.sqlite` and a fresh one is created, with a message, as `PreferencesStore` does.
Connections use `journal_mode=WAL` (persistent), `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`,
`journal_size_limit=4194304`; Python opens with `autocommit=True` and issues `BEGIN IMMEDIATE` itself (deferred
read-then-write transactions failed 52 % of the time under two writers; `BEGIN IMMEDIATE` failed 0 of 6,000).
`meta.current_analyzer_key` is written by every run.

**Other commands:**

```
python -m iqa memory stats DB [--json]          counts and bytes per tier, oldest and newest capture, per camera
python -m iqa memory compact DB [--window N] [--detail-mb M]
python -m iqa memory forget DB (--camera NAME | --before YYYY-MM-DD | --sha HEX | --all)
python -m iqa memory export DB --out results.json [--camera NAME]   the window as results.json (for iqa report)
python -m iqa memory key                         prints the current analyzer key
```

## 7. The app

**Who writes.** The analyzer is the only writer of the database. The app opens it read-write with
`PRAGMA query_only=ON` (opening a WAL file `SQLITE_OPEN_READONLY` fails with SQLITE_CANTOPEN when no -wal/-shm files
exist), reads, and closes. Forgetting and compacting run the `iqa memory` commands. Deleting the whole memory is done by
the app only while no analysis runs.

**Library.** At launch, and after every analysis, the library is the window read from the memory (newest `window`
records per camera), not the last run's results.json. "Open Results…" still opens any results.json as a file. Each
`PhotoRecord` carries `sha256` and `analyzer_key`; its `id` is the content id when there is one, so two
`IMG_0001.JPG` from different cameras no longer collide. Rows measured with an older analyzer key stay in the library
and are counted on the Library screen ("12 photos were measured with an earlier method; analyze them again to
refresh"), never mixed silently.

**Staging.** One folder per batch, `~/Library/Caches/IQCoach/staging/<stamp>-<random>/`, holding `files/<index>/
<originalFilename>` (what the analyzer measures, so a record's `file` is the real name), `other/<index>/<name>`
(non-captures, listed in the manifest only), `sources.jsonl` and `out/`. Every deletion checks that its path lies
strictly inside the staging folder (after resolving symlinks and `..`). Each batch holds an exclusive `flock` on its
own `.lock` file for its whole life; the launch sweep removes only batches whose lock it can take, so a second app
instance never deletes a live batch (it did in 12 of 12 trials before), and a crashed run's batch is swept because the
kernel releases its lock.

**PhotoKit (newest N).** One query loads the known `photokit` sources with their asset status, analyzer key and
signature. Walking the newest captures: screenshots and photos under 5 MP are skipped from PHAsset metadata before
any download, by the `.photo` resource's own pixel size (`PHAssetResource.pixelWidth`, macOS 13+), not the asset's,
which is the edited size: a crop would otherwise change the signature and push a capture under the 5 MP gate (48
real captures were). A known asset with the current key and an unchanged signature is skipped with no download
and no copy; one remembered as finally `failed` (two attempts) with the current key is skipped too and reported apart ("could not be
measured before, not tried again"). A known `not_capture` asset with an unchanged signature is skipped without
counting. Everything else is downloaded into staging and listed in the sources manifest. Non-captures found after
download (no EXIF camera model, under 5 MP, or a format iqa cannot read) go in the manifest as `not_capture`, so they
are never downloaded again. N counts captures considered, known or new. The signature check is enough here because
the app reads the `.photo` resource, the original, which an edit in Photos never changes.

**Picker.** `.photosPicker(..., preferredItemEncoding: .current, photoLibrary: .shared())` so `itemIdentifier` is
available where the system allows it. The picker delivers the current version, which is the edited render once a
photo has adjustments, so picker bytes never back an alias. When the library is readable without asking and the
identifier resolves, the item takes the PhotoKit path: the same skip rule against the remembered `photokit` sources,
and on a miss the `.photo` original is downloaded, hashed and staged with kind `photokit` (a picked item is not put
through the 5 MP / camera-model gate, because the photographer chose it). Otherwise the bytes are loaded and hashed
with CryptoKit and only they decide: a known content is linked by a `sha256`-only manifest line and not written
(unless its preview is missing, then it is staged again so the preview comes back, and the analyzer reports a hit); an
unknown one is staged as `photo-<first 8 hex>.<ext>`, the extension read from the bytes' own magic numbers, so an
edited RAW delivered as HEIC is not named `.DNG`.

**Folder.** `iqa analyze <folder> -r --memory` with the stat cache. Folder files stay where they are, so their real
path is the preview source.

**Earlier copies.** The copies earlier versions left in `Application Support/IQCoach/photos` are imported only when the
photographer asks (Settings). One APFS clone per distinct content is staged under the name it had before the app
prefixed it (`007-IMG_0448.JPG` becomes `IMG_0448.JPG`; a picker copy `002-photo.jpeg` becomes
`photo-<first 8 hex>.jpeg`) and measured with a locator-less manifest; previews are made; then only the copies whose
content the memory holds (measured with a preview, or not a capture) are deleted, with the empty folders left behind.

**Previews.** After the analyzer commits, the app makes, for each newly measured content whose staged file exists, a
1600 px HEIC preview (quality 0.7) and the clipping mask (computed exactly as today, from the original's 800 px
thumbnail in the file's own colour space, stored as PNG because a lossy preview moves the blown-pixel count by up to
116 %), then deletes the staging folder. `PhotoRecord.path` points at the preview (or at the real file for folder
sources). When a preview is missing and the photo has a PhotoKit source, it is rebuilt lazily from
`PHImageManager` (`version .unadjusted`, network off) when a view asks for it. Vision results are cached per content
in `<sha>.vision.json`. The previews folder is trimmed to its budget, least recently used first.

**RAM.** `ThumbnailStore` becomes one `NSCache` with `totalCostLimit` 96 MB (cost = bytesPerRow x height) and
`countLimit` 600, without the strong dictionary that blocked eviction. `ClippingMaskStore` and `ContentIdentifier`
use `NSCache` with byte or count limits.

## 8. Advice the memory enables

1. **Resting cameras.** A camera whose newest photo is more than 90 days old is Resting (more than 365 days:
   Dormant). Its screen opens with "You haven't shot with the iPhone 13 since 8 Jul 2026 (110 days). This advice comes
   from those photos; a new photo from this camera brings it up to date." The coaching itself is unchanged.
2. **This photo against your usual.** On a photo's screen, for blown highlights, crushed shadows and clean SNR: the
   mid-rank percentile of the photo among the camera's other photos in the window, shown only at or below the 10th or
   at or above the 90th percentile and only with at least 20 other photos (feedback outside a tolerance band).
   Clipping is said only when it is material: "more" needs the photo at 0.1 % of the frame or above, "fewer" needs the
   camera's median there (on the real library a photo was otherwise "fewer crushed shadows than 90 %" at a few
   thousandths of a percent). Sharpness is claimed only when the photo's 95 % interval lies wholly beyond the camera's
   10th or 90th percentile, because the per-image interval is about +/-30 %.
3. **Earlier photos.** A camera with archived buckets shows "Earlier: 2,310 photos (Mar 2021 - Jun 2026), median
   sharpness 812 LW/PH, more than 1 % blown in 21 %", from the archive, beside the window's own figures.
4. **What the coach remembers** (Settings): per tier the count and bytes, oldest and newest capture, the window and
   budgets, per camera the photos remembered and its state; and Compact now, Clear previews, Forget a camera, Forget
   everything. Each control says what it does before it does it.

## 9. Not in this change

- PhotoKit persistent change tokens (`fetchPersistentChanges(since:)`) to notice deleted and edited assets. The
  localIdentifier lookup already makes a re-run free; deleted assets stay in the memory until forgotten.
- `PHCloudIdentifier` for cross-device identity (`archivalStringValue` needs macOS 15.2).
- A long-lived analyzer worker (`iqa serve`) and parallel workers (1.7-2.9 GB peak RSS per image).
- Burst advice. On this library only 2 burst groups have two frames with a sharpness figure, and both ratios sit
  inside the per-image interval, so "the sharpest frame" cannot be claimed; clipping-based burst advice needs
  sub-second capture times the records do not carry. dHash256 is stored so this can be built later.
- Recency weights inside the window. The window is a boxcar: every rule and test stays exact and unchanged.

The final research round (MEMORY-RESEARCH.md §0, §3.10-§3.14) argues for further hardening that this change does not
build yet, each with its measured reason:

- **A bounded reservoir of originals** (64 per active camera, at most 1 GB, in Caches) so a `MEASUREMENT_VERSION` bump
  can be re-measured without downloads: 99.9 % of the library is iCloud-only and Photos keeps an app download only
  until its next sweep. Today a bump re-measures a photo only when it is presented again.
- **A writer lease** (`flock` on `memory.lock`) so a second app instance is a read-only viewer. Staging batches already
  carry an owner lock, so a second instance's sweep no longer deletes a live batch; two analyses at once are safe for
  the database (`BEGIN IMMEDIATE`) but compete for RAM.
- **A rendition column** (original / edited / external edit) so only originals feed the camera figures. Picked photos
  that Photos can read now go through the PhotoKit path and are measured as their originals; a picked photo without
  library access is measured as delivered, which can be an edited render. Lightroom saves (959 at 5 MP or more in this
  library) are not told apart from camera originals.
- **A recovery ladder and payload checksums** (REINDEX, `.recover`, a weekly `VACUUM INTO` backup, CRC32 on each
  compressed blob) instead of moving a damaged file aside and starting fresh.
- **Capture time from SubSecTimeOriginal and OffsetTimeOriginal, never tag 306** (`DateTime`, a modification time that
  iqa/imageio.py falls back to). That is a measurement-module change and needs a `MEASUREMENT_VERSION` bump.
