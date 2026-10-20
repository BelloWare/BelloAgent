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
    "resignKey", "resignMain", "orderFront", "orderFrontRegardless", "isKeyWindow", "isMainWindow",
    "showWindow", "runModal",
)
AUDIT_FOCUS = re.compile(
    r"\.\s*(?:" + "|".join(WINDOW_APIS) + r")\b"
    r"|\b(?:NSApp|NSApplication\s*\.\s*shared)\s*\.\s*(?:activate|isActive|keyWindow|mainWindow|hide|unhide|deactivate|sendEvent|postEvent)\b"
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

    def test_offscreen_responders_and_local_delivery_remain_parallel(self):
        source = """
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.makeFirstResponder(editor)
        XCTAssertTrue(window.firstResponder === editor)
        editor.becomeFirstResponder(); editor.resignFirstResponder()
        window.sendEvent(key)
        window.performKeyEquivalent(with: key)
        window.beginSheet(sheet)
        """
        self.assertEqual(lanes.reasons([], source, "Debug"), [])
        self.assertIn("focus", lanes.reasons([], source + "\nwindow.makeKeyAndOrderFront(nil)", "Debug"))

    def test_visible_nonkey_windows_require_serial(self):
        for api in ("orderFront", "orderFrontRegardless", "orderFrontStandardWindow"):
            with self.subTest(api=api):
                self.assertIn("focus", lanes.reasons([], "window." + api + "(nil)", "Debug"))

    def test_unrelated_shared_helpers_do_not_open_windows(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class Offscreen: XCTestCase { func testValue() { generatedRoot() } }
                class Visible: XCTestCase { func testView() { openWindow() } }
            """,
            "Helpers.swift": """
                func generatedRoot() { return "/fixture" }
                func openWindow() { window.makeKeyAndOrderFront(nil) }
            """,
        })
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_complete_helper_signatures_keep_their_bodies(self):
        signatures = (
            "func mount(\n    value: Int\n) async throws",
            "func mount<T>(\n    value: T\n) -> T\nwhere T: Equatable",
            '@available(macOS 14, *)\n@MainActor\nprivate func mount(\n    value: Int\n)',
            "func mount(\n    value: Int = makeValue({ nested(1, 2) }),\n    callback: () -> Void = { localHandler() }\n)",
        )
        for signature in signatures:
            with self.subTest(signature=signature):
                source = ("class Visible: XCTestCase {\n"
                          "    func testWindow() { mount(value: 1) }\n"
                          + textwrap.indent(signature, "    ")
                          + "\n    {\n        openWindow()\n    }\n}\n"
                          "func openWindow() { NSApp.activate(ignoringOtherApps: true) }\n")
                classes = self.fixture_classes({"Tests.swift": source})
                self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_signature_closures_are_not_the_declaration_body(self):
        classes = self.fixture_classes({"Tests.swift": """
            @MainActor
            class Helpers
            {
                @available(macOS 14, *)
                static func data<T>(
                    value: T = { nested({ 1 }) }()
                ) -> T where T: Equatable
                { return value }
                static func mount(
                    callback: () -> Void = {}
                ) { window.makeKeyAndOrderFront(nil) }
            }
            class Offscreen: XCTestCase { func testValue() { Helpers.data() } }
            class Visible: XCTestCase { func testWindow() { Helpers.mount() } }
        """})
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_declaration_boundaries_include_attributes_generics_and_defaults(self):
        source = textwrap.dedent("""
            @available(
                macOS 14, *
            )
            @MainActor
            final class Fixture<
                T: Equatable
            >: NSObject where T: Sendable
            {
                @MainActor private func mount<U>(
                    value: U = makeValue({ nested({ 1 }) }),
                    callback: () -> Void = { window.makeKeyAndOrderFront(nil) }
                ) async throws -> U
                where U: Equatable, U: Sendable
                {
                    openWindow()
                    return value
                }
                let values: Dictionary<
                    String, T
                > = [:]
                func data() { return 1 }
            }
        """)
        declaration, = lanes.declarations(source)
        self.assertEqual((declaration.kind, declaration.name, declaration.inherits),
                         ("class", "Fixture", ["NSObject"]))
        self.assertTrue(declaration.text.startswith("@available("))
        mount, values, data = lanes.declarations(declaration.body)
        self.assertEqual([mount.name, values.name, data.name], ["mount", "values", "data"])
        self.assertIn("callback: () -> Void", mount.header)
        self.assertIn("where U: Equatable", mount.header)
        self.assertEqual(mount.body.strip(), "openWindow()\n        return value")
        self.assertIn("Dictionary<", values.text)
        self.assertIn("> = [:]", values.text)
        self.assertNotIn("func data", values.text)

    def test_multiline_inheritance_and_attributes_keep_test_declarations(self):
        classes = self.fixture_classes({"Tests.swift": """
            @available(
                macOS 14, *
            )
            @MainActor
            final class Visible:
                XCTestCase,
                FixtureProtocol
            {
                func testWindow(
                ) { fixture() }
            }
            func fixture(
                callback: () -> Void = { nested({ 1 }) }
            )
            { NSApp.activate() }
            class Offscreen: XCTestCase {
                func testValue() { data() }
            }
            func data(
                value: Int = 1
            ) -> Int { value }
        """})
        self.assertIn("Visible", classes)
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])

    def test_string_properties_and_protocol_requirements_do_not_eat_neighbors(self):
        classes = self.fixture_classes({"Tests.swift": """
            struct Helpers {
                static let label = "generated"
                static func data() -> Int { 1 }
                static func window() { NSApp.activate() }
            }
            protocol Fixture {
                func data(
                    value: Int
                ) -> Int
                func mount()
            }
            class Offscreen: XCTestCase { func testValue() { Helpers.data() } }
            class Visible: XCTestCase { func testWindow() { Helpers.window() } }
        """})
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_multiline_property_bodies_and_initializers_keep_focus_calls(self):
        for property in (
            "var fixture: NSWindow\n{ window.makeKeyAndOrderFront(nil); return window }",
            "let fixture = makeFixture()\n{ window.makeKeyAndOrderFront(nil) }",
            "let fixture = makeFixture()\n.configure { window.makeKeyAndOrderFront(nil) }",
        ):
            with self.subTest(property=property):
                source = ("class Visible: XCTestCase {\n"
                          + textwrap.indent(property, "    ")
                          + "\n    func testWindow() { _ = fixture }\n}\n")
                classes = self.fixture_classes({"Tests.swift": source})
                self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_shared_type_members_do_not_pull_in_other_members_or_tests(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class Offscreen: XCTestCase { func testValue() { SharedTests.data() } }
                class Visible: XCTestCase { func testView() { SharedTests.Window() } }
            """,
            "Shared.swift": """
                class SharedTests: XCTestCase {
                    static func data() { return seed() }
                    private static func seed() { return 1 }
                    struct Window { init() { window.makeKeyAndOrderFront(nil) } }
                    func testWindow() { Window() }
                }
            """,
        })
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_comments_and_string_contents_are_not_focus_calls_or_dependencies(self):
        classes = self.fixture_classes({
            "Tests.swift": r'''
                class Offscreen: XCTestCase {
                    func testValue() {
                        // VisibleFixture() uses window.makeKeyAndOrderFront(nil).
                        let example = "VisibleFixture().window.makeKeyAndOrderFront(nil)"
                        XCTAssertTrue(example.contains("makeKeyAndOrderFront"))
                    }
                }
                class Visible: XCTestCase {
                    func testValue() { let value = "\(VisibleFixture())" }
                }
            ''',
            "Fixture.swift": "struct VisibleFixture { init() { window.makeKeyAndOrderFront(nil) } }",
        })
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_popouts_respect_explicit_offscreen_hosts_and_factories(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class Offscreen: XCTestCase {
                    private func host() -> TabHost {
                        let host = TabHost()
                        host.showsWindows = false
                        return host
                    }
                    func testFactory() { let first = host(); first.popOut(tab) }
                    func testLocal() { model.tabs.showsWindows = false; model.tabs.popOut(tab) }
                }
                class Visible: XCTestCase { func testView() { let host = TabHost(); host.popOut(tab) } }
                class Reenabled: XCTestCase {
                    func testView() { host.showsWindows = false; host.showsWindows = true; host.popOut(tab) }
                }
                class Conditional: XCTestCase {
                    func testView() { if flag { host.showsWindows = false }; host.popOut(tab) }
                }
                class ConditionalReset: XCTestCase {
                    func testView() { host.showsWindows = false; if flag { host.showsWindows = true }; host.popOut(tab) }
                }
                class UnknownReset: XCTestCase {
                    func testView() { host.showsWindows = false; host.showsWindows = flag; host.popOut(tab) }
                }
                class Expression: XCTestCase {
                    func testView() { host.showsWindows = false || flag; host.popOut(tab) }
                }
            """,
        })
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        for name in ("Visible", "Reenabled", "Conditional", "ConditionalReset", "UnknownReset", "Expression"):
            with self.subTest(name=name):
                self.assertIn("focus", lanes.reasons(*classes[name], "Debug"))

    def test_only_called_base_fixtures_and_lifecycle_hooks_contend(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class Base: XCTestCase {
                    func mount() { window.makeKeyAndOrderFront(nil) }
                    func data() { return 1 }
                }
                class Offscreen: Base { func testValue() { data() } }
                class Visible: Base { func testView() { self.mount() } }
                class SetUp: XCTestCase {
                    override func setUp() { window.orderFront(nil) }
                    func testValue() { XCTAssertTrue(true) }
                }
            """,
        })
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        for name in ("Visible", "SetUp"):
            self.assertIn("focus", lanes.reasons(*classes[name], "Debug"))

    def test_qualified_inherited_data_builder_does_not_import_visible_tests(self):
        classes = self.fixture_classes({
            "Tests.swift": """
                class Base: XCTestCase {
                    static func data() { return 1 }
                    struct Window { init() { window.makeKeyAndOrderFront(nil) } }
                }
                class Derived: Base { func testView() { Window() } }
                class Offscreen: XCTestCase { func testValue() { Derived.data() } }
                class Visible: XCTestCase { func testView() { Derived.Window() } }
            """,
        })
        self.assertEqual(lanes.reasons(*classes["Offscreen"], "Debug"), [])
        self.assertIn("focus", lanes.reasons(*classes["Visible"], "Debug"))

    def test_window_visibility_and_focus_apis_require_serial(self):
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
            "NSApp.sendEvent(key)", "NSApp.postEvent(mouse, atStart: false)",
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
            "FileReviewStateTests", "PendingChatProjectTests", "MessageDetailTests",
            "InspectorFollowTests", "InspectorWindowControlTests", "MessageVersionTranscriptTests",
            "TranscriptStreamingScrollTests", "TranscriptRowGalleryTests",
        ):
            with self.subTest(name=name):
                self.assertIn("focus", lanes.reasons(*classes[name], "Debug"))
        for name in ("AccountingScaleTests", "FileTabTests", "TabHostTests", "WorkspaceTests",
                     "TerminalCursorAlignmentTests", "MarkdownStreamingCorrectnessTests"):
            with self.subTest(offscreen=name):
                self.assertNotIn("focus", lanes.reasons(*classes[name], "Debug"))

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
                            if AUDIT_FOCUS.search(source.focus) and name not in commands["parallel"])
            with self.subTest(configuration=configuration):
                self.assertEqual(missed, [], "parallel classes use focus APIs: " + ", ".join(missed))


if __name__ == "__main__":
    unittest.main()
