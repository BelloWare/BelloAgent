import { createHash, randomUUID } from 'node:crypto';
import { buildSessionContext, sessionEntryToContextMessages, type SessionEntry, type SessionManager } from '@earendil-works/pi-coding-agent';
import type { ResourceSnapshot } from '../resources/resolver.ts';
import { CommandError } from '../sessions/command-ledger.ts';

export const MAX_SIDE_CONTEXT_BYTES = 32 * 1024 * 1024;
export interface SideBoundary {
  parentSessionId: string; cutoffEntryId: string | null; contextRevision: string; capturedAt: string;
  entries: SessionEntry[]; order: string[]; resources?: ResourceSnapshot; omittedIncompleteEntries: number; bytes: number;
}
// Only completed, persisted Pi entries enter this function. Its input never comes
// from AgentSession.messages, a streaming message, or the transcript projection.
export function usableEntries(context: SessionEntry[]): { entries: SessionEntry[]; omitted: number } {
  const entries: SessionEntry[] = []; let staged: SessionEntry[] = [], pending = new Set<string>(), unsafe = false, omitted = 0;
  const discard = () => { omitted += staged.length; staged = []; pending = new Set(); };
  for (const entry of context) {
    if (entry.type !== 'message') {
      if (['compaction', 'branch_summary', 'custom_message'].includes(entry.type)) { if (pending.size || unsafe) staged.push(entry); else entries.push(entry); }
      continue;
    }
    const message = entry.message;
    if (message.role === 'user') { discard(); unsafe = false; entries.push(entry); }
    else if (message.role === 'assistant') {
      if (pending.size || unsafe || ['aborted', 'error', 'length'].includes(message.stopReason)) { discard(); omitted++; unsafe = true; continue; }
      const ids = message.content.filter(b => b.type === 'toolCall').map(b => b.id);
      if (new Set(ids).size !== ids.length) { omitted++; unsafe = true; continue; }
      if (ids.length) { pending = new Set(ids); staged = [entry]; } else entries.push(entry);
    } else if (message.role === 'toolResult') {
      if (!pending.delete(message.toolCallId) || unsafe) { omitted++; continue; }
      staged.push(entry);
      if (!pending.size) { entries.push(...staged); staged = []; }
    } else { if (pending.size || unsafe) staged.push(entry); else entries.push(entry); }
  }
  discard(); return { entries, omitted };
}
function deepFreeze<T>(value: T): T {
  const stack: unknown[] = [value];
  while (stack.length) { const item = stack.pop(); if (item && typeof item === 'object' && !Object.isFrozen(item)) { Object.freeze(item); stack.push(...Object.values(item)); } }
  return value;
}
export class SideBoundaryCache {
  private value: SideBoundary | undefined;
  private identity = '';
  private failure: string | undefined;
  update(manager: SessionManager, resources?: ResourceSnapshot): void {
    const safe = usableEntries(manager.buildContextEntries()), cutoffEntryId = safe.entries.at(-1)?.id ?? null;
    const identity = `${cutoffEntryId}:${safe.entries[0]?.id}:${resources?.revision}:${safe.omitted}`;
    if (this.identity === identity) return;
    let bytes = 0; const hash = createHash('sha256');
    for (const entry of safe.entries) {
      const json = JSON.stringify(entry); bytes += Buffer.byteLength(json);
      if (bytes > MAX_SIDE_CONTEXT_BYTES || safe.entries.length > 20000) { this.failure = 'The usable side context exceeds 32 MiB or 20000 entries. Compact the parent before opening a side.'; return; }
      hash.update(json).update('\n');
    }
    const ids = new Set(safe.entries.map(e=>e.id)), order = manager.getBranch().filter(e=>ids.has(e.id)).map(e=>e.id);
    this.value = deepFreeze({ parentSessionId: manager.getSessionId(), cutoffEntryId, contextRevision: hash.digest('hex'), order,
      capturedAt: new Date().toISOString(), entries: structuredClone(safe.entries), ...(resources ? {resources} : {}), omittedIncompleteEntries: safe.omitted, bytes });
    this.identity = identity; this.failure = undefined;
  }
  get(): SideBoundary {
    if (this.failure) throw new CommandError('side_context_limit', this.failure);
    if (!this.value) throw new CommandError('side_boundary_unavailable', 'No complete Pi boundary is available yet');
    return this.value;
  }
}
export function sideSeed(boundary: SideBoundary, binding: unknown, thinkingLevel: string): SessionEntry[] {
  const timestamp = new Date().toISOString(), anchorId = randomUUID().replaceAll('-', '').slice(0,16);
  const entries: SessionEntry[] = [{type:'custom',id:anchorId,parentId:null,timestamp,customType:'pi-app.profile.v1',data:structuredClone(binding)}];
  let parentId = anchorId;
  const byId = new Map(boundary.entries.map(e=>[e.id,e]));
  for (const id of boundary.order) {
    const original = byId.get(id)!;
    const entry = structuredClone(original); entry.parentId = parentId;
    // Only usable retained entries remain before the latest compaction. The
    // non-context anchor keeps every compaction reference valid after pruning.
    if (entry.type === 'compaction') entry.firstKeptEntryId = anchorId;
    entries.push(entry); parentId = entry.id;
  }
  entries.push({type:'thinking_level_change',id:randomUUID().replaceAll('-','').slice(0,16),parentId,timestamp,thinkingLevel});
  const expected = boundary.entries.flatMap(sessionEntryToContextMessages);
  const actual = buildSessionContext(entries).messages;
  // Compaction entries by themselves project their summary through the public API.
  if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new CommandError('side_context_invalid', 'Pi context changed while materializing the side boundary');
  return entries;
}
