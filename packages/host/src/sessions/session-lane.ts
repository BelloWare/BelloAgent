import type { Attachment } from '../pi/attachments.ts';
import type { FrozenSkill } from '../resources/skills.ts';
import { CommandError } from './command-ledger.ts';
import { WorkspaceScheduler, type ScheduledJob, type ToolMode } from './workspace-scheduler.ts';

export type TurnOutcome = 'completed' | 'failed' | 'cancelled' | 'interrupted';
export interface Submission { turnId: string; commandId: string; text: string; attachments?: Attachment[]; skills?: FrozenSkill[] }
export interface SessionPort {
  submit(text: string, turnId: string, input?: Submission): Promise<TurnOutcome>;
  steer(text: string, attachments?: Attachment[], skills?: FrozenSkill[], invocationId?: string): Promise<void>;
  abort(): Promise<void>;
  compact(): Promise<unknown>;
  recordCommand(commandId: string, turnId: string, state: 'dispatched' | TurnOutcome): void;
}
export type LaneState = 'idle' | 'queued' | 'running' | 'compacting' | 'stopping' | 'paused' | 'interrupted';
export interface LaneEvent { type: 'state' | 'queue' | 'turn.end'; state?: LaneState; turnId?: string; outcome?: TurnOutcome }

export class SessionLane {
  private queue: Submission[] = [];
  private queueBytes = 0;
  private attachmentBytes = 0;
  private paused = false;
  private interrupted = false;
  private scheduled: ScheduledJob | undefined;
  private running: Submission | undefined;
  private operation: 'turn' | 'compact' | undefined;
  private stateValue: LaneState = 'idle';
  private closed = false;
  private steering: Submission[] = [];
  private steeringBytes = 0;
  private steeringAttachmentBytes = 0;
  constructor(readonly id: string, readonly mode: ToolMode, private port: SessionPort,
    private scheduler: WorkspaceScheduler, private emit: (event: LaneEvent) => void,
    private limits = { entries: 16, bytes: 2 * 1024 * 1024, submissionBytes: 256 * 1024 }) {}

  get state(): LaneState { return this.stateValue; }
  get isIdle(): boolean { return !this.scheduled && !this.running && this.queue.length === 0; }
  get pending(): ReadonlyArray<Submission> { return this.queue.map(item => ({ ...item })); }
  private inputBytes(input: Submission): number { return Buffer.byteLength(input.text) + (input.skills?.length ? Buffer.byteLength(JSON.stringify(input.skills)) : 0); }
  private setState(state: LaneState): void { this.stateValue = state; this.emit({ type: 'state', state }); }

