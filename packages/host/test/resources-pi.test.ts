import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { resourceOptions } from '../src/resources/config.ts';
import { ResourceResolver } from '../src/resources/resolver.ts';
import { freezeSkills, piSkills, selectionsFrom, validateFrozen } from '../src/resources/skills.ts';
import { PiSessionAdapter } from '../src/pi/session-adapter.ts';
import { CaptureStore, type ApiKind } from '../src/observability/capture-store.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic } from '../../../fixtures/providers/traffic.ts';
import { SessionService } from '../src/sessions/session-service.ts';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'pi-resources-')), home = join(root, 'home'), project = join(root, 'repo'), cwd = join(project, 'nested');
  await Promise.all([mkdir(home), mkdir(cwd, {recursive: true})]);
  const resolver = new ResourceResolver(cwd, {codexHome: home}, home);
  return {root, home, project, cwd, resolver, close: async () => {resolver.dispose(); await rm(root, {recursive:true,force:true});}};
}
async function put(path: string, text: string) { await mkdir(join(path, '..'), {recursive:true}); await writeFile(path, text); }
const skill = (name: string, extra = '', body = 'Preserve all prose restrictions. Use ./scripts/example.sh only if the available tool policy permits it.') => `---\nname: ${name}\ndescription: ${name}_description_unique\n${extra}---\n${body}`;
const select = (s: any) => ({id:s.id,contentHash:s.contentHash,metadataHash:s.metadataHash,arguments:'quoted $() arguments',intent:'picker' as const});

test('queued explicit selections revalidate revocation before Pi dispatch and retain a visible recoverable failure', async () => {
  const f=await fixture(), gate=Promise.withResolvers<void>(), service=new SessionService(()=>{},f.home);
  const server=await new FixtureServer(()=>({chunks:[traffic('openai-responses')],beforeChunk:()=>gate.promise})).start();
  try {
    await put(join(f.home,'skills','only','SKILL.md'),skill('only','disable-model-invocation: true\n','explicit_queue_body'));
    await service.command('workspace','workspace.open',undefined,{cwd:f.cwd,directory:join(f.root,'managed')});
    const p={id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api:'openai-responses',baseUrl:server.origin,contextWindow:32768,maxOutputTokens:1024};
    await service.command('open','session.open','chat',{profile:p,apiKey:'synthetic'});
    await service.command('send','turn.submit','chat',{text:'/only is literal without a native selection',clientTurnId:'one'});
    for(let i=0;i<100 && !server.requests.length;i++) await new Promise(r=>setTimeout(r,5));
    assert.equal(server.requests.length,1); assert.ok(!server.requests[0]!.bytes.toString().includes('explicit_queue_body'));
    const catalog:any=await service.command('catalog','resources.inspect','chat',{}), chosen=select(catalog.skills[0]);
    const queued:any=await service.command('queued','turn.submit','chat',{text:'',skills:[chosen],clientTurnId:'two'}); assert.equal(queued.queued,true);
    await service.command('disable','resources.configure',undefined,{options:{codexHome:f.home,disabled:[chosen.id]}}); gate.resolve();
    let state:any; for(let i=0;i<200;i++) {state=await service.command('status','session.status','chat',{});if(state.preflightError)break;await new Promise(r=>setTimeout(r,5));}
    assert.match(state.preflightError,/revoked/); assert.equal(state.state,'interrupted'); assert.equal(server.requests.length,1);
    assert.ok(state.commands.some((c:any)=>c.turnId==='two' && c.state==='dispatched'));
    assert.equal(await readFile(join(f.home,'skills','only','SKILL.md'),'utf8'),skill('only','disable-model-invocation: true\n','explicit_queue_body'));
  } finally {gate.resolve();await service.shutdown();await server.close();await f.close();}
});

for (const api of ['openai-responses','anthropic-messages'] as ApiKind[]) test(`${api}: Pi receives one frozen explicit expansion and instruction chain across a tool loop, then a fresh next-turn revision`, async () => {
  const f=await fixture(); const capture=new CaptureStore(); let adapter:PiSessionAdapter|undefined;
  const server=await new FixtureServer((_request,index)=>({chunks:[traffic(api,{tool:index===0})]})).start();
  try {
    await put(join(f.cwd,'AGENTS.md'),'instruction_v1_unique'); await put(join(f.home,'skills','only','SKILL.md'),skill('only','disable-model-invocation: true\n','explicit_body_unique'));
    const snapshot=await f.resolver.resolve(), frozen=freezeSkills(snapshot.catalog,[select(snapshot.catalog.skills[0])],['fixture_echo']);
    adapter=await PiSessionAdapter.create({cwd:f.cwd,agentDir:join(f.root,'agent'),profile:{id:'p',revision:'r',api,providerId:'fixture',modelId:'fixture-model',baseUrl:server.origin,contextWindow:32768,maxOutputTokens:1024},apiKey:'synthetic',capture,
      resources:f.resolver, fixtureEcho:async text=>{await put(join(f.cwd,'AGENTS.md'),'instruction_v2_unique');return text;}});
    assert.equal(await adapter.submit('Use the selected skill.','first',{text:'Use the selected skill.',commandId:'first',turnId:'first',skills:frozen}),'completed');
    assert.equal(server.requests.length,2);
    for(const request of server.requests) {const wire=request.bytes.toString(); assert.equal(wire.split('explicit_body_unique').length-1,1); assert.equal(wire.split('instruction_v1_unique').length-1,1); assert.ok(!wire.includes('instruction_v2_unique')); assert.ok(!wire.includes('only_description_unique'));}
    assert.equal(capture.attempts[0]!.skillGrants?.[0]?.contentHash,frozen[0]!.contentHash); assert.equal(capture.attempts[1]!.resourceRevision,capture.attempts[0]!.resourceRevision);
    assert.equal(await adapter.submit('A quoted example: `/only`\n```\n/only\n```','second'),'completed');
    assert.equal(server.requests.length,3); assert.ok(server.requests[2]!.bytes.toString().includes('instruction_v2_unique')); assert.deepEqual(capture.attempts[2]!.skillGrants,[]);
    assert.notEqual(capture.attempts[2]!.resourceRevision,capture.attempts[0]!.resourceRevision);
    assert.ok(JSON.stringify(adapter.provenance()).includes('first'));
  } finally {await adapter?.dispose();await server.close();await f.close();}
});
