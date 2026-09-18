import type { RawEventRange } from './raw-event-index.ts';
import { createHash, randomUUID } from 'node:crypto';

export type ApiKind = 'openai-responses' | 'anthropic-messages';
export type Purpose = 'turn' | 'compaction' | 'connection-test' | 'auxiliary';
export type CaptureState = 'recording' | 'complete' | 'prefix-only' | 'evicted' | 'disabled' | 'unavailable' | 'capture-error';
export interface CallContext {
  readonly sessionId: string;
  readonly turnId: string | null;
  readonly requestId: string;
  readonly purpose: Purpose;
  readonly api: ApiKind;
  readonly profileRevision: string;
  readonly requestedModel: string;
  readonly resourceRevision?: string;
  readonly skillGrants?: readonly { id: string; contentHash: string; metadataHash: string }[];
  readonly sideSnapshot?: { parentSessionId: string; cutoffEntryId: string | null; contextRevision: string };
}
export interface BodyRecord {
  state: CaptureState;
  reason: string | null;
  observedBytes: number | null;
  retainedBytes: number;
  chunks: Uint8Array[];
  tailUsed: number;
}
export interface Attempt extends CallContext {
  readonly attemptId: string;
  readonly ordinal: number;
  wallTime: string;
  captureMode: 'memory' | 'off' | 'persist';
  rawEvents: RawEventRange[];
  rawEventsDropped: number;
  method: string;
  redactedUrl: string;
  requestHeaders: Record<string, string>;
  responseHeaders: Record<string, string>;
  status: number | null;
  outcome: 'in-flight' | 'completed' | 'failed' | 'cancelled' | 'interrupted';
  modelOutcome: 'unavailable' | 'completed' | 'failed' | 'cancelled';
  transportActive: boolean;
  errorKind: string | null;
  request: BodyRecord;
  response: BodyRecord;
  timings: {
    dispatch: number;
    headers: number | null;
    firstByte: number | null;
    firstContent: number | null;
    firstText: number | null;
    modelComplete: number | null;
    eof: number | null;
    cancelled: number | null;
  };
  reportedModel: string | null;
  usage: { input: number | null; output: number | null; cacheRead: number | null; cacheWrite: number | null };
  eventCount: number;
  unknownEventCount: number;
  observerErrors: number;
}
export interface CaptureLimits { totalBytes: number; bodyBytes: number; attempts: number }
export const DEFAULT_LIMITS: Readonly<CaptureLimits> = Object.freeze({
  totalBytes: 128 * 1024 * 1024, bodyBytes: 32 * 1024 * 1024, attempts: 2_000,
});

// Headers are deliberately derived metadata. Unknown values are secret by default.
const PUBLIC_HEADERS = new Set(['content-type', 'content-length', 'content-encoding',
  'accept', 'anthropic-version', 'request-id', 'x-request-id', 'retry-after']);
export function redactHeaders(headers: Headers, permitted: readonly string[] = []): Record<string, string> {
  const additional = new Set(permitted.map(name => name.toLowerCase()));
  return Object.fromEntries([...headers].map(([name, value]) => [name,
    /authorization|cookie|token|secret|key|credential|proxy/i.test(name) ? '[REDACTED]' :
      PUBLIC_HEADERS.has(name) || additional.has(name) ? value : '[REDACTED]']));
}
export function redactUrl(value: string): string {
  try {
    const url = new URL(value);
    if (url.username) url.username = 'REDACTED';
    if (url.password) url.password = 'REDACTED';
    // No query-value allowlist in v1: even novel credential parameters stay private.
    for (const key of new Set(url.searchParams.keys())) url.searchParams.set(key, '[REDACTED]');
    url.hash = '';
    return url.href;
  } catch { return '[Invalid URL redacted]'; }
}

