#!/usr/bin/env python3
"""Verify the exact Bash Rust snapshot and reviewed LOC carry, without builds/writes.

Use a repository containing c0df340 and the Skills baseline objects. Read current
source through --source-root, or immutable Git bytes through --after. Non-Rust
publication files belong to the separate changed-file/preimage manifest.
"""
import argparse,hashlib,importlib.util,json,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
EVIDENCE=HERE.parent/'docs/validation/bash-workflow-2026-10-07'
AUDIT=EVIDENCE/'loc'
BASE='c0df34001f512c2bc374329c13708afe9bfa0aaa'
TREE='7e9db8f815e5dcb998383da5b3c8dfb51d01bda6'
COMP='rust/crates/bello-agent-core/src/compaction_runtime_tests.rs'
READ='rust/crates/bello-agent-app/src/transcript_read_native_ui_tests.rs'
AFTER={COMP:'269e9df6285deb95d2b04442d039a29f6c5bac5ce93178e5e40e402d1fa444e5',READ:'8fd4cf20c77c50bb15bdd1e97f33d7972ed22867ddea07f09a025d1387735084'}
sha=lambda b:hashlib.sha256(b).hexdigest()

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--repo',type=Path,required=True);p.add_argument('--source-root',type=Path);p.add_argument('--after');a=p.parse_args();assert bool(a.source_root)!=bool(a.after),'Choose source-root or after'
 spec=importlib.util.spec_from_file_location('frozen_bash_audit',AUDIT/'verify-loc-bash-workflow-2026-10-07.py');v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
 assert v.read_git(a.repo,'rev-parse',BASE+'^{tree}').decode().strip()==TREE
 skills=v.git_sources(a.repo,v.BASE_TREE);baseline=v.git_sources(a.repo,BASE)
 current=v.git_sources(a.repo,a.after) if a.after else v.directory_sources(a.source_root)[0]
 freeze_raw=(AUDIT/'agent-shell-rebased-files.json').read_bytes();assert sha(freeze_raw)==v.FREEZE_SHA;freeze=json.loads(freeze_raw)
 ranges_raw=(AUDIT/'reviewed-support-ranges.json').read_bytes();assert sha(ranges_raw)==v.RANGES_SHA;ranges=json.loads(ranges_raw);ledger=json.loads((AUDIT/'loc-bash-workflow-2026-10-07-delta.json').read_bytes())
 original=dict(skills)
 for name in freeze['changed_files']:
  data=(AUDIT/'trusted-bash-workflow.original.md').read_bytes() if name=='rust/docs/trusted-bash-workflow.md' else current[name]
  assert sha(data)==freeze['changed_files'][name], 'Original Bash input drift: '+name
  original[name]=data
 v.verify_sources(freeze,skills,original);frozen=v.verify_ledger(ledger,freeze,ranges,skills,original)
 assert sorted(name for name in skills.keys()|baseline.keys() if skills.get(name)!=baseline.get(name))==[READ,'rust/docs/validation/read-native-ci-2026-10-07.md']
 assert sha(baseline[READ])==AFTER[READ]
 before_rs=v.rust_only(original);current_rs=v.rust_only(current);assert set(before_rs)==set(current_rs)
 assert sorted(name for name in before_rs if before_rs[name]!=current_rs[name])==sorted(AFTER)
 for name,h in AFTER.items():assert sha(current[name])==h, 'Final test input drift: '+name
 assert b'#[cfg(test)]\n#[path = "compaction_runtime_tests.rs"]\nmod tests;' in current['rust/crates/bello-agent-core/src/compaction_runtime.rs']
 assert b'#[cfg(test)]\nmod transcript_view_tests;' in current['rust/crates/bello-agent-app/src/main.rs']
 assert b'#[path = "transcript_read_ui_tests.rs"]\nmod read_ui;' in current['rust/crates/bello-agent-app/src/transcript_view_tests.rs']
 assert b'#[cfg(feature = "synthetic-authority")]\n#[path = "transcript_read_native_ui_tests.rs"]\nmod native_workflow;' in current['rust/crates/bello-agent-app/src/transcript_read_ui_tests.rs']
 nb=lambda b:v.nonblank(b.decode().splitlines())
 assert nb(current[COMP])-nb(original[COMP])==20
 assert nb(current[READ])-nb(original[READ])==11
 counts=dict(frozen['counts']);counts['tests_and_test_support']+=31
 assert counts=={'production':43570,'tests_and_test_support':58083,'benchmark_example':1192}
 assert sum(nb(b) for b in current_rs.values())==sum(counts.values())==102845
 # Every compiled input in the sealed GUI binary is unchanged apart from these
 # specifically known test-only files; Cargo metadata and lock must match too.
 built_raw=(EVIDENCE/'candidate2-build-source-manifest.json').read_bytes();assert sha(built_raw)=='46dd6bc1d1711ad37d64933d5f628b21eea4e5d8519fad80ea47cb12175dd1ab';built=json.loads(built_raw)['all_files']
 changed=sorted(name for name in current_rs if sha(current_rs[name])!=built.get(name))
 assert changed==['rust/crates/bello-agent-app/src/connection_settings_controller_tests.rs','rust/crates/bello-agent-app/src/mcp_inspector_controller_tests.rs','rust/crates/bello-agent-app/src/transcript_edit_native_ui_tests.rs',READ,COMP,'rust/crates/bello-agent-core/tests/project_skills_native.rs']
 for name,data in current.items():
  if name.endswith(('Cargo.toml','Cargo.lock')):assert sha(data)==built[name], 'Cargo input changed: '+name
 result={'status':'PASS','baseline_commit':BASE,'baseline_tree':TREE,'baseline_counts':{'production':42590,'tests_and_test_support':56239,'benchmark_example':1192},'counts':counts,'total':102845,'delta':{'production':980,'tests_and_test_support':1844,'benchmark_example':0},'native_read_carry_support':11,'compaction_barrier_support':20,'rust_files':len(current_rs),'rust_source_manifest_sha256':v.manifest_hash(v.source_manifest(current_rs)),'post_build_rust_changes_test_only':changed,'production_and_cargo_inputs_match_sealed_candidate2':True,'shared_ui':'Counted only in BelloBox; excluded from Agent.','limits':'Exact source/LOC and build-input attribution only; not a test, publication, GUI, native, completion or performance claim.'}
 print(json.dumps(result,indent=2))
if __name__=='__main__':
 try:main()
 except Exception as e:print('FAIL: '+str(e),file=sys.stderr);sys.exit(1)
