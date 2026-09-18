#!/usr/bin/env python3
"""Stage the native Swift helper for the Xcode copy phase. Nothing else is
built here: the app is Swift, the transcript is native, and no runtime or
package manager is involved."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
if platform.system() != 'Darwin':
    raise SystemExit('App staging requires macOS. On Linux use swift test --package-path packages/swift-host.')
if not os.environ.get('PI_BUILD_ROOT'):
    raise SystemExit('Set PI_BUILD_ROOT to a scratch directory outside the repository')
SCRATCH = Path(os.environ['PI_BUILD_ROOT']).expanduser().resolve()
if SCRATCH == ROOT or ROOT in SCRATCH.parents or SCRATCH in ROOT.parents:
    raise SystemExit('PI_BUILD_ROOT must be outside, and must not contain, the source repository')
SCRATCH.mkdir(parents=True, exist_ok=True)
BUNDLE = SCRATCH / 'bundle'
if BUNDLE.exists():
    shutil.rmtree(BUNDLE)
for name in ('Helpers', 'Host'):
    (BUNDLE / name).mkdir(parents=True)

def run(*args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)

common = ['swift', 'build', '--package-path', str(ROOT / 'packages/swift-host'),
          '--scratch-path', str(SCRATCH / 'swift-host'), '--configuration', 'release', '--arch', 'arm64']
run(*common, '--product', 'pi-native-host', '-Xswiftc', '-Osize')
bin_dir = Path(subprocess.check_output(common + ['--show-bin-path'], cwd=ROOT, text=True).strip())
helper = BUNDLE / 'Helpers/pi-native-host'
shutil.copy2(bin_dir / 'pi-native-host', helper)
# Keep a dSYM for crash symbolication; the shipped helper is fully stripped at release.
helper_dsym = SCRATCH / 'pi-native-host.dSYM'
if helper_dsym.exists():
    shutil.rmtree(helper_dsym)
run('xcrun', 'dsymutil', helper, '-o', helper_dsym)
run('xcrun', 'strip', '-S', helper)
helper.chmod(0o755)
run('lipo', helper, '-verify_arch', 'arm64')
manifest = {'engine': 'swift', 'engineVersion': '1.0.0', 'protocolMajor': 1, 'protocolMinor': 1,
            'piBehaviorReference': '0.85.1', 'bundledNode': False,
            'runtimeDependencies': 'macOS system libraries', 'entry': 'Contents/Helpers/pi-native-host'}
(BUNDLE / 'Host/bundle-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
shutil.copy2(ROOT / 'packages/swift-host/NOTICE', BUNDLE / 'Host/NOTICE')
assert not (BUNDLE / 'Helpers/node').exists()
assert not list(BUNDLE.rglob('node_modules'))
print(f'Native bundle staged at {BUNDLE}; helper {helper.stat().st_size / 1048576:.2f} MiB. DMG size is not yet measured.')
