"""Launch benchmark probes use generated bundles, homes and a fake harness only."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DOMAIN = 'com.belloware.PiApp.launchperf'


def normalize_home(value):
    # Foundation spells generated /private/var homes as /var on macOS.
    return value.removeprefix('/private') if value and value.startswith('/private/var/') else value


class PerfLaunchTests(unittest.TestCase):
    def test_launch_and_preference_checks_stay_in_the_fixture(self):
        with tempfile.TemporaryDirectory(prefix='pi-launch-fixture-') as folder:
            root = Path(folder).resolve()
            fixture, output, binary = root / 'fixture', root / 'output', root / 'bin'
            preferences = fixture / 'home/Library/Preferences' / (DOMAIN + '.plist')
            preferences.parent.mkdir(parents=True)
            preferences.write_bytes(plistlib.dumps({'fixture': 'untouched'}))
            (fixture / 'fixture-root').write_text(str(fixture))
            (fixture / 'vault.json').write_text('{}')
            app = root / 'Fixture.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'fixture', 'CFBundleName': 'Fixture'}))
            # The fake harness never executes the app or launches a window.
            (app / 'Contents/MacOS/Bello Agent').write_text('not an executable')
            binary.mkdir()
            calls = root / 'calls.jsonl'
            stub = '#!' + sys.executable + '\n' + r'''
import json, os, sys
from pathlib import Path
command = Path(sys.argv[0]).name
args = sys.argv[1:]
keys = ('HOME', 'CFFIXED_USER_HOME', 'CODEX_HOME', 'TMPDIR', 'PI_APP_SCRATCH_ROOT',
        'PI_APP_BENCHMARK_STATE_ROOT', 'PI_APP_BENCHMARK_OUTPUT', 'BELLO_CONTEXT_DIAGNOSTICS')
record = dict(command=command, args=args, environment={key: os.environ.get(key) for key in keys})
if command == 'belloperf':
    record['overrides'] = dict(args[index + 1].split('=', 1) for index, value in enumerate(args) if value == '--env')
    home = Path(record['overrides']['HOME'])
    record['homeExists'] = home.is_dir()
    record['codexExists'] = (home / '.codex').is_dir()
    record['preferencesExist'] = (home / 'Library/Preferences/com.belloware.PiApp.launchperf.plist').exists()
    label = args[args.index('--label') + 1]
    print(label + ' trial {"windowMs": 1, "settledMs": 2}')
elif command == 'stat':
    print('fixture-mtime')
elif command == 'sysctl':
    print('{ 0.0 0.0 0.0 }')
with open(os.environ['PI_LAUNCH_CALLS'], 'a') as output:
    output.write(json.dumps(record) + '\n')
'''
            for command in ('belloperf', 'stat', 'defaults', 'sysctl'):
                executable = binary / command
                executable.write_text(stub)
                executable.chmod(0o755)
            inherited = root / 'inherited'
            inherited.mkdir()
            environment = dict(os.environ, HOME=str(inherited), CFFIXED_USER_HOME=str(inherited),
                               CODEX_HOME=str(inherited / 'codex'), TMPDIR=str(inherited),
                               PI_APP_SCRATCH_ROOT=str(inherited), PI_LAUNCH_CALLS=str(calls),
                               PI_APP_BENCHMARK_STATE_ROOT=str(inherited / 'state'),
                               PI_APP_BENCHMARK_OUTPUT=str(inherited / 'benchmark.json'),
                               BELLO_CONTEXT_DIAGNOSTICS=str(inherited / 'context.json'),
                               PATH=str(binary) + os.pathsep + os.environ['PATH'],
                               BELLOPERF=str(binary / 'belloperf'), WARM='1', COLD='0')
            result = subprocess.run(['bash', str(ROOT / 'scripts/perf-launch.sh'),
                                     str(fixture), str(output), 'fixture=' + str(app)],
                                    cwd=root, env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            launches = [record for record in records if record['command'] == 'belloperf']
            self.assertEqual(len(launches), 2, 'one prime and one warm trial must execute')
            home, scratch = str(output / 'run/home'), str(output / 'run/tmp')
            expected = dict(HOME=home, CFFIXED_USER_HOME=home, CODEX_HOME=home + '/.codex',
                            TMPDIR=scratch, PI_APP_SCRATCH_ROOT=scratch)
            for launch in launches:
                with self.subTest(trial=Path(launch['args'][launch['args'].index('--out') + 1]).name):
                    self.assertEqual(launch['environment'], dict(expected, PI_APP_BENCHMARK_STATE_ROOT=None,
                                     PI_APP_BENCHMARK_OUTPUT=None, BELLO_CONTEXT_DIAGNOSTICS=None),
                                     'the harness must also be isolated')
                    self.assertEqual({key: launch['overrides'].get(key) for key in expected}, expected)
                    self.assertEqual(launch['overrides']['PI_APP_LAUNCH_FIXTURE_VAULT'], str(output / 'run/vault.json'))
                    self.assertTrue(launch['homeExists'])
                    self.assertTrue(launch['codexExists'])
                    self.assertFalse(launch['preferencesExist'], 'reset only the copied fixture preferences')
            with self.subTest(preferences='metadata'):
                stats = [record['args'][-1] for record in records if record['command'] == 'stat']
                self.assertEqual(stats, [str(preferences), str(preferences)])
            with self.subTest(preferences='defaults'):
                self.assertFalse(any(record['command'] == 'defaults' for record in records),
                                 'do not contact the invoking account preferences service')
            self.assertEqual(plistlib.loads(preferences.read_bytes()), {'fixture': 'untouched'})


class LaunchHelperEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='pi-launch-helper-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name).resolve()
        source = cls.root / 'main.swift'
        source.write_text(r'''
import Foundation
if CommandLine.arguments.contains("child") {
    let paths = ["foundationHome": NSHomeDirectory(),
                 "fileManagerHome": FileManager.default.homeDirectoryForCurrentUser.path]
    print(String(decoding: try JSONSerialization.data(withJSONObject: paths), as: UTF8.self))
} else {
    let environment = HostEnvironment.values(toolsPATH: "/fixture/tools", appVersion: "fixture",
                                            benchmark: CommandLine.arguments.contains("benchmark"))
    print(String(decoding: try JSONSerialization.data(withJSONObject: environment), as: UTF8.self))
    if CommandLine.arguments.contains("spawn") {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["child"]; child.environment = environment
        let pipe = Pipe(); child.standardOutput = pipe
        try child.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        print(String(decoding: output, as: UTF8.self), terminator: "")
        exit(child.terminationStatus)
    }
}
''')
        cls.probes = {}
        for condition in ('shipping', 'PI_LAUNCH_FIXTURE', 'PI_TEST_HOST'):
            probe = cls.root / condition
            flags = [] if condition == 'shipping' else ['-D', condition]
            subprocess.run(['xcrun', 'swiftc', *flags, '-module-cache-path', str(cls.root / 'modules'),
                            str(ROOT / 'apps/macos/PiApp/Host/HostEnvironment.swift'), str(source),
                            '-o', str(probe)], check=True, capture_output=True, text=True)
            cls.probes[condition] = probe

    def environment(self):
        home, scratch = self.root / 'home', self.root / 'scratch'
        home.mkdir(exist_ok=True); scratch.mkdir(exist_ok=True)
        return dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                    CODEX_HOME=str(self.root / 'inherited-codex'), TMPDIR=str(scratch),
                    PI_APP_SCRATCH_ROOT=str(scratch))

    def test_fixture_helpers_keep_foundation_and_codex_in_the_generated_home(self):
        parent = self.environment()
        for condition in ('PI_LAUNCH_FIXTURE', 'PI_TEST_HOST'):
            with self.subTest(condition=condition):
                result = subprocess.run([str(self.probes[condition]), 'spawn', 'benchmark'],
                                        env=parent, capture_output=True, text=True, check=True)
                environment, paths = map(json.loads, result.stdout.splitlines())
                for key, expected in (('HOME', parent['HOME']), ('CFFIXED_USER_HOME', parent['HOME']),
                                      ('CODEX_HOME', parent['HOME'] + '/.codex')):
                    with self.subTest(variable=key):
                        self.assertEqual(normalize_home(environment.get(key)), normalize_home(expected))
                self.assertEqual(environment['TMPDIR'], parent['PI_APP_SCRATCH_ROOT'])
                self.assertEqual(environment['PATH'], '/fixture/tools')
                self.assertEqual(environment['PI_APP_BENCHMARK'], '1')
                self.assertEqual({key: normalize_home(value) for key, value in paths.items()},
                                 dict(foundationHome=normalize_home(parent['HOME']), fileManagerHome=normalize_home(parent['HOME'])))

    def test_shipping_helper_environment_keeps_its_existing_allowlist(self):
        parent = self.environment()
        for benchmark in (False, True):
            with self.subTest(benchmark=benchmark):
                result = subprocess.run([str(self.probes['shipping']), *(['benchmark'] if benchmark else [])],
                                        env=parent, capture_output=True, text=True, check=True)
                environment = json.loads(result.stdout)
                environment['HOME'] = normalize_home(environment['HOME'])
                self.assertEqual(environment, {
                    'HOME': normalize_home(parent['HOME']), 'PATH': '/fixture/tools', 'LANG': 'en_US.UTF-8',
                    'TMPDIR': parent['PI_APP_SCRATCH_ROOT'], 'PI_APP_VERSION': 'fixture',
                    'PI_APP_BENCHMARK': '1' if benchmark else '0'})


if __name__ == '__main__':
    unittest.main()
