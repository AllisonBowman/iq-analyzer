"""The analyzer's memory (iqa/memory.py, docs/MEMORY-SPEC.md).

Ground truth here is mostly exact: a photo is measured once per content and analyzer key, so the
pipeline tests count measurements and hashes with a fake analyzer whose record is a function of the
file's bytes. The archive's statistics are checked against the exact quantiles and shares of
synthetic samples (within half a bin, as the spec promises), the stored format against zlib's raw
DEFLATE, and dHash256 against images whose relation is known (the same picture resized or
re-encoded, independent pictures, a rotation, a flat field).
"""
import base64
import errno
import hashlib
import json
import math
import multiprocessing
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import zlib
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image, UnidentifiedImageError

import iqa
import iqa.memory as M
from iqa import cli
from iqa.fingerprint import dhash256, hamming
from iqa.synth import synthetic_scene

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The raw-DEFLATE bytes of a small record, for the Swift side's cross-language decoding test.
FIXTURE_JSON = '{"file":"IMG_0001.JPG","camera_model":"iPhone 17 Pro Max","snr_midgrey_db":NaN,"mtf50_p80_lwph":812.5}'
FIXTURE_B64 = ("DcpRCoQgEADQq8h8R4wLkXiBaKHwBoO7jiVohi1sEd29vt87wYfIoKEfOkJEWb9NBxV8beJiKWXH8dFg5rywkK0wJYvB7k/ZlkIpuKnwQe4"
               "DerRjBennG6RVIcX/OoNW8lU31w0=")


# ---------------------------------------------------------------------------------------------
# A fake analyzer: the record is a function of the file's bytes (a JSON spec), calls are counted
# ---------------------------------------------------------------------------------------------

class FakeAnalyzer:
    def __init__(self):
        self.calls: list[str] = []
        self.succeed_anyway = False
        self.on_call = None

    def __call__(self, path, max_rois=30, max_side=None):
        self.calls.append(os.path.basename(path))
        if self.on_call:
            self.on_call(path)
        spec = json.loads(open(path, "rb").read().decode())
        if spec.get("fail") and not self.succeed_anyway:
            raise RuntimeError("cannot decode this file")
        edge = {"mtf50": 0.2, "orientation": "v"}
        return {
            "file": os.path.basename(path), "path": path, "is_raw": False, "format": "jpeg",
            "camera_model": spec.get("camera", "CamA"), "datetime": spec.get("datetime"),
            "edges_measured": spec.get("edges", 5), "mtf50_p80_cpp": 0.2, "mtf50_p80_lwph": spec.get("lwph", 800.0),
            "snr_midgrey_db": spec.get("snr", 35.0), "snr_midgrey_extrapolated": False,
            "noise_texture_suspect": False, "noise_periodic_suspect": False, "noise_patches": 10,
            "clip_high_pct": spec.get("clip", 0.5), "clip_low_pct": 0.0,
            "structure_horizon_tilt_deg": spec.get("tilt", float("nan")),
            "dhash256": "0f" * 32, "analysis_s": 0.01, "cpu_s": 0.01,
            "_edges": SimpleNamespace(edges=[SimpleNamespace(as_dict=lambda: dict(edge))]),
            "_noise": SimpleNamespace(bin_centers=np.array([60.0, 118.0]), luma_noise=np.array([1.0, 1.2]),
                                      chroma_noise=np.array([0.5, 0.6]), bin_counts=np.array([5, 5])),
        }


def _photo(folder, name, **spec):
    """A fake photo: its bytes are a JSON spec of the record, unique to its name unless copied."""
    p = os.path.join(folder, name)
    with open(p, "w") as fh:
        fh.write(json.dumps({"name": name, **spec}, sort_keys=True))
    return p


@pytest.fixture
def env(tmp_path, monkeypatch, capsys):
    import iqa.analyze
    fake = FakeAnalyzer()
    monkeypatch.setattr(iqa.analyze, "analyze_file", fake)
    photos = tmp_path / "photos"
    photos.mkdir()
    db = str(tmp_path / "mem" / "memory.sqlite")
    out = str(tmp_path / "out")

    def run(*extra, paths=None):
        argv = ["analyze", *([str(photos)] if paths is None else paths), "--memory", db, "--out", out,
                "--no-report", *extra]
        rc = cli.main(argv)
        o, e = capsys.readouterr()
        lines = [ln.split(" ", 3) for ln in o.splitlines() if ln.startswith("IQA-MEMORY ")]
        return SimpleNamespace(rc=rc, states=[(p[1], p[3]) for p in lines], shas=[p[2] for p in lines], out=o, err=e)

    def results():
        with open(os.path.join(out, "results.json")) as fh:
            return json.load(fh)

    return SimpleNamespace(photos=str(photos), db=db, out=out, fake=fake, run=run, results=results, tmp=tmp_path)


def _sources(db, sha_hex):
    with M.Memory.open(db) as mem:
        return sorted(tuple(r) for r in mem.conn.execute(
            "SELECT s.kind, s.locator FROM source s JOIN asset a ON a.id = s.asset_id WHERE a.sha256 = ?",
            (bytes.fromhex(sha_hex),)))


# ---------------------------------------------------------------------------------------------
# Identity and reuse
# ---------------------------------------------------------------------------------------------

def test_same_bytes_twice_are_measured_once(env):
    _photo(env.photos, "a.jpg", lwph=900.0)
    _photo(env.photos, "b.jpg", lwph=700.0)
    first = env.run()
    assert first.rc == 0 and first.states == [("miss", "a.jpg"), ("miss", "b.jpg")]
    second = env.run()
    assert second.states == [("hit", "a.jpg"), ("hit", "b.jpg")]
    assert env.fake.calls == ["a.jpg", "b.jpg"]
    recs = env.results()
    assert [r["memory_tier"] for r in recs] == ["record", "record"]
    assert recs[0]["mtf50_p80_lwph"] == 900.0 and recs[0]["edges"] == [{"mtf50": 0.2, "orientation": "v"}]
    assert recs[0]["sha256"] == hashlib.sha256(open(os.path.join(env.photos, "a.jpg"), "rb").read()).hexdigest()
    assert recs[0]["path"] == os.path.join(env.photos, "a.jpg")


def test_byte_identical_copy_is_a_hit_with_two_sources(env):
    a = _photo(env.photos, "a.jpg")
    env.run()
    shutil.copyfile(a, os.path.join(env.photos, "copy of a.jpg"))
    r = env.run()
    assert sorted(r.states) == [("hit", "a.jpg"), ("hit", "copy of a.jpg")]
    assert env.fake.calls == ["a.jpg"]
    assert len(set(r.shas)) == 1
    real = os.path.realpath(env.photos)
    assert _sources(env.db, r.shas[0]) == [("file", os.path.join(real, "a.jpg")),
                                          ("file", os.path.join(real, "copy of a.jpg"))]
    copy = [x for x in env.results() if x["file"] == "copy of a.jpg"][0]
    assert copy["path"].endswith("copy of a.jpg")       # this copy's name and path, the stored figures


def test_a_record_folded_by_another_process_after_the_lookup_reads_as_archived(env, monkeypatch):
    _photo(env.photos, "a.jpg")
    env.run()
    monkeypatch.setattr(M.Memory, "record", lambda self, asset_id: None)
    r = env.run()
    assert r.states == [("archived", "a.jpg")] and env.results()[0]["memory_tier"] == "ledger"
    assert env.fake.calls == ["a.jpg"]


def test_one_byte_change_is_a_miss(env):
    a = _photo(env.photos, "a.jpg")
    env.run()
    with open(a, "a") as fh:
        fh.write(" ")
    r = env.run()
    assert r.states == [("miss", "a.jpg")] and env.fake.calls == ["a.jpg", "a.jpg"]


