export interface RawEventRange { start: number; end: number; observedAt: number; event: string }
// Byte offsets into the one captured response, including original CR/LF separators.
// This parser never retains payloads. Even malformed/unknown SSE is indexed.
export class RawEventIndexer {
  private offset = 0;
  private start = 0;
  private lineBytes = 0;
  private header: number[] = [];
  private name = 'message';
  private cr = false;
  private lastTime = 0;
  constructor(private append: (event: RawEventRange) => void) {}
  observe(bytes: Uint8Array, now: number): void {
    this.lastTime = now;
    for (const byte of bytes) {
      if (this.cr) {
        this.cr = false;
        if (byte === 10) { this.offset++; this.endLine(now); continue; }
        this.endLine(now);
      }
      this.offset++;
      if (byte === 13) this.cr = true;
      else if (byte === 10) this.endLine(now);
      else { this.lineBytes++; if (this.header.length < 256) this.header.push(byte); }
    }
  }
  finish(): void { if (this.cr) { this.cr = false; this.endLine(this.lastTime); } }
  private endLine(now: number): void {
    if (this.lineBytes === 0) {
      if (this.offset > this.start) this.append({ start: this.start, end: this.offset, observedAt: now, event: this.name });
      this.start = this.offset; this.name = 'message';
    } else {
      const header = Buffer.from(this.header).toString('utf8');
      if (header.startsWith('event:')) this.name = header.slice(6).replace(/^ /, '').slice(0, 128);
    }
    this.header = []; this.lineBytes = 0;
  }
}
