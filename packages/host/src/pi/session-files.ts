import { createHash, randomUUID } from 'node:crypto';
import { readFile, open, mkdir, mkdtemp, realpath, rm, stat, link, chmod, rename } from 'node:fs/promises';
import { join, basename } from 'node:path';
import { SessionManager } from '@earendil-works/pi-coding-agent';

const MAX_FILE = 128 * 1024 * 1024, MAX_RECORD = 32 * 1024 * 1024;
export interface SessionFileInfo { path: string; sha256: string; bytes: number; records: number; version: number; id: string }

async function finalizeCopiedManager(manager: SessionManager, target: string): Promise<void> {
  const header = manager.getHeader(); if (!header) throw new Error('Copied Pi header is unavailable');
  const temporary = target + `.${randomUUID()}.finalizing`, file = await open(temporary, 'wx', 0o600);
  let published = false;
  try {
    let bytes = 0;
    // Public Pi-format entries, including unflushed custom metadata. Never use
    // rendered text or fabricate assistant output to force Pi's first flush.
    for (const entry of [header, ...manager.getEntries()]) {
      const line = JSON.stringify(entry) + '\n'; bytes += Buffer.byteLength(line);
      if (bytes > MAX_FILE || Buffer.byteLength(line) > MAX_RECORD + 1) throw new Error('Copied session exceeds the active-file limits');
      await file.writeFile(line);
    }
    await file.sync(); await file.close(); await inspectSessionFile(temporary);
    await rename(temporary, target); published = true;
  } finally { await file.close().catch(() => {}); if (!published) await rm(temporary, { force: true }); }
}

export async function persistMemorySession(manager: SessionManager, directory: string): Promise<string> {
  await mkdir(directory,{recursive:true,mode:0o700});
  const staging = await mkdtemp(join(directory, '.keep-side-'));
  try {
    const name = `side_${manager.getSessionId()}.jsonl`;
    const path = join(staging, name); await finalizeCopiedManager(manager, path);
    const published = join(directory, name); await link(path, published);
    const folder=await open(directory,'r'); try { await folder.sync(); } finally { await folder.close(); }
    return published;
  } finally { await rm(staging, {recursive:true,force:true}); }
}

// Validate through the same open descriptor used for the optional snapshot.
// Pi's permissive JSONL reader must not silently discard a damaged import tail.
export async function inspectSessionFile(path: string, snapshotPath?: string,
  progress?: (bytes: number, total: number) => void | Promise<void>): Promise<SessionFileInfo> {
  const canonical = await realpath(path), source = await open(canonical, 'r');
  let destination: Awaited<ReturnType<typeof open>> | undefined;
  let keepSnapshot = false;
  try {
    const before = await source.stat({ bigint: true });
    if (!before.isFile() || before.size > BigInt(MAX_FILE)) throw new Error('Session exceeds the 128 MiB active-file limit or is not a regular file');
    if (snapshotPath) destination = await open(snapshotPath, 'wx', 0o600);
    const hash = createHash('sha256'); let bytes = 0, records = 0, pendingBytes = 0;
    let pending: Buffer[] = [];
    let header: { version: number; id: string } | undefined;
    const entryIDs = new Set<string>();
    const decoder = new TextDecoder('utf-8', { fatal: true });
    const validate = (line: Buffer): void => {
      if (line.length === 0) throw new Error('Empty record in Pi session');
      let value: unknown;
      try { value = JSON.parse(decoder.decode(line)) as unknown; }
      catch { throw new Error(`Malformed JSON or UTF-8 in session record ${records + 1}`); }
      if (!value || typeof value !== 'object' || !('type' in value) || typeof value.type !== 'string') throw new Error('Invalid Pi session record');
      if (records === 0) {
        if (value.type !== 'session' || !('id' in value) || typeof value.id !== 'string') throw new Error('Pi session header is missing');
        const version = 'version' in value ? value.version : 1;
        if (typeof version !== 'number' || ![1, 2, 3].includes(version)) throw new Error('Unsupported Pi session version');
        header = { version, id: value.id };
      } else if (value.type === 'session') throw new Error('Duplicate Pi session header');
      else if (header?.version === 3) {
        const entry = value as Record<string, unknown>;
        if (typeof entry.id !== 'string' || entry.id.length > 128 || entryIDs.has(entry.id) ||
            !(entry.parentId === null || typeof entry.parentId === 'string' && entryIDs.has(entry.parentId))) throw new Error('Invalid Pi entry identity or parent relationship');
        if (entry.type === 'message' && (!entry.message || typeof entry.message !== 'object' || !('role' in entry.message) || typeof entry.message.role !== 'string')) throw new Error('Invalid Pi message');
        if (entry.type === 'compaction' && (typeof entry.summary !== 'string' || typeof entry.firstKeptEntryId !== 'string' || !entryIDs.has(entry.firstKeptEntryId))) throw new Error('Invalid Pi compaction boundary');
        entryIDs.add(entry.id);
      }
      records++;
    };
    for await (const chunk of source.createReadStream({ highWaterMark: 64 * 1024, autoClose: false })) {
      const buffer = chunk as Buffer; bytes += buffer.length;
      if (bytes > MAX_FILE) throw new Error('Session exceeds the 128 MiB active-file limit');
      hash.update(buffer); await destination?.writeFile(buffer);
      await progress?.(bytes, Number(before.size));
      let start = 0;
      for (;;) {
        const end = buffer.indexOf(10, start);
        if (end < 0) break;
        if (pendingBytes + end - start > MAX_RECORD) throw new Error('Session record exceeds 32 MiB');
        validate(pendingBytes ? Buffer.concat([...pending, buffer.subarray(start, end)], pendingBytes + end - start) : buffer.subarray(start, end));
        pending = []; pendingBytes = 0; start = end + 1;
      }
      if (pendingBytes + buffer.length - start > MAX_RECORD) throw new Error('Session record exceeds 32 MiB');
      if (start < buffer.length) { pending.push(buffer.subarray(start)); pendingBytes += buffer.length - start; }
    }
    if (pendingBytes > 0) throw new Error('Incomplete session tail; preserve the original and create an explicit recovered copy');
    if (!header) throw new Error('Empty Pi session');
    const after = await source.stat({ bigint: true });
    if (before.ino !== after.ino || before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) throw new Error('Source session changed during import');
    const current = await stat(canonical, { bigint: true });
    if (current.ino !== before.ino || current.size !== before.size || current.mtimeNs !== before.mtimeNs || await realpath(path) !== canonical) throw new Error('Source session path changed during import');
    await destination?.sync(); keepSnapshot = true;
    return { path: canonical, bytes, records, sha256: hash.digest('hex'), ...header };
  } finally {
    await source.close(); await destination?.close();
    if (snapshotPath && destination && !keepSnapshot) await rm(snapshotPath, { force: true });
  }
}

