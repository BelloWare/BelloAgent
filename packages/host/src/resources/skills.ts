import { ResourceError } from './files.ts';
import { opendir, realpath, stat } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { parseDocument } from 'yaml';
import type { Skill } from '@earendil-works/pi-coding-agent';
import type { ResourceConfig } from './config.ts';
import { digest, missing, readSource } from './files.ts';

export type SkillPolicy = 'implicitAllowed' | 'explicitOnly' | 'disabled' | 'needsAttention';
export interface Dependency { type: string; value: string }
export interface DiscoveredSkill {
  id: string; name: string; path: string; baseDir: string; sourceRoot: string; scope: string; description: string;
  contentHash: string; metadataHash: string; policy: SkillPolicy; reasons: string[]; dependencies: Dependency[]; body: string;
}
export interface SkillSelection { id: string; contentHash: string; metadataHash: string; arguments: string; intent: 'picker' | 'leading-command' }
export interface FrozenSkill extends SkillSelection { name: string; path: string; baseDir: string; body: string; policy: SkillPolicy }
export interface SkillCatalog { skills: DiscoveredSkill[]; diagnostics: string[]; roots: string[] }
const map = (value: unknown): Record<string, unknown> => { if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ResourceError('Expected a metadata mapping'); return value as Record<string, unknown>; };
function yaml(text: string): Record<string, unknown> {
  if (Buffer.byteLength(text) > 65536) throw new ResourceError('YAML metadata exceeds 64 KiB');
  const doc = parseDocument(text, { schema: 'core', customTags: [], uniqueKeys: true, strict: true });
  if (doc.errors.length || doc.warnings.length) throw new ResourceError('Invalid or unsupported YAML');
  return map(doc.toJS({ maxAliasCount: 0 }) ?? {});
}
export function selectionsFrom(raw: unknown): SkillSelection[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 8) throw new ResourceError('A submission supports at most eight explicit skills');
  const ids = new Set<string>();
  return raw.map(item => {
    const input = map(item);
    if (![input.id, input.contentHash, input.metadataHash].every(x => typeof x === 'string' && /^[a-f0-9]{64}$/.test(x)) ||
        !['picker', 'leading-command'].includes(String(input.intent)) || typeof input.arguments !== 'string' || Buffer.byteLength(input.arguments) > 16384) throw new ResourceError('Invalid explicit skill selection');
    if (ids.has(input.id as string)) throw new ResourceError('Duplicate skill selection'); ids.add(input.id as string);
    return { id: input.id as string, contentHash: input.contentHash as string, metadataHash: input.metadataHash as string, intent: input.intent as SkillSelection['intent'], arguments: input.arguments };
  });
}
export async function discoverSkills(config: ResourceConfig, directories: string[], userHome = homedir()): Promise<SkillCatalog> {
  const roots = [{ path: join(config.codexHome, 'skills'), scope: 'user' }, { path: join(userHome, '.agents', 'skills'), scope: 'user' },
    ...directories.map(path => ({ path: join(path, '.agents', 'skills'), scope: 'project' })),
    ...(config.extraSkillPaths ?? []).map(path => ({ path, scope: 'approved additional' })), ...(config.piSkillPaths ?? []).map(path => ({ path, scope: 'approved Pi' }))];
  const skills: DiscoveredSkill[] = [], diagnostics: string[] = [], visited = new Set<string>(), seenFiles = new Set<string>();
  let scanned = 0, bytes = 0, capped = false;
  const load = async (path: string, root: typeof roots[number]): Promise<void> => {
    const file = await readSource(path, 262144); if (!file || seenFiles.has(file.path)) return; seenFiles.add(file.path);
    if (skills.length >= 512 || bytes + file.bytes > 2 * 1024 * 1024) { capped = true; return; } bytes += file.bytes;
    const reasons: string[] = [], dependencies: Dependency[] = []; let front: Record<string, unknown> = {}, metadata: Record<string, unknown> = {}, metadataHash = 'absent', body = file.text, frontText = '';
    try {
      if (file.text.startsWith('---\n') || file.text.startsWith('---\r\n')) {
        const end = /^---\r?$/mg; end.lastIndex = file.text.indexOf('\n') + 1; const match = end.exec(file.text);
        if (!match) throw new ResourceError('Unterminated frontmatter');
        frontText = file.text.slice(file.text.indexOf('\n') + 1, match.index); front = yaml(frontText); body = file.text.slice(match.index + match[0].length).trim();
      }
      const extra = await readSource(join(dirname(file.path), 'agents', 'openai.yaml'), 65536);
      if (extra) { metadataHash = extra.hash; metadata = yaml(extra.text); }
      if (front['disable-model-invocation'] !== undefined && typeof front['disable-model-invocation'] !== 'boolean') throw new ResourceError('Invalid Pi invocation policy');
      if (metadata.policy !== undefined) {
        const policy = map(metadata.policy);
        if (Object.keys(policy).some(key => key !== 'allow_implicit_invocation') || policy.allow_implicit_invocation !== undefined && typeof policy.allow_implicit_invocation !== 'boolean') throw new ResourceError('Invalid or unsupported invocation policy');
      }
      if (metadata.dependencies !== undefined) {
        const tools = map(metadata.dependencies).tools;
        if (!Array.isArray(tools) || tools.length > 32) throw new ResourceError('Invalid skill dependencies');
        for (const item of tools) {
          const dep = map(item);
          if (typeof dep.type !== 'string' || typeof dep.value !== 'string' || dep.type.length > 64 || dep.value.length > 256) throw new ResourceError('Invalid skill dependency');
          dependencies.push({ type: dep.type, value: dep.value });
        }
      }
    } catch { reasons.push('Unreadable, malformed or unsupported mandatory metadata; fix the source before invocation.'); }
    const name = typeof front.name === 'string' ? front.name : basename(dirname(file.path));
    const description = typeof front.description === 'string' ? front.description : '';
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(name) || !description.trim() || description.length > 1024) reasons.push('A valid name and a description of at most 1024 characters are required.');
    const id = digest(file.path), disabled = config.disabledPaths.includes(file.path) || config.disabledPaths.includes(dirname(file.path)) || config.disabled?.includes(id);
    const explicitOnly = front['disable-model-invocation'] === true || (metadata.policy as Record<string, unknown> | undefined)?.allow_implicit_invocation === false || config.explicitOnly?.includes(id);
    if (config.policyInvalid) reasons.push('Codex disabled-skill configuration needs attention.');
    const policy: SkillPolicy = reasons.length ? 'needsAttention' : disabled ? 'disabled' : explicitOnly ? 'explicitOnly' : 'implicitAllowed';
    if (disabled) reasons.push('Disabled by Codex configuration or the app.');
    if (explicitOnly) reasons.push('Explicit invocation required by source metadata or the app.');
    skills.push({ id, name: name.slice(0, 128), description: description.slice(0, 1024), path: file.path, baseDir: dirname(file.path), sourceRoot: root.path, scope: root.scope,
      contentHash: file.hash, metadataHash: digest(JSON.stringify({ frontText, metadataHash, policy, dependencies })), policy, reasons, dependencies, body });
  };
  const visit = async (path: string, root: typeof roots[number], depth: number): Promise<void> => {
    if (scanned++ >= 5000 || depth > 12) { capped = true; return; }
    try {
      const canonical = await realpath(path); if (visited.has(canonical)) return; visited.add(canonical);
      const info = await stat(canonical);
      if (info.isFile()) { if (canonical.endsWith('.md')) await load(canonical, root); return; }
      if (!info.isDirectory()) return;
      const skillPath = join(canonical, 'SKILL.md');
      try { if ((await stat(skillPath)).isFile()) { await load(skillPath, root); return; } } catch (error) { if (!missing(error)) throw error; }
      const children: string[] = [], iterator = await opendir(canonical);
      for await (const item of iterator) {
        if (children.length + scanned >= 5000) { capped = true; break; }
        if (item.isDirectory() || item.isSymbolicLink() || depth === 0 && item.isFile() && item.name.endsWith('.md')) children.push(item.name);
      }
      for (const child of children.sort()) { if (capped && scanned >= 5000) break; await visit(join(canonical, child), root, depth + 1); }
    } catch (error) { if (!missing(error) && diagnostics.length < 64) diagnostics.push(`Cannot discover ${path}: unreadable, invalid UTF-8 or source size limit.`); }
  };
  for (const root of roots) await visit(root.path, root, 0);
  if (capped) diagnostics.push('Discovery limit reached: 5000 entries, depth 12, 512 skills or 2 MiB source bytes. Narrow the approved paths.');
  return { skills: skills.sort((a, b) => a.name.localeCompare(b.name, 'en') || a.path.localeCompare(b.path, 'en')), diagnostics, roots: roots.map(x => x.path) };
}
export const unmetDependencies = (skill: Pick<DiscoveredSkill, 'dependencies'>, tools: readonly string[]): Dependency[] => skill.dependencies.filter(dep => !['tool', 'builtin'].includes(dep.type) || !tools.includes(dep.value));
export function piSkills(catalog: SkillCatalog, tools: readonly string[]): Skill[] {
  return catalog.skills.filter(s => s.policy === 'implicitAllowed' && !unmetDependencies(s, tools).length).map(s => ({
    name: s.name, description: s.description, filePath: s.path, baseDir: s.baseDir, disableModelInvocation: false,
    sourceInfo: { path: s.path, source: s.scope, scope: s.scope === 'project' ? 'project' : 'user', origin: 'top-level', baseDir: s.baseDir },
  }));
}
export function freezeSkills(catalog: SkillCatalog, selected: SkillSelection[], tools: readonly string[]): FrozenSkill[] {
  return selected.map(selection => {
    const skill = catalog.skills.find(s => s.id === selection.id);
    if (!skill || !['implicitAllowed', 'explicitOnly'].includes(skill.policy)) throw new ResourceError('Selected skill is unavailable, disabled or needs attention. Refresh the picker.');
    if (skill.contentHash !== selection.contentHash || skill.metadataHash !== selection.metadataHash) throw new ResourceError('Selected skill changed. Refresh the chip and submit again.');
    if (unmetDependencies(skill, tools).length) throw new ResourceError(`Skill ${skill.name} requires unavailable dependencies: ${unmetDependencies(skill, tools).map(d => `${d.type}:${d.value}`).join(', ')}`);
    return { ...selection, name: skill.name, path: skill.path, baseDir: skill.baseDir, body: skill.body, policy: skill.policy };
  });
}
export function validateFrozen(catalog: SkillCatalog, frozen: FrozenSkill[], tools: readonly string[]): void {
  for (const selected of frozen) {
    const current = catalog.skills.find(s => s.id === selected.id);
    if (!current || !['implicitAllowed', 'explicitOnly'].includes(current.policy) || current.metadataHash !== selected.metadataHash || unmetDependencies(current, tools).length) throw new ResourceError('Queued skill authorization changed or was revoked. Refresh and resubmit the draft.');
  }
}
export function expandSkills(text: string, skills: FrozenSkill[], turnId: string): string {
  const escape = (value: string): string => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return [...skills.map(s => `<skill name="${escape(s.name)}" location="${escape(s.path)}" content_sha256="${s.contentHash}" explicit_turn="${escape(turnId)}">\nReferences are relative to ${s.baseDir}. This selection grants no additional tools.\n\n${s.body}\n</skill>${s.arguments ? `\nArguments: ${s.arguments}` : ''}`), text].join('\n\n');
}