def test_stat_fast_path_skips_hashing_and_the_racy_rule_rehashes(env, monkeypatch):
    hashed = []
    real_hash = M.sha256_file
    monkeypatch.setattr(M, "sha256_file", lambda p: hashed.append(p) or real_hash(p))
    a = _photo(env.photos, "a.jpg")
    assert env.run().states == [("miss", "a.jpg")] and len(hashed) == 1
    # Modified less than a second before it was hashed: the stat key is not trusted yet.
    assert env.run().states == [("hit", "a.jpg")] and len(hashed) == 2
    old = time.time() - 10
    os.utime(a, (old, old))                  # a new ctime: the stat key no longer matches
    assert env.run().states == [("hit", "a.jpg")] and len(hashed) == 3
    # Unchanged and modified long before it was last hashed: no read at all.
    assert env.run().states == [("hit", "a.jpg")] and len(hashed) == 3
    assert env.fake.calls == ["a.jpg"]


def test_a_new_analyzer_key_is_stale_and_replaced(env, monkeypatch):
    _photo(env.photos, "a.jpg", lwph=900.0)
    env.run()
    monkeypatch.setattr(M, "MEASUREMENT_VERSION", 2)
    r = env.run()
    assert r.states == [("stale", "a.jpg")] and env.fake.calls == ["a.jpg", "a.jpg"]
    with M.Memory.open(env.db) as mem:
        rows = mem.conn.execute("SELECT analyzer_key FROM asset").fetchall()
        assert [x[0] for x in rows] == ["m2-r30-s0"]
        assert mem.conn.execute("SELECT count(*) FROM record").fetchone()[0] == 1
        assert mem.get_meta("current_analyzer_key") == "m2-r30-s0"
    assert env.run().states == [("hit", "a.jpg")]
    assert env.run("--max-rois", "20").states == [("stale", "a.jpg")]    # settings are in the key too


def test_a_failure_is_tried_twice_then_final_and_retry_failed_retries(env):
    _photo(env.photos, "bad.jpg", fail=True)
    r = env.run()
    assert r.rc == 4 and r.states == [("failed", "bad.jpg")] and "FAILED" in r.err and "not remembered" not in r.err
    sha = bytes.fromhex(r.shas[0])
    with M.Memory.open(env.db) as mem:
        assert mem.asset(sha).status == "failed" and mem.asset(sha).attempts == 1 and not mem.asset(sha).final
    r = env.run()                          # a first failure is measured once more
    assert r.rc == 4 and r.states == [("failed", "bad.jpg")] and env.fake.calls == ["bad.jpg"] * 2
    with M.Memory.open(env.db) as mem:
        assert mem.asset(sha).attempts == 2 and mem.asset(sha).final
    r = env.run()
    assert r.rc == 0 and r.states == [("skip", "bad.jpg")] and len(env.fake.calls) == 2
    assert "failed 2 times" in r.out
    assert env.run("--retry-failed").states == [("failed", "bad.jpg")]
    env.fake.succeed_anyway = True
    assert env.run("--retry-failed").states == [("miss", "bad.jpg")]
    with M.Memory.open(env.db) as mem:
        assert mem.asset(sha).status == "measured" and mem.asset(sha).attempts == 0
    assert env.run().states == [("hit", "bad.jpg")]
    assert len(env.fake.calls) == 4


def test_a_first_failure_that_passes_on_the_retry_reads_as_a_miss(env):
    _photo(env.photos, "flaky.jpg", fail=True)
    assert env.run().states == [("failed", "flaky.jpg")]
    env.fake.succeed_anyway = True
    r = env.run()
    assert r.rc == 0 and r.states == [("miss", "flaky.jpg")] and [x["file"] for x in env.results()] == ["flaky.jpg"]


def test_attempts_count_failures_with_one_key_and_a_measurement_resets_them(tmp_path):
    with M.Memory.open(str(tmp_path / "m.sqlite")) as mem:
        sha = b"\x02" * 32
        mem.put_status(sha, "failed", "boom", byte_size=10)
        assert mem.asset(sha).attempts == 1 and not mem.asset(sha).final
        mem.put_status(sha, "failed", "boom", byte_size=10)
        assert mem.asset(sha).attempts == 2 and mem.asset(sha).final
        mem.put_status(sha, "failed", "boom", byte_size=10, key="m9-r30-s0")     # another key starts again
        assert mem.asset(sha).attempts == 1
        mem.put_measured(sha, {"file": "a.jpg"}, None, [], 1, 1, None, byte_size=10, key="m9-r30-s0")
        assert mem.asset(sha).status == "measured" and mem.asset(sha).attempts == 0
        mem.put_status(sha, "failed", "boom", byte_size=10)      # replaces a measurement with another key
        assert mem.asset(sha).attempts == 1
        mem.put_status(sha, "not_capture", "under 5 MP", byte_size=10)
        assert mem.asset(sha).attempts == 0 and not mem.asset(sha).final


@pytest.mark.parametrize("exc, remembered", [
    (ModuleNotFoundError("No module named 'cv2'", name="cv2"), False),
    (MemoryError(), False),
    (OSError(errno.EIO, "Input/output error"), False),
    (PermissionError(errno.EACCES, "Permission denied"), False),
    (UnidentifiedImageError("cannot identify image file 'a.jpg'"), True),      # an OSError without an errno
    (OSError("image file is truncated (8 bytes not processed)"), True),
    (RuntimeError("cannot decode this file"), True),
], ids=["no-module", "memory", "eio", "permission", "unidentified", "truncated", "runtime"])
def test_only_failures_of_the_file_itself_are_remembered(env, exc, remembered):
    _photo(env.photos, "a.jpg")

    def fail(path):
        raise exc

    env.fake.on_call = fail
    r = env.run()
    assert r.rc == 4 and r.states == [("failed", "a.jpg")] and ("not remembered" in r.err) is not remembered
    with M.Memory.open(env.db) as mem:
        a = mem.asset(bytes.fromhex(r.shas[0]))
        assert (a is not None and a.status == "failed" and a.attempts == 1) if remembered else a is None


@pytest.mark.parametrize("name, flag", [("IMG_0001.HEIC", "HAVE_HEIF"), ("IMG_0002.DNG", "HAVE_RAWPY")])
def test_a_missing_decoder_is_never_remembered(env, monkeypatch, name, flag):
    import iqa.imageio
    _photo(env.photos, name)
    monkeypatch.setattr(iqa.imageio, flag, False)
    r = env.run()
    assert r.rc == 4 and r.states == [("failed", name)] and env.fake.calls == []
    assert "is not installed" in r.err and "not remembered" in r.err
    with M.Memory.open(env.db) as mem:
        assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 0
    monkeypatch.setattr(iqa.imageio, flag, True)          # the interpreter fixed: measured at once
    assert env.run().states == [("miss", name)] and env.fake.calls == [name]


@pytest.mark.parametrize("when", ["before it is read", "after it is read"])
def test_a_file_that_vanishes_during_analysis_costs_only_itself(env, monkeypatch, when):
    import iqa.analyze
    _photo(env.photos, "a.jpg")
    _photo(env.photos, "b.jpg")
    if when == "before it is read":          # the analyzer's own open fails (FileNotFoundError)
        env.fake.on_call = lambda p: os.remove(p) if p.endswith("a.jpg") else None
    else:                                    # measured, then gone before the re-stat
        def measure_then_delete(path, **kw):
            rec = env.fake(path, **kw)
            if path.endswith("a.jpg"):
                os.remove(path)
            return rec

        monkeypatch.setattr(iqa.analyze, "analyze_file", measure_then_delete)
    r = env.run()
    assert r.rc == 0 and r.states == [("failed", "a.jpg"), ("miss", "b.jpg")] and "not remembered" in r.err
    assert env.fake.calls == ["a.jpg", "b.jpg"] and [x["file"] for x in env.results()] == ["b.jpg"]
    with M.Memory.open(env.db) as mem:
        assert mem.asset(bytes.fromhex(r.shas[0])) is None
        assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 1
        assert mem.get_meta("current_analyzer_key") == "m1-r30-s0" and mem.get_meta("last_compact")


