#!/usr/bin/env python3
"""Aggregate native/descendant/new WebKit RSS, retaining each timed sample."""
import argparse
import json
import platform
import statistics
import subprocess
import time
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--app-pid',type=int);p.add_argument('--baseline',type=Path,required=True)
p.add_argument('--output',type=Path);p.add_argument('--seconds',type=int,default=120)
p.add_argument('--exclude-pids',type=int,nargs='*',default=[],help='Explicit synthetic fixture processes to exclude, with descendants')
a=p.parse_args()

def processes():
    rows={}
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,time=,comm='],text=True).splitlines():
        pid,parent,rss,cpu,command=line.strip().split(None,4)
        seconds=sum(float(v)*60**i for i,v in enumerate(reversed(cpu.split(':'))))
        rows[int(pid)]={'pid':int(pid),'parent':int(parent),'rssBytes':int(rss)*1024,'cpuSeconds':seconds,'command':command}
    return rows

if not a.app_pid:
    a.baseline.write_text(json.dumps([pid for pid,row in processes().items() if '/com.apple.WebKit.' in row['command']]))
    raise SystemExit(0)
assert a.output and 1<=a.seconds<=3600
baseline=set(json.loads(a.baseline.read_text()));samples=[];cpu_seen={};cpu_used=0
for n in range(a.seconds+1):
    rows=processes();owned={a.app_pid};excluded=set(a.exclude_pids)
    assert a.app_pid in rows, 'Native app exited during measurement'
    for _ in range(8):
        previous=len(owned);owned.update(pid for pid,row in rows.items() if row['parent'] in owned)
        if len(owned)==previous:break
    owned.update(pid for pid,row in rows.items() if '/com.apple.WebKit.' in row['command'] and pid not in baseline)
    for _ in range(8):
        previous=len(excluded);excluded.update(pid for pid,row in rows.items() if row['parent'] in excluded)
        if len(excluded)==previous:break
    owned.difference_update(excluded)
    assert a.app_pid in owned, 'Cannot exclude the measured native app'
    items=[rows[pid] for pid in sorted(owned) if pid in rows]
    for item in items:
        pid=item['pid'];cpu_used+=max(0,item['cpuSeconds']-cpu_seen.get(pid,item['cpuSeconds'] if n==0 else 0));cpu_seen[pid]=item['cpuSeconds']
    samples.append({'at':time.monotonic(),'wallTime':time.time(),'rssBytes':sum(i['rssBytes'] for i in items),'cpuSecondsSinceStart':cpu_used,'processes':items})
    report={'os':platform.platform(),'hardware':subprocess.check_output(['sysctl','-n','hw.model','hw.memsize','machdep.cpu.brand_string'],text=True).splitlines() if n==0 else report['hardware'],
      'durationSeconds':samples[-1]['at']-samples[0]['at'],'samples':samples,
      'excludedFixturePIDs':a.exclude_pids,
      'method':'Sum RSS of native app, descendants and WebKit processes absent from the pre-launch baseline; explicitly excluded fixture PIDs and their descendants are recorded. No other browser activity during sampling. RSS can count shared pages more than once; 1-second sampling may miss shorter peaks.'}
    report.update(aggregateRssMeanBytes=statistics.mean(s['rssBytes'] for s in samples),aggregateRssPeakBytes=max(s['rssBytes'] for s in samples),
      aggregateCPUPercentOfOneCore=cpu_used/max(.001,report['durationSeconds'])*100)
    a.output.write_text(json.dumps(report,indent=2)+'\n')
    if n<a.seconds:time.sleep(1)
print(json.dumps({k:v for k,v in report.items() if k!='samples'},indent=2))
