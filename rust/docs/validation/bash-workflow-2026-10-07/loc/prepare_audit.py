import json,subprocess,pathlib,hashlib,difflib
REPO=pathlib.Path('/workspace/scratch/8b6fda578834/BelloAgent'); REF='b44e47c9a4ad882431c567889df72c35fe574da8'; SOURCE=pathlib.Path('/workspace/shared/agent-shell-stage'); OUT=pathlib.Path('/workspace/shared/agent-shell-loc')
def git(*args):return subprocess.check_output(['git','-C',str(REPO),*args])
def sha(x):return hashlib.sha256(x).hexdigest()
def blob(x):return hashlib.sha1(b'blob '+str(len(x)).encode()+b'\0'+x).hexdigest()
old={n:git('show',REF+':'+n) for row in git('ls-tree','-r',REF,'--','rust/').decode().splitlines() for _,n in [row.split('\t')] if n.endswith('.rs')}
new={str(p.relative_to(SOURCE)):p.read_bytes() for p in SOURCE.joinpath('rust').rglob('*.rs') if not {'target','.git'}.intersection(p.parts)}
paths=sorted(p for p in old.keys()|new.keys() if old.get(p)!=new.get(p))
ledgers={}
for row in git('ls-tree','-r',REF,'--','rust/docs/validation').decode().splitlines():
 _,p=row.split('\t')
 if pathlib.Path(p).name.startswith('loc') and p.endswith('-delta.json'):
  data=git('show',REF+':'+p);ledgers[p]=(data,json.loads(data))
prior={}
for p in paths:
 if p not in old:continue
 matches=[]
 for lp,(data,d) in ledgers.items():
  for x in d.get('files',[]):
   if x['path']==p:
    for side in ('before','after'):
     if x.get(side+'_blob')==blob(old[p]):matches.append((lp,data,x,side))
 assert matches,p
 # Prefer the most recent Skills ledger when available; otherwise exact prior blob.
 matches.sort(key=lambda x:(0 if 'project-skills' in x[0] else 1,x[0],0 if x[3]=='after' else 1))
 lp,data,x,side=matches[0]
 prior[p]={'origin':{'kind':'committed_ledger','path':lp,'git_blob':blob(data),'sha256':sha(data),'side':side},'classification':x[side]}
 for _,_,m,s in matches:assert m[s]==x[side],p
before_lines={p:old.get(p,b'').decode().splitlines() for p in paths};after_lines={p:new.get(p,b'').decode().splitlines() for p in paths}
after_ranges={}
for p in paths:
 if p not in prior:continue
 before,after=before_lines[p],after_lines[p]
 line_map={i+1:k+1 for tag,a,b,c,d in difflib.SequenceMatcher(a=before,b=after,autojunk=False).get_opcodes() if tag=='equal' for i,k in zip(range(a,b),range(c,d))}
 spans=[]
 for r in prior[p]['classification']['reviewed_support_ranges']:
  if r['start']==1 and r['end']==len(before):spans.append([1,len(after),'whole test module']);continue
  if r['start'] not in line_map or r['end'] not in line_map:print('UNMAPPED',p,r);continue
  spans.append([line_map[r['start']],line_map[r['end']],r['reason']])
 after_ranges[p]=spans
 print(p,spans)
(OUT/'baseline-classification-review.json').write_text(json.dumps(prior,indent=2)+'\n')
(OUT/'mapped-support-review.json').write_text(json.dumps(after_ranges,indent=2)+'\n')
helpers={};exec(git('show',REF+':rust/scripts/verify-loc-project-skills-2026-10-07.py').decode().split('def main():')[0].replace('ROOT = Path(__file__).resolve().parents[2]','ROOT = Path.cwd()'),helpers)
KEYS=helpers['KEYS'];line_categories=helpers['line_categories'];line_counts=helpers['line_counts'];nonblank=helpers['nonblank'];source_manifest=helpers['source_manifest'];manifest_hash=helpers['manifest_hash'];diff_evidence=helpers['diff_evidence']
app='rust/crates/bello-agent-app/src/';core='rust/crates/bello-agent-core/src/'
for p in paths:
 if p not in old:
  if p.endswith('_tests.rs') or '/tests/' in p:after_ranges[p]=[[1,len(after_lines[p]),'whole test-only module; parent cfg or integration test target']]
  else:after_ranges[p]=[]
extra={core+'saved_runtime.rs':[(32,33),(49,50),(273,278)],core+'tool_runtime.rs':[(81,88),(1643,1645)],core+'tools.rs':[(206,207),(273,274),(332,339),(636,637)],core+'live_tool_runtime.rs':[(131,133)],core+'tools/bash.rs':[(150,157),(176,183),(189,199),(201,204),(208,211),(292,293),(298,301),(495,502),(525,526),(574,575),(620,621),(625,627)]}
for p,spans in extra.items():
 after_ranges[p].extend([a,b,'source-reviewed positive cfg(test) range'] for a,b in spans)