def test_a_damaged_record_is_measured_again_not_failed(env, monkeypatch):
    _photo(env.photos, "a.jpg")
    _photo(env.photos, "b.jpg")
    env.run()
    stored = M.Memory.record

    def damaged(self, asset_id):           # a.jpg's record blob no longer inflates
        rec = stored(self, asset_id)
        if rec["file"] == "a.jpg":
            raise zlib.error("Error -3 while decompressing data: invalid stored block lengths")
        return rec

    monkeypatch.setattr(M.Memory, "record", damaged)
    r = env.run()
    assert r.rc == 0 and r.states == [("stale", "a.jpg"), ("hit", "b.jpg")] and "invalid stored block" in r.err
    assert env.fake.calls == ["a.jpg", "b.jpg", "a.jpg"]          # the file is here: measured again, once
    assert sorted(x["file"] for x in env.results()) == ["a.jpg", "b.jpg"]
    monkeypatch.setattr(M.Memory, "record", stored)
    with M.Memory.open(env.db) as mem:          # the new record replaced the damaged one
        a = mem.asset(bytes.fromhex(r.shas[0]))
        assert a.status == "measured" and mem.record(a.id)["file"] == "a.jpg"


def test_an_unexpected_error_after_hashing_costs_one_photo(env, monkeypatch):
    _photo(env.photos, "a.jpg")
    _photo(env.photos, "b.jpg")
    env.run()
    touch = M.Memory.touch

    def broken(self, sha, sources=(), now=None):     # anything but a database error, on a.jpg only
        if self.asset(sha).file == "a.jpg":
            raise RuntimeError("unexpected")
        return touch(self, sha, sources, now)

    monkeypatch.setattr(M.Memory, "touch", broken)
    r = env.run()
    assert r.rc == 0 and r.states == [("failed", "a.jpg"), ("hit", "b.jpg")] and "unexpected" in r.err
    assert [x["file"] for x in env.results()] == ["b.jpg"]
    with M.Memory.open(env.db) as mem:          # not a verdict on the photo: its measurement stays
        assert mem.asset(bytes.fromhex(r.shas[0])).status == "measured"


def test_every_photo_failing_exits_4_never_1(env):
    _photo(env.photos, "bad.jpg", fail=True)              # remembered
    _photo(env.photos, "gone.jpg")                        # vanished: not remembered
    env.fake.on_call = lambda p: os.remove(p) if p.endswith("gone.jpg") else None
    r = env.run()
    assert r.rc == 4 and r.states == [("failed", "bad.jpg"), ("failed", "gone.jpg")]
    env.fake.on_call = None
    _photo(env.photos, "good.jpg")
    assert env.run().rc == 0                              # one photo measured: a normal run


def test_missing_measurement_libraries_exit_5_and_mark_nothing(env, monkeypatch):
    a = _photo(env.photos, "a.jpg")
    env.run()
    _photo(env.photos, "b.jpg")
    monkeypatch.setitem(sys.modules, "iqa.analyze", None)    # `from .analyze import ...` raises ImportError
    r = env.run()
    assert r.rc == 5 and "measurement libraries cannot be imported" in r.err and "nothing was marked" in r.err
    assert r.states == [("hit", "a.jpg")] and env.fake.calls == ["a.jpg"]
    with M.Memory.open(env.db) as mem:
        assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 1
    assert env.run(paths=[a]).rc == 0             # nothing to measure: the libraries are not needed


def test_a_staged_file_is_measured_only_when_it_hashes_to_the_apps_sha256(env):
    staged = _photo(env.photos, "IMG_0453.JPG")
    shot = _photo(env.photos, "Screenshot.png")
    true_sha = hashlib.sha256(open(staged, "rb").read()).hexdigest()
    shot_sha = hashlib.sha256(open(shot, "rb").read()).hexdigest()
    manifest = env.tmp / "sources.jsonl"
    line = {"path": staged, "kind": "photokit", "locator": "ABC/L0/001", "signature": "s"}
    nc = {"path": shot, "kind": "photokit", "locator": "SCR/L0/001", "status": "not_capture", "reason": "r"}

    def run(sha, nc_sha):
        manifest.write_text(json.dumps({**line, "sha256": sha}) + "\n" + json.dumps({**nc, "sha256": nc_sha}) + "\n")
        return env.run("--sources", str(manifest))

    for wrong in ("00" * 32, "not a hash"):
        r = run(wrong, "11" * 32)
        assert r.rc == 4 and r.states == [("failed", "Screenshot.png"), ("failed", "IMG_0453.JPG")]
        assert r.shas == [shot_sha, true_sha] and env.fake.calls == [] and "not remembered" in r.err
        with M.Memory.open(env.db) as mem:
            assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 0
            assert mem.conn.execute("SELECT count(*) FROM source").fetchone()[0] == 0
    assert "not 64 hex digits" in r.err
    r = run(true_sha.upper(), shot_sha)
    assert r.rc == 0 and r.states == [("skip", "Screenshot.png"), ("miss", "IMG_0453.JPG")]
    assert env.fake.calls == ["IMG_0453.JPG"] and _sources(env.db, true_sha) == [("photokit", "ABC/L0/001")]


def test_an_unreadable_manifest_is_a_usage_error(env):
    _photo(env.photos, "a.jpg")
    manifest = env.tmp / "sources.jsonl"
    manifest.write_bytes(b'{"path": "\xff\xfe"}\n')
    r = env.run("--sources", str(manifest))
    assert r.rc == 2 and "cannot read the sources manifest" in r.err and env.fake.calls == []


def test_a_pre_release_file_without_attempts_gains_the_column(tmp_path):
    path, sha = str(tmp_path / "m.sqlite"), b"\x03" * 32
    with M.Memory.open(path) as mem:
        mem.put_status(sha, "failed", "boom", byte_size=1)
        mem.conn.execute("ALTER TABLE asset DROP COLUMN attempts")
    with M.Memory.open(path) as mem:
        assert mem.asset(sha).attempts == 0 and not mem.asset(sha).final     # an old failure is tried again
        mem.put_status(sha, "failed", "boom", byte_size=1)
        assert mem.asset(sha).attempts == 1


def test_a_failure_never_replaces_a_current_measurement(tmp_path):
    with M.Memory.open(str(tmp_path / "m.sqlite")) as mem:
        sha = b"\x01" * 32
        mem.put_measured(sha, {"file": "a.jpg", "edges_measured": 4, "mtf50_p80_lwph": 900.0}, None, [], 1, 1, None,
                         byte_size=10)
        assert mem.put_status(sha, "failed", "MemoryError()", byte_size=10) is False
        a = mem.asset(sha)
        assert a.status == "measured" and a.has_record and a.headline["sharpness_lwph"] == 900.0
        # Measured with another key: the new verdict replaces the old measurement.
        assert mem.put_status(sha, "failed", "boom", byte_size=10, key="m9-r30-s0") is True
        a = mem.asset(sha)
        assert a.status == "failed" and not a.has_record and a.reason == "boom"


def test_a_file_changed_during_analysis_is_not_remembered(env):
    a = _photo(env.photos, "a.jpg")

    def edit(path):
        with open(path, "a") as fh:
            fh.write(" ")

    env.fake.on_call = edit
    r = env.run()
    assert r.states == [("failed", "a.jpg")]
    with M.Memory.open(env.db) as mem:
        assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 0
    env.fake.on_call = None
    assert env.run().states == [("miss", "a.jpg")]
    assert os.path.exists(a)


