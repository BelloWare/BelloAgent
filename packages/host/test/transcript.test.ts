import test from 'node:test';
import assert from 'node:assert/strict';
import { createElement, isValidElement, type ReactElement, type ReactNode } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { SafeMarkdown, safeURL } from '../../transcript/src/safe-markdown.tsx';
import { highlightCode } from '../../transcript/src/highlight.ts';
import { frameConflator } from '../../transcript/src/frame-conflator.ts';
import { MessageRow } from '../../transcript/src/message-row.tsx';
import { accountingPresentation, MessageAccounting, uncachedInput } from '../../transcript/src/message-accounting.tsx';
import type { Accounting, Message } from '../../transcript/src/message-model.ts';
import { validModelSummary } from '../../transcript/src/message-model.ts';
import { latestCompletedAssistant, replyEndIsVisible } from '../../transcript/src/read-visibility.ts';
import { actionOutcome, aggregateAccounting, blocksOf, changedFiles, describeTool, editTexts, formatClock, formatCompactTokens, formatDuration, formatTokenCount, formatTurnCost, lineDiff, reasoningTeaser, summarizeActivity, summarizeWork, usageBreakdown, type Block } from '../../transcript/src/activity.ts';
import { ActionRow, ActivityGroup, BlockView, TranscriptItems, TurnTotals } from '../../transcript/src/activity.tsx';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { addMarkdownCopyTargets, selectedMarkdown, type MarkdownCopyTarget, type MarkdownNode } from '../../transcript/src/markdown-copy.ts';
import { copyRequests, type CopyContentRequest } from '../../transcript/src/copy-requests.ts';

function markdownTargets(source: string): MarkdownCopyTarget[] {
  const targets = new Map<string, MarkdownCopyTarget>();
  renderToStaticMarkup(createElement(Markdown, { children: source, remarkPlugins: [remarkGfm, () => (tree: MarkdownNode) => addMarkdownCopyTargets(tree, source, targets)] }));
  return [...targets.values()];
}

test('section copy follows parsed heading hierarchy, includes nested sections, and excludes adjacent peers', () => {
  const source = 'Intro **Markdown**.\n\n# Setup\nRoot.\n\n## Install\nRun it.\n\n### macOS\nKeep this.\n\n## Test\nDifferent step.\n\n# Done\nFinish.';
  const targets = markdownTargets(source);
  const copy = (label: string) => selectedMarkdown(targets.find(target => target.label === label)!);
  assert.equal(copy('Copy introduction as Markdown'), 'Intro **Markdown**.\n\n');
  assert.equal(copy('Copy Setup as Markdown'), source.slice(source.indexOf('# Setup'), source.indexOf('# Done')));
  assert.equal(copy('Copy Install as Markdown'), '## Install\nRun it.\n\n### macOS\nKeep this.\n\n');
  assert.equal(copy('Copy macOS as Markdown'), '### macOS\nKeep this.\n\n');
  assert.equal(copy('Copy Test as Markdown'), '## Test\nDifferent step.\n\n');
  assert.equal(copy('Copy Done as Markdown'), '# Done\nFinish.');
});

test('copy sections honor setext headings and never treat code, quoted, or list headings as document boundaries', () => {
  const source = 'First\n=====\n\n```md\n# fenced\n```\n\n> # quoted\n> text\n\n- ## listed\n\nSecond\n======\nFinal';
  const targets = markdownTargets(source);
  assert.deepEqual(targets.filter(target => target.label !== 'Copy code').map(target => target.label), ['Copy First as Markdown', 'Copy Second as Markdown']);
  assert.equal(selectedMarkdown(targets.find(target => target.label === 'Copy First as Markdown')!), source.slice(0, source.indexOf('Second')));
  assert.equal(selectedMarkdown(targets.find(target => target.label === 'Copy code')!), '# fenced\n');
  const noHeading = '**A reply** with [a link](https://example.com) and `inline code`.\n';
  const fallback = markdownTargets(noHeading);
  assert.equal(fallback.length, 1); assert.equal(fallback[0]!.label, 'Copy as Markdown');
  assert.equal(selectedMarkdown(fallback[0]!), noHeading);
});

test('code copies preserve source bytes without fences, language labels, escaped HTML, or fabricated trailing newlines', () => {
  const code = 'const earth = "🌍";  \r\n\tconst html = "<img src=x>";\r\n\r\n';
  const source = 'Before\r\n\r\n```typescript linenums\r\n' + code + '```\r\n\r\nAfter';
  const target = markdownTargets(source).find(value => value.label === 'Copy code')!;
  assert.equal(selectedMarkdown(target), code);
  for (const source of ['```js\nconst x = 1;', '~~~\n# still code\n  value  ', '    first\n    second']) {
    const target = markdownTargets(source).find(value => value.label === 'Copy code')!;
    assert.equal(selectedMarkdown(target), source.startsWith('    ') ? 'first\nsecond' : source.slice(source.indexOf('\n') + 1));
  }
  assert.equal(markdownTargets('```\n```').filter(value => value.label === 'Copy code').length, 0, 'Empty code has no misleading copy action');
});

test('nested fenced and indented code copy drops only Markdown container prefixes', () => {
  const source = '- Example:\n\n  ```js\n  const a = 1;\n    indented();\n  ```\n\n> ```sh\n> echo hi\n>   echo there\n> ```\n\n    plain\n      deeper';
  const targets = markdownTargets(source).filter(value => value.label === 'Copy code');
  assert.deepEqual(targets.map(selectedMarkdown), ['const a = 1;\n  indented();\n', 'echo hi\n  echo there\n', 'plain\n  deeper']);
});

test('copy controls remain accessible, keep whole-message Copy, and retain Markdown security restrictions', () => {
  const html = renderMessages([{ id: 'copyable', role: 'assistant', text: '# Install\n\n```sh\necho "<script>"\n```\n\n[run](javascript:bad) ![pixel](https://evil.example/image)' }]);
  assert.ok(html.includes('aria-label="Copy Install as Markdown"'));
  assert.ok(html.includes('aria-label="Copy code"'));
  assert.ok(html.includes('aria-label="Copy assistant message"'));
  assert.equal((html.match(/type="button" class="markdown-copy-button"/g) ?? []).length, 2);
  assert.ok(html.includes('role="status" aria-live="polite"'));
  assert.ok(!html.includes('<script>')); assert.ok(!html.includes('javascript:')); assert.ok(!html.includes('<img'));
  assert.ok(!html.includes('data-copy-key='), 'Source ranges and source content are not emitted as HTML attributes');
});

test('streaming section selections expand with content while prior source ranges stay tied to their original snapshot', () => {
  const first = '# Answer\nPartial', second = first + ' text.\n\n## Details\nMore.', third = second + '\n\n# Next\nElsewhere';
  const a = markdownTargets(first)[0]!, b = markdownTargets(second)[0]!, c = markdownTargets(third)[0]!;
  assert.equal(selectedMarkdown(a), first); assert.equal(selectedMarkdown(b), second);
  assert.equal(selectedMarkdown(c), second + '\n\n');
  assert.notEqual(a.source, b.source); assert.notEqual(b.source, c.source);
  const html = renderToStaticMarkup(createElement(SafeMarkdown, { text: second, onCopy: async () => true }));
  assert.ok(html.includes('aria-label="Copy Details as Markdown"'));
});

test('copy range validation is bounded, ordered, and safe for UTF-16 offsets', () => {
  assert.equal(selectedMarkdown({ source: 'x🌍y', ranges: [{ start: 1, end: 3 }] }), '🌍');
  for (const ranges of [[], [{ start: -1, end: 1 }], [{ start: 1, end: 2 }], [{ start: 2, end: 3 }], [{ start: 0, end: 99 }], [{ start: 0, end: 2.5 }], [{ start: 0, end: 3 }, { start: 1, end: 4 }]]) {
    assert.equal(selectedMarkdown({ source: 'x🌍y', ranges }), null);
  }
  assert.equal(selectedMarkdown({ source: 'x'.repeat(65_537), ranges: [{ start: 0, end: 1 }] }), null);
  assert.equal(selectedMarkdown({ source: 'x'.repeat(8_194), ranges: Array.from({ length: 4_097 }, (_, index) => ({ start: index * 2, end: index * 2 + 1 })) }), null);
});

