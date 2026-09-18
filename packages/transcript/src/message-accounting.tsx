import type { Accounting } from './message-model.ts';

const numeric = (value: number | null | undefined): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const formatTokens = (value: number): string => value.toLocaleString('en-US', { maximumFractionDigits: 0 });
const formatCost = (value: number): string => `$${value === 0 ? '0' : value < 1e-8 ? value.toPrecision(3) : value.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 8 })} USD`;
const coverage = (samples: number, requests: number): string => samples < requests ? ` (${samples}/${requests})` : '';

/** Do not infer missing cache counters or subtract aggregates with different coverage. */
export function uncachedInput(accounting: Accounting): number | null {
  if (accounting.uncachedInputSamples != null) {
    return accounting.uncachedInputSamples > 0 && numeric(accounting.uncachedInputReportedTokens) ? accounting.uncachedInputReportedTokens : null;
  }
  const tokens = accounting.tokens;
  if (!tokens || !numeric(tokens.input) || !numeric(accounting.cacheReadTokens) ||
      tokens.inputSamples !== accounting.requests || accounting.cacheReadSamples !== accounting.requests ||
      accounting.cacheReadTokens > tokens.input) return null;
  return tokens.input - accounting.cacheReadTokens;
}

/** The line shows only what the gateway reported; unreported figures are left out rather than named. */
export function accountingPresentation(a: Accounting): { summary: string; detail: string; modelLabel: string | null; usage: string } {
  const t = a.tokens;
  const input = t && t.inputSamples > 0 && numeric(t.input) ? `${formatTokens(t.input)} in${coverage(t.inputSamples, a.requests)}` : null;
  const reasoning = t && (t.reasoningSamples ?? 0) > 0 && numeric(t.reasoning) ? `${formatTokens(t.reasoning)} reasoning${coverage(t.reasoningSamples!, a.requests)}` : null;
  const output = t && t.outputSamples > 0 && numeric(t.output) ? `${formatTokens(t.output)} out${coverage(t.outputSamples, a.requests)}` + (reasoning ? ` (${reasoning})` : '') : null;
  const total = t && t.samples > 0 && numeric(t.total) ? `${formatTokens(t.total)} total${coverage(t.samples, a.requests)}` : null;
  const cached = a.cacheReadSamples > 0 && numeric(a.cacheReadTokens) ? `${formatTokens(a.cacheReadTokens)} cached${coverage(a.cacheReadSamples, a.requests)}` : null;
  const cost = a.costSamples > 0 && numeric(a.costUSD) ? `${formatCost(a.costUSD)}${coverage(a.costSamples, a.requests)}` : null;
  const reasoningCost = (a.reasoningCostSamples ?? 0) > 0 && numeric(a.reasoningCostUSD) ? formatCost(a.reasoningCostUSD) : 'unavailable';
  const uncached = uncachedInput(a);
  const responseCache = [a.cacheHits > 0 ? `${a.cacheHits} hit` : '', a.cacheMisses > 0 ? `${a.cacheMisses} miss` : '',
    a.cacheUnreported > 0 ? `${a.cacheUnreported} unreported` : '', a.cacheConflicts > 0 ? `${a.cacheConflicts} invalid/conflicting` : ''].filter(Boolean).join(', ') || 'unreported';
  const models = a.models;
  const modelLabel = models?.names[0] ?? null;
  const modelDetail = models ? [
    `Reported model${models.nameCount === 1 ? '' : 's'}: ${models.names.join(', ') || 'unavailable'}${models.nameCount > models.names.length ? `; ${models.nameCount - models.names.length} more (see Details)` : ''}.`,
    'The response body supplies the displayed name when available; older captures may retain a verified gateway name. Click the model to see response-body and header reports.',
    `Resolved identity ${models.reportedRequests}/${a.requests}; unreported ${models.unreportedRequests}, conflicting ${models.conflictingRequests}, incomplete ${models.incompleteRequests}. Displaying a body name does not change routing identity or accounting.`,
  ].join(' ') : null;
  const usage = [input, cached, output, total, cost].filter(Boolean).join(' · ');
  return {
    summary: [modelLabel, usage].filter(Boolean).join(' · '), modelLabel, usage,
    detail: [
      modelDetail,
      `Gateway-reported usage for ${a.requests} request${a.requests === 1 ? '' : 's'}. Each request appears once in the transcript. Details on the user message remain available.`,
      `Input includes cached tokens. Uncached input: ${uncached === null ? 'unavailable' : formatTokens(uncached) + coverage(a.uncachedInputSamples ?? a.requests, a.requests)}. Output includes reasoning tokens; they are not added again.`,
      `Reasoning: ${reasoning ?? 'tokens unavailable'} (${t?.reasoningSamples ?? 0}/${a.requests} requests reported). Reasoning cost: ${reasoningCost} (${a.reasoningCostSamples ?? 0}/${a.requests} reported), a per-request output-cost breakdown, never added to total cost. Its reporting coverage may differ.`,
      `Input ${t?.inputSamples ?? 0}/${a.requests}, output ${t?.outputSamples ?? 0}/${a.requests}, total ${t?.samples ?? 0}/${a.requests}, cost ${a.costSamples}/${a.requests} requests reported. Partial totals include only reported requests.`,
      `Prompt-cache read ${a.cacheReadSamples > 0 && numeric(a.cacheReadTokens) ? formatTokens(a.cacheReadTokens) : 'unavailable'} tokens (${a.cacheReadSamples}/${a.requests} reported); write ${a.cacheWriteSamples > 0 && numeric(a.cacheWriteTokens) ? formatTokens(a.cacheWriteTokens) : 'unavailable'} tokens (${a.cacheWriteSamples}/${a.requests} reported).`,
      `Response cache: ${responseCache}. Response-cache hits are separate from prompt-cache tokens.`,
    ].filter(Boolean).join('\n'),
  };
}

export function MessageAccounting({ accounting, onInspect }: { accounting: Accounting; onInspect: () => void }) {
  const { summary, detail, modelLabel, usage } = accountingPresentation(accounting);
  // Nothing reported means nothing to say; the Details button still opens the requests.
  if (!summary) return null;
  return <p className="message-accounting" title={detail} aria-label={`${summary}. ${detail}`}>
    {modelLabel && <><button className="message-model-link" type="button" onClick={onInspect} aria-label={`View model reports: ${modelLabel}`} title="View response-body and header models">{modelLabel}</button>{usage ? ' · ' : ''}</>}{usage}
  </p>;
}
