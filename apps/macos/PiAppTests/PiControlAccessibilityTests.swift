import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import PiApp

/// What VoiceOver is told about the shared Pi controls: names that say which
/// setting or item a control acts on, current values and bounds, which tab or
/// row is selected, and whether a control is enabled.
///
/// The tree is read as VoiceOver reads it: through the accessibility client
/// API (`AXUIElement`), against this process. Asked of its own process the
/// API answers in place, on the calling thread, so it is asked on the main
/// thread, where AppKit answers VoiceOver. It sees what VoiceOver does where
/// the in-process objects differ: an AppKit button inside SwiftUI keeps its
/// name on the button, not on the cell those objects list. SwiftUI builds its
/// elements only while assistive access is on; `HostedAccessibility` turns it
/// on for one test and off after, so the rest of the host is left as it was.
@MainActor final class PiControlAccessibilityTests: XCTestCase {
    private var assistive = false
    override func setUp() async throws { assistive = HostedAccessibility.begin() }
    override func tearDown() async throws { HostedAccessibility.end(restoring: assistive) }

    func testTabsMarkTheChosenTabSelectedAndNameTheirRow() async throws {
        let choice = Choice(2)
        let window = try await hosted(TabsFixture(choice: choice, name: "Commit scope"))
        let row = try await AXClient.find(in: window) { $0.label == "Commit scope" }
        XCTAssertEqual(row.role, "AXGroup")
        XCTAssertEqual(row.value, "", "the chosen tab says it is chosen; the group does not repeat it")
        XCTAssertEqual(row.children.map(\.label), ["One", "Two"], "each tab stays its own element")
        XCTAssertEqual(row.children.map(\.role), ["AXButton", "AXButton"])
        XCTAssertEqual(row.children.map(\.selected), [false, true])
        choice.value = 1
        _ = try await AXClient.find(in: window, "the chosen tab follows the selection") { $0.label == "Commit scope" && $0.children.map(\.selected) == [true, false] }
    }

    func testAnUnnamedTabRowAddsNoGroup() async throws {
        let window = try await hosted(TabsFixture(choice: Choice(1), name: nil))
        let one = try await AXClient.find(in: window) { $0.label == "One" }
        let content = try await AXClient.content(of: window)
        XCTAssertEqual(content.map(\.role), ["AXButton", "AXButton"], "the tabs sit directly in their container, as before")
        XCTAssertEqual(content.map(\.label), ["One", "Two"])
        XCTAssertTrue(one.selected)
        XCTAssertEqual(content.map(\.selected), [true, false])
    }

    func testStepperButtonsNameTheirSettingWithItsValueAndBounds() async throws {
        let window = try await hosted(StepperFixture(value: 10))
        _ = try await AXClient.find(in: window) { $0.label == "Decrease Idle helper grace" }
        let content = try await AXClient.content(of: window)
        XCTAssertEqual(content.map(\.label), ["Decrease Idle helper grace", "Increase Idle helper grace"],
                       "the buttons carry the value; the text is not read again")
        let decrease = content[0], increase = content[1]
        XCTAssertEqual(decrease.value, "10 seconds"); XCTAssertEqual(increase.value, "10 seconds")
        XCTAssertEqual(decrease.help, "From 10 to 600 seconds, in steps of 10")
        XCTAssertFalse(decrease.enabled, "at its lower bound")
        XCTAssertTrue(increase.enabled)
        let pressed = AXClient.press(increase)
        XCTAssertTrue(pressed)
        let after = try await AXClient.find(in: window, "the value follows a press") { $0.label == "Decrease Idle helper grace" && $0.value == "20 seconds" }
        XCTAssertTrue(after.enabled, "off its lower bound")
    }

    func testADropdownIsNamedForWhatItChoosesAndReadsTheChoiceAsItsValue() async throws {
        let window = try await hosted(DropdownFixture())
        let button = try await AXClient.find(in: window) { $0.label == "Webhook method" }
        XCTAssertEqual(button.role, "AXButton")
        XCTAssertEqual(button.value, "PUT")
        let content = try await AXClient.content(of: window)
        XCTAssertEqual(content.count, 1, "one element: \(content.map(\.label))")
    }

    func testASelectableRowIsMarkedSelectedAndKeepsItsOwnControls() async throws {
        let window = try await hosted(RowsFixture())
        let selected = try await AXClient.find(in: window) { $0.label == "claude" }
        let other = try await AXClient.find(in: window) { $0.label == "gpt-5" }
        XCTAssertEqual(selected.role, "AXButton")
        XCTAssertTrue(selected.selected); XCTAssertFalse(other.selected)
    }

    func testAnIconButtonCanSayWhichItemItActsOn() async throws {
        let window = try await hosted(PiIconButton(symbol: "xmark", label: "Remove", spokenLabel: "Remove follow-up 2") {})
        let button = try await AXClient.find(in: window) { $0.label == "Remove follow-up 2" }
        XCTAssertEqual(button.role, "AXButton")
        XCTAssertEqual(button.help, "Remove", "the tooltip stays short")
    }

    // MARK: Fixtures

    private func hosted<V: View>(_ view: V) async throws -> NSWindow {
        try await hostedWindow(view.padding(20).environment(\.piReduceMotion, true), width: 520, height: 260)
    }
}