test('native copy acknowledgment is scoped, supports out-of-order writes, and handles timeout/failure without false success', async () => {
  let serial = 0;
  const tasks = new Map<number, () => void>(), sent: (CopyContentRequest & { requestId: string })[] = [];
  const broker = copyRequests(fields => { sent.push(fields); }, { later: run => { tasks.set(++serial, run); return serial; }, cancel: timer => { tasks.delete(timer); } });
  const fields: CopyContentRequest = { id: 'assistant', field: 'text', source: 'code', ranges: [{ start: 0, end: 4 }] };
  const first = broker.request(fields), second = broker.request(fields);
  assert.equal(broker.reply({ requestId: 'missing', success: true }), false);
  assert.equal(broker.reply({ requestId: sent[1]!.requestId, success: 'true' }), false);
  assert.equal(broker.reply({ requestId: sent[1]!.requestId, success: true }), true);
  assert.equal(await second, true); assert.equal(tasks.size, 1);
  assert.equal(broker.reply({ requestId: sent[1]!.requestId, success: true }), false);
  assert.equal(broker.reply({ requestId: sent[0]!.requestId, success: false }), true); assert.equal(await first, false);
  const timeout = broker.request(fields); tasks.values().next().value!(); assert.equal(await timeout, false);
  const limited = Array.from({ length: 16 }, () => broker.request(fields));
  assert.equal(await broker.request(fields), false); assert.equal(tasks.size, 16);
  [...tasks.values()].forEach(run => run()); assert.deepEqual(await Promise.all(limited), Array(16).fill(false));
  const broken = copyRequests(() => { throw new Error('unavailable'); }, { later: run => { tasks.set(++serial, run); return serial; }, cancel: timer => { tasks.delete(timer); } });
  assert.equal(await broken.request(fields), false); assert.equal(tasks.size, 0);
});

test('read receipts require a completed assistant and reaching the reply end, not scrollback or partial visibility', () => {
  const messages: Message[] = [{ id: 'u', role: 'user', text: 'Question' }, { id: 'a', role: 'assistant', text: 'Answer' }, { id: 'stream:next', role: 'assistant', state: 'streaming', text: 'Still working' }];
  assert.equal(latestCompletedAssistant(messages), 'a');
  assert.equal(latestCompletedAssistant([messages[0]!, messages[2]!]), null);
  assert.equal(replyEndIsVisible({ top: 100, bottom: 900, height: 800 }, 600), false, 'Seeing only the first lines is not reading to the end');
  assert.equal(replyEndIsVisible({ top: -300, bottom: 500, height: 800 }, 600), true, 'The end of a long reply can be reached');
  assert.equal(replyEndIsVisible({ top: -500, bottom: -100, height: 400 }, 600), false, 'A reply completely above the viewport is not proof');
  assert.equal(replyEndIsVisible({ top: 0, bottom: 0, height: 0 }, 600), false, 'Hidden native views produce no visible row');
  assert.equal(replyEndIsVisible({ top: 100, bottom: 500, height: 400 }, 0), false);
  assert.equal(replyEndIsVisible({ top: 100, bottom: NaN, height: 400 }, 600), false);
  assert.equal(replyEndIsVisible({ top: 100, bottom: 500, height: 400 }, 600), true, 'The same DOM is remeasured again after a hidden/background rejection');
});

const reportedAccounting = (patch: Partial<Accounting> = {}): Accounting => ({
  requests: 1, costSamples: 1, costUSD: 0.000421875,
  cacheHits: 0, cacheMisses: 1, cacheUnreported: 0, cacheConflicts: 0,
  cacheReadTokens: 0, cacheWriteTokens: 0, cacheReadSamples: 1, cacheWriteSamples: 1,
  tokens: { input: 38, output: 423, total: 461, inputSamples: 1, outputSamples: 1, samples: 1 },
  ...patch,
});
const renderMessages = (messages: Message[]): string => messages.map(message => renderToStaticMarkup(createElement(MessageRow, { message, notify: () => {} }))).join('');
const accountingLines = (html: string): number => (html.match(/class="message-accounting"/g) ?? []).length;

test('message rows omit speaker names while preserving accessible roles and original input actions', () => {
  const html = renderMessages([{ id: 'u1', role: 'user', text: 'Question' }, { id: 'a1', role: 'assistant', text: 'Answer' }]);
  assert.ok(!html.includes('You')); assert.ok(!html.includes('Bello Agent')); assert.ok(!html.includes('class="who"'));
  assert.ok(html.includes('aria-label="user message"')); assert.ok(html.includes('aria-label="assistant message"'));
  assert.ok(html.includes('aria-label="Inspect requests for user message"'));
  assert.ok(html.includes('aria-label="Inspect requests for assistant message"'));
  assert.ok(html.includes('aria-label="Edit user message"'));
});

test('native ownership moves the visible summary to the response without removing user Details', () => {
  const accounting = reportedAccounting();
  const pending = renderMessages([{ id: 'u1', role: 'user', text: 'Question', accounting }]);
  const streaming = renderMessages([{ id: 'u1', role: 'user', text: 'Question' }, { id: 'stream:turn-1', role: 'assistant', text: 'Answer', state: 'streaming', accounting }]);
  const restored = renderMessages([{ id: 'u1', role: 'user', text: 'Question' }, { id: 'a1', role: 'assistant', text: 'Answer', state: 'completed', accounting }]);
  for (const html of [pending, streaming, restored]) {
    assert.equal(accountingLines(html), 1);
    assert.ok(html.includes('aria-label="Inspect requests for user message"'));
  }
  assert.ok(pending.indexOf('message-accounting') < pending.indexOf('Inspect requests for user message'));
  for (const html of [streaming, restored]) assert.ok(html.indexOf('message-accounting') > html.indexOf('Inspect requests for user message'));
});

