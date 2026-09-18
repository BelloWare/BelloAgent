import type { Message, Tool } from './message-model.ts';
import { uncachedInput } from './message-accounting.tsx';

export type ActionKind = 'command' | 'read' | 'write' | 'search' | 'list' | 'mcp' | 'other';
export interface ActionDescription { kind: ActionKind; verb: string; object: string; path?: string }

function parseInput(tool: Tool): Record<string, unknown> {
  try { const value: unknown = JSON.parse(tool.input); return typeof value === 'object' && value !== null ? value as Record<string, unknown> : {}; }
  catch { return {}; }
}
function shortPath(path: string): string {
  const parts = path.split('/').filter(Boolean);
  return parts.length > 2 ? parts.slice(-2).join('/') : path;
}
function firstLine(text: string, max = 96): string {
  const line = text.split('\n')[0]?.trim() ?? '';
  return line.length > max ? line.slice(0, max - 1) + '…' : line;
}
const text = (value: unknown): string | undefined => typeof value === 'string' && value.length > 0 ? value : undefined;

/** Where a call stands, as the transcript reads it. */
export type ActionOutcome = 'running' | 'done' | 'failed' | 'cancelled';
export function actionOutcome(tool: Tool): ActionOutcome {
  if (['running', 'preparing', 'prepared'].includes(tool.state)) return 'running';
  if (tool.state === 'cancelled') return 'cancelled';
  if (tool.state === 'failed') return 'failed';
  return 'done';
}
/** "Edited" once done, "Editing" under way, "Failed editing" or "Skipped editing" otherwise: the verb never claims work that did not happen. */
function conjugate(done: string, doing: string, outcome: ActionOutcome): string {
  switch (outcome) {
    case 'running': return doing.charAt(0).toUpperCase() + doing.slice(1);
    case 'failed': return 'Failed ' + doing;
    case 'cancelled': return 'Skipped ' + doing;
    default: return done;
  }
}

/** One verb-and-object line per tool call, like "Ran npm test", "Editing retry.swift" or "Failed reading notes.md". */
export function describeTool(tool: Tool): ActionDescription {
  const input = parseInput(tool);
  const path = text(tool.path) ?? text(input.path);
  const outcome = actionOutcome(tool);
  const verb = (done: string, doing: string): string => conjugate(done, doing, outcome);
  const at = path ? { path } : {};
  switch (tool.name) {
    case 'bash': return { kind: 'command', verb: verb('Ran', 'running'), object: firstLine(text(input.command) ?? tool.input) || 'command' };
    case 'read': return { kind: 'read', verb: verb('Read', 'reading'), object: path ? shortPath(path) : 'file', ...at };
    case 'write': return { kind: 'write', verb: verb(tool.added != null && (tool.removed ?? 0) === 0 ? 'Created' : 'Wrote', 'writing'), object: path ? shortPath(path) : 'file', ...at };
    case 'edit': return { kind: 'write', verb: verb('Edited', 'editing'), object: path ? shortPath(path) : 'file', ...at };
    case 'ls': return { kind: 'list', verb: verb('Listed', 'listing'), object: path ? shortPath(path) : 'directory', ...at };
    case 'find': case 'grep': return { kind: 'search', verb: verb('Searched', 'searching'), object: text(input.pattern) ?? 'files' };
    case 'mcp': {
      // The meta-tool's action says what happened: a server list, schema loads or one invocation.
      const action = text(input.action) ?? 'invoke', server = text(input.server);
      if (action === 'list') return { kind: 'mcp', verb: verb('Listed', 'listing'), object: server ? `tools on ${server}` : 'MCP servers' };
      if (action === 'describe') { const count = Array.isArray(input.targets) ? input.targets.length : 0; return { kind: 'mcp', verb: verb('Loaded', 'loading'), object: count ? `${count} tool ${count === 1 ? 'schema' : 'schemas'}` : 'tool schemas' }; }
      return { kind: 'mcp', verb: verb('Called', 'calling'), object: `${server ?? 'server'} · ${text(input.tool) ?? 'call'}` };
    }
    default: return { kind: 'other', verb: verb('Used', 'using'), object: tool.name };
  }
}

/** A file's identity for counting: its path, else the call itself, so nothing is merged by guesswork. */
const fileKey = (description: ActionDescription, tool: Tool): string => description.path ?? `${description.object}#${tool.id}`;
/**
 * The collapsed one-line summary of a run of tool calls: distinct files for
 * edits, reads and listings, counts for the rest, then what failed or was
 * skipped. Only completed calls count as work done; a running one waits for
 * its outcome.
 */
