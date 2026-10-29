#!/usr/bin/env python3
"""Focused phase-B comparisons on the phase-A fixtures, using the real timeout.

Build Release first. A stage names its binaries, e.g. b1-base or b2-first-paint.
The bounded wheel subset is not the final phase-B ten-page/full-matrix gate.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage")
    parser.add_argument("--suite", choices=["open", "scroll"], required=True)
    parser.add_argument("--sizes", nargs="+", default=["50k", "50k-exchanges"])
    parser.add_argument("--sources", nargs="+", choices=["journal", "helper"], default=["journal", "helper"])
    parser.add_argument("--rates", nargs="+", type=int, default=[120, 480])
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--start-load", type=float, default=2.5, help="Start headroom; the runner still rejects any peak over 4")
    parser.add_argument("--products", type=Path, help="Preserved Release products under PI_BUILD_ROOT")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(os.environ["PI_BUILD_ROOT"]).resolve()
    products = (args.products or root / "release/Build/Products").resolve()
    assert root in products.parents, "Use only products inside PI_BUILD_ROOT"
    manifests = list(products.glob("*.xctestrun"))
    assert len(manifests) == 1, "Build the isolated Release host first"
    scripts = Path(__file__).resolve().parent
    app = ["xcodebuild", "test-without-building", "-xctestrun", str(manifests[0]),
           "-derivedDataPath", str(root / "release"), "-destination", "platform=macOS,arch=arm64",
           "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
           "-only-testing:PiAppTests/LongChatPerformanceTests/testMeasureLongChat"]
    failures = []
    for size in args.sizes:
        for source in args.sources:
            for rate in args.rates if args.suite == "scroll" else [0]:
                label = f"{args.stage}-{args.suite}-{source}-{size}" + (f"-{rate}" if rate else "")
                if args.resume and any((data := json.loads(path.read_text())).get("label") == label and
                        data.get("validLoad") and data.get("exit") == 0 for path in (root / "perf").glob(label + "-*.json")):
                    print("Already complete:", label, flush=True)
                    continue
                fixture = root / "fixtures" / size / "warm/chat.jsonl"
                assert fixture.is_file() and Path(str(fixture) + ".meta").is_file()
                knobs = dict(SOURCE=source, SWITCH_FIRST=1)
                if rate:
                    knobs.update(WHEEL_ONLY=1, WHEEL_POINTS=rate, WHEEL_SECONDS=args.seconds, DWELL_FRAMES=180)
                else:
                    knobs["OPEN_ONLY"] = 1
                env = {key: value for key, value in os.environ.items() if not key.startswith("TEST_RUNNER_PI_PERF_")}
                env.update({"TEST_RUNNER_PI_PERF_" + key: str(value) for key, value in knobs.items()})
                command = [sys.executable, str(scripts / "perf-longchat-run.py"), "--label", label,
                           "--start-load", str(args.start_load), "--attempts", "5", "--fixture", str(fixture), "--"] + app
                print(json.dumps(dict(label=label, knobs=knobs, command=command)), flush=True)
                if not args.dry_run:
                    status = subprocess.call(command, env=env)
                    if status: failures.append([label, status])
    print("Round failures:", json.dumps(failures), flush=True)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
