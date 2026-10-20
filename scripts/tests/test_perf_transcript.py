"""Run the performance wrapper with generated products and a fake xcodebuild."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "perf-transcript.sh"


class PerformanceWrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pi-perf-wrapper-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dd = self.root / "Derived Data"
        products = self.dd / "Build/Products"
        app = products / "Bello Agent Tests.app/Contents"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.belloware.PiAppTests.Host"}))
        (products / "fixture.xctestrun").write_bytes(plistlib.dumps({"PiAppTests": {
            "TestHostPath": "__TESTROOT__/Bello Agent Tests.app/Contents/MacOS/Bello Agent Tests",
            "EnvironmentVariables": {"CFFIXED_USER_HOME": str(self.root / "isolated-home")},
        }}))
        binary = self.root / "bin"
        binary.mkdir()
        self.calls = self.root / "calls.txt"
        for name, source in {
            "sysctl": "#!/bin/sh\necho '{ 0.0 0.0 0.0 }'\n",
            "xcodebuild": """#!/bin/sh
echo "$*" >> "$PERF_CALLS"
echo 'Executed 1 tests'
if [ "$(wc -l < "$PERF_CALLS")" -eq 1 ]; then exit "$PERF_FIRST_STATUS"; fi
exit 0
""",
        }.items():
            path = binary / name
            path.write_text(source)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        ONLY="baseline", PERF_CALLS=str(self.calls), PERF_FIRST_STATUS="0")

    def run_wrapper(self, output, *, dd=None, rounds=1, soak=0):
        return subprocess.run(["bash", str(SCRIPT), str(dd or self.dd), str(output), str(rounds), str(soak), "100000"],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)

    def test_an_earlier_failed_invocation_is_not_masked_by_later_success(self):
        self.env["PERF_FIRST_STATUS"] = "65"
        done = self.run_wrapper(self.root / "results", rounds=2)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2, done.stdout + done.stderr)
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("exit 65", (self.root / "results/load.txt").read_text())
        self.assertIn("exit 0", (self.root / "results/load.txt").read_text())

    def test_relative_output_runs_tests_and_writes_logs_directly_in_that_folder(self):
        done = self.run_wrapper("results")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue(self.calls.exists(), done.stdout + done.stderr)
        self.assertIn("Executed 1 tests", (self.root / "results/baseline-1.log").read_text())
        self.assertFalse((self.root / "results/results").exists())

    def test_relative_products_are_resolved_before_entering_the_output_folder(self):
        done = self.run_wrapper("results", dd="Derived Data")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(str(self.dd / "Build/Products/fixture.xctestrun"), self.calls.read_text())

    def test_absolute_resolution_preserves_a_trailing_newline_in_the_output_name(self):
        sibling = self.root / "results"
        sibling.mkdir()
        log = sibling / "baseline-1.log"
        log.write_text("preserve the sibling log")
        done = self.run_wrapper("results\n")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(log.read_text(), "preserve the sibling log")
        self.assertIn("Executed 1 tests", (self.root / "results\n/baseline-1.log").read_text())

    def test_an_uncreatable_output_folder_fails_without_launching_tests(self):
        blocked = self.root / "blocked"
        blocked.write_text("not a directory")
        done = self.run_wrapper(blocked)
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse(self.calls.exists())

    def test_successful_invocations_return_success(self):
        done = self.run_wrapper(self.root / "results", rounds=2)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)

    def test_a_failed_soak_is_not_masked_by_successful_soakdraw(self):
        self.env.update(ONLY="soak", PERF_FIRST_STATUS="65")
        done = self.run_wrapper(self.root / "results", soak=1)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2, done.stdout + done.stderr)
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((self.root / "results/soak-1.log").exists())
        self.assertTrue((self.root / "results/soakdraw-1.log").exists())


if __name__ == "__main__":
    unittest.main()