def test_not_capture_lines_are_remembered_never_measured(env):
    _photo(env.photos, "IMG_0001.jpg")
    shot = _photo(env.photos, "Screenshot.png")
    manifest = env.tmp / "sources.jsonl"
    manifest.write_text(json.dumps({"path": shot, "kind": "photokit", "locator": "SCR/L0/001", "signature": "s",
                                    "status": "not_capture", "reason": "no EXIF camera model"}) + "\n")
    r = env.run("--sources", str(manifest))
    assert sorted(r.states) == [("miss", "IMG_0001.jpg"), ("skip", "Screenshot.png")]
    assert env.fake.calls == ["IMG_0001.jpg"]
    assert [x["file"] for x in env.results()] == ["IMG_0001.jpg"]
    with M.Memory.open(env.db) as mem:
        a = mem.asset_by_source("photokit", "SCR/L0/001")
        assert a.status == "not_capture" and a.reason == "no EXIF camera model"
    # Presented again without the manifest it is still remembered, still not measured.
    assert sorted(env.run().states) == [("hit", "IMG_0001.jpg"), ("skip", "Screenshot.png")]
    assert env.fake.calls == ["IMG_0001.jpg"]


def test_staged_files_are_known_by_their_manifest_source(env):
    staged = _photo(env.photos, "IMG_0453.JPG")
    manifest = env.tmp / "sources.jsonl"
    manifest.write_text(json.dumps({"path": staged, "kind": "photokit", "locator": "ABC/L0/001",
                                    "signature": "IMG_0453.JPG|public.jpeg|5712x4284"}) + "\n")
    gone = json.dumps({"path": str(env.tmp / "elsewhere.jpg"), "kind": "photokit", "locator": "X/L0/001"})
    manifest.write_text(manifest.read_text() + gone + "\nnot json\n")
    r = env.run("--sources", str(manifest))
    assert _sources(env.db, r.shas[0]) == [("photokit", "ABC/L0/001")]     # no row for the staging path
    assert "not in this batch" in r.err and "not JSON" in r.err
    with M.Memory.open(env.db) as mem:
        assert mem.conn.execute("SELECT signature FROM source").fetchone()[0] == "IMG_0453.JPG|public.jpeg|5712x4284"


def test_staged_files_without_a_locator_leave_no_source(env):
    # A picker item the system gave no identifier, or a copy an earlier version left: measured and
    # remembered by content, but its staging path never becomes an alias in the ledger.
    staged = _photo(env.photos, "photo-0123abcd.jpeg")
    manifest = env.tmp / "sources.jsonl"
    manifest.write_text(json.dumps({"path": staged, "kind": "picker"}) + "\n"
                        + json.dumps({"kind": "picker"}) + "\n")
    r = env.run("--sources", str(manifest))
    assert r.states == [("miss", "photo-0123abcd.jpeg")]
    assert _sources(env.db, r.shas[0]) == []
    assert "needs a kind" in r.err                       # a line with neither path nor locator is refused
    assert env.run("--sources", str(manifest)).states == [("hit", "photo-0123abcd.jpeg")]
    assert env.fake.calls == ["photo-0123abcd.jpeg"]


def test_sha_only_lines_link_a_source_and_an_empty_list_is_allowed(env):
    _photo(env.photos, "a.jpg")
    sha = env.run().shas[0]
    manifest = env.tmp / "sources.jsonl"
    manifest.write_text(json.dumps({"sha256": sha, "kind": "picker", "locator": "item-1"}) + "\n"
                        + json.dumps({"sha256": "ab" * 32, "kind": "picker", "locator": "item-2"}) + "\n")
    r = env.run("--sources", str(manifest), paths=[])
    assert r.rc == 0 and r.states == []
    assert "unknown sha256 " + "ab" * 32 in r.err
    assert ("picker", "item-1") in _sources(env.db, sha)
    with M.Memory.open(env.db) as mem:
        assert mem.asset_by_source("picker", "item-2") is None
    assert env.run(paths=[]).rc == 0             # nothing at all: still fine, still compacts


def test_archived_hits_emit_the_ledger_record_and_refresh_measures(env):
    for k, day in enumerate(("01", "02", "03")):
        _photo(env.photos, f"p{k}.jpg", datetime=f"2026:03:{day} 10:00:00", lwph=700.0 + k, clip=2.0)
    env.run()
    with M.Memory.open(env.db) as mem:
        assert mem.compact(window=1)["folded"] == 2
    r = env.run()
    assert sorted(r.states) == [("archived", "p0.jpg"), ("archived", "p1.jpg"), ("hit", "p2.jpg")]
    assert len(env.fake.calls) == 3
    ledger = {x["file"]: x for x in env.results() if x["memory_tier"] == "ledger"}
    assert ledger["p0.jpg"] == {"file": "p0.jpg", "path": os.path.join(env.photos, "p0.jpg"), "camera_model": "CamA",
                                "datetime": "2026:03:01 10:00:00", "mtf50_p80_lwph": 700.0, "snr_midgrey_db": 35.0,
                                "clip_high_pct": 2.0, "clip_low_pct": 0.0, "structure_horizon_tilt_deg": None,
                                "sha256": r.shas[r.states.index(("archived", "p0.jpg"))],
                                "analyzer_key": "m1-r30-s0", "memory_tier": "ledger"}
    from iqa.report import write_markdown          # a report over ledger rows reads them as partial rows
    write_markdown(env.results(), [], str(env.tmp / "report.md"))
    assert "| Highlight clipping (% pixels) | 2.00 | 2.00 | 2.00 | 3 |" in open(env.tmp / "report.md").read()
    r = env.run("--refresh")
    assert sorted(r.states) == [("hit", "p2.jpg"), ("miss", "p0.jpg"), ("miss", "p1.jpg")]
    assert len(env.fake.calls) == 5
    with M.Memory.open(env.db) as mem:     # folded again by the run's compaction, counted once
        assert sum(b["n"] for b in mem.archive_buckets()) == 2
        _assert_archive_matches_ledger(mem)


# ---------------------------------------------------------------------------------------------
# Compaction and the archive
# ---------------------------------------------------------------------------------------------

def _rec(camera, dt, lwph=800.0, snr=35.0, clip=0.5, tilt=0.3, edges=5, **kw):
    return {"file": f"{camera}-{dt}.jpg", "camera_model": camera, "datetime": dt, "edges_measured": edges,
            "mtf50_p80_lwph": lwph, "snr_midgrey_db": snr, "clip_high_pct": clip, "clip_low_pct": 0.0,
            "structure_horizon_tilt_deg": tilt, **kw}


def _put(mem, n, rec, detail=None, now=None):
    sha = hashlib.sha256(f"photo {n}".encode()).digest()
    mem.put_measured(sha, rec, detail, [M.Source("file", f"/photos/{n}.jpg")], 1.0, 1.0, None, byte_size=1000 + n,
                     now=now)
    return sha


def _expected_archive(mem):
    """The archive recomputed from the ledger: every measured photo without a record, folded."""
    exp = {}
    rows = mem.conn.execute("SELECT a.* FROM asset a WHERE a.status = 'measured' AND NOT EXISTS "
                            "(SELECT 1 FROM record r WHERE r.asset_id = a.id)").fetchall()
    for r in rows:
        key = (r["camera"], M.month_of(r["captured_ts"]), r["analyzer_key"])
        n, b = exp.get(key, (0, M.Bucket()))
        b.fold({m: r[col] for m, (col, _) in M.HEADLINE_FIELDS.items()})
        exp[key] = (n + 1, b)
    return {k: (n, b.to_dict()) for k, (n, b) in exp.items()}


