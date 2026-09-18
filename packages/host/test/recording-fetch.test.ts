import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FixtureServer, fragment } from '../../../fixtures/providers/server.ts';
import { CaptureStore, redactHeaders, redactUrl, type CallContext } from '../src/observability/capture-store.ts';
import { recordingFetch } from '../src/observability/recording-fetch.ts';
import { SSEObserver } from '../src/observability/sse-observer.ts';

const context: CallContext = Object.freeze({ sessionId: 'session-A', turnId: 'turn-A', requestId: 'request-A',
  purpose: 'turn', api: 'openai-responses', profileRevision: 'fixture-v1', requestedModel: 'fixture-model' });

test('fetch preserves serialized request, fragmented response bytes, and response semantics', async t => {
  const bytes = Buffer.from(': comment\r\nevent: future_event\r\ndata: { "type": "vendor.unknown", "value": "🌍漢字" }\r\n\r\n');
  const server = await new FixtureServer(() => ({ chunks: fragment(bytes), headers: { 'x-request-id': 'fixture-1', 'x-private': 'hidden' } })).start();
  t.after(() => server.close());
  const store = new CaptureStore();
  const fetch = recordingFetch(store, context);
  const payload = ' { "input" : "hello\n🌍", "unknown": [1, 2] } ';
  const response = await fetch(`${server.origin}/v1/responses?api_key=synthetic-secret`, {
    method: 'POST', headers: { authorization: 'Bearer synthetic-secret', 'x-new-credential': 'hidden' }, body: payload,
  });
  assert.equal(response.url, `${server.origin}/v1/responses?api_key=synthetic-secret`);
  assert.equal(response.redirected, false); assert.equal(response.status, 200);
  assert.equal(response.bodyUsed, false);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
  assert.equal(response.bodyUsed, true);
  const attempt = store.attempts[0]!;
  assert.deepEqual(Buffer.from(store.read(attempt.request)), server.requests[0]!.bytes);
  assert.deepEqual(Buffer.from(store.read(attempt.response)), Buffer.concat(server.emitted[0]!));
  assert.equal(attempt.response.state, 'complete'); assert.equal(attempt.unknownEventCount, 1);
  assert.equal(attempt.timings.firstContent, null); assert.equal(attempt.outcome, 'completed');
  assert.equal(attempt.requestHeaders.authorization, '[REDACTED]');
  assert.equal(attempt.responseHeaders['x-private'], '[REDACTED]');
  assert.equal(attempt.responseHeaders['x-request-id'], 'fixture-1');
  assert.ok(!attempt.redactedUrl.includes('synthetic-secret'));
});

test('Request plus init overrides reach the server without body mutation', async t => {
  const server = await new FixtureServer(() => ({ chunks: [Buffer.from('{"ok":true}')], headers: { 'content-type': 'application/json' } })).start();
  t.after(() => server.close());
  const store = new CaptureStore();
  const original = new Request(server.origin, { method: 'POST', body: 'old', headers: { 'x-old': 'old' } });
  const response = await recordingFetch(store, context)(original, { method: 'PUT', body: 'new 🌍', headers: { 'content-type': 'text/plain' } });
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(server.requests[0]!.method, 'PUT'); assert.equal(server.requests[0]!.bytes.toString(), 'new 🌍');
  assert.equal(server.requests[0]!.headers['x-old'], undefined);
  assert.deepEqual(Buffer.from(store.read(store.attempts[0]!.request)), server.requests[0]!.bytes);
});

test('HTML errors and no-body responses preserve HTTP status and content', async t => {
  const bytes = Buffer.from('<html>synthetic provider failure</html>');
  const server = await new FixtureServer((_, i) => i === 0 ? { status: 500, headers: { 'content-type': 'text/html' }, chunks: [bytes] } : { status: 204, chunks: [] }).start();
  t.after(() => server.close());
  const store = new CaptureStore(); const fetch = recordingFetch(store, context);
  const failed = await fetch(server.origin); assert.equal(failed.status, 500); assert.equal(await failed.text(), bytes.toString());
  assert.equal(store.attempts[0]!.outcome, 'failed'); assert.equal(store.attempts[0]!.response.state, 'complete');
  const empty = await fetch(server.origin); assert.equal(empty.status, 204); assert.equal(empty.body, null);
  assert.equal(store.attempts[1]!.response.state, 'complete');
});

