#!/usr/bin/env python3
"""Verify the scoped Skills publication overlay and frozen LOC evidence.

Read-only Git/filesystem plus a disposable extraction of the pinned audit archive.
No network, builds, Git mutations, source-tree copies or native execution.
"""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile

BASE = '2ffbc323b9ad006683c2fef1eafa23f4990d8da5'
TREE = '529ba4b5b54031db5d40c63413f1d1f5df6e3c21'
PREFIX = 'rust/docs/validation/skill-source-identity-2026-10-07/'
SCRIPT = 'rust/scripts/verify-skill-source-identity-final-2026-10-07.py'
INPUTS = PREFIX + 'publication-inputs.json'
INPUTS_SHA = '8bb5b809243063c1065412612a6b6ba9ca016e6b5aa4a5a2ddf6797bf8ee34ca'
ARCHIVE_SHA = '77bbf47ee8c01e02296c98d7650b0b0617aa541e20d4b40ca96059e863a00428'
VERIFY_SHA = '65fb477c78ee267dda2c297891dcd56b8506a3bd1759a9b78eeaa919167d424a'
HERE = Path(__file__).resolve()
EVIDENCE = HERE.parent.parent / 'docs/validation/skill-source-identity-2026-10-07'


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def overlay_sources(root):
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'Unexpected overlay symlink: ' + str(path))
        if path.is_file():
            result[path.relative_to(root).as_posix()] = path.read_bytes()
    return result


