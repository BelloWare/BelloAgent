import { createHash, randomUUID } from 'node:crypto';
import { realpath } from 'node:fs/promises';
import { relative, isAbsolute } from 'node:path';
import { InMemoryCredentialStore, InMemoryModelsStore, Type } from '@earendil-works/pi-ai';
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager, type AgentSession } from '@earendil-works/pi-coding-agent';
import { type ApiKind, type Purpose, CaptureStore } from '../observability/capture-store.ts';
import { instrumentRuntime } from './instrument-runtime.ts';
import { inspectSessionFile } from './session-files.ts';
import { readAttachments, type Attachment } from './attachments.ts';
import { ResourceResolver, ResolvedResourceLoader, type ResourceSnapshot } from '../resources/resolver.ts';
import { expandSkills, validateFrozen, type FrozenSkill } from '../resources/skills.ts';
import { ResourceError } from '../resources/files.ts';
import { digest } from '../resources/files.ts';
import { SideBoundaryCache, sideSeed, type SideBoundary } from './side-boundary.ts';
import { READ_ONLY_TOOLS, readOnlyGuard } from './read-only-policy.ts';
import { persistMemorySession } from './session-files.ts';
import { textPage } from './text-page.ts';
import { searchContent, copyContentPage, type ContentEntry } from './conversation-content.ts';
import type { Submission, TurnOutcome } from '../sessions/session-lane.ts';
import { messageView, preview, type MessageView, type ToolView } from './presentation.ts';

import { profileFrom, type Profile } from './profiles.ts';
export type { Profile } from './profiles.ts';
export interface AdapterEvent { type: string; delta?: string; contentKind?: string; toolName?: string }
export interface SessionOptions {
  sessionId?: string;
  cwd: string;
  agentDir: string;
  profile: Profile;
  apiKey: string;
  capture: CaptureStore;
  sessionDirectory?: string;
  resumePath?: string;
  tools?: string[];
  autoCompaction?: boolean;
  reserveTokens?: number;
  keepRecentTokens?: number;
  providerRetries?: number;
  purpose?: Purpose;
  handoff?: Record<string, unknown>;
  resources?: ResourceResolver;
  resourceSnapshot?: ResourceSnapshot;
  sideBoundary?: SideBoundary;
  readOnly?: boolean;
  // Synthetic, opt-in test tool; not registered in normal application sessions.
  fixtureEcho?: (text: string, signal: AbortSignal | undefined) => Promise<string>;
}

export class PiSessionAdapter {
  readonly id: string;
  private turnId: string | null = null;
  private purpose: Purpose = 'turn';
  private defaultPurpose: Purpose = 'turn';
  private busy = false;
  private cancelled = false;
  private listeners = new Set<(event: AdapterEvent) => void>();
  private unsubscribe: () => void;
  // Pi already owns this mutable partial message. Project it only when the
  // foreground asks, instead of rescanning a growing answer on every delta.
  private activeMessage: { id: string; message: unknown } | undefined;
  private streamSerial = 0;
  private toolStates = new Map<string, ToolView>();
  private toolStarts = new Map<string, number>();
  private lifecycle = 'idle';
  private turnStart: number | null = null;
  private turnEnd: number | null = null;
  private resources: ResourceResolver | undefined;
  private resolvedLoader: ResolvedResourceLoader | undefined;
  private skillGrants: { id: string; contentHash: string; metadataHash: string }[] = [];
  preflightError: string | null = null;
  private boundaryCache = new SideBoundaryCache();
  private boundaryScheduled = false;
  private disposed = false;
  private firstSideTurn = false;
  private displayObservedAt: number | undefined;
  private origin: {parentSessionId:string;cutoffEntryId:string|null;contextRevision:string;capturedAt:string;bytes:number;omittedIncompleteEntries:number;instructionRevision:string|null} | undefined;

