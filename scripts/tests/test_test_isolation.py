"""Test host configuration and guard probes; never open a real preferences domain."""
import json
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
TEST_ID = "com.belloware.PiAppTests.Host"


class TestHostConfigurationTests(unittest.TestCase):
    def test_every_configuration_uses_a_separate_host(self):
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-", str(ROOT / "PiApp.xcodeproj/project.pbxproj")]))
        objects = project["objects"]
        targets = {v["name"]: v for v in objects.values() if v.get("isa") == "PBXNativeTarget"}
        self.assertIn("PiAppTestHost", targets)
        def configs(name):
            return [objects[key]["buildSettings"] for key in
                    objects[targets[name]["buildConfigurationList"]]["buildConfigurations"]]
        for settings in configs("PiApp"):
            self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.belloware.PiApp")
            self.assertNotIn("PI_TEST_HOST", str(settings))
        for settings in configs("PiAppTestHost"):
            self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], TEST_ID)
            self.assertIn("PI_TEST_HOST", settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
        for settings in configs("PiAppTests"):
            self.assertIn("Bello Agent Tests.app", settings["TEST_HOST"])
        def sources(name):
            phases = [objects[key] for key in targets[name]["buildPhases"]]
            return [objects[objects[key]["fileRef"]]["path"] for phase in phases
                    if phase["isa"] == "PBXSourcesBuildPhase" for key in phase["files"]]
        self.assertNotIn("TestIsolationGuard.m", sources("PiApp"))
        for target in ("PiAppTestHost", "PiAppTests"):
            self.assertIn("TestIsolationGuard.m", sources(target))
        scheme = ET.parse(ROOT / "PiApp.xcodeproj/xcshareddata/xcschemes/PiApp.xcscheme")
        env = {v.get("key"): v.get("value") for v in scheme.findall(".//TestAction/EnvironmentVariables/EnvironmentVariable")}
        self.assertEqual(env["CFFIXED_USER_HOME"], "$(PROJECT_TEMP_DIR)/PiAppTests-Home")
        self.assertEqual(scheme.find(".//TestAction/MacroExpansion/BuildableReference").get("BlueprintName"), "PiAppTestHost")
        entries = {entry.find("BuildableReference").get("BlueprintName"): entry
                   for entry in scheme.findall(".//BuildActionEntry")}
        self.assertEqual(entries["PiApp"].get("buildForTesting"), "NO")
        self.assertEqual(entries["PiApp"].get("buildForArchiving"), "YES")
        self.assertEqual(entries["PiAppTestHost"].get("buildForTesting"), "YES")
        self.assertEqual(entries["PiAppTestHost"].get("buildForRunning"), "NO")
        self.assertEqual(entries["PiAppTestHost"].get("buildForArchiving"), "NO")


class TestIsolationGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probe = Path(cls.temp.name) / "guard"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Werror", "-DPI_TEST_ISOLATION_PROBE=1",
                        "-framework", "Foundation", str(ROOT / "apps/macos/TestSupport/TestIsolationGuard.m"),
                        "-o", str(cls.probe)], check=True)

    def probe_result(self, identifier, effective, real, fixed):
        return subprocess.run([str(self.probe), identifier, str(effective), str(real), str(fixed)],
                              text=True, capture_output=True)

    def test_child_environments_keep_fixed_home_and_codex_root(self):
        root = Path(self.temp.name)
        home = root / "child-home"
        home.mkdir()
        source = root / "child-home.m"
        source.write_text('#define PI_TEST_ISOLATION_PROBE 1\n#define main policyMain\n#import "' +
                          str(ROOT / "apps/macos/TestSupport/TestIsolationGuard.m") + '"\n#undef main\n' + r'''
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2) {
            for (NSString *key in @[@"HOME", @"CFFIXED_USER_HOME", @"CODEX_HOME", @"PI_FIXTURE_FLAG"]) {
                puts([NSProcessInfo.processInfo.environment[key] ?: @"-" UTF8String]);
            }
            puts(NSHomeDirectory().UTF8String);
            return 0;
        }
        (void)NSProcessInfo.processInfo.environment;
        installTestHomes(@(argv[1]));
        installTestHomes(@(argv[1])); // host and test bundle install the same policy
        NSTask *child = [NSTask new];
        child.executableURL = [NSURL fileURLWithPath:@(argv[0])]; child.arguments = @[@"child"];
        NSString *mode = @(argv[2]);
        if ([mode isEqualToString:@"explicit"]) child.environment = @{@"HOME": @"/synthetic/inherited", @"CFFIXED_USER_HOME": @"/synthetic/inherited", @"CODEX_HOME": @"/synthetic/codex", @"PI_FIXTURE_FLAG": @"retained"};
        if ([mode isEqualToString:@"empty"]) child.environment = @{};
        if ([mode isEqualToString:@"nil"]) child.environment = nil;
        NSPipe *output = [NSPipe pipe]; child.standardOutput = output;
        if (![child launchAndReturnError:nil]) return 1;
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        [child waitUntilExit]; fwrite(data.bytes, 1, data.length, stdout);
        return child.terminationStatus;
    }
}
''')
        probe = root / "child-home-probe"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Werror", "-framework", "Foundation",
                        str(source), "-o", str(probe)], check=True)
        for mode, flag in [("explicit", "retained"), ("empty", "-"), ("nil", "parent"), ("inherited", "parent")]:
            with self.subTest(mode=mode):
                result = subprocess.run([str(probe), str(home), mode], text=True, capture_output=True,
                                        env=dict(os.environ, HOME="/synthetic/parent", CFFIXED_USER_HOME="/synthetic/parent",
                                                 CODEX_HOME="/synthetic/parent-codex", PI_FIXTURE_FLAG="parent"))
                self.assertEqual(result.returncode, 0, result.stderr)
                fixed = str(home.resolve())
                values = result.stdout.splitlines()
                self.assertEqual(len(values), 5)
                for index in (0, 1, 2, 4):
                    values[index] = str(Path(values[index]).resolve())
                self.assertEqual(values, [fixed, fixed, fixed + "/.codex", flag, fixed])

    def test_real_domain_is_rejected_without_opening_it(self):
        # These are synthetic path arguments, not the user's home or plist.
        for home in ["/fixture/owner", "/fixture/scratch"]:
            result = self.probe_result("com.belloware.PiApp", home, "/fixture/owner", home)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to run PiAppTests", result.stderr)
            self.assertIn("real preferences domain", result.stderr)

    def test_missing_or_ineffective_isolation_is_rejected(self):
        for effective, fixed in [("/fixture/owner", ""), ("/fixture/owner", "/fixture/scratch"),
                                 ("/fixture/scratch", ""), ("/fixture/owner/../owner", "/fixture/owner")]:
            with self.subTest(effective=effective, fixed=fixed):
                self.assertNotEqual(self.probe_result(TEST_ID, effective, "/fixture/owner", fixed).returncode, 0)

    def test_separate_host_and_home_are_accepted_and_symlink_aliases_rejected(self):
        base = Path(self.temp.name)
        real, scratch = base / "owner", base / "scratch"
        real.mkdir(exist_ok=True); scratch.mkdir(exist_ok=True)
        alias = base / "alias"
        alias.symlink_to(real)
        self.assertEqual(self.probe_result(TEST_ID, scratch, real, scratch).returncode, 0)
        self.assertNotEqual(self.probe_result(TEST_ID, alias, real, alias).returncode, 0)
        (real / "Library").mkdir()
        (scratch / "Library").symlink_to(real / "Library")
        self.assertNotEqual(self.probe_result(TEST_ID, scratch, real, scratch).returncode, 0)


