import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { FixtureServer, fragment } from '../../../../fixtures/providers/server.ts';
import { traffic } from '../../../../fixtures/providers/traffic.ts';
import { CaptureStore, type ApiKind } from '../observability/capture-store.ts';
import { PiSessionAdapter } from '../pi/session-adapter.ts';

// Local synthetic diagnostics only. Production credentials never enter these fixtures.
export async function providerProof(signal: AbortSignal, onText: (api: ApiKind, delta: string) => void): Promise<{ api: ApiKind; requests: number; exact: boolean }[]> {
  const directory = await mkdtemp(join(tmpdir(), 'pi-packaged-proof-'));
  const results: { api: ApiKind; requests: number; exact: boolean }[] = [];
  try {
    for (const api of ['openai-responses', 'anthropic-messages'] as const) {
      if (signal.aborted) throw new Error('Diagnostic cancelled');
      const capture = new CaptureStore();
      const server = await new FixtureServer((_request, index) => ({ chunks: fragment(traffic(api,
        index === 0 ? { tool: true } : { text: `Verified ${api}: Pi tool round trip and exact HTTP bytes. 🌍` })), delayMs: 0 })).start();
      const cwd = join(directory, api); await mkdir(cwd);
      let session: PiSessionAdapter | undefined;
      const abort = (): void => { void session?.abort(); };
      try {
        let dispatches = 0;
        session = await PiSessionAdapter.create({ cwd, agentDir: join(directory, 'agent'), capture, apiKey: 'synthetic-diagnostic-key',
          profile: { id: 'diagnostic', revision: '1', api, providerId: 'fixture-provider', modelId: 'fixture-model',
            baseUrl: server.origin + (api === 'openai-responses' ? '/v1' : ''), contextWindow: 8192, maxOutputTokens: 333 },
          fixtureEcho: async text => { dispatches++; return `Echo ${text}`; } });
        signal.addEventListener('abort', abort, { once: true });
        if (signal.aborted) throw new Error('Diagnostic cancelled');
        session.subscribe(e => { if (e.contentKind === 'text_delta' && e.delta) onText(api, e.delta); });
        await session.submit('Use the synthetic echo tool then answer.');
        const exact = capture.attempts.length === 2 && capture.attempts.every((a, index) =>
          a.request.state === 'complete' && a.response.state === 'complete' &&
          Buffer.from(capture.read(a.request)).equals(server.requests[index]!.bytes) &&
          Buffer.from(capture.read(a.response)).equals(Buffer.concat(server.emitted[index]!)));
        if (!exact || dispatches !== 1 || session.snapshot().at(-1)?.stopReason !== 'stop') throw new Error('Packaged provider fixture failed');
        results.push({ api, requests: server.requests.length, exact });
      } finally { signal.removeEventListener('abort', abort); await session?.dispose(); await server.close(); }
    }
    return results;
  } finally { await rm(directory, { recursive: true, force: true }); }
}
