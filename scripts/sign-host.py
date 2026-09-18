#!/usr/bin/env python3
"""Sign the native helper before the outer app; no Node/V8 JIT entitlement."""
import os
from pathlib import Path
import subprocess
import sys
from release_signing import sign

app = Path(sys.argv[1]).resolve()
helper = app / 'Contents/Helpers/pi-native-host'
identity = os.environ.get('SIGN_IDENTITY', 'Developer ID Application: Zhaofeng Wang (43TXHV3TM3)')
if not helper.is_file() or (app / 'Contents/Helpers/node').exists():
    raise SystemExit('Expected only the native helper; rebuild the staged bundle')
if list((app / 'Contents/Resources/Host').rglob('node_modules')):
    raise SystemExit('Unexpected npm runtime dependencies in the application')
sign(helper, identity=identity)
subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
print('Signed native Swift host without JIT entitlements')
