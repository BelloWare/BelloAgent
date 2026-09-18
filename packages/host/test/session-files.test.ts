import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, stat, open, readdir, appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { FrameDecoder, record } from '../../protocol/src/framing.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic } from '../../../fixtures/providers/traffic.ts';
import { CaptureStore } from '../src/observability/capture-store.ts';
import { PiSessionAdapter, type SessionOptions } from '../src/pi/session-adapter.ts';
import { inspectSessionFile, continueSessionCopy, recoverSessionCopy } from '../src/pi/session-files.ts';

test('Pi command receipts persist, imported originals stay unchanged, and a continued copy has a new identity', { timeout: 10000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'pi-import-test-'));
  const sourceDir = join(root, 'source'), managed = join(root, 'managed'); await mkdir(sourceDir); await mkdir(managed);
  const server = await new FixtureServer((_request, index) => ({ chunks: [traffic('openai-responses', { tool: index === 0, thinking: index === 0 })] })).start();
  t.after(() => server.close());
  const options: SessionOptions = { cwd: root, agentDir: join(root, 'agent'), sessionDirectory: sourceDir, apiKey: 'synthetic-key', capture: new CaptureStore(),
    profile: { id: 'fixture', revision: 'one', providerId: 'fixture-provider', api: 'openai-responses', baseUrl: server.origin + '/v1',
      modelId: 'fixture-model', contextWindow: 8192, maxOutputTokens: 333 }, fixtureEcho: async text => text };
  const original = await PiSessionAdapter.create(options);
  original.recordCommand('command-source', 'turn-source', 'dispatched');
  assert.equal(await original.submit('Synthetic saved tool conversation.', 'turn-source'), 'completed');
  original.recordCommand('command-source', 'turn-source', 'completed');
  const source = original.sessionFile; assert.ok(source);
  const originalID = original.id; await original.dispose();
  const bytes = await readFile(source); const inspected = await inspectSessionFile(source);
  assert.equal(inspected.id, originalID);
  assert.equal((await stat(source)).size, inspected.bytes);
  const copyID = randomUUID();
  const copied = await continueSessionCopy(source, root, managed, copyID);
  assert.equal(copied.source.sha256, inspected.sha256);
  assert.notEqual(copied.sessionFile, source); assert.deepEqual(await readFile(source), bytes);
  assert.equal((await stat(copied.sessionFile)).mode & 0o777, 0o600);
  const resumed = await PiSessionAdapter.create({ ...options, sessionDirectory: managed, sessionId: copyID, resumePath: copied.sessionFile });
  assert.equal(resumed.id, copyID); assert.notEqual(resumed.id, originalID);
  assert.deepEqual(resumed.commandHistory().map(c => c.state), ['dispatched', 'completed']);
  assert.equal(server.requests.length, 2, 'Opening must not run any provider or tool');
  await resumed.submit('Continue this independent copy.'); await resumed.dispose();
  assert.deepEqual(await readFile(source), bytes);
  assert.ok((await readFile(copied.sessionFile, 'utf8')).includes('fixture-opaque-continuation'));
  assert.ok((await readFile(copied.sessionFile, 'utf8')).includes('pi-app.import.v1'));
  await assert.rejects(PiSessionAdapter.create({ ...options, sessionDirectory: managed, resumePath: source }), /app-managed copy/);
  await assert.rejects(PiSessionAdapter.create({ ...options, resumePath: source, profile: { ...options.profile, baseUrl: 'https://different.invalid/v1' } }), /profile or route differs/);
  assert.deepEqual(await readFile(source), bytes);
});

test('strict session validation rejects incomplete tails and invalid bytes without changing the original', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-invalid-session-'));
  const header = JSON.stringify({ type: 'session', version: 3, id: randomUUID(), timestamp: '2026-09-14T00:00:00.000Z', cwd: root }) + '\n';
  for (const [name, bytes] of [
    ['tail', Buffer.from(header + '{"type":"message"')],
    ['utf8', Buffer.concat([Buffer.from(header + '{"type":"'), Buffer.from([255]), Buffer.from('"}\n')])],
    ['parent', Buffer.from(header + JSON.stringify({ type: 'message', id: 'entry', parentId: 'missing', message: { role: 'user', content: 'x' } }) + '\n')],
    ['future', Buffer.from(JSON.stringify({ type: 'session', version: 99, id: randomUUID() }) + '\n')],
  ] as const) {
    const path = join(root, name + '.jsonl'); await writeFile(path, bytes);
    await assert.rejects(inspectSessionFile(path));
    await assert.rejects(continueSessionCopy(path, root, join(root, 'copies')));
    assert.deepEqual(await readFile(path), bytes);
  }
});

