#!/usr/bin/env python3
from pathlib import Path
import re, shutil, hashlib, json
source=Path('/workspace/shared/catalog-native-integrated-stage');target=Path('/workspace/shared/catalog-native-app-focused')
if not target.exists():shutil.copytree(source,target,ignore=shutil.ignore_patterns('__pycache__','target','.git'))
root=source/'rust/crates/bello-agent-app/src'
rx=re.compile(r'(?m)^(?P<indent>[ \t]*)#\[cfg\((?P<cfg>[^\n]*)\)\]\n(?P<attrs>(?:[ \t]*#\[[^\n]*\]\n)*)(?P<decl>[ \t]*(?:pub(?:\([^\n]*?\))?[ \t]+)?mod[ \t]+(?P<name>\w+)[ \t]*(?:;|\{))')
rows=[];excluded=[]
for p in root.rglob('*.rs'):
    rel=str(p.relative_to(source));text=p.read_text();changes=[]
    for m in rx.finditer(text):
        if not re.search(r'\btest\b',m['cfg']):continue
        unit=m['name']=='tests' or m['name'].endswith('_tests') or m['name']=='transcript_benchmark'
        if not unit or (p.name.startswith('connection_') or p.name == 'launch_authority.rs'):continue
        assert m['cfg']=='test' or m['cfg'].startswith('all(test, '),(rel,m['name'],m['cfg'])
        start=m.start()+len(m['indent']);old=f"#[cfg({m['cfg']})]";assert text[start:start+len(old)]==old
        changes.append((start,old,'#[cfg(any())]'))
        excluded.append({'path':rel,'line':text.count('\n',0,start)+1,'module':m['name'],'before':old,'after':'#[cfg(any())]'})
    altered=text
    for start,old,new in reversed(changes):altered=altered[:start]+new+altered[start+len(old):]
    # No token outside test-only module guards is changed.
    restored=altered;delta=0;shifted=[]
    for start,old,new in changes:shifted.append((start+delta,old,new));delta+=len(new)-len(old)
    for start,old,new in reversed(shifted):assert restored[start:start+len(new)]==new;restored=restored[:start]+old+restored[start+len(new):]
    assert restored==text
    out=target/rel;out.parent.mkdir(parents=True,exist_ok=True);out.write_text(altered)
    rows.append({'path':rel,'source_sha256':hashlib.sha256(text.encode()).hexdigest(),'harness_sha256':hashlib.sha256(altered.encode()).hexdigest()})
for subtree in ['rust/crates/bello-agent-core','catalogs','assets']:shutil.copytree(source/subtree,target/subtree,dirs_exist_ok=True)
manifest=(source/'rust/Cargo.toml').read_text();extra='\n# Harness-only memory bound; shipping manifest is unchanged.\n[profile.test.package.bello-agent-app]\ncodegen-units = 256\n'
(target/'rust/Cargo.toml').write_text(manifest+extra)
provenance={'scope':'All production tokens are unchanged. Unrelated App test modules/helpers are excluded only with cfg(any()); all Connections tests stay exact. App-only harness test codegen-units=256 reduces LLVM peak. This is not the full App suite.','source':str(source),'target':str(target),'files':rows,'excluded_modules':excluded,'manifest_source_sha256':hashlib.sha256(manifest.encode()).hexdigest(),'manifest_suffix':extra}
(target/'focused-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
print(len(excluded),'test/helper modules excluded; Connections tests retained; App test codegen-units=256')
