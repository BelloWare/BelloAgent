import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("report", Path(__file__).parents[1] / "report-native-benchmark.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def test_bounded_sample_rollover_is_explicit_and_uses_observation_counts(self):
        before = {"totalSamples": {"input": 10, "delta": 10}, "samples": {"input": [1, 2]}}
        after = {"totalSamples": {"input": 12, "delta": 20}, "samples": {"input": [1, 2, 5, 6], "delta": [7, 8]}}
        values = report.timing_window(before, after)
        self.assertEqual(values["input"]["p50"], 5)
        self.assertEqual(values["input"]["coverage"], "full")
        self.assertEqual(values["delta"]["count"], 10)
        self.assertEqual(values["delta"]["coverage"], "retained-tail")

    def test_memory_window_excludes_idle_samples(self):
        samples = [{"wallTime": t, "rssBytes": n * 1_048_576} for t, n in [(0, 1), (1, 600), (2, 800), (3, 1)]]
        values = report.memory_window(samples, {"streamStartWall": 1, "streamEndWall": 2})
        self.assertEqual(values["meanMiB"], 700)
        self.assertEqual(values["peakMiB"], 800)
        self.assertEqual(values["samples"], 2)
