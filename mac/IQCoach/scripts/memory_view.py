"""What iqa/memory.py reads from a memory file, as JSON for the Swift test realMemoryDecodesEveryRecord.

usage: .venv/bin/python mac/IQCoach/scripts/memory_view.py MEMORY.sqlite OUT.json

then: TEST_RUNNER_IQA_MEMORY=MEMORY.sqlite TEST_RUNNER_IQA_MEMORY_EXPECT=OUT.json xcodebuild ... test
(mac/IQCoach/README.md). The test then checks that the app's window and archive quantiles are the analyzer's.
"""
import json
import sys

from iqa import memory as M

QS = [0.1, 0.25, 0.5, 0.75, 0.9]
db, out = sys.argv[1], sys.argv[2]
with M.Memory.open(db, create=False) as mem:
    key = mem.get_meta("current_analyzer_key")
    window = [r["sha256"] for r in mem.window_records()]
    merged = {}
    for b in mem.archive_buckets():
        if b["analyzer_key"] != key:
            continue
        cam = b["camera"] or "Unknown camera"          # PhotoRecord.unknownCamera
        e = merged.setdefault(cam, {"photos": 0, "buckets": 0, "bucket": M.Bucket()})
        e["photos"] += b["n"]
        e["buckets"] += 1
        e["bucket"].merge(b["bucket"])
view = {"window": window, "archive": {
    cam: {"photos": e["photos"], "buckets": e["buckets"],
          "quantiles": {m: {str(q): e["bucket"].quantile(m, q) for q in QS} for m in M.ARCHIVE_BINS},
          "shares": {s: list(e["bucket"].shares[s]) for s in M.ARCHIVE_SHARES}}
    for cam, e in merged.items()}}
with open(out, "w") as fh:
    json.dump(view, fh, indent=1)
print(json.dumps({"window": len(window), "archive": {c: v["photos"] for c, v in view["archive"].items()}}))