  private constructor(private session: AgentSession, private manager: SessionManager, id: string, private creation: SessionOptions) {
    this.id = id;
    this.unsubscribe = session.subscribe(event => {
      if (event.type === 'message_start' || event.type === 'message_update') {
        if (event.type === 'message_start') this.streamSerial++;
        this.activeMessage = {id:`stream:${id}:${this.streamSerial}`,message:event.message};
      }
      if (event.type === 'message_end') this.activeMessage = undefined;
      if (event.type === 'tool_execution_start') {
        while (this.toolStates.size >= 128) this.toolStates.delete(this.toolStates.keys().next().value!);
        const input = preview(JSON.stringify(event.args), 4096);
        this.toolStarts.set(event.toolCallId, performance.now());
        this.toolStates.set(event.toolCallId, { id: event.toolCallId, name: event.toolName, state: 'running', input: input.text,
          output: '', durationMs: null, truncated: input.truncated }); this.lifecycle = 'waitingTool';
      }
      if (event.type === 'tool_execution_update' || event.type === 'tool_execution_end') {
        const tool = this.toolStates.get(event.toolCallId);
        const result = event.type === 'tool_execution_end' ? event.result : event.partialResult;
        if (tool && result && typeof result === 'object' && 'content' in result) {
          const output = messageView('tool', result).text; const bounded = preview(output, 4096);
          tool.output = bounded.text; tool.truncated ||= bounded.truncated || messageView('tool', result).truncated;
          if (event.type === 'tool_execution_end') {
            tool.state = event.isError ? this.cancelled ? 'cancelled' : 'failed' : 'completed';
            tool.durationMs = performance.now() - (this.toolStarts.get(event.toolCallId) ?? performance.now());
            this.toolStarts.delete(event.toolCallId); this.lifecycle = 'running';
          }
        }
      }
      if (event.type === 'compaction_start') this.lifecycle = 'compacting';
      if (event.type === 'compaction_end') this.lifecycle = event.errorMessage ? 'compaction failed' : 'running';
      if (event.type === 'auto_retry_start' || event.type === 'summarization_retry_scheduled') this.lifecycle = 'retryWaiting';
      if (event.type === 'agent_settled') this.lifecycle = 'idle';
      if (['message_end', 'turn_end', 'compaction_end', 'agent_settled'].includes(event.type)) this.scheduleBoundary();
      const view: AdapterEvent = { type: event.type };
      if (event.type === 'message_update') {
        const update = event.assistantMessageEvent;
        view.contentKind = update.type;
        if ('delta' in update && typeof update.delta === 'string') view.delta = update.delta;
        if (process.env.PI_APP_BENCHMARK === '1' && view.delta && this.displayObservedAt === undefined) this.displayObservedAt=performance.now();
      }
      if ('toolName' in event && typeof event.toolName === 'string') view.toolName = event.toolName;
      for (const listener of this.listeners) listener(view);
    });
  }

