import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { FixtureServer, fragment } from '../../../fixtures/providers/server.ts';
import { traffic, responses, messages } from '../../../fixtures/providers/traffic.ts';
import { CaptureStore, type ApiKind } from '../src/observability/capture-store.ts';
import { PiSessionAdapter, type SessionOptions, type AdapterEvent } from '../src/pi/session-adapter.ts';

const apis: ApiKind[] = ['openai-responses', 'anthropic-messages'];
async function setup(t: TestContext, api: ApiKind, handler: ConstructorParameters<typeof FixtureServer>[0], overrides: Partial<SessionOptions> = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'pi-fixture-'));
  const cwd = join(directory, 'workspace'); await mkdir(cwd);
  const server = await new FixtureServer(handler).start();
  const capture = overrides.capture ?? new CaptureStore();
  const options: SessionOptions = { cwd, agentDir: join(directory, 'agent'), sessionDirectory: join(directory, 'sessions'), capture, apiKey: 'synthetic-fixture-key',
    profile: { id: 'fixture', revision: 'revision-1', providerId: 'fixture-provider', modelId: 'fixture-model', api,
      baseUrl: server.origin + (api === 'openai-responses' ? '/v1' : ''), contextWindow: 8192, maxOutputTokens: 333 }, ...overrides };
  const session = await PiSessionAdapter.create(options);
  t.after(async () => { await session.dispose(); await server.close(); assert.deepEqual(server.errors, []); });
  return { session, capture, server, directory, options };
}
function assertBytes(capture: CaptureStore, server: FixtureServer): void {
  assert.equal(capture.attempts.length, server.requests.length);
  for (const [index, attempt] of capture.attempts.entries()) {
    const request = server.requests[index]!;
    assert.equal(attempt.request.state, 'complete');
    assert.deepEqual(Buffer.from(capture.read(attempt.request, 0, 1024 * 1024)), request.bytes);
    assert.equal(capture.hash(attempt.request).sha256, createHash('sha256').update(request.bytes).digest('hex'));
    const response = Buffer.concat(server.emitted[index]!);
    assert.equal(attempt.response.state, 'complete');
    assert.deepEqual(Buffer.from(capture.read(attempt.response, 0, 1024 * 1024)), response);
    assert.equal(capture.hash(attempt.response).sha256, createHash('sha256').update(response).digest('hex'));
    assert.equal(capture.hash(attempt.response).scope, 'full');
    assert.equal(JSON.stringify([attempt.requestHeaders, attempt.responseHeaders]).includes('synthetic-fixture-key'), false);
  }
}

