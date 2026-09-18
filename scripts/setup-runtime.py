#!/usr/bin/env python3
"""Download the locked runtime from nodejs.org; never substitute PATH's Node."""
import hashlib
import json
import os
import pathlib
import subprocess
import tarfile

root = pathlib.Path(__file__).resolve().parent
lock = json.loads((root / "runtime-lock.json").read_text())
scratch = pathlib.Path(os.environ["PI_BUILD_ROOT"]) / "runtime"
scratch.mkdir(parents=True, exist_ok=True)
archive = scratch / lock["archive"]
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != lock["sha256"]:
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                    "--proto", "=https", "--max-time", "180", "--output", str(archive), lock["url"]], check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != lock["sha256"]:
    raise SystemExit("Pinned Node archive SHA-256 mismatch")
with tarfile.open(archive) as package:
    package.extractall(scratch, filter="data")
node = scratch / f"node-v{lock['node']}-{lock['platform']}" / "bin/node"
actual = subprocess.check_output([str(node), "--version"], text=True).strip()
if actual != "v" + lock["node"]:
    raise SystemExit("Extracted Node version does not match the lock")
print(f"Verified {actual}: {node}")
