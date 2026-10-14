#!/usr/bin/env python3
"""Whole-family v3 acceptance, generated helpers and loopback only.

The speakers fixture advances only the generated helper's acceptance clock to
exercise pending caps without a minute of waiting. The separate rate case uses
real time. No production switch, installed app or user directory is touched.
"""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import traceback
import uuid
from native_host_client import HostPeer

BUILD = Path(os.environ['PI_BUILD_ROOT'])
MODES = ['flow','speakers','rate','loop','stop','shutdown','update','budget']


def load_crashes():
    spec = importlib.util.spec_from_file_location('steering_crashes',Path(__file__).with_name('test-subagent-steering-crashes.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def records(path):
    if not path.exists(): return []
    data = path.read_bytes()
    # A concurrent writer may be between the JSON write and its newline.
    return [json.loads(line) for line in data[:data.rfind(b'\n')+1].splitlines()]


def agent_events(body):
    events = []
    for item in body['input']:
        for block in item.get('content',[]) if isinstance(item.get('content'),list) else []:
            try:
                value = json.loads(block.get('text',''))
                if isinstance(value,dict) and value.get('kind') == 'agent_events': events.extend(value['events'])
            except (ValueError,TypeError): pass
    return events


def call(name,identity,arguments):
    return dict(type='function_call',id='item-'+identity,call_id=identity,name=name,arguments=json.dumps(arguments))


def answer(text):
    return dict(type='message',id='message-'+uuid.uuid4().hex,role='assistant',content=[dict(type='output_text',text=text)])


def run(binary,recovery,mode):
    with tempfile.TemporaryDirectory(prefix='steering-acceptance-',dir=BUILD) as folder:
        root = Path(folder); sessions = root/'sessions'; sessions.mkdir()
        lock = threading.Lock(); requests = []; packets = []; errors = []; counts = {}; roles = {}; active = peak = 0
        all_started = threading.Event(); transport_ready = threading.Event(); answered = threading.Event(); release_children = threading.Event(); early_done = threading.Event()
        resumed = threading.Event(); peers = []; response_times = {}; first_group = set()
        count = 16 if mode in ('speakers','rate') else 2 if mode == 'flow' else 1 if mode == 'loop' else 4
        parent_path = sessions/'parent.jsonl'
        hold = 'while [ ! -f release-parent ]; do sleep 0.02; done'

        def wait(predicate,timeout=25):
            deadline = time.monotonic()+timeout
            while not predicate():
                assert not errors, errors
                assert time.monotonic() < deadline, ('Fixture deadline',mode,len(requests),counts)
                time.sleep(.005)

        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                nonlocal active,peak
                child = False; session = None
                try:
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    session = self.headers['x-session-id']; child = session != 'parent'
                    with lock:
                        number = counts.get(session,0)+1; counts[session] = number
                        requests.append(dict(session=session,body=body,at=time.time()))
                        if child:
                            active += 1; peak = max(peak,active)
                            raw = json.dumps(body['input'])
                            speaker = re.search(r'SPEAKER-(\d+)',raw)
                            roles[session] = int(speaker[1]) if speaker else 'ask' if 'ASK-QUESTION' in raw else 'worker'
                            if len(roles) >= count: all_started.set()
                            # URLSession's existing per-host pool has six HTTP
                            # connections. Sixteen executable child turns still
                            # run concurrently; tool holds leave HTTP slots free.
                            if len(roles) >= min(count,6): transport_ready.set()
                            if mode == 'speakers' and roles[session] < 8 and number >= 6:
                                first_group.add(session)
                                if len(first_group) == 8: early_done.set(); (root/'early-done').touch()
                    output = []
                    outputs = {item.get('call_id') for item in body['input'] if item.get('type') == 'function_call_output'}
                    events = agent_events(body)
                    if not child:
                        if resumed.is_set(): output = [answer('Resumed parent collected retained events')]
                        elif number == 1:
                            tasks = ['ASK-QUESTION REMEMBER-CONTEXT-29','WORK-IN-PARALLEL'] if mode == 'flow' else [f'SPEAKER-{i:02d}' for i in range(count)]
                            output = [call('subagent_start',f'start-{i}',dict(task=task,mode='background')) for i,task in enumerate(tasks)]
                            if mode in ('speakers','rate','stop','shutdown','update','budget'):
                                output.append(call('bash','hold',dict(command='touch parent-tool-running; '+hold)))
                            elif mode == 'flow': output.append(call('bash','independent',dict(command='printf independent > independent')))
                        elif mode == 'loop':
                            # No reports/follow-ups: every renewal replaces the child.
                            latest = [e for e in events if e['kind'] == 'result']
                            prior = len([v for v in outputs if v and v.startswith('replacement-')])
                            if len(latest) > prior: output = [call('subagent_start',f'replacement-{number}',dict(task='Replacement child',mode='background'))]
                            else: output = [answer('Wait for the child')]
                        elif mode == 'flow':
                            question = next((e for e in events if e['kind'] == 'question'),None)
                            final = next((e for e in events if e['kind'] == 'result' and roles.get(e['child_id']) == 'ask' and e['turn'] == 1),None)
                            if question and 'answer' not in outputs:
                                output = [call('subagent_send','answer',dict(child_id=question['child_id'],message='Answer is ORCHID-73',reply_to=question['event_id']))]
                                answered.set()
                            elif final and 'follow' not in outputs:
                                output = [call('subagent_send','follow',dict(child_id=final['child_id'],message='Follow up using the original sentinel and answer',expected_turn=1))]
                            else: output = [answer('Parent synthesis')]
                        else: output = [answer('Parent collected the next bounded batch')]
                    else:
                        assert not any(t.get('name') in ('subagent','subagent_start','subagent_send') for t in body['tools']), 'Depth-one contract widened'
                        if number == 1 and mode != 'loop': assert transport_ready.wait(20), 'Children did not overlap'
                        if mode == 'flow':
                            if roles[session] == 'ask':
                                if number == 1: output = [call('subagent_report','question',dict(kind='question',message='Which answer should I use?'))]
                                elif number == 2:
                                    assert answered.wait(20)
                                    output = [call('bash','boundary',dict(command='sleep 0.05'))]
                                elif number == 3:
                                    assert 'ORCHID-73' in json.dumps(body['input']), 'Steer missing from next safe boundary'
                                    output = [call('bash','use-answer',dict(command='printf ORCHID-73 > used-answer'))]
                                elif number == 4: output = [answer('Child remembers ORCHID-73 and REMEMBER-CONTEXT-29')]
                                else:
                                    raw = json.dumps(body['input'])
                                    assert 'Child remembers ORCHID-73' in raw and 'REMEMBER-CONTEXT-29' in raw and 'Follow up using' in raw, 'Follow-up lost context'
                                    output = [answer('Follow-up retained the entire prior conversation')]
                            else: output = [answer('Parallel worker finished')]
                        elif mode in ('speakers','rate'):
                            maximum = 5 if mode == 'speakers' else 3
                            late = mode == 'speakers' and roles[session] >= 8
                            report_number = number-1 if late else number
                            if late and number == 1: output = [call('bash','early-hold',dict(command='while [ ! -f early-done ]; do sleep 0.02; done'))]
                            elif report_number <= maximum: output = [call('subagent_report',f'report-{report_number}',dict(kind='note',message=f"Speaker {roles[session]} note {report_number}: "+'x'*180))]
                            elif mode == 'speakers' and report_number == maximum+1:
                                output = [call('bash','speaker-hold',dict(command='while [ ! -f release-child ]; do sleep 0.02; done'))]
                            else:
                                output = [answer(f"Speaker {roles[session]} final, retaining important findings even if rate-limited")]
                        elif mode in ('stop','shutdown','update'):
                            if number == 1: output = [call('subagent_report','question',dict(kind='question',message='Retain this pending discovery'))]
                            else:
                                assert release_children.wait(20)
                                output = [answer('Child done')]
                        else:
                            if mode == 'budget': wait(lambda:(root/'parent-tool-running').exists())
                            output = [answer('Child final')]
                    self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
                    if mode == 'flow' and child and roles[session] == 'worker':
                        for _ in range(20):
                            self.wfile.write(b'data: {"type":"response.output_text.delta","delta":"parallel "}\n\n'); self.wfile.flush(); time.sleep(.01)
                    response = dict(id='response-'+uuid.uuid4().hex,model=body['model'],status='completed',output=output,usage=dict(input_tokens=200,output_tokens=20,total_tokens=220,cost=.01))
                    data = ('data: '+json.dumps(dict(type='response.completed',response=response))+'\n\n').encode()
                    self.wfile.write(data); self.wfile.flush()
                    with lock: response_times[(session,number)] = time.time()
                except (BrokenPipeError,ConnectionResetError): pass
                except BaseException:
                    errors.append(traceback.format_exc()); release_children.set(); answered.set(); all_started.set(); transport_ready.set(); early_done.set()
                finally:
                    if child:
                        with lock: active -= 1

        gateway = http.server.ThreadingHTTPServer(('127.0.0.1',0),Gateway)
        gateway.request_queue_size = 64
        thread = threading.Thread(target=gateway.serve_forever,daemon=True); thread.start()
        profile = dict(id='fixture',providerId='litellm',modelId='fixture-model',api='openai-responses',baseUrl=f'http://127.0.0.1:{gateway.server_port}/v1',contextWindow=100000,maxOutputTokens=4096)
        def capture(frame): packets.append(frame['packet']); return True
        def command(peer,method,params=None,session='parent'):
            identity = peer.post(method,params,session)
            while True:
                frame = peer.next_frame(25)
                if frame.get('commandId') == identity:
                    assert frame['ok'],frame
                    return frame['result']
        def opened(path=None,helper=binary):
            env = dict(os.environ)
            if mode == 'speakers': env['PI_STEERING_FIXTURE_CLOCK'] = 'fast'
            peer = HostPeer(helper,root,env=env,capture=capture); peers.append(peer)
            peer.epoch = peer.hello(10)['hostEpoch']
            command(peer,'workspace.open',dict(cwd=str(root),directory=str(sessions),captureProtocol=1,resources=dict(codexHome=str(root/'codex'),skills=False)),None)
            params = dict(profile=profile,apiKey='synthetic-loopback-key',toolMode='editing')
            if path: params['path'] = str(path)
            command(peer,'session.open',params)
            command(peer,'debug.mode',dict(mode='persist'))
            return peer
        def shutdown(peer):
            peer.send(dict(v=1,kind='shutdown',hostEpoch=peer.epoch)); peer.process.wait(timeout=10)
            assert peer.process.returncode == 0, peer.process.returncode
            peer.close(); peers.remove(peer)
        def family_rows(): return records(parent_path)
        def accepted_reports(): return [r['data'] for r in family_rows() if r.get('customType') == 'pi-app.agent-operation.v1' and r['data'].get('message',{}).get('author') == 'subagent']
        def deliveries(): return [r for r in family_rows() if r.get('message',{}).get('nativeAgentDelivery',{}).get('author') == 'subagent']
        def decoded(row): return json.loads(row['message']['content'][0]['text'])
        began = time.monotonic(); admission_ms = rss_mib = 0; settlement_ms = None
        try:
            peer = opened()
            if mode == 'budget': command(peer,'session.configure',dict(costLimit=dict(usd=.015)))
            command(peer,'turn.submit',dict(clientTurnId='user',text='Perform the generated whole-family task'))
            if mode != 'loop':
                wait(all_started.is_set)
                admission_ms = (time.monotonic()-began)*1000
                rss = subprocess.check_output(['ps','-o','rss=','-p',str(peer.process.pid)],text=True).strip()
                rss_mib = int(rss)/1024
            if mode in ('stop','shutdown','update'):
                wait(lambda:len(accepted_reports()) == 4)
                assert not deliveries(), 'Parent hold did not retain the inbox'
                pending = command(peer,'session.snapshot')['agentInboxPending']; assert pending >= 4
                stopping = time.monotonic()
                if mode != 'shutdown':
                    command(peer,'turn.stop')
                    wait(lambda:command(peer,'session.status')['state'] in ('paused','error'))
                    if mode == 'update': command(peer,'workspace.quiesce',session=None)
                shutdown(peer); settlement_ms = (time.monotonic()-stopping)*1000
                assert len([r for r in family_rows() if r.get('customType') == 'pi-app.subagent-turn-terminal.v1']) == 4
                for path in sessions.glob('*.jsonl'):
                    if path == parent_path: continue
                    receipts = [r for r in records(path) if r.get('message',{}).get('toolName') == 'subagent_report']
                    assert len(receipts) == 1 and decoded(receipts[0])['accepted'], 'Stop contradicted accepted report'
                before = len(requests); cold = opened(parent_path,recovery)
                assert len(requests) == before, 'Cold open launched work'
                shutdown(cold); resumed.set(); peer = opened(parent_path)
                child_count = sum(r['session'] != 'parent' for r in requests)
                command(peer,'run.continue')
                wait(lambda:command(peer,'session.status')['state'] == 'idle')
                assert sum(r['session'] != 'parent' for r in requests) == child_count
                ids = [e['event_id'] for r in deliveries() for e in decoded(r)['events']]
                assert all(op['message']['id'] in ids for op in accepted_reports())
            elif mode == 'speakers':
                wait(lambda:sum(n >= (7 if roles[s] >= 8 else 6) for s,n in counts.items() if s != 'parent') == 16)
                assert command(peer,'subagent.list')['active'] == 16
                assert len(accepted_reports()) == 64
                rejected = [decoded(r) for path in sessions.glob('*.jsonl') if path != parent_path for r in records(path) if r.get('message',{}).get('toolName') == 'subagent_report' and not decoded(r).get('accepted')]
                assert len(rejected) == 16 and all(r['error']['code'] == 'subagent_mailbox_full' for r in rejected)
                assert not deliveries()
                (root/'release-parent').touch()
                wait(lambda:sum(len(decoded(r)['events']) for r in deliveries()) >= 64)
                batches = [decoded(r)['events'] for r in deliveries()]
                assert all(len(batch) <= 8 and sum(len(e['text'].encode()) for e in batch) <= 16384 for batch in batches)
                assert len({e['child_id'] for batch in batches[:2] for e in batch}) == 16, 'Rotation starved later speakers across boundaries'
                release_children.set(); (root/'release-child').touch()
                wait(lambda:command(peer,'session.status')['state'] == 'idle')
            elif mode == 'rate':
                wait(lambda:len([r for r in family_rows() if r.get('customType') == 'pi-app.subagent-turn-terminal.v1']) == 16)
                accepted = accepted_reports(); times = [op['acceptedAt'] for op in accepted]
                assert len(accepted) <= 16+(max(times)-min(times)), 'Family real-time rate cap was bypassed'
                errors_seen = [decoded(r).get('error',{}).get('code') for p in sessions.glob('*.jsonl') if p != parent_path for r in records(p) if r.get('message',{}).get('toolName') == 'subagent_report']
                assert 'subagent_rate_limited' in errors_seen
                (root/'release-parent').touch(); wait(lambda:command(peer,'session.status')['state'] == 'idle')
            elif mode == 'budget':
                wait(lambda:command(peer,'session.status')['state'] in ('paused','error'))
                snapshot = command(peer,'session.snapshot'); assert snapshot['errorCode'] == 'cost_limit',snapshot
                assert .015 <= snapshot['cost']['spentUSD'] <= .05+1e-9
                assert len(requests) == 5, 'A request escaped the dispatch-time family budget fence'
                before = len(requests); command(peer,'run.continue')
                wait(lambda:command(peer,'session.status')['state'] in ('paused','error'))
                assert len(requests) == before
            elif mode == 'loop':
                wait(lambda:command(peer,'session.status')['state'] in ('paused','error'))
                snapshot = command(peer,'session.snapshot'); assert snapshot['errorCode'] == 'coordination_limit',snapshot
                operations = [r['data'] for r in family_rows() if r.get('customType') == 'pi-app.agent-operation.v1']
                turns = [op['turn'] for op in operations if op.get('turn')]
                assert len(turns) == 32 and all(t['turn'] == 1 for t in turns),len(turns)
            else:
                wait(lambda:command(peer,'session.status')['state'] == 'idle')
                assert (root/'independent').read_text() == 'independent'
                assert (root/'used-answer').read_text() == 'ORCHID-73'
                family = command(peer,'subagent.list'); assert family['total'] == 2
                asker = next(c for c in family['children'] if roles[c['link']['childSessionID']] == 'ask')
                assert asker['turn'] == 2 and asker['status'] == 'completed',asker
                sends = [r['data']['receipt']['route'] for r in family_rows() if r.get('customType') == 'pi-app.agent-operation.v1' and r['data']['key']['toolCallID'] in ('answer','follow')]
                assert sends == ['steer','follow_up'],sends
                parents = [r for r in requests if r['session'] == 'parent']
                for earlier,later in zip(parents,parents[1:]):
                    assert later['body']['input'][:len(earlier['body']['input'])] == earlier['body']['input'], 'Boundary delivery rewrote the cached prefix'
            family = command(peer,'subagent.list'); assert family['active'] == 0
            state = command(peer,'session.snapshot')
            began_close = time.monotonic(); shutdown(peer)
            if settlement_ms is None: settlement_ms = (time.monotonic()-began_close)*1000
            assert not errors, errors
            ids = [e['event_id'] for row in deliveries() for e in decoded(row)['events']]
            assert len(ids) == len(set(ids)), 'A parent event was inserted twice'
            if mode not in ('loop','budget'):
                assert peak == min(count,6),(peak,count)
                assert all(op['message']['id'] in ids for op in accepted_reports()), 'An accepted report disappeared'
            begins = [p['metadata'] for p in packets if p['type'] == 'begin']
            for metadata in begins:
                scope = metadata.get('requestScope')
                if scope and scope.get('sourceSessionID') != 'parent':
                    assert scope['budgetOwnerSessionID'] == 'parent' and scope['childTurn'] >= 1
                    assert scope['delegation']['depth'] == 1
            delivery_times = []
            if mode == 'flow':
                for op in accepted_reports():
                    first = next(r['at'] for r in requests if r['session'] == 'parent' and any(e['event_id'] == op['message']['id'] for e in agent_events(r['body'])))
                    delivery_times.append(round((first-op['acceptedAt'])*1000,2))
            report = dict(mode=mode,child_conversations=len(roles),simultaneous_child_turns=16 if mode == 'speakers' else peak,peak_child_http=peak,requests=len(requests),accepted_reports=len(accepted_reports()),parent_delivery_batches=len(deliveries()),parent_events=len(ids),elapsed_ms=round((time.monotonic()-began)*1000,2),admission_ms=round(admission_ms,2),shutdown_ms=round(settlement_ms,2),sampled_rss_mib=round(rss_mib,2),reported_cost=state['cost']['spentUSD'],report_to_parent_request_ms=delivery_times,captured_attempts=len(begins))
            print(json.dumps(report),flush=True)
            return report
        finally:
            release_children.set(); answered.set(); all_started.set(); transport_ready.set(); early_done.set(); (root/'release-parent').touch(); (root/'release-child').touch(); (root/'early-done').touch()
            for peer in peers: peer.close()
            gateway.shutdown(); gateway.server_close(); thread.join()


def main(recovery,fixture=False,modes=None):
    modes = modes or MODES
    assert set(modes).issubset(MODES),modes
    binary = load_crashes().fixture_binary() if fixture else BUILD/'steering-crash-build/debug/pi-native-host'
    reports = [run(binary,recovery,mode) for mode in modes]
    (BUILD/'logs/subagent-steering-streaming.json').write_text(json.dumps(reports,indent=2)+'\n')
