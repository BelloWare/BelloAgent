import { createHash } from 'node:crypto';
import { open, realpath, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { CommandError } from '../sessions/command-ledger.ts';

export class ResourceError extends CommandError { constructor(message: string) { super('resource_error', message); } }

export const digest = (value: string | Uint8Array): string => createHash('sha256').update(value).digest('hex');
export interface SourceFile { path: string; text: string; bytes: number; hash: string }
export const missing = (error: unknown): boolean => ['ENOENT', 'ENOTDIR'].includes((error as NodeJS.ErrnoException)?.code ?? '');
// Allocate only the declared, capped size; reject replacement/growth during the read.
export async function readSource(path: string, limit: number): Promise<SourceFile | undefined> {
  let file;
  try { file = await open(path, 'r'); } catch (error) { if (missing(error)) return; throw error; }
  try {
    const before = await file.stat();
    if (!before.isFile() || before.size > limit) throw new ResourceError(`Expected a regular file of at most ${limit} bytes`);
    const bytes = Buffer.alloc(before.size); let offset = 0;
    while (offset < bytes.length) {
      const read = await file.read(bytes, offset, Math.min(65536, bytes.length - offset), offset);
      if (!read.bytesRead) throw new ResourceError('Resource changed during read'); offset += read.bytesRead;
    }
    const after = await file.stat(), canonical = await realpath(path), current = await stat(canonical);
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs || before.ino !== current.ino || before.dev !== current.dev) throw new ResourceError('Resource changed during read');
    return { path: canonical, text: new TextDecoder('utf-8', { fatal: true }).decode(bytes), bytes: bytes.length, hash: digest(bytes) };
  } finally { await file.close(); }
}
export function utf8Prefix(text: string, limit: number): string {
  const bytes = Buffer.from(text); if (bytes.length <= limit) return text;
  let end = Math.max(0, limit); while (end > 0 && (bytes[end]! & 0xc0) === 0x80) end--;
  return bytes.subarray(0, end).toString('utf8');
}
export async function projectDirectories(cwd: string): Promise<{ root: string | null; directories: string[] }> {
  const canonical = await realpath(cwd), ancestors = [canonical];
  for (let directory = canonical, depth = 0; depth < 64; depth++) {
    try { const git = await stat(join(directory, '.git')); if (git.isDirectory() || git.isFile()) return { root: directory, directories: ancestors.reverse() }; }
    catch (error) { if (!missing(error)) throw new ResourceError(`Cannot inspect Git root at ${directory}`); }
    const parent = dirname(directory); if (parent === directory) return { root: null, directories: [canonical] };
    directory = parent; ancestors.push(directory);
  }
  throw new ResourceError('Project ancestor limit reached');
}