test('tool-round projections show one summary per selected assistant and preserve tool/input details', () => {
  const html = renderMessages([
    { id: 'u', role: 'user', text: 'Read the file' },
    { id: 'a-tool', role: 'assistant', text: '', tools: [{ id: 'call', name: 'read', state: 'completed', input: '{"path":"fixture.txt"}', output: 'Contents', durationMs: 10, truncated: false }], accounting: reportedAccounting() },
    { id: 'tool', role: 'tool', text: 'Contents' },
    { id: 'a-final', role: 'assistant', text: 'Done', accounting: reportedAccounting({ costUSD: 0, cacheHits: 1, cacheMisses: 0 }) },
  ]);
  assert.equal(accountingLines(html), 2);
  assert.equal((html.match(/>Details<\/button>/g) ?? []).length, 4);
  assert.ok(html.includes('aria-label="Inspect requests for tool message"'));
  assert.ok(html.includes('$0 USD'));
  // Tool calls no longer render inside the row; the block view folds them under the reply.
  assert.ok(!html.includes('Tool input'));
  const messages: Message[] = [
    { id: 'u', role: 'user', text: 'Read the file', at: 1_000 },
    { id: 'a-tool', role: 'assistant', text: '', tools: [{ id: 'call', name: 'read', state: 'completed', input: '{"path":"/repo/src/fixture.txt"}', output: 'Contents', durationMs: 10, truncated: false }], at: 3_000 },
    { id: 'tool', role: 'tool', text: 'Contents', at: 3_020 },
    { id: 'a-final', role: 'assistant', text: 'Done', at: 5_000 },
  ];
  const items = blocksOf(messages);
  assert.deepEqual(items.map(item => item.kind), ['message', 'block'], 'the user message stays a row; the reply and the work before it form one block');
  const block = items[1]!.kind === 'block' ? items[1]!.block : null;
  assert.ok(block && block.message?.id === 'a-final' && block.activity.map(m => m.id).join() === 'a-tool');
  assert.equal(block!.modelMs, 2_000 + 1_980, 'model time is the gap before each reply');
  assert.equal(block!.toolMs, 10);
  assert.equal(block!.endedAt! - block!.startedAt!, 4_000);
  const chained = blocksOf([
    { id: 'u', role: 'user', text: 'Go' },
    { id: 'a1', role: 'assistant', text: '', tools: [{ id: 't1', name: 'read', state: 'completed', input: '{"path":"a"}', output: '', durationMs: 1, truncated: false }] },
    { id: 'a2', role: 'assistant', text: '', tools: [{ id: 't2', name: 'bash', state: 'completed', input: '{"command":"ls"}', output: '', durationMs: 2, truncated: false }] },
    { id: 'a3', role: 'assistant', text: 'Now edit', tools: [{ id: 't3', name: 'edit', state: 'completed', input: '{"path":"b"}', output: '', durationMs: 3, truncated: false }] },
    { id: 'a4', role: 'assistant', text: '', tools: [{ id: 't4', name: 'bash', state: 'completed', input: '{"command":"pwd"}', output: '', durationMs: 4, truncated: false }] },
  ]);
  assert.deepEqual(chained.map(item => item.kind === 'block' ? `block:${item.block.message?.id ?? '-'}` : item.kind), ['message', 'block:a3', 'block:-']);
  const first = chained[1]!.kind === 'block' ? chained[1]!.block : null, trailing = chained[2]!.kind === 'block' ? chained[2]!.block : null;
  assert.deepEqual(first!.tools.map(t => t.id), ['t1', 't2', 't3'], 'a reply owns the work before it and its own calls');
  assert.deepEqual(trailing!.tools.map(t => t.id), ['t4'], 'work the turn ended on forms a trailing block without prose');
  assert.equal(first!.toolMs, 6); assert.equal(trailing!.toolMs, 4);
  const noUsage = { requests: 0, input: null, inputSamples: 0, cached: null, cachedSamples: 0, uncached: null, uncachedSamples: 0, output: null, outputSamples: 0, reasoning: null, reasoningSamples: 0, total: null, totalSamples: 0, costUSD: null, costSamples: 0, model: null, modelMessageID: null };
  assert.deepEqual(block!.accounting, noUsage);
  assert.deepEqual(block!.turn, { replies: 1, tools: 1, startedAt: 1_000, endedAt: 5_000, elapsedMs: 4_000, modelMs: 3_980, toolMs: 10, live: false, accounting: noUsage, requests: [], current: null, notice: null, files: 0, partial: false }, 'a single-reply turn carries its totals too');
  assert.equal(first!.turn, undefined); assert.deepEqual(trailing!.turn, { replies: 2, tools: 4, startedAt: null, endedAt: null, elapsedMs: null, modelMs: 0, toolMs: 10, live: false, accounting: noUsage, requests: [], current: null, notice: null, files: 1, partial: false }, 'the last block of a multi-reply turn totals the turn, counting the file its edit touched');
  const multi = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a1', role: 'assistant', text: 'First', at: 3_000, tools: [{ id: 't1', name: 'read', state: 'completed', input: '{"path":"a"}', output: '', durationMs: 500, truncated: false }] },
    { id: 'a2', role: 'assistant', text: 'Second', at: 6_000 },
    { id: 'u2', role: 'user', text: 'More', at: 9_000 },
    { id: 'a3', role: 'assistant', text: 'Third', at: 9_500 },
  ]);
  const turnBlocks = multi.flatMap(item => item.kind === 'block' ? [item.block] : []);
  assert.deepEqual(turnBlocks.map(b => b.turn?.replies ?? 0), [0, 2, 1], 'only the last reply of a turn carries totals; the next turn starts fresh');
  assert.deepEqual(turnBlocks[1]!.turn, { replies: 2, tools: 1, startedAt: 1_000, endedAt: 6_000, elapsedMs: 5_000, modelMs: 5_000, toolMs: 500, live: false, accounting: noUsage, requests: [], current: null, notice: null, files: 0, partial: false });
  const stamped = renderToStaticMarkup(createElement(BlockView, { block: turnBlocks[1]!, notify: () => undefined }));
  assert.ok(stamped.includes(`title="Started ${formatClock(1_000)} · finished ${formatClock(6_000)}"`) && stamped.includes('class="turn-stamp"'), 'a settled turn carries its timestamps for hover: ' + stamped);
  const turnView = renderToStaticMarkup(createElement(BlockView, { block: turnBlocks[1]!, notify: () => undefined }));
  assert.ok(turnView.indexOf('class="block-footer"') < turnView.indexOf('class="turn-total"'), 'turn totals follow the reply\'s own work line');
  assert.ok(turnView.includes('>Turn<') && turnView.includes('>5s<') && turnView.includes('2 replies, 1 tool call') && turnView.includes('model 5s · tools 0.5s'), turnView);
  assert.ok(!renderToStaticMarkup(createElement(BlockView, { block: turnBlocks[0]!, notify: () => undefined })).includes('turn-total'));
  const view = renderToStaticMarkup(createElement(BlockView, { block: block!, notify: () => undefined }));
  assert.ok(view.indexOf('data-message-id="a-final"') < view.indexOf('class="block-footer'), 'the work line sits under the reply');
  // A settled one-reply turn is one line: the reply's work and the turn's figures together, labelled Turn.
  assert.ok(view.includes('class="block-footer merged-turn') && !view.includes('class="turn-total"'), 'a one-reply turn merges its two lines: ' + view);
  assert.ok(view.includes('class="turn-label">Turn<') && view.includes('class="block-duration">4s<') && view.includes('model 4s · tools 0.0s'), 'the merged line keeps the duration and the split');
  assert.ok(view.indexOf('>Turn<') < view.indexOf('Read 1 file') && view.indexOf('Read 1 file') < view.indexOf('class="chevron"'), 'label, work, figures, chevron');
  assert.ok(view.includes(`title="Started ${formatClock(1_000)} · finished ${formatClock(5_000)}"`), 'the merged line carries the turn\'s times for hover');
  assert.ok(!view.includes('>Did<') && !view.includes('class="block-label"'), 'a settled reply line names only its work');
  assert.ok(!view.includes('class="spinner"'), 'nothing turns once the turn has settled');
  assert.ok(!view.includes('turn-toggle') && !view.includes('turn-details'), 'the turn line has nothing to expand');
  assert.ok(!view.includes('class="block-split"><') || view.indexOf('class="block-split"') > view.indexOf('class="turn-total"'), 'the reply line carries no split of its own');
  assert.ok(view.includes('class="block-summary">Read 1 file<'), 'the folded line names the work');
  assert.ok(view.includes('class="block-toggle" aria-expanded="false"'), 'reasoning and tool calls start folded');
  assert.ok(!view.includes('class="activity'), 'no action rows until the user expands');
  assert.ok(!view.includes('data-message-id="a-tool"'), 'a tool-only reply\'s accounting stays folded with its activity');
  assert.ok(!view.includes('data-message-id="tool"'), 'tool-result rows fold into their call');
  assert.ok(!view.includes('Tool result'));
  const plain = blocksOf([{ id: 'u', role: 'user', text: 'Hi', at: 1_000 }, { id: 'a', role: 'assistant', text: 'Hello', at: 1_800 }]);
  const plainView = renderToStaticMarkup(createElement(BlockView, { block: plain[1]!.kind === 'block' ? plain[1]!.block : null!, notify: () => undefined }));
  assert.ok(plainView.includes('class="block-footer merged-turn"') && plainView.includes('class="block-duration">0.8s<') && !plainView.includes('class="turn-total"') && !plainView.includes('class="chevron"'), 'a plain reply still gets the merged turn line with its time, and nothing to expand: ' + plainView);
  const live = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a', role: 'assistant', text: '', state: 'streaming', tools: [{ id: 't', name: 'bash', state: 'running', input: '{"command":"npm test"}', output: '', durationMs: null, truncated: false }] },
  ]);
  const liveView = renderToStaticMarkup(createElement(BlockView, { block: live[1]!.kind === 'block' ? live[1]!.block : null!, notify: () => undefined }));
  assert.ok(!liveView.includes('Working…') && !liveView.includes('class="block-current"'), 'the docked bar is the one live indicator; the reply line does not repeat it: ' + liveView);
  assert.ok(liveView.includes('class="spinner"'), 'the bar and the running trail item turn a spinner');
  assert.ok(liveView.includes('class="action-trail"') && liveView.includes('class="trail-item running"') && liveView.includes('class="action-verb">Running</span>') && liveView.includes('npm test'), 'a live block lists its recent actions inline, in the present tense');
  assert.ok(liveView.includes('class="turn-total live"') && liveView.includes('role="status"') && liveView.includes('>Working<') && liveView.includes('class="turn-current"') && liveView.includes('class="turn-stop"'), 'the live turn bar names the current action and offers Stop: ' + liveView);
  assert.ok(liveView.includes('aria-expanded="false"'), 'even a live block stays folded until expanded');
  const liveTurn = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a1', role: 'assistant', text: 'First', at: 2_000 },
    { id: 'a2', role: 'assistant', text: '', state: 'streaming', tools: [{ id: 't', name: 'bash', state: 'running', input: '{"command":"npm test"}', output: '', durationMs: null, truncated: false }] },
  ]);
  const liveTurnBlock = liveTurn[2]!.kind === 'block' ? liveTurn[2]!.block : null!;
  assert.equal(liveTurnBlock.turn?.live, true); assert.equal(liveTurnBlock.turn?.startedAt, 1_000);
  assert.ok(renderToStaticMarkup(createElement(BlockView, { block: liveTurnBlock, notify: () => undefined })).includes('class="turn-total live"'), 'a live turn docks its bar');
  const ticking = renderToStaticMarkup(createElement(TurnTotals, { turn: liveTurnBlock.turn!, now: () => 13_000 }));
  assert.ok(ticking.includes('>12s<') && ticking.includes('class="spinner"'), 'a live turn counts from the user\'s message and turns a spinner: ' + ticking);
  const retrying = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a', role: 'assistant', text: '', state: 'streaming' },
    { id: 'notice:retry:s', role: 'system', text: 'Retrying (attempt 2 of 3) after: stream dropped', kind: 'notice' },
  ]);
  assert.deepEqual(retrying.map(item => item.kind), ['message', 'block'], 'a retry notice during a live turn folds into its bar');
  const retryBar = renderToStaticMarkup(createElement(TurnTotals, { turn: (retrying[1] as { block: Block }).block.turn!, now: () => 2_000 }));
  assert.ok(retryBar.includes('class="turn-notice">Retrying (attempt 2 of 3) after: stream dropped<'), retryBar);
  const settledNotice = blocksOf([{ id: 'u', role: 'user', text: 'Go', at: 1_000 }, { id: 'a', role: 'assistant', text: 'Done', at: 2_000 }, { id: 'n', role: 'system', text: 'Later', kind: 'notice' }]);
  assert.equal(settledNotice.length, 3, 'a notice after a settled turn stays a row');
  const tickingReply = renderToStaticMarkup(createElement(BlockView, { block: liveTurnBlock, notify: () => undefined, now: () => 13_000 }));
  assert.ok(tickingReply.includes('class="block-duration">11s<'), 'a live reply counts from where it started: ' + tickingReply);
  const reasoned = blocksOf([
    { id: 'u', role: 'user', text: 'Why?', at: 1_000 },
    { id: 'think', role: 'assistant', text: '', thinking: 'Private chain of thought', at: 2_000 },
    { id: 'answer', role: 'assistant', text: 'Because.', thinking: 'More thought', at: 3_000 },
  ]);
  const reasonedView = renderToStaticMarkup(createElement(BlockView, { block: reasoned[1]!.kind === 'block' ? reasoned[1]!.block : null!, notify: () => undefined }));
  assert.ok(reasonedView.includes('class="block-summary">Reasoned<') && reasonedView.includes('aria-expanded="false"'), 'reasoning alone still gives the reply a folded work line');
  assert.ok(reasonedView.includes('class="block-teaser"') && reasonedView.includes('More thought'), 'the first sentence of the last exposed reasoning shows as a teaser');
  assert.ok(!reasonedView.includes('Private chain of thought'), 'earlier reasoning stays out of the DOM until expanded');
  assert.ok(reasonedView.includes('data-message-id="answer"'));
  assert.equal(summarizeWork([], true), 'Reasoned');
  assert.equal(summarizeWork([{ id: 'r', name: 'read', state: 'completed', input: '{"path":"x"}', output: '', durationMs: 1, truncated: false }], true), 'Reasoned, read 1 file');
});

