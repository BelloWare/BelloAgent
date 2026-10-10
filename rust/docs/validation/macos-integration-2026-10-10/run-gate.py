#!/usr/bin/env python3
"""Run the requested gate without shared-worktree artifact collisions."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

record = Path(__file__).resolve().parent
rust = record.parents[2]
expected_target = "/Users/admin/Library/Caches/BelloRustWork/claude-2026-10-10/target"
if os.environ.get("CARGO_TARGET_DIR") != expected_target:
    raise SystemExit("Source the supplied env.sh first; refusing an unexpected target directory")
for key in ("CARGO_PROFILE_DEV_DEBUG", "CARGO_PROFILE_TEST_DEBUG", "CARGO_INCREMENTAL"):
    if os.environ.get(key) != "0":
        raise SystemExit(f"Set {key}=0 before running the gate")
toolchain = Path(shutil.which("cargo")).resolve().parent
# cargo-clippy overrides RUSTC_WORKSPACE_WRAPPER with its sibling driver. Use
# an APFS clone of that identical launcher with a worktree-specific driver path.
# This isolates only workspace artifact hashes, preserving shared dependencies.
tools = record / ".tools"
tools.mkdir(exist_ok=True)
subprocess.run(["cp", "-c", str(toolchain / "cargo-clippy"), str(tools / "cargo-clippy")], check=True)
driver = tools / "clippy-driver"
driver.write_text("#!/bin/sh\nexec " + shlex.quote(str(toolchain / "clippy-driver")) + ' "$@"\n')
driver.chmod(0o755)
env = dict(os.environ)
env["PATH"] = str(tools) + os.pathsep + env["PATH"]
env["DYLD_LIBRARY_PATH"] = str(toolchain.parent / "lib")
env["RUSTC_WORKSPACE_WRAPPER"] = str(record / "rustc-workspace-wrapper.sh")
env["PI_APP_TESTING"] = "1"
env["BELLO_APP_TESTING"] = "1"
commands = [
    ("fmt", ["cargo", "fmt", "--all", "--", "--check"]),
    ("clippy-app-default", ["cargo", "clippy", "--locked", "-p", "bello-agent-app", "--all-targets", "--", "-D", "warnings"]),
    ("clippy-app-synthetic", ["cargo", "clippy", "--locked", "-p", "bello-agent-app", "--all-targets", "--features", "synthetic-authority", "--", "-D", "warnings"]),
    ("clippy-app-native", ["cargo", "clippy", "--locked", "-p", "bello-agent-app", "--all-targets", "--features", "native-authority", "--", "-D", "warnings"]),
    ("clippy-app-both", ["cargo", "clippy", "--locked", "-p", "bello-agent-app", "--all-targets", "--features", "native-authority,synthetic-authority", "--", "-D", "warnings"]),
    ("clippy-workspace", ["cargo", "clippy", "--locked", "--workspace", "--all-targets", "--", "-D", "warnings"]),
    ("test-app-synthetic", ["cargo", "test", "--locked", "-p", "bello-agent-app", "--features", "synthetic-authority"]),
    ("test-app-native", ["cargo", "test", "--locked", "-p", "bello-agent-app", "--features", "native-authority"]),
    ("test-core-read-observation", ["cargo", "test", "--locked", "-p", "bello-agent-core", "--lib", "read_observation::tests"]),
]
results = []
try:
    for name, command in commands:
        print("START " + name, flush=True)
        start = time.monotonic()
        log = record / (name + ".log")
        with log.open("w") as output:
            process = subprocess.run(command, cwd=rust, env=env, stdout=output, stderr=subprocess.STDOUT)
        lines = log.read_text().splitlines()
        summaries = [line for line in lines if line.startswith("test result:")]
        result = dict(check=name, command=command, exit_code=process.returncode,
                      seconds=round(time.monotonic() - start, 2), summaries=summaries)
        results.append(result)
        (record / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print("END " + name + " " + str(process.returncode) + " " + "; ".join(summaries), flush=True)
        if process.returncode:
            print("\n".join(lines[-35:]), flush=True)
finally:
    # These are temporary tools created by this runner, never committed binaries.
    (tools / "cargo-clippy").unlink(missing_ok=True)
    driver.unlink(missing_ok=True)
    tools.rmdir()
raise SystemExit(any(result["exit_code"] for result in results))
