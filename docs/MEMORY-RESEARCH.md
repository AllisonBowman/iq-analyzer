# IQ Coach memory: research brief

A slim, lazy, bounded memory for iq-analyzer and IQ Coach. Status: final research brief for design review,
2026-10-26, after one critique round and four follow-up studies.
What was built from it is `docs/MEMORY-SPEC.md` and its implementation (`iqa/memory.py`, `iqa/memory_schema.sql`,
`iqa/cli.py`, and `MemoryDatabase.swift`, `MemoryStore.swift`, `ImportBatch.swift`, `PreviewStore.swift` and others in
IQ Coach), built on 2026-10-26. The working-tree defects this brief measured in its final round (a transient
`FileNotFoundError` cached as `failed`, one instance's launch sweep deleting another's batch, the signature and capture
gate on the edited size, picker bytes as an alias, no check of staged bytes) are fixed there; MEMORY-SPEC.md §9 lists
what the brief recommends that is not built yet (the originals reservoir, the writer lease, renditions, the recovery
ladder, capture-time fields). §3.9 lists where this brief and the spec differ, and why.

**Goal (Allison, verbatim):** "build a robust, slim, lazy, memory for the application and advise of image
outcomes. build a memory management system that analyzes each image, makes some kind of fingerprint that it has
looked at that image, but prevents accumulations memory or processing power focused on past work."

**Working interpretation.**
- (a) Fingerprint every analysed image, so it is never copied or measured twice.
- (b) Keep a compact memory of outcomes, as a short per-image summary plus per-camera rolling aggregates, that the coach advises from.
- (c) Keep it bounded. Disk, RAM and CPU do not grow with history, old detail decays into aggregates, originals are not hoarded, and advice is weighted toward recent photos.
- (d) Keep it lazy. Nothing is computed until it is needed, a cache hit costs O(1), and cheap checks run before expensive ones.

**How this brief was made.** Eight researchers worked in parallel on fingerprinting, PhotoKit, bounded statistics, caching, coaching, lazy pipelines, profiling and a perceptual-hash benchmark. Six of them ran measurements on this Mac. The synthesiser then:
- re-ran the disk and duplicate counts and the `results.json` statistics on 2026-10-26 [L9];
- re-fetched six of the most load-bearing external sources [1][2][6][8][17][54];
- resolved the disagreements between researchers (§3.9).

**Final round.** A critic checked the draft against its own measurements and found 17 shaky claims. Four follow-up
studies answered them on this Mac:
- iCloud availability, retention, byte stability and the cost of restoring after an analyzer bump [L10] (§3.10);
- edited photos and picker renditions [L11] (§3.11);
- ledger bytes measured from both schemas [L12] (§3.12);
- fault injection: concurrent instances, a damaged database, a full disk [L13] (§3.13).

The finaliser then ran two checks nobody had run: WAL growth under a long reader, and Apple's system SQLite in Swift
writing against the Python writer [L14] (§3.14). A claim the final round changed is marked **Corrected**.

**How to read the tags.**
- [n] is an external source, listed in §7. Sources 157–196 were added in the final round.
- [L1]–[L14] are local measurements; §7 gives each one's scripts.
- [R] is this repository.
- **UNVERIFIED** marks a claim that nobody could check.

**Measurement conditions.** Other jobs (simulators, emulators, Xcode builds, parallel agents) loaded the Mac heavily during the research: load average 17 to 650. Every wall-clock time below is therefore an upper bound. Byte sizes, counts, stage shares and determinism results do not depend on load.

---

## 0. Decisions

1. **Identity is SHA-256 of the exact bytes the analyzer reads.** It is the only key that can let a stored measurement be reused.
   - Cost: 1.7–2.4 ms per 5 MB photo [L4][L6][L7], about 0.1 % of one analysis.
   - Collision probability: about 10⁻⁶⁸ at 54,000 files [L1].
   - No perceptual hash, pixel hash, filename, date or asset ID may ever cause a measurement to be skipped.
   - The rendition the bytes carry (original, edited, unknown, external edit) is recorded with them, because only PhotoKit `.photo` is the original by contract (§3.11).
2. **The PhotoKit asset ID is an alias, checked before any bytes move, and only for PhotoKit `.photo`.** A known `localIdentifier` whose `modificationDate` and resource signature are unchanged skips the download, the copy and the analysis.
   - The signature is built from the `.photo` *resource* (`PHAssetResource` W×H, macOS 13+), not from `PHAsset.pixelWidth`, which is the edited size (**Corrected**, §3.11).
   - Contract: `.photo` "Provides the original photo data for its asset" [1]. Measured [L10]: 93 of 93 retrievals of 50 assets matched the library's own content fingerprint, including 13 fresh iCloud downloads (95 % upper bound per retrieval 3.2 %). Across 62,013 assets, 705 of them edited, no `.photo` fingerprint differed from its original-stable hash.
   - A picked photo whose identifier resolves under authorization takes this PhotoKit path. Picker bytes never back an alias.
   - The re-hash audit is stratified by camera, source kind and local/cloud availability. A mismatch disables L0 only in its stratum (**Corrected**: a global disable would cost about 130 MB of downloads per newest-40 import) (§4.2).
3. **No hoarding of originals, plus a bounded re-measure reservoir** (**Corrected** from "originals are never kept").
   - Cache misses are streamed into staging, hashed while streaming, measured and deleted. The 443.8 MB of copies at rest and the 43 byte-identical copies (196.6 MB) go [L9].
   - Up to 64 originals per Active camera, sampled uniformly from its window, stay in `Caches/IQCoach/reservoir`: ≤ 256 MB per camera, ≤ 1 GB in total, discardable and excluded from backup [165][31].
   - Why [L10]:
     - 53,210 of her 53,257 captures (99.9 %) are cloud-only.
     - Photos keeps an app-downloaded original only until its next space-driven sweep (72 h to 86 days).
     - 6 of the last 10 analyzer transitions needed pixels. Without the reservoir, one such bump costs 3.94 GB of downloads to restore the 4 Active cameras' windows.
   - Measured cost: 957 MB for today's 4 Active cameras. A bump then costs 0 downloads and about 8.5 CPU-minutes, and coaching resumes at n = 64 at once.
4. **New photos are measured on arrival, and downloads spend a per-day budget set by the network path.**
   - The change feed drives analysis while Photos still holds a new capture locally: 29 of the newest 40 were local at IQ Coach's own 10-15 import [L10].
   - On an unmetered path: up to 500 photos and 2 GB a day. On an expensive or constrained path (`NWPath`): nothing [163][164]. Never more than about 1 % of free space a day, because downloaded originals stay inside her Photos library until the next sweep.
   - A restore starts only after the analyzer key has been stable for 12 h.
5. **One SQLite file in WAL mode, `memory.sqlite` in Application Support, with one batch at a time per machine.**
   - The Python package owns the schema. The Python worker writes measurements; the app writes only its own tables and the source statuses it decides before any bytes move.
   - Both sides use `BEGIN IMMEDIATE` and UPSERT. Measured:
     - 0 of 6,000 transactions failed with two Python writers and a reader [L4];
     - 0 failures in 3 × (3,000 Swift transactions on Apple's system SQLite 3.51.0 + 3,000 Python transactions on SQLite 3.53.4) with a reader, and `integrity_check` ok [L14]. (**Corrected**: the draft's figure had no Swift writer.)
   - Every batch, migration, compaction or forget runs under an `flock` lease on `memory.lock`, so one batch runs at a time per machine. A second app instance becomes a read-only viewer. Today nothing stops two instances, and one instance's launch sweep deleted the other's batch in 12 of 12 trials [L13].
   - The WAL stays near 4 MiB only while every read is short. A read held open grows it by about 44 KB per photo committed meanwhile, to 88 MB after 2,000 photos [L14]. `journal_size_limit` truncates only at the next reset [55]. Lists page by keyset in short statements (**Corrected**).
