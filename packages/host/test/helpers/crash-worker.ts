import { appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { PiSessionAdapter } from '../../src/pi/session-adapter.ts';
import { CaptureStore } from '../../src/observability/capture-store.ts';
const [root, origin, id] = process.argv.slice(2);
if (!root || !origin || !id) throw new Error('Missing fixture paths');
process.stdin.resume();
const session = await PiSessionAdapter.create({ sessionId: id, cwd: root, agentDir: join(root, 'agent'), sessionDirectory: join(root, 'sessions'),
  capture: new CaptureStore(), apiKey: 'synthetic-crash-key',
  profile: { id: 'crash-fixture', revision: 'one', providerId: 'fixture-provider', api: 'openai-responses', baseUrl: origin + '/v1',
    modelId: 'fixture-model', contextWindow: 8192, maxOutputTokens: 333 },
  fixtureEcho: async () => {
    await appendFile(join(root, 'synthetic-effect.txt'), 'effect\n');
    process.stdout.write('{"phase":"effect-written"}\n');
    return new Promise<string>(() => {});
  } });
session.recordCommand('uncertain-command', 'interrupted-turn', 'dispatched');
await session.submit('Run the synthetic effect tool.', 'interrupted-turn');
