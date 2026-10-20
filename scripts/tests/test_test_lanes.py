"""Lane selection is checked from source; these tests never launch an app."""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("test_lanes", ROOT / "scripts/test-lanes.py")
lanes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lanes)

# Independent of the detector: dropping a production pattern must break the
# repository audit as well as the generated one-API fixtures below.
WINDOW_APIS = (
    "makeKeyAndOrderFront", "makeKey", "makeMain", "becomeKey", "becomeMain",
    "resignKey", "resignMain", "orderFrontRegardless", "isKeyWindow", "isMainWindow",
    "makeFirstResponder", "becomeFirstResponder", "resignFirstResponder", "firstResponder",
    "sendEvent", "postEvent", "performKeyEquivalent", "showWindow", "beginSheet", "runModal",
)
AUDIT_FOCUS = re.compile(
    r"\.\s*(?:" + "|".join(WINDOW_APIS) + r")\b"
    r"|\b(?:NSApp|NSApplication\s*\.\s*shared)\s*\.\s*(?:activate|isActive|keyWindow|mainWindow|hide|unhide|deactivate)\b"
    r"|\.\s*activate\s*\(\s*(?:ignoringOtherApps|options)\s*:"
    r"|\b(?:CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition|CGEventPost|CGEventPostToPid)\s*\("
    r"|\.\s*(?:postToPid\s*\(|post\s*\(\s*(?:tap|toPid)\s*:)"
    r"|\bNSEvent\s*\.\s*mouseLocation\b"
    r"|\bSessionInspectorWindows\b|\.\s*(?:openInspector|showMessageDetail|popOut|bringForward|bringMainWindowForward)\s*\(")


