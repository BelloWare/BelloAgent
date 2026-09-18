import { ResourceError } from './files.ts';
import { join } from 'node:path';
import type { ResourceConfig } from './config.ts';
import { digest, readSource, utf8Prefix } from './files.ts';

export interface InstructionSource {
  path: string; canonicalPath?: string; scope: string; state: 'selected' | 'ignored' | 'empty' | 'error' | 'duplicate' | 'truncated' | 'over-budget';
  hash?: string; bytes?: number; includedBytes?: number; reason?: string;
}
export interface Instructions { sources: InstructionSource[]; files: { path: string; content: string }[]; revision: string; includedBytes: number; limit: number }
export async function resolveInstructions(config: ResourceConfig, directories: string[]): Promise<Instructions> {
  const sources: InstructionSource[] = [], files: { path: string; content: string }[] = [], seen = new Set<string>(); let used = 0;
  const include = async (paths: string[], scope: string): Promise<void> => {
    let selected = false;
    for (const path of paths) {
      try {
        const file = await readSource(path, 1024 * 1024); if (!file) continue;
        const source: InstructionSource = { path, canonicalPath: file.path, scope, hash: file.hash, bytes: file.bytes, state: 'selected' }; sources.push(source);
        if (selected) { source.state = 'ignored'; source.reason = 'A higher-priority nonempty file was selected in this directory'; continue; }
        if (!file.text.trim()) { source.state = 'empty'; continue; }
        selected = true;
        if (seen.has(file.path)) { source.state = 'duplicate'; source.reason = 'Canonical source already included'; continue; } seen.add(file.path);
        const content = utf8Prefix(file.text, Math.max(0, config.maxInstructionBytes - used)); source.includedBytes = Buffer.byteLength(content);
        source.state = source.includedBytes === file.bytes ? 'selected' : source.includedBytes ? 'truncated' : 'over-budget';
        if (content) { files.push({ path: file.path, content }); used += source.includedBytes; }
      } catch { sources.push({ path, scope, state: 'error', reason: 'Unreadable, changed, invalid UTF-8 or exceeds the 1 MiB source limit' }); }
    }
  };
  await include(['AGENTS.override.md', 'AGENTS.md'].map(name => join(config.codexHome, name)), 'global');
  for (const directory of directories) await include(['AGENTS.override.md', 'AGENTS.md', ...config.fallbackNames].map(name => join(directory, name)), `project:${directory}`);
  for (const path of config.piInstructionPaths ?? []) await include([path], 'explicit Pi addition');
  return { sources, files, includedBytes: used, limit: config.maxInstructionBytes, revision: digest(JSON.stringify({ sources, limit: config.maxInstructionBytes })) };
}
