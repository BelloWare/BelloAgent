export const PROTOCOL_MAJOR = 1;
export const MAX_FRAME_BYTES = 1024 * 1024;

export class FrameDecoder {
  private buffer = Buffer.alloc(MAX_FRAME_BYTES);
  private used = 0;
  private decoder = new TextDecoder('utf-8', { fatal: true });
  feed(bytes: Uint8Array, receive: (value: unknown) => void): void {
    let start = 0;
    for (let index = 0; index <= bytes.length; index++) {
      if (index !== bytes.length && bytes[index] !== 10) continue;
      const count = index - start;
      if (this.used + count > MAX_FRAME_BYTES) throw new Error('Protocol frame exceeds 1 MiB');
      this.buffer.set(bytes.subarray(start, index), this.used); this.used += count;
      if (index < bytes.length) {
        if (this.used === 0) throw new Error('Empty protocol frame');
        const text = this.decoder.decode(this.buffer.subarray(0, this.used)); this.used = 0;
        receive(JSON.parse(text) as unknown);
      }
      start = index + 1;
    }
  }
  end(): void { if (this.used !== 0) throw new Error('Truncated protocol frame'); }
}
export function encodeFrame(value: unknown): Buffer {
  const bytes = Buffer.from(JSON.stringify(value));
  if (bytes.length > MAX_FRAME_BYTES) throw new Error('Protocol frame exceeds 1 MiB');
  return Buffer.concat([bytes, Buffer.from('\n')]);
}
export function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
