#!/usr/bin/env python3
"""Run finite subprocesses, preserve raw samples, and aggregate without polling."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
repeats = int(os.environ.get("BENCH_REPEATS", "3"))
chunks = int(os.environ.get("BENCH_CHUNKS", "500"))
if not 1 <= repeats <= 10 or not 1 <= chunks <= 99999:
    raise SystemExit("Invalid repeat/chunk count")


def distribution(values):
    values = sorted(values)
    return {"n": len(values), "min": values[0], "p50": values[math.ceil(.5*len(values))-1],
            "p95": values[math.ceil(.95*len(values))-1], "p99": values[math.ceil(.99*len(values))-1],
            "max": values[-1], "mean": sum(values)/len(values), "method": "nearest rank"}


index = []
# CPU/system-call primary counters are collected in-process without tracing.
for filesystem, root in (("overlay", output), ("tmpfs", Path("/tmp"))):
    for mode in ("store", "controller"):
        for repeat in range(1, repeats+1):
            name = f"{filesystem}-{mode}-{repeat}"
            with tempfile.TemporaryDirectory(prefix="bello-stream-fixture-", dir=root) as directory:
                command = [str(binary), mode, directory, "100", "1000", str(chunks), "100"]
                begun = time.time()
                result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=30+chunks/100*6)
                (output/f"{name}.json").write_bytes(result.stdout)
                (output/f"{name}.stderr").write_bytes(result.stderr)
                record = {"artifact": f"{name}.json", "command": command, "returncode": result.returncode,
                          "wall_seconds_including_startup": time.time()-begun, "filesystem": filesystem}
                index.append(record)
                (output/"runs.json").write_text(json.dumps(index, indent=2)+"\n")
                if result.returncode:
                    raise SystemExit(f"Failed {name}: {result.stderr.decode()}")
                print(name, f"completed in {record['wall_seconds_including_startup']:.3f}s", flush=True)

summary = {}
for filesystem in ("overlay", "tmpfs"):
    for mode in ("store", "controller"):
        measurements = [json.loads((output/record["artifact"]).read_text())["measurement"]
                        for record in index if record["filesystem"] == filesystem and f"-{mode}-" in record["artifact"]]
        key = "transaction_ms" if mode == "store" else "send_start_to_first_observation_ms"
        summary[f"{filesystem}-{mode}"] = {
            "latency_ms": distribution([sample[key] for result in measurements for sample in result["samples"]]),
            "runs": [{key: value for key, value in result.items() if key not in ("samples", "fixture")}
                     for result in measurements],
        }
(output/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")

# Separate instrumentation sample: syscall counts only; traced timings are not
# mixed into the primary latency samples. Three finite transactions keep it small.
if os.environ.get("BENCH_STRACE", "1") == "1":
    with tempfile.TemporaryDirectory(prefix="bello-stream-trace-", dir=output) as directory:
        command = ["strace", "-f", "-c", "-e", "trace=write,writev,fsync,fdatasync,rename,renameat,renameat2,openat,close",
                   "-o", str(output/"strace-store-3.txt"), str(binary), "store", directory, "100", "1000", "3", "100"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        (output/"strace-store-3.json").write_bytes(result.stdout)
        (output/"strace-store-3.stderr").write_bytes(result.stderr)
        (output/"strace-command.json").write_text(json.dumps({"command": command, "returncode": result.returncode}, indent=2)+"\n")
        print("Separate syscall trace return code:", result.returncode, flush=True)
