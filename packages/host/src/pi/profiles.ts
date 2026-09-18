import { createHash } from 'node:crypto';
import { realpath } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { Worker } from 'node:worker_threads';
import { InMemoryCredentialStore, InMemoryModelsStore, type Model, type Api } from '@earendil-works/pi-ai';
import { ModelRuntime } from '@earendil-works/pi-coding-agent';
import type { ApiKind } from '../observability/capture-store.ts';
import { CommandError } from '../sessions/command-ledger.ts';
import { readSource } from '../resources/files.ts';

export interface Profile {
  id: string; revision: string; providerId: string; modelId: string; api: ApiKind;
  baseUrl: string; contextWindow: number; maxOutputTokens: number;
  reasoning?: boolean; input?: ('text' | 'image')[];
  thinkingLevel?: 'off' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  thinkingLevelMap?: Model<Api>['thinkingLevelMap'];
  samplingParams?: Record<string, unknown>; compat?: Model<Api>['compat'];
  publicMetadataHeaders?: string[];
  cost?: Model<Api>['cost']; headers?: Record<string, string>;
  source?: { modelsPath: string; authPath: string; sha256: string; commandTrust: boolean; settingsPath?: string; settingsSHA256?: string };
}
const fail = (message: string): never => { throw new CommandError('invalid_profile', message); };
function obj(v: unknown): Record<string, any> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return fail('Expected a configuration object');
  return v as Record<string, any>;
}
function text(v: unknown, label: string, max = 4096): string {
  if (typeof v !== 'string' || !v || Buffer.byteLength(v) > max) return fail(`Invalid ${label}`);
  return v;
}
export function resolveEndpoint(api: ApiKind, value: string): { baseUrl: string; requestUrl: string } {
  const url = new URL(value);
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) return fail('Endpoint must be HTTP(S), without credentials, query, or fragment. Use credential headers.');
  if (url.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) return fail('Remote endpoints require HTTPS');
  let path = url.pathname.replace(/\/+$/, '');
  const leaf = api === 'openai-responses' ? '/responses' : '/messages';
  if (path.endsWith(leaf)) path = path.slice(0, -leaf.length);
  if (/\/(responses|messages)$/.test(path) || /\/v1\/v1(?:\/|$)/.test(path)) return fail('Endpoint repeats or mixes API routes');
  if (api === 'openai-responses') { if (!path) path = '/v1'; }
  else if (path.endsWith('/v1')) path = path.slice(0, -3);
  url.pathname = path || '/';
  const baseUrl = url.href.replace(/\/$/, '');
  return { baseUrl, requestUrl: baseUrl + (api === 'openai-responses' ? '/responses' : '/v1/messages') };
}
const compatKeys = {
  'openai-responses': ['supportsDeveloperRole', 'sessionAffinityFormat', 'supportsLongCacheRetention', 'supportsStrictMode', 'supportsOpenAIGrammarTools', 'supportsAdditionalTools', 'supportsToolSearch', 'supportsExplicitPromptCacheMode', 'supportsMaxOutputTokens'],
  'anthropic-messages': ['supportsEagerToolInputStreaming', 'supportsLongCacheRetention', 'sendSessionAffinityHeaders', 'supportsCacheControlOnTools', 'supportsTemperature', 'forceAdaptiveThinking', 'allowEmptySignature', 'supportsStrictTools', 'supportsMidConvoEffort', 'allowedFallbackModels', 'supportsToolReferences'],
};
export function profileFrom(value: unknown): Profile {
  const p = obj(value), api = p.api;
  if (api !== 'openai-responses' && api !== 'anthropic-messages') return fail('Choose Responses or Messages explicitly');
  const contextWindow = p.contextWindow, maxOutputTokens = p.maxOutputTokens;
  if (!Number.isSafeInteger(contextWindow) || !Number.isSafeInteger(maxOutputTokens) || maxOutputTokens <= 0 || contextWindow <= maxOutputTokens || contextWindow > 10_000_000 || maxOutputTokens > 1_000_000) return fail('Set a positive configured capacity and smaller output reserve');
  const result: Profile = { id: text(p.id, 'identity', 128), revision: text(p.revision, 'revision', 128), providerId: text(p.providerId, 'provider', 128), modelId: text(p.modelId, 'model', 256), api,
    baseUrl: resolveEndpoint(api, text(p.baseUrl, 'endpoint')).baseUrl, contextWindow, maxOutputTokens };
  if (p.reasoning !== undefined) { if (typeof p.reasoning !== 'boolean') return fail('Reasoning must be a boolean'); result.reasoning = p.reasoning; }
  if (p.input !== undefined) { if (!Array.isArray(p.input) || !p.input.length || p.input.some(x => x !== 'text' && x !== 'image')) return fail('Supported input types are text and image'); result.input = p.input; }
  if (p.thinkingLevel !== undefined) { if (!['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(p.thinkingLevel)) return fail('Unsupported thinking level'); result.thinkingLevel = p.thinkingLevel; }
  if (p.thinkingLevelMap !== undefined) {
    for (const [key, value] of Object.entries(obj(p.thinkingLevelMap))) if (!['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(key) || (value !== null && typeof value !== 'string')) return fail('Invalid thinking-level mapping');
    result.thinkingLevelMap = p.thinkingLevelMap;
  }
  if (p.compat !== undefined) {
    for (const [key, value] of Object.entries(obj(p.compat))) {
      if (!compatKeys[api as ApiKind].includes(key)) return fail(`Unsupported ${api} compatibility option: ${key}`);
      if (key === 'sessionAffinityFormat') { if (!['openai', 'openai-nosession', 'openrouter'].includes(value as string)) return fail('Invalid session affinity'); }
      else if (key === 'allowedFallbackModels') { if (!Array.isArray(value) || value.length > 32 || value.some(x => !x || typeof x.provider !== 'string' || typeof x.model !== 'string' || !x.cost)) return fail('Invalid fallback models'); }
      else if (typeof value !== 'boolean') return fail(`Compatibility option ${key} must be boolean`);
    }
    result.compat = structuredClone(p.compat);
  }
  if (p.samplingParams !== undefined) { const params = obj(p.samplingParams); if (Buffer.byteLength(JSON.stringify(params)) > 16384) return fail('Sampling configuration is too large'); result.samplingParams = structuredClone(params); }
  if (p.cost !== undefined) { if (['input', 'output', 'cacheRead', 'cacheWrite'].some(k => typeof p.cost[k] !== 'number' || !Number.isFinite(p.cost[k]) || p.cost[k] < 0)) return fail('Invalid cost information'); result.cost = p.cost; }
  if (p.publicMetadataHeaders !== undefined) { if (!Array.isArray(p.publicMetadataHeaders) || p.publicMetadataHeaders.length > 32 || p.publicMetadataHeaders.some(x => typeof x !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(x))) return fail('Invalid public metadata header allowlist'); result.publicMetadataHeaders = p.publicMetadataHeaders; }
  if (p.headers !== undefined) { const headers = obj(p.headers); if (Object.keys(headers).length > 64 || Object.entries(headers).some(([k,v]) => !/^[\w-]{1,128}$/.test(k) || typeof v !== 'string' || v.length > 16384 || /[\r\n]/.test(v))) return fail('Invalid headers'); result.headers = headers; }
  if (p.source !== undefined) { const s = obj(p.source); if (!/^[a-f0-9]{64}$/.test(s.sha256)) return fail('Invalid configuration source hash'); result.source = { modelsPath: text(s.modelsPath, 'models path'), authPath: text(s.authPath, 'auth path'), sha256: s.sha256, commandTrust: s.commandTrust === true, ...(s.settingsPath && /^[a-f0-9]{64}$/.test(s.settingsSHA256) ? { settingsPath: text(s.settingsPath, 'Pi settings path'), settingsSHA256: s.settingsSHA256 } : {}) }; }
  return result;
}

export async function configurationFile(path: string): Promise<{ path: string; sha256: string; data: Record<string, any> }> {
  const file=await readSource(await realpath(path),2*1024*1024);
  if (!file) throw Object.assign(new Error('Pi configuration disappeared during read'),{code:'ENOENT'});
  return { path:file.path,sha256:file.hash,data:obj(JSON.parse(file.text)) };
}
export async function discoverProfiles(path: string): Promise<unknown> {
  const file = await configurationFile(path);
  // Pi composes model definitions without refreshing availability or resolving auth.
  const runtime = await ModelRuntime.create({ modelsPath: file.path, credentials: new InMemoryCredentialStore(), modelsStore: new InMemoryModelsStore(), allowModelNetwork: false, refreshOnCreate: false });
  if (runtime.getError()) return fail('Pi rejected this models.json. Inspect its configuration; no credential command was run.');
  if ((await configurationFile(file.path)).sha256 !== file.sha256) return fail('Configuration changed; refresh discovery');
  let settings: Awaited<ReturnType<typeof configurationFile>> | undefined;
  try { settings = await configurationFile(join(dirname(file.path), 'settings.json')); } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  const providers = obj(file.data.providers ?? {}), profiles: unknown[] = [], unsupported: string[] = [];
  for (const provider of Object.keys(providers)) for (const model of runtime.getModels(provider)) {
    if (profiles.length >= 512) return fail('Discovery exceeds 512 profiles');
    if (model.api !== 'openai-responses' && model.api !== 'anthropic-messages') { unsupported.push(`${provider}/${model.id}: ${model.api}`); continue; }
    const id = createHash('sha256').update(`${file.path}\0${provider}\0${model.id}\0${model.api}`).digest('hex');
    const source = { modelsPath: file.path, authPath: join(dirname(file.path), 'auth.json'), sha256: file.sha256, commandTrust: false, ...(settings ? { settingsPath: settings.path, settingsSHA256: settings.sha256 } : {}) };
    const definition = providers[provider].models?.find((x: any) => x.id === model.id);
    const headers = { ...providers[provider].headers, ...providers[provider].modelOverrides?.[model.id]?.headers, ...definition?.headers };
    const commands = [providers[provider].apiKey, ...Object.values(headers)].some(x => typeof x === 'string' && x.startsWith('!'));
    const known = new Set(['id','name','api','baseUrl','reasoning','input','cost','contextWindow','maxTokens','thinkingLevelMap','samplingParams','headers','compat']);
    const unsupportedFields = Object.keys(definition ?? {}).filter(key => !known.has(key));
    profiles.push({ name: `${provider} / ${model.name}`, ...profileFrom({ id, revision: file.sha256, providerId: provider, modelId: model.id, api: model.api, baseUrl: model.baseUrl, contextWindow: model.contextWindow, maxOutputTokens: model.maxTokens,
      thinkingLevel: settings?.data.modelThinkingLevels?.[`${provider}/${model.id}`] ?? settings?.data.defaultThinkingLevel ?? 'medium',
      reasoning: model.reasoning, input: model.input, thinkingLevelMap: model.thinkingLevelMap, samplingParams: model.samplingParams, compat: model.compat, cost: model.cost, source }),
      headerNames: Object.keys(headers), commandCredentials: commands, unsupportedFields, origin: 'Pi models.json; app overrides are separate' });
  }
  return { profiles, unsupported, source: { path: file.path, sha256: file.sha256 }, discoveryMadeModelCall: false };
}

let resolving = false;
export async function resolveProfileCredentials(profile: Profile, apiKey?: string): Promise<{ apiKey: string; headers: Record<string, string> }> {
  if (!profile.source) { if (!apiKey) return fail('Save an API key in Keychain'); return { apiKey, headers: profile.headers ?? {} }; }
  if (resolving) return fail('Another credential resolver is active; try again when it finishes');
  resolving = true;
  try {
    return await new Promise((resolve, reject) => {
      const worker = new Worker(new URL(import.meta.url.endsWith('.ts') ? './profile-resolver-worker.ts' : './profile-resolver-worker.js', import.meta.url), { execArgv: import.meta.url.endsWith('.ts') ? ['--experimental-transform-types'] : [], workerData: { profile, apiKey }, stdout: true, stderr: true });
      worker.stdout.resume(); worker.stderr.resume();
      const timer = setTimeout(() => { void worker.terminate(); reject(new CommandError('credential_timeout', 'Pi credential resolution exceeded 12 seconds. No provider request was sent.')); }, 12_000);
      const finish = (): void => { clearTimeout(timer); void worker.terminate(); };
      worker.once('message', message => { finish(); if (message.ok) resolve(message.result); else reject(new CommandError('credential_unavailable', message.message)); });
      worker.once('error', () => { finish(); reject(new CommandError('credential_unavailable', 'Pi credential resolution failed; no provider request was sent')); });
      worker.once('exit', () => { clearTimeout(timer); reject(new CommandError('credential_unavailable', 'Credential worker exited')); });
    });
  } finally { resolving = false; }
}
