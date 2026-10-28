#!/usr/bin/env python3
"""Release-only generated journal measurement. No app, real data or provider."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import sys
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ['PI_BUILD_ROOT'])
LOCK = Path('/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock')

def busy():
    try: return any(word in (LOCK/'owner').read_text().lower() for word in ('perf','soak'))
    except FileNotFoundError: return False

def load():
    return subprocess.check_output(['sysctl','-n','vm.loadavg'],text=True).strip()

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--label',default='promotion'); parser.add_argument('--skip-build',action='store_true')
    args=parser.parse_args()
    source=BUILD/'promotion-benchmark-source'; source.mkdir(exist_ok=True)
    shutil.copy2(ROOT/'packages/swift-host/Package.swift',source/'Package.swift')
    if not (source/'Sources').exists(): (source/'Sources').symlink_to(ROOT/'packages/swift-host/Sources',target_is_directory=True)
    tests=source/'Tests/PiAgentCoreTests'; tests.mkdir(parents=True,exist_ok=True)
    for name in ('HelperTestCase.swift','JournalPromotionPerformanceTests.swift'):
        shutil.copy2(ROOT/'packages/swift-host/Tests/PiAgentCoreTests'/name,tests/name)
    fixtures=(ROOT/'packages/swift-host/Tests/PiAgentCoreTests/Fixtures.swift').read_text().split('/// Polls until')[0]
    fixtures=fixtures.replace('FileManager.default.temporaryDirectory','URL(fileURLWithPath:ProcessInfo.processInfo.environment["PI_BUILD_ROOT"]!)')
    (tests/'Fixtures.swift').write_text(fixtures)
    common=['swift','test','--package-path',str(source),'--scratch-path',str(BUILD/'swift-host'),'--configuration','release','--arch','arm64','-Xswiftc','-Osize','-Xswiftc','-enable-testing','-j','4','--filter','JournalPromotionPerformanceTests']
    logs=BUILD/'logs/round2'; logs.mkdir(parents=True,exist_ok=True)
    if not args.skip_build:
        while busy(): print('Waiting for PERF-1 before build',flush=True); time.sleep(60)
        with (logs/(args.label+'-build.log')).open('w') as log:
            subprocess.run(common[:1]+['build']+common[2:-2]+['--build-tests'],stdout=log,stderr=subprocess.STDOUT,check=True)
    while True:
        try: LOCK.mkdir(); break
        except FileExistsError: print('Waiting for full-lane lock',flush=True); time.sleep(60)
    try:
        (LOCK/'owner').write_text(f'a136-cutin perf promotion pid={os.getpid()} {time.ctime()}\n')
        while float(load().strip('{} ').split()[0]) > 4:
            print('Waiting for quiet load',load(),flush=True); time.sleep(60)
        with (logs/(args.label+'.log')).open('w') as log:
            log.write('START '+time.ctime()+' load='+load()+'\n'); log.flush()
            result=subprocess.run(common+['--skip-build'],env=dict(os.environ,PI_PROMOTION_PERF='1',NSUnbufferedIO='YES'),stdout=log,stderr=subprocess.STDOUT)
            log.write('END '+time.ctime()+' load='+load()+'\n')
            result.check_returncode()
        print((logs/(args.label+'.log')).read_text(),flush=True)
    finally:
        (LOCK/'owner').unlink(missing_ok=True); LOCK.rmdir()

if __name__ == '__main__':
    signal.signal(signal.SIGTERM,lambda *_: sys.exit(143))
    main()
