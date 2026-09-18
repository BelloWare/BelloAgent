import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { textPage } from '../src/pi/text-page.ts';
import { SessionService } from '../src/sessions/session-service.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic } from '../../../fixtures/providers/traffic.ts';

for (const api of ['openai-responses','anthropic-messages'] as const) test(`${api}: display revisions omit only unchanged previews and historical browsing keeps live status`,async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-display-revision-'));
  const server=await new FixtureServer(()=>({chunks:[traffic(api,{text:'Fresh display 🌍'})]})).start(),service=new SessionService(()=>{},join(root,'home'));
  const command=async(method:string,p:unknown={})=>await service.command(crypto.randomUUID(),method,method==='workspace.open'?undefined:'main',p) as any;
  try {
    await command('workspace.open',{cwd:root,directory:join(root,'sessions')});
    await command('session.open',{profile:{id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api,baseUrl:server.origin,contextWindow:8192,maxOutputTokens:512},apiKey:'synthetic'});
    const empty=await command('session.snapshot');assert.deepEqual(empty.messages,[]);
    assert.equal((await command('session.snapshot',{displayRevision:empty.displayRevision})).messages,undefined);
    await command('turn.submit',{text:'New turn',clientTurnId:'one'});
    for(let n=0;n<200;n++){if((await command('session.status')).state==='idle')break;await new Promise(r=>setTimeout(r,5));}
    const next=await command('session.snapshot',{displayRevision:empty.displayRevision});
    assert.notEqual(next.displayRevision,empty.displayRevision);assert.equal(next.messages.at(-1).text,'Fresh display 🌍');
    const unchanged=await command('session.snapshot',{displayRevision:next.displayRevision});assert.equal(unchanged.messages,undefined);assert.equal(unchanged.state,'idle');assert.ok(unchanged.latestAttempt);
    const historical=await command('session.snapshot',{includeMessages:false});assert.equal(historical.messages,undefined);assert.equal(historical.displayRevision,next.displayRevision);
    assert.deepEqual((await command('session.snapshot')).messages,next.messages);assert.equal(server.requests.length,1);assert.equal(service.capture.attempts[0]?.response.state,'complete');
    const found=await command('session.content.search',{query:'Fresh display',start:0});assert.equal(found.hits.length,1);
    const copied=await command('session.content.page',{first:found.hits[0].position,last:found.hits[0].position,index:found.hits[0].position,offset:0,revision:found.revision});
    assert.ok(copied.text.includes('Fresh display 🌍'));assert.equal(copied.next,null);assert.equal(server.requests.length,1);
  }finally{await service.shutdown();await server.close();await rm(root,{recursive:true,force:true});}
});

test('UTF-16 pages round trip astral Unicode at every edge and reject split input offsets',()=>{
  const text='a'.repeat(16383)+'🌍'+'漢'.repeat(16382)+'😀tail';
  let offset=0,assembled=''; do { const page=textPage(text,offset); assert.ok(!page.text.includes('�'));assembled+=page.text;offset=page.next??-1; } while(offset>=0);
  assert.equal(assembled,text);assert.throws(()=>textPage(text,16384),/boundary/);assert.equal(textPage(text,text.length+10).text,'');
});

test('host update barrier drains accepted preflights, rejects work until resume, and refuses active or ephemeral sessions',{timeout:10000},async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-idle-barrier-')),gate=Promise.withResolvers<void>();
  const server=await new FixtureServer(()=>({chunks:[traffic('openai-responses')],beforeChunk:()=>gate.promise})).start();
  const service=new SessionService(()=>{},join(root,'home'));
  const command=(method:string,id?:string,p:unknown={})=>service.command(crypto.randomUUID(),method,id,p);
  const profile={id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api:'openai-responses',baseUrl:server.origin,contextWindow:8192,maxOutputTokens:512};
  try {
    await command('workspace.open',undefined,{cwd:root,directory:join(root,'sessions')});
    const opening=command('session.open','main',{profile,apiKey:'synthetic'}),barrier=command('workspace.quiesce');
    await opening;assert.equal((await barrier as any).accepted,true);
    await assert.rejects(command('turn.submit','main',{text:'blocked',clientTurnId:'no'}),/barrier/);assert.equal(server.requests.length,0);
    await command('workspace.resume');await command('turn.submit','main',{text:'running',clientTurnId:'one'});
    await assert.rejects(command('workspace.quiesce'),/Finish work/);
    await command('turn.stop','main');
    for(let n=0;n<200;n++){const state:any=await command('session.status','main');if(state.state==='paused')break;await new Promise(r=>setTimeout(r,5));}
    await command('side.open','main',{sideSessionId:'side'});await assert.rejects(command('workspace.quiesce'),/sides/);
    await command('side.close','side');assert.equal((await command('workspace.quiesce') as any).accepted,true);
    await assert.rejects(command('side.open','main',{sideSessionId:'blocked'}),/barrier/);
  } finally {gate.resolve();await service.shutdown();await server.close();await rm(root,{recursive:true,force:true});}
});

test('simultaneous runtime opens never exceed the three-runtime cache and duplicate identities retain their bound mode',async()=>{
  const root=await mkdtemp(join(tmpdir(),'pi-runtime-capacity-')),unloaded:string[]=[],service=new SessionService((id,_seq,type)=>{if(type==='session.unloaded')unloaded.push(id);},join(root,'home'));
  const profile={id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api:'anthropic-messages',baseUrl:'http://127.0.0.1:1',contextWindow:8192,maxOutputTokens:512};
  const command=(method:string,id?:string,p:unknown={})=>service.command(crypto.randomUUID(),method,id,p);
  try {
    await command('workspace.open',undefined,{cwd:root,directory:join(root,'sessions')});
    await Promise.all(['a','b','c','d','e'].map(id=>command('session.open',id,{profile,apiKey:'synthetic'})));
    const active=await Promise.allSettled(['a','b','c','d','e'].map(id=>command('session.status',id)));
    assert.equal(active.filter(r=>r.status==='fulfilled').length,3);assert.equal(unloaded.length,2);
    await assert.rejects(command('session.open','e',{profile,apiKey:'synthetic',toolMode:'read-only'}),/bound profile and tool mode/);
  } finally {await service.shutdown();await rm(root,{recursive:true,force:true});}
});
