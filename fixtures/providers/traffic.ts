import type { ApiKind } from '../../packages/host/src/observability/capture-store.ts';

// Deliberately synthetic, fixed provider wire events. Do not derive these from Pi events.
export function event(type: string, fields: Record<string, unknown> = {}): string {
  return `event: ${type}\r\ndata: ${JSON.stringify({ type, ...fields })}\r\n\r\n`;
}
export interface TrafficOptions {
  text?: string;
  tool?: boolean;
  toolName?: string;
  toolInput?: Record<string, unknown>;
  thinking?: boolean;
  inputTokens?: number;
  unknown?: boolean;
  error?: boolean;
}
export function traffic(api: ApiKind, options: TrafficOptions = {}): Buffer {
  return Buffer.from((api === 'openai-responses' ? responses(options) : messages(options)).join(''));
}
export function responses(options: TrafficOptions = {}): string[] {
  const text = options.text ?? 'Hello 🌍 漢字';
  const usage = { input_tokens: options.inputTokens ?? 110, output_tokens: 7,
    input_tokens_details: { cached_tokens: 10 }, output_tokens_details: { reasoning_tokens: 3 } };
  const response = { id: 'resp_fixture', object: 'response', created_at: 1, status: 'in_progress', model: 'fixture-model', output: [] as object[] };
  const output: object[] = [];
  const result = [': fixture comment, UTF-8 🌍\r\n\r\n', event('response.created', { response })];
  if (options.unknown) result.push('event: response.future_fixture\r\ndata: { "type": "response.future_fixture", "unknown" : [1, "保留"] }\r\n\r\n');
  let index = 0;
  if (options.thinking) {
    const item = { type: 'reasoning', id: 'rs_fixture', summary: [{ type: 'summary_text', text: 'Synthetic thought.' }], encrypted_content: 'fixture-opaque-continuation' };
    result.push(event('response.output_item.added', { output_index: index, item: { ...item, summary: [] } }),
      event('response.reasoning_summary_text.delta', { item_id: item.id, output_index: index, summary_index: 0, delta: 'Synthetic thought.' }),
      event('response.output_item.done', { output_index: index, item }));
    output.push(item); index++;
  }
  if (options.error) {
    result.push(event('response.failed', { response: { ...response, status: 'failed', error: { code: 'fixture_failure', message: 'Synthetic stream failure' } } }));
    return result;
  }
  if (options.tool) {
    const item = { type: 'function_call', id: 'fc_fixture', call_id: 'call_fixture', name: options.toolName ?? 'fixture_echo', arguments: options.toolInput ? JSON.stringify(options.toolInput) : '{"text":"🌍"}', status: 'completed' };
    result.push(event('response.output_item.added', { output_index: index, item: { ...item, arguments: '', status: 'in_progress' } }));
    for (const delta of (options.toolInput ? [...JSON.stringify(options.toolInput)] : ['{"te', 'xt":"', '🌍', '"}'])) result.push(event('response.function_call_arguments.delta', { item_id: item.id, output_index: index, delta }));
    result.push(event('response.function_call_arguments.done', { item_id: item.id, output_index: index, arguments: item.arguments }),
      event('response.output_item.done', { output_index: index, item }));
    output.push(item);
  } else {
    const item = { type: 'message', id: 'msg_fixture', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text, annotations: [] }] };
    result.push(event('response.output_item.added', { output_index: index, item: { ...item, status: 'in_progress', content: [] } }));
    for (const delta of (text.length < 100 ? [...text] : text.match(/[\s\S]{1,128}/gu) ?? [])) result.push(event('response.output_text.delta', { item_id: item.id, output_index: index, content_index: 0, delta }));
    result.push(event('response.output_item.done', { output_index: index, item }));
    output.push(item);
  }
  result.push(event('response.completed', { response: { ...response, status: 'completed', output, usage } }), ': fixture EOF\r\n\r\n');
  return result;
}
export function messages(options: TrafficOptions = {}): string[] {
  const text = options.text ?? 'Hello 🌍 漢字';
  const result = [': fixture comment, UTF-8 🌍\r\n\r\n', event('message_start', { message: { id: 'msg_fixture', type: 'message', role: 'assistant',
    model: 'fixture-model', content: [], stop_reason: null, stop_sequence: null,
    usage: { input_tokens: options.inputTokens ?? 100, output_tokens: 1, cache_read_input_tokens: 10, cache_creation_input_tokens: 5 } } })];
  if (options.unknown) result.push('event: future_fixture\r\ndata: { "type": "future_fixture", "unknown" : [1, "保留"] }\r\n\r\n');
  let index = 0;
  if (options.thinking) {
    result.push(event('content_block_start', { index, content_block: { type: 'thinking', thinking: '', signature: '' } }),
      event('content_block_delta', { index, delta: { type: 'thinking_delta', thinking: 'Synthetic thought.' } }),
      event('content_block_delta', { index, delta: { type: 'signature_delta', signature: 'fixture-opaque-signature' } }),
      event('content_block_stop', { index }));
    index++;
  }
  if (options.error) {
    result.push(event('error', { error: { type: 'overloaded_error', message: 'Synthetic stream failure' } }));
    return result;
  }
  if (options.tool) {
    result.push(event('content_block_start', { index, content_block: { type: 'tool_use', id: 'toolu_fixture', name: options.toolName ?? 'fixture_echo', input: {} } }));
    for (const partial_json of (options.toolInput ? [...JSON.stringify(options.toolInput)] : ['{"te', 'xt":"', '🌍', '"}'])) result.push(event('content_block_delta', { index, delta: { type: 'input_json_delta', partial_json } }));
  } else {
    result.push(event('content_block_start', { index, content_block: { type: 'text', text: '' } }));
    for (const delta of (text.length < 100 ? [...text] : text.match(/[\s\S]{1,128}/gu) ?? [])) result.push(event('content_block_delta', { index, delta: { type: 'text_delta', text: delta } }));
  }
  result.push(event('content_block_stop', { index }),
    event('message_delta', { delta: { stop_reason: options.tool ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: { output_tokens: 7 } }),
    event('message_stop'), ': fixture EOF\r\n\r\n');
  return result;
}