test('replies carry their own usage and the turn line sums cached, uncached, output and reasoning tokens', () => {
  const items = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a1', role: 'assistant', text: '', at: 2_000, tools: [{ id: 't', name: 'read', state: 'completed', input: '{"path":"a"}', output: '', durationMs: 5, truncated: false }], accounting: reportedAccounting() },
    { id: 'a2', role: 'assistant', text: 'Done', at: 3_000, accounting: reportedAccounting({ costUSD: 0.001, cacheReadTokens: 20, tokens: { input: 62, output: 100, total: 162, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 30, reasoningSamples: 1 }, models: { names: ['gpt-5.4'], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0 } }) },
    { id: 'a3', role: 'assistant', text: 'Extra', at: 4_000 },
  ]);
  const blocks = items.flatMap(item => item.kind === 'block' ? [item.block] : []);
  const [first, last] = [blocks[0]!, blocks[1]!];
  // The reply line carries the block's own requests: a1 folded into a2.
  assert.equal(first.accounting.requests, 2); assert.equal(first.accounting.input, 100); assert.equal(first.accounting.cached, 20); assert.equal(first.accounting.uncached, 80);
  assert.equal(first.accounting.output, 523); assert.equal(first.accounting.reasoning, 30); assert.equal(first.accounting.total, 623); assert.equal(first.accounting.costUSD, 0.001421875);
  assert.equal(first.accounting.model, 'gpt-5.4'); assert.equal(first.accounting.modelMessageID, 'a2');
  assert.equal(last.accounting.requests, 0);
  const reply = renderToStaticMarkup(createElement(BlockView, { block: first, notify: () => undefined }));
  assert.ok(reply.includes('class="block-summary">Read 1 file<') && reply.includes('class="block-duration">2s<') && reply.includes('623 tokens') && reply.includes('$0.00142<'), reply);
  assert.ok(!reply.includes('merged-turn'), 'the first reply of a two-reply turn keeps its own line');
  assert.ok(reply.includes('class="block-line"') && reply.indexOf('class="block-model-segment"') < reply.indexOf('class="block-toggle"') && reply.indexOf('>gpt-5.4<') < reply.indexOf('class="chevron"'), 'the model link sits in the flowing line, before the chevron toggle: ' + reply);
  assert.ok(!reply.match(/<button[^>]*>[^<]*(<(?!\/button)[^>]*>[^<]*)*role="link"/), 'no link nests inside the toggle button');
  assert.ok(reply.includes('aria-expanded="false"') && !reply.includes('class="message-accounting"'), 'the full accounting rows stay folded until asked');
  assert.ok(!reply.includes('class="turn-total"'), 'a reply that is not the turn\'s last carries no turn line');
  const turnLine = renderToStaticMarkup(createElement(BlockView, { block: last, notify: () => undefined }));
  assert.ok(turnLine.includes('in 100 · 20 cached · 80 uncached · out 523 · 30 reasoning (1/2) · $0.00142'), turnLine);
  assert.ok(turnLine.includes('2 replies, 1 tool call') && !turnLine.includes('turn-toggle') && !turnLine.includes('turn-details'), 'the turn line is a plain summary');
  assert.ok(turnLine.includes('class="turn-total"') && !turnLine.includes('merged-turn'), 'a two-reply turn keeps its separate turn line');
  const single = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a', role: 'assistant', text: 'Done', at: 3_000, accounting: reportedAccounting({ cacheReadTokens: 8, models: { names: ['gpt-5.4'], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0 } }) },
  ]);
  const singleView = renderToStaticMarkup(createElement(BlockView, { block: (single[1] as { block: Block }).block, notify: () => undefined }));
  assert.ok(singleView.includes('merged-turn') && singleView.includes('class="block-usage turn-usage">in 38 · 8 cached · 30 uncached · out 423 · $0.00042<') && singleView.includes('>gpt-5.4<') && !singleView.includes('461 tokens'), 'a merged line carries the turn\'s usage breakdown instead of the reply\'s token count: ' + singleView);
  assert.equal(usageBreakdown(last.turn!.accounting), 'in 100 · 20 cached · 80 uncached · out 523 · 30 reasoning (1/2) · $0.00142', 'only one of the two requests reported reasoning');
  const partial = aggregateAccounting([{ id: 'x', role: 'assistant', text: '', accounting: reportedAccounting({ costSamples: 0, costUSD: null, cacheReadSamples: 0, cacheReadTokens: null, tokens: { input: 5, output: null, total: null, inputSamples: 1, outputSamples: 0, samples: 0 } }) }]);
  assert.equal(partial.costUSD, null); assert.equal(partial.input, 5); assert.equal(partial.output, null); assert.equal(partial.total, null); assert.equal(partial.uncached, null); assert.equal(partial.reasoning, null);
  assert.equal(usageBreakdown(partial), 'in 5');
  const uncovered = aggregateAccounting([{ id: 'y', role: 'assistant', text: '', accounting: reportedAccounting({ requests: 2, costSamples: 1 }) }]);
  assert.equal(usageBreakdown(uncovered), 'in 38 (1/2) · 0 cached (1/2) · out 423 (1/2) · $0.00042 (1/2)', 'partial coverage stays visible, and an uncached share is not derived from partial input and cache reports');
  assert.equal(formatCompactTokens(950), '950'); assert.equal(formatCompactTokens(1_500), '1.5k'); assert.equal(formatCompactTokens(2_000), '2k'); assert.equal(formatCompactTokens(48_200), '48k'); assert.equal(formatCompactTokens(2_500_000), '2.5M');
  assert.equal(formatTokenCount(9_999), '9,999'); assert.equal(formatTokenCount(12_000), '12k');
  assert.equal(formatTurnCost(0), '$0'); assert.equal(formatTurnCost(0.0004), '$0.0004'); assert.equal(formatTurnCost(0.0123), '$0.012'); assert.equal(formatTurnCost(2), '$2.00');
});

