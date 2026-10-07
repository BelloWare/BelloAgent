#!/usr/bin/env python3
"""Verify the frozen Bash LOC delta using only Python stdlib and read-only Git.

Requires a repository containing the reviewed Skills baseline tree. The original
local unpublished commit is NOT required: --baseline-ref may name any revision
resolving to BASE_TREE, and defaults to that immutable tree ID. No checkout,
fetch, build, Cargo, source write, Git-state write, or third-party package is used.

Counts inherit the exact immutable Skills ledger; they are not a Rust parser or
feature-completeness measure. The prior Skills verifier was separately rerun at
audit time, with its exact script, ledger, and result supplied alongside this file.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
KEYS = ('production', 'tests_and_test_support', 'benchmark_example')
BASE_COMMIT = 'b44e47c9a4ad882431c567889df72c35fe574da8'
BASE_TREE = 'e41551e2cdc390c040820870eede7fdd2d4363ce'
FREEZE_SHA = '0129e22e28ac05f2c610804dc6d1bdde366f98ff4e2d6243addcdfc4dca546e4'
RANGES_SHA = '3b0a91118e7132009370107864157439bfcb9f1ca244ba5e16ec4977a9afe411'
BASE_LEDGER_SHA = 'e530726af07bee1382e9b545076d15200e16b6f382d9380b028a944a6604f203'
BASE_VERIFIER_SHA = 'e244dc2bc2d881903992e952c28075290a7c9a543a6f5a0c8cf659cadb648e75'
BASE_MANIFEST_SHA = 'd5402de8e36c31ae70d245e78624dc3ca9efa7bf9ddb7d110f8eeac259f8d9f4'
AFTER_MANIFEST_SHA = '74fcbe4cfd34dfce465afdf088c2e92576c5b263efa224f7bdaa5a17b8c5079e'

class VerificationError(Exception):
    pass

def require(condition, message):
    if not condition:
        raise VerificationError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

def nonblank(lines):
    return sum(bool(line.strip()) for line in lines)

def source_manifest(sources):
    return {p: {'git_blob': blob(b), 'sha256': sha(b),
                'nonblank': nonblank(b.decode('utf-8').splitlines())}
            for p, b in sorted(sources.items())}

def manifest_hash(manifest):
    return sha(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode())

def read_git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    return subprocess.check_output(['git', '-C', str(repo), *args], env=env)

def git_sources(repo, ref):
    result = {}
    for row in read_git(repo, 'ls-tree', '-rz', ref).split(b'\0'):
        if not row:
            continue
        metadata, name = row.split(b'\t', 1)
        mode, kind, oid = metadata.decode().split()
        name = name.decode('utf-8')
        require(kind == 'blob', 'non-blob baseline entry: ' + name)
        data = read_git(repo, 'cat-file', 'blob', oid)
        require(blob(data) == oid, 'Git blob mismatch: ' + name)
        result[name] = data
    return result

def directory_sources(root):
    sources, ignored_cache = {}, {}
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in ('.git', 'target'))
        for filename in sorted(files):
            path = Path(directory) / filename
            rel = path.relative_to(root)
            require(not path.is_symlink(), 'unexpected source symlink: ' + rel.as_posix())
            data = path.read_bytes()
            if '__pycache__' in rel.parts and rel.suffix == '.pyc':
                ignored_cache[rel.as_posix()] = sha(data)
            else:
                sources[rel.as_posix()] = data
    return sources, ignored_cache

def rust_only(sources):
    return {p: b for p, b in sources.items() if p.startswith('rust/') and p.endswith('.rs')}

def categories(lines, ranges, benchmark=False):
    support = set()
    for span in ranges:
        a, b = span['start'], span['end']
        require(1 <= a <= b <= len(lines), 'invalid support range')
        require(lines[a-1] == span['start_text'], 'support start anchor mismatch')
        require(lines[b-1] == span['end_text'], 'support end anchor mismatch')
        numbers = set(range(a, b+1))
        require(not numbers & support, 'overlapping support ranges')
        support.update(numbers)
    return [('benchmark_example' if benchmark else 'tests_and_test_support'
             if n in support else 'production') for n in range(1, len(lines)+1)]

def line_counts(lines, labels):
    require(len(lines) == len(labels), 'line/category length mismatch')
    counts = dict.fromkeys(KEYS, 0)
    for line, label in zip(lines, labels):
        require(label in counts, 'unknown line category')
        if line.strip():
            counts[label] += 1
    return counts

def diff_evidence(before, after, old_labels, new_labels):
    preserved, changed = [], []
    delta = dict.fromkeys(KEYS, 0)
    for tag, a, b, c, d in difflib.SequenceMatcher(a=before, b=after, autojunk=False).get_opcodes():
        if tag == 'equal':
            for i, j in zip(range(a, b), range(c, d)):
                require(not before[i].strip() or old_labels[i] == new_labels[j],
                        'unchanged nonblank line reclassified')
            preserved.append({'before_start': a+1, 'after_start': c+1, 'line_count': b-a,
                              'nonblank_counts': line_counts(before[a:b], old_labels[a:b]),
                              'source_sha256': sha('\n'.join(before[a:b]).encode())})
        else:
            for side, lines, labels, start, stop, sign in (
                    ('before', before, old_labels, a, b, -1),
                    ('after', after, new_labels, c, d, 1)):
                cursor = start
                while cursor < stop:
                    label = labels[cursor]
                    end = cursor+1
                    while end < stop and labels[end] == label:
                        end += 1
                    count = nonblank(lines[cursor:end])
                    delta[label] += sign*count
                    changed.append({'operation': tag, 'side': side, 'start': cursor+1,
                                    'end': end, 'classification': label, 'nonblank': count,
                                    'signed_delta': sign*count,
                                    'source_sha256': sha('\n'.join(lines[cursor:end]).encode())})
                    cursor = end
    return preserved, changed, delta

def verify_sources(freeze, old_all, new_all):
    require({p: sha(b) for p, b in old_all.items()} == freeze['baseline_files'],
            'baseline full-source manifest differs')
    require({p: sha(b) for p, b in new_all.items()} == freeze['all_files'],
            'candidate full-source manifest differs (source changed, missing, or extra file)')
    changed = {p: sha(new_all[p]) if p in new_all else None
               for p in old_all.keys() | new_all.keys() if old_all.get(p) != new_all.get(p)}
    require(changed == freeze['changed_files'], 'changed-file set differs from freeze')
    require(len(changed) == 25, 'unexpected changed-file count')

def verify_ledger(report, freeze, ranges, old_all, new_all):
    require(report['before_commit'] == BASE_COMMIT and report['before_tree'] == BASE_TREE,
            'original local baseline metadata differs')
    require(report['publication_commit'] is None and report['baseline_publication_commit'] is None,
            'this frozen audit cannot establish publication')
    require(report['checkpoint_status'] == 'source_frozen_baseline_and_bash_publication_pending',
            'checkpoint status differs')
    require(freeze['baseline_commit'] == BASE_COMMIT and freeze['baseline_tree'] == BASE_TREE,
            'freeze baseline metadata differs')
    require(freeze['baseline_published'] is False, 'freeze publication status differs')
    require(report['candidate_freeze'] == {'filename': 'agent-shell-rebased-files.json',
            'sha256': FREEZE_SHA, 'rust_files': 197, 'changed_files': 25}, 'freeze reference differs')
    old, new = rust_only(old_all), rust_only(new_all)
    old_manifest, new_manifest = source_manifest(old), source_manifest(new)
    require(old_manifest == report['before_rust_sources'], 'before Rust manifest differs')
    require(new_manifest == report['after_rust_sources'], 'after Rust manifest differs')
    require(manifest_hash(old_manifest) == report['before_source_manifest_sha256'] == BASE_MANIFEST_SHA,
            'before Rust manifest digest differs')
    require(manifest_hash(new_manifest) == report['after_source_manifest_sha256'] == AFTER_MANIFEST_SHA,
            'after Rust manifest digest differs')

    def committed_ledger(origin):
        path = origin['path']
        require(path in old_all, 'missing committed ledger: ' + path)
        data = old_all[path]
        require(blob(data) == origin['git_blob'] and sha(data) == origin['sha256'],
                'committed ledger identity differs: ' + path)
        return json.loads(data)

    expected_exceptions = {
        'rust/crates/bello-agent-core/src/attachment_runtime.rs': (263, 268),
        'rust/crates/bello-agent-core/src/tools/attachment_images.rs': (37, 54),
    }
    exceptions = report['inherited_synthetic_fixture_exceptions']
    require({e['path'] for e in exceptions} == set(expected_exceptions) and len(exceptions) == 2,
            'inherited exception identity set differs')
    for exception in exceptions:
        name = exception['path']; data = old_all[name]
        require(data == new_all[name], 'inherited fixture exception source changed')
        require(blob(data) == exception['git_blob'] and sha(data) == exception['sha256'],
                'inherited fixture source hash differs')
        a, b = expected_exceptions[name]
        require((exception['range']['start'], exception['range']['end']) == (a, b),
                'inherited fixture range differs')
        lines = data.decode().splitlines()[a-1:b]
        require(nonblank(lines) == exception['nonblank'] and
                sha('\n'.join(lines).encode()) == exception['range_source_sha256'],
                'inherited fixture range content differs')
        origin = exception['classification_origin']; prior = committed_ledger(origin)
        rows = [row for row in prior['files'] if row['path'] == name]
        require(len(rows) == 1 and rows[0][origin['side']+'_blob'] == blob(data),
                'inherited fixture exact-blob provenance differs')
        require(exception['range'] in rows[0][origin['side']]['reviewed_support_ranges'] and
                exception['classification'] == 'tests_and_test_support',
                'inherited fixture classification differs')

    base = committed_ledger(report['baseline_ledger'])
    require(report['baseline_ledger']['sha256'] == BASE_LEDGER_SHA, 'baseline ledger digest differs')
    require(base['after_rust_sources'] == old_manifest, 'Skills baseline source manifest differs')
    require(base['after_source_manifest_sha256'] == BASE_MANIFEST_SHA, 'Skills manifest digest differs')
    require(base['after_counts'] == report['before_counts'] == dict(zip(KEYS, (42590,56228,1192))),
            'Skills baseline category totals differ')
    require(base['after_total'] == report['before_total'] == 100010, 'Skills baseline total differs')
    verifier = report['baseline_verifier']; verifier_data = old_all[verifier['path']]
    require(blob(verifier_data) == verifier['git_blob'] and sha(verifier_data) == verifier['sha256'] == BASE_VERIFIER_SHA,
            'Skills verifier identity differs')
    changed_names = sorted(p for p in old.keys() | new.keys() if old.get(p) != new.get(p))
    require(changed_names == [e['path'] for e in report['files']], 'Rust delta file set differs')
    require(set(ranges) == set(changed_names), 'reviewed span path set differs')
    require(len(changed_names) == report['changed_rust_files'] == 21, 'Rust delta file count differs')
    require(len(new) == report['rust_file_count'] == 197, 'Rust source count differs')
    unchanged = len(old.keys() & new.keys()) - sum(p in old and p in new for p in changed_names)
    require(unchanged == report['unchanged_rust_files'] == 176, 'unchanged Rust count differs')
    require(report['inherited_classification_adjustments'] == [], 'unexpected inherited reclassification')
    require(report['uncertain_classifications'] == [], 'uncertain classification added')
    delta, preserved_counts = dict.fromkeys(KEYS, 0), dict.fromkeys(KEYS, 0)
    for entry in report['files']:
        name = entry['path']; text, labels = {}, {}
        benchmark = '/benches/' in name or '/examples/' in name
        for side, sources in (('before', old), ('after', new)):
            data = sources.get(name, b'')
            require(entry[side+'_blob'] == (blob(data) if name in sources else None), 'blob differs: '+name)
            require(entry[side+'_sha256'] == (sha(data) if name in sources else None), 'SHA-256 differs: '+name)
            text[side] = data.decode().splitlines()
            labels[side] = categories(text[side], entry[side]['reviewed_support_ranges'], benchmark)
            require(nonblank(text[side]) == entry[side]['nonblank'], 'nonblank count differs: '+name)
            require(line_counts(text[side], labels[side]) == entry[side]['counts'], 'category counts differ: '+name)
        expected_ranges = [{'start': a, 'end': b, 'reason': reason,
                            'start_text': text['after'][a-1], 'end_text': text['after'][b-1]}
                           for a, b, reason in sorted(ranges[name])]
        require(expected_ranges == entry['after']['reviewed_support_ranges'], 'reviewed support spans differ: '+name)
        origin = entry['before_classification_origin']
        if origin['kind'] == 'committed_ledger':
            prior = committed_ledger(origin)
            rows = [row for row in prior['files'] if row['path'] == name]
            require(len(rows) == 1, 'ambiguous prior classification: '+name)
            prior_entry, side = rows[0], origin['side']
            require(prior_entry[side+'_blob'] == entry['before_blob'], 'prior exact blob differs: '+name)
            require(prior_entry[side] == entry['before'], 'inherited classification differs: '+name)
        else:
            require(origin['kind'] == 'new_file' and name not in old, 'invalid new-file origin: '+name)
            require(entry['before'] == {'nonblank':0, 'counts':dict.fromkeys(KEYS,0),
                                       'reviewed_support_ranges':[]}, 'new file has before counts')
        preserved, changed, change = diff_evidence(text['before'], text['after'], labels['before'], labels['after'])
        require(preserved == entry['preserved_line_ranges'], 'preserved-line evidence differs: '+name)
        require(changed == entry['changed_line_spans'], 'changed-span evidence differs: '+name)
        require(change == entry['delta'], 'per-file delta differs: '+name)
        require(change == {k: entry['after']['counts'][k]-entry['before']['counts'][k] for k in KEYS},
                'category delta does not reconcile: '+name)
        for k in KEYS:
            delta[k] += change[k]
            preserved_counts[k] += sum(s['nonblank_counts'][k] for s in preserved)
    require(delta == report['delta'] == dict(zip(KEYS, (980,1824,0))), 'aggregate delta differs')
    require(preserved_counts == report['preserved_nonblank_counts_in_changed_files'], 'preserved totals differ')
    counts = {k: report['before_counts'][k]+delta[k] for k in KEYS}
    require(counts == report['after_counts'] == dict(zip(KEYS, (43570,58052,1192))), 'after totals differ')
    for manifest, total in ((old_manifest, report['before_total']), (new_manifest, report['after_total'])):
        require(sum(v['nonblank'] for v in manifest.values()) == total, 'total does not match source bytes')
    require(sum(report['before_counts'].values()) == report['before_total'], 'before category sum differs')
    require(sum(counts.values()) == report['after_total'] == 102814, 'after category sum differs')
    non_rust_names = sorted(p for p in freeze['changed_files'] if not p.endswith('.rs'))
    require(non_rust_names == [e['path'] for e in report['non_rust_changed_files']], 'non-Rust set differs')
    for entry in report['non_rust_changed_files']:
        name = entry['path']
        for side, sources in (('before', old_all), ('after', new_all)):
            require(entry[side+'_blob'] == (blob(sources[name]) if name in sources else None), 'non-Rust blob differs')
            require(entry[side+'_sha256'] == (sha(sources[name]) if name in sources else None), 'non-Rust SHA differs')
        require(entry['outside_rust_loc'] is True, 'non-Rust file counted')
    return {'delta':delta, 'counts':counts, 'total':report['after_total'],
            'rust_files':len(new), 'changed_rust_files':len(changed_names),
            'unchanged_rust_files':unchanged, 'preserved_nonblank_counts':preserved_counts,
            'preserved_nonblank_lines_verified':sum(preserved_counts.values()),
            'baseline_source_manifest_sha256':BASE_MANIFEST_SHA,
            'candidate_source_manifest_sha256':AFTER_MANIFEST_SHA}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, help='Frozen candidate directory; required unless --after is used')
    parser.add_argument('--after', help='Optional exact candidate Git revision instead of directory; does not prove remote publication')
    parser.add_argument('--baseline-ref', default=BASE_TREE, help='Any revision resolving to the exact reviewed baseline tree')
    parser.add_argument('--report', type=Path, default=HERE/'loc-bash-workflow-2026-10-07-delta.json')
    parser.add_argument('--freeze', type=Path, default=HERE/'agent-shell-rebased-files.json')
    parser.add_argument('--ranges', type=Path, default=HERE/'reviewed-support-ranges.json')
    args = parser.parse_args()
    require(bool(args.source_root) != bool(args.after), 'choose exactly one of --source-root or --after')
    tree = read_git(args.repo, 'rev-parse', '--verify', args.baseline_ref+'^{tree}').decode().strip()
    require(tree == BASE_TREE, 'baseline revision does not resolve to the reviewed tree')
    freeze_bytes, ranges_bytes = args.freeze.read_bytes(), args.ranges.read_bytes()
    require(sha(freeze_bytes) == FREEZE_SHA, 'freeze digest differs')
    require(sha(ranges_bytes) == RANGES_SHA, 'reviewed span registry digest differs')
    freeze, ranges, report = json.loads(freeze_bytes), json.loads(ranges_bytes), json.loads(args.report.read_bytes())
    old_all = git_sources(args.repo, tree)
    if args.after:
        after_tree = read_git(args.repo, 'rev-parse', '--verify', args.after+'^{tree}').decode().strip()
        new_all, ignored = git_sources(args.repo, after_tree), {}
        candidate_identity = {'revision':args.after, 'tree':after_tree}
    else:
        new_all, ignored = directory_sources(args.source_root)
        candidate_identity = {'kind':'source_manifest_only', 'publication_verified':False}
    verify_sources(freeze, old_all, new_all)
    result = verify_ledger(report, freeze, ranges, old_all, new_all)
    result.update({'status':'PASS', 'baseline_input':args.baseline_ref, 'baseline_tree':tree,
                   'original_local_unpublished_baseline_commit':BASE_COMMIT,
                   'baseline_publication_verified':False, 'candidate':candidate_identity,
                   'manifested_candidate_files_verified':len(new_all), 'baseline_files_verified':len(old_all),
                   'changed_files_verified':25, 'freeze_sha256':FREEZE_SHA,
                   'unmanifested_generated_cache_files_excluded':ignored,
                   'baseline_classification_basis':'Exact-blob inherited Skills ledger; prior verifier rerun recorded separately',
                   'limits':'LOC verifies source identity and reviewed category accounting, not tests, GUI acceptance, macOS oracle, feature parity, ETA, performance, or remote publication.'})
    print(json.dumps(result, indent=2))

if __name__ == '__main__':
    try:
        main()
    except (VerificationError, KeyError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print('FAIL: '+str(exc), file=sys.stderr)
        sys.exit(1)
