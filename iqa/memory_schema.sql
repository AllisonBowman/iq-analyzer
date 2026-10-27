-- The analyzer's memory: one SQLite file that remembers every photo it has measured, so a photo is never copied
-- or measured twice, while disk, RAM and CPU stay bounded as the library grows. docs/MEMORY-SPEC.md is the design;
-- docs/MEMORY-RESEARCH.md holds the evidence behind each choice.
--
-- This file is the single source of truth for the schema. iqa/memory.py executes it on a new database (after setting
-- page_size and auto_vacuum, which must precede the first CREATE TABLE); the IQ Coach tests execute it to build
-- fixtures. Bump PRAGMA user_version here and add a migration in iqa/memory.py when the schema changes.
--
-- Tiers (budgets in docs/MEMORY-SPEC.md section 4):
--   asset + source  the ledger: one row per distinct content (SHA-256), kept until forgotten (about 530 B per photo, measured)
--   record          the full scalar record of the newest photos per camera (the coaching window)
--   detail          per-edge lists and noise curves, newest first under a byte budget
--   archive         fixed-size monthly histograms that records are folded into when they leave the window

PRAGMA application_id = 1230062385;  -- 0x49514331, "IQC1"
PRAGMA user_version = 1;

-- One row per distinct content. sha256 is the identity: the SHA-256 of the exact bytes the analyzer read.
CREATE TABLE asset (
    id           INTEGER PRIMARY KEY,
    sha256       BLOB    NOT NULL UNIQUE CHECK (length(sha256) = 32),
    byte_size    INTEGER NOT NULL,
    file         TEXT,               -- the original file name as first seen (no folder)
    camera       TEXT    NOT NULL DEFAULT '',  -- EXIF camera model, '' when the file names none
    format       TEXT,               -- "jpeg", "heic", "dng", ...
    captured_at  TEXT,               -- EXIF DateTimeOriginal as written, "YYYY:MM:DD HH:MM:SS"
    captured_ts  REAL,               -- the same instant as seconds since 1970, read as UTC (EXIF has no zone); NULL when undated
    dhash256     BLOB CHECK (dhash256 IS NULL OR length(dhash256) = 32),  -- advisory near-duplicate hash, never an identity
    status       TEXT    NOT NULL CHECK (status IN ('measured', 'failed', 'not_capture')),
    analyzer_key TEXT    NOT NULL,   -- e.g. "m1-r30-s0": measurement version and the settings that change results
    measured_at  REAL    NOT NULL,   -- unix seconds
    wall_s       REAL,               -- monotonic wall time of the measurement (does not count system sleep)
    cpu_s        REAL,               -- process CPU time of the measurement
    first_seen   REAL    NOT NULL,
    last_seen    REAL    NOT NULL,
    reason       TEXT,               -- why a 'failed' or 'not_capture' row is not measured
    attempts     INTEGER NOT NULL DEFAULT 0,  -- failed measurements with analyzer_key; a 'failed' row is final at 2
    -- Headline figures kept for the life of the ledger row, so a photo that left the window still reads in one line.
    h_sharpness_lwph REAL,           -- mtf50_p80_lwph, only when edges_measured >= 3
    h_snr_db         REAL,           -- snr_midgrey_db, only when clean (not extrapolated, texture or periodic suspect)
    h_clip_high_pct  REAL,
    h_clip_low_pct   REAL,
    h_tilt_deg       REAL            -- structure_horizon_tilt_deg
);
CREATE INDEX asset_camera_time ON asset (camera, captured_ts);

-- Every way a content was reached: a file path, a PhotoKit asset, a picker item. Many sources may share one asset
-- (the same photo exported twice, or picked and then exported). The source is an alias; the asset is the identity.
CREATE TABLE source (
    kind        TEXT    NOT NULL CHECK (kind IN ('file', 'photokit', 'picker')),
    locator     TEXT    NOT NULL,    -- real path, PHAsset localIdentifier, or PhotosPickerItem itemIdentifier
    asset_id    INTEGER NOT NULL REFERENCES asset (id) ON DELETE CASCADE,
    stat_key    TEXT,                -- files: "dev:ino:size:mtime_ns:ctime_ns"
    signature   TEXT,                -- PhotoKit: "originalFilename|uti|WxH" of the .photo resource
    verified_at REAL    NOT NULL,    -- unix seconds when the content behind this source was last hashed
    PRIMARY KEY (kind, locator)
) WITHOUT ROWID;
CREATE INDEX source_asset ON source (asset_id);

-- The full scalar record (what results.json carries for a photo, without path, edges and noise_curve), as JSON
-- compressed with raw DEFLATE (RFC 1951, no zlib header), which Apple's Compression framework reads as .zlib.
CREATE TABLE record (
    asset_id INTEGER PRIMARY KEY REFERENCES asset (id) ON DELETE CASCADE,
    z        BLOB NOT NULL
);

-- The heavy per-photo detail: {"edges": [...], "noise_curve": {...}} as raw-DEFLATE JSON.
CREATE TABLE detail (
    asset_id INTEGER PRIMARY KEY REFERENCES asset (id) ON DELETE CASCADE,
    z        BLOB    NOT NULL,
    bytes    INTEGER NOT NULL
);

-- Photos that left the window, folded into one bucket per camera, capture month and analyzer version. z is
-- raw-DEFLATE JSON (docs/MEMORY-SPEC.md section 5). Buckets of different analyzer versions are never merged.
CREATE TABLE archive (
    camera       TEXT    NOT NULL,
    month        TEXT    NOT NULL,   -- "YYYY-MM" of capture, "undated" when unknown
    analyzer_key TEXT    NOT NULL,
    n            INTEGER NOT NULL,   -- photos folded in
    first_ts     REAL,
    last_ts      REAL,
    z            BLOB    NOT NULL,
    PRIMARY KEY (camera, month, analyzer_key)
);

-- Settings and bookkeeping: current_analyzer_key, window, detail_budget_bytes, last_compact, created.
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT
) WITHOUT ROWID;