  submit(submission: Submission): { queued: boolean } {
    if (this.closed) throw new CommandError('session_closed', 'Session is closed');
    const bytes = this.inputBytes(submission), images = submission.attachments?.reduce((n,x)=>n+x.bytes,0) ?? 0;
    if (this.attachmentBytes + images > 32 * 1024 * 1024) throw new CommandError("attachment_queue_full", "Queued image references exceed the 32 MiB budget");
    if ((!submission.text.trim() && !submission.skills?.length) || bytes > this.limits.submissionBytes) throw new CommandError('invalid_submission', 'Submission must contain text or selected skills and fit the 256 KiB input limit including frozen skills');
    if (this.queue.length >= this.limits.entries || this.queueBytes + bytes > this.limits.bytes) throw new CommandError('session_queue_full', 'Follow-up queue is full');
    if (this.running?.turnId === submission.turnId || this.queue.some(item => item.turnId === submission.turnId)) throw new CommandError('turn_conflict', 'Turn ID is already active or queued');
    if (this.paused && this.queue.length === 0 && !this.scheduled && !this.running) { this.paused = false; this.interrupted = false; }
    const queued = this.scheduled !== undefined || this.running !== undefined || this.paused;
    this.queue.push(Object.freeze(structuredClone(submission))); this.queueBytes += bytes; this.attachmentBytes += images; this.emit({ type: 'queue' });
    try { this.pump(); } catch (error) { this.queue.pop(); this.queueBytes -= bytes; this.attachmentBytes -= images; this.emit({ type: 'queue' }); this.setState('idle'); throw error; }
    return { queued };
  }
  removeQueued(turnId: string): void {
    const index = this.queue.findIndex(item => item.turnId === turnId);
    if (index < 0) throw new CommandError('not_queued', 'This turn is no longer queued');
    const [removed] = this.queue.splice(index, 1); this.queueBytes -= this.inputBytes(removed!); this.attachmentBytes -= removed!.attachments?.reduce((n,x)=>n+x.bytes,0) ?? 0;
    if (this.queue.length === 0 && this.scheduled && !this.running) this.scheduled.cancelWaiting();
    this.emit({ type: 'queue' });
  }
  resumeQueue(): void {
    if (this.closed) throw new CommandError('session_closed', 'Session is closed');
    this.paused = false; this.interrupted = false; this.pump();
  }
  async steer(text: string, commandId?: string, turnId?: string, attachments: Attachment[] = [], skills: FrozenSkill[] = []): Promise<void> {
    if (!this.running || this.operation !== 'turn' || this.stateValue === 'stopping') throw new CommandError('cannot_steer', 'There is no running turn to steer');
    if ((!text.trim() && !skills.length) || Buffer.byteLength(text) > this.limits.submissionBytes) throw new CommandError('invalid_submission', 'Invalid steering input');
    const bytes = this.inputBytes({text, skills, commandId: '', turnId: ''});
    if (bytes > this.limits.submissionBytes || this.steering.length >= this.limits.entries || this.steeringBytes + bytes > this.limits.bytes) throw new CommandError('steering_full', 'Steering input or queue reached its limit, including frozen skills');
    const imageBytes = attachments.reduce((n,x)=>n+x.bytes,0);
    if (this.steeringAttachmentBytes + imageBytes > 32 * 1024 * 1024) throw new CommandError("attachment_limit", "Steering image limit exceeded");
    await this.port.steer(text, attachments, skills, turnId);
    this.steeringBytes += bytes; this.steeringAttachmentBytes += imageBytes;
    if (commandId && turnId) { this.steering.push({ text: '', commandId, turnId }); this.port.recordCommand(commandId, turnId, 'dispatched'); }
    else this.steering.push({ text: '', commandId: '', turnId: '' });
  }
  async stop(): Promise<void> {
    this.paused = true;
    if (this.scheduled?.cancelWaiting()) { await this.scheduled.completion; this.setState('paused'); return; }
    if (this.running || this.operation === 'compact') {
      this.setState('stopping'); await this.port.abort(); await this.scheduled?.completion;
    }
    this.setState('paused');
  }
  compact(commandId?: string): void {
    if (!this.isIdle || this.closed) throw new CommandError('session_busy', 'Compaction requires an idle session and empty queue');
    this.scheduled = this.scheduler.schedule(this.mode, async () => {
      this.setState('compacting');
      if (commandId) this.port.recordCommand(commandId, `compaction:${commandId}`, 'dispatched');
      try { await this.port.compact(); if (commandId) this.port.recordCommand(commandId, `compaction:${commandId}`, 'completed'); }
      catch (error) { if (commandId) this.port.recordCommand(commandId, `compaction:${commandId}`, 'failed'); throw error; }
    });
    this.operation = 'compact'; this.setState('queued');
    this.watch(this.scheduled);
  }
  async close(): Promise<void> { await this.stop(); this.closed = true; this.queue = []; this.queueBytes = 0; this.attachmentBytes = 0; this.emit({ type: 'queue' }); }
  private pump(): void {
    if (this.scheduled || this.closed || this.paused || this.queue.length === 0) {
      if (!this.scheduled) this.setState(this.paused ? this.interrupted ? 'interrupted' : 'paused' : 'idle');
      return;
    }
    this.setState('queued');
    this.scheduled = this.scheduler.schedule(this.mode, async () => {
      if (this.paused) return;
      const submission = this.queue.shift();
      if (!submission) return;
      this.queueBytes -= this.inputBytes(submission); this.attachmentBytes -= submission.attachments?.reduce((n,x)=>n+x.bytes,0) ?? 0; this.running = submission; this.operation = 'turn';
      this.emit({ type: 'queue' }); this.setState('running');
      let outcome: TurnOutcome = 'interrupted';
      try {
        this.port.recordCommand(submission.commandId, submission.turnId, 'dispatched');
        outcome = await this.port.submit(submission.text, submission.turnId, submission);
        this.port.recordCommand(submission.commandId, submission.turnId, outcome);
        for (const steer of this.steering) if (steer.commandId) this.port.recordCommand(steer.commandId, steer.turnId, outcome);
      } finally {
        this.steering = []; this.steeringBytes = 0; this.steeringAttachmentBytes = 0;
        if (outcome !== 'completed') this.paused = true;
        this.emit({ type: 'turn.end', turnId: submission.turnId, outcome }); this.running = undefined;
      }
    });
    this.watch(this.scheduled);
  }
  private watch(job: ScheduledJob): void {
    void job.completion.catch(() => { this.paused = true; this.interrupted = true; this.setState('interrupted'); }).finally(() => {
      if (this.scheduled === job) this.scheduled = undefined;
      this.operation = undefined;
      try { this.pump(); }
      catch { this.paused = true; this.setState('paused'); }
    });
  }
}
