#!/usr/bin/env python3
"""Throw generated append/fsync failures at each cut, delivery and settlement row."""
import argparse
import importlib.util
from pathlib import Path

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file)); value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value

if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('recovery'); parser.add_argument('--skip-build',action='store_true'); parser.add_argument('--points',nargs='+')
    args=parser.parse_args(); crash=module('crash','test-subagent-cutin-crashes.py'); cutin=module('cutin','test-subagent-cutin.py')
    binary=crash.BUILD/'cutin-crash-build/debug/pi-native-host' if args.skip_build else crash.build()
    points=[f'{name}-{edge}' for name in ('preparation','owner-commit','recipient-commit','prefix','call-result','delivery-prepare','delivery-row','delivery-ack','delivery-mirror','continuation-admit','continuation-dispatch','drain-cost') for edge in ('write','sync')]
    for point in args.points or points:
        cutin.run(str(binary),'terminal_race' if point.startswith('drain-cost') else 'reasoning',failure_point=point,recovery=args.recovery)
