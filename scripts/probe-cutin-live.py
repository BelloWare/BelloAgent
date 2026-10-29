#!/usr/bin/env python3
"""OWNER-ONLY paid probe. Never run as part of automated validation.

The root's orchestration is generated locally. Only the real worker's Responses
requests go to the owner's gateway. A transparent SSE relay holds one completed
item until the root's send_message is durable, then lets the helper perform its
normal cut, continuation and background drain. No protocol is added upstream.
"""
import argparse
import http.server
import json
import math
import os
from pathlib import Path
import threading
import time
import urllib.error
import urllib.request
from native_host_client import HostPeer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('helper', type=Path)
    parser.add_argument('--gateway', required=True, help='Owner gateway base URL, ending in /v1')
    parser.add_argument('--alias', required=True, help='Saved gateway alias; identity must be reported separately')
    parser.add_argument('--expected-model', required=True, help='Fixed native OpenAI Responses model from the route contract')
    parser.add_argument('--boundary', choices=['reasoning','commentary'], required=True)
    parser.add_argument('--limit-usd', type=float, default=1, help='Existing family cost limit; concurrent requests retain normal overshoot semantics')
    parser.add_argument('--seconds', type=int, default=300)
    parser.add_argument('--report', type=Path, required=True, help='New private directory for generated journals and the summary')
    args = parser.parse_args()
    # Intentionally read only when the owner executes this program.
    key = os.environ.get('BELLO_PROBE_API_KEY')
    if not key: parser.error('Set BELLO_PROBE_API_KEY in your own shell; do not paste it into a chat.')
    if not args.gateway.startswith(('https://','http://127.0.0.1:','http://localhost:')): parser.error('Use HTTPS for the gateway.')
    args.report.mkdir(mode=0o700,parents=True,exist_ok=False)
    sessions = args.report/'sessions'; sessions.mkdir(mode=0o700)
    root = args.report.resolve(); parent_path = sessions/'parent.jsonl'
    trigger = threading.Event(); ended = threading.Event(); settled = threading.Event()
    lock = threading.Lock(); requests = []; failures = []; completed = {}; retained = []; boundary_item = []; originals = []; child_id = []; parent_count = 0
    deadline = time.monotonic()+args.seconds
    def records(path):
        if not path.exists(): return []
        data = path.read_bytes(); return [json.loads(line) for line in data[:data.rfind(b'\n')+1].splitlines()]
    def wait(predicate):
        while not predicate():
            if failures: raise RuntimeError(failures[0])
            if time.monotonic() >= deadline: raise TimeoutError('Probe deadline; inspect the retained generated journals.')
            time.sleep(.01)
    def accepted():
        return any(r.get('data',{}).get('message',{}).get('text') == 'PROBE-MAIL: stop the original explanation and answer READY.' for r in records(parent_path))
    def frame(event): return ('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode()
    class Relay(http.server.BaseHTTPRequestHandler):
        def log_message(self,*unused): pass
        def do_POST(self):
            nonlocal parent_count
            try:
                data = self.rfile.read(int(self.headers['Content-Length'])); body = json.loads(data)
                source = self.headers['x-session-id']
                if source == 'parent':
                    with lock: parent_count += 1; number = parent_count
                    if number == 1:
                        task = ('Work without tools. Give a careful analysis of why there are infinitely many prime numbers, comparing two proofs. '
                                'First send a commentary message describing your approach, then reason fully, then give your final answer. '
                                'If a team message arrives, follow it immediately and answer READY.')
                        output = [dict(type='function_call',id='fc_spawn',call_id='spawn',name='spawn_agent',arguments=json.dumps(dict(task_name='worker',message=task,fork_turns='none')))]
                    elif number == 2:
                        wait(lambda:trigger.is_set() or ended.is_set())
                        if trigger.is_set(): output = [dict(type='function_call',id='fc_mail',call_id='mail',name='send_message',arguments=json.dumps(dict(target='worker',message='PROBE-MAIL: stop the original explanation and answer READY.')))]
                        else: output = [dict(type='message',id='msg_root',role='assistant',phase='final_answer',content=[dict(type='output_text',text='Probe ended without the requested boundary.')])]
                    else: output = [dict(type='message',id='msg_root'+str(number),role='assistant',phase='final_answer',content=[dict(type='output_text',text='Probe orchestration complete.')])]
                    self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
                    self.wfile.write(frame(dict(type='response.completed',response=dict(id='root-'+str(number),model=args.expected_model,status='completed',output=output,usage=dict(input_tokens=0,output_tokens=0,cost=0))))); self.wfile.flush(); return
                with lock:
                    number = len(requests)+1; requests.append(body)
                    if not child_id: child_id.append(source)
                headers = {'Authorization':'Bearer '+key,'Content-Type':'application/json','Accept':'text/event-stream'}
                for name in ['x-session-id','x-turn-id','session_id','x-client-request-id']:
                    if self.headers.get(name): headers[name] = self.headers[name]
                request = urllib.request.Request(args.gateway.rstrip('/')+'/responses',data=data,headers=headers,method='POST')
                with urllib.request.urlopen(request,timeout=args.seconds) as upstream:
                    if 'text/event-stream' not in upstream.headers.get('Content-Type',''): raise RuntimeError('Gateway did not return SSE; this route waits for the normal boundary.')
                    self.send_response(upstream.status); self.send_header('Content-Type','text/event-stream')
                    for name in ['x-litellm-model-name','x-litellm-model-group','x-litellm-response-cost']:
                        if upstream.headers.get(name): self.send_header(name,upstream.headers[name])
                    self.end_headers()
                    event_lines = []
                    for line in upstream:
                        event_lines.append(line)
                        if line.strip(): continue
                        packet = b''.join(event_lines); event_lines = []
                        raw = b'\n'.join(part[5:].strip() for part in packet.splitlines() if part.startswith(b'data:'))
                        event = json.loads(raw) if raw and raw != b'[DONE]' else {}
                        if number == 1 and event.get('type') == 'response.output_item.done':
                            item = event['item']; completed[event['output_index']] = item
                            eligible = item.get('type') == args.boundary if args.boundary == 'reasoning' else item.get('type') == 'message' and item.get('role') == 'assistant' and item.get('phase') == 'commentary'
                            if eligible and not trigger.is_set():
                                retained.extend(completed[index] for index in sorted(completed))
                                boundary_item.append(item['id']); trigger.set(); wait(accepted)
                        self.wfile.write(packet); self.wfile.flush()
                        if event.get('type') in ('response.completed','response.incomplete'):
                            if number == 1: originals.append(event['response'])
                            elif event['response'].get('status') == 'completed': settled.set()
                    if event_lines: self.wfile.write(b''.join(event_lines)); self.wfile.flush()
                if number == 1: ended.set()
            except (BrokenPipeError,ConnectionResetError):
                failures.append('The helper closed a probe stream before its natural end.')
            except urllib.error.HTTPError as error:
                failures.append(f'Gateway rejected request with HTTP {error.code}; inspect your gateway log (no key is logged here).')
            except Exception as error:
                failures.append(type(error).__name__+': '+str(error)); ended.set()
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Relay)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    # The paid key belongs only to this relay, never to a worker/tool process.
    helper_env = {name:value for name,value in os.environ.items() if name != 'BELLO_PROBE_API_KEY'}
    peer = HostPeer(args.helper,root,env=helper_env,home=root/'home'); peer.epoch = peer.hello(10)['hostEpoch']
    def command(method,params=None,session='parent'):
        identity = peer.post(method,params,session)
        while True:
            value = peer.next_frame(args.seconds)
            if value.get('commandId') == identity:
                if not value['ok']: raise RuntimeError(value['result'])
                return value['result']
    try:
        command('workspace.open',dict(cwd=str(root),directory=str(sessions.resolve()),captureProtocol=1,resources=dict(codexHome=str(root/'codex'),skills=False)),None)
        profile = dict(id='owner-probe',revision='cutin-live-1',providerId='litellm',modelId=args.alias,api='openai-responses',baseUrl=f'http://127.0.0.1:{server.server_port}/v1',contextWindow=100000,maxOutputTokens=4096,reasoning=True,thinkingLevel='high',routing=dict(replayPolicy='pinned',expectedModel=args.expected_model,replayContract='Owner-supplied native fixed Responses route for this probe'))
        command('session.open',dict(profile=profile,apiKey='local-relay-only',toolMode='read-only'))
        command('session.configure',dict(costLimit=dict(usd=args.limit_usd)))
        command('turn.submit',dict(clientTurnId='probe',text='Run the generated worker probe.'))
        wait(lambda:settled.is_set() or ended.is_set() and not trigger.is_set())
        if not trigger.is_set(): raise RuntimeError('INCONCLUSIVE: the model emitted no '+args.boundary+' item. Retry this probe; do not count it as passing.')
        wait(lambda:ended.is_set() and settled.is_set())
        child_path = sessions/(child_id[0]+'.jsonl')
        def cuts(): return [r['message']['nativeMailboxCut'] for r in records(child_path) if 'nativeMailboxCut' in r.get('message',{})]
        wait(lambda:bool(cuts()))
        cut = cuts()[0]; assert len(cuts()) == 1 and cut['itemId'] == boundary_item[0]
        def costs(): return [r['data'] for r in records(parent_path) if r.get('customType') == 'pi-app.cost.v1' and r.get('data',{}).get('attemptId') == cut['attemptId']]
        wait(lambda:bool(costs()))
        cost = costs(); assert len(cost) == 1, 'Original attempt settled more than once'
        if cost[0].get('reported') != 1: raise RuntimeError('INCONCLUSIVE: the gateway did not report final dollars for the drained attempt.')
        assert len(requests) >= 2 and originals, 'No accepted continuation or no naturally drained terminal'
        usage = originals[0].get('usage') or {}
        if not isinstance(usage.get('output_tokens'),int): raise RuntimeError('INCONCLUSIVE: no final upstream output-token count.')
        assert cost[0]['usage']['output'] == usage['output_tokens'], 'Discarded output was omitted from original-attempt usage'
        reported = [float(usage[field]) for field in ('cost','response_cost') if usage.get(field) is not None]
        if not reported or any(not math.isfinite(value) or value < 0 for value in reported):
            raise RuntimeError('INCONCLUSIVE: no valid final upstream dollar amount. A pre-stream cost header is insufficient.')
        assert all(abs(cost[0]['usd']-value) < 1e-9 for value in reported), 'Drained dollars differ from the upstream terminal'
        incoming = requests[1]['input']; positions = [incoming.index(item) for item in retained]
        assert positions == sorted(positions), 'Retained prefix changed or reordered'
        assert 'PROBE-MAIL' in json.dumps(incoming), 'Continuation omitted the mail'
        retained_ids = {item['id'] for item in retained}
        for item in list(completed.values())+originals[0].get('output',[]):
            if item.get('id') not in retained_ids: assert item not in incoming, 'Discarded suffix leaked'
        report = dict(boundary=args.boundary,cut=cut,upstreamTerminal=originals[0]['status'],upstreamUsage=originals[0].get('usage'),settlement=cost[0],workerRequests=len(requests),continuationAccepted=True)
        (root/'result.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
        print(f'PASS {args.boundary}: real worker cut, retained prefix accepted, original attempt settled once: ${cost[0]["usd"]:.8f}. Report: {root/"result.json"}')
    finally:
        peer.send(dict(v=1,kind='shutdown',hostEpoch=peer.epoch))
        try: peer.process.wait(timeout=15)
        except Exception: peer.process.kill()
        peer.close(); server.shutdown(); server.server_close()

if __name__ == '__main__': main()
