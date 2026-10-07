#!/usr/bin/env python3
"""Verify the reviewed project-skills LOC delta without changing source or Git.

Uses immutable baseline Git objects and an exact after-source manifest. Unchanged
lines retain their inherited category; only changed spans contribute to the delta.
WORKTREE is a pre-publication check, not evidence of a published checkpoint.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
KEYS = ('production', 'tests_and_test_support', 'benchmark_example')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def nonblank(lines):
    return sum(bool(line.strip()) for line in lines)


def source_manifest(sources):
    return {name: {'git_blob': blob(data), 'sha256': sha256(data),
                   'nonblank': nonblank(data.decode().splitlines())}
            for name, data in sorted(sources.items())}


def manifest_hash(manifest):
    return sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode())


def line_categories(lines, ranges, benchmark):
    support = set()
    for span in ranges:
        start, end = span['start'], span['end']
        assert 1 <= start <= end <= len(lines), ('invalid support range', span)
        assert lines[start - 1] == span['start_text'], ('start anchor', span)
        assert lines[end - 1] == span['end_text'], ('end anchor', span)
        support.update(range(start, end + 1))
    return ['benchmark_example' if benchmark else
            'tests_and_test_support' if number in support else 'production'
            for number in range(1, len(lines) + 1)]


def line_counts(lines, categories):
    counts = dict.fromkeys(KEYS, 0)
    for line, category in zip(lines, categories):
        if line.strip():
            counts[category] += 1
    return counts


def diff_evidence(before, after, old_categories, new_categories, alignment_anchors=()):
    """Audited SequenceMatcher convention, with explicit reviewed bridge anchors."""
    preserved, changed = [], []
    delta = dict.fromkeys(KEYS, 0)
    operations, old_cursor, new_cursor = [], 0, 0
    for anchor in [*alignment_anchors, None]:
        old_stop = len(before) if anchor is None else anchor['before_line'] - 1
        new_stop = len(after) if anchor is None else anchor['after_line'] - 1
        assert old_cursor <= old_stop <= len(before)
        assert new_cursor <= new_stop <= len(after)
        for tag, i, j, k, l in difflib.SequenceMatcher(
                a=before[old_cursor:old_stop], b=after[new_cursor:new_stop],
                autojunk=False).get_opcodes():
            operations.append((tag, i + old_cursor, j + old_cursor, k + new_cursor, l + new_cursor))
        if anchor is not None:
            assert before[old_stop] == after[new_stop] == anchor['source']
            operations.append(('equal', old_stop, old_stop + 1, new_stop, new_stop + 1))
            old_cursor, new_cursor = old_stop + 1, new_stop + 1
    for tag, i, j, k, l in operations:
        if tag == 'equal':
            for old, new in zip(range(i, j), range(k, l)):
                if before[old].strip():
                    assert old_categories[old] == new_categories[new], (
                        'unchanged nonblank line reclassified', old + 1, new + 1)
            preserved.append({
                'before_start': i + 1, 'after_start': k + 1, 'line_count': j - i,
                'nonblank_counts': line_counts(before[i:j], old_categories[i:j]),
                'source_sha256': sha256('\n'.join(before[i:j]).encode()),
            })
            continue
        for side, lines, categories, start, end, sign in (
                ('before', before, old_categories, i, j, -1),
                ('after', after, new_categories, k, l, 1)):
            cursor = start
            while cursor < end:
                category = categories[cursor]
                stop = cursor + 1
                while stop < end and categories[stop] == category:
                    stop += 1
                count = nonblank(lines[cursor:stop])
                delta[category] += sign * count
                changed.append({
                    'operation': tag, 'side': side, 'start': cursor + 1, 'end': stop,
                    'classification': category, 'nonblank': count,
                    'signed_delta': sign * count,
                    'source_sha256': sha256('\n'.join(lines[cursor:stop]).encode()),
                })
                cursor = stop
    return preserved, changed, delta


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT, help='Repository containing baseline Git history')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--after', default='HEAD', help='Exact Git revision, or WORKTREE before publication')
    parser.add_argument('--source-root', type=Path, help='Separate staging source; valid only with --after WORKTREE')
    args = parser.parse_args()
    assert args.source_root is None or args.after == 'WORKTREE'
    source_root = args.source_root or args.repo
    report_path = args.report or source_root / 'rust/docs/validation/loc-project-skills-2026-10-07-delta.json'
    report = json.loads(report_path.read_text())

    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(args.repo), *arguments])

    def committed_sources(ref):
        result = {}
        for row in git('ls-tree', '-r', ref, '--', 'rust/').decode().splitlines():
            metadata, name = row.split('\t', 1)
            if name.endswith('.rs'):
                data = git('show', f'{ref}:{name}')
                assert blob(data) == metadata.split()[2]
                result[name] = data
        return result

    before = report['before_commit']
    assert git('rev-parse', before + '^{tree}').decode().strip() == report['before_tree']
    old = committed_sources(before)
    if args.after == 'WORKTREE':
        new = {str(path.relative_to(source_root)): path.read_bytes()
               for path in sorted((source_root / 'rust').rglob('*.rs'))
               if not {'target', '.git'}.intersection(path.relative_to(source_root).parts)}
        after_identity = 'WORKTREE (source manifest only; publication unverified)'
    else:
        subprocess.check_call(['git', '-C', str(args.repo), 'merge-base', '--is-ancestor', before, args.after])
        after_identity = git('rev-parse', args.after + '^{commit}').decode().strip()
        new = committed_sources(after_identity)
    old_manifest, new_manifest = source_manifest(old), source_manifest(new)
    assert old_manifest == report['before_rust_sources'], 'baseline Rust sources differ'
    assert new_manifest == report['after_rust_sources'], 'after Rust sources differ from reviewed source'
    assert manifest_hash(old_manifest) == report['before_source_manifest_sha256']
    assert manifest_hash(new_manifest) == report['after_source_manifest_sha256']

    provenance_cache = {}

    def committed_ledger(provenance):
        path = provenance['path']
        if path not in provenance_cache:
            data = git('show', f'{before}:{path}')
            provenance_cache[path] = (data, json.loads(data))
        data, ledger = provenance_cache[path]
        assert blob(data) == provenance['git_blob']
        assert sha256(data) == provenance['sha256']
        return ledger

    baseline = committed_ledger(report['baseline_ledger'])
    anchor = report.get('baseline_anchor_commit', before)
    anchor_sources = old
    if anchor != before:
        subprocess.check_call(['git', '-C', str(args.repo), 'merge-base', '--is-ancestor', anchor, before])
        assert git('rev-parse', anchor + '^{tree}').decode().strip() == report['baseline_anchor_tree']
        anchor_sources = committed_sources(anchor)
    assert baseline['after_rust_blobs'] == {name: blob(data) for name, data in anchor_sources.items()}
    baseline_counts = baseline['after_counts'].copy()
    assert baseline['after_total'] == sum(nonblank(data.decode().splitlines()) for data in anchor_sources.values())
    if 'baseline_bridges' in report:
        previous, previous_sources = anchor, anchor_sources
        reviewed_paths = {
            'rust/crates/bello-agent-core/src/attachment_native_tests.rs',
            'rust/crates/bello-agent-app/src/mcp_inspector_controller_tests.rs',
            'rust/crates/bello-agent-core/src/mcp.rs',
            'rust/crates/bello-agent-core/src/mcp/outcome.rs',
            'rust/crates/bello-agent-core/src/mcp/tests.rs',
            'rust/crates/bello-agent-app/src/connection_settings_controller_tests.rs',
            'rust/crates/bello-agent-app/src/transcript_read_native_ui_tests.rs',
            'rust/crates/bello-agent-app/src/transcript_edit_native_ui_tests.rs',
        }
        for bridge_index, bridge in enumerate(report['baseline_bridges']):
            assert bridge['before_commit'] == previous
            current = bridge['after_commit']
            assert git('rev-list', '--parents', '-n', '1', current).decode().split() == [current, previous]
            for side, ref in (('before', previous), ('after', current)):
                assert git('rev-parse', ref + '^{tree}').decode().strip() == bridge[side + '_tree']
            current_sources = old if current == before else committed_sources(current)
            names = sorted(name for name in previous_sources.keys() | current_sources.keys()
                           if previous_sources.get(name) != current_sources.get(name))
            assert names == [entry['path'] for entry in bridge['files']]
            bridge_delta = dict.fromkeys(KEYS, 0)
            for entry in bridge['files']:
                name = entry['path']
                assert name in reviewed_paths
                text, categories = {}, {}
                for side, sources in (('before', previous_sources), ('after', current_sources)):
                    data = sources[name]
                    assert entry[side + '_source'] == source_manifest({name: data})[name]
                    text[side] = data.decode().splitlines()
                    categories[side] = line_categories(text[side], entry[side]['reviewed_support_ranges'], False)
                    assert nonblank(text[side]) == entry[side]['nonblank']
                    assert line_counts(text[side], categories[side]) == entry[side]['counts']
                origin = entry['before_classification_origin']
                if origin['kind'] == 'committed_ledger':
                    prior = committed_ledger(origin)
                    rows = [row for row in prior['files'] if row['path'] == name]
                    assert len(rows) == 1
                    assert rows[0][origin['side'] + '_blob'] == entry['before_source']['git_blob']
                    assert rows[0][origin['side']] == entry['before']
                else:
                    assert origin['kind'] == 'baseline_bridge'
                    assert 0 <= origin['bridge_index'] < bridge_index
                    prior = report['baseline_bridges'][origin['bridge_index']]
                    assert prior['after_commit'] == origin['commit']
                    rows = [row for row in prior['files'] if row['path'] == name]
                    assert len(rows) == 1
                    assert rows[0]['after_source']['git_blob'] == entry['before_source']['git_blob']
                    assert rows[0]['after'] == entry['before']
                anchors = entry.get('alignment_anchors', [])
                expected_anchors = ([{'before_line': 158, 'after_line': 158, 'source': '    }'}]
                                    if name == 'rust/crates/bello-agent-core/src/mcp/outcome.rs' else [])
                assert anchors == expected_anchors
                preserved, changed, change = diff_evidence(
                    text['before'], text['after'], categories['before'], categories['after'], anchors)
                assert preserved == entry['preserved_line_ranges']
                assert changed == entry['changed_line_spans']
                assert change == entry['delta']
                for key in KEYS:
                    bridge_delta[key] += change[key]
            assert bridge_delta == bridge['delta']
            assert baseline_counts == bridge['before_counts']
            baseline_counts = {key: baseline_counts[key] + bridge_delta[key] for key in KEYS}
            assert baseline_counts == bridge['after_counts']
            assert sum(baseline_counts.values()) == sum(nonblank(data.decode().splitlines()) for data in current_sources.values())
            evidence = bridge['review_document']
            evidence_data = git('show', f"{current}:{evidence['path']}")
            assert blob(evidence_data) == evidence['git_blob']
            assert sha256(evidence_data) == evidence['sha256']
            previous, previous_sources = current, current_sources
        assert previous == before
    else:
        # Candidate-1 report compatibility: the sole correction was all support.
        bridge_names = sorted(name for name in anchor_sources.keys() | old.keys()
                              if anchor_sources.get(name) != old.get(name))
        adjustments = report.get('baseline_adjustments', [])
        assert bridge_names == [entry['path'] for entry in adjustments]
        for adjustment in adjustments:
            name = adjustment['path']
            assert name == 'rust/crates/bello-agent-core/src/attachment_native_tests.rs'
            assert adjustment['classification'] == 'tests_and_test_support'
            for side, sources in (('before', anchor_sources), ('after', old)):
                data = sources[name]
                assert adjustment[side] == source_manifest({name: data})[name]
            amount = adjustment['after']['nonblank'] - adjustment['before']['nonblank']
            assert adjustment['delta'] == dict(zip(KEYS, (0, amount, 0)))
            baseline_counts['tests_and_test_support'] += amount
    assert baseline_counts == report['before_counts']
    changed_names = sorted(name for name in old.keys() | new.keys() if old.get(name) != new.get(name))
    assert changed_names == [entry['path'] for entry in report['files']]
    assert len(changed_names) == report['changed_rust_files']
    assert len(new) == report['rust_file_count']
    assert len(old.keys() & new.keys()) - sum(name in old and name in new for name in changed_names) == report['unchanged_rust_files']

    delta, preserved_counts = dict.fromkeys(KEYS, 0), dict.fromkeys(KEYS, 0)
    for entry in report['files']:
        name = entry['path']
        benchmark = '/benches/' in name or '/examples/' in name
        lines, categories = {}, {}
        for side, sources in (('before', old), ('after', new)):
            data = sources.get(name, b'')
            assert entry[side + '_blob'] == (blob(data) if name in sources else None)
            assert entry[side + '_sha256'] == (sha256(data) if name in sources else None)
            lines[side] = data.decode().splitlines()
            categories[side] = line_categories(lines[side], entry[side]['reviewed_support_ranges'], benchmark)
            assert nonblank(lines[side]) == entry[side]['nonblank']
            assert line_counts(lines[side], categories[side]) == entry[side]['counts']
        origin = entry['before_classification_origin']
        if origin['kind'] == 'committed_ledger':
            ledger = committed_ledger(origin)
            matches = [row for row in ledger['files'] if row['path'] == name]
            assert len(matches) == 1
            recorded = matches[0]
            side = origin['side']
            assert recorded[side + '_blob'] == entry['before_blob']
            assert recorded[side] == entry['before']
        elif origin['kind'] == 'baseline_bridge':
            bridge = report['baseline_bridges'][origin['bridge_index']]
            assert bridge['after_commit'] == origin['commit']
            rows = [row for row in bridge['files'] if row['path'] == name]
            assert len(rows) == 1
            assert rows[0]['after_source']['git_blob'] == entry['before_blob']
            assert rows[0]['after'] == entry['before']
        elif origin['kind'] == 'source_review':
            if name == 'rust/crates/bello-agent-core/src/instructions.rs':
                assert [(span['start'], span['end']) for span in entry['before']['reviewed_support_ranges']] == [(274, 289)]
                assert entry['before']['counts'] == dict(zip(KEYS, (262, 16, 0)))
            else:
                assert name in {
                    'rust/crates/bello-agent-core/src/read_synthetic_tests.rs',
                    'rust/crates/bello-agent-core/tests/production_tools.rs',
                }
                assert [(span['start'], span['end']) for span in entry['before']['reviewed_support_ranges']] == [(1, len(lines['before']))]
                assert entry['before']['counts'] == dict(zip(KEYS, (0, entry['before']['nonblank'], 0)))
        else:
            assert origin['kind'] == 'new_file' and name not in old
        preserved, spans, local_delta = diff_evidence(
            lines['before'], lines['after'], categories['before'], categories['after'])
        assert preserved == entry['preserved_line_ranges']
        assert spans == entry['changed_line_spans']
        assert local_delta == entry['delta']
        assert local_delta == {key: entry['after']['counts'][key] - entry['before']['counts'][key] for key in KEYS}
        for key in KEYS:
            delta[key] += local_delta[key]
            preserved_counts[key] += sum(span['nonblank_counts'][key] for span in preserved)
    assert delta == report['delta']
    slice_adjustment_delta = dict.fromkeys(KEYS, 0)
    for adjustment in report.get('slice_test_adjustments', []):
        name = adjustment['path']
        assert name == 'rust/crates/bello-agent-core/tests/project_skills_native.rs'
        assert adjustment['classification'] == 'tests_and_test_support'
        assert adjustment['before_source'] == report['candidate2']['rust_sources'][name]
        assert adjustment['after_source'] == new_manifest[name]
        amount = adjustment['after_source']['nonblank'] - adjustment['before_source']['nonblank']
        assert amount == 61
        assert adjustment['delta'] == dict(zip(KEYS, (0, amount, 0)))
        slice_adjustment_delta['tests_and_test_support'] += amount
    if 'candidate1' in report:
        assert delta == {key: report['candidate1']['skill_delta'][key] + slice_adjustment_delta[key]
                         for key in KEYS}, 'unrecorded change to skill-only category delta'
    if 'candidate2' in report:
        prior = report['candidate2']
        assert delta == {key: prior['skill_delta'][key] + slice_adjustment_delta[key] for key in KEYS}
        assert manifest_hash(prior['rust_sources']) == prior['source_manifest_sha256']
        changed = sorted(name for name in prior['rust_sources'].keys() | new_manifest.keys()
                         if prior['rust_sources'].get(name) != new_manifest.get(name))
        baseline_test_paths = sorted('rust/crates/bello-agent-app/src/' + name for name in (
            'connection_settings_controller_tests.rs', 'mcp_inspector_controller_tests.rs',
            'transcript_read_native_ui_tests.rs', 'transcript_edit_native_ui_tests.rs'))
        adjustment_paths = [entry['path'] for entry in report.get('slice_test_adjustments', [])]
        assert len(adjustment_paths) == len(set(adjustment_paths))
        expected = sorted(baseline_test_paths + adjustment_paths)
        assert changed == expected == prior['test_only_carry_paths']
        assert sum(new_manifest[name]['nonblank'] - prior['rust_sources'][name]['nonblank']
                   for name in baseline_test_paths) == 39
        assert sum(new_manifest[name]['nonblank'] - prior['rust_sources'][name]['nonblank']
                   for name in adjustment_paths) == slice_adjustment_delta['tests_and_test_support']
    assert preserved_counts == report['preserved_nonblank_counts_in_changed_files']
    counts = {key: report['before_counts'][key] + delta[key] for key in KEYS}
    assert counts == report['after_counts']
    for sources, expected in ((old_manifest, report['before_total']), (new_manifest, report['after_total'])):
        assert sum(entry['nonblank'] for entry in sources.values()) == expected
    assert sum(report['before_counts'].values()) == report['before_total']
    assert sum(counts.values()) == report['after_total']
    print(json.dumps({
        'after': after_identity, 'ledger_status': report['checkpoint_status'],
        'source_manifest_sha256': report['after_source_manifest_sha256'],
        'baseline': before, 'delta': delta, 'counts': counts,
        'total': report['after_total'], 'rust_files': len(new),
        'preserved_nonblank_lines_verified': sum(preserved_counts.values()),
        'unchanged_rust_files': report['unchanged_rust_files'],
        'publication_commit_recorded_in_ledger': report['publication_commit'],
    }, indent=2))


if __name__ == '__main__':
    main()
