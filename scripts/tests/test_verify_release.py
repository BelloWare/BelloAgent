import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class VerifyReleaseTests(unittest.TestCase):
    """Exercise gate ordering and failures without builds or app launches."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        binary = self.root / "bin"
        binary.mkdir()
        self.calls = self.root / "calls.jsonl"
        stub = f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
descriptor = os.open(os.environ["GATE_CALLS"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.write(descriptor, (json.dumps([name, args]) + "\\n").encode())
os.close(descriptor)
if name == "python3" and args[:1] == ["scripts/test-lanes.py"]:
    print("-only-testing:PiAppTests/Fixture")
elif name == "swift" and args[:1] == ["test"]:
    if "--filter" in args:
        if os.environ.get("GATE_FAIL_COST"):
            print("Test Case '-[PiAgentCoreTests.StreamingCostTests testFixture]' failed.")
            sys.exit(1)
        print("Executed 5 tests, with 0 failures")
    else:
        print("Executed 575 tests, with 6 tests skipped and 0 failures")
elif name == "python3":
    print("Ran 2 tests")
elif name == "xcodebuild" and "test-without-building" in args:
    print("Executed 1 test, with 0 failures")
'''
        for name in ("git", "python3", "swift", "xcodegen", "xcodebuild"):
            path = binary / name
            path.write_text(stub)
            path.chmod(0o755)
        self.environment = dict(os.environ, PI_BUILD_ROOT=str(self.root / "build"),
                                PATH=str(binary) + os.pathsep + os.environ["PATH"],
                                GATE_CALLS=str(self.calls))
        self.environment.pop("GATE_FAIL_COST", None)

    def gate(self, **environment):
        result = subprocess.run(["bash", str(ROOT / "scripts/verify-release.sh")],
                                env=dict(self.environment, **environment), text=True, capture_output=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls

    def test_cost_measurements_run_alone_and_are_not_repeated_with_gallery(self):
        result, calls = self.gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cost = [index for index, (name, args) in enumerate(calls) if name == "swift" and "--filter" in args]
        bulk = [args for name, args in calls if name == "swift" and "--skip" in args]
        gallery = next(index for index, (name, args) in enumerate(calls)
                       if name == "xcodebuild" and "-only-testing:PiAppTests/UIScreenshotTests" in args)
        self.assertEqual(len(cost), 1)
        self.assertLess(cost[0], gallery)
        self.assertEqual(calls[cost[0]][1][-2:], ["--filter", "StreamingCostTests"])
        self.assertEqual(len(bulk), 1)
        self.assertEqual(bulk[0][-2:], ["--skip", "StreamingCostTests"])
        self.assertIn("helper-cost", result.stdout)
        self.assertIn("all passed", result.stdout)

    def test_cost_failure_fails_the_gate_and_later_checks_still_run(self):
        result, calls = self.gate(GATE_FAIL_COST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED: helper-cost", result.stdout)
        self.assertIn("failed StreamingCostTests.testFixture", result.stdout)
        self.assertTrue(any(name == "swift" and "--skip" in args for name, args in calls))
        self.assertTrue(any(name == "xcodebuild" and "-only-testing:PiAppTests/UIScreenshotTests" in args for name, args in calls))
        self.assertTrue(any(name == "python3" and args[:1] == ["scripts/test-native-host.py"] for name, args in calls))