test('redirects are rejected without forwarding credentials to an unseen hop', async t => {
  const server = await new FixtureServer(() => ({ status: 307, headers: { location: '/secret-destination' }, chunks: [] })).start();
  t.after(() => server.close());
  const store = new CaptureStore();
  await assert.rejects(recordingFetch(store, context)(server.origin, { headers: { authorization: 'Bearer fixture' } }));
  assert.equal(server.requests.length, 1); assert.equal(store.attempts[0]!.status, null);
  assert.equal(store.attempts[0]!.response.state, 'unavailable');
});

test('early consumer cancellation leaves an honest prefix and cancels the upstream reader', async () => {
  let cancelled = false, pulls = 0;
  const upstream = new Response(new ReadableStream<Uint8Array>({
    pull(controller) { pulls++; controller.enqueue(Buffer.from('chunk')); },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 }));
  const store = new CaptureStore();
  const response = await recordingFetch(store, context, { fetch: async () => upstream })('https://fixture.invalid');
  assert.equal(pulls, 0);
  const reader = response.body!.getReader(); await reader.read(); await reader.cancel();
  assert.equal(pulls, 1); assert.equal(cancelled, true);
  assert.equal(store.attempts[0]!.response.state, 'prefix-only');
  assert.equal(store.attempts[0]!.timings.eof, null);
});

test('aborting before headers records cancellation without inventing a response', async () => {
  const controller = new AbortController(); controller.abort();
  const store = new CaptureStore();
  await assert.rejects(recordingFetch(store, context)('http://127.0.0.1:1', { signal: controller.signal }));
  const attempt = store.attempts[0]!;
  assert.equal(attempt.outcome, 'cancelled'); assert.equal(attempt.status, null);
  assert.equal(attempt.response.state, 'unavailable'); assert.notEqual(attempt.timings.cancelled, null);
});

test('recorder failure never prevents delivery to the SDK consumer', async () => {
  const store = new CaptureStore();
  store.observe = () => { throw new Error('Synthetic recorder failure'); };
  const bytes = Buffer.from('unchanged');
  const response = await recordingFetch(store, context, { fetch: async () => new Response(bytes) })('https://fixture.invalid', { method: 'POST', body: 'body' });
  assert.equal(await response.text(), 'unchanged');
  assert.equal(store.attempts[0]!.request.state, 'capture-error');
  assert.equal(store.attempts[0]!.response.state, 'capture-error');
});

test('capture off and exhausted metadata preserve traffic with explicit coverage gaps', async () => {
  for (const capped of [false, true]) {
    const store = new CaptureStore(capped ? { attempts: 0 } : {}); store.mode = 'off';
    const response = await recordingFetch(store, context, { fetch: async () => new Response('ok') })('https://fixture.invalid');
    assert.equal(await response.text(), 'ok'); assert.equal(store.retainedBytes, 0);
    if (capped) assert.equal(store.droppedMetadata, 1);
    else assert.equal(store.attempts[0]!.response.state, 'disabled');
  }
});

test('body and allocation budgets bound tiny chunks; counts continue after prefix truncation', () => {
  const store = new CaptureStore({ totalBytes: 200, bodyBytes: 100 });
  const attempt = store.begin(context, 1, 0);
  for (let i = 0; i < 200; i++) store.observe(attempt.response, Uint8Array.of(i));
  store.finish(attempt.response, true);
  assert.equal(attempt.response.observedBytes, 200); assert.equal(attempt.response.retainedBytes, 100);
  assert.equal(attempt.response.state, 'prefix-only'); assert.equal(attempt.response.chunks.length, 1);
  assert.ok(store.allocatedBytes <= 200); assert.equal(store.hash(attempt.response).scope, 'retained-prefix');
  assert.deepEqual(store.read(attempt.response), Uint8Array.from({ length: 100 }, (_, i) => i));
});

