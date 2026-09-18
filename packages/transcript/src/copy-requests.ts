import type { MarkdownCopySelection } from './markdown-copy.ts';

export interface CopyContentRequest extends MarkdownCopySelection { id: string; field: 'text' | 'thinking' }
export interface CopyReply { requestId: string; success: boolean }
interface Scheduler { later: (run: () => void, delay: number) => number; cancel: (timer: number) => void }

/** Acknowledgments are scoped to one pending native write; unavailable bridges time out. */
export function copyRequests(send: (fields: CopyContentRequest & { requestId: string }) => void, scheduler: Scheduler) {
  let serial = 0;
  const pending = new Map<string, { resolve: (success: boolean) => void; timer: number }>();
  const finish = (requestId: string, success: boolean): boolean => {
    const request = pending.get(requestId);
    if (!request) return false;
    scheduler.cancel(request.timer); pending.delete(requestId); request.resolve(success); return true;
  };
  return {
    request(fields: CopyContentRequest): Promise<boolean> {
      // Clicks cannot grow the bridge queue without bound while the native pane
      // is unavailable, reloading, or waiting for a busy main thread.
      if (pending.size >= 16) return Promise.resolve(false);
      const requestId = `copy-${++serial}`;
      return new Promise(resolve => {
        const timer = scheduler.later(() => finish(requestId, false), 3_000);
        pending.set(requestId, { resolve, timer });
        try { send({ ...fields, requestId }); } catch { finish(requestId, false); }
      });
    },
    reply(value: unknown): boolean {
      if (!value || typeof value !== 'object') return false;
      const reply = value as Partial<CopyReply>;
      return typeof reply.requestId === 'string' && typeof reply.success === 'boolean' && finish(reply.requestId, reply.success);
    },
  };
}
