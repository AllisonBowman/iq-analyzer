"""The analyzer's memory: every photo it has measured, remembered by the SHA-256 of its bytes.

docs/MEMORY-SPEC.md is the design and iqa/memory_schema.sql the schema (the single source of truth,
executed here on a new file and by the IQ Coach tests). The memory is one SQLite file in four tiers:

* ledger (``asset``, ``source``): one row per distinct content, kept until forgotten, with five
  headline figures so a photo that left the window still reads in one line;
* record: the full scalar record of the newest ``window`` photos per camera (default 500);
* detail: per-edge lists and noise curves, newest capture first under a byte budget (8 MiB);
* archive: per camera, capture month and analyzer key, fixed-bin histograms with exact integer
  counts, into which records are folded when they leave the window.

A photo is reused only when its bytes hash to a stored content id and it was measured with the
current analyzer key (``analyzer_key``); no perceptual hash, name, size or date ever causes a skip.
Every write is one ``BEGIN IMMEDIATE`` transaction: under two writers, deferred read-then-write
transactions failed 52 % of the time on this Mac and immediate ones 0 of 6,000.

Only the standard library is imported here, so ``import iqa.memory`` stays cheap: a run whose photos
are all remembered never loads numpy, scipy or OpenCV for the memory's sake.
"""
from __future__ import annotations

import calendar
import contextlib
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
import time
import zlib
from dataclasses import dataclass, field

from . import MEASUREMENT_VERSION

APPLICATION_ID = 0x49514331          # "IQC1", set by memory_schema.sql
SCHEMA_VERSION = 1                   # the PRAGMA user_version this code reads and writes
DEFAULT_WINDOW = 500                 # measured photos kept as full records, per camera
DEFAULT_DETAIL_BUDGET = 8 * 1024 * 1024
FINAL_ATTEMPTS = 2                   # failed measurements with one analyzer key before a photo is not tried again
RACY_S = 1.0                        # git's racy-clean margin for the stat fast path
SQLITE_MAGIC = b"SQLite format 3\x00"
_CORRUPTION_CODES = (11, 26)         # SQLITE_CORRUPT, SQLITE_NOTADB (primary codes)

# Record fields kept out of the stored record: the location of this copy, the detail tier's
# contents, and fields that live in asset columns or describe how a record was emitted.
_NOT_STORED = frozenset({"path", "edges", "noise_curve", "sha256", "analyzer_key", "memory_tier"})


class MemoryFileError(Exception):
    """The file at the memory path cannot be used as it is (foreign, newer, missing or damaged)."""


# ---------------------------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------------------------

def analyzer_key(max_rois: int = 30, max_side: int | None = None) -> str:
    """The validity key of a measurement: the measurement version and the settings that change
    results, e.g. ``m1-r30-s0``."""
    return f"m{MEASUREMENT_VERSION}-r{max_rois}-s{max_side or 0}"


def sha256_file(path: str) -> bytes:
    """The content id: SHA-256 of the file's exact bytes (32 bytes)."""
    with open(path, "rb") as fh:
        return hashlib.file_digest(fh, "sha256").digest()


def stat_key(st: os.stat_result) -> str:
    """A file's identity on disk at one moment: device, inode, size and both timestamps in ns."""
    return f"{st.st_dev}:{st.st_ino}:{st.st_size}:{st.st_mtime_ns}:{st.st_ctime_ns}"


# ---------------------------------------------------------------------------------------------
# Stored JSON: raw DEFLATE (RFC 1951, no zlib header), which Apple's Compression reads as .zlib
# ---------------------------------------------------------------------------------------------

def _json_default(o):
    # The same conversion as report.write_json, without importing numpy: a numpy value can only
    # exist when numpy is already loaded.
    np = sys.modules.get("numpy")
    if np is not None:
        if isinstance(o, (np.floating, np.integer)):
            return o.item()
        if isinstance(o, np.ndarray):
            return o.tolist()
    return str(o)


def deflate(obj) -> bytes:
    raw = json.dumps(obj, allow_nan=True, separators=(",", ":"), default=_json_default).encode("utf-8")
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    return c.compress(raw) + c.flush()


def inflate(z: bytes):
    return json.loads(zlib.decompress(z, -15))


# ---------------------------------------------------------------------------------------------
# Record fields
# ---------------------------------------------------------------------------------------------

def storable(record: dict) -> dict:
    """The record as stored: without the path, the detail and the in-memory objects."""
    return {k: v for k, v in record.items() if k not in _NOT_STORED and not k.startswith("_")}


def _finite(x) -> float | None:
    if x is None or isinstance(x, bool):
        return None
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def headline(record: dict) -> dict:
    """The five figures the ledger keeps for life and the archive folds, under the report's
    validity gates: sharpness needs three edges, SNR a clean measurement."""
    sharp_ok = (record.get("edges_measured") or 0) >= 3
    clean = not (record.get("snr_midgrey_extrapolated") or record.get("noise_texture_suspect")
                 or record.get("noise_periodic_suspect"))
    return {
        "sharpness_lwph": _finite(record.get("mtf50_p80_lwph")) if sharp_ok else None,
        "snr_db": _finite(record.get("snr_midgrey_db")) if clean else None,
        "clip_high_pct": _finite(record.get("clip_high_pct")),
        "clip_low_pct": _finite(record.get("clip_low_pct")),
        "tilt_deg": _finite(record.get("structure_horizon_tilt_deg")),
    }


# headline name -> (asset column, results.json field)
HEADLINE_FIELDS = {
    "sharpness_lwph": ("h_sharpness_lwph", "mtf50_p80_lwph"),
    "snr_db": ("h_snr_db", "snr_midgrey_db"),
    "clip_high_pct": ("h_clip_high_pct", "clip_high_pct"),
    "clip_low_pct": ("h_clip_low_pct", "clip_low_pct"),
    "tilt_deg": ("h_tilt_deg", "structure_horizon_tilt_deg"),
}

_EXIF_DATETIME = re.compile(r"(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})")


