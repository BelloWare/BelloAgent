#!/usr/bin/env python3
"""Manual, synthetic GPUI CPU-work benchmark (Python 3.11+, stdlib only).

Build the ignored app test with Cargo, validate its complete workload, and retain
only allowlisted synthetic measurements and source/profile fingerprints. This is
NoopTextSystem wall time, not a native frame or typing-latency measurement.
Historical 0beb423 copied-source results require an explicit reviewed adapter;
this runner neither executes their commands nor promises direct reproduction.
"""
import argparse
import copy
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import tomllib

SCHEMA = 1
MARKER = "BENCHMARK_JSON "
TEST_NAME = "transcript_benchmark::manual_transcript_benchmark"
KINDS = ("short", "multiline_unicode_reasoning")
REVEAL_MODES = ("default_100", "all_revealed")
TOTALS = (100, 1000, 10000)
ROUTES = ("root_entity_notify_auto_draw", "window_refresh_explicit_draw")
LABEL = "synthetic GPUI CPU-work wall time"
TEXT_SYSTEM = "NoopTextSystem"
PAYLOAD_VERSION = "transcript-v1"
CONSTRUCTION_SCOPE = "parent conversation composition only; child not rendered"
CHILD_SCOPE = "explicit cache bypass; no layout/prepaint/paint; 7 warmups + 31 measured"
CLONE_EXCLUDES = ("formatted IDs/selectors/labels, GPUI internal cloning/allocation, "
                  "queue/composer/footer allocations, deferred geometry callback clone")
METRICS = ("construction", "destruction_and_arena_clear", "construction_plus_destruction",
           "direct_child_render_construction", "direct_child_render_destruction",
           "direct_child_render_combined")
METHOD_FILES = ("rust/benches/transcript.rs", "rust/scripts/transcript_benchmark.py")
PROFILE_KEYS = {"opt_level", "debuginfo", "debug_assertions", "overflow_checks", "test"}
CAVEATS = [
    "Synthetic GPUI CPU-work elapsed wall time with NoopTextSystem; not native frame latency.",
    "Repeated payloads favor warm caches; shared-host scheduling and run order can affect results.",
    "Parent composition and direct-child construction are separate scopes, not whole-transcript construction.",
    "Generic mode omits child probes; it does not disable caching or recreate historical code.",
    "Historical 0beb423 direct-rustc evidence needs a reviewed adapter and verified matching profiles.",
]


class ValidationError(ValueError):
    """Input does not prove a complete, comparable benchmark run."""


