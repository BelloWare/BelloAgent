#!/usr/bin/env python3
"""Check duration/censoring semantics without running a timing workload."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("report", Path(__file__).with_name("perf-longchat-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class BlankDurationTests(unittest.TestCase):
    def test_duration_ends_at_first_nonblank_observation(self):
        spans = report.blank_episodes(dict(frameUptimes=[10, 10.01, 10.03, 10.08, 10.1], blankAt=[1, 2, 4]), ended=10.12)
        self.assertEqual(len(spans), 2)
        self.assertAlmostEqual(spans[0]["ms"], 70)
        self.assertEqual(spans[0]["blankObservations"], 2)
        self.assertFalse(spans[0]["censored"])
        self.assertAlmostEqual(spans[1]["ms"], 20)
        self.assertTrue(spans[1]["censored"])

    def test_absent_timestamps_cannot_supply_a_duration(self):
        self.assertEqual(report.blank_episodes(dict(blankAt=[0, 1])), [])
        self.assertEqual(report.blank_episodes(dict(frameUptimes=[1, 2], blankAt=[])), [])


if __name__ == "__main__":
    unittest.main()
