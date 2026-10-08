#!/usr/bin/env python3
import argparse,hashlib,json,shutil,subprocess,tempfile,time
from pathlib import Path
parser=argparse.ArgumentParser(description="Run isolated instruction-path detecting controls; set CARGO_BUILD_JOBS=1 and a separate CARGO_TARGET_DIR.")
parser.add_argument('--source-root', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
args=parser.parse_args()
SOURCE=args.source_root.resolve()
EVIDENCE=args.output_dir.resolve()
if EVIDENCE == SOURCE or SOURCE in EVIDENCE.parents:
 raise ValueError('Control output must be outside the source tree')
EVIDENCE.mkdir(parents=True, exist_ok=True)
workspace=tempfile.TemporaryDirectory(prefix='instruction-path-controls-')
ROOT=Path(workspace.name)/'source'
shutil.copytree(SOURCE,ROOT,ignore=shutil.ignore_patterns('.git','target'))
P='rust/crates/bello-agent-core/src/'
rows=[]
controls=[
 ('omit_prompt_map',{P+'project_resources.rs':('instruction.prompt_roots','instruction.roots'),P+'resource_runtime.rs':('snapshot.prompt_roots','snapshot.roots')},['--lib','project_resources::presentation_tests::instruction_prompt_uses_captured_spelling_without_rewriting_body_or_skill_text'],'project_resources::presentation_tests::instruction_prompt_uses_captured_spelling_without_rewriting_body_or_skill_text'),
 ('resolve_locator_leaf',{P+'instructions.rs':('let source = source_path::existing(&locator, &canonical)?;', 'let source = source_path::existing(&locator, &canonical)?;\n            let locator = source.clone();')},['--test','instruction_discovery','instruction_locator_and_resolved_provenance_are_distinct_and_literal_body_is_untouched'],'instruction_locator_and_resolved_provenance_are_distinct_and_literal_body_is_untouched'),
 ('remove_target_check',{P+'project_resources/source_path.rs':('if fs::canonicalize(&source)? != canonical || fs::canonicalize(path)? != canonical {','if false {')},['--lib','project_resources::identity_tests::source_spelling_must_resolve_to_the_scanned_target'],'project_resources::identity_tests::source_spelling_must_resolve_to_the_scanned_target'),
 ('rewrite_instruction_body',{P+'instructions.rs':('snapshot.instructions = chunks.join("\\n\\n");','snapshot.instructions = chunks.join("\\n\\n").replace("/private/", "/");')},['--test','instruction_discovery','instruction_locator_and_resolved_provenance_are_distinct_and_literal_body_is_untouched'],'instruction_locator_and_resolved_provenance_are_distinct_and_literal_body_is_untouched'),
 ('refresh_instruction_retry',{P+'resource_runtime.rs':('if let Some(retained) = retained {','if let Some(retained) = retained.filter(|_| false) {')},['--all-features','--lib','runtime::resource_runtime::tests::synthetic_instruction_locator_retarget_retains_active_and_retry_bytes_until_new_delivery'],'runtime::resource_runtime::tests::synthetic_instruction_locator_retarget_retains_active_and_retry_bytes_until_new_delivery'),
 ('refresh_project_retry',{P+'project_input_runtime.rs':('let retained = if retry {','let retained = if false {')},['--all-features','--lib','saved_runtime::tests::skills::delivered_retry_and_reopen_never_reread_removed_skill_bodies'],'saved_runtime::tests::skills::delivered_retry_and_reopen_never_reread_removed_skill_bodies'),
]
for name,changes,arguments,test in controls:
 originals={}; mutations={}
 try:
  for path,(before,after) in changes.items():
   f=ROOT/path; data=f.read_bytes();originals[path]=data;s=data.decode();assert before in s,(name,path)
   modified=s.replace(before,after)
   if name=='omit_prompt_map':modified=modified.replace('.prompt_roots\n                .iter()', '.roots\n                .iter()')
   f.write_text(modified);mutations[path]={'before':hashlib.sha256(data).hexdigest(),'mutated':hashlib.sha256(f.read_bytes()).hexdigest()}
  command=['cargo','test','--offline','--locked','-p','bello-agent-core']+arguments+['--','--exact','--nocapture']
  started=time.time()
  result=subprocess.run(command,cwd=ROOT/'rust',capture_output=True,text=True,timeout=240)
  output=result.stdout+result.stderr
  (EVIDENCE/f'control-{name}.log').write_text(output)
  detected=result.returncode!=0 and f'test {test} ... FAILED' in output and 'panicked at ' in output
  row={'control':name,'command':command,'test':test,'status':result.returncode,'detected_by_test_failure':detected,'source':mutations,'elapsed_seconds':round(time.time()-started,3)}
  rows.append(row)
  (EVIDENCE/'behavior-controls.json').write_text(json.dumps(rows,indent=2)+'\n')
  print(json.dumps(row),flush=True)
  assert detected, f'Control {name} did not yield the expected runtime assertion failure'
 finally:
  for path,data in originals.items():(ROOT/path).write_bytes(data)
for path in SOURCE.rglob('*'):
 if path.is_file() and '.git' not in path.relative_to(SOURCE).parts and 'target' not in path.relative_to(SOURCE).parts:assert path.read_bytes()==(ROOT/path.relative_to(SOURCE)).read_bytes()
print('All controls detected; control checkout restored byte-exactly.',flush=True)
