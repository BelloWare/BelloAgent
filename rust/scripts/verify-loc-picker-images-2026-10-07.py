#!/usr/bin/env python3
"""Verify reviewed picker-selected image attachment LOC spans against exact Rust source blobs.

The after-source manifest avoids a self-referential commit hash in this same
checkpoint. Use --after with its published revision; only exact source matches
pass. No checkout, dependency download, or general-purpose classifier is used.
"""
import argparse
import hashlib
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
    parser.add_argument('--after', default='HEAD', help='Git revision; WORKTREE only for pre-commit checks')
    args = parser.parse_args()
    report_path = args.report or args.repo / 'rust/docs/validation/loc-picker-images-2026-10-07-delta.json'
    report = json.loads(report_path.read_text())

    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(args.repo), *arguments])

    def source(ref, name):
        return ((args.repo / name).read_bytes() if ref == 'WORKTREE'
                else git('show', f'{ref}:{name}'))

    def files(ref):
        if ref == 'WORKTREE':
            names = git('ls-files', '--cached', '--others', '--exclude-standard', '--', 'rust/').decode().splitlines()
            result = {}
            for name in sorted(set(names)):
                if name.endswith('.rs'):
                    data = source(ref, name)
                    result[name] = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            return result
        result = {}
        for line in git('ls-tree', '-r', ref, '--', 'rust/').decode().splitlines():
            metadata, name = line.split('\t', 1)
            if name.endswith('.rs'):
                result[name] = metadata.split()[2]
        return result

    before, after = report['before_commit'], args.after
    assert git('rev-parse', before + '^{tree}').decode().strip() == report['before_tree']
    if after != 'WORKTREE':
        subprocess.check_call(['git', '-C', str(args.repo), 'merge-base', '--is-ancestor', before, after])
    old_blobs, new_blobs = files(before), files(after)
    assert new_blobs == report['after_rust_blobs'], 'after Rust blobs differ from the reviewed source'
    manifest = hashlib.sha256(json.dumps(new_blobs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    assert manifest == report['after_source_manifest_sha256']
    changed = sorted(name for name in old_blobs.keys() | new_blobs.keys()
                     if old_blobs.get(name) != new_blobs.get(name))
    assert changed == sorted(entry['path'] for entry in report['files'])
    assert len(changed) == report['changed_rust_files']
    assert len(new_blobs) == report['rust_file_count']
    delta = dict.fromkeys(KEYS, 0)
    for entry in report['files']:
        name = entry['path']
        benchmark = '/benches/' in name or '/examples/' in name
        assert entry['category'] == ('benchmark_example' if benchmark else 'mixed')
        for side, ref, blobs, sign in (
                ('before', before, old_blobs, -1), ('after', after, new_blobs, 1)):
            assert blobs.get(name) == entry[side + '_blob']
            lines = source(ref, name).decode().splitlines() if name in blobs else []
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
                    category = ('benchmark_example' if benchmark else
                                'tests_and_test_support' if number in support else 'production')
                    counts[category] += 1
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
        total = sum(nonblank(source(ref, name).decode().splitlines()) for name in blobs)
        assert total == expected
    assert sum(report['before_counts'].values()) == report['before_total']
    assert sum(counts.values()) == report['after_total']
    print(json.dumps({'after': after, 'source_manifest_sha256': manifest, 'delta': delta,
                      'counts': counts, 'total': report['after_total'],
                      'rust_files': report['rust_file_count']}, indent=2))


if __name__ == '__main__':
    main()
