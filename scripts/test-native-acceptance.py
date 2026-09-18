#!/usr/bin/env python3
"""Additional native runtime acceptance using the shared deterministic harness.

Usage: python3 scripts/test-native-acceptance.py /path/to/pi-native-host
No paid gateway, production Keychain, signing or release action is performed.
"""
import importlib.util
import json
import pathlib
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('pi_native_fixture', ROOT / 'scripts/test-native-host.py')
fixture = importlib.util.module_from_spec(spec)
# The shared runner consumes only the optional executable argument. Its main
# block does not execute on import, and the remaining unittest flags are intact.
spec.loader.exec_module(fixture)


class NativeAcceptance(unittest.TestCase):
    setUpClass = classmethod(fixture.NativeIntegration.setUpClass.__func__)
    tearDownClass = classmethod(fixture.NativeIntegration.tearDownClass.__func__)
    setUp = fixture.NativeIntegration.setUp
    tearDown = fixture.NativeIntegration.tearDown
    open = fixture.NativeIntegration.open
    submit = fixture.NativeIntegration.submit
    settled = fixture.NativeIntegration.settled

    def restart(self):
        self.peer.close()
        # The shared peer's graceful path closes stdin; a deliberately killed
        # process also needs its already-dead pipe released by this crash test.
        if not self.peer.process.stdin.closed:
            self.peer.process.stdin.close()
        self.peer = fixture.Peer(self.root)
        self.peer.command('workspace.open', {'cwd': str(self.root), 'directory': str(self.root / 'sessions'), 'captureProtocol': 1, 'resources': {'codexHome': str(self.root / 'codex')}})

    def effects(self):
        path = self.root / 'effects.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_real_stdio_disconnected_effect_remains_quarantined_after_host_restart(self):
        self.open()
        config = {'servers': {'effect': {'transport': 'stdio', 'command': sys.executable, 'args': [str(ROOT / 'fixtures/native/mcp-effect-server.py'), str(self.root)], 'timeoutSeconds': 5}}}
        self.peer.command('mcp.configure', {'config': config})
        self.peer.command('mcp.list', {'server': 'effect'})
        self.peer.command('mcp.describe', {'targets': [{'server': 'effect', 'tool': 'record'}]})
        self.assertEqual(self.effects(), [], 'Discovery must never invoke a tool')
        params = {'server': 'effect', 'tool': 'record', 'arguments': {'text': 'first synthetic effect'}}
        self.peer.command('mcp.invoke', params, 's', fail=True)
        self.assertEqual(self.effects(), [params['arguments']])
        self.assertTrue(self.peer.command('mcp.list')['outcomeUnknown'])
        self.peer.command('mcp.invoke', params, 's', fail=True)
        self.assertEqual(len(self.effects()), 1)
        path = self.peer.command('session.snapshot', session='s')['path']
        self.restart(); self.open(path=path)
        self.peer.command('mcp.configure', {'config': config})
        self.assertTrue(self.peer.command('mcp.list')['outcomeUnknown'])
        self.peer.command('mcp.invoke', params, 's', fail=True)
        self.peer.command('mcp.acknowledgeUnknown', fail=True)
        self.assertEqual(len(self.effects()), 1)
        self.peer.command('mcp.acknowledgeUnknown', {'confirmed': True})
        self.assertEqual(len(self.effects()), 1, 'Human acknowledgement cannot replay the old invocation')
        self.peer.command('side.open', {'sideSessionId': 'side'}, 's')
        self.peer.command('mcp.invoke', params, 'side', fail=True)
        self.assertEqual(len(self.effects()), 1, 'A readOnlyHint annotation cannot authorize side effects')
        new_params = {**params, 'arguments': {'text': 'new deliberate effect'}}
        self.peer.command('mcp.invoke', new_params, 's')
        self.assertEqual(self.effects(), [params['arguments'], new_params['arguments']])
        self.assertFalse(self.peer.command('mcp.list')['outcomeUnknown'])
        self.peer.command('side.close', session='side')

    def test_killed_host_preserves_removed_queue_and_explicit_resume_without_replay(self):
        self.open(model='slow')
        with fixture.Fixture.lock:
            initial_requests = len(fixture.Fixture.requests)
        self.submit(text='initial interrupted question')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with fixture.Fixture.lock:
                if len(fixture.Fixture.requests) > initial_requests:
                    break
            time.sleep(.01)
        else:
            self.fail('The first request was never dispatched')
        kept = self.submit(text='kept follow-up')
        removed = self.submit(text='removed follow-up')
        self.peer.command('queue.remove', {'turnId': removed['turnId']}, 's')
        path = self.peer.command('session.snapshot', session='s')['path']
        self.peer.process.kill(); self.peer.process.wait(timeout=5)
        self.restart(); restored = self.open(model='slow', path=path)
        self.assertEqual(restored['state'], 'paused'); self.assertEqual(restored['queueCount'], 1)
        self.assertEqual(restored['queue'][0]['turnId'], kept['turnId'])
        with fixture.Fixture.lock:
            before_resume = len(fixture.Fixture.requests)
        self.assertEqual(before_resume, initial_requests + 1, 'Restart must not dispatch a request')
        self.peer.command('queue.resume', session='s')
        result = self.settled(); self.assertEqual(result['state'], 'idle')
        users = [message['text'] for message in result['messages'] if message['role'] == 'user']
        self.assertEqual(users, ['initial interrupted question', 'kept follow-up'])
        with fixture.Fixture.lock:
            after_resume = len(fixture.Fixture.requests)
        self.assertEqual(after_resume, before_resume + 1, 'Explicit resume dispatches the pending input once')


if __name__ == '__main__':
    unittest.main(verbosity=2)
