"""XCTest keeps every failure a test records; these tests never launch an app.

XCTest (Xcode 16.1) drops an issue that reaches it while it records another
one, which happens to assertions made off the main thread (HelperTestCase.swift
explains how). The helper's test classes derive from HelperTestCase, and the
app's test bundle links IssueRecordingGuard.m; both record such an issue once
the outer one is done. Each test here builds a small XCTest bundle that records
an issue inside another on purpose, runs it with xctest and reads the counts.
"""
import json
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER_BASE = ROOT / "packages/swift-host/Tests/PiAgentCoreTests/HelperTestCase.swift"
APP_GUARD = ROOT / "apps/macos/TestSupport/IssueRecordingGuard.m"

PROBE = r'''
import XCTest

final class Delivery: NSObject, XCTestObservation {
    static let shared = Delivery()
    var hooks: [String: () -> Void] = [:]
    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) { hooks.removeValue(forKey: testCase.name)?() }
}

/// Records A on the main thread. While XCTest delivers A, another thread
/// records B and waits until XCTest has queued it, so XCTest records B from
/// inside its recording of A, as a race does for an assertion made after an
/// `await`. Plain XCTest counts 1 failure, not 2.
func recordNestedIssues(_ test: XCTestCase) {
    XCTestObservationCenter.shared.addTestObserver(Delivery.shared)
    Delivery.shared.hooks[test.name] = {
        let queued = DispatchSemaphore(value: 0)
        Thread.detachNewThread { XCTFail("B, from another thread"); queued.signal() }
        queued.wait()
    }
    XCTFail("A, from the main thread")
    XCTestObservationCenter.shared.removeTestObserver(Delivery.shared)
}

final class PlainProbe: XCTestCase {
    func testNestedIssues() { recordNestedIssues(self) }
}
'''

HELPER_PROBE = '''
import XCTest

final class HelperProbe: HelperTestCase {
    func testNestedIssues() { recordNestedIssues(self) }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "XCTest bundles run on macOS")
class NestedIssueRecordingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="pi-issue-recording-")
        cls.addClassCleanup(cls.temp.cleanup)
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        cls.frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
        cls.lib = developer / "Platforms/MacOSX.platform/Developer/usr/lib"
        cls.sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        cls.target = platform.machine() + "-apple-macos13.0"

    def failures(self, name, swift=(), objc=()):
        """Builds the probe with `swift` and `objc` sources into a bundle, runs
        it, and returns each probe class's failure count and the output."""
        work = Path(self.temp.name) / name
        work.mkdir()
        sources = [work / "Probe.swift"]
        sources[0].write_text(PROBE)
        for index, source in enumerate(swift):
            sources.append(work / f"Extra{index}.swift")
            sources[-1].write_text(source)
        for source in objc:
            sources.append(work / (source.stem + ".o"))
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Werror", "-target", self.target,
                            "-isysroot", self.sdk, "-c", str(source), "-o", str(sources[-1])], check=True)
        bundle = work / (name + ".xctest")
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": name, "CFBundleIdentifier": "com.belloware.tests." + name,
            "CFBundlePackageType": "BNDL"}))
        build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", self.target, "-sdk", self.sdk,
                                "-F", str(self.frameworks), "-I", str(self.lib), "-L", str(self.lib),
                                "-Xlinker", "-rpath", "-Xlinker", str(self.frameworks),
                                "-Xlinker", "-rpath", "-Xlinker", str(self.lib),
                                "-emit-library", "-module-name", name, *map(str, sources),
                                "-o", str(bundle / "Contents/MacOS" / name)], text=True, capture_output=True)
        self.assertEqual(build.returncode, 0, build.stderr)
        run = subprocess.run(["xcrun", "xctest", str(bundle)], text=True, capture_output=True, timeout=120)
        output = run.stdout + run.stderr
        counts = {match.group(1): int(match.group(2)) for match in re.finditer(
            r"Test Suite '(\w+)' (?:passed|failed) at [^\n]*\n\s+Executed 1 test, with (\d+) failures?", output)}
        return counts, output

    def test_helper_test_case_records_an_issue_raised_while_another_is_recorded(self):
        counts, output = self.failures("HelperIssues", swift=[HELPER_BASE.read_text(), HELPER_PROBE])
        self.assertEqual(counts.get("PlainProbe"), 1, "XCTest no longer drops the nested issue, so this probe no "
                         "longer exercises HelperTestCase; if XCTest has fixed it, retire HelperTestCase and "
                         "IssueRecordingGuard.m with this file.\n" + output)
        self.assertEqual(counts.get("HelperProbe"), 2, output)

    def test_app_test_bundle_guard_records_an_issue_raised_while_another_is_recorded(self):
        counts, output = self.failures("AppIssues", objc=[APP_GUARD])
        self.assertEqual(counts.get("PlainProbe"), 2, output)

    def test_app_guard_is_built_into_the_test_bundle_only(self):
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-", str(ROOT / "PiApp.xcodeproj/project.pbxproj")]))
        objects = project["objects"]
        targets = {value["name"]: value for value in objects.values() if value.get("isa") == "PBXNativeTarget"}

        def sources(name):
            phases = [objects[key] for key in targets[name]["buildPhases"]]
            return [objects[objects[key]["fileRef"]]["path"] for phase in phases
                    if phase["isa"] == "PBXSourcesBuildPhase" for key in phase["files"]]
        for target, linked in (("PiAppTests", True), ("PiApp", False), ("PiAppTestHost", False)):
            self.assertEqual(APP_GUARD.name in sources(target), linked, f"{APP_GUARD.name} in {target}")


if __name__ == "__main__":
    unittest.main()