export function summarizeActivity(tools: Tool[]): string {
  const files = { write: new Set<string>(), read: new Set<string>(), list: new Set<string>() };
  const counts = { command: 0, search: 0, mcp: 0, other: 0 };
  let failed = 0, cancelled = 0;
  for (const tool of tools) {
    const outcome = actionOutcome(tool);
    if (outcome === 'failed') { failed += 1; continue; }
    if (outcome === 'cancelled') { cancelled += 1; continue; }
    if (outcome === 'running') continue;
    const description = describeTool(tool);
    if (description.kind === 'write' || description.kind === 'read' || description.kind === 'list') files[description.kind].add(fileKey(description, tool));
    else counts[description.kind] += 1;
  }
  const plural = (n: number, one: string, many: string): string => `${n} ${n === 1 ? one : many}`;
  const parts: string[] = [];
  if (files.write.size) parts.push(`edited ${plural(files.write.size, 'file', 'files')}`);
  if (counts.command) parts.push(`ran ${plural(counts.command, 'command', 'commands')}`);
  if (files.read.size) parts.push(`read ${plural(files.read.size, 'file', 'files')}`);
  if (files.list.size) parts.push(`listed ${plural(files.list.size, 'directory', 'directories')}`);
  if (counts.search) parts.push(counts.search === 1 ? 'searched once' : `searched ${counts.search} times`);
  if (counts.mcp) parts.push(`called ${plural(counts.mcp, 'tool', 'tools')}`);
  if (counts.other) parts.push(`used ${plural(counts.other, 'tool', 'tools')}`);
  if (failed) parts.push(`${plural(failed, 'call', 'calls')} failed`);
  if (cancelled) parts.push(`${plural(cancelled, 'call', 'calls')} skipped`);
  const joined = parts.join(', ');
  return joined.charAt(0).toUpperCase() + joined.slice(1);
}
/** Distinct files that completed write or edit calls touched. */
export function changedFiles(tools: Tool[]): number {
  const files = new Set<string>();
  for (const tool of tools) { if (actionOutcome(tool) !== 'done') continue; const description = describeTool(tool); if (description.kind === 'write') files.add(fileKey(description, tool)); }
  return files.size;
}

export type ActivityState = 'running' | 'failed' | 'completed';
export function activityState(tools: Tool[]): ActivityState {
  if (tools.some(tool => ['running', 'preparing', 'prepared'].includes(tool.state))) return 'running';
  if (tools.some(tool => ['failed', 'cancelled'].includes(tool.state))) return 'failed';
  return 'completed';
}

export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '';
  if (ms < 1_000) return `${(ms / 1000).toFixed(1)}s`;
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60), rest = seconds % 60;
  if (minutes < 60) return rest ? `${minutes}m ${rest}s` : `${minutes}m`;
  const hours = Math.floor(minutes / 60), restMinutes = minutes % 60;
  return restMinutes ? `${hours}h ${restMinutes}m` : `${hours}h`;
}

/**
 * One prose reply and the work that produced it: the reasoning-only and
 * tool-only replies before it, plus its own reasoning and tool calls. A
 * trailing block with no prose holds work the turn ended on (a cancelled or
 * still-running tool round). Tool-result rows disappear; their output lives
 * on the call. Model time is the gap between a message and the assistant
 * reply after it; tool time is the sum of recorded tool durations.
 */