6. **One analyzer key, as in MEMORY-SPEC §3, with every bump classified by its golden-corpus diff** (**Corrected**: the draft's per-group versions are dropped).
   - Git replay of the 11 measurement commits on 20 canary photos [L10]:
     - 10 transitions in 10.1 days. 7 changed existing values, 6 needed pixels and 1 was derivable from stored columns.
     - 4 touched `imageio.py`, but only 1 changed every group.
   - Per-group keys would save CPU but not downloads: a cloud-only photo must be fetched if any group is stale. The per-photo `measurement` table costs 338–341 B per photo, half the ledger [L12].
   - Each bump declares `migration` (recomputed from stored columns, 0 downloads), `pixel`, or `schema-add` (new fields filled lazily). A test checks the declaration against the corpus diff.
   - Library versions (numpy, OpenCV, Pillow, libheif, LibRaw) are recorded as provenance, not put in the key. An upgrade re-runs the corpus, and any changed output becomes a `pixel` bump. Determinism across library upgrades is untested (risk 10).
   - A pytest AST tripwire (docstrings removed) forces the bump.
7. **Per-camera aggregates are fixed-mapping histograms** (the DDSketch/HDR family), with moments and exact share counters.
   - They are held in 13 weekly, 24 monthly and 1 archive bucket.
   - Size: at most 128 KiB per active camera and about 14 KiB per dormant one [L3].
   - Merges are exact and independent of insertion order (measured difference 3 × 10⁻¹⁶) [L3].
   - Only original renditions feed them (decision 12).
8. **Recency weighting is forward exponential decay on capture time, applied at query time, on a clamped clock.**
   - The half-life adapts per camera from the ladder {30, 90, 180, 365 days, lifetime}.
   - A separate calendar *freshness* clock (Active / Resting / Archived) decides whether a camera is coached at all.
   - The screen always shows n, Kish n_eff and n_eff counted in capture days.
   - **Corrected:** iqa reads only `DateTimeOriginal`, and without it falls back to tag 306 `DateTime`, which is a modification time (`imageio.py` L99-111, L157) [R]. The design reads `SubSecTimeOriginal` and `OffsetTimeOriginal` too, never uses tag 306, and clamps capture time to the moment the file was first seen, so no weight exceeds 1. Implausible clocks are flagged and left out of decay (§4.7).
9. **Byte budgets per tier: about 125 MB worst case at 54,000 photos, plus a ≤ 1 GB purgeable reservoir and ≤ 93 MB of weekly backups** (§4.8; **Corrected**).
   - The ledger is the only part that grows with the number of distinct photos. The lean layout measured 338–341 B per photo (18.3 MB at 54k, 37.5 MB at 110k). The draft's §4.4 DDL measured 666–677 B (36.3 MB at 54k), and the spec's schema 527–531 B, not the 140–290 B and "about 200 B" claimed [L12].
   - Live ledger rows are never evicted, only tombstones (beyond the newest 10,000). The draft's fixed 32 MB cap would have evicted 10,000 live rows at 54k, whose re-presentation costs about 47.7 GB of downloads [L12].
   - A re-run of photos already seen adds 0 bytes.
10. **One long-lived `python -m iqa serve` worker** (JSON lines over stdin/stdout, no matplotlib, recycled by count and RSS), **at most 2 per machine**, enforced by the batch lease (**Corrected**: the draft's limit held per instance only).
    - Environmental failures never become permanent. `failed` and `timeout` become final only after 2 attempts in different runs. An OSError with an errno, MemoryError, sqlite3.Error, a vanished file, a SHA mismatch or a signal the parent did not send is never cached [L13].
    - Today's working tree cached a FileNotFoundError from a swept staging file as `failed` in 2 of 2 real runs [L13].
11. **Near-duplicates are advisory only, and capture links are exact** (**Corrected**).
    - Each capture counts once, through exact links in this order: SHA-256 equality, a linked identifier, then a capture_id (make, model, `DateTimeOriginal`, `SubSecTimeOriginal`, `OffsetTimeOriginal`, plus Apple `PhotoIdentifier` or the Nikon serial and image number).
    - dHash256 ≤ 24 only breaks ties between tone edits. It linked 18 of 1,000 real crop geometries from her own edits [L11]. Its zero-error window (23–27) rests on 23 burst pairs, so the 95 % upper bound on false burst merges is about 13 % [L8][162].
    - Burst ID, capture-time window and a Vision revision-2 print (same scene at ≤ 0.50) group photos for advice. Burst siblings are always measured: they differ in exactly the sharpness the coach reports.
12. **Only original renditions feed the coach** (new).
    - A `rendition` column (original / edited / unknown / external_edit). Camera aggregates, percentiles and capture checks read `original`, and `unknown` only when its area is a native size seen for that model, its `Software` is the camera's own and it is not a Portrait.
    - Measured on her library [L11]: 48 captures fail today's 5 MP gate only because they were cropped; 959 Lightroom saves of 5 MP or more sit in Photos as unedited originals with camera EXIF.
    - Edited and external-edit photos are measured for their own screen and labelled "includes your edits".
13. **Damage and a full disk have a recovery ladder, not "start fresh"** (new) [L13].
    - Damage is declared only from a fresh connection under the batch lease, on `SQLITE_CORRUPT`/`SQLITE_NOTADB` or `quick_check` ≠ ok. An open reader saw `SQLITE_CORRUPT` on a file that passed `integrity_check`. On a full APFS volume SQLite reported FULL, IOERR and CANTOPEN, and "start fresh" would have renamed a healthy memory and then failed to create one.
    - Ladder: REINDEX → `.recover` (53,841–54,000 of 54,000 assets back) → merge the weekly `VACUUM INTO` backup → rebuild the archive from the ledger (204 of 204 buckets reproduced exactly).
    - CRC32 on every compressed payload, because both checks missed 18 of 20 archive and 20 of 20 record bit flips. A sequence sidecar detects a lost WAL tail.

---

## 1. The problem in numbers (measured on this Mac)

### 1.1 Disk and duplication

| What | Measured | Source |
|---|---|---|
| Photo copies in `~/Library/Application Support/IQCoach/photos` after 5 runs | 93 files, 443,769,320 B. That is 443.8 MB in decimal units, or 423.2 MiB; the "423 MB" figure quoted elsewhere is the MiB value | [L9] |
| Distinct contents among them (SHA-256) | 50. Duplicates form 40 groups with 43 redundant files: 37 files appear twice and 3 appear three times | [L9][L7] |
| Bytes wasted on duplicates | 196.6 MB, 44 %. The earlier 176 MB estimate missed a duplicate across paths: picker `002-photo.jpeg` is byte-identical to PhotoKit `IMG_0453.JPG` | [L1][L4][L8] |
| `runs/` | 6 entries, 1.7 MB, including one empty folder left by a failed run (`20261015T040043`) | [L9][L7] |
| Mean / maximum original | 4.77 MB / 15.5 MB (Nikon D850 JPEG) among the 93 copies. **Library-wide the mean `.photo` original is 9.67 MB** (D850 15.4 MB), from the sizes the Photos database records | [L2][L1][L10] |
| Local originals | **30 of 53,257 captures (0.056 %) on 2026-10-26**, all iPhones and all under 31 days old. The peak was 424 (0.8 %) on 2026-10-17. Photos' prune sweep of 2026-10-18 then freed 18.8 GB in one night and left 0. 1,035 originals were listed on 2026-10-13; none was still at its path on 2026-10-23 | [L1][L10][53] |
| A copy of every capture in the library | about 515 GB (53,257 × 9.67 MB). **Corrected:** the draft's 258 GB used the copies' 4.77 MB mean. 53,257 is the count under the app's own capture rule (≥ 5 MP, not a screenshot, not hidden, burst picks only, EXIF camera model) | [L10] |

### 1.2 Identity defects in today's keys

- **`PhotoKey = camera|file|datetime`** (`PhotoRecord.swift` L307-313) [R]:
  - Camera plus `DateTimeOriginal`, at 1-s resolution, collides in 6 groups covering 12 of 389 rows (3.1 %). Every one of those pairs is two distinct frames [L1].
  - Picker files get positional names (`001-photo.jpeg`), so three photos exist under two names and get two keys. Their intent tags do not carry over, and a capture check would count them twice [L7].
- **`PhotoRecord.id = path ?? file`** (L129): with `--no-paths`, two files named `IMG_0001.JPG` collide [L7].
- iPhone filenames wrap from IMG_9999 back to IMG_0001 [50] (UNVERIFIED by Apple documentation).
- **Picker identity:** at HEAD (1c199f5) the picker is created without `photoLibrary:` (`RootView.swift` L60), so `itemIdentifier` is always nil; the working tree now passes `photoLibrary: .shared()` (L62-64). Apple: "This value is `nil` if you create a Photos picker without a photo library" [17] (re-checked by the synthesiser).
- **The capture gate and the signature read the edited size** [L11][R]:
  - `PhotosImporter` gates on `PHAsset.pixelWidth × pixelHeight` (working tree L128). Apple documents that size as the current, edited version's [171].
  - 48 real captures with 8–20 MP originals fall below 5 MP only because they were cropped (median kept area 20 %). Today they are skipped on every run without being remembered; the draft's S1 would have written `not_capture` for them for good.
  - The signature (L133-134) is built from the same asset size, so it changes on every one of the 437 geometric edits in her library and a known edited asset is downloaded again.
- **Capture time** [R]:
  - `iqa/imageio.py` reads only `DateTimeOriginal`. Without it, it falls back to tag 306 `DateTime` (L99-111, L157), which is a modification time.
  - `results.json` carries no sub-second time and no offset.
  - The spec's ledger stores the time "read as UTC (EXIF has no zone)". Nothing clamps an implausible camera clock: today 0 of 389 rows are future-dated, and the earliest is 2013-05-17.

### 1.3 What one analysis costs

These are per-stage costs, medians with p90 in brackets, for 10 JPEGs and 4 HEICs at load average about 20 [L7]. Two independent benches agree on the shares [L4][L6].

| Stage | JPEG ms | HEIC ms | Share | Notes |
|---|---|---|---|---|
| `load_image` | 1,676 (1,982) | 2,020 (2,609) | 46 % | Within it: ICC→sRGB 671 ms (40 %), linearise + luma 461 ms (27 %), native clip count 213 ms, sRGB clip count 192 ms, **pixel decode only 56 ms (3 %)** |
| noise | 1,099 (1,546) | 1,447 | 34 % | |
| exposure | 292 (382) | 380 | 8 % | |
| structure | 201 (277) | 219 | 5–8 % | |
| edges + SFR | 171 (236) | 248 | 5 % | |
| **Total** | 3,608 (4,127) | 4,344 (5,203) | | [L4] measured 2,801 ms total for 12 photos of 12–24 MP. [L6] measured a 4.5 s median wall time (2.3–11 s under contention) |

**Wall-clock records.** The app's own logs on 15 Oct had a median `analysis_s` of 1.27–1.32 s (40 photos per run), a figure that excludes `load_image` [L7]. CLAUDE.md records 578 s for 389 images (1.49 s each) on the first library run [R].

**The current `results/results.json` (a later full run)** has `analysis_s` values summing to 15,508 s [L9]:
- **21 rows exceed 60 s and hold 14,734 s, or 95 %.** Thirteen of them are at 900 s or more, up to 1,063 s.
- The other 368 rows have a median of 1.99 s and a p90 of 3.01 s.
- This fits the Mac sleeping while `time.time()` kept counting (inferred, UNVERIFIED) [L6][L7].
- (One report said "22 rows at 900–1,063 s". The synthesiser's recount is 13.)

**Memory.** Peak RSS of one analysis in a fresh process:
- 1.65–1.69 GB for a JPEG; 2.81–2.94 GB for a 24 MP HEIC [L7]. Another bench measured 0.86–1.64 GB [L6].
- Peak traced numpy allocations: `load_image` 1,261 MB, noise 1,176 MB [L7].

**Overheads per run.**
- `import iqa.analyze` takes 0.30–0.72 s; `scipy.ndimage` alone is 322 ms [L6][L7].
- Charts cost 1.55–1.65 s of CPU per run; `iqa report` takes 2.5–4.3 s [L7][L6]. The app reads none of these outputs [L7].
- Inside the sandbox, matplotlib rebuilds its font cache every run, which costs 9.7–15 s [L6][L7][152].

**Determinism.** Analysing the same file twice, and analysing two byte-identical copies under different names, both gave **0 differing fields** [L7][L4]. The bootstrap is seeded (`uncertainty.py`, seed 0) [R]. This is what makes reuse keyed on content safe [70].

### 1.4 What a cache hit could cost instead

| Check | Cost | Source |
|---|---|---|
| `stat` (Python) / `URL.resourceValues` (Swift) | 1.4–1.9 µs / 6.3–11 µs | [L6][L2] |
| Size + first and last 64 KiB hashed | 0.056–0.13 ms | [L6][L7] |
| Full SHA-256 of a 4.8–5.2 MB file, warm cache | 1.66–2.4 ms (2.1–2.9 GB/s; hashlib and CryptoKit about equal). Heavy load cut this to 0.06 GB/s in one run | [L4][L6][L7][L2] |
| SQLite point lookup at 54k–100k rows | 5–13 µs median (p99 167 µs) | [L2][L6][L7] |
| Swift `Set` lookup on a 16-byte key | 51 ns | [L3] |
| Full analysis | about 1,600× a hash plus a lookup [L4]; 2–4.5 s in wall time | |

**Worked example.**
- Today, re-running 40 photos already seen costs a 176–184 MB copy and 2–3 CPU-minutes [L9][L10].
- With the asset-ID alias it costs 40 lookups, about 0.4 ms, and 0 bytes. **Corrected:** that holds only while L0 is enabled in those assets' stratum and the assets are already known.
- In strict mode, or where L0 is disabled, every asset must be read and hashed. At today's 17.5 % local share of the newest 40, that is 7 local reads (about 3 ms each) and 33 downloads (about 130 MB, median 0.555 s each); right after a prune sweep it is all 40 (184 MB) [L10].
- Via hashing local files only: about 0.1 s [L6][L7].
- With 5 new photos among the 40: about 23 s [L6].

### 1.5 RAM and load-time growth in the app (read from the code [R], sizes measured [L7][L6])

- **`ThumbnailStore`** holds a dictionary of 600 entries plus an `NSCache` with `countLimit` 600 and no cost limit, so it is bounded only by count. An 800-px entry is 1.875–1.92 MB, so the worst case is about 1.1 GB. The actor dictionary also holds strong references that block `NSCache` eviction.
- **`ClippingMaskStore`** and **`ContentIdentifier`** grow without limit, are never saved, and Vision re-runs after every launch.
- **`PhotoRecord`** stride is 912 B, plus 0.5–0.86 KB on the heap. That would be 76–97 MB at 54,000 records. `decodeAll` on 389 records takes 99.6 ms, which extrapolates to about 3–9 s per load at 54,000.
- **The library is replaced on every load** (`AppModel.swift` L71). Coaching weights every photo equally and has no recency anywhere.

---

## 2. Requirements as testable properties

Each property has a test in §6.3, where "T" numbers refer to that table.

| # | Property | Pass criterion |
|---|---|---|
| R1 | **Zero false-positive skip.** A stored measurement is reused only when SHA-256 of the bytes to be analysed equals the stored `content.sha256` *and* every analyzer-key component is equal (`==`). | Changing any single byte of a file (header, EXIF, quantisation table, entropy data, last byte) forces a re-measure. An edit that leaves a perceptual hash unchanged (blur σ 0.7) forces a re-measure. T1, T19 |
| R1a | **The download-avoiding alias is audited per stratum.** An L0 (asset-ID) skip is allowed only for PhotoKit `.photo` under the documented contract [1]. Re-hash audits are drawn per stratum (camera × source kind × local/cloud), and every re-download made for any reason counts as a cloud audit. | A mismatch disables L0 in its stratum only, is logged, and raises that stratum's audit rate to 10 % until 300 clean audits. Each stratum shows its own 3/n bound (rule of three [162]); a stratum with no audits shows "unaudited", never a bound. T2 |
| R2 | **A cache hit is O(1).** A hit costs one hash, or zero bytes on the alias path, plus one indexed lookup, independent of history. | Hit latency at 10³, 10⁴ and 10⁵ rows stays within 2× of each other and under 5 ms per photo, including the hash. A hit reads no file except the one being hashed. T3 |
| R3 | **Disk is bounded.** A re-run adds zero bytes. Each tier stays within its byte budget (§4.8). Originals at rest: only the reservoir, ≤ 256 MB per camera and ≤ 1 GB in total, purgeable. Live ledger rows are never evicted. The WAL stays bounded under the short-read rule. | Importing the same 40 photos twice gives 0 analyses, 0 new staging files and an unchanged DB page count. Filling the window, derivatives or reservoir past budget evicts down to budget. The ledger evicts only tombstones. T4, T5, T28, T29 |
| R4 | **RAM is bounded.** App caches are limited in bytes and count. List views are paged. The worker is recycled. At most 2 workers per machine, whatever the number of app instances and CLI runs. | Synthetic load: cache cost stays at or below its limit plus one entry. Worker RSS between images stays below its threshold. A second instance or a CLI run never starts a third worker. T6, T23 |
| R5 | **CPU is bounded.** Re-runs cost O(n) hashing at most. A version bump never triggers a blind whole-library re-measure. Each image has a CPU budget. Backfill stops when the camera's estimates are precise enough. | A `migration` bump re-measures nothing. A `pixel` bump re-measures the reservoir first, then window photos newest first, within the download budget. A runaway image is stopped at the budget; a timeout or failure becomes final only after a second attempt in a later run. T12, T22, T30 |
| R6 | **Advice is recency-weighted and independent of arrival order.** Weights depend only on capture time. A freshness gate pauses coaching for idle cameras. | Shuffled and sorted insertion give the same buckets to ≤ 10⁻¹² relative error. A synthetic step change is tracked within one half-life. T7, T11 |
| R7 | **Statistics are honest.** Every number carries n, n_eff and n_eff in days. Small-n rules apply. Quantile summaries have a stated error bound. | Weighted quantiles fall within α of the exact value. Interval coverage is at least 95 % on synthetic data clustered by session. T8, T9, T10 |
| R8 | **The Photos library is never modified.** Only read APIs are used, and nothing is written under the library package. | A static scan finds no `performChanges`, `PHAssetChangeRequest` or `PHAssetCreationRequest`. A file-system trace of an import shows no writes inside the library. T16 |
| R9 | **All input paths work, including `--no-paths`.** PhotoKit, picker (with and without an identifier), Analyze Folder and the CLI resolve the same bytes to one content row. With `--no-paths`, no exported file holds a path or locator, and `sha256` stays unless `--no-ids` is given. No store row holds a plaintext folder path, and the key of the keyed path hash is not in the database file. | T17, T18 |
| R10 | **Crash-safe and concurrent.** Killing the worker at any point and resuming gives the same final database. A Swift writer, a Python writer and a reader never fail a transaction. A second app instance, a damaged file or a full disk never loses committed measurements, never deletes another instance's staging, and never caches a negative entry. | T14, T15, T23, T24, T25 |
| R11 | **Versions never mix.** Aggregates combine only rows with the same analyzer era. A rollback also re-measures, because the rule is `==`. | T12 |
| R12 | **Forgetting is under the user's control.** "Forget photo / camera / before date", "Reset coaching" (which keeps the ledger) and "Clear cache" each state their consequence first. | T20 (UI) |
| R13 | **Renditions never mix.** Camera aggregates, percentiles and capture checks read only rows whose bytes are the original rendition (§4.2). | A cropped or exposure-edited pick is measured for its own screen, labelled "includes your edits", and leaves every aggregate unchanged. A capture cropped below 5 MP is still measured from `.photo`. T26 |
| R14 | **The decay clock is sane.** Capture time comes from `DateTimeOriginal` plus `SubSecTimeOriginal` and `OffsetTimeOriginal` when present. Tag 306 `DateTime` never stands in. No weight exceeds 1. | A future-dated or 1970-dated synthetic photo is flagged `clock_suspect` and gets weight ≤ 1 (0 in decay). A file with only tag 306 is undated. T27 |

---

## 3. Findings by topic

### 3.1 Fingerprinting: exact identity and near-duplicate grouping
**Decision supported:** an exact SHA-256 over the file bytes is the only key for skipping, and grouping of similar photos is a separate, advisory tier.

- **Exact hash choice** [L1][L4][L6][L7]:
  - **SHA-256 runs at 2.0–2.9 GB/s** on Apple M5 through OpenSSL/hashlib and CryptoKit.
  - BLAKE2b runs at 1.2–1.36 GB/s, BLAKE3's Python wheel at 1.42 GB/s on one thread, and MD5 at 0.67–0.92 GB/s.
  - XXH3 is 10–15× faster, but it "is not a cryptographic hash function" [82], and it would save only about 1.5 ms (0.06 % of an analysis).
  - BLAKE3's own figures [83] give no Apple numbers.
  - **Why SHA-256:** Swift and Python produce the same 32-byte key with no new dependency.
  - Birthday probability at N = 54,000: 7.9 × 10⁻¹¹ at 64 bits, 4.3 × 10⁻³⁰ at 128 bits, 1.3 × 10⁻⁶⁸ at 256 bits [L1].
- **A partial hash (size plus head and tail) cannot prove identity.**
  - imohash, which uses this design, says it is unsuitable for verification [84].
  - PhotoKit delivers resources as a sequential stream of chunks [13], so the tail cannot be read without the whole file.
  - Size is a perfect *negative* filter only.
- **Which bytes to hash** [L1][L8]:
  - A one-byte EXIF edit changes the file hash but leaves the hash over the JPEG coded data (SOS..EOI) unchanged. That hash takes 8.4 ms.
  - The analyzer reads ISO and exposure from EXIF, so a metadata edit *should* trigger a re-measure. The file hash is therefore the right key.
  - Decoded-pixel hashes depend on the decoder:
    - Pillow (libjpeg-turbo) vs ImageIO, JPEG: maximum difference 3–17 DN.
    - libheif vs ImageIO, HEIC: maximum difference 26–37 DN.
    - The two decoders gave matching 256×256 hashes in **0 of 11** files.
    - ImageIO inside vs outside the sandbox differed by up to 5–16 DN.
    - The libjpeg-turbo IDCT trade-offs explain why [86].
  - A SHA-256 of a 256-px downsample did **not** change after a one-pixel edit in 50 of 50 photos [L8].
  - In iPhone HEIC files, Exif (3,090 B) and XMP sit *inside* `mdat`, so a shortcut that hashes only `mdat` is not metadata-independent [L1].
- **Metadata identifiers are capture or asset IDs, not content IDs** [L1]:
  - `ImageUniqueID` was present in 0 of 50 files, although Exif 3.0 defines it [52].
  - Apple MakerNote `PhotoIdentifier` was present in 47 of 50, all unique. `ContentIdentifier` in 34 of 50. `BurstUUID` in 0 of 50 [51].
  - `SubSecTimeOriginal` was present in 49 of 50.
  - Photos' own fingerprint (`CPLResourceIdentity`) is private [98], and its column has been reported NULL [99]. On this library it is populated: `ZINTERNALRESOURCE.ZFINGERPRINT` equals `0x01 ‖ SHA-1("com.apple.XattrObjectSalt\0com.apple.DataObjectSalt\0" ‖ bytes)`, verified empirically on 124 files [L10]. It is undocumented, so it serves only as a research and CI instrument (§3.10).
- **Perceptual hashes on these files** [L1][L8]:
  - Burst frames 0.67 s apart had aHash 0, pHash64 0 and dHash64 4.
  - Only **dHash256** has a threshold with zero errors that also separates burst siblings: copies reach at most 23 bits (worst case a 1 %-per-side crop), cropped burst siblings start at 28, unrelated photos at 58, so T = 23–27 works on this set.
  - **Corrected (scope).** The set is 50 photos, 4 of them HEIC, with only 23 burst pairs. Zero errors in 23 pairs bounds the false burst-merge rate below about 13 % (95 %, rule of three [162]). The benign variants were re-encodes, resizes and crops of at most 1 % per side, not Photos edits. Against her own 1,000 real crop geometries, dHash256 ≤ 24 linked only 18 (§3.11).
  - pHash256 has no such window: same-photo copies reach 34 bits while burst siblings start at 24.
  - aHash falsely matched 1.02 % of unrelated pairs at ≤ 10.
  - PDQ at its standard threshold of ≤ 31 [88] caught 0 of 51 pairs taken within 60 s, and a 10 % crop moved it by a median of 88 bits.
  - Published thresholds (pHash T = 22 [94]; dHash "> 10 is different" [91]) are far too loose for burst-heavy phone libraries.
- **Perceptual identity is unsafe for skipping, measured** [L8]:
  - Blur σ 0.7 moved MTF50 by a median of −18.5 % (up to −31.7 %), while dHash64 and pHash64 stayed at 0–1 bits.
  - An unsharp mask moved it by +8.3 % (up to +13.7 %).
- **Apple Vision feature prints, revision 2** [27][28][L1][L8]:
  - 768 floats with unit L2 norm. Stored as Float16 it is 1,536 B (lossless on this Mac); int8 is 768 B with a maximum error of 0.0077.
  - Cost: 5–7 ms on a 512-px image, plus a model load of 48–376 ms on first use.
  - **No threshold separates "same photo" from "burst sibling":** benign same-photo variants reach 0.183, while burst siblings start at 0.155.
  - It is a good *scene* measure. Within ±60 s, a distance ≤ 0.50 matched 0 of 1,174 unrelated pairs and caught 24 of 51 related ones.
  - **The input pipeline must be fixed.** ImageIO `CreateThumbnailFromImageIfAbsent` returns the embedded 160/320-px JPEG thumbnail, and prints from it were a median 0.77 away from the full image. With a `MaxPixelSize` smaller than the embedded thumbnail it returned **all-black** images for 37 of 50 files [L8].
- **NeuralHash** is not a public API, and collisions have been crafted against it [95][96][97]. Rejected.

### 3.2 PhotoKit: identity, change tracking, pixels without hoarding
**Decision supported:** the asset ID is an alias, not the identity. Change tracking comes from the persistent change history. Bytes are streamed with network access off first. Thumbnails come from PhotoKit.

- **`localIdentifier` is device-local** [3]. An Apple engineer wrote in June 2026 that it "should not be considered for long-term persistence. These identifiers can change in the photo library under certain conditions" [6] (re-checked).
  - The same thread recommends storing the pair (local, `PHCloudIdentifier` [4]) and falling back to the cloud ID.
  - It notes that the conversion is "costly" and that deleted assets are "likely the only scenario" in which it fails [6].
  - Developers report identifiers changing after a device transfer [7].
  - Archiving a `PHCloudIdentifier` uses `archivalStringValue` on macOS 15.2+, or `NSKeyedArchiver` before that [12].
  - The mappings should be fetched in batches, "only once after loading from and before saving to persistent storage" [12][5].
- **`modificationDate` is a "maybe dirty" hint, not an invalidation key.** "Photos updates the modification date when an asset's image or video content or metadata changes" [2] (re-checked).
  - In DTS thread 793303 it is the *original poster* who says the date "often changes unexpectedly". The DTS engineer recommends "a content hash … access the raw image data using the PHAssetResourceManager class" [8].
  - (A researcher attributed the "changes unexpectedly" phrase to DTS; the synthesiser's re-read corrects that, and the conclusion is unchanged.)
- **Edits do not touch PhotoKit `.photo` bytes; other routes can deliver an edited rendition** (**Corrected**: the draft said "the measured bytes"). `.photo` "Provides the original photo data for its asset", and `.fullSizePhoto` "Provides a modified version of the original photo asset" [1] (both re-checked).
  - Exceptions named by the SDK: a RAW+JPEG primary switch, and capture-time adjustments such as Portrait or Night mode that are "preserved" on revert [12].
  - Measured [L10][L11]: no `.photo` fingerprint differs from its original-stable hash in 62,013 assets, including 705 edited stills; all 705 keep an original resource at the original pixel area and a separate full-size render; `ZORIGINALRESOURCECHOICE` is 0 everywhere, so no asset uses "Use RAW as Original".
  - Not measured: hashing `.photo` before and after an edit made on the device (Adjust Date & Time, Adjust Location, Revert). The audit (R1a) and the PickerProbe protocol (§6.2) cover it.
  - The picker, a third-party export saved as a new asset, and `PHAsset.pixelWidth` (the size of the current version [171]) can all deliver or describe an edited rendition (§3.11).
- **Change feed.** `fetchPersistentChanges(since:)` (macOS 13+) returns inserted, updated and deleted local identifiers. The token can be archived [9][10].
  - WWDC22: the token is "local to the device and is cheap to access" [11].
  - Errors 3105 (token expired) and 3210 (details unavailable) mean "refetch what you track" [11][12].
  - **The retention window is undocumented** (UNVERIFIED).
  - Because background analysis and iCloud sync generate many update entries [11], "updated" must not mean "re-measure".
  - **Limited access** (omitted by the draft): "if your app is in limited library mode, only changes for user-selected PhotoKit objects will be returned" [11] (re-checked by the finaliser). `PhotosImporter.authorize` accepts `.limited` (working tree L83) [R]. Under limited access an asset missing from a fetch is not proof of deletion, so it becomes `unavailable`, never `deleted`. The macOS SDK annotates `.limited` for iOS only, yet the Mac guide offers "access to only photos you select" [175][178][179]; whether macOS ever returns `.limited` is UNVERIFIED.
- **Free metadata.** `PHAssetResource` exposes `type`, `uniformTypeIdentifier`, `originalFilename` and pixel size [14]. `dataSize` exists only on macOS 27+, and there is no checksum API [12][14].
  - `requestData(for:options:dataReceivedHandler:)` streams chunks on a serial queue [13], so the app can hash while writing.
- **iCloud.** Request with `isNetworkAccessAllowed = false` first, and treat error 3164 (network access required) as "cloud-only, deferred" [12][157][158][159].
  - With Optimize Storage only "space-saving versions" are local [36], and the library "is optimized only when you need space, starting with the photos and videos you access least" [160][161].
  - **Answered** (draft: UNVERIFIED) [L10]: Photos keeps an app-downloaded original until its next space-driven sweep. All 13 on-demand downloads of 10-15 stayed local 72.3–72.8 h, until one sweep freed 18.8 GB. Across 787 pruned on-demand downloads, residency ran 72–2,074 h (median 86 days). App downloads got no protection. So a download grows her Photos library by its bytes until the next sweep.
  - Download latency: median 0.555 s for 2.3–7.9 MB, fitted as t ≈ 0.52 s + MB / 130 MB/s; per-request latency dominates.
- **Thumbnails cost the app no disk** through `PHCachingImageManager` [23][24], for grids.
  - Grids: `.opportunistic`, `.fast`, network off. A low-resolution derivative is acceptable there.
  - Overlays must align with the measured pixels, so request version `.unadjusted`. (`.current` renders edits, and `.original` returns the RAW of a RAW+JPEG pair) [12].
  - **Qualified:** for a cloud-only asset with network access off, whether `.unadjusted` comes back at overlay resolution, aligned with the measured pixels, is UNVERIFIED. It may fall back to a small derivative or to nothing. An overlay therefore checks the returned image's aspect against the `.photo` resource W×H, asks for the network only when the user opens that photo, and says so when it cannot draw.
- **Picker.** Pass `photoLibrary: .shared()` (macOS 13+) [18] so `itemIdentifier` is set.
  - **The documentation and DTS disagree** on whether read authorization is needed [18][19] (UNVERIFIED on macOS; test both states).
  - `.current` encoding avoids transcoding [20][167]; an Apple engineer: "Unless .current is specified, transcoding can happen" [170], so `.automatic` ("chooses the best encoding" [168]) may change the bytes; keep `.current`. For 13 of 13 unedited picks `.current` delivered the original bytes [L11].
  - **Qualified:** for an edited asset the picker reportedly returns the adjusted rendition even under `.current` ("current still returns the asset with previous adjustments applied", FB9706029, Oct 2021 [169], re-checked). No edited asset has been picked on macOS 26, so this is UNVERIFIED here. A picker identifier is therefore never an alias of picker bytes; an authorized pick goes through the PhotoKit path (§4.2).
  - Load through `FileRepresentation` rather than `Data` [21][22]; a ProRAW DNG is about 75 MB in RAM as `Data` [L11].
- **Folders.** `NSURLFileContentIdentifierKey` is an APFS content-stream ID [35]. Measured: a clone shares its source's ID, a byte copy gets a new one, and a 1-byte write changes it. Reading 4 resource keys costs 11 µs [L2].
- **Free space.** `volumeAvailableCapacityForImportantUsage` returned **0** inside the Claude Code sandbox, while `volumeAvailableCapacity` returned 351 GB [L2][33]. Unsandboxed it returned 325,569 MB (important) and 227,062 MB (opportunistic) for the home volume, but 0 for both keys on a mounted disk image with 298 MB free [L13]. Treat 0 or nil as "unknown". Apple's guidance: opportunistic capacity for predictive downloads, important capacity for requests the user made [33][166].

### 3.3 Bounded summaries: moments, decay, quantile sketches, exemplars, seen-set
**Decision supported:** fixed-mapping histograms in weekly, monthly and archive buckets, forward decay on capture time evaluated at query time, and an exact seen-index with no probabilistic filter.

- **What the summaries have to hold** (389-row run) [L3][L9]:
  - 19 cameras; photos per camera: 206, 85, 36, 21, 8, 8, 6, 5, then 1–2 each. Small n is the common case.
  - MTF50 is finite in 149 of 389 rows (38 %), with a between-image CV of 0.44–0.50 within an iPhone model. The per-image 95 % CI half-width has a median of 28 %.
  - SNR ranges over 18.3–50.5 dB.
  - `clip_high_pct` is zero-inflated with a heavy tail: median 0.42, p99 8.0, maximum 14.7.
  - DR has mass points at its lower bounds.
- **Sketch error must be small next to sampling error.** At n_eff = 100 the MTF50 median's 95 % CI is about ±11.5 % [L3].
- **Fixed-mapping histograms vs other sketches** (n = 20,000 smoothed bootstrap of the real MTF50 values) [L3]:

  | Summary | Bytes | Maximum median rank error | Guarantee | Merge | Weights |
  |---|---|---|---|---|---|
  | Log bins, α = 1 % (DDSketch mapping) [108] | 523 | 0.64 % | ≤ α relative, deterministic | exact, any order | yes |
  | KLL k = 200 [105][106] | 2,292 | 0.46 % | 1.65 % rank (two-sided), randomised | yes | Java 6.0 only [133]; Python none |
  | t-digest δ = 100 (DataSketches) [104][107] | 2,064 | 3.2–3.8 % | none; adversarial inputs push error arbitrarily high [109] | one-way | yes |
  | P² [110] | 5 markers per quantile | – | none | not mergeable | Boost variant |

  - Histogram updates cost 16.5 ns per photo per metric.
  - A median-plus-p80 query over 171 bins takes 0.56 µs (Swift -O, synthetic data).
- **Decay** [101][L3]:
  - Forward decay with g = exp(λ·) *is* backward exponential decay (Cormode et al. §III-A). Arrivals out of order need no special handling (§VI-B), and a decayed quantile is computable from weighted summaries (Thm 3).
  - Measured: 2,852 photos inserted shuffled vs sorted gave bin weights differing by 3 × 10⁻¹⁶.
  - Kish n_eff = (Σw)²/Σw² [102] equals 2.885·r·H for r photos a day and a half-life of H days. Simulated: 255.6 vs predicted 259.7 at 1 photo a day; 1,314 vs 1,298 at 5 a day.
  - EWMA control-chart practice (λ = 0.2–0.3 [103]) gives an n_eff of only 6.7–9. That is an alarm, not a coach.
- **Clustering** [102][121][L3]:
  - Photos taken in sessions inflate n_eff, with design effect 1 + (m̄ − 1)ρ.
  - Woodruff median-interval coverage, assuming ρ = 0.34, which was **not measured on this library**: 91.9 % using n_eff per photo vs 99.3 % using n_eff per day.
- **Tiered retention.** RRDtool, Thanos and Prometheus roll up *scalars* [113][114][115], and an average of medians is not a median. Buckets therefore hold mergeable histograms [116]. Simulated query-time decay over 38 buckets reproduced the exactly decayed median with **0.00 %** error, at 41 µs per camera [L3].
- **Seen-set.** Bloom [117], cuckoo [118], xor [119] and binary fuse [120] filters all have false positives, and a false positive is a photo silently and permanently skipped.
  - A 1 % Bloom filter filled incrementally to 54,000 entries averages a 0.166 % false-positive rate, so **about 90 photos would never be analysed**. Once full, it skips 100 of every 10,000 new photos [L3].
  - An exact index costs 1.7 MiB at 32 B per row [L3].
- **Exemplars** [111][L3]:
  - A recency-weighted Efraimidis–Spirakis reservoir (k = 16, 384 B).
  - Its random keys are derived from the fingerprint, so a re-import never changes the sample (the bounded researcher's own derivation, UNVERIFIED in the literature).
  - Plus best-1 and worst-1 per sealed month. No all-time heaps.

### 3.4 Content-addressed cache, invalidation and storage engine
**Decision supported:** SQLite in WAL mode with typed rowid tables, one analyzer key with an equality test and declared bump classes, library versions as provenance checked by a golden corpus, and early cutoff. (**Corrected**: the draft chose per-group versions and environment classes in the key.)

- **Build-system precedent.**
  - Bazel keys actions by hash. Tools outside the workspace are not tracked, so two users with different compilers can share wrong hits [68]. For iqa, the decoders (libheif, LibRaw, Pillow) are those tools. The draft put them in the key; the final design records them, re-runs the golden corpus when one changes, and turns any changed output into a `pixel` bump of the single key, as MEMORY-SPEC §3 does [R]. Keying on them would re-measure 54k photos for an upgrade that changes no output.
  - ccache `compiler_check` options include `content` and `string:` [69].
  - git's index caches lstat data with the racy-clean rule [73][74].
  - Nix content-addressed derivations give early cutoff [71][72].
  - *Build Systems à la Carte*: this cache is a deep constructive trace, safe only for deterministic tasks [70]. Determinism was measured in §1.3.
- **Versioning the analyzer** [L4]:
  - A single version number invalidates everything, and a forgotten bump serves stale numbers.
  - A hash of the whole module re-measures on docstring edits; this repo keeps ISO method notes in docstrings. That would cost about 42 h at 54,000 photos × 2.8 s (extrapolated).
  - **Draft choice:** per-group semantic versions, plus a pytest that hashes `ast.dump()` of each group with docstrings removed.
  - **Partial invalidation saves less than it looks, because `load_image` is 46 % of the cost.** A structure-only bump costs about 1.36 s instead of 2.8 s, so all of a photo's stale groups should be recomputed in one load.
  - **Final choice (Corrected), from the git replay [L10] and the ledger bench [L12]:** one analyzer key, the AST tripwire kept, and a declared bump class per bump (§4.5).
    - Module touches over-predicted changes: 4 transitions touched `imageio.py`, but only 1 changed every group; 076ef98 changed only `clip_low_pct`; 95bf2f1 touched `noise.py` and changed no noise output.
    - Per-group keys save CPU but not downloads, and on this library nearly every window photo is cloud-only.
    - The per-photo `measurement` table cost 338–341 B per photo, half the ledger. If per-group invalidation is ever needed, an 8 B era digest plus a stale-group mask on the content row costs +7 B.
- **Environment.** Library versions recorded today: numpy 2.5.4, opencv 5.0.0, Pillow 12.3.0, scipy 1.18.1, pillow-heif 1.8.1 / libheif 1.23.6, rawpy 0.27.1 / LibRaw 0.22.1 [L4]. A 20-photo canary set (about 1 minute) decides whether a new environment is equivalent to the old one; any differing output becomes a `pixel` bump (§4.5).
- **SQLite facts** [54][55][58][60][61][63]:
  - WAL lets readers and the writer run together. All processes must be on the same host.
  - The default checkpoint runs at 1,000 pages (about 4 MB). "If … there is always at least one active reader, then no checkpoints will be able to complete and hence the WAL file will grow without bound" [54] (re-checked).
  - `journal_size_limit` acts only "each time a transaction is committed or a WAL file resets" [55] (re-checked by the finaliser), so it does not cap growth while a reader holds a snapshot. Measured: 44 KB per photo transaction while a read is open (§3.14) [L14].
  - With `synchronous=NORMAL`, transactions "might rollback following a power failure or hard reset" [54] (re-checked). That is acceptable for a recomputable cache.
  - `auto_vacuum` must be set before the first table is created [55].
  - The WITHOUT ROWID rule of thumb is rows under about 1/20 of a page [58].
- **Bytes per row, measured at 54k–100k rows:**

  | Layout | B/row | Source |
  |---|---|---|
  | Fingerprint only (16 B hash index, date, version), WITHOUT ROWID | 140 | [L2] |
  | 24 typed coach scalars | 274 | [L4] |
  | 96 B summary blob plus secondary index | 287 | [L6] |
  | 71 fields packed as float32, unique sha index | 414 (22.4 MB at 54k) | [L7] |
  | 87 scalars, rowid / WITHOUT ROWID | 873 / 998 | [L4] |
  | Scalars + zlib detail, rowid / **WITHOUT ROWID** | 1,566 / **3,931** | [L4] |
  | Blob in a WITHOUT ROWID table | 4,662 | [L7] |
  | Whole record as JSON / JSONB | 6,048 / 5,913. JSONB saved 2.2 %; the documentation claims 5–10 % [59] | [L4] |
  | **Ledger per photo, measured as the app fills it** (one transaction per photo, never VACUUMed, after 5 era rewrites): draft §4.4 DDL / spec `memory_schema.sql` / lean layout | **666–677 / 527–531 / 338–341** | [L12] |

  The first rows above are single tables, so they are not ledger sizes. The draft quoted the 140–287 B rows as the ledger's cost; the whole ledger (content, sources, indexes, per-group rows) measures 2.3–4.8 times that [L12].

- **Detail compression.** Edges, noise curve and focus map take 2,041 B as JSON, 1,136 B with floats rounded to 4 significant digits, and **496 B after zlib** (median 350 B, maximum 2,288 B) [L4].
- **JSON vs SQLite at scale** [L4]:
  - 10⁵ records as one JSON file: 507.7 MB, 20.1 s to rewrite, 20.9 s and 962 MB to decode in Swift.
  - SQLite: point lookups 2.5–35 µs; scanning 5 columns of 100k rows 221–756 ms at a 30 MB peak.
  - `quick_check` on 54k rows: 13–21 ms on a ledger-only file. **Corrected:** on a 63.2 MB file holding every tier it cost 135–152 ms of CPU (292–2,062 ms wall), and `integrity_check` 314–345 ms [L13].
- **Eviction measured** [L4]:
  - Deleting the detail of all but the newest 2,000 of 54k rows took 73 ms.
  - A fully stepped `incremental_vacuum` then took 57 ms, shrinking the file from 77.5 to 48.4 MB.
  - **`PRAGMA incremental_vacuum` without `.fetchall()` reclaimed nothing**: the pragma frees pages only as it is stepped.
- **Cache policies.** ARC [126], W-TinyLFU [125], SIEVE [127] and GDSF [128] optimise hit ratio on long request streams. Here a miss is a deterministic re-measure and access follows "newest captures plus what is on screen", so an explainable recency-plus-pins rule fits better. SIEVE (a FIFO queue with one visited bit) suits the thumbnail cache.

### 3.5 Coaching: what to remember and how memory shapes advice
**Decision supported:**
- remember habits, not photos;
- compare her only with her own recent work;
- set landmarks in advance;
- bring a card back only when her behaviour changes;
- show what the coach remembers.

- **Feedback research.**
  - Feedback aimed at the person backfires. More than a third of feedback interventions *reduced* performance, and effectiveness fell as attention moved toward the self (607 effect sizes) [129].
  - High-information feedback reached d = 0.99, against 0.24 for plain reinforcement (435 studies) [130].
  - Shute: focus on the task, give elaborated feedback in manageable units, and make no normative comparisons [132].
  - Repeated reminders: each additional repeat was associated with about 30 % lower acceptance [141].
  - Broken streaks reduce engagement [140].
  - If-then plans have d = 0.65 [138] (second-hand).
  - Temporal landmarks raise goal pursuit [139].
  - Habit automaticity took a median of 66 days, with a range of 18–254 [137] (modelled; second-hand).
  - Apple's HIG for machine learning ("Prioritize recent feedback", "Let people correct their corrections") [48] and Microsoft's human-AI guidelines G8/G11/G12/G14/G16/G17 [142].
- **Tools.** Every tool found culls one shoot at a time: Lightroom Assisted Culling [143][144], Google Photos stacks [145], Photos Duplicates [47]. None keeps a per-camera history of technical outcomes, so that is IQ Coach's niche.
  - Lab practice: lead with *typical* performance and show the best only as a target [146][147][148]. Map differences to noticeability units where they exist (CPIQ JNDs [149]).
- **Measured on this library** [L5]:
  - A **58-byte** binary per-photo summary (16 B fingerprint, 2 B camera, 4 B time, 16 float16 fields, 4 B flags) replaces about 6 KB of JSON.
  - **Recency weighting changes little on a camera used only recently.** 17 Pro Max highlights: 26.2 % unweighted (Wilson 20.7–32.6 %) vs 26.3 % with a 90-day half-life (n_eff 194.8).
  - **Kish n_eff cannot tell how old a camera's photos are.** It does not change when every weight is scaled by the same factor. For the iPhone 13 it is 64.1 whether decay is counted from today or from the camera's last photo. The absolute weight sum W does distinguish them (25.8 vs 58.5).
  - **Decaying by time alone, with a short half-life, wipes out sparse cameras.** The D850's 36 photos spread over 1,073 days fall to n_eff 3.0 at a 30-day half-life.
  - **The "since <date>" trap.** 17 Pro Max highlights by month: Jun 1/6, Jul 25/89, Aug 11/48, Sep 12/50, Oct 5/13. Splitting at 1 Aug gives −2.1 points (−14.2 to +9.7); at 1 Sep, +1.1 (−11.1 to +14.8). Nothing changed, yet a search for the best split date would still announce a change.
  - **Bursts.** 35 groups within 10 s on the 17 Pro Max. In 11 of them one frame has more than 1 % of pixels blown while another does not, so highlight advice per burst is real. Only 2 burst groups have two frames with a sharpness figure, and both max/min MTF50 ratios (1.20 and 1.26) sit inside the ±30 % per-image band (FINDINGS §6). **"Frame 3 is sharpest" cannot come from natural-edge MTF50.**
  - **Fixed bins are accurate enough.** Percentile error (median / p95 / max points): `clip_high_pct` with 32 log bins 0.5 / 1.9 / 5.5; `snr_midgrey_db` with 1 dB bins 0.4 / 1.4 / 2.4. The sampling error of a median percentile at n = 206 is already ±6.8 points.
- **Current spec rule to replace.** A set-aside card returns when "`counted` has grown 25 % or more since it was set aside" (FEEDBACK-LAYERS-SPEC L659-660) [R]. That re-nags as photos accumulate even when nothing has changed [141].

### 3.6 Lazy, staged processing
**Decision supported:** short-circuit stages ordered by cost, a demand-ordered queue with a per-camera stopping rule, a long-lived worker, and an energy policy based on QoS.

- **How other tools avoid re-reading files.**
  - rsync's quick check uses size and mtime [78].
  - git applies the racy-clean rule [74]. APFS timestamps have 1 ns resolution, which narrows the race but does not remove it [L6] (via a secondary source).
  - FSEvents event IDs persist across reboots, with a rescan on `MustScanSubDirs` [79]. Watchman reports `is_fresh_instance` [80].
  - Lightroom Classic flags a suspected duplicate by filename, capture time and size [81]. That is today's `PhotoKey` problem, and it misses renamed files.
- **Incremental computation.** Salsa "backdates" a re-run whose result is unchanged [75]. rustc runs try-mark-green [76]. Adapton computes on demand [77]. **For iqa:** key each content by (content, analyzer era); re-measure a photo in one load when its era is stale; if a re-run gives the same rounded summary, leave the aggregates alone. (The draft keyed each group separately; §4.5 explains why the final design does not.)
- **Cheap stages that are not worth it** [L6][L7]:
  - JPEG `draft` at 1/8 scale is only 1.5× faster than a full decode (36 vs 53 ms), because entropy decoding dominates [153].
  - These HEIC files have no embedded thumbnail, so downsampling costs a full decode (267 ms).
  - EXIF thumbnails drift by up to 41 bits of dHash256 from the full decode [L8].
- **Stopping rule** [L6][L3]:
  - Bootstrap 95 % half-widths of the per-camera median at n = 30: SNR ±1.6–3.6 dB; MTF50 p80 ±11–28 %.
  - Stopping when the SNR half-width is under 1.5 dB and the MTF half-width under 10 % takes about 30–60 images per camera for SNR and 100–150 for MTF, not thousands.
  - The bounded researcher's figure agrees: n_eff ≥ 133 photos *that yield MTF50* gives ±10 %.
- **Worker.**
  - Recycle by count, as `max_tasks_per_child` does [67].
  - At most 2 workers per machine (the batch lease, §4.9), each pinned to one internal thread (`OMP_NUM_THREADS=1`, `cv2.setNumThreads(1)`, pillow-heif `decode_threads=1`; its default is 4 [154]).
  - The metric stages already use 1.4–1.7× CPU per wall second [L6].
- **Energy.**
  - Background QoS runs only on efficiency cores [43] (third-party measurement).
  - Measured: `taskpolicy -c background` was 1.6–1.9× slower and `-c utility` 1.4–1.6× slower [L6].
  - A run the user starts uses `.utility` [37][38] plus `beginActivity([.userInitiated, .idleSystemSleepDisabled])` [40], which also prevents the sleep outliers of §1.3.
  - Backfill uses `NSBackgroundActivityScheduler`, checking `shouldDefer` [39].
  - Pause at `thermalState ≥ .serious` [41] or in Low Power Mode [42]. This matters on a fanless Air.
- **A free speed-up, separate from memory:** a 256-entry lookup table for `srgb_decode` is **bit-identical** (max |Δ| = 0.0) and saves 0.28–0.39 s per 24 MP image [L6]. It is a measurement-code change, so it needs its own test and its own commit.

### 3.7 Profile and integration points (code map [R], measured [L7])
**Decision supported:** where the memory layer hooks in, and what breaks once copies are deleted.

**Where to hook in**, in order:
1. `PhotosImporter` L80-87, before `writeResource`. Today the download happens *before* the capture filter at L88-93.
2. `export(picked:)` L111-118 and the picker call in `RootView` L60-61.
3. `AnalyzerRunner` L50-52: pass only misses. The CLI already has `--list`, cli.py L38-41.
4. `cmd_analyze`'s loop.
5. Write each record as it finishes; today everything is written at the end (L69-72).
6. `AppModel` L71: merge results instead of replacing the library.
7. `PhotoKey` and `PhotoRecord.id`.
8. `AfterRow.path`.
9. `ThumbnailStore`, `OverlayImage` and `ContentIdentifier`: read stored derivatives.

**What breaks when copies are deleted.** Every feature that draws pixels:
- thumbnails;
- overlays (clipping, focus map, subject box, horizon), which are drawn only inside `if let img`;
- Vision content identification;
- "What you photograph";
- recent strips;
- snapshots.

No measured number changes. Hence the derivatives tier in §4.8.

**Slim derivatives**, measured sizes:

| Derivative | From JPEG sources | From HEIC sources |
|---|---|---|
| 256 px HEIC thumbnail, quality 0.6 | 5.9 KB | 8.6 KB |
| 800 px HEIC preview (Display P3), quality 0.6 | 61 KB | 63 KB |
| 800×600 greyscale PNG clipping mask, median (max 17.2 KB) | 8.1 KB | 6.4 KB |

The clipping mask must be computed **from the original at analysis time**. Re-encoding the preview as JPEG at quality 0.7 changed the blown-pixel count by 0.1–35 % for JPEG sources and 15–116 % for HEIC sources [L7].

### 3.8 Perceptual-hash benchmark: what may and may not decide a skip
**Decision supported:** exact byte hash for skipping; dHash256 at T = 24 for "another copy of the same photo"; time-gated grouping.

- **Benchmark setup** [L8]:
  - 50 unique photos: 39 iPhone 17 Pro / Pro Max JPEG/MPO, 4 HEIC, 2 D850 and others.
  - 41 of the 46 JPEGs carry an EXIF Orientation other than 1.
  - 23 of the 1,225 pairs fall within 10 s ("burst").
- **Zero-error thresholds** (benign copies vs different photos, cross pairs included):

  | Hash | Benign same-photo max | Different, far min | Different, burst min | Zero-error threshold including bursts |
  |---|---|---|---|---|
  | aHash64 | 5 | 3 | 0 | none |
  | dHash64 | 6 | 9 | 2 | none |
  | pHash64 | 4 | 12 | 0 | none |
  | **dHash256** | **23** | 58 | **28** | **23–27** |
  | pHash256 | 34 | 96 | 24 | none |

- **Orientation.** Stripping EXIF Orientation rotated the displayed image in 43 of 46 JPEGs and broke every perceptual hash. Matching the best of 4 rotations (about 0.26 ms) brings dHash256 back to at most 6 bits without lowering the different-photo minima.
- **Degenerate decodes.** An all-black image hashes to all zeros and "matches" every other failure. Reject any 256×256 greyscale image with SD < 1 DN as a decode failure.
- **Cost inside `iqa analyze`**, where the image is already decoded: about 11 ms for the 256×256 greyscale plus 65 µs for the hash. A brute-force scan of 54k 256-bit hashes takes 1.45 ms in numpy.
- **Statistical limit.** 0 collisions in 1,202 far pairs bounds the per-pair rate below 0.25 % (95 %). At 54,000 photos (1.46 × 10⁹ pairs) the real risk is same-scene re-shoots, so **all near-duplicate queries are gated by camera and capture-time window**.
- **Corrected (burst side).** Only 23 burst pairs were tested, so the 95 % upper bound on merging burst siblings at T = 24 is about 3/23 = 13 % [162]. The "benign" side held only re-encodes, resizes and crops of at most 1 % per side. Real Photos crops (median kept area 44 %) and straightens move dHash256 far past 24 (§3.11), so dHash256 can link tone edits but not geometric ones, and it never decides that two files are one capture on its own.

### 3.9 Where the researchers disagreed, and the resolution

| # | Disagreement | Evidence | Resolution |
|---|---|---|---|
| D1 | **Decay clock.** Coaching wanted count-based decay (H = 100 photos) plus a calendar freshness clock. Bounded wanted capture-time forward decay. | Count ranks shift when older photos are backfilled, and count-based weights are not a sum over buckets. Time-based forward decay is exact under any arrival order (3 × 10⁻¹⁶ measured) [101][L3]. Coaching, though, showed that time-only decay at H = 30 d leaves the D850 with n_eff 3.0 [L5]. | **Time-keyed decay with an adaptive half-life per camera** (§4.7) gives count-like evidence for sparse cameras and stays mergeable. **Keep coaching's freshness clock** (last capture age plus W), because Kish n_eff is invariant to scale and cannot detect staleness [L5]. |
| D2 | **What the PhotoKit fast path compares.** Fingerprint: `localIdentifier` + `modificationDate`. PhotoKit: never invalidate on `modificationDate`; compare the resource signature instead. Lazy: date first, then signature. | `modificationDate` changes on metadata [2]. `localIdentifier` can change [6]. DTS recommends a content hash [8]. Whether `.photo` is immutable is UNVERIFIED. | Date equal: hit. Date changed but signature equal: refresh metadata only. Signature changed: hash. Treat `localIdentifier` as an alias. **Add a re-hash audit (R1a)** and a strict mode. **Final round:** the signature comes from the `.photo` resource, not the asset size (§3.11); the audit is stratified (§3.10); a cloud alias is optional (§3.12). |
| D3 | **Near-duplicate signal.** Fingerprint: Vision rev2 best; dHash64 ≤ 10 as fallback. Benchmark: only dHash256 separates copies from burst siblings; Vision has no separating threshold. | The two studies defined "unrelated" differently (> 60 s vs > 10 s). Pairs 22–46 s apart count as "far" in one and "related" in the other. Both found 64-bit hashes merge burst frames [L1][L8]. | **Two questions, two signals.** dHash256 ≤ 24 answers "same photo, re-encoded or tone-edited". Vision ≤ 0.50 within ±60 s answers "same scene". dHash64 is dropped: it costs 24 B less per image and loses the burst separation. **Final round:** capture links are exact (capture_id); dHash only breaks ties between tone edits (§3.11). |
| D4 | **WITHOUT ROWID.** PhotoKit's schema used it for the wide content table. | 2.5× the bytes for wide rows (3,931 vs 1,566 B/row) [L4]; 4,662 vs 414 B with a blob [L7]; SQLite's own rule [58]. | WITHOUT ROWID **only for narrow tables** (`source`, `era`, `ring`, `reservoir`). |
| D5 | **Size of the detail window.** Proposals: newest 500 (PhotoKit), newest 2,000 (cache), 1,000 per camera (coaching), N per camera (profile, lazy), a 64-row ring (bounded). | 32 MB covers about 35,000 photos of summary plus detail (414 + 496 B), so the byte budget does not force a small window. The goal (focus on current work) does. | **500 newest per Active camera, 64 per Resting camera, plus pinned and recently viewed photos, under a 32 MB hard cap** (§4.8). The cap applies to the window only, never to the ledger (§3.12). |
| D6 | **Stored previews.** PhotoKit researcher: 0 B, served by PhotoKit. Profile: about 80 KB per photo, 160 MB LRU. | PhotoKit can render `.unadjusted` thumbnails at no disk cost [23][12]. Folder and identifier-less picker sources cannot. The clipping mask must come from the original [L7]. | **Mask stored for every analysed photo; 256 px thumbnail and 800 px preview stored only for non-PhotoKit sources**; a 64 MB Caches budget. Whether PhotoKit renders a usable `.unadjusted` overlay image for a cloud-only asset with network off is UNVERIFIED (§3.2). |
| D7 | **Cross-process protocol.** Cache: Python writes SQLite directly. Lazy: a JSON-lines `serve` worker. Profile: JSON Lines records plus `--list`. | SQLite with `BEGIN IMMEDIATE`: 0 of 6,000 failures, versus 52 % with deferred read-then-write [L4]. Process start costs 0.3–0.7 s; charts 1.55 s CPU [L6][L7]. | **Both:** control over `serve` pipes, data in SQLite. The Python worker owns the measurement tables (§4.9). **Final round:** the Swift writer was tested against the Python writer: 0 failures in 9,000 + 9,000 transactions [L14]; every writer also takes the `memory.lock` lease [L13]. |
| D8 | **"Decode is 44 %" (cache) vs "pixel decode is 3 %" (profile).** | The cache researcher's "decode" is the whole of `load_image`: ICC 40 %, linearise 27 % [L7]. Pixel decode is 53–65 ms for JPEG and 244–311 ms for HEIC [L7][L8]. | Same data, two names. **The conclusion holds: recompute every stale group in one load.** |
| D9 | **Seconds per image.** 1.49 s (first run), 2.0 s (`results.json` median), 2.8 s (12-file bench), 3.6–4.5 s under load. | Load varied from 17 to 650. | Use **2.0 s median / 3.0 s p90** (368 rows, [L9]) as typical and 2.7–2.8 s for 24 MP. All stage *ratios* agree. |
| D10 | **Slow rows.** "22 rows at 900–1,063 s" (profile) vs "21 rows > 60 s" (lazy). | Recount [L9]: 21 rows > 60 s, totalling 14,734 s; 13 rows ≥ 900 s. | Lazy's figure stands. |
| D11 | **Library makeup.** The task said "54,000 captures from 19 devices". | FINDINGS: about 54,000 captures from 55 camera models (D850 about 27,000). 19 is the count for the 389-image run [R]. | Treat the 258 GB full-library estimate as a lower bound. |
| D12 | **Peak RSS for HEIC.** 1.64 GB [L6] vs 2.81–2.94 GB [L7]. | Different files and conditions. | Budget on the larger figure (≤ 2 workers on 16 GB). |
| D13 | **Per-photo summary kept forever?** Cache: 274 B per photo forever. Bounded: only the 32 B seen-index grows with photo count. | Both are small. The goal favours not keeping detail about past work. | **The ledger keeps 8 float16 headline values (16 B) forever. The full summary lives in the window.** |
| D14 | **Cache key.** Draft: per-group versions with decoders in the key (Bazel precedent). MEMORY-SPEC §3: one `MEASUREMENT_VERSION`, library versions recorded in `meta` as provenance only. | Replay of 11 measurement commits: per-group keys save CPU but no downloads; module touches over-predict changes; the per-photo `measurement` table is half the ledger [L10][L12]. Determinism across library upgrades is untested. | **The spec's single key**, plus a declared bump class per bump checked by the golden corpus, and a corpus re-run on any library upgrade (§4.5). |
| D15 | **Originals at rest.** Draft: 0 B. iCloud follow-up: a bounded reservoir. | 99.9 % of captures are cloud-only; app downloads leave at the next sweep; 10 analyzer transitions in 10 days; FINDINGS §8–9 already could not re-measure the 389-photo run because its originals had been pruned [L10][R]. | **No hoarding, plus a reservoir** of 64 per Active camera, ≤ 256 MB per camera, ≤ 1 GB total, purgeable (§4.8). |
| D16 | **Ledger size.** Draft: 140–287 B per photo, ≤ 16 MB at 54k. Spec: about 200 B. | Measured as the app fills it: 666–677 B (draft DDL), 527–531 B (spec), 338–341 B (lean) [L12]. The draft's figures were single-table benches. | **Lean layout** (§4.4). Budget from incremental sizes, never from VACUUMed ones. |
| D17 | **On an audit mismatch.** Draft: disable L0 everywhere. Follow-up: disable the stratum. | At today's 17.5 % local share a global disable costs about 33 downloads (about 130 MB) per newest-40 import, more than the draft's whole per-session budget; expected exceptions (RAW+JPEG primary switch, Portrait) would trip it [L10]. | **Per stratum**, with a raised audit rate until 300 clean audits (§4.2). |
| D18 | **Who may write, and how many workers.** Draft: "≤ 2 workers", per instance. Spec: the analyzer is the only writer. | No lease exists. Two instances plus a CLI would allow 5 workers (6–15 GB of RSS on a 16 GB Mac); one instance's launch sweep deleted the other's staging in 12 of 12 trials, and a good photo was cached as `failed` [L13]. | **`flock` leases**: one writer at a time, one importing instance per user, ≤ 2 workers per machine (§4.9). |


### 3.10 The iCloud-optimised library: availability, retention, byte stability, bump frequency, restore cost [L10]
**Decision supported:** a bounded re-measure reservoir instead of "0 B of originals", measuring on arrival, a per-day download budget, a stratified audit, and invalidation by output diff.

**Method.** No PhotoKit probe could run from the research session: `PHPhotoLibrary.authorizationStatus(.readWrite)` returned 2 (denied) for any binary started there, and the ad-hoc-signed debug app's grant does not carry over to a rebuilt probe. The study therefore read the state PhotoKit reads:
- an APFS clone of `Photos.sqlite` plus its WAL, opened read-only and deleted afterwards; the library itself was never written;
- the timestamps and hashes of IQ Coach's own 93 copies.

Validation: `ZLOCALAVAILABILITY = 1` matched a file on disk for 30 of 30 captures. A reconstruction from the download, prefetch and prune dates gave 1,044 local originals at 2026-10-13 08:29, against 1,035 in `photo_list.txt` (1,034 names overlap). A read-only probe for a live re-run is built (§6.2).

**Availability.** Population: 53,257 captures under the app's own rule, at 2026-10-26 03:21 EDT.

| Sample | Local | Cloud-only (error 3164 with network off [157][158][159]) |
|---|---|---|
| Newest 40 | 7 (17.5 %) | 33 |
| Newest 400 | 30 (7.5 %) | 370 |
| Newest 4,000 | 30 (0.75 %) | 3,970 |
| Random 1,000 (seed 1) | 1 (0.1 %) | 999 |
| All 53,257 | 30 (0.056 %) | 53,210, plus 17 neither local nor uploaded |

The local share of the newest 400 swings with prune sweeps: 66 % (10-01), 71.5 % (10-15), 74 % (10-17), **0 % after the sweep of 10-18**, 7.5 % today. Every local original is under 31 days old, and all are iPhones.

**Latency and retention.**
- IQ Coach's own import of the newest 40 at 2026-10-15 00:05 EDT: 29 local, cloned by `writeData` in a median 4.2 ms (max 7 ms); 11 downloaded sequentially in 0.477–0.676 s each (median 0.555 s, 11.3 MB/s aggregate). Fit: t ≈ 0.52 s + MB / 130 MB/s. Picker, 10-23: 0.53–0.77 s per file.
- Eleven minutes later all 40 were local; the re-export took 2.1 ms per file.
- The 13 on-demand downloads of 10-15 survived until one library-wide sweep at 2026-10-18 00:18–00:52, 72.3–72.8 h later. That sweep freed 18.8 GB: 1,081 photo originals (2.39 GB), 265 Live Photo videos (1.12 GB) and 21,229 derivatives (13.8 GB). Across all 787 pruned on-demand downloads, residency ran 72–2,074 h, median 86 days.
- The 10-23 picker run added exactly its 6 originals (27.5 MB, byte-identical) to the library's `originals/`. A download therefore grows her Photos library until the next sweep.

**Byte stability.**
- The Photos database holds iCloud's own content fingerprint for every original: `ZINTERNALRESOURCE.ZFINGERPRINT` = `0x01 ‖ SHA-1(salt ‖ bytes)`, found by testing and verified on 124 files. No public documentation describes it.
- 93 of 93 retrievals of 50 distinct assets matched it: PhotoKit `writeData` and the picker with `.current`, 13 fresh iCloud downloads and 80 local reads. 95 % upper bound per retrieval: 3/93 = 3.2 % [162].
- 31 of 31 local originals matched. One asset (IMG_0446) completed a full cycle with identical SHA-256: prefetched 10-13, exported 10-15, pruned 10-18, re-downloaded 10-23.
- No `.photo` fingerprint differs from `ZORIGINALSTABLEHASH` (0 of 62,013), including the 705 edited assets. 24,916 D850 assets carry a separate RAW resource.
- The library holds 107 redundant byte-identical originals in 97 groups; content keys remove those re-measures.

**Git replay on a golden corpus.** 20 canaries (2 D850, 4 iPhone 17 Pro, 13 iPhone 17 Pro Max including 3 HEIC, 1 iPhone 13 mini HEIC) plus the 4 `iqa demo` scenes, generated once because `synth.py` itself changed, run at all 11 commits touching measurement modules and at HEAD.
- Determinism: HEAD against 95bf2f1, identical code, gave 0 differing fields at load average about 100.
- 10 transitions in 10.1 days, in bursts on 3 days (10-13: 5 in 21 h; 10-15: 3 in 36 min; 10-23: 2 in 1.5 h). All 10 changed some output, 7 changed existing values, 6 needed pixels, and 1 (bd6b877, the thirds-distance rescale) was derivable from stored columns.

  | Group | Commits changing values | Adding or removing fields | Either |
  |---|---|---|---|
  | meta | 1 (`format` jpg→jpeg, derivable) | 1 | 2 |
  | sharpness | 3 | 4 | 5 |
  | noise | 2 | 3 | 4 |
  | exposure | 4 | 2 | 4 |
  | structure | 2 | 1 | 3 |

- Changes are heterogeneous. At 47fcb2f, MTF50 moved by a median +3.9 % (sd 10.6 %, up to +29.7 %, 2 NaN↔value flips); SNR by a median −0.46 dB, but 5 of 15 canaries fell 6.6–21 dB. At 0a1473e, `clip_low_pct` rose by up to 53.9 points, and 076ef98 reverted it.
- This has already cost data: FINDINGS §8–9 (10-23) could not re-measure the 389-photo run because its originals were pruned on 10-18; fixes were back-filled from stored columns and 328 rows stay stale "until the next full run" [R].

**Restore cost after a pixel bump** (window as in §4.8: 500 newest per Active camera; actual `.photo` sizes):

| Active camera | Window (cloud-only) | GB to download | Sessions at 20 / 100 / 500 photos |
|---|---|---|---|
| iPhone 17 Pro Max | 500 (472) | 1.85 | 24 / 5 / 1 |
| iPhone 12 mini | 500 (500) | 1.03 | 25 / 5 / 1 |
| iPhone 13 mini | 245 (244) | 0.58 | 13 / 3 / 1 |
| iPhone 17 Pro | 81 (80) | 0.49 | 4–5 / 1 / 1 |
| **All 4, shared budget** | 1,326 (1,296) | **3.94** | **65–67 / 13–14 / 3–4** |

- Resting cameras (7): 335 photos, 2.23 GB. The D850, if it becomes Active: 6.84 GB, 69 sessions under the draft's 100 MB cap.
- Time is not the limit: the full Active restore is about 12 min of downloading plus 44 min of analysis at 2.0 s a photo. The draft's per-session budget is: at one session a day, 65 days for all four cameras. During development a pixel bump came every 1.7 days, so the window would never restore.
- If nothing is downloaded, new captures refill the window; reaching the coaching threshold (30 photos, 10 capture days) takes about 16 days for the 17 Pro Max and about 180 days for the other three.

**The reservoir alternative** (64 originals per Active camera, uniform over the window, Algorithm R [111]):
- Disk: 270, 152, 150 and 385 MB, about 957 MB for the 4 cameras. A D850 reservoir would be 0.85–1.05 GB, so the cap is in bytes (256 MB per camera, about 16 D850 photos).
- Per bump: 0 downloads and 256 local re-measures, about 8.5 CPU-minutes (4.3 on 2 workers). Coaching resumes at n = 64 at once.
- Paired old/new values give each metric's era shift: for a 47fcb2f-like change with about 26 valid MTF50 photos, the mean shift comes out to about ±4 %, and the share of large SNR drops to about ±13 points.
- Its disk equals about 24 % of one full Active restore's downloads.

**Why the draft's audit bound did not cover the risk.** 97.7 % of Active-window rows (100 % right after a sweep) are cloud-only. The local stratum was 30 recent iPhone photos, empty after 10-18, and the same newest assets recur across sessions, so the audits are neither independent nor representative. The highest-risk stratum, RAW+JPEG D850 (24,916 assets), is never local.

### 3.11 Edited photos, picker renditions, and the capture gate [L11]
**Decision supported:** a rendition flag on every content row, the picker routed to PhotoKit when authorized, the capture gate on the `.photo` resource size, exact capture links.

**Not run:** the on-device matrix (picker × encoding policy × four authorization states × prepared edits). It needs a person picking photos, a disposable library and changes to an app's Photos privacy state. Switching her System Photo Library turns off iCloud Photos, and turning it back on merges libraries irreversibly [180], so the protocol uses a separate macOS user account (§6.2). Privacy-state changes are hers to make. A harness, `PickerProbe.app`, is built.

**Run, read-only:** the 13 picker deliveries already on disk; a copy-on-write clone of `Photos.sqlite` (7.3 GB, 0 extra bytes) and the library's 3,974 adjustment plists; a dHash256 simulation on the 50 distinct photos with 1,000 real crop geometries taken from her own edits.

**A. Unedited picks under `.current` delivered the original bytes, 13 of 13.** 8 are SHA-256-identical to the original (three match PhotoKit `.photo` exports, five match the library's own files, one a depth-captured HEIC with no effect applied); the other 5 have exactly the original's byte count, one of them the JPEG half of a D850 RAW+JPEG pair. All 13 carry `DateTimeOriginal`, `SubSecTimeOriginal` and `OffsetTimeOriginal`; the 11 iPhone files also carry MakerNote `PhotoIdentifier` (tag 0x002b [51]), the 2 D850 files do not. No edited asset has been picked, so FB9706029 [169] is untested on macOS 26.

**B. Edits in her library.**
- 66,268 stills; 705 adjusted (654 by her, 51 by the camera), 1.06 %; 549 of the 56,776 stills with an original of 5 MP or more.
- Newest 500 captures: 11 adjusted (2.2 %), 10 of them Portraits whose depth effect the camera applied.
- Crops: 391 stills; the median crop keeps 44 % of the area (p10 23 %, p90 75 %); 80 also straighten (median 2.6°). 437 of the 705 edits changed the pixel area.
- All 705 adjusted stills keep a separate full-size render whose area equals the current size (437 of 437 geometric edits), and the original resource keeps the original area (705 of 705): the database counterpart of `.photo` versus `.fullSizePhoto` [1].
- Portraits: 39 renders (106.7 MB) sit beside 39 originals (131.6 MB). That implies, but does not prove, that `.photo` is the Portrait without the rendered blur (risk 13).

**C. The capture gate reads the edited size.** `PHAsset.pixelWidth` describes the current version [171]. The stored current area equals the original area for 65,563 of 65,563 unedited stills and differs for the 437 geometric edits. 48 captures with 8–20 MP originals are now below 5 MP (median kept area 20 %, maximum 64 %). Fix: read W×H from the `.photo` `PHAssetResource`, public since macOS 13 [172]; build the signature from the same resource.

**D. The picker without authorization.** `itemIdentifier` is nil without a photo library [17], and the plain PHPicker `init()` "never returns asset identifiers" [175]. DTS says creating the picker with a library needs read authorization [19]. WWDC20: the picker never prompts, and fetching assets by identifier needs library access [176]. PhotoKit prompts automatically on the first operation that needs authorization [177], so a fetch while the status is notDetermined changes the state; the working tree's guard (L186) prevents that. Under limited access, picking a photo does not add it to the app's accessible set [176], so a fetch can come back empty.

**E. dHash256 against edits** (50 photos; 46 JPEG, 4 HEIC; each decoded once and box-reduced 4×):

| Edit | Median bits | Max | ≤ 24 |
|---|---|---|---|
| JPEG re-encode, q90 | 1 | 7 | 50/50 |
| −1 EV / S-curve / +0.5 EV | 4 / 5 / 7 | 13 / 17 / 17 | 50/50 each |
| +1 EV | 13 | 36 | 42/50 |
| Centred crop keeping 98 % (1 %/side) | 8 | 19 | 50/50 |
| Keep 90 % / 60 % / 40 % / 10 % | 34 / 106 / 118 / 125 | 50 / 136 / 153 / 158 | 5 / 0 / 0 / 0 |
| Straighten 0.5° / 1° / 2.6° / 5° | 12 / 21 / 53 / 87 | 27 / 32 / 64 / 106 | 48 / 35 / 1 / 0 |
| 1,000 real crop geometries (20 per photo) | 117 (p10 74) | 166 | 18 (1.8 %) |

954 of the 1,000 real crops land at ≥ 58 bits, the draft's range for unrelated photos. The reduced pipeline differs from a full decode by a median of 3 bits (max 19), so values within about 20 bits are approximate. A cropped pick and its PhotoKit original would count twice if dHash had to confirm the link, and the crop would count against the camera's framing and clipping figures.

**F. Edits already inside `.photo`.** 1,020 stills were saved by `com.adobe.lrmobile` (959 of 5 MP or more). Example: IMG_6308.JPG names a D850, `Software` reads "Adobe Lightroom 11.3.1 (iOS)", and at 4,883 × 3,251 it is consistent with a crop of the 5,408 × 3,600 frames shot that same second. PhotoKit reports it as unedited, and run 20261015T043403 measured it as a D850 capture.

**G. RAW+JPEG.** 25,326 stills have a RAW alternate resource; none uses "Use RAW as Original". The macOS 27 SDK adds `PHAsset.originalResourceChoice`; macOS 26 has no public equivalent [12].

### 3.12 Ledger bytes, measured from both schemas [L12]
**Decision supported:** the lean ledger layout, no per-photo `measurement` rows, and a retention rule that never evicts a live row.

**Method.** SQLite 3.53.4 (Homebrew Python 3.14.7) with the draft's settings (page 4,096, `auto_vacuum=INCREMENTAL`, WAL, `synchronous=NORMAL`, `foreign_keys=ON`). One `BEGIN IMMEDIATE` per photo, newest capture first, never VACUUMed, then 5 era rewrites; `dbstat` per B-tree [183] after each; `VACUUM INTO` for the compacted size [187]. Row values bootstrapped from the 389 records; 1,035 real asset UUIDs from `photo_list.txt` (all RFC 4122 v4) give a 43 B `localIdentifier` (`UUID/L0/001`). Commit grouping did not change page counts. The critic's VACUUMed files re-read at 594.9 and 715.7 B per photo; the same DDL VACUUMed after 5 eras gives 615.5 B here, the difference being `version` values above 1, which need a byte where 1 needs none [64].

| Variant | B/photo at 10k / 54k / 110k | MB at 54k / 110k | VACUUMed, 54k |
|---|---|---|---|
| Draft §4.4 as written | 666.0 / 671.7 / 677.0 | 36.3 / 74.5 | 615.5 |
| + eager cloud alias (100 B text, length UNVERIFIED) | 799.1 / 807.4 / 814.4 | 43.6 / 89.6 | 736.4 |
| + `source(content_id)` index (needed) | 725.8 / 731.2 / 736.6 | 39.5 / 81.0 | 668.6 |
| (a) 8 B era digest + 1 B stale mask instead of `measurement` rows | 341.6 / 340.5 / 340.0 | 18.4 / 37.4 | 306.9 |
| (c) 16 B sha256 prefix in the unique index | 647.6 / 653.4 / 659.4 | 35.3 / 72.5 | 599.5 |
| (b) cloud alias as a 16 B hash column, no index | 683.6 / 691.5 / 697.2 | 37.3 / 76.7 | 632.8 |
| **Lean = a + b + c + source index + 16 B UUID locator** | **338.3 / 338.4 / 340.7** | **18.3 / 37.5** | 305.7 |
| Spec `memory_schema.sql` as written | 528.0 / 527.2 / 531.3 | 28.5 / 58.4 | 479.5 |
| Spec slimmed (integer kind, UUID locator, 8 B signature digest, no `captured_at` text, sha16 index) | 379.7 / 378.5 / 383.1 | 20.4 / 42.1 | 345.4 |

- At 110k the draft's ledger splits into `measurement` 341 B, `content` 141, `source` 113, sha UNIQUE 46, camera/time 36 B per photo.
- **No pages are ever freed by same-size rewrites:** the freelist stayed at 0 after the fill and every era. The gap to the VACUUMed size is slack inside pages: random-key B-trees run at 0.88–0.90 fill; the (camera, capture time) index at 0.52–0.56 under the newest-first backfill. Declaring it `(camera, captured_ts DESC)` gives 31.5 B per photo at fill 0.87–0.88, against 49–53 B.
- **Growth trap:** an integer 0 or 1 is stored in zero bytes [64]; rewriting it to 2–6 adds a byte and splits dense pages: +12.0 B per photo at 54k after 5 eras. Integral REALs are stored as integers [182].
- **Child-key indexes** missing from the draft DDL: with `foreign_keys=ON` each content delete scans the child table [184]. Per delete: 178–196 ms with neither index, 34–44 ms with `source(content_id)` only, 0.04–0.59 ms with a partial index on `variant_of` (about 0 B while NULL [186]) as well.
- **Sha prefix index** [185]: lookups write exactly `substr(sha256,1,16)` and compare all 32 bytes; a forced 128-bit prefix collision raises IntegrityError instead of aliasing. Odds about n²/2¹²⁹ = 1.8 × 10⁻²⁹ at 110,000 photos [190].
- **A lazy cloud alias cannot work:** `cloudIdentifierMappings` maps local identifiers that resolve *now* [5][12]. The case that needs a cloud alias is a rebuilt library, where the stored identifier no longer resolves (error 3201); nothing is left to map from. A compact eager form, SHA-256(`archivalStringValue`)[:16] on the source row with no index, costs +19.8 B per photo and is matched by one scan after a rebuild. Precondition, UNVERIFIED: the archival string is stable across calls and edits. Cloud identifiers need library access [188]; the `idprobe` that measures them was built, not run.
- **Window churn** (record and detail tiers, `compact()` every 40 photos): freelist 0, ledger B-trees unchanged; the record B-tree sits at 0.55 fill (51.6 MB at 54k against 43.4 MB VACUUMed). Mean compressed record 1,550 B; mean detail 728 B (max 4,945 B).

**Retention.** Deleting scattered rows frees almost no pages, and `auto_vacuum` does not compact partly filled pages [187]. On a 130,000-row ledger, evicting 14,922 tombstones freed 8 KB of 44.77 MB; in-page slack rose from 4.96 to 9.61 MB. `VACUUM` took 0.41 s (48.0 → 40.1 MB); the WAL briefly reached 40.3 MB, and VACUUM needs up to twice the file size free.
- The draft's rule (fixed 32 MiB cap, then oldest captured) on its own schema plus the needed indexes, with 54,000 live photos, **evicted 10,000 live rows (18.5 %)**; re-presenting them costs about 47.7 GB of downloads and 7.5 h of measuring. With an eager cloud alias: 25,750 (47.7 %). Each re-added row pushes another out, so the ledger thrashes.
- The replacement (`ledger_cap.py`, 7 tests passing): a row is live if pinned or if any source is not `deleted`; only tombstones are candidates; the newest T_MAX = 10,000 are kept (Photos keeps Recently Deleted 30 days [189]); cap = 512 B × (n_reachable + T_MAX) is a reported tripwire. On 110,000 live photos, 20,000 tombstones, 300 pinned tombstones and 2,000 screenshot sources (43.08 MB, 325.6 B per reachable item), exactly the 15,000 tombstones beyond T_MAX = 5,000 were evicted, the live set was unchanged, and all 110,000 identifiers still resolved after a 3105/3210 reconcile.

### 3.13 Fault injection: concurrent instances, a damaged database, a full disk [L13]
**Decision supported:** `flock` leases, owner-aware staging, error classes with a retry, a compare-and-swap change token, a damage policy and recovery ladder, payload checksums, a free-space reserve.

**Method.** `memproto.py` prototypes the MEMORY-SPEC §6 writer on the repo's `memory_schema.sql` (read-only), one `BEGIN IMMEDIATE` per photo, optionally calling the real `iqa.analyze.analyze_file`. `orchestrator.py` stands in for one app instance: *naive* mode copies the working tree (`Staging.sweep()` deletes every child of `staging/`, ImportBatch.swift L69-72 as of the finaliser's read, called unconditionally from `AppModel.launch()` L101-103); *robust* mode is the proposal. The real app binary could not be run (`open -n` is blocked in the research sandbox), so instances were emulated. Load average 16–200: wall times are upper bounds.

**What the working tree has today** [R]: no lease of any kind (`LSMultipleInstancesProhibited` governs multiple *users* [196]); staging folders with no owner; `forgetEverything()` unlinking `memory.sqlite`, `-wal` and `-shm` guarded only by its own `isAnalyzing`; `failed` with the current key skipped forever, and `captureInfo(of:) == nil` stored as `not_capture` forever; `preferences.json` last-writer-wins across instances; and `cmd_analyze` catching every `Exception` per file.

**Concurrent instances** (A runs `--analyze-photos 5`; B starts 0.2–4 s later while a new photo moves the change token T1 → T2; a CLI `analyze --memory` starts 0–2 s after B):

| 12 stub trials per policy | Naive (today) | Robust (`flock` leases) |
|---|---|---|
| Other instance's batch deleted by the launch sweep | 12/12 | 0/12 |
| A's staged files gone before they were hashed | 28 of 60 | 0 |
| Duplicate analyses | 16 of 88 (18 %) | 0 of 72 |
| Second app instance | runs a full import | viewer, exits 75, 12/12 |
| Final change token | T2 in 12/12, although A's batch was destroyed | T1 (T2 left for the next run) |

With the real analyzer on her photos, the naive run (done twice) deleted A's batch at 3.0–3.2 s; A's in-flight `IMG_5004.jpeg` raised FileNotFoundError and was stored as **`failed` in both runs**, so B and C skipped a good photo as a remembered failure. The robust run: 6 analyses, 0 duplicates, 0 `failed`; C waited 337 s for the lease. An uncontended `flock` costs 1.7 µs (p99 9.4 µs) and is free within 245 µs of SIGKILL [195]. A child started with Foundation `Process` inherited no descriptors ≥ 3, so the analyzer child takes its own locks. A lease row in `meta` is worse: it needs a database write (which fails on a full disk) and outlives a crash.

**Damage, on copies of a 54,000-photo memory** (54,000 assets, 56,123 sources, 5,693 window rows, 204 archive buckets; 63.2 MB, 46.7 MB compacted):

| Damage | `quick_check` detects | `integrity_check` detects | Effect |
|---|---|---|---|
| Asset leaf, 1 bit (20 trials) | 2/20 | 5/20 | 18/20 changed or broke a value; 13/20 changed one silently (sha256, captured_ts, h_snr_db, …) |
| Asset leaf, 16 random bytes | 8/10 | 10/10 | |
| Record leaf, 1 bit (20) | 0/20 | 0/20 | 9/20 damaged: 7 undecodable, 2 decode to different content |
| Archive leaf, 1 bit (20) | 0/20 | 2/20 | 19/20 damaged |
| UNIQUE sha index leaf, 1 bit | 1/10 | 10/10 | index only |
| Asset internal page | 9–10/10 | 9–10/10 | |

- `.recover` [191] (37 runs, 4.3–84.5 s): `integrity_check` passed on all 37 results; 53,841–54,000 assets came back, with damaged payload bytes still inside, because it salvages structure, not payloads. Raw DEFLATE carries no checksum.
- WAL truncated at 14 cut points: both checks ok, exactly the committed prefix survived. One flipped bit mid-WAL silently dropped 99 of 200 committed transactions, because a frame is valid only if its checksum chain matches [64].
- `-shm` deleted under live connections: a second writer's 400 committed rows vanished in 3/3 trials; an open reader got SQLITE_CORRUPT on a file that then passed `integrity_check` with all 57,000 rows. `forgetEverything()` performs this deletion if another instance's analyzer runs [63].
- The archive is derived data: all 204 buckets were rebuilt exactly from the ledger's headline columns in 0.45 s.
- `VACUUM INTO` [187]: 2.36 s wall, 0.29 s CPU, 46.7 MB; `integrity_check` of the copy 0.31 s CPU.

**Full disk** (300 MB APFS image): APFS returned ENOSPC while `statvfs` still showed 6.4–6.9 MB free. SQLite reported SQLITE_FULL on commit, SQLITE_IOERR_TRUNCATE (1546) on `wal_checkpoint(TRUNCATE)` with data intact, SQLITE_CANTOPEN or SQLITE_IOERR_SHMSIZE (4874) on open without `-shm`, and CANTOPEN on creating a fresh database [60]. A commit whose automatic checkpoint fails still stands [192]. A read-only `immutable=1` open read all 54,000 rows with no space left [194]. In the naive run the change token advanced past 3–5 photos that were never measured; the robust run refused the batch before staging (8.6 MB plus a 16 MB reserve did not fit in 19.9 MB), or rolled back and left the token unchanged.

**Environmental failures that would become permanent:** a HEIC truncated to 50 % measured "successfully" with `clip_high_pct` −81 %; a JPEG truncated to 50 % raised OSError (errno None); a JPEG truncated to 98 % gave identical figures under a content id that matches no real file. CPU per image was 6.8–13.1 s of `process_time` for 12–45 MP at load 16–200 (background QoS: +0–8 % CPU, 1.47–1.59× wall), so the 60 s budget has at least 4.6× headroom.

### 3.14 Finaliser checks: a long reader, and the Swift writer against the Python writer [L14]
**Decision supported:** the short-read rule for every reader, and the claim that both languages can write.

**WAL under readers.** A copy of a 54,000-photo ledger on the repo's `memory_schema.sql` (41.1 MB, 5,000 window rows), `journal_size_limit` 4 MiB, one writer committing 2,000 photo transactions (asset, source, 1,550 B record, 728 B detail):

| Reader | WAL maximum | WAL afterwards |
|---|---|---|
| None | 4.16 MB | 4.16 MB |
| Keyset pages of 200 rows, each its own statement, 10 ms apart | 5.00 MB | 4,194,304 B |
| One statement over all 54,000 rows, stepped 200 rows per 10 ms | **85.2 MB** | 4,194,304 B once it finished |
| `BEGIN; SELECT …` held for the whole run | **88.2 MB**, i.e. 44,086 B per photo transaction | 4,194,304 B after release and one reset |

So the WAL is bounded by 4 MiB + 44 KB × (photo transactions committed while the oldest read is open). At 2 workers and 2 s a photo, an hour-long read would leave about 160 MB. The draft's reader test reset its statements every 2 ms and never measured this.

**Mixed writers.** Three trials on copies of the same database: a Swift writer on Apple's system SQLite 3.51.0 (`aapl` build) doing 3,000 `BEGIN IMMEDIATE` transactions of `meta`, `app_state` and `source` UPSERTs; a Python writer on Homebrew SQLite 3.53.4 doing 3,000 photo transactions; a reader polling every 2 ms; `busy_timeout` 5,000 everywhere.

| | Transactions | Failures | p50 / p99 / max ms |
|---|---|---|---|
| Swift (3.51.0) | 9,000 | 0 | 0.05–0.12 / 2.8–5.1 / 13–16 |
| Python (3.53.4) | 9,000 | 0 | 0.13–0.26 / 4.7–6.6 / 12–31 |
| Reader | 6,549 reads | 0 errors | max 5.6 |

`integrity_check` was ok after every trial. Not tested: the app's own `MemoryStore` (under MEMORY-SPEC §7 the app does not write yet) and a real `serve` worker, which does not exist yet; and a long-running Swift reader against both writers.

---

## 4. Recommended architecture

### 4.1 Overview

```
 PhotoKit change feed ─┐   Picker (photoLibrary: .shared(), .current) ─┐   Folder / CLI paths ─┐
   (measure on arrival) │   id resolves + authorized → PhotoKit path;    │                       │
                        │   otherwise its bytes, rendition = unknown     │                       │
                        ▼                                                ▼                       ▼
  orchestrator.lock: one importing instance per user (a second instance is a read-only viewer)
               ┌──────────────────────── Swift orchestrator (actor MemoryIndex) ─────────────────────┐
  S0 change feed → S1 .photo-resource gate → S2 alias lookup (L0) → S3 stat (folders) → S4 stream+SHA-256
               │      no bytes                no bytes, 5–13 µs        ~2–11 µs            2–4 ms + transfer
               │                                  │ hit: stop               │ hit: stop     │ hit: delete temp, stop
               └── miss: staging/<pid>-<random>/ with a locked .owner; free-space reserve; per-day download budget ─┘
                                                  ▼  JSON line {job, sha256, bytes, path, source, rendition}
               ┌──── python -m iqa serve (≤ 2 workers per machine, recycled; memory.lock held per batch) ───────┐
               │ verify sha + byte count → S5 capture/provenance gate → S6 load once, measure, dHash256, mask  │
               │ S7 one BEGIN IMMEDIATE txn: content, summary, detail, ring, bucket deltas, seq + 1            │
               └──► stdout {job, status, error_class, cpu_s, rss_mb} ─► Swift deletes the staged file,
                                                                         or moves it into the reservoir
                                                  ▼
  memory.sqlite (Application Support, WAL; weekly VACUUM INTO backups A/B; memory.seq sidecar)
  Caches/IQCoach/derived/<sha>.{png,heic} (64 MB)        Caches/IQCoach/reservoir (≤ 256 MB/camera, ≤ 1 GB)
                                                  ▼
  Coach queries (short, keyset-paged reads): per-camera buckets of original renditions × query-time decay
```

### 4.2 Identities and the layered fingerprint

| Identity | Definition | Used for | Never used for |
|---|---|---|---|
| **content_id** | SHA-256 of the exact bytes of the analysed resource (PhotoKit `.photo`, picker file, folder file), 32 B. Stored with `rendition` ∈ original / edited / unknown / external_edit | Measurement reuse; the key for preferences, checks and derivatives. Only `original` rows (and qualifying `unknown` ones, §4.3 S5) feed aggregates | — |
| **source alias** | (kind, locator). PhotoKit: `localIdentifier` (as its 16 B UUID when canonical) for the `.photo` resource; optionally a 16 B hash of the `PHCloudIdentifier` archival string (§4.4). Picker: `itemIdentifier`, recorded as `picked_via` on the PhotoKit source when it resolves under authorization, otherwise its own row with rendition = unknown. Folder: a keyed hash of the canonical path (key outside the DB), plus a stat key | Avoiding downloads, copies and hashing (L0/L1). Only a PhotoKit `.photo` source may back an L0 skip | Proving identity |
| **capture_id** | 8-byte hash of make, model, `DateTimeOriginal`, `SubSecTimeOriginal`, `OffsetTimeOriginal`, plus Apple MakerNote `PhotoIdentifier` (0x002b) or the Nikon body serial and image number. Needs iqa to read those tags; today it reads only `DateTimeOriginal` [R] | Counting each capture once (`variant_of`): links are SHA equality, then a linked identifier, then capture_id; aggregates count a capture once, preferring rendition = original | Skipping a measurement |
| **dhash256** | 17×16 dHash of a 256×256 greyscale of the display-oriented decode, 32 B, with a pipeline version in `meta` | "Same photo, re-encoded or tone-edited" (≤ 24), "similar framing" (25–56); a tiebreaker between tone edits | Skipping; confirming a capture link (it links 18 of 1,000 real crops [L11]); comparison across pipelines |
| **vision print** | Revision 2, Float16, 1,536 B, from one fixed input pipeline (file URL, or a `FromImageAlways` + `WithTransform` thumbnail at a fixed size) | "Same scene" (≤ 0.50) within ±60 s | Identity |

**Exact tier, cheapest first** (R1, R2):

| Layer | Check | Cost | On a hit | On a miss |
|---|---|---|---|---|
| L0 (PhotoKit `.photo`; a picked item that resolves to a PhotoKit asset) | `source(photokit, localIdentifier)` exists. Its content has `status=measured` and the current era. `modificationDate` is unchanged. L0 is enabled in the asset's stratum. | 5–13 µs, 0 bytes | Stop. Count as a hit and audit with the stratum's probability (below). | Date changed: compare the signature of the `.photo` **resource** (type, UTI or `contentType`, `originalFilename`, resource pixel W×H [172], plus `dataSize` on macOS 27), never `PHAsset.pixelWidth`, which changes with every crop. Equal: refresh metadata only and stop. Otherwise go to L2. |
| L1 (folder, CLI) | Stat key (dev, ino, size, mtime_ns, ctime_ns) equal, and `mtime_ns < verified_at − 1 s` (git's racy rule [74]) | 1.4–11 µs | Use the stored content_id and check the era | L2 |
| L2 (all) | SHA-256, streamed over `requestData` chunks while writing the staging file (PhotoKit), over the `FileRepresentation` file (picker), or `hashlib.file_digest` (folder) | 2–4 ms per photo, no extra I/O when streamed | Link the alias, delete the staging file, stop. | Measure (S5–S7) |

**The L0 audit (R1a), stratified** (**Corrected** [L10]).
- Strata: camera × source kind × availability (local / cloud-only). The draft sampled only local assets, about 2 % of the library and the same newest ones every session, so its 3/n bound said nothing about the cloud-only hits L0 actually makes.
- Each session: up to 5 local hits (about 3 ms each) and 1–2 cloud-only hits (about 0.56 s and 4–10 MB each), inside the download budget. Over-sample the RAW+JPEG stratum (24,916 D850 assets, never local): a primary switch there is an exception the SDK names [12].
- Every re-download made for any reason (a restore, a reservoir refill, a photo the user opens) is compared with the stored content_id and counts as a cloud audit. One full Active restore gives n = 1,296 cloud audits, a bound of 0.23 % per hit, at no extra cost.
- Show 3/n per stratum in the Method tab, for example "iPhone 17 Pro Max, iCloud: audited 300 times, 0 mismatches: < 1 % per hit". Audits repeat assets and are not independent, so the bound is a display figure, not a guarantee. A stratum with no audits shows "unaudited".
- **On a mismatch:** disable L0 in that stratum only, log the asset, and raise the stratum's audit rate to 10 % until 300 clean audits. A global disable would cost about 33 downloads (about 130 MB) per newest-40 import at today's local share, and the expected exceptions (a RAW+JPEG primary switch, Portrait or Night adjustments) would trip it.
- **Strict identity** disables L0 entirely. Its setting shows the cost first: one read per local asset, one download per cloud-only asset per run (about 130 MB per newest-40 import today; 184 MB right after a sweep).
- Measured so far: 93 of 93 retrievals byte-identical to the library's own fingerprint, 95 % bound 3.2 % per retrieval [L10].

**Advisory tier, cheapest first.** It never skips anything.
- **B0.** `PHAsset.burstIdentifier` [15] / `BurstUUID`. The user's pick comes from `burstSelectionTypes` [16].
- **B1.** Same camera with Δt ≤ 2 s → burst group. Any camera within ±60 s → scene candidates. Both come from the `content(camera_id, captured_ts DESC)` index. Across cameras, times are compared in UTC using `OffsetTimeOriginal` when both photos carry it; otherwise only same-camera windows apply, since a missing offset can be off by hours.
- **B2.** dHash256 ≤ 24 → same photo, re-encoded or tone-edited; used only to break ties between candidates already linked by capture_id. 25–56 → similar framing.
- **B3.** Vision ≤ 0.50 → same scene. The print is kept only for the newest 2,000 photos.
- **Suppress** advisory matches for low-texture frames (luminance SD < about 25) [L1] and for degenerate decodes (SD < 1 DN) [L8].
- **Apply EXIF orientation first.** Use best-of-4 rotations only for sources outside PhotoKit [L8].

### 4.3 Staged lazy pipeline and short-circuit rules

| Stage | Where | Cost | Rule |
|---|---|---|---|
| **S0** change feed | Swift | one `fetchPersistentChanges` call [9] | Merge the details: a delete beats an insert or update; inserted plus updated counts as inserted. Deleted → `source.status = deleted` and `deleted_at`. First run, or error 3105/3210/3114/3142/3143: reconcile with one batched fetch plus `localIdentifierMappings`, and store the token read *at the start* [11][12]. **Under limited access** the feed covers only the selected assets [11], so an asset missing from a fetch becomes `unavailable`, never `deleted`. Write the new token by compare-and-swap against the value read at batch start, in the same transaction as the source updates, and only when the analyzer exited 0 and the batch had no environmental errors (§4.9) [L13]. |
| **S1** free metadata gate | Swift | µs, no bytes | Reject `mediaSubtypes.photoScreenshot`, a `.photo` **resource** pixel area under 5 MP (`PHAssetResource.pixelWidth × pixelHeight`, macOS 13+ [172]), and assets with no `.photo` resource. Screenshots get a persistent `not_capture`, so they are **never downloaded again**; today they are downloaded, rejected and forgotten on every run [L2]. A size-only rejection is never persisted by `localIdentifier`: recomputing it costs microseconds, and an edit or revert must not strand a capture. **Corrected:** the draft gated on `PHAsset.pixelWidth`, the edited size, which rejects 48 cropped captures [L11]. |
| **S2** alias lookup (L0) | Swift | 5–13 µs | As in §4.2. |
| **S3** stat (L1) | Swift / Python | ≤ 11 µs | Folders and CLI only. |
| **S4** stream + hash (L2) | Swift | 2–4 ms + transfer (median 0.555 s per iCloud download [L10]) | `requestData` with network off first. Error 3164 → `cloud_deferred`, retried within the per-day download budget (§4.8). Check free space against the reserve before each download. Stream through `requestData(for:options:dataReceivedHandler:)` into `<name>.partial`, hash while streaming, fsync, check bytes written = bytes received, then rename [L13]. |
| **S5** capture gate | Python | 0.19–0.58 ms (PIL EXIF) | No camera model in EXIF → `not_capture`, keyed by content and by source. EXIF `Software` or XMP `CreatorTool` naming an editor (Lightroom, Snapseed and others) → rendition `external_edit` [L11]. A picker or folder file is `unknown` and enters aggregates only if its area is a native size already seen for that model through PhotoKit `.photo`, its `Software` is the camera's own firmware, and it is not a Portrait. A file whose EXIF cannot be read is an environmental error (delete, retry next run), never `not_capture` [L13]. |
| **S6** measure | Python | load about 1.7–2.0 s, plus the measurement | Verify the claimed SHA-256 and byte count of the staged file (2 ms; catches staging mix-ups and short writes: a HEIC truncated to 50 % measured "successfully" with `clip_high_pct` −81 % [L13]). Load once and run every group. Compute dHash256 (+11 ms), the clipping-mask PNG, and the thumbnail and preview for non-PhotoKit sources. **CPU budget: 60 s of `time.process_time()`** (measured need 6.8–13.1 s at load 16–200, ≥ 4.6× headroom [L13]). When it is exceeded, the parent kills and recycles the worker, records `cpu_s`, `wall_s`, thermal state and memory pressure, and stores `timeout_once`. The retry runs alone at `userInitiated` in a later session; only a second timeout is final (`timeout_final`). Errors are classed as in §4.9. |
| **S7** commit | Python | one transaction | `BEGIN IMMEDIATE`, inside a batch that holds `memory.lock`. UPSERT the content, summary, detail, ring and bucket deltas, and increment `meta.seq`. **Early cutoff:** if a re-measure's rounded summary equals the stored one, leave the buckets alone [75]. Emit a `done` line. Swift deletes the staging file, or moves it into the reservoir when the sampler keeps it. An owner-aware sweep removes leftovers (§4.9). |
| **S8** advisory grouping | Swift / Python | O(k) per photo | Runs lazily when the photo's camera is viewed (B0–B3). |

**Queue order (demand-driven [77]).**
0. New captures from the change feed, while Photos still holds them locally: prefetch lands a median 1.8 h after an asset is added and stays until the next sweep, at least 72 h observed [L10]. This keeps steady-state imports nearly download-free.
1. Photo on screen or selected: `userInitiated`.
2. Newest captures per camera: `utility`.
3. Backfill and restores after a bump: `background`, via `NSBackgroundActivityScheduler`, within the per-day download budget.

**Stopping rule per camera.** Stop backfilling when the bootstrap 95 % half-width of the median SNR is below 1.5 dB *and* the MTF50 half-width is below 10 %, or when the backlog is older than the camera's half-life horizon [L6]. Resume when the freshness state changes.

### 4.4 Storage engine and schema sketch

**File and settings.**
- `~/Library/Application Support/IQCoach/memory.sqlite`. It stands for about 2 s of compute per photo, so it stays in backups [31][32].
- The CLI takes `--memory PATH` and is **opt-in**, so published runs in `results/` stay exactly reproducible.
- Set once, before the first `CREATE`: `page_size = 4096`, `application_id = 0x49514331`, `user_version`, `auto_vacuum = INCREMENTAL`, `journal_mode = WAL`.
- On every connection: `synchronous = NORMAL`, `busy_timeout = 5000`, `foreign_keys = ON`, `journal_size_limit = 4194304` [55]. That limit truncates the WAL only when a commit or reset finds it larger; it does not cap growth while a read is open (§3.14), so the short-read rule of §4.9 is what bounds the WAL.

The sketch below is the lean layout measured at 338–341 B per photo in the ledger (incremental, never VACUUMed, after 5 era rewrites) [L12], plus four columns the final round added (`time_flags`, `rendition`, `deleted_at`, `picked_via`). By the record format [64] those add about 6 B per photo (one header byte per column, plus one value byte for each small integer); that increment is computed, not measured. **Corrected:** the draft's DDL measured 666–677 B, mostly its per-photo `measurement` table, and lacked two indexes that foreign keys need.

```sql
-- Ledger: one row per distinct byte string ever seen. The only table whose size scales with #photos.
-- Enumerations start at 2: SQLite stores 0 and 1 in zero bytes, so rewriting them later grows rows and
-- splits dense pages (+12 B per photo after 5 eras [L12]).
CREATE TABLE content (
  id           INTEGER PRIMARY KEY,
  sha256       BLOB NOT NULL CHECK (length(sha256) = 32),
  byte_size    INTEGER NOT NULL,
  camera_id    INTEGER REFERENCES camera(id),
  captured_ts  REAL,             -- local wall-clock DateTimeOriginal + SubSecTimeOriginal in s, as MEMORY-SPEC stores it; NULL = undated
  time_flags   INTEGER NOT NULL, -- 2 + bits: sub-second known, clock_suspect, OffsetTimeOriginal in 15-min steps when known (§4.7)
  capture_id   BLOB,             -- 8 B exact capture link key
  dhash256     BLOB,             -- 32 B, advisory only
  status       INTEGER NOT NULL, -- 2 measured | 3 not_capture | 4 failed_once | 5 failed_final | 6 timeout_once | 7 timeout_final
  rendition    INTEGER NOT NULL, -- 2 original | 3 edited | 4 unknown | 5 external_edit
  era          BLOB NOT NULL,    -- 8 B digest of the analyzer key of the last full measure (fixed width)
  stale_mask   INTEGER NOT NULL DEFAULT 0,  -- unused unless per-group invalidation is ever built; 0 costs 0 bytes
  headline     BLOB,             -- 8 × float16: mtf50_p80, snr_mid, clip_hi, clip_lo, wb_rg, wb_bg, tilt, mean_luma
  variant_of   INTEGER REFERENCES content(id),
  first_seen   REAL NOT NULL
);
CREATE UNIQUE INDEX content_sha16 ON content(substr(sha256, 1, 16));  -- lookups use exactly this expression [185]
                                                                       -- and then compare all 32 bytes
CREATE INDEX content_cam_time ON content(camera_id, captured_ts DESC); -- 31.5 B/photo at 0.87 fill under newest-first backfill
CREATE INDEX content_variant  ON content(variant_of) WHERE variant_of IS NOT NULL;  -- about 0 B; FK deletes need it [184]

-- Aliases (how a content was reached). Narrow → WITHOUT ROWID.
CREATE TABLE source (
  kind        INTEGER NOT NULL,  -- 2 photokit | 3 picker (unlinked) | 4 folder
  locator     BLOB NOT NULL,     -- photokit: 16 B UUID when the identifier is "<UUID>/L0/001", else its text (lossless);
                                 -- picker: itemIdentifier text; folder: HMAC-SHA256(install_key, realpath)[:16]
  content_id  INTEGER REFERENCES content(id),
  sig         BLOB,              -- photokit: 8 B digest of the .photo resource signature; folder: packed stat key (40 B)
  mod_date    REAL,              -- photokit
  verified_at REAL,
  status      INTEGER NOT NULL,  -- 2 linked | 3 not_capture | 4 cloud_deferred | 5 unavailable (limited access) | 6 deleted
  deleted_at  REAL,              -- tombstone age for retention (§4.8)
  picked_via  BLOB,              -- photokit rows reached from the picker: the itemIdentifier
  cloud_h16   BLOB,              -- optional: SHA-256(PHCloudIdentifier.archivalStringValue)[:16], no index (+19.8 B/photo);
                                 -- ship only after idprobe shows the string is stable (§6.2)
  PRIMARY KEY (kind, locator)
) WITHOUT ROWID;
CREATE INDEX source_content ON source(content_id);  -- without it each content delete scans source: 178–196 ms at 54k–110k [L12]

-- One row per analyzer era, instead of 8 per-photo measurement rows (saves 338–341 B per photo [L12]).
CREATE TABLE era (
  digest BLOB PRIMARY KEY,       -- 8 B, as stored in content.era
  analyzer_key TEXT NOT NULL,    -- "m<MEASUREMENT_VERSION>-r<max_rois>-s<max_side or 0>" (MEMORY-SPEC §3)
  bump_class TEXT,               -- migration | pixel | schema-add, as declared for the bump into this era
  env_json TEXT,                 -- numpy, opencv, Pillow, libheif, LibRaw versions: provenance, not key
  first_used REAL
) WITHOUT ROWID;

-- Window tier (evictable): full scalars and detail. crc32 is checked on every read: raw DEFLATE has no checksum,
-- and quick_check / integrity_check missed 20 of 20 record and 18 of 20 archive bit flips [L13].
CREATE TABLE summary (content_id INTEGER PRIMARY KEY REFERENCES content(id) ON DELETE CASCADE,
  layout INTEGER NOT NULL,       -- field-order version
  f32 BLOB NOT NULL,             -- ~71 numeric fields packed float32 (414 B/row measured [L7])
  crc32 INTEGER NOT NULL,
  camera TEXT, lens TEXT, fmt TEXT, iso REAL, exposure_s REAL, f_number REAL, focal_mm REAL);
CREATE TABLE detail  (content_id INTEGER PRIMARY KEY REFERENCES content(id) ON DELETE CASCADE,
  codec INTEGER NOT NULL, z BLOB NOT NULL, crc32 INTEGER NOT NULL);  -- edges, noise curve, focus map: zlib JSON (496 B mean)
CREATE TABLE vision  (content_id INTEGER PRIMARY KEY, rev INTEGER, print_f16 BLOB, labels BLOB);  -- newest 2,000

-- Aggregates (fixed size per camera). Derived data: rebuildable from the ledger's headline values (§4.9).
CREATE TABLE camera (id INTEGER PRIMARY KEY, make TEXT, model TEXT, first_capture REAL, last_capture REAL);
CREATE TABLE bucket (                 -- rows of 1.4–4.6 KB → ordinary rowid table
  id INTEGER PRIMARY KEY, camera_id INTEGER, grp INTEGER, era BLOB,
  tier INTEGER,                       -- 2 weekly (13) | 3 monthly (24) | 4 archive (1)
  start REAL, t_mean REAL, n INTEGER, payload BLOB, crc32 INTEGER NOT NULL,  -- histograms + moments + shares + per-day counts
  UNIQUE (camera_id, grp, era, tier, start));
CREATE TABLE ring (camera_id INTEGER, seq INTEGER, content_id INTEGER, captured_ts REAL, row BLOB,
  PRIMARY KEY (camera_id, seq)) WITHOUT ROWID;       -- last 64 per camera (exact small-n stats)
CREATE TABLE reservoir (camera_id INTEGER, slot INTEGER, content_id INTEGER, bytes INTEGER,
  PRIMARY KEY (camera_id, slot)) WITHOUT ROWID;      -- which originals Caches/IQCoach/reservoir holds (§4.8)

-- App-owned (written only by Swift).
CREATE TABLE app_state (content_id INTEGER PRIMARY KEY, pinned INTEGER NOT NULL DEFAULT 0, last_viewed REAL);
CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB);
  -- change token, seq, schema and hash-pipeline versions, authorization state,
  -- L0 audit counts and disabled strata (per camera × source kind × availability)
```

**The spec's implementation.** MEMORY-SPEC's `iqa/memory_schema.sql` measured 527–531 B per photo, not the "about 200 B" it states. Without losing anything it can do, an integer `kind`, a 16 B UUID locator, an 8 B signature digest, dropping the `captured_at` text (rebuildable from `captured_ts`) and the 16 B sha prefix index bring it to 379–383 B [L12]. It also needs `source.status` and `deleted_at`: without them, rows of deleted photos can never be told from live ones and stay for good.

**What stays outside SQLite.**
- `preferences.json`: intent tags, set-asides, capture checks, coaching state. It is small, written by the user, and re-keyed by `sha256`. Only the instance holding `orchestrator.lock` writes it: today each instance rewrites the whole file from its own copy, so the last writer wins [L13].
- `Caches/IQCoach/derived/<sha>.*`: masks, and thumbnails and previews for non-PhotoKit sources.
- `Caches/IQCoach/reservoir/<sha>`: the re-measure reservoir.
- `memory.lock`, `orchestrator.lock` (created at first launch: creating a lock file fails with ENOSPC on a full disk [L13]), the `memory.seq` sidecar, and `install.key` (0600), the key of the keyed path hash, which never goes into the database file or an export.

**Not needed.** There is no job table: each image commits on its own, so the ledger itself is the resume point after a crash. Staging is swept by owner (§4.9).

**SwiftData is not used.** It needs macOS 14+, has reported `ModelActor` sync regressions, and its schema is private, so Python cannot read it [44][45][46].

### 4.5 Cache key and invalidation

**Corrected.** The draft keyed each of 8 groups by its own version, a config digest and an environment class, stored as 8 `measurement` rows per photo. The final design keeps MEMORY-SPEC §3's single key and adds a declared bump class, because the replay and the ledger bench showed that per-group keys cost half the ledger and save no downloads (§3.10, §3.12).

```
analyzer_key = "m<MEASUREMENT_VERSION>-r<max_rois>-s<max_side or 0>"     # MEMORY-SPEC §3; iqa/__init__.py
era          = SHA-256(analyzer_key)[:8]                                # 8 B on each content row; one era row each
valid(row)   ⇔ row.era == era(current analyzer_key)                     # equality: a rollback re-measures too
BUMPS        = {MEASUREMENT_VERSION: "pixel" | "migration:<fn>" | "schema-add:<fields>"}   # declared per bump
```

- **Equality, not `<`.** A rollback re-measures too.
- **Bump discipline.** `tests/test_memory_versions.py` hashes `ast.dump()` of the measurement modules with docstrings stripped and compares it with a pinned table.
  - A change without a version bump fails the test. Re-pinning without a bump is allowed only when the golden corpus gives **bit-identical** outputs.
  - The corpus is the 4 `iqa demo` scenes, generated once and frozen (`synth.py` itself changes), the 20 canary photos of [L10] and one DNG. Its pinned outputs live in the repo.
  - This catches refactors while ignoring edits to method notes [70][L4].
- **Bump classes, checked against the corpus diff** (T30):
  - `migration:<fn>`: `fn` applied to the old pinned outputs must reproduce the new ones exactly. Rows are updated in place from stored columns with 0 downloads. In the replay one whole transition was of this kind (bd6b877, the thirds-distance rescale). Other derivable changes rode inside pixel-needing commits (`mtf50_p80_lwph` from `mtf50_p80` and the short side, `format` jpg→jpeg, the flat-share fix), and FINDINGS §9 back-filled such fields this way [R]. A commit that mixes both is declared `pixel`, with its derivable part also declared as a migration and applied first to rows that cannot be re-measured yet. Window rows migrate in full; ledger-only rows migrate their headline values where derivable, and otherwise keep their old era label.
  - `schema-add:<fields>`: every existing field is unchanged; new fields are filled when the bytes next pass, and are shown as missing until then.
  - `pixel`: at least one existing field differs (otherwise it should have been a re-pin). Rows go stale.
- **Library upgrades.** Versions of numpy, OpenCV, Pillow, pillow-heif/libheif and rawpy/LibRaw are recorded in `era.env_json` as provenance, not in the key. An upgrade re-runs the corpus (about 1 minute); identical outputs keep the era, and any difference becomes a `pixel` bump. Determinism with identical code held (0 differing fields at load about 100 [L10]); determinism across upgrades is untested (risk 10).
- **Debounce.** A restore starts only after the key has been stable for 12 h. In the replay that turns 10 transitions into 3 restores (10-13, 10-15, 10-23) and avoids downloading for intermediate versions [L10].
- **What happens to stale rows after a `pixel` bump.**
  - They stay visible with a label naming the method version.
  - Their old-era buckets are frozen and leave coaching once the new era passes the n_eff threshold.
  - Re-measurement order: the re-measure reservoir first (0 downloads; paired old/new values give the era shift), then local window photos, then cloud-only window photos within the per-day download budget, newest first. All stale fields of a photo are recomputed in one load.
  - Old photos without a reachable original (deleted, or folder files that are gone) keep their old-era label and are never mixed in.
- **Per-group invalidation, only if ever needed:** a stale-group bitmask on the content row (`stale_mask`, +7 B with the era digest) and one row per era, not per-photo rows. It would save CPU, never downloads.
- **Python reports the key at start-up** (handshake, §4.9), so Swift evaluates L0 validity without importing Python.

### 4.6 Bounded summaries per metric (sizes and error bounds)

**Inputs.** Each bucket receives only values that pass the report's own validity gates:
- sharpness: three-edge minimum;
- SNR: clean-SNR gate, with extrapolated mid-grey excluded (C5);
- dynamic range: lower bounds excluded (C13).

Pass and fail counts are kept as shares so prevalence stays computable [R]. Sizes come from [L3]; bins are float32 counts (exact to 2²⁴), and every histogram has underflow and overflow bins that the UI flags when they are used.

| Metric | Mapping, range | Weekly (13): bins / bytes / error | Monthly (24) | Archive (1) |
|---|---|---|---|---|
| MTF50, MTF50 p80 (cpp) | log, α = 1 %, [0.02, 0.6] | 173 / 692 B / ±1 % relative | merge pairs → ±2 % | ±4 % |
| SNR at mid-grey (dB) | linear 0.25 dB, [10, 55] | 182 / 728 B / ±0.125 dB | ±0.25 dB | ±0.5 dB |
| `clip_high_pct`, `clip_low_pct` | exact zero bucket + log α = 5 %, [0.001, 100] % | 120 / 480 B each / ±5 % rel. (measured 0.57 % at p50, 1.9 % at p99) | ±10 % | ±20 % |
| WB r/g, b/g (stops) | linear 0.05, [−3, 3] | 122 / 488 B each / ±0.025 | ±0.05 | ±0.1 |
| Horizon tilt (°), tonal range (stops) | linear 0.25°, 0.1 stop | 328 B, 648 B | half resolution | quarter resolution |
| Exact shares (decayed Bernoulli) | clip > 0.1 / 1 / 5 %, gate passes, flags | 12 counters | same | same |
| Moments | (n, mean, M2) per metric. Chan merge [100]; direct mean when merging two large buckets of similar size. ln(MTF50) for a geometric mean. Used only for SNR and WB. | 24–32 B | | |

**Per-camera totals.**
- Bucket: 4,600 B weekly, 2,476 B monthly, 1,412 B archive.
- Per-day counts for the weekly tier: 728 B.
- Ring of the last 64 rows: 5,440 B.
- Exemplar reservoir of rows (k = 16): 384 B. (Not to be confused with the re-measure reservoir of originals, §4.8.)
- Total: **≤ 128 KiB per active camera, about 14.3 KiB per dormant camera**.

**Library scale.** 19 cameras with 4 active is about 0.7 MiB [L3]. The full library's 55 models, again with 4 active, comes to about 4 × 128 + 51 × 14.3 ≈ 1.24 MiB (synthesiser's arithmetic).

**Error budget.** The sketch's ≤ 1 % on MTF50 compares with a ±11.5 % sampling CI at n_eff = 100 and a ±28 % per-image CI [L3]. Sketch error is negligible.

**Forgetting a photo.** Histogram and share counts subtract exactly. Moments use the inverse Chan update.

**Sealing and folding.** Seal week → fold into month → fold into archive. This runs lazily at launch or after a batch, costs O(bins) and is idempotent. Merging adjacent log-bin pairs gives α′ = 2α/(1 + α²) [L3].

### 4.7 Decay and half-life

**Weights.** Forward decay on capture time [101]: w(t) = 2^((t_eff − L)/H), with the clamped t_eff defined below. The **weight is applied at query time** per bucket from its mean capture time, and per photo in the ring, so the buckets themselves store unweighted counts. Three consequences:
- H can change without a rewrite;
- landmark overflow never arises;
- the result does not depend on arrival order.

Kish n_eff uses per-day counts for Σw².

**The capture clock** (**Corrected**; R14, T27).
- **Source.** `DateTimeOriginal` plus `SubSecTimeOriginal`, and `OffsetTimeOriginal` when present. All 13 picker deliveries carried all three, D850 files included [L11]. Today iqa reads only `DateTimeOriginal` and falls back to tag 306 `DateTime`, a modification time [R]. Reading the two extra tags is a `schema-add` bump; tag 306 is dropped, and a file without `DateTimeOriginal` is undated.
- **Storage.** `captured_ts` keeps the local wall-clock time, as MEMORY-SPEC stores it. That is what "capture days" should count. The offset, when known, goes in `time_flags`, so cross-camera windows (B1) compare true instants.
- **Error from ignoring the offset in decay:** at most 2^(14 h / H), i.e. 1.4 % of a weight at H = 30 d and 0.5 % at 90 d. It matters only for the ±2 s and ±60 s windows.
- **Clamp.** The decay uses t_eff = min(captured_ts, first_seen), because a capture cannot happen after the file is first seen; so no weight exceeds 1 and a future-dated photo cannot dominate a bucket's mean time. A row is `clock_suspect` when captured_ts > first_seen + 1 day or captured_ts < 2000-01-01. Such rows stay in the ledger and the per-photo screen, count in lifetime totals, and are left out of decayed aggregates, with a note. Today 0 of 389 rows are future-dated and the earliest is 2013-05-17 [R]. The 1-day and year-2000 limits are judgement (risk 14).

**Half-life per camera.** Use the smallest H in {30, 90, 180, 365 days, lifetime} that gives **n_eff ≥ 30 photos and ≥ 10 effective capture days** [L3]. The default target is 90 days.
- Planning rule: n_eff ≈ 2.885 · rate · H.
- A ±10 % MTF50-median CI needs n_eff ≥ 133 photos *with MTF*, about 350 photos at the 38 % yield [L3][L9].
- Label every number, for example "half-life 90 d, 140 effective photos over 23 days".
- These thresholds are engineering judgement, not a cited standard (UNVERIFIED).

**Freshness clock** [L5]. It is separate from the evidence and decides whether a camera is coached:

| State | Last capture | Coaching |
|---|---|---|
| **Active** | ≤ 90 d | Full coaching |
| **Resting** | 90–365 d | No new "one thing", no new checks, report card frozen, with a line such as "You haven't shot with the iPhone 13 since 8 Jul 2026; coaching is paused" |
| **Archived** | > 365 d | Detail rows evicted; buckets remain |

- The state is driven by last-capture age and the absolute weight W counted from today, **never by Kish n_eff**, which does not change when all weights scale together.
- A new photo wakes the camera.
- On the 389-photo run on 23 Oct 2026, only the iPhone 17 Pro Max was Active [L5].

**Statistical honesty** [L3][121][122]:
- Show photos, n_eff and n_eff in days.
- Window of ≤ 64 photos: compute exactly from the ring.
- Fewer than 6 photos: list the values and show no median.
- n_eff < 14: hide p80.
- Medians use Woodruff intervals with the per-day n_eff. Shares use Wilson with n = n_eff.
- Never merge across eras.

### 4.8 Retention and eviction, with byte budgets

| Tier | Location | Unit size (measured) | What is kept | Budget | Eviction |
|---|---|---|---|---|---|
| **Originals (staging)** | `Caches/IQCoach/staging/<pid>-<random>/` with a locked `.owner` | 4.77 MB mean, 15.5 MB max among her copies; 9.67 MB library mean [L2][L10] | Only in flight | ≤ 2 files per worker, ≤ 2 workers per machine, ≤ 128 MB, and never below the free-space reserve | Deleted after commit, or moved into the reservoir; owner-aware sweep (§4.9) |
| **Re-measure reservoir** (new; **Corrected** from "0 at rest") | `Caches/IQCoach/reservoir` ("discardable cache files" [165]), marked excluded from backup [31] | 270 / 152 / 150 / 385 MB per Active camera today [L10] | 64 originals per Active camera, a uniform sample of its window (Algorithm R [111]) | ≤ 256 MB per camera (about 16 D850 photos), **≤ 1 GB in total** (957 MB for today's 4 Active cameras) | Algorithm R replacement as the window moves; released when a camera turns Resting; purgeable by Clear cache or the system, after which a `pixel` bump costs downloads |
| **Ledger** (`content`, `source`, `era`) | memory.sqlite | **338–341 B per photo**, lean layout, incremental [L12] | Every live content: pinned, or with any source not `deleted`. Tombstones (all sources deleted): the newest 10,000 | **18.3 MB at 54,000 photos, 37.5 MB at 110,000.** Tripwire 512 B × (n_reachable + 10,000): 32.8 MB at 54k, reported in Settings, never enforced on live rows | Tombstones beyond the newest 10,000, oldest deletion first, by count. Then `VACUUM` when in-page slack (`dbstat` unused) exceeds 25 % of the file (0.41 s at 130k rows; needs 2× the file free) [L12] |
| **Window** (`summary` + `detail` + `ring`) | memory.sqlite | 414 + 496 B mean (detail max 2,288 B) [L7][L4] | 500 newest per Active camera, 64 per Resting camera, pinned (intent tags, check baselines, burst keepers), viewed in the last 30 days | Expected ≤ 9 MB (19 cameras × 500 × 910 B); **hard cap 32 MB** | Oldest captured, unpinned first. Then a fully stepped `incremental_vacuum` (57 ms for 29 MB [L4]) |
| **Vision** | memory.sqlite | 1,536 B print + < 1 KB labels [L1][L7] | Newest 2,000 | about 5 MB | Window |
| **Aggregates** | memory.sqlite | ≤ 128 KiB active, 14.3 KiB dormant | Every camera, every era until superseded | about 1.3 MiB (55 models) | Old-era buckets dropped after the new era passes the n_eff threshold, unless a check baseline pins them |
| **WAL** | memory.sqlite-wal | 44 KB per photo transaction committed while a read is open [L14] | — | 4 MiB after each reset (`journal_size_limit` [55]); **only under the short-read rule** | Readers page by keyset in short statements; `wal_checkpoint(TRUNCATE)` after each batch; log a WAL above 64 MB with the age of the oldest open statement |
| **Backups** (new) | `memory.backup-A/B.sqlite`, Application Support | `VACUUM INTO`: 46.7 MB, 2.4 s wall, 0.29 s CPU for a 63.2 MB file holding every tier [L13] | Two, rotated weekly; `integrity_check` of each new copy recorded in Settings | ≤ 2 × the compacted DB (93 MB measured) | Rotation; skipped when opportunistic capacity (when > 0) is under 4 × the DB size |
| **Derivatives** | `Caches/IQCoach/derived` | mask 6–17 KB; non-PhotoKit thumbnail 5.9–8.6 KB + preview 61–63 KB [L7] | Mask for analysed photos; thumbnail and preview only where PhotoKit cannot render | **64 MB** | SIEVE [127] |
| **Coaching state** | `preferences.json` | finished check collapsed to about 40 B [L5] | Statements, open checks, ≤ 50 verdicts | < 1 MB | User controls (R12) |
| **runs/** | — | — | Nothing (`serve` writes no run folders) | 0 | — |

**Worst case at 54,000 photos** (**Corrected**): ledger 18.3 + window 32 + vision 5 + aggregates 1.3 + derivatives 64 + WAL 4 ≈ **125 MB** for the memory itself, flat in the number of runs; about 144 MB at 110,000 photos. With the draft's §4.4 ledger as written it would be about 142 MB (about 150 MB with an eager cloud alias); the draft's "122 MB" used a ledger figure 2.3–4.8 times too small [L12]. On top of that: the two backups (≤ 93 MB measured) and the purgeable reservoir (≤ 1 GB). The WAL term holds only under the short-read rule; an hour-long open read at 1 photo a second would add about 160 MB until it ends [L14].

**Today's trajectory:** 4.77 MB per photo per import, plus 43 duplicate copies already on disk.

**Why live ledger rows are never evicted.** Re-presenting an evicted live row is not "only a re-measure": with originals pruned, it is a download (median 0.555 s, 4–15 MB) plus about 2 s of CPU [L10]. The draft's fixed 32 MB cap, oldest captured first, would have evicted 10,000 live rows at 54k (about 47.7 GB to re-present) and thrashed as each re-added row pushed another out [L12]. A ledger over the tripwire is shown in Settings with its cause; the user decides (Forget camera, Forget before date).

**Download and restore budget** (**Corrected** from "20 photos or 100 MB per session") [L10]:
- Background spending is per day and set by the network path [163][164]: on an unmetered path up to 500 photos and 2 GB a day with 2 workers; nothing when `NWPath.isExpensive` or `isConstrained` is set.
- Never more than about 1 % of free space a day, read from `volumeAvailableCapacityForOpportunisticUsage` (0 or nil means unknown, so spend nothing) [33][166], because downloaded originals stay inside her Photos library until the next sweep.
- A batch she starts may use important-usage capacity, still above the free-space reserve.
- Free-space reserve: max(64 MB, 3 × the largest original + 2 × `journal_size_limit`), re-checked before each download and each photo; below it the batch stops. APFS returned ENOSPC with 6.4–6.9 MB still reported free [L13].
- Result: a full Active restore (1,296 photos, 3.94 GB) takes about 3 days instead of 65 sessions, and with the reservoir it is no longer on the critical path.
- These limits are judgement (risk 14).

**RAM budgets.**

| Component | Budget |
|---|---|
| App image `NSCache` | `totalCostLimit` 64 MB with cost = `bytesPerRow × height`, plus a `countLimit`, because the cost limit "is not a strict limit" [29][30]. Drop the `ThumbnailStore` dictionary. |
| `ClippingMaskStore` | 32 MB, in the same way |
| List views | ~130 B `PhotoSummary` rows paged by keyset on (`captured_ts`, `id`), 200 rows per statement, each fully stepped and reset before the UI uses it [L6][L14] |
| Camera aggregates | ≤ 128 KiB, loaded only while that camera is viewed |
| Python worker | ≤ 2 at a time **per machine** (the batch lease, §4.9), each peaking at 1.6–2.9 GB per image [L7] (0.9–1.5 GB measured under heavy memory compression [L13]). Recycle after 25 images, or when *current* RSS between images (not `ru_maxrss`, a high-water mark) exceeds 1 GB. These thresholds are proposals, to be validated in T6. |

### 4.9 Cross-process protocol (Python analyzer ↔ Swift app)

**Process.** `python -m iqa serve --memory <db> [--no-paths]`, long-lived, with no matplotlib import and no report. Its stdin and stdout carry UTF-8 JSON lines.

```
→ {"op":"hello"}
← {"hello":{"schema":1,"analyzer_key":"m9-r30-s0","era":"<16 hex>","hash_pipeline":1,"env":{…}}}
→ {"op":"analyze","job":"j42","sha256":"<hex>","bytes":5712345,"path":"<staged file>",
   "source":{"kind":2,"locator":"<localIdentifier>"},"rendition":"original","want":["mask"],"cpu_budget_s":60}
← {"job":"j42","status":"done","sha256":"<hex>","cpu_s":3.1,"wall_s":3.4,"rss_mb":610}
   status ∈ done | not_capture | sha_mismatch | failed | timeout | env_error
   env_error carries {"error_class":"vanished|oserror|memory|sqlite|enospc|signal", "errno":…}
→ {"op":"shutdown"}
```

**Leases** (new) [L13]. All are `flock(2)` locks on files in `Application Support/IQCoach/` [195]: an uncontended acquire and release costs 1.7 µs, and a lock is free within 245 µs of its holder's SIGKILL.
- **`memory.lock`, the batch lease.** The process that orchestrates a batch takes `LOCK_EX|LOCK_NB` and holds it until the batch ends: the app for its imports (its `serve` children write under it; SQLite's own locking orders their transactions), or a CLI `iqa analyze --memory` run. Migrations, `iqa memory compact/forget` and the app's Forget everything take it too, as does the change-token update. Only one batch therefore runs per machine, which is what keeps it at ≤ 2 workers. Small app-owned UPSERTs (`app_state`) do not need it. The CLI waits and prints the holder's pid and start time (in [L13] the CLI waited 337 s, then had 5 hits and 1 miss); `--no-wait` exits 75. Never lock `memory.sqlite` itself: closing any descriptor of that file drops SQLite's POSIX locks [63].
- **`orchestrator.lock`, the importing instance.** The app takes it at launch. A second instance, whether from `open -n` or the binary run directly (`--snapshot` excepted), becomes a viewer: it browses the memory read-only, imports nothing, disables Settings' destructive actions and does not write `preferences.json`. With `--analyze-photos N` it exits 75 with a sentence naming the running instance. `LSMultipleInstancesProhibited` cannot do this job: it governs launches by more than one *user* [196].
- **Staging ownership.** Batches are `staging/<pid>-<random>/` with an `.owner` file on which the app holds `LOCK_SH` for the whole batch. The analyzer child takes its own `LOCK_SH`, because a child started with Foundation `Process` inherited no descriptors ≥ 3 (measured). The sweep tries `LOCK_EX|LOCK_NB` per folder and deletes only when it gets the lock; a folder without `.owner` goes only when older than 1 h. Measured: 2.6 ms; it kept a live owner's and an orphaned child's folders and removed a dead owner's and a legacy one. This replaces `Staging.sweep()` and its unconditional call in `AppModel.launch()`, which deleted the other instance's batch in 12 of 12 trials.
- A lease row in `meta` was rejected: it needs a database write, which fails on a full disk, and a crash leaves it held.

**Writers.**
- **Python** writes `content`, `source` for completed jobs, `summary`, `detail`, `ring`, `bucket`, `era` and `meta.seq`. It uses `sqlite3.connect(db, timeout=5.0, autocommit=True)` with explicit `BEGIN IMMEDIATE` and one transaction per image.
  - Writes are UPSERTs, never a read followed by a write: deferred read-then-write failed 52 % of the time with `SQLITE_BUSY_SNAPSHOT` [L4][60][61].
  - The legacy default transaction mode of Python's `sqlite3` "will change" in a future release, so autocommit is set explicitly [65].
- **Swift** writes `app_state`, `meta` (change token, audit counts, disabled strata, authorization state) and `source` rows whose status it decides itself (`not_capture` at S1, `cloud_deferred`, `unavailable`, `deleted`), also with `BEGIN IMMEDIATE` and UPSERTs.
  - **Measured** (**Corrected**: the draft's 0-of-6,000 figure had two Python writers): Swift on Apple's system SQLite 3.51.0 against the Python writer on SQLite 3.53.4 with a reader, 3 trials of 3,000 + 3,000 transactions: 0 failures on either side, Swift p99 2.8–5.1 ms, Python p99 4.7–6.6 ms, reader maximum 5.6 ms, `integrity_check` ok [L14]. The two library versions share one WAL file without trouble in this test.
- **Error classes** (each pinned by a test; T22) [L13]:
  - Cache `failed_once` only for a decoder error on bytes whose SHA-256 and byte count were just verified and that still exist; it becomes `failed_final` on a second failure in a later run. So the worst case is one extra measurement per file per analyzer key.
  - Never cache: an OSError with an errno, MemoryError, sqlite3.Error, a vanished file, a SHA mismatch, or a worker killed by a signal the parent did not send. Today `cmd_analyze` catches every `Exception` per file, and the spec's rule ("a measurement exception marks the photo failed") would turn these into permanent negative entries.
  - Stop the run on ENOSPC and on SQLite errors; skip the photo on the others.
- **Change token.** Swift writes it by compare-and-swap against the value read when the batch started, in the same transaction as the source updates, and only when the analyzer exited 0 and the batch had no environmental errors. A failed swap writes nothing; the next run re-fetches, and repeated photos are O(1) hits. Last-writer-wins advanced the token past 3–5 unmeasured photos on a full disk, and past a destroyed batch in 12 of 12 concurrency trials [L13].

**Readers.**
- Swift opens a read-write connection with `PRAGMA query_only = ON`. `SQLITE_OPEN_READONLY` failed with `SQLITE_CANTOPEN` when no `-wal`/`-shm` files existed [L4].
- It refreshes on `done` lines or when `PRAGMA data_version` changes [55].
- **Short reads only** (**Corrected**: the draft's reader test reset its statements every 2 ms and never measured a long read). One statement stepped slowly over 54,000 rows let the WAL reach 85.2 MB while 2,000 photos committed; keyset pages of 200 rows, each its own statement, held it at 5.0 MB [L14]. Lists therefore page by keyset (`WHERE (captured_ts, id) < (?, ?) ORDER BY captured_ts DESC, id DESC LIMIT 200`), and every statement is fully stepped and reset before the UI uses its rows. No transaction spans a UI event. A debug check logs any statement open longer than 1 s.
- One actor owns each connection (`SQLITE_OPEN_NOMUTEX` is safe under that discipline [56]).

**Migrations.** Gated on `user_version`, run inside `BEGIN IMMEDIATE` under `memory.lock`. A side that finds a newer `user_version` than it knows opens with `query_only` and asks to be updated.

**Damage and a full disk** (new) [L13].
- **Declaring damage.** Only from a fresh connection, under the batch lease, with free space above the reserve, and only on `SQLITE_CORRUPT` (11), `SQLITE_NOTADB` (26) or `quick_check` ≠ ok. FULL (13), the IOERR family (4874 and 1546 were seen), CANTOPEN (14), BUSY, NOMEM and READONLY are environmental: stop, show a message, keep the file [60]. An open reader saw SQLITE_CORRUPT on a file that passed `integrity_check`. The spec's "move a damaged file aside and start fresh" would, on a full disk, have renamed a healthy memory and then failed to create a new one.
- **Recovery ladder.** (1) REINDEX when only `integrity_check` reports index errors; this is lossless [191]. (2) Otherwise rename the damaged trio aside, run `/usr/bin/sqlite3 … .recover` into a new file (4.3–84.5 s; 53,841–54,000 of 54,000 assets back), and run `integrity_check`. (3) Merge the newest backup by `sha256`, never downgrading a newer row. (4) Rebuild the archive from the ledger. (5) Swap in by rename. (6) Keep one `.bad` file until the next good backup. Start empty only when no ledger survives in any copy.
- **What a loss costs.** Archive: nothing, it rebuilds from the ledger's headline columns (204 of 204 buckets exact in 0.45 s). Window rows: re-measuring 5,693 photos, about 27 GB of downloads at the copies' 4.77 MB mean (about 55 GB at the library's 9.67 MB) without the reservoir. Source rows: re-linking means downloading and hashing every original, with no re-measure. Asset rows: everything is measured again. Hence the backups.
- **Backups.** Weekly `VACUUM INTO` copies `memory.backup-A/B.sqlite` (46.7 MB, 2.4 s wall, 0.29 s CPU each; the target must not exist [187]); `integrity_check` of the new copy (0.31 s CPU) recorded in Settings. They bound the loss to one week of measurements.
- **Payload checksums.** `crc32` on summary, detail and bucket blobs, verified on read (about 46 KB at 54k photos). On a mismatch, a summary or detail becomes a miss (re-measured if the photo is presented) and a bucket is rebuilt from the ledger. `cksumvfs` (8 B per page, verified on every read [193]) is optional, if both Python and Swift can load it.
- **A lost WAL tail.** `meta.seq` is incremented in every photo transaction; after each run it is written to an fsync'd sidecar, `memory.seq`, by atomic rename. On open, a database `seq` below the sidecar's means "N photos measured on <date> were lost and will be measured again". A WAL cut, or one flipped bit that dropped 99 of 200 committed transactions, is otherwise silent to both checks.
- **Viewing on a full disk.** When opening fails with CANTOPEN or IOERR_SHMSIZE and no `-wal` file exists, the app may open `file:…?mode=ro&immutable=1` for display only; it read all 54,000 rows with no free space. Never when `-wal` exists or a writer may run [194].
- **Checks.** `quick_check` once per analyzer run under the lease (about 150 ms of CPU at 54k with every tier, not the draft's 15 ms), not on every app read; `integrity_check` weekly on the backup copy.

**Avoiding corruption** [63]:
- the database is never on a network volume;
- `-wal` and `-shm` files are never deleted or renamed while any connection may be open: deleting `-shm` under live connections lost a writer's 400 committed rows in 3 of 3 trials [L13];
- Forget everything takes `memory.lock` exclusively (and refuses with a message when it is held), closes the app's own connections, renames the trio aside, and only then deletes;
- copies are made with `VACUUM INTO`;
- no `fork()` while a connection is open.

**CLI.** `iqa analyze … --memory PATH` skips known content and still writes the run's `results.json`, marking each record `"cached": true` or false.
- A `--no-report` flag skips charts.
- `analysis_s` is timed with `perf_counter`, and `cpu_s` is added.
- The record always carries `sha256`. `--no-paths` removes paths and locators only.

**`--no-paths` (R9)** (**Corrected**).
- Exports contain no paths or locators. `sha256` stays, so a `--no-paths` results.json can still be re-joined to preferences keyed by `sha256`. A separate `--no-ids` also drops `sha256`, for publication, and marks the export as not re-joinable. The draft dropped `sha256` under `--no-paths`; at HEAD the app's Analyze Folder passes `--no-paths` (`AppModel.analyze(folder:)` → `runner.analyze(folder:keepPaths: false)`), and the working tree no longer does [R].
- Folder locators in the store are `HMAC-SHA256(install_key, realpath)`. That is pseudonymisation, not secrecy: anyone holding the key can confirm a guessed path, and folder paths are low-entropy (`/Users/<name>/Pictures/…`). The draft kept the key in `meta`, in the same file, so the database alone allowed a dictionary attack. The key now lives in `install.key` (0600) beside the database, never in it and never in an export, and the app passes it to the analyzer child. The database is documented as private data, never a publishable artefact.
- The stat fast path still works. The app shows folder photos from stored derivatives instead of paths. Today it shows nothing for them [L7].

### 4.10 Coaching outputs the memory enables

| Output | Memory it reads | Gate / rule | Source |
|---|---|---|---|
| **This photo vs your usual** ("more blown highlights than 95 % of your recent iPhone 17 Pro Max photos, 2.2 % of the frame") | Mid-rank percentile in the camera's decayed histogram of original renditions | Only at p ≤ 10 or ≥ 90, with n_eff ≥ 20. "Softer than usual" only when the photo's `mtf50_median_ci_hi_cpp` is below the camera's p10 (per-image CI about ±30 %) | [L5][132] |
| **The one thing**, recent-weighted | Decayed share counters plus the Wilson interval on n_eff | Existing severity, evidence-word and 10 %-prevalence gates [R]. The action is written as an if-then sentence | [138] |
| **Since <landmark>** | Buckets on either side of a pre-registered date | Only landmarks fixed in advance: a check's start, the first photo from a new camera, or a landmark she declares. **Never search for a split date** (measured trap, §3.5) | [139][L5] |
| **Check follow-ups** | Collapsed check record plus buckets | "Still holding: k of n" at +30 and +66 days after "It worked", then silence | [137][155][156] |
| **Burst siblings** | B0/B1 groups plus pixel counts (clipping) | Highlight advice applies in 11 of 35 ten-second groups on the 17 Pro Max. **Never "sharpest" from natural-edge MTF50** when the ratio is inside the CI band. The keeper is her `userPick` | [16][L5] |
| **Set-aside card returns** | Snapshot {share, n_eff, severity, grade, date} | Returns only if the Newcombe interval of (current − snapshot) excludes 0 **and** the change is ≥ 10 points, or the severity word changes. At most once per 30 days. Replaces the 25 %-growth rule | [141][R] |
| **Typical vs your best** | Decayed median, plus p90 as a target | Report a gap only above a stated noticeability unit; label it Moderate | [146][149] |
| **N more photos make this firm** | Current decayed hits/n | Smallest extra n at which the Wilson interval clears the rule's line | [122] |
| **Camera resting** | Freshness clock | Active / Resting / Archived (§4.7) | [L5] |
| **Same scene on two phones** | B1 + B3 (Vision ≤ 0.50 within ±60 s) | Only with at least 2 cameras in the window; for comparison, not ranking | [L1] |
| **Includes your edits** | `rendition` | An edited, external-edit or unqualified picker photo shows its own numbers with this label and is left out of every camera figure (R13) | [L11] |
| **Method changed** | Paired old/new values from the re-measure reservoir | After a `pixel` bump: "The new method reads your iPhone 17 Pro Max photos +3.9 % sharper (±4 %, 26 photos); earlier figures are labelled with the old method". Shown once per bump | [L10] |
| **What the coach remembers** panel | Per-tier counts, bytes, oldest date; per-camera state and reason | Every card says why it is remembered. Controls: Forget photo / camera / before date, Reset coaching (keeps the ledger), Clear cache. Each states its consequence first | [48][142][151] |

**No-go list:** no streaks, no overall-score trend, no badges or notifications, no comparison with other people or with published camera scores [129][132][140].

On-device processing counts as "not collected" under Apple's App Privacy definitions [49].

### 4.11 Migration from today

1. **Ingest the current copies before deleting anything.**
   - Hash every file in `photos/*/`.
   - Re-measure the 50 unique contents under the new analyzer key while the copies still exist (about 2–3 CPU-minutes). Legacy records carry no version, so they cannot be trusted as current.
   - Seed the re-measure reservoir from these copies (up to 64 per Active camera, within its byte cap) rather than deleting them all: they are the only originals of the 10-15 and 10-23 runs still on this Mac outside the Photos library [L10].
   - Build a bridge table from old `PhotoKey`s to `sha256` out of the `runs/*/results.json` records.
2. **Re-key** intent tags and `CaptureCheck.after` through the bridge. Merge the 3 photos that exist under two names.
3. **Clean up with the user's confirmation.** Ask before deleting each `photos/<stamp>/` folder whose every hash is in the DB (or the reservoir), and the empty run folder. This is the app's own data; the Photos library is never touched.
4. **Code changes:**
   - first, the leases, the owner-aware sweep and the error classes (§4.9): they fix defects in the working tree today, where a launch sweep can delete another instance's batch and a FileNotFoundError is cached as `failed` [L13];
   - gate and sign with the `.photo` `PHAssetResource` size, not `PHAsset.pixelWidth` (`PhotosImporter` L128, L133-134);
   - route an authorized pick with an identifier through the PhotoKit path, and record `rendition`;
   - read `SubSecTimeOriginal` and `OffsetTimeOriginal` in `iqa/imageio.py`, and stop using tag 306 as a capture time (a `schema-add` bump);
   - keep `sha256` in `--no-paths` exports and move the path-hash key out of the database;
   - pass `photoLibrary: .shared()` to the picker;
   - import through `FileRepresentation`;
   - stream and hash with `requestData`;
   - merge instead of replacing the library (`AppModel` L71);
   - replace `ThumbnailStore` and `ClippingMaskStore` with cost-limited caches;
   - persist `ContentIdentifier` results by `sha256`.
5. **Suggested order of work:**
   - (o) leases and error classes, which fix live defects.
   - (i) identity, ledger and no copies. This is the biggest win and removes the 423 MiB growth.
   - (i′) the reservoir and the bump classes, before the next `pixel` bump.
   - (ii) the `serve` worker and per-image commit.
   - (iii) buckets and decay.
   - (iv) coaching outputs.
   - (v) advisory grouping.

---

## 5. Alternatives considered and rejected

| Alternative | Rejected because | Evidence |
|---|---|---|
| `camera\|file\|datetime`, path or filename as key | Collides for 3.1 % of rows at 1-s resolution, for positional picker names and across the IMG_9999 wrap; paths change every run | [L1][L7][50] |
| `localIdentifier` as the identity | Device-local; "can change … under certain conditions" | [3][6][7] |
| `modificationDate` as the invalidation key | Changes on any metadata change; DTS recommends a content hash | [2][8] |
| Partial hash (size + head + tail) as a match | Not a proof of identity; PhotoKit streams sequentially | [84][13] |
| XXH3 / XXH128 | Not cryptographic; saves about 1.5 ms (0.06 %) | [82][L7] |
| BLAKE2b / BLAKE3 | 2.2× slower here; no system library on the Swift side | [L7][83] |
| Decoded-pixel hash as the key | Depends on the decoder (0 of 11 matched); 1.46 s under load; a downsample hash missed a one-pixel edit in 50 of 50 | [L1][L8][86] |
| HEIC `mdat` hash for "metadata-independent" identity | Exif and XMP live inside `mdat` | [L1] |
| Perceptual hash or Vision print as "already analysed" | Blur shifted MTF50 by −18.5 % at 0–1 bits; Vision has no separating threshold | [L8] |
| 64-bit aHash / dHash / pHash | Burst siblings at 0–4 bits; aHash 1.02 % false matches | [L1][L8] |
| PDQ | 0 of 51 related pairs at ≤ 31; a 10 % crop moves it a median of 88 bits | [L1][88][89] |
| NeuralHash | Not public; crafted and natural collisions | [95][96][97] |
| Photos' private fingerprint, EXIF `ImageUniqueID` | Private or reported NULL; present in 0 of 50 | [98][99][L1] |
| Shipping a dependency on `Photos.sqlite` `ZFINGERPRINT` | It verifies every original without a download (93 of 93 matches), but it is private and undocumented; kept as a research and CI instrument behind `--measure-photokit` | [L10] |
| dHash256 ≤ 24 to confirm a capture link | Links 18 of 1,000 real crop geometries and 1 of 50 straightens at 2.6°; its burst window rests on 23 pairs (95 % bound about 13 %) | [L8][L11][162] |
| Picker bytes for an authorized pick that has an identifier | The picker reportedly returns the adjusted rendition even under `.current`; the PhotoKit `.photo` path gives the original and the L0 alias | [169][L11] |
| `PHAsset.pixelWidth` for the capture gate and the signature | It is the edited size: 48 cropped captures rejected, and the signature changes on 437 geometric edits | [171][L11] |
| Bloom / cuckoo / xor / binary fuse filter as the seen-set | Any false positive is a permanent silent skip (about 90 of 54k at 1 %); cannot return the stored row | [117][118][119][120][L3] |
| Keeping every original (or a GDSF cache of them) | About 515 GB at library scale; 423 MiB after 5 runs today. A bounded uniform reservoir (≤ 1 GB) is kept instead | [L9][L10][128] |
| 0 bytes of originals at rest (the draft) | 99.9 % of captures are cloud-only and app downloads leave at the next sweep, so each `pixel` bump would cost 3.94 GB of downloads for 4 cameras; 6 of the last 10 transitions needed pixels | [L10] |
| A session download cap of 20 photos or 100 MB | 65 sessions to restore 4 Active cameras; the window never restores at development bump rates | [L10] |
| One growing JSON file or JSON Lines | 20.9 s / 962 MB to decode at 10⁵ records; a single bad byte loses the file | [L4] |
| SwiftData | macOS 14+, reported regressions, Python cannot read it | [44][45][46] |
| WITHOUT ROWID for wide rows | 2.5× the bytes | [L4][L7][58] |
| Per-group versions with a per-photo `measurement` table (the draft's decision 5) | 338–341 B per photo, half the ledger; saves CPU but no downloads; module touches over-predicted changes in the replay. (The draft rejected one global version because "a forgotten bump serves stale numbers"; the AST tripwire and the corpus check now catch that) | [L4][L10][L12] |
| Decoder library versions in the cache key (Bazel precedent) | An upgrade that changes no output would re-measure every photo; the corpus re-run turns real changes into a `pixel` bump | [68][L10] |
| Hash of the module source as the version | A docstring edit re-measures 54k photos (about 42 h) | [L4][70] |
| t-digest, KLL, P², GK | No guarantee or randomised; 3.2–3.8 % rank error (t-digest); weighted KLL support unclear; P² not mergeable | [104][105][107][109][110][L3] |
| Moments only | Not robust to a frame with 14.7 % clipped | [L3] |
| Equal lifetime weights (today) | Step simulation: lifetime median 0.174 vs decayed 0.235, against a true 0.24 | [L3] |
| Decay by photo count | Changes with arrival order under backfill; cannot be summed over buckets | [L3][101] |
| Time decay with a short fixed H | D850 falls to n_eff 3.0 at H = 30 d | [L5] |
| EWMA at λ = 0.2–0.3 | n_eff 6.7–9, far below the noise of a single image | [103][L3] |
| All-time best and worst heaps | Anchor the advice on old work | [L3][L5] |
| ARC / W-TinyLFU for measurement eviction | A miss is a deterministic re-measure; an explainable recency-plus-pins rule is preferred | [125][126][L4] |
| A fixed byte cap on the ledger, evicting the oldest captured | Evicted 10,000 live rows (18.5 %) at 54k, 25,750 with an eager cloud alias, and thrashed | [L12] |
| A lazy cloud alias created after a `localIdentifier` miss | After a rebuild the stored identifier no longer resolves, so there is nothing left to map from | [5][12][L12] |
| Disabling L0 everywhere after one audit mismatch | About 130 MB of downloads per newest-40 import at today's local share; expected exceptions would trip it | [L10] |
| A lease row in `meta`; `LSMultipleInstancesProhibited` | The row needs a database write (fails on a full disk) and outlives a crash; the plist key covers multiple users, not a second instance | [196][L13] |
| "Move aside and start fresh" on any open error | On a full disk SQLite reports FULL, IOERR and CANTOPEN; it would rename a healthy memory and fail to create one | [60][L13] |
| Caching every measurement exception as `failed` | A swept staging file became a permanent `failed` in 2 of 2 runs | [L13] |
| Long-lived read transactions or slowly stepped statements | The WAL grew to 85–88 MB while 2,000 photos committed | [54][55][L14] |
| A new process plus charts per batch | 0.3–0.7 s of imports plus 1.55 s of charts per run; 9.7–15 s of font-cache rebuild in the sandbox | [L6][L7][152] |
| Searching for the best "since" date | Finds changes that are not there | [L5] |
| "Sharpest frame" from natural-edge MTF50 | Ratios of 1.20 and 1.26 sit inside the ±30 % per-image band | [L5] |
| Set-aside card returning on 25 % count growth | Nags while behaviour is unchanged; repeated reminders lose about 30 % acceptance each | [R][141] |
| Reading `Photos Library.photoslibrary/originals` directly | Private layout; originals are transient (0 of 1,035 still at their paths) | [L1][L2] |

---

## 6. Risks, open questions, and tests

### 6.1 Risks and open questions

1. **Is `.photo` immutable?** Partly answered [L10]: 93 of 93 retrievals matched the library's own fingerprint (95 % bound 3.2 % per retrieval), and no `.photo` fingerprint differs from its original-stable hash across 62,013 assets, 705 of them edited. Still not done: hashing `.photo` before and after an edit made on the device (Adjust Date & Time, Adjust Location, Revert, Use RAW as Original). *Mitigation:* the stratified audit, strict mode and the resource-signature check; the PickerProbe protocol (§6.2) closes it.
2. **`localIdentifier` stability** after migration or repair (UNVERIFIED [6][7]). A change only causes a miss, which is safe. Without a cloud alias, recovery costs a download plus a hash per photo as it is presented, never a re-measure, as long as the content row survives [L12].
3. **Retention window of the persistent change history** (undocumented [11]). The 3105 fallback reconciles. Under limited access the feed covers only the selected assets [11]; whether macOS ever grants `.limited` is UNVERIFIED (§3.2).
4. **The picker:** whether `itemIdentifier` is set without authorization (the documentation and DTS disagree [18][19]), and whether an edited pick under `.current` delivers the adjusted rendition on macOS 26 (FB9706029 [169]; no edited asset has been picked). The design no longer depends on either: an authorized pick takes the PhotoKit path, and any other pick is hashed and labelled `unknown`.
5. **Downloads grow her Photos library.** Answered [L10]: a downloaded original stays in the library until the next space-driven sweep (72 h to 86 days observed), and the 10-23 picker run added exactly its 27.5 MB. The per-day budget and the 1 %-of-free-space rule bound the effect.
6. **Capture time.** Corrected (§4.7): iqa reads only `DateTimeOriginal` and falls back to tag 306, a modification time. Still open: a date adjusted in Photos may change `PHAsset.creationDate` but not the original's EXIF (UNVERIFIED; publicspace.net reports that originals keep their EXIF [181]). Decay uses EXIF, consistent with the measurement; record both.
7. **Vision print stability** across Macs and OS updates within revision 2 (UNVERIFIED; one machine). Store the revision and recompute on mismatch. Prints are advisory only.
8. **dHash256.** The 23–27 window comes from 50 photos (4 HEIC) and 23 burst pairs: the 95 % upper bound on false burst merges is about 13 %. It does not survive real crops (18 of 1,000 linked). It no longer decides any link on its own; re-measure the window on a burst-rich, HEIC-heavy sample before relying on it even as a tiebreaker.
9. **The session correlation ρ = 0.34 was assumed.** Coverage figures depend on it. Measure the within-day ICC on the library.
10. **Determinism.** With identical code it held on 2–3 files [L4][L7] and on the 20-canary corpus at load about 100 [L10]. Across numpy, OpenCV, Pillow, libheif or LibRaw upgrades it is untested, and so is RAW/DNG. The corpus re-run on every upgrade covers it; add a DNG.
11. **Timings come from a loaded machine.** Treat the absolute ms as upper bounds. Instrument in-app with `os_signpost` behind `--measure-photokit`: `fetchPersistentChanges` after a day or a week, `cloudIdentifierMappings` for 389 and for 5,000 IDs, `assetResources(for:)` per asset, and first-image latency of `PHCachingImageManager` [L2].
12. **`volumeAvailableCapacityForImportantUsage`** returned 0 inside the research sandbox, real values unsandboxed for the home volume, and 0 for a mounted image [L2][L13]. Treat 0 as unknown and test inside the signed app.
13. **Portrait-mode `.photo` content.** Partly answered [L11]: every one of 39 Portraits keeps a separate render beside its original, which implies `.photo` is the image without the effect, the right input for MTF50. Not proven by decoding both.
14. **Several design thresholds are judgement:**
    - half-life ladder, n_eff ≥ 30, 90-day freshness;
    - window of 500 per camera;
    - 64 MB of derivatives;
    - audits of 5 local and 1–2 cloud per session, 10 % after a mismatch until 300 clean;
    - 60 s CPU budget and 2 attempts;
    - reservoir of 64 per camera, 256 MB per camera, 1 GB total;
    - 500 photos, 2 GB and 1 % of free space per day; 12 h debounce;
    - T_MAX = 10,000 tombstones and the 512 B-per-row tripwire;
    - `clock_suspect` limits (1 day ahead, before 2000);
    - +30 and +66 day follow-ups.
    Expose them as constants in one place and document them in the Method tab.
15. **The forward-decay patent** (US 8,595,194 [124]). The method is algebraically classical exponential decay (Cormode §III-A). Legal status UNVERIFIED.
16. **Bump frequency after release.** 10 transitions in 10 days were measured during development [L10]. The reservoir and the debounce are sized for that rate; a stable analyzer would make them cheap insurance. Unknown until it happens.
17. **The reservoir as a proxy.** A uniform 64-photo sample estimates an era shift to about ±4 % (MTF50 mean) and ±13 points (share of large SNR drops) [L10]. Window photos not yet re-measured stay labelled with the old method; the reservoir does not make them current.
18. **Overlays for cloud-only photos.** Whether `PHImageManager` returns an `.unadjusted` image at overlay resolution with network off is UNVERIFIED (§3.2).
19. **The cloud identifier.** Its archival string length (assumed 100 B) and its stability across calls and edits are UNVERIFIED; `idprobe` measures both [L12]. The design ships without a cloud alias until then.
20. **Concurrency was emulated.** The lease and sweep results come from a Python stand-in for the app; the real binary was not run with `open -n` [L13]. The Swift writer test used a scratch program, not `MemoryStore` [L14].
21. **The `ZFINGERPRINT` formula** was inferred and checked on 124 files only [L10]. It is used for research, never shipped.
22. **External edits** are detected only through EXIF `Software` / XMP `CreatorTool`. An exporter that strips both leaves a file `unknown`; it then enters aggregates only if its area is a native size for that camera, so a crop still stays out, but an uncropped tone edit would get in.
23. **The WAL rule depends on discipline.** Any SwiftUI view that keeps a statement open across UI events breaks the bound (44 KB per photo committed meanwhile). T29 and the debug check catch it in development only.

### 6.2 What to validate on device (not testable headless)

The research sessions could not run PhotoKit: TCC returned "denied" or "notDetermined" for every binary they started, and granting Photos access, changing an app's privacy state or creating a macOS user are Allison's decisions. Three read-only probes are built; the `/tmp` paths do not survive a reboot, so copy them first.
- **AvailProbe** [L10] (`/tmp/claude-501/icloudcost/probe/AvailProbe.app`, source `main.swift`). Launched by Allison so that TCC asks about the probe itself: `open -W …/AvailProbe.app --args census <out>/census.json`, then `download 50 <out.json>` (a 60 s re-check and a second download for SHA-256 are built in), and `recheck <in> <out>` after 24 h. It re-measures availability, download latency, retention and byte stability through PhotoKit.
- **PickerProbe** [L11] (`…/scratchpad/edits/PickerProbe/`). Run in a separate macOS user account without iCloud, never by switching her System Photo Library [180]. Import copies of an iPhone JPEG and HEIC, a D850 NEF+JPEG pair and a Portrait HEIC; duplicate one asset per edit (crops keeping 90 % and 40 %, Exposure +1, Adjust Date & Time, Adjust Location, an edit then Revert, Use RAW as Original, Portrait on and off). Run it with full access before and after the edits, then in each authorization state (notDetermined via `tccutil reset Photos dev.iqcoach.pickerprobe` without pressing Request; denied; limited if offered; full). Each row records the picker deliveries for `.current` and `.automatic` with and without a library, as `Data` and `FileRepresentation`; `itemIdentifier` and the fetch count; `.photo`, `.fullSizePhoto`, `.alternatePhoto` and `.adjustmentBasePhoto` hashes; asset size against `.photo` resource size; `hasAdjustments`, `adjustmentsState`, `adjustmentTimestamp` [173][174]; and the capture tags. Score with `dhash_pairs.py probe.jsonl`.
- **idprobe** [L12] (`…/scratchpad/ledger/idprobe`). With her consent: `idprobe 1000 out.json --request-access`. It reports identifier length statistics and shapes (never an identifier), mapping errors, the time of one batched call, whether a second call returns the same strings, and a 50-item round trip.
- **The real app binary**: `open -n` plus the binary with `--analyze-photos 5` plus the CLI (T23).
- Itemised PhotoKit costs (risk 11), thumbnails and overlays for cloud-only assets (risk 18), `volumeAvailableCapacity*` in the signed app (risk 12), and `requestData` streaming plus hashing throughput on a cold cache.

### 6.3 Tests, one or more per requirement

Following the repo convention, every statistic gets a synthetic ground-truth test before it ships.

| Test | Requirement | Method and ground truth |
|---|---|---|
| T1 Byte identity | R1 | Synthetic JPEG/HEIC from `iqa demo`. Flip one byte each at SOI+2, inside APP1 EXIF, DQT, the entropy data and the last byte: each must miss and re-measure. A byte-identical copy under a new name, folder or picker-style `NNN-photo.jpeg`: one content row, two sources, 0 re-measures. Ground truth: `cmp`. |
| T2 L0 audit | R1a | A fake PhotoKit adapter serves mutated `.photo` bytes under an unchanged `modificationDate` and signature in one stratum (camera × kind × availability). The audit detects it and disables L0 in that stratum only; lookups there hash, other strata still hit, and the stratum's audit rate is 10 % until 300 clean audits. A re-download made for a restore counts as a cloud audit. Each stratum's counter yields its own 3/n bound; an empty stratum reads "unaudited". |
| T3 O(1) hit | R2 | Ledger of 10³, 10⁴ and 10⁵ synthetic rows: hit latency within 2× across sizes. An instrumented file layer shows a hit opens only the hashed file (L2) or no file (L0/L1). |
| T4 Zero growth | R3 | Import 40 synthetic photos twice: second run 0 analyses, staging empty, DB page count unchanged, App Support byte count unchanged, reservoir unchanged. |
| T5 Budgets | R3 | Fill the window, derivatives and reservoir to 150 % of budget: eviction brings them to ≤ budget (reservoir ≤ 256 MB per camera and ≤ 1 GB, Algorithm R keeps a uniform sample); pinned rows survive; a fully stepped `incremental_vacuum` shrinks the file. The ledger is covered by T28. |
| T6 RAM | R4 | Cost accounting of the Swift `NSCache` with synthetic 800-px images stays ≤ limit plus one entry. The worker recycles after K images or above the RSS threshold (fake RSS source). At most 2 workers run per machine (with T23). |
| T7 Order invariance | R6 | Insert a synthetic stream (lognormal MTF50, normal SNR, zero-inflated clipping) shuffled, sorted and reversed: buckets equal to ≤ 10⁻¹² relative. A merged sketch equals one built once. |
| T8 Quantile error | R7 | Weighted quantile from the histogram vs an exact weighted quantile computed by sorting: \|error\| ≤ α (1 % MTF, 0.125 dB SNR, 5 % clipping), including after folds (2α/(1+α²)). Under- and overflow bins flagged. |
| T9 n_eff and freshness | R6, R7 | Poisson arrivals at rate r: n_eff within 2 % of 2.885·r·H. Kish n_eff invariant to reference time (documented property) while W and last-capture age drive the state machine (synthetic idle camera → Resting at 90 d). |
| T10 Interval coverage | R7 | 1,500 simulations, i.i.d. and clustered (known ρ): coverage of Woodruff with per-day n_eff ≥ 95 %; Wilson coverage for shares ≥ 95 % at n_eff ≥ 20. |
| T11 Tracking and false alarms | R6 | Synthetic MTF50 history whose median steps from 0.16 to 0.24: the bucket-decayed median equals the exact per-photo-weighted median within α (the bounded simulation gave 0.00 %). One year after the step at H = 90 d it is within 5 % of 0.24 (simulated 0.235, against a lifetime median of 0.174 [L3]). Under a null stream, a pre-registered landmark flags a change ≤ 5 % of the time. A best-split search is shown to exceed 5 %, which documents the trap. |
| T12 Versioning | R5, R11 | A `pixel` bump makes rows of the old era stale; a rollback (`==`) recomputes. The AST tripwire fails on a code change without a bump and passes on a docstring-only edit. A library upgrade with identical corpus outputs keeps the era; one with a differing output fails until a `pixel` bump is declared. Aggregates never combine two eras. |
| T13 Determinism | R1 | Golden corpus (synthetic plus canary, DNG included): two runs and two byte-identical copies give 0 differing fields. Early cutoff: a no-op re-measure leaves the buckets untouched. |
| T14 Crash safety | R10 | 100 trials of `kill -9` at random points of a batch: `quick_check` ok; no `content` row without its `era` row; staging swept by owner; the change token never ahead of the committed photos; the resumed DB equals an uninterrupted run (excluding timing columns). |
| T15 Concurrency | R10 | A Swift writer on the system SQLite (`app_state`, `meta`, `source` UPSERTs) and the Python writer (photo transactions), 3,000 transactions each, plus a reader polling every 2 ms: 0 failures, reader latency < 50 ms, `integrity_check` ok. Measured once as a harness [L14]; it becomes a test against `MemoryStore` and the real worker. |
| T16 Read-only Photos | R8 | Static test: no `performChanges`, `PHAssetChangeRequest` or `PHAssetCreationRequest` in Sources. Manual: an `fs_usage` trace of an import shows no writes under the library. |
| T17 `--no-paths` | R9 | Exported `results.json`/CSV contain no absolute paths or locators and do contain `sha256`; with `--no-ids` they contain no `sha256` either. A byte scan of `memory.sqlite` finds no plaintext folder path and no copy of the path-hash key. A `--no-paths` export re-joins to preferences by `sha256`. |
| T18 Input paths | R9 | The same synthetic file via fake PhotoKit, picker with ID, picker without ID, folder and CLI resolves to one `content` row with the right `source` kinds. A picker item with an ID under authorization takes the PhotoKit path (no `loadTransferable`) and adds `picked_via`, not a second source. While the status is notDetermined, the picker path makes no PhotoKit fetch. |
| T19 Near-duplicate tier | R1 | Synthetic textured images: q70, 50 % resize and 1 % crop give dHash256 ≤ 24; distinct images ≥ 57; an all-black decode is rejected. A blurred copy at dHash ≤ 1 is **still measured** (never skipped). |
| T20 Coaching rules | R12 | A stationary synthetic stream with growing n never brings a set-aside card back (the 25 % rule would). A shift of ≥ 10 points with an interval excluding 0 brings it back once, then not again within 30 days. "Sharpest frame" is withheld when the ratio is inside the CI band. |
| T21 Backfill stop | R5 | A synthetic camera with known SNR SD stops within ±10 % of the n predicted by the CI-width rule. |
| T22 CPU budget and error classes | R5, R10 | A fake decoder that exceeds 60 s of CPU is killed, stored `timeout_once`, retried alone in a later run, and becomes `timeout_final` only on a second timeout. Injected FileNotFoundError, OSError with an errno, MemoryError, sqlite3.Error, a SHA mismatch and SIGKILL are never cached; a decoder error on verified bytes becomes `failed_once`, then `failed_final`. A file truncated to 50 % is caught by the byte-count check. |
| T23 Instances | R4, R10 | `open -n` plus the binary with `--analyze-photos 5` plus the CLI on one memory: 0 duplicate analyses, 0 `failed` rows, one batch at a time, at most 2 workers, no other instance's staging deleted, the second instance a viewer that exits 75, and a change token that never regresses (the [L13] matrix as a test). |
| T24 Damage | R10 | The [L13] matrix: leaf and internal-page bit flips, WAL truncation and a mid-WAL flip, `-shm` deletion. The damage policy declares damage only from a fresh connection; the recovery ladder yields a ledger that passes `integrity_check`; the archive rebuilt from the ledger equals the stored buckets; CRC32 catches every record and archive flip; the `memory.seq` sidecar reports a lost tail. |
| T25 Full disk | R10 | A 300 MB APFS image: ENOSPC during staging, commit, checkpoint and open. 0 negative entries, token unchanged, staging empty, file kept (never "start fresh"); `immutable=1` viewing only when no `-wal` exists. |
| T26 Renditions and the gate | R13 | Fake PhotoKit: an asset whose current size is 3 MP and whose `.photo` resource is 12 MP is measured; its signature does not change when it is cropped. A Lightroom-`Software` file is `external_edit`; an edited or unqualified pick is labelled and leaves every aggregate unchanged; a qualifying `unknown` pick (native size, camera firmware, not a Portrait) enters. |
| T27 Capture clock | R14 | Synthetic EXIF: `DateTimeOriginal` + `SubSecTimeOriginal` + `OffsetTimeOriginal` parsed; tag 306 alone gives undated; a capture dated after `first_seen` + 1 day or before 2000 is `clock_suspect`, out of decay, and no weight exceeds 1; cross-camera windows use offsets when both photos have them. |
| T28 Ledger retention | R3 | `test_ledger_cap.py` [L12] as `tests/test_memory_retention.py`: 110,000 live photos, 20,000 tombstones, 300 pinned tombstones, 2,000 screenshot sources. Exactly the tombstones beyond T_MAX go, oldest deletion first; the live set is unchanged; every identifier still resolves after a 3105/3210 reconcile; over the tripwire is reported, not enforced. |
| T29 WAL bound | R3, R10 | The [L14] harness as a test: with keyset paging the WAL stays ≤ 4 MiB plus one checkpoint's worth while 2,000 photos commit; a statement held open is detected by the debug check, and after release one reset truncates the WAL to `journal_size_limit`. |
| T30 Bump classes | R5, R11 | A `migration` bump: the declared function applied to the old pinned corpus outputs reproduces the new ones exactly, and applying it to the store downloads and re-measures nothing. A `schema-add` bump leaves every old field unchanged. A `pixel` bump changes at least one field; otherwise the test asks for a re-pin. Two bumps within 12 h start one restore. |

---

## 7. Sources

Most sources were gathered by the researchers. The synthesiser re-fetched [1], [2], [6], [8], [17] and [54] on 2026-10-26. A few entries are background reading the researchers consulted and are not cited inline: 25, 26, 34, 57, 62, 66, 85, 87, 90, 92, 93, 112, 123, 131, 134–136 and 150.

### Apple platform
1. PHAssetResourceType: `.photo` "Provides the original photo data for its asset"; `.fullSizePhoto` "Provides a modified version of the original photo asset" (re-checked 2026-10-26) - https://developer.apple.com/documentation/photos/phassetresourcetype
2. PHAsset.modificationDate (re-checked) - https://developer.apple.com/documentation/photos/phasset/modificationdate
3. PHObject.localIdentifier - https://developer.apple.com/documentation/photos/phobject/localidentifier
4. PHCloudIdentifier - https://developer.apple.com/documentation/photos/phcloudidentifier
5. PHPhotoLibrary.cloudIdentifierMappings(forLocalIdentifiers:) - https://developer.apple.com/documentation/photos/phphotolibrary/cloudidentifiermappings(forlocalidentifiers:)
6. Apple Developer Forums thread 833047, localIdentifier reliability (Apple engineer, Jun 2026; re-checked) - https://developer.apple.com/forums/thread/833047
7. Apple Developer Forums thread 774303, localIdentifier after device transfer - https://developer.apple.com/forums/thread/774303
8. Apple Developer Forums thread 793303, detecting user-modified photos (DTS; re-checked) - https://developer.apple.com/forums/thread/793303
9. PHPhotoLibrary.fetchPersistentChanges(since:) - https://developer.apple.com/documentation/photos/phphotolibrary/fetchpersistentchanges(since:)
10. PHPersistentChangeToken - https://developer.apple.com/documentation/photos/phpersistentchangetoken
11. WWDC22 session 10132, Discover PhotoKit change history - https://developer.apple.com/videos/play/wwdc2022/10132/
12. macOS 27.0 SDK Photos.framework headers, read locally - file:///Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Photos.framework/Headers/
13. PHAssetResourceManager.requestData(for:options:dataReceivedHandler:completionHandler:) - https://developer.apple.com/documentation/photos/phassetresourcemanager/requestdata(for:options:datareceivedhandler:completionhandler:)
14. PHAssetResource - https://developer.apple.com/documentation/photos/phassetresource
15. PHAsset.burstIdentifier - https://developer.apple.com/documentation/photos/phasset/burstidentifier
16. PHAsset.burstSelectionTypes - https://developer.apple.com/documentation/photos/phasset/burstselectiontypes
17. PhotosPickerItem.itemIdentifier (re-checked) - https://developer.apple.com/documentation/photosui/photospickeritem/itemidentifier
18. View.photosPicker(…photoLibrary:) - https://developer.apple.com/documentation/swiftui/view/photospicker(ispresented:selection:maxselectioncount:selectionbehavior:matching:preferreditemencoding:photolibrary:)
19. Apple Developer Forums thread 807143, itemIdentifier always nil (DTS) - https://developer.apple.com/forums/thread/807143
20. PhotosPickerItem.EncodingDisambiguationPolicy - https://developer.apple.com/documentation/photosui/photospickeritem/encodingdisambiguationpolicy
21. FileRepresentation (Core Transferable) - https://developer.apple.com/documentation/coretransferable/filerepresentation
22. WWDC22 session 10023, What's new in the Photos picker - https://developer.apple.com/videos/play/wwdc2022/10023/
23. PHCachingImageManager - https://developer.apple.com/documentation/photos/phcachingimagemanager
24. PHImageManager.requestImage(for:targetSize:contentMode:options:resultHandler:) - https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:)
25. kCGImageSourceCreateThumbnailFromImageIfAbsent - https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimageifabsent
26. CGImageSourceCreateThumbnailAtIndex - https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)
27. VNGenerateImageFeaturePrintRequest - https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest
28. VNGenerateImageFeaturePrintRequestRevision2 - https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequestrevision2
29. NSCache - https://developer.apple.com/documentation/foundation/nscache
30. NSCache.totalCostLimit - https://developer.apple.com/documentation/foundation/nscache/totalcostlimit
31. Optimizing your app's data for iCloud backup - https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup
32. File System Programming Guide, macOS Library directories - https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
33. Checking volume storage capacity - https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity
34. About Apple File System - https://developer.apple.com/documentation/foundation/about-apple-file-system
35. URLResourceKey.fileContentIdentifierKey - https://developer.apple.com/documentation/foundation/urlresourcekey/filecontentidentifierkey
36. Apple Support, iCloud Photos (Optimize Storage) - https://support.apple.com/en-us/108782
37. Energy Efficiency Guide for Mac Apps, Prioritize Work at the Task Level - https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html
38. Process.qualityOfService - https://developer.apple.com/documentation/foundation/process/qualityofservice
39. NSBackgroundActivityScheduler - https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler
40. ProcessInfo.ActivityOptions - https://developer.apple.com/documentation/foundation/processinfo/activityoptions
41. ProcessInfo.ThermalState - https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum
42. ProcessInfo.isLowPowerModeEnabled - https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled
43. Eclectic Light Company, Tune for Performance: Core types - https://eclecticlight.co/2024/12/17/tune-for-performance-core-types/
44. SwiftData ModelActor - https://developer.apple.com/documentation/swiftdata/modelactor
45. Apple Developer Forums thread 763487, SwiftData regression - https://developer.apple.com/forums/thread/763487
46. Apple Developer Forums thread 770416, ModelActor issues - https://developer.apple.com/forums/thread/770416
47. Apple Support, Remove duplicate photos and videos on Mac - https://support.apple.com/guide/photos/remove-duplicates-pht5a3157c1d/mac
48. Apple Human Interface Guidelines, Machine learning - https://developer.apple.com/design/human-interface-guidelines/machine-learning
49. Apple, App Privacy Details - https://developer.apple.com/app-store/app-privacy-details/
50. Apple Community, What happens after IMG_9999? - https://discussions.apple.com/thread/255012150
51. ExifTool Apple tags (BurstUUID, ContentIdentifier, PhotoIdentifier) - https://exiftool.org/TagNames/Apple.html
52. IPTC, Exif 3.0 released - https://iptc.org/news/exif-3-0-released-featuring-utf-8-support/
53. Apple Community, Optimize Mac Storage behaviour - https://discussions.apple.com/thread/256123234

### SQLite and Python
54. SQLite, Write-Ahead Logging (re-checked) - https://www.sqlite.org/wal.html
55. SQLite, PRAGMA statements - https://www.sqlite.org/pragma.html
56. SQLite, Using SQLite in multi-threaded applications - https://www.sqlite.org/threadsafe.html
57. SQLite, 35% Faster Than The Filesystem - https://www.sqlite.org/fasterthanfs.html
58. SQLite, WITHOUT ROWID - https://www.sqlite.org/withoutrowid.html
59. SQLite, JSONB - https://www.sqlite.org/jsonb.html
60. SQLite, Result and Error Codes - https://www.sqlite.org/rescode.html
61. SQLite, sqlite3_busy_handler - https://www.sqlite.org/c3ref/busy_handler.html
62. SQLite, BEGIN TRANSACTION - https://www.sqlite.org/lang_transaction.html
63. SQLite, How To Corrupt An SQLite Database File - https://www.sqlite.org/howtocorrupt.html
64. SQLite, Database File Format - https://www.sqlite.org/fileformat2.html
65. Python docs, sqlite3 - https://docs.python.org/3/library/sqlite3.html
66. Python docs, hashlib (file_digest) - https://docs.python.org/3/library/hashlib.html
67. Python docs, concurrent.futures (max_tasks_per_child) - https://docs.python.org/3/library/concurrent.futures.html

### Incremental computation and change detection
68. Bazel, Remote caching - https://bazel.build/remote/caching
69. ccache manual - https://ccache.dev/manual/latest.html
70. Mokhov, Mitchell, Peyton Jones, Build Systems à la Carte (ICFP 2018) - https://www.microsoft.com/en-us/research/uploads/prod/2018/03/build-systems-a-la-carte.pdf
71. Nix manual, Store path - https://nix.dev/manual/nix/latest/store/store-path
72. Nix manual, Experimental features (ca-derivations) - https://nix.dev/manual/nix/stable/development/experimental-features
73. Pro Git, Git Objects - https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
74. Git documentation, racy-git - https://git-scm.com/docs/racy-git
75. Salsa, The red-green algorithm - https://salsa-rs.github.io/salsa/reference/algorithm.html
76. rustc dev guide, Incremental compilation - https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation.html
77. Hammer et al., Adapton (PLDI 2014) - https://people.mpi-sws.org/~hammer/adapton-pldi2014.pdf
78. rsync(1) - https://download.samba.org/pub/rsync/rsync.1
79. Apple, Using the FSEvents Framework - https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
80. Watchman, query - https://facebook.github.io/watchman/docs/cmd/query
81. Adobe Community, Why is a file a suspected duplicate (Lightroom Classic) - https://community.adobe.com/t5/lightroom-classic-discussions/why-is-a-file-a-suspected-duplicate/m-p/6756297

### Hashing and image fingerprints
82. xxHash README - https://github.com/Cyan4973/xxHash
83. BLAKE3 README - https://github.com/BLAKE3-team/BLAKE3
84. imohash README - https://github.com/kalafut/imohash
85. ExifTool forum, ImageDataHash - https://exiftool.org/forum/index.php?msg=80651
86. libjpeg-turbo commit on DCT/IDCT trade-offs - https://flutter.googlesource.com/third_party/libjpeg-turbo/+/8940e6ca8628e10b45486fad4572a15b63546eb1%5E%21
87. Sullivan et al., Overview of the HEVC Standard - https://www.academia.edu/31339976/HEVC_Overview
88. Meta ThreatExchange, PDQ README - https://github.com/facebook/ThreatExchange/blob/main/pdq/README.md
89. Dalins, Wilson, Boudry, PDQ & TMK + PDQF (arXiv:1912.07745) - https://ar5iv.labs.arxiv.org/html/1912.07745
90. Zauner, Implementation and Benchmarking of Perceptual Image Hash Functions (2010) - https://phash.org/docs/pubs/thesis_zauner.pdf
91. Krawetz, Kind of Like That (dHash) - https://www.hackerfactor.com/blog/index.php?/archives/529-Kind-of-Like-That.html
92. Krawetz, Looks Like It (aHash, pHash) - https://www.hackerfactor.com/blog/index.php?/archives/432-Looks-Like-It.html
93. ImageHash Python library - https://github.com/JohannesBuchner/imagehash
94. pHash design notes - https://www.phash.org/docs/design.html
95. Roboflow, NeuralHash collisions - https://roboflow.com/blog/neuralhash-collision
96. Struppek et al., Learning to Break Deep Perceptual Hashing (FAccT 2022) - https://arxiv.org/abs/2111.06628
97. Tsai, NeuralHash Implementation and Collision - https://mjtsai.com/blog/2021/08/18/neuralhash-implementation-and-collision/
98. osxphotos fingerprint.py - https://github.com/RhetTbull/osxphotos/blob/main/osxphotos/fingerprint.py
99. Apple Community, ZMASTERFINGERPRINT NULL after import - https://communities.apple.com/thread/255598336

### Streaming statistics and retention
100. Algorithms for calculating variance (Welford, West, Chan et al.) - https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance
101. Cormode, Shkapenyuk, Srivastava, Xu, Forward Decay (ICDE 2009) - https://www.cs.ox.ac.uk/people/graham.cormode/pubs/papers/fwddecay.pdf
102. Effective sample size / design effect (Kish 1965) - https://en.wikipedia.org/wiki/Effective_sample_size
103. NIST/SEMATECH e-Handbook 6.3.2.4, EWMA control charts - https://itl.nist.gov/div898/handbook/pmc/section3/pmc324.htm
104. Dunning & Ertl, t-digest (arXiv:1902.04023) - https://arxiv.org/abs/1902.04023
105. Karnin, Lang, Liberty, KLL (arXiv:1603.05346) - https://arxiv.org/abs/1603.05346
106. Apache DataSketches, KLL accuracy and size - https://datasketches.apache.org/docs/KLL/KLLAccuracyAndSize.html
107. Apache DataSketches, KLL vs t-digest - https://datasketches.apache.org/docs/QuantilesStudies/KllSketchVsTDigest.html
108. Masson, Rim, Lee, DDSketch (PVLDB 12(12), 2019) - https://www.vldb.org/pvldb/vol12/p2195-masson.pdf
109. Cormode, Mishra, Ross, Vesely, Theory meets Practice at the Median (KDD 2021) - https://arxiv.org/abs/2102.09299
110. Jain & Chlamtac, The P² algorithm (CACM 1985) - https://classes.engineering.wustl.edu/~jain/papers/ftp/psqr.pdf
111. Reservoir sampling (Vitter; Efraimidis & Spirakis) - https://en.wikipedia.org/wiki/Reservoir_sampling
112. Aggarwal, Biased Reservoir Sampling (VLDB 2006) - https://researcher.watson.ibm.com/publications/on-biased-reservoir-sampling-in-the-presence-of-stream-evolution
113. RRDtool rrdcreate - https://oss.oetiker.ch/rrdtool/doc/rrdcreate.en.html
114. Thanos Compactor and downsampling - https://thanos.io/tip/components/compact.md/
115. Prometheus storage - https://prometheus.io/docs/prometheus/latest/storage/
116. O'Neil et al., The Log-Structured Merge-Tree (1996) - https://www.cs.umb.edu/~poneil/lsmtree.pdf
117. Bloom filter - https://en.wikipedia.org/wiki/Bloom_filter
118. Fan et al., Cuckoo Filter (CoNEXT 2014) - https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf
119. Graf & Lemire, Xor Filters (arXiv:1912.08258) - https://arxiv.org/abs/1912.08258
120. Graf & Lemire, Binary Fuse Filters (arXiv:2201.01174) - https://arxiv.org/abs/2201.01174
121. Sitter & Wu (2001), on Woodruff (1952) quantile intervals - https://ideas.repec.org/a/eee/stapro/v52y2001i4p353-358.html
122. Binomial proportion confidence interval (Wilson 1927) - https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval
123. PracTools vignette, Design Effects and Effective Sample Size - https://cran.r-project.org/web/packages/PracTools/vignettes/Design-effects.html
124. US Patent 8,595,194, Forward decay temporal data analysis - https://patents.google.com/patent/US8595194

### Cache policies
125. Caffeine wiki, Efficiency (W-TinyLFU) - https://github.com/ben-manes/caffeine/wiki/Efficiency
126. Megiddo & Modha, ARC (FAST 03) - https://www.usenix.org/conference/fast-03/arc-self-tuning-low-overhead-replacement-cache
127. Zhang et al., SIEVE is Simpler than LRU (NSDI 24) - https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo
128. Cherkasova, GDSF (HPL-98-69R1) - https://eclass-b.uoa.gr/modules/document/file.php/D245/2015/HPL-98-69R1_GDS.pdf

### Coaching and feedback
129. Kluger & DeNisi (1996), abstract - https://pluto.huji.ac.il/~mskluger/files/Download/Kluger%20&%20%20DeNisi%20abstract.doc
130. Wisniewski, Zierer & Hattie (2020), The Power of Feedback Revisited - https://pmc.ncbi.nlm.nih.gov/articles/PMC6987456
131. BERA blog on Hattie & Timperley feedback levels - https://www.bera.ac.uk/blog/how-to-optimise-the-use-of-hattie-and-timperleys-feedback-levels-for-student-learning
132. Shute (2008), Focus on Formative Feedback - https://myweb.fsu.edu/vshute/pdf/shute%202008_b.pdf
133. Apache DataSketches Java releases (weighted KLL in 6.0.0) - https://github.com/apache/datasketches-java/releases
134. APS release on Macnamara, Hambrick & Oswald (2014) - https://www.psychologicalscience.org/news/releases/becoming-an-expert-takes-more-than-practice.html
135. Frontiers in Neuroscience (2016), citing Winstein & Schmidt (1990) - https://www.frontiersin.org/articles/10.3389/fnins.2016.00251/full
136. Bandwidth knowledge of results (Motricidade) - https://revistas.rcaap.pt/motricidade/article/view/14294
137. BPS Research Digest on Lally et al. (2010) - https://bps.org.uk/research-digest/how-form-habit
138. Frontiers in Psychology (2021), citing Gollwitzer & Sheeran (2006) - https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2021.565202/pdf
139. Dai, Milkman & Riis (2014), The Fresh Start Effect - https://faculty.wharton.upenn.edu/wp-content/uploads/2014/06/Dai_Fresh_Start_2014_Mgmt_Sci.pdf
140. Silverman & Barasch (2023), broken streaks - https://www.colorado.edu/business/faculty-research/2023/04/19/or-track-how-broken-streaks-affect-consumer-decisions
141. Ancker et al. (2017), repeated alerts and alert fatigue - https://pmc.ncbi.nlm.nih.gov/articles/PMC5387195/
142. Amershi et al. (2019), Guidelines for Human-AI Interaction - https://www.microsoft.com/en-us/research/uploads/prod/2019/01/Guidelines-for-Human-AI-Interaction-camera-ready.pdf
143. Adobe Help, Assisted Culling - https://helpx.adobe.com/be_en/lightroom/desktop/organize-photos/assisted-culling.html
144. Adobe Design, Behind the design: Assisted Culling - https://adobe.design/ideas/behind-the-design-assisted-culling-in-adobe-lightroom
145. 9to5Google, Google Photos Stacks - https://9to5google.com/2023/11/15/google-photos-stacks/
146. DXOMARK lens, camera and sensor testing protocol - https://cdn.dxomark.com/dxomark-lens-camera-sensor-testing-protocol/
147. Castleman, SFRplus/Imatest weighted MTF50; Imatest multi-ROI docs - https://www.wlcastleman.com/equip/reviews/m43/mtf_resol.htm ; https://imatest.com/docs/sfr_multiROIplot
148. Lensrentals, MTF and Variation - https://www.lensrentals.com/blog/2015/08/mtf-and-variation-an-example/
149. IEEE 1858 CPIQ working group - https://sagroups.ieee.org/1858/
150. Ericsson (2020/2021), deliberate-practice criteria - https://pmc.ncbi.nlm.nih.gov/articles/PMC8049893/
151. Apple Personal Safety User Guide, Feature Less / Reset Suggested Memories - https://support.apple.com/en-ca/guide/personal-safety/ipsa4c9edc62/web
152. Matplotlib, MPLCONFIGDIR and cache directory - https://matplotlib.org/stable/install/environment_variables_faq.html
153. Pillow docs, Image.draft - https://pillow.readthedocs.io/en/stable/reference/Image.html
154. pillow-heif docs, options (DECODE_THREADS) - https://pillow-heif.readthedocs.io/en/latest/options.html
155. Murre & Dros (2015), replication of Ebbinghaus' forgetting curve - https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0120644
156. Cepeda et al. (2006), Distributed practice in verbal recall tasks - https://pubmed.ncbi.nlm.nih.gov/16719566/

### Added in the final round (157–196)
Gathered by the follow-up studies on 2026-10-26. The finaliser re-fetched [11] (the limited-library sentence), [55] (`journal_size_limit`) and [169].

157. PHAssetResourceRequestOptions.isNetworkAccessAllowed ("If false (the default) … an NSError object indicating that the resource requires network access") - https://developer.apple.com/documentation/photos/phassetresourcerequestoptions/isnetworkaccessallowed
158. PHPhotosError.Code.networkAccessRequired - https://developer.apple.com/documentation/photos/phphotoserror-swift.struct/code/networkaccessrequired
159. Apple Developer Forums thread 743514, PHPhotosErrorDomain 3164 is network access required - https://developer.apple.com/forums/thread/743514
160. Apple, Photos User Guide, Optimize Mac Storage ("stores smaller versions of your photos on your Mac when storage space is limited") - https://support.apple.com/en-gw/guide/photos/phtf5e48489c/7.0
161. Apple Community thread 251647982, quoting Apple support: the library is "optimized only when you need space, starting with the photos and videos you access least" - https://discussions.apple.com/thread/251647982
162. Rule of three (statistics); Hanley & Lippman-Hand, JAMA 1983, doi:10.1001/jama.1983.03330370053031 - https://en.wikipedia.org/wiki/Rule_of_three_(statistics)
163. NWPath.isExpensive - https://developer.apple.com/documentation/network/nwpath/isexpensive
164. NWPath.isConstrained (Low Data Mode) - https://developer.apple.com/documentation/network/nwpath/isconstrained
165. FileManager.SearchPathDirectory.cachesDirectory ("Discardable cache files") - https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/cachesdirectory
166. URLResourceValues.volumeAvailableCapacityForImportantUsage - https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage
167. PhotosPickerItem.EncodingDisambiguationPolicy.current ("chooses the current encoding to avoid transcoding, if possible") - https://developer.apple.com/documentation/photosui/photospickeritem/encodingdisambiguationpolicy/current
168. PhotosPickerItem.EncodingDisambiguationPolicy.automatic ("chooses the best encoding") - https://developer.apple.com/documentation/photosui/photospickeritem/encodingdisambiguationpolicy/automatic
169. Apple Developer Forums thread 692407, "Allow PHPicker access to original/unadjusted asset" (Oct 2021; `.current` "still returns the asset with previous adjustments applied"; FB9706029 acknowledged by an Apple engineer; re-checked by the finaliser) - https://developer.apple.com/forums/thread/692407
170. Apple Developer Forums thread 736545, Apple engineer: "Unless .current is specified, transcoding can happen" (Aug 2023) - https://developer.apple.com/forums/thread/736545
171. PHAsset.pixelWidth ("If the asset's content has been edited, this property describes the size of the current version"; quoted by two researchers; the finaliser's fetch returned no body text and the SDK header carries no comment) - https://developer.apple.com/documentation/photos/phasset/pixelwidth
172. PHAssetResource.pixelWidth / pixelHeight (macOS 13, iOS 16; confirmed in the SDK header) - https://developer.apple.com/documentation/photos/phassetresource/pixelwidth
173. PHAsset.adjustmentTimestamp (macOS 15) - https://developer.apple.com/documentation/photos/phasset/adjustmenttimestamp
174. PHAsset.hasAdjustments (macOS 12) - https://developer.apple.com/documentation/photos/phasset/hasadjustments
175. macOS 27.0 SDK PhotosUI headers, read locally: PHPicker.h (`init` "never returns asset identifiers"), PHPhotoLibrary+PhotosUISupport.h (`API_UNAVAILABLE(macos)`), and the `_PhotosUI_SwiftUI` swiftinterface; Photos PHPhotoLibrary.h (`PHAuthorizationStatusLimited` `API_AVAILABLE(ios(14))`) - file:///Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/
176. WWDC20 session 10652, Meet the new Photos picker (no prompt; identifiers need a photo library; the limited selection is not extended) - https://developer.apple.com/videos/play/wwdc2020/10652/
177. Delivering an enhanced privacy experience in your photos app ("the system automatically and asynchronously prompts") - https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app
178. PHAuthorizationStatus.limited - https://developer.apple.com/documentation/photos/phauthorizationstatus/limited
179. Mac User Guide, Control access to your photos ("access to only photos you select") - https://support.apple.com/guide/mac-help/mchl244f2895/mac
180. Photos for Mac, System Photo Library (switching turns off iCloud Photos; merges cannot be undone) - https://support.apple.com/en-la/guide/photos/pht6d60b524/9.0/mac/14.0
181. publicspace.net on Adjust Date & Time (originals keep their EXIF; the change lives in the database) - https://www.publicspace.net/blog/change-photo-date-taken-mac/
182. SQLite, Datatypes In SQLite (REAL affinity: integral values stored as integers) - https://www.sqlite.org/datatype3.html
183. SQLite, The DBSTAT Virtual Table - https://www.sqlite.org/dbstat.html
184. SQLite, Foreign Key Support, §3 Required and Suggested Database Indexes - https://www.sqlite.org/foreignkeys.html
185. SQLite, Indexes On Expressions (the expression must match exactly) - https://www.sqlite.org/expridx.html
186. SQLite, Partial Indexes - https://www.sqlite.org/partialindex.html
187. SQLite, VACUUM (up to 2× free disk; VACUUM INTO, target must not exist; auto_vacuum does not compact partly filled pages) - https://www.sqlite.org/lang_vacuum.html
188. Apple Developer Forums thread 697352, PHCloudIdentifier without photo library access - https://developer.apple.com/forums/thread/697352
189. Apple, Photos for Mac User Guide, Delete photos (Recently Deleted kept 30 days) - https://support.apple.com/guide/photos/pht3bfab2f96/mac
190. Birthday problem (collision approximation n²/2^(b+1)) - https://en.wikipedia.org/wiki/Birthday_problem
191. SQLite, Recovering Data From A Corrupt Database (`.recover`, `lost_and_found`, index-only damage restorable) - https://www.sqlite.org/recovery.html
192. SQLite, sqlite3_wal_hook ("the commit will have still occurred") - https://www.sqlite.org/c3ref/wal_hook.html
193. SQLite, Checksum VFS Shim (8-byte checksum per page, verified on read) - https://www.sqlite.org/cksumvfs.html
194. SQLite, URI filenames, `immutable=1` (no locking or change detection) - https://www.sqlite.org/uri.html
195. flock(2), BSD manual ("Locks are on files, not file descriptors"; LOCK_NB returns EWOULDBLOCK) - https://man.freebsd.org/cgi/man.cgi?query=flock&sektion=2
196. Apple, LSMultipleInstancesProhibited ("whether more than one user can launch the app simultaneously") - https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited

### Local measurements (this Mac: MacBook Air Mac17,3, Apple M5 with 4 P + 6 E cores, 16 GB, macOS 26.6.2; inputs read only)
- **[L1] Fingerprinting bench, 2026-10-23.** 93 photo copies, 50 unique, 8 edits each; hash throughput; Vision probes. Scripts in `/private/tmp/claude-501/-Users-allisonbowman-Developer-iq-analyzer/40eb8208-c363-416f-af06-e29b4d4094a1/scratchpad/`: `bench_hash.py`, `ck.swift`, `make_set.py`, `probe*.swift`, `phash_eval.py`, `sweep.py`, `quant.swift`, `norm.swift`, `payload.py`.
- **[L2] PhotoKit and storage bench, 2026-10-23.** `/tmp/claude-501/memsim/sqlbench.py`; `/tmp/claude-501/swiftbench/bench.swift`, `bench2.swift`, `cl.swift`, `ids.swift`.
- **[L3] Bounded-statistics bench.** `…/scratchpad/sk/` (`exp1.py`, `exp2.py`, `exp3.py`, `size.py`) and `…/scratchpad/swb/` (`bench.swift`, `fold.swift`).
- **[L4] Cache and storage-engine bench, 2026-10-23.** `/tmp/claude-501/memres/`: `hashbench.py`, `stagebench.py`, `sqlbench.py`, `bench2.py`, `jsonbench.py`, `dec.swift`, `rd.swift`, `ro.swift`, `conc_writer.py`, `conc_reader.swift`, `decay.py`, `det.py`, `ck2.swift`.
- **[L5] Coaching analysis of `results/results.json`.** `…/scratchpad/`: `lib_stats.py`, `groups.py`, `decay.py`, `pct.py`, `sizes.py`, `advice.py`, `timing.py`.
- **[L6] Lazy-pipeline bench, 2026-10-23.** `/private/tmp/claude-501/lazybench/`: `bench_io.py`, `bench_decode.py`, `bench_stages.py`, `bench_load.py`, `bench_phash.py`, `bench_rss.py`, `bench_sqlite.py`, `bench_icc.py`, and `swift/`.
- **[L7] Profile and code map, 2026-10-23.** `…/scratchpad/`: `bench.py`, `cpustage.py`, `rss.py`, `memstage.py`, `reportcost.py`, `dbsim2.py`, `phash_sep.py`, `inventory.py`, `swiftbench/`, `decode/`.
- **[L8] Perceptual-hash benchmark.** `/tmp/claude-501/phash/`: `bench.py`, `analyze.py`, `extra.py`, `compare_decoders.py`, `cmp_thumbs.py`, `cmp_vision.py`, `swift/`, `swift2/`.
- **[L9] Synthesiser re-checks, 2026-10-26.**
  - `shasum -a 256` over `~/Library/Application Support/IQCoach/photos`: 93 files, 443,769,320 B, 50 unique, 40 groups, 43 redundant. `runs/`: 6 entries, 1,720 KiB.
  - `results/results.json`: 389 rows; 2,344,413 B; compact median 4,204 B; `analysis_s` sum 15,508.2 s, 21 rows > 60 s (14,734 s), 13 rows ≥ 900 s, the other 368 rows median 1.99 s and p90 3.01 s; 149 finite MTF50; 73 rows with ≥ 3 edges; 19 camera models.
  - Re-fetched sources [1][2][6][8][17][54].
- **[L10] iCloud cost study, 2026-10-26.** Availability census over a read-only APFS clone of `Photos.sqlite` and its WAL (clone deleted after use); residency, prune-sweep and local-share reconstruction validated against `photo_list.txt`; download latency and retention from IQ Coach's own export timestamps; IQ Coach copies mapped to library assets; the `ZFINGERPRINT` check of 93 copies and 31 local originals and 62,013 fingerprint-versus-stable-hash comparisons; git replay at 11 measurement commits plus HEAD on 20 canaries and 4 frozen synthetic scenes; restore-cost and reservoir model. Scripts in `/tmp/claude-501/icloudcost/scripts/` (`avail.py`, `residency.py`, `timeline.py`, `dlrate.py`, `match.py`, `fpcheck.py`, `run_one.sh`, `compare.py`, `detail.py`, `restore.py`); outputs in `/tmp/claude-501/icloudcost/out/`; corpus in `/tmp/claude-501/icloudcost/corpus/`; probe (built, not run) in `/tmp/claude-501/icloudcost/probe/` (`AvailProbe.app`, `main.swift`).
- **[L11] Edits and renditions study, 2026-10-26.** Picker copies against PhotoKit exports and library originals (SHA-256 plus an ImageIO metadata probe); read-only survey of a copy-on-write clone of `Photos.sqlite` and the adjustment plists; date-shift check; dHash256 edit simulation with 1,000 real crop geometries. `/private/tmp/claude-501/-Users-allisonbowman-Developer-iq-analyzer/40eb8208-c363-416f-af06-e29b4d4094a1/scratchpad/edits/`: `meta.swift`, `survey.py` (output `survey.json`), `datecheck.py`, `dhash_edits.py` (`dhash_edits.json`, `dhash_edits_summary.json`), and `PickerProbe/` (`PickerProbe.app`, ad-hoc signed as `dev.iqcoach.pickerprobe`; `PickerProbe.swift`; `dhash_pairs.py`).
- **[L12] Ledger budget study, 2026-10-26.** SQLite 3.53.4, Homebrew Python 3.14.7. `/private/tmp/claude-501/-Users-allisonbowman-Developer-iq-analyzer/40eb8208-c363-416f-af06-e29b4d4094a1/scratchpad/ledger/`: `ledgerbench.py`, `out/*.json`, `run.log`, `summarize.py`, `reclaim.py`, `fkdelete.py`, `evict_brief.py`, `camidx.py`, `ledger_cap.py`, `test_ledger_cap.py` (`pytest.log`: 7 passed), `idprobe.swift` and `idprobe` (built, not run). The critic's script and VACUUMed databases: `/tmp/claude-501/critic/ledger.py`, `l0.db`, `l1.db`.
- **[L13] Fault-injection study, 2026-10-26.** Harness in `/tmp/claude-501/faultlab/harness/` (`memproto.py`, `orchestrator.py`, `concurrency.py`, `corrupt.py`, `gen54k.py`, `diskfull.py`, `filler.py`, `procmem.py`); results in `/tmp/claude-501/faultlab/conc/` (`stub-lines.jsonl`, `real2.log`, `real-naive/`, `real-robust/`), `/tmp/claude-501/faultlab/corrupt/` (`result-flips.json`, `result-shm.json`, `result-backup.json`, `base.sqlite`), `/tmp/claude-501/faultlab/df-result-*.json`, `/tmp/claude-501/faultlab/cpu_budget.log`; Swift probes `/tmp/claude-501/faultlab/swift/cap.swift`, `inherit.swift`.
- **[L14] Finaliser checks, 2026-10-26.** `/private/tmp/claude-501/-Users-allisonbowman-Developer-iq-analyzer/40eb8208-c363-416f-af06-e29b4d4094a1/scratchpad/finalise/`: `common.py` (54,000-row ledger on the repo's `iqa/memory_schema.sql`, read only), `wal_reader.py` (WAL under no reader, keyset pages, a slow statement and a pinned snapshot; output `wal_reader_2000_none_paged_slowcursor_pinned.json`, `wal_reader2.log`), `swwriter.swift` (Swift writer on the system SQLite 3.51.0), `mixed.py` (Swift writer + Python writer + reader, 3 trials; output `mixed_3000x3.json`, `mixed.log`). Load average 28–60 during the runs.
- **[R] This repository.** `mac/IQCoach/Sources` (AppModel, AnalyzerRunner, PhotosImporter, ImportBatch, MemoryStore, MemoryDatabase, PreferencesStore, ThumbnailStore, PhotoRecord, CaptureCheck, CameraGroup, ClippingMask, ContentIdentifier, RootView), in the working tree of 2026-10-26 unless HEAD (1c199f5) is named; `iqa/` (cli.py, analyze.py, imageio.py, uncertainty.py, memory.py, memory_schema.sql); `results/FINDINGS.md` (§8–9); `docs/MEMORY-SPEC.md`; `docs/FEEDBACK-LAYERS-SPEC.md`; `CLAUDE.md`; `git log`.