test('completed bodies evict before active bodies and clear cannot start recording a suffix', () => {
  const store = new CaptureStore({ totalBytes: 16, bodyBytes: 8, attempts: 2 });
  const first = store.begin(context, 1, 0); store.observe(first.response, '12345678'); store.finish(first.response, true); first.outcome = 'completed'; first.transportActive = false;
  const second = store.begin({ ...context, requestId: 'next' }, 1, 1); store.observe(second.request, 'abcdefgh');
  store.observe(second.response, 'ijklmnop');
  assert.equal(first.response.state, 'evicted'); assert.equal(second.request.state, 'recording');
  assert.equal(store.retainedBytes, 16); assert.equal(store.allocatedBytes, 16);
  store.clear(); store.observe(second.response, 'suffix');
  assert.equal(store.retainedBytes, 0); assert.equal(second.response.state, 'unavailable');
});

test('an HTTP error body remains active until transport ends and cannot evict its own prefix', () => {
  const store = new CaptureStore({ totalBytes: 16, bodyBytes: 16, attempts: 1 });
  const attempt = store.begin(context, 1, 0); attempt.status = 500; attempt.outcome = 'failed';
  store.observe(attempt.request, 'request'); store.observe(attempt.response, '0123456789');
  store.observe(attempt.response, 'later');
  assert.equal(attempt.request.state, 'recording');
  assert.equal(attempt.response.state, 'prefix-only');
  assert.equal(attempt.response.observedBytes, 15);
  assert.throws(() => store.begin(context, 2, 1), /Active attempt/);
  assert.equal(store.attempts[0], attempt);
  assert.ok(store.allocatedBytes <= 16);
});

test('SSE observations distinguish thinking/tool TTFT from first text and use cumulative usage', () => {
  let clock = 0;
  const store = new CaptureStore(); const attempt = store.begin({ ...context, api: 'anthropic-messages' }, 1, clock);
  const observer = new SSEObserver(attempt);
  const emit = (data: unknown, at: number): void => {
    clock = at;
    for (const byte of fragment(Buffer.from(`event: arbitrary\r\ndata: ${JSON.stringify(data)}\r\n\r\n`), [1])) observer.observe(byte, clock);
  };
  emit({ type: 'message_start', message: { model: 'reported', usage: { input_tokens: 9, output_tokens: 1 } } }, 5);
  emit({ type: 'ping' }, 6);
  emit({ type: 'content_block_delta', delta: { type: 'signature_delta', signature: 'opaque' } }, 8);
  emit({ type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: '🌍' } }, 10);
  emit({ type: 'content_block_delta', delta: { type: 'text_delta', text: 'Answer' } }, 20);
  emit({ type: 'message_delta', usage: { output_tokens: 4 } }, 25);
  emit({ type: 'message_delta', usage: { output_tokens: 7 } }, 30);
  emit({ type: 'message_stop' }, 40); observer.finish();
  assert.equal(attempt.timings.firstContent, 10); assert.equal(attempt.timings.firstText, 20);
  assert.equal(attempt.usage.output, 7); assert.equal(attempt.usage.input, 9);
  assert.equal(attempt.timings.modelComplete, 40); assert.equal(attempt.observerErrors, 0);
});

test('observer handles multiline data and bounds oversized/malformed events without altering raw capture', () => {
  const store = new CaptureStore(); const attempt = store.begin(context, 1, 0); const observer = new SSEObserver(attempt, 100);
  observer.observe(Buffer.from('data: {"type":\r\ndata: "response.output_text.delta", "delta":"x"}\r\n\r\n'), 10);
  observer.observe(Buffer.from(`data: ${'x'.repeat(200)}\n\ndata: malformed\n\n`), 20);
  assert.equal(attempt.timings.firstText, 10); assert.equal(attempt.observerErrors, 2);
});

test('secret metadata is redacted even if explicitly allowlisted', () => {
  const headers = redactHeaders(new Headers({ authorization: 'secret', cookie: 'secret', 'x-api-key': 'secret', 'x-team': 'visible' }), ['authorization', 'x-team']);
  assert.equal(headers.authorization, '[REDACTED]'); assert.equal(headers['x-team'], 'visible');
  assert.ok(!redactUrl('https://user:password@fixture.invalid/api?credential=secret#fragment').includes('secret'));
});