export interface Block {
  id: string; message: Message | null; activity: Message[]; tools: Tool[];
  /** Stays the id of the block's first row for its whole life, so React keeps the block mounted (and open) as its reply arrives. */
  key: string;
  /** The host's turn id for the block's rows, when the rows carry one. */
  turnID: string | null;
  /** The block's own requests' usage: its activity replies plus its reply. */
  accounting: TurnAccounting;
  startedAt: number | null; endedAt: number | null; modelMs: number; toolMs: number; live: boolean;
  /** Set on the last block of every turn: the whole turn's figures, live ones included. */
  turn?: TurnSummary;
}
/** Gateway-reported usage summed over a turn's (or a reply's) requests; a figure is null when no request reported it. */
export interface TurnAccounting {
  requests: number;
  input: number | null; inputSamples: number; cached: number | null; cachedSamples: number; uncached: number | null; uncachedSamples: number;
  output: number | null; outputSamples: number; reasoning: number | null; reasoningSamples: number; total: number | null; totalSamples: number;
  costUSD: number | null; costSamples: number;
  /** The last reported model name, and the request it came from, for the reply line's model link. */
  model: string | null; modelMessageID: string | null;
}
/** Everything the assistant did since the user's message, across every reply of the turn. */
export interface TurnSummary {
  replies: number; tools: number; startedAt: number | null; endedAt: number | null; elapsedMs: number | null; modelMs: number; toolMs: number; live: boolean;
  /** Distinct files that completed edits and writes touched. */
  files: number;
  /** True when the host's turn id shows the turn began before the loaded history. */
  partial: boolean;
  accounting: TurnAccounting;
  /** The turn's replies that carry gateway accounting, in order, for the expanded per-request rows. */
  requests: Message[];
  /** While live: the tool call under way, if any. */
  current: Tool | null;
  /** While live: a status the host attached to the turn, such as a retry in progress. */
  notice: string | null;
}
/** "21:17:41" in local time, for hover stamps. */
export function formatClock(ms: number): string {
  const date = new Date(ms);
  return [date.getHours(), date.getMinutes(), date.getSeconds()].map(part => String(part).padStart(2, '0')).join(':');
}
/** The first sentence of exposed reasoning, bounded, for the reply line's teaser. */
export function reasoningTeaser(text: string, max = 90): string | null {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (!flat) return null;
  const sentence = flat.match(/^.*?[.!?](\s|$)/)?.[0]?.trim() ?? flat;
  return sentence.length > max ? sentence.slice(0, max - 1).trimEnd() + '…' : sentence;
}
export interface DiffRow { kind: 'context' | 'removed' | 'added'; text: string }
/** A line diff for an edit's old and new text: a bounded longest-common-subsequence, else a plain replace. */
export function lineDiff(before: string, after: string, limit = 300): DiffRow[] {
  const a = before.split('\n'), b = after.split('\n');
  if (a.length > limit || b.length > limit) return [...a.map(text => ({ kind: 'removed' as const, text })), ...b.map(text => ({ kind: 'added' as const, text }))];
  const lengths: number[][] = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) lengths[i]![j] = a[i] === b[j] ? lengths[i + 1]![j + 1]! + 1 : Math.max(lengths[i + 1]![j]!, lengths[i]![j + 1]!);
  const rows: DiffRow[] = [];
  let i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { rows.push({ kind: 'context', text: a[i]! }); i++; j++; }
    else if (lengths[i + 1]![j]! >= lengths[i]![j + 1]!) { rows.push({ kind: 'removed', text: a[i]! }); i++; }
    else { rows.push({ kind: 'added', text: b[j]! }); j++; }
  }
  while (i < a.length) rows.push({ kind: 'removed', text: a[i++]! });
  while (j < b.length) rows.push({ kind: 'added', text: b[j++]! });
  return rows;
}
/** The tool's edit as old and new text, when it is a file edit or write. */
export function editTexts(tool: Tool): { before: string; after: string } | null {
  let input: Record<string, unknown>;
  try { const value: unknown = JSON.parse(tool.input); input = typeof value === 'object' && value !== null ? value as Record<string, unknown> : {}; } catch { return null; }
  if (tool.name === 'edit' && typeof input.oldText === 'string' && typeof input.newText === 'string') return { before: input.oldText, after: input.newText };
  if (tool.name === 'write' && typeof input.content === 'string') return { before: '', after: input.content };
  return null;
}

