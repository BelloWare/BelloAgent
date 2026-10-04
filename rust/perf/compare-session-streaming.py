#!/usr/bin/env python3
"""Check fixture equivalence and emit explicit before/after local measurements."""
import json
from pathlib import Path
import sys

before, after = (Path(arg) for arg in sys.argv[1:3])


def read(path):
    return json.loads(path.read_text())


def hashes(directory):
    return {path: digest for digest, path in
            (line.split(None, 1) for line in (directory / "source-pre-run.sha256").read_text().splitlines())}


a, b = hashes(before), hashes(after)
harness = "rust/crates/bello-agent-core/examples/session_streaming_bench.rs"
assert a[harness] == b[harness], "The timed harness differs"
changed = {path: {"before": digest, "after": b.get(path)} for path, digest in a.items() if b.get(path) != digest}
result = {"before": str(before), "after": str(after), "changed_source_hashes": changed,
          "harness_sha256": a[harness], "scope": "Sequential synthetic local runs; not an exclusive-host controlled trial",
          "primary": {}, "stress": {}}
for filesystem in ("overlay", "tmpfs"):
    for mode in ("store", "controller"):
        case = f"{filesystem}-{mode}"
        left = read(before/"summary.json")[case]
        right = read(after/"summary.json")[case]
        for index in range(1, len(left["runs"])+1):
            x, y = read(before/f"{case}-{index}.json"), read(after/f"{case}-{index}.json")
            for key in ("fixture", "chunks", "offered_hz", "chunk_bytes", "offered_duration_seconds"):
                assert x[key] == y[key], (case, index, key)
            if mode == "store":
                assert x["measurement"]["logical_snapshot_bytes_written"] == y["measurement"]["logical_snapshot_bytes_written"]
            else:
                assert x["measurement"]["reopen_validated"] and y["measurement"]["reopen_validated"]
        result["primary"][case] = {"before_latency_ms": left["latency_ms"], "after_latency_ms": right["latency_ms"],
                                  "ratio_before_over_after": {q: left["latency_ms"][q]/right["latency_ms"][q] for q in ("p50", "p95", "p99")},
                                  "before_runs": left["runs"], "after_runs": right["runs"]}
for mode in ("store", "controller"):
    x, y = read(before/f"stress-overlay-{mode}.json"), read(after/f"stress-overlay-{mode}.json")
    for key in ("fixture", "chunks", "offered_hz", "chunk_bytes", "offered_duration_seconds"):
        assert x[key] == y[key], (mode, key)
    result["stress"][mode] = {"before": {k:v for k,v in x["measurement"].items() if k not in ("samples", "fixture")},
                              "after": {k:v for k,v in y["measurement"].items() if k not in ("samples", "fixture")}}
print(json.dumps(result, indent=2))
