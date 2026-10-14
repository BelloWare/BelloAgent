#!/usr/bin/env python3
"""Crash the actual helper at delegation durability barriers using loopback only.

A generated source copy under PI_BUILD_ROOT selects the historical v2 contract and
injects SIGSTOP barriers. Production sources/bundles have no environment override
or test barrier. Recovery and Resume use the unmodified helper supplied on
the command line. Every project, effect, journal and credential is synthetic.
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
import time
import uuid
from native_host_client import HostPeer

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ['PI_BUILD_ROOT'])
POINTS = [kind + '-' + edge for kind in ['plan', 'child-origin', 'child-admission',
          'child-dispatch', 'owner-cost', 'child-cost', 'child-terminal', 'parent-result']
          for edge in ['before', 'synced']] + ['effect-before', 'effect-after', 'stop', 'shutdown', 'update']
BARRIER = r'''
import Foundation
import Darwin
enum FixtureCrashBarrier {
    static func hit(_ point: String) {
        guard ProcessInfo.processInfo.environment["PI_SUBAGENT_CRASH_POINT"] == point,
              let path = ProcessInfo.processInfo.environment["PI_SUBAGENT_BARRIER_FILE"] else { return }
        try! Data(point.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        raise(SIGSTOP)
    }
    static func record(_ value: JSON, url: URL, edge: String) {
        let parent = url.lastPathComponent == "parent.jsonl", kind = value["customType"].text
        if parent && kind == JournalRecordKind.subagentCall { hit("plan-" + edge) }
        if !parent && kind == JournalRecordKind.subagentOrigin { hit("child-origin-" + edge) }
        if parent && kind == JournalRecordKind.budgetAttempt && value["data"]["sourceSessionId"].text != "parent" {
            if value["data"]["state"].text == "admitted" { hit("child-admission-" + edge) }
            if value["data"]["state"].text == "dispatched" { hit("child-dispatch-" + edge) }
        }
        if kind == JournalRecordKind.cost && value["data"]["sourceSessionId"].text != nil && value["data"]["sourceSessionId"].text != "parent" {
            hit((parent ? "owner-cost-" : "child-cost-") + edge)
        }
        if !parent && kind == JournalRecordKind.subagentTerminal { hit("child-terminal-" + edge) }
        if parent && value["message"]["role"].text == "toolResult" && value["message"]["toolName"].text == "subagent" { hit("parent-result-" + edge) }
    }
}
'''


def fixture_binary(without_drain=False):
    source = BUILD / 'subagent-crash-source'
    source.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'packages/swift-host/Package.swift', source)
    shutil.copytree(ROOT / 'packages/swift-host/Sources', source / 'Sources', dirs_exist_ok=True)
    (source / 'Tests/PiAgentCoreTests').mkdir(parents=True, exist_ok=True)
    (source / 'Tests/PiAgentCoreTests/Placeholder.swift').write_text('import XCTest\n')
    core = source / 'Sources/PiAgentCore'
    policy = core / 'SubagentTypes.swift'
    policy.write_text(policy.read_text().replace('public static let enabled = false', 'public static let enabled = true')
                      .replace('public static let steeringEnabled = true', 'public static let steeringEnabled = false'))
    (core / 'FixtureCrashBarrier.swift').write_text(BARRIER)
    journal = core / 'SessionJournal.swift'
    text = journal.read_text().replace('        try beforeAppend(v)', '        FixtureCrashBarrier.record(v, url: url, edge: "before")\n        try beforeAppend(v)')
    text = text.replace('        unsynced=false; synchronizations += 1', '        unsynced=false; synchronizations += 1\n        if let line = lastAppendLine { FixtureCrashBarrier.record(try JSON.parse(line), url: url, edge: "synced") }')
    journal.write_text(text)
    tools = core / 'SessionTools.swift'
    tools.write_text(tools.read_text().replace('        return try await tools.invoke(prepared,readOnly:readOnly,onUpdate:update)', '''        if isSubagent { FixtureCrashBarrier.hit("effect-before") }
        let result = try await tools.invoke(prepared,readOnly:readOnly,onUpdate:update)
        if isSubagent { FixtureCrashBarrier.hit("effect-after") }
        return result'''))
    coordinator = core / 'SubagentCoordinator.swift'
    coordinator.write_text(coordinator.read_text().replace('        var result = result\n        do { try await runtime.child.saveSubagentTerminal(result) }', '        var result = result\n        if ProcessInfo.processInfo.environment["PI_SUBAGENT_SLOW_TERMINAL"] == "1" { try? await Task.sleep(for: .milliseconds(200)) }\n        do { try await runtime.child.saveSubagentTerminal(result) }'))
    host = core / 'HostService.swift'
    text = host.read_text()
    # Dictionary traversal may visit a child first. Pin that valid order in
    # this fixture so the missing-drain mutation is deterministic.
    text = text.replace('        for s in sessions.values { await s.close() }', '        for s in sessions.values.sorted(by: { $0.id != "parent" && $1.id == "parent" }) { await s.close() }')
    if without_drain:
        assert '        await subagentCoordinator?.drain()' in text
        text = text.replace('        await subagentCoordinator?.drain()', '        // fixture mutation: omit family settlement barrier')
    host.write_text(text)
    scratch = BUILD / 'subagent-crash-build'
    with (BUILD / 'logs/phase7-crash-build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--package-path', str(source), '--scratch-path', str(scratch), '--product', 'pi-native-host'], stdout=log, stderr=subprocess.STDOUT, check=True)
    return scratch / 'debug/pi-native-host'


def command(peer, method, params=None, session=None):
    identity = peer.post(method, params, session)
    while True:
        frame = peer.next_frame(20)
        if frame.get('commandId') == identity:
            assert frame['ok'], frame
            return frame['result']


def wait_for(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError('fixture deadline exceeded')


def run(point, fixture, recovery):
    with tempfile.TemporaryDirectory(prefix='subagent-crash-', dir=BUILD) as directory:
        root = Path(directory); sessions = root / 'sessions'; sessions.mkdir()
        requests = []; controlled = point in ["stop", "shutdown", "update"]; release = threading.Event()
        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                session = self.headers['x-session-id']; requests.append((session, body))
                assert body['metadata']['session_id'] == session
                outputs = [item for item in body['input'] if item.get('type') == 'function_call_output']
                if session == 'parent' and not outputs:
                    output = [dict(type='function_call', id='item-delegate-' + str(i), call_id='delegate-' + str(i), name='subagent', arguments=json.dumps(dict(task='Complete synthetic task ' + str(i)))) for i in range(18 if controlled else 1)]
                elif session != 'parent' and not outputs:
                    if controlled: release.wait(20)
                    output = [dict(type='function_call', id='item-effect', call_id='effect', name='bash', arguments=json.dumps(dict(command='printf x >> effects')))]
                else:
                    output = [dict(type='message', id='message-' + uuid.uuid4().hex, role='assistant', content=[dict(type='output_text', text='Child finished' if session != 'parent' else 'Parent resumed')])]
                response = dict(id='response-' + uuid.uuid4().hex, model=body['model'], status='completed', output=output,
                                usage=dict(input_tokens=20, output_tokens=5, total_tokens=25, cost=.01))
                payload = ('event: response.completed\ndata: ' + json.dumps(dict(type='response.completed', response=response)) + '\n\n').encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(payload)))
                try:
                    self.end_headers(); self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError): pass
        gateway = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
        thread = threading.Thread(target=gateway.serve_forever, daemon=True); thread.start()
        profile = dict(id='fixture', providerId='litellm', modelId='fixture-model', api='openai-responses',
                       baseUrl=f'http://127.0.0.1:{gateway.server_port}/v1', contextWindow=100000, maxOutputTokens=4096)
        def opened(binary, env=None, resume=False):
            peer = HostPeer(binary, root, env=env)
            peer.epoch = peer.hello(10)['hostEpoch']
            command(peer, 'workspace.open', dict(cwd=str(root), directory=str(sessions), resources=dict(codexHome=str(root/'codex'), skills=False)))
            params = dict(profile=profile, apiKey='synthetic-fixture-key', toolMode='editing')
            if resume: params['path'] = str(sessions / 'parent.jsonl')
            command(peer, 'session.open', params, 'parent')
            return peer
        peer = None
        try:
            env = dict(os.environ, PI_SUBAGENT_CRASH_POINT=point, PI_SUBAGENT_BARRIER_FILE=str(root/'barrier'), PI_SUBAGENT_SLOW_TERMINAL='1' if controlled else '0')
            peer = opened(fixture, env)
            command(peer, 'turn.submit', dict(clientTurnId='turn', text='Delegate the synthetic task'), 'parent')
            if controlled:
                wait_for(lambda: sum(session != 'parent' for session, _ in requests) >= 2)
                wait_for(lambda: command(peer, 'subagent.list', {}, 'parent')['active'] == 16)
                family = command(peer, 'subagent.list', {}, 'parent')
                assert family['active'] == 16 and family['total'] == 18, family
                if point != 'shutdown':
                    command(peer, 'turn.stop', {}, 'parent')
                    wait_for(lambda: command(peer, 'session.status', {}, 'parent')['state'] in ['paused', 'error'])
                    if point == 'update': command(peer, 'workspace.quiesce')
                peer.close(); peer = None
                rows = [json.loads(line) for line in (sessions/'parent.jsonl').read_text().splitlines()]
                results = [r['message'] for r in rows if r.get('message', {}).get('toolName') == 'subagent']
                assert len(results) == 18, len(results)
                statuses = [json.loads(r['content'][0]['text'])['status'] for r in results]
                assert set(statuses) <= {'interrupted', 'not_executed'} and statuses.count('not_executed') >= 2, statuses
                for child in sessions.glob('*.jsonl'):
                    if child.name == 'parent.jsonl': continue
                    records = [json.loads(line) for line in child.read_text().splitlines()]
                    assert any(r.get('customType') == 'pi-app.subagent-terminal.v1' for r in records), child
                assert not (root/'effects').exists()
                assert 3 <= len(requests) <= 17, len(requests)
                queued = {c['link']['childSessionID'] for c in family['children'][-2:]}
                assert not queued.intersection(s for s, _ in requests)
                print(f'PASS {point}: 16 active slots + 2 queued, {len(requests)-1} overlapping child HTTP requests; all settled before journals closed', flush=True)
                return
            wait_for(lambda: (root/'barrier').exists() or peer.process.poll() is not None)
            assert (root/'barrier').exists(), peer.process.stderr.read().decode()
            peer.process.kill(); peer.process.wait(); peer.close(); peer = None
            count = len(requests); child_requests = sum(session != 'parent' for session, _ in requests)
            effects = (root/'effects').read_bytes() if (root/'effects').exists() else b''
            assert effects in [b'', b'x'], effects
            peer = opened(recovery, resume=True)
            state = command(peer, 'session.snapshot', {}, 'parent')
            assert state['state'] in ['paused', 'error'], state
            assert len(requests) == count, 'Open must not issue requests'
            rows = [json.loads(line) for line in (sessions/'parent.jsonl').read_text().splitlines()]
            results = [r['message'] for r in rows if r.get('message', {}).get('toolName') == 'subagent']
            assert len(results) == 1, results
            envelope = json.loads(results[0]['content'][0]['text'])
            if point in ['child-terminal-synced', 'parent-result-before', 'parent-result-synced']:
                assert envelope['status'] == 'completed' and envelope['text'] == 'Child finished', envelope
            command(peer, 'run.continue', {}, 'parent')
            wait_for(lambda: command(peer, 'session.status', {}, 'parent')['state'] in ['idle', 'error'])
            assert len(requests) == count + 1, (point, requests)
            assert sum(session != 'parent' for session, _ in requests) == child_requests, 'Resume restarted a child'
            assert ((root/'effects').read_bytes() if (root/'effects').exists() else b'') == effects, 'Resume repeated an effect'
            peer.close(); peer = None
            # Repeated open cannot duplicate the parent result or charges.
            peer = opened(recovery, resume=True)
            again = [json.loads(line) for line in (sessions/'parent.jsonl').read_text().splitlines()]
            assert len([r for r in again if r.get('message', {}).get('toolName') == 'subagent']) == 1
            print(f'PASS {point}: {child_requests} child requests before kill, {len(effects)} effects, Resume sent only one parent request', flush=True)
        finally:
            if peer:
                if peer.process.poll() is None: peer.process.send_signal(signal.SIGCONT)
                peer.close()
            release.set(); gateway.shutdown(); gateway.server_close(); thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recovery_helper', type=Path)
    parser.add_argument('--points', nargs='+')
    parser.add_argument('--steering', action='store_true', help='Run the v3 extension, including promotion, delivery, adoption and coordination barriers')
    parser.add_argument('--older-helper', type=Path)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--without-drain', action='store_true', help='Mutation check: remove the family settlement barrier in the generated fixture only')
    args = parser.parse_args()
    if args.steering:
        spec = importlib.util.spec_from_file_location('steering_crashes', Path(__file__).with_name('test-subagent-steering-crashes.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        points = args.points or module.POINTS
        if not set(points).issubset(module.POINTS): parser.error('Unknown v3 crash point')
        binary = BUILD/'steering-crash-build/debug/pi-native-host' if args.skip_build else module.fixture_binary()
        for point in points: module.run(point,binary,args.recovery_helper.resolve(),args.older_helper.resolve() if args.older_helper else None)
    else:
        points = args.points or POINTS
        if not set(points).issubset(POINTS): parser.error('Unknown v2 crash point')
        binary = BUILD / 'subagent-crash-build/debug/pi-native-host' if args.skip_build else fixture_binary(args.without_drain)
        for point in points: run(point, binary, args.recovery_helper.resolve())
