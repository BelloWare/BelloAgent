"""Generated launch probes; real preferences access is limited to the fixture domain."""
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
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pi-launch-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = root = Path(self.temp.name).resolve()
        self.fixture, self.output, binary = root / 'fixture', root / 'output', root / 'bin'
        self.preferences = self.fixture / 'home/Library/Preferences' / (DOMAIN + '.plist')
        self.preferences.parent.mkdir(parents=True)
        self.preferences.write_bytes(plistlib.dumps({'fixture': 'untouched'}))
        (self.fixture / 'fixture-root').write_text(str(self.fixture))
        (self.fixture / 'vault.json').write_text('{}')
        self.app = root / 'Fixture.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'fixture', 'CFBundleName': 'Fixture'}))
        # The fake harness never executes the app or launches a window.
        (self.app / 'Contents/MacOS/Bello Agent').write_text('not an executable')
        binary.mkdir()
        self.calls = root / 'calls.jsonl'
        stub = '#!' + sys.executable + '\n' + r'''
import json, os, subprocess, sys
from pathlib import Path
command = Path(sys.argv[0]).name
args = sys.argv[1:]
keys = ('HOME', 'CFFIXED_USER_HOME', 'CODEX_HOME', 'TMPDIR', 'PI_APP_SCRATCH_ROOT',
        'PI_APP_BENCHMARK_STATE_ROOT', 'PI_APP_BENCHMARK_OUTPUT', 'BELLO_CONTEXT_DIAGNOSTICS')
record = dict(command=command, args=args, environment={key: os.environ.get(key) for key in keys})
status = 0
if command == 'belloperf':
    record['overrides'] = dict(args[index + 1].split('=', 1) for index, value in enumerate(args) if value == '--env')
    home = Path(record['overrides']['HOME'])
    record['homeExists'] = home.is_dir()
    record['codexExists'] = (home / '.codex').is_dir()
    record['preferencesExist'] = (home / 'Library/Preferences/com.belloware.PiApp.launchperf.plist').exists()
    if os.environ.get('PI_LAUNCH_DEFAULTS_PROBE'):
        trial = Path(args[args.index('--out') + 1]).stem
        probe = subprocess.run([os.environ['PI_LAUNCH_DEFAULTS_PROBE'], 'trial', trial],
                               env=dict(os.environ, **record['overrides']), capture_output=True, text=True, check=True)
        record['preferences'] = json.loads(probe.stdout)
    label = args[args.index('--label') + 1]
    print(label + ' trial {"windowMs": 1, "settledMs": 2}')
elif command == 'defaults':
    if os.environ.get('PI_LAUNCH_DEFAULTS_FAIL') == args[0]:
        status = 73
    elif os.environ.get('PI_LAUNCH_DEFAULTS_PROBE'):
        # Even a broken script/mutation must never reach a non-fixture domain.
        allowed = [['write', 'com.belloware.PiApp.launchperf', 'BelloLaunchFixtureReset', '-bool', 'true'],
                   ['delete', 'com.belloware.PiApp.launchperf']]
        if args not in allowed:
            raise SystemExit('Refusing non-fixture defaults invocation in the real probe')
        status = subprocess.run(['/usr/bin/defaults', *args], check=False).returncode
elif command == 'stat':
    print('fixture-mtime')
elif command == 'sysctl':
    print('{ 0.0 0.0 0.0 }')
with open(os.environ['PI_LAUNCH_CALLS'], 'a') as output:
    output.write(json.dumps(record) + '\n')
sys.exit(status)
'''
        for command in ('belloperf', 'stat', 'defaults', 'sysctl'):
            executable = binary / command
            executable.write_text(stub)
            executable.chmod(0o755)
        inherited = root / 'inherited'
        inherited.mkdir()
        self.environment = dict(os.environ, HOME=str(inherited), CFFIXED_USER_HOME=str(inherited),
                                CODEX_HOME=str(inherited / 'codex'), TMPDIR=str(inherited),
                                PI_APP_SCRATCH_ROOT=str(inherited), PI_LAUNCH_CALLS=str(self.calls),
                                PI_APP_BENCHMARK_STATE_ROOT=str(inherited / 'state'),
                                PI_APP_BENCHMARK_OUTPUT=str(inherited / 'benchmark.json'),
                                BELLO_CONTEXT_DIAGNOSTICS=str(inherited / 'context.json'),
                                PATH=str(binary) + os.pathsep + os.environ['PATH'],
                                BELLOPERF=str(binary / 'belloperf'), WARM='1', COLD='0')
        for key in ('PI_LAUNCH_DEFAULTS_PROBE', 'PI_LAUNCH_DEFAULTS_FAIL'):
            self.environment.pop(key, None)

    def run_benchmark(self, script=None, labels=('fixture',)):
        self.calls.unlink(missing_ok=True)
        return subprocess.run(['bash', str(script or ROOT / 'scripts/perf-launch.sh'),
                               str(self.fixture), str(self.output), *[label + '=' + str(self.app) for label in labels]],
                              cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=20)

    def records(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_launch_and_preference_checks_stay_in_the_fixture(self):
        result = self.run_benchmark()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = self.records()
        launches = [record for record in records if record['command'] == 'belloperf']
        self.assertEqual(len(launches), 2, 'one prime and one warm trial must execute')
        home, scratch = str(self.output / 'run/home'), str(self.output / 'run/tmp')
        expected = dict(HOME=home, CFFIXED_USER_HOME=home, CODEX_HOME=home + '/.codex',
                        TMPDIR=scratch, PI_APP_SCRATCH_ROOT=scratch)
        for launch in launches:
            with self.subTest(trial=Path(launch['args'][launch['args'].index('--out') + 1]).name):
                self.assertEqual(launch['environment'], dict(expected, PI_APP_BENCHMARK_STATE_ROOT=None,
                                 PI_APP_BENCHMARK_OUTPUT=None, BELLO_CONTEXT_DIAGNOSTICS=None),
                                 'the harness must also be isolated')
                self.assertEqual({key: launch['overrides'].get(key) for key in expected}, expected)
                self.assertEqual(launch['overrides']['PI_APP_LAUNCH_FIXTURE_VAULT'], str(self.output / 'run/vault.json'))
                self.assertTrue(launch['homeExists'])
                self.assertTrue(launch['codexExists'])
                self.assertFalse(launch['preferencesExist'], 'also reset the copied fixture plist')
        stats = [record['args'][-1] for record in records if record['command'] == 'stat']
        self.assertEqual(stats, [str(self.preferences), str(self.preferences)])
        defaults = [record for record in records if record['command'] == 'defaults']
        self.assertEqual([record['args'][:2] for record in defaults],
                         [['write', DOMAIN], ['delete', DOMAIN]] * 3, 'reset before each trial and after the run')
        for record in defaults:
            self.assertEqual(record['environment']['HOME'], home)
            self.assertEqual(record['environment']['CFFIXED_USER_HOME'], home)
            self.assertEqual(record['environment']['CODEX_HOME'], home + '/.codex')
        self.assertEqual(plistlib.loads(self.preferences.read_bytes()), {'fixture': 'untouched'})

    def test_non_fixture_domains_are_refused_before_access_or_launch(self):
        source = (ROOT / 'scripts/perf-launch.sh').read_text()
        script = self.root / 'wrong-domain.sh'
        for domain in ('com.belloware.PiApp', 'com.example.Other', DOMAIN + '.other', '-g', ''):
            with self.subTest(domain=domain):
                script.write_text(source.replace('DOMAIN=' + DOMAIN, 'DOMAIN=' + domain, 1))
                result = self.run_benchmark(script)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Refusing non-fixture preferences domain', result.stderr)
                self.assertEqual(self.records(), [], 'refuse before any preferences access or launch')

    def test_failed_preference_reset_stops_before_a_trial_launches(self):
        for operation in ('write', 'delete'):
            with self.subTest(operation=operation):
                self.environment['PI_LAUNCH_DEFAULTS_FAIL'] = operation
                result = self.run_benchmark()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(any(record['command'] == 'belloperf' for record in self.records()))

    def test_each_trial_resets_the_effective_fixture_defaults(self):
        # Run serially with launch benchmarks: this deliberately uses their
        # authorized fixture domain, never UserDefaults.standard or another suite.
        source, probe = self.root / 'preferences.swift', self.root / 'preferences'
        source.write_text(r'''
import Foundation
let domain = "com.belloware.PiApp.launchperf"
let defaults = UserDefaults(suiteName: domain)!
let key = "BelloLaunchFixtureTrial"
let before = defaults.persistentDomain(forName: domain)?[key] as? String
let operation = CommandLine.arguments[1]
if operation == "clear" {
    defaults.removePersistentDomain(forName: domain)
} else if operation == "trial" {
    defaults.setPersistentDomain([key: CommandLine.arguments[2]], forName: domain)
}
guard defaults.synchronize() else { exit(1) }
let after = defaults.persistentDomain(forName: domain)?[key] as? String
print(String(decoding: try JSONSerialization.data(withJSONObject:
    ["before": before as Any? ?? NSNull(), "after": after as Any? ?? NSNull()]), as: UTF8.self))
''')
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(self.root / 'modules'),
                        str(source), '-o', str(probe)], check=True, capture_output=True, text=True)
        home = self.output / 'run/home'
        home.mkdir(parents=True)
        environment = dict(self.environment, HOME=str(home), CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home / '.codex'))

        def preferences(operation):
            # The launcher removes its run folder; query under the same existing
            # home as a subsequent trial, rather than a missing home.
            home.mkdir(parents=True, exist_ok=True)
            result = subprocess.run([str(probe), operation], env=environment, check=True,
                                    capture_output=True, text=True, timeout=10)
            return json.loads(result.stdout)

        try:
            self.assertIsNone(preferences('clear')['after'])
            self.environment['PI_LAUNCH_DEFAULTS_PROBE'] = str(probe)
            result = self.run_benchmark(labels=('fixture', 'second'))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            trials = [record['preferences'] for record in self.records() if record['command'] == 'belloperf']
            self.assertEqual(len(trials), 4, 'two labels each execute a prime and a warm trial')
            self.assertEqual(len({trial['after'] for trial in trials}), 4, 'each process must persist its own marker')
            self.assertEqual([trial['before'] for trial in trials], [None] * 4,
                             'UserDefaults retained a previous trial: ' + json.dumps(trials))
            self.assertIsNone(preferences('inspect')['after'], 'the fixture domain is cleared after the run')
        finally:
            preferences('clear')


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