  static async create(options: SessionOptions): Promise<PiSessionAdapter> {
    const profile = profileFrom(options.profile);
    if (options.resumePath) {
      if (!options.sessionDirectory) throw new Error('A managed session directory is required for writable resume');
      const path = relative(await realpath(options.sessionDirectory), await realpath(options.resumePath));
      if (path.startsWith('..') || isAbsolute(path)) throw new Error('Writable resume must use an app-managed copy of the session');
      await inspectSessionFile(options.resumePath);
    }
    const newSession = { id: options.sessionId ?? randomUUID() };
    const binding = { profileId: profile.id, api: profile.api, providerId: profile.providerId, modelId: profile.modelId,
      endpointSHA256: createHash('sha256').update(profile.baseUrl).digest('hex') };
    if (options.sideBoundary && (options.resumePath || options.sessionDirectory)) throw new Error('A new side must start in memory');
    const manager = options.sideBoundary ? SessionManager.inMemory(options.cwd, newSession, sideSeed(options.sideBoundary, binding, profile.thinkingLevel ?? 'off')) :
      options.resumePath ? SessionManager.open(options.resumePath, options.sessionDirectory, options.cwd) :
        options.sessionDirectory ? SessionManager.create(options.cwd, options.sessionDirectory, newSession) : SessionManager.inMemory(options.cwd, newSession);
    const id = manager.getSessionId();
    if (options.sessionId && options.sessionId !== id) throw new Error('Managed session identity does not match the Pi file');
    const saved = manager.getEntries().findLast(entry => entry.type === 'custom' && entry.customType === 'pi-app.profile.v1');
    if (saved?.type === 'custom' && JSON.stringify(saved.data) !== JSON.stringify(binding)) {
      throw new Error('Saved session profile or route differs. Create a new chat or an explicit portable handoff.');
    }
    if (!saved) {
      for (const entry of manager.getEntries()) if (entry.type === 'message' && entry.message.role === 'assistant') {
        const message = entry.message;
        const opaque = message.content.some(block => block.type === 'thinking' && !!block.thinkingSignature || block.type === 'text' && !!block.textSignature);
        if (message.api !== profile.api || message.provider !== profile.providerId || message.model !== profile.modelId || opaque) {
          throw new Error('Unbound CLI history has incompatible or opaque provider state. Use an explicit portable handoff; the original is preserved.');
        }
      }
      manager.appendCustomEntry('pi-app.profile.v1', binding);
    }
    if (options.handoff && !manager.getEntries().some(e => e.type === 'custom' && e.customType === 'pi-app.handoff.v1')) manager.appendCustomEntry('pi-app.handoff.v1', options.handoff);
    const runtime = await ModelRuntime.create({ credentials: new InMemoryCredentialStore(), modelsStore: new InMemoryModelsStore(),
      modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
    runtime.registerProvider(profile.providerId, { api: profile.api, baseUrl: profile.baseUrl,
      models: [{ id: profile.modelId, name: profile.modelId, api: profile.api, reasoning: profile.reasoning ?? false, input: profile.input ?? ['text'],
        cost: profile.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: profile.contextWindow, maxTokens: profile.maxOutputTokens,
        ...(profile.thinkingLevelMap ? { thinkingLevelMap: profile.thinkingLevelMap } : {}),
        ...(profile.samplingParams ? { samplingParams: profile.samplingParams } : {}), ...(profile.compat ? { compat: profile.compat } : {}) }] });
    await runtime.setRuntimeApiKey(profile.providerId, options.apiKey);
    const model = runtime.getModel(profile.providerId, profile.modelId);
    if (!model) throw new Error('Configured Pi model was not registered');
    let adapter: PiSessionAdapter | undefined;
    instrumentRuntime(runtime, options.capture, () => ({ sessionId: id, turnId: adapter?.turnId ?? null,
      profileRevision: profile.revision, resourceRevision: adapter?.resolvedLoader?.snapshot?.revision ?? 'none',
      skillGrants: adapter?.skillGrants.map(s => Object.freeze({...s})) ?? [],
      ...(adapter?.origin ? { sideSnapshot: { parentSessionId: adapter.origin.parentSessionId, cutoffEntryId: adapter.origin.cutoffEntryId, contextRevision: adapter.origin.contextRevision } } : {}),
      purpose: adapter?.session.isCompacting ? 'compaction' : adapter?.purpose ?? 'turn' }), profile.headers, profile.publicMetadataHeaders);
    const settings = SettingsManager.inMemory({ transport: 'sse', defaultProjectTrust: 'never',
      compaction: { enabled: options.autoCompaction ?? false, reserveTokens: options.reserveTokens ?? 1024, keepRecentTokens: options.keepRecentTokens ?? 128 },
      retry: { enabled: false, provider: { maxRetries: options.providerRetries ?? 0 } } });
    const Loader = options.resources || options.resourceSnapshot ? ResolvedResourceLoader : DefaultResourceLoader;
    const loader = new Loader({ cwd: options.cwd, agentDir: options.agentDir, settingsManager: settings,
      ...(options.readOnly ? { extensionFactories: [readOnlyGuard] } : {}),
      noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true });
    await loader.reload();
    const activeTools = options.readOnly ? [...READ_ONLY_TOOLS] : options.tools ?? (options.fixtureEcho ? ['fixture_echo'] : []);
    if (loader instanceof ResolvedResourceLoader) { loader.snapshot = options.resourceSnapshot ?? await options.resources?.resolve(); loader.allowedTools = activeTools; }
    const echo = options.fixtureEcho;
    const result = await createAgentSession({ cwd: options.cwd, agentDir: options.agentDir, modelRuntime: runtime,
      model, thinkingLevel: profile.thinkingLevel ?? 'off', settingsManager: settings, resourceLoader: loader, sessionManager: manager,
      tools: activeTools,
      ...(echo ? { customTools: [{ name: 'fixture_echo', label: 'Fixture echo', description: 'Echo synthetic fixture text.',
        parameters: Type.Object({ text: Type.String() }),
        execute: async (_id, args: { text: string }, signal) => ({ content: [{ type: 'text' as const, text: await echo(args.text, signal) }], details: {} }) }] } : {}),
    });
    if (result.modelFallbackMessage) { result.session.dispose(); throw new Error('Pi attempted a model fallback; explicit profile selection is required'); }
    const {sideBoundary, ...creation} = options;
    adapter = new PiSessionAdapter(result.session, manager, id, creation); adapter.defaultPurpose = options.purpose ?? 'turn';
    adapter.resources = options.resources; if (loader instanceof ResolvedResourceLoader) adapter.resolvedLoader = loader;
    if (sideBoundary) {
      adapter.firstSideTurn = true;
      const { entries, order, resources, ...origin } = sideBoundary;
      adapter.origin = {...origin,instructionRevision:resources?.instructions.revision ?? null};
      manager.appendCustomEntry('pi-app.side.v1', {...adapter.origin, toolPolicy:'read-only', source:'immutable completed Pi context; historical explicit grants are inactive', sessionAffinity:'new Pi session ID; no parent server cursor'});
    } else {
      const origin = manager.getEntries().findLast(e=>e.type==='custom' && e.customType==='pi-app.side.v1');
      if (origin?.type==='custom') adapter.origin = origin.data as typeof adapter.origin;
    }
    adapter.boundaryCache.update(manager, adapter.resolvedLoader?.snapshot);
    return adapter;
  }

  private scheduleBoundary(): void {
    if (this.boundaryScheduled || this.disposed) return; this.boundaryScheduled = true;
    // Pi emits message_end before its synchronous append. Wait one microtask,
    // then read only the persisted entries. Active message arrays are never read.
    queueMicrotask(()=>{this.boundaryScheduled=false;if(!this.disposed && !this.session.isCompacting) this.boundaryCache.update(this.manager,this.resolvedLoader?.snapshot);});
  }
  getSideBoundary(): SideBoundary { return this.boundaryCache.get(); }
  takeDisplayObservation(): number | null { const value=this.displayObservedAt;this.displayObservedAt=undefined;return value??null; }
  async createSide(sessionId: string, boundary = this.getSideBoundary()): Promise<PiSessionAdapter> {
    const {sessionDirectory,resumePath,fixtureEcho,handoff,resourceSnapshot,...base} = this.creation;
    return PiSessionAdapter.create({...base,sessionId,sideBoundary:boundary,readOnly:true,tools:[...READ_ONLY_TOOLS],purpose:'turn',
      ...(boundary.resources ? {resourceSnapshot:boundary.resources} : {})});
  }
  sideInfo(): unknown { return this.origin ? {...this.origin,instructionsRefreshed: this.resolvedLoader?.snapshot?.instructions.revision !== this.origin.instructionRevision} : null; }
  async prepareKeep(directory: string): Promise<{adapter:PiSessionAdapter;path:string}> {
    if (!this.isIdle) throw new Error('Keep requires an idle side');
    const path = await persistMemorySession(this.manager,directory);
    try {
      const {resourceSnapshot,...base}=this.creation;
      const adapter = await PiSessionAdapter.create({...base,sessionDirectory:directory,resumePath:path,sessionId:this.id,
        ...(this.resolvedLoader?.snapshot ? {resourceSnapshot:this.resolvedLoader.snapshot} : {})});
      return {adapter,path};
    } catch (error) { const {rm} = await import('node:fs/promises'); await rm(path,{force:true}); throw error; }
  }

  subscribe(listener: (event: AdapterEvent) => void): () => void { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  get isIdle(): boolean { return !this.busy && this.session.isIdle; }
  get sessionFile(): string | undefined { return this.manager.getSessionFile(); }
  get activeTools(): string[] { return this.session.getActiveToolNames(); }
  get effectiveThinkingLevel(): string { return this.session.thinkingLevel; }
  get runStatus(): string { return this.lifecycle; }

  projection(before: number | null = null, limit = 60): { messages: MessageView[]; before: number | null; total: number } {
    const entries = this.manager.getBranch().filter(entry => entry.type === 'message' || entry.type === 'compaction');
    const end = Math.min(before ?? entries.length, entries.length), messages: MessageView[] = [];
    let bytes = 0, index = end;
    while (index > 0 && messages.length < Math.min(100, limit)) {
      const entry = entries[index - 1]!;
      const message = messageView(entry.id, entry.type === 'message' ? entry.message : entry.type === 'compaction' ?
        { role: 'system', content: `Compaction summary\n${entry.summary}` } : {}, this.toolStates);
      const size = Buffer.byteLength(JSON.stringify(message));
      if (bytes + size > 300_000) break;
      messages.unshift(message); bytes += size; index--;
    }
    if (before === null && this.activeMessage) messages.push(messageView(this.activeMessage.id, this.activeMessage.message, this.toolStates));
    return { messages, before: index > 0 ? index : null, total: entries.length };
  }
  readMessage(id: string, field: 'text' | 'thinking', offset: number): { text: string; totalCharacters: number; next: number | null } {
    const entry = this.manager.getEntry(id);
    if (!entry || entry.type !== 'message') throw new Error('Completed message is unavailable');
    const content = 'content' in entry.message ? entry.message.content : '';
    const text = typeof content === 'string' ? content : Array.isArray(content) ? content.map(block =>
      field === 'thinking' && block.type === 'thinking' ? block.thinking : field === 'text' && block.type === 'text' ? block.text : '').join('') : '';
    return textPage(text,offset);
  }
  searchContent(query: string, start: number) { return searchContent(this.manager.getBranch().filter((e):e is ContentEntry=>e.type==='message'||e.type==='compaction'),query,start); }
  copyContentPage(first:number,last:number,index:number,offset:number,revision:string) {
    return copyContentPage(this.manager.getBranch().filter((e):e is ContentEntry=>e.type==='message'||e.type==='compaction'),first,last,index,offset,revision);
  }

  async submit(text: string, turnId: string = randomUUID(), input?: Submission): Promise<TurnOutcome> {
    if (!this.isIdle) throw new Error('Session already has an active command');
    this.busy = true; this.cancelled = false; this.turnId = turnId; this.purpose = this.defaultPurpose; this.lifecycle = 'running'; this.turnStart = performance.now(); this.turnEnd = null; this.preflightError = null;
    try {
      if (this.resources && this.resolvedLoader) {
        const snapshot = await this.resources.resolve(); validateFrozen(snapshot.catalog, input?.skills ?? [], this.activeTools);
        if (this.firstSideTurn && this.resolvedLoader.snapshot) {
          const instructions = this.resolvedLoader.snapshot.instructions;
          this.resolvedLoader.snapshot = {...snapshot,instructions,revision:digest(JSON.stringify({catalogRevision:snapshot.revision,instructionRevision:instructions.revision}))};
        } else this.resolvedLoader.snapshot = snapshot;
        if (this.creation.readOnly) this.resolvedLoader.allowedTools = [...READ_ONLY_TOOLS];
        // Public Pi API rebuilds its base prompt from current resource getters without
        // reload() resetting the global provider registry used by concurrent sessions.
        this.session.setActiveToolsByName(this.creation.readOnly ? [...READ_ONLY_TOOLS] : this.activeTools);
      }
      this.recordResources(turnId, input?.skills ?? []);
      const images = await readAttachments(input?.attachments ?? []);
      if (this.cancelled) return 'cancelled';
      await this.session.prompt(expandSkills(text, input?.skills ?? [], turnId), { expandPromptTemplates: false, ...(images.length ? { images } : {}) });
      this.firstSideTurn = false;
      const last = this.session.messages.findLast(message => message.role === 'assistant');
      return this.cancelled || last?.stopReason === 'aborted' ? 'cancelled' : last?.stopReason === 'error' ? 'failed' : 'completed';
    }
    catch (error) { if (error instanceof ResourceError) this.preflightError = error.message; throw error; }
    finally { this.busy = false; this.turnId = null; this.turnEnd = performance.now(); this.skillGrants = []; this.scheduleBoundary(); }
  }
  async steer(text: string, attachments: Attachment[] = [], skills: FrozenSkill[] = [], invocationId?: string): Promise<void> {
    if (!this.busy || !this.session.isStreaming || this.session.isCompacting) throw new Error('Steering is unavailable while idle or compacting');
    // Unlike the public steer() convenience method, prompt(..., false) avoids
    // Pi performing a second skill/template expansion on already resolved input.
    const images = await readAttachments(attachments);
    if (this.resources) validateFrozen((await this.resources.resolve()).catalog, skills, this.activeTools);
    if (this.skillGrants.length + skills.length > 32) throw new Error('This turn already reached its 32 explicit skill grant limit');
    if (!this.busy || !this.session.isStreaming || this.cancelled) throw new Error('Steering turn ended while preparing images');
    await this.session.prompt(expandSkills(text, skills, invocationId ?? this.turnId!), { streamingBehavior: 'steer', expandPromptTemplates: false, ...(images.length ? { images } : {}) });
    this.recordResources(invocationId ?? this.turnId!, skills);
  }
  private recordResources(turnId: string, skills: FrozenSkill[]): void {
    const snapshot = this.resolvedLoader?.snapshot;
    const grants = skills.map(({ id, contentHash, metadataHash }) => ({ id, contentHash, metadataHash })); this.skillGrants.push(...grants);
    if (snapshot || grants.length) this.manager.appendCustomEntry('pi-app.resources.v1', { turnId, revision: snapshot?.revision ?? null,
      instructions: snapshot?.instructions.sources.filter(s => s.includedBytes).map(({ path, hash, includedBytes, scope }) => ({ path, hash, includedBytes, scope })) ?? [],
      skills: skills.map(({ body, arguments: args, ...skill }) => ({ ...skill, argumentsSHA256: createHash('sha256').update(args).digest('hex') })), lifetime: 'this accepted turn and its tool loop; historical text grants no new invocation' });
  }
  get appliedResources(): ResourceSnapshot | undefined { return this.resolvedLoader?.snapshot; }
  recordCommand(commandId: string, turnId: string, state: 'dispatched' | TurnOutcome): void {
    this.manager.appendCustomEntry('pi-app.command.v1', { commandId, turnId, state, at: new Date().toISOString() });
  }
  commandHistory(): { commandId: string; turnId: string; state: string }[] {
    return this.manager.getEntries().flatMap(entry => {
      if (entry.type !== 'custom' || entry.customType !== 'pi-app.command.v1' || !entry.data || typeof entry.data !== 'object') return [];
      const data = entry.data as Record<string, unknown>;
      return typeof data.commandId === 'string' && typeof data.turnId === 'string' && typeof data.state === 'string' ?
        [{ commandId: data.commandId, turnId: data.turnId, state: data.state }] : [];
    }).slice(-4096);
  }
  async compact(): Promise<{ summary: string }> {
    if (!this.isIdle) throw new Error('Session already has an active command');
    this.busy = true; this.purpose = 'compaction';
    try { const result = await this.session.compact(); return { summary: result.summary }; }
    finally { this.busy = false; this.purpose = 'turn'; }
  }
  async abort(): Promise<void> { if (this.busy) this.cancelled = true; this.session.clearQueue(); await this.session.abort(); }
  provenance(): unknown {
    const entries = this.manager.getEntries().filter(e => e.type === 'custom' && ['pi-app.profile.v1', 'pi-app.import.v1', 'pi-app.handoff.v1', 'pi-app.resources.v1', 'pi-app.side.v1'].includes(e.customType)).slice(-16);
    const result: unknown[] = []; let bytes = 0;
    for (const entry of entries.reverse()) {
      const size = Buffer.byteLength(JSON.stringify(entry));
      if (bytes + size > 131072) { result.unshift({ id: entry.id, previewOmitted: true, reason: 'Provenance preview budget; full custom entry is retained in the Pi file' }); continue; }
      bytes += size; result.unshift(entry);
    }
    return result;
  }
  contextUsage(): unknown { const usage = this.session.getContextUsage(); return { tokens:null,contextWindow:this.creation.profile.contextWindow, ...usage, outputReserve:this.creation.profile.maxOutputTokens, state: usage?.tokens == null ? this.manager.getEntries().some(e => e.type === 'compaction') ? 'post-compaction' : 'unknown' : this.busy ? 'stale-estimate' : 'estimated', source: 'Pi current-context estimate', capacitySource: 'configured' }; }
  turnMetrics(): unknown { return { elapsedMs: this.turnStart === null ? null : (this.turnEnd ?? performance.now()) - this.turnStart, includes: 'tools, waits, retries and all model calls', state: this.busy ? 'running' : 'settled' }; }
  sessionUsage(): unknown { const stats = this.session.getSessionStats(); return { ...stats, source: 'Pi cumulative session consumption; not current context' }; }
  snapshot(): { role: string; text: string; stopReason?: string; toolNames: string[] }[] {
    return this.session.messages.map(message => {
      const content = 'content' in message ? message.content : 'summary' in message ? message.summary : '';
      return { role: message.role,
      text: typeof content === 'string' ? content : Array.isArray(content) ?
        content.map(block => block.type === 'text' ? block.text : '').join('') : '',
      ...('stopReason' in message ? { stopReason: message.stopReason } : {}),
      toolNames: Array.isArray(content) ? content.flatMap(block => block.type === 'toolCall' ? [block.name] : []) : [],
    }; });
  }
  async dispose(): Promise<void> { this.disposed = true; await this.abort(); this.unsubscribe(); this.session.dispose(); this.listeners.clear(); }
}
