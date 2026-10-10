#!/usr/bin/env python3
"""Summarize belloperf launch trials: per app and warm/cold, nearest-rank percentiles."""
import glob
import json
import math
import os
import sys

run = sys.argv[1]
rows = {}
failures = {}
for path in sorted(glob.glob(os.path.join(run, "raw", "*-*-*.json"))):
    name = os.path.basename(path)
    if "-probe-" in name or "-prime-" in name:
        continue
    label, kind = name.rsplit("-", 2)[0], name.rsplit("-", 2)[1]
    report = json.load(open(path))
    for trial in report["trials"]:
        if not trial.get("measured"):
            continue
        key = (label, kind)
        if "error" in trial:
            failures.setdefault(key, []).append(trial["error"])
            continue
        rows.setdefault(key, []).append(trial)


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, max(0, math.ceil(len(s) * q) - 1))]


metrics = [("windowMs", "window ms", 0), ("settledMs", "settled ms", 0),
           ("idleCpuPercent", "idle CPU %", 2), ("footprintMB", "footprint MB", 1),
           ("residentMB", "RSS MB", 1), ("lifetimeMaxFootprintMB", "peak footprint MB", 1)]
summary = {}
order = ["swift-agent", "rust-agent", "swift-box", "rust-box", "rust-box-sandboxed"]
lines = ["| app | launch | n | " + " | ".join(m[1] + " p50 [min–max]" for m in metrics) + " |",
         "|---|---|---|" + "---|" * len(metrics)]
for kind in ["warm", "cold"]:
    for label in order:
        trials = rows.get((label, kind), [])
        if not trials:
            continue
        cells = []
        entry = {"n": len(trials), "failures": failures.get((label, kind), [])}
        for key, title, digits in metrics:
            values = [t[key] for t in trials if isinstance(t.get(key), (int, float))]
            if not values:
                cells.append("–")
                continue
            entry[key] = {"p50": pct(values, 0.5), "min": min(values), "max": max(values),
                          "p90": pct(values, 0.9), "mean": sum(values) / len(values), "samples": values}
            fmt = f"{{:.{digits}f}}"
            cells.append(f"{fmt.format(pct(values, 0.5))} [{fmt.format(min(values))}–{fmt.format(max(values))}]")
        summary[f"{label}/{kind}"] = entry
        lines.append(f"| {label} | {kind} | {len(trials)} | " + " | ".join(cells) + " |")
table = "\n".join(lines)
print(table)
if failures:
    print("\nFailures:", json.dumps({f"{k[0]}/{k[1]}": v for k, v in failures.items()}, indent=1))
json.dump(summary, open(os.path.join(run, "summary.json"), "w"), indent=1, sort_keys=True)
open(os.path.join(run, "summary.md"), "w").write(table + "\n")
