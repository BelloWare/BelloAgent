#!/usr/bin/env python3
"""v3/v4/v5 clone/copy crash and I/O matrix, using generated fault sources."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

BUILD = Path(os.environ['PI_BUILD_ROOT'])

def command(bundle, test):
    assert bundle.exists(), bundle
    return ['xcrun','xctest','-XCTest','PiAgentCoreTests.JournalPromotionTests/'+test,str(bundle)]

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--fault-bundle',type=Path,required=True); parser.add_argument('--recovery-bundle',type=Path,required=True)
    args=parser.parse_args(); logs=BUILD/'logs/round2/promotion-faults'; logs.mkdir(parents=True,exist_ok=True)
    total=0
    for version in (3,4,5):
        for child in (False,True):
            for copy in (False,True):
                stages=('verified','copy','installed','renamed') if copy else ('cloned','marker','verified','copy','installed','renamed')
                for stage in stages:
                    for crash in (False,True):
                        point=f'v{version}-{"recipient" if child else "owner"}-promotion-{stage}'
                        label=point+('-copy' if copy else '-clone')+('-crash' if crash else '-failure')
                        with tempfile.TemporaryDirectory(prefix='promotion-fault-',dir=BUILD) as directory:
                            root=Path(directory); barrier=root/'barrier'
                            env=dict(os.environ,PI_PROMOTION_FIXTURE=directory,PI_PROMOTION_VERSION=str(version),PI_PROMOTION_CHILD=str(int(child)),PI_PROMOTION_COPY=str(int(copy)),PI_CUTIN_BARRIER_FILE=str(barrier),NSUnbufferedIO='YES')
                            for key in ('PI_CUTIN_MUTATION','PI_CUTIN_CRASH_POINT','PI_CUTIN_FAILURE'): env.pop(key,None)
                            fault=dict(env); fault['PI_CUTIN_CRASH_POINT' if crash else 'PI_CUTIN_FAILURE']=point
                            with (logs/(label+'.log')).open('w') as log:
                                process=subprocess.Popen(command(args.fault_bundle,'testPromotionFaultFixture'),env=fault,stdout=log,stderr=subprocess.STDOUT)
                                try:
                                    if crash:
                                        deadline=time.monotonic()+30
                                        while not barrier.exists():
                                            assert process.poll() is None and time.monotonic()<deadline, (label,'barrier not reached')
                                            time.sleep(.01)
                                        pid=int(barrier.read_text().splitlines()[1]); os.kill(pid,signal.SIGKILL)
                                    assert process.wait(timeout=30) != 0, (label,'fault did not fail')
                                finally:
                                    if process.poll() is None: process.kill(); process.wait()
                            assert barrier.exists(), (label,'fault switch was not reached')
                            before=[json.loads(line) for line in (root/'before.jsonl').read_bytes().splitlines()]
                            rows=[json.loads(line) for line in (root/'promotion.jsonl').read_bytes().splitlines()]
                            expected=f'pi-app.native.v{version}' if stage in ('installed','renamed') else 'pi-app.native.v2' if child else 'pi-app.native.v1'
                            assert rows[1]['customType']==expected, (label,rows[1])
                            before[1]['customType']=expected
                            assert rows==before, (label,'promotion changed other journal content')
                            env['PI_PROMOTION_EXPECTED']=expected
                            with (logs/(label+'-reopen.log')).open('w') as log:
                                subprocess.run(command(args.recovery_bundle,'testReopenPromotionFaultFixture'),env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=30)
                            assert 'Executed 1 test' in (logs/(label+'-reopen.log')).read_text()
                            rows=[json.loads(line) for line in (root/'promotion.jsonl').read_bytes().splitlines()]
                            previous=None; seen=set()
                            for row in rows[1:]:
                                assert row.get('parentId')==previous and row['id'] not in seen, (label,'broken chain')
                                previous=row['id']; seen.add(previous)
                            assert previous=='after'
                            total+=1; print('PASS',label,flush=True)
    print(f'PASS {total} promotion crash/failure cases with clean reopen',flush=True)

if __name__ == '__main__': main()
