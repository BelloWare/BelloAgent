import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { getHeapStatistics } from 'node:v8';
import { FrameDecoder, encodeFrame, record, MAX_FRAME_BYTES } from '../../protocol/src/framing.ts';
import { sdkVersions } from './pi/sdk-version.ts';
import { OutputQueue } from './sessions/output-queue.ts';
import { CommandError } from './sessions/command-ledger.ts';
import type { SessionService } from './sessions/session-service.ts';

// No third-party diagnostic can print a payload or credential to protocol stdout.
process.umask(0o077);
let diagnostics = 0;
for (const method of ['log', 'info', 'warn', 'error', 'debug'] as const) console[method] = () => {
  if (diagnostics++ < 128) process.stderr.write('[host] Dependency diagnostic omitted; inspect captured requests in the app.\n');
};
const epoch = randomUUID();
const versions = sdkVersions();
let ready = false, closing = false;
let operation: Promise<void> | null = null;
let abort: AbortController | null = null;
let service: SessionService | undefined;
let serviceLoading: Promise<SessionService> | undefined;
let commands = 0;
const output = new OutputQueue(async bytes => { if (!process.stdout.write(bytes)) await once(process.stdout, 'drain'); }, () => { void shutdown(70); });
const send = (value: unknown): void => {
  if (closing) return;
  output.send(value);
};
async function shutdown(code = 0): Promise<void> {
  if (closing) return;
  closing = true; abort?.abort();
  const deadline = setTimeout(() => process.exit(code), 3000); deadline.unref();
  await service?.shutdown(); await operation; await output.drain();
  process.exit(code);
}
function receive(value: unknown): void {
  if (!record(value) || value.v !== 1) throw new Error('Unsupported protocol version');
  if (value.kind === 'hello' && value.major === 1 && !ready) {
    ready = true;
    send({ v: 1, kind: 'ready', hostEpoch: epoch, major: 1, minor: 0, node: process.versions.node, ...versions,
      limits: { frameBytes: MAX_FRAME_BYTES, captureBytes: 128 * 1024 * 1024 }, capabilities: ['diagnostics', 'runtime.info', 'sessions', 'queued-turns', 'managed-import'] });
    return;
  }
  if (!ready || value.kind !== 'command' || typeof value.commandId !== 'string' || value.commandId.length > 128 || value.hostEpoch !== epoch) throw new Error('Handshake or command identity is invalid');
  const commandId = value.commandId;
  const reply = (ok: boolean, result: unknown): void => send({ v: 1, kind: 'reply', hostEpoch: epoch, commandId, ok, result });
  if (value.method === 'shutdown') { reply(true, {}); void output.drain().then(() => shutdown()); return; }
  if (value.method === 'runtime.info') { reply(true, { ...versions, node: process.versions.node, pid: process.pid, memory: process.memoryUsage(), heapSizeLimit: getHeapStatistics().heap_size_limit, execArgv: process.execArgv }); return; }
  if (value.method === 'diagnostics.stop') { abort?.abort(); reply(true, {}); return; }
  if (value.method !== 'diagnostics.run') {
    if (typeof value.method !== 'string' || value.method.length > 128) throw new Error('Invalid method');
    if (commands >= 32 && value.method !== 'turn.stop') { reply(false, { code: 'command_capacity', message: 'Too many pending commands' }); return; }
    commands++;
    serviceLoading ??= import('./sessions/session-service.ts').then(({ SessionService }) => service = new SessionService((sessionId, seq, type) => {
      if (!closing) output.send({ v: 1, kind: 'event', hostEpoch: epoch, sessionId, seq, type: type ?? 'session.changed', payload: {} }, sessionId);
    }));
    void serviceLoading.then(service => service.command(commandId, value.method as string,
      typeof value.sessionId === 'string' ? value.sessionId : undefined, value.params)).then(result => reply(true, result), error =>
      reply(false, error instanceof CommandError ? { code: error.code, message: error.message } :
        { code: 'operation_failed', message: 'Operation failed. Check the saved session, profile, and endpoint. No automatic replay was attempted.' })).finally(() => { commands--; });
    return;
  }
  if (operation || service?.busy) { reply(false, { message: 'Work is already running' }); return; }
  reply(true, { accepted: true });
  abort = new AbortController();
  const signal = abort.signal;
  operation = (async () => {
    try {
      const { providerProof } = await import('./diagnostics/provider-proof.ts');
      // Coalesce diagnostic display text; the full provider proof runs independently.
      const texts = new Map<string, string>();
      const result = await providerProof(signal, (api, delta) => { texts.set(api, (texts.get(api) ?? '') + delta); });
      send({ v: 1, kind: 'event', hostEpoch: epoch, type: 'diagnostics.complete', payload: { result, messages: [...texts].map(([id, text]) => ({ id, role: 'assistant', text })) } });
    } catch { send({ v: 1, kind: 'event', hostEpoch: epoch, type: signal.aborted ? 'diagnostics.cancelled' : 'diagnostics.failed', payload: {} }); }
    finally { operation = null; abort = null; }
  })();
}
const decoder = new FrameDecoder();
process.stdin.on('data', (bytes: Buffer) => {
  try { decoder.feed(bytes, receive); } catch { send({ v: 1, kind: 'fatal', message: 'Invalid or incompatible protocol frame' }); void output.drain().then(() => shutdown(64)); }
});
process.stdin.on('end', () => { void shutdown(); });
process.on('SIGTERM', () => { void shutdown(); });
process.on('SIGINT', () => { void shutdown(); });
process.stdout.on('error', () => { void shutdown(70); });