def _assert_archive_matches_ledger(mem):
    stored = {(b["camera"], b["month"], b["analyzer_key"]): (b["n"], b["bucket"].to_dict())
              for b in mem.archive_buckets()}
    assert stored == _expected_archive(mem)


def test_compaction_keeps_the_newest_window_per_camera(tmp_path):
    with M.Memory.open(str(tmp_path / "m.sqlite")) as mem:
        t = 1_000_000.0
        dated = ["2026:01:05 10:00:00", "2026:01:20 10:00:00", "2026:02:01 10:00:00", "2026:03:01 10:00:00",
                 "2026:03:15 10:00:00", "2026:04:01 10:00:00"]
        for k, dt in enumerate(dated):
            _put(mem, k, _rec("CamA", dt, lwph=500.0 + 50 * k), now=t + k)
        # Undated photos seen later than every dated one still leave first, the earliest seen first.
        _put(mem, 10, _rec("CamA", None), now=t + 100)
        _put(mem, 11, _rec("CamA", "0000:00:00 00:00:00"), now=t + 200)
        _put(mem, 20, _rec("CamB", "2020:01:01 00:00:00"), now=t)
        _put(mem, 21, _rec("CamB", "2020:01:02 00:00:00"), now=t)

        rep = mem.compact(window=7)
        assert rep["folded"] == 1
        assert [b["month"] for b in mem.archive_buckets("CamA")] == ["undated"]
        assert {r["file"] for r in mem.window_records("CamA")} >= {"CamA-0000:00:00 00:00:00.jpg"}

        rep = mem.compact(window=3)
        assert rep["folded"] == 4 and mem.window() == 3
        kept = [r["datetime"] for r in mem.window_records("CamA")]
        assert kept == ["2026:04:01 10:00:00", "2026:03:15 10:00:00", "2026:03:01 10:00:00"]
        assert len(mem.window_records("CamB")) == 2 and mem.archive_buckets("CamB") == []
        buckets = {b["month"]: b for b in mem.archive_buckets("CamA")}
        assert {m: b["n"] for m, b in buckets.items()} == {"2026-01": 2, "2026-02": 1, "undated": 2}
        assert sum(b["n"] for b in buckets.values()) == 5 == mem.conn.execute(
            "SELECT count(*) FROM asset a WHERE camera = 'CamA' AND NOT EXISTS "
            "(SELECT 1 FROM record r WHERE r.asset_id = a.id)").fetchone()[0]
        jan = buckets["2026-01"]
        assert jan["first_ts"] == M.exif_timestamp(dated[0]) and jan["last_ts"] == M.exif_timestamp(dated[1])
        assert jan["bucket"].metrics["sharpness_lwph"].n == 2
        _assert_archive_matches_ledger(mem)

        def snapshot():
            return [mem.conn.execute(f"SELECT * FROM {t} ORDER BY 1, 2").fetchall()
                    for t in ("asset", "source", "record", "detail", "archive")]

        before = [[tuple(r) for r in rows] for rows in snapshot()]
        rep = mem.compact()
        assert rep["folded"] == 0 and rep["details_dropped"] == 0
        assert [[tuple(r) for r in rows] for rows in snapshot()] == before


def test_detail_budget_evicts_the_oldest_capture_first_and_vacuum_frees_every_page(tmp_path):
    with M.Memory.open(str(tmp_path / "m.sqlite")) as mem:
        rng = np.random.default_rng(3)
        for k in range(12):
            blob = base64.b64encode(rng.bytes(3000)).decode()      # barely compressible
            _put(mem, k, _rec("CamA", f"2026:05:{k + 1:02d} 12:00:00"), detail={"edges": [{"blob": blob}]})
        sizes = mem.conn.execute("SELECT d.bytes FROM detail d JOIN asset a ON a.id = d.asset_id "
                                 "ORDER BY a.captured_ts DESC").fetchall()
        budget = sum(s[0] for s in sizes[:4])
        rep = mem.compact(detail_budget=budget)
        assert rep["details_dropped"] == 8 and rep["folded"] == 0
        kept = mem.conn.execute("SELECT a.captured_at FROM detail d JOIN asset a ON a.id = d.asset_id "
                                "ORDER BY a.captured_ts DESC").fetchall()
        assert [k[0] for k in kept] == [f"2026:05:{d:02d} 12:00:00" for d in (12, 11, 10, 9)]
        assert mem.conn.execute("PRAGMA freelist_count").fetchone()[0] == 0
        assert rep["bytes_after"] < rep["bytes_before"]
        assert mem.detail_budget() == budget
        assert len(mem.window_records()) == 12       # the records stay; only their detail went


def test_new_file_settings(tmp_path):
    with M.Memory.open(str(tmp_path / "a" / "b" / "m.sqlite")) as mem:
        q = lambda p: mem.conn.execute(f"PRAGMA {p}").fetchone()[0]   # noqa: E731
        assert (q("application_id"), q("user_version"), q("page_size"), q("auto_vacuum"), q("journal_mode"),
                q("foreign_keys"), q("synchronous"), q("busy_timeout"), q("journal_size_limit")) == \
               (0x49514331, 1, 4096, 2, "wal", 1, 1, 5000, 4194304)
        assert mem.window() == 500 and mem.detail_budget() == 8 * 1024 * 1024


def _lognormal(rng, n, median, sigma):
    return list(median * np.exp(rng.normal(0.0, sigma, n)))


def _exact_quantile(xs, q):
    s = sorted(xs)
    return s[max(1, math.ceil(q * len(s))) - 1]


def test_archive_quantiles_are_within_half_a_bin():
    rng = np.random.default_rng(11)
    sharp = _lognormal(rng, 4000, 800.0, 0.35)
    snr = list(rng.normal(34.0, 4.0, 4000))
    b = M.Bucket()
    for s, n in zip(sharp, snr):
        b.fold({"sharpness_lwph": s, "snr_db": n})
    half_log = math.log(1.02) / 2
    for q in (0.0, 0.05, 0.25, 0.5, 0.75, 0.95, 1.0):
        assert abs(math.log(b.quantile("sharpness_lwph", q) / _exact_quantile(sharp, q))) <= half_log + 1e-12
        assert abs(b.quantile("snr_db", q) - _exact_quantile(snr, q)) <= 0.125 + 1e-9
    assert b.metrics["sharpness_lwph"].n == 4000 and b.metrics["clip_high_pct"].n == 0
    assert b.quantile("clip_high_pct", 0.5) is None


def test_clipping_has_an_exact_zero_bin_and_exact_shares():
    rng = np.random.default_rng(5)
    clip = [0.0] * 600 + _lognormal(rng, 400, 0.8, 1.2)
    b = M.Bucket()
    for c in clip:
        b.fold({"clip_high_pct": c, "tilt_deg": c - 1.0})
    h = b.metrics["clip_high_pct"]
    assert h.zero == 600 and h.n == 1000
    assert b.quantile("clip_high_pct", 0.6) == 0.0 and b.quantile("clip_high_pct", 0.601) > 0
    for q in (0.7, 0.8, 0.9, 0.99):
        assert abs(math.log(b.quantile("clip_high_pct", q) / _exact_quantile(clip, q))) <= math.log(1.05) / 2 + 1e-12
    assert b.shares["clip_high_gt1"] == [sum(c > 1 for c in clip), 1000]
    assert b.shares["tilt_ge1"] == [sum(abs(c - 1.0) >= 1 for c in clip), 1000]
    assert b.shares["clip_low_gt1"] == [0, 0] and b.share("clip_low_gt1") is None
    # The edges of the range: below the lowest bin, the top itself, and beyond it.
    bins = M.ARCHIVE_BINS["clip_high_pct"]
    assert bins.slot(0.0005) == "under" and bins.slot(100.0) == math.floor(math.log(1e5) / math.log(1.05))
    assert bins.slot(100.5) == "over" and M.ARCHIVE_BINS["tilt_deg"].slot(-45.0) == 0
    assert M.ARCHIVE_BINS["sharpness_lwph"].slot(40.0) == "under"


