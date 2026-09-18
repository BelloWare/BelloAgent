import { createHash } from 'node:crypto';

export class CommandError extends Error {
  constructor(readonly code: string, message: string) { super(message); }
}
export interface CommandResult { accepted: boolean; sessionId?: string; turnId?: string; queued?: boolean }

// Keep every mutating command receipt for this epoch. At capacity, reject new
// mutations before dispatch instead of evicting an ID that could be replayed.
// Read-only queries and idempotent Stop do not occupy this ledger.
export class CommandLedger {
  private receipts = new Map<string, { fingerprint: string; result: Promise<CommandResult> }>();
  constructor(readonly capacity = 4096) {}
  perform(id: string, canonicalIntent: unknown, execute: () => Promise<CommandResult>): Promise<CommandResult> {
    if (!/^[A-Za-z0-9._:-]{1,128}$/.test(id)) return Promise.reject(new CommandError('invalid_command_id', 'Invalid command ID'));
    const fingerprint = createHash('sha256').update(JSON.stringify(canonicalIntent)).digest('hex');
    const previous = this.receipts.get(id);
    if (previous) {
      if (previous.fingerprint !== fingerprint) return Promise.reject(new CommandError('command_conflict', 'Command ID was reused for a different action'));
      return previous.result;
    }
    if (this.receipts.size >= this.capacity) return Promise.reject(new CommandError('epoch_capacity', 'Restart the idle workspace host before submitting more commands'));
    // A microtask defers execution until the receipt has been installed.
    const result = Promise.resolve().then(execute);
    this.receipts.set(id, { fingerprint, result });
    return result;
  }
  get size(): number { return this.receipts.size; }
}
