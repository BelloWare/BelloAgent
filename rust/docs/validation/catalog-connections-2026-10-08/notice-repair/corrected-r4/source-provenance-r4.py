from pathlib import Path
import hashlib,json,sys
stage=Path('/workspace/shared/catalog-native-integrated-stage');out=Path('/workspace/shared/catalog-native-evidence/gui-r4')
files=set(stage.glob('rust/Cargo*'))|set(stage.glob('rust/crates/*/Cargo.toml'))|set(stage.glob('rust/crates/*/src/**/*.rs'))|set(stage.glob('assets/**/*'))|{stage/'catalogs/bello-agent.models.json'}
rows=[]
for p in sorted(files):
 if p.is_file():
  b=p.read_bytes();rows.append({'path':str(p.relative_to(stage)),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
digest=hashlib.sha256(''.join(r['path']+'\0'+r['sha256']+'\n' for r in rows).encode()).hexdigest()
m={'base':'6eee1d06776b18b55b45f0f8adbbe6204c3cb328','source_digest':digest,'files':rows}
if sys.argv[1]=='before':(out/'source-before.json').write_text(json.dumps(m,indent=2)+'\n')
else:
 before=json.loads((out/'source-before.json').read_text());assert before==m
 binary=out/'bello-agent-catalog-native-integrated';m.update(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),build_features=['native-authority','synthetic-authority'],cargo_config=['profile.dev.package.gpui.codegen-units=256'],review_revision='review-r4',jobs=1,rustc='1.99.0 (b940084d7 2026-09-28)',selected_gui_launch_mode='--synthetic-connections only',source_before_after_identical=True)
 (out/'source-and-binary-manifest.json').write_text(json.dumps(m,indent=2)+'\n')
print(digest,len(rows))