def exif_timestamp(text) -> float | None:
    """EXIF ``YYYY:MM:DD HH:MM:SS`` as seconds since 1970, read as UTC (EXIF carries no zone, so
    the number orders captures by their wall clock); None when missing or not a real date."""
    if not isinstance(text, str):
        return None
    m = _EXIF_DATETIME.fullmatch(text.strip(" \x00"))
    if not m:
        return None
    y, mo, d, h, mi, s = (int(g) for g in m.groups())
    if not (y >= 1 and 1 <= mo <= 12 and 1 <= d <= calendar.monthrange(y, mo)[1]
            and h <= 23 and mi <= 59 and s <= 59):
        return None
    return float(calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)))


def month_of(ts: float | None) -> str:
    """The archive month of a capture time: ``YYYY-MM``, or ``undated``."""
    if ts is None:
        return "undated"
    tm = time.gmtime(ts)
    return f"{tm.tm_year:04d}-{tm.tm_mon:02d}"


def _wall_clock(ts: float | None) -> str | None:
    return None if ts is None else time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(ts))


# ---------------------------------------------------------------------------------------------
# The archive: fixed bins, exact integer counts (docs/MEMORY-SPEC.md section 5)
# ---------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Bins:
    """Fixed bins of one metric. ``step`` is the ratio of a log bin or the width of a linear one.
    Values below ``lo`` count in ``under`` (in ``zero`` when exactly 0 and ``zero_bin``), values
    above ``top`` in ``over``."""
    scale: str
    lo: float
    step: float
    top: float
    zero_bin: bool = False

    def slot(self, x: float):
        if self.zero_bin and x == 0:
            return "zero"
        if x < self.lo:
            return "under"
        if x > self.top:
            return "over"
        if self.scale == "log":
            return math.floor(math.log(x / self.lo) / math.log(self.step))
        return math.floor((x - self.lo) / self.step)

    def representative(self, i: int) -> float:
        """The value a bin stands for: the geometric centre of a log bin, the mid-point of a
        linear one; a value read back is off by at most half a bin."""
        if self.scale == "log":
            return self.lo * self.step ** (i + 0.5)
        return self.lo + (i + 0.5) * self.step


ARCHIVE_BINS = {
    "sharpness_lwph": Bins("log", 50.0, 1.02, 10_000.0),     # about 1 % relative per bin
    "snr_db": Bins("linear", 0.0, 0.25, 80.0),
    "clip_high_pct": Bins("log", 0.001, 1.05, 100.0, zero_bin=True),
    "clip_low_pct": Bins("log", 0.001, 1.05, 100.0, zero_bin=True),
    "tilt_deg": Bins("linear", -45.0, 0.25, 45.0),
}

# share name -> (headline metric, test); each share is [hits, of] over the photos with the field.
ARCHIVE_SHARES = {
    "clip_high_gt1": ("clip_high_pct", lambda v: v > 1.0),
    "clip_low_gt1": ("clip_low_pct", lambda v: v > 1.0),
    "tilt_ge1": ("tilt_deg", lambda v: abs(v) >= 1.0),
}


@dataclass
class Histogram:
    counts: dict = field(default_factory=dict)     # bin index -> count
    zero: int = 0
    under: int = 0
    over: int = 0

    @property
    def n(self) -> int:
        return self.zero + self.under + self.over + sum(self.counts.values())

    def _count(self, slot) -> int:
        return getattr(self, slot) if isinstance(slot, str) else self.counts.get(slot, 0)

    def _bump(self, slot, k: int) -> None:
        if isinstance(slot, str):
            setattr(self, slot, getattr(self, slot) + k)
            return
        c = self.counts.get(slot, 0) + k
        if c:
            self.counts[slot] = c
        else:
            self.counts.pop(slot, None)

    def add(self, x: float, bins: Bins) -> None:
        self._bump(bins.slot(x), 1)

    def merge(self, other: "Histogram") -> "Histogram":
        self.zero += other.zero
        self.under += other.under
        self.over += other.over
        for i, c in other.counts.items():
            self._bump(i, c)
        return self

    def quantile(self, q: float, bins: Bins) -> float | None:
        """The nearest-rank quantile (the ceil(q n)-th smallest value) read at its bin's
        representative value; ``lo`` or ``top`` when it falls in the under or over count."""
        total = self.n
        if total == 0 or not 0.0 <= q <= 1.0:
            return None
        target = max(1, math.ceil(q * total))
        seen = self.zero
        if seen >= target:
            return 0.0
        seen += self.under
        if seen >= target:
            return bins.lo
        for i in sorted(self.counts):
            seen += self.counts[i]
            if seen >= target:
                return bins.representative(i)
        return bins.top

    def to_dict(self) -> dict:
        return {"counts": {str(i): self.counts[i] for i in sorted(self.counts)},
                "zero": self.zero, "under": self.under, "over": self.over, "n": self.n}

    @classmethod
    def from_dict(cls, d: dict) -> "Histogram":
        return cls(counts={int(k): int(v) for k, v in (d.get("counts") or {}).items() if int(v)},
                   zero=int(d.get("zero", 0)), under=int(d.get("under", 0)), over=int(d.get("over", 0)))