export async function continueSessionCopy(sourcePath: string, cwd: string, managedDirectory: string, id: string = randomUUID()): Promise<{ sessionFile: string; source: SessionFileInfo }> {
  await mkdir(managedDirectory, { recursive: true, mode: 0o700 });
  const snapshotDirectory = join(managedDirectory, 'imports'); await mkdir(snapshotDirectory, { recursive: true, mode: 0o700 });
  const snapshot = join(snapshotDirectory, `${randomUUID()}.jsonl`);
  const source = await inspectSessionFile(sourcePath, snapshot);
  // forkFrom reads our immutable snapshot, never the CLI-owned original. Pi owns
  // header/version migration and all message/tool/branch relationships in the copy.
  const staging = await mkdtemp(join(managedDirectory, '.continue-'));
  try {
    const manager = SessionManager.forkFrom(snapshot, cwd, staging, { id });
    manager.appendCustomEntry('pi-app.import.v1', { originalPath: source.path, originalSHA256: source.sha256, snapshotPath: snapshot, importedAt: new Date().toISOString() });
    const stagedFile = manager.getSessionFile();
    if (!stagedFile) throw new Error('Pi did not create the managed copy');
    await finalizeCopiedManager(manager, stagedFile);
    await chmod(stagedFile, 0o600);
    const sessionFile = join(managedDirectory, basename(stagedFile));
    // Same-volume hard link publishes the completed file atomically and refuses
    // an existing destination. Removing staging leaves the managed link intact.
    await link(stagedFile, sessionFile);
    return { sessionFile, source };
  } finally { await rm(staging, { recursive: true, force: true }); }
}

