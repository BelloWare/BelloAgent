"""Synthetic parser/runner unit tests, never benchmark or desktop measurements."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("benchmark", Path(__file__).with_name("transcript_benchmark.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

PROFILE = {"opt_level": "0", "debuginfo": 0, "debug_assertions": True, "overflow_checks": True, "test": True}


def records(mode="cached", totals=None):
    totals = [100] if totals is None else totals
    result = [bench.make_metadata(totals, mode, PROFILE)]
    for kind in bench.KINDS:
        for total in totals:
            for reveal in bench.REVEAL_MODES:
                visible = min(100, total) if reveal == "default_100" else total
                case = {
                    "record_type": "case", "schema_version": 1, "kind": kind, "total": total,
                    "mode": reveal, "revealed": visible, "hidden": total - visible,
                    "measurement_mode": mode, "build_profile": dict(PROFILE), "window": [1280, 840],
                    "pane_width": 979.0, "exact_rows_before": visible, "exact_rows_after": visible,
                    "unchanged_history_and_draft": True, "persistent_snapshot_bytes_unchanged": True,
                    "visible_payload_utf8_bytes": bench.payload_bytes(kind, visible), "draw_routes": [],
                }
                for index, route in enumerate(bench.ROUTES):
                    entry = {"route": route, "warmup": 3, "budget_seconds": 45, "budget_exhausted": False,
                             "wall_seconds_including_warmup": .1, "timings": bench.timing_summary(list(range(1, 22)))}
                    if mode == "cached":
                        entry.update(child_render_counts_per_measured_sample=[index] * 21,
                                     child_render_counts_per_warmup=[index] * 3)
                    case["draw_routes"].append(entry)
                if mode == "cached":
                    case.update(construction_warmup=7, construction_scope=bench.CONSTRUCTION_SCOPE,
                                parent_composition_child_renders=0, direct_child_render_scope=bench.CHILD_SCOPE,
                                source_accounting={"message_payload_string_clone_bytes_per_parent_composition": 0,
                                 "message_payload_string_clone_bytes_per_child_render": bench.payload_bytes(kind, visible),
                                 "is_heap_allocation_measurement": False, "excludes": bench.CLONE_EXCLUDES})
                    for build, destroy, combined in (bench.METRICS[:3], bench.METRICS[3:]):
                        case[build] = bench.timing_summary([1000] * 31)
                        case[destroy] = bench.timing_summary([500] * 31)
                        case[combined] = bench.timing_summary([1500] * 31)
                result.append(case)
    result.append({"record_type": "complete", "schema_version": 1, "cases": len(totals) * 4})
    return result


def provenance():
    compiler = {"release": "1.90.0", "commit-hash": "a" * 40, "commit-date": "2025-09-14",
                "host": "x86_64-unknown-linux-gnu", "LLVM version": "20.1.8", "cargo": "cargo 1.90.0 (abc123 2025-09-14)"}
    hashes = {"rust/Cargo.lock": "b" * 64, "rust/benches/transcript.rs": "c" * 64,
              "rust/scripts/transcript_benchmark.py": "d" * 64}
    profiles = "d" * 64
    host = {"system": "Linux", "machine": "x86_64"}
    fingerprint = {"profile": 123, "rustc": 456, "target": 789, "compile_kind": 0,
                   "rustflags": [], "features": ["default"]}
    return {"source": {"commit": "a" * 40, "source_sha256": hashes,
                       "source_tree_sha256": bench.digest(hashes), "manifest_profiles_sha256": profiles},
            "compiler": compiler, "compiler_overrides_checked": True, "build_profile": dict(PROFILE),
            "test_binary_sha256": "e" * 64, "platform": host, "cargo_fingerprint": fingerprint,
            "profile_identity_sha256": bench.digest({"profile": PROFILE, "compiler": compiler,
                "cargo_fingerprint": fingerprint, "manifest_profiles_sha256": profiles, "platform": host}),
            "build_command": bench.build_command(), "test_command": ["<cargo-built-app-test>", *bench.test_arguments()]}


def report(mode="cached", totals=None):
    return bench.make_report(records(mode, totals), provenance())


def output(values):
    return "\n".join(bench.MARKER + json.dumps(value) for value in values) + (
        "\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 99 filtered out; finished in 1.00s\n")


def update_identity(value):
    value["profile_identity_sha256"] = bench.digest({"profile": value["build_profile"], "compiler": value["compiler"],
        "cargo_fingerprint": value["cargo_fingerprint"], "manifest_profiles_sha256": value["source"]["manifest_profiles_sha256"],
        "platform": value["platform"]})


class ParserTests(unittest.TestCase):
    def test_complete_default_matrix(self):
        values = records(totals=[100, 1000, 10000])
        parsed = bench.parse_output(output(values), 0, values[0])
        self.assertEqual(len(parsed), 14)
        self.assertEqual(len(list(bench.summary_rows(parsed))), 96)

    def test_even_median_and_nearest_rank_p95(self):
        value = bench.timing_summary([40, 10, 30, 20])
        self.assertEqual(value["median_us"], .025)
        self.assertEqual(value["p95_us"], .04)
        self.assertEqual(bench.validate_timings(value, 21), value)

    def test_generic_has_only_comparable_draws(self):
        values = bench.validate_records(records("generic"))
        self.assertEqual(len(list(bench.summary_rows(values))), 8)
        self.assertNotIn("construction", values[1])
        self.assertNotIn("source_accounting", values[1])
        self.assertNotIn("child_render_counts_per_measured_sample", values[1]["draw_routes"][0])
        self.assertTrue(all(row["cache_hit_samples"] == "" for row in bench.summary_rows(values)))

    def test_budget_exhausted_sparse_series_is_explicit(self):
        values = records()
        route = values[1]["draw_routes"][0]
        route.update(budget_exhausted=True, wall_seconds_including_warmup=46.0,
                     timings=bench.timing_summary([400, 600]), child_render_counts_per_measured_sample=[0, 0])
        result = bench.make_report(values, provenance())
        self.assertIn("observed maximum", result["caveats"][-1])
        self.assertEqual(result["records"][1]["draw_routes"][0]["timings"]["median_us"], .5)

    def test_notify_misses_are_reported_honestly(self):
        values = records()
        values[1]["draw_routes"][0]["child_render_counts_per_measured_sample"][0] = 2
        rows = list(bench.summary_rows(bench.validate_records(values)))
        notify = next(row for row in rows if row["metric"] == bench.ROUTES[0])
        self.assertEqual(notify["child_renders_measured"], 2)
        self.assertEqual(notify["cache_hit_samples"], 20)

    def test_failed_process_even_with_complete_records_rejected(self):
        values = records()
        with self.assertRaisesRegex(bench.ValidationError, "process failed"):
            bench.parse_output(output(values), 1, values[0])

    def test_missing_terminal_success_rejected(self):
        values = records()
        with self.assertRaises(bench.ValidationError):
            bench.parse_output(output(values).split("test result:")[0], 0, values[0])

    def test_missing_duplicate_undeclared_and_wrong_complete_rejected(self):
        mutations = [lambda rows: rows.pop(2), lambda rows: rows.insert(2, copy.deepcopy(rows[1])),
                     lambda rows: rows[1].update(total=1000), lambda rows: rows.pop(),
                     lambda rows: rows[-1].update(cases=5), lambda rows: rows.reverse()]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                values = records()
                mutate(values)
                with self.assertRaises(bench.ValidationError):
                    bench.validate_records(values)

    def test_wrong_labels_profiles_totals_and_types_rejected(self):
        mutations = [lambda rows: rows[0].update(measurement_label="native frame"),
                     lambda rows: rows[0].update(text_system="CoreText"),
                     lambda rows: rows[0].update(expected_cases=True),
                     lambda rows: rows[0].update(totals=[100, 100]),
                     lambda rows: rows[0].update(totals=[1000, 100]),
                     lambda rows: rows[0].update(totals=[]),
                     lambda rows: rows[0].update(cfg_debug_assertions=1),
                     lambda rows: rows[1].update(kind="unknown"),
                     lambda rows: rows[1].update(mode="native"),
                     lambda rows: rows[1].update(revealed=True),
                     lambda rows: rows[1].update(window=[1280, 600]),
                     lambda rows: rows[1].update(pane_width=True),
                     lambda rows: rows[1].update(exact_rows_after=99),
                     lambda rows: rows[1].update(persistent_snapshot_bytes_unchanged=1),
                     lambda rows: rows[1].update(visible_payload_utf8_bytes=1),
                     lambda rows: rows[1]["build_profile"].update(opt_level="3")]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                values = records()
                mutate(values)
                with self.assertRaises(bench.ValidationError):
                    bench.validate_records(values)

    def test_raw_nonfinite_negative_boolean_fractional_and_huge_rejected(self):
        for value in (-1, True, 1.5, float("nan"), float("inf"), 2**128):
            with self.subTest(value=value):
                values = records()
                values[1]["draw_routes"][0]["timings"]["raw_ns"][0] = value
                with self.assertRaises(bench.ValidationError):
                    bench.validate_records(values)

    def test_malformed_json_duplicate_keys_and_nonfinite_rejected(self):
        for text in ('{"a":', '{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}', '{"a":-Infinity}'):
            with self.subTest(text=text), self.assertRaises(bench.ValidationError):
                bench.read_json(text)

    def test_partial_budget_count_and_claims_rejected(self):
        mutations = [lambda route: route["timings"].update(samples=20),
                     lambda route: route["timings"].update(median_us=2),
                     lambda route: route.update(budget_exhausted=True),
                     lambda route: route.update(budget_exhausted=1),
                     lambda route: route.update(wall_seconds_including_warmup=float("inf")),
                     lambda route: route.update(wall_seconds_including_warmup=-1),
                     lambda route: route.update(wall_seconds_including_warmup=10**1000),
                     lambda route: route.update(warmup=2),
                     lambda route: route.update(child_render_counts_per_measured_sample=[0]),
                     lambda route: route.update(child_render_counts_per_warmup=[False, 0, 0]),
                     lambda route: route.update(child_render_counts_per_warmup=[-1, 0, 0]),
                     lambda route: route.update(timings=bench.timing_summary([1, 2]))]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                values = records()
                mutate(values[1]["draw_routes"][0])
                with self.assertRaises(bench.ValidationError):
                    bench.validate_records(values)
        values = records()
        values[1]["draw_routes"][1]["child_render_counts_per_measured_sample"][0] = 0
        with self.assertRaisesRegex(bench.ValidationError, "cache hit"):
            bench.validate_records(values)

    def test_unknown_fields_private_text_and_false_clone_claims_rejected(self):
        for mutate in (lambda rows: rows[1].update(fixture="/private/secret"),
                       lambda rows: rows[1]["source_accounting"].update(is_heap_allocation_measurement=True),
                       lambda rows: rows[1]["source_accounting"].update(message_payload_string_clone_bytes_per_child_render=0),
                       lambda rows: rows[1].update(parent_composition_child_renders=1),
                       lambda rows: rows[1]["construction_plus_destruction"].update(**bench.timing_summary([1] * 31))):
            values = records()
            mutate(values)
            with self.assertRaises(bench.ValidationError):
                bench.validate_records(values)

    def test_generic_cannot_hide_child_or_construction_claims(self):
        for mutate in (lambda rows: rows[1].update(construction=bench.timing_summary([1] * 31)),
                       lambda rows: rows[1]["draw_routes"][0].update(child_render_counts_per_measured_sample=[0] * 21)):
            values = records("generic")
            mutate(values)
            with self.assertRaises(bench.ValidationError):
                bench.validate_records(values)

    def test_profile_mismatch_against_invocation_rejected(self):
        values = records()
        expected = copy.deepcopy(values[0])
        expected["build_profile"]["debuginfo"] = 2
        with self.assertRaisesRegex(bench.ValidationError, "configuration/profile"):
            bench.parse_output(output(values), 0, expected)


class ComparisonTests(unittest.TestCase):
    def test_same_mode_compares_only_full_draw_routes(self):
        compared = bench.compare_reports(report("generic"), report("generic"))
        self.assertEqual(len(compared["cases"]), 8)
        self.assertEqual({row["route"] for row in compared["cases"]}, set(bench.ROUTES))
        self.assertTrue(all(row["median_ratio_baseline_over_candidate"] == 1 for row in compared["cases"]))

    def test_modes_cannot_be_compared_with_different_preparation(self):
        with self.assertRaisesRegex(bench.ValidationError, "modes differ"):
            bench.compare_reports(report("generic"), report("cached"))

    def test_case_sets_profile_and_fingerprints_must_match(self):
        with self.assertRaises(bench.ValidationError):
            bench.compare_reports(report(totals=[100]), report(totals=[100, 1000]))
        for field in ("profile", "rustc"):
            candidate = report()
            candidate["provenance"]["cargo_fingerprint"][field] += 1
            update_identity(candidate["provenance"])
            with self.assertRaisesRegex(bench.ValidationError, "profile mismatch"):
                bench.compare_reports(report(), candidate)
        candidate = report()
        candidate["provenance"]["compiler"]["release"] = "1.91.0"
        update_identity(candidate["provenance"])
        with self.assertRaisesRegex(bench.ValidationError, "profile mismatch"):
            bench.compare_reports(report(), candidate)

    def test_same_length_payload_or_method_edits_cannot_hide_behind_version(self):
        for name in bench.METHOD_FILES:
            with self.subTest(name=name):
                candidate = report()
                source = candidate["provenance"]["source"]
                source["source_sha256"][name] = "f" * 64
                source["source_tree_sha256"] = bench.digest(source["source_sha256"])
                # Declared payload version and UTF-8 byte counts stay unchanged.
                with self.assertRaisesRegex(bench.ValidationError, "workload/method source mismatch"):
                    bench.compare_reports(report(), candidate)

    def test_old_or_partial_reports_need_adapter(self):
        for old in ([], {"status": "failed"}, {"kind": "short", "base_commit": "0beb423"}):
            with self.assertRaises(bench.ValidationError):
                bench.compare_reports(old, report())

    def test_source_changes_allowed_but_fake_fingerprints_rejected(self):
        candidate = report()
        candidate["provenance"]["source"]["commit"] = "f" * 40
        self.assertEqual(len(bench.compare_reports(report(), candidate)["cases"]), 8)
        candidate["provenance"]["profile_identity_sha256"] = "f" * 64
        with self.assertRaisesRegex(bench.ValidationError, "fingerprint mismatch"):
            bench.compare_reports(report(), candidate)

    def test_commands_from_result_data_are_never_accepted(self):
        candidate = report()
        candidate["provenance"]["test_command"] = ["sh", "-c", "touch /private/file"]
        with self.assertRaisesRegex(bench.ValidationError, "command metadata"):
            bench.compare_reports(report(), candidate)


class RunnerTests(unittest.TestCase):
    def test_existing_output_refused_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "recovery.txt"
            path.write_text("keep")
            with patch.object(bench, "run_benchmark") as run, self.assertRaises(FileExistsError):
                bench.main(["run", "--output", directory])
            run.assert_not_called()
            self.assertEqual(path.read_text(), "keep")
            self.assertEqual(len(list(Path(directory).iterdir())), 1)

    def test_outputs_inside_hashed_sources_are_rejected_before_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for name in ("rust/crates", "rust/benches", "rust/scripts", "assets", ".git"):
                output_dir = repo / name / "new-evidence"
                with self.subTest(name=name), \
                        patch.object(bench, "__file__", str(repo / "rust/scripts/transcript_benchmark.py")), \
                        patch.object(bench, "run_benchmark") as run, \
                        self.assertRaisesRegex(bench.ValidationError, "inside source"):
                    bench.main(["run", "--output", str(output_dir)])
                run.assert_not_called()
                self.assertFalse(output_dir.exists())
            bench.validate_output_location(repo / "rust/target/benchmark", repo)
            bench.validate_output_location(repo.parent / "sibling-evidence", repo)

    def test_failure_report_contains_no_private_exception_or_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory) / "new"
            with patch.object(bench, "run_benchmark", side_effect=RuntimeError("/private/secret token=abc")):
                self.assertEqual(bench.main(["run", "--output", str(output_dir)]), 1)
            result = (output_dir / "report.json").read_text()
            self.assertNotIn("private", result)
            self.assertNotIn("abc", result)
            self.assertEqual(json.loads(result)["status"], "failed")
            self.assertEqual([path.name for path in output_dir.iterdir()], ["report.json"])

    def test_cargo_artifact_requires_actual_app_test_and_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bello_agent-abcd"
            binary.touch()
            artifact = {"reason": "compiler-artifact", "target": {"name": "bello-agent", "kind": ["bin"],
                "src_path": str(root / "crates/bello-agent-app/src/main.rs")}, "profile": PROFILE,
                "features": ["default"], "executable": str(binary)}
            success = {"reason": "build-finished", "success": True}
            stream = json.dumps(artifact) + "\n" + json.dumps(success)
            self.assertEqual(bench.cargo_artifact(stream, root), (binary, PROFILE))
            for lines in ([artifact], [artifact, artifact, success], [artifact, {"reason": "build-finished", "success": False}]):
                with self.assertRaises(bench.ValidationError):
                    bench.cargo_artifact("\n".join(map(json.dumps, lines)), root)
            artifact["target"]["src_path"] = "/private/other/main.rs"
            with self.assertRaises(bench.ValidationError):
                bench.cargo_artifact(json.dumps(artifact) + "\n" + json.dumps(success), root)

    def test_matching_fingerprint_required_and_flags_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "deps/bello_agent-0123456789abcdef"
            path = root / ".fingerprint/bello-agent-app-0123456789abcdef/test-bin-bello-agent.json"
            path.parent.mkdir(parents=True)
            value = {"rustflags": [], "features": '["default"]', "profile": 1, "rustc": 2,
                     "target": 3, "compile_kind": 0, "private": "/private/secret"}
            path.write_text(json.dumps(value))
            result = bench.cargo_fingerprint(binary)
            self.assertNotIn("private", result)
            value["rustflags"] = ["-Copt-level=3"]
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(bench.ValidationError, "rustflags"):
                bench.cargo_fingerprint(binary)
            path.unlink()
            with self.assertRaisesRegex(bench.ValidationError, "unavailable"):
                bench.cargo_fingerprint(binary)

    def test_custom_compiler_environment_and_config_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {"CARGO_HOME": str(root / "cargo-home")}
            for name in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER", "CARGO_PROFILE_DEV_CODEGEN_UNITS",
                         "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER", "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS"):
                with self.subTest(name=name), self.assertRaises(bench.ValidationError):
                    bench.validate_build_environment(root, dict(env, **{name: "unsupported"}))
            config = root / ".cargo/config.toml"
            config.parent.mkdir()
            config.write_text('[build]\nrustc-wrapper = "/private/wrapper"\n')
            with self.assertRaises(bench.ValidationError):
                bench.validate_build_environment(root, env)
            config.write_text('[build]\njobs = 2\n')
            self.assertIs(bench.validate_build_environment(root, env), True)

    def test_unsupported_profile_types_rejected(self):
        for key, value in (("opt_level", "3"), ("test", 1), ("debug_assertions", False),
                           ("overflow_checks", False), ("debuginfo", True), ("debuginfo", "private")):
            with self.subTest(key=key, value=value), self.assertRaises(bench.ValidationError):
                bench.validate_profile(dict(PROFILE, **{key: value}))

    def test_runner_builds_locked_exact_artifact_and_saves_sanitized_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "debug/deps/bello_agent-0123456789abcdef"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"synthetic executable placeholder")
            out = root / "evidence"
            out.mkdir()
            rust_root = Path(bench.__file__).resolve().parents[1]
            artifact = {"reason": "compiler-artifact", "target": {"name": "bello-agent", "kind": ["bin"],
                "src_path": str(rust_root / "crates/bello-agent-app/src/main.rs")}, "profile": PROFILE,
                "features": ["default"], "executable": str(executable)}
            cargo_output = json.dumps(artifact) + "\n" + json.dumps({"reason": "build-finished", "success": True})
            def fake_capture(command, cwd, env, timeout):
                self.assertNotIn("BELLO_PERF_LOG", env)
                self.assertNotIn("BELLO_TEST_APPEARANCE", env)
                self.assertNotIn("BELLO_TEST_WINDOW_SIZE", env)
                if command[0] == "cargo":
                    self.assertEqual(command, bench.build_command())
                    self.assertIn("--locked", command)
                    self.assertEqual(command[command.index("--jobs") + 1], "4")
                    return 0, cargo_output
                self.assertEqual(command, [str(executable), *bench.test_arguments()])
                config = json.loads(Path(env["BELLO_TRANSCRIPT_BENCHMARK_CONFIG"]).read_text())
                self.assertEqual(config["fixture_dir"], str(out / "fixtures"))
                self.assertEqual(config["build_profile"], PROFILE)
                return 0, output(records())
            info = provenance()
            args = SimpleNamespace(totals=[100], mode="cached", build_timeout=20, run_timeout=30)
            with patch.object(bench, "source_state", return_value=info["source"]), \
                    patch.object(bench, "compiler_identity", return_value=info["compiler"]), \
                    patch.object(bench, "cargo_fingerprint", return_value=info["cargo_fingerprint"]), \
                    patch.object(bench, "validate_build_environment", return_value=True), \
                    patch.object(bench, "capture", side_effect=fake_capture), \
                    patch.dict(bench.os.environ, {"BELLO_PERF_LOG": "private", "BELLO_TEST_APPEARANCE": "dark",
                                                 "BELLO_TEST_WINDOW_SIZE": "tiny"}):
                self.assertEqual(bench.run_benchmark(args, out)["status"], "complete")
            saved = (out / "results.json").read_text()
            self.assertNotIn(directory, saved)
            self.assertNotIn("private", saved)
            self.assertEqual(bench.validate_report(json.loads(saved))["status"], "complete")
            self.assertEqual(sorted(path.name for path in out.iterdir()),
                             ["fixtures", "raw.json", "results.json", "summary.csv"])

    def test_capture_is_private_bounded_and_checks_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            status, stdout = bench.capture([sys.executable, "-c", "print('synthetic')"], directory, timeout=2)
            self.assertEqual((status, stdout), (0, "synthetic\n"))
            with self.assertRaises(bench.CaptureError):
                bench.capture([sys.executable, "-c", "print('x' * 10000)"], directory, timeout=2, limit=100)
            with self.assertRaises(bench.CaptureError):
                bench.capture([sys.executable, "-c", "import time; time.sleep(20)"], directory, timeout=.01)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_compare_cli_writes_only_sanitized_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after = root / "before.json", root / "after.json"
            bench.write_json(before, report("generic"))
            bench.write_json(after, report("generic"))
            out = root / "comparison"
            self.assertEqual(bench.main(["compare", "--baseline", str(before), "--candidate", str(after), "--output", str(out)]), 0)
            self.assertEqual(sorted(path.name for path in out.iterdir()), ["comparison.csv", "comparison.json", "report.json"])
            self.assertNotIn(directory, (out / "comparison.json").read_text())


if __name__ == "__main__":
    unittest.main()