(OUT/'reviewed-support-ranges.json').write_text(json.dumps(after_ranges,indent=2)+'\n')
entries=[];total_delta=dict.fromkeys(KEYS,0);preserved_total=dict.fromkeys(KEYS,0);adjustments=[]
for p in paths:
 before,after=before_lines[p],after_lines[p]
 ranges=[{'start':a,'end':b,'reason':reason,'start_text':after[a-1],'end_text':after[b-1]} for a,b,reason in sorted(after_ranges[p])]
 bentry=prior[p]['classification'] if p in prior else {'nonblank':0,'counts':dict.fromkeys(KEYS,0),'reviewed_support_ranges':[]}
 oldcat=line_categories(before,bentry['reviewed_support_ranges'],False);newcat=line_categories(after,ranges,False)
 for tag,a,b,c,d in difflib.SequenceMatcher(a=before,b=after,autojunk=False).get_opcodes():
  if tag!='equal':continue
  for i,j in zip(range(a,b),range(c,d)):
   if before[i].strip() and oldcat[i]!=newcat[j]:adjustments.append({'path':p,'before_line':i+1,'after_line':j+1,'source':before[i],'inherited_category':oldcat[i],'fresh_syntax_category':newcat[j]})
 preserved,changed,delta=diff_evidence(before,after,oldcat,newcat)
 aentry={'nonblank':nonblank(after),'counts':line_counts(after,newcat),'reviewed_support_ranges':ranges}
 entry={'path':p,'category':'source-reviewed mixed spans' if ranges and aentry['counts']['production'] else ('tests_and_test_support' if ranges else 'production'),'before_blob':blob(old[p]) if p in old else None,'after_blob':blob(new[p]),'before_sha256':sha(old[p]) if p in old else None,'after_sha256':sha(new[p]),'before_classification_origin':prior[p]['origin'] if p in prior else {'kind':'new_file'},'before':bentry,'after':aentry,'preserved_line_ranges':preserved,'changed_line_spans':changed,'delta':delta}
 entries.append(entry)
 for k in KEYS:total_delta[k]+=delta[k];preserved_total[k]+=sum(s['nonblank_counts'][k] for s in preserved)
 print('DELTA',p,delta)
assert not adjustments,adjustments
baseline_path='rust/docs/validation/loc-project-skills-2026-10-07-delta.json';base_data,base=ledgers[baseline_path]
freeze_path=pathlib.Path('/workspace/shared/agent-shell-rebased-files.json');freeze_data=freeze_path.read_bytes();freeze=json.loads(freeze_data)
assert sha(freeze_data)=='0129e22e28ac05f2c610804dc6d1bdde366f98ff4e2d6243addcdfc4dca546e4'
assert {p:sha(v) for p,v in new.items()}=={p:s for p,s in freeze['all_files'].items() if p.startswith('rust/') and p.endswith('.rs')}
assert source_manifest(old)==base['after_rust_sources']
counts={k:base['after_counts'][k]+total_delta[k] for k in KEYS}
nonrust=[]
for p,h in freeze['changed_files'].items():
 if p.endswith('.rs'):continue
 data=SOURCE.joinpath(p).read_bytes();assert sha(data)==h
 try:olddata=git('show',REF+':'+p)
 except subprocess.CalledProcessError:olddata=None
 nonrust.append({'path':p,'before_blob':blob(olddata) if olddata is not None else None,'before_sha256':sha(olddata) if olddata is not None else None,'after_blob':blob(data),'after_sha256':h,'outside_rust_loc':True})
report={'method':base['method'],'scope':base['scope'],'checkpoint_status':'source_frozen_baseline_and_bash_publication_pending','publication_commit':None,'before_commit':REF,'before_tree':git('rev-parse',REF+'^{tree}').decode().strip(),'before_publication_status':'unpublished local commit; do not call this a published checkpoint','baseline_publication_commit':None,'baseline_ledger':{'path':baseline_path,'git_blob':blob(base_data),'sha256':sha(base_data)},'baseline_verifier':{'path':'rust/scripts/verify-loc-project-skills-2026-10-07.py','git_blob':blob(git('show',REF+':rust/scripts/verify-loc-project-skills-2026-10-07.py')),'sha256':sha(git('show',REF+':rust/scripts/verify-loc-project-skills-2026-10-07.py'))},'candidate_freeze':{'filename':freeze_path.name,'sha256':sha(freeze_data),'rust_files':len(new),'changed_files':len(freeze['changed_files'])},'before_counts':base['after_counts'],'before_total':base['after_total'],'before_source_manifest_sha256':manifest_hash(source_manifest(old)),'after_source_manifest_sha256':manifest_hash(source_manifest(new)),'before_rust_sources':source_manifest(old),'after_rust_sources':source_manifest(new),'delta':total_delta,'after_counts':counts,'after_total':sum(counts.values()),'rust_file_count':len(new),'changed_rust_files':len(paths),'unchanged_rust_files':len(old.keys()&new.keys())-sum(p in old and p in new for p in paths),'preserved_nonblank_counts_in_changed_files':preserved_total,'inherited_classification_adjustments':adjustments,'classification_notes':['Positive cfg(test), test-only module and inherited explicit synthetic-only spans count as support. Platform-only gates do not imply test ownership.','Mixed cfg(any(feature, test)) code remains production. Runtime fixture branches in shared production composition remain production unless independently classified as test-only.','No new equal-line reclassification is required in this Bash delta. The unchanged Skills context_preview.rs inherited delimiter classifications remain untouched.','Shared code is counted once by its repository source path; no vendored Cargo/git dependency source is included.','The four non-Rust Bash files are recorded for freeze provenance but contribute zero Rust LOC.','GUI and Mac Swift source-oracle acceptance are pending. LOC neither verifies these gates nor implies feature completeness or performance.'],'uncertain_classifications':[],'non_rust_changed_files':nonrust,'files':entries}
assert report['after_total']==sum(nonblank(v.decode().splitlines()) for v in new.values())
(OUT/'loc-bash-workflow-2026-10-07-delta.json').write_text(json.dumps(report,indent=2)+'\n')
(OUT/freeze_path.name).write_bytes(freeze_data)
print('TOTAL',total_delta,counts,report['after_total'],'manifest',report['after_source_manifest_sha256'])
