import { parentPort, workerData } from 'node:worker_threads';
import { InMemoryCredentialStore, InMemoryModelsStore } from '@earendil-works/pi-ai';
import { ModelRuntime, readStoredCredential } from '@earendil-works/pi-coding-agent';
import { configurationFile, type Profile } from './profiles.ts';

try {
  const profile = workerData.profile as Profile, source = profile.source!;
  const file = await configurationFile(source.modelsPath);
  if (file.sha256 !== source.sha256) throw new Error('Pi configuration changed since selection. Refresh the imported profile and submit again.');
  if (source.settingsPath && (await configurationFile(source.settingsPath)).sha256 !== source.settingsSHA256) throw new Error('Pi configuration changed since selection. Refresh the imported thinking defaults and submit again.');
  const provider = file.data.providers?.[profile.providerId];
  if (!provider) throw new Error('The imported provider is missing');
  const definition = provider.models?.find((x: any) => x.id === profile.modelId);
  const values = [provider.apiKey, ...Object.values(provider.headers ?? {}), ...Object.values(provider.modelOverrides?.[profile.modelId]?.headers ?? {}), ...Object.values(definition?.headers ?? {})];
  if (!source.commandTrust && values.some(x => typeof x === 'string' && x.startsWith('!'))) throw new Error('This profile uses executable credential commands. Approve that specific profile in Settings before connection.');
  // Bound the published synchronous credential reader before invoking it.
  try { await configurationFile(source.authPath); } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  const stored = readStoredCredential(profile.providerId, source.authPath);
  if (stored?.type === 'oauth' || provider.oauth) throw new Error('Subscription/OAuth credentials are outside the v1 API-key transports. Configure a separate API-key profile.');
  const credentials = new InMemoryCredentialStore();
  if (stored) await credentials.modify(profile.providerId, async () => stored);
  const runtime = await ModelRuntime.create({ credentials, modelsStore: new InMemoryModelsStore(), modelsPath: file.path, allowModelNetwork: false, refreshOnCreate: false });
  const model = runtime.getModel(profile.providerId, profile.modelId);
  if (!model || runtime.getError()) throw new Error('Pi could not compose the imported profile');
  const resolved = await runtime.getAuth(model, workerData.apiKey ? { apiKey: workerData.apiKey } : {});
  if (!resolved?.auth.apiKey) throw new Error('No API key resolved. Check the Pi credential reference and Finder environment.');
  if ((await configurationFile(file.path)).sha256 !== file.sha256) throw new Error('Configuration changed during credential resolution; refresh before sending');
  parentPort!.postMessage({ ok: true, result: { apiKey: resolved.auth.apiKey, headers: { ...resolved.auth.headers, ...profile.headers } } });
} catch (error) {
  // SDK errors can contain resolver stderr or header values. Only app-authored messages leave the worker.
  const message = error instanceof Error && /^(Pi configuration changed|The imported provider|This profile uses|Subscription\/OAuth|Pi could not compose|No API key resolved|Configuration changed during)/.test(error.message) ? error.message : 'Pi credential reference could not be resolved; review the source and command trust. No request was sent.';
  parentPort!.postMessage({ ok: false, message });
}
