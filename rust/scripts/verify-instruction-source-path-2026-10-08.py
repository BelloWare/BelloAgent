#!/usr/bin/env python3
"""Verify the additive instruction-path source freeze without changing Git or files.

The default check is scoped so independent catalog changes can be integrated.
Use --strict-tree for the isolated candidate's complete owned Rust source tree.
"""
import argparse, hashlib, json, subprocess
from pathlib import Path
BASE = '8914fd798e30750a0bd07c209d36138397b9ec4a'
TREE = '1770c0b10103a773573bfef867fc1cd98f1758d5'
MANIFEST_SHA = '626c8852bd2cb61900b34185cb984a1c9d43559000bc09b575ef3f8f075f5c58'
CATEGORIES = ['production', 'tests_and_test_support', 'benchmark_example']

def need(ok, message):
    if not ok:
        raise ValueError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])

def identity(data):
    if data is None:
        return None
    return {'sha256': sha(data), 'git_blob': hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest(), 'bytes': len(data)}

def categories(path, data):
    lines = data.decode().splitlines()
    if not path.endswith('.rs'):
        return []
    if path.endswith('/instructions.rs'):
        boundary = lines.index('#[cfg(test)]')
        return ['production' if n < boundary else 'tests_and_test_support' for n in range(len(lines))]
    if path.endswith('/project_resources.rs'):
        result = ['production'] * len(lines)
        for n, line in enumerate(lines):
            if line in ['#[cfg(test)]', '#[cfg(all(test, unix))]']:
                need(lines[n + 1].startswith('mod '), 'Unexpected test module')
                result[n:n + 2] = ['tests_and_test_support'] * 2
        return result
    if path.endswith('/source_path.rs'):
        return ['production'] * len(lines)
    return ['tests_and_test_support'] * len(lines)

def spans(kinds):
    result = []
    for n, kind in enumerate(kinds, 1):
        if not result or kind != result[-1]['category']:
            result.append({'start': n, 'end': n, 'category': kind})
        else:
            result[-1]['end'] = n
    return result

def counts(data, kinds):
    return {k: sum(bool(line.strip()) and kind == k for line, kind in zip(data.decode().splitlines(), kinds)) for k in CATEGORIES}

def verify(repo, root, manifest, strict):
    need(sha(manifest) == MANIFEST_SHA, 'Manifest bytes differ from the frozen review')
    value = json.loads(manifest)
    need(value['baseline_commit'] == BASE and value['baseline_tree'] == TREE, 'Baseline changed')
    need(git(repo, 'rev-parse', BASE + '^{tree}').decode().strip() == TREE, 'Baseline Git tree changed')
    names = set(git(repo, 'ls-tree', '-r', '--name-only', BASE).decode().splitlines())
    delta = dict.fromkeys(CATEGORIES, 0)
    owned = set()
    preserved = 0
    for entry in value['files']:
        path = entry['path']
        need(path not in owned and path.startswith('rust/crates/bello-agent-core/'), 'Invalid/duplicate source path')
        owned.add(path)
        before = git(repo, 'show', BASE + ':' + path) if path in names else None
        current = root / path
        need(current.is_file() and not current.is_symlink(), 'Missing/nonregular source: ' + path)
        after = current.read_bytes()
        need(identity(before) == entry['before'], 'Preimage changed: ' + path)
        need(identity(after) == entry['after'], 'Afterimage changed: ' + path)
        bk, ak = categories(path, before or b''), categories(path, after)
        need(spans(bk) == entry['before_spans'] and spans(ak) == entry['after_spans'], 'Classification spans changed: ' + path)
        bc, ac = counts(before or b'', bk), counts(after, ak)
        need(bc == entry['before_counts'] and ac == entry['after_counts'], 'Counts changed: ' + path)
        diff = {k: ac[k] - bc[k] for k in CATEGORIES}
        need(diff == entry['delta'], 'Delta changed: ' + path)
        for k in CATEGORIES:
            delta[k] += diff[k]
        old_lines, new_lines = (before or b'').decode().splitlines(), after.decode().splitlines()
        for span in entry['preserved_spans']:
            a, b, length = span['before_start'] - 1, span['after_start'] - 1, span['length']
            need(old_lines[a:a + length] == new_lines[b:b + length], 'Preserved source span changed: ' + path)
            if path.endswith('.rs'):
                need(bk[a:a + length] == ak[b:b + length], 'Preserved lines reclassified: ' + path)
                preserved += sum(bool(line.strip()) for line in new_lines[b:b + length])
    need(delta == value['delta'], 'Category delta changed')
    need(preserved == value['preserved_nonblank_rust_lines'], 'Preserved count changed')
    totals = {k: value['baseline_counts'][k] + delta[k] for k in CATEGORIES}
    need(totals == value['counts_with_this_patch_only'], 'Total categories changed')
    need(sum(totals.values()) == value['total_with_this_patch_only'], 'Physical total changed')
    for path, expected in value['sealed_prior_evidence_sha256'].items():
        need(sha(git(repo, 'show', BASE + ':' + path)) == expected, 'Prior evidence preimage changed: ' + path)
        need(sha((root / path).read_bytes()) == expected, 'Prior evidence was rewritten: ' + path)
    if strict:
        rust_names = {p for p in names if p.startswith('rust/') and p.endswith('.rs')}
        current_names = {p.relative_to(root).as_posix() for p in (root / 'rust').rglob('*.rs') if '/target/' not in p.as_posix()}
        need(current_names == rust_names | {p for p in owned if p.endswith('.rs')}, 'Unexpected/missing Rust source')
        for path in rust_names - owned:
            need((root / path).read_bytes() == git(repo, 'show', BASE + ':' + path), 'Unrelated Rust source changed: ' + path)
        need(len(current_names) == value['rust_file_counts']['after'], 'Rust file count changed')
        need(sum(sum(bool(line.strip()) for line in (root / p).read_bytes().splitlines()) for p in current_names) == value['total_with_this_patch_only'], 'Whole-tree Rust count changed')
    return {'result': 'passed', 'baseline': BASE, 'delta': delta, 'counts_with_this_patch_only': totals, 'strict_owned_rust_tree': strict, 'prior_sealed_evidence_unchanged': True, 'native_acceptance': False, 'publication_verified': False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parent.parent / 'docs/validation/instruction-source-path-2026-10-08/source-loc.json')
    parser.add_argument('--strict-tree', action='store_true')
    args = parser.parse_args()
    print(json.dumps(verify(args.repo, args.source_root, args.manifest.read_bytes(), args.strict_tree), indent=2))

if __name__ == '__main__':
    main()