class StoredTestRunIsolationTests(unittest.TestCase):
    def test_perf_entrypoint_stops_before_xcodebuild_for_old_products(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            products = root / "dd/Build/Products"
            contents = products / "Bello Agent.app/Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.belloware.PiApp"}))
            (products / "PiApp.xctestrun").write_bytes(plistlib.dumps({"PiAppTests": {
                "TestHostPath": "__TESTROOT__/Bello Agent.app"}}))
            binary = root / "bin"
            binary.mkdir()
            called = root / "called"
            stub = binary / "xcodebuild"
            stub.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath(" + repr(str(called)) + ").touch()\n")
            stub.chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "scripts/perf-transcript.sh"), str(root / "dd"),
                                     str(root / "out"), "1", "0", "100000"],
                                    env=dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"], ONLY="baseline"),
                                    text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing unsafe test products", result.stderr)
            self.assertFalse(called.exists())

    def test_perf_rejects_old_host_or_missing_home_and_accepts_isolated_products(self):
        spec = importlib.util.spec_from_file_location("check_test_host", ROOT / "scripts/check-test-host.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            contents = root / "Bello Agent Tests.app/Contents"
            contents.mkdir(parents=True)
            info = contents / "Info.plist"
            manifest = root / "PiApp.xctestrun"
            target = {"TestHostPath": "__TESTROOT__/Bello Agent Tests.app",
                      "EnvironmentVariables": {"CFFIXED_USER_HOME": str(root / "home")}}
            def write(identifier):
                info.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
                manifest.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [target]}]}))
            write("com.belloware.PiApp")
            with self.assertRaisesRegex(ValueError, "test host must be"):
                module.validate(manifest)
            write(TEST_ID)
            module.validate(manifest)
            target["TestHostPath"] += "/Contents/MacOS/Bello Agent Tests"
            write(TEST_ID)
            module.validate(manifest)
            target["EnvironmentVariables"] = {}
            write(TEST_ID)
            with self.assertRaisesRegex(ValueError, "isolated CFFIXED_USER_HOME"):
                module.validate(manifest)


