import { randomUUID } from 'node:crypto';
import type { Api, AssistantMessageEventStream, Context, Model, ModelsApiStreamOptions, ModelsSimpleStreamOptions } from '@earendil-works/pi-ai';
import type { ModelRuntime } from '@earendil-works/pi-coding-agent';
import type { CallContext, CaptureStore } from '../observability/capture-store.ts';
import { recordingFetch } from '../observability/recording-fetch.ts';

type RequestScope = Omit<CallContext, 'requestId' | 'api' | 'requestedModel'>;

export function instrumentRuntime(runtime: ModelRuntime, store: CaptureStore, scope: () => RequestScope, headers?: Record<string, string>, publicHeaders?: readonly string[]): void {
  const originalStream = runtime.stream.bind(runtime);
  const originalSimple = runtime.streamSimple.bind(runtime);
  const drained = new WeakSet<AssistantMessageEventStream>();
  const instrument = <T>(
    model: Model<Api>, options: T | undefined,
  ): { options: T; call: CallContext; finish: () => Promise<void> } => {
    if (model.api !== 'openai-responses' && model.api !== 'anthropic-messages') throw new Error(`Unsupported API: ${model.api}`);
    const common = options as ModelsSimpleStreamOptions | undefined;
    if (common?.transport !== undefined && common.transport !== 'sse') throw new Error('Pi App v1 requires HTTP/SSE transport');
    const call: CallContext = Object.freeze({ ...scope(), requestId: randomUUID(),
      api: model.api === 'openai-responses' ? 'openai-responses' : 'anthropic-messages', requestedModel: model.id });
    const fetch = recordingFetch(store, call, { userSignal: common?.signal ?? null, ...(publicHeaders ? { publicHeaders } : {}), ...(common?.fetch ? { fetch: common.fetch } : {}) });
    return { call, finish: fetch.finish, options: { ...options, ...(headers ? { headers: { ...headers, ...common?.headers } } : {}), transport: 'sse', maxTokens: common?.maxTokens ?? model.maxTokens, fetch } as T };
  };
  const observeResult = (stream: AssistantMessageEventStream, call: CallContext, finish: () => Promise<void>): AssistantMessageEventStream => {
    // result() itself does not consume Pi events. This observer never replaces the raw body.
    void stream.result().then(message => {
      // Some provider error parsers stop without returning the body iterator. Release
      // our sole reader when Pi settles; unread bytes are explicitly unavailable.
      void finish();
      const attempt = store.attempts.findLast(item => item.requestId === call.requestId);
      if (!attempt) return;
      attempt.modelOutcome = message.stopReason === 'aborted' ? 'cancelled' : message.stopReason === 'error' ? 'failed' : 'completed';
      if (message.stopReason === 'aborted') attempt.outcome = 'cancelled';
      else if (message.stopReason === 'error') attempt.outcome = 'failed';
    }, () => { /* A rejected result is also observed by the Pi caller. */ });
    if (call.purpose === 'compaction') {
      // Pi 0.85.1 compaction awaits agent.streamFunction(...).result() without iteration.
      // Drain the unused normalized queue. Pi still owns generation and summarization.
      drained.add(stream);
      void (async () => { for await (const _event of stream) { /* no duplicate payload retention */ } })().catch(() => {
        const attempt = store.attempts.findLast(item => item.requestId === call.requestId);
        if (attempt) attempt.observerErrors++;
      });
    }
    return stream;
  };
  runtime.stream = function <TApi extends Api>(model: Model<TApi>, context: Context, options?: ModelsApiStreamOptions<TApi>) {
    const recorded = instrument(model, options);
    return observeResult(originalStream(model, context, recorded.options), recorded.call, recorded.finish);
  };
  runtime.streamSimple = (model, context, options) => {
    const recorded = instrument(model, options);
    return observeResult(originalSimple(model, context, recorded.options), recorded.call, recorded.finish);
  };
  // These methods do not allocate another call ID; their stream method remains the capture boundary.
  runtime.complete = async (model, context, options) => {
    const stream = runtime.stream(model, context, options);
    if (!drained.has(stream)) for await (const _event of stream) { /* drain unused events */ }
    return stream.result();
  };
  runtime.completeSimple = async (model, context, options) => {
    const stream = runtime.streamSimple(model, context, options);
    if (!drained.has(stream)) for await (const _event of stream) { /* drain unused events */ }
    return stream.result();
  };
}
