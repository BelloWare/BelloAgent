#!/usr/bin/env python3
"""Signed ordinary macOS Keychain acceptance, isolated synthetic item only.

No provisioning profile, notarization, model call, production-vault read or
signing-key export. Raw same-user update/delete behavior is observed explicitly;
ordinary Keychain policy does not promise per-application write isolation.
"""
import argparse
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('scratch', type=Path)
parser.add_argument('--identity', default='Developer ID Application: Zhaofeng Wang (43TXHV3TM3)')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
work = args.scratch.resolve() / ('keychain-' + str(uuid.uuid4()))
work.mkdir(parents=True, mode=0o700)
storage = root / 'apps/macos/PiApp/Storage'
for name, defines in [('owner', []), ('update', ['-D', 'UPDATE_PROBE'])]:
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors', '-O',
        str(storage/'KeychainVaultStorage.swift'),
        str(root/'fixtures/native/keychain-probe.swift'), '-o', str(work/name)] + defines, check=True, timeout=120)
executables = {}
for name, identity in [('owner', 'com.belloware.PiApp'), ('update', 'com.belloware.PiApp'),
                       ('other', 'com.belloware.PiApp.acceptance.other'), ('helper', 'com.belloware.PiApp.native-host'),
                       ('adhoc', 'com.belloware.PiApp')]:
    app = work/(name+'.app'); contents = app/'Contents'; binary = contents/'MacOS/probe'
    binary.parent.mkdir(parents=True)
    shutil.copyfile(work/('update' if name=='update' else 'owner'), binary); binary.chmod(0o700)
    (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identity, 'CFBundleExecutable': 'probe',
        'CFBundleName': 'Pi Vault Acceptance', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '2' if name=='update' else '1'}))
    # The test proves the installed Developer ID identity locally. Production
    # release signing separately requires a secure timestamp and notarization.
    sign = '-' if name=='adhoc' else args.identity
    subprocess.run(['codesign', '--force', '--sign', sign, '--timestamp=none', '--identifier', identity,
                    '--options', 'runtime', str(app)], check=True, timeout=120)
    executables[name] = binary
assert executables['owner'].read_bytes() != executables['update'].read_bytes(), 'Update must be a changed executable'
shutil.copytree(work/'owner.app', work/'tampered.app')
tampered = work/'tampered.app/Contents/MacOS/probe'
blob = bytearray(tampered.read_bytes()); marker = blob.index(b'SYNTHETIC-VAULT-ACCEPTANCE-ONLY'); blob[marker] = ord('X'); tampered.write_bytes(blob)
executables['tampered'] = tampered
service = 'com.belloware.PiApp.acceptance.' + str(uuid.uuid4())
results = []

def probe(executable, operation, allowed=True):
    p = subprocess.run([str(executables[executable]), operation, service, str(work/'vault.lock')],
                       capture_output=True, text=True, timeout=20)
    # None means record the standard Keychain policy, without imposing stronger
    # cross-application write/delete isolation than the chosen backend provides.
    passed = p.returncode in (0, 3) if allowed is None else (p.returncode == 0) == allowed
    if allowed is False and executable != 'tampered':
        passed = p.returncode == 3 and (p.stdout.startswith('status=-') or p.stdout.strip() == 'denied unsigned')
    result = {'executable': executable, 'operation': operation, 'expectedAllowed': allowed,
              'observedAllowed': p.returncode == 0, 'exit': p.returncode,
              'result': p.stdout.strip(), 'pass': passed}
    if allowed is None: result['policy'] = 'standard-keychain-observation-not-write-isolation'
    results.append(result)
    print(json.dumps(result), flush=True)
    if not passed: raise RuntimeError('Keychain acceptance failed: ' + executable + ' ' + operation)
    return p.returncode == 0

def race_updates():
    processes = [subprocess.Popen([str(executables[name]), 'update', service, str(work/'vault.lock')],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                 for name in ['owner', 'update']]
    try:
        outputs = [p.communicate(timeout=20)[0].strip() for p in processes]
        codes = [p.returncode for p in processes]
        passed = codes.count(0) == 1 and codes.count(3) == 1 and all(
            code == 0 or output in ['denied conflict', 'denied busy'] for code, output in zip(codes, outputs))
        result = {'operation': 'concurrent-owner-update', 'exits': codes, 'results': outputs, 'pass': passed}
        results.append(result)
        print(json.dumps(result), flush=True)
        if not passed: raise RuntimeError('Concurrent Keychain updates lost compare-and-replace protection')
    finally:
        for p in processes:
            if p.poll() is None: p.kill(); p.communicate()

try:
    probe('owner', 'missing')
    probe('owner', 'conflict-missing')
    probe('owner', 'missing')
    probe('owner', 'create')
    probe('owner', 'read')
    probe('owner', 'conflict-create')
    probe('owner', 'read')
    probe('update', 'read')
    probe('update', 'update')
    probe('update', 'read-updated')
    probe('owner', 'read-updated')
    probe('owner', 'conflict-stale')
    probe('update', 'read-updated')
    for name in ['other', 'helper', 'adhoc']:
        probe(name, 'read', False)  # Production self-identity check.
        probe(name, 'update', False)
        probe(name, 'raw-read', False)  # OS check, no application guard.
    probe('tampered', 'raw-read', False)
    probe('owner', 'read-updated')
    for name in ['other', 'helper', 'adhoc']:
        if probe(name, 'raw-update', None):
            # Standard Keychain raw tampering can alter subsequent access as
            # well as bytes. Observe that limit; do not assert app isolation.
            if probe('owner', 'read-raw-update', None):
                probe('owner', 'restore')
            else:
                # Reset only this script's synthetic item so later cases are
                # independent of the deliberately foreign raw modification.
                probe('owner', 'cleanup')
                probe('owner', 'create')
                probe('update', 'update')
        probe('owner', 'read-updated')
        if probe(name, 'raw-delete', None):
            probe('owner', 'missing')
            probe('owner', 'create')
            probe('update', 'update')
        probe('owner', 'read-updated')
    probe('owner', 'cleanup')
    probe('owner', 'create')
    race_updates()
    probe('owner', 'read-updated')
    probe('update', 'read-updated')
finally:
    try:
        probe('owner', 'cleanup')
        probe('owner', 'missing')
    finally:
        (work/'report.json').write_text(json.dumps(results, indent=2) + '\n')
print('Isolated signed Keychain checks passed:', len(results))
print('Report:', work/'report.json')