class TestPasteboardIsolationTests(unittest.TestCase):
    def test_shared_pasteboards_are_private_before_any_content_access(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "pasteboards.m"
            source.write_text('#define PI_TEST_PASTEBOARD_PROBE 1\n#import "' +
                              str(ROOT / "apps/macos/TestSupport/TestIsolationGuard.m") + '"\n' + r'''
int main(void) {
    @autoreleasepool {
        installTestPasteboards();
        installTestPasteboards(); // host and test bundle both install it
        NSMutableArray<NSPasteboard *> *boards = [NSMutableArray array];
        for (NSString *name in @[NSPasteboardNameGeneral, NSPasteboardNameDrag,
                                NSPasteboardNameFind, NSPasteboardNameFont, NSPasteboardNameRuler]) {
            NSPasteboard *board = [NSPasteboard pasteboardWithName:name];
            // Fail without reading or writing any content if routing is broken.
            if (![board.name hasPrefix:@"com.belloware.PiAppTests.pasteboard."]) return 1;
            [boards addObject:board];
        }
        if (![[NSPasteboard generalPasteboard].name isEqualToString:boards[0].name]) return 2;
        if ([NSSet setWithArray:[boards valueForKey:@"name"]].count != boards.count) return 3;
        NSString *custom = [@"bello-pasteboard-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSPasteboard *fixture = [NSPasteboard pasteboardWithName:custom];
        if (![fixture.name isEqualToString:custom]) return 4;
        [boards addObject:fixture];
        for (NSPasteboard *board in boards) {
            [board clearContents];
            [board setString:@"generated fixture" forType:NSPasteboardTypeString];
            if (![[board stringForType:NSPasteboardTypeString] isEqualToString:@"generated fixture"]) return 5;
            [board releaseGlobally];
        }
        return 0;
    }
}
''')
            probe = root / "pasteboards"
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Werror", "-framework", "AppKit",
                            str(source), "-o", str(probe)], check=True)
            result = subprocess.run([str(probe)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