@dataclass
class Bucket:
    """Photos of one camera, capture month and analyzer key, folded into fixed bins. Every
    metric and share is always present, so the stored JSON has one shape."""
    metrics: dict = field(default_factory=lambda: {m: Histogram() for m in ARCHIVE_BINS})
    shares: dict = field(default_factory=lambda: {s: [0, 0] for s in ARCHIVE_SHARES})

    def _apply(self, values: dict, k: int) -> None:
        for name, bins in ARCHIVE_BINS.items():
            v = _finite(values.get(name))
            if v is not None:
                self.metrics[name]._bump(bins.slot(v), k)
        for name, (metric, test) in ARCHIVE_SHARES.items():
            v = _finite(values.get(metric))
            if v is not None:
                self.shares[name][0] += k * bool(test(v))
                self.shares[name][1] += k

    def fold(self, values: dict) -> None:
        """Count one photo's headline figures (``headline()`` of its record)."""
        self._apply(values, 1)

    def unfold(self, values: dict) -> bool:
        """Remove one photo folded earlier. Refuses (False, nothing changed) when the bucket does
        not hold its values, so an inconsistent call can never make a count negative."""
        for name, bins in ARCHIVE_BINS.items():
            v = _finite(values.get(name))
            if v is not None and self.metrics[name]._count(bins.slot(v)) < 1:
                return False
        for name, (metric, test) in ARCHIVE_SHARES.items():
            v = _finite(values.get(metric))
            if v is not None and (self.shares[name][1] < 1 or (test(v) and self.shares[name][0] < 1)):
                return False
        self._apply(values, -1)
        return True

    def merge(self, other: "Bucket") -> "Bucket":
        for name in ARCHIVE_BINS:
            self.metrics[name].merge(other.metrics[name])
        for name in ARCHIVE_SHARES:
            self.shares[name][0] += other.shares[name][0]
            self.shares[name][1] += other.shares[name][1]
        return self

    def quantile(self, metric: str, q: float) -> float | None:
        return self.metrics[metric].quantile(q, ARCHIVE_BINS[metric])

    def share(self, name: str) -> float | None:
        hits, of = self.shares[name]
        return hits / of if of else None

    def to_dict(self) -> dict:
        return {"metrics": {m: self.metrics[m].to_dict() for m in ARCHIVE_BINS},
                "shares": {s: list(self.shares[s]) for s in ARCHIVE_SHARES}}

    @classmethod
    def from_dict(cls, d: dict) -> "Bucket":
        b = cls()
        for name, h in (d.get("metrics") or {}).items():
            if name in b.metrics:
                b.metrics[name] = Histogram.from_dict(h)
        for name, pair in (d.get("shares") or {}).items():
            if name in b.shares and len(pair) == 2:
                b.shares[name] = [int(pair[0]), int(pair[1])]
        return b

    def to_bytes(self) -> bytes:
        return deflate(self.to_dict())

    @classmethod
    def from_bytes(cls, z: bytes) -> "Bucket":
        return cls.from_dict(inflate(z))


# ---------------------------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Source:
    """One way a content was reached. ``verified_at`` is when the content behind it was hashed
    (None: now); for a file it pairs with the ``stat_key`` taken just before hashing."""
    kind: str                       # "file", "photokit" or "picker"
    locator: str
    stat_key: str | None = None
    signature: str | None = None
    verified_at: float | None = None


@dataclass(frozen=True)
class Asset:
    id: int
    sha256: bytes
    status: str
    analyzer_key: str
    has_record: bool
    file: str | None
    camera: str
    captured_at: str | None
    captured_ts: float | None
    reason: str | None
    headline: dict
    attempts: int = 0               # failed measurements with ``analyzer_key``

    @property
    def sha_hex(self) -> str:
        return self.sha256.hex()

    @property
    def final(self) -> bool:
        """A failure that is not tried again with this key (``--retry-failed`` still does)."""
        return self.status == "failed" and self.attempts >= FINAL_ATTEMPTS


_ASSET_SELECT = """SELECT a.*, EXISTS (SELECT 1 FROM record r WHERE r.asset_id = a.id) AS has_record FROM asset a"""

# Newest first within a camera: dated photos by capture time, then undated ones by first sight,
# so undated photos are the first to leave the window.
_NEWEST_FIRST = "a.captured_ts IS NULL, a.captured_ts DESC, a.first_seen DESC, a.id DESC"


def _asset(row) -> Asset | None:
    if row is None:
        return None
    return Asset(id=row["id"], sha256=bytes(row["sha256"]), status=row["status"],
                 analyzer_key=row["analyzer_key"], has_record=bool(row["has_record"]), file=row["file"],
                 camera=row["camera"], captured_at=row["captured_at"], captured_ts=row["captured_ts"],
                 reason=row["reason"], headline={m: row[col] for m, (col, _) in HEADLINE_FIELDS.items()},
                 attempts=row["attempts"])


def _headline_of_row(row) -> dict:
    return {m: row[col] for m, (col, _) in HEADLINE_FIELDS.items()}


def library_versions() -> dict:
    """Versions of the libraries a measurement ran on: provenance, not part of the analyzer key."""
    import importlib
    out = {"python": sys.version.split()[0], "sqlite": sqlite3.sqlite_version}
    for name in ("numpy", "scipy", "cv2", "PIL", "pillow_heif", "rawpy"):
        try:
            mod = sys.modules.get(name) or importlib.import_module(name)
        except Exception:
            continue
        out[name] = str(getattr(mod, "__version__", "unknown"))
        if name == "pillow_heif":
            with contextlib.suppress(Exception):
                out["libheif"] = str(mod.libheif_version())
        if name == "rawpy":
            with contextlib.suppress(Exception):
                out["libraw"] = ".".join(str(v) for v in mod.libraw_version)
    return out


# ---------------------------------------------------------------------------------------------
# Opening the file
# ---------------------------------------------------------------------------------------------

class _Damaged(Exception):
    pass


def _schema_sql() -> str:
    from importlib import resources
    return resources.files(__package__).joinpath("memory_schema.sql").read_text(encoding="utf-8")


def _identify(path: str) -> None:
    """Refuse, without touching it, a file that does not say it is an IQ Coach memory: only a
    file that does is ever moved aside as damaged."""
    with open(path, "rb") as fh:
        head = fh.read(100)
    if not head.startswith(SQLITE_MAGIC) or len(head) < 100:
        raise MemoryFileError(f"{path} is not an SQLite database; it was left untouched. "
                              "Point --memory at another file or move this one away.")
    app_id = int.from_bytes(head[68:72], "big")
    if app_id != APPLICATION_ID:
        raise MemoryFileError(f"{path} is an SQLite database but not an IQ Coach memory (application_id "
                              f"{app_id:#010x}, expected {APPLICATION_ID:#010x}); it was left untouched.")


def _connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=5.0, autocommit=True)
    conn.row_factory = sqlite3.Row
    for pragma in ("synchronous=NORMAL", "busy_timeout=5000", "foreign_keys=ON", "journal_size_limit=4194304"):
        conn.execute(f"PRAGMA {pragma}").fetchall()
    return conn


def _is_corruption(exc: sqlite3.Error) -> bool:
    code = getattr(exc, "sqlite_errorcode", None)
    return code is not None and (code & 0xFF) in _CORRUPTION_CODES


