import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, stat } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { FixtureServer, fragment } from '../fixtures/providers/server.ts';
import { traffic } from '../fixtures/providers/traffic.ts';

const [app, output] = process.argv.slice(2); assert.ok(app && output, 'APP and output.json required');
const host = join(resolve(app), 'Contents/Resources/Host/packages/host/src');
const { PiSessionAdapter } = await import(pathToFileURL(join(host, 'pi/session-adapter.js')));
const { CaptureStore } = await import(pathToFileURL(join(host, 'observability/capture-store.js')));
const scratch = await mkdtemp(join(dirname(resolve(output)), 'host-benchmark-'));
const report = { node: process.version, app: resolve(app), bytesPerResponseText: 1048576, wireChunkBytes: 65536, delayMsPerChunk: 1, measured: [] };
const median = a => [...a].sort((x,y)=>x-y)[Math.floor(a.length/2)];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const save=()=>writeFile(output,JSON.stringify(report,null,2)+'\n',{mode:0o600});
process.on('uncaughtException',error=>{void save().finally(()=>{process.stderr.write(String(error.stack)+'\n');process.exitCode=1;});});
for (const api of (process.env.PI_BENCH_APIS?.split(',') ?? ['openai-responses','anthropic-messages'])) {
  const text = '0123456789abcdef'.repeat(65536), response = traffic(api, {text,unknown:true});
  const chunks = fragment(response,[65536]);
  const server = await new FixtureServer(()=>({chunks,delayMs:1})).start();
  const profile = {id:'benchmark',revision:'1',providerId:'benchmark',modelId:'fixture-model',api,baseUrl:server.origin,contextWindow:2000000,maxOutputTokens:300000};
  let serial = 0; const capture = new CaptureStore();
  const create = (extra={})=>PiSessionAdapter.create({sessionId:`benchmark-${serial++}`,cwd:scratch,agentDir:join(scratch,'agent'),profile,apiKey:'synthetic-fixture-only',capture,...extra});
  const clearServer = ()=>{server.requests=[];server.emitted=[];};
  try {
    const runs={off:[],memory:[]};
    for(let n=-4;n<24;n++) {
      const mode=n%2===0?'off':'memory'; capture.mode=mode; clearServer();
      const session=await create(), start=performance.now();
      const outcome=await session.submit('One mebibyte response fixture.');
      if(outcome!=='completed') {
        const saved=await session.prepareKeep(join(scratch,'failed'));
        const entries=(await readFile(saved.path,'utf8')).trim().split('\n').map(JSON.parse);
        process.stderr.write(JSON.stringify({api,error:entries.findLast(e=>e.message?.role==='assistant')?.message?.errorMessage,attempts:capture.attempts.map(a=>({status:a.status,error:a.errorKind}))})+'\n');
        await saved.adapter.dispose();await session.dispose();
      }
      assert.equal(outcome,'completed');
      const elapsed=performance.now()-start;
      assert.equal(session.snapshot().at(-1).text,text);
      const projection=session.projection();assert.ok(Buffer.byteLength(JSON.stringify(projection))<500000);assert.equal(projection.messages.at(-1).truncated,true);
      if(mode==='memory') {
        const attempt=capture.attempts.at(-1); assert.equal(attempt.response.state,'complete');
        assert.equal(capture.hash(attempt.response).sha256,sha(response)); assert.deepEqual(Buffer.from(capture.read(attempt.request)),server.requests[0].bytes);
      }
      if(n>=0)runs[mode].push(elapsed);
      await session.dispose(); capture.clear();
    }
    const overhead=(median(runs.memory)/median(runs.off)-1)*100;
    report.measured.push({api,case:'capture-overhead',responseWireBytes:response.length,offMs:runs.off,memoryMs:runs.memory,medianOffMs:median(runs.off),medianMemoryMs:median(runs.memory),overheadPercent:overhead,targetPercent:5});
    await save();
    process.stdout.write(`${api} capture overhead ${overhead.toFixed(2)}%\n`);
    capture.mode='memory'; capture.clear();const resident=[];
    // Fresh Pi sessions prevent unrelated growing model history from obscuring
    // the shared workspace capture quota. Capture is never disabled to pass.
    const iterations=Math.ceil(128*1024*1024/response.length)+10;
    for(let n=0;n<iterations;n++) {
      clearServer(); const session=await create(); assert.equal(await session.submit('Repeated large response.'),'completed');
      assert.equal(session.snapshot().at(-1).text,text);
      const newest=capture.attempts.at(-1);assert.equal(newest.response.state,'complete');assert.equal(capture.hash(newest.response).sha256,sha(response));
      await session.dispose();
      assert.ok(capture.retainedBytes<=128*1024*1024);assert.ok(capture.allocatedBytes<=128*1024*1024);
      resident.push({iteration:n+1,...process.memoryUsage(),captureBytes:capture.retainedBytes});
    }
    const evicted=capture.attempts.filter(a=>a.response.state==='evicted').length;
    assert.ok(evicted>0);report.measured.push({api,case:'capture-budget-exhaustion',iterations,evictedResponses:evicted,retainedBytes:capture.retainedBytes,allocatedBytes:capture.allocatedBytes,resident,
      memoryScope:'Standalone Node plus its in-process fixture, not native/WebKit aggregate. Final native aggregate is measured separately.'});
    await save();process.stdout.write(`${api} ${iterations} large responses: capture ${capture.retainedBytes} bytes, ${evicted} evicted\n`);
    capture.clear();clearServer();const main=await create(), side=await main.createSide(`side-${serial++}`), start=performance.now();
    await Promise.all([main.submit('Main stream'),side.submit('Side stream')]);
    assert.equal(main.snapshot().at(-1).text,text);assert.equal(side.snapshot().at(-1).text,text);
    assert.equal(server.requests.length,2);assert.equal(new Set(capture.attempts.slice(-2).map(a=>a.sessionId)).size,2);
    report.measured.push({api,case:'two-streams',elapsedMs:performance.now()-start,responseBytesEach:response.length,modelTextBytesEach:text.length});
    await side.dispose();await main.dispose();capture.clear();
  } finally {await server.close();}

  const toolServer=await new FixtureServer((_r,index)=>({chunks:[traffic(api,index===0?{tool:true,toolName:'bash',toolInput:{command:"/usr/bin/head -c 52428800 /dev/zero | /usr/bin/tr '\\000' x"}}:{text:'Large tool fixture completed.'})]})).start();
  const toolCapture=new CaptureStore(),session=await PiSessionAdapter.create({sessionId:`tool-${api}`,cwd:scratch,agentDir:join(scratch,'agent'),sessionDirectory:join(scratch,api),
    profile:{...profile,baseUrl:toolServer.origin},apiKey:'synthetic-fixture-only',capture:toolCapture,tools:['bash']});
  try {
    const start=performance.now();await session.submit('Run the 50 MiB output fixture.');
    assert.equal(toolServer.requests.length,2);
    const entries=(await readFile(session.sessionFile,'utf8')).trim().split('\n').map(JSON.parse);
    const tool=entries.find(e=>e.type==='message'&&e.message.role==='toolResult').message;
    const fullPath=tool.details.fullOutputPath;assert.ok(fullPath,'Pi exposes its full output file');
    assert.equal((await stat(fullPath)).size,52428800);
    const resultText=tool.content.filter(c=>c.type==='text').map(c=>c.text).join('');
    assert.ok(Buffer.byteLength(resultText)<60000);assert.match(resultText,/truncat|full output|output saved/i);
    for(const [index,a] of toolCapture.attempts.entries()) { assert.deepEqual(Buffer.from(toolCapture.read(a.request)),toolServer.requests[index].bytes); assert.equal(toolCapture.hash(a.response).sha256,sha(Buffer.concat(toolServer.emitted[index]))); }
    report.measured.push({api,case:'50-MiB-bash-output',elapsedMs:performance.now()-start,fullOutputBytes:52428800,piToolResultBytes:Buffer.byteLength(resultText),nativePreviewBytes:Buffer.byteLength(JSON.stringify(session.projection())),sdkTruncation:tool.details.truncation});
    await save();
    if(fullPath.startsWith(process.env.TMPDIR+'/')) await rm(fullPath);
    process.stdout.write(`${api} actual bash 50 MiB output retained by Pi; bounded model result verified\n`);
  } finally {await session.dispose();await toolServer.close();}
}
await writeFile(output,JSON.stringify(report,null,2)+'\n',{mode:0o600});
await rm(scratch,{recursive:true,force:true});
if(report.measured.some(r=>r.case==='capture-overhead'&&r.overheadPercent>5)) { process.stderr.write('Capture overhead target missed; inspect the measured report.\n');process.exitCode=1; }
