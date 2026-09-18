import { CaptureStore, type Attempt, type BodyRecord } from './capture-store.ts';
import { CommandError } from '../sessions/command-ledger.ts';

function bodyMetadata(body: BodyRecord): unknown {
  return { state: body.state, reason: body.reason, observedBytes: body.observedBytes, retainedBytes: body.retainedBytes };
}
export function attemptMetrics(a: Attempt): unknown {
  const delta = (end: number | null): number | null => end === null ? null : Math.max(0, end - a.timings.dispatch);
  const end = a.timings.modelComplete ?? a.timings.eof;
  const duration = delta(end);
  const input = a.usage.input === null ? null : a.api === 'openai-responses' ? a.usage.input :
    a.usage.cacheRead === null || a.usage.cacheWrite === null ? null : a.usage.input + a.usage.cacheRead + a.usage.cacheWrite;
  return { observedTTFTms: delta(a.timings.firstContent), firstTextMs: delta(a.timings.firstText), streamDurationMs: duration,
    outputTokensPerSecond: a.usage.output === null || duration === null || duration <= 0 ? null : a.usage.output / (duration / 1000),
    inputIncludingCache: input, usageSource: 'provider-reported cumulative snapshot', rateSource: 'provider output tokens / attempt dispatch-to-completion; not decode speed',
    completeness: a.outcome === 'completed' && a.modelOutcome === 'completed' ? 'complete' : 'partial',
    liveTokenRate: null, liveTokenRateReason: 'No compatible tokenizer configured' };
}
export function attemptMetadata(a: Attempt): Record<string, unknown> {
  const { request, response, rawEvents, ...metadata } = a;
  return { ...metadata, rawEventIndexCount: rawEvents.length, request: bodyMetadata(request), response: bodyMetadata(response), metrics: attemptMetrics(a) };
}
const validOffset = (v: unknown, max = Number.MAX_SAFE_INTEGER): number => {
  if (v === undefined) return 0;
  if (!Number.isSafeInteger(v) || (v as number) < 0 || (v as number) > max) throw new CommandError('invalid_range', 'Invalid inspector byte or event range');
  return v as number;
};
export const TRANSPORT_BOUNDARY = 'Application fetch boundary, after serialization and HTTP decoding; not TCP/TLS. Gateway upstream traffic is unavailable. Authentication and unknown headers and URL query values are redacted. Body bytes remain sensitive.';
export class Inspector {
  constructor(private capture: CaptureStore) {}
  command(method: string, sessionId: string, p: Record<string, unknown>): unknown {
    if (method === 'debug.list') {
      const attempts = this.capture.attempts.filter(a => a.sessionId === sessionId), offset = validOffset(p.offset);
      const page = attempts.slice().reverse().slice(offset, offset + 64);
      return { attempts: page.map(attemptMetadata), total: attempts.length, next: offset + page.length < attempts.length ? offset + page.length : null,
        mode: this.capture.modeFor(sessionId), limits: this.capture.limits, workspaceRetainedBytes: this.capture.retainedBytes,
        droppedMetadata: this.capture.droppedMetadata, boundary: TRANSPORT_BOUNDARY };
    }
    if (method === 'debug.mode') {
      if (!['off', 'memory', 'persist'].includes(p.mode as string)) throw new CommandError('invalid_mode', 'Choose Off, Session memory, or Persist locally');
      this.capture.setMode(sessionId, p.mode as 'off' | 'memory' | 'persist');
      return { mode: this.capture.modeFor(sessionId), appliesTo: 'future attempt bodies; Clear is separate' };
    }
    if (method === 'debug.clear') { this.capture.clear(sessionId); return { cleared: true }; }
    const a = this.capture.attempts.find(a => a.sessionId === sessionId && a.attemptId === p.attemptId);
    if (!a) throw new CommandError('capture_unavailable', 'This session has no retained attempt with that identity');
    if (method === 'debug.attempt') return { ...attemptMetadata(a), boundary: TRANSPORT_BOUNDARY,
      requestHash: this.capture.hash(a.request), responseHash: this.capture.hash(a.response) };
    if (method === 'debug.raw-events') {
      const offset = validOffset(p.offset);
      return { source: 'raw response byte ranges; timestamps observed at the transport boundary', events: a.rawEvents.slice(offset, offset + 128), total: a.rawEvents.length, omitted: a.rawEventsDropped,
        response: bodyMetadata(a.response) };
    }
    if (method === 'debug.body') {
      if (p.body !== 'request' && p.body !== 'response') throw new CommandError('invalid_body', 'Choose request or response');
      const body = a[p.body], offset = validOffset(p.offset), bytes = this.capture.read(body, offset, 32 * 1024);
      return { ...bodyMetadata(body) as object, offset, bytes: Buffer.from(bytes).toString('base64'), next: offset + bytes.length < body.retainedBytes ? offset + bytes.length : null,
        view: 'exact retained bytes; UTF-8 decoding and pretty JSON are derived views' };
    }
    throw new CommandError('unsupported_debug_command', 'Unsupported inspector operation');
  }
}
