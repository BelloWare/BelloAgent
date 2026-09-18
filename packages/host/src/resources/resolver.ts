import { ResourceError } from './files.ts';
import { watch, type FSWatcher } from 'node:fs';
import { dirname } from 'node:path';
import { DefaultResourceLoader, type Skill } from '@earendil-works/pi-coding-agent';
import { loadConfig, type ResourceOptions } from './config.ts';
import { digest, projectDirectories } from './files.ts';
import { resolveInstructions, type Instructions } from './instructions.ts';
import { discoverSkills, freezeSkills, piSkills, type FrozenSkill, type SkillCatalog, type SkillSelection } from './skills.ts';

export interface ResourceSnapshot { revision: string; cwd: string; root: string | null; codexHome: string; instructions: Instructions; catalog: SkillCatalog; diagnostics: string[] }
export class ResourceResolver {
  private latest: ResourceSnapshot | undefined;
  private pending: Promise<ResourceSnapshot> | undefined;
  private watchers: FSWatcher[] = [];
  stale = true;
  constructor(readonly cwd: string, private options: ResourceOptions = {}, private userHome?: string) {}
  configure(options: ResourceOptions): void { this.options = options; this.latest = undefined; this.stale = true; }
  async resolve(): Promise<ResourceSnapshot> {
    if (this.pending) { await this.pending; return this.resolve(); }
    const options = this.options;
    this.pending = (async () => {
      const config = await loadConfig(options), project = await projectDirectories(this.cwd);
      const [instructions, catalog] = await Promise.all([resolveInstructions(config, project.directories), discoverSkills(config, project.directories, this.userHome)]);
      const diagnostics = [...config.diagnostics, ...catalog.diagnostics];
      const snapshot = { cwd: this.cwd, root: project.root, codexHome: config.codexHome, instructions, catalog, diagnostics,
        revision: digest(JSON.stringify({ config: config.revision, instructions: instructions.revision, skills: catalog.skills.map(({ body, ...skill }) => skill) })) };
      if (options === this.options) {
        this.latest = snapshot; this.stale = false;
        this.watch([...catalog.roots, config.codexHome, ...project.directories, ...(config.piInstructionPaths ?? []).map(dirname)], diagnostics);
      }
      return snapshot;
    })();
    try { const result = await this.pending; if (options !== this.options) throw new ResourceError('Resource settings changed during discovery; refresh and retry'); return result; }
    finally { this.pending = undefined; }
  }
  async current(): Promise<ResourceSnapshot> { return this.latest ?? this.resolve(); }
  async freeze(selected: SkillSelection[], tools: readonly string[]): Promise<FrozenSkill[]> {
    return freezeSkills((await this.resolve()).catalog, selected, tools);
  }
  private watch(paths: string[], diagnostics: string[]): void {
    for (const watcher of this.watchers) watcher.close(); this.watchers = [];
    for (const path of [...new Set(paths)].slice(0, 64)) {
      try { const watcher = watch(path, { persistent: false, recursive: true }, () => { this.stale = true; }); watcher.on('error', () => { this.stale = true; }); this.watchers.push(watcher); }
      catch { /* Missing roots are checked on every deliberate next-turn discovery. */ }
    }
    if (paths.length > 64) diagnostics.push('Only 64 roots are watched; every turn still rereads all configured resources.');
  }
  dispose(): void { for (const watcher of this.watchers) watcher.close(); this.watchers = []; }
}
export class ResolvedResourceLoader extends DefaultResourceLoader {
  snapshot: ResourceSnapshot | undefined;
  allowedTools: string[] = [];
  override getAgentsFiles(): { agentsFiles: { path: string; content: string }[] } { return { agentsFiles: this.snapshot?.instructions.files ?? [] }; }
  override getSkills(): { skills: Skill[]; diagnostics: [] } { return { skills: this.snapshot ? piSkills(this.snapshot.catalog, this.allowedTools) : [], diagnostics: [] }; }
  override getSystemPrompt(): undefined { return undefined; }
  override getAppendSystemPrompt(): string[] { return ['Instruction files are resolved only from the project root to this session working directory. Read applicable deeper instructions before working in descendants. Historical explicit skill text is not a new invocation grant. Skills cannot add tools or install dependencies.']; }
}
