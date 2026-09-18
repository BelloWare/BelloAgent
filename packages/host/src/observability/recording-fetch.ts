import { performance } from 'node:perf_hooks';
import { CaptureStore, redactHeaders, redactUrl, type Attempt, type CallContext, type BodyRecord } from './capture-store.ts';
import { RawEventIndexer } from './raw-event-index.ts';
import { SSEObserver } from './sse-observer.ts';

export interface FetchRecorderOptions {
  fetch?: typeof globalThis.fetch;
  now?: () => number;
  publicHeaders?: readonly string[];
  // Distinguish an explicit user cancellation from the provider SDK aborting its own reader.
  userSignal?: AbortSignal | null;
}

export type RecordedFetch = typeof globalThis.fetch & { finish: () => Promise<void> };
export function recordingFetch(store: CaptureStore, context: CallContext, options: FetchRecorderOptions = {}): RecordedFetch {
  const transport = options.fetch ?? globalThis.fetch;
  const now = options.now ?? (() => performance.now());
  const call = Object.freeze({ ...context });
  let ordinal = 0;
  const active = new Set<() => Promise<void>>();
  const fetch: typeof globalThis.fetch = async (input, init) => {
    let attempt: Attempt | undefined;
    try { attempt = store.begin(call, ++ordinal, now()); } catch { /* Visible store.droppedMetadata; traffic continues. */ }
    const safe = (action: (record: Attempt) => void, body?: BodyRecord): void => {
      if (!attempt) return;
      try { action(attempt); }
      catch {
        attempt.observerErrors++;
        if (body) { body.state = 'capture-error'; body.reason = 'recorder-failure'; }
      }
    };
    const request = input instanceof Request ? input : null;
    const signal = init?.signal === undefined ? request?.signal : init.signal;
    const userSignal = options.userSignal === undefined ? signal : options.userSignal;
    safe(record => {
      record.method = (init?.method ?? request?.method ?? 'GET').toUpperCase();
      record.redactedUrl = redactUrl(request?.url ?? String(input));
      record.requestHeaders = redactHeaders(new Headers(init?.headers ?? request?.headers), options.publicHeaders);
      const body = init?.body;
      if (typeof body === 'string' || body instanceof Uint8Array) store.observe(record.request, body);
      else if (body instanceof ArrayBuffer) store.observe(record.request, new Uint8Array(body));
      else if (body != null || request?.body != null) {
        record.request.state = 'unavailable'; record.request.reason = 'unsupported-body-form';
        record.request.observedBytes = null;
      }
      store.finish(record.request, true);
    }, attempt?.request);
    let cancelUpstream: (() => Promise<void>) | undefined;
    const onAbort = (): void => {
      safe(record => {
        if (userSignal?.aborted) { record.timings.cancelled ??= now(); record.outcome = 'cancelled'; }
        else if (record.outcome === 'in-flight') record.outcome = 'interrupted';
        if (record.status !== null) {
          record.transportActive = false;
          store.finish(record.response, false, userSignal?.aborted ? 'abort' : 'sdk-transport-abort');
        }
      });
      void cancelUpstream?.().catch(() => { /* The SDK receives its own transport failure. */ });
    };
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) onAbort();
    const cleanup = (): void => signal?.removeEventListener('abort', onAbort);
    try {
      // Explicit v1 policy: no invisible redirect hop or forwarded credentials.
      const original = await transport(input, { ...init, redirect: 'error' });
      safe(record => {
        record.status = original.status; record.timings.headers = now();
        record.responseHeaders = redactHeaders(original.headers, options.publicHeaders);
        if (!original.ok) record.outcome = 'failed';
      });
      if (!original.body) {
        safe(record => { store.finish(record.response, true); record.timings.eof = now();
          record.transportActive = false;
          if (record.outcome === 'in-flight') record.outcome = 'completed'; });
        cleanup(); return original;
      }
      const reader = original.body.getReader();
      const observer = attempt && original.headers.get('content-type')?.includes('text/event-stream') ? new SSEObserver(attempt) : null;
      const rawIndex = observer && attempt ? new RawEventIndexer(event => store.index(attempt!, event)) : null;
      let released = false;
      const release = (): void => { if (!released) { released = true; reader.releaseLock(); cleanup(); if (cancelUpstream) active.delete(cancelUpstream); } };
      cancelUpstream = async () => {
        safe(record => { record.transportActive = false; store.finish(record.response, false, 'sdk-consumer-stopped');
          if (record.outcome === 'in-flight') record.outcome = 'interrupted'; });
        try { await reader.cancel(signal?.reason); } finally { release(); }
      };
      active.add(cancelUpstream);
      const body = new ReadableStream<Uint8Array>({
        async pull(controller) {
          try {
            const next = await reader.read();
            if (next.done) {
              safe(record => { observer?.finish(); rawIndex?.finish(); store.finish(record.response, true);
                record.transportActive = false;
                record.timings.eof = now(); if (record.outcome === 'in-flight') record.outcome = 'completed'; });
              controller.close(); release();
            } else {
              const timestamp = now();
              safe(record => {
                record.timings.firstByte ??= timestamp;
                store.observe(record.response, next.value); observer?.observe(next.value, timestamp); rawIndex?.observe(next.value, timestamp);
              }, attempt?.response);
              controller.enqueue(next.value); // Identical original bytes; one pull, one upstream read.
            }
          } catch (error) {
            safe(record => { record.outcome = userSignal?.aborted ? 'cancelled' : 'failed'; record.transportActive = false;
              record.errorKind = userSignal?.aborted ? 'abort' : 'stream-error';
              store.finish(record.response, false, record.errorKind); });
            controller.error(error); release();
          }
        },
        async cancel(reason) {
          safe(record => { store.finish(record.response, false); record.transportActive = false;
            if (record.outcome === 'in-flight') record.outcome = userSignal?.aborted ? 'cancelled' : record.timings.modelComplete != null ? 'completed' : 'interrupted'; });
          try { await reader.cancel(reason); } finally { release(); }
        },
      }, { highWaterMark: 0 });
      const response = new Response(body, { status: original.status, statusText: original.statusText, headers: original.headers });
      // Response construction otherwise loses these transport properties. SDK access patterns are fixture-tested.
      Object.defineProperties(response, {
        url: { value: original.url }, redirected: { value: original.redirected }, type: { value: original.type },
      });
      return response;
    } catch (error) {
      safe(record => {
        record.outcome = userSignal?.aborted ? 'cancelled' : 'failed'; record.transportActive = false;
        record.errorKind = userSignal?.aborted ? 'abort' : 'transport-error';
        record.response.state = 'unavailable'; record.response.reason = 'no-response';
      });
      cleanup(); throw error;
    }
  };
  return Object.assign(fetch, { finish: async () => { await Promise.allSettled([...active].map(close => close())); } });
}
