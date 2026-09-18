import { Component, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { MessageRow } from './message-row.tsx';
import type { Message, NotifyMessageAction } from './message-model.ts';
import { validModelSummary } from './message-model.ts';
import { copyRequests, type CopyContentRequest } from './copy-requests.ts';
import { frameConflator } from './frame-conflator.ts';
import { latestCompletedAssistant, replyEndIsVisible } from './read-visibility.ts';
import './transcript.css';
import './activity.css';
import { TranscriptItems } from './activity.tsx';
import { blocksOf } from './activity.ts';

const MESSAGE_KINDS: readonly string[] = ['compaction', 'branch', 'failure', 'notice'];
interface Snapshot { v: 1; viewId: string; sessionId: string; viewportRequest?: number; seq: number; receivedAt?: number; messages: Message[]; anchor?: { id: string; offset: number; followsBottom: boolean } }
declare global { interface Window {
  webkit?: { messageHandlers: { transcript: { postMessage: (value: unknown) => void } } };
  piTranscript: { apply: (value: unknown) => boolean; checkRead: () => void; copyResult: (value: unknown) => boolean };
} }
const viewId = new URLSearchParams(location.hash.slice(1)).get('viewId') ?? '';
const notify = (type: string, fields: object = {}): void => window.webkit?.messageHandlers.transcript.postMessage({ v: 1, viewId, type, ...fields });
const clipboard = copyRequests(fields => notify('copyContent', fields), { later: (run, delay) => window.setTimeout(run, delay), cancel: timer => clearTimeout(timer) });
const notifyMessage: NotifyMessageAction = (type, fields) => type === 'copyContent' ? clipboard.request(fields as CopyContentRequest) : notify(type, fields);
let receive: (snapshot: Snapshot) => void = () => {}, sequence = -1;
let checkRead = (): void => {};
window.piTranscript = { checkRead: () => checkRead(), copyResult: clipboard.reply, apply(value): boolean {
  if (typeof value !== 'object' || value === null) return false;
  const data = value as Partial<Snapshot>;
  if (data.v !== 1 || data.viewId !== viewId || typeof data.sessionId !== 'string' || data.sessionId.length > 128 || !Number.isSafeInteger(data.seq) || data.seq! <= sequence || !Array.isArray(data.messages) || data.messages.length > 501) return false;
  if (data.viewportRequest !== undefined && !Number.isSafeInteger(data.viewportRequest)) return false;
  const ids = new Set<string>();
  for (const message of data.messages) {
    if (!message || typeof message.id !== 'string' || message.id.length > 256 || ids.has(message.id) || !['user', 'assistant', 'system', 'tool'].includes(message.role) ||
        typeof message.text !== 'string' || message.text.length > 65536 || (message.thinking !== undefined && message.thinking !== null && typeof message.thinking !== 'string')) return false;
    ids.add(message.id);
    // A marker kind this build does not know renders as an ordinary message
    // rather than rejecting the whole page and freezing the transcript.
    if (message.kind !== undefined && message.kind !== null && (typeof message.kind !== 'string' || !MESSAGE_KINDS.includes(message.kind))) delete message.kind;
    if (message.detail !== undefined && message.detail !== null && (typeof message.detail !== 'string' || message.detail.length > 4096)) return false;
    if (message.accounting !== undefined && message.accounting !== null) {
      const a = message.accounting;
      if (![a.requests, a.costSamples, a.cacheHits, a.cacheMisses, a.cacheUnreported, a.cacheConflicts, a.cacheReadSamples, a.cacheWriteSamples].every(n => Number.isSafeInteger(n) && n >= 0 && n <= 100_000) ||
          [a.costUSD, a.cacheReadTokens, a.cacheWriteTokens, a.reasoningCostUSD, a.uncachedInputReportedTokens].some(n => n !== undefined && n !== null && (!Number.isFinite(n) || n < 0)) ||
          (a.uncachedInputSamples !== undefined && a.uncachedInputSamples !== null && (!Number.isSafeInteger(a.uncachedInputSamples) || a.uncachedInputSamples < 0 || a.uncachedInputSamples > a.requests)) ||
          (a.reasoningCostSamples !== undefined && a.reasoningCostSamples !== null && (!Number.isSafeInteger(a.reasoningCostSamples) || a.reasoningCostSamples < 0 || a.reasoningCostSamples > 100_000))) return false;
      if (a.models !== undefined && a.models !== null && !validModelSummary(a.models, a.requests)) return false;
      if (a.tokens !== undefined && a.tokens !== null) {
        const t = a.tokens;
        if (typeof t !== 'object' || ![t.inputSamples, t.outputSamples, t.samples].every(n => Number.isSafeInteger(n) && n >= 0 && n <= 100_000) ||
            [t.input, t.output, t.total, t.reasoning].some(n => n !== undefined && n !== null && (!Number.isFinite(n) || n < 0)) ||
            (t.reasoningSamples !== undefined && t.reasoningSamples !== null && (!Number.isSafeInteger(t.reasoningSamples) || t.reasoningSamples < 0 || t.reasoningSamples > 100_000))) return false;
      }
    }
    const count = (value: unknown): boolean => value === undefined || value === null || (Number.isSafeInteger(value) && (value as number) >= 0 && (value as number) <= 10_000_000);
    if (message.at !== undefined && message.at !== null && (typeof message.at !== 'number' || !Number.isFinite(message.at) || message.at < 0)) return false;
    if (message.turn !== undefined && message.turn !== null && (typeof message.turn !== 'string' || message.turn.length > 256)) return false;
    if (message.modelMs !== undefined && message.modelMs !== null && (typeof message.modelMs !== 'number' || !Number.isFinite(message.modelMs) || message.modelMs < 0)) return false;
    if (message.tools !== undefined && message.tools !== null && (!Array.isArray(message.tools) || message.tools.length > 32 || message.tools.some(t => !t || typeof t.id !== 'string' || typeof t.input !== 'string' || typeof t.output !== 'string' || typeof t.name !== 'string' || typeof t.state !== 'string' ||
      (t.durationMs !== undefined && t.durationMs !== null && (typeof t.durationMs !== 'number' || !Number.isFinite(t.durationMs) || t.durationMs < 0)) ||
      (t.path !== undefined && t.path !== null && (typeof t.path !== 'string' || t.path.length > 4096)) || !count(t.added) || !count(t.removed)))) return false;
  }
  let approximateBytes = 0;
  for (const message of data.messages) {
    approximateBytes += message.text.length + (message.thinking?.length ?? 0) + (message.detail?.length ?? 0);
    for (const tool of message.tools ?? []) approximateBytes += tool.input.length + tool.output.length;
  }
  if (approximateBytes > 500_000) return false;
  // Native permits one call, at most two unpainted snapshots, and one conflated
  // dirty marker. React renders only the newest accepted snapshot in each frame.
  sequence = data.seq!; receive({ ...data, receivedAt: performance.now() } as Snapshot);
  notify('committed', {seq: sequence});
  return true;
} };
/// A render exception unmounts the React root and leaves a blank page with no
/// way back. The boundary keeps the page alive and offers a reload, which
/// re-runs the bridge handshake so native resends the current snapshot.
class TranscriptErrorBoundary extends Component<{ children: ReactNode; sequence: number }, { failed: boolean; sequence: number }> {
  state = { failed: false, sequence: this.props.sequence };
  static getDerivedStateFromProps(props: { sequence: number }, state: { sequence: number }): { failed: boolean; sequence: number } | null {
    // A corrected snapshot or a different chat must be able to recover without
    // reloading. Normal successful updates retain their DOM and disclosures.
    return props.sequence !== state.sequence ? { failed: false, sequence: props.sequence } : null;
  }
  static getDerivedStateFromError(): { failed: boolean } { return { failed: true }; }
  componentDidCatch(): void { notify('renderError', { seq: this.props.sequence }); }
  render(): ReactNode {
    if (!this.state.failed) return this.props.children;
    return <p className="empty">The transcript could not be drawn. <button type="button" className="request-link" onClick={() => location.reload()}>Reload</button></p>;
  }
}

function Transcript() {
  const [snapshot, setSnapshot] = useState<Snapshot>({ v: 1, viewId, sessionId: '', seq: -1, messages: [] });
  const renderedSession = useRef('');
  const renderBoundary = useRef<TranscriptErrorBoundary>(null);
  const renderedSequence = useRef(-1);
  const completedAssistant = useRef<string | null>(null);
  const viewportRequest = useRef<number | undefined>(undefined);
  const followsBottom = useRef(true), initialized = useRef(false), anchor = useRef<{ id: string; offset: number } | null>(null);
  // Rows that were not on the page at the previous paint animate in; a fresh
  // session or a restored page arrives settled, without a wave of motion.
  const seenRows = useRef<Set<string>>(new Set());
  const freshRows = useRef<Set<string>>(new Set());
  // Scrolling near the top asks the native side for the page before the first
  // row, once per first row; a prepended page changes that row and re-arms it.
  const firstRow = useRef(''), earlierRequested = useRef('');
  // `detached` shows the jump pill once the reader scrolls away from the newest
  // message; `jumping` keeps it hidden while a smooth scroll is still travelling.
  const [detached, setDetached] = useState(false);
  const jumping = useRef(false);
  const [announcement, setAnnouncement] = useState('');
  const jumpToLatest = (): void => {
    followsBottom.current = true; jumping.current = true; setDetached(false);
    scrollTo({ top: document.documentElement.scrollHeight, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
    // A smooth scroll the browser abandons must not leave the pill hidden.
    window.setTimeout(() => { if (jumping.current) { jumping.current = false; setDetached(document.documentElement.scrollHeight - innerHeight - scrollY >= 70); } }, 1_500);
  };
  useLayoutEffect(() => {
    let timer = 0;
    checkRead = (): void => {
      if (document.visibilityState !== 'visible' || !completedAssistant.current) return;
      const row = [...document.querySelectorAll<HTMLElement>('article[data-message-id]')].find(node => node.dataset.messageId === completedAssistant.current);
      if (row && replyEndIsVisible(row.getBoundingClientRect(), innerHeight)) notify('readReply', { seq: renderedSequence.current, sessionId: renderedSession.current, id: completedAssistant.current });
    };
    const frames = frameConflator<Snapshot>(value=>{flushSync(()=>setSnapshot(value));return renderBoundary.current?.state.failed === false;},
      value=>{const paintedAt=performance.now();notify('rendered',{seq:value.seq,paintedAt,paintDelayMs:paintedAt-(value.receivedAt??paintedAt)});checkRead();},
      {frame:callback=>requestAnimationFrame(callback),cancelFrame:id=>cancelAnimationFrame(id),task:callback=>window.setTimeout(callback,0),cancelTask:id=>clearTimeout(id)});
    receive = frames.push;
    notify('ready');
    const track = (): void => {
      followsBottom.current = document.documentElement.scrollHeight - innerHeight - scrollY < 70;
      if (followsBottom.current) jumping.current = false;
      if (!jumping.current) setDetached(!followsBottom.current);
      const visible = [...document.querySelectorAll<HTMLElement>('article[data-message-id]')].find(node => node.getBoundingClientRect().bottom > 0);
      anchor.current = visible ? { id: visible.dataset.messageId!, offset: visible.getBoundingClientRect().top } : null;
      if (scrollY < 240 && firstRow.current && earlierRequested.current !== firstRow.current) {
        earlierRequested.current = firstRow.current;
        notify('earlier', { seq: renderedSequence.current, firstId: firstRow.current });
      }
      if (!timer) timer = window.setTimeout(() => { timer = 0; if (anchor.current) notify('viewport', { seq: renderedSequence.current, ...anchor.current, followsBottom: followsBottom.current }); checkRead(); }, 150);
    };
    // A narrower pane makes the same messages taller; a reader who was at the
    // newest message stays there instead of being left mid-transcript.
    const resized = (): void => {
      if (followsBottom.current) scrollTo({ top: document.documentElement.scrollHeight, behavior: 'instant' });
      track();
    };
    // Any user-initiated scroll cancels a programmatic jump in progress.
    const interrupt = (): void => { if (jumping.current) { jumping.current = false; track(); } };
    addEventListener('scroll', track, { passive: true });
    addEventListener('wheel', interrupt, { passive: true }); addEventListener('keydown', interrupt); addEventListener('touchstart', interrupt, { passive: true });
    addEventListener('resize', resized); document.addEventListener('visibilitychange', track);
    return () => { receive = () => {}; checkRead = () => {}; removeEventListener('scroll', track); removeEventListener('wheel', interrupt); removeEventListener('keydown', interrupt); removeEventListener('touchstart', interrupt); removeEventListener('resize', resized); document.removeEventListener('visibilitychange', track); clearTimeout(timer); frames.dispose(); };
  }, []);
  useLayoutEffect(() => {
    if (snapshot.seq < 0) return;
    renderedSequence.current = snapshot.seq;
    firstRow.current = snapshot.messages[0]?.id ?? '';
    const completed = latestCompletedAssistant(snapshot.messages);
    // role="log" stays silent so streaming deltas are not read aloud; a
    // finished reply is announced once through the polite region below.
    if (initialized.current && completed && completed !== completedAssistant.current) setAnnouncement(previous => previous === 'Reply complete' ? 'Reply complete.' : 'Reply complete');
    completedAssistant.current = completed;
    if (renderedSession.current !== snapshot.sessionId || viewportRequest.current !== snapshot.viewportRequest) {
      renderedSession.current = snapshot.sessionId; viewportRequest.current = snapshot.viewportRequest; initialized.current = false; followsBottom.current = true; anchor.current = null;
      seenRows.current = new Set(); freshRows.current = new Set();
    }
    const fresh = new Set<string>();
    for (const message of snapshot.messages) { if (initialized.current && !seenRows.current.has(message.id)) fresh.add(message.id); seenRows.current.add(message.id); }
    freshRows.current = fresh;
    if (!initialized.current && snapshot.anchor) { followsBottom.current = snapshot.anchor.followsBottom; anchor.current = snapshot.anchor; }
    initialized.current = true;
    if (followsBottom.current) { scrollTo({ top: document.documentElement.scrollHeight, behavior: 'instant' }); setDetached(false); }
    else if (anchor.current) {
      const target = [...document.querySelectorAll<HTMLElement>('article[data-message-id]')].find(node => node.dataset.messageId === anchor.current?.id);
      if (target) scrollBy(0, target.getBoundingClientRect().top - anchor.current.offset);
    }
  }, [snapshot]);
  return <>
    <TranscriptErrorBoundary ref={renderBoundary} sequence={snapshot.seq}>
      <main aria-label="Conversation page" role="log" aria-live="off">
        {snapshot.messages.length === 0 ? <p className="empty">Ready for a conversation.</p> : <TranscriptItems items={blocksOf(snapshot.messages)} notify={notifyMessage} fresh={freshRows.current} />}
      </main>
    </TranscriptErrorBoundary>
    <div className="visually-hidden" role="status" aria-live="polite">{announcement}</div>
    {detached && snapshot.messages.length > 0 && <button type="button" className="jump" onClick={jumpToLatest} aria-label="Jump to the latest message">Latest ↓</button>}
  </>;
}
createRoot(document.getElementById('root')!).render(<Transcript />);
