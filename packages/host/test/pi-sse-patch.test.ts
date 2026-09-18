import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { InMemoryCredentialStore, InMemoryModelsStore } from '@earendil-works/pi-ai';
import { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { traffic } from '../../../fixtures/providers/traffic.ts';
import { CaptureStore } from '../src/observability/capture-store.ts';
import { instrumentRuntime } from '../src/pi/instrument-runtime.ts';

for (const ending of ['crlf', 'bare-cr-eof', 'lf']) {
  test(`pinned Pi Anthropic SSE: separate CR/LF reads, UTF-8 splits and ${ending}`, async () => {
    const original = traffic('anthropic-messages', { text: 'Split 🌍 漢字', unknown: true }).toString();
    const wire = Buffer.from(ending === 'lf' ? original.replaceAll('\r\n', '\n') : ending === 'bare-cr-eof' ? original.replaceAll('\r\n', '\r') : original);
    const runtime = await ModelRuntime.create({ credentials: new InMemoryCredentialStore(), modelsStore: new InMemoryModelsStore(), modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
    runtime.registerProvider('split-fixture', { api: 'anthropic-messages', baseUrl: 'http://127.0.0.1:1', models: [{id:'fixture-model',name:'fixture',api:'anthropic-messages',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:8192,maxTokens:333}] });
    await runtime.setRuntimeApiKey('split-fixture','synthetic-fixture-only');
    const capture = new CaptureStore();
    instrumentRuntime(runtime, capture, () => ({ sessionId:'split',turnId:'turn',purpose:'turn',profileRevision:'1',resourceRevision:'none',skillGrants:[] }));
    let sent: string | undefined;
    const transport: typeof fetch = async (_input, init) => {
      sent = String(init?.body); let index=0;
      // A synthetic fetch boundary guarantees every byte is a distinct SDK read;
      // TCP coalescing cannot hide a CR/LF or multi-byte UTF-8 boundary regression.
      return new Response(new ReadableStream<Uint8Array>({ pull(controller) {
        if(index===wire.length) controller.close(); else controller.enqueue(wire.subarray(index,++index));
      } }, {highWaterMark:0}), {headers:{'content-type':'text/event-stream'}});
    };
    const model=runtime.getModel('split-fixture','fixture-model'); assert.ok(model);
    const result=await runtime.completeSimple(model,{messages:[{role:'user',content:'Synthetic byte splits.',timestamp:1}]},{fetch:transport,transport:'sse'});
    assert.equal(result.stopReason,'stop');
    assert.deepEqual(result.content.filter(c=>c.type==='text').map(c=>c.text),['Split 🌍 漢字']);
    const attempt=capture.attempts[0]!;
    assert.equal(attempt.response.state,'complete');
    assert.equal(capture.hash(attempt.response).sha256,createHash('sha256').update(wire).digest('hex'));
    assert.deepEqual(Buffer.from(capture.read(attempt.response)),wire);
    assert.equal(Buffer.from(capture.read(attempt.request)).toString(),sent);
  });
}