class CaptureError(RuntimeError):
    """A command failed its private output or time bound."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def keys(value, expected, context):
    require(isinstance(value, dict) and set(value) == set(expected),
            f"invalid {context} fields")


def integer(value, minimum=0, maximum=2**64 - 1):
    return type(value) is int and minimum <= value <= maximum


def number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def reject_constant(_):
    raise ValidationError("nonfinite JSON number")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def read_json(text):
    try:
        return json.loads(text, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (json.JSONDecodeError, OverflowError, RecursionError) as error:
        raise ValidationError("malformed JSON") from error


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def file_digest(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def validate_profile(profile):
    keys(profile, PROFILE_KEYS, "build profile")
    require(profile["opt_level"] == "0", "unsupported optimized profile")
    for name in ("debug_assertions", "overflow_checks", "test"):
        require(profile[name] is True, f"unsupported profile {name}")
    debug = profile["debuginfo"]
    require(debug is None or (type(debug) is int and debug in (0, 1, 2))
            or (type(debug) is str and debug in
                ("none", "limited", "full", "line-directives-only", "line-tables-only")),
            "unsupported profile debuginfo")
    return copy.deepcopy(profile)


def validate_totals(totals):
    require(isinstance(totals, list) and totals and all(integer(n) and n in TOTALS for n in totals)
            and totals == sorted(set(totals)), "totals must be an ascending unique subset of 100,1000,10000")
    return totals


def make_metadata(totals, mode, profile):
    validate_totals(totals)
    require(mode in ("cached", "generic"), "unsupported measurement mode")
    result = {
        "record_type": "metadata", "schema_version": SCHEMA, "totals": totals,
        "measurement_mode": mode, "expected_cases": len(totals) * 4,
        "build_profile": validate_profile(profile), "cfg_debug_assertions": True,
        "measurement_label": LABEL, "text_system": TEXT_SYSTEM,
        "payload_version": PAYLOAD_VERSION, "window": [1280, 840], "pane_width": 979.0,
        "draw_warmup": 3, "draw_samples": 21, "draw_budget_seconds": 45,
    }
    if mode == "cached":
        result.update(construction_warmup=7, construction_samples=31)
    return result


def validate_metadata(metadata):
    require(isinstance(metadata, dict), "invalid metadata")
    try:
        expected = make_metadata(metadata["totals"], metadata["measurement_mode"],
                                 metadata["build_profile"])
    except KeyError as error:
        raise ValidationError("missing metadata") from error
    # JSON equality alone considers true and 1 equal; the canonical comparison
    # keeps boolean labels and integer declarations distinct.
    require(canonical(metadata) == canonical(expected), "metadata or profile label mismatch")
    return expected


def timing_summary(raw):
    ordered = sorted(raw)
    return {"samples": len(raw), "median_us": statistics.median(raw) / 1000,
            "p95_us": ordered[math.ceil(.95 * len(raw)) - 1] / 1000,
            "min_us": ordered[0] / 1000, "max_us": ordered[-1] / 1000,
            "raw_ns": list(raw)}


def validate_timings(value, sample_limit, full=False):
    keys(value, ("samples", "median_us", "p95_us", "min_us", "max_us", "raw_ns"), "timing")
    raw = value["raw_ns"]
    require(isinstance(raw, list) and 1 <= len(raw) <= sample_limit
            and all(integer(n) for n in raw), "invalid raw timings")
    require(integer(value["samples"], 1) and value["samples"] == len(raw), "sample count mismatch")
    require(not full or len(raw) == sample_limit, "partial construction series")
    expected = timing_summary(raw)
    for name in ("median_us", "p95_us", "min_us", "max_us"):
        require(number(value[name]) and math.isclose(value[name], expected[name], rel_tol=1e-12,
                                                    abs_tol=1e-9), "timing summary mismatch")
    return expected


def payload_bytes(kind, revealed):
    # Both declared totals and the default reveal count are even; these values
    # include the alternating assistant reasoning, measured as UTF-8 bytes.
    return revealed * (59 if kind == "short" else 810)


def validate_case(case, metadata):
    common = {"record_type", "schema_version", "kind", "total", "mode", "revealed", "hidden",
              "measurement_mode", "build_profile", "window", "pane_width", "exact_rows_before",
              "exact_rows_after", "unchanged_history_and_draft", "persistent_snapshot_bytes_unchanged",
              "visible_payload_utf8_bytes", "draw_routes"}
    cached = metadata["measurement_mode"] == "cached"
    if cached:
        common.update(METRICS)
        common.update(("construction_warmup", "construction_scope", "parent_composition_child_renders",
                       "direct_child_render_scope", "source_accounting"))
    keys(case, common, "case")
    require(case["record_type"] == "case" and type(case["schema_version"]) is int
            and case["schema_version"] == SCHEMA, "invalid case record")
    require(case["kind"] in KINDS and case["mode"] in REVEAL_MODES, "invalid workload label")
    total = case["total"]
    require(integer(total) and total in metadata["totals"], "undeclared total")
    revealed = min(total, 100) if case["mode"] == "default_100" else total
    for name, expected in (("revealed", revealed), ("hidden", total - revealed),
                           ("exact_rows_before", revealed), ("exact_rows_after", revealed),
                           ("visible_payload_utf8_bytes", payload_bytes(case["kind"], revealed))):
        require(integer(case[name]) and case[name] == expected, f"invalid {name}")
    for name in ("measurement_mode", "build_profile", "window", "pane_width"):
        # Rust serializes the actual f32 pane width as 979.0.
        if name == "pane_width":
            require(number(case[name]) and case[name] == 979, "window/pane mismatch")
        else:
            require(canonical(case[name]) == canonical(metadata[name]), f"case {name} mismatch")
    for name in ("unchanged_history_and_draft", "persistent_snapshot_bytes_unchanged"):
        require(case[name] is True, "fixture verification failed")
    result = copy.deepcopy(case)
    if cached:
        require(type(case["construction_warmup"]) is int and case["construction_warmup"] == 7
                and case["construction_scope"] == CONSTRUCTION_SCOPE
                and case["direct_child_render_scope"] == CHILD_SCOPE, "construction label mismatch")
        require(type(case["parent_composition_child_renders"]) is int
                and case["parent_composition_child_renders"] == 0, "parent composition rendered child")
        expected_accounting = {
            "message_payload_string_clone_bytes_per_parent_composition": 0,
            "message_payload_string_clone_bytes_per_child_render": payload_bytes(case["kind"], revealed),
            "is_heap_allocation_measurement": False, "excludes": CLONE_EXCLUDES,
        }
        require(canonical(case["source_accounting"]) == canonical(expected_accounting),
                "invalid source accounting")
        for name in METRICS:
            result[name] = validate_timings(case[name], 31, full=True)
        for build, destroy, combined in (METRICS[:3], METRICS[3:]):
            require(all(a + b == c for a, b, c in zip(result[build]["raw_ns"],
                    result[destroy]["raw_ns"], result[combined]["raw_ns"])), "combined timing mismatch")
    routes = case["draw_routes"]
    require(isinstance(routes, list) and len(routes) == 2, "incomplete draw routes")
    seen = set()
    for route in result["draw_routes"]:
        expected_keys = {"route", "warmup", "budget_seconds", "budget_exhausted",
                         "wall_seconds_including_warmup", "timings"}
        if cached:
            expected_keys.update(("child_render_counts_per_measured_sample", "child_render_counts_per_warmup"))
        keys(route, expected_keys, "draw route")
        name = route["route"]
        require(name in ROUTES and name not in seen, "duplicate or invalid draw route")
        seen.add(name)
        require(type(route["warmup"]) is int and route["warmup"] == 3
                and type(route["budget_seconds"]) is int and route["budget_seconds"] == 45,
                "draw sampling label mismatch")
        require(type(route["budget_exhausted"]) is bool, "invalid budget flag")
        route["timings"] = validate_timings(route["timings"], 21)
        n = route["timings"]["samples"]
        wall = route["wall_seconds_including_warmup"]
        require(number(wall) and wall + 1e-9 >= sum(route["timings"]["raw_ns"]) / 1e9,
                "invalid route wall time")
        require((route["budget_exhausted"] and wall >= 45)
                or (not route["budget_exhausted"] and n == 21), "partial or false budget-exhausted series")
        if cached:
            for field, length in (("child_render_counts_per_measured_sample", n),
                                  ("child_render_counts_per_warmup", 3)):
                counts = route[field]
                require(isinstance(counts, list) and len(counts) == length
                        and all(integer(value) for value in counts), "invalid child render counts")
                if name == ROUTES[1]:
                    require(all(value >= 1 for value in counts), "forced refresh falsely claims cache hit")
    result["draw_routes"].sort(key=lambda route: ROUTES.index(route["route"]))
    return result


def validate_records(records, expected_metadata=None):
    require(isinstance(records, list) and len(records) >= 3, "partial benchmark output")
    metadata = validate_metadata(records[0])
    if expected_metadata is not None:
        require(canonical(metadata) == canonical(expected_metadata), "run configuration/profile mismatch")
    complete = records[-1]
    keys(complete, ("record_type", "schema_version", "cases"), "completion")
    require(complete["record_type"] == "complete" and type(complete["schema_version"]) is int
            and complete["schema_version"] == SCHEMA and type(complete["cases"]) is int
            and complete["cases"] == metadata["expected_cases"], "missing or invalid completion")
    expected = {(kind, total, mode) for kind in KINDS for total in metadata["totals"] for mode in REVEAL_MODES}
    cases, seen = [], set()
    for value in records[1:-1]:
        case = validate_case(value, metadata)
        key = (case["kind"], case["total"], case["mode"])
        require(key not in seen, "duplicate workload case")
        seen.add(key)
        cases.append(case)
    require(seen == expected and len(cases) == metadata["expected_cases"], "incomplete workload matrix")
    cases.sort(key=lambda case: (KINDS.index(case["kind"]), case["total"], REVEAL_MODES.index(case["mode"])))
    return [metadata, *cases, copy.deepcopy(complete)]


def parse_output(stdout, returncode, expected_metadata):
    require(type(returncode) is int and returncode == 0, "benchmark process failed")
    records = [read_json(line.split(MARKER, 1)[1]) for line in stdout.splitlines() if MARKER in line]
    require(len(re.findall(r"^test result: ok\. 1 passed; 0 failed; 0 ignored;", stdout, re.MULTILINE)) == 1,
            "ignored app test did not finish successfully")
    return validate_records(records, expected_metadata)


def cargo_artifact(stdout, rust_root):
    artifacts, finished = [], []
    for line in stdout.splitlines():
        if not line.startswith("{"):
            continue
        item = read_json(line)
        if item.get("reason") == "build-finished":
            finished.append(item.get("success"))
        if item.get("reason") != "compiler-artifact":
            continue
        target = item.get("target", {})
        if target.get("name") == "bello-agent" and target.get("kind") == ["bin"] and item.get("executable"):
            require(Path(target.get("src_path", "")).resolve()
                    == (rust_root / "crates/bello-agent-app/src/main.rs").resolve(), "wrong Cargo app artifact")
            require(item.get("features") == ["default"], "unsupported app test features")
            profile = validate_profile(item.get("profile"))
            artifacts.append((Path(item["executable"]).resolve(), profile))
    require(finished == [True] and len(artifacts) == 1, "Cargo did not produce exactly one app test artifact")
    executable, profile = artifacts[0]
    require(executable.is_file(), "compiled app test is missing")
    return executable, profile


def cargo_fingerprint(executable):
    """Validate Cargo's matching test fingerprint, including opaque full profile.

    This is Cargo's internal evidence, not a stable public schema: fail closed
    when its location/fields change rather than invent profile equivalence.
    """
    match = re.fullmatch(r"bello_agent-([a-f0-9]{16})(?:\.exe)?", executable.name)
    require(match is not None and executable.parent.name == "deps", "unsupported Cargo executable layout")
    path = (executable.parent.parent / ".fingerprint" /
            f"bello-agent-app-{match.group(1)}" / "test-bin-bello-agent.json")
    require(path.is_file(), "matching Cargo test fingerprint unavailable")
    value = read_json(path.read_text())
    require(isinstance(value, dict) and value.get("rustflags") == [], "unsupported compiler rustflags")
    require(read_json(value.get("features", "null")) == ["default"], "unsupported fingerprint features")
    result = {key: value.get(key) for key in ("profile", "rustc", "target", "compile_kind")}
    require(all(integer(value) for value in result.values()) and result["compile_kind"] == 0,
            "unsupported Cargo fingerprint/target")
    result.update(rustflags=[], features=["default"])
    return result


def capture(command, cwd, env=None, timeout=3600, limit=32 * 1024 * 1024):
    """Private bounded pipes, no raw build/test logs written into evidence."""
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=(os.name == "posix"))
    chunks = [bytearray(), bytearray()]
    overflow = threading.Event()

    def reader(stream, index):
        try:
            while chunk := stream.read(65536):
                remaining = limit - len(chunks[index])
                chunks[index].extend(chunk[:remaining])
                if len(chunk) > remaining:
                    overflow.set()
                    break
        finally:
            stream.close()

    readers = [threading.Thread(target=reader, args=(stream, index), daemon=True)
               for index, stream in enumerate((process.stdout, process.stderr))]
    for thread in readers:
        thread.start()
    deadline = time.monotonic() + timeout
    try:
        while process.poll() is None:
            if overflow.is_set() or time.monotonic() >= deadline:
                raise CaptureError("command output/time limit exceeded")
            time.sleep(.05)
        for thread in readers:
            thread.join(timeout=2)
        if overflow.is_set() or any(thread.is_alive() for thread in readers):
            raise CaptureError("command output limit or unfinished pipe")
        return process.returncode, bytes(chunks[0]).decode("utf-8", "replace")
    finally:
        if process.poll() is None or any(thread.is_alive() for thread in readers):
            if os.name == "posix":
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            elif process.poll() is None:
                process.kill()
        process.wait()
        for thread in readers:
            thread.join(timeout=2)


def checked(command, cwd, env=None, timeout=60):
    status, stdout = capture(command, cwd, env=env, timeout=timeout)
    require(status == 0, "command failed")
    return stdout


def validate_build_environment(rust_root, env):
    # Cargo artifact.profile does not describe arbitrary -C options or wrappers.
    # Reject these rather than label a custom build as the supported profile.
    blocked = {"RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC", "RUSTC_WRAPPER",
               "RUSTC_WORKSPACE_WRAPPER", "RUSTDOCFLAGS", "CARGO_ENCODED_RUSTDOCFLAGS",
               "CARGO_BUILD_RUSTFLAGS", "CARGO_BUILD_RUSTC", "CARGO_BUILD_RUSTC_WRAPPER",
               "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER", "CARGO_BUILD_TARGET", "CARGO_INCREMENTAL"}
    for key, value in env.items():
        require(not value or not (key in blocked or key.startswith("CARGO_PROFILE_")
                or (key.startswith("CARGO_TARGET_") and key.endswith(("_RUSTFLAGS", "_LINKER", "_RUNNER")))),
                "unsupported compiler override in environment")
    cargo_home = Path(env.get("CARGO_HOME", str(Path.home() / ".cargo"))).expanduser().resolve()
    directories = [rust_root.resolve(), *rust_root.resolve().parents]
    files = {cargo_home / name for name in ("config", "config.toml")}
    files.update(directory / ".cargo" / name for directory in directories for name in ("config", "config.toml"))
    for path in sorted(files):
        if not path.is_file():
            continue
        data = tomllib.loads(path.read_text())
        require(not any(key in data for key in ("env", "profile", "target", "unstable", "include")),
                "unsupported Cargo configuration override")
        build = data.get("build", {})
        require(isinstance(build, dict) and not (set(build) - {"jobs", "target-dir"}),
                "unsupported Cargo build override")
        # Only inspect compiler-related overrides. Registry configuration may
        # contain credentials; never save its values, paths or content hashes.
    return True


def compiler_identity(rust_root, env):
    text = checked(["rustc", "-vV"], rust_root, env)
    fields = {}
    for line in text.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            if key in ("release", "commit-hash", "commit-date", "host", "LLVM version"):
                require(re.fullmatch(r"[A-Za-z0-9.+_-]{1,100}", value) is not None,
                        "unsupported compiler identity")
                fields[key] = value
    require(set(fields) == {"release", "commit-hash", "commit-date", "host", "LLVM version"},
            "incomplete compiler identity")
    cargo = checked(["cargo", "--version"], rust_root, env).strip()
    require(re.fullmatch(r"cargo [0-9][A-Za-z0-9.+_-]* \([a-f0-9]+ [0-9-]+\)", cargo) is not None,
            "unsupported Cargo identity")
    fields["cargo"] = cargo
    return fields


def source_state(repo, rust_root, env):
    commit = checked(["git", "rev-parse", "HEAD"], repo, env).strip()
    require(re.fullmatch(r"[a-f0-9]{40,64}", commit) is not None, "invalid source commit")
    # Hash source, manifests, lockfile, benchmark tooling and compile-time assets.
    # No source bytes, private paths, git diffs or environment values are saved.
    names = checked(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
                     "--", "rust", "assets"], repo, env).split("\0")
    selected = sorted(name for name in names if name and (
        name in ("rust/Cargo.lock", "rust/Cargo.toml")
        or name.startswith(("rust/crates/", "rust/benches/", "rust/scripts/", "assets/"))))
    hashes = {}
    for name in selected:
        path = repo / name
        require(path.is_file() and not path.is_symlink(), "unsupported missing/symlinked source")
        hashes[name] = file_digest(path)
    require("rust/Cargo.lock" in hashes and "rust/benches/transcript.rs" in hashes,
            "benchmark checkout is incomplete (historical revisions need an adapter)")
    manifest = tomllib.loads((rust_root / "Cargo.toml").read_text())
    profiles = manifest.get("profile", {})
    return {"commit": commit, "source_sha256": hashes, "source_tree_sha256": digest(hashes),
            "manifest_profiles_sha256": digest(profiles)}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def validate_provenance(value, metadata):
    expected = {"source", "compiler", "compiler_overrides_checked", "build_profile", "test_binary_sha256",
                "profile_identity_sha256", "cargo_fingerprint", "platform", "build_command", "test_command"}
    keys(value, expected, "provenance")
    require(canonical(value["build_profile"]) == canonical(metadata["build_profile"]), "provenance profile mismatch")
    source = value["source"]
    keys(source, ("commit", "source_sha256", "source_tree_sha256", "manifest_profiles_sha256"), "source provenance")
    require(isinstance(source["commit"], str) and re.fullmatch(r"[a-f0-9]{40,64}", source["commit"]), "invalid commit")
    require(isinstance(source["source_sha256"], dict) and source["source_sha256"], "missing source hashes")
    for name, sha in source["source_sha256"].items():
        require(isinstance(name, str) and re.fullmatch(r"(?:rust|assets)/[A-Za-z0-9_./-]+", name)
                and ".." not in Path(name).parts and isinstance(sha, str)
                and re.fullmatch(r"[a-f0-9]{64}", sha), "invalid source hash")
    require(all(name in source["source_sha256"] for name in METHOD_FILES), "missing workload/method source hashes")
    require(source["source_tree_sha256"] == digest(source["source_sha256"]), "source manifest hash mismatch")
    for sha in (source["manifest_profiles_sha256"], value["test_binary_sha256"], value["profile_identity_sha256"]):
        require(isinstance(sha, str) and re.fullmatch(r"[a-f0-9]{64}", sha), "invalid fingerprint")
    require(value["compiler_overrides_checked"] is True, "compiler override checks missing")
    keys(value["compiler"], ("release", "commit-hash", "commit-date", "host", "LLVM version", "cargo"), "compiler")
    for key, field in value["compiler"].items():
        pattern = r"cargo [0-9][A-Za-z0-9.+_-]* \([a-f0-9]+ [0-9-]+\)" if key == "cargo" else r"[A-Za-z0-9.+_-]{1,100}"
        require(isinstance(field, str) and re.fullmatch(pattern, field), "invalid compiler identity")
    keys(value["platform"], ("system", "machine"), "platform")
    require(value["platform"]["system"] in ("Linux", "Darwin", "Windows")
            and isinstance(value["platform"]["machine"], str)
            and re.fullmatch(r"[A-Za-z0-9_-]{1,32}", value["platform"]["machine"]), "invalid platform")
    require(value["build_command"] == build_command()
            and value["test_command"] == ["<cargo-built-app-test>", *test_arguments()], "command metadata mismatch")
    fingerprint = value["cargo_fingerprint"]
    keys(fingerprint, ("profile", "rustc", "target", "compile_kind", "rustflags", "features"), "Cargo fingerprint")
    require(all(integer(fingerprint[key]) for key in ("profile", "rustc", "target", "compile_kind"))
            and fingerprint["compile_kind"] == 0 and fingerprint["rustflags"] == []
            and fingerprint["features"] == ["default"], "unsupported Cargo fingerprint")
    expected_identity = digest({"profile": value["build_profile"], "compiler": value["compiler"],
                                "cargo_fingerprint": fingerprint,
                                "manifest_profiles_sha256": source["manifest_profiles_sha256"],
                                "platform": value["platform"]})
    require(value["profile_identity_sha256"] == expected_identity, "profile fingerprint mismatch")
    return value


def build_command():
    return ["cargo", "test", "--locked", "--jobs", "4", "-p", "bello-agent-app", "--bin", "bello-agent",
            "--no-run", "--message-format=json"]


def test_arguments():
    return [TEST_NAME, "--exact", "--ignored", "--nocapture", "--test-threads=1"]


def make_report(records, provenance):
    records = validate_records(records)
    validate_provenance(provenance, records[0])
    caveats = list(CAVEATS)
    if any(route["timings"]["samples"] < 20 for case in records[1:-1] for route in case["draw_routes"]):
        caveats.append("Sparse-series nearest-rank p95 is the observed maximum, not a characterized tail latency.")
    return {"schema_version": SCHEMA, "status": "complete", "records": records,
            "provenance": provenance, "caveats": caveats}


def validate_report(report):
    keys(report, ("schema_version", "status", "records", "provenance", "caveats"), "report")
    require(type(report["schema_version"]) is int and report["schema_version"] == SCHEMA
            and report["status"] == "complete", "partial/legacy benchmark report needs an adapter")
    expected = make_report(report["records"], report["provenance"])
    require(report["caveats"] == expected["caveats"], "missing or invalid measurement caveats")
    return expected


def summary_rows(records):
    for case in records[1:-1]:
        common = {key: case[key] for key in ("kind", "total", "mode", "measurement_mode", "revealed", "hidden")}
        metrics = [(name, case[name], False, None) for name in METRICS if name in case]
        metrics += [(route["route"], route["timings"], route["budget_exhausted"], route)
                    for route in case["draw_routes"]]
        for name, timings, exhausted, route in metrics:
            counts = route.get("child_render_counts_per_measured_sample") if route else None
            yield dict(common, metric=name, samples=timings["samples"], median_ms=timings["median_us"] / 1000,
                       p95_ms=timings["p95_us"] / 1000, budget_exhausted=exhausted,
                       child_renders_measured=sum(counts) if counts is not None else "",
                       cache_hit_samples=sum(value == 0 for value in counts) if counts is not None else "")


def write_csv(path, rows):
    rows = list(rows)
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def compare_reports(baseline, candidate):
    baseline, candidate = validate_report(baseline), validate_report(candidate)
    left, right = baseline["records"][0], candidate["records"][0]
    # Require the same mode: cached construction probes change pre-draw warmup
    # and generic does not disable caching. Compare only the full-draw scopes.
    require(left["measurement_mode"] == right["measurement_mode"],
            "comparison modes differ; rerun both in generic or both in cached mode")
    common_fields = set(left) | set(right)
    for name in common_fields:
        require(canonical(left.get(name)) == canonical(right.get(name)), f"comparison {name} mismatch")
    require(baseline["provenance"]["profile_identity_sha256"]
            == candidate["provenance"]["profile_identity_sha256"], "comparison compiler/profile mismatch")
    for name in METHOD_FILES:
        require(baseline["provenance"]["source"]["source_sha256"][name]
                == candidate["provenance"]["source"]["source_sha256"][name],
                "comparison workload/method source mismatch; use an identical harness and runner")
    before = {(case["kind"], case["total"], case["mode"]): case for case in baseline["records"][1:-1]}
    after = {(case["kind"], case["total"], case["mode"]): case for case in candidate["records"][1:-1]}
    require(before.keys() == after.keys(), "comparison case set mismatch")
    rows = []
    for key, case in before.items():
        other = after[key]
        for name in ("revealed", "hidden", "visible_payload_utf8_bytes", "window", "pane_width"):
            require(case[name] == other[name], "comparison payload/window mismatch")
        for old, new in zip(case["draw_routes"], other["draw_routes"]):
            require(old["route"] == new["route"], "comparison route mismatch")
            a, b = old["timings"], new["timings"]
            require(a["median_us"] > 0 and b["median_us"] > 0, "zero median cannot form a comparison ratio")
            rows.append({"kind": key[0], "total": key[1], "mode": key[2], "route": old["route"],
                         "baseline_median_ms": a["median_us"] / 1000, "candidate_median_ms": b["median_us"] / 1000,
                         "baseline_p95_ms": a["p95_us"] / 1000, "candidate_p95_ms": b["p95_us"] / 1000,
                         "median_ratio_baseline_over_candidate": a["median_us"] / b["median_us"],
                         "baseline_samples": a["samples"], "candidate_samples": b["samples"],
                         "baseline_budget_exhausted": old["budget_exhausted"],
                         "candidate_budget_exhausted": new["budget_exhausted"]})
    return {"schema_version": SCHEMA, "measurement_label": LABEL, "text_system": TEXT_SYSTEM,
            "baseline_sha256": digest(baseline), "candidate_sha256": digest(candidate), "cases": rows,
            "caveats": sorted(set(baseline["caveats"] + candidate["caveats"]))}


def run_benchmark(args, output):
    rust_root = Path(__file__).resolve().parents[1]
    repo = rust_root.parent
    env = dict(os.environ)
    for name in ("BELLO_PERF_LOG", "BELLO_TEST_APPEARANCE", "BELLO_TEST_WINDOW_SIZE",
                 "BELLO_TRANSCRIPT_BENCHMARK_CONFIG"):
        env.pop(name, None)
    configurations = validate_build_environment(rust_root, env)
    source = source_state(repo, rust_root, env)
    compiler = compiler_identity(rust_root, env)
    status, stdout = capture(build_command(), rust_root, env=env, timeout=args.build_timeout)
    require(status == 0, "Cargo build failed")
    executable, profile = cargo_artifact(stdout, rust_root)
    require(source_state(repo, rust_root, env) == source, "source changed during build")
    require(compiler_identity(rust_root, env) == compiler, "compiler changed during build")
    binary_hash = file_digest(executable)
    fingerprint = cargo_fingerprint(executable)
    host = {"system": platform.system(), "machine": platform.machine()}
    provenance = {
        "source": source, "compiler": compiler, "compiler_overrides_checked": configurations,
        "build_profile": profile, "test_binary_sha256": binary_hash, "platform": host,
        "cargo_fingerprint": fingerprint,
        "build_command": build_command(), "test_command": ["<cargo-built-app-test>", *test_arguments()],
        "profile_identity_sha256": digest({"profile": profile, "compiler": compiler,
            "cargo_fingerprint": fingerprint,
            "manifest_profiles_sha256": source["manifest_profiles_sha256"], "platform": host}),
    }
    metadata = make_metadata(args.totals, args.mode, profile)
    validate_provenance(provenance, metadata)
    fixtures = output / "fixtures"
    fixtures.mkdir()
    with tempfile.TemporaryDirectory(prefix="bello-transcript-config-") as scratch:
        config_path = Path(scratch) / "config.json"
        write_json(config_path, {"schema_version": SCHEMA, "totals": args.totals, "mode": args.mode,
                                "fixture_dir": str(fixtures.resolve()), "build_profile": profile})
        env["BELLO_TRANSCRIPT_BENCHMARK_CONFIG"] = str(config_path)
        status, stdout = capture([str(executable), *test_arguments()], rust_root, env=env,
                                 timeout=args.run_timeout)
    records = parse_output(stdout, status, metadata)
    require(file_digest(executable) == binary_hash and cargo_fingerprint(executable) == fingerprint,
            "compiled test changed during measurement")
    require(source_state(repo, rust_root, env) == source, "source changed during measurement")
    require(validate_build_environment(rust_root, env) == configurations, "Cargo configuration changed during measurement")
    require(compiler_identity(rust_root, env) == compiler, "compiler changed during measurement")
    report = make_report(records, provenance)
    write_json(output / "raw.json", records)
    write_json(output / "results.json", report)
    write_csv(output / "summary.csv", summary_rows(records))
    return {"schema_version": SCHEMA, "status": "complete", "cases": metadata["expected_cases"]}


def totals_argument(value):
    try:
        values = [int(part) for part in value.split(",")]
        validate_totals(values)
        return values
    except (ValueError, ValidationError) as error:
        raise argparse.ArgumentTypeError("use an ascending unique subset of 100,1000,10000") from error



def validate_output_location(output, repo):
    protected = ("rust/crates", "rust/benches", "rust/scripts", "assets", ".git")
    require(not any(output.is_relative_to((repo / name).resolve()) for name in protected),
            "output is inside source/tooling/assets; use a workspace sibling or rust/target directory")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="manually build and measure the ignored GPUI test")
    run.add_argument("--output", required=True, type=Path, help="new evidence directory; existing paths are refused")
    run.add_argument("--totals", type=totals_argument, default=list(TOTALS))
    run.add_argument("--mode", choices=("cached", "generic"), default="cached")
    run.add_argument("--build-timeout", type=int, default=3600)
    run.add_argument("--run-timeout", type=int, default=7200)
    compare = commands.add_parser("compare", help="compare complete current-schema reports, full draws only")
    compare.add_argument("--baseline", required=True, type=Path)
    compare.add_argument("--candidate", required=True, type=Path)
    compare.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    if args.command == "run":
        require(1 <= args.build_timeout <= 86400 and 1 <= args.run_timeout <= 86400, "invalid command timeout")
    # This is intentionally outside the failure-report handler: never alter an
    # existing evidence directory, even when a previous run failed halfway.
    output = args.output.resolve()
    validate_output_location(output, Path(__file__).resolve().parents[2])
    output.mkdir(parents=True, exist_ok=False)
    try:
        if args.command == "run":
            result = run_benchmark(args, output)
        else:
            result = compare_reports(read_json(args.baseline.read_text()), read_json(args.candidate.read_text()))
            write_json(output / "comparison.json", result)
            write_csv(output / "comparison.csv", result["cases"])
            result = {"schema_version": SCHEMA, "status": "complete", "cases": len(result["cases"])}
        write_json(output / "report.json", result)
        print(f"Complete: {result['cases']} validated cases. Results are in the new evidence directory.")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Exception text and command output can contain paths, source snippets,
        # credentials or private environment values. Persist only a category.
        failure = {"schema_version": SCHEMA, "status": "failed", "operation": args.command,
                   "failure": type(error).__name__}
        # ValidationError messages are authored here from fixed schema labels,
        # never copied from a subprocess, OS exception, or supplied JSON text.
        if type(error) is ValidationError:
            failure["reason"] = str(error)
        write_json(output / "report.json", failure)
        detail = f": {failure['reason']}" if "reason" in failure else ""
        print(f"Benchmark {args.command} failed ({type(error).__name__}){detail}; "
              "no valid comparison is claimed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
