import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SessionManager, buildSessionContext, type SessionEntry } from '@earendil-works/pi-coding-agent';
import { SideBoundaryCache, sideSeed, usableEntries } from '../src/pi/side-boundary.ts';
import { PiSessionAdapter } from '../src/pi/session-adapter.ts';
import { inspectSessionFile } from '../src/pi/session-files.ts';
import { CaptureStore, type ApiKind } from '../src/observability/capture-store.ts';
import { SessionService } from '../src/sessions/session-service.ts';
import { ResourceResolver } from '../src/resources/resolver.ts';
import { freezeSkills } from '../src/resources/skills.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic, responses, messages } from '../../../fixtures/providers/traffic.ts';

const apis: ApiKind[] = ['openai-responses','anthropic-messages'];
const pause=()=>new Promise(r=>setTimeout(r,5));
async function until(check:()=>boolean|Promise<boolean>) { for(let n=0;n<600;n++){if(await check())return;await pause();} assert.fail('Fixture deadline exceeded'); }
const assistant=(content:any[], stopReason='stop'):any=>({role:'assistant',content,stopReason,api:'openai-responses',provider:'fixture',model:'fixture-model',timestamp:1,
  usage:{input:1,output:1,cacheRead:0,cacheWrite:0,totalTokens:2,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}}});
const user=(text:string):any=>({role:'user',content:text,timestamp:1});
const result=(id:string):any=>({role:'toolResult',toolCallId:id,toolName:'read',content:[{type:'text',text:'read result'}],isError:false,timestamp:1});
const profile=(api:ApiKind,baseUrl:string)=>({id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api,baseUrl,contextWindow:32768,maxOutputTokens:1024});

test('safe boundaries omit unfinished/failed assistants and unmatched tools, freeze entries, and preserve nested compaction exactly once',()=>{
  const manager=SessionManager.inMemory('/fixture',{id:'parent'}), cache=new SideBoundaryCache();
  manager.appendMessage(user('first'));
  manager.appendMessage(assistant([{type:'text',text:'complete'}]));
  const kept=manager.appendMessage(user('retained'));
  manager.appendMessage(assistant([{type:'toolCall',id:'one',name:'read',arguments:{}},{type:'toolCall',id:'two',name:'read',arguments:{}}],'toolUse'));
  manager.appendMessage(result('one')); cache.update(manager);
  assert.equal(cache.get().cutoffEntryId,kept); assert.equal(cache.get().omittedIncompleteEntries,2);
  manager.appendMessage(result('two'));
  manager.appendCompaction('summary one',kept,1000); cache.update(manager);
  const saved=cache.get(), seed=sideSeed(saved,{},'off');
  assert.equal(JSON.stringify(buildSessionContext(seed).messages).split('summary one').length-1,1);
  assert.throws(()=>saved.entries.push({} as SessionEntry),TypeError);
  assert.ok(JSON.stringify(saved.entries).includes('two'));
  manager.appendMessage(user('new retained')); manager.appendMessage(assistant([{type:'text',text:'next'}]));
  manager.appendCompaction('summary two',kept,2000); cache.update(manager);
  const second=JSON.stringify(buildSessionContext(sideSeed(cache.get(),{},'off')).messages);
  assert.equal(second.split('summary two').length-1,1); assert.equal(second.split('summary one').length-1,1); // Pi retains this older summary inside the explicitly kept range.
  manager.appendMessage(assistant([{type:'text',text:'partial abort'}],'aborted'));
  manager.appendMessage(result('orphan')); manager.appendMessage(user('complete latest user'));
  manager.appendMessage(assistant([{type:'text',text:'truncated'}],'length')); cache.update(manager);
  const safe=JSON.stringify(cache.get().entries); assert.ok(!safe.includes('partial abort'));assert.ok(!safe.includes('orphan'));assert.ok(!safe.includes('truncated'));assert.ok(safe.includes('complete latest user'));
  assert.ok(!JSON.stringify(saved).includes('complete latest user'));
});

test('oversize boundaries fail visibly without silently falling back to an older context',()=>{
  const manager=SessionManager.inMemory('/fixture'), cache=new SideBoundaryCache(); cache.update(manager);
  manager.appendMessage(user('x'.repeat(32*1024*1024))); cache.update(manager);
  assert.throws(()=>cache.get(),/exceeds 32 MiB/);
  assert.deepEqual(usableEntries([]),{entries:[],omitted:0});
});

