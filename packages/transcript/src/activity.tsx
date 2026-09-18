import { useEffect, useState, type ReactNode } from 'react';
import { MessageMarkdown, MessageRow } from './message-row.tsx';
import { MessageAccounting } from './message-accounting.tsx';
import type { Message, NotifyMessageAction, Tool } from './message-model.ts';
import { actionOutcome, activityState, blockReasoned, describeTool, editTexts, formatClock, formatDuration, formatTurnCost, formatTokenCount, lineDiff, reasoningTeaser, summarizeWork, tokensOf, usageBreakdown, type ActionKind, type ActionOutcome, type Block, type TranscriptItem, type TurnSummary } from './activity.ts';

/** Re-renders once a second while `active`, for durations that count up. */
function useTicker(active: boolean): void {
  const [, setTick] = useState(0);
  useEffect(() => {
    if (!active) return;
    const timer = window.setInterval(() => setTick(value => value + 1), 1_000);
    return () => window.clearInterval(timer);
  }, [active]);
}

const ICONS: Record<ActionKind, ReactNode> = {
  command: <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 4.5 6.5 8 3 11.5M8 12h5" /></svg>,
  write: <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M10.5 2.5 13.5 5.5 6 13H3v-3z" /></svg>,
  read: <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2h5l3 3v9H4zM9 2v3h3" /></svg>,
  list: <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 4h5l1.5 1.5H14V13H2z" /></svg>,
  search: <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4" /><path d="m10 10 3.5 3.5" /></svg>,
  mcp: <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v3M8 11v3M2 8h3M11 8h3" /><circle cx="8" cy="8" r="2.5" /></svg>,
  other: <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5" /></svg>,
};
const Chevron = () => <svg className="chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4" /></svg>;
/** A small ring that turns while something is under way. */
export const Spinner = ({ label }: { label?: string }) => <span className="spinner" role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true} />;

/**
 * What the model asked a file tool to change, as tinted rows like the Changes
 * sheet. It is the request, not proof of what is on disk: the label says so,
 * and a failed or skipped call never reads as an applied change. A write shows
 * its requested content plainly unless the tool confirmed it created the file.
 */
function EditDiff({ before, after, path, mode, outcome, created }: { before: string; after: string; path: string | null; mode: 'edit' | 'write'; outcome: ActionOutcome; created: boolean }) {
  const rows = mode === 'edit' || (created && outcome === 'done') ? lineDiff(before, after) : after.split('\n').map(text => ({ kind: 'context' as const, text }));
  const shown = rows.slice(0, 400);
  const label = (mode === 'edit' ? 'Requested edit' : 'Requested content') + (outcome === 'done' ? '' : outcome === 'running' ? ' · in progress' : mode === 'edit' ? ' · not applied' : ' · not written');
  return <div className={`edit-diff ${outcome}`}>
    <div className="edit-diff-head"><span className="edit-diff-label">{label}</span>{path && <span className="edit-diff-path">{path}</span>}</div>
    <div className="edit-diff-rows">
      {shown.map((row, index) => <div key={index} className={`diff-row ${row.kind}`}><span className="diff-marker" aria-hidden="true">{row.kind === 'added' ? '+' : row.kind === 'removed' ? '−' : ' '}</span><span className="diff-text">{row.text || ' '}</span></div>)}
      {rows.length > shown.length && <div className="diff-row context"><span className="diff-marker" aria-hidden="true"> </span><span className="diff-text">… {rows.length - shown.length} more lines</span></div>}
    </div>
  </div>;
}