test('active-file limits reject a large sparse file before allocating its body', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-large-session-')), path = join(root, 'large.jsonl');
  const file = await open(path, 'wx'); await file.truncate(128 * 1024 * 1024 + 1); await file.close();
  await assert.rejects(inspectSessionFile(path), /128 MiB active-file limit/);
});

test('explicit tail recovery preserves every original byte and refuses corruption before the tail', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-recovered-session-')), source = join(root, 'source.jsonl');
  const header = { type: 'session', version: 3, id: randomUUID(), timestamp: '2026-09-14T00:00:00.000Z', cwd: root };
  const message = { type: 'message', id: 'message', parentId: null, timestamp: header.timestamp, message: { role: 'assistant', content: [{ type: 'text', text: 'Retained history.' }], api: 'openai-responses', provider: 'fixture', model: 'fixture-model', stopReason: 'stop', timestamp: 1 } };
  const prefix = JSON.stringify(header) + '\n' + JSON.stringify(message) + '\n', tail = '{"type":"message","broken":"🌍';
  const original = Buffer.from(prefix + tail); await writeFile(source, original);
  const id = randomUUID(), result = await recoverSessionCopy(source, root, join(root, 'managed'), id);
  assert.deepEqual(await readFile(source), original); assert.deepEqual(await readFile(result.preservedOriginal), original);
  assert.equal(result.omittedTailBytes, Buffer.byteLength(tail)); assert.equal((await inspectSessionFile(result.sessionFile)).id, id);
  assert.ok((await readFile(result.sessionFile, 'utf8')).includes('pi-app.recovery.v1'));
  await writeFile(source, JSON.stringify(header) + '\n{bad record}\n' + tail);
  await assert.rejects(recoverSessionCopy(source, root, join(root, 'other'), randomUUID()), /Malformed/);
  await writeFile(source, JSON.stringify(header) + '\n' + tail);
  const empty = await recoverSessionCopy(source, root, join(root, 'empty'), randomUUID());
  const saved = await readFile(empty.sessionFile, 'utf8');
  assert.ok(saved.includes('pi-app.import.v1')); assert.ok(saved.includes('pi-app.recovery.v1'));
  assert.ok(!saved.includes('"role":"assistant"'), 'Recovery cannot invent assistant output to force a flush');
});

test('source changes abort import and an existing snapshot destination is never removed', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-changing-session-')), source = join(root, 'source.jsonl'), snapshot = join(root, 'snapshot.jsonl');
  const header = JSON.stringify({ type: 'session', version: 3, id: randomUUID(), timestamp: '2026-09-14T00:00:00.000Z', cwd: root });
  const row = JSON.stringify({ type: 'message', id: 'entry', parentId: null, message: { role: 'user', content: 'x'.repeat(100_000) } });
  await writeFile(source, header + '\n' + row + '\n');
  await writeFile(snapshot, 'pre-existing destination');
  await assert.rejects(inspectSessionFile(source, snapshot));
  assert.equal(await readFile(snapshot, 'utf8'), 'pre-existing destination');
  let changed = false;
  await assert.rejects(inspectSessionFile(source, join(root, 'new-snapshot.jsonl'), async () => {
    if (!changed) { changed = true; await appendFile(source, JSON.stringify({ type: 'custom', id: 'extra', parentId: 'entry', customType: 'fixture', data: {} }) + '\n'); }
  }), /changed during import/);
  assert.equal((await readFile(source, 'utf8')).includes('extra'), true);
  await assert.rejects(stat(join(root, 'new-snapshot.jsonl')), { code: 'ENOENT' });
});