export class CaptureStore {
  readonly attempts: Attempt[] = [];
  retainedBytes = 0;
  allocatedBytes = 0;
  droppedMetadata = 0;
  mode: 'memory' | 'off' = 'memory';
  private sessionModes = new Map<string, 'memory' | 'off' | 'persist'>();
  private indexedEvents = 0;
  modeFor(id: string): 'memory' | 'off' | 'persist' { return this.sessionModes.get(id) ?? this.mode; }
  setMode(id: string, mode: 'memory' | 'off' | 'persist'): void { this.sessionModes.set(id, mode); }
  forget(id: string): void {
    this.sessionModes.delete(id);
    for (let i = this.attempts.length - 1; i >= 0; i--) {
      const a = this.attempts[i]!; if (a.sessionId !== id) continue;
      this.evict(a.request); this.evict(a.response); this.indexedEvents -= a.rawEvents.length; a.rawEvents = [];
      a.transportActive = false; this.attempts.splice(i, 1);
    }
  }
  index(attempt: Attempt, event: RawEventRange): void {
    if (attempt.rawEvents.length >= 1024 || this.indexedEvents >= 16384) { attempt.rawEventsDropped++; return; }
    attempt.rawEvents.push(event); this.indexedEvents++;
  }
  readonly limits: CaptureLimits;

  constructor(limits: Partial<CaptureLimits> = {}) {
    this.limits = { ...DEFAULT_LIMITS, ...limits };
    if (Object.values(this.limits).some(value => !Number.isSafeInteger(value) || value < 0)) {
      throw new Error('Capture limits must be nonnegative safe integers');
    }
  }

  begin(context: CallContext, ordinal: number, now: number): Attempt {
    while (this.attempts.length >= this.limits.attempts) {
      const index = this.attempts.findIndex(attempt => !attempt.transportActive);
      if (index < 0) { this.droppedMetadata++; throw new Error('Active attempt metadata limit'); }
      const [old] = this.attempts.splice(index, 1);
      if (old) this.indexedEvents -= old.rawEvents.length;
      if (old) for (const body of [old.request, old.response]) this.evict(body);
      this.droppedMetadata++;
    }
    const newBody = (): BodyRecord => ({ state: this.modeFor(context.sessionId) === 'off' ? 'disabled' : 'recording',
      reason: this.modeFor(context.sessionId) === 'off' ? 'capture-off-at-dispatch' : null, observedBytes: 0, retainedBytes: 0, chunks: [], tailUsed: 0 });
    const attempt: Attempt = {
      ...context, attemptId: randomUUID(), ordinal, captureMode: this.modeFor(context.sessionId), wallTime: new Date().toISOString(), rawEvents: [], rawEventsDropped: 0, method: '', redactedUrl: '',
      requestHeaders: {}, responseHeaders: {}, status: null, outcome: 'in-flight', modelOutcome: 'unavailable', transportActive: true, errorKind: null,
      request: newBody(), response: newBody(), reportedModel: null,
      timings: { dispatch: now, headers: null, firstByte: null, firstContent: null,
        firstText: null, modelComplete: null, eof: null, cancelled: null },
      usage: { input: null, output: null, cacheRead: null, cacheWrite: null },
      eventCount: 0, unknownEventCount: 0, observerErrors: 0,
    };
    this.attempts.push(attempt);
    return attempt;
  }

  private evict(body: BodyRecord): void {
    if (body.retainedBytes === 0) return;
    this.retainedBytes -= body.retainedBytes;
    this.allocatedBytes -= body.chunks.reduce((total, block) => total + block.byteLength, 0);
    body.chunks = []; body.retainedBytes = 0; body.tailUsed = 0;
    body.state = 'evicted'; body.reason = 'workspace-memory-budget';
  }

  private available(body: BodyRecord, length: number): number {
    if (body.state !== 'recording') return 0;
    const desired = Math.min(length, this.limits.bodyBytes - body.retainedBytes);
    const spare = (body.chunks.at(-1)?.byteLength ?? 0) - body.tailUsed;
    for (const attempt of this.attempts) {
      if (this.limits.totalBytes - this.allocatedBytes + spare >= desired) break;
      if (!attempt.transportActive) {
        this.evict(attempt.request); this.evict(attempt.response);
      }
    }
    return Math.max(0, Math.min(desired, this.limits.totalBytes - this.allocatedBytes + spare));
  }