export function ActionRow({ tool }: { tool: Tool }) {
  const description = describeTool(tool);
  const edit = editTexts(tool);
  const failed = ['failed', 'cancelled'].includes(tool.state), running = ['running', 'preparing', 'prepared'].includes(tool.state);
  const status = running ? 'Running' : failed ? (tool.state === 'cancelled' ? 'Cancelled' : 'Failed') : 'Success';
  const command = description.kind === 'command' ? description.object : null;
  return <li className={`action ${description.kind} ${tool.state}`}>
    <details>
      <summary>
        <span className="action-icon">{ICONS[description.kind]}</span>
        <span className="action-verb">{description.verb}</span>
        <span className={description.kind === 'command' ? 'action-object mono' : 'action-object'} title={description.path ?? description.object}>{description.object}</span>
        {(tool.added != null || tool.removed != null) && <span className="action-diff"><span className="added">+{tool.added ?? 0}</span> <span className="removed">-{tool.removed ?? 0}</span></span>}
        {failed && <span className="action-state failed">{status}</span>}
        {running && <span className="action-state running">Running…</span>}
        {tool.durationMs != null && !running && <span className="action-duration">{formatDuration(tool.durationMs)}</span>}
      </summary>
      <div className="action-card">
        <div className="action-card-kind">{description.kind === 'command' ? 'Shell' : tool.name}</div>
        {command ? <pre className="action-command">$ {tool.input && parseCommand(tool.input) ? parseCommand(tool.input) : command}</pre>
          : edit ? <EditDiff before={edit.before} after={edit.after} path={description.path ?? null} mode={tool.name === 'write' ? 'write' : 'edit'} outcome={actionOutcome(tool)} created={tool.added != null && (tool.removed ?? 0) === 0} />
          : <pre className="action-input" aria-label="Tool input">{tool.input}</pre>}
        {tool.output ? <pre className="action-output" aria-label="Tool output">{tool.output}</pre> : <p className="action-empty">No output</p>}
        {tool.truncated && <p className="notice">Preview truncated. The full result is retained in context.</p>}
        <div className={`action-status ${running ? 'running' : failed ? 'failed' : 'ok'}`}>{running ? '⟳' : failed ? '✕' : '✓'} {status}</div>
      </div>
    </details>
  </li>;
}
function parseCommand(input: string): string | null {
  try { const value: unknown = JSON.parse(input); return typeof value === 'object' && value !== null && typeof (value as { command?: unknown }).command === 'string' ? (value as { command: string }).command : null; }
  catch { return null; }
}

/** The expanded list of one run of tool calls; each row opens its own card. */
export function ActivityGroup({ tools }: { tools: Tool[] }) {
  return <section className={`activity ${activityState(tools)}`} aria-label="Tool activity">
    <ul className="activity-list">{tools.map(tool => <ActionRow key={tool.id} tool={tool} />)}</ul>
  </section>;
}

function Reasoning({ message, notify }: { message: Message; notify: NotifyMessageAction }) {
  if (!(message.thinking ?? '').trim()) return null;
  return <details className="reasoning"><summary>Exposed reasoning</summary><div className="body"><MessageMarkdown message={message} field="thinking" notify={notify} /></div></details>;
}

/**
 * The line under each reply: what it did ("Reasoned, read 1 file"), how long
 * it took, its tokens, cost and model, all in view. The chevron folds the bulky
 * parts: reasoning, the tool call rows and each request's full accounting.
 * While the reply is live the docked turn bar carries the spinner, the current
 * action and Stop; this line only lists work already done, with the last few
 * actions beneath it.
 */
