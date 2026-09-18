// This is a lossy display projection. It must never be used as model input.
export interface ToolView { id: string; name: string; state: string; input: string; output: string; durationMs: number | null; truncated: boolean }
export interface MessageView { id: string; role: string; text: string; thinking: string; tools: ToolView[]; state: string; truncated: boolean }
export function preview(text: string, bytes = 16_384): { text: string; truncated: boolean } {
  if (text.length <= bytes / 4 || (text.length <= bytes && Buffer.byteLength(text) <= bytes)) return { text, truncated: false };
  let end = Math.min(text.length, bytes);
  while (end > 0 && Buffer.byteLength(text.slice(0, end)) > bytes) end = Math.floor(end * 0.9);
  if (end && /[\uD800-\uDBFF]/.test(text[end - 1]!)) end--;
  return { text: text.slice(0, end), truncated: true };
}
function object(value: unknown): Record<string, any> { return value !== null && typeof value === 'object' ? value as Record<string, any> : {}; }
export function messageView(id: string, value: unknown, toolStates: ReadonlyMap<string, ToolView> = new Map()): MessageView {
  const message = object(value), content = message.content;
  let text = typeof content === 'string' ? content : typeof message.summary === 'string' ? message.summary : '';
  let thinking = ''; const tools: ToolView[] = [];
  if (Array.isArray(content)) for (const item of content) {
    const block = object(item);
    if (block.type === 'text' && typeof block.text === 'string') text += block.text;
    if (block.type === 'thinking' && typeof block.thinking === 'string') thinking += block.thinking;
    if (block.type === 'toolCall' && typeof block.id === 'string') {
      const input = preview(JSON.stringify(block.arguments ?? {}), 4096);
      tools.push(toolStates.get(block.id) ?? { id: block.id, name: String(block.name).slice(0, 128), input: input.text,
        output: '', state: message.stopReason ? 'prepared' : 'preparing', durationMs: null, truncated: input.truncated });
    }
    if (block.type === 'image') text += '\n[Image attachment]';
  }
  const body = preview(text), reason = preview(thinking, 8192);
  return { id, role: message.role === 'toolResult' ? 'tool' : ['user', 'assistant'].includes(message.role) ? message.role : 'system',
    text: body.text, thinking: reason.text, tools: tools.slice(0, 32), state: message.stopReason ?? 'complete',
    truncated: body.truncated || reason.truncated || tools.length > 32 };
}