test('edits render as diffs, user rows carry hover stamps, and helpers format teasers and clocks', () => {
  const edit = { id: 'e', name: 'edit', state: 'completed', input: JSON.stringify({ path: '/repo/src/retry.swift', oldText: 'let a = 1\nlet b = 2\nlet c = 3', newText: 'let a = 1\nlet b = 20\nlet c = 3\nlet d = 4' }), output: 'ok', durationMs: 3, truncated: false, path: '/repo/src/retry.swift', added: 2, removed: 1 };
  assert.deepEqual(lineDiff('let a = 1\nlet b = 2\nlet c = 3', 'let a = 1\nlet b = 20\nlet c = 3\nlet d = 4'), [
    { kind: 'context', text: 'let a = 1' }, { kind: 'removed', text: 'let b = 2' }, { kind: 'added', text: 'let b = 20' }, { kind: 'context', text: 'let c = 3' }, { kind: 'added', text: 'let d = 4' },
  ]);
  assert.deepEqual(editTexts(edit), { before: 'let a = 1\nlet b = 2\nlet c = 3', after: 'let a = 1\nlet b = 20\nlet c = 3\nlet d = 4' });
  assert.deepEqual(editTexts({ ...edit, name: 'write', input: JSON.stringify({ path: 'x', content: 'new' }) }), { before: '', after: 'new' });
  assert.equal(editTexts({ ...edit, name: 'bash', input: '{"command":"ls"}' }), null);
  const row = renderToStaticMarkup(createElement(ActionRow, { tool: edit }));
  assert.ok(row.includes('class="edit-diff done"') && row.includes('class="edit-diff-label">Requested edit<') && row.includes('class="diff-row removed"') && row.includes('let b = 20') && !row.includes('class="action-input"'), row);
  const failedEdit = renderToStaticMarkup(createElement(ActionRow, { tool: { ...edit, id: 'ef', state: 'failed' } }));
  assert.ok(failedEdit.includes('class="edit-diff failed"') && failedEdit.includes('Requested edit · not applied') && failedEdit.includes('class="action-verb">Failed editing</span>'), 'a failed edit shows what was asked, never as applied: ' + failedEdit);
  const created = renderToStaticMarkup(createElement(ActionRow, { tool: { id: 'w', name: 'write', state: 'completed', input: '{"path":"/a/new.swift","content":"let a = 1\\nlet b = 2"}', output: '', durationMs: 2, truncated: false, path: '/a/new.swift', added: 2, removed: 0 } }));
  assert.ok(created.includes('class="edit-diff-label">Requested content<') && created.includes('class="diff-row added"') && created.includes('class="action-verb">Created</span>'), 'a confirmed new file reads as added lines: ' + created);
  const overwrite = renderToStaticMarkup(createElement(ActionRow, { tool: { id: 'w2', name: 'write', state: 'completed', input: '{"path":"/a/old.swift","content":"let a = 1"}', output: '', durationMs: 2, truncated: false, path: '/a/old.swift', added: 1, removed: 4 } }));
  assert.ok(overwrite.includes('class="diff-row context"') && !overwrite.includes('class="diff-row added"') && overwrite.includes('class="action-verb">Wrote</span>'), 'an overwrite shows its requested content plainly, not as a diff against nothing: ' + overwrite);
  const failedWrite = renderToStaticMarkup(createElement(ActionRow, { tool: { id: 'w3', name: 'write', state: 'failed', input: '{"path":"/a/x.swift","content":"let a = 1"}', output: 'denied', durationMs: 2, truncated: false } }));
  assert.ok(failedWrite.includes('Requested content · not written') && !failedWrite.includes('class="diff-row added"') && failedWrite.includes('class="action-verb">Failed writing</span>'), 'a failed write never looks like a created file: ' + failedWrite);
  const big = lineDiff(Array.from({ length: 301 }, (_, i) => `l${i}`).join('\n'), 'x');
  assert.equal(big.filter(r => r.kind === 'removed').length, 301); assert.equal(big.filter(r => r.kind === 'added').length, 1);
  const user = renderToStaticMarkup(createElement(MessageRow, { message: { id: 'u', role: 'user', text: 'Hello', at: 1_726_000_000_000 }, notify: () => {} }));
  assert.ok(user.includes(`class="stamp" dateTime="2024-09-10T`) && user.includes(`>${formatClock(1_726_000_000_000)}<`), user);
  assert.ok(!renderToStaticMarkup(createElement(MessageRow, { message: { id: 'a', role: 'assistant', text: 'Hi', at: 1_726_000_000_000 }, notify: () => {} })).includes('class="stamp"'), 'replies keep their stamps on the turn line');
  assert.equal(reasoningTeaser('  First thought here. Then more.  '), 'First thought here.');
  assert.equal(reasoningTeaser('x'.repeat(120)), 'x'.repeat(89) + '…'); assert.equal(reasoningTeaser('   '), null);
  assert.match(formatClock(1_726_000_000_000), /^\d{2}:\d{2}:\d{2}$/);
});

test('rows new since the last paint animate in and a just-settled turn glows; restored pages arrive still', () => {
  const messages: Message[] = [
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a', role: 'assistant', text: 'Done', at: 2_000 },
    { id: 'u2', role: 'user', text: 'More', at: 3_000 },
    { id: 'a2', role: 'assistant', text: 'Again', at: 4_000 },
  ];
  const still = renderToStaticMarkup(createElement(TranscriptItems, { items: blocksOf(messages), notify: () => undefined }));
  assert.ok(!still.includes('fresh') && !still.includes('settled'), 'without a fresh set nothing moves');
  const moving = renderToStaticMarkup(createElement(TranscriptItems, { items: blocksOf(messages), notify: () => undefined, fresh: new Set(['u2', 'a2']) }));
  assert.equal((moving.match(/class="user fresh"/g) ?? []).length, 1, 'only the new user row is fresh');
  assert.ok(moving.includes('class="block fresh"') && moving.includes('class="block-footer merged-turn settled'), 'the new reply\'s block animates and its merged turn line glows: ' + moving);
  assert.ok(moving.indexOf('data-message-id="a"') < moving.indexOf('class="block fresh"'), 'the earlier reply stays still');
  const twoReplies = blocksOf([...messages.slice(0, 1), { id: 'b1', role: 'assistant', text: 'One', at: 1_500 }, { id: 'b2', role: 'assistant', text: 'Two', at: 2_000 }]);
  const settledLine = renderToStaticMarkup(createElement(TranscriptItems, { items: twoReplies, notify: () => undefined, fresh: new Set(['b2']) }));
  assert.ok(settledLine.includes('class="turn-total settled"'), 'a multi-reply turn line glows when its last reply is new');
  const live = renderToStaticMarkup(createElement(TranscriptItems, { items: blocksOf([messages[0]!, { id: 's', role: 'assistant', text: '', state: 'streaming' }]), notify: () => undefined, fresh: new Set(['s']) }));
  assert.ok(live.includes('class="turn-total live"') && live.includes('class="turn-since">since ') && !live.includes('settled'), 'a live turn shows when it started and does not glow yet');
});

test('code blocks name their language beside the copy control', () => {
  const html = renderToStaticMarkup(createElement(SafeMarkdown, { text: 'Look:\n\n```swift\nlet a = 1\n```\n\nand\n\n```\nplain\n```\n', onCopy: async () => true }));
  assert.ok(html.includes('class="code-lang" aria-label="Language swift">swift<'), html);
  assert.equal((html.match(/class="code-lang"/g) ?? []).length, 1, 'a fence without a language has no label');
});

test('failures and notices render inside the conversation flow', () => {
  const failure = renderToStaticMarkup(createElement(MessageRow, { message: { id: 'failure:s', role: 'system', text: 'Failed after 3 attempts. Provider returned HTTP 503.', kind: 'failure', detail: 'Queued follow-ups are paused.' }, notify: () => undefined }));
  assert.ok(failure.includes('class="system failure"') && failure.includes('role="alert"'), failure);
  assert.ok(failure.includes('Something went wrong') && failure.includes('Failed after 3 attempts. Provider returned HTTP 503.') && failure.includes('Queued follow-ups are paused.'));
  assert.ok(!failure.includes('class="body"'), 'a failure is a card, not a system pill');
  const notice = renderToStaticMarkup(createElement(MessageRow, { message: { id: 'notice:s', role: 'system', text: 'Retrying (attempt 2 of 3)', kind: 'notice' }, notify: () => undefined }));
  assert.ok(notice.includes('class="system notice-row"') && notice.includes('role="status"') && notice.includes('Retrying (attempt 2 of 3)'));
  assert.ok(notice.includes('class="spinner"'), 'a retry notice turns while it waits');
  const items = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a', role: 'assistant', text: 'Half', at: 2_000, state: 'error' },
    { id: 'failure:s', role: 'system', text: 'Failed', kind: 'failure' },
  ]);
  assert.deepEqual(items.map(item => item.kind), ['message', 'block', 'message'], 'a failure row follows the reply it interrupted and never folds into a block');
});