  observe(body: BodyRecord, value: Uint8Array | string): void {
    const length = typeof value === 'string' ? Buffer.byteLength(value) : value.byteLength;
    body.observedBytes = (body.observedBytes ?? 0) + length;
    if (body.state !== 'recording') return;
    const available = this.available(body, length);
    let remaining = available;
    const append = (bytes: Uint8Array): void => {
      let offset = 0;
      while (offset < bytes.length && remaining > 0) {
        let block = body.chunks.at(-1);
        if (!block || body.tailUsed === block.length) {
          const capacity = Math.min(16 * 1024, this.limits.bodyBytes - body.retainedBytes,
            this.limits.totalBytes - this.allocatedBytes);
          if (capacity <= 0) break;
          block = new Uint8Array(capacity); this.allocatedBytes += capacity;
          body.chunks.push(block); body.tailUsed = 0;
        }
        const count = Math.min(bytes.length - offset, block.length - body.tailUsed, remaining);
        block.set(bytes.subarray(offset, offset + count), body.tailUsed);
        body.tailUsed += count; body.retainedBytes += count; this.retainedBytes += count;
        offset += count; remaining -= count;
      }
    };
    if (typeof value === 'string') {
      // Bounded temporary encoding, including code points straddling our input slices.
      for (let start = 0; start < value.length && remaining > 0;) {
        let end = Math.min(start + 4096, value.length);
        const last = value.charCodeAt(end - 1);
        if (end < value.length && last >= 0xd800 && last <= 0xdbff) end--;
        append(new TextEncoder().encode(value.slice(start, end))); start = end;
      }
    } else { append(value); }
    if (body.retainedBytes < body.observedBytes) {
      body.state = 'prefix-only';
      body.reason = body.retainedBytes >= this.limits.bodyBytes ? 'individual-body-budget' : 'workspace-memory-budget';
    }
  }

  finish(body: BodyRecord, complete: boolean, reason = 'consumer-stopped-before-eof'): void {
    if (body.state === 'recording') {
      body.state = complete ? 'complete' : 'prefix-only';
      body.reason = complete ? null : reason;
    }
  }

  read(body: BodyRecord, offset = 0, limit = 64 * 1024): Uint8Array {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 0 || limit > 1024 * 1024) {
      throw new Error('Invalid bounded capture range');
    }
    const output = new Uint8Array(Math.max(0, Math.min(limit, body.retainedBytes - offset)));
    let position = 0, copied = 0;
    for (const chunk of this.usedChunks(body)) {
      if (position + chunk.length > offset && copied < output.length) {
        const start = Math.max(0, offset - position);
        const take = Math.min(chunk.length - start, output.length - copied);
        output.set(chunk.subarray(start, start + take), copied); copied += take;
      }
      position += chunk.length;
      if (copied === output.length) break;
    }
    return output;
  }

  hash(body: BodyRecord): { sha256: string; scope: 'full' | 'retained-prefix' } {
    const hash = createHash('sha256');
    for (const chunk of this.usedChunks(body)) hash.update(chunk);
    return { sha256: hash.digest('hex'), scope: body.state === 'complete' ? 'full' : 'retained-prefix' };
  }

  private *usedChunks(body: BodyRecord): Iterable<Uint8Array> {
    for (let i = 0; i < body.chunks.length; i++) {
      const block = body.chunks[i]!;
      yield i === body.chunks.length - 1 ? block.subarray(0, body.tailUsed) : block;
    }
  }

  clear(sessionId?: string): void {
    for (const attempt of this.attempts.filter(a => sessionId === undefined || a.sessionId === sessionId)) { this.indexedEvents -= attempt.rawEvents.length; attempt.rawEvents = []; }
    for (const attempt of this.attempts.filter(attempt => sessionId === undefined || attempt.sessionId === sessionId)) for (const body of [attempt.request, attempt.response]) {
      this.evict(body); body.state = 'unavailable'; body.reason = 'cleared';
    }
  }
}