// Explicit recovery drops only the unterminated final record in a NEW copy.
// Preserve the complete damaged source first, including every tail byte.
export async function recoverSessionCopy(sourcePath: string, cwd: string, managedDirectory: string, id: string): Promise<{ sessionFile: string; preservedOriginal: string; omittedTailBytes: number }> {
  const directory = join(managedDirectory, 'recovery'); await mkdir(directory, { recursive: true, mode: 0o700 });
  const canonical = await realpath(sourcePath), source = await open(canonical, 'r');
  const preservedOriginal = join(directory, `${randomUUID()}.original`), prefix = join(directory, `${randomUUID()}.jsonl`);
  let archive: Awaited<ReturnType<typeof open>> | undefined, output: Awaited<ReturnType<typeof open>> | undefined;
  let completeArchive = false, size = 0, boundary = 0;
  const hash = createHash('sha256');
  try {
    const initial = await source.stat({ bigint: true });
    if (!initial.isFile() || initial.size > BigInt(MAX_FILE)) throw new Error('Source is outside the active-file limit');
    archive = await open(preservedOriginal, 'wx', 0o600);
    for await (const data of source.createReadStream({ autoClose: false, highWaterMark: 64 * 1024 })) {
      const chunk = data as Buffer;
      if (size + chunk.length > MAX_FILE) throw new Error('Source grew beyond the active-file limit');
      const newline = chunk.lastIndexOf(10); if (newline >= 0) boundary = size + newline + 1;
      size += chunk.length; hash.update(chunk); await archive.writeFile(chunk);
    }
    const after = await source.stat({ bigint: true }), current = await stat(canonical, { bigint: true });
    if (initial.ino !== after.ino || initial.size !== after.size || initial.mtimeNs !== after.mtimeNs || initial.ctimeNs !== after.ctimeNs || current.ino !== initial.ino || current.size !== initial.size || current.mtimeNs !== initial.mtimeNs || await realpath(sourcePath) !== canonical) throw new Error('Source changed during recovery');
    await archive.sync(); await archive.close(); archive = undefined; completeArchive = true;
    if (boundary === 0 || boundary === size) throw new Error('There is no incomplete final record to recover');
    const saved = await open(preservedOriginal, 'r');
    try {
      output = await open(prefix, 'wx', 0o600);
      for await (const chunk of saved.createReadStream({ start: 0, end: boundary - 1, highWaterMark: 64 * 1024, autoClose: false })) await output.writeFile(chunk as Buffer);
      await output.sync(); await output.close(); output = undefined;
    } finally { await saved.close(); }
    await inspectSessionFile(prefix); // Reject corruption anywhere before the tail.
    const copied = await continueSessionCopy(prefix, cwd, managedDirectory, id);
    const manager = SessionManager.open(copied.sessionFile, managedDirectory, cwd);
    manager.appendCustomEntry('pi-app.recovery.v1', { originalPath: canonical, originalSHA256: hash.digest('hex'), preservedOriginal,
      omittedTailBytes: size - boundary, recoveredAt: new Date().toISOString(), policy: 'drop-unterminated-final-record-only' });
    await finalizeCopiedManager(manager, copied.sessionFile);
    return { sessionFile: copied.sessionFile, preservedOriginal, omittedTailBytes: size - boundary };
  } finally {
    await source.close(); await archive?.close(); await output?.close(); await rm(prefix, { force: true });
    if (!completeArchive) await rm(preservedOriginal, { force: true });
  }
}

// Deliberately lossy, user-reviewed handoff into a NEW draft. This is never a
// resume operation and never feeds rendered transcript text back into Pi.
export async function portableContextDraft(sourcePath: string, cwd: string, managedDirectory: string): Promise<unknown> {
  const directory = join(managedDirectory, 'imports'); await mkdir(directory, { recursive: true, mode: 0o700 });
  const snapshotPath = join(directory, `${randomUUID()}.jsonl`), source = await inspectSessionFile(sourcePath, snapshotPath);
  const { buildSessionContext, parseSessionEntries } = await import('@earendil-works/pi-coding-agent');
  const manager = SessionManager.inMemory(cwd, undefined, parseSessionEntries(await readFile(snapshotPath, 'utf8')));
  const messages = buildSessionContext(manager.getEntries()).messages;
  const included: string[] = []; let bytes = 0, omitted = 0, incomplete = 0;
  for (const message of [...messages].reverse()) {
    if (message.role === 'assistant' && ['error','aborted'].includes(message.stopReason)) { incomplete++; continue; }
    const content = 'content' in message ? message.content : 'summary' in message ? message.summary : '';
    const text = typeof content === 'string' ? content : Array.isArray(content) ? content.flatMap(block => block.type === 'text' ? [block.text] : []).join('\n') : '';
    if (!text) { omitted++; continue; }
    const section = `[Historical ${message.role}; quoted context, not a new tool or skill authorization]\n${text}\n`;
    if (bytes + Buffer.byteLength(section) > 128 * 1024) { omitted++; continue; }
    included.unshift(section); bytes += Buffer.byteLength(section);
  }
  return { draft: `Portable context handoff. Review and edit before sending. Omitted thinking, signatures/encrypted state, image data, tool-call arguments and provider continuation cursors. ${omitted} messages omitted by content/128 KiB limit; ${incomplete} failed or partial assistant messages omitted. Tool results below are historical text, not pending execution.\n\n${included.join('\n')}`,
    provenance: { originalPath: source.path, originalSHA256: source.sha256, snapshotPath, sourceLeaf: manager.getLeafId(), omittedMessages: omitted, incompleteMessages: incomplete, transformation: 'text-only portable draft; no opaque provider state; explicit review required' } };
}