test('activity descriptions, summaries and durations read as verb and object', () => {
  const bash = { id: 'b', name: 'bash', state: 'completed', input: '{"command":"npm test -- --watch=false\\necho done"}', output: '', durationMs: 1234, truncated: false };
  const edit = { id: 'e', name: 'edit', state: 'completed', input: '{"path":"/repo/Sources/App/Retry.swift","oldText":"a","newText":"b"}', output: 'Edited', durationMs: 5, truncated: false, path: '/repo/Sources/App/Retry.swift', added: 11, removed: 3 };
  const created = { ...edit, id: 'w', name: 'write', added: 40, removed: 0 };
  assert.deepEqual(describeTool(bash), { kind: 'command', verb: 'Ran', object: 'npm test -- --watch=false' });
  assert.deepEqual(describeTool(edit), { kind: 'write', verb: 'Edited', object: 'App/Retry.swift', path: '/repo/Sources/App/Retry.swift' });
  assert.equal(describeTool(created).verb, 'Created');
  assert.equal(describeTool({ ...bash, id: 'g', name: 'grep', input: '{"pattern":"TODO"}' }).object, 'TODO');
  assert.equal(describeTool({ ...bash, id: 'm', name: 'mcp', input: '{"server":"fixture","tool":"echo"}' }).object, 'fixture · echo');
  assert.equal(summarizeActivity([bash, edit, created, { ...bash, id: 'r', name: 'read', input: '{"path":"x"}' }]), 'Edited 1 file, ran 1 command, read 1 file', 'two calls on one path are one file');
  assert.equal(summarizeActivity([bash, edit, { ...created, path: '/repo/Sources/App/New.swift' }]), 'Edited 2 files, ran 1 command');
  const read = (id: string, path: string, state = 'completed') => ({ ...bash, id, name: 'read', state, input: JSON.stringify({ path }) });
  assert.equal(summarizeActivity([read('r1', 'a'), read('r2', 'a'), read('r3', 'a')]), 'Read 1 file', 'three reads of one file are one file, not three');
  assert.equal(summarizeActivity([read('r1', 'a'), { ...bash, id: 'l', name: 'ls', input: '{"path":"/repo"}' }]), 'Read 1 file, listed 1 directory', 'a listing is not a file read');
  assert.equal(summarizeActivity([edit, { ...edit, id: 'e2', state: 'failed' }, read('r4', 'b', 'cancelled'), read('r5', 'c', 'running')]), 'Edited 1 file, 1 call failed, 1 call skipped', 'failed and skipped calls are attempts, never work done; a running one waits');
  assert.equal(describeTool({ ...bash, state: 'running' }).verb, 'Running'); assert.equal(describeTool({ ...edit, state: 'failed' }).verb, 'Failed editing'); assert.equal(describeTool(read('r6', 'x', 'cancelled')).verb, 'Skipped reading');
  assert.deepEqual([actionOutcome(bash), actionOutcome({ ...bash, state: 'preparing' }), actionOutcome({ ...bash, state: 'failed' }), actionOutcome({ ...bash, state: 'cancelled' })], ['done', 'running', 'failed', 'cancelled']);
  assert.deepEqual(describeTool({ ...bash, id: 'm1', name: 'mcp', input: '{"action":"list"}' }), { kind: 'mcp', verb: 'Listed', object: 'MCP servers' });
  assert.deepEqual(describeTool({ ...bash, id: 'm2', name: 'mcp', input: '{"action":"list","server":"fixture"}' }), { kind: 'mcp', verb: 'Listed', object: 'tools on fixture' });
  assert.deepEqual(describeTool({ ...bash, id: 'm3', name: 'mcp', input: '{"action":"describe","targets":[{"server":"a","tool":"x"},{"server":"a","tool":"y"}]}' }), { kind: 'mcp', verb: 'Loaded', object: '2 tool schemas' });
  assert.deepEqual(describeTool({ ...bash, id: 'm4', name: 'mcp', state: 'running', input: '{"action":"invoke","server":"fixture","tool":"echo","arguments":{}}' }), { kind: 'mcp', verb: 'Calling', object: 'fixture · echo' });
  assert.equal(changedFiles([edit, created, { ...edit, id: 'e3', state: 'failed', path: '/other.swift' }]), 1, 'only completed edits count toward files changed');
  assert.equal(formatDuration(400), '0.4s'); assert.equal(formatDuration(72_000), '1m 12s'); assert.equal(formatDuration(3_753_000), '1h 2m');
});

test('action rows start collapsed, keep status, diff counts, output and truncation in their card', () => {
  for (const state of ['running', 'completed', 'failed', 'cancelled', 'recorded']) {
    const html = renderToStaticMarkup(createElement(ActionRow, { tool: { id: 'call', name: 'bash', state, input: '{"command":"pwd"}', output: 'Output preview', durationMs: 120, truncated: true } }));
    assert.ok(!html.match(/<details[^>]*\bopen\b/), state + ' must not force details open');
    assert.ok(html.includes(`class="action-verb">${state === 'running' ? 'Running' : state === 'failed' ? 'Failed running' : state === 'cancelled' ? 'Skipped running' : 'Ran'}</span>`), state + ' names its outcome in the verb');
    assert.ok(html.includes('>pwd</span>'));
    assert.ok(html.includes('$ pwd'));
    assert.ok(html.includes('Output preview'));
    assert.ok(html.includes('Preview truncated.'));
    if (state === 'failed' || state === 'cancelled') assert.ok(html.includes('class="action-state failed"'), state);
    if (state === 'running') assert.ok(html.includes('Running…'), state); else assert.ok(html.includes('0.1s'), state);
  }
  const edited = renderToStaticMarkup(createElement(ActionRow, { tool: { id: 'e', name: 'edit', state: 'completed', input: '{"path":"/a/b.swift"}', output: '', durationMs: null, truncated: false, added: 11, removed: 0 } }));
  assert.ok(edited.includes('<span class="added">+11</span>') && edited.includes('<span class="removed">-0</span>'));
  assert.ok(edited.includes('No output'));
  const group = renderToStaticMarkup(createElement(ActivityGroup, { tools: [{ id: 'r', name: 'bash', state: 'running', input: '{"command":"sleep 1"}', output: '', durationMs: null, truncated: false }] }));
  assert.ok(group.includes('class="activity running"') && group.includes('class="action-verb">Running</span>') && group.includes('>sleep 1</span>'), 'an expanded group lists its rows directly');
  assert.ok(!group.match(/<details[^>]*\bopen\b/), 'rows keep their request and response closed until clicked');
});

test('blocks keep their key while the reply arrives, and status rows never split a turn', () => {
  const activityOnly = { id: 'a1', role: 'assistant', text: '', turn: 'u', tools: [{ id: 't1', name: 'read', state: 'completed', input: '{"path":"a"}', output: '', durationMs: 1, truncated: false }] };
  const before = blocksOf([{ id: 'u', role: 'user', text: 'Go', turn: 'u' }, activityOnly]);
  const after = blocksOf([{ id: 'u', role: 'user', text: 'Go', turn: 'u' }, activityOnly, { id: 'a2', role: 'assistant', text: 'Done', turn: 'u' }]);
  const only = (items: ReturnType<typeof blocksOf>) => items.flatMap(item => item.kind === 'block' ? [item.block] : []);
  assert.equal(only(before)[0]!.key, 'block:a1'); assert.equal(only(after)[0]!.key, 'block:a1', 'the key stays with the first row, so React keeps the block mounted and open');
  assert.equal(only(after)[0]!.id, 'a2', 'the id still follows the reply for anchors');
  assert.equal(only(after)[0]!.turnID, 'u');
  const keyed = renderToStaticMarkup(createElement(TranscriptItems, { items: after, notify: () => undefined }));
  assert.ok(keyed.includes('data-block-id="a2"'), keyed);
  const interrupted = blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000, turn: 'u' },
    { id: 'a1', role: 'assistant', text: 'First', at: 2_000, turn: 'u', tools: [{ id: 't1', name: 'edit', state: 'completed', input: '{"path":"a"}', output: '', durationMs: 1, truncated: false, path: '/repo/a' }] },
    { id: 'c', role: 'system', text: 'Conversation summary', kind: 'compaction', at: 2_500 },
    { id: 'n', role: 'system', text: 'Retrying (attempt 2 of 3)', kind: 'notice' },
    { id: 'a2', role: 'assistant', text: 'Second', at: 4_000, turn: 'u' },
    { id: 'f', role: 'system', text: 'Run failed.', kind: 'failure' },
    { id: 'u2', role: 'user', text: 'More', at: 9_000, turn: 'u2' },
    { id: 'a3', role: 'assistant', text: 'Third', at: 9_500, turn: 'u2' },
  ]);
  const blocks = only(interrupted);
  assert.deepEqual(blocks.map(block => block.turn?.replies ?? 0), [0, 2, 1], 'a compaction summary, a retry notice and a failure sit inside the turn instead of ending it');
  assert.equal(blocks[1]!.turn?.files, 1); assert.equal(blocks[1]!.turn?.partial, false); assert.equal(blocks[2]!.turn?.partial, false);
  assert.ok(renderToStaticMarkup(createElement(BlockView, { block: blocks[1]!, notify: () => undefined })).includes('2 replies, 1 tool call, 1 file changed'), 'the turn line counts files changed');
  const plainSystem = only(blocksOf([{ id: 'u', role: 'user', text: 'Go' }, { id: 'a1', role: 'assistant', text: 'One' }, { id: 's', role: 'system', text: 'Imported context' }, { id: 'a2', role: 'assistant', text: 'Two' }]));
  assert.deepEqual(plainSystem.map(block => block.turn?.replies ?? 0), [1, 1], 'a plain system row still separates turns, as before');
  const midHistory = only(blocksOf([
    { id: 'a1', role: 'assistant', text: 'Late in turn one', at: 1_000, turn: 't1' },
    { id: 'a2', role: 'assistant', text: 'Turn two', at: 2_000, turn: 't2' },
    { id: 'u3', role: 'user', text: 'Three', at: 3_000, turn: 't3' },
    { id: 'a3', role: 'assistant', text: 'Turn three', at: 4_000, turn: 't3' },
  ]));
  assert.deepEqual(midHistory.map(block => [block.turn?.replies ?? 0, block.turn?.partial ?? null]), [[1, true], [1, true], [1, false]], 'host turn ids separate replies with no user row between them and mark turns that began before the loaded page');
  assert.ok(renderToStaticMarkup(createElement(BlockView, { block: midHistory[0]!, notify: () => undefined })).includes('Turn (partial)'), 'a partial turn says so');
  const measured = only(blocksOf([
    { id: 'u', role: 'user', text: 'Go', at: 1_000 },
    { id: 'a1', role: 'assistant', text: 'Reply', at: 5_000, modelMs: 700 },
  ]));
  assert.equal(measured[0]!.modelMs, 700, 'the host\'s request timing wins over the gap between rows');
  assert.equal(measured[0]!.turn?.modelMs, 700);
});

