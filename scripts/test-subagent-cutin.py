#!/usr/bin/env python3
"""Native Responses mailbox cut-in: generated family, loopback HTTP, no keys."""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import shutil
import sys
import tempfile
import threading
import time
import traceback
from native_host_client import HostPeer

BUILD = Path(os.environ['PI_BUILD_ROOT'])
MODES = ('reasoning', 'commentary', 'partial_answer', 'root', 'overlap', 'error', 'stop', 'quit', 'crash', 'terminal_race', 'portable', 'ask', 'translated', 'unknown', 'json', 'no_usage', 'no_dollars', 'dollars_only', 'incomplete', 'duplicate_terminal', 'interrupt', 'reasoning_only', 'commentary_only', 'followup')


def records(path):
    if not path.exists(): return []
    data = path.read_bytes()
    return [json.loads(line) for line in data[:data.rfind(b'\n')+1].splitlines()]


def call(name, key, args):
    return dict(type='function_call', id='fc_'+key, call_id=key, name=name, arguments=json.dumps(args))


def answer(text, phase='final_answer', key='answer'):
    return dict(type='message', role='assistant', id='msg_'+key, phase=phase, status='completed', content=[dict(type='output_text', text=text, annotations=[])])


def run(binary, mode, crash_point=None, recovery=None, failure_point=None):
    with tempfile.TemporaryDirectory(prefix='cutin-'+mode+'-', dir=BUILD) as folder:
        root = Path(folder); sessions = root/'sessions'; sessions.mkdir()
        parent_path = sessions/'parent.jsonl'
        release = threading.Event(); ready = threading.Event(); second = threading.Event(); continuation = threading.Event(); finished = threading.Event()
        errors = []; requests = []; counts = {}; packets = []; drains = []; children = []; lock = threading.Lock(); peers = []
        negative = mode in ('portable','ask','translated','unknown','json')
        no_tool = mode in ('reasoning_only','commentary_only')
        recipient = lambda session: session == 'parent' if mode == 'root' else session != 'parent'
        effective = 'claude-opus-4' if mode == 'translated' else 'gpt-5.4'
        def wait(predicate, timeout=30):
            deadline = time.monotonic()+timeout
            while not predicate():
                assert not errors, errors
                assert time.monotonic() < deadline, (mode, 'deadline', counts, errors)
                time.sleep(.005)
        def pending(session, text):
            return any(r.get('data',{}).get('message',{}).get('text') == text and (r['data']['message'].get('recipientChildID') or 'parent') == session for r in records(parent_path))
        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def frame(self,event):
                self.wfile.write(('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode()); self.wfile.flush()
            def do_POST(self):
                try:
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    session = self.headers['x-session-id']
                    with lock:
                        n = counts.get(session,0)+1; counts[session] = n
                        requests.append(dict(session=session, number=n, body=body))
                        if session != 'parent' and session not in children: children.append(session)
                    is_cut = recipient(session) and n == (2 if mode == 'root' else 1) or mode == 'overlap' and session != 'parent' and n == 2
                    if is_cut:
                        which = 2 if mode == 'overlap' and n == 2 else 1
                        if which == 2: self.check_continuation(body,1)
                        prefix = ([call('bash','buffered-'+str(which),dict(command='touch forbidden'))] if not negative and not no_tool else [])
                        item = answer('Retained note '+str(which),mode if mode in ('commentary','partial_answer') else 'commentary',key='note-'+str(which)) if mode in ('commentary','partial_answer','commentary_only') or negative else dict(type='reasoning',id='rs_'+str(which),summary=[],encrypted_content='exact-opaque-雪-+/='+str(which))
                        prefix.append(item)
                        self.send_response(200); self.send_header('Content-Type','application/json' if mode == 'json' else 'text/event-stream'); self.end_headers()
                        if mode != 'json': self.frame(dict(type='response.created',response=dict(id='resp_'+str(which),model=body['model'] if mode == 'unknown' else effective)))
                        (second if which == 2 else ready).set()
                        wait(lambda:pending(session,'MAIL-'+str(which)))
                        suffix = [answer('DISCARDED-SUFFIX-'+str(which),key='discard-'+str(which)),call('bash','discarded-'+str(which),dict(command='touch suffix-forbidden'))] if not negative else [answer('Uncut final'),call('bash','ordinary-boundary',dict(command='printf boundary > ordinary-boundary'))]
                        response = dict(id='resp_'+str(which),model=effective,status='completed',output=prefix+suffix,usage=dict(input_tokens=200,output_tokens=2000,total_tokens=2200,cost=.02))
                        if mode == 'no_usage': response.pop('usage')
                        if mode == 'no_dollars': response['usage'].pop('cost')
                        if mode == 'dollars_only': response['usage'] = dict(cost=.02)
                        if mode == 'incomplete': response.update(status='incomplete',incomplete_details=dict(reason='max_output_tokens'))
                        if mode == 'json':
                            assert release.wait(30)
                            self.wfile.write(json.dumps(response).encode()); self.wfile.flush(); return
                        if mode == 'terminal_race':
                            events = [dict(type='response.output_item.done',output_index=index,item=piece) for index,piece in enumerate(prefix+suffix)]
                            events.append(dict(type='response.completed',response=response))
                            # One write puts cut and terminal in the same parser batch.
                            self.wfile.write(b''.join(('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode() for event in events)); self.wfile.flush(); return
                        for index,piece in enumerate(prefix): self.frame(dict(type='response.output_item.done',output_index=index,item=piece))
                        drains.append((session,n))
                        if mode != 'terminal_race': assert release.wait(30)
                        if mode == 'error': return
                        for index,piece in enumerate(suffix,len(prefix)):
                            self.frame(dict(type='response.output_item.added',output_index=index,item=piece))
                            self.frame(dict(type='response.output_text.delta',output_index=index,delta='DISCARDED-DELTA'))
                            self.frame(dict(type='response.output_item.done',output_index=index,item=piece))
                        self.frame(dict(type='response.incomplete' if mode == 'incomplete' else 'response.completed',response=response))
                        if mode == 'duplicate_terminal': self.frame(dict(type='response.completed',response=response))
                        return
                    if session == 'parent':
                        if n == 1: output = [call('spawn_agent','spawn',dict(task_name='worker',message='Generated cut-in worker',fork_turns='none'))]
                        elif mode == 'root':
                            assert n >= 3
                            self.check_continuation(body,1); continuation.set(); output = [answer('Parent continued')]
                        elif n == 2:
                            assert ready.wait(30); output = [call('send_message','mail-1',dict(target='worker',message='MAIL-1'))]
                        elif mode == 'overlap' and n == 3:
                            assert second.wait(30); output = [call('send_message','mail-2',dict(target='worker',message='MAIL-2'))]
                        elif mode == 'followup' and n == 3:
                            wait(lambda:any(r.get('customType') == 'pi-app.subagent-turn-terminal.v1' and r.get('data',{}).get('turn') == 1 and r.get('data',{}).get('status') == 'completed' for r in records(parent_path)))
                            output = [call('followup_task','followup',dict(target='worker',message='FOLLOWUP-WHILE-DRAINING'))]
                        elif mode == 'interrupt' and n == 3:
                            assert continuation.wait(30); output = [call('interrupt_agent','interrupt',dict(target='worker'))]
                        else: output = [answer('Parent synthesis')]
                    else:
                        if mode == 'root' and n == 1:
                            assert ready.wait(30); output = [call('send_message','mail-1',dict(target='/root',message='MAIL-1'))]
                        elif mode == 'root': output = [answer('Worker finished')]
                        else:
                            self.check_continuation(body,2 if mode == 'overlap' else 1); continuation.set()
                            if mode in ('stop','quit','crash','interrupt'): assert release.wait(30)
                            if mode == 'followup' and n == 3:
                                assert 'FOLLOWUP-WHILE-DRAINING' in json.dumps(body), body
                                assert not release.is_set(), 'follow-up waited for drain'
                                output = [answer('Follow-up finished while draining')]
                            else: output = [answer('Worker continued and finished')]
                    self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
                    self.frame(dict(type='response.completed',response=dict(id='resp-final',model=effective,status='completed',output=output,usage=dict(input_tokens=100,output_tokens=10,total_tokens=110,cost=.01))))
                except (BrokenPipeError,ConnectionResetError): pass
                except BaseException:
                    errors.append(traceback.format_exc()); release.set(); ready.set(); second.set(); continuation.set()
            def check_continuation(self,body,number):
                wire = json.dumps(body,ensure_ascii=False)
                assert 'MAIL-'+str(number) in wire, ('missing delivery',body)
                if not negative:
                    assert 'DISCARDED' not in wire, ('suffix leaked into context',body)
                    if not no_tool: assert 'Not executed: agent message arrived before dispatch.' in wire
                    if mode not in ('commentary','partial_answer','commentary_only'):
                        assert any(i.get('encrypted_content') == 'exact-opaque-雪-+/='+str(number) for i in body['input'])
                    else: assert any(i.get('phase') == ('commentary' if mode == 'commentary_only' else mode) for i in body['input'])
                    assert not (root/'forbidden').exists() and not (root/'suffix-forbidden').exists()
        server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Gateway)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        profile = dict(id='fixture',revision='cutin-fixture-1',providerId='litellm',modelId='fixture-alias',api='openai-responses',baseUrl=f'http://127.0.0.1:{server.server_port}/v1',contextWindow=100000,maxOutputTokens=4096,routing=dict(replayPolicy=mode if mode in ('portable','ask') else 'pinned',expectedModel=effective,replayContract='Generated native fixture'))
        def capture(frame): packets.append(frame['packet']); return True
        def command(peer,method,params=None,session='parent'):
            key = peer.post(method,params,session)
            while True:
                frame = peer.next_frame(30)
                if frame.get('commandId') == key:
                    assert frame['ok'],frame
                    return frame['result']
        def opened(path=None, helper=None):
            env = dict(os.environ, PI_CUTIN_BARRIER_FILE=str(root/'crash-point'))
            if crash_point and helper is None: env['PI_CUTIN_CRASH_POINT'] = crash_point
            if failure_point and helper is None: env['PI_CUTIN_FAILURE'] = failure_point
            peer = HostPeer(helper or binary,root,capture=capture,env=env); peers.append(peer); hello = peer.hello(10); peer.epoch = hello['hostEpoch']
            assert 'subagents-mailbox-cutin-v1' in hello['capabilities']
            command(peer,'workspace.open',dict(cwd=str(root),directory=str(sessions),captureProtocol=1,resources=dict(codexHome=str(root/'codex'),skills=False)),None)
            params = dict(profile=profile,apiKey='synthetic-loopback-key',toolMode='editing')
            if path: params['path'] = str(path)
            command(peer,'session.open',params)
            command(peer,'session.configure',dict(costLimit=dict(usd=10)))
            return peer
        def shutdown(peer):
            peer.send(dict(v=1,kind='shutdown',hostEpoch=peer.epoch)); peer.process.wait(timeout=15); assert peer.process.returncode == 0
            peer.close(); peers.remove(peer)
        try:
            peer = opened(); command(peer,'turn.submit',dict(clientTurnId='user',text='Run the generated family'))
            wait(ready.is_set)
            if crash_point or failure_point:
                wait(lambda:(root/'crash-point').exists())
                if failure_point:
                    release.set(); shutdown(peer)
                else:
                    peer.process.kill(); peer.process.wait(timeout=10); peer.close(); peers.remove(peer)
                release.set()
                commits = [r for r in records(parent_path) if r.get('customType') == 'agent_cut_committed']
                before = len(requests)
                peer = opened(parent_path,helper=recovery)
                command(peer,'session.snapshot')
                assert len(requests) == before, 'Crash recovery dispatched work'
                child_path = sessions/(children[0]+'.jsonl')
                projected = [r['message'] for r in records(child_path) if r.get('type') == 'message' and 'nativeMailboxCut' in r.get('message',{})]
                assert len(projected) == len(commits), (crash_point,len(projected),len(commits))
                if commits:
                    for prefix in projected:
                        cut_id = prefix['nativeMailboxCut']['cutId']
                        results = [r['message'] for r in records(child_path) if r.get('message',{}).get('nativeAgentCallCancellation',{}).get('cutId') == cut_id]
                        assert len(results) == 1 and results[0]['content'][0]['text'] == 'Not executed: agent message arrived before dispatch.'
                assert 'DISCARDED' not in json.dumps([r.get('message') for r in records(child_path)])
                assert not (root/'forbidden').exists() and not (root/'suffix-forbidden').exists()
                deliveries = [r['data'] for r in records(parent_path) if r.get('customType') == 'pi-app.agent-delivery.v1' and r['data'].get('committed') and 'MAIL-1' in str(r['data'].get('payload'))]
                for delivery in deliveries:
                    saved = [r for r in records(child_path) if r.get('type') == 'message' and r.get('id') == delivery['rowID']]
                    assert len(saved) == 1, 'Delivery acknowledged without exactly one durable row'
                for row in records(child_path):
                    if any(event.get('text') == 'MAIL-1' for event in row.get('message',{}).get('nativeAgentDelivery',{}).get('events',[])):
                        assert any(delivery['rowID'] == row['id'] for delivery in deliveries), 'Durable mailbox row lost its reserved delivery identity'
                shutdown(peer)
                peer = opened(parent_path,helper=recovery); command(peer,'session.snapshot')
                assert len(requests) == before, 'Second reopen dispatched work'
                assert len([r for r in records(child_path) if 'nativeMailboxCut' in r.get('message',{})]) == len(commits)
                print(f'PASS {"failure" if failure_point else "crash"} {failure_point or crash_point}: {len(commits)} durable cuts, no replayed request/tool, idempotent reopen',flush=True)
                return
            if negative:
                wait(lambda:pending(children[0],'MAIL-1'))
                assert not any(r.get('customType') == 'agent_cut_committed' for r in records(parent_path))
                release.set()
            wait(continuation.is_set)
            cut_rows = [r for r in records(parent_path) if r.get('customType') == 'agent_cut_committed']
            assert len(cut_rows) == (0 if negative else 2 if mode == 'overlap' else 1), cut_rows
            if not negative and mode != 'terminal_race':
                assert not release.is_set(), 'continuation waited for drain'
                attempts = {r['data']['attemptId']:r['data'] for r in records(parent_path) if r.get('customType') == 'pi-app.cost.v1' and 'attemptId' in r.get('data',{})}
                assert all(r['data']['attemptId'] not in attempts for r in cut_rows), 'drain settled before terminal'
            if mode == 'followup':
                wait(lambda:any(r.get('customType') == 'pi-app.subagent-turn-terminal.v1' and r.get('data',{}).get('turn') == 2 for r in records(parent_path)))
                terminal = [r['data'] for r in records(parent_path) if r.get('customType') == 'pi-app.subagent-turn-terminal.v1' and r.get('data',{}).get('turn') == 2]
                assert terminal[-1]['status'] == 'completed', terminal[-1]
                assert not release.is_set(), 'follow-up completion waited for drain'
                assert counts[children[0]] == 3, counts
                wait(lambda:command(peer,'session.snapshot')['state'] != 'running')
                assert command(peer,'session.snapshot')['state'] == 'idle', 'family completion waited for drain or failed'
            if mode == 'stop': command(peer,'turn.stop')
            if mode == 'quit': shutdown(peer)
            if mode == 'crash':
                peer.process.kill(); peer.process.wait(timeout=10); peer.close(); peers.remove(peer)
            if mode == 'interrupt':
                wait(lambda:any(r.get('customType') == 'pi-app.cost.v1' and r.get('data',{}).get('attemptId') == cut_rows[0]['data']['attemptId'] for r in records(parent_path)))
            release.set()
            if mode in ('quit','crash'):
                before = len(requests); peer = opened(parent_path)
                command(peer,'session.snapshot'); assert len(requests) == before, 'reopen dispatched a request'
            def costs(): return [r for r in records(parent_path) if r.get('customType') == 'pi-app.cost.v1' and 'attemptId' in r.get('data',{})]
            if mode != 'crash': wait(lambda:all(any(c['data']['attemptId'] == r['data']['attemptId'] for c in costs()) for r in cut_rows))
            for cut in cut_rows:
                settled = [c['data'] for c in costs() if c['data']['attemptId'] == cut['data']['attemptId']]
                assert len(settled) == (0 if mode == 'crash' else 1), settled
                if mode in ('stop','quit','error','interrupt','no_usage','no_dollars'):
                    assert settled[0]['unreported'] == 1, settled
                    if mode == 'no_dollars': assert settled[0].get('usage',{}).get('output') == 2000, settled
                elif mode == 'dollars_only': assert settled[0]['usd'] == .02 and settled[0]['reported'] == 1, settled
                elif mode != 'crash': assert settled[0]['usd'] == .02 and settled[0].get('usage',{}).get('output') == 2000, settled
            for path in sessions.glob('*.jsonl'):
                rows = records(path)
                if not negative:
                    visible = [r['message'] for r in rows if r.get('type') == 'message']
                    assert 'DISCARDED' not in json.dumps(visible), ('suffix journal leak',path)
                    markers = [m for m in visible if 'nativeMailboxCut' in m]
                    if markers:
                        assert rows[1]['customType'] == 'pi-app.native.v5'
                        assert len({m['nativeMailboxCut']['cutId'] for m in markers}) == len(markers)
            assert not (root/'forbidden').exists() and not (root/'suffix-forbidden').exists()
            assert 'session_locked' not in json.dumps(packets), packets
            if mode == 'followup':
                shutdown(peer)
                before = len(requests)
                for path in sessions.glob('*.jsonl'):
                    previous = None; seen = set()
                    for row in records(path)[1:]:
                        assert row['id'] not in seen and row.get('parentId') == previous, row
                        seen.add(row['id']); previous = row['id']
                peer = opened(parent_path); command(peer,'session.snapshot')
                assert len(requests) == before, 'reopen replayed a request'
                assert not (root/'forbidden').exists() and not (root/'suffix-forbidden').exists()
            assert not errors, errors
            if os.environ.get('PI_CUTIN_KEEP'):
                for item in list(peers): shutdown(item)
                evidence = Path(os.environ['PI_CUTIN_KEEP'])/mode
                shutil.copytree(root,evidence,dirs_exist_ok=True)
                (evidence/'profile.json').write_text(json.dumps(profile))
            print(f'PASS {mode}: {len(cut_rows)} cuts, {len(requests)} physical requests, original attempts settled once',flush=True)
        finally:
            if sys.exc_info()[0] is not None:
                evidence = BUILD/('failed-cutin-'+mode)
                shutil.copytree(root,evidence,dirs_exist_ok=True)
                (evidence/'requests.json').write_text(json.dumps(requests,indent=2,ensure_ascii=False))
                (evidence/'packets.json').write_text(json.dumps(packets,indent=2,ensure_ascii=False))
            release.set(); ready.set(); second.set()
            for peer in list(peers):
                try: shutdown(peer)
                except Exception: peer.process.kill(); peer.close()
            server.shutdown(); server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('binary'); parser.add_argument('--mode',choices=MODES,action='append')
    args = parser.parse_args()
    for mode in args.mode or MODES: run(args.binary,mode)