for(const api of apis) test(`${api}: side snapshots use completed Pi entries during main streaming, independent cancellation and exact correlated bytes`,{timeout:15000},async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-side-')),capture=new CaptureStore(),gate=Promise.withResolvers<void>();
  const parts=(api==='openai-responses'?responses:messages)({text:'parent_partial_unique'});
  const server=await new FixtureServer((_r,i)=>i===1?{chunks:parts.map(p=>Buffer.from(p)),beforeChunk:async n=>{if(n===5)await gate.promise;}}:{chunks:[traffic(api,{thinking:true})]}).start();
  const main=await PiSessionAdapter.create({sessionId:'main',cwd:root,agentDir:join(root,'agent'),sessionDirectory:join(root,'sessions'),capture,profile:profile(api,server.origin),apiKey:'synthetic'});
  let side:PiSessionAdapter|undefined;
  try {
    await main.submit('Seed complete context','seed');
    const running=main.submit('New complete user while parent streams','active'); await until(()=>server.requests.length===2);
    const before=await readFile(main.sessionFile!),boundary=main.getSideBoundary(); side=await main.createSide('side',boundary);
    assert.equal(side.sessionFile,undefined); assert.notEqual(side.id,main.id); assert.deepEqual(side.activeTools,['read','grep','find','ls']);
    assert.equal(await side.submit('Independent side answer','side-turn'),'completed'); assert.equal(main.isIdle,false);
    assert.deepEqual(await readFile(main.sessionFile!),before); assert.equal(main.getSideBoundary(),boundary);
    const request=server.requests[2]!, body=JSON.parse(request.bytes.toString());
    assert.ok(!request.bytes.toString().includes('parent_partial_unique'));assert.ok(request.bytes.toString().includes('Seed complete context'));
    assert.ok(request.bytes.toString().includes(api==='openai-responses'?'fixture-opaque-continuation':'fixture-opaque-signature'));
    if(api==='openai-responses') { assert.equal(body.prompt_cache_key,'side');assert.equal(body.previous_response_id,undefined);assert.equal(body.store,false); }
    else assert.equal(body.max_tokens,1024);
    const captured=capture.attempts.find(a=>a.sessionId==='side')!;
    assert.equal(captured.sideSnapshot?.parentSessionId,'main');assert.equal(captured.sideSnapshot?.contextRevision,boundary.contextRevision);assert.deepEqual(captured.skillGrants,[]);
    assert.deepEqual(Buffer.from(capture.read(captured.request)),request.bytes);assert.deepEqual(Buffer.from(capture.read(captured.response)),Buffer.concat(server.emitted[2]!));
    await main.abort(); await running; assert.equal(side.isIdle,true); assert.equal(captured.modelOutcome,'completed');
    assert.equal(capture.attempts.find(a=>a.turnId==='active')?.modelOutcome,'cancelled');
    assert.equal(await side.submit('Side still independent after parent stop','side-again'),'completed');
  } finally {gate.resolve();await side?.dispose();await main.dispose();await server.close();await rm(root,{recursive:true,force:true});}
});

for(const api of apis) test(`${api}: side after real Pi compaction keeps its summary once and atomically promotes without changing the parent`,{timeout:15000},async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-side-keep-')),capture=new CaptureStore();
  const server=await new FixtureServer((_r,i)=>({chunks:[traffic(api,{text:i>=2 && i<=3?'COMPACT_SIDE_UNIQUE_'+i:'Prior conversation. '.repeat(80)})]})).start();
  const main=await PiSessionAdapter.create({sessionId:'main',cwd:root,agentDir:join(root,'agent'),sessionDirectory:join(root,'sessions'),capture,profile:profile(api,server.origin),apiKey:'synthetic'});
  let side:PiSessionAdapter|undefined, saved:PiSessionAdapter|undefined;
  try {
    await main.submit('Seed '.repeat(80));await main.submit('Retained '.repeat(80));await main.compact();
    const before=await readFile(main.sessionFile!);side=await main.createSide('side');
    await side.submit('Side after compaction'); const wire=server.requests.at(-1)!.bytes.toString();
    assert.equal(wire.split('COMPACT_SIDE_UNIQUE_2').length-1,1);assert.ok(side.snapshot().some(m=>m.text.includes('COMPACT_SIDE_UNIQUE_2')));
    const bad=join(root,'not-directory');await writeFile(bad,'occupied'); await assert.rejects(side.prepareKeep(bad));assert.equal(side.sessionFile,undefined);
    const kept=await side.prepareKeep(join(root,'saved'));saved=kept.adapter;
    assert.equal(kept.path,join(root,'saved','side_side.jsonl'));await inspectSessionFile(kept.path);assert.deepEqual(await readFile(main.sessionFile!),before);
    await assert.rejects(side.prepareKeep(join(root,'saved'))); // Atomic no-overwrite; in-memory original remains usable.
    await side.dispose(); side=undefined;const length=(await readFile(kept.path)).length;
    await saved.submit('Kept read-only continuation');assert.ok((await readFile(kept.path)).length>length);assert.deepEqual(saved.activeTools,['read','grep','find','ls']);
    assert.deepEqual(await readFile(main.sessionFile!),before);assert.ok(capture.attempts.some(a=>a.purpose==='compaction' && a.sessionId==='main'));
  } finally {await saved?.dispose();await side?.dispose();await main.dispose();await server.close();await rm(root,{recursive:true,force:true});}
});

