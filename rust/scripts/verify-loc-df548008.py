#!/usr/bin/env python3
"""Read-only LOC delta for the published df548008 checkpoint.

Reads immutable Git objects. No build, checkout, source edit, commit or publish.
This is a reviewed-span delta over audited counts, not a fresh full classifier.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = 'f443882dde2f7d917f3aed6d44bc93d1b35e1a36'
BEFORE = '88a0ddbb762703c47010f3eb2e537aa1eb0a3d71'
BEFORE_TREE = '96d1557fa0437f58bf7734f9d6ba16a0c8485d1f'
AFTER = 'df548008411b602e19ad2c3ac466a7a469ff6ae5'
AFTER_TREE = '39de1c4d8847ca337c0013a80ece00bb760cf181'
KEYS = ('production', 'tests_and_test_support', 'benchmark_example')
BASE = dict(zip(KEYS, (22009, 32613, 1184)))
PUBLIC_BASE = dict(zip(KEYS, (21870, 30296, 1184)))
APP = 'rust/crates/bello-agent-app/src/'
CORE = 'rust/crates/bello-agent-core/src/'
NEW_MODULES = {APP + 'context_inspector.rs', CORE + 'context_preview.rs'}
NEW_SUPPORT = {APP + 'context_inspector_tests.rs', CORE + 'context_preview_tests.rs'}
MIXED = {
    APP + 'chat_navigation.rs', APP + 'main.rs', CORE + 'provider.rs',
    CORE + 'runtime.rs', CORE + 'session.rs', CORE + 'tool_runtime.rs',
}
# Explicit source-reviewed positive cfg spans; one-based inclusive boundaries.
SUPPORT = {
    APP + 'context_inspector.rs': [(832, 834, 'cfg(test) tail declaration')],
    CORE + 'context_preview.rs': [
        (84, 89, 'synthetic-authority guard in prepare_context'),
        (337, 339, 'cfg(test) tail declaration'),
    ],
}
# Only changed lines in these bounds are classified. Existing support elsewhere
# retains its inherited classification. Empty sides of insertions are ignored.
PRODUCTION_CHANGE_BOUNDS = {
    APP + 'chat_navigation.rs': ((925, 935), (925, 936)),
    APP + 'main.rs': ((1, 2540), (1, 2561)),
    CORE + 'provider.rs': ((1, 384), (1, 419)),
    CORE + 'runtime.rs': ((1, 15), (1, 19)),
    CORE + 'session.rs': ((1057, 1064), (1057, 1068)),
    CORE + 'tool_runtime.rs': ((26, 311), (26, 321)),
}
NOTE = (
    'Preserves the prior positive-cfg-span convention: support begins at the '
    'cfg attribute. The new Context modules are production except their '
    'cfg(test) tails and context_preview.rs lines 84-89, the new positive '
    'synthetic-authority guard. The three comments before that guard, lines '
    '81-83, stay production. Both Context _tests.rs files are wholly support. '
    'The four synthetic-only runtime files already counted in the parent are '
    'unchanged and retain inherited support classification. All changed lines '
    'in existing files are reviewed production code or declarations. Platform '
    'gates and unchanged source are not reclassified. Public commit/tree identities '
    'are verified before counting.'
)


def nb(lines):
    return sum(bool(line.strip()) for line in lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--output-dir', type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()

    def git(*words):
        return subprocess.check_output(['git', '-C', str(args.repo), *words])

    def files(ref):
        result = {}
        for row in git('ls-tree', '-r', ref, '--', 'rust/').decode().splitlines():
            metadata, path = row.split('\t', 1)
            if path.endswith('.rs'):
                result[path] = metadata.split()[2]
        return result

    def source(ref, path):
        return git('show', f'{ref}:{path}').decode().splitlines()

    assert git('rev-parse', AFTER + '^{tree}').decode().strip() == AFTER_TREE
    assert git('rev-parse', BEFORE + '^{tree}').decode().strip() == BEFORE_TREE
    assert git('rev-list', '--parents', '-n', '1', AFTER).decode().split() == [AFTER, BEFORE]
    old_blobs, new_blobs = files(BEFORE), files(AFTER)
    changed = sorted(p for p in old_blobs.keys() | new_blobs.keys()
                     if old_blobs.get(p) != new_blobs.get(p))
    assert changed == sorted(NEW_MODULES | NEW_SUPPORT | MIXED), changed
    assert new_blobs.keys() - old_blobs.keys() == NEW_MODULES | NEW_SUPPORT
    assert old_blobs.keys() <= new_blobs.keys()
    old = {p: source(BEFORE, p) for p in old_blobs}
    new = {p: source(AFTER, p) for p in new_blobs}
    before_total = sum(nb(lines) for lines in old.values())
    public_total = sum(nb(source(PUBLIC, p)) for p in files(PUBLIC))
    assert before_total == sum(BASE.values()) == 55806
    assert public_total == sum(PUBLIC_BASE.values()) == 53350

    # Verify production module ownership and exact cfg tails from immutable text.
    assert new[APP + 'main.rs'][4:7] == [
        'mod chat_tool_mode;', 'mod context_inspector;', 'mod draft_status;']
    assert new[CORE + 'runtime.rs'][14:18] == [
        '#[path = "context_preview.rs"]', 'mod context_preview;',
        'pub use context_preview::{ContextPreview, ContextPreviewMetadata, ContextPreviewMode};', '']
    for path in NEW_MODULES:
        start, end, _ = SUPPORT[path][-1]
        assert end == len(new[path])
        assert new[path][start - 1:end] == [
            '#[cfg(test)]', f'#[path = "{Path(path).stem}_tests.rs"]', 'mod tests;']
    assert [(i + 1, line.strip()) for i, line in enumerate(new[APP + 'context_inspector.rs'])
            if '#[cfg(' in line] == [(832, '#[cfg(test)]')]
    preview = new[CORE + 'context_preview.rs']
    assert [(i + 1, line.strip()) for i, line in enumerate(preview) if '#[cfg(' in line] == [
        (84, '#[cfg(feature = "synthetic-authority")]'), (337, '#[cfg(test)]')]
    assert preview[80:89] == [
        '        // The synthetic delivery path resolves instructions per turn. Its',
        '        // lifetime-fixed options cannot truthfully describe that request, and',
        '        // read-only inspection must not silently discover fresh resources.',
        '        #[cfg(feature = "synthetic-authority")]',
        '        if self.resources.is_some() {',
        '            return Err(invalid(',
        '                "Context inspection is not yet available for synthetic resource runtimes",',
        '            ));', '        }',
    ]

    # Exact published tree identity above replaces unavailable local-fork refs.
    inherited_synthetic = {}
    for name in ('resource_runtime.rs', 'resource_runtime_tests.rs',
                 'synthetic_project_runtime.rs', 'synthetic_project_runtime_tests.rs'):
        path = CORE + name
        assert old_blobs[path] == new_blobs[path]
        inherited_synthetic[path] = {'blob': new_blobs[path], 'nonblank': nb(new[path]),
                                    'classification': 'tests_and_test_support'}
    assert sum(x['nonblank'] for x in inherited_synthetic.values()) == 2229
    assert new[CORE + 'lib.rs'][10:12] == [
        '#[cfg(feature = "synthetic-authority")]', 'pub mod synthetic_project_runtime;']
    assert new[CORE + 'runtime.rs'][8:13] == old[CORE + 'runtime.rs'][8:13]

    ledger, flat_spans = [], []
    for path in changed:
        before, after = old.get(path, []), new[path]
        ranges = ([(1, len(after), 'entire file inherits cfg(test) owner')]
                  if path in NEW_SUPPORT else SUPPORT.get(path, []))
        support_lines = {i for start, end, _ in ranges for i in range(start, end + 1)}
        assert len(support_lines) == sum(end - start + 1 for start, end, _ in ranges)
        delta = dict.fromkeys(KEYS, 0)
        spans, added_lines = [], set()
        for tag, i, j, k, l in difflib.SequenceMatcher(a=before, b=after, autojunk=False).get_opcodes():
            if tag == 'equal':
                continue
            added_lines.update(range(k + 1, l + 1))
            for side, lines, start, end, sign in (
                ('before', before, i, j, -1), ('after', after, k, l, 1),
            ):
                if start < end and path in MIXED:
                    lower, upper = PRODUCTION_CHANGE_BOUNDS[path][0 if side == 'before' else 1]
                    assert lower <= start + 1 <= end <= upper, (path, side, start + 1, end)
                cursor = start
                while cursor < end:
                    category = ('tests_and_test_support'
                                if side == 'after' and cursor + 1 in support_lines else 'production')
                    stop = cursor + 1
                    while stop < end:
                        candidate = ('tests_and_test_support'
                                     if side == 'after' and stop + 1 in support_lines else 'production')
                        if candidate != category:
                            break
                        stop += 1
                    count = nb(lines[cursor:stop])
                    delta[category] += sign * count
                    span = {
                        'operation': tag, 'side': side, 'start_line': cursor + 1,
                        'end_line': stop, 'classification': category, 'nonblank': count,
                        'signed_delta': sign * count, 'source': lines[cursor:stop],
                    }
                    spans.append(span)
                    flat_spans.append({'path': path, **span})
                    cursor = stop
        assert all(i in added_lines for i in support_lines if after[i - 1].strip())
        assert delta['tests_and_test_support'] == sum(nb(after[s - 1:e]) for s, e, _ in ranges)
        assert sum(delta.values()) == nb(after) - nb(before)
        ledger.append({
            'path': path, 'before_blob': old_blobs.get(path), 'after_blob': new_blobs[path],
            'after_sha256': hashlib.sha256(git('show', f'{AFTER}:{path}')).hexdigest(),
            'before_nonblank': nb(before), 'after_nonblank': nb(after), 'category_delta': delta,
            'reviewed_support_ranges': [
                {'start_line': s, 'end_line': e, 'nonblank': nb(after[s - 1:e]), 'reason': reason}
                for s, e, reason in ranges
            ],
            'reviewed_production_change_bounds': PRODUCTION_CHANGE_BOUNDS.get(path),
            'changed_line_spans': spans,
        })
    delta = {key: sum(entry['category_delta'][key] for entry in ledger) for key in KEYS}
    assert delta == dict(zip(KEYS, (1184, 1370, 0))), delta
    counts = {key: BASE[key] + delta[key] for key in KEYS}
    total = sum(nb(lines) for lines in new.values())
    assert sum(counts.values()) == total == 58360
    report = {
        'method': 'Immutable Git-object delta over audited parent; source-reviewed explicit spans, not a fresh full category counter or sum of branches',
        'scope': 'Tracked rust/**/*.rs; nonblank physical lines including comments',
        'before_commit': BEFORE, 'before_tree': BEFORE_TREE, 'before_counts': BASE,
        'after_commit': AFTER, 'after_tree': AFTER_TREE,
        'checkpoint_status': 'published and remote tree verified',
        'category_delta': delta, 'after_counts': counts,
        'public_baseline_commit': PUBLIC, 'public_baseline_counts': PUBLIC_BASE,
        'delta_from_public_baseline': {key: counts[key] - PUBLIC_BASE[key] for key in KEYS},
        'public_nonblank_independently_recounted': public_total,
        'before_nonblank_independently_recounted': before_total,
        'after_nonblank_independently_recounted': total,
        'rust_file_count': len(new), 'changed_rust_blob_count': len(changed),
        'unchanged_rust_blob_count': sum(old_blobs.get(p) == new_blobs[p] for p in new_blobs),
        'classification_note': NOTE,
        'inherited_unchanged_synthetic_support': inherited_synthetic,
        'files': ledger,
        'all_rust_blobs': [
            {'path': p, 'before_blob': old_blobs.get(p), 'after_blob': new_blobs[p]}
            for p in sorted(new_blobs)
        ],
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    stem = args.output_dir / 'loc-df548008'
    stem.with_name(stem.name + '-delta.json').write_text(json.dumps(report, indent=2) + '\n')
    with stem.with_name(stem.name + '-spans.tsv').open('w') as f:
        fields = ('path', 'operation', 'side', 'start_line', 'end_line', 'classification', 'nonblank', 'signed_delta')
        f.write('\t'.join(fields) + '\n')
        for span in flat_spans:
            f.write('\t'.join(str(span[key]) for key in fields) + '\n')
    print(json.dumps({k: v for k, v in report.items()
                      if k not in ('files', 'all_rust_blobs', 'inherited_unchanged_synthetic_support')}, indent=2))


if __name__ == '__main__':
    main()