test('a killed host after a real Pi tool effect resumes history without replaying the tool or command', { timeout: 15000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'pi-crash-test-')), id = randomUUID();
  const server = await new FixtureServer((_request, index) => ({ chunks: [traffic('openai-responses', index === 0 ? { tool: true } : { text: 'Continued after review.' })] })).start();
  t.after(() => server.close());
  const child = spawn(process.execPath, ['--import', 'tsx', 'packages/host/test/helpers/crash-worker.ts', root, server.origin, id], {
    cwd: process.cwd(), env: { HOME: root, TMPDIR: tmpdir(), PATH: process.env.PATH ?? '/usr/bin:/bin' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); });
  const effect = Promise.withResolvers<void>(), decoder = new FrameDecoder();
  child.stdout.on('data', (chunk: Buffer) => decoder.feed(chunk, value => { if (record(value) && value.phase === 'effect-written') effect.resolve(); }));
  child.stderr.on('data', () => {});
  await effect.promise;
  assert.equal(await readFile(join(root, 'synthetic-effect.txt'), 'utf8'), 'effect\n');
  const exited = once(child, 'exit'); child.kill('SIGKILL'); await exited;
  const name = (await readdir(join(root, 'sessions'))).find(name => name.endsWith('.jsonl')); assert.ok(name);
  const path = join(root, 'sessions', name);
  assert.equal((await inspectSessionFile(path)).id, id);
  let newToolExecutions = 0;
  const resumed = await PiSessionAdapter.create({ sessionId: id, cwd: root, agentDir: join(root, 'agent'), sessionDirectory: join(root, 'sessions'), resumePath: path,
    capture: new CaptureStore(), apiKey: 'synthetic-crash-key',
    profile: { id: 'crash-fixture', revision: 'one', providerId: 'fixture-provider', api: 'openai-responses', baseUrl: server.origin + '/v1',
      modelId: 'fixture-model', contextWindow: 8192, maxOutputTokens: 333 }, fixtureEcho: async () => { newToolExecutions++; return 'unexpected'; } });
  t.after(() => resumed.dispose());
  assert.equal(server.requests.length, 1);
  assert.deepEqual(resumed.commandHistory(), [{ commandId: 'uncertain-command', turnId: 'interrupted-turn', state: 'dispatched' }]);
  assert.equal(newToolExecutions, 0);
  await resumed.submit('Continue after reviewing the interrupted run.', 'new-explicit-turn');
  assert.equal(resumed.snapshot().at(-1)?.text, 'Continued after review.');
  assert.equal(newToolExecutions, 0);
  assert.equal(await readFile(join(root, 'synthetic-effect.txt'), 'utf8'), 'effect\n');
  const request = JSON.parse(server.requests[1]!.bytes.toString());
  const recovered = request.input.find((item: { type: string; call_id?: string }) => item.type === 'function_call_output' && item.call_id === 'call_fixture');
  assert.ok(recovered, 'Pi must supply a protocol-valid missing-tool result during explicit continuation');
});

test('portable handoff strips opaque state into an editable draft and preserves its entire source snapshot', async () => {
  const { portableContextDraft } = await import('../src/pi/session-files.ts');
  const root = await mkdtemp(join(tmpdir(), 'pi-portable-')), source = join(root, 'source.jsonl');
  const records = [
    { type: 'session', version: 3, id: randomUUID(), timestamp: '2026-09-14T00:00:00.000Z', cwd: root },
    { type: 'message', id: 'user', parentId: null, message: { role: 'user', content: 'Earlier question' } },
    { type: 'message', id: 'assistant', parentId: 'user', message: { role: 'assistant', content: [ { type: 'thinking', thinking: 'Private thinking', thinkingSignature: 'opaque-signature' }, { type: 'text', text: 'Useful answer', textSignature: 'opaque-response-id' } ], api: 'openai-responses', provider: 'fixture', model: 'fixture-model', stopReason: 'stop', timestamp: 1 } },
  ];
  const bytes = Buffer.from(records.map(x => JSON.stringify(x)).join('\n')+'\n'); await writeFile(source, bytes);
  const result: any = await portableContextDraft(source, root, join(root,'managed'));
  assert.ok(result.draft.includes('Useful answer')); assert.ok(!result.draft.includes('Private thinking')); assert.ok(!result.draft.includes('opaque-signature')); assert.ok(!result.draft.includes('opaque-response-id'));
  assert.deepEqual(await readFile(source),bytes); assert.deepEqual(await readFile(result.provenance.snapshotPath),bytes);
  const copied = await continueSessionCopy(source, root, join(root,'other'));
  await assert.rejects(PiSessionAdapter.create({cwd:root,agentDir:root,sessionDirectory:join(root,'other'),resumePath:copied.sessionFile,apiKey:'synthetic',capture:new CaptureStore(),profile:{id:'new',revision:'r',providerId:'fixture',modelId:'fixture-model',api:'openai-responses',baseUrl:'http://127.0.0.1:1/v1',contextWindow:8192,maxOutputTokens:1024}}),/opaque provider state/);
});