test('legacy tool-call disclosure is gone from rows', () => {
  for (const state of ['running', 'completed', 'error', 'aborted', 'recorded']) {
    const html = renderMessages([{ id: 'assistant', role: 'assistant', text: '', tools: [
      { id: 'call', name: 'bash', state, input: '{"command":"pwd"}', output: 'Output preview', durationMs: 120, truncated: true },
    ] }]);
    assert.ok(!html.includes('<details class="tool-call"'), state);
    assert.ok(html.includes('data-message-id="assistant"'), 'the article survives for anchors and read receipts');
  }
});


test('standalone tool results keep output and truncation inside a closed disclosure without hiding actions', () => {
  const html = renderMessages([{ id: 'result', role: 'tool', state: 'error', text: '<script>tool failed</script>', truncated: true }]);
  const disclosure = html.match(/<details class="tool-result"[^>]*>([\s\S]*?)<\/details>/)!;
  assert.ok(disclosure);
  assert.ok(!disclosure[0].match(/^<details[^>]*\bopen\b/));
  assert.ok(disclosure[1]!.startsWith('<summary><span class="name">Tool result</span>'));
  assert.ok(disclosure[1]!.includes('class="state error">error</span></summary>'));
  assert.ok(disclosure[1]!.includes('&lt;script&gt;tool failed&lt;/script&gt;'));
  assert.ok(disclosure[1]!.includes('Display preview truncated.'));
  assert.ok(!html.includes('<script>'));
  const outside = html.replace(disclosure[0], '');
  assert.ok(!outside.includes('tool failed'));
  assert.ok(outside.includes('aria-label="Copy tool message"'));
  assert.ok(outside.includes('aria-label="Inspect requests for tool message"'));
});

test('Responses token summary counts reasoning within output and preserves a null cost', () => {
  const presentation = accountingPresentation(reportedAccounting({ costUSD: null, costSamples: 0 }));
  assert.equal(presentation.summary, '38 in · 0 cached · 423 out · 461 total', 'an unreported cost is left out rather than named');
  assert.equal(accountingPresentation({ requests: 1, costSamples: 0, cacheHits: 0, cacheMisses: 0, cacheUnreported: 1, cacheConflicts: 0, cacheReadSamples: 0, cacheWriteSamples: 0, models: { names: [], nameCount: 0, reportedRequests: 0, unreportedRequests: 1, conflictingRequests: 0, incompleteRequests: 0 } }).summary, '', 'nothing reported means no line at all');
  assert.equal(renderToStaticMarkup(createElement(MessageAccounting, { accounting: { requests: 1, costSamples: 0, cacheHits: 0, cacheMisses: 0, cacheUnreported: 1, cacheConflicts: 0, cacheReadSamples: 0, cacheWriteSamples: 0 }, onInspect: () => undefined })), '');
  assert.ok(presentation.detail.includes('Uncached input: 38'));
  assert.ok(presentation.detail.includes('Output includes reasoning tokens; they are not added again'));
  assert.ok(presentation.detail.includes('cost 0/1 requests reported'));
  assert.ok(!presentation.summary.includes('$0'));
});

test('reasoning token and cost breakdowns remain subsets of the supplied totals', () => {
  const presentation = accountingPresentation(reportedAccounting({ costUSD: 0.0013875, reasoningCostUSD: 0.0011385, reasoningCostSamples: 1,
    tokens: { input: 38, output: 302, total: 340, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 253, reasoningSamples: 1 } }));
  assert.equal(presentation.summary, '38 in · 0 cached · 302 out (253 reasoning) · 340 total · $0.0013875 USD');
  assert.ok(presentation.detail.includes('Reasoning cost: $0.0011385 USD (1/1 reported), a per-request output-cost breakdown, never added to total cost'));
  assert.ok(!presentation.summary.includes('593')); assert.ok(!presentation.summary.includes('$0.002526'));
  const legacy = accountingPresentation(reportedAccounting());
  assert.ok(legacy.detail.includes('Reasoning: tokens unavailable'));
  assert.ok(!legacy.summary.includes('reasoning'));
});

test('missing usage stays unavailable and absent cache data never becomes uncached input', () => {
  const missing = reportedAccounting({ tokens: null, costSamples: 0, costUSD: null, cacheReadTokens: null, cacheWriteTokens: null, cacheReadSamples: 0, cacheWriteSamples: 0, cacheMisses: 0, cacheUnreported: 1 });
  const presentation = accountingPresentation(missing);
  assert.equal(presentation.summary, '', 'unreported figures are left out of the line; the detail still explains them');
  assert.ok(presentation.detail.includes('Response cache: 1 unreported'));
  assert.equal(uncachedInput(missing), null);
  assert.equal(uncachedInput(reportedAccounting({ cacheReadTokens: null, cacheReadSamples: 0 })), null);
  assert.equal(uncachedInput(reportedAccounting({ cacheReadTokens: 39 })), null);
  assert.equal(uncachedInput(reportedAccounting()), 38);
});

test('partial coverage is visible and independently reported token aggregates are not subtracted', () => {
  const partial = reportedAccounting({ requests: 2, cacheReadTokens: 10, cacheMisses: 1, cacheUnreported: 1 });
  const presentation = accountingPresentation(partial);
  assert.equal(presentation.summary, '38 in (1/2) · 10 cached (1/2) · 423 out (1/2) · 461 total (1/2) · $0.00042188 USD (1/2)');
  assert.equal(uncachedInput(partial), null);
  assert.ok(presentation.detail.includes('Partial totals include only reported requests'));
  assert.ok(presentation.detail.includes('Prompt-cache read 10 tokens (1/2 reported)'));
});
test('paired request-level uncached counters retain partial coverage without subtracting unrelated aggregate samples', () => {
  const partial = reportedAccounting({ requests: 3, cacheReadTokens: 120, cacheReadSamples: 2,
    tokens: { input: 500, output: null, total: null, inputSamples: 2, outputSamples: 0, samples: 0 },
    uncachedInputReportedTokens: 30, uncachedInputSamples: 1, costUSD: 0.001, costSamples: 1,
    reasoningCostUSD: 0.002, reasoningCostSamples: 2 });
  const presentation = accountingPresentation(partial);
  assert.equal(uncachedInput(partial), 30);
  assert.ok(presentation.detail.includes('Uncached input: 30 (1/3)'));
  assert.ok(presentation.detail.includes('Its reporting coverage may differ'));
  assert.ok(!presentation.detail.includes('included in total cost'));
  assert.equal(uncachedInput({ ...partial, uncachedInputSamples: 0, uncachedInputReportedTokens: null }), null);
});

test('zero and very small positive reported costs remain distinct from unavailable values', () => {
  assert.ok(accountingPresentation(reportedAccounting({ costUSD: 0 })).summary.endsWith('$0 USD'));
  assert.ok(accountingPresentation(reportedAccounting({ costUSD: 1e-10 })).summary.endsWith('$1.00e-10 USD'));
  assert.ok(!accountingPresentation(reportedAccounting({ costUSD: -1 })).summary.includes('USD'), 'an invalid cost is left out');
  assert.ok(!accountingPresentation(reportedAccounting({ costSamples: 0 })).summary.includes('USD'), 'an unreported cost is left out');
});

test('assistant status shows the gateway-resolved model once after inline ownership moves', () => {
  const models = { names: ['gpt-5.4-mini'], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0 };
  const accounting = reportedAccounting({ models });
  const presentation = accountingPresentation(accounting);
  assert.ok(presentation.summary.startsWith('gpt-5.4-mini · 38 in'));
  assert.ok(presentation.detail.includes('The response body supplies the displayed name when available'));
  const html = renderMessages([{ id: 'u', role: 'user', text: 'Question' }, { id: 'a', role: 'assistant', text: 'Answer', accounting }]);
  assert.equal(accountingLines(html), 1);
  assert.ok(html.indexOf('gpt-5.4-mini') > html.indexOf('Inspect requests for user message'));
  assert.ok(!html.includes('auto-router'));
});

test('mixed model status displays one body name and keeps identity differences in details', () => {
  const models = { names: ['one', 'two', 'three'], nameCount: 3, reportedRequests: 4, unreportedRequests: 1, conflictingRequests: 1, incompleteRequests: 1 };
  const presentation = accountingPresentation(reportedAccounting({ requests: 7, models }));
  assert.ok(presentation.summary.startsWith('one · 38 in'));
  assert.ok(!presentation.summary.includes('Model conflict')); assert.ok(!presentation.summary.includes('Model incomplete'));
  assert.ok(!presentation.summary.includes('two')); assert.ok(!presentation.summary.includes('three'));
  assert.ok(presentation.detail.includes('Reported models: one, two, three.'));
  assert.ok(presentation.detail.includes('Resolved identity 4/7'));
  const unknown = accountingPresentation(reportedAccounting({ models: { names: [], nameCount: 0, reportedRequests: 0, unreportedRequests: 1, conflictingRequests: 0, incompleteRequests: 0 } }));
  assert.ok(!unknown.summary.includes('Model not reported') && unknown.summary.startsWith('38 in'), 'an unreported model is left out; the usage stands alone');
});

