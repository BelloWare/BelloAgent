#!/usr/bin/env python3
"""Summarize a bounded probe window without mistaking retained tails for full runs."""
import argparse
import json
import math
import statistics
from pathlib import Path


def timing_window(before, after):
    result = {}
    for name, samples in after["samples"].items():
        count = after["totalSamples"][name] - before.get("totalSamples", {}).get(name, 0)
        if count < 0:
            raise ValueError("Probe restarted; use a matching baseline")
        if not count:
            continue
        values = sorted(samples[-min(count, len(samples)):])
        if not values:
            raise ValueError("Probe reports observations without retained samples")
        result[name] = {"count": count, "retained": len(values),
                        "coverage": "full" if len(values) == count else "retained-tail",
                        **{f"p{int(q * 100)}": values[math.ceil(len(values) * q) - 1]
                           for q in (.50, .95, .99)}, "max": values[-1]}
    return result


def memory_window(samples, phase):
    start, end = phase["streamStartWall"], phase["streamEndWall"]
    if end <= start:
        raise ValueError("Invalid active window")
    values = [s["rssBytes"] / 1_048_576 for s in samples if start <= s["wallTime"] <= end]
    if not values:
        raise ValueError("No aggregate memory samples in the active window")
    return {"samples": len(values), "durationSeconds": end - start,
            "meanMiB": statistics.mean(values), "peakMiB": max(values), "lastMiB": values[-1]}


def main():
    parser = argparse.ArgumentParser()
    for argument in ("before", "after", "processes", "phase", "output"):
        parser.add_argument("--" + argument, type=Path, required=True)
    args = parser.parse_args()
    read = lambda path: json.loads(path.read_text())
    before, after = read(args.before), read(args.after)
    if before["pid"] != after["pid"]:
        raise ValueError("Different native processes")
    result = {"version": after["version"], "build": after["build"], "method": after["method"],
              "timingMilliseconds": timing_window(before, after),
              "calibration": {k: v for k, v in after["metrics"].items() if "Calibration" in k},
              "aggregateMemory": memory_window(read(args.processes)["samples"], read(args.phase))}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