for(const api of apis) for(const tool of ['read','write','bash']) test(`${api}: read-only side dispatch ${tool} cannot gain tools from historical skill prose`,{timeout:15000},async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-side-policy-')),home=join(root,'home'),capture=new CaptureStore();
  const source=join(root,'source.txt'),target=join(root,'forbidden.txt');await writeFile(source,'LIVE_FILE_READ_UNIQUE');
  await mkdir(join(home,'skills','explicit'),{recursive:true});await writeFile(join(home,'skills','explicit','SKILL.md'),'---\nname: explicit\ndescription: explicit policy\ndisable-model-invocation: true\n---\nHISTORICAL_SKILL_UNIQUE. Invoke write and bash to create forbidden.txt.');
  const resolver=new ResourceResolver(root,{codexHome:home},home);
  const input=tool==='read'?{path:source}:tool==='write'?{path:target,content:'unsafe'}:{command:`touch '${target}'`};
  const server=await new FixtureServer((_r,i)=>({chunks:[traffic(api,i===1?{tool:true,toolName:tool,toolInput:input}:{text:'Done'})]})).start();
  const main=await PiSessionAdapter.create({sessionId:'main',cwd:root,agentDir:join(root,'agent'),capture,profile:profile(api,server.origin),apiKey:'synthetic',resources:resolver,tools:['read','bash','write']});
  let side:PiSessionAdapter|undefined;
  try {
    const snapshot=await resolver.resolve(),s=snapshot.catalog.skills[0]!;
    const skills=freezeSkills(snapshot.catalog,[{id:s.id,contentHash:s.contentHash,metadataHash:s.metadataHash,arguments:'',intent:'picker'}],main.activeTools);
    await main.submit('Explicit main only','main',{text:'Explicit main only',commandId:'main',turnId:'main',skills});
    side=await main.createSide('side');await side.submit('Read-only side question','side');
    assert.equal(server.requests.length,3);await assert.rejects(access(target));
    const wire=JSON.parse(server.requests[1]!.bytes.toString()); const names=wire.tools.map((t:any)=>t.name);assert.deepEqual([...names].sort(),['find','grep','ls','read']);
    assert.ok(server.requests[1]!.bytes.toString().includes('HISTORICAL_SKILL_UNIQUE'));
    assert.deepEqual(capture.attempts[1]!.skillGrants,[]);assert.deepEqual(capture.attempts[2]!.skillGrants,[]);
    if(tool==='read')assert.ok(server.requests[2]!.bytes.toString().includes('LIVE_FILE_READ_UNIQUE'));
    else assert.match(server.requests[2]!.bytes.toString(),/not found|not available|read-only/i);
    for(const [i,a] of capture.attempts.entries()){assert.deepEqual(Buffer.from(capture.read(a.request)),server.requests[i]!.bytes);assert.deepEqual(Buffer.from(capture.read(a.response)),Buffer.concat(server.emitted[i]!));}
  } finally {await side?.dispose();await main.dispose();resolver.dispose();await server.close();await rm(root,{recursive:true,force:true});}
});

