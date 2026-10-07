#!/usr/bin/env python3
"""Launch a sealed owned app and sample its exact generated shell identity.

This is a GUI-launch/observation harness, not a UI automation backdoor. Only CUA
operates the app. No signals target numeric child PIDs. Unexpected app death first
records failure, then releases the generated shell by its own control-file path.
"""
import hashlib,json,os,subprocess,time
from pathlib import Path
ROOT=Path('/workspace/shared/agent-shell-held-gui-fixture');E=ROOT/'evidence';P=ROOT/'project'
def parse_stat(raw):
 head,tail=raw.rsplit(') ',1);fields=tail.split();return {'pid':int(head.split(' ',1)[0]),'start_ticks':int(fields[19]),'state':fields[0]}
def stat(pid):
 try:return parse_stat(Path(f'/proc/{pid}/stat').read_text())
 except (FileNotFoundError,ProcessLookupError):return None
seal=json.loads((E/'sealed-build.json').read_text());binary=Path(seal['binary']);assert hashlib.sha256(binary.read_bytes()).hexdigest()==seal['binary_sha256']
assert not (P/'held.ready').exists(),'Use a fresh generated fixture for this run'
with (E/'app.log').open('w') as app_log,(E/'process-observations.jsonl').open('w',buffering=1) as log:
 app=subprocess.Popen([str(binary),'--synthetic-connections','--synthetic-attachment-fixture',str(ROOT/'profile.json'),'--project',str(P),'--session',str(ROOT/'state/session.json')],stdout=app_log,stderr=subprocess.STDOUT)
 (E/'app-identity.json').write_text(json.dumps({'pid':app.pid,'stat':stat(app.pid),'binary_sha256':seal['binary_sha256'],'started_monotonic':time.monotonic()},indent=2)+'\n')
 expected=None;ready_at=None;term_at=None;shell_gone_at=None;app_exit_at=None;held_with_app_alive=0;reaped_with_app_alive=0;app_exited_before_shell_absent=False;last=None
 try:
  while True:
   now=time.monotonic();status=app.poll()
   if expected is None and (P/'held.ready').exists():
    expected=parse_stat((P/'held.startstat').read_text());ready_at=now
    (E/'shell-identity.json').write_text(json.dumps(expected,indent=2)+'\n')
   actual=stat(expected['pid']) if expected else None
   matched=bool(expected and actual and actual['start_ticks']==expected['start_ticks'])
   term=(P/'held.term').exists()
   if term and term_at is None:term_at=now
   if expected and not matched and shell_gone_at is None:shell_gone_at=now
   if status is None and matched and term:held_with_app_alive+=1
   if status is None and expected and not matched:reaped_with_app_alive+=1
   row={'monotonic':now,'app_alive':status is None,'app_status':status,'shell_identity_known':expected is not None,'shell_same_identity_present':matched,'shell_state':actual['state'] if matched else None,'term_observed':term,'manual_release':(P/'held.release').exists()}
   summary={k:v for k,v in row.items() if k!='monotonic'}
   # Retain every 10 ms sample once the command is ready; before then changes only.
   if expected or summary!=last:log.write(json.dumps(row)+'\n')
   last=summary
   if status is not None:
    if app_exit_at is None:
     app_exit_at=now;app_exited_before_shell_absent=matched
     if matched:
      (E/'premature-exit.json').write_text(json.dumps(row,indent=2)+'\n')
      (P/'held.release').write_text('Observer cleanup after premature app exit\n')
    if not matched or now-app_exit_at>5:break
   time.sleep(.01 if expected else .1)
 finally:
  if expected and stat(expected['pid']) is not None:(P/'held.release').write_text('Bounded fixture cleanup\n')
 result={'app_exit_code':app.returncode,'held_ready_observed':expected is not None,'held_ready_at':ready_at,'term_observed_at':term_at,'shell_identity_disappeared_at':shell_gone_at,'app_exit_observed_at':app_exit_at,'app_alive_while_term_cleanup_samples':held_with_app_alive,'app_alive_after_shell_reap_samples':reaped_with_app_alive,'app_exited_before_owned_shell_absent':app_exited_before_shell_absent,'normal_finish_marker_exists':(P/'held.finished').exists(),'limit':'10 ms observations corroborate source ordering; Linux process evidence is not macOS acceptance.'}
 (E/'process-lifetime-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
