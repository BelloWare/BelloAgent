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
    @MainActor func testDeleteCommandCannotDeleteTheMainChatFromAFocusedManagedReader() async throws {
        let (model, _) = try fixture()
        _ = try await open("chat-child", in: model)
        let menus = ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { nil }, revealWorkspace: {}, showSettings: {})
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        menus.install()
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        let delete = try XCTUnwrap(file.items.first { $0.title == "Delete Chat…" })
        XCTAssertFalse(menus.validateMenuItem(delete), "A managed reader has no independent Delete Chat command")
        var asked: [ChatQuestion] = []
        model.questions.answer = { asked.append($0); return false }
        model.deleteChat()
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(asked.isEmpty, "The focused child must never prepare its main chat's deletion")
        XCTAssertNotNil(model.record("chat-parent")); XCTAssertNotNil(model.record("chat-child"))
        model.focusPane("chat-parent")
        XCTAssertTrue(menus.validateMenuItem(delete))
        model.deleteChat()
        for _ in 0..<200 where asked.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(asked.count, 1, "Explicit parent focus still offers its ordinary confirmation")
    }
    @MainActor func testEmbeddedReaderFamilyMenuTargetsTheVisibleMainHeader() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; other.title = "Other main"
        model.chats.append(other)
        await model.select(other.id); tab.focus()
        XCTAssertFalse(model.canShowAgentFamily, "There is no picker anchor when the visible main chat has no family")
        var side = try XCTUnwrap(model.record("chat-side")); side.id = "other-side"; side.parentSessionID = other.id; model.chats.append(side)
        var owners: [String] = []
        let subscription = model.agentFamilyRequests.sink { owners.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(model.canShowAgentFamily)
        model.showAgentFamily()
        XCTAssertEqual(owners, [other.id], "Embedded commands use the main column's available picker")
        model.tabs.popOut(tab)
        model.showAgentFamily()
        XCTAssertEqual(owners.last, "chat-parent", "A child window has its own family anchor")
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
        model.page = .report
        XCTAssertTrue(model.subagentReaderCommandsEnabled(tab.key), "A popped-out reader keeps its commands while the main window shows another page")
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
        model.tabs.moveToPane(tab)
        XCTAssertFalse(model.subagentReaderCommandsEnabled(tab.key), "The Reports page still covers a reader embedded in the workspace")
    }
    @MainActor func testReopeningUnchangedHistoryCancelsPagingWithoutKeepingItsLoadingFlags() async throws {
        let (model, gate) = try fixture()
        let path = model.root.appendingPathComponent("paging.jsonl")
        var data = Data()
        func append(_ row: [String: WireValue]) throws { data.append(try JSONEncoder().encode(row)); data.append(10) }
        try append(["type": .string("session"), "version": .number(3), "id": .string("chat-child")])
        for index in 0..<121 {
            try append(["type": .string("message"), "id": .string("m\(index)"), "parentId": index == 0 ? .null : .string("m\(index - 1)"),
                        "message": .object(["role": .string(index % 2 == 0 ? "user" : "assistant"), "content": .string("Reply \(index)")])])
        }
        try FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        try data.write(to: path)
        model.chats[1].path = path.path; model.historyWindowLoader = nil
        let tab = try await open("chat-child", in: model), display = try XCTUnwrap(model.displays[tab.key])
        model.historyViewportReady(tab.key, generation: display.presentationGeneration)
        let cursor = try XCTUnwrap(display.olderPage.cursor)
        await gate.set("Older page", held: true)
        model.historyWindowLoader = { _, _, _, _ in try await gate.page() }
        let paging = Task { await model.loadEarlierPage(sessionID: tab.key) }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(display.olderPage.loading)
        _ = otherTab(model)
        await model.openSubagentTab(tab.key)
        XCTAssertFalse(display.olderPage.loading, "A new presentation owns fresh boundary flags, even when the journal is unchanged")
        XCTAssertEqual(display.olderPage.cursor, cursor)
        await gate.release(); _ = await paging.value
        XCTAssertFalse(display.olderPage.loading)
    }
    @MainActor func testShowingAnAvailableSideClearsTheHiddenChildFocus() async throws {
        let (model, _) = try fixture()
        model.openSide()
        let side = try XCTUnwrap(model.sides["chat-parent"])
        let tab = try await open("chat-child", in: model)
        XCTAssertEqual(model.focusedSessionID, tab.key)
        model.tabs.showSide()
        XCTAssertTrue(model.paneSideAvailable)
        XCTAssertFalse(model.subagentTabIsShown(tab.key))
        XCTAssertNotEqual(model.focusedSessionID, tab.key)
        XCTAssertTrue(["chat-parent", side.id].contains(model.focusedSessionID ?? ""))
    }
    @MainActor func testSavedSideLoadDoesNotHideATabChosenWhileItWasLoading() async throws {
        let (model, gate) = try fixture()
        await gate.set("Saved side", held: true)
        let opening = Task { await model.openFamilySide("chat-side") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let other = otherTab(model)
        await gate.release(); await opening.value
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === other)
        XCTAssertNotEqual(model.focusedSessionID, "chat-child")
    }
    @MainActor func testNativeResponderTransitionsRestoreChildCommandFocus() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of: container))
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(tab.pane)
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 30)); text.isEditable = false
        pane.addSubview(text)
        for responder in [pane, text] as [NSView] {
            window.makeFirstResponder(nil); model.focusedSessionID = "chat-parent"
            XCTAssertTrue(window.makeFirstResponder(responder))
            XCTAssertEqual(model.focusedSessionID, tab.key, "Native focus inside the child must route Inspector, folding and Stop to that child")
        }
    }

    @MainActor func testClosingAndReopeningDuringAReadCannotAdoptTheClosedReadersPage() async throws {
        let (model, gate) = try fixture()
        await gate.set("Closed reader", held: true)
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let old = try XCTUnwrap(model.subagentTab("chat-child"))
        model.tabs.close(old)
        let fresh = ChildHistoryGate(); await fresh.set("New reader")
        model.historyWindowLoader = { _, _, _, _ in try await fresh.page() }
        let reopened = try await open("chat-child", in: model), display = try XCTUnwrap(model.displays["chat-child"])
        let generation = display.presentationGeneration
        XCTAssertFalse(reopened === old)
        await gate.release(); _ = await opening.value
        old.contentVisibilityChanged(false); old.refresh()
        XCTAssertTrue(model.subagentTab("chat-child") === reopened)
        XCTAssertEqual(display.messages.first?.text, "New reader")
        XCTAssertEqual(display.presentationGeneration, generation)
        XCTAssertNil(display.presentation.navigation); XCTAssertNil(reopened.loading)
    }
    @MainActor func testOpeningForAnotherParentDoesNotOverrideANewerTabChoice() async throws {
        for kind in ["child", "side", "new side"] {
            let (model, gate) = try fixture()
            var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
            let view = SessionDisplay(id: other.id); view.historyState = .ready; model.displays[other.id] = view
            model.selectedID = other.id; model.selected = view; model.focusedSessionID = other.id
            model.displays["chat-parent"]?.historyState = .dormant
            await gate.set("Parent", held: true)
            let opening = Task {
                if kind == "child" { await model.openSubagentTab("chat-child") }
                else if kind == "side" { await model.openFamilySide("chat-side") }
                else { model.openNewFamilySide("chat-parent") }
            }
            for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
            let selected = otherTab(model)
            await gate.release(); await opening.value; await model.navigationTask?.value
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === selected, kind)
            XCTAssertNil(model.subagentTab("chat-child"), kind)
            XCTAssertNil(model.sides["chat-parent"], kind)
        }
    }
    @MainActor func testMovingALoadingChildAcrossContainersKeepsItsLoadAndLaterFocusChoice() async throws {
        let (model, gate) = try fixture()
        await gate.set("Moved reader", held: true)
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let tab = try XCTUnwrap(model.subagentTab("chat-child"))
        let loading = try XCTUnwrap(tab.loading)
        model.tabs.popOut(tab)
        model.tabs.move(tab, to: model.tabs.pane)
        await model.backToSubagentParent(tab.key)
        await gate.release(); await loading.value; _ = await opening.value
        XCTAssertTrue(model.subagentTab(tab.key) === tab)
        XCTAssertEqual(model.displays[tab.key]?.messages.first?.text, "Moved reader")
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
        XCTAssertNil(tab.loading)
    }
    @MainActor func testSavedSideOwnedAgentOpensBesideTheMainAndBackShowsItsActualOwner() async throws {
        let (model, _) = try fixture()
        model.chats[1].parentSessionID = "chat-side"
        model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"
        let tab = try await open("chat-child", in: model)
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertTrue(model.subagentTabIsShown(tab.key))
        await model.backToSubagentParent(tab.key)
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertEqual(model.sides["chat-parent"]?.id, "chat-side")
        XCTAssertEqual(model.focusedSessionID, "chat-side")
        XCTAssertTrue(model.tabs.pane.sideShown)
    }
    @MainActor func testSidePresentationRestartsResetBothBoundaryFlagsAndRetainCursors() async throws {
        let (model, gate) = try fixture()
        let display = try XCTUnwrap(model.displays["chat-side"]), chat = try XCTUnwrap(model.record("chat-side"))
        let cursor = ConversationCursor(incarnation: "fixture", lineage: "root", entry: "boundary")
        func markPendingPages() {
            display.olderPage = .init(cursor: cursor, loading: true, error: "Old failure")
            display.newerPage = .init(cursor: cursor, loading: true, error: "Old failure")
        }
        func checkBoundaries() {
            XCTAssertEqual(display.olderPage, .init(cursor: cursor))
            XCTAssertEqual(display.newerPage, .init(cursor: cursor))
        }
        markPendingPages(); _ = model.mountSide(chat, beside: "chat-parent"); checkBoundaries()
        var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
        await model.select(other.id)
        markPendingPages(); await gate.set("Restored side", held: true)
        let selection = Task { await model.select("chat-parent") }
        for _ in 0..<500 { if model.selectedID == "chat-parent" { break }; try await Task.sleep(for: .milliseconds(2)) }
        checkBoundaries(); await gate.release(); await selection.value; await display.presentation.navigation?.value
        XCTAssertNil(display.presentation.navigation)
    }
    @MainActor func testPickerArrowsReturnAndRefreshPreserveTheChosenRow() async throws {
        let (model, _) = try fixture()
        let window = TabWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let picker = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: window)
        window.contentView = picker; window.makeKeyAndOrderFront(nil); window.layoutIfNeeded()
        func key(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        let first = try XCTUnwrap(ConversationPaneTests.views(FamilyPickerRow.self, in: picker).first)
        window.makeFirstResponder(first)
        first.keyDown(with: try key(125))
        XCTAssertEqual((window.firstResponder as? FamilyPickerRow)?.title, "New Side")
        (window.firstResponder as? FamilyPickerRow)?.keyDown(with: try key(125))
        XCTAssertEqual((window.firstResponder as? FamilyPickerRow)?.accessibilityIdentifier(), "open-agent-chat-child")
        let child = try XCTUnwrap(model.record("chat-child"))
        model.subagentSummaries[child.id] = .init(link: child.delegation!, description: child.title, model: "fixture", status: .running, revision: 2)
        picker.refresh()
        let focused = try XCTUnwrap(window.firstResponder as? FamilyPickerRow)
        XCTAssertEqual(focused.accessibilityIdentifier(), "open-agent-chat-child")
        var opened = false; focused.onPress = { opened = true }
        focused.keyDown(with: try key(36)); XCTAssertTrue(opened)
        let stop = try XCTUnwrap(focused.stop); picker.layoutSubtreeIfNeeded()
        XCTAssertTrue(focused.hitTest(stop.convert(.init(x: 12, y: 12), to: focused.superview)) === stop)
        XCTAssertTrue(focused.accessibilityChildren()?.contains { ($0 as? NSView) === stop } == true)
    }

    @MainActor func testNewSideRequestRetiresBeforeItsDeferredSelectionIfAnotherTabWasChosen() async throws {
        let (model, _) = try fixture()
        var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
        model.openNewFamilySide(other.id)
        let file = otherTab(model)
        for _ in 0..<30 { await Task.yield() }
        await model.navigationTask?.value
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === file)
        XCTAssertNil(model.sides[other.id])
    }
    @MainActor func testReopeningASideWhoseReadWasCanceledStartsANewPresentation() async throws {
        let (model, gate) = try fixture()
        await gate.set("Canceled side read", held: true)
        let opening = Task { await model.openFamilySide("chat-side") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let display = try XCTUnwrap(model.displays["chat-side"])
        display.presentation.navigation?.cancel()
        await gate.release(); await opening.value
        XCTAssertEqual(display.historyState, .dormant)
        XCTAssertNil(display.presentation.navigation)
        await gate.set("Reopened saved side")
        await model.openFamilySide("chat-side")
        XCTAssertEqual(display.messages.first?.text, "Reopened saved side")
        XCTAssertFalse(display.historyState == .dormant)
    }

}