for (const api of apis) {
  test(`${api}: real Pi tool cycle, streaming, exact bytes, save/resume and manual compaction`, { timeout: 15000 }, async t => {
    let toolExecutions = 0;
    const plans = [traffic(api, { tool: true, thinking: true, unknown: true }), traffic(api, { unknown: true }),
      traffic(api, { text: 'Synthetic prior conversation. '.repeat(40) }), traffic(api, { text: 'Synthetic compacted summary.' }),
      traffic(api, { text: 'Synthetic turn prefix summary.' }), traffic(api, { text: 'Continued.' })];
    const { session, capture, server, directory, options } = await setup(t, api, (_request, index) => {
      assert.ok(plans[index], `Unexpected request ${index}`);
      return { chunks: fragment(plans[index]!, [1, 2, 3, 13, 17, 5]) };
    }, { fixtureEcho: async text => { toolExecutions++; assert.equal(text, '🌍'); return `Echo ${text}`; } });
    const events: AdapterEvent[] = []; session.subscribe(event => events.push(event));
    await session.submit('Use the fixture echo tool, then answer.', 'turn-fixture');
    assert.equal(toolExecutions, 1);
    assert.equal(server.requests.length, 2);
    assert.equal(session.snapshot().at(-1)?.text, 'Hello 🌍 漢字');
    assert.equal(session.snapshot().at(-1)?.stopReason, 'stop');
    assert.equal(events.filter(e => e.contentKind === 'text_delta').map(e => e.delta).join(''), 'Hello 🌍 漢字');
    assert.ok(events.some(e => e.contentKind === 'thinking_delta'));
    assert.ok(events.some(e => e.type === 'tool_execution_start' && e.toolName === 'fixture_echo'));
    assert.deepEqual(capture.attempts.map(a => [a.turnId, a.purpose, a.modelOutcome]), [
      ['turn-fixture', 'turn', 'completed'], ['turn-fixture', 'turn', 'completed']]);
    assert.notEqual(capture.attempts[0]!.requestId, capture.attempts[1]!.requestId);
    assert.ok(capture.attempts.every(a => a.unknownEventCount > 0));
    const first = capture.attempts[0]!;
    assert.ok(first.timings.firstContent !== null && first.timings.firstText === null);
    assert.equal(first.usage.output, 7);
    assert.equal(first.usage.cacheRead, 10);
    const serialized = server.requests.map(r => JSON.parse(r.bytes.toString()));
    assert.equal(serialized[0].model, 'fixture-model');
    assert.equal(serialized[0].stream, true);
    if (api === 'openai-responses') {
      assert.equal(server.requests[0]!.url, '/v1/responses');
      assert.equal(serialized[0].max_output_tokens, 333);
      assert.ok(serialized[1].input.some((item: { type: string; call_id: string; output: string }) =>
        item.type === 'function_call_output' && item.call_id === 'call_fixture' && item.output.includes('Echo 🌍')));
      assert.ok(serialized[1].input.some((item: { encrypted_content?: string }) => item.encrypted_content === 'fixture-opaque-continuation'));
    } else {
      assert.match(server.requests[0]!.url, /^\/v1\/messages(?:\?beta=true)?$/);
      assert.equal(serialized[0].max_tokens, 333);
      assert.ok(JSON.stringify(serialized[1].messages).includes('toolu_fixture'));
      assert.ok(JSON.stringify(serialized[1].messages).includes('Echo 🌍'));
      assert.ok(JSON.stringify(serialized[1].messages).includes('fixture-opaque-signature'));
    }
    assertBytes(capture, server);
    const path = session.sessionFile; assert.ok(path);
    const persisted = await readFile(path, 'utf8');
    assert.ok(persisted.includes('Echo 🌍'));
    assert.ok(persisted.includes(api === 'openai-responses' ? 'fixture-opaque-continuation' : 'fixture-opaque-signature'));
    await session.submit('Continue with this synthetic history. '.repeat(40));
    const compacted = await session.compact();
    assert.ok(compacted.summary.startsWith('Synthetic compacted summary.'));
    assert.equal(capture.attempts[3]!.purpose, 'compaction');
    assert.equal(capture.attempts[3]!.turnId, null);
    assert.equal(capture.attempts[3]!.modelOutcome, 'completed');
    assert.equal(capture.attempts[4]!.purpose, 'compaction');
    assert.equal(capture.attempts[4]!.turnId, null);
    assert.ok(compacted.summary.includes('Synthetic turn prefix summary.'));
    assertBytes(capture, server);
    assert.ok(session.snapshot().some(m => m.role === 'compactionSummary'));

    // A managed Pi file is authoritative; opaque provider fields survive disk persistence.
    await session.dispose();
    const resumed = await PiSessionAdapter.create({ ...options, resumePath: path, sessionDirectory: join(directory, 'sessions') });
    assert.ok(resumed.snapshot().some(m => m.text.includes('Synthetic compacted summary.')));
    await resumed.submit('Continue after resume.');
    assert.equal(resumed.snapshot().at(-1)?.text, 'Continued.');
    assert.ok(server.requests[5]!.bytes.includes(Buffer.from('Synthetic compacted summary.')));
    await resumed.dispose();
    assertBytes(capture, server);
  });

  test(`${api}: automatic compaction uses the captured Pi runtime without replaying the turn`, { timeout: 10000 }, async t => {
    const { session, capture, server } = await setup(t, api, (_request, index) => ({ chunks: fragment(traffic(api,
      index === 1 ? { text: 'Threshold reached.', inputTokens: 8000 } : index === 2 ? { text: 'Automatic checkpoint.' } : { text: 'Seed answer.' })) }),
    { autoCompaction: true });
    const events: AdapterEvent[] = []; session.subscribe(e => events.push(e));
    await session.submit('Seed conversation.');
    await session.submit('Continue this fixture history. '.repeat(40), 'auto-turn');
    assert.equal(server.requests.length, 3);
    assert.deepEqual(capture.attempts.map(a => a.purpose), ['turn', 'turn', 'compaction']);
    assert.equal(capture.attempts[2]!.turnId, 'auto-turn');
    assert.equal(capture.attempts[2]!.sessionId, session.id);
    assert.ok(events.some(e => e.type === 'compaction_start'));
    assert.ok(events.some(e => e.type === 'compaction_end'));
    assert.ok(session.snapshot().some(m => m.text.includes('Automatic checkpoint.')));
    assertBytes(capture, server);
  });

  for (const status of [400, 401, 429, 500]) {
    test(`${api}: HTTP ${status} preserves error bytes and does not retry silently`, { timeout: 10000 }, async t => {
      const body = Buffer.from(status === 500 ? '<!doctype html><p>Synthetic proxy failure 🌍</p>' :
        JSON.stringify({ type: 'error', error: { type: 'fixture_error', message: `Synthetic HTTP ${status}` } }));
      const { session, capture, server } = await setup(t, api, () => ({ status,
        headers: { 'content-type': status === 500 ? 'text/html' : 'application/json', 'x-secret-fixture': 'synthetic-fixture-key' }, chunks: fragment(body) }));
      await session.submit('Synthetic failing request.');
      assert.equal(server.requests.length, 1);
      assert.equal(session.snapshot().at(-1)?.stopReason, 'error');
      assert.equal(capture.attempts[0]!.status, status);
      assert.equal(capture.attempts[0]!.modelOutcome, 'failed');
      assertBytes(capture, server);
    });
  }

  test(`${api}: retry has separate attempts under one logical request`, { timeout: 10000 }, async t => {
    const { session, capture, server } = await setup(t, api, (_request, index) => index === 0 ? {
      status: 429, headers: { 'content-type': 'application/json', 'retry-after-ms': '1' },
      chunks: [Buffer.from('{"error":{"type":"rate_limit_error","message":"Synthetic retry"}}')],
    } : { chunks: fragment(traffic(api)) }, { providerRetries: 1 });
    await session.submit('Retry this fixture.');
    assert.equal(server.requests.length, 2);
    assert.equal(session.snapshot().at(-1)?.text, 'Hello 🌍 漢字');
    assert.equal(capture.attempts[0]!.requestId, capture.attempts[1]!.requestId);
    assert.deepEqual(capture.attempts.map(a => a.ordinal), [1, 2]);
    assert.deepEqual(capture.attempts.map(a => a.status), [429, 200]);
    assert.deepEqual(capture.attempts.map(a => a.outcome), ['failed', 'completed']);
    assert.ok(capture.attempts[1]!.timings.dispatch >= capture.attempts[0]!.timings.eof!);
    assertBytes(capture, server);
  });

  test(`${api}: HTTP 200 with a provider stream error is a failed model call`, { timeout: 10000 }, async t => {
    const bytes = traffic(api, { thinking: true, error: true });
    const { session, capture, server } = await setup(t, api, () => ({ chunks: [bytes] }));
    await session.submit('Fail within the stream.');
    const attempt = capture.attempts[0]!;
    assert.equal(server.requests.length, 1);
    assert.equal(attempt.status, 200);
    assert.equal(attempt.modelOutcome, 'failed');
    assert.equal(attempt.outcome, 'failed');
    assert.equal(attempt.timings.cancelled, null);
    assert.equal(attempt.transportActive, false);
    assert.equal(session.snapshot().at(-1)?.stopReason, 'error');
    assert.deepEqual(Buffer.from(capture.read(attempt.response)), bytes);
    // Provider parsing may stop before EOF; exact retained bytes are not proof of EOF.
    assert.ok(['prefix-only', 'complete'].includes(attempt.response.state));
  });

  test(`${api}: disconnected transport records an attempt without a fabricated response`, { timeout: 10000 }, async t => {
    const { session, capture, server } = await setup(t, api, () => ({ disconnectBeforeHeaders: true, chunks: [] }));
    await session.submit('Disconnect before headers.');
    assert.equal(server.requests.length, 1);
    const attempt = capture.attempts[0]!;
    assert.equal(attempt.status, null);
    assert.equal(attempt.timings.headers, null);
    assert.equal(attempt.response.state, 'unavailable');
    assert.equal(attempt.response.reason, 'no-response');
    assert.equal(attempt.modelOutcome, 'failed');
    assert.deepEqual(Buffer.from(capture.read(attempt.request)), server.requests[0]!.bytes);
  });

  for (const afterContent of [false, true]) {
    test(`${api}: cancellation ${afterContent ? 'after content' : 'before headers'} settles without replay`, { timeout: 10000 }, async t => {
      const received = Promise.withResolvers<void>();
      const release = Promise.withResolvers<void>();
      const content = Promise.withResolvers<void>();
      t.after(() => release.resolve());
      const parts = (api === 'openai-responses' ? responses : messages)();
      const { session, capture, server } = await setup(t, api, async () => {
        received.resolve();
        if (!afterContent) await release.promise;
        return { chunks: parts.map(p => Buffer.from(p)), beforeChunk: async index => { if (afterContent && index === 4) await release.promise; } };
      });
      session.subscribe(e => { if (e.contentKind === 'text_delta') content.resolve(); });
      const running = session.submit('A cancellable fixture.');
      await received.promise;
      if (afterContent) await content.promise;
      await session.abort(); await running; release.resolve();
      assert.equal(server.requests.length, 1);
      assert.equal(session.snapshot().at(-1)?.stopReason, 'aborted');
      assert.equal(session.isIdle, true);
      const attempt = capture.attempts[0]!;
      assert.equal(attempt.outcome, 'cancelled');
      assert.equal(attempt.modelOutcome, 'cancelled');
      assert.notEqual(attempt.timings.cancelled, null);
      assert.equal(attempt.timings.firstContent === null, !afterContent);
      assert.equal(attempt.response.state, afterContent ? 'prefix-only' : 'unavailable');
    });
  }

  test(`${api}: stop cancels an active tool without starting another provider call`, { timeout: 10000 }, async t => {
    const toolStarted = Promise.withResolvers<void>();
    let cancelled = false, dispatches = 0;
    const { session, server } = await setup(t, api, () => ({ chunks: fragment(traffic(api, { tool: true })) }), {
      fixtureEcho: async (_text, signal) => {
        dispatches++; toolStarted.resolve();
        await new Promise<void>(resolve => { signal?.addEventListener('abort', () => { cancelled = true; resolve(); }, { once: true }); });
        return 'Synthetic tool cancelled';
      },
    });
    const turn = session.submit('Cancel the tool.'); await toolStarted.promise;
    await session.abort(); await turn;
    assert.equal(cancelled, true); assert.equal(dispatches, 1); assert.equal(server.requests.length, 1);
    assert.equal(session.isIdle, true);
  });

  test(`${api}: failed compaction preserves the previous Pi history`, { timeout: 10000 }, async t => {
    const { session, capture, server } = await setup(t, api, (_request, index) => ({ chunks: [traffic(api, index === 2 ? { error: true } : {})] }));
    await session.submit('Seed conversation.');
    await session.submit('Recent context. '.repeat(50));
    const before = session.snapshot();
    await assert.rejects(session.compact(), /Synthetic stream failure/);
    assert.deepEqual(session.snapshot(), before);
    assert.equal(server.requests.length, 3);
    assert.equal(capture.attempts[2]!.purpose, 'compaction');
    assert.equal(capture.attempts[2]!.modelOutcome, 'failed');
    assert.equal(session.isIdle, true);
  });

  for (const mode of ['off', 'capped', 'failure'] as const) {
    test(`${api}: ${mode} recorder preserves a large Pi response`, { timeout: 10000 }, async t => {
      const capture = new CaptureStore({ bodyBytes: 4096, totalBytes: 8192 });
      if (mode === 'off') capture.mode = 'off';
      if (mode === 'failure') capture.observe = () => { throw new Error('Synthetic storage failure'); };
      const answer = 'Large synthetic output 🌍 漢字\n'.repeat(800);
      // The oversized unknown event remains raw, while the bounded observer discards its derived parse.
      const unknown = Buffer.from(`event: future_fixture\ndata: {"type":"future_fixture","padding":"${'x'.repeat(270_000)}"}\n\n`);
      const bytes = Buffer.concat([unknown, traffic(api, { text: answer })]);
      const { session, server } = await setup(t, api, () => ({ chunks: fragment(bytes, [16381, 13, 8191]) }), { capture });
      await session.submit('A synthetic large response.');
      assert.equal(session.snapshot().at(-1)?.text, answer);
      const attempt = capture.attempts[0]!;
      assert.equal(attempt.modelOutcome, 'completed');
      assert.equal(attempt.response.state, mode === 'off' ? 'disabled' : mode === 'capped' ? 'prefix-only' : 'capture-error');
      assert.ok(capture.allocatedBytes <= 8192);
      assert.equal(server.requests.length, 1);
      if (mode !== 'failure') assert.equal(attempt.response.observedBytes, bytes.length);
    });
  }
}