const reported = (value: number | null | undefined): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0;
/** Sums only what each request reported; partial coverage stays visible through the sample counts. */
export function aggregateAccounting(messages: Message[]): TurnAccounting {
  const sum: TurnAccounting = { requests: 0, input: null, inputSamples: 0, cached: null, cachedSamples: 0, uncached: null, uncachedSamples: 0, output: null, outputSamples: 0, reasoning: null, reasoningSamples: 0, total: null, totalSamples: 0, costUSD: null, costSamples: 0, model: null, modelMessageID: null };
  type Field = 'input' | 'cached' | 'uncached' | 'output' | 'reasoning' | 'total' | 'costUSD';
  const add = (field: Field, value: number | null | undefined, samples: number) => {
    if (samples > 0 && reported(value)) { sum[field] = (sum[field] ?? 0) + value; sum[`${field === 'costUSD' ? 'cost' : field}Samples` as 'inputSamples'] += samples; }
  };
  for (const message of messages) {
    const a = message.accounting; if (!a) continue;
    sum.requests += a.requests;
    add('input', a.tokens?.input, a.tokens?.inputSamples ?? 0);
    add('output', a.tokens?.output, a.tokens?.outputSamples ?? 0);
    add('reasoning', a.tokens?.reasoning, a.tokens?.reasoningSamples ?? 0);
    add('total', a.tokens?.total, a.tokens?.samples ?? 0);
    add('cached', a.cacheReadTokens, a.cacheReadSamples);
    const uncached = uncachedInput(a);
    if (uncached !== null) add('uncached', uncached, a.uncachedInputSamples ?? a.requests);
    add('costUSD', a.costUSD, a.costSamples);
    const name = a.models?.names[0];
    if (name) { sum.model = name; sum.modelMessageID = message.id; }
  }
  return sum;
}
/** Tokens as counted: exact with grouping under ten thousand, compact above. */
export function formatTokenCount(value: number): string {
  return value < 10_000 ? Math.round(value).toLocaleString('en-US') : formatCompactTokens(value);
}
/** The tokens of a summary, preferring the reported total, else input plus output. */
export function tokensOf(a: TurnAccounting): number | null {
  return a.total != null ? a.total : a.input != null || a.output != null ? (a.input ?? 0) + (a.output ?? 0) : null;
}
/** "in 1,200 · 300 cached · 900 uncached · out 200 · 50 reasoning · $0.0041", each figure with its coverage when partial. */
export function usageBreakdown(a: TurnAccounting): string {
  const coverage = (samples: number): string => samples < a.requests ? ` (${samples}/${a.requests})` : '';
  return [
    a.input != null ? `in ${formatTokenCount(a.input)}${coverage(a.inputSamples)}` : null,
    a.cached != null ? `${formatTokenCount(a.cached)} cached${coverage(a.cachedSamples)}` : null,
    a.uncached != null ? `${formatTokenCount(a.uncached)} uncached${coverage(a.uncachedSamples)}` : null,
    a.output != null ? `out ${formatTokenCount(a.output)}${coverage(a.outputSamples)}` : null,
    a.reasoning != null ? `${formatTokenCount(a.reasoning)} reasoning${coverage(a.reasoningSamples)}` : null,
    a.costUSD != null ? `${formatTurnCost(a.costUSD)}${coverage(a.costSamples)}` : null,
  ].filter(Boolean).join(' · ');
}
export function formatCompactTokens(value: number): string {
  if (value < 1_000) return `${Math.round(value)}`;
  if (value < 10_000) return `${(value / 1_000).toFixed(1).replace(/\.0$/, '')}k`;
  if (value < 1_000_000) return `${Math.round(value / 1_000)}k`;
  return `${(value / 1_000_000).toFixed(2).replace(/\.?0+$/, '')}M`;
}
export function formatTurnCost(value: number): string {
  if (value === 0) return '$0';
  if (value >= 1) return `$${value.toFixed(2)}`;
  if (value >= 0.01) return `$${value.toFixed(3)}`;
  return `$${value.toFixed(5).replace(/0+$/, '')}`;
}
export type TranscriptItem = { kind: 'message'; message: Message } | { kind: 'block'; block: Block };

const isStreaming = (message: Message): boolean => message.state === 'streaming' || message.id.startsWith('stream:');
/** A reply with no prose: only tool calls, exposed reasoning, or both. It folds into the next reply's block. */
export const activityOnly = (message: Message): boolean =>
  message.role === 'assistant' && !message.text.trim() && ((message.tools?.length ?? 0) > 0 || (message.thinking ?? '').trim().length > 0);
/** Whether any reply in the block exposed reasoning. */
export const blockReasoned = (block: Block): boolean =>
  [...block.activity, ...(block.message ? [block.message] : [])].some(message => (message.thinking ?? '').trim().length > 0);
/** "Reasoned", "Read 1 file" or "Reasoned, read 1 file, ran 2 commands". */
export function summarizeWork(tools: Tool[], reasoned: boolean): string | null {
  const work = tools.length ? summarizeActivity(tools) : null;
  if (!reasoned) return work;
  return work ? 'Reasoned, ' + work.charAt(0).toLowerCase() + work.slice(1) : 'Reasoned';
}

