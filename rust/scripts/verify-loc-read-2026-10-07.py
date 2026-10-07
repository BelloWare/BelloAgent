#!/usr/bin/env python3
"""Verify the reviewed read-tool LOC delta from immutable published Git objects.

No checkout, dependency download or Rust parser is required. The checked-in JSON
contains explicit reviewed spans, not a claim to classify arbitrary future code.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
KEYS = ('production', 'tests_and_test_support', 'benchmark_example')


def nonblank(lines):
    return sum(bool(line.strip()) for line in lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    path = args.report or args.repo / 'rust/docs/validation/loc-read-2026-10-07-delta.json'
    report = json.loads(path.read_text())

    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(args.repo), *arguments])

    def files(ref):
        result = {}
        for line in git('ls-tree', '-r', ref, '--', 'rust/').decode().splitlines():
            metadata, name = line.split('\t', 1)
            if name.endswith('.rs'):
                result[name] = metadata.split()[2]
        return result

    before, after = report['before_commit'], report['after_commit']
    assert git('rev-parse', before + '^{tree}').decode().strip() == report['before_tree']
    assert git('rev-parse', after + '^{tree}').decode().strip() == report['after_tree']
    assert git('rev-list', '--parents', '-n', '1', after).decode().split() == [after, before]
    old_blobs, new_blobs = files(before), files(after)
    changed = sorted(name for name in old_blobs.keys() | new_blobs.keys()
                     if old_blobs.get(name) != new_blobs.get(name))
    assert changed == sorted(entry['path'] for entry in report['files'])
    assert len(changed) == report['changed_rust_files']
    assert len(new_blobs) == report['rust_file_count']
    assert not any('/benches/' in name or '/examples/' in name for name in changed)
    delta = dict.fromkeys(KEYS, 0)
    for entry in report['files']:
        name = entry['path']
        for side, ref, blobs, sign in (
                ('before', before, old_blobs, -1), ('after', after, new_blobs, 1)):
            assert blobs.get(name) == entry[side + '_blob']
            lines = git('show', f'{ref}:{name}').decode().splitlines() if name in blobs else []
            support = set()
            for span in entry[side]['reviewed_support_ranges']:
                start, end = span['start'], span['end']
                assert 1 <= start <= end <= len(lines)
                assert lines[start - 1] == span['start_text']
                assert lines[end - 1] == span['end_text']
                support.update(range(start, end + 1))
            counts = dict.fromkeys(KEYS, 0)
            for number, line in enumerate(lines, 1):
                if line.strip():
                    counts['tests_and_test_support' if number in support else 'production'] += 1
            assert nonblank(lines) == entry[side]['nonblank']
            assert counts == entry[side]['counts']
            for key in KEYS:
                delta[key] += sign * counts[key]
        assert entry['delta'] == {
            key: entry['after']['counts'][key] - entry['before']['counts'][key] for key in KEYS}
    assert delta == report['delta']
    counts = {key: report['before_counts'][key] + delta[key] for key in KEYS}
    assert counts == report['after_counts']
    for ref, blobs, expected in ((before, old_blobs, report['before_total']),
                                 (after, new_blobs, report['after_total'])):
        total = sum(nonblank(git('show', f'{ref}:{name}').decode().splitlines()) for name in blobs)
        assert total == expected
    assert sum(report['before_counts'].values()) == report['before_total']
    assert sum(counts.values()) == report['after_total']
    print(json.dumps({'commit': after, 'tree': report['after_tree'], 'delta': delta,
                      'counts': counts, 'total': report['after_total'],
                      'rust_files': report['rust_file_count']}, indent=2))


if __name__ == '__main__':
    main()
