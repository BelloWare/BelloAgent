import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { attachmentsFrom, readAttachments } from '../src/pi/attachments.ts';
import { PiSessionAdapter } from '../src/pi/session-adapter.ts';
import { CaptureStore } from '../src/observability/capture-store.ts';
import { FixtureServer } from '../../../fixtures/providers/server.ts';
import { traffic } from '../../../fixtures/providers/traffic.ts';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=','base64');
for (const api of ['openai-responses','anthropic-messages'] as const) test(`${api}: selected image bytes reach Pi, changed queued references are rejected`, async () => {
  const root = await mkdtemp(join(tmpdir(),'pi-images-')), path = join(root,'test.png');
  const server = await new FixtureServer(()=>({chunks:[traffic(api)]})).start(); let adapter: PiSessionAdapter | undefined;
  try {
    await writeFile(path,png);
    const images = attachmentsFrom([{id:'image',path,sha256:createHash('sha256').update(png).digest('hex'),bytes:png.length,mimeType:'image/png'}]);
    assert.deepEqual(Buffer.from((await readAttachments(images))[0]!.data,'base64'),png);
    const capture = new CaptureStore();
    adapter = await PiSessionAdapter.create({cwd:root,agentDir:root,apiKey:'synthetic',capture, profile: {id:'p',revision:'r',providerId:'fixture',modelId:'fixture-model',api,baseUrl:server.origin,contextWindow:8192,maxOutputTokens:1024,input:['text','image']}});
    await adapter.submit('Describe this synthetic pixel','turn',{text:'Describe',turnId:'turn',commandId:'cmd',attachments:images});
    assert.ok(server.requests[0]!.bytes.toString().includes(png.toString('base64')));
    await writeFile(path,Buffer.alloc(png.length)); await assert.rejects(readAttachments(images),/changed/);
    assert.throws(()=>attachmentsFrom(new Array(5).fill(images[0])),/four/);
  } finally { await adapter?.dispose(); await server.close(); await rm(root,{recursive:true,force:true}); }
});
