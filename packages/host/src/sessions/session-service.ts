import { attachmentsFrom } from '../pi/attachments.ts';
import { textPage } from '../pi/text-page.ts';
import { resourceOptions } from '../resources/config.ts';
import { ResourceResolver } from '../resources/resolver.ts';
import { selectionsFrom, unmetDependencies } from '../resources/skills.ts';
import { mkdir, realpath, rm } from 'node:fs/promises';
import { isAbsolute, join, relative } from 'node:path';
import { createHash } from 'node:crypto';
import { Inspector, attemptMetrics } from '../observability/inspector.ts';
import { CaptureStore } from '../observability/capture-store.ts';
import { discoverProfiles, profileFrom, resolveProfileCredentials } from '../pi/profiles.ts';
import { PiSessionAdapter, type Profile } from '../pi/session-adapter.ts';
import { continueSessionCopy, inspectSessionFile, recoverSessionCopy, portableContextDraft } from '../pi/session-files.ts';
import { CommandError, CommandLedger } from './command-ledger.ts';
import { EventJournal } from './event-journal.ts';
import { SessionLane } from './session-lane.ts';
import { WorkspaceScheduler, type ToolMode } from './workspace-scheduler.ts';

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new CommandError('invalid_params', 'Expected an object');
  return value as Record<string, unknown>;
}
export function string(value: unknown, name: string, max = 4096): string {
  if (typeof value !== 'string' || !value || Buffer.byteLength(value) > max) throw new CommandError('invalid_params', `Invalid ${name}`);
  return value;
}
export function identity(value: unknown): string {
  const id = string(value, 'identity', 128);
  if (!/^[A-Za-z0-9._:-]+$/.test(id)) throw new CommandError('invalid_identity', 'Invalid identity');
  return id;
}
function integer(value: unknown, fallback: number, max: number): number {
  if (value === undefined) return fallback;
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > max) throw new CommandError('invalid_params', 'Invalid numeric limit');
  return value as number;
}
export { profileFrom } from '../pi/profiles.ts';
interface Entry { adapter: PiSessionAdapter; lane: SessionLane; journal: EventJournal; profile: Profile; mode: ToolMode; used: number; dirty: boolean;
  snapshotContext?: { at: number; state: string; value: unknown };
  parentId?: string; ephemeral?: boolean; keeping?: boolean; keepRequested?: boolean; keepError?: string }