def test_buckets_merge_exactly_in_any_order():
    rng = np.random.default_rng(8)
    values = [{"sharpness_lwph": float(s), "snr_db": float(n), "clip_high_pct": float(c), "clip_low_pct": 0.0,
               "tilt_deg": float(t)}
              for s, n, c, t in zip(rng.lognormal(6.7, 0.4, 300), rng.normal(33, 5, 300),
                                    rng.choice([0.0, 0.3, 2.5], 300), rng.normal(0, 2, 300))]
    parts = [M.Bucket(), M.Bucket(), M.Bucket()]
    whole = M.Bucket()
    for k, v in enumerate(values):
        parts[k % 3].fold(v)
        whole.fold(v)
    copy = lambda b: M.Bucket.from_bytes(b.to_bytes())   # noqa: E731
    ab_c = copy(parts[0]).merge(parts[1]).merge(parts[2])
    c_ba = copy(parts[2]).merge(copy(parts[1]).merge(parts[0]))
    assert ab_c.to_bytes() == c_ba.to_bytes() == whole.to_bytes()
    assert json.dumps(ab_c.to_dict()) == json.dumps(whole.to_dict())
    # Unfolding is exact too, and refuses a photo the bucket does not hold.
    assert whole.unfold(values[0]) and not M.Bucket().unfold(values[0])


def test_headline_gates_and_capture_times():
    base = {"edges_measured": 3, "mtf50_p80_lwph": 812.5, "snr_midgrey_db": 33.0, "clip_high_pct": float("nan")}
    assert M.headline(base)["sharpness_lwph"] == 812.5 and M.headline(base)["snr_db"] == 33.0
    assert M.headline({**base, "edges_measured": 2})["sharpness_lwph"] is None
    for flag in ("snr_midgrey_extrapolated", "noise_texture_suspect", "noise_periodic_suspect"):
        assert M.headline({**base, flag: True})["snr_db"] is None
    assert M.headline(base)["clip_high_pct"] is None and M.headline(base)["tilt_deg"] is None
    assert M.exif_timestamp("2026:10:13 08:48:00") == 1791881280.0      # read as UTC
    assert M.exif_timestamp("2024:02:29 23:59:59\x00") == M.exif_timestamp("2024:03:01 00:00:00") - 1
    for bad in (None, "", "0000:00:00 00:00:00", "2026:02:30 10:00:00", "2026-10-13 08:48:00", "2026:13:01 00:00:00",
                "2026:10:13 24:00:00", 1791881280):
        assert M.exif_timestamp(bad) is None
    assert M.month_of(1791881280.0) == "2026-10" and M.month_of(None) == "undated"


# ---------------------------------------------------------------------------------------------
# The file: damage, foreign files, concurrency, format
# ---------------------------------------------------------------------------------------------

@pytest.mark.parametrize("damage", ["every page", "one page"])
def test_a_damaged_file_is_moved_aside_and_a_fresh_one_started(tmp_path, damage):
    path = str(tmp_path / "memory.sqlite")
    with M.Memory.open(path) as mem:
        for k in range(40):
            _put(mem, k, _rec("CamA", f"2026:01:{k % 28 + 1:02d} 10:00:00"), detail={"edges": [{"k": k}] * 20})
    data = bytearray(open(path, "rb").read())
    if damage == "every page":      # the header survives; opening fails with SQLITE_CORRUPT
        data[4096:] = b"\xa5" * (len(data) - 4096)
    else:                           # one b-tree page: the file opens and quick_check reports it
        pages = len(data) // 4096
        data[4096 * (pages - 2):4096 * (pages - 1)] = np.random.default_rng(0).bytes(4096)
    open(path, "wb").write(bytes(data))
    with M.Memory.open(path) as mem:
        assert mem.moved_aside and os.path.basename(mem.moved_aside).startswith("memory.bad-")
        assert mem.moved_aside.endswith(".sqlite") and open(mem.moved_aside, "rb").read() == bytes(data)
        assert mem.stats()["tiers"]["ledger"]["assets"] == 0
        _put(mem, 1, _rec("CamA", "2026:01:01 10:00:00"))
    with M.Memory.open(path) as mem:
        assert mem.moved_aside is None and mem.stats()["tiers"]["ledger"]["assets"] == 1


def test_foreign_and_newer_files_are_refused_and_left_untouched(tmp_path):
    other = tmp_path / "other.sqlite"
    c = sqlite3.connect(other)
    c.execute("CREATE TABLE photos (x)")
    c.commit()
    c.close()
    text = tmp_path / "results.json"
    text.write_text("[]\n" * 50)
    newer = tmp_path / "newer.sqlite"
    with M.Memory.open(str(newer)):
        pass
    c = sqlite3.connect(newer)
    c.execute("PRAGMA user_version = 99")
    c.close()
    for p, words in ((other, "not an IQ Coach memory"), (text, "not an SQLite database"), (newer, "newer")):
        before = p.read_bytes()
        with pytest.raises(M.MemoryFileError, match=words):
            M.Memory.open(str(p))
        assert p.read_bytes() == before
        assert not [n for n in os.listdir(tmp_path) if ".bad-" in n]
    with pytest.raises(M.MemoryFileError, match="no memory"):
        M.Memory.open(str(tmp_path / "absent.sqlite"), create=False)
    assert cli.main(["analyze", str(tmp_path), "--memory", str(other), "--out", str(tmp_path / "o")]) == 3


def _writer(db, start, n, errors, ready):
    try:
        with M.Memory.open(db) as mem:
            ready.wait(60)                 # both processes start writing together
            for i in range(start, start + n):
                sha = hashlib.sha256(str(i).encode()).digest()
                mem.put_measured(sha, _rec("CamA", "2026:01:01 10:00:00", lwph=800.0 + i), None,
                                 [M.Source("file", f"/x/{i}.jpg")], 0.1, 0.1, None, byte_size=i)
                mem.touch(sha)
    except Exception as exc:          # reported to the parent, which fails the test
        errors.put(repr(exc))


def test_two_processes_writing_at_once_see_no_errors(tmp_path):
    db = str(tmp_path / "m.sqlite")
    M.Memory.open(db).close()
    ctx = multiprocessing.get_context("spawn")
    errors, ready = ctx.Queue(), ctx.Barrier(2)
    procs = [ctx.Process(target=_writer, args=(db, start, 300, errors, ready)) for start in (0, 300)]
    for p in procs:
        p.start()
    for p in procs:
        p.join(120)
    assert [p.exitcode for p in procs] == [0, 0]
    assert errors.empty(), errors.get()
    with M.Memory.open(db) as mem:
        assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 600
        assert mem.conn.execute("SELECT count(*) FROM record").fetchone()[0] == 600
        # The two writers' transactions interleaved: each one's span overlaps the other's.
        span = [mem.conn.execute("SELECT min(measured_at), max(measured_at) FROM asset WHERE byte_size "
                                 "BETWEEN ? AND ?", (lo, lo + 299)).fetchone() for lo in (0, 300)]
        assert span[0][0] < span[1][1] and span[1][0] < span[0][1]