class TestLaneTests(unittest.TestCase):
    def fixture_classes(self, files):
        with tempfile.TemporaryDirectory(prefix="pi-lanes-") as directory:
            root = Path(directory)
            for name, source in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(textwrap.dedent(source))
            with patch.object(lanes, "TESTS", root):
                return lanes.classes()

    def test_window_and_responder_apis_require_serial(self):
        for api in WINDOW_APIS:
            for separator in (".", "\n  . "):
                with self.subTest(api=api, separator=separator):
                    suffix = "" if api in ("isKeyWindow", "isMainWindow", "firstResponder") else "()"
                    self.assertIn("focus", lanes.reasons([], "window" + separator + api + suffix, "Debug"))

    def test_application_focus_and_event_injection_require_serial(self):
        for source in (
            "NSApp.activate()", "NSApplication.shared.activate(ignoringOtherApps: true)",
            "NSApp . isActive", "NSApplication . shared . keyWindow", "NSApp.mainWindow",
            "NSApp.hide(nil)", "NSApp.unhide(nil)", "NSApp.deactivate()",
            "application.activate (ignoringOtherApps: true)", "running.activate(options: [])",
            "event.post(tap: .cghidEventTap)", "event?.post (tap: .cgSessionEventTap)",
            "event.postToPid(pid)", "CGEventPost(.cghidEventTap, event)", "CGEventPostToPid(pid, event)",
            "CGWarpMouseCursorPosition(point)", "CGAssociateMouseAndMouseCursorPosition(true)",
            "let pointer = NSEvent.mouseLocation",
        ):
            with self.subTest(source=source):
                self.assertIn("focus", lanes.reasons([], source, "Debug"))

    def test_local_event_values_and_direct_view_handlers_remain_parallel(self):
        source = """
        let key = NSEvent.keyEvent(with: .keyDown, windowNumber: 0)
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel)
        view.keyDown(with: key); view.mouseDown(with: mouse); view.scrollWheel(with: wheel)
        NotificationCenter.default.post(name: .changed, object: view)
        host.activate(tab)
        """
        self.assertEqual(lanes.reasons([], source, "Debug"), [])

    def test_project_window_entry_points_require_serial(self):
        for source in ("model.openInspector(session: id)", "model.showMessageDetail(id, messageID: message)",
                       "tabs.popOut(tab)", "controller.bringForward()", "inspector.bringMainWindowForward()",
                       "SessionInspectorWindows.shared.show(model: model)"):
            with self.subTest(source=source):
                self.assertIn("focus", lanes.reasons([], source, "Debug"))

    def test_fixtures_nested_in_other_test_classes_are_followed(self):
        classes = self.fixture_classes({
            "Consumer.swift": "class Consumer: XCTestCase { func testView() { SharedTests.Window() } }",
            "Shared.swift": """
                class SharedTests: XCTestCase {
                    struct Window { init() { window.makeKeyAndOrderFront(nil) } }
                    func testWindow() { Window() }
                }
            """,
        })
        self.assertIn("focus", lanes.reasons(*classes["Consumer"], "Debug"))

    def test_shared_helpers_are_followed_transitively_without_unrelated_private_helpers(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class UsesFixture: XCTestCase { func testView() { Wrapper().mount() } }
                class LocalOnly: XCTestCase { func testValue() { LocalFixture() } }
                private struct LocalFixture { let value = 1 }
            """,
            "Wrapper.swift": """
                struct Wrapper { func mount() { WindowFixture().mount() } }
            """,
            "Window.swift": """
                class WindowFixture: NSObject { func mount() { openFixtureWindow() } }
                func openFixtureWindow() { window.makeKeyAndOrderFront(nil); Wrapper() }
                private struct LocalFixture { func mount() { window.makeKeyAndOrderFront(nil) } }
            """,
        })
        self.assertIn("focus", lanes.reasons(*classes["UsesFixture"], "Debug"))
        self.assertEqual(lanes.reasons(*classes["LocalOnly"], "Debug"), [])

    def test_base_and_extension_helpers_are_audited(self):
        classes = self.fixture_classes({
            "Base.swift": """
                class FixtureBase: XCTestCase { func mount() { SharedFixture().mount() } }
            """,
            "Child.swift": """
                class Child: FixtureBase { func testView() { mount() } }
                class Extended: XCTestCase { func testView() { mount() } }
            """,
            "Extension.swift": """
                extension Extended { func mount() { SharedFixture().mount() } }
            """,
            "Shared.swift": """
                struct SharedFixture { func mount() { window.makeKeyAndOrderFront(nil) } }
            """,
        })
        for name in ("Child", "Extended"):
            with self.subTest(name=name):
                self.assertIn("focus", lanes.reasons(*classes[name], "Debug"))

    def test_nested_test_sources_and_fixtures_are_audited(self):
        classes = self.fixture_classes({
            "Nested/Tests.swift": "class Nested: XCTestCase { func testView() { NestedFixture() } }",
            "Fixtures/Window.swift": "struct NestedFixture { init() { window.makeKeyAndOrderFront(nil) } }",
        })
        self.assertIn("Nested", classes)
        self.assertIn("focus", lanes.reasons(*classes["Nested"], "Debug"))

    def test_shared_extension_method_is_followed_only_when_referenced(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class UsesMethod: XCTestCase { func testView() { keyFixture() } }
                class Unrelated: XCTestCase { func testValue() { XCTAssertTrue(true) } }
            """,
            "Extension.swift": """
                extension XCTestCase {
                    func keyFixture() { openWindow() }
                }
                private func openWindow() { window.makeKeyAndOrderFront(nil) }
            """,
        })
        self.assertIn("focus", lanes.reasons(*classes["UsesMethod"], "Debug"))
        self.assertEqual(lanes.reasons(*classes["Unrelated"], "Debug"), [])

    def test_shared_helpers_do_not_widen_other_lane_rules(self):
        classes = self.fixture_classes({
            "Tests.swift": "class LocalOnly: XCTestCase { func testValue() { generatedRoot() } }",
            "Helpers.swift": """
                func generatedRoot() { return "/fixture" }
                func releaseBudget(_ value: Double) -> Double { value }
                func unrelatedTimingAssertion() { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1) }
            """,
        })
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                self.assertEqual(lanes.reasons(*classes["LocalOnly"], configuration), [])

    def test_classes_with_inherited_tests_are_not_left_out(self):
        classes = self.fixture_classes({"Tests.swift": """
            class Parent: XCTestCase { func testView() { window.makeKeyAndOrderFront(nil) } }
            class Child: Parent { }
        """})
        self.assertEqual(set(classes), {"Parent", "Child"})
        self.assertIn("focus", lanes.reasons(*classes["Child"], "Debug"))

    def test_known_native_fixture_users_have_a_focus_reason(self):
        classes = lanes.classes()
        for name in (
            "TranscriptGeometryCacheTests", "TranscriptTurnFoldTests", "TranscriptBugRegressionTests",
            "TranscriptRevealTests", "PiChartParityTests", "CaptureMacIntegrationTests",
            "SubagentDisplayGalleryTests", "CostLimitTests",
            "FileTabTests", "FileReviewStateTests", "PendingChatProjectTests", "MessageDetailTests",
            "InspectorFollowTests", "InspectorWindowControlTests", "MessageVersionTranscriptTests",
        ):
            with self.subTest(name=name):
                self.assertIn("focus", lanes.reasons(*classes[name], "Debug"))

    def test_no_parallel_native_class_uses_focus_apis(self):
        classes = lanes.classes()
        for configuration in ("Debug", "Release"):
            commands = {}
            for command in ("serial", "parallel"):
                output = subprocess.check_output([sys.executable, str(ROOT / "scripts/test-lanes.py"),
                                                  command, "--configuration", configuration], text=True)
                commands[command] = {line.split("/")[-1] for line in output.splitlines()}
            self.assertEqual(commands["serial"], commands["parallel"], "serial classes must be skipped by parallel clones")
            missed = sorted(name for name, (_, source) in classes.items()
                            if AUDIT_FOCUS.search(source) and name not in commands["parallel"])
            with self.subTest(configuration=configuration):
                self.assertEqual(missed, [], "parallel classes use focus APIs: " + ", ".join(missed))


if __name__ == "__main__":
    unittest.main()