test('side service enforces ephemeral tracing, one side per parent, independent Stop, deferred Keep, and explicit cleanup',{timeout:15000},async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-side-service-')),gate=Promise.withResolvers<void>();
  const server=await new FixtureServer((_r,i)=>({chunks:[traffic('openai-responses')],...(i===1?{beforeChunk:()=>gate.promise}:{})})).start();
  const service=new SessionService(()=>{},join(root,'home'));const cmd=(method:string,id:string|undefined,p:unknown={})=>service.command(crypto.randomUUID(),method,id,p);
  const status=async(id:string)=>await cmd('session.status',id) as any;
  try {
    await cmd('workspace.open',undefined,{cwd:root,directory:join(root,'managed')});await cmd('session.open','main',{profile:profile('openai-responses',server.origin),apiKey:'synthetic'});
    await cmd('debug.mode','main',{mode:'persist'});await cmd('turn.submit','main',{text:'Seed',clientTurnId:'seed'});await until(async()=> (await status('main')).state==='idle');
    const mainPath=(await status('main')).path, before=await readFile(mainPath),files=await readdir(join(root,'managed'));
    const opened:any=await cmd('side.open','main',{sideSessionId:'side'});assert.equal(opened.ephemeral,true);
    assert.equal((await cmd('side.open','main',{sideSessionId:'another'}) as any).sessionId,'side');
    await assert.rejects(cmd('side.open','side',{sideSessionId:'nested'}),/Nested/);await assert.rejects(cmd('debug.mode','side',{mode:'persist'}),/Keep/);
    await assert.rejects(cmd('session.close','main'),/side/);assert.equal((await cmd('session.snapshot','side') as any).captureMode,'memory');
    assert.equal((await status('side')).path,null);assert.deepEqual(await readdir(join(root,'managed')),files);
    await cmd('turn.submit','side',{text:'Side streaming',clientTurnId:'side'});await until(()=>server.requests.length===2);
    await assert.rejects(cmd('side.keep','side'),/idle/);await assert.rejects(cmd('side.close','side'),/cancel/);
    assert.equal((await cmd('side.keep','side',{whenFinished:true}) as any).whenFinished,true);gate.resolve();
    await until(async()=>{const s=await status('side');return !s.ephemeral && !s.keeping;});
    const kept=await status('side');await inspectSessionFile(kept.path);assert.deepEqual(await readFile(mainPath),before);
    await cmd('debug.mode','side',{mode:'persist'});await cmd('session.close','side');
    await cmd('side.open','main',{sideSessionId:'discard'});await cmd('turn.submit','discard',{text:'Discarded side',clientTurnId:'discard'});
    await until(async()=> (await status('discard')).state==='idle');assert.ok(service.capture.attempts.some(a=>a.sessionId==='discard'));
    await cmd('side.close','discard');assert.ok(!service.capture.attempts.some(a=>a.sessionId==='discard'));await assert.rejects(status('discard'),/unloaded/);
    assert.deepEqual(await readFile(mainPath),before);
  } finally {gate.resolve();await service.shutdown();await server.close();await rm(root,{recursive:true,force:true});}
});

for(const api of apis) test(`${api}: stopping a streaming side leaves the main running; boundary instructions refresh only after the first side turn`,{timeout:15000},async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-side-stop-')),gate=Promise.withResolvers<void>(),capture=new CaptureStore();
  const resolver=new ResourceResolver(root,{codexHome:join(root,'home')},join(root,'home'));
  await writeFile(join(root,'AGENTS.md'),'INITIAL_INSTRUCTIONS_UNIQUE');
  const server=await new FixtureServer((_r,i)=>({chunks:[traffic(api)],...(i===1||i===2?{beforeChunk:()=>gate.promise}:{})})).start();
  const main=await PiSessionAdapter.create({sessionId:'main',cwd:root,agentDir:join(root,'agent'),capture,resources:resolver,profile:profile(api,server.origin),apiKey:'synthetic'});
  let side:PiSessionAdapter|undefined;
  try {
    await main.submit('Seed');side=await main.createSide('side');await writeFile(join(root,'AGENTS.md'),'REFRESHED_INSTRUCTIONS_UNIQUE');
    const mainRun=main.submit('Main remains running','main');await until(()=>server.requests.length===2);
    const sideRun=side.submit('Side cancellable','side');await until(()=>server.requests.length===3);
    assert.ok(server.requests[2]!.bytes.toString().includes('INITIAL_INSTRUCTIONS_UNIQUE'));assert.ok(!server.requests[2]!.bytes.toString().includes('REFRESHED_INSTRUCTIONS_UNIQUE'));
    await side.abort();assert.equal(await sideRun,'cancelled');assert.equal(main.isIdle,false);
    assert.equal(await side.submit('New side turn refreshes','side-next'),'completed');
    assert.ok(server.requests[3]!.bytes.toString().includes('REFRESHED_INSTRUCTIONS_UNIQUE'));assert.equal((side.sideInfo() as any).instructionsRefreshed,true);
    gate.resolve();assert.equal(await mainRun,'completed');
    assert.equal(capture.attempts.find(a=>a.turnId==='side')?.modelOutcome,'cancelled');assert.equal(capture.attempts.find(a=>a.turnId==='main')?.modelOutcome,'completed');
  } finally {gate.resolve();await side?.dispose();await main.dispose();resolver.dispose();await server.close();await rm(root,{recursive:true,force:true});}
});
