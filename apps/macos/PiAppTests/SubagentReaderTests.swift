import AppKit
import XCTest
@testable import PiApp

private actor ChildHistoryGate {
    var text = "Saved child reply"
    var held = false
    private(set) var reads = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func set(_ text: String, held: Bool = false) { self.text = text; self.held = held }
    func release() { held = false; waiting.forEach { $0.resume() }; waiting = [] }
    func page() async throws -> ConversationHistoryPage {
        reads += 1
        if held { await withCheckedContinuation { waiting.append($0) } }
        return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("saved-reply"), "role": .string("assistant"), "text": .string(text)])]),
            "older": .null, "newer": .null]))
    }
}

final class SubagentReaderTests: XCTestCase, SerialTestLane {
    @MainActor private func fixture() throws -> (WorkspaceModel, ChildHistoryGate) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        let gate = ChildHistoryGate()
        model.historyWindowLoader = { _, _, _, _ in try await gate.page() }
        for chat in model.chats {
            let view = SessionDisplay(id: chat.id); view.historyState = .ready; view.draftReady = true
            model.displays[chat.id] = view
        }
        model.chats[1].subagentNumber = 2
        model.selectedID = "chat-parent"; model.selected = model.displays["chat-parent"]; model.focusedSessionID = "chat-parent"
        return (model, gate)
    }
    @MainActor private func open(_ id: String, in model: WorkspaceModel) async throws -> SubagentTab {
        let tab = await model.openSubagentTab(id); return try XCTUnwrap(tab)
    }
    @MainActor private func otherTab(_ model: WorkspaceModel) -> HostedTab {
        model.tabs.open(kind: HostedTab.kind, key: "other") { HostedTab(key: "other", title: "Other reader", symbol: "doc") }
    }
    @MainActor func testReopeningAHiddenChildRevalidatesSavedHistoryWithoutALiveHelper() async throws {
        let (model, gate) = try fixture()
        model.displays["chat-child"]?.historyState = .dormant
        let tab = try await open("chat-child", in: model)
        let display = try XCTUnwrap(model.displays[tab.key])
        model.historyViewportReady(display.id, generation: display.presentationGeneration)
        XCTAssertEqual(display.messages.first?.text, "Saved child reply")
        _ = otherTab(model)
        await gate.set("Finished while hidden")
        XCTAssertTrue(model.hosts.isEmpty)
        await model.openSubagentTab(tab.key)
        XCTAssertEqual(display.messages.first?.text, "Finished while hidden")
        XCTAssertTrue(model.sessionOpenings.isEmpty, "Reading saved history must not start a helper")
    }
    @MainActor func testBackDuringInitialLoadKeepsTheParentFocused() async throws {
        let (model, gate) = try fixture()
        await gate.set("Finished loading", held: true)
        model.displays["chat-child"]?.historyState = .dormant
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(model.subagentTab("chat-child"))
        await model.backToSubagentParent("chat-child")
        await gate.release(); _ = await opening.value
        XCTAssertEqual(model.focusedSessionID, "chat-parent", "Finishing a read is not a new focus request")
    }
    @MainActor func testAnotherTabChosenDuringLoadDoesNotFocusTheHiddenChild() async throws {
        let (model, gate) = try fixture()
        await gate.set("Finished loading", held: true)
        model.displays["chat-child"]?.historyState = .dormant
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let other = otherTab(model)
        await gate.release(); _ = await opening.value
        XCTAssertTrue(model.tabs.pane.activeTab === other)
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
        XCTAssertFalse(model.subagentTabIsShown("chat-child"))
    }
    @MainActor func testSideSelectionWithoutAnAvailableSideStillShowsTheHostedReader() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        model.tabs.showSide()
        XCTAssertFalse(model.paneSideAvailable)
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === tab)
        XCTAssertTrue(model.subagentTabIsShown(tab.key))
        let display = try XCTUnwrap(model.displays[tab.key]); display.historyState = .preparing
        model.historyViewportReady(tab.key, generation: display.presentationGeneration)
        XCTAssertEqual(display.historyState, .ready)
    }
    @MainActor func testClosingChildrenAppliesTheDisplayBudgetAndKeepsOpenAndRunningReaders() async throws {
        let (model, _) = try fixture()
        let original = try XCTUnwrap(model.record("chat-child"))
        let kept = try await open(original.id, in: model)
        model.displays["chat-side"]?.runState = .running
        for index in 0..<14 {
            var child = original; child.id = "child-\(index)"; child.delegation?.childSessionID = child.id
            model.chats.append(child)
            let display = SessionDisplay(id: child.id); display.historyState = .ready
            display.messages = [.init(id: "reply", role: "assistant", text: String(repeating: "Retained transcript ", count: 100))]
            model.displays[child.id] = display
            let tab = try await open(child.id, in: model)
            model.tabs.close(tab)
        }
        XCTAssertLessThanOrEqual(model.displays.count, 8)
        XCTAssertNotNil(model.displays["chat-parent"]); XCTAssertNotNil(model.displays["chat-side"])
        XCTAssertNotNil(model.displays[kept.key]); XCTAssertTrue(model.subagentTab(kept.key) === kept)
    }
    @MainActor func testInactiveChildCannotOverwriteItsWindowsActiveTitle() async throws {
        let (model, _) = try fixture()
        var second = try XCTUnwrap(model.record("chat-child")); second.id = "second-child"; second.subagentNumber = 3
        second.delegation?.childSessionID = second.id; second.title = "Another task"
        model.chats.append(second)
        let first = try await open("chat-child", in: model)
        model.tabs.showsWindows = false
        let container = model.tabs.popOut(first)
        let secondTab = try await open(second.id, in: model)
        model.tabs.move(secondTab, to: container)
        let window = try XCTUnwrap(model.tabs.window(of: container))
        window.contentView?.layoutSubtreeIfNeeded()
        first.refresh()
        XCTAssertEqual(window.title, second.displayTitle + " — Bello Agent")
        model.tabs.activate(first); window.contentView?.layoutSubtreeIfNeeded(); secondTab.refresh()
        XCTAssertEqual(window.title, model.record(first.key)!.displayTitle + " — Bello Agent")
    }
    @MainActor func testPoppedOutReaderOwnsFindAndStopShortcutsButNotBehindASheet() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of: container))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let pane = try XCTUnwrap(tab.pane), display = try XCTUnwrap(model.displays[tab.key])
        XCTAssertTrue(window.makeFirstResponder(pane))
        func key(_ text: String, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        }
        XCTAssertTrue(TabHost.tabKey(try key("f"), in: window))
        XCTAssertEqual(display.findCommand?.kind, .show)
        XCTAssertNil(model.selected?.findCommand)
        try await eventually("The child Find bar opened") { display.findHost?.findIsOpen == true }
        XCTAssertTrue(TabHost.tabKey(try key("g", [.command, .shift]), in: window))
        XCTAssertEqual(display.findCommand?.kind, .previous)
        XCTAssertTrue(TabHost.tabKey(try key("g"), in: window))
        XCTAssertEqual(display.findCommand?.kind, .next)
        XCTAssertTrue(TabHost.tabKey(try key("."), in: window))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; window.beginSheet(sheet, completionHandler: nil)
        XCTAssertFalse(TabHost.tabKey(try key("f"), in: window))
        window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
    }
}
