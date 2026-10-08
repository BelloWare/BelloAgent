#!/usr/bin/env python3
"""Create an exact-source focused test copy without building or editing canonical input."""
from pathlib import Path
import hashlib, json, re, shutil
SOURCE = Path('/workspace/shared/catalog-native-integrated-stage')
DEST = Path('/workspace/shared/catalog-native-core-focused')
if DEST.exists():
    raise SystemExit(f'Refusing to overwrite an existing harness: {DEST}')
DEST.mkdir()
# Keep the workspace manifest and lock exactly unchanged. The app is copied
# byte-for-byte solely to satisfy workspace membership; -p selects core only.
for part in ('rust', 'catalogs'):
    shutil.copytree(SOURCE / part, DEST / part)
for name in ('AGENTS.md', 'NEXT-RELEASE.md'):
    shutil.copy2(SOURCE / name, DEST / name)
sha = lambda b: hashlib.sha256(b).hexdigest()
canonical = {str(p.relative_to(SOURCE)): sha(p.read_bytes())
             for part in ('rust','catalogs') for p in sorted((SOURCE / part).rglob('*')) if p.is_file()}
rx = re.compile(r'(?m)^(?P<indent>[ \t]*)#\[cfg\((?P<cfg>[^\n]*)\)\]\n(?P<attrs>(?:[ \t]*#\[[^\n]*\]\n)*)(?P<decl>[ \t]*(?:pub(?:\([^\n]*?\))?[ \t]+)?mod[ \t]+(?P<name>\w+)[ \t]*(?:;|\{))')
keep_paths = {'model_catalog.rs', 'connection_vault.rs', 'native.rs'}
exclusions, retained_modules = [], []
for path in sorted((DEST / 'rust/crates/bello-agent-core/src').rglob('*.rs')):
    rel = str(path.relative_to(DEST))
    original = path.read_text()
    replacements = []
    for match in rx.finditer(original):
        if not re.search(r'\btest\b', match['cfg']):
            continue
        record = {'path':rel, 'line':original.count('\n',0,match.start())+1,
                  'module':match['name'], 'original_guard':f"#[cfg({match['cfg']})]"}
        unit_module = match['name'] == 'tests' or match['name'].endswith('_tests')
        if not unit_module or path.name in keep_paths:
            record['reason'] = 'focused test module' if unit_module else 'production or test-support module'
            retained_modules.append(record)
            continue
        # Exclusions are restricted to modules whose original condition
        # requires cfg(test), never production-or-test implementation modules.
        assert match['cfg'] == 'test' or match['cfg'].startswith('all(test, '), record
        old = record['original_guard']
        offset = match.start() + len(match['indent'])
        assert original[offset:offset+len(old)] == old
        replacements.append((offset, old, '#[cfg(any())]'))
        record['replacement_guard'] = '#[cfg(any())]'
        exclusions.append(record)
    focused = original
    for offset, old, new in reversed(replacements):
        focused = focused[:offset] + new + focused[offset+len(old):]
    # Exact reconstruction verifies that every byte outside the declared
    # test-module guard replacements, including test-support hooks, is intact.
    restored = focused
    delta = 0
    shifted = []
    for offset, old, new in replacements:
        shifted.append((offset+delta, old, new))
        delta += len(new)-len(old)
    for offset, old, new in reversed(shifted):
        assert restored[offset:offset+len(new)] == new
        restored = restored[:offset] + old + restored[offset+len(new):]
    assert restored == original, rel
    if focused != original:
        path.write_text(focused)
# Verify every copied file against current canonical source, allowing only
# the explicit substitutions above. No app source/manifest changes are allowed.
changed_paths = {entry['path'] for entry in exclusions}
records = []
for rel, before in canonical.items():
    assert sha((SOURCE/rel).read_bytes()) == before, f'Canonical input changed during snapshot: {rel}'
    after = sha((DEST/rel).read_bytes())
    assert before == after or rel in changed_paths, rel
    if '/bello-agent-app/' in rel:
        assert before == after, rel
    records.append({'path':rel, 'canonical_sha256':before, 'focused_sha256':after, 'test_module_guards_only':rel in changed_paths})
provenance = DEST/'provenance'; provenance.mkdir()
shutil.copy2(Path(__file__), provenance/'prepare-catalog-core-focused.py')
manifest = {
 'canonical_root':str(SOURCE), 'focused_root':str(DEST),
 'purpose':'Retain catalog and connection-vault unit tests after full lib-test rustc was SIGKILLed; this is not a full-suite pass.',
 'method':'Only unrelated unit-test-module #[cfg(test)] or #[cfg(all(test, ...))] guards become #[cfg(any())]. All production code, standalone tests and test-support hooks remain unchanged. Canonical stage is read-only.',
 'workspace_manifest_unchanged':True, 'cargo_lock_unchanged':True,
 'app_files_unchanged':True, 'compiled':False,
 'exclusion_count':len(exclusions), 'changed_source_file_count':len(changed_paths),
 'exclusions':exclusions, 'retained_test_or_support_modules':retained_modules,
 'source_hashes':records,
}
(provenance/'exclusion-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(provenance/'canonical.sha256').write_text(''.join(f"{r['canonical_sha256']}  {r['path']}\n" for r in records))
(provenance/'focused.sha256').write_text(''.join(f"{r['focused_sha256']}  {r['path']}\n" for r in records))
(provenance/'verification.txt').write_text(f"Verified {len(records)} copied files.\nExcluded {len(exclusions)} unrelated test modules in {len(changed_paths)} source files.\nEvery edited file reconstructs byte-for-byte to its canonical input by reversing only listed cfg guard substitutions.\nAll production declarations and test-support hooks preserved.\nAll workspace manifests, Cargo.lock, app files and catalog bytes unchanged.\nNo Cargo command, compiler, or test executed.\n")
print((provenance/'verification.txt').read_text(),end='')