test('clicking the displayed body model opens the same native message details as its request action', () => {
  const accounting = reportedAccounting({ models: { names: ['gpt-5.4-mini'], nameCount: 1, reportedRequests: 0,
    unreportedRequests: 0, conflictingRequests: 1, incompleteRequests: 0, displayRequests: 1 } });
  assert.equal(validModelSummary(accounting.models, 1), true);
  const presentation = accountingPresentation(accounting);
  assert.ok(presentation.summary.startsWith('gpt-5.4-mini · ')); assert.ok(!presentation.summary.includes('conflict'));
  const calls: unknown[] = [];
  // Follow the actual React row's model-button callback; no browser bridge or
  // HTTP body enters the transcript. The native details already own those.
  const renderRow = (MessageRow as unknown as { type: (props: { message: Message; notify: (...args: unknown[]) => void }) => ReactElement }).type;
  const row = renderRow({ message: { id: 'assistant-model', role: 'assistant', text: 'Answer', accounting }, notify: (...args) => { calls.push(args); } });
  function find(node: ReactNode, predicate: (value: ReactElement<Record<string, unknown>>) => boolean): ReactElement<Record<string, unknown>> | undefined {
    if (Array.isArray(node)) return node.map(child => find(child, predicate)).find(Boolean);
    if (!isValidElement<Record<string, unknown>>(node)) return undefined;
    return predicate(node) ? node : find(node.props.children as ReactNode, predicate);
  }
  const component = find(row, node => node.type === MessageAccounting)!;
  assert.ok(component);
  const rendered = MessageAccounting(component.props as Parameters<typeof MessageAccounting>[0]);
  const button = find(rendered, node => node.type === 'button')!;
  assert.equal(button.props['aria-label'], 'View model reports: gpt-5.4-mini');
  (button.props.onClick as () => void)();
  assert.deepEqual(calls, [['inspectRequests', { id: 'assistant-model' }]]);
  const html = renderMessages([{ id: 'assistant-model', role: 'assistant', text: 'Answer', accounting }]);
  assert.ok(html.includes('class="message-model-link"')); assert.ok(!html.includes('Model conflict'));
});

test('the model identity bridge rejects unbounded or inconsistent metadata and escapes reported names', () => {
  const models = { names: ['model'], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0 };
  assert.equal(validModelSummary(models, 1), true);
  for (const invalid of [
    null, [], { ...models, names: ['same', 'same'], nameCount: 2 },
    { ...models, names: ['x'.repeat(257)] }, { ...models, names: ['line\nbreak'] },
    { ...models, nameCount: 0 }, { ...models, unreportedRequests: 1 },
    { ...models, displayRequests: -1 }, { ...models, displayRequests: 2 }, { ...models, displayRequests: 0 },
    { ...models, displayRequests: 0.5 }, { ...models, names: ['  '] },
    { ...models, names: Array.from({ length: 9 }, (_, i) => String(i)), nameCount: 9, reportedRequests: 9 },
  ]) assert.equal(validModelSummary(invalid, 1), false);
  const many = { ...models, names: Array.from({ length: 8 }, (_, i) => 'model-' + i), nameCount: 20, reportedRequests: 20 };
  assert.equal(validModelSummary(many, 20), true);
  assert.equal(validModelSummary({ ...models, reportedRequests: 0, conflictingRequests: 1, displayRequests: 1 }, 1), true);
  assert.equal(validModelSummary({ ...models, reportedRequests: 0, conflictingRequests: 1 }, 1), false, 'Legacy summaries require verified model coverage');
  const html = renderMessages([{ id: 'a', role: 'assistant', text: 'Answer', accounting: reportedAccounting({ models: { ...models, names: ['<script>model</script>'] } }) }]);
  assert.ok(!html.includes('<script>')); assert.ok(html.includes('&lt;script&gt;model&lt;/script&gt;'));
});

test('retained messages without accounting and compaction markers keep content and detail actions', () => {
  const html = renderMessages([
    { id: 'inherited-user', role: 'user', text: 'Earlier question' },
    { id: 'inherited-answer', role: 'assistant', text: 'Earlier answer', thinking: 'Visible summary' },
    { id: 'compacted', role: 'system', kind: 'compaction', text: 'Retained summary', accounting: reportedAccounting() },
    { id: 'branch', role: 'system', kind: 'branch', text: 'A revised question' },
  ]);
  assert.equal(accountingLines(html), 1);
  assert.equal((html.match(/>Details<\/button>/g) ?? []).length, 3);
  for (const text of ['Earlier question', 'Earlier answer', 'Context compacted', 'Retained summary', 'Edited from here']) assert.ok(html.includes(text));
  assert.ok(!html.includes('Visible summary'), 'exposed reasoning belongs to the reply\'s folded work line, not the row');
});
test('frame delivery conflates bursts, acknowledges only rendered cutoffs and stays bounded while paint tasks stall',()=>{
  let id=0;const frames=new Map<number,()=>void>(),tasks=new Map<number,()=>void>(),rendered:number[]=[],painted:number[]=[];
  const queue=frameConflator<number>(n=>rendered.push(n),n=>painted.push(n),{
    frame:f=>{frames.set(++id,f);return id;},cancelFrame:n=>{frames.delete(n);},task:f=>{tasks.set(++id,f);return id;},cancelTask:n=>{tasks.delete(n);},
  });
  const drain=(map:Map<number,()=>void>)=>{const first=map.entries().next().value!;map.delete(first[0]);first[1]();};
  for(let n=0;n<1000;n++)queue.push(n);
  assert.equal(frames.size,1);drain(frames);assert.deepEqual(rendered,[999]);assert.deepEqual(painted,[]);
  queue.push(1000);drain(frames);for(let n=1001;n<2000;n++)queue.push(n);
  assert.equal(tasks.size,2);assert.equal(frames.size,0);
  drain(tasks);assert.deepEqual(painted,[999]);assert.equal(frames.size,1);drain(frames);assert.deepEqual(rendered,[999,1000,1999]);
  queue.dispose();assert.equal(tasks.size,0);queue.push(2000);assert.equal(frames.size,0);
});
test('a committed error fallback is never acknowledged as a painted transcript and later snapshots recover',()=>{
  let id=0;
  const frames=new Map<number,()=>void>(),tasks=new Map<number,()=>void>(),painted:number[]=[];
  const queue=frameConflator<number>(value=>value!==1,value=>painted.push(value),{
    frame:run=>{frames.set(++id,run);return id;},cancelFrame:key=>{frames.delete(key);},
    task:run=>{tasks.set(++id,run);return id;},cancelTask:key=>{tasks.delete(key);},
  });
  const drain=(map:Map<number,()=>void>)=>{const [key,run]=map.entries().next().value!;map.delete(key);run();};
  queue.push(1);drain(frames);
  assert.equal(tasks.size,0);assert.deepEqual(painted,[]);
  queue.push(2);drain(frames);drain(tasks);
  assert.deepEqual(painted,[2]);
  queue.dispose();
});
test('bounded bundled highlighting escapes code, handles unfinished fences and preserves long code as text',()=>{
  const code='const x = "<img src=x onerror=alert(1)>";\nconst earth = "🌍";';
  const html=highlightCode(code,'typescript')!;
  assert.ok(html.includes('hljs-keyword'));assert.ok(!html.includes('<img'));assert.ok(html.includes('&lt;img'));assert.ok(html.includes('🌍'));
  assert.equal(highlightCode(code,'unknown'),null);assert.equal(highlightCode('x'.repeat(16385),'ts'),null);
  const rendered=renderToStaticMarkup(createElement(SafeMarkdown,{text:'```ts\n'+code+'x'.repeat(100000)}));
  assert.ok(rendered.includes('x'.repeat(100000)));assert.ok(!rendered.includes('<img'));
});
test('Markdown never enables raw HTML, executable URLs, credential URLs, or automatic remote images', () => {
  const html = renderToStaticMarkup(createElement(SafeMarkdown, { text: '<script>window.pwned=1</script>\n\n[run](javascript:alert%281%29) ![tracking](https://evil.example/pixel) [bad](https://secret:pass@evil.example) [good](https://example.com/page)\n\n```js\n<script>text</script>\n```' }));
  assert.ok(!html.includes('<script>')); assert.ok(!html.includes('<img')); assert.ok(!html.includes('javascript:'));
  assert.ok(!html.includes('secret:pass')); assert.ok(html.includes('href="https://example.com/page"'));
  assert.ok(html.includes('&lt;script&gt;text&lt;/script&gt;')); assert.ok(html.includes('[Image not loaded: tracking]'));
  for (const value of ['file:///etc/passwd', 'data:text/html,x', '//evil.example', 'https://name:secret@evil.example', 'javascript:alert(1)']) assert.equal(safeURL(value), '');
});
