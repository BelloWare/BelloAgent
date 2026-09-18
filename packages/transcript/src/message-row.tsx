import { memo, useCallback } from 'react';
import { SafeMarkdown } from './safe-markdown.tsx';
import { MessageAccounting } from './message-accounting.tsx';
import { formatClock } from './activity.ts';
import type { Message, NotifyMessageAction } from './message-model.ts';
import type { MarkdownCopySelection } from './markdown-copy.ts';

export function MessageMarkdown({ message, field = 'text', notify }: { message: Message; field?: 'text' | 'thinking'; notify: NotifyMessageAction }) {
  const copy = useCallback((selection: MarkdownCopySelection) => Promise.resolve(notify('copyContent', { id: message.id, field, ...selection })).then(success => success === true), [message.id, field, notify]);
  return <SafeMarkdown text={message[field] ?? ''} onCopy={copy} />;
}

/** Request details stay available on every row, including the original input. */
function RowActions({ message, edit, notify }: { message: Message; edit: boolean; notify: NotifyMessageAction }) {
  return <span className="actions" role="group" aria-label={`Actions for ${message.role} message`}>
    {edit && <button className="request-link edit-link" type="button" aria-label="Edit user message" onClick={() => notify('editMessage', { id: message.id })}>Edit</button>}
    <button className="request-link copy-link" type="button" aria-label={`Copy ${message.role} message`} onClick={() => notify('copyMessage', { id: message.id })}>Copy</button>
    <button className="request-link" type="button" aria-label={`Inspect requests for ${message.role} message`} onClick={() => notify('inspectRequests', { id: message.id })}>Details</button>
  </span>;
}

function CompactionRow({ message, notify }: { message: Message; notify: NotifyMessageAction }) {
  return <article className="system compaction" data-message-id={message.id} aria-label="Context compacted">
    <div className="marker-card">
      <div className="marker-head">
        <span className="marker-icon" aria-hidden="true">⇣</span>
        <span className="marker-title">Context compacted</span>
        {message.detail && <span className="marker-detail">{message.detail}</span>}
        <RowActions message={message} edit={false} notify={notify} />
      </div>
      {message.text && <details className="marker-summary"><summary>Summary kept in context</summary><div className="body"><MessageMarkdown message={message} notify={notify} /></div></details>}
      {message.accounting && <MessageAccounting accounting={message.accounting} onInspect={() => { void notify('inspectRequests', { id: message.id }); }} />}
    </div>
  </article>;
}

function BranchRow({ message }: { message: Message }) {
  return <article className="system branch" data-message-id={message.id} aria-label="Edited from here">
    <div className="marker-line"><span className="marker-title">Edited from here</span>{(message.detail || message.text) && <span className="marker-detail">{message.detail || message.text}</span>}</div>
  </article>;
}

/** A run failure, shown where the conversation stopped rather than in a fixed strip above it. */
function FailureRow({ message }: { message: Message }) {
  return <article className="system failure" data-message-id={message.id} aria-label="Error" role="alert">
    <div className="failure-card">
      <div className="failure-head"><span className="failure-icon" aria-hidden="true">!</span><span className="failure-title">Something went wrong</span></div>
      <div className="failure-text">{message.text}</div>
      {message.detail && <div className="failure-detail">{message.detail}</div>}
    </div>
  </article>;
}

/** A transient status line inside the conversation, such as a retry in progress; it turns while it waits. */
function NoticeRow({ message }: { message: Message }) {
  return <article className="system notice-row" data-message-id={message.id} aria-label="Status" role="status">
    <div className="marker-line"><span className="spinner" aria-hidden="true" /><span className="notice-text">{message.text}</span></div>
  </article>;
}

export const MessageRow = memo(function MessageRow({ message, notify, inlineAccounting = true, fresh = false }: { message: Message; notify: NotifyMessageAction; inlineAccounting?: boolean; fresh?: boolean }) {
  if (message.kind === 'compaction') return <CompactionRow message={message} notify={notify} />;
  if (message.kind === 'branch') return <BranchRow message={message} />;
  if (message.kind === 'failure') return <FailureRow message={message} />;
  if (message.kind === 'notice') return <NoticeRow message={message} />;
  const failed = message.state !== undefined && ['error', 'aborted'].includes(message.state);
  const label = message.role === 'system' ? 'Status' : null;
  const streaming = message.role === 'assistant' && (message.state === 'streaming' || message.id.startsWith('stream:'));
  // Exposed reasoning renders in the reply's folded work line (activity.tsx), not inside the row.
  const content = <>
    <div className="body">{message.role === 'tool' ? <div className="plain">{message.text}</div> : <MessageMarkdown message={message} notify={notify} />}</div>
    {message.truncated && <p className="notice">Display preview truncated. Full retained content is available in the native message viewer.</p>}
  </>;
  // Tool calls render as grouped activity after the row (activity.tsx); a
  // reply that only called tools keeps its article for anchors and receipts.
  const toolsOnly = message.role === 'assistant' && !message.text.trim() && (message.tools?.length ?? 0) > 0;
  const className = [message.role, streaming ? 'streaming' : '', toolsOnly ? 'tools-only' : '', fresh ? 'fresh' : ''].filter(Boolean).join(' ');
  return <article className={className} data-message-id={message.id} aria-label={`${message.role} message`} aria-busy={streaming || undefined}>
    {message.role === 'tool' ? <details className="tool-result">
      <summary><span className="name">Tool result</span>{failed && <span className={`state ${message.state}`}>{message.state}</span>}</summary>
      {content}
    </details> : <>
      {(label || failed) && <div className="role">{label && <span className="who">{label}</span>}{failed && <span className="state">{message.state}</span>}</div>}
      {content}
      {message.role === 'user' && message.at != null && <time className="stamp" dateTime={new Date(message.at).toISOString()}>{formatClock(message.at)}</time>}
    </>}
    <div className="message-footer">
      {inlineAccounting && message.accounting && <MessageAccounting accounting={message.accounting} onInspect={() => { void notify('inspectRequests', { id: message.id }); }} />}
      <RowActions message={message} edit={message.role === 'user'} notify={notify} />
    </div>
  </article>;
}, (a, b) => a.notify === b.notify && a.inlineAccounting === b.inlineAccounting && a.fresh === b.fresh && sameMessage(a.message, b.message));

/// Field comparison instead of serializing both messages on every snapshot.
function sameMessage(a: Message, b: Message): boolean {
  if (a === b) return true;
  if (a.id !== b.id || a.role !== b.role || a.text !== b.text || a.thinking !== b.thinking || a.state !== b.state || a.kind !== b.kind || a.detail !== b.detail || a.truncated !== b.truncated || a.at !== b.at || a.turn !== b.turn || a.modelMs !== b.modelMs) return false;
  const toolsA = a.tools ?? [], toolsB = b.tools ?? [];
  if (toolsA.length !== toolsB.length) return false;
  for (const [index, x] of toolsA.entries()) {
    const y = toolsB[index];
    if (!y || x.id !== y.id || x.name !== y.name || x.state !== y.state || x.input !== y.input || x.output !== y.output || x.durationMs !== y.durationMs || x.truncated !== y.truncated || x.path !== y.path || x.added !== y.added || x.removed !== y.removed) return false;
  }
  if ((a.accounting == null) !== (b.accounting == null)) return false;
  return a.accounting == null || JSON.stringify(a.accounting) === JSON.stringify(b.accounting);
}