def test_stored_json_is_raw_deflate():
    obj = {"a": float("nan"), "b": [1, 2.5], "c": np.float64(0.25), "d": np.int64(7), "e": np.array([1.0, 2.0])}
    z = M.deflate(obj)
    assert json.loads(zlib.decompress(z, -15).decode()) is not None
    with pytest.raises(zlib.error):
        zlib.decompress(z)                                  # no zlib header
    back = M.inflate(z)
    assert math.isnan(back["a"]) and back["b"] == [1, 2.5] and back["c"] == 0.25 and back["d"] == 7
    assert back["e"] == [1.0, 2.0]
    fixture = base64.b64decode(FIXTURE_B64)
    assert zlib.decompress(fixture, -15).decode() == FIXTURE_JSON
    fresh = M.deflate({"file": "IMG_0001.JPG", "camera_model": "iPhone 17 Pro Max",
                       "snr_midgrey_db": float("nan"), "mtf50_p80_lwph": 812.5})
    assert zlib.decompress(fresh, -15).decode() == FIXTURE_JSON
    print("raw-DEFLATE fixture:", base64.b64encode(fresh).decode())


# ---------------------------------------------------------------------------------------------
# Forgetting, stats, export
# ---------------------------------------------------------------------------------------------

def test_forget_by_camera_date_content_and_all(tmp_path):
    with M.Memory.open(str(tmp_path / "m.sqlite")) as mem:
        a = {dt: _put(mem, k, _rec("CamA", dt, lwph=600.0 + k)) for k, dt in enumerate(
            ["2026:01:10 10:00:00", "2026:02:10 10:00:00", "2026:03:10 10:00:00", "2026:03:20 10:00:00",
             "2026:04:10 10:00:00", None])}
        _put(mem, 50, _rec("CamB", "2025:06:01 10:00:00"))
        _put(mem, 51, _rec("CamB", "2025:07:01 10:00:00"))
        mem.compact(window=1)
        assert {b["month"]: b["n"] for b in mem.archive_buckets("CamA")} == \
               {"2026-01": 1, "2026-02": 1, "2026-03": 2, "undated": 1}

        rep = mem.forget(before="2026-03-15")
        # CamA's three photos before the date and CamB's two; CamB's newest was in its window.
        assert rep["assets"] == 5 and rep["buckets_deleted"] == 3
        assert {(b["camera"], b["month"]): b["n"] for b in mem.archive_buckets()} == \
               {("CamA", "2026-03"): 1, ("CamA", "undated"): 1}
        _assert_archive_matches_ledger(mem)

        rep = mem.forget(sha=a["2026:03:20 10:00:00"])
        assert rep == {"assets": 1, "buckets_deleted": 0, "buckets_adjusted": 1}
        assert [b["month"] for b in mem.archive_buckets("CamA")] == ["undated"]
        _assert_archive_matches_ledger(mem)

        assert mem.forget(camera="CamA")["assets"] == 2 and mem.archive_buckets() == []
        _put(mem, 60, _rec("CamC", "2026:01:01 10:00:00"))
        assert mem.forget(all=True)["assets"] == 1
        assert mem.conn.execute("SELECT count(*) FROM source").fetchone()[0] == 0
        assert mem.conn.execute("PRAGMA freelist_count").fetchone()[0] == 0
        with pytest.raises(ValueError):
            mem.forget(before="13 March")
        with pytest.raises(ValueError):
            mem.forget(camera="CamA", all=True)


def test_forgetting_a_camera_keeps_failed_and_not_capture_verdicts(env, capsys):
    # Verdicts are stored without a camera (''), so forgetting the unknown camera must not take
    # every camera's failures and not-captures with it.
    with M.Memory.open(env.db) as mem:
        gone = _put(mem, 1, _rec("", "2026:01:01 10:00:00"))
        _put(mem, 2, _rec("CamA", "2026:01:02 10:00:00"))
        bad, shot = b"\x0a" * 32, b"\x0b" * 32
        mem.put_status(bad, "failed", "RuntimeError()", byte_size=1, sources=[M.Source("photokit", "F/L0/001")])
        mem.put_status(shot, "not_capture", "no EXIF camera model", byte_size=1,
                       sources=[M.Source("photokit", "S/L0/001")])
    assert cli.main(["memory", "forget", env.db, "--camera", ""]) == 0
    assert "forgot 1 photos" in capsys.readouterr().out
    with M.Memory.open(env.db) as mem:
        assert mem.asset(gone) is None and [c["camera"] for c in mem.stats()["cameras"]] == ["CamA"]
        assert mem.asset_by_source("photokit", "F/L0/001").status == "failed"
        assert mem.asset_by_source("photokit", "S/L0/001").status == "not_capture"
        assert mem.forget(camera="")["assets"] == 0


def test_stats_counts_each_tier(tmp_path):
    with M.Memory.open(str(tmp_path / "m.sqlite")) as mem:
        for k in range(5):
            _put(mem, k, _rec("CamA", f"2026:0{k + 1}:01 10:00:00"), detail={"edges": [{"k": k}]})
        _put(mem, 9, _rec("CamB", None))
        mem.put_status(b"\x07" * 32, "not_capture", "under 5 MP", byte_size=1)
        mem.compact(window=2)
        st = mem.stats()
        assert st["tiers"]["ledger"]["assets"] == 7 and st["tiers"]["record"]["count"] == 3
        assert st["tiers"]["detail"]["count"] == 2 and st["tiers"]["archive"]["photos"] == 3
        assert st["status"] == {"measured": 6, "failed": 0, "not_capture": 1}
        assert st["oldest_capture"] == "2026-01-01 10:00:00" and st["newest_capture"] == "2026-05-01 10:00:00"
        cams = {c["camera"]: c for c in st["cameras"]}
        assert cams["CamA"]["records"] == 2 and cams["CamA"]["archived"] == 3 and cams["CamB"]["undated"] == 1
        assert st["bytes_exact"] and st["tiers"]["record"]["bytes"] > 0
        assert st["window"] == 2 and st["code_analyzer_key"] == "m1-r30-s0"


def test_memory_commands(env, capsys):
    for k in range(3):
        _photo(env.photos, f"p{k}.jpg", datetime=f"2026:0{k + 1}:01 10:00:00")
    sha = env.run().shas[0]
    assert cli.main(["memory", "key"]) == 0 and capsys.readouterr().out.strip() == "m1-r30-s0"
    assert cli.main(["memory", "compact", env.db, "--window", "2", "--detail-mb", "1"]) == 0
    assert "1 records archived" in capsys.readouterr().out
    assert cli.main(["memory", "stats", env.db, "--json"]) == 0
    st = json.loads(capsys.readouterr().out)
    assert st["window"] == 2 and st["detail_budget_bytes"] == 1048576 and st["tiers"]["archive"]["photos"] == 1
    assert cli.main(["memory", "stats", env.db]) == 0 and "CamA: 3 photos" in capsys.readouterr().out
    exported = str(env.tmp / "export" / "results.json")
    assert cli.main(["memory", "export", env.db, "--out", exported]) == 0
    recs = json.load(open(exported))
    assert len(recs) == 2 and all(len(r["sha256"]) == 64 and r["analyzer_key"] == "m1-r30-s0" for r in recs)
    assert "path" not in recs[0] and recs[0]["noise_curve"]["luma_8bit"] == [60.0, 118.0]
    capsys.readouterr()
    assert cli.main(["report", exported, "--title", "from the memory"]) == 0
    assert "## Summary" in open(env.tmp / "export" / "report.md").read()
    assert cli.main(["memory", "forget", env.db, "--sha", sha]) == 0
    assert cli.main(["memory", "forget", env.db, "--sha", "xyz"]) == 2
    assert cli.main(["memory", "forget", env.db, "--before", "2027-01-01"]) == 0
    assert "forgot 2 photos" in capsys.readouterr().out
    assert cli.main(["memory", "stats", str(env.tmp / "absent.sqlite")]) == 2


# ---------------------------------------------------------------------------------------------
# The CLI without the memory, and real end-to-end runs
# ---------------------------------------------------------------------------------------------

