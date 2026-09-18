import test from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate } from 'node:timers/promises';
import { CommandLedger } from '../src/sessions/command-ledger.ts';
import { EventJournal } from '../src/sessions/event-journal.ts';
import { SessionLane, type SessionPort, type Submission, type TurnOutcome } from '../src/sessions/session-lane.ts';
import { WorkspaceScheduler } from '../src/sessions/workspace-scheduler.ts';

const turn = (id: string, text = id): Submission => ({ turnId: id, commandId: `command-${id}`, text });
async function settle(): Promise<void> { await setImmediate(); await setImmediate(); }
class Port implements SessionPort {
  calls: { text: string; turnId: string }[] = [];
  records: { commandId: string; turnId: string; state: string }[] = [];
  steers: string[] = [];
  aborted = 0;
  compacted = 0;
  gate: ReturnType<typeof Promise.withResolvers<TurnOutcome>> | undefined;
  async submit(text: string, turnId: string): Promise<TurnOutcome> { this.calls.push({ text, turnId }); return this.gate ? this.gate.promise : 'completed'; }
  async steer(text: string): Promise<void> { this.steers.push(text); }
  async abort(): Promise<void> { this.aborted++; this.gate?.resolve('cancelled'); }
  async compact(): Promise<void> { this.compacted++; }
  recordCommand(commandId: string, turnId: string, state: string): void { this.records.push({ commandId, turnId, state }); }
}

test('lost acknowledgments and duplicate command IDs do not execute a mutation twice', async () => {
  const ledger = new CommandLedger(2); let calls = 0;
  const gate = Promise.withResolvers<void>();
  const execute = async () => { calls++; await gate.promise; return { accepted: true, turnId: 'turn-1' }; };
  const first = ledger.perform('cmd-1', ['submit', 'hello'], execute);
  const retry = ledger.perform('cmd-1', ['submit', 'hello'], execute);
  assert.equal(first, retry); gate.resolve();
  assert.deepEqual(await retry, { accepted: true, turnId: 'turn-1' }); assert.equal(calls, 1);
  await assert.rejects(ledger.perform('cmd-1', ['submit', 'different'], execute), /reused/);
  await ledger.perform('cmd-2', ['rename'], async () => ({ accepted: true }));
  await assert.rejects(ledger.perform('cmd-3', ['submit'], execute), /Restart/);
  assert.equal(await ledger.perform('cmd-1', ['submit', 'hello'], execute), await first);
  assert.equal(calls, 1);
});

test('ordinary Send queues; Stop pauses follow-ups until explicit resume', async () => {
  const port = new Port(); port.gate = Promise.withResolvers<TurnOutcome>();
  const lane = new SessionLane('main', 'editing', port, new WorkspaceScheduler(), () => {});
  lane.submit(turn('one')); await settle();
  assert.equal(lane.state, 'running');
  assert.equal(lane.submit(turn('two')).queued, true);
  await lane.steer('Explicit steer'); assert.deepEqual(port.steers, ['Explicit steer']);
  await lane.stop(); await settle();
  assert.equal(port.calls.length, 1); assert.equal(lane.state, 'paused'); assert.equal(lane.pending[0]?.turnId, 'two');
  port.gate = undefined; lane.resumeQueue(); await settle();
  assert.deepEqual(port.calls.map(c => c.turnId), ['one', 'two']); assert.equal(lane.state, 'idle');
  assert.deepEqual(port.records.map(r => r.state), ['dispatched', 'cancelled', 'dispatched', 'completed']);
});

test('workspace scheduling serializes writers but allows an independent read-only run', async () => {
  const scheduler = new WorkspaceScheduler();
  const first = new Port(); first.gate = Promise.withResolvers<TurnOutcome>();
  const second = new Port(), side = new Port();
  const main = new SessionLane('one', 'editing', first, scheduler, () => {});
  const other = new SessionLane('two', 'editing', second, scheduler, () => {});
  const detour = new SessionLane('side', 'read-only', side, scheduler, () => {});
  main.submit(turn('main')); other.submit(turn('other')); detour.submit(turn('side')); await settle();
  assert.equal(first.calls.length, 1); assert.equal(second.calls.length, 0); assert.equal(side.calls.length, 1);
  await main.stop(); await settle();
  assert.equal(second.calls.length, 1); assert.equal(side.aborted, 0);
});

