#!/usr/bin/env python3
"""Append task/command timing to duration-data.json, without guessing missing inference.
Examples:
  python duration-track.py --ledger duration-data.json begin task1 --activity 'Review search parity' --category review --resource assistant-task-window --source 'Task acceptance observed locally'
  python duration-track.py --ledger duration-data.json end task1 --outcome completed
  python duration-track.py --ledger duration-data.json record cmd1 --activity 'Focused tests' --category test --resource cloud-command --source 'validation/test.log' --start 2026-10-09T07:00:00Z --end 2026-10-09T07:00:10Z --duration 10 --basis 'measured monotonic command timer' --count-group local_command --parent task1 --outcome passed
  python duration-track.py --ledger duration-data.json summary
Task windows are mixed elapsed time, not inference or active labor. A counted group
must contain only one accounting level: no counted parent and descendant. Keep
CI jobs and steps, and command wrappers and build phases, in separate groups.
The script records data only. It does not execute commands or publish Git changes.
"""
import argparse,datetime as dt,json,pathlib,os,sys,tempfile,math
UTC=dt.timezone.utc

def now():return dt.datetime.now(UTC).isoformat().replace('+00:00','Z')
def date(x):
 d=dt.datetime.fromisoformat(x.replace('Z','+00:00'))
 if d.tzinfo is None:raise ValueError('timestamps must include timezone')
 return d

def union_seconds(pairs):
 merged=[]
 for s,e in sorted(pairs):
  if merged and s<=merged[-1][1]:merged[-1]=(merged[-1][0],max(e,merged[-1][1]))
  else:merged.append((s,e))
 return sum((e-s).total_seconds() for s,e in merged)

def effective_group(x):
 return x.get('accounting_group') or x.get('subtotal') or ('ci_job' if x.get('category')=='ci' else 'legacy_unassigned')

def summary(items):
 groups={}
 for x in items:
  if not x.get('include_in_totals'):continue
  group=effective_group(x)
  g=groups.setdefault(group,{'count':0,'known_duration_count':0,'resource_seconds_sum':0,'wall_coverage_seconds':0,'category_seconds':{},'resource_seconds':{},'_spans':[]})
  g['count']+=1;s=x.get('duration_seconds')
  if s is not None:
   g['known_duration_count']+=1;g['resource_seconds_sum']+=s
   for key,field in [('category_seconds','category'),('resource_seconds','resource')]:g[key][x[field]]=g[key].get(x[field],0)+s
  if x.get('start_utc') and x.get('end_utc'):g['_spans'].append((date(x['start_utc']),date(x['end_utc'])))
 for g in groups.values():g['wall_coverage_seconds']=union_seconds(g.pop('_spans'))
 return {'warning':'Separate accounting groups may overlap; never add their totals blindly. Resource sums are not elapsed time, labor or inference. Unknown durations are not zero. Wall coverage includes only items with both timestamps.','groups':groups}

def validate(items):
 ids={x['id']:x for x in items}
 if len(ids)!=len(items):raise ValueError('duplicate item id')
 for x in items:
  if x.get('duration_seconds') is not None and (not math.isfinite(x['duration_seconds']) or x['duration_seconds']<0):raise ValueError('duration must be finite and nonnegative')
  for field in ['start_utc','end_utc']:
   if x.get(field):date(x[field])
  if x.get('start_utc') and x.get('end_utc') and date(x['end_utc'])<date(x['start_utc']):raise ValueError('end precedes start')
  parent=x.get('parent_id');seen={x['id']}
  while parent:
   if parent in seen:raise ValueError('parent cycle')
   seen.add(parent)
   if parent not in ids:raise ValueError('unknown parent '+parent)
   p=ids[parent]
   if x.get('include_in_totals') and p.get('include_in_totals') and effective_group(x)==effective_group(p):raise ValueError('parent and descendant counted in same group')
   parent=p.get('parent_id')

