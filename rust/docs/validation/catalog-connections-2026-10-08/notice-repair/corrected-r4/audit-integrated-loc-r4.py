#!/usr/bin/env python3
"""Reviewed additive audit against exact6eee baseline; never rewrites prior ledgers."""
import importlib.util,subprocess,hashlib,json,difflib
from pathlib import Path
repo=Path('/workspace/scratch/8b6fda578834/BelloAgent');stage=Path('/workspace/shared/catalog-native-integrated-stage');out=Path('/workspace/shared/catalog-native-evidence');base='6eee1d06776b18b55b45f0f8adbbe6204c3cb328'
spec=importlib.util.spec_from_file_location('prior_audit','/workspace/shared/new-remote-checkpoint-audit/audit.py');audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
prior_path=Path('/workspace/shared/new-remote-checkpoint-audit/BelloAgent-loc.json');prior=json.loads(prior_path.read_text());assert prior['head_commit']==base
P,S,B=audit.CATS
A='rust/crates/bello-agent-app/src/';C='rust/crates/bello-agent-core/src/'
after_ranges={
 A+'chat_navigation.rs':[],
 A+'connection_settings_controller.rs':[(6,7),(28,31),(149,159),(169,172),(1247,1249)],
 A+'connection_settings_view.rs':[(1937,1939)],
 A+'connection_model_catalog.rs':[(321,337),(343,429)],
 C+'connection_vault.rs':[(194,195),(197,200),(385,386),(389,409),(709,710),(757,761),(763,769),(771,860)],
 C+'lib.rs':[(22,23)],C+'model_catalog.rs':[(460,462)]}
oldfiles={r['path']:r for r in prior['files']};manifest=json.loads((out/'review-r4/manifest.json').read_text());delta=dict.fromkeys(audit.CATS,0);files=[];transition_count=0
for row in manifest['files']:
 path=row['path']
 if not path.endswith('.rs'):continue
 result=subprocess.run(['git','-C',str(repo),'show',base+':'+path],capture_output=True);old=result.stdout if result.returncode==0 else b'';new=(stage/path).read_bytes();assert audit.sha(new)==row['afterimage_sha256'];ol=old.decode().splitlines();nl=new.decode().splitlines()
 if not old:before=[];origin={'kind':'new file'}
 elif path in oldfiles:
  f=oldfiles[path];assert audit.sha(old)==f['after']['sha256'];ranges=f['after_reviewed_support_ranges'];before=audit.kinds(ol,[(r['start'],r['end']) for r in ranges]);origin={'kind':'exact6eee additive audit','sha256':audit.sha(prior_path.read_bytes())};assert audit.count(ol,before)==f['after_counts']
 elif path==C+'lib.rs':before=audit.kinds(ol,[(21,22)]);origin={'kind':'reviewed simple module-export file, only positive synthetic module declaration is support'}
 else:before,origin=audit.inherited(repo,path,audit.object_blob(old),ol)
 ranges=[(1,len(nl))] if path.endswith('_tests.rs') else after_ranges[path]
 after=audit.kinds(nl,ranges);bc=audit.count(ol,before);ac=audit.count(nl,after);dd={c:ac[c]-bc[c] for c in audit.CATS};transitions=[];hunks=[]
 for tag,a,b,c,d in difflib.SequenceMatcher(None,ol,nl,autojunk=False).get_opcodes():
  if tag=='equal':
   for oi,ni in zip(range(a,b),range(c,d)):
    if ol[oi].strip() and before[oi]!=after[ni]:transitions.append({'before_line':oi+1,'after_line':ni+1,'from':before[oi],'to':after[ni],'text':nl[ni]})
  else:hunks.append({'operation':tag,'before':[a+1,b],'after':[c+1,d],'before_counts':audit.count(ol[a:b],before[a:b]),'after_counts':audit.count(nl[c:d],after[c:d])})
 transition_count+=len(transitions)
 for cat in audit.CATS:delta[cat]+=dd[cat]
 files.append({'path':path,'before_sha256':audit.sha(old) if old else None,'after_sha256':audit.sha(new),'origin':origin,'before_counts':bc,'after_counts':ac,'delta':dd,'after_reviewed_support_ranges':audit.spans(nl,ranges),'equal_line_category_changes':transitions,'changed_spans':hunks})
counts={c:prior['counts'][c]+delta[c] for c in audit.CATS}
physical=sum(sum(bool(l.strip()) for l in p.read_bytes().splitlines()) for p in (stage/'rust').rglob('*.rs') if '/target/' not in str(p) and '/docs/' not in str(p))
assert physical==sum(counts.values()),(physical,counts)
assert transition_count==0,[(f['path'],f['equal_line_category_changes']) for f in files if f['equal_line_category_changes']]
r={'base_commit':base,'base_tree':prior['head_tree'],'baseline_audit_sha256':audit.sha(prior_path.read_bytes()),'baseline_counts':prior['counts'],'delta':delta,'counts':counts,'physical_total':physical,'preserved_equal_line_category_changes':transition_count,'method':'Nonblank physical owned Rust lines including comments. Inherit exact6eee category ledger including its138 native-generalized lines; source-review all changed/new file spans. No old8914 delta reused; no unchanged source reclassification. Not completion or performance evidence.','files':files}
(out/'notice-repair/corrected-r4/integrated-loc-r4.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({k:r[k] for k in ['delta','counts','physical_total','preserved_equal_line_category_changes']},indent=2))