test('steering stays bounded and command receipts follow the owning turn outcome', async () => {
  const port = new Port(); port.gate = Promise.withResolvers<TurnOutcome>();
  const lane = new SessionLane('main', 'editing', port, new WorkspaceScheduler(), () => {}, { entries: 2, bytes: 10, submissionBytes: 10 });
  lane.submit(turn('main')); await settle();
  await lane.steer('🌍', 'steer-1', 's1'); await lane.steer('🌍', 'steer-2', 's2');
  await assert.rejects(lane.steer('x', 'steer-3', 's3'), /limit/);
  await lane.stop(); await settle();
  assert.deepEqual(port.records.filter(r => r.commandId === 'steer-1').map(r => r.state), ['dispatched', 'cancelled']);
  port.gate = undefined; lane.compact('compact-1'); await settle();
  assert.deepEqual(port.records.filter(r => r.commandId === 'compact-1').map(r => r.state), ['dispatched', 'completed']);
});

test('stopping a workspace-waiting turn preserves it without dispatch', async () => {
  const scheduler = new WorkspaceScheduler(); const busy = new Port(); busy.gate = Promise.withResolvers<TurnOutcome>();
  const a = new SessionLane('a', 'editing', busy, scheduler, () => {}), waiting = new Port();
  const b = new SessionLane('b', 'editing', waiting, scheduler, () => {});
  a.submit(turn('a')); await settle(); b.submit(turn('b')); await b.stop(); await settle();
  assert.equal(waiting.calls.length, 0); assert.equal(b.pending[0]?.turnId, 'b');
  await a.stop(); await settle(); assert.equal(waiting.calls.length, 0);
  b.resumeQueue(); await settle(); assert.equal(waiting.calls.length, 1);
});

test('a throw after dispatch remains interrupted and is never automatically replayed', async () => {
  const port = new Port(); port.submit = async (text, turnId) => { port.calls.push({ text, turnId }); throw new Error('Synthetic crash after tool dispatch'); };
  const lane = new SessionLane('main', 'editing', port, new WorkspaceScheduler(), () => {});
  lane.submit(turn('uncertain')); lane.submit(turn('queued')); await settle();
  assert.equal(lane.state, 'interrupted'); assert.equal(port.calls.length, 1);
  assert.deepEqual(port.records.map(r => r.state), ['dispatched']);
  assert.equal(lane.pending[0]?.turnId, 'queued');
  await settle(); assert.equal(port.calls.length, 1);
});

test('queue limits count encoded bytes and queued removal cannot resend a turn', async () => {
  const port = new Port(); port.gate = Promise.withResolvers<TurnOutcome>();
  const lane = new SessionLane('main', 'editing', port, new WorkspaceScheduler(), () => {}, { entries: 2, bytes: 10, submissionBytes: 10 });
  lane.submit(turn('one')); await settle(); lane.submit(turn('two', '🌍🌍'));
  assert.throws(() => lane.submit(turn('three', 'four')), /queue is full/);
  assert.throws(() => lane.submit(turn('four', '🌍🌍🌍')), /input limit/);
  lane.removeQueued('two'); await lane.stop(); await settle();
  assert.equal(lane.pending.length, 0); assert.equal(port.calls.length, 1);
  port.gate = undefined; lane.submit(turn('fresh')); await settle();
  assert.equal(port.calls[1]?.turnId, 'fresh');
});

test('compaction shares the session lane and rejected scheduling leaves no phantom operation', async () => {
  const port = new Port(), lane = new SessionLane('main', 'editing', port, new WorkspaceScheduler(), () => {});
  lane.compact(); assert.throws(() => lane.compact(), /idle/); await settle();
  assert.equal(port.compacted, 1); assert.equal(lane.isIdle, true);
  const full = new SessionLane('blocked', 'editing', port, new WorkspaceScheduler(0), () => {});
  assert.throws(() => full.compact(), /queue is full/); assert.equal(full.isIdle, true);
});

test('bounded journals report a gap and preserve the snapshot sequence boundary', () => {
  const journal = new EventJournal({ entries: 2, bytes: 512 });
  journal.append('message.delta', { delta: 'one' }); const boundary = journal.seq;
  journal.append('message.delta', { delta: 'two' }); journal.append('message.delta', { delta: 'three' });
  assert.equal(journal.since(0).resyncRequired, true);
  assert.deepEqual(journal.since(boundary).events.map(e => e.seq), [2, 3]);
  assert.equal(journal.since(4).resyncRequired, true);
  assert.equal(journal.append('large', { text: 'x'.repeat(1024) }).type, 'resyncRequired');
  assert.equal(journal.since(3).resyncRequired, true); assert.ok(journal.retainedBytes <= 512);
  const payload = { delta: 'immutable' }; journal.append('delta', payload); payload.delta = 'changed';
  assert.deepEqual(journal.since(4).events[0]?.payload, { delta: 'immutable' });
});