export function blocksOf(messages: Message[]): TranscriptItem[] {
  const items: TranscriptItem[] = [];
  let lastAt: number | null = null;
  let pending: Block | null = null;
  const open = (id: string): Block => ({ id, key: id, turnID: null, message: null, activity: [], tools: [], accounting: aggregateAccounting([]), startedAt: lastAt, endedAt: lastAt, modelMs: 0, toolMs: 0, live: false });
  const flush = () => {
    if (pending && (pending.message || pending.activity.length)) { pending.accounting = aggregateAccounting([...pending.activity, ...(pending.message ? [pending.message] : [])]); items.push({ kind: 'block', block: pending }); }
    pending = null;
  };
  const observe = (message: Message, block: Block) => {
    if (message.turn && !block.turnID) block.turnID = message.turn;
    if (isStreaming(message)) block.live = true;
    // The host's own measurement of the request wins; the gap between rows is the fallback for older journals.
    else if (message.modelMs != null) block.modelMs += message.modelMs;
    else if (message.at != null && lastAt != null && message.at >= lastAt) block.modelMs += message.at - lastAt;
    for (const tool of message.tools ?? []) { block.tools.push(tool); if (tool.durationMs != null) block.toolMs += tool.durationMs; }
    if (message.at != null) { lastAt = message.at; block.endedAt = message.at; }
  };
  for (const message of messages) {
    if (message.role === 'tool') { if (message.at != null) { lastAt = message.at; if (pending) pending.endedAt = message.at; } continue; }
    if (message.role === 'assistant' && !message.kind) {
      const block: Block = pending ?? open('block:' + message.id);
      pending = block;
      if (activityOnly(message)) { block.activity.push(message); observe(message, block); continue; }
      observe(message, block);
      block.message = message; block.id = message.id;
      flush();
      continue;
    }
    flush();
    items.push({ kind: 'message', message });
    if (message.at != null) lastAt = message.at;
  }
  flush();
  attachTurns(items);
  // A status the host appended during a live turn (a retry in progress) belongs in the turn's live bar, not in a row of its own.
  const tail = items[items.length - 1], before = items[items.length - 2];
  if (tail?.kind === 'message' && tail.message.kind === 'notice' && before?.kind === 'block' && before.block.turn?.live) {
    before.block.turn.notice = tail.message.text; items.pop();
  }
  return items;
}

/**
 * A turn is the run of blocks since the user's message; its last block carries
 * the turn's totals. Blocks whose rows name a different host turn start a new
 * one. Status rows the host or app add mid-run (a compaction summary, a retry
 * notice, a failure) do not end the turn; only a user row or a plain system row does.
 */
function attachTurns(items: TranscriptItem[]): void {
  let group: Block[] = [];
  let lastUser: string | null = null, groupUser: string | null = null;
  const close = () => {
    if (group.length > 0) {
      const first = group[0]!, last = group[group.length - 1]!;
      const partial = first.turnID != null && first.turnID !== groupUser;
      const requests = group.flatMap(block => [...block.activity, ...(block.message ? [block.message] : [])]).filter(message => message.accounting);
      const live = group.some(block => block.live);
      last.turn = {
        replies: group.length,
        tools: group.reduce((count, block) => count + block.tools.length, 0),
        accounting: aggregateAccounting(requests), requests,
        current: live ? last.tools.findLast(tool => ['running', 'preparing', 'prepared'].includes(tool.state)) ?? null : null,
        notice: null,
        startedAt: first.startedAt, endedAt: last.endedAt,
        elapsedMs: first.startedAt != null && last.endedAt != null && last.endedAt >= first.startedAt ? last.endedAt - first.startedAt : null,
        modelMs: group.reduce((sum, block) => sum + block.modelMs, 0),
        toolMs: group.reduce((sum, block) => sum + block.toolMs, 0),
        live: group.some(block => block.live),
        files: changedFiles(group.flatMap(block => block.tools)),
        partial,
      };
    }
    group = [];
  };
  for (const item of items) {
    if (item.kind === 'block') {
      const first = group[0];
      if (first && first.turnID != null && item.block.turnID != null && first.turnID !== item.block.turnID) close();
      if (group.length === 0) groupUser = lastUser;
      group.push(item.block);
    } else if (item.message.role === 'user' || !item.message.kind) {
      close();
      if (item.message.role === 'user') lastUser = item.message.turn ?? item.message.id;
    }
  }
  close();
}
