import { CommandError } from './command-ledger.ts';

export type ToolMode = 'editing' | 'read-only';
interface Job { mode: ToolMode; run: () => Promise<void>; started: boolean; settled: boolean;
  resolve: () => void; reject: (error: unknown) => void }
export interface ScheduledJob { completion: Promise<void>; cancelWaiting: () => boolean }

export class WorkspaceScheduler {
  private jobs: Job[] = [];
  private active = new Set<ToolMode>();
  constructor(readonly capacity = 32) {}
  schedule(mode: ToolMode, run: () => Promise<void>): ScheduledJob {
    if (this.jobs.length >= this.capacity) throw new CommandError('workspace_queue_full', 'Workspace queue is full');
    const result = Promise.withResolvers<void>();
    const job: Job = { mode, run, started: false, settled: false, resolve: result.resolve, reject: result.reject };
    this.jobs.push(job); queueMicrotask(() => this.pump());
    return { completion: result.promise, cancelWaiting: () => {
      if (job.started || job.settled) return false;
      this.jobs.splice(this.jobs.indexOf(job), 1); job.settled = true; job.resolve(); return true;
    } };
  }
  private pump(): void {
    for (const mode of ['editing', 'read-only'] as const) {
      if (this.active.has(mode)) continue;
      const index = this.jobs.findIndex(job => job.mode === mode);
      if (index < 0) continue;
      const [job] = this.jobs.splice(index, 1); if (!job) continue;
      this.active.add(mode); job.started = true;
      void Promise.resolve().then(job.run).then(job.resolve, job.reject).finally(() => {
        job.settled = true; this.active.delete(mode); this.pump();
      });
    }
  }
  get pending(): number { return this.jobs.length; }
}
