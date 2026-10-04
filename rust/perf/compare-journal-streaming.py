#!/usr/bin/env python3
"""Compare schema-v1 buffered Controller with schema-v2 journal Controller.

The retained text workload and timed harness must match. Snapshot seeds and write
bytes intentionally need not: schema-v2 adds random stream generation metadata.
The unchanged store mode remains a non-journal full-checkpoint control.
"""
import json
from pathlib import Path
import sys

before, after = (Path(arg) for arg in sys.argv[1:3])


def read(path):
    return json.loads(path.read_text())


def hashes(directory):
    return {path: digest for digest, path in
            (line.split(None, 1) for line in (directory/"source-pre-run.sha256").read_text().splitlines())}


def check_workload(left, right):
    for key in ("chunks", "offered_hz", "chunk_bytes", "offered_duration_seconds"):
        assert left[key] == right[key], key
    for key in ("rows", "characters_per_message", "retained_ascii_characters", "retained_utf8_bytes"):
        assert left["fixture"][key] == right["fixture"][key], key
    if left["measurement"]["mode"] == "controller":
        assert left["measurement"]["reopen_validated"] and right["measurement"]["reopen_validated"]


a, b = hashes(before), hashes(after)
harness = "rust/crates/bello-agent-core/examples/session_streaming_bench.rs"
assert a[harness] == b[harness], "The timed harness differs"
changed = {path: {"before": a.get(path), "after": b.get(path)} for path in a.keys() | b.keys() if a.get(path) != b.get(path)}
result = {
    "before": str(before), "after": str(after), "changed_source_hashes": changed,
    "harness_sha256": a[harness],
    "scope": "Sequential local synthetic runs, shared host; Controller exercises journal; store is full-checkpoint control",
    "schema_difference": {"before_checkpoint_version": 1, "after_checkpoint_version": 2,
                          "journal_record_version": 1, "new_checkpoint_fields": ["stream_generation", "stream_sequence"],
                          "seed_hash_equality_required": False,
                          "reason": "Session::new now adds a random generation UUID; retained text generation and dimensions are unchanged"},
    "primary": {}, "stress": {},
}
left_summary, right_summary = read(before/"summary.json"), read(after/"summary.json")
for filesystem in ("overlay", "tmpfs"):
    for mode in ("store", "controller"):
        case = f"{filesystem}-{mode}"
        left, right = left_summary[case], right_summary[case]
        assert len(left["runs"]) == len(right["runs"])
        for index in range(1, len(left["runs"])+1):
            check_workload(read(before/f"{case}-{index}.json"), read(after/f"{case}-{index}.json"))
        result["primary"][case] = {
            "interpretation": "journal through Controller" if mode == "controller" else "non-journal full-checkpoint control",
            "before_latency_ms": left["latency_ms"], "after_latency_ms": right["latency_ms"],
            "ratio_before_over_after": {q:left["latency_ms"][q]/right["latency_ms"][q] for q in ("p50", "p95", "p99")},
            "before_runs": left["runs"], "after_runs": right["runs"],
        }
for mode in ("store", "controller"):
    left, right = read(before/f"stress-overlay-{mode}.json"), read(after/f"stress-overlay-{mode}.json")
    check_workload(left, right)
    result["stress"][mode] = {
        "interpretation": "journal through Controller" if mode == "controller" else "non-journal full-checkpoint control",
        "before": {k:v for k,v in left["measurement"].items() if k not in ("samples", "fixture")},
        "after": {k:v for k,v in right["measurement"].items() if k not in ("samples", "fixture")},
    }
print(json.dumps(result, indent=2, sort_keys=True))