@MainActor final class Choice: ObservableObject {
    @Published var value: Int
    init(_ value: Int) { self.value = value }
}
private struct TabsFixture: View {
    @ObservedObject var choice: Choice
    let name: String?
    var body: some View { PiTabs(selection: $choice.value, items: [(1, "One"), (2, "Two")], accessibilityName: name) }
}
private struct StepperFixture: View {
    @State var value: Int
    var body: some View { PiStepper(name: "Idle helper grace", unit: "seconds", value: $value, range: 10...600, step: 10).frame(width: 260) }
}
private struct DropdownFixture: View {
    @State var method = "PUT"
    var body: some View { PiDropdown(selection: $method, items: [("POST", "POST"), ("PUT", "PUT")], compact: true, accessibilityName: "Webhook method") }
}
private struct RowsFixture: View {
    var body: some View {
        VStack(spacing: 1) {
            PiSelectableRow(selected: false, action: {}) { Text("gpt-5") }
            PiSelectableRow(selected: true, action: {}) { Text("claude") }
        }.frame(width: 240)
    }
}

/// Assistive access for the hosting views of one test: on while it runs,
/// then back to what it was.
@MainActor enum HostedAccessibility {
    private static let attribute = "AXEnhancedUserInterface"
    /// Turns it on; returns what it was.
    static func begin() -> Bool {
        let was = (NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        set(true)
        return was
    }
    static func end(restoring was: Bool) { set(was) }
    private static func set(_ on: Bool) {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: on), with: attribute)
    }
}

extension XCTestCase {
    /// `view` in a window of its own, front but not key, with a title the
    /// accessibility client finds it by; taken down after the test.
    @MainActor func hostedWindow<V: View>(_ view: V, width: CGFloat, height: CGFloat) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ax-" + UUID().uuidString
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil }
        _ = try await AXClient.content(of: window)
        return window
    }
}

/// One accessibility element as an assistive client is given it.
struct AXNode: @unchecked Sendable {
    /// What VoiceOver speaks as its name: the description, else the title.
    let role: String, label: String, value: String, help: String
    let selected: Bool, enabled: Bool
    /// Where it is, in screen coordinates.
    let frame: CGRect
    let children: [AXNode]
    let element: AXUIElement

    init(_ element: AXUIElement, depth: Int = 0) {
        self.element = element
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        role = attribute(kAXRoleAttribute) as? String ?? ""
        let description = attribute(kAXDescriptionAttribute) as? String ?? ""
        label = description.isEmpty ? (attribute(kAXTitleAttribute) as? String ?? "") : description
        value = attribute(kAXValueAttribute).map { "\($0)" } ?? ""
        help = attribute(kAXHelpAttribute) as? String ?? ""
        selected = (attribute(kAXSelectedAttribute) as? Bool) ?? false
        enabled = (attribute(kAXEnabledAttribute) as? Bool) ?? false
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
        if let value = attribute(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        frame = CGRect(origin: origin, size: size)
        children = depth > 40 ? [] : ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { AXNode($0, depth: depth + 1) }
    }
    /// What VoiceOver reads first: a text's value, any other element's name.
    var spoken: String { role == "AXStaticText" && label.isEmpty ? value : label }
    /// Every element under these, depth first.
    static func flat(_ nodes: [AXNode]) -> [AXNode] { nodes.flatMap { [$0] + flat($0.children) } }
}

/// The client side: this process's windows as VoiceOver reads them, asked on
/// the main thread (the API answers its own process in place).
enum AXClient {
    /// The window's own elements: its content view's children.
    @MainActor static func content(of window: NSWindow) async throws -> [AXNode] {
        let title = window.title, pid = getpid()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let nodes = { () -> [AXNode]? in
                let app = AXUIElementCreateApplication(pid)
                var windows: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success else { return nil }
                for candidate in (windows as? [AXUIElement]) ?? [] {
                    var name: CFTypeRef?
                    AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &name)
                    guard (name as? String) == title else { continue }
                    let node = AXNode(candidate)
                    // The hosting view: the window's one group.
                    return node.children.first { $0.role == "AXGroup" || $0.role == "AXScrollArea" || $0.role == "AXSplitGroup" }?.children
                }
                return nil
            }()
            if let nodes, !nodes.isEmpty { return nodes }
            guard ContinuousClock.now < deadline else { XCTFail("No accessible content in \(title)"); throw EventuallyTimedOut(what: "accessible content") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    /// The whole window, every element.
    @MainActor static func all(in window: NSWindow) async throws -> [AXNode] { AXNode.flat(try await content(of: window)) }
    /// The first element `matching`, waited for up to ten seconds.
    @MainActor static func find(in window: NSWindow, _ what: String = "the element", timeout: Duration = .seconds(10),
                                file: StaticString = #filePath, line: UInt = #line, _ matching: (AXNode) -> Bool) async throws -> AXNode {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: [AXNode] = []
        while true {
            last = try await all(in: window)
            if let found = last.first(where: matching) { return found }
            guard ContinuousClock.now < deadline else {
                XCTFail("Never found \(what) among: " + last.map { "\($0.role):\($0.label)" }.joined(separator: " | "), file: file, line: line)
                throw EventuallyTimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    /// Presses the element, as VoiceOver's VO-Space does.
    @MainActor static func press(_ node: AXNode) -> Bool {
        AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success
    }
}
