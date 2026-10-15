import AppKit
import XCTest
@testable import PiApp

private actor OriginalReaderBackGate {
    private(set) var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}

final class InheritedSubagentReaderTests: XCTestCase, SerialTestLane {
    @MainActor func testForkCardAndPickerOpenOriginalReadOnlyWithoutWritingSource() async throws {
        let root = scratchRoot("fork-original-reader")
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        try await model.store?.putChats(model.chats)
        await model.reconcileSubagents()
        let child = try XCTUnwrap(model.record(family.child)), parent = model.chats[0]
        let source = URL(fileURLWithPath: parent.path!)
        let before = try [Data(contentsOf: source), Data(contentsOf: family.path)]
        let path = source.deletingLastPathComponent().appendingPathComponent("fork.jsonl")
        try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "\"id\":\"chat-parent\"", with: "\"id\":\"fork\"").write(to: path, atomically: true, encoding: .utf8)
        var fork = parent; fork.id = "fork"; fork.title = "Independent fork"; fork.path = path.path; fork.parentSessionID = parent.id
        model.chats.append(fork)
        var tool = SubagentTranscriptTests.tool
        var fields = SubagentTranscriptTests.metadata.object!; fields["sessionId"] = .string(child.id); tool.nativeSubagent = .object(fields)
        let savedTool = tool
        model.historyWindowLoader = { id, _, _, _ in
            var page = try ConversationHistoryPage(.object(["version":.number(2), "incarnation":.string(id), "lineage":.string("root"), "messages":.array([]), "older":.null, "newer":.null]))
            page.messages = id == "fork" ? [.init(id:"reply", role:"assistant", text:"Copied review", tools:[savedTool])] : [.init(id:"answer", role:"assistant", text:"Original saved reply")]
            return page
        }
        await model.select(fork.id)
        let display = try XCTUnwrap(model.displays[fork.id]); display.disclosure.setOpen(true, .work("reply"))
        display.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply",tool.id)))
        let pane = NativeTranscriptPane(frame:.init(x:0,y:0,width:700,height:500))
        pane.showTranscript(model:model, session:display, state:"idle", canFork:true, canQuote:true, enabled:true)
        pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self,in:pane).first)
        let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:card).first { $0.accessibilityIdentifier() == "open-subagent" })
        XCTAssertEqual(model.inheritedSubagents[fork.id]?.count,1)
        XCTAssertTrue(model.conversationFamily(fork.id).canAddSide, "A fork's own family picker retains New Side")
        XCTAssertNil(model.originalAvailability(SubagentTarget(child.delegation!)).reason)
        XCTAssertNotNil(display.originalSubagentAvailability[child.id])
        XCTAssertEqual(open.title,"Open"); XCTAssertTrue(open.isEnabled, open.toolTip ?? "no tooltip")
        guard open.isEnabled else { return }
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self,in:card).contains { $0.string.contains("From the original chat") })
        open.onPress?()
        try await eventually("Fork card opens the original reader") { model.subagentTab(child.id) != nil }
        let tab = try XCTUnwrap(model.subagentTab(child.id)); await tab.loading?.value
        XCTAssertEqual(model.selectedID,fork.id)
        XCTAssertTrue(tab.title.contains("From the original chat · " + parent.title))
        XCTAssertTrue(tab.stripTitle.contains("From the original chat"))
        XCTAssertEqual(model.displays[child.id]?.messages.first?.text,"Original saved reply")
        let inspect = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:card).first { $0.accessibilityIdentifier() == "inspect-subagent" })
        inspect.onPress?(); XCTAssertEqual(model.lastInspectorFocus,.subagent(child.delegation!.delegationID))
        XCTAssertTrue(model.isOriginalSubagentReader(child.id))
        XCTAssertFalse(model.canStopConversation)
        do { _ = try await model.open(child); XCTFail("A reference reader cannot attach a writable helper") } catch { }
        model.displays[child.id]?.draft = "Cannot send"
        model.send(sessionID: child.id); model.send(steer:true,sessionID:child.id); model.stop(sessionID:child.id)
        model.action("turn.stop",sessionID:child.id); model.action("queue.resume",sessionID:child.id)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertFalse(model.displays[child.id]?.loading == true)
        let restored = try XCTUnwrap(SubagentTab.restore(key:child.id,state:tab.savedState()) as? SubagentTab)
        XCTAssertEqual(restored.originalForkID,fork.id)
        model.tabs.showsWindows = false
        let external = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of:external))
        _ = tab.contentView; tab.focus()
        model.conversationWindow = { window }
        let menus = ApplicationMenus(model:model,updates:UpdateController(),workspaceWindow:{nil},revealWorkspace:{},showSettings:{})
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }; menus.install()
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Conversation" }?.submenu)
        for title in ["Stop", "Send / Queue Follow-up", "Send / Steer Current Run", "Resume", "Resume Follow-ups", "Compact Now"] {
            XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(menu.items.first { $0.title == title })),title)
        }
        for title in ["Find…", "Search and Copy Conversation…"] {
            XCTAssertTrue(menus.validateMenuItem(try XCTUnwrap(menu.items.first { $0.title == title })),title)
        }
        XCTAssertTrue(tab.pane?.composer.isHidden == true)
        XCTAssertFalse(ConversationPaneTests.views(PiKit.Button.self,in:tab.contentView).contains { $0.title == "Stop" && !$0.isHidden && $0.isEnabled })
        // Back is still a reader-owned navigation when the fork needs loading.
        await model.select(parent.id, focusesComposer: false)
        display.historyState = .dormant; display.presentation.identity = nil
        let gate = OriginalReaderBackGate(), originalLoader = try XCTUnwrap(model.historyWindowLoader), forkID = fork.id
        model.historyWindowLoader = { id, cursor, newer, around in
            if id == forkID { await gate.wait() }
            return try await originalLoader(id, cursor, newer, around)
        }
        let back = Task { await model.backToSubagentParent(child.id) }
        try await eventually("Original-reader Back is loading its fork") { await gate.entered }
        await model.select(parent.id, focusesComposer: false)
        await gate.release(); await back.value
        XCTAssertEqual(model.focusedSessionID, parent.id, "Retired Back cannot refocus the fork after a newer selection")
        model.historyWindowLoader = originalLoader
        await model.select(fork.id, focusesComposer: false)
        model.tabs.close(tab)
        _ = model.tabs.open(kind:SubagentTab.kind,key:child.id) { restored }
        await restored.loading?.value
        XCTAssertTrue(model.isOriginalSubagentReader(child.id)); XCTAssertTrue(model.hosts.isEmpty)
        model.tabs.close(restored)
        let inspector = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID:parent.id)?.inspector)
        XCTAssertEqual(inspector.originalForkID,fork.id)
        inspector.reveal(model,child.id,nil)
        try await eventually("Inspector retains original-read-only provenance after the tab closes") { model.isOriginalSubagentReader(child.id) }
        await model.subagentTab(child.id)?.loading?.value
        if let shown = model.subagentTab(child.id) { model.tabs.close(shown) }
        let picker = AgentFamilyPopoverView(model:model,sessionID:fork.id,close:{},ownerWindow:nil)
        let rows = ConversationPaneTests.views(FamilyPickerRow.self,in:picker)
        let row = try XCTUnwrap(rows.first { $0.primary.contains("Parser review") })
        row.onPress?()
        try await eventually("Fork picker opens original") { model.subagentTab(child.id) != nil }
        await model.subagentTab(child.id)?.loading?.value
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        XCTAssertFalse(ConversationPaneTests.views(PiKit.IconButton.self,in:picker).contains { $0.accessibilityIdentifier().hasPrefix("stop-agent-") })
        display.disclosure.setOpen(true, .work("reply"))
        display.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", tool.id)))
        // Missing and untrusted originals remain labelled, with inert actions.
        for missing in ["project", "folder", "trust", "parent", "child", "file"] {
            let records = model.chats, projects = model.workspaces
            if missing == "project" { model.workspaces = [] }
            if missing == "folder" { model.workspaces[0].path += "/unavailable-original-project" }
            if missing == "trust" { model.workspaces[0].trusted = false }
            if missing == "parent" { model.chats.removeAll { $0.id == parent.id } }
            if missing == "child" { model.chats.removeAll { $0.id == child.id } }
            if missing == "file" { try FileManager.default.removeItem(at:family.path); model.refreshOriginalAvailability() }
            XCTAssertNotNil(model.originalAvailability(SubagentTarget(child.delegation!)).reason,missing)
            pane.showTranscript(model:model,session:display,state:"idle",canFork:true,canQuote:true,enabled:true)
            pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded()
            let missingCard = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self,in:pane).first)
            let unavailableOpen = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:missingCard).first { $0.accessibilityIdentifier() == "open-subagent" })
            XCTAssertFalse(unavailableOpen.isEnabled,missing)
            XCTAssertTrue(unavailableOpen.toolTip?.contains("unavailable") == true || unavailableOpen.toolTip?.contains("trusted") == true,missing)
            let unavailable = AgentFamilyPopoverView(model:model,sessionID:fork.id,close:{},ownerWindow:nil)
            let missingRow = try XCTUnwrap(ConversationPaneTests.views(FamilyPickerRow.self,in:unavailable).first { $0.accessibilityIdentifier().hasPrefix("open-original-") })
            XCTAssertFalse(missingRow.isEnabled,missing); XCTAssertNotNil(missingRow.secondary)
            let opened = await model.openOriginalSubagent(SubagentTarget(child.delegation!),from:fork.id)
            XCTAssertFalse(opened,missing)
            if missing == "file" { try before[1].write(to:family.path) }
            model.chats = records; model.workspaces = projects
        }
        XCTAssertEqual(try [Data(contentsOf:source),Data(contentsOf:family.path)],before)
    }
}
