import type { Message } from './message-model.ts';

export function latestCompletedAssistant(messages: readonly Message[]): string | null {
  return messages.findLast(message => message.role === 'assistant' && message.state !== 'streaming' && !message.id.startsWith('stream:'))?.id ?? null;
}

/** Reaching the end of a long reply counts; merely seeing its first line does not. */
export function replyEndIsVisible(rect: { top: number; bottom: number; height: number }, viewportHeight: number): boolean {
  return [rect.top, rect.bottom, rect.height, viewportHeight].every(Number.isFinite) &&
    viewportHeight > 0 && rect.height > 0 && rect.top < viewportHeight && rect.bottom > 0 && rect.bottom <= viewportHeight + 1;
}
