#!/usr/bin/env python3
"""Prove overlapping work in the real helper using a request-aware loopback gateway.

python3 scripts/test-concurrent-native-host.py /path/to/pi-native-host
Only synthetic credentials and isolated temporary projects are used. Barriers
require all requests to arrive before any can finish, so sequential execution
cannot accidentally pass this test by returning fast canned responses.
"""
import base64
import collections
import http.server
import importlib.util
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith('-')
                      else ROOT / 'packages/swift-host/.build/debug/pi-native-host').resolve()
SPEC = importlib.util.spec_from_file_location('litellm_contract', ROOT / 'fixtures/native/litellm_contract.py')
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


class ConcurrentPeer:
    """Multiplexes command replies while independently acknowledging captures."""
    def __init__(self, cwd, capture_delay=0):
        self.process = subprocess.Popen([str(BINARY)], cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.frames = queue.Queue()
        self.captures = []
        self.events = []
        self.write_lock = threading.Lock()
        self.capture_delay = capture_delay
        self.errors = []
        self.stderr = bytearray()

        def read():
            try:
                for line in self.process.stdout:
                    frame = json.loads(line)
                    if frame.get('kind') == 'capture':
                        self.captures.append(frame['packet'])
                        if self.capture_delay:
                            time.sleep(self.capture_delay)
                        self.send({'v': 1, 'kind': 'capture.ack', 'hostEpoch': frame['hostEpoch'],
                                   'transferId': frame['transferId'], 'accepted': True})
                    else:
                        self.frames.put(frame)
            except Exception as error:
                self.errors.append(str(error))

        def read_errors():
            for line in self.process.stderr:
                self.stderr.extend(line)

        self.reader = threading.Thread(target=read, daemon=True)
        self.error_reader = threading.Thread(target=read_errors, daemon=True)
        self.reader.start()
        self.error_reader.start()
        self.send({'v': 1, 'kind': 'hello', 'major': 1, 'minor': 1})
        hello = self.frames.get(timeout=10)
        assert hello['kind'] == 'ready' and hello['engine'] == 'swift', hello
        self.epoch = hello['hostEpoch']

    def send(self, value):
        with self.write_lock:
            self.process.stdin.write(encoded(value) + b'\n')
            self.process.stdin.flush()

    def batch(self, commands, timeout=25):
        ids = [str(uuid.uuid4()) for _ in commands]
        for identifier, (method, session, params) in zip(ids, commands):
            self.send({'v': 1, 'kind': 'command', 'hostEpoch': self.epoch,
                       'commandId': identifier, 'sessionId': session,
                       'method': method, 'params': params})
        pending = set(ids)
        replies = {}
        deadline = time.monotonic() + timeout
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Helper command replies did not arrive: ' + repr(sorted(pending)))
            frame = self.frames.get(timeout=remaining)
            identifier = frame.get('commandId')
            if identifier in pending:
                pending.remove(identifier)
                assert frame['ok'], frame
                replies[identifier] = frame['result']
            else:
                self.events.append(frame)
        return [replies[identifier] for identifier in ids]

    def command(self, method, session=None, params=None):
        return self.batch([(method, session, params or {})])[0]

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=2)
        self.error_reader.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()


class Scenario:
    def __init__(self, count, tools, automatic_release=False):
        self.count = count
        self.tools = tools
        self.automatic_release = automatic_release
        self.condition = threading.Condition()
        self.requests = []
        self.errors = []
        self.active = 0
        self.maximum = 0
        self.arrived = {1: set(), 2: set()}
        self.releases = {1: threading.Event(), 2: threading.Event()}
        self.cancelled = set()

    def wait_for_wave(self, wave):
        with self.condition:
            ok = self.condition.wait_for(lambda: len(self.arrived[wave]) == self.count or self.errors, timeout=20)
            assert ok and not self.errors and len(self.arrived[wave]) == self.count, {
                'wave': wave, 'arrived': sorted(self.arrived[wave]), 'errors': self.errors}

    def release_all(self):
        for event in self.releases.values():
            event.set()


