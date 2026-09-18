import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SessionService } from '../src/sessions/session-service.ts';
import { OutputQueue } from '../src/sessions/output-queue.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic } from '../../../fixtures/providers/traffic.ts';

test('a blocked output consumer retains one display invalidation per session and ordered replies', async () => {
  const gate = Promise.withResolvers<void>(); const received: any[] = [];
  const queue = new OutputQueue(async bytes => { await gate.promise; received.push(JSON.parse(bytes.toString())); }, () => assert.fail('overflow'));
  queue.send({ kind: 'reply', n: 1 });
  for (let i = 0; i < 100_000; i++) queue.send({ seq: i }, 'main');
  queue.send({ kind: 'reply', n: 2 });
  assert.ok(queue.pendingBytes < 256); gate.resolve(); await queue.drain();
  assert.deepEqual(received, [{ kind: 'reply', n: 1 }, { kind: 'reply', n: 2 }, { seq: 99999 }]);
});

test('session service reconciles snapshots, deduplicates submission, and isolates displayed history from opaque Pi state', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-service-'));
  const server = new FixtureServer(() => ({ chunks: [traffic('openai-responses', { thinking: true })] }));
  await server.start(); const service = new SessionService(() => {}, join(root, 'home'));
  try {
    await service.command('workspace', 'workspace.open', undefined, { cwd: root, directory: join(root, 'managed') });
    const profile = { id: 'p', revision: 'r', providerId: 'fixture', modelId: 'fixture-model', api: 'openai-responses', baseUrl: `${server.origin}/v1`, contextWindow: 4096, maxOutputTokens: 512 };
    await service.command('open', 'session.open', 'chat', { profile, apiKey: 'synthetic' });
    const input = { text: 'Hello', clientTurnId: 'turn' };
    assert.deepEqual(await service.command('send', 'turn.submit', 'chat', input), await service.command('send', 'turn.submit', 'chat', { clientTurnId: 'turn', text: 'Hello' }));
    let snapshot: any;
    for (let i = 0; i < 300; i++) {
      snapshot = await service.command('snapshot', 'session.snapshot', 'chat', {});
      if (snapshot.commands.some((c: any) => c.state === 'completed')) break;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.equal(server.requests.length, 1);
    assert.equal(snapshot.messages.at(-1).text, 'Hello 🌍 漢字');
    assert.equal(snapshot.messages.at(-1).thinking, 'Synthetic thought.');
    assert.ok(!JSON.stringify(snapshot.messages).includes('fixture-opaque'));
    const events: any = await service.command('events', 'session.events', 'chat', { since: snapshot.seq });
    assert.deepEqual(events.events, []);
    await service.command('close', 'session.close', 'chat', {});
    await assert.rejects(service.command('snapshot', 'session.snapshot', 'chat', {}), /unloaded/);
    await service.command('reopen', 'session.open', 'chat', { profile, apiKey: 'synthetic', path: snapshot.path });
    assert.equal(server.requests.length, 1);
    const restored: any = await service.command('snapshot', 'session.snapshot', 'chat', {});
    assert.deepEqual(restored.messages.map((m: any) => m.id), snapshot.messages.map((m: any) => m.id));
  } finally { await service.shutdown(); await server.close(); await rm(root, { recursive: true, force: true }); }
});

test('a per-session Off preference applies before the first Pi request without changing adapter traffic', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-capture-preference-'));
  const server = await new FixtureServer(()=>({chunks:[traffic('anthropic-messages')]})).start(), service = new SessionService(()=>{}, join(root, 'home'));
  try {
    await service.command('workspace','workspace.open',undefined,{cwd:root,directory:join(root,'managed')});
    await service.command('off','debug.mode','new-chat',{mode:'off'});
    const profile={id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api:'anthropic-messages',baseUrl:server.origin,contextWindow:8192,maxOutputTokens:1024};
    await service.command('open','session.open','new-chat',{profile,apiKey:'synthetic',connectionTest:true});
    await service.command('send','turn.submit','new-chat',{text:'Hello',clientTurnId:'turn'});
    for(let i=0;i<200;i++) { const s:any=await service.command('status','session.status','new-chat',{}); if(s.commands.some((c:any)=>c.state==='completed')) break; await new Promise(r=>setTimeout(r,10)); }
    assert.equal(server.requests.length,1); assert.ok(JSON.parse(server.requests[0]!.bytes.toString()).max_tokens===1024);
    const capture:any=await service.command('list','debug.list','new-chat',{});
    assert.equal(capture.attempts[0].request.state,'disabled'); assert.equal(capture.attempts[0].request.retainedBytes,0); assert.equal(capture.attempts[0].captureMode,'off');
    assert.equal(capture.attempts[0].purpose,'connection-test'); assert.equal(capture.attempts[0].modelOutcome,'completed');
  } finally { await service.shutdown(); await server.close(); await rm(root,{recursive:true,force:true}); }
});
