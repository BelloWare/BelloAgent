"""Reuse a completed npm ci while its inputs and installed packages still match."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


CI_ARGUMENTS = ("npm", "ci", "--no-audit", "--no-fund")
STAMP_NAME = ".pi-build-dependencies.json"


def _input_fingerprint(root):
    # Ask the pinned npm for effective project/user/global/environment settings.
    # Store only their digest; npm configuration can contain credentials.
    configuration = json.loads(subprocess.check_output(
        [str(root / "scripts/with-runtime.sh"), "npm", "config", "list", "--json"],
        cwd=root, text=True, stderr=subprocess.PIPE))
    inputs = {
        "version": 1,
        "command": CI_ARGUMENTS,
        "configuration": configuration,
        "platform": [platform.system(), platform.machine()],
        "environment": {key: os.environ.get(key) for key in
                        ("NODE_ENV", "NODE_OPTIONS", "ESBUILD_BINARY_PATH")},
    }
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode())
    for name in ("package.json", "package-lock.json", "scripts/runtime-lock.json",
                 "scripts/with-runtime.sh", ".npmrc"):
        path = root / name
        content = path.read_bytes() if path.exists() else None
        if content is None and name != ".npmrc":
            raise FileNotFoundError(path)
        digest.update(json.dumps([name, content.hex() if content is not None else None]).encode())
    return digest.hexdigest()


def _installed_fingerprint(root):
    """Check package presence/versions and bins, without hashing all source files."""
    try:
        lock_bytes = (root / "node_modules/.package-lock.json").read_bytes()
        packages = json.loads(lock_bytes)["packages"]
        manifest = json.loads((root / "package.json").read_bytes())
        required = set(manifest.get("dependencies", {})) | set(manifest.get("devDependencies", {}))
        if not {"node_modules/" + name for name in required}.issubset(packages):
            return None
        digest = hashlib.sha256(lock_bytes)
        for relative, package in sorted(packages.items()):
            if not relative.startswith("node_modules/") or ".." in Path(relative).parts:
                return None
            directory = root / relative
            package_bytes = (directory / "package.json").read_bytes()
            if json.loads(package_bytes).get("version") != package["version"]:
                return None
            digest.update(relative.encode())
            digest.update(str(directory.resolve()).encode())
            digest.update(package_bytes)
            for binary in package.get("bin", {}).values():
                executable = directory / binary
                if not executable.is_file() or not os.access(executable, os.X_OK):
                    return None
                digest.update(str(executable.resolve()).encode())
        esbuild = root / "node_modules/.bin/esbuild"
        if not esbuild.is_file() or not os.access(esbuild, os.X_OK):
            return None
        digest.update(str(esbuild.resolve()).encode())
        return digest.hexdigest()
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def ensure_dependencies(root):
    """Run lockfile-driven npm ci on a miss; return whether an install was needed."""
    root = Path(root).resolve()
    stamp = root / "node_modules" / STAMP_NAME
    fingerprint = _input_fingerprint(root)
    try:
        previous = json.loads(stamp.read_bytes())
    except (OSError, ValueError):
        previous = None
    if isinstance(previous, dict) and previous.get("inputs") == fingerprint:
        installed = _installed_fingerprint(root)
        if installed is not None and previous.get("installed") == installed:
            print("Reusing cached npm dependencies")
            return False

    # Invalidate before npm touches the tree, including when a reinstall fails.
    stamp.unlink(missing_ok=True)
    subprocess.run([str(root / "scripts/with-runtime.sh"), *CI_ARGUMENTS], cwd=root, check=True)
    installed = _installed_fingerprint(root)
    if installed is None:
        raise RuntimeError("npm ci completed without the dependencies needed to build transcript assets")
    stamp.write_text(json.dumps({"inputs": fingerprint, "installed": installed}) + "\n")
    return True
