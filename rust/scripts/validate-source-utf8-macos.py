#!/usr/bin/env python3
"""Freeze a release decoder/oracle pair, then run the identical pair on each Mac.

build-bundle requires the selected Xcode toolchain and Cargo. run-bundle requires
neither and never rebuilds. Both modes use synthetic data and no GUI or authority.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys

RUST = Path(__file__).resolve().parents[1]
ROOT = RUST.parent
CORE = RUST / "crates/bello-agent-core"
FILES = {"rust-probe", "swift-oracle", "bridge.a", "bridge-Swift.h", "build.json", "oracle.swift"}
PROBE = "tools::read::macos::source_utf8::tests::"


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def run(arguments, *, timeout=120, data=None, cwd=RUST):
    child = subprocess.Popen(arguments, cwd=cwd, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
    try:
        out, err = child.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise RuntimeError(f"timed out: {arguments}") from None
    if len(out) + len(err) > 64 * 1024 * 1024:
        raise RuntimeError("command output exceeds evidence bound")
    if child.returncode:
        raise RuntimeError(f"failed ({child.returncode}): {arguments}\n{err.decode(errors='replace')}\n{out.decode(errors='replace')}")
    return out.decode(), err.decode()


def command(*arguments):
    return run(list(arguments))[0].strip()


def host():
    return {"os": command("/usr/bin/sw_vers"), "architecture": platform.machine()}


def source_snapshot():
    paths = command("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                    "Cargo.toml", "Cargo.lock", "crates/bello-agent-core",
                    "../packages/swift-host/Sources/PiAgentCore",
                    "scripts/validate-source-utf8-macos.py").split("\0")
    return {str((RUST / name).resolve().relative_to(ROOT)): digest(RUST / name)
            for name in paths if name and (RUST / name).is_file()}


def audit(binary):
    dependencies = command("/usr/bin/otool", "-L", str(binary))
    for line in dependencies.splitlines()[1:]:
        name = line.strip().split(" (", 1)[0]
        if not name.startswith(("/usr/lib/", "/System/Library/")):
            raise RuntimeError(f"non-system runtime dependency in {binary}: {name}")
    load_commands = command("/usr/bin/otool", "-l", str(binary))
    minimum = re.findall(r"\bminos\s+(\S+)", load_commands)
    if minimum != ["14.0"]:
        raise RuntimeError(f"expected macOS14.0 binary: {binary}, got {minimum}")
    for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", load_commands):
        if rpath != "/usr/lib/swift":
            raise RuntimeError(f"unexpected runtime search path: {rpath}")
    architecture = command("/usr/bin/lipo", "-archs", str(binary))
    if architecture != "arm64":
        raise RuntimeError(f"unsupported binary architecture: {architecture}")
    return {"dependencies": dependencies, "load_commands": load_commands,
            "architecture": architecture}


def build_bundle(args):
    if os.environ.get("MACOSX_DEPLOYMENT_TARGET") != "14.0":
        raise RuntimeError("set MACOSX_DEPLOYMENT_TARGET=14.0 for Rust and Swift")
    bundle = args.bundle.resolve()
    bundle.mkdir(parents=True, exist_ok=False)
    sources = source_snapshot()
    cargo = ["cargo", "test", "--locked", "--release", "-p", "bello-agent-core",
             "--lib", "--no-run", "--message-format=json"]
    if args.offline:
        cargo.append("--offline")
    output, diagnostics = run(cargo, timeout=1800)
    events = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    artifacts = [event for event in events if event.get("reason") == "compiler-artifact"
                 and event["target"]["name"] == "bello_agent_core" and event.get("executable")]
    if len(artifacts) != 1:
        raise RuntimeError("expected exactly one compiled core test executable")
    manifests = [Path(event["out_dir"]) / "source-utf8-build.json" for event in events
                 if event.get("reason") == "build-script-executed"]
    manifests = [path for path in manifests if path.is_file()]
    if len(manifests) != 1:
        raise RuntimeError("expected exactly one source UTF-8 build identity")
    build = json.loads(manifests[0].read_text())
    shutil.copy2(artifacts[0]["executable"], bundle / "rust-probe")
    for source, name in [(build["archive"], "bridge.a"), (build["header"], "bridge-Swift.h"),
                         (manifests[0], "build.json")]:
        shutil.copy2(source, bundle / name)
    source_path = ROOT / "packages/swift-host/Sources/PiAgentCore/Tools.swift"
    source = source_path.read_text()
    expression = "String(data:data,encoding:.utf8)"
    if source.count("guard let text=" + expression) != 1:
        raise RuntimeError("original Swift Read decoding expression moved; review the oracle")
    template = CORE / "tests/fixtures/utf8_decode_oracle.swift"
    driver = template.read_text()
    if driver.count("/* SOURCE_DECODE */") != 1:
        raise RuntimeError("oracle decoder marker must occur exactly once")
    (bundle / "oracle.swift").write_text(driver.replace("/* SOURCE_DECODE */", expression))
    compiler_args = [build["compiler"], "-swift-version", "5", "-O", "-target", build["target"],
                     "-sdk", build["sdk"], "-module-cache-path", str(manifests[0].parent / "oracle-cache"),
                     str(bundle / "oracle.swift"), "-o", str(bundle / "swift-oracle")]
    run(compiler_args)
    if source_snapshot() != sources:
        raise RuntimeError("source changed during bundle build; rebuild from a stable checkout")
    manifest = {"schema": 1, "build_host": host(), "commit": command("git", "rev-parse", "HEAD"),
                "tree": command("git", "rev-parse", "HEAD^{tree}"),
                "worktree_status": command("git", "status", "--short"),
                "cargo_command": cargo, "cargo_diagnostics": diagnostics,
                "rustc": command("rustc", "-vV"), "oracle_command": compiler_args,
                "sources": sources,
                "files": {name: digest(bundle / name) for name in sorted(FILES)},
                "linkage": {name: audit(bundle / name) for name in ["rust-probe", "swift-oracle"]}}
    (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"bundle": str(bundle), "manifest_sha256": digest(bundle / "manifest.json")}))


def run_bundle(args):
    bundle = args.bundle.resolve()
    manifest_path = bundle / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema") != 1 or set(manifest.get("files", {})) != FILES:
        raise RuntimeError("unsupported or incomplete bundle manifest")
    for name, expected in manifest["files"].items():
        if digest(bundle / name) != expected:
            raise RuntimeError(f"bundle hash mismatch: {name}")
    output, diagnostics = run([str(bundle / "rust-probe"), PROBE, "--nocapture", "--test-threads=1"],
                              cwd=bundle)
    receipts = re.findall(r"BELLO_UTF8_RECEIPT:(\[.*\])", output)
    if len(receipts) != 1:
        raise RuntimeError("expected one compiled decoder receipt")
    actual = json.loads(receipts[0])
    inputs = [{"case": row["case"], "input": row["input"]} for row in actual]
    oracle, oracle_errors = run([str(bundle / "swift-oracle")], cwd=bundle,
                                data=json.dumps(inputs).encode())
    expected = json.loads(oracle)
    result = {"schema": 1, "host": host(), "manifest_sha256": digest(manifest_path),
              "files": manifest["files"], "passed": actual == expected,
              "actual": actual, "expected": expected, "probe_stdout": output,
              "probe_stderr": diagnostics, "oracle_stderr": oracle_errors}
    args.receipt.write_text(json.dumps(result, indent=2) + "\n")
    if actual != expected:
        raise RuntimeError(f"source decoder mismatch; see {args.receipt}")
    print(json.dumps({"passed": True, "cases": len(actual), "receipt": str(args.receipt),
                      "receipt_sha256": digest(args.receipt),
                      "manifest_sha256": result["manifest_sha256"]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    build = modes.add_parser("build-bundle")
    build.add_argument("bundle", type=Path)
    build.add_argument("--offline", action="store_true")
    check = modes.add_parser("run-bundle")
    check.add_argument("bundle", type=Path)
    check.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("this native bundle requires an Apple Silicon macOS host")
    if args.mode == "build-bundle":
        build_bundle(args)
    else:
        run_bundle(args)


if __name__ == "__main__":
    main()
