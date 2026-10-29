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


class ArchiveLocationTests(unittest.TestCase):
    def test_default_archive_is_outside_the_repository(self):
        output = report.archive_path()
        self.assertEqual(output.parent, Path('/Users/admin/Library/Caches/BelloSwiftWork/perf-evidence'))
        self.assertEqual(output.name, 'a136-perf-0.1.136-phase-b-data.json.gz')

    def test_an_archive_cannot_be_written_into_the_repository(self):
        with self.assertRaises(ValueError):
            report.archive_path(Path(__file__).resolve().parent.parent / 'docs/validation/evidence.json.gz')


class DirectionalReadTests(unittest.TestCase):
    def test_directional_cancellation_excludes_opposite_and_maintenance_reads(self):
        calls = [dict(cursor='older', newer='false', cancelled='true'),
                 dict(cursor='newer', newer='true', cancelled='false'),
                 dict(position='125', newer='false', cancelled='false'),
                 dict(cursor='', position='', newer='false', cancelled='true'),
                 dict(cursor='opening', newer='false', opening='true', cancelled='true')]
        for newer in [False, True]:
            value = report.directional_reads(calls, newer=newer)
            self.assertEqual(value, dict(requests=2, cancelled=0 if newer else 1))

    def test_empty_direction_has_no_cancellation_denominator(self):
        self.assertEqual(report.directional_reads([], newer=False), dict(requests=0, cancelled=0))


if __name__ == "__main__":
    unittest.main()
