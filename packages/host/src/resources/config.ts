import { ResourceError } from './files.ts';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';
import { realpath } from 'node:fs/promises';
import { parse } from 'smol-toml';
import { digest, readSource } from './files.ts';

export interface ResourceOptions {
  codexHome?: string; extraSkillPaths?: string[]; piSkillPaths?: string[]; piInstructionPaths?: string[];
  fallbackNames?: string[]; maxInstructionBytes?: number; explicitOnly?: string[]; disabled?: string[];
}
export interface ResourceConfig extends ResourceOptions {
  codexHome: string; fallbackNames: string[]; maxInstructionBytes: number;
  disabledPaths: string[]; diagnostics: string[]; policyInvalid: boolean; revision: string;
}
export function resourceOptions(raw: unknown): ResourceOptions {
  if (raw === undefined) return {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new ResourceError('Invalid resource settings');
  const input = raw as Record<string, unknown>, output: ResourceOptions = {};
  const allowed = ['codexHome', 'extraSkillPaths', 'piSkillPaths', 'piInstructionPaths', 'fallbackNames', 'maxInstructionBytes', 'explicitOnly', 'disabled'];
  for (const key of Object.keys(input)) if (!allowed.includes(key)) throw new ResourceError(`Unknown resource setting: ${key}`);
  if (input.codexHome !== undefined) { if (typeof input.codexHome !== 'string' || !isAbsolute(input.codexHome) || input.codexHome.length > 4096) throw new ResourceError('Codex home must be an absolute path'); output.codexHome = input.codexHome; }
  for (const key of ['extraSkillPaths', 'piSkillPaths', 'piInstructionPaths', 'fallbackNames', 'explicitOnly', 'disabled'] as const) {
    const value = input[key]; if (value === undefined) continue;
    const cap = key === 'explicitOnly' || key === 'disabled' ? 512 : 32;
    if (!Array.isArray(value) || value.length > cap || value.some(x => typeof x !== 'string' || !x || x.length > 4096)) throw new ResourceError(`Invalid ${key}`);
    if (key.endsWith('Paths') && value.some(x => !isAbsolute(x))) throw new ResourceError(`${key} requires absolute approved paths`);
    if ((key === 'explicitOnly' || key === 'disabled') && value.some(x => !/^[a-f0-9]{64}$/.test(x))) throw new ResourceError(`${key} requires canonical skill IDs`);
    output[key] = [...new Set(value as string[])];
  }
  if (input.maxInstructionBytes !== undefined) {
    const n = input.maxInstructionBytes;
    if (!Number.isInteger(n) || (n as number) < 0 || (n as number) > 262144) throw new ResourceError('Instruction budget must be 0–262144 bytes'); output.maxInstructionBytes = n as number;
  }
  return output;
}
const basenameValid = (name: unknown): name is string => typeof name === 'string' && name.length > 0 && name.length <= 255 && !/[\/\\\0]/.test(name) && name !== '.' && name !== '..';
export async function loadConfig(options: ResourceOptions): Promise<ResourceConfig> {
  const codexHome = options.codexHome ?? process.env.CODEX_HOME ?? join(homedir(), '.codex');
  if (!isAbsolute(codexHome) || codexHome.length > 4096) throw new ResourceError('CODEX_HOME must be an absolute bounded path; shell expressions are not evaluated');
  const diagnostics: string[] = [], disabledPaths: string[] = []; let policyInvalid = false, parsed: Record<string, unknown> = {}, configHash = 'absent';
  try {
    const file = await readSource(join(codexHome, 'config.toml'), 1024 * 1024);
    if (file) { parsed = parse(file.text) as Record<string, unknown>; configHash = file.hash; }
    const skills = parsed.skills as { config?: unknown } | undefined;
    if (skills !== undefined && (!skills || typeof skills !== 'object' || Array.isArray(skills))) throw new ResourceError('Invalid skills configuration');
    if (skills?.config !== undefined) {
      if (!Array.isArray(skills.config) || skills.config.length > 1024) throw new ResourceError('Invalid skills.config table');
      for (const item of skills.config) {
        if (!item || typeof item.path !== 'string' || item.path.length > 4096 || typeof item.enabled !== 'boolean') throw new ResourceError('Invalid skills.config entry');
        if (!item.enabled) { const path = resolve(codexHome, item.path); disabledPaths.push(await realpath(path).catch(() => path)); }
      }
    }
  } catch { policyInvalid = true; diagnostics.push('Codex config.toml is unreadable, too large or malformed; skill policy needs attention.'); }
  let fallbackNames = options.fallbackNames ?? parsed.project_doc_fallback_filenames ?? [];
  if (!Array.isArray(fallbackNames) || fallbackNames.length > 32 || !fallbackNames.every(basenameValid)) { diagnostics.push('Invalid instruction fallback basenames; only AGENTS.override.md and AGENTS.md will be used.'); fallbackNames = []; }
  let maxInstructionBytes = options.maxInstructionBytes ?? parsed.project_doc_max_bytes ?? 32768;
  if (!Number.isSafeInteger(maxInstructionBytes) || (maxInstructionBytes as number) < 0 || (maxInstructionBytes as number) > 262144) { diagnostics.push('Invalid instruction byte limit; the 32768-byte default is applied (app maximum 262144).'); maxInstructionBytes = 32768; }
  return { ...options, codexHome, disabledPaths, diagnostics, policyInvalid, fallbackNames: fallbackNames as string[], maxInstructionBytes: maxInstructionBytes as number,
    revision: digest(JSON.stringify({ options, configHash })) };
}