class Gateway(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def log_message(self, *args):
        pass

    def do_GET(self):
        scenario = self.server.scenario
        with scenario.condition:
            if self.path == '/state':
                value = {'active': scenario.active, 'peakHTTP': scenario.maximum,
                         'waves': {str(wave): len(ids) for wave, ids in scenario.arrived.items()},
                         'requests': len(scenario.requests), 'errors': list(scenario.errors),
                         'cancelled': sorted(scenario.cancelled),
                         'textDeltas': sum(record.get('textDeltas', 0) for record in scenario.requests)}
            elif self.path == '/captures':
                value = [{'session': record['session'], 'wave': record['wave'],
                          'request': base64.b64encode(record['body']).decode(),
                          'response': base64.b64encode(record['response']).decode()}
                         for record in scenario.requests]
            else:
                self.send_error(404)
                return
        data = encoded(value)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        scenario = self.server.scenario
        raw = self.rfile.read(int(self.headers['Content-Length']))
        record = {'body': raw, 'response': bytearray(), 'headers': dict(self.headers)}
        entered = False
        session = None
        try:
            body = json.loads(raw)
            semantic = CONTRACT.validate_request('POST', self.path, dict(self.headers), body,
                api_key='fixture-secret', model='concurrency-fixture', max_output_tokens=4096)
            session = self.headers['x-session-id']
            record['session'] = session
            first_prompt = 'concurrency ' + session
            followup = semantic['latest_text'] == 'followup ' + session
            assert semantic['user_texts'] == [first_prompt] + (['followup ' + session] if followup else []), semantic
            results = [item for item in body['input'] if item.get('type') == 'function_call_output']
            wave = 2 if results else 1
            record['wave'] = wave
            if results:
                assert scenario.tools and len(results) == 1, results
                assert results[0]['call_id'] == 'call_' + session, results
                assert 'contents for ' + session in results[0]['output'], results
                assert any(tool.get('name') == 'read' for tool in body['tools']), body['tools']
            else:
                assert not any(item.get('type') == 'function_call' for item in body['input']), body['input']
            with scenario.condition:
                scenario.requests.append(record)
                scenario.active += 1
                entered = True
                scenario.maximum = max(scenario.maximum, scenario.active)
                if not followup:
                    scenario.arrived[wave].add(session)
                    if scenario.automatic_release and len(scenario.arrived[wave]) == scenario.count:
                        scenario.releases[wave].set()
                scenario.condition.notify_all()

            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('X-Litellm-Model-Name', 'fixture/resolved')
            self.end_headers()
            self.event(record, {'type': 'response.created', 'response': {
                'id': 'resp_' + session, 'status': 'in_progress', 'model': 'concurrency-fixture'}})
            # Hold actual open HTTP streams. Heartbeats make cancellation visible
            # without releasing the other sessions' barriers.
            if not followup:
                while not scenario.releases[wave].wait(.04):
                    self.write(record, b': concurrent fixture waiting\n\n')
            if not scenario.tools and session.endswith('-01'):
                self.event(record, {'type': 'response.failed', 'response': {
                    'status': 'failed', 'error': {'code': 'invalid_request', 'message': 'isolated fixture error ' + session}}})
                return
            if scenario.tools and wave == 1:
                arguments = encoded({'path': session + '.txt'}).decode()
                item = {'type': 'function_call', 'id': 'fc_' + session, 'call_id': 'call_' + session,
                        'name': 'read', 'arguments': arguments}
                self.event(record, {'type': 'response.output_item.added', 'output_index': 0,
                                    'item': {**item, 'arguments': ''}})
                for offset in range(0, len(arguments), 5):
                    self.event(record, {'type': 'response.function_call_arguments.delta', 'output_index': 0,
                                        'delta': arguments[offset:offset + 5]})
                output = [item]
            else:
                prefix = ('followup complete ' if followup else 'completed ') + session + ' 中文🙂'
                pieces = ([prefix + '\n'] + [f'chunk {i:02} {session} 中文🙂\n' for i in range(32)]
                          if scenario.tools else [prefix[:8], prefix[8:16], prefix[16:]])
                text = ''.join(pieces)
                record['textDeltas'] = len(pieces)
                for piece in pieces:
                    self.event(record, {'type': 'response.output_text.delta', 'delta': piece})
                    if scenario.tools:
                        time.sleep(.004)
                output = [{'type': 'message', 'id': 'msg_' + session, 'role': 'assistant', 'status': 'completed',
                           'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}]
            self.event(record, {'type': 'response.completed', 'response': {
                'id': 'resp_' + session, 'status': 'completed', 'model': 'fixture/resolved', 'output': output,
                'usage': {'input_tokens': 100, 'input_tokens_details': {'cached_tokens': 40},
                          'output_tokens': 10, 'output_tokens_details': {'reasoning_tokens': 2},
                          'total_tokens': 110, 'cost': .001}}})
        except (BrokenPipeError, ConnectionResetError):
            with scenario.condition:
                if session:
                    scenario.cancelled.add(session)
                scenario.condition.notify_all()
        except Exception as error:
            with scenario.condition:
                scenario.errors.append(str(error))
                scenario.condition.notify_all()
        finally:
            if entered:
                with scenario.condition:
                    scenario.active -= 1
                    scenario.condition.notify_all()

    def write(self, record, data):
        self.wfile.write(data)
        self.wfile.flush()
        record['response'].extend(data)

    def event(self, record, value):
        self.write(record, b'data: ' + encoded(value) + b'\r\n\r\n')


class Server(http.server.ThreadingHTTPServer):
    request_queue_size = 64
    daemon_threads = True


class TwentySessionIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='concurrent-native-', dir=os.environ.get('PI_APP_SCRATCH_ROOT'))
        self.root = pathlib.Path(self.temp.name)
        self.peers = []
        self.server = None
        self.started = time.monotonic()

    def tearDown(self):
        if self.server:
            self.scenario.release_all()
        for peer in self.peers:
            peer.close()
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server_thread.join(timeout=2)
        self.temp.cleanup()

    def setup_projects(self, projects=1, tools=True, delay=0):
        self.scenario = Scenario(20, tools)
        self.server = Server(('127.0.0.1', 0), Gateway)
        self.server.scenario = self.scenario
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        profile = {'id': 'fixture', 'revision': '1', 'providerId': 'litellm',
                   'modelId': 'concurrency-fixture', 'api': 'openai-responses',
                   'baseUrl': 'http://127.0.0.1:' + str(self.server.server_port) + '/v1',
                   'contextWindow': 100000, 'maxOutputTokens': 4096, 'modelOutputLimit': 4096,
                   'routing': {'replayPolicy': 'portable'}}
        self.sessions = []
        for project in range(projects):
            root = self.root / ('project-' + str(project))
            root.mkdir()
            peer = ConcurrentPeer(root, capture_delay=delay)
            self.peers.append(peer)
            peer.command('workspace.open', params={'cwd': str(root), 'directory': str(root / 'state'),
                'captureProtocol': 1, 'resources': {'codexHome': str(root / 'codex'), 'skills': False}})
            ids = ['p' + str(project) + '-' + format(i, '02') for i in range(20 // projects)]
            for identifier in ids:
                (root / (identifier + '.txt')).write_text('contents for ' + identifier)
                self.sessions.append((peer, identifier))
            peer.batch([('session.open', identifier, {'profile': profile, 'apiKey': 'fixture-secret',
                         'toolMode': 'read-only'}) for identifier in ids])
            peer.batch([('debug.mode', identifier, {'mode': 'persist'}) for identifier in ids])

    def start_all(self):
        for peer in self.peers:
            peer.batch([('turn.submit', identifier, {'clientTurnId': 'turn-' + identifier,
                        'text': 'concurrency ' + identifier}) for owner, identifier in self.sessions if owner is peer])
        self.scenario.wait_for_wave(1)

    def states(self):
        result = {}
        for peer in self.peers:
            ids = [identifier for owner, identifier in self.sessions if owner is peer]
            values = peer.batch([('session.snapshot', identifier, {}) for identifier in ids])
            result.update(zip(ids, values))
        return result

    def settled(self):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            states = self.states()
            if all(value['state'] in ('idle', 'error', 'paused') for value in states.values()):
                return states
            time.sleep(.02)
        diagnostics = {'sessions': {k: v['state'] for k, v in states.items()},
                       'gatewayRequests': len(self.scenario.requests), 'gatewayActive': self.scenario.active,
                       'recorderPackets': [dict(collections.Counter(packet.get('type') for packet in peer.captures)) for peer in self.peers],
                       'peerErrors': [peer.errors for peer in self.peers]}
        self.fail('Not every concurrent session settled: ' + repr(diagnostics))

    def assert_captures(self, expected_attempts):
        attempts = {}
        bodies = {}
        finishes = {}
        for peer in self.peers:
            self.assertFalse(peer.errors, peer.errors)
            for packet in peer.captures:
                kind = packet['type']
                if kind == 'begin':
                    metadata = packet['metadata']
                    attempts[metadata['attemptId']] = metadata
                elif kind == 'bytes':
                    key = (packet['attemptId'], packet['body'])
                    body = bodies.setdefault(key, bytearray())
                    self.assertEqual(packet['offset'], len(body), 'No capture gaps, duplication or cross-session data')
                    body.extend(base64.b64decode(packet['bytes']))
                elif kind == 'finish':
                    metadata = packet['metadata']
                    finishes[metadata['attemptId']] = metadata
        self.assertEqual(len(attempts), expected_attempts)
        self.assertEqual(set(attempts), set(finishes))
        for identifier, metadata in finishes.items():
            self.assertIsNone(metadata.get('persistenceError'), metadata)
            request = bytes(bodies[(identifier, 'request')])
            matching = [r for r in self.scenario.requests if r['body'] == request]
            self.assertEqual(len(matching), 1)
            record = matching[0]
            self.assertEqual(metadata['sessionId'], record['session'])
            self.assertEqual(metadata['requestHeaders']['authorization'], 'Bearer ********cret')
            self.assertEqual(metadata['requestHeaders']['x-session-id'], record['session'])
            response = bytes(bodies.get((identifier, 'response'), b''))
            self.assertEqual(metadata['response']['captureBytes'], len(response))
            if metadata['outcome'] == 'completed' or metadata.get('transportOutcome') == 'eof':
                self.assertEqual(response, bytes(record['response']))
            else:
                self.assertEqual(response, bytes(record['response'])[:len(response)],
                                 'Interrupted captures must retain an exact contiguous prefix')
                self.assertEqual(metadata['response']['state'], 'partial')
                self.assertLessEqual(len(response), metadata['response']['observedBytes'])
            if metadata['outcome'] == 'completed':
                self.assertEqual(metadata['usage']['output'], 10)
                # The gateway reports ten output tokens, including two hidden
                # reasoning tokens. Visible text/arguments vary by hundreds of
                # bytes, but neither those bytes nor reasoning are added again.
                self.assertEqual(metadata['usage']['reasoning'], 2)
                # Decode speed: the 9 tokens after the first over first -> last
                # output (the terminal only when no last output was stamped),
                # and no rate below the measurement floor.
                timings, metrics = metadata['timings'], metadata['metrics']
                end = timings['lastContent'] if timings['lastContent'] is not None else timings['modelComplete']
                self.assertLessEqual(timings['firstContent'], end)
                self.assertLessEqual(end, timings['modelComplete'])
                span = end - timings['firstContent']
                self.assertAlmostEqual(metrics['streamDurationMs'], span)
                if span >= metrics['minimumDecodeSpanMs']:
                    self.assertAlmostEqual(metrics['decodeTokensPerSecond'], 9 / (span / 1000))
                else:
                    self.assertIsNone(metrics['decodeTokensPerSecond'], 'A span below the floor is one burst, not a rate')
            else:
                self.assertIsNone(metadata['metrics']['decodeTokensPerSecond'],
                                  'Failed and cancelled attempts cannot publish a completed rate')
            self.assertNotIn('outputTokensPerSecond', metadata['metrics'])
        self.assertFalse(self.scenario.errors, self.scenario.errors)
        return finishes

    def run_roundtrip(self, projects):
        # Delay durable ACKs enough to overlap twenty recorder submissions;
        # a healthy slow recorder must apply backpressure, never drop captures.
        self.setup_projects(projects=projects, tools=True, delay=.01)
        self.start_all()
        self.assertEqual(self.scenario.maximum, 20)
        self.assertTrue(all(v['state'] not in ('idle', 'error', 'paused') for v in self.states().values()))
        self.scenario.releases[1].set()
        self.scenario.wait_for_wave(2)
        self.assertEqual(len(self.scenario.arrived[2]), 20, 'Every session executed its own real read tool')
        self.scenario.releases[2].set()
        states = self.settled()
        for identifier, state in states.items():
            self.assertEqual(state['state'], 'idle', state.get('error'))
            self.assertIn('completed ' + identifier, json.dumps(state['messages'], ensure_ascii=False))
            self.assertEqual(state['activity']['version'], 2)
            self.assertNotIn('estimatedOutputTokensPerSecond', state['activity'])
            self.assertNotIn('outputBytes', state['activity'])
        self.assertEqual(len(self.scenario.requests), 40)
        self.assertEqual(sum(r.get('textDeltas', 0) for r in self.scenario.requests), 660)
        self.assert_captures(40)
        print(f'CONCURRENCY projects={projects} sessions=20 peakHTTP={self.scenario.maximum} '
              f'toolRoundTrips=20 streamedTextEvents=660 exactCapturedBodies=80 '
              f'elapsed={time.monotonic()-self.started:.3f}s', flush=True)

    def test_twenty_sessions_one_project_stream_tools_and_exact_capture(self):
        self.run_roundtrip(1)

    def test_twenty_sessions_across_four_projects(self):
        self.run_roundtrip(4)

    def test_cancel_error_and_queued_followup_are_session_local(self):
        self.setup_projects(tools=False)
        self.start_all()
        peer, cancelled = self.sessions[0]
        queued = self.sessions[2][1]
        peer.command('turn.submit', queued, {'clientTurnId': 'followup-' + queued, 'text': 'followup ' + queued})
        # Exercise a nonempty partial body, not just cancellation before headers.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            observed = peer.command('debug.list', cancelled)['attempts']
            if observed and observed[0]['response']['captureBytes'] > 0:
                break
            time.sleep(.02)
        self.assertTrue(observed and observed[0]['response']['captureBytes'] > 0)
        peer.command('turn.stop', cancelled)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            stopped = peer.command('session.snapshot', cancelled)
            if stopped['state'] == 'paused':
                break
            time.sleep(.02)
        self.assertEqual(stopped['state'], 'paused')
        states = self.states()
        self.assertEqual(sum(v['state'] not in ('idle', 'error', 'paused') for v in states.values()), 19,
                         'Stopping one request must leave the other nineteen running')
        with self.scenario.condition:
            disconnected = self.scenario.condition.wait_for(
                lambda: cancelled in self.scenario.cancelled or self.scenario.errors, timeout=5)
            self.assertFalse(self.scenario.errors, self.scenario.errors)
            self.assertTrue(disconnected and cancelled in self.scenario.cancelled,
                            'Stop must close its HTTP stream while the other streams remain held')
        self.scenario.releases[1].set()
        states = self.settled()
        self.assertEqual(states[cancelled]['state'], 'paused')
        self.assertEqual(states['p0-01']['state'], 'error')
        self.assertIn('isolated fixture error', json.dumps(states['p0-01']))
        for identifier, state in states.items():
            if identifier not in (cancelled, 'p0-01'):
                self.assertEqual(state['state'], 'idle')
        self.assertIn('followup complete ' + queued, json.dumps(states[queued]['messages']))
        self.assertEqual(len(self.scenario.requests), 21, 'No retries or cross-session queue deliveries')
        captures = list(self.assert_captures(21).values())
        interrupted = [item for item in captures if item['sessionId'] == cancelled]
        failed = [item for item in captures if item['sessionId'] == 'p0-01']
        self.assertEqual(len(interrupted), 1)
        self.assertEqual(len(failed), 1)
        self.assertEqual(interrupted[0]['outcome'], 'cancelled')
        self.assertEqual(interrupted[0]['modelOutcome'], 'interrupted')
        self.assertEqual(interrupted[0]['transportOutcome'], 'cancelled')
        self.assertEqual(interrupted[0]['response']['state'], 'partial')
        self.assertGreater(interrupted[0]['response']['captureBytes'], 0)
        self.assertEqual(failed[0]['outcome'], 'failed')
        self.assertEqual(failed[0]['modelOutcome'], 'failed')
        self.assertEqual(failed[0]['transportOutcome'], 'eof')
        self.assertEqual(failed[0]['response']['state'], 'complete')
        print(f'CONCURRENCY mixed sessions=20 peakHTTP={self.scenario.maximum} '
              f'cancelled=1 failed=1 unaffected=18 queuedFollowups=1 transportCancellation=true '
              f'exactPartialResponseBytes={interrupted[0]["response"]["captureBytes"]} '
              f'elapsed={time.monotonic()-self.started:.3f}s', flush=True)


if __name__ == '__main__':
    if sys.argv[1:] == ['--serve']:
        server = Server(('127.0.0.1', 0), Gateway)
        server.scenario = Scenario(20, tools=True, automatic_release=True)
        print(json.dumps({'port': server.server_port}), flush=True)
        try:
            server.serve_forever()
        finally:
            server.scenario.release_all()
            server.server_close()
    else:
        unittest.main(verbosity=2)