def _initialise(conn: sqlite3.Connection) -> None:
    # page_size and auto_vacuum only take effect before the first table exists. The schema runs in
    # one transaction, so a crash leaves no half-made file, and a second process that raced to
    # create the same file finds the application id already set and adds nothing.
    conn.execute("PRAGMA page_size=4096")
    conn.execute("PRAGMA auto_vacuum=INCREMENTAL")
    conn.execute("BEGIN IMMEDIATE")
    try:
        if conn.execute("PRAGMA application_id").fetchone()[0] == 0:
            conn.executescript(_schema_sql())
            conn.executemany("INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
                             [("created", f"{time.time():.3f}"), ("window", str(DEFAULT_WINDOW)),
                              ("detail_budget_bytes", str(DEFAULT_DETAIL_BUDGET))])
        conn.execute("COMMIT")
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def _check(conn: sqlite3.Connection, path: str) -> None:
    try:
        rows = [tuple(r) for r in conn.execute("PRAGMA quick_check").fetchall()]
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        tables = conn.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table'").fetchone()[0]
    except sqlite3.DatabaseError as exc:
        if _is_corruption(exc):
            raise _Damaged(str(exc)) from exc
        raise
    if rows != [("ok",)]:
        raise _Damaged("; ".join(str(r[0]) for r in rows[:3]))
    if version > SCHEMA_VERSION:
        raise MemoryFileError(f"{path} was written by a newer iqa (schema version {version}; this code "
                              f"knows {SCHEMA_VERSION}); it was left untouched. Update iqa to read it.")
    if version < SCHEMA_VERSION:
        if version == 0 and tables == 0:
            _initialise(conn)        # ours but empty: a creation that never committed
            return
        raise MemoryFileError(f"{path} has schema version {version}, which this code cannot migrate; "
                              "it was left untouched.")
    _add_attempts(conn)


