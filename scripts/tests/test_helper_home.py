"""Generated home resources only; real helpers talk exclusively to loopback."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    with patch.object(sys, 'argv', ['home-isolation-test']):
        spec.loader.exec_module(module)
    return module


client = load('native_host_client')
wire = load('test-native-host')
concurrent = load('test-concurrent-native-host')
acceptance = load('test-native-acceptance')
helper = (Path(os.environ['PI_NATIVE_HOST']) if os.environ.get('PI_NATIVE_HOST') else
          Path(os.environ['PI_BUILD_ROOT']) / 'swift-host/arm64-apple-macosx/release/pi-native-host' if os.environ.get('PI_BUILD_ROOT') else
          ROOT / 'packages/swift-host/.build/release/pi-native-host').resolve()


@unittest.skipUnless(helper.is_file(), 'build the Release helper under PI_BUILD_ROOT first')
class HelperPathTests(unittest.TestCase):
    def test_relative_helper_and_build_root_launch_all_fixture_peers(self):
        with tempfile.TemporaryDirectory(prefix='pi-relative-helper-') as folder:
            build = Path(folder)
            executable = build / 'swift-host/arm64-apple-macosx/release/pi-native-host'
            executable.parent.mkdir(parents=True)
            executable.symlink_to(helper.resolve())
            for variable, path in (('PI_NATIVE_HOST', executable), ('PI_BUILD_ROOT', build)):
                with self.subTest(variable=variable):
                    environment = dict(os.environ)
                    for key in ('PI_NATIVE_HOST', 'PI_BUILD_ROOT'):
                        environment.pop(key, None)
                    environment[variable] = os.path.relpath(path, ROOT)
                    result = subprocess.run(
                        [sys.executable, '-m', 'unittest',
                         'scripts.tests.test_helper_home.HelperHomeFixtureTests', '-v'],
                        cwd=ROOT, env=environment, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('Ran 1 test', result.stderr)
                    self.assertNotIn('skipped', result.stderr)


class HelperEnvironmentTests(unittest.TestCase):
    def test_failed_launch_removes_its_generated_home(self):
        created = []
        temporary_directory = tempfile.TemporaryDirectory

        def temporary_home(*args, **kwargs):
            directory = temporary_directory(*args, **kwargs)
            created.append(Path(directory.name))
            return directory

        with tempfile.TemporaryDirectory(prefix='pi-home-failed-launch-') as folder, \
             patch.object(client.tempfile, 'TemporaryDirectory', side_effect=temporary_home):
            with self.assertRaises(FileNotFoundError):
                client.HostPeer(Path(folder) / 'missing-helper', folder)
        self.assertEqual(len(created), 1)
        self.assertFalse(created[0].exists())

    def test_packaged_smoke_launch_does_not_inherit_home_roots(self):
        with tempfile.TemporaryDirectory(prefix='pi-smoke-home-test-') as folder:
            root = Path(folder)
            app = root / 'Fixture.app'
            executable = app / 'Contents/Helpers/pi-native-host'
            manifest = app / 'Contents/Resources/Host/bundle-manifest.json'
            executable.parent.mkdir(parents=True)
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({'engine': 'swift', 'bundledNode': False}))
            (manifest.parent.parent / 'bello-agent.models.json').write_bytes((ROOT / 'catalogs/bello-agent.models.json').read_bytes())
            recorded = root / 'environment.json'
            executable.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                                  'from pathlib import Path\nPath(' + repr(str(recorded)) + ').write_text(json.dumps({key: os.environ.get(key) for key in ("HOME", "CFFIXED_USER_HOME", "CODEX_HOME")}))\n'
                                  'for line in sys.stdin:\n'
                                  '    frame = json.loads(line)\n'
                                  '    reply = dict(kind="ready", engine="swift", engineVersion="fixture", hostEpoch="fixture", capabilities=["responses"]) if frame["kind"] == "hello" else dict(commandId=frame["commandId"], ok=True)\n'
                                  '    print(json.dumps(reply), flush=True)\n')
            executable.chmod(0o755)
            binary = root / 'bin'
            binary.mkdir()
            (binary / 'lipo').write_text('#!/bin/sh\nexit 0\n')
            (binary / 'lipo').chmod(0o755)
            environment = {**os.environ, 'HOME': str(root / 'inherited'), 'CFFIXED_USER_HOME': str(root / 'inherited'),
                           'CODEX_HOME': str(root / 'inherited-codex'), 'PATH': str(binary) + os.pathsep + os.environ['PATH']}
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/smoke-native-bundle.py'), str(app)],
                                    env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            child = json.loads(recorded.read_text())
            for name in ('HOME', 'CFFIXED_USER_HOME', 'CODEX_HOME'):
                with self.subTest(variable=name):
                    self.assertNotEqual(child[name], environment[name], name + ' was inherited by the smoke helper')
            self.assertEqual(child['HOME'], child['CFFIXED_USER_HOME'])
            self.assertTrue(Path(child['CODEX_HOME']).is_relative_to(Path(child['HOME'])))

    def test_child_roots_are_isolated_even_with_an_explicit_environment(self):
        with tempfile.TemporaryDirectory(prefix='pi-home-env-test-') as folder:
            root = Path(folder)
            probe = root / 'environment'
            probe.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                             'print(json.dumps({key: os.environ.get(key) for key in ("HOME", "CFFIXED_USER_HOME", "CODEX_HOME", "PI_FIXTURE_FAULT", "PATH")}), flush=True)\nsys.stdin.read()\n')
            probe.chmod(0o755)
            inherited = {**os.environ, 'HOME': str(root / 'inherited'), 'CFFIXED_USER_HOME': str(root / 'inherited'),
                         'CODEX_HOME': str(root / 'private-codex'), 'PI_FIXTURE_FAULT': 'synthetic-fault'}
            homes = []
            for explicit in (False, True):
                with self.subTest(explicit=explicit), patch.dict(os.environ, inherited, clear=True):
                    peer = client.HostPeer(probe, root, env=inherited if explicit else None)
                    try:
                        child = peer.next_frame(5)
                        for name in ('HOME', 'CFFIXED_USER_HOME', 'CODEX_HOME'):
                            with self.subTest(variable=name):
                                self.assertNotEqual(child[name], inherited[name], name + ' was inherited')
                                self.assertTrue(Path(child[name]).is_dir())
                        self.assertEqual(child['HOME'], child['CFFIXED_USER_HOME'])
                        self.assertTrue(Path(child['CODEX_HOME']).is_relative_to(Path(child['HOME'])))
                        self.assertEqual(child['PI_FIXTURE_FAULT'], 'synthetic-fault')
                        self.assertEqual(child['PATH'], inherited['PATH'])
                        homes.append(Path(child['HOME']))
                    finally:
                        peer.close()
            self.assertEqual(len(set(homes)), 2, 'helpers must not share a default home')
            self.assertTrue(all(not home.exists() for home in homes), 'owned homes must be removed after disposal')
            self.assertEqual(inherited['CODEX_HOME'], str(root / 'private-codex'), 'do not mutate the caller environment')


@unittest.skipUnless(helper.is_file(), 'build the Release helper under PI_BUILD_ROOT first')
class HelperHomeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = wire.http.server.ThreadingHTTPServer(('127.0.0.1', 0), wire.Fixture)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()

    def test_every_peer_excludes_inherited_skills_and_codex_instructions(self):
        with tempfile.TemporaryDirectory(prefix='pi-home-fixture-') as folder:
            root = Path(folder)
            inherited, codex = root / 'inherited', root / 'inherited-codex'
            skill = inherited / '.agents/skills/private/SKILL.md'
            skill.parent.mkdir(parents=True)
            skill.write_text('---\nname: private\ndescription: SYNTHETIC_INHERITED_SKILL_47CF\n---\nFixture body.\n')
            codex.mkdir()
            (codex / 'AGENTS.md').write_text('SYNTHETIC_INHERITED_CODEX_47CF')
            constructors = {'wire': wire.Peer, 'concurrent': concurrent.ConcurrentPeer,
                            'acceptance': acceptance.fixture.Peer, 'shared': lambda cwd: client.HostPeer(helper, cwd)}
            for name, constructor in constructors.items():
                for explicit_codex in (True, False):
                    with self.subTest(peer=name, explicit_codex=explicit_codex), \
                         patch.dict(os.environ, {'HOME': str(inherited), 'CFFIXED_USER_HOME': str(inherited), 'CODEX_HOME': str(codex)}), \
                         patch.object(wire, 'BINARY', helper), patch.object(concurrent, 'BINARY', helper), \
                         patch.object(acceptance.fixture, 'BINARY', helper):
                        workspace = root / (name + str(explicit_codex))
                        workspace.mkdir()
                        peer = constructor(workspace)
                        try:
                            if peer.epoch is None:
                                peer.epoch = peer.hello(10)['hostEpoch']

                            def command(method, params=None, session=None):
                                identity = peer.post(method, params, session)
                                while True:
                                    frame = peer.next_frame(10)
                                    if frame.get('commandId') == identity:
                                        self.assertTrue(frame['ok'], frame)
                                        return frame['result']

                            resources = {'codexHome': str(workspace / 'codex')} if explicit_codex else {}
                            command('workspace.open', {'cwd': str(workspace), 'directory': str(workspace / 'sessions'), 'resources': resources})
                            profile = {'id': 'fixture', 'providerId': 'litellm', 'modelId': 'text', 'api': 'openai-responses',
                                       'baseUrl': f'http://127.0.0.1:{self.server.server_port}/v1', 'contextWindow': 100000,
                                       'maxOutputTokens': 4096, 'modelOutputLimit': 4096, 'routing': {'replayPolicy': 'portable'}}
                            command('session.open', {'profile': profile, 'apiKey': 'fixture-secret', 'toolMode': 'read-only'}, 'isolation')
                            with wire.Fixture.lock:
                                wire.Fixture.requests.clear()
                            command('turn.submit', {'clientTurnId': 'isolation-turn', 'text': 'Say hello without tools.'}, 'isolation')
                            deadline = time.monotonic() + 10
                            while True:
                                status = command('session.status', {}, 'isolation')
                                if status['state'] in ('idle', 'error'):
                                    break
                                self.assertLess(time.monotonic(), deadline)
                                time.sleep(0.01)
                            self.assertEqual(status['state'], 'idle', status)
                            self.assertFalse(status.get('errorCode'), status)
                            with wire.Fixture.lock:
                                self.assertTrue(all(record.get('validated') for record in wire.Fixture.requests))
                                requests = [record['body'].decode() for record in wire.Fixture.requests]
                            self.assertTrue(requests, 'the loopback fixture must receive a real request')
                            for secret in ('SYNTHETIC_INHERITED_SKILL_47CF', str(skill), 'SYNTHETIC_INHERITED_CODEX_47CF', str(codex)):
                                with self.subTest(secret=secret):
                                    self.assertFalse(any(secret in body for body in requests), 'fixture received inherited resource: ' + secret)
                        finally:
                            peer.close()


if __name__ == '__main__':
    unittest.main()
