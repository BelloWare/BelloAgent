import { createServer, type IncomingHttpHeaders, type Server } from 'node:http';
import { once } from 'node:events';
import { setTimeout } from 'node:timers/promises';

export interface ReceivedRequest { method: string; url: string; headers: IncomingHttpHeaders; bytes: Buffer }
export interface ResponsePlan {
  disconnectBeforeHeaders?: boolean;
  status?: number;
  headers?: Record<string, string>;
  chunks: Iterable<Uint8Array>;
  beforeChunk?: (index: number) => Promise<void>;
  delayMs?: number;
}
export class FixtureServer {
  requests: ReceivedRequest[] = [];
  emitted: Buffer[][] = [];
  errors: unknown[] = [];
  private server: Server;
  origin = '';
  constructor(handler: (request: ReceivedRequest, index: number) => ResponsePlan | Promise<ResponsePlan>) {
    this.server = createServer((req, res) => {
      void (async () => {
        const received: Buffer[] = [];
        for await (const chunk of req) received.push(Buffer.from(chunk));
        const record: ReceivedRequest = { method: req.method!, url: req.url!, headers: req.headers, bytes: Buffer.concat(received) };
        const index = this.requests.push(record) - 1;
        this.emitted[index] = [];
        const plan = await handler(record, index);
        if (plan.disconnectBeforeHeaders) { res.destroy(); return; }
        res.writeHead(plan.status ?? 200, { 'content-type': 'text/event-stream', ...plan.headers });
        res.flushHeaders();
        let chunkIndex = 0;
        for (const chunk of plan.chunks) {
          await plan.beforeChunk?.(chunkIndex++);
          if (plan.delayMs) await setTimeout(plan.delayMs);
          if (res.destroyed) break;
          this.emitted[index]!.push(Buffer.from(chunk));
          if (!res.write(chunk)) {
            await new Promise<void>(resolve => {
              const done = (): void => { res.off('drain', done); res.off('close', done); resolve(); };
              res.once('drain', done); res.once('close', done);
            });
          }
        }
        res.end();
      })().catch(error => { this.errors.push(error); res.destroy(); });
    });
  }
  async start(port = 0): Promise<this> {
    this.server.listen(port, '127.0.0.1'); await once(this.server, 'listening');
    const address = this.server.address();
    if (!address || typeof address === 'string') throw new Error('No loopback fixture address');
    this.origin = `http://127.0.0.1:${address.port}`;
    return this;
  }
  async close(): Promise<void> {
    this.server.closeAllConnections();
    await new Promise<void>((resolve, reject) => this.server.close(error => error ? reject(error) : resolve()));
  }
}
export function fragment(bytes: Uint8Array, sizes = [1, 2, 7, 3, 11]): Uint8Array[] {
  const result: Uint8Array[] = [];
  for (let offset = 0, i = 0; offset < bytes.length; i++) {
    const size = sizes[i % sizes.length]!;
    result.push(bytes.subarray(offset, Math.min(offset + size, bytes.length))); offset += size;
  }
  return result;
}
