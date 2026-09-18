import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, access } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { discoverProfiles, profileFrom, resolveEndpoint, resolveProfileCredentials, type Profile } from '../src/pi/profiles.ts';
import { PiSessionAdapter } from '../src/pi/session-adapter.ts';
import { CaptureStore } from '../src/observability/capture-store.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic } from '../../../fixtures/providers/traffic.ts';

test('endpoint normalization resolves both APIs once and rejects doubled/mixed paths', () => {
  for (const api of ['openai-responses','anthropic-messages'] as const) {
    const leaf = api === 'openai-responses' ? 'responses' : 'messages';
    for (const path of ['', '/', '/v1', `/v1/${leaf}`, `/v1/${leaf}/`]) {
      const endpoint = resolveEndpoint(api, 'https://fixture.example' + path);
      assert.equal(endpoint.requestUrl, `https://fixture.example/v1/${leaf}`);
      assert.deepEqual(resolveEndpoint(api, endpoint.baseUrl), endpoint);
    }
    assert.throws(() => resolveEndpoint(api, `https://fixture.example/v1/${leaf}/${leaf}`));
    assert.throws(() => resolveEndpoint(api, 'https://fixture.example/v1/v1'));
    assert.throws(() => resolveEndpoint(api, 'https://fixture.example?key=secret'));
  }
});

test('Pi discovery is credential-blind; activation is hash-bound, read-only, and resolves commands off the host lane', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-profile-'));
  try {
    const path = join(root,'models.json'), marker = join(root,'executed');
    await writeFile(path, JSON.stringify({ providers: { fixture: { api: 'openai-responses', baseUrl: 'http://127.0.0.1:1/v1',
      apiKey: `!sleep 0.2; touch '${marker}'; printf synthetic-fixture-key`, headers: { 'x-fixture': '$!literal-$$-value' },
      models: [{ id: 'fixture-model', name: 'A router alias', reasoning: true, input: ['text','image'], contextWindow: 64000, maxTokens: 2048,
        thinkingLevelMap: { high: 'medium' }, compat: { supportsStrictMode: false }, samplingParams: { temperature: 0.25 } }] } } }));
    await writeFile(join(root,'auth.json'), '{}');
    await writeFile(join(root,'settings.json'), JSON.stringify({defaultThinkingLevel:'low', modelThinkingLevels:{'fixture/fixture-model':'high'}}));
    const original = await readFile(path);
    const discovered: any = await discoverProfiles(path);
    assert.equal(discovered.discoveryMadeModelCall, false); assert.equal(discovered.profiles.length, 1);
    await assert.rejects(access(marker));
    const item = discovered.profiles[0]; assert.equal(item.maxOutputTokens, 2048); assert.equal(item.contextWindow, 64000);
    assert.deepEqual(item.thinkingLevelMap, { high: 'medium' }); assert.deepEqual(item.input, ['text','image']);
    assert.equal(item.thinkingLevel, 'high'); assert.ok(item.source.settingsSHA256); assert.equal(item.commandCredentials, true); assert.ok(!JSON.stringify(item).includes('synthetic-fixture-key')); assert.ok(!JSON.stringify(item).includes('literal-'));
    await assert.rejects(resolveProfileCredentials(profileFrom(item)), /executable credential/);
    item.source.commandTrust = true;
    let ticks = 0; const timer = setInterval(() => ticks++, 10);
    const resolved = await resolveProfileCredentials(profileFrom(item)); clearInterval(timer);
    assert.ok(ticks >= 10); assert.equal(resolved.apiKey, 'synthetic-fixture-key'); assert.equal(resolved.headers['x-fixture'], '!literal-$-value');
    assert.deepEqual(await readFile(path), original); assert.equal((await readFile(join(root,'auth.json'))).toString(), '{}');
    await writeFile(path, original.toString() + '\n');
    await assert.rejects(resolveProfileCredentials(profileFrom(item)), /changed since selection/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

for (const api of ['openai-responses', 'anthropic-messages'] as const) test(`${api}: full profile fields reach Pi's serialized request and headers exactly once`, async () => {
  const root = await mkdtemp(join(tmpdir(), 'pi-profile-wire-'));
  const server = await new FixtureServer(() => ({ chunks: [traffic(api)] })).start();
  let adapter: PiSessionAdapter | undefined;
  try {
    const profile: Profile = profileFrom({ id: 'p', revision: 'r', providerId: 'fixture', modelId: 'fixture-model', api,
      baseUrl: `${server.origin}/v1/${api === 'openai-responses' ? 'responses' : 'messages'}`, contextWindow: 128000, maxOutputTokens: 4096,
      reasoning: true, thinkingLevel: 'high', thinkingLevelMap: { high: 'medium' }, input: ['text', 'image'],
      samplingParams: { temperature: 0.2 }, headers: { 'x-fixture': '!literal-$-value' } });
    const capture = new CaptureStore();
    adapter = await PiSessionAdapter.create({ cwd: root, agentDir: root, profile, apiKey: 'synthetic', capture });
    await adapter.submit('Synthetic profile check');
    const request = server.requests[0]!; assert.equal(request.headers['x-fixture'], '!literal-$-value');
    assert.equal(new URL(request.url, server.origin).pathname, `/v1/${api === 'openai-responses' ? 'responses' : 'messages'}`);
    const body = JSON.parse(request.bytes.toString());
    if (api === 'anthropic-messages') { assert.equal(body.max_tokens, 4096); assert.ok(body.thinking); }
    else { assert.equal(body.reasoning.effort, 'medium'); assert.equal(body.max_output_tokens, 4096); }
    assert.equal(capture.attempts[0]!.requestHeaders['x-fixture'], '[REDACTED]');
    assert.deepEqual(Buffer.from(capture.read(capture.attempts[0]!.request)), request.bytes);
  } finally { await adapter?.dispose(); await server.close(); await rm(root, { recursive: true, force: true }); }
});