def test_without_memory_records_gain_the_content_id(env, capsys):
    a = _photo(env.photos, "a.jpg")
    assert cli.main(["analyze", env.photos, "--out", env.out, "--no-report"]) == 0
    rec = env.results()[0]
    assert rec["sha256"] == hashlib.sha256(open(a, "rb").read()).hexdigest() and rec["analyzer_key"] == "m1-r30-s0"
    assert "memory_tier" not in rec and not os.path.exists(os.path.join(env.out, "report.md"))
    assert sorted(os.listdir(env.out)) == ["results.csv", "results.json"]
    assert "IQA-MEMORY" not in capsys.readouterr().out
    assert cli.main(["analyze", env.photos, "--out", env.out, "--refresh"]) == 2     # needs --memory


def test_a_database_error_stops_the_run_and_marks_nothing(env, monkeypatch):
    _photo(env.photos, "a.jpg")
    _photo(env.photos, "b.jpg")

    def full_disk(*a, **k):
        raise sqlite3.OperationalError("database or disk is full")

    monkeypatch.setattr(M.Memory, "put_measured", full_disk)
    r = env.run()
    assert r.rc == 3 and "memory database error" in r.err and env.fake.calls == ["a.jpg"]
    with M.Memory.open(env.db) as mem:
        assert mem.conn.execute("SELECT count(*) FROM asset").fetchone()[0] == 0


def _synthetic_folder(folder, n=2):
    os.makedirs(folder, exist_ok=True)
    for k in range(n):
        rgb = synthetic_scene(size=400, sigma_px=1.0 + 0.5 * k, noise_8bit=2.0, seed=k)
        Image.fromarray(rgb).save(os.path.join(folder, f"scene{k}.png"))


def test_real_end_to_end_second_run_only_remembers(tmp_path, monkeypatch, capsys):
    import iqa.analyze
    photos, db = str(tmp_path / "photos"), str(tmp_path / "memory.sqlite")
    _synthetic_folder(photos)
    calls = []
    real = iqa.analyze.analyze_file
    monkeypatch.setattr(iqa.analyze, "analyze_file", lambda *a, **k: calls.append(a[0]) or real(*a, **k))
    assert cli.main(["analyze", photos, "--memory", db, "--out", str(tmp_path / "o1"), "--no-report"]) == 0
    first = capsys.readouterr().out
    assert first.count("IQA-MEMORY miss ") == 2 and len(calls) == 2
    assert cli.main(["analyze", photos, "--memory", db, "--out", str(tmp_path / "o2")]) == 0
    second = [ln for ln in capsys.readouterr().out.splitlines() if ln.startswith("IQA-MEMORY")]
    assert [ln.split()[1] for ln in second] == ["hit", "hit"] and len(calls) == 2
    fresh = json.load(open(tmp_path / "o1" / "results.json"))
    remembered = json.load(open(tmp_path / "o2" / "results.json"))
    for f, r in zip(fresh, remembered):
        assert [k for k in r if k != "memory_tier"] == list(f)
        assert json.dumps({k: r[k] for k in f}) == json.dumps(f)       # NaN-safe equality, field by field
        assert f["analysis_s"] >= 0 and f["cpu_s"] >= 0 and len(f["dhash256"]) == 64
    assert os.path.exists(tmp_path / "o2" / "report.md")
    with M.Memory.open(db) as mem:
        prov = json.loads(mem.get_meta("provenance"))
        assert {"numpy", "scipy", "cv2", "PIL", "python", "sqlite"} <= set(prov)
        assert [tuple(r) for r in mem.conn.execute("SELECT wall_s > 0, cpu_s > 0 FROM asset")] == [(1, 1), (1, 1)]


def test_an_all_hit_run_loads_no_opencv_or_scipy(env):
    _photo(env.photos, "a.jpg")
    _photo(env.photos, "b.jpg")
    env.run()
    code = ("import sys\nfrom iqa.cli import main\n"
            f"rc = main(['analyze', {env.photos!r}, '--memory', {env.db!r}, '--out', {env.out!r}, '--no-report'])\n"
            "print('LOADED', sorted(m for m in ('cv2', 'scipy', 'matplotlib') if m in sys.modules))\n"
            "raise SystemExit(rc)\n")
    p = subprocess.run([sys.executable, "-c", code], cwd=REPO, capture_output=True, text=True, timeout=120)
    assert p.returncode == 0, p.stderr
    states = [ln.split()[1] for ln in p.stdout.splitlines() if ln.startswith("IQA-MEMORY")]
    assert states == ["hit", "hit"]
    assert "LOADED []" in p.stdout
    p = subprocess.run([sys.executable, "-c", "import sys, iqa.memory\nprint(sorted(m for m in "
                        "('numpy', 'PIL', 'cv2', 'scipy') if m in sys.modules))"],
                       cwd=REPO, capture_output=True, text=True, timeout=60)
    assert p.stdout.strip() == "[]"


# ---------------------------------------------------------------------------------------------
# dHash256
# ---------------------------------------------------------------------------------------------

def _smooth_scene(seed, size=480):
    """An independent random picture: a 12 x 12 random colour field, smoothly enlarged."""
    rng = np.random.default_rng(seed)
    small = Image.fromarray(rng.integers(0, 256, (12, 12, 3), dtype=np.uint8))
    return np.asarray(small.resize((size, size), Image.Resampling.BICUBIC))


def _jpeg(rgb, quality):
    import io
    buf = io.BytesIO()
    Image.fromarray(rgb).save(buf, "JPEG", quality=quality)
    return np.asarray(Image.open(io.BytesIO(buf.getvalue())).convert("RGB"))


def test_dhash_ground_truth():
    scenes = [_smooth_scene(s) for s in range(6)] + [synthetic_scene(size=480, sigma_px=1.2, noise_8bit=3.0)]
    for rgb in scenes:
        h = dhash256(rgb)
        assert len(h) == 64 and int(h, 16) >= 0
        half = np.asarray(Image.fromarray(rgb).resize((240, 240), Image.Resampling.LANCZOS))
        assert hamming(h, dhash256(half)) <= 16
        assert hamming(h, dhash256(_jpeg(rgb, 70))) <= 16
        assert hamming(h, dhash256(np.ascontiguousarray(np.rot90(rgb)))) >= 64
    hashes = [dhash256(s) for s in scenes[:6]]
    assert min(hamming(a, b) for i, a in enumerate(hashes) for b in hashes[i + 1:]) >= 64
    # A flat field has no darker-left neighbours: every bit is 0 (documented in iqa/fingerprint.py).
    assert dhash256(np.full((300, 400, 3), 128, dtype=np.uint8)) == "0" * 64
    # The bit order: a left-to-right ramp sets every bit, a right-to-left one none.
    ramp = np.tile(np.linspace(0, 255, 512).astype(np.uint8)[None, :, None], (256, 1, 3))
    assert dhash256(ramp) == "f" * 64 and dhash256(np.ascontiguousarray(ramp[:, ::-1])) == "0" * 64


def test_analysis_records_timing_and_fingerprint(tmp_path):
    from iqa.analyze import analyze_file
    p = tmp_path / "scene.png"
    rgb = synthetic_scene(size=400, sigma_px=1.2, noise_8bit=2.0)
    Image.fromarray(rgb).save(p)
    rec = analyze_file(str(p))
    assert isinstance(rec["analysis_s"], float) and isinstance(rec["cpu_s"], float)
    assert 0 <= rec["analysis_s"] < 60 and 0 <= rec["cpu_s"] < 600
    assert rec["dhash256"] == dhash256(rgb)
    assert M.analyzer_key() == f"m{iqa.MEASUREMENT_VERSION}-r30-s0" and M.analyzer_key(20, 2000) == "m1-r20-s2000"
