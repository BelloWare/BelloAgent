import test from 'node:test';
import assert from 'node:assert/strict';
import { CaptureStore, type CallContext } from '../src/observability/capture-store.ts';
import { Inspector, attemptMetrics } from '../src/observability/inspector.ts';
import { RawEventIndexer } from '../src/observability/raw-event-index.ts';
import { fragment } from '../../../fixtures/providers/server.ts';

const context: CallContext = { sessionId: 'main', turnId: 'turn', requestId: 'r', purpose: 'turn', api: 'openai-responses', profileRevision: 'p', requestedModel: 'alias' };
test('raw event index addresses exact split UTF-8 and CRLF bytes with observed timestamps and bounded metadata', () => {
  const store = new CaptureStore(), a = store.begin(context, 1, 0);
  const first = Buffer.from(': comment\r\nevent: unknown\r\ndata: {"word":"漢字🌍"}\r\n\r\n');
  const second = Buffer.from('event: next\rdata: broken\r\r');
  const index = new RawEventIndexer(e => store.index(a, e));
  let now = 1;
  for (const chunk of fragment(Buffer.concat([first,second]), [1,2,3])) { store.observe(a.response,chunk); index.observe(chunk,now++); }
  index.finish();
  assert.equal(a.rawEvents.length,2); assert.equal(a.rawEvents[0]!.event, 'unknown');
  for (const [i,expected] of [first,second].entries()) {
    const event = a.rawEvents[i]!; assert.deepEqual(Buffer.from(store.read(a.response,event.start,event.end-event.start)),expected);
    assert.ok(event.observedAt > 0);
  }
  for (let i=0;i<20_000;i++) store.index(a,{start:0,end:1,observedAt:i,event:'huge'});
  assert.equal(a.rawEvents.length,1024); assert.ok(a.rawEventsDropped > 0);
});
test('inspector scopes bodies, paginates native byte transfers, and separates Off from Clear', () => {
  const store = new CaptureStore({bodyBytes:40_000}), inspector = new Inspector(store);
  const a = store.begin(context,1,0); store.observe(a.request, new Uint8Array(50_000).fill(65)); store.finish(a.request,true);
  const page: any = inspector.command('debug.body','main',{attemptId:a.attemptId,body:'request'});
  assert.equal(Buffer.from(page.bytes,'base64').length,32768); assert.equal(page.state,'prefix-only'); assert.equal(page.observedBytes,50_000);
  assert.throws(()=>inspector.command('debug.body','side',{attemptId:a.attemptId,body:'request'}),/no retained/);
  inspector.command('debug.mode','main',{mode:'off'});
  assert.equal(a.request.retainedBytes,40_000);
  assert.equal(store.begin({...context,requestId:'next'},1,1).request.state,'disabled');
  assert.equal(store.begin({...context,sessionId:'side'},1,1).request.state,'recording');
  const meta = JSON.stringify(inspector.command('debug.list','main',{})); assert.ok(!meta.includes('chunks')); assert.ok(!meta.includes('AAAAAA'));
  inspector.command('debug.clear','main',{}); assert.equal(a.request.state,'unavailable'); assert.equal(store.retainedBytes,0);
});
test('attempt rates are host timings, unavailable stays null, cache is counted once for each API', () => {
  const store = new CaptureStore(), a = store.begin(context,1,100);
  assert.equal((attemptMetrics(a) as any).observedTTFTms,null);
  a.timings.firstContent=125; a.timings.firstText=180; a.timings.modelComplete=1100;
  a.usage={input:100,output:20,cacheRead:70,cacheWrite:0};
  const m: any=attemptMetrics(a); assert.equal(m.observedTTFTms,25); assert.equal(m.firstTextMs,80); assert.equal(m.outputTokensPerSecond,20); assert.equal(m.inputIncludingCache,100);
  const b=store.begin({...context,api:'anthropic-messages'},1,100); b.usage={input:30,output:null,cacheRead:60,cacheWrite:10};
  assert.equal((attemptMetrics(b) as any).inputIncludingCache,100); assert.equal((attemptMetrics(b) as any).outputTokensPerSecond,null);
});
