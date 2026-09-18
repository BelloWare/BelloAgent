import { readFile, writeFile, access } from 'node:fs/promises';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { setTimeout } from 'node:timers/promises';
import { responses,messages,event,traffic } from '../fixtures/providers/traffic.ts';

const root=process.argv[2]!;
const config=JSON.parse(await readFile(join(root,'configuration.json'),'utf8'));
const prefix='# Release fixture\n\nNative editing during streamed Markdown. 🌍\n\n```typescript\nconst pane = "independent";\n```\n\n';
const text=prefix+'A synthetic Markdown paragraph.\n\n'.repeat(33000);
const full=Buffer.from(text).subarray(0,1048576).toString('utf8');
const unknown='x'.repeat(16*1024*1024);let requests=0,saturation=0,active=0;
const counts={requests:0,active:0,completed:0,cancelled:0,responseBytes:0,saturationCalls:0,attempts:[] as object[]};
let logTail=Promise.resolve();
const log=()=>{const bytes=JSON.stringify(counts,null,2)+'\n';logTail=logTail.then(()=>writeFile(join(root,'fixture-counts.json'),bytes));};
const server=createServer((req,res)=>void(async()=>{
  const bytes=[];for await(const data of req)bytes.push(data);const body=Buffer.concat(bytes).toString();
  const api=req.url?.includes('responses')?'openai-responses':'anthropic-messages',payload=JSON.parse(body);
  const prompt=(payload.input??payload.messages??[]).filter((m:any)=>m.role==='user').flatMap((m:any)=>typeof m.content==='string'?[m.content]:(m.content??[]).filter((b:any)=>['text','input_text'].includes(b.type)).map((b:any)=>b.text)).at(-1)??'';
  const slow=prompt.includes('two streams'),stress=prompt.includes('capture saturation');
  requests++;active++;counts.requests=requests;counts.active=active;log();
  const responseHash=createHash('sha256'),requestHash=createHash('sha256').update(body).digest('hex');let emitted=0;
  let ended=false;res.on('close',()=>{active--;counts.active=active;if(!ended)counts.cancelled++;counts.attempts.push({api,requestBytes:Buffer.byteLength(body),requestSHA256:requestHash,responseBytes:emitted,responseSHA256:responseHash.digest('hex'),completed:ended});log();});
  let wire:Buffer[],delay=0;
  if(stress){
    saturation++;counts.saturationCalls=saturation;
    const leading=Buffer.from(event(api==='openai-responses'?'response.future_fixture':'future_fixture',{opaqueFixture:unknown}));
    const ending=traffic(api,saturation<=10?{tool:true,toolName:'read',toolInput:{path:join(root,'workspace','tiny.txt')}}:{text:'Capture saturation complete.'});
    const combined=Buffer.concat([leading,ending]);wire=[];for(let at=0;at<combined.length;at+=65536)wire.push(combined.subarray(at,at+65536));
  }else{
    const parts=(api==='openai-responses'?responses:messages)({text:full,unknown:true});
    if(slow){wire=parts.map(x=>Buffer.from(x));delay=8;}
    else {const combined=Buffer.from(parts.join(''));wire=[];for(let at=0;at<combined.length;at+=65536)wire.push(combined.subarray(at,at+65536));delay=2;}
  }
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  if(slow && process.argv.includes('--gate-start')) {
    // A deterministic fixture gate lets both native panes initialize before
    // measuring steady foreground rendering; the real SDK requests stay open.
    const deadline=Date.now()+120000;
    while(!res.destroyed && Date.now()<deadline) {
      if(await access(join(root,'stream-start')).then(()=>true,()=>false))break;
      await setTimeout(20);
    }
  }
  for(const chunk of wire){if(delay)await setTimeout(delay);if(res.destroyed)break;counts.responseBytes+=chunk.length;emitted+=chunk.length;responseHash.update(chunk);
    if(!res.write(chunk))await new Promise<void>(resolve=>{const done=()=>{res.off('drain',done);res.off('close',done);resolve();};res.once('drain',done);res.once('close',done);});}
  if(!res.destroyed){ended=true;counts.completed++;res.end();}log();
})().catch(()=>res.destroy()));
server.listen(config.port,'127.0.0.1');await once(server,'listening');process.stdout.write(`Fixture ready on ${config.port}\n`);
