import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { resourceOptions } from '../src/resources/config.ts';
import { ResourceResolver } from '../src/resources/resolver.ts';
import { freezeSkills, piSkills, selectionsFrom, validateFrozen } from '../src/resources/skills.ts';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'pi-resources-')), home = join(root, 'home'), project = join(root, 'repo'), cwd = join(project, 'nested');
  await Promise.all([mkdir(home), mkdir(cwd, {recursive: true})]);
  const resolver = new ResourceResolver(cwd, {codexHome: home}, home);
  return {root, home, project, cwd, resolver, close: async () => {resolver.dispose(); await rm(root, {recursive:true,force:true});}};
}
async function put(path: string, text: string) { await mkdir(join(path, '..'), {recursive:true}); await writeFile(path, text); }
const skill = (name: string, extra = '', body = 'Preserve all prose restrictions. Use ./scripts/example.sh only if the available tool policy permits it.') => `---\nname: ${name}\ndescription: ${name}_description_unique\n${extra}---\n${body}`;
const select = (s: any) => ({id:s.id,contentHash:s.contentHash,metadataHash:s.metadataHash,arguments:'quoted $() arguments',intent:'picker' as const});

test('instruction chain chooses one nonempty file, preserves order, ignores descendants, reports unreadable priority and deduplicates aliases', async () => {
  const f = await fixture();
  try {
    await put(join(f.project,'.git'), 'gitdir: /synthetic/worktree/admin');
    await put(join(f.home,'AGENTS.md'), 'global'); await put(join(f.home,'AGENTS.override.md'), '   \n');
    await put(join(f.project,'AGENTS.override.md'), 'root'); await put(join(f.project,'AGENTS.md'), 'ignored-root');
    await put(join(f.cwd,'AGENTS.override.md'), 'unreadable'); await chmod(join(f.cwd,'AGENTS.override.md'),0);
    await put(join(f.cwd,'TEAM.md'),'fallback'); await put(join(f.cwd,'descendant','AGENTS.md'),'do-not-preload');
    await put(join(f.home,'config.toml'),'project_doc_fallback_filenames = ["TEAM.md"]');
    let s = await f.resolver.resolve();
    assert.equal(s.root,f.project); assert.deepEqual(s.instructions.files.map(x=>x.content),['global','root','fallback']);
    assert.ok(s.instructions.sources.some(x=>x.state==='error')); assert.ok(s.instructions.sources.some(x=>x.state==='ignored'));
    await chmod(join(f.cwd,'AGENTS.override.md'),0o600); await rm(join(f.cwd,'AGENTS.override.md'));
    await symlink(join(f.home,'AGENTS.md'),join(f.cwd,'AGENTS.md'));
    s = await f.resolver.resolve(); assert.deepEqual(s.instructions.files.map(x=>x.content),['global','root']); assert.ok(s.instructions.sources.some(x=>x.state==='duplicate'));
  } finally {await f.close();}
});
test('no Git root means only cwd; Unicode instruction cap counts global and project source bytes', async () => {
  const f = await fixture();
  try {
    await put(join(f.project,'AGENTS.md'),'must-not-scan'); await put(join(f.home,'AGENTS.override.md'),'abc'); await put(join(f.cwd,'AGENTS.md'),'🌍tail');
    f.resolver.configure({codexHome:f.home,maxInstructionBytes:6}); const s=await f.resolver.resolve();
    assert.equal(s.root,null); assert.equal(s.instructions.includedBytes,3); assert.deepEqual(s.instructions.files.map(x=>x.content),['abc']);
    assert.equal(s.instructions.sources.at(-1)?.state,'over-budget'); assert.ok(!JSON.stringify(s).includes('must-not-scan'));
    assert.throws(()=>resourceOptions({extraSkillPaths:['../bad']}),/absolute/);
    f.resolver.configure({codexHome:f.home,fallbackNames:['../escape']}); assert.ok((await f.resolver.resolve()).diagnostics.some(x=>x.includes('basenames')));
  } finally {await f.close();}
});
test('canonical skill identities deduplicate cycles and retain collisions and reserved names', async () => {
  const f=await fixture();
  try {
    await put(join(f.home,'skills','a','SKILL.md'),skill('duplicate'));
    await put(join(f.cwd,'.agents','skills','b','SKILL.md'),skill('duplicate'));
    await put(join(f.cwd,'.agents','skills','builtin','SKILL.md'),skill('side'));
    await symlink(join(f.home,'skills'),join(f.home,'skills','cycle')); await symlink(join(f.home,'skills','a'),join(f.home,'skills','alias'));
    const s=await f.resolver.resolve(); assert.equal(s.catalog.skills.length,3); assert.equal(new Set(s.catalog.skills.map(x=>x.id)).size,3);
    assert.equal(s.catalog.skills.filter(x=>x.name==='duplicate').length,2); assert.ok(s.catalog.skills.some(x=>x.name==='side'));
  } finally {await f.close();}
});
test('Codex, Pi and app policy combine strictly; disabled is distinct and malformed tags/policy never become implicit', async () => {
  const f=await fixture();
  try {
    for(const name of ['codex','pi','disabled','bad','tag','app']) await put(join(f.home,'skills',name,'SKILL.md'),skill(name,name==='pi'?'disable-model-invocation: true\n':''));
    await put(join(f.home,'skills','codex','agents','openai.yaml'),'policy:\n  allow_implicit_invocation: false');
    await put(join(f.home,'skills','bad','agents','openai.yaml'),'policy:\n  allow_implicit_invocation: "false"');
    await put(join(f.home,'skills','tag','agents','openai.yaml'),'policy: !!js/function function(){}');
    await put(join(f.home,'config.toml'),`[[skills.config]]\npath = ${JSON.stringify(join(f.home,'skills','disabled','SKILL.md'))}\nenabled = false`);
    let s=await f.resolver.resolve(); const policies=Object.fromEntries(s.catalog.skills.map(x=>[x.name,x.policy]));
    assert.deepEqual(policies,{app:'implicitAllowed',bad:'needsAttention',codex:'explicitOnly',disabled:'disabled',pi:'explicitOnly',tag:'needsAttention'});
    const app=s.catalog.skills.find(x=>x.name==='app')!; f.resolver.configure({codexHome:f.home,explicitOnly:[app.id]}); s=await f.resolver.resolve();
    assert.deepEqual(piSkills(s.catalog,['read']),[]); assert.equal(s.catalog.skills.filter(x=>x.policy==='explicitOnly').length,3);
    await put(join(f.home,'config.toml'),'[[skills.config]\nenabled = false'); s=await f.resolver.resolve(); assert.ok(s.catalog.skills.every(x=>x.policy==='needsAttention'));
  } finally {await f.close();}
});
test('selection freezes bytes, checks hashes and dependencies; queued content remains frozen but revocation blocks dispatch', async () => {
  const f=await fixture();
  try {
    const path=join(f.home,'skills','a','SKILL.md'); await put(path,skill('a')); let s=await f.resolver.resolve(); const chosen=select(s.catalog.skills[0]);
    const frozen=freezeSkills(s.catalog,selectionsFrom([chosen]),['read']);
    await put(path,skill('a','','changed source body')); s=await f.resolver.resolve();
    assert.throws(()=>freezeSkills(s.catalog,[chosen],['read']),/changed/); validateFrozen(s.catalog,frozen,['read']); assert.ok(frozen[0]!.body.includes('Preserve all prose'));
    await put(join(f.home,'skills','a','agents','openai.yaml'),'dependencies:\n  tools:\n    - type: mcp\n      value: missingServer'); s=await f.resolver.resolve();
    assert.throws(()=>freezeSkills(s.catalog,[select(s.catalog.skills[0])],['read']),/unavailable dependencies/); assert.throws(()=>validateFrozen(s.catalog,frozen,['read']),/revoked/);
    assert.deepEqual(piSkills(s.catalog,['read']),[]); assert.throws(()=>selectionsFrom([{...chosen,intent:'assistant'}]),/Invalid/);
  } finally {await f.close();}
});
test('resource files, aliases and directory depth have explicit bounded failure states', async () => {
  const f=await fixture();
  try {
    await put(join(f.home,'skills','giant','SKILL.md'),skill('giant','','x'.repeat(262145)));
    await put(join(f.home,'skills','alias','SKILL.md'),skill('alias'));
    await put(join(f.home,'skills','alias','agents','openai.yaml'),'x: &x [1, 2]\npolicy: { allow_implicit_invocation: *x }');
    await put(join(f.home,'skills',...Array(14).fill('deep'),'SKILL.md'),skill('deep'));
    const s=await f.resolver.resolve(); assert.ok(s.catalog.diagnostics.some(x=>x.includes('limit'))); assert.equal(s.catalog.skills.length,1); assert.equal(s.catalog.skills[0]!.policy,'needsAttention');
  } finally {await f.close();}
});

