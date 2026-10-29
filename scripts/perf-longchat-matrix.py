#!/usr/bin/env python3
"""Run the PERF-1 Release matrix; each trial gets its own quiet-window lock.

Build first. --resume skips only a completed, load-valid trial with exit zero.
The journal variants are cold (no sidecar) and warm (real helper checkpoint).
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["helper", "open", "scroll", "rate", "find", "profile", "all"], default="all")
    parser.add_argument("--sizes", nargs="+", default=["10k", "50k", "200k", "50k-exchanges"])
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    root = Path(os.environ["PI_BUILD_ROOT"]).resolve()
    scripts = Path(__file__).resolve().parent
    runner = [sys.executable, str(scripts / "perf-longchat-run.py")]
    manifests = list((root / "release/Build/Products").glob("*.xctestrun"))
    if args.suite != "helper":
        assert len(manifests) == 1, "Build the isolated Release test host first"
    app = ["xcodebuild", "test-without-building", "-xctestrun", str(manifests[0]) if manifests else "",
           "-derivedDataPath", str(root / "release"), "-destination", "platform=macOS,arch=arm64",
           "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
           "-only-testing:PiAppTests/LongChatPerformanceTests/testMeasureLongChat"]
    failures = []
    def run(label, command, fixture=None, knobs=None, profile=False):
        if args.resume:
            for path in (root / "perf").glob(label + "-*.json"):
                old = json.loads(path.read_text())
                if old.get("label") == label and old.get("validLoad") and old.get("exit") == 0:
                    print("Already complete:", label, flush=True); return
        env = {k: v for k, v in os.environ.items() if not k.startswith("TEST_RUNNER_PI_PERF_")}
        env.update({"TEST_RUNNER_PI_PERF_" + k: str(v) for k, v in (knobs or {}).items()})
        invocation = runner + ["--label", label, "--start-load", "2.0"]
        if fixture:
            invocation += ["--fixture", str(fixture)]
        if profile:
            invocation += ["--profile"]
        print("Starting:", label, flush=True)
        code = subprocess.call(invocation + ["--"] + command, env=env)
        if code:
            failures.append([label, code]); print("Trial failed:", label, code, flush=True)

    for size in args.sizes:
        fixture = root / "fixtures" / size
        cold, warm = fixture / "chat.jsonl", fixture / "warm/chat.jsonl"
        assert cold.is_file()
        if args.suite in ["helper", "all"]:
            helper = [sys.executable, str(scripts / "perf-longchat-helper.py"), str(fixture)]
            run("prepare-" + size, helper + ["--prepare"])
            run("helper-cold-" + size, helper + ["--cold"])
            run("helper-warm-" + size, helper)
        if args.suite in ["open", "scroll", "rate", "find", "profile", "all"]:
            assert Path(str(warm) + ".meta").is_file(), "Run --suite helper to prepare native checkpoints"
        if args.suite in ["open", "all"]:
            for source in ["journal", "helper"]:
                for variant, path in [("cold", cold), ("warm", warm)]:
                    run(f"open-{source}-{variant}-{size}", app, path, {"SOURCE": source, "OPEN_ONLY": 1})
                run(f"switch-{source}-{size}", app, warm, {"SOURCE": source, "OPEN_ONLY": 1, "SWITCH_FIRST": 1, "HELPER_HOT": int(source == "helper")})
        if args.suite in ["scroll", "all"]:
            for source in ["journal", "helper"]:
                # The short-dwell/continuous stress run is separate. Three
                # seconds between momentum tails lets the real helper finish
                # a page while still recording the empty/stalled frames.
                knobs = {"SOURCE": source, "WHEEL_POINTS": 480, "WHEEL_SECONDS": 300, "DWELL_FRAMES": 180}
                suffix = ""
                if source == "helper" and size in ["200k", "50k-exchanges"]:
                    # Baseline opening trials retain the production 30-second
                    # deadline. This explicit diagnostic permits page coverage
                    # after the already-recorded acknowledgement failures.
                    knobs["ACK_SECONDS"] = 180
                    suffix = "-ack180"
                if size == "50k" and source == "journal":
                    knobs["STREAM"] = 1
                run(f"scroll-paced480-{source}-{size}{suffix}", app, warm, knobs)
        if args.suite == "rate":
            # A slower wheel control with the same quiet frames as the main
            # matrix, isolated from Find/resize. Report actual coverage even
            # when the 180-second limit precedes twelve windows.
            for source in ["journal", "helper"]:
                run(f"wheel-paced120-{source}-{size}", app, warm,
                    {"SOURCE": source, "WHEEL_ONLY": 1, "WHEEL_POINTS": 120,
                     "WHEEL_SECONDS": 180, "DWELL_FRAMES": 180})
        if args.suite in ["find", "all"]:
            # The normal scroll trial observes Find for 60 seconds and records
            # an unfinished scan honestly. This separate trial waits for the
            # whole-chat result set before stepping back across its boundary.
            run(f"find-complete-{size}", app, warm,
                {"SOURCE": "journal", "FIND_ONLY": 1, "FIND_SECONDS": 3600})
        if args.suite in ["profile", "all"] and size in ["50k", "200k"]:
            run(f"profile-open-journal-{size}", app, cold, {"SOURCE": "journal", "OPEN_ONLY": 1}, profile=True)
            run(f"profile-helper-{size}", [sys.executable, str(scripts / "perf-longchat-helper.py"), str(fixture), "--cold"], profile=True)
    print("Matrix failures:", json.dumps(failures), flush=True)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