export class SessionService {
  readonly capture = new CaptureStore();
  private inspector = new Inspector(this.capture);
  private ledger = new CommandLedger();
  private scheduler = new WorkspaceScheduler();
  private entries = new Map<string, Entry>();
  private cwd: string | undefined;
  private directory: string | undefined;
  private closing = false;
  private quiescing = false;
  private resources: ResourceResolver | undefined;
  private openingSides = new Map<string, Promise<Entry>>();
  private runtimeTail: Promise<unknown> = Promise.resolve();
  private inFlightMutations = new Set<Promise<unknown>>();
  private stops = new Map<string, Promise<void>>();
  private timer: NodeJS.Timeout | undefined;
  constructor(private notify: (sessionId: string, seq: number, type?: string) => void, private fixtureHome?: string) {}
  private markDirty(entry: Entry): void {
    entry.dirty = true;
    if (this.timer || this.closing) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      for (const [id, entry] of this.entries) if (entry.dirty) { entry.dirty = false; this.notify(id, entry.journal.seq); }
    }, 16); this.timer.unref();
  }
  get busy(): boolean { return [...this.entries.values()].some(entry => !entry.lane.isIdle); }
  private entry(id: string): Entry {
    const entry = this.entries.get(id);
    if (!entry) throw new CommandError('session_unloaded', 'Session runtime is unloaded; explicitly open it before sending');
    entry.used = Date.now(); return entry;
  }
  async command(commandId: string, method: string, sessionId: string | undefined, raw: unknown): Promise<unknown> {
    const operation=this.dispatch(commandId,method,sessionId,raw);
    const mutating=/^(turn\.|queue\.|side\.|workspace\.open$|session\.(open|close|forget|import\.(continue|recover))$|context\.compact$|resources\.configure$)/.test(method);
    if (mutating) this.inFlightMutations.add(operation);
    try { return await operation; } finally { this.inFlightMutations.delete(operation); }
  }
  private async dispatch(commandId: string, method: string, sessionId: string | undefined, raw: unknown): Promise<unknown> {
    const p = raw === undefined ? {} : object(raw);
    if (this.closing && !['turn.stop', 'session.status', 'session.snapshot'].includes(method)) throw new CommandError('closing', 'Host is shutting down');
    if (method === 'workspace.resume') { this.quiescing=false;return {accepted:true}; }
    if (method === 'workspace.quiesce') {
      this.quiescing=true;
      await Promise.allSettled([...this.inFlightMutations]);
      return this.runtimeMutation(async()=>{
        if (this.busy || [...this.entries.values()].some(e=>e.ephemeral || e.keeping || e.keepRequested) || this.openingSides.size) {this.quiescing=false;throw new CommandError('workspace_busy','Finish work and close or keep sides before updating');}
        return {accepted:true};
      });
    }
    if (this.quiescing && !['turn.stop','session.status','session.snapshot','session.events','session.event-page','context.info'].includes(method) && !method.startsWith('debug.')) throw new CommandError('update_preparing','This host is at its idle update barrier');
    if (method === 'workspace.open') {
      const cwd = await realpath(string(p.cwd, 'workspace')), directory = string(p.directory, 'managed directory');
      if (!isAbsolute(directory)) throw new CommandError('invalid_directory', 'Managed directory must be absolute');
      if (this.cwd && this.cwd !== cwd) throw new CommandError('workspace_bound', 'A host belongs to exactly one workspace');
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const canonical = await realpath(directory);
      if (this.directory && this.directory !== canonical) throw new CommandError('workspace_bound', 'Managed directory cannot change');
      this.cwd = cwd; this.directory = canonical;
      this.resources ??= new ResourceResolver(cwd, resourceOptions(p.resources ?? (this.fixtureHome ? { codexHome: this.fixtureHome } : undefined)), this.fixtureHome);
      return { cwd, directory: canonical };
    }
    if (method === 'profiles.discover') return discoverProfiles(string(p.path, 'Pi models.json path'));
    if (method === 'clock.sync') return {monotonic:performance.now()};
    if (!this.cwd || !this.directory) throw new CommandError('workspace_required', 'Open a trusted workspace first');
    if (method === 'resources.configure') {
      const options = resourceOptions(p.options);
      return this.ledger.perform(commandId, [method, options], async () => { this.resources!.configure(options); return { accepted: true }; });
    }
    if (method === 'resources.inspect' || method === 'resources.skill.read') {
      const snapshot = p.refresh === true ? await this.resources!.resolve() : await this.resources!.current();
      if (method === 'resources.skill.read') {
        const skill = snapshot.catalog.skills.find(s => s.id === p.skillId); if (!skill) throw new CommandError('skill_unavailable', 'Refresh the catalog');
        const offset = integer(p.offset, 0, 262144);
        return { ...textPage(skill.body,offset), contentHash: skill.contentHash };
      }
      const offset = integer(p.offset, 0, 512), active = sessionId ? this.entries.get(sessionId) : undefined;
      const tools = active?.adapter.activeTools ?? ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'];
      return { revision: snapshot.revision, appliedRevision: active?.adapter.appliedResources?.revision ?? null, stale: this.resources!.stale,
        cwd: snapshot.cwd, root: snapshot.root, codexHome: snapshot.codexHome, diagnostics: snapshot.diagnostics,
        instructionLimit: snapshot.instructions.limit, instructionBytes: snapshot.instructions.includedBytes,
        sources: snapshot.instructions.sources.slice(integer(p.sourceOffset, 0, 4096), integer(p.sourceOffset, 0, 4096) + 32), sourceCount: snapshot.instructions.sources.length,
        skills: snapshot.catalog.skills.slice(offset, offset + 32).map(({body, ...skill}) => ({...skill, sourceCharacters:body.length, missingDependencies: unmetDependencies(skill, tools)})),
        next: offset + 32 < snapshot.catalog.skills.length ? offset + 32 : null, total: snapshot.catalog.skills.length };
    }
    if (method === 'session.portable.preview') return portableContextDraft(string(p.path, 'source session'), this.cwd, this.directory);
    if (method === 'session.import.inspect') return inspectSessionFile(string(p.path, 'import path'));
    if (method === 'session.import.continue' || method === 'session.import.recover') {
      const source = string(p.path, 'source'), id = identity(p.newSessionId);
      return this.ledger.perform(commandId, [method, source, id], async () => {
        const copy = method === 'session.import.recover' ? await recoverSessionCopy(source, this.cwd!, this.directory!, id) : await continueSessionCopy(source, this.cwd!, this.directory!, id);
        return { accepted: true, sessionId: id, ...copy };
      });
    }
    const id = identity(sessionId);
    if (method === 'session.forget') {
      return this.runtimeMutation(async()=>{
        const active = this.entries.get(id);
        if (this.sideForParent(id) || this.openingSides.has(id)) throw new CommandError('side_open', 'Close or keep the side before forgetting its parent');
        if (active && (!active.lane.isIdle || active.keeping || active.ephemeral)) throw new CommandError('session_busy', 'Stop work and close or keep a side before deleting the chat');
        if (active) await this.unload(id);
        this.capture.forget(id); return { accepted: true };
      });
    }
    if (method === 'session.open') {
      if (this.closing) throw new CommandError('closing', 'Host is shutting down');
      const profile = profileFrom(p.profile), mode: ToolMode = p.toolMode === 'read-only' ? 'read-only' : 'editing';
      const apiKey = p.apiKey ? string(p.apiKey, 'API key', 16384) : undefined, resumePath = typeof p.path === 'string' && p.path ? p.path : undefined;
      return this.ledger.perform(commandId, [method, id, profile, mode, resumePath, p.connectionTest === true, p.handoff], () => this.runtimeMutation(async () => {
        if (this.closing) throw new CommandError('closing','Host is shutting down');
        const existing = this.entries.get(id);
        if (existing) {
          if (JSON.stringify(existing.profile) !== JSON.stringify(profile) || existing.mode !== mode) throw new CommandError('profile_changed', 'An open session retains its bound profile and tool mode. Close its idle runtime before changing compatible settings.');
          return { accepted: true, sessionId: id };
        }
        // A bounded active-runtime cache; browsing archived chats never calls this command.
        await this.ensureCapacity();
        if (p.handoff !== undefined && Buffer.byteLength(JSON.stringify(p.handoff)) > 8192) throw new CommandError('invalid_handoff', 'Handoff provenance exceeds its limit');
        const credentials = await resolveProfileCredentials(profile, apiKey);
        const adapter = await PiSessionAdapter.create({ sessionId: id, cwd: this.cwd!, agentDir: join(this.directory!, '.runtime'),
          resources: this.resources!,
          readOnly: mode === 'read-only' && p.connectionTest !== true,
          sessionDirectory: this.directory!, ...(resumePath ? { resumePath } : {}), profile: { ...profile, headers: credentials.headers }, apiKey: credentials.apiKey, capture: this.capture,
          ...(p.handoff ? { handoff: object(p.handoff) } : {}),
          ...(p.connectionTest === true ? { purpose: 'connection-test' as const } : {}),
          tools: p.connectionTest === true ? [] : mode === 'read-only' ? ['read', 'grep', 'find', 'ls'] : ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'],
          autoCompaction: true, reserveTokens: Math.min(profile.maxOutputTokens, Math.floor(profile.contextWindow / 4)),
          keepRecentTokens: Math.min(20_000, Math.floor(profile.contextWindow / 8)) });
        this.install(adapter,profile,mode); return { accepted: true, sessionId: id };
      }));
    }
    if (method.startsWith('debug.')) {
      if (this.entries.get(id)?.ephemeral && method === 'debug.mode' && p.mode === 'persist') throw new CommandError('side_memory_only', 'Keep the side as a separate chat before enabling persistent tracing');
      return this.inspector.command(method, id, p);
    }
    const entry = this.entry(id);
    if (method === 'side.open') {
      if (entry.ephemeral) throw new CommandError('nested_side', 'Nested sides are unavailable; keep this one as a separate chat first');
      const newId = identity(p.sideSessionId);
      return this.ledger.perform(commandId,[method,id,newId],async()=>{
        const existing = this.sideForParent(id); if (existing) return {accepted:true,sessionId:existing.adapter.id,side:existing.adapter.sideInfo(),ephemeral:true};
        let pending=this.openingSides.get(id);
        if (!pending) {
          if (this.entries.has(newId)) throw new CommandError('session_conflict','Side identity already exists');
          const boundary=entry.adapter.getSideBoundary();
          pending=this.runtimeMutation(async()=>{
            if (this.closing || this.entries.get(id)!==entry) throw new CommandError('closing','Parent runtime changed while preparing the side');
            await this.ensureCapacity([id]); const adapter=await entry.adapter.createSide(newId,boundary);
            if (this.closing || !this.entries.has(id)) {await adapter.dispose();throw new CommandError('closing','Workspace closed while preparing the side');}
            this.capture.setMode(newId,this.capture.modeFor(id)==='off'?'off':'memory');
            return this.install(adapter,entry.profile,'read-only',{parentId:id,ephemeral:true});
          });
          this.openingSides.set(id,pending);
          void pending.finally(()=>this.openingSides.delete(id)).catch(()=>{});
        }
        const side=await pending; return {accepted:true,sessionId:side.adapter.id,side:side.adapter.sideInfo(),ephemeral:true};
      });
    }
    if (method === 'side.keep') return this.ledger.perform(commandId,[method,id,p.whenFinished===true],async()=>{
      if (!entry.ephemeral) return {accepted:true,path:entry.adapter.sessionFile,ephemeral:false};
      if (!entry.lane.isIdle) {
        if (p.whenFinished!==true) throw new CommandError('session_busy','Keep at idle, or explicitly choose Keep when finished');
        entry.keepRequested=true; entry.journal.append('side.keep-requested',{}); entry.dirty=true; return {accepted:true,whenFinished:true};
      }
      return this.keep(entry);
    });
    if (method === 'side.close') return this.ledger.perform(commandId,[method,id,p.cancel===true],async()=>{
      if (!entry.ephemeral) throw new CommandError('side_kept','This is a saved chat; close its idle runtime separately');
      if ((!entry.lane.isIdle || entry.keeping) && p.cancel!==true) throw new CommandError('session_busy','Explicitly cancel before discarding a running side');
      if (entry.keeping) throw new CommandError('side_keeping','Wait for the atomic Keep operation to finish');
      entry.keepRequested=false;
      return this.runtimeMutation(async()=>{await this.unload(id); this.capture.forget(id); return {accepted:true};});
    });
    if (method === 'context.info') {
      const latest = this.capture.attempts.findLast(a => a.sessionId === id);
      const { headers, ...profile } = entry.profile;
      return { context: entry.adapter.contextUsage(), contextSource: 'Pi estimate; configured capacity', profile, headerNames: Object.keys(headers ?? {}), effectiveThinkingLevel: entry.adapter.effectiveThinkingLevel,
        outputReserve: entry.profile.maxOutputTokens, run: entry.adapter.turnMetrics(), captureMode: this.capture.modeFor(id),
        latestAttemptId: latest?.attemptId ?? null, latestUsage: latest?.usage ?? null, latestMetrics: latest ? attemptMetrics(latest) : null,
        cumulative: entry.adapter.sessionUsage(), provenance: entry.adapter.provenance(), liveTokenRate: null,
        resources: { stale: this.resources!.stale, appliedRevision: entry.adapter.appliedResources?.revision ?? null } };
    }
    if (method === 'session.status') return { sessionId: id, seq: entry.journal.seq, state: entry.lane.state, runStatus: entry.adapter.runStatus,
      preflightError: entry.adapter.preflightError,
      side: entry.adapter.sideInfo(), ephemeral: entry.ephemeral===true, keeping: entry.keeping===true, keepRequested: entry.keepRequested===true, keepError: entry.keepError ?? null,
      queueCount: entry.lane.pending.length, path: entry.adapter.sessionFile ?? null, commands: entry.adapter.commandHistory().slice(-128) };
    if (method === 'session.snapshot') {
      const projection = entry.adapter.projection();
      const displayRevision = createHash('sha256').update(JSON.stringify(projection)).digest('hex');
      const now = performance.now(), state = `${entry.lane.state}:${entry.adapter.runStatus}`;
      if (!entry.snapshotContext || now - entry.snapshotContext.at >= 250 || entry.snapshotContext.state !== state) entry.snapshotContext = {at:now,state,value:entry.adapter.contextUsage()};
      return { sessionId: id, seq: entry.journal.seq, state: entry.lane.state,
      displayObservedAt:entry.adapter.takeDisplayObservation(),
      preflightError: entry.adapter.preflightError,
      side: entry.adapter.sideInfo(), ephemeral: entry.ephemeral===true, keeping: entry.keeping===true, keepRequested: entry.keepRequested===true, keepError: entry.keepError ?? null,
      runStatus: entry.adapter.runStatus, queue: entry.lane.pending.map(item => ({ turnId: item.turnId, commandId: item.commandId, text: item.text.slice(0, 1024) })),
      queueCount: entry.lane.pending.length, path: entry.adapter.sessionFile ?? null, commands: entry.adapter.commandHistory().slice(-128),
      ...(p.includeMessages === false || p.displayRevision === displayRevision ? {before:projection.before,total:projection.total} : projection), displayRevision,
      profileId: entry.profile.id, toolMode: entry.mode, context: entry.snapshotContext.value, turnMetrics: entry.adapter.turnMetrics(), captureMode: this.capture.modeFor(id), latestAttempt: (() => { const a = this.capture.attempts.findLast(a => a.sessionId === id); return a ? { attemptId: a.attemptId, metrics: attemptMetrics(a), usage: a.usage } : null; })() };
    }
    if (method === 'session.event-page') return entry.journal.recent();
    if (method === 'session.events') return entry.journal.since(integer(p.since, 0, Number.MAX_SAFE_INTEGER));
    if (method === 'session.history') return entry.adapter.projection(integer(p.before, 0, Number.MAX_SAFE_INTEGER));
    if (method === 'session.message.read') return entry.adapter.readMessage(identity(p.messageId), p.field === 'thinking' ? 'thinking' : 'text', integer(p.offset, 0, 128 * 1024 * 1024));
    if (method === 'session.content.search') return entry.adapter.searchContent(p.query===''?'':string(p.query,'search',1024),integer(p.start,0,100000));
    if (method === 'session.content.page') return entry.adapter.copyContentPage(integer(p.first,1,100000),integer(p.last,1,100000),integer(p.index,1,100000),integer(p.offset,0,128*1024*1024),identity(p.revision));
    if (method === 'turn.stop') {
      if (!this.stops.has(id)) {
        const stop = entry.lane.stop().catch(() => { entry.journal.append('error', { message: 'Cancellation did not finish; inspect this workspace before forcing it to stop' }); this.markDirty(entry); }).finally(() => { this.stops.delete(id); });
        this.stops.set(id, stop);
      }
      return { accepted: true };
    }
    if (this.closing) throw new CommandError('closing', 'Host is shutting down');
    if (entry.keeping) throw new CommandError('side_keeping','This side is being kept. Wait before starting another command.');
    // Canonical field order makes equivalent JSON parameter order irrelevant.
    if (method === 'turn.submit') {
      const selected = selectionsFrom(p.skills);
      const turnId = identity(p.clientTurnId), text = p.text === '' && selected.length ? '' : string(p.text, 'submission', 256 * 1024);
      const attachments = attachmentsFrom(p.attachments);
      if (attachments.length && !entry.profile.input?.includes('image')) throw new CommandError('unsupported_image', 'The selected profile does not declare image input');
      return this.ledger.perform(commandId, [method, id, turnId, text, attachments, selected], async () => {
        const skills = selected.length ? await this.resources!.freeze(selected, entry.adapter.activeTools) : [];
        return { accepted: true, sessionId: id, turnId, ...entry.lane.submit({ commandId, turnId, text, attachments, skills }) };
      });
    }
    if (method === 'turn.steer') {
      const selected = selectionsFrom(p.skills);
      const text = p.text === '' && selected.length ? '' : string(p.text, 'steering input', 256 * 1024), turnId = identity(p.clientTurnId);
      const attachments = attachmentsFrom(p.attachments);
      if (attachments.length && !entry.profile.input?.includes('image')) throw new CommandError('unsupported_image', 'Profile does not declare image input');
      return this.ledger.perform(commandId, [method, id, turnId, text, attachments, selected], async () => {
        const skills = selected.length ? await this.resources!.freeze(selected, entry.adapter.activeTools) : [];
        await entry.lane.steer(text, commandId, turnId, attachments, skills); return { accepted: true }; });
    }
    if (method === 'queue.remove' || method === 'queue.resume' || method === 'context.compact' || method === 'session.close') {
      const turnId = method === 'queue.remove' ? identity(p.turnId) : null;
      return this.ledger.perform(commandId, [method, id, turnId], async () => {
        if (method === 'queue.remove') entry.lane.removeQueued(turnId!);
        if (method === 'queue.resume') entry.lane.resumeQueue();
        if (method === 'context.compact') entry.lane.compact(commandId);
        if (method === 'session.close') await this.runtimeMutation(async()=>{ if (!entry.lane.isIdle || entry.ephemeral || entry.keeping || this.sideForParent(id) || this.openingSides.has(id)) throw new CommandError('session_busy', 'Stop work, clear queued turns and close or keep any side before closing'); await this.unload(id); });
        return { accepted: true };
      });
    }
    throw new CommandError('unsupported_command', 'Unsupported command');
  }
  private sideForParent(id: string): Entry | undefined { return [...this.entries.values()].find(e=>e.ephemeral && e.parentId===id); }
  // Serialize only runtime creation/promotion/retirement. Model lanes remain
  // independent; slow credentials cannot oversubscribe the three-runtime cache.
  private runtimeMutation<T>(operation:()=>Promise<T>): Promise<T> {
    const result=this.runtimeTail.then(operation); this.runtimeTail=result.catch(()=>{}); return result;
  }
  private async ensureCapacity(protectedIds: string[] = []): Promise<void> {
    if (this.entries.size < 3) return;
    const oldest=[...this.entries.values()].filter(e=>e.lane.isIdle && !e.ephemeral && !e.keeping && !this.sideForParent(e.adapter.id) && !this.openingSides.has(e.adapter.id) && !protectedIds.includes(e.adapter.id)).sort((a,b)=>a.used-b.used)[0];
    if (!oldest) throw new CommandError('runtime_capacity','Three session runtimes are active or pinned by unkept sides. Close or keep a side first');
    await this.unload(oldest.adapter.id);
  }
  private install(adapter: PiSessionAdapter, profile: Profile, mode: ToolMode, extra: Partial<Entry> = {}, journal = new EventJournal()): Entry {
    const entry={} as Entry;
    const changed=(type:string,payload:unknown)=>{journal.append(type,payload);this.markDirty(entry);};
    const lane=new SessionLane(adapter.id,mode,adapter,this.scheduler,event=>{
      changed(event.type,event);
      if (event.type==='state' && event.state==='idle' && entry.keepRequested && !entry.keeping) void this.keep(entry).catch(()=>{});
    });
    Object.assign(entry,{adapter,lane,journal,profile,mode,used:Date.now(),dirty:true},extra);
    adapter.subscribe(event=>{
      if (['compaction_start','compaction_end','agent_settled'].includes(event.type)) delete entry.snapshotContext;
      changed('pi.normalized',{...event,...(event.delta?{delta:event.delta.slice(0,256),previewOnly:true}:{})});
    });
    this.entries.set(adapter.id,entry); this.markDirty(entry); return entry;
  }
  private async keep(entry: Entry): Promise<{accepted:true;path:string;sessionId:string;ephemeral:false}> {
    if (entry.keeping) throw new CommandError('side_keeping','Keep is already in progress');
    if (!entry.lane.isIdle || !entry.ephemeral) throw new CommandError('session_busy','Keeping requires an idle unkept side and an empty queue');
    entry.keeping=true; entry.keepRequested=false; entry.journal.append('side.keeping',{});this.markDirty(entry);
    return this.runtimeMutation(async()=>{
      let prepared: Awaited<ReturnType<PiSessionAdapter['prepareKeep']>>;
      try { prepared=await entry.adapter.prepareKeep(this.directory!); }
      catch {
        entry.keeping=false;entry.keepError='Could not keep the side. Its in-memory context remains intact; check available disk space and retry.';
        entry.journal.append('side.keep-failed',{message:entry.keepError});this.markDirty(entry);throw new CommandError('side_keep_failed',entry.keepError);
      }
      const next=this.install(prepared.adapter,entry.profile,'read-only',{ephemeral:false,keeping:true},entry.journal);
      // Publication is the commit point. A cleanup failure must never roll back
      // the live saved adapter or misreport the intact file as an unkept side.
      await Promise.allSettled([entry.lane.close(),entry.adapter.dispose()]);
      next.keeping=false;next.journal.append('side.kept',{path:prepared.path});this.markDirty(next);
      return {accepted:true,path:prepared.path,sessionId:prepared.adapter.id,ephemeral:false};
    });
  }
  private async unload(id: string): Promise<void> {
    const entry = this.entries.get(id); if (!entry) return;
    await entry.lane.close(); await entry.adapter.dispose(); this.entries.delete(id);
    this.notify(id, entry.journal.seq, 'session.unloaded');
  }
  async shutdown(): Promise<void> {
    this.closing = true; clearTimeout(this.timer);
    await Promise.allSettled([...this.inFlightMutations]);
    await Promise.allSettled([...this.openingSides.values()]);
    await this.runtimeMutation(()=>Promise.all([...this.entries.keys()].map(id => this.unload(id))));
    this.resources?.dispose();
  }
}