def update_report(p,d):
 report=p.with_name('duration.md')
 if not report.exists():return
 marker='<!-- duration-track: prospective -->'
 text=report.read_text().split(marker)[0].rstrip()
 lines=[marker,'## New tracked work','',f"Updated: {d['as_of_utc']}. Historical CI coverage above retains its own cutoff.",'','Task windows include research, tools, transport and waiting. They are excluded from resource totals and do not measure active labor or model inference.','','| Item | Class | Start UTC | End UTC | Duration (seconds) | Outcome |','|---|---|---|---|---:|---|']
 esc=lambda x:str(x if x is not None else 'unknown').replace('|','/').replace('\n',' ')
 for x in d['items']:
  if x.get('prospective') or x.get('tracking_state'):
   lines.append('| '+' | '.join(esc(x.get(k)) for k in ['activity','category','start_utc','end_utc','duration_seconds','outcome'])+' |')
 lines+=['','### Current counted resource groups','','Separate groups may overlap. Never add these blindly. Historical log components/receipts retain their separate disclosed subtotals above.','','| Group | Items | Resource sum (seconds) | Known-span wall union (seconds) |','|---|---:|---:|---:|']
 for name,g in d['grouped_current']['groups'].items():lines.append(f"| {esc(name)} | {g['count']} | {g['resource_seconds_sum']:.3f} | {g['wall_coverage_seconds']:.3f} |")
 lines+=['','See duration-data.json for source, resource, uncertainty, parent relationships and per-category totals. Use duration-track.py begin/end for mixed task windows and record for explicitly measured commands; unknown inference stays null.','']
 report.write_text(text+'\n\n'+'\n'.join(lines))

def save(p,d):
 validate(d['items']);d['as_of_utc']=now();d['grouped_current']=summary(d['items'])
 fd,tmp=tempfile.mkstemp(prefix=p.name+'.',dir=p.parent)
 try:
  with os.fdopen(fd,'w') as f:json.dump(d,f,indent=2);f.write('\n')
  os.replace(tmp,p)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
 update_report(p,d)

p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter);p.add_argument('--ledger',default='duration-data.json');sub=p.add_subparsers(dest='action',required=True)
for name in ['begin','record']:
 q=sub.add_parser(name);q.add_argument('id');q.add_argument('--activity',required=True);q.add_argument('--category',required=True);q.add_argument('--resource',required=True);q.add_argument('--source',required=True);q.add_argument('--parent');q.add_argument('--start');q.add_argument('--uncertainty',default='')
 if name=='record':q.add_argument('--end');q.add_argument('--duration',type=float);q.add_argument('--basis',required=True);q.add_argument('--count-group');q.add_argument('--outcome',required=True)
q=sub.add_parser('end');q.add_argument('id');q.add_argument('--end');q.add_argument('--outcome',required=True)
sub.add_parser('summary');a=p.parse_args();path=pathlib.Path(a.ledger);d=json.loads(path.read_text())
try:
 if a.action=='summary':print(json.dumps(summary(d['items']),indent=2));sys.exit(0)
 if a.action in ['begin','record']:
  if any(x['id']==a.id for x in d['items']):raise ValueError('id already exists')
  begin=a.action=='begin';count=None if begin else a.count_group
  x=dict(id=a.id,category=a.category,activity=a.activity,start_utc=(a.start or now()) if begin else a.start,end_utc=None if begin else a.end,duration_seconds=None if begin else a.duration,duration_basis='mixed task elapsed window; includes research/tools/transport/wait, not active labor or inference' if begin else a.basis,resource=a.resource,outcome='in_progress' if begin else a.outcome,source=a.source,uncertainty=a.uncertainty,include_in_totals=bool(count),accounting_group=count or 'task_window' if begin else count or 'uncounted_observation',parent_id=a.parent,prospective=True,inference_duration_seconds=None,inference_status='unavailable')
  if begin:x['tracking_state']='open'
  d['items'].append(x)
 else:
  x=next((x for x in d['items'] if x['id']==a.id),None)
  if x is None:raise ValueError('unknown id')
  if x.get('tracking_state')!='open':raise ValueError('only an open task window can be ended; do not overwrite immutable command receipts')
  x['end_utc']=a.end or now();x['duration_seconds']=(date(x['end_utc'])-date(x['start_utc'])).total_seconds();x['outcome']=a.outcome;x['tracking_state']='closed'
 save(path,d);print(json.dumps(x,indent=2))
except ValueError as e:p.error(str(e))