def load_audit(directory, archive):
    require(sha(archive) == ARCHIVE_SHA, 'LOC archive bytes changed')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        names = set()
        for member in tar.getmembers():
            require(member.isfile() and Path(member.name).name == member.name,
                    'Unexpected audit member')
            require(member.name not in names, 'Duplicate audit member')
            names.add(member.name)
            data = tar.extractfile(member).read()
            (directory / member.name).write_bytes(data)
    require(sha((directory / 'verify-skill-path-loc.py').read_bytes()) == VERIFY_SHA,
            'Archived verifier changed')
    hashes = json.loads((directory / 'artifact-sha256.json').read_bytes())
    for name, expected in hashes.items():
        require(sha((directory / name).read_bytes()) == expected,
                'Archived evidence changed: ' + name)
    spec = importlib.util.spec_from_file_location(
        'frozen_skill_path_audit', directory / 'verify-skill-path-loc.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    return verifier


def verify_payload(verifier, old, current, inputs):
    expected = set()
    for entry in inputs['files']:
        path = entry['path']
        require(path not in expected, 'Duplicate publication path')
        expected.add(path)
        before = old.get(path)
        require((sha(before) if before is not None else None) == entry['before_sha256'],
                'Baseline preimage differs: ' + path)
        require((blob(before) if before is not None else None) == entry['before_git_blob'],
                'Baseline blob differs: ' + path)
        require(path in current, 'Missing publication file: ' + path)
        after = current[path]
        require(sha(after) == entry['after_sha256']
                and blob(after) == entry['after_git_blob']
                and len(after) == entry['after_bytes'], 'Afterimage differs: ' + path)
        require(entry['mode'] == '100644', 'Unexpected publication mode')
    require(INPUTS not in old and SCRIPT not in old, 'New verification path already exists')
    require(current[INPUTS] == (EVIDENCE / 'publication-inputs.json').read_bytes(),
            'Published input manifest differs from trusted verifier inputs')
    require(current[SCRIPT] == HERE.read_bytes(), 'Published verifier differs from running script')
    expected.update((INPUTS, SCRIPT))
    changed = {path for path in old.keys() | current.keys() if old.get(path) != current.get(path)}
    require(changed == expected, 'Unexpected/missing publication delta: ' + str(sorted(changed ^ expected)))
    freeze_bytes = (EVIDENCE / 'source-freeze.json').read_bytes()
    require(sha(freeze_bytes) == verifier.FREEZE_SHA, 'Six-file freeze changed')
    frozen = dict(old)
    freeze = json.loads(freeze_bytes)
    for entry in freeze:
        path = entry['path']
        require(sha(current[path]) == entry['sha256'], 'Frozen correction changed: ' + path)
        frozen[path] = current[path]
    require(verifier.rust_only(current) == verifier.rust_only(frozen),
            'Publication overlay changes Rust beyond the six-file correction')
    return frozen, freeze_bytes, sorted(changed)


def git_modes(verifier, repo, revision):
    result = {}
    for row in verifier.git(repo, 'ls-tree', '-rz', revision).split(b'\0'):
        if row:
            meta, name = row.split(b'\t', 1)
            mode, kind, _ = meta.decode().split()
            require(kind == 'blob', 'Unexpected non-blob Git entry')
            result[name.decode()] = mode
    return result


def verify_modes(old, current, inputs):
    expected = dict(old)
    for entry in inputs['files']:
        expected[entry['path']] = entry['mode']
    expected[INPUTS] = expected[SCRIPT] = '100644'
    require(current == expected, 'Publication Git file modes differ')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--after', help='Immutable candidate commit/tree')
    source.add_argument('--overlay', type=Path, help='Scoped publication files directory')
    args = parser.parse_args()
    inputs_bytes = (EVIDENCE / 'publication-inputs.json').read_bytes()
    require(sha(inputs_bytes) == INPUTS_SHA, 'Publication inputs changed')
    inputs = json.loads(inputs_bytes)
    require(inputs['baseline_commit'] == BASE and inputs['baseline_tree'] == TREE,
            'Publication baseline differs')
    archive = (EVIDENCE / 'loc-audit.tar.gz').read_bytes()
    with tempfile.TemporaryDirectory(prefix='skill-path-loc-') as scratch:
        audit = Path(scratch)
        verifier = load_audit(audit, archive)
        verifier.verify_ref(args.repo, BASE, TREE)
        verifier.verify_ref(args.repo, verifier.SKILLS_TREE, verifier.SKILLS_TREE)
        old = verifier.git_sources(args.repo, BASE)
        if args.after:
            current = verifier.git_sources(args.repo, args.after)
            verify_modes(git_modes(verifier, args.repo, BASE),
                         git_modes(verifier, args.repo, args.after), inputs)
        else:
            overlay = overlay_sources(args.overlay)
            declared = {entry['path'] for entry in inputs['files']} | {INPUTS, SCRIPT}
            require(set(overlay) == declared, 'Overlay file allowlist differs')
            current = dict(old)
            current.update(overlay)
        frozen, freeze_bytes, changed = verify_payload(verifier, old, current, inputs)
        skills = verifier.git_sources(args.repo, verifier.SKILLS_TREE)
        bash_copy = (audit / 'immutable-prior-bash-ledger.json').read_bytes()
        historical_bash = verifier.rust_only(old)
        for path, entry in json.loads(bash_copy)['after_rust_sources'].items():
            if sha(historical_bash[path]) != entry['sha256']:
                historical_bash[path] = verifier.git(args.repo, 'cat-file', 'blob', entry['git_blob'])
                require(sha(historical_bash[path]) == entry['sha256'], 'Historical Bash blob differs')
        result = verifier.verify_report(
            json.loads((audit / 'loc-skill-source-path-delta.json').read_bytes()),
            skills, old, frozen, freeze_bytes,
            (audit / 'immutable-prior-skills-ledger.json').read_bytes(), bash_copy,
            historical_bash, (audit / 'historical-c0-source-path-audit.json').read_bytes())
        result.update({
            'publication_overlay': 'verified exact scoped afterimages and preimages',
            'publication_file_count': len(changed),
            'checked_git_revision': args.after,
            'readiness_overlay': 'separate documentation-only, exact reviewed afterimages',
            'rust_changes_beyond_frozen_correction': False,
            'remote_publication_verified': False,
            'limits': 'Source/LOC provenance only; no build, CI, native or performance acceptance.'})
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('VERIFICATION FAILED: ' + str(error), file=sys.stderr)
        sys.exit(1)
