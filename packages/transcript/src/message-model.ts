export interface Tool {
  id: string; name: string; state: string; input: string; output: string;
  durationMs: number | null; truncated: boolean;
  /** File tools: the resolved path and approximate line counts changed. */
  path?: string | null; added?: number | null; removed?: number | null;
}

export interface TokenTotals {
  input?: number | null; output?: number | null; total?: number | null;
  inputSamples: number; outputSamples: number; samples: number;
  reasoning?: number | null; reasoningSamples?: number | null;
}

export interface ModelSummary {
  names: string[]; nameCount: number; reportedRequests: number;
  unreportedRequests: number; conflictingRequests: number; incompleteRequests: number;
  /** Names can come from a body even when header/body identity differs. */
  displayRequests?: number | null;
}

/** Accept only the bounded native identity projection, never arbitrary evidence. */
export function validModelSummary(value: unknown, requests: number): value is ModelSummary {
  if (typeof value !== 'object' || value === null) return false;
  const m = value as Partial<ModelSummary>;
  const displayRequests = m.displayRequests ?? m.reportedRequests;
  const counts = [m.nameCount, m.reportedRequests, m.unreportedRequests, m.conflictingRequests, m.incompleteRequests];
  if (!counts.every(n => Number.isSafeInteger(n) && n! >= 0 && n! <= requests) ||
      m.reportedRequests! + m.unreportedRequests! + m.conflictingRequests! + m.incompleteRequests! !== requests ||
      !Array.isArray(m.names) || m.names.length !== Math.min(8, m.nameCount!) || new Set(m.names).size !== m.names.length ||
      m.names.some(name => typeof name !== 'string' || name.trim().length === 0 || new TextEncoder().encode(name).length > 256 || /[\x00-\x1f\x7f]/u.test(name)) ||
      !Number.isSafeInteger(displayRequests) || displayRequests! < 0 || displayRequests! > requests) return false;
  return m.nameCount! <= displayRequests! && (displayRequests === 0) === (m.nameCount === 0);
}

/** A native-selected, non-overlapping set of attempts for this visible row. */
export interface Accounting {
  requests: number; costSamples: number; costUSD?: number | null;
  cacheHits: number; cacheMisses: number; cacheUnreported: number; cacheConflicts: number;
  cacheReadTokens?: number | null; cacheWriteTokens?: number | null;
  cacheReadSamples: number; cacheWriteSamples: number; tokens?: TokenTotals | null;
  uncachedInputReportedTokens?: number | null; uncachedInputSamples?: number | null;
  reasoningCostUSD?: number | null; reasoningCostSamples?: number | null;
  models?: ModelSummary | null;
}

export type MessageKind = 'compaction' | 'branch' | 'failure' | 'notice';
export interface Message {
  id: string; role: string; text: string; thinking?: string; tools?: Tool[];
  state?: string; truncated?: boolean; accounting?: Accounting | null;
  kind?: MessageKind | null; detail?: string | null;
  /** Milliseconds since 1970 when the host appended the message. */
  at?: number | null;
  /** The turn (user message id) the host appended the row under; rows from older journals have none. */
  turn?: string | null;
  /** Assistant rows: the model request's duration in milliseconds, as the host measured it. */
  modelMs?: number | null;
}

import type { CopyContentRequest } from './copy-requests.ts';
export type MessageAction = 'editMessage' | 'copyMessage' | 'inspectRequests' | 'copyContent' | 'stop';
export type NotifyMessageAction = (type: MessageAction, fields: { id: string } | CopyContentRequest) => void | Promise<boolean>;
