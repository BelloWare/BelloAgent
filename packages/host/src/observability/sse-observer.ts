import type { Attempt } from './capture-store.ts';

// Derived observations only. Pi is the parser/agent authority; original bytes live in CaptureStore.
// Do not retain JSON/event payload duplicates or unbounded text lines here.
export class SSEObserver {
  private decoder = new TextDecoder('utf-8', { fatal: true });
  private line = '';
  private data: string[] = [];
  private eventChars = 0;
  private discarding = false;
  private afterCR = false;
  private broken = false;

  constructor(private attempt: Attempt, private maxEventChars = 256 * 1024) {}

  observe(chunk: Uint8Array, now: number): void {
    if (this.broken) return;
    try {
      for (let index = 0; index < chunk.length; index += 4096) {
        const text = this.decoder.decode(chunk.subarray(index, index + 4096), { stream: true });
        for (const character of text) {
          if (this.afterCR && character === '\n') { this.afterCR = false; continue; }
          this.afterCR = character === '\r';
          if (character === '\n' || character === '\r') { this.endLine(now); }
          else if (!this.discarding) {
            if (++this.eventChars > this.maxEventChars) {
              this.discarding = true; this.line = 'discarded'; this.data = []; this.attempt.observerErrors++;
            } else { this.line += character; }
          } else { this.line = 'discarded'; }
        }
      }
    } catch { this.broken = true; this.attempt.observerErrors++; this.line = ''; this.data = []; }
  }

  finish(): void {
    try { this.decoder.decode(); } catch { this.attempt.observerErrors++; }
    if (this.line || this.data.length || this.discarding) this.attempt.observerErrors++;
    this.line = ''; this.data = [];
  }

  private endLine(now: number): void {
    const line = this.line; this.line = '';
    if (line === '') {
      if (!this.discarding && this.data.length) this.event(this.data.join('\n'), now);
      this.data = []; this.eventChars = 0; this.discarding = false;
    } else if (!this.discarding && line.startsWith('data:')) {
      this.data.push(line.slice(5).replace(/^ /, ''));
    }
  }

  private event(data: string, now: number): void {
    this.attempt.eventCount++;
    if (data === '[DONE]') return;
    let event: Record<string, any>;
    try { event = JSON.parse(data) as Record<string, any>; }
    catch { this.attempt.observerErrors++; return; }
    if (!event || typeof event !== 'object') { this.attempt.observerErrors++; return; }
    const attempt = this.attempt;
    let text = '', content = '', known = true;
    if (attempt.api === 'openai-responses') {
      switch (event.type) {
        case 'response.output_text.delta': text = typeof event.delta === 'string' ? event.delta : ''; content = text; break;
        case 'response.reasoning_summary_text.delta':
        case 'response.reasoning_text.delta':
        case 'response.function_call_arguments.delta': content = typeof event.delta === 'string' ? event.delta : ''; break;
        case 'response.completed':
        case 'response.failed':
        case 'response.incomplete': {
          attempt.timings.modelComplete ??= now;
          const usage = event.response?.usage;
          this.usage(usage?.input_tokens, usage?.output_tokens, usage?.input_tokens_details?.cached_tokens, undefined);
          if (typeof event.response?.model === 'string') attempt.reportedModel = event.response.model;
          if (event.type === 'response.failed') attempt.outcome = 'failed';
          break;
        }
        case 'error': attempt.outcome = 'failed'; break;
        default: known = typeof event.type === 'string' && /^response\.(created|in_progress|output_item\.|content_part\.|output_text.done|function_call_arguments.done|reasoning_)/.test(event.type);
      }
    } else {
      switch (event.type) {
        case 'content_block_delta':
          if (event.delta?.type === 'text_delta') text = typeof event.delta.text === 'string' ? event.delta.text : '';
          content = text || (event.delta?.type === 'thinking_delta' ? event.delta.thinking :
            event.delta?.type === 'input_json_delta' ? event.delta.partial_json : '') || '';
          break;
        case 'message_start':
          if (typeof event.message?.model === 'string') attempt.reportedModel = event.message.model;
          this.usage(event.message?.usage?.input_tokens, event.message?.usage?.output_tokens,
            event.message?.usage?.cache_read_input_tokens, event.message?.usage?.cache_creation_input_tokens);
          break;
        case 'message_delta':
          this.usage(event.usage?.input_tokens, event.usage?.output_tokens,
            event.usage?.cache_read_input_tokens, event.usage?.cache_creation_input_tokens);
          break;
        case 'message_stop': attempt.timings.modelComplete ??= now; break;
        case 'error': attempt.outcome = 'failed'; break;
        case 'ping': case 'content_block_start': case 'content_block_stop': break;
        default: known = false;
      }
    }
    if (!known) attempt.unknownEventCount++;
    if (typeof content === 'string' && content.length) attempt.timings.firstContent ??= now;
    if (text.length) attempt.timings.firstText ??= now;
  }

  private usage(input: unknown, output: unknown, cacheRead: unknown, cacheWrite: unknown): void {
    for (const [name, value] of Object.entries({ input, output, cacheRead, cacheWrite })) {
      if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
        this.attempt.usage[name as keyof Attempt['usage']] = value; // Cumulative snapshots, never increments.
      }
    }
  }
}
