export interface SessionEvent { seq: number; type: string; payload: unknown }
export class EventJournal {
  private events: { event: SessionEvent; bytes: number }[] = [];
  private bytes = 0;
  private sequence = 0;
  constructor(private limit = { entries: 256, bytes: 1024 * 1024 }) {}
  append(type: string, payload: unknown): SessionEvent {
    const event = { seq: ++this.sequence, type, payload };
    const bytes = Buffer.byteLength(JSON.stringify(event));
    if (bytes > this.limit.bytes) { this.events = []; this.bytes = 0; return { seq: event.seq, type: 'resyncRequired', payload: { reason: 'oversized-presentation-event' } }; }
    event.payload = structuredClone(payload);
    this.events.push({ event, bytes }); this.bytes += bytes;
    while (this.events.length > this.limit.entries || this.bytes > this.limit.bytes) this.bytes -= this.events.shift()!.bytes;
    return event;
  }
  since(sequence: number): { resyncRequired: boolean; events: SessionEvent[]; seq: number } {
    if (!Number.isSafeInteger(sequence) || sequence < 0 || sequence > this.sequence) return { resyncRequired: true, events: [], seq: this.sequence };
    const first = this.events[0]?.event.seq ?? this.sequence + 1;
    return sequence < first - 1 ? { resyncRequired: true, events: [], seq: this.sequence } :
      { resyncRequired: false, events: this.events.filter(item => item.event.seq > sequence).map(item => item.event), seq: this.sequence };
  }
  recent(): unknown { return { events: this.events.map(e => e.event), seq: this.sequence, firstRetained: this.events[0]?.event.seq ?? null, source: "Pi-normalized previews; not raw HTTP" }; }
  get seq(): number { return this.sequence; }
  get retainedBytes(): number { return this.bytes; }
}
