#!/usr/bin/env python3
"""Tamper-detection checks; all source mutations are in memory, never on disk."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('bash_loc', HERE/'verify-loc-bash-workflow-2026-10-07.py')
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, required=True)
    args = parser.parse_args()
    old = V.git_sources(args.repo, V.BASE_TREE)
    new, ignored = V.directory_sources(args.source_root)
    freeze = json.loads((HERE/'agent-shell-rebased-files.json').read_bytes())
    ranges = json.loads((HERE/'reviewed-support-ranges.json').read_bytes())
    report = json.loads((HERE/'loc-bash-workflow-2026-10-07-delta.json').read_bytes())
    V.verify_sources(freeze, old, new)
    result = V.verify_ledger(report, freeze, ranges, old, new)
    controls = []

    def detects(name, fn, expected):
        try:
            fn()
        except V.VerificationError as exc:
            V.require(expected in str(exc), name + ' failed for an unexpected reason: '+str(exc))
            controls.append({'case':name, 'detected':True, 'error':str(exc), 'source_modified_on_disk':False})
        else:
            raise V.VerificationError('negative control was NOT detected: '+name)

    source_path = 'rust/crates/bello-agent-core/src/tools/bash.rs'
    changed = dict(new); changed[source_path] += b'\n// simulated source drift\n'
    detects('modified Rust source byte', lambda:V.verify_sources(freeze,old,changed), 'candidate full-source')
    changed = dict(new); changed['rust/crates/bello-agent-core/src/unmanifested.rs'] = b'fn extra() {}\n'
    detects('extra Rust source file', lambda:V.verify_sources(freeze,old,changed), 'candidate full-source')
    changed = dict(new); del changed[source_path]
    detects('missing Rust source file', lambda:V.verify_sources(freeze,old,changed), 'candidate full-source')
    changed = dict(new); changed['rust/fixtures/bash_workflow_fixture.py'] += b'\n# simulated drift\n'
    detects('modified non-Rust frozen fixture', lambda:V.verify_sources(freeze,old,changed), 'candidate full-source')
    changed = dict(old); changed['rust/crates/bello-agent-core/src/tools.rs'] += b'\n// drift\n'
    detects('modified immutable baseline blob in memory', lambda:V.verify_sources(freeze,changed,new), 'baseline full-source')

    def ledger_case(name, edit, expected):
        altered = copy.deepcopy(report)
        edit(altered)
        detects(name,lambda:V.verify_ledger(altered,freeze,ranges,old,new),expected)

    ledger_case('baseline category total altered',lambda d:d['before_counts'].__setitem__('production',42591), 'Skills baseline category')
    ledger_case('aggregate delta altered',lambda d:d['delta'].__setitem__('production',981), 'aggregate delta')
    ledger_case('benchmark incorrectly included in support',lambda d:d['after_counts'].__setitem__('benchmark_example',0), 'after totals')
    ledger_case('publication asserted by ledger',lambda d:d.__setitem__('publication_commit','fake-published-sha'), 'cannot establish publication')
    ledger_case('prior classification provenance altered',lambda d:d['files'][0]['before_classification_origin'].__setitem__('sha256','0'*64), 'committed ledger identity')
    ledger_case('changed-span evidence altered',lambda d:d['files'][0]['changed_line_spans'][0].__setitem__('source_sha256','0'*64), 'changed-span evidence')
    ledger_case('preserved-line evidence altered',lambda d:d['files'][0]['preserved_line_ranges'][0].__setitem__('source_sha256','0'*64), 'preserved-line evidence')
    ledger_case('support anchor altered',lambda d:d['files'][0]['after']['reviewed_support_ranges'][0].__setitem__('start_text','// false anchor'), 'support start anchor')

    def support_reclassification(d):
        entry = next(e for e in d['files'] if e['path'] == source_path)
        entry['after']['reviewed_support_ranges'] = []
        entry['after']['counts'] = dict(zip(V.KEYS,(617,0,0)))
    ledger_case('self-consistent new support-to-production reclassification',support_reclassification,'reviewed support spans')

    def inherited_reclassification(d):
        entry = d['files'][0]
        entry['before']['reviewed_support_ranges'] = []
        entry['before']['counts'] = dict(zip(V.KEYS,(243,0,0)))
    ledger_case('self-consistent inherited support-to-production reclassification',inherited_reclassification,'inherited classification')

    # Exercise public CLI for immutable-tree portability and wrong-tree refusal.
    command = [sys.executable,'-B',str(HERE/'verify-loc-bash-workflow-2026-10-07.py'),
               '--repo',str(args.repo),'--source-root',str(args.source_root)]
    ok = subprocess.run(command+['--baseline-ref',V.BASE_COMMIT],capture_output=True,text=True)
    V.require(ok.returncode == 0,'supplied matching baseline commit rejected: '+ok.stderr)
    portable = json.loads(ok.stdout)
    V.require(portable['baseline_tree'] == V.BASE_TREE,'matching commit resolved to wrong tree')
    wrong = subprocess.run(command+['--baseline-ref',report['baseline_ledger']['git_blob']],capture_output=True,text=True)
    V.require(wrong.returncode != 0,'non-tree baseline accepted')
    controls.append({'case':'blob object rejected as baseline revision','detected':True,
                     'error':wrong.stderr.strip(),'source_modified_on_disk':False})
    prior = json.loads(old[report['baseline_ledger']['path']])['before_commit']
    wrong = subprocess.run(command+['--baseline-ref',prior],capture_output=True,text=True)
    V.require(wrong.returncode != 0 and 'reviewed tree' in wrong.stderr,'wrong baseline tree not detected')
    controls.append({'case':'different valid baseline commit tree','detected':True,
                     'error':wrong.stderr.strip(),'source_modified_on_disk':False})

    # Source-independent synthetic preservation rule tests: no Rust is executed.
    detects('equal nonblank line reclassification',
            lambda:V.diff_evidence(['}'],['}'],['production'],['tests_and_test_support']),
            'unchanged nonblank line reclassified')
    counts = V.line_counts(['// comment','','fn one() {}'],V.categories(['// comment','','fn one() {}'],[]))
    V.require(counts == dict(zip(V.KEYS,(2,0,0))),'physical comment/blank convention failed')
    output={'status':'PASS','negative_controls_detected':len(controls),'controls':controls,
            'positive_controls':['Exact frozen candidate passes',
                                 'Baseline immutable tree ID passes without requiring original local commit lookup',
                                 'Supplied original baseline commit accepted only after tree equality',
                                 'Nonblank comments count; blank lines do not'],
            'no_source_or_git_state_changes':True,'candidate_total':result['total'],
            'ignored_generated_cache_files':ignored}
    print(json.dumps(output,indent=2))

if __name__ == '__main__':
    main()