test('concurrent Pi sessions preserve immutable correlation and independent cancellation', { timeout: 10000 }, async t => {
  const release = Promise.withResolvers<void>();
  const started = Promise.withResolvers<void>();
  t.after(() => release.resolve());
  const main = await setup(t, 'openai-responses', async () => { started.resolve(); await release.promise; return { chunks: [traffic('openai-responses')] }; });
  const side = await setup(t, 'anthropic-messages', () => ({ chunks: fragment(traffic('anthropic-messages', { text: 'Independent side.' })) }), { capture: main.capture });
  const mainTurn = main.session.submit('Main fixture.', 'main-turn');
  await started.promise;
  await side.session.submit('Side fixture.', 'side-turn');
  await main.session.abort(); await mainTurn; release.resolve();
  assert.equal(side.session.snapshot().at(-1)?.text, 'Independent side.');
  assert.equal(side.session.snapshot().at(-1)?.stopReason, 'stop');
  assert.deepEqual(main.capture.attempts.map(a => [a.sessionId, a.turnId, a.outcome]), [
    [main.session.id, 'main-turn', 'cancelled'], [side.session.id, 'side-turn', 'completed'],
  ]);
});

test('main auto-compaction overlaps a side request without mixing purpose or abort signals', { timeout: 10000 }, async t => {
  const compacting = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  t.after(() => release.resolve());
  const main = await setup(t, 'openai-responses', async (_request, index) => {
    if (index === 2) { compacting.resolve(); await release.promise; }
    return { chunks: [traffic('openai-responses', index === 1 ? { inputTokens: 8000 } : index === 2 ? { text: 'Overlapping checkpoint.' } : {})] };
  }, { autoCompaction: true });
  await main.session.submit('Seed main.');
  const mainTurn = main.session.submit('Recent main context. '.repeat(50), 'main-compacting-turn');
  await compacting.promise;
  const side = await setup(t, 'anthropic-messages', () => ({ chunks: [traffic('anthropic-messages')] }), { capture: main.capture });
  await side.session.submit('Independent side while main compacts.', 'overlap-side-turn');
  await side.session.abort(); release.resolve(); await mainTurn;
  assert.ok(main.session.snapshot().some(m => m.text.includes('Overlapping checkpoint.')));
  assert.deepEqual(main.capture.attempts.slice(1).map(a => [a.sessionId, a.turnId, a.purpose]), [
    [main.session.id, 'main-compacting-turn', 'turn'],
    [main.session.id, 'main-compacting-turn', 'compaction'],
    [side.session.id, 'overlap-side-turn', 'turn'],
  ]);
  assert.equal(main.capture.attempts[2]!.outcome, 'completed');
});
