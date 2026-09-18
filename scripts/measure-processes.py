#!/usr/bin/env python3
"""Sample an explicitly identified app process set; RSS is a conservative sum."""
import argparse
import json
import platform
import statistics
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--pids', nargs='+', type=int, required=True)
parser.add_argument('--seconds', type=int, default=60)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert 1 <= args.seconds <= 300

def cpu_seconds(value):
    parts = value.split(':')
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(parts)))

def sample():
    text = subprocess.check_output(['ps', '-p', ','.join(map(str, args.pids)), '-o', 'pid=,ppid=,rss=,time=,comm='], text=True)
    items = []
    for line in text.splitlines():
        pid, parent, rss, cpu, command = line.strip().split(None, 4)
        items.append({'pid': int(pid), 'parent': int(parent), 'rssBytes': int(rss) * 1024, 'cpuSeconds': cpu_seconds(cpu), 'command': command})
    assert {item['pid'] for item in items} == set(args.pids), 'An identified process exited; repeat with the correct process set'
    return {'at': time.monotonic(), 'rssBytes': sum(item['rssBytes'] for item in items), 'cpuSeconds': sum(item['cpuSeconds'] for item in items), 'processes': items}

samples = [sample()]
for _ in range(args.seconds):
    time.sleep(1)
    samples.append(sample())
duration = samples[-1]['at'] - samples[0]['at']
report = {'hardware': subprocess.check_output(['sysctl', '-n', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string'], text=True).splitlines(),
          'os': platform.platform(), 'durationSeconds': duration, 'samples': len(samples),
          'aggregateRssMeanBytes': statistics.mean(item['rssBytes'] for item in samples),
          'aggregateRssPeakBytes': max(item['rssBytes'] for item in samples),
          'aggregateCPUPercentOfOneCore': (samples[-1]['cpuSeconds'] - samples[0]['cpuSeconds']) / duration * 100,
          'first': samples[0], 'last': samples[-1],
          'method': 'Sum RSS of explicitly identified native, Node and WebKit processes; shared pages may be counted more than once. CPU is cumulative process-time delta over the sampling interval.'}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key not in ('first', 'last')}, indent=2))
