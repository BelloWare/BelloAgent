import { encodeFrame } from '../../../protocol/src/framing.ts';

// Control replies are bounded and never silently dropped. Display notifications
// are replaceable: a stalled client needs one current snapshot, not every delta.
export class OutputQueue {
  private controls: Buffer[] = [];
  private displays = new Map<string, Buffer>();
  private bytes = 0;
  private pumping: Promise<void> | undefined;
  private failure: unknown;
  constructor(private write: (bytes: Buffer) => Promise<void>, private fail: () => void, private limit = 2_097_152) {}
  send(value: unknown, displayKey?: string): void {
    if (this.failure) return;
    const bytes = encodeFrame(value);
    if (displayKey !== undefined) {
      if (this.displays.size >= 32 && !this.displays.has(displayKey)) { this.fail(); return; }
      this.displays.set(displayKey, bytes);
    } else {
      if (this.bytes + bytes.length > this.limit) { this.failure = new Error('Control queue full'); this.fail(); return; }
      this.controls.push(bytes); this.bytes += bytes.length;
    }
    this.pump();
  }
  private pump(): void {
    if (this.pumping || this.failure) return;
    this.pumping = Promise.resolve().then(async () => {
      while (this.controls.length || this.displays.size) {
        let next = this.controls.shift();
        if (next) this.bytes -= next.length;
        else { const key = this.displays.keys().next().value!; next = this.displays.get(key)!; this.displays.delete(key); }
        await this.write(next);
      }
    }).catch(error => { this.failure = error; this.fail(); }).finally(() => {
      this.pumping = undefined;
      if (this.controls.length || this.displays.size) this.pump();
    });
  }
  async drain(): Promise<void> { while (this.pumping) await this.pumping; }
  get pendingBytes(): number { return this.bytes + [...this.displays.values()].reduce((n, bytes) => n + bytes.length, 0); }
}