def _add_attempts(conn: sqlite3.Connection) -> None:
    # A pre-release file of schema version 1 made before the attempts column (nothing had shipped,
    # so the version stayed 1). Adding a column with a constant default does not rewrite the table.
    def has() -> bool:
        return any(r[1] == "attempts" for r in conn.execute("PRAGMA table_info(asset)"))
    if has():
        return
    conn.execute("BEGIN IMMEDIATE")
    try:
        if not has():                # a second process may have added it while this one waited
            conn.execute("ALTER TABLE asset ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0")
        conn.execute("COMMIT")
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def _move_aside(path: str) -> str:
    folder, name = os.path.split(path)
    stem, ext = os.path.splitext(name)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    bad = os.path.join(folder, f"{stem}.bad-{stamp}{ext or '.sqlite'}")
    k = 1
    while os.path.exists(bad):
        bad = os.path.join(folder, f"{stem}.bad-{stamp}-{k}{ext or '.sqlite'}")
        k += 1
    os.rename(path, bad)
    for suffix in ("-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.rename(path + suffix, bad + suffix)
    return bad


# ---------------------------------------------------------------------------------------------
# The memory
# ---------------------------------------------------------------------------------------------

class Memory:
    """One open memory file. Use ``Memory.open(path)``; every write method is one transaction."""

    def __init__(self, conn: sqlite3.Connection, path: str, moved_aside: str | None = None):
        self.conn = conn
        self.path = path
        self.moved_aside = moved_aside          # where a damaged file was moved, when one was

    @classmethod
    def open(cls, path: str, create: bool = True) -> "Memory":
        """Open (or, with ``create``, make) the memory at ``path``. An existing file is checked
        with ``PRAGMA quick_check``; a damaged one is renamed ``<name>.bad-<stamp>.sqlite`` (with its
        -wal and -shm) and a fresh memory started. A file that is not an IQ Coach memory, or was
        written by a newer schema, raises MemoryFileError and is left untouched."""
        path = os.path.abspath(os.path.expanduser(path))
        moved = None
        if os.path.exists(path) and os.path.getsize(path) > 0:
            _identify(path)
            conn = None
            try:
                conn = _connect(path)
                _check(conn, path)
            except _Damaged as exc:
                if conn is not None:
                    conn.close()
                moved = _move_aside(path)
                print(f"iqa memory: {path} was damaged ({exc}); moved aside to {moved}", file=sys.stderr)
                if not create:
                    raise MemoryFileError(f"{path} was damaged and has been moved aside to {moved}") from exc
                conn = _connect(path)
                _initialise(conn)
            except BaseException:
                if conn is not None:
                    conn.close()
                raise
        else:
            if not create:
                raise MemoryFileError(f"no memory at {path}")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            conn = _connect(path)
            _initialise(conn)
        conn.execute("PRAGMA journal_mode=WAL").fetchall()
        return cls(conn, path, moved)

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "Memory":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    @contextlib.contextmanager
    def transaction(self):
        """``BEGIN IMMEDIATE`` ... ``COMMIT``, rolled back on any error. Taking the write lock up
        front means a transaction never has to upgrade a read lock, which is what fails under a
        second writer."""
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            yield self.conn
            self.conn.execute("COMMIT")
        except BaseException:
            if self.conn.in_transaction:
                self.conn.execute("ROLLBACK")
            raise

    # -- meta ----------------------------------------------------------------------------------

    def get_meta(self, key: str, default: str | None = None) -> str | None:
        row = self.conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return default if row is None else row[0]

    def set_meta(self, key: str, value: str) -> None:
        with self.transaction() as c:
            c.execute("INSERT INTO meta (key, value) VALUES (?, ?) "
                      "ON CONFLICT (key) DO UPDATE SET value = excluded.value", (key, str(value)))

    def window(self) -> int:
        return int(self.get_meta("window") or DEFAULT_WINDOW)

    def detail_budget(self) -> int:
        return int(self.get_meta("detail_budget_bytes") or DEFAULT_DETAIL_BUDGET)

    def record_provenance(self) -> None:
        """Store the library versions of this run's measurements. Called after a measurement, when
        the libraries are loaded already, so the remembered path imports nothing."""
        self.set_meta("provenance", json.dumps(library_versions(), sort_keys=True))

    # -- lookups -------------------------------------------------------------------------------

    def asset(self, sha: bytes) -> Asset | None:
        return _asset(self.conn.execute(f"{_ASSET_SELECT} WHERE a.sha256 = ?", (sha,)).fetchone())

    def asset_by_source(self, kind: str, locator: str) -> Asset | None:
        return _asset(self.conn.execute(
            f"{_ASSET_SELECT} JOIN source s ON s.asset_id = a.id WHERE s.kind = ? AND s.locator = ?",
            (kind, locator)).fetchone())

    def sha_from_stat(self, path: str, st: os.stat_result | None = None) -> bytes | None:
        """The stat fast path: the content id of a file known by its real path, without reading
        it, when its stat key is unchanged and it was last modified more than a second before it
        was hashed (git's racy-clean rule: a change within the timestamp granularity of the hash
        could otherwise leave the stat key as it was). None means: hash the file."""
        real = os.path.realpath(path)
        st = os.stat(real) if st is None else st
        row = self.conn.execute(
            "SELECT a.sha256, s.stat_key, s.verified_at FROM source s JOIN asset a ON a.id = s.asset_id "
            "WHERE s.kind = 'file' AND s.locator = ?", (real,)).fetchone()
        if row is None or row["stat_key"] != stat_key(st):
            return None
        if st.st_mtime_ns >= (row["verified_at"] - RACY_S) * 1e9:
            return None
        return bytes(row["sha256"])

    def record(self, asset_id: int) -> dict | None:
        """The stored record with its detail merged in, when both are kept."""
        row = self.conn.execute("SELECT r.z AS rz, d.z AS dz FROM record r LEFT JOIN detail d "
                                "ON d.asset_id = r.asset_id WHERE r.asset_id = ?", (asset_id,)).fetchone()
        if row is None:
            return None
        rec = inflate(row["rz"])
        if row["dz"] is not None:
            rec.update(inflate(row["dz"]))
        return rec

    # -- writes --------------------------------------------------------------------------------

    def _add_sources(self, c, asset_id: int, sources, now: float) -> None:
        # The stat key and signature describe the content behind the source when it was verified,
        # so they are replaced together with the asset they point at, never kept from before.
        c.executemany(
            "INSERT INTO source (kind, locator, asset_id, stat_key, signature, verified_at) "
            "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (kind, locator) DO UPDATE SET asset_id = excluded.asset_id, "
            "stat_key = excluded.stat_key, signature = excluded.signature, verified_at = excluded.verified_at",
            [(s.kind, s.locator, asset_id, s.stat_key, s.signature,
              now if s.verified_at is None else s.verified_at) for s in sources])

    def _unfold_if_archived(self, c, sha: bytes) -> bool:
        """Take a photo out of its archive bucket before it is measured again, replaced or
        forgotten, so the archive counts each remembered photo at most once. A measured photo
        without a record is one whose record was folded."""
        row = c.execute(f"{_ASSET_SELECT} WHERE a.sha256 = ?", (sha,)).fetchone()
        if row is None or row["status"] != "measured" or row["has_record"]:
            return False
        key = (row["camera"], month_of(row["captured_ts"]), row["analyzer_key"])
        b = c.execute("SELECT n, z FROM archive WHERE camera = ? AND month = ? AND analyzer_key = ?", key).fetchone()
        if b is None:
            return False
        bucket = Bucket.from_bytes(b["z"])
        if not bucket.unfold(_headline_of_row(row)):
            return False
        if b["n"] <= 1:
            c.execute("DELETE FROM archive WHERE camera = ? AND month = ? AND analyzer_key = ?", key)
        else:
            c.execute("UPDATE archive SET n = n - 1, z = ? WHERE camera = ? AND month = ? AND analyzer_key = ?",
                      (bucket.to_bytes(), *key))
        return True

    def put_measured(self, sha: bytes, record: dict, detail: dict | None, sources, wall_s: float | None,
                     cpu_s: float | None, dhash: str | None, *, byte_size: int,
                     key: str | None = None, now: float | None = None) -> int:
        """Remember a measurement: the ledger row (upserted), the record, the detail and the
        sources, in one transaction. ``key`` is the analyzer key it was made with (default: the
        record's, else this code's default). Returns the asset id."""
        key = key or record.get("analyzer_key") or analyzer_key()
        now = time.time() if now is None else now
        h = headline(record)
        captured_at = record.get("datetime") if isinstance(record.get("datetime"), str) else None
        dh = bytes.fromhex(dhash) if isinstance(dhash, str) and len(dhash) == 64 else None
        params = {
            "sha256": sha, "byte_size": int(byte_size), "file": record.get("file"),
            "camera": record.get("camera_model") or "", "format": record.get("format"),
            "captured_at": captured_at, "captured_ts": exif_timestamp(captured_at), "dhash256": dh,
            "analyzer_key": key, "now": now, "wall_s": _finite(wall_s), "cpu_s": _finite(cpu_s),
            **{col: h[m] for m, (col, _) in HEADLINE_FIELDS.items()},
        }
        z = deflate(storable(record))
        with self.transaction() as c:
            self._unfold_if_archived(c, sha)
            asset_id = c.execute(
                "INSERT INTO asset (sha256, byte_size, file, camera, format, captured_at, captured_ts, dhash256, "
                "status, analyzer_key, measured_at, wall_s, cpu_s, first_seen, last_seen, reason, "
                "h_sharpness_lwph, h_snr_db, h_clip_high_pct, h_clip_low_pct, h_tilt_deg) "
                "VALUES (:sha256, :byte_size, :file, :camera, :format, :captured_at, :captured_ts, :dhash256, "
                "'measured', :analyzer_key, :now, :wall_s, :cpu_s, :now, :now, NULL, "
                ":h_sharpness_lwph, :h_snr_db, :h_clip_high_pct, :h_clip_low_pct, :h_tilt_deg) "
                "ON CONFLICT (sha256) DO UPDATE SET byte_size = excluded.byte_size, "
                "file = coalesce(asset.file, excluded.file), camera = excluded.camera, format = excluded.format, "
                "captured_at = excluded.captured_at, captured_ts = excluded.captured_ts, "
                "dhash256 = coalesce(excluded.dhash256, asset.dhash256), status = 'measured', "
                "analyzer_key = excluded.analyzer_key, measured_at = excluded.measured_at, "
                "wall_s = excluded.wall_s, cpu_s = excluded.cpu_s, last_seen = excluded.last_seen, reason = NULL, "
                "attempts = 0, h_sharpness_lwph = excluded.h_sharpness_lwph, h_snr_db = excluded.h_snr_db, "
                "h_clip_high_pct = excluded.h_clip_high_pct, h_clip_low_pct = excluded.h_clip_low_pct, "
                "h_tilt_deg = excluded.h_tilt_deg RETURNING id", params).fetchall()[0][0]
            c.execute("INSERT INTO record (asset_id, z) VALUES (?, ?) "
                      "ON CONFLICT (asset_id) DO UPDATE SET z = excluded.z", (asset_id, z))
            if detail:
                zd = deflate(detail)
                c.execute("INSERT INTO detail (asset_id, z, bytes) VALUES (?, ?, ?) ON CONFLICT (asset_id) "
                          "DO UPDATE SET z = excluded.z, bytes = excluded.bytes", (asset_id, zd, len(zd)))
            else:
                c.execute("DELETE FROM detail WHERE asset_id = ?", (asset_id,))
            self._add_sources(c, asset_id, sources, now)
        return asset_id

    def put_status(self, sha: bytes, status: str, reason: str | None, *, byte_size: int,
                   file: str | None = None, camera: str | None = None, format: str | None = None,
                   captured_at: str | None = None, key: str | None = None, sources=(),
                   wall_s: float | None = None, cpu_s: float | None = None, now: float | None = None) -> bool:
        """Remember a photo that is not measured: ``failed`` (with the exception) or ``not_capture``
        (with the app's reason). A measurement made with the same analyzer key is never replaced by
        a failure or a late verdict; then only the sources and last_seen change and the result is
        False. Otherwise any older measurement (another key) is replaced, and True returned.
        A failure counts an attempt: one more after a failure with the same key, else the first."""
        if status not in ("failed", "not_capture"):
            raise ValueError(f"put_status takes 'failed' or 'not_capture', not {status!r}")
        key = key or analyzer_key()
        now = time.time() if now is None else now
        with self.transaction() as c:
            cur = c.execute("SELECT id, status, analyzer_key FROM asset WHERE sha256 = ?", (sha,)).fetchone()
            if cur is not None and cur["status"] == "measured" and cur["analyzer_key"] == key:
                c.execute("UPDATE asset SET last_seen = ? WHERE id = ?", (now, cur["id"]))
                self._add_sources(c, cur["id"], sources, now)
                return False
            if cur is not None:
                self._unfold_if_archived(c, sha)
                c.execute("DELETE FROM record WHERE asset_id = ?", (cur["id"],))
                c.execute("DELETE FROM detail WHERE asset_id = ?", (cur["id"],))
            asset_id = c.execute(
                "INSERT INTO asset (sha256, byte_size, file, camera, format, captured_at, captured_ts, status, "
                "analyzer_key, measured_at, wall_s, cpu_s, first_seen, last_seen, reason, attempts) "
                "VALUES (:sha256, :byte_size, :file, :camera, :format, :captured_at, :captured_ts, :status, "
                ":analyzer_key, :now, :wall_s, :cpu_s, :now, :now, :reason, :status = 'failed') "
                "ON CONFLICT (sha256) DO UPDATE SET byte_size = excluded.byte_size, "
                "file = coalesce(asset.file, excluded.file), "
                "camera = CASE WHEN excluded.camera = '' THEN asset.camera ELSE excluded.camera END, "
                "format = coalesce(excluded.format, asset.format), "
                "captured_at = coalesce(excluded.captured_at, asset.captured_at), "
                "captured_ts = coalesce(excluded.captured_ts, asset.captured_ts), "
                "attempts = CASE WHEN excluded.status <> 'failed' THEN 0 WHEN asset.status = 'failed' "
                "AND asset.analyzer_key = excluded.analyzer_key THEN asset.attempts + 1 ELSE 1 END, "
                "status = excluded.status, "
                "analyzer_key = excluded.analyzer_key, measured_at = excluded.measured_at, "
                "wall_s = excluded.wall_s, cpu_s = excluded.cpu_s, last_seen = excluded.last_seen, "
                "reason = excluded.reason, h_sharpness_lwph = NULL, h_snr_db = NULL, h_clip_high_pct = NULL, "
                "h_clip_low_pct = NULL, h_tilt_deg = NULL RETURNING id",
                {"sha256": sha, "byte_size": int(byte_size), "file": file, "camera": camera or "",
                 "format": format, "captured_at": captured_at, "captured_ts": exif_timestamp(captured_at),
                 "status": status, "analyzer_key": key, "now": now, "wall_s": _finite(wall_s),
                 "cpu_s": _finite(cpu_s), "reason": reason}).fetchall()[0][0]
            self._add_sources(c, asset_id, sources, now)
        return True

    def add_source(self, sha: bytes, kind: str, locator: str, stat_key: str | None = None,
                   signature: str | None = None, verified_at: float | None = None,
                   now: float | None = None) -> bool:
        """Link a source to a known content (and mark the content seen). False when the content
        is unknown: a source is an alias and never creates an asset."""
        now = time.time() if now is None else now
        with self.transaction() as c:
            row = c.execute("SELECT id FROM asset WHERE sha256 = ?", (sha,)).fetchone()
            if row is None:
                return False
            c.execute("UPDATE asset SET last_seen = ? WHERE id = ?", (now, row["id"]))
            self._add_sources(c, row["id"], [Source(kind, locator, stat_key, signature, verified_at)], now)
        return True

    def touch(self, sha: bytes, sources=(), now: float | None = None) -> None:
        """Mark a remembered photo seen now, adding the sources it was reached through."""
        now = time.time() if now is None else now
        with self.transaction() as c:
            row = c.execute("SELECT id FROM asset WHERE sha256 = ?", (sha,)).fetchone()
            if row is None:
                return
            c.execute("UPDATE asset SET last_seen = ? WHERE id = ?", (now, row["id"]))
            self._add_sources(c, row["id"], sources, now)

    # -- compaction ----------------------------------------------------------------------------

    def _db_bytes(self) -> int:
        return (self.conn.execute("PRAGMA page_count").fetchone()[0]
                * self.conn.execute("PRAGMA page_size").fetchone()[0])

    def _vacuum(self) -> None:
        # The pragma frees pages as it is stepped: without fetchall() it reclaims nothing.
        self.conn.execute("PRAGMA incremental_vacuum").fetchall()

    def compact(self, window: int | None = None, detail_budget: int | None = None) -> dict:
        """Fold the records beyond each camera's newest ``window`` into the archive, drop detail
        beyond ``detail_budget`` bytes oldest capture first, and give the freed pages back.
        Arguments given are saved as the new settings. Idempotent."""
        if window is not None:
            if int(window) < 1:
                raise ValueError("window must be at least 1")
            self.set_meta("window", str(int(window)))
        if detail_budget is not None:
            if int(detail_budget) < 0:
                raise ValueError("detail budget must not be negative")
            self.set_meta("detail_budget_bytes", str(int(detail_budget)))
        window, budget = self.window(), self.detail_budget()
        before = self._db_bytes()
        with self.transaction() as c:
            rows = c.execute(
                "SELECT * FROM (SELECT a.*, row_number() OVER (PARTITION BY a.camera ORDER BY "
                f"{_NEWEST_FIRST}) AS rank FROM asset a JOIN record r ON r.asset_id = a.id "
                "WHERE a.status = 'measured') WHERE rank > ?", (window,)).fetchall()
            groups: dict = {}
            for r in rows:
                groups.setdefault((r["camera"], month_of(r["captured_ts"]), r["analyzer_key"]), []).append(r)
            for key, rs in sorted(groups.items()):
                old = c.execute("SELECT n, first_ts, last_ts, z FROM archive WHERE camera = ? AND month = ? "
                                "AND analyzer_key = ?", key).fetchone()
                bucket = Bucket.from_bytes(old["z"]) if old else Bucket()
                for r in rs:
                    bucket.fold(_headline_of_row(r))
                ts = [r["captured_ts"] for r in rs if r["captured_ts"] is not None]
                if old is not None:
                    ts += [t for t in (old["first_ts"], old["last_ts"]) if t is not None]
                c.execute("INSERT INTO archive (camera, month, analyzer_key, n, first_ts, last_ts, z) "
                          "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (camera, month, analyzer_key) DO UPDATE SET "
                          "n = excluded.n, first_ts = excluded.first_ts, last_ts = excluded.last_ts, z = excluded.z",
                          (*key, (old["n"] if old else 0) + len(rs), min(ts) if ts else None,
                           max(ts) if ts else None, bucket.to_bytes()))
            ids = [(r["id"],) for r in rows]
            c.executemany("DELETE FROM record WHERE asset_id = ?", ids)
            details_folded = sum(c.execute("DELETE FROM detail WHERE asset_id = ?", i).rowcount for i in ids)
            dropped = c.execute(
                "DELETE FROM detail WHERE asset_id IN (SELECT asset_id FROM (SELECT d.asset_id, sum(d.bytes) "
                f"OVER (ORDER BY {_NEWEST_FIRST} ROWS UNBOUNDED PRECEDING) AS kept FROM detail d "
                "JOIN asset a ON a.id = d.asset_id) WHERE kept > ?)", (budget,)).rowcount
        self._vacuum()
        self.set_meta("last_compact", f"{time.time():.3f}")
        return {"folded": len(rows), "buckets_touched": len(groups), "details_folded": details_folded,
                "details_dropped": dropped, "window": window, "detail_budget_bytes": budget,
                "bytes_before": before, "bytes_after": self._db_bytes()}

    # -- forgetting ----------------------------------------------------------------------------

    def forget(self, camera: str | None = None, before: str | None = None, sha: bytes | None = None,
               all: bool = False) -> dict:
        """Forget one camera's measured photos, everything captured before a date (``YYYY-MM-DD``),
        one content, or everything. Ledger rows go with their sources, records and detail. Archive
        buckets go with a camera or everything; for a date, the buckets of months wholly before it
        go, and photos earlier in the date's own month are taken out of its bucket one by one, so the
        photos on and after the date keep their counts. Undated photos have no date to be before."""
        if sum((camera is not None, before is not None, sha is not None, bool(all))) != 1:
            raise ValueError("forget takes exactly one of camera, before, sha or all")
        cutoff = None
        if before is not None:
            ok = isinstance(before, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", before)
            cutoff = exif_timestamp(f"{before.replace('-', ':')} 00:00:00") if ok else None
            if cutoff is None:
                raise ValueError(f"before must be a date YYYY-MM-DD, not {before!r}")
        adjusted = 0
        with self.transaction() as c:
            if all:
                assets = c.execute("DELETE FROM asset").rowcount
                buckets = c.execute("DELETE FROM archive").rowcount
            elif camera is not None:
                # Only the measured photos a camera is listed with: failed and not_capture verdicts are
                # mostly camera-less (''), so forgetting the unknown camera would otherwise drop them
                # for every camera and have them downloaded and tried again.
                assets = c.execute("DELETE FROM asset WHERE camera = ? AND status = 'measured'", (camera,)).rowcount
                buckets = c.execute("DELETE FROM archive WHERE camera = ?", (camera,)).rowcount
            elif sha is not None:
                adjusted = int(self._unfold_if_archived(c, sha))
                assets = c.execute("DELETE FROM asset WHERE sha256 = ?", (sha,)).rowcount
                buckets = 0
            else:
                buckets = c.execute("DELETE FROM archive WHERE month <> 'undated' AND month < ?",
                                    (before[:7],)).rowcount
                for (s,) in c.execute("SELECT sha256 FROM asset WHERE captured_ts < ?", (cutoff,)).fetchall():
                    adjusted += self._unfold_if_archived(c, bytes(s))
                assets = c.execute("DELETE FROM asset WHERE captured_ts < ?", (cutoff,)).rowcount
        self._vacuum()
        return {"assets": assets, "buckets_deleted": buckets, "buckets_adjusted": adjusted}

    # -- reading out ---------------------------------------------------------------------------

    def window_records(self, camera: str | None = None) -> list[dict]:
        """The window: each camera's newest ``window`` stored records, newest first, with
        ``sha256`` (hex) and ``analyzer_key`` added and the detail merged in when it is kept."""
        where, args = ("AND a.camera = ?", (camera,)) if camera is not None else ("", ())
        rows = self.conn.execute(
            "SELECT * FROM (SELECT a.sha256, a.analyzer_key, a.camera, r.z AS rz, d.z AS dz, row_number() OVER "
            f"(PARTITION BY a.camera ORDER BY {_NEWEST_FIRST}) AS rank FROM asset a JOIN record r ON r.asset_id = a.id "
            f"LEFT JOIN detail d ON d.asset_id = a.id WHERE a.status = 'measured' {where}) WHERE rank <= ? "
            "ORDER BY camera, rank", (*args, self.window())).fetchall()
        out = []
        for r in rows:
            rec = inflate(r["rz"])
            rec["sha256"] = bytes(r["sha256"]).hex()
            rec["analyzer_key"] = r["analyzer_key"]
            if r["dz"] is not None:
                rec.update(inflate(r["dz"]))
            out.append(rec)
        return out

    def export(self, out_path: str, camera: str | None = None) -> int:
        """Write the window as a results.json (the shape write_json produces), for ``iqa report``."""
        from .report import write_json
        records = self.window_records(camera)
        folder = os.path.dirname(os.path.abspath(out_path))
        os.makedirs(folder, exist_ok=True)
        write_json(records, out_path)
        return len(records)

    def archive_buckets(self, camera: str | None = None) -> list[dict]:
        where, args = ("WHERE camera = ?", (camera,)) if camera is not None else ("", ())
        rows = self.conn.execute(f"SELECT * FROM archive {where} ORDER BY camera, month, analyzer_key", args).fetchall()
        return [{"camera": r["camera"], "month": r["month"], "analyzer_key": r["analyzer_key"], "n": r["n"],
                 "first_ts": r["first_ts"], "last_ts": r["last_ts"], "bucket": Bucket.from_bytes(r["z"])}
                for r in rows]

    def _tier_bytes(self) -> tuple[dict, bool]:
        tiers = {"asset": "ledger", "source": "ledger", "record": "record", "detail": "detail",
                 "archive": "archive", "meta": "meta"}
        try:
            owner = {r["name"]: r["tbl_name"] for r in self.conn.execute("SELECT name, tbl_name FROM sqlite_master")}
            out: dict = {}
            for r in self.conn.execute("SELECT name, sum(pgsize) AS b FROM dbstat GROUP BY name"):
                tier = tiers.get(owner.get(r["name"], r["name"]), "other")
                out[tier] = out.get(tier, 0) + r["b"]
            return out, True
        except sqlite3.OperationalError:
            # No dbstat in this SQLite: payload sizes for the blob tiers, the rest is the ledger.
            c = self.conn
            out = {"record": c.execute("SELECT coalesce(sum(length(z)), 0) FROM record").fetchone()[0],
                   "detail": c.execute("SELECT coalesce(sum(bytes), 0) FROM detail").fetchone()[0],
                   "archive": c.execute("SELECT coalesce(sum(length(z)), 0) FROM archive").fetchone()[0]}
            used = self._db_bytes() - c.execute("PRAGMA freelist_count").fetchone()[0] * c.execute(
                "PRAGMA page_size").fetchone()[0]
            out["ledger"] = max(0, used - sum(out.values()))
            return out, False

    def stats(self) -> dict:
        """What the memory holds: counts and bytes per tier, the capture span overall and per
        camera, the settings, and the analyzer keys."""
        c = self.conn
        one = lambda sql, *a: c.execute(sql, a).fetchone()[0]   # noqa: E731
        tier_bytes, exact = self._tier_bytes()
        current = self.get_meta("current_analyzer_key")
        by_status = {r[0]: r[1] for r in c.execute("SELECT status, count(*) FROM asset GROUP BY status")}
        span = c.execute("SELECT min(captured_ts), max(captured_ts) FROM asset WHERE status = 'measured'").fetchone()
        archived = {r[0]: r[1] for r in c.execute("SELECT camera, sum(n) FROM archive GROUP BY camera")}
        cameras = []
        for r in c.execute(
                "SELECT a.camera, count(*) AS measured, count(r.asset_id) AS records, min(a.captured_ts) AS oldest, "
                "max(a.captured_ts) AS newest, sum(a.captured_ts IS NULL) AS undated FROM asset a "
                "LEFT JOIN record r ON r.asset_id = a.id WHERE a.status = 'measured' GROUP BY a.camera "
                "ORDER BY count(*) DESC, a.camera"):
            cameras.append({"camera": r["camera"], "measured": r["measured"], "records": r["records"],
                            "archived": archived.get(r["camera"], 0), "undated": r["undated"],
                            "oldest_capture": _wall_clock(r["oldest"]), "newest_capture": _wall_clock(r["newest"]),
                            "newest_ts": r["newest"]})
        file_bytes = sum(os.path.getsize(self.path + s) for s in ("", "-wal", "-shm") if os.path.exists(self.path + s))
        return {
            "path": self.path,
            "file_bytes": file_bytes,
            "db_bytes": self._db_bytes(),
            "freelist_pages": one("PRAGMA freelist_count"),
            "bytes_exact": exact,
            "tiers": {
                "ledger": {"assets": one("SELECT count(*) FROM asset"), "sources": one("SELECT count(*) FROM source"),
                           "bytes": tier_bytes.get("ledger", 0)},
                "record": {"count": one("SELECT count(*) FROM record"), "bytes": tier_bytes.get("record", 0)},
                "detail": {"count": one("SELECT count(*) FROM detail"),
                           "payload_bytes": one("SELECT coalesce(sum(bytes), 0) FROM detail"),
                           "bytes": tier_bytes.get("detail", 0)},
                "archive": {"buckets": one("SELECT count(*) FROM archive"),
                            "photos": one("SELECT coalesce(sum(n), 0) FROM archive"),
                            "bytes": tier_bytes.get("archive", 0)},
            },
            "status": {s: by_status.get(s, 0) for s in ("measured", "failed", "not_capture")},
            "stale": one("SELECT count(*) FROM asset WHERE status = 'measured' AND analyzer_key <> ?",
                         current or analyzer_key()),
            "oldest_capture": _wall_clock(span[0]),
            "newest_capture": _wall_clock(span[1]),
            "cameras": cameras,
            "window": self.window(),
            "detail_budget_bytes": self.detail_budget(),
            "current_analyzer_key": current,
            "code_analyzer_key": analyzer_key(),
            "last_compact": self.get_meta("last_compact"),
        }
