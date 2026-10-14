#!/usr/bin/env python3
"""V3 extension of test-subagent-crashes.py: generated helpers and loopback only.

The production helper (switch off) does cold recovery; an enabled source copy
without fault environment performs explicit Resume. No installed app/data.
"""
import argparse
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import uuid
from native_host_client import HostPeer

spec = importlib.util.spec_from_file_location('v2_crashes', Path(__file__).with_name('test-subagent-crashes.py'))
v2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(v2)
ROOT, BUILD = v2.ROOT, v2.BUILD
POINTS = ['promotion-copy-synced', 'promotion-replaced'] + [kind+'-'+edge for kind in
    ['start', 'follow-up', 'steer', 'report', 'report-mirror', 'parent-row', 'child-row',
     'delivery-prepared', 'report-receipt', 'delivery-commit', 'child-terminal', 'owner-terminal', 'family-fence',
     'legacy-snapshot'] for edge in ['before', 'synced']] + ['stop', 'shutdown', 'update']
BARRIER = r'''
import Foundation
import Darwin
enum FixtureSteeringBarrier {
    static let clockLock = NSLock()
    static var clockStep = 0.0
    static func acceptedTime() -> Double {
        guard ProcessInfo.processInfo.environment["PI_STEERING_FIXTURE_CLOCK"] == "fast" else { return Date().timeIntervalSince1970 }
        clockLock.lock(); defer { clockLock.unlock() }; clockStep += 10
        return Date().timeIntervalSince1970 + clockStep
    }
    static func hit(_ point: String) {
        guard ProcessInfo.processInfo.environment["PI_STEERING_CRASH_POINT"] == point,
              let path = ProcessInfo.processInfo.environment["PI_STEERING_BARRIER_FILE"] else { return }
        try! Data(point.utf8).write(to: URL(fileURLWithPath:path),options:.atomic)
        raise(SIGSTOP)
    }
    static func record(_ value: JSON, url: URL, edge: String) {
        let parent = url.lastPathComponent == "parent.jsonl", kind = value["customType"].text, data = value["data"]
        if kind == JournalRecordKind.agentOperation {
            if parent && data["turn"]["turn"].int == 1 { hit("start-" + edge) }
            if parent && data["turn"]["turn"].int == 2 { hit("follow-up-" + edge) }
            if parent && data["message"]["author"].text == "parent" { hit("steer-" + edge) }
            if data["message"]["author"].text == "subagent" { hit((parent ? "report-" : "report-mirror-") + edge) }
        }
        if value["message"]["nativeAgentDelivery"]["eventIds"].list.count > 0 && value["message"]["nativeInputLane"].text == "agent" {
            hit((parent ? "parent-row-" : "child-row-") + edge)
        }
        if parent && kind == JournalRecordKind.agentDelivery && data["committed"].flag == true { hit("delivery-commit-" + edge) }
        if parent && kind == JournalRecordKind.agentDelivery && data["committed"].flag != true { hit("delivery-prepared-" + edge) }
        if value["message"]["toolName"].text == "subagent_report" { hit("report-receipt-" + edge) }
        if parent && kind == JournalRecordKind.agentTurn && data["epoch"].text == "legacy" { hit("legacy-snapshot-" + edge) }
        if kind == JournalRecordKind.agentTerminal { hit((parent ? "owner-terminal-" : "child-terminal-") + edge) }
        if parent && kind == JournalRecordKind.familyRun && data["closed"].flag == true { hit("family-fence-" + edge) }
    }
}
'''