export function BlockView({ block, notify, now, fresh = false }: { block: Block; notify: NotifyMessageAction; now?: (() => number) | undefined; fresh?: boolean }) {
  const [open, setOpen] = useState(false);
  useTicker(block.live);
  const clock = now ?? Date.now;
  const reasoned = blockReasoned(block);
  const hasWork = block.tools.length > 0 || reasoned;
  const summary = summarizeWork(block.tools, reasoned);
  const a = block.accounting;
  const tokens = tokensOf(a);
  const settledMs = block.startedAt != null && block.endedAt != null && block.endedAt >= block.startedAt ? block.endedAt - block.startedAt : null;
  const elapsed = block.live && block.startedAt != null ? Math.max(settledMs ?? 0, clock() - block.startedAt) : settledMs;
  const hasUsage = tokens != null || a.costUSD != null || a.model != null;
  const expandable = hasWork || a.requests > 0;
  // A settled one-reply turn has one line: the reply's work and the turn's figures together.
  const merged = block.turn != null && block.turn.replies === 1 && !block.turn.live;
  const turn = block.turn;
  // While live, the last few actions stay in view so a long run reads as progress rather than silence.
  const trail = block.live ? block.tools.slice(-3) : [];
  const showFooter = block.live ? summary != null || trail.length > 0 : hasWork || hasUsage || merged;
  const usageTitle = a.requests > 0 ? usageBreakdown(a) : undefined;
  const stamps = merged && turn ? [turn.startedAt != null ? `Started ${formatClock(turn.startedAt)}` : null, turn.endedAt != null ? `finished ${formatClock(turn.endedAt)}` : null].filter(Boolean).join(' · ') : '';
  const teaser = reasoned && !open ? reasoningTeaser([...block.activity, ...(block.message ? [block.message] : [])].map(message => message.thinking ?? '').filter(text => text.trim()).pop() ?? '') : null;
  const mergedUsage = merged && turn ? usageBreakdown(turn.accounting) : '';
  // A turn that has just settled glows for a moment so the eye finds where it ended.
  const settled = fresh && !block.live;
  const toggle = () => setOpen(value => !value);
  const inspect = (event: { stopPropagation(): void }) => { event.stopPropagation(); void notify('inspectRequests', { id: a.modelMessageID ?? block.id }); };
  return <div className={`block${block.live ? ' live' : ''}${open ? ' expanded' : ''}${fresh ? ' fresh' : ''}`} data-block-id={block.id}>
    {block.message && <MessageRow message={block.message} notify={notify} inlineAccounting={false} fresh={fresh} />}
    {showFooter && <div className={`block-footer${merged ? ' merged-turn' : ''}${merged && settled ? ' settled' : ''}${expandable ? ' expandable' : ''}`} title={stamps || undefined}>
      {/* The figures flow like text and wrap between their dots; the whole line toggles on click, the chevron is the keyboard control, and the model link is a sibling of both. */}
      <span className="block-line" onClick={expandable ? toggle : undefined}>
        {merged && <span className="turn-label" title={turn?.partial ? 'Earlier replies of this turn are above the loaded history' : undefined}>{turn?.partial ? 'Turn (partial)' : 'Turn'}</span>}
        {summary && <span className="block-summary">{summary}</span>}
        {elapsed != null && <span className="block-duration">{formatDuration(elapsed)}</span>}
        {merged && turn && (turn.modelMs > 0 || turn.toolMs > 0) && <span className="block-split">model {formatDuration(turn.modelMs)} · tools {formatDuration(turn.toolMs)}</span>}
        {merged ? (mergedUsage && <span className="block-usage turn-usage">{mergedUsage}</span>) : <>
          {tokens != null && <span className="block-usage" title={usageTitle}>{formatTokenCount(tokens)} tokens</span>}
          {a.costUSD != null && <span className="block-usage" title={usageTitle}>{formatTurnCost(a.costUSD)}{a.costSamples < a.requests ? ` (${a.costSamples}/${a.requests})` : ''}</span>}
        </>}
        {a.model && <span className="block-model-segment"><span className="message-model-link block-model" role="link" tabIndex={0} onClick={inspect} onKeyDown={event => { if (event.key === 'Enter') inspect(event); }} aria-label={`View model reports: ${a.model}`} title="View response-body and header models">{a.model}</span></span>}
      </span>
      {expandable && <button type="button" className="block-toggle" aria-expanded={open} onClick={event => { event.stopPropagation(); toggle(); }}
        aria-label={open ? 'Hide reasoning, tool calls and request details' : 'Show reasoning, tool calls and request details'} title={open ? 'Hide reasoning, tool calls and request details' : 'Show reasoning, tool calls and request details'}><Chevron /></button>}
      {teaser && <div className="block-teaser" title="The reply's exposed reasoning begins like this; expand the line for all of it">{teaser}</div>}
      {trail.length > 0 && <ul className="action-trail" aria-label="Recent actions">
        {trail.map(tool => { const d = describeTool(tool); const outcome = actionOutcome(tool);
          return <li key={tool.id} className={`trail-item ${outcome === 'running' ? 'running' : outcome === 'done' ? 'done' : 'failed'}`}>{outcome === 'running' ? <Spinner /> : <span className="trail-mark" aria-hidden="true">{outcome === 'done' ? '✓' : '✕'}</span>}<span className="action-verb">{d.verb}</span> <span className={d.kind === 'command' ? 'mono' : ''}>{d.object}</span></li>; })}
      </ul>}
      {open && expandable && <div className="block-details">
        {block.activity.map(message => <div className="block-step" key={message.id} data-message-id={message.id}>
          <Reasoning message={message} notify={notify} />
          {message.tools && message.tools.length > 0 && <ActivityGroup tools={message.tools} />}
          {message.accounting && <MessageAccounting accounting={message.accounting} onInspect={() => { void notify('inspectRequests', { id: message.id }); }} />}
        </div>)}
        {block.message && <div className="block-step">
          <Reasoning message={block.message} notify={notify} />
          {block.message.tools && block.message.tools.length > 0 && <ActivityGroup tools={block.message.tools} />}
          {block.message.accounting && <MessageAccounting accounting={block.message.accounting} onInspect={() => { void notify('inspectRequests', { id: block.message!.id }); }} />}
        </div>}
      </div>}
    </div>}
    {block.turn && !merged && <TurnTotals turn={block.turn} now={now} notify={notify} settled={settled} />}
  </div>;
}

