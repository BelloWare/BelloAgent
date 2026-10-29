#!/usr/bin/env python3
"""Check quiet-window admission without starting a build or measurement."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("perf-longchat-run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class QuietWindowTests(unittest.TestCase):
    def admit(self, processes, load=2.1):
        with patch.object(runner.subprocess, "check_output", return_value=processes), \
             patch.object(runner, "load", return_value=("raw load", load)), patch("builtins.print"):
            return runner.quiet_start(2.5)

    def test_an_existing_xcode_test_waits_even_when_load_is_low(self):
        self.assertFalse(self.admit("12 S /Applications/Xcode 16.app/Contents/Developer/usr/bin/xcodebuild\n"))

    def test_swift_build_workers_also_wait(self):
        for name in ["swift-frontend", "swift-build", "swift-test"]:
            with self.subTest(name=name):
                self.assertFalse(self.admit(f"14 R /toolchain/bin/{name}\n"))

    def test_completed_builds_and_unrelated_processes_do_not_hold_the_lane(self):
        self.assertTrue(self.admit("12 Z+ /toolchain/xcodebuild\n13 S /bin/python3\n14 S /bin/xcodebuild-notes\n"))

    def test_load_headroom_still_applies_without_a_build(self):
        self.assertFalse(self.admit("13 S /bin/python3\n", load=2.6))


if __name__ == "__main__":
    unittest.main()