def fixture_binary():
    source = BUILD/'steering-crash-source'; source.mkdir(exist_ok=True)
    shutil.copy2(ROOT/'packages/swift-host/Package.swift',source)
    shutil.copytree(ROOT/'packages/swift-host/Sources',source/'Sources',dirs_exist_ok=True)
    (source/'Tests/PiAgentCoreTests').mkdir(parents=True,exist_ok=True)
    (source/'Tests/PiAgentCoreTests/Placeholder.swift').write_text('import XCTest\n')
    core = source/'Sources/PiAgentCore'
    policy = core/'SubagentTypes.swift'; policy.write_text(policy.read_text().replace('public static let steeringEnabled = false','public static let steeringEnabled = true'))
    (core/'FixtureSteeringBarrier.swift').write_text(BARRIER)
    family = core/'AgentFamilyJournal.swift'
    family.write_text(family.read_text().replace('var acceptedAt: Double = Date().timeIntervalSince1970','var acceptedAt: Double = FixtureSteeringBarrier.acceptedTime()'))
    journal = core/'SessionJournal.swift'; text = journal.read_text()
    text = text.replace('        try beforeAppend(v)','        FixtureSteeringBarrier.record(v,url:url,edge:"before")\n        try beforeAppend(v)')
    text = text.replace('        unsynced=false; synchronizations += 1','        unsynced=false; synchronizations += 1\n        if let line = lastAppendLine { FixtureSteeringBarrier.record(try JSON.parse(line),url:url,edge:"synced") }')
    text = text.replace('        try copy.synchronize()','        try copy.synchronize()\n        if url.lastPathComponent == "parent.jsonl" { FixtureSteeringBarrier.hit("promotion-copy-synced") }')
    text = text.replace('            try handle.close(); handle = try FileHandle(forWritingTo:url); try handle.seekToEnd()','            if url.lastPathComponent == "parent.jsonl" { FixtureSteeringBarrier.hit("promotion-replaced") }\n            try handle.close(); handle = try FileHandle(forWritingTo:url); try handle.seekToEnd()')
    journal.write_text(text)
    with (BUILD/'logs/phase4-crash-build.log').open('w') as log:
        subprocess.run(['swift','build','--package-path',str(source),'--scratch-path',str(BUILD/'steering-crash-build'),'--product','pi-native-host'],stdout=log,stderr=subprocess.STDOUT,check=True)
    return BUILD/'steering-crash-build/debug/pi-native-host'


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def run(point, fixture, recovery, older=None):
    with tempfile.TemporaryDirectory(prefix='steering-crash-',dir=BUILD) as directory:
        root = Path(directory); sessions = root/'sessions'; sessions.mkdir()
        requests = []; resumed = threading.Event(); steer_seen = threading.Event(); release = threading.Event()
        controlled = point in ('stop','shutdown','update'); legacy = point.startswith('legacy-snapshot')
        legacy_ready = threading.Event()
        def call(name, identity, arguments):
            return dict(type='function_call',id='item-'+identity,call_id=identity,name=name,arguments=json.dumps(arguments))
        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                session = self.headers['x-session-id']; requests.append((session,body))
                outputs = {item.get('call_id') for item in body['input'] if item.get('type') == 'function_call_output'}
                events = []
                for item in body['input']:
                    for block in item.get('content',[]) if isinstance(item.get('content'),list) else []:
                        try:
                            value = json.loads(block.get('text',''))
                            if isinstance(value,dict) and value.get('kind') == 'agent_events': events += value['events']
                        except (ValueError,TypeError): pass
                if legacy and not legacy_ready.is_set():
                    output = [call('subagent','legacy-start',dict(task='Legacy conversation'))] if session == 'parent' and not outputs else []
                elif legacy and session == 'parent' and not resumed.is_set():
                    original_child = next(s for s,_ in requests if s != 'parent')
                    output = [call('subagent_send','legacy-follow',dict(child_id=original_child,message='Parent follow-up',expected_turn=1))] if 'legacy-follow' not in outputs else []
                elif session == 'parent':
                    if resumed.is_set(): output = []
                    elif not outputs: output = [call('subagent_start','start-'+str(i),dict(task='Child first task',mode='background')) for i in range(18 if controlled else 1)]
                    elif any(e['kind'] == 'question' for e in events) and 'steer' not in outputs:
                        question = next(e for e in events if e['kind'] == 'question')
                        output = [call('subagent_send','steer',dict(child_id=question['child_id'],message='Use the safe path',reply_to=question['event_id']))]
                    elif any(e['kind'] == 'result' and e['turn'] == 1 for e in events) and 'follow' not in outputs:
                        child = next(e['child_id'] for e in events if e['kind'] == 'result')
                        output = [call('subagent_send','follow',dict(child_id=child,message='Parent follow-up',expected_turn=1))]
                    else: output = []
                    if 'steer' in outputs: steer_seen.set()
                elif not outputs:
                    if controlled: release.wait(20)
                    output = [call('subagent_report','report',dict(kind='question',message='Which path is safe?'))]
                elif 'effect' not in outputs:
                    # Order the synthetic effect after report delivery. Killing
                    # the helper must not sample an already-forked shell mid-write.
                    steer_seen.wait(20)
                    output = [call('bash','effect',dict(command='printf x >> effects'))]
                elif 'Parent follow-up' in json.dumps(body) and 'effect-follow' not in outputs:
                    output = [call('bash','effect-follow',dict(command='printf y >> effects'))]
                else:
                    if 'effect-follow' not in outputs: steer_seen.wait(20)
                    output = []
                if not output: output = [dict(type='message',id='message-'+uuid.uuid4().hex,role='assistant',content=[dict(type='output_text',text='Parent complete' if session == 'parent' else 'Child complete')])]
                response = dict(id='response-'+uuid.uuid4().hex,model=body['model'],status='completed',output=output,usage=dict(input_tokens=20,output_tokens=5,total_tokens=25,cost=.01))
                payload = ('event: response.completed\ndata: '+json.dumps(dict(type='response.completed',response=response))+'\n\n').encode()
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(payload)))
                try: self.end_headers(); self.wfile.write(payload)
                except (BrokenPipeError,ConnectionResetError): pass
        gateway = http.server.ThreadingHTTPServer(('127.0.0.1',0),Gateway)
        thread = threading.Thread(target=gateway.serve_forever,daemon=True); thread.start()
        profile = dict(id='fixture',providerId='litellm',modelId='fixture-model',api='openai-responses',baseUrl=f'http://127.0.0.1:{gateway.server_port}/v1',contextWindow=100000,maxOutputTokens=4096)
        def opened(binary, env=None, resume=True, identity='parent'):
            peer = HostPeer(binary,root,env=env); peer.epoch = peer.hello(10)['hostEpoch']
            v2.command(peer,'workspace.open',dict(cwd=str(root),directory=str(sessions),resources=dict(codexHome=str(root/'codex'),skills=False)))
            params = dict(profile=profile,apiKey='synthetic-fixture-key',toolMode='editing')
            if resume: params['path'] = str(sessions/(identity+'.jsonl'))
            try: v2.command(peer,'session.open',params,identity)
            except BaseException: peer.close(); raise
            return peer
        peer = None
        try:
            if legacy:
                peer = opened(recovery,resume=False)
                v2.command(peer,'turn.submit',dict(clientTurnId='legacy-user',text='Complete the v2 task'),'parent')
                v2.wait_for(lambda:v2.command(peer,'session.status',{},'parent')['state'] == 'idle')
                peer.close(); peer = None; legacy_ready.set()
            peer = opened(fixture,dict(os.environ,PI_STEERING_CRASH_POINT=point,PI_STEERING_BARRIER_FILE=str(root/'barrier')),resume=legacy)
            v2.command(peer,'turn.submit',dict(clientTurnId='user',text='Do the synthetic parallel task'),'parent')
            if controlled:
                v2.wait_for(lambda:v2.command(peer,'subagent.list',{},'parent')['total'] == 18)
                v2.wait_for(lambda:v2.command(peer,'subagent.list',{},'parent')['active'] == 16)
                v2.wait_for(lambda:sum(s != 'parent' for s,_ in requests) >= 2)
                family = v2.command(peer,'subagent.list',{},'parent')
                queued = {c['link']['childSessionID'] for c in family['children'] if c['status'] == 'queued'}
                assert len(queued) == 2, family
                if point != 'shutdown':
                    v2.command(peer,'turn.stop',{},'parent')
                    v2.wait_for(lambda:v2.command(peer,'session.status',{},'parent')['state'] in ('paused','error'))
                    if point == 'update': v2.command(peer,'workspace.quiesce')
                peer.close(); peer = None
                ledger = rows(sessions/'parent.jsonl')
                terminals = [r['data'] for r in ledger if r.get('customType') == 'pi-app.subagent-turn-terminal.v1']
                assert len(terminals) == 18, (point,len(terminals))
                assert all(t['status'] in ('interrupted','not_executed') for t in terminals), terminals
                assert sum(t['status'] == 'not_executed' for t in terminals) >= 2
                for child in sessions.glob('*.jsonl'):
                    if child.name != 'parent.jsonl':
                        assert any(r.get('customType') == 'pi-app.subagent-turn-terminal.v1' for r in rows(child)), child
                assert not queued.intersection(s for s,_ in requests), 'Queued child dispatched during shutdown'
                assert not (root/'effects').exists()
                count = len(requests)
                peer = opened(recovery)
                assert len(requests) == count, 'Shutdown recovery resumed work'
                print(f'PASS {point}: 16 active + 2 queued; all 18 parent/child terminals settled before close; no queued dispatch',flush=True)
                return
            v2.wait_for(lambda:(root/'barrier').exists() or peer.process.poll() is not None)
            assert (root/'barrier').exists(), point
            peer.process.kill(); peer.process.wait(); peer.close(); peer = None
            steer_seen.set(); resumed.set()
            count = len(requests); child_count = sum(s != 'parent' for s,_ in requests)
            effect = (root/'effects').read_bytes() if (root/'effects').exists() else b''
            assert effect in (b'',b'x',b'xy'), effect
            peer = opened(recovery)
            assert len(requests) == count, 'Cold recovery dispatched a request'
            state = v2.command(peer,'session.snapshot',{},'parent')
            peer.close(); peer = None
            if older and any(r.get('customType') == 'pi-app.native.v3' for r in rows(sessions/'parent.jsonl')):
                for path in sessions.glob('*.jsonl'):
                    if not any(r.get('customType') == 'pi-app.native.v3' for r in rows(path)): continue
                    before = path.read_bytes()
                    try:
                        old = opened(older,identity=path.stem); old.close(); raise AssertionError('Older helper accepted v3')
                    except AssertionError as error:
                        assert 'legacy_session' in str(error), str(error)
                    assert path.read_bytes() == before
            peer = opened(fixture)
            ready = v2.command(peer,'session.snapshot',{},'parent')
            if ready.get('continuable'):
                v2.command(peer,'run.continue',{},'parent')
                v2.wait_for(lambda:v2.command(peer,'session.status',{},'parent')['state'] in ['idle','error'])
            assert sum(s != 'parent' for s,_ in requests) == child_count, 'Resume re-executed accepted child work'
            assert ((root/'effects').read_bytes() if (root/'effects').exists() else b'') == effect, 'Repeated tool effect'
            ledger = rows(sessions/'parent.jsonl')
            accepted = [r['data'] for r in ledger if r.get('customType') == 'pi-app.agent-operation.v1']
            assert len({json.dumps(op['key'],sort_keys=True) for op in accepted}) == len(accepted)
            delivered = [e for r in ledger for e in r.get('message',{}).get('nativeAgentDelivery',{}).get('eventIds',[])]
            assert len(delivered) == len(set(delivered)), 'Automatic event delivered twice'
            messages = {op['message']['id']:op['message'] for op in accepted if op.get('message')}
            for row in ledger:
                if row.get('customType') == 'pi-app.agent-message.v1': messages[row['data']['id']] = row['data']
                if row.get('customType') == 'pi-app.agent-delivery.v1' and row['data'].get('committed'):
                    for identity in row['data']['eventIDs']:
                        if identity in messages: messages[identity]['disposition'] = 'delivered'
            for op in accepted:
                if not op.get('message'): continue
                message = messages[op['message']['id']]
                assert message['disposition'] in ('delivered','not_delivered_interrupted'), ('Accepted message lost',message)
            for child in sessions.glob('*.jsonl'):
                if child.name == 'parent.jsonl': continue
                ids = [e for r in rows(child) for e in r.get('message',{}).get('nativeAgentDelivery',{}).get('eventIds',[])]
                assert len(ids) == len(set(ids)), 'Child steering delivered twice'
            receipts = [r for r in ledger if r.get('message',{}).get('toolName') in ('subagent_start','subagent_send','subagent_report')]
            ids = [r['id'] for r in receipts]; assert len(ids) == len(set(ids))
            cost = v2.command(peer,'session.snapshot',{},'parent')['cost']['spentUSD']
            peer.close(); peer = opened(recovery)
            assert v2.command(peer,'session.snapshot',{},'parent')['cost']['spentUSD'] == cost, 'Reopen double-charged'
            print(f'PASS {point}: {child_count} child requests, {len(effect)} effects, {len(accepted)} accepted operations; no replay/double delivery',flush=True)
        finally:
            if peer:
                if peer.process.poll() is None: peer.process.send_signal(signal.SIGCONT)
                peer.close()
            steer_seen.set(); release.set(); gateway.shutdown(); gateway.server_close(); thread.join()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recovery_helper',type=Path)
    parser.add_argument('--older-helper',type=Path)
    parser.add_argument('--points',nargs='+',choices=POINTS,default=POINTS)
    parser.add_argument('--skip-build',action='store_true')
    args = parser.parse_args()
    binary = BUILD/'steering-crash-build/debug/pi-native-host' if args.skip_build else fixture_binary()
    for point in args.points: run(point,binary,args.recovery_helper.resolve(),args.older_helper.resolve() if args.older_helper else None)
