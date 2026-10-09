#!/usr/bin/env python3
"""Audit the resolved official SQLite dependency source and entire feature union.
Run from the repository or rust directory; Cargo configuration remains mandatory.
This checks build provenance, not platform privacy acceptance.
"""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
revision = "91f876c80114122670f455190d03c81d1f78b0af"
source = f"git+https://github.com/rusqlite/rusqlite?rev={revision}#{revision}"
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--manifest-path", str(root / "Cargo.toml"),
    "--locked", "--offline", "--format-version", "1", *sys.argv[1:]
], text=True))
expected = {
    "rusqlite": ("0.40.1", {"bundled", "hooks", "limits", "modern_sqlite"}),
    "libsqlite3-sys": ("0.38.1", {"bundled", "bundled_bindings", "cc", "default",
                                  "min_sqlite_version_3_45_3", "pkg-config", "vcpkg"}),
}
nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
for name, (version, features) in expected.items():
    packages = [p for p in metadata["packages"] if p["name"] == name]
    assert len(packages) == 1, f"unexpected {name} package multiplicity"
    package = packages[0]
    assert package["version"] == version and package["source"] == source, f"unexpected {name} source"
    assert set(nodes[package["id"]]["features"]) == features, f"unexpected {name} feature union"
    print(f"{name} {version}: exact upstream revision and reviewed feature union")