/**
 * Under the last reply of every turn, a summary with nothing to expand: how
 * long the whole turn took, its replies and tool calls, model versus tool
 * time, its input tokens (cached and uncached), output tokens (with
 * reasoning) and reported cost. A live turn keeps counting from the user's
 * message until its work settles. Per-request detail lives on each reply.
 */
export function TurnTotals({ turn, now, notify, settled = false }: { turn: TurnSummary; now?: (() => number) | undefined; notify?: NotifyMessageAction | undefined; settled?: boolean }) {
  const clock = now ?? Date.now;
  useTicker(turn.live);
  const plural = (n: number, one: string, many: string): string => `${n} ${n === 1 ? one : many}`;
  const elapsed = turn.live && turn.startedAt != null ? Math.max(turn.elapsedMs ?? 0, clock() - turn.startedAt) : turn.elapsedMs;
  const usage = usageBreakdown(turn.accounting);
  const stamps = [turn.startedAt != null ? `Started ${formatClock(turn.startedAt)}` : null, !turn.live && turn.endedAt != null ? `finished ${formatClock(turn.endedAt)}` : null].filter(Boolean).join(' · ');
  const current = turn.current ? describeTool(turn.current) : null;
  const label = turn.partial ? 'Turn (partial)' : 'Turn';
  const partialTitle = turn.partial ? 'Earlier replies of this turn are above the loaded history' : undefined;
  const counts = plural(turn.replies, 'reply', 'replies') + (turn.tools ? `, ${plural(turn.tools, 'tool call', 'tool calls')}` : '') + (turn.files ? `, ${plural(turn.files, 'file changed', 'files changed')}` : '');
  if (turn.live) {
    // Docked above the composer while the turn runs, so one place shows what is going on.
    return <div className="turn-total live" role="status" aria-live="polite" title={stamps || undefined}>
      <Spinner />
      <span className="turn-label">Working</span>
      {elapsed != null && <span className="turn-elapsed">{formatDuration(elapsed)}</span>}
      {current && <span className="turn-current"><span className="action-verb">{current.verb}</span> <span className={current.kind === 'command' ? 'mono' : ''}>{current.object}</span></span>}
      {turn.notice && <span className="turn-notice">{turn.notice}</span>}
      <span>{counts}</span>
      {usage && <span className="turn-usage">{usage}</span>}
      {turn.startedAt != null && <span className="turn-since">since {formatClock(turn.startedAt)}</span>}
      {notify && <button type="button" className="turn-stop" onClick={() => { void notify('stop', { id: 'turn' }); }} aria-label="Stop the current run">Stop</button>}
    </div>;
  }
  return <div className={`turn-total${settled ? ' settled' : ''}`} title={stamps || 'The whole turn: every reply since your message'} role="note">
    <span className="turn-line">
      <span className="turn-label" title={partialTitle}>{label}</span>
      {elapsed != null && <span>{formatDuration(elapsed)}</span>}
      <span>{counts}</span>
      {(turn.modelMs > 0 || turn.toolMs > 0) && <span className="block-split">model {formatDuration(turn.modelMs)} · tools {formatDuration(turn.toolMs)}</span>}
      {usage && <span className="turn-usage">{usage}</span>}
    </span>
    {stamps && <span className="turn-stamp">{stamps}</span>}
  </div>;
}

export function TranscriptItems({ items, notify, fresh }: { items: TranscriptItem[]; notify: NotifyMessageAction; fresh?: ReadonlySet<string> | undefined }) {
  const isFresh = (id: string): boolean => fresh?.has(id) ?? false;
  return <>{items.map(item => item.kind === 'message'
    ? <MessageRow key={item.message.id} message={item.message} notify={notify} fresh={isFresh(item.message.id)} />
    : <BlockView key={item.block.key} block={item.block} notify={notify} fresh={item.block.message ? isFresh(item.block.message.id) : item.block.activity.some(message => isFresh(message.id))} />)}</>;
}
