import AppKit
import FileView
import GitView
import XCTest
@testable import PiApp

final class SubagentNavigationTests: XCTestCase, SerialTestLane {
    @MainActor func testFollowUpReturnAndTypedSourceKeepTheIssuingSendInAnEarlierVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child"])
        registerWorkspaceFixtureTeardown(bench.model, root: root)
        bench.model.chats[1].delegation = SubagentTranscriptTests.link
        bench.model.chats[1].parentSessionID = "chat-parent"
        let view = SessionDisplay(id: "chat-parent"); view.historyState = .ready; view.draft = "Keep my draft"
        view.messages = [.init(id: "edited", role: "user", text: "Edited ancestor")]
        var send = SubagentSteeringPresentationTests.tool; send.name = "subagent_send"; send.id = "send-3"
        view.versionView = TranscriptVersionView(latestID: "edited", index: 1, count: 2, ids: ["turn", "edited"], live: 2,
            rows: [.init(id: "turn", role: "user", text: "Earlier task", earlierVersion: true),
                   .init(id: "follow-up", role: "assistant", text: "", tools: [send], earlierVersion: true)], loading: false)
        bench.model.displays[view.id] = view; bench.model.selectedID = view.id; bench.model.selected = view; bench.model.focusedSessionID = view.id
        var target = SubagentTarget(SubagentTranscriptTests.link); target.receiptSource = true; target.turn = 3
        target.assistantID = "follow-up"; target.toolCallID = "send-3"
        bench.model.subagentReturnTargets["chat-child"] = target
        await bench.model.backToSubagentParent("chat-child")
        XCTAssertEqual(view.reveal?.messageID, "follow-up"); XCTAssertEqual(view.reveal?.toolCallID, "send-3")
        view.reveal = nil
        await bench.model.showAgentSource(.init(id: "input-3", childID: "chat-child", turn: 3, kind: "follow_up", author: "parent",
            sourceSessionID: "chat-parent", sourceMessageID: "follow-up", sourceToolCallID: "send-3", recipientID: "chat-child", disposition: "delivered"))
        XCTAssertEqual(view.reveal?.messageID, "follow-up"); XCTAssertEqual(view.reveal?.toolCallID, "send-3")
        XCTAssertEqual(view.versionView?.index, 1); XCTAssertEqual(view.draft, "Keep my draft")
        XCTAssertTrue(bench.model.sessionOpenings.isEmpty)
    }
    @MainActor func testChildPaneHasNoInputOrContinuationControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-navigation-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var child = bench.chats[1]; child.delegation = SubagentTranscriptTests.link; child.parentSessionID = "chat-parent"
        bench.model.chats[1] = child
        let session = SessionDisplay(id: child.id)
        session.historyState = .empty
        bench.model.selectedID = child.id; bench.model.selected = session; bench.model.displays[child.id] = session
        let pane = ConversationPaneView(model: bench.model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane
        defer { window.contentView = nil; window.close() }
        pane.show(session: session, chat: child); window.makeKeyAndOrderFront(nil); pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.composer.isHidden)
        XCTAssertNil(pane.composer.session)
        XCTAssertTrue(ConversationPaneTests.views(NSView.self, in: pane).contains { $0.accessibilityIdentifier() == "back-to-subagent-parent" })
        session.draft = "must not send"; session.draftReady = true
        bench.model.send(sessionID: child.id); bench.model.resumeRun(sessionID: child.id); bench.model.editMessage("task", sessionID: child.id)
        XCTAssertFalse(session.resuming); XCTAssertFalse(session.editPreparing)
        XCTAssertTrue(bench.model.sessionOpenings.isEmpty)
    }
    @MainActor func testBackShortcutChecksRealResponderAndWindowOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-keys-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var child = bench.chats[1]; child.delegation = SubagentTranscriptTests.link; child.parentSessionID = "chat-parent"
        bench.model.chats[1] = child
        let session = SessionDisplay(id: child.id)
        session.historyState = .ready
        bench.model.selectedID = child.id; bench.model.focusedSessionID = child.id
        bench.model.selected = session; bench.model.displays[child.id] = session
        let pane = ConversationPaneView(model: bench.model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds); window.contentView = content
        pane.frame = content.bounds; content.addSubview(pane); pane.show(session: session, chat: child)
        defer { window.contentView = nil; window.close() }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33))
        XCTAssertTrue(window.makeFirstResponder(pane)); XCTAssertTrue(pane.canBackToSubagentParent)
        let file = FileTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let git = GitDiffTable(); git.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        content.addSubview(file); content.addSubview(git)
        let gitResponder = try XCTUnwrap(ConversationPaneTests.views(NSTableView.self, in: git).first)
        let terminal = TerminalView(emulator: TerminalEmulator())
        // The terminal can sit inside the pane, but is not its transcript.
        pane.addSubview(terminal)
        for responder in [file, gitResponder, terminal] as [NSView] {
            XCTAssertTrue(window.makeFirstResponder(responder))
            XCTAssertFalse(pane.canBackToSubagentParent)
            XCTAssertFalse(window.performKeyEquivalent(with: key))
            XCTAssertEqual(bench.model.selectedID, child.id)
        }
        terminal.removeFromSuperview(); git.close(); git.removeFromSuperview(); file.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(pane))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; window.beginSheet(sheet, completionHandler: nil)
        XCTAssertFalse(pane.canBackToSubagentParent); XCTAssertFalse(pane.performKeyEquivalent(with: key))
        window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
        let picker = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        picker.isReleasedWhenClosed = false; window.addChildWindow(picker, ordered: .above); picker.orderFront(nil)
        XCTAssertFalse(pane.canBackToSubagentParent)
        window.removeChildWindow(picker); picker.close()
        let inspector = SessionInspectorModel(scope: .init(sessionID: "chat-parent", workspaceID: bench.workspace.id), title: "Parent", archive: bench.model.traces, workspace: bench.model, usageLoader: { _,_,_ in throw CancellationError() })
        let inspectorView = SessionInspectorView(inspector: inspector)
        let inspectorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        inspectorWindow.isReleasedWhenClosed = false; inspectorWindow.contentView = inspectorView; inspectorWindow.makeKeyAndOrderFront(nil)
        XCTAssertFalse(pane.canBackToSubagentParent)
        let inspectorKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: inspectorWindow.windowNumber, context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33))
        XCTAssertTrue(inspectorWindow.performKeyEquivalent(with: inspectorKey), "Inspector retains its own previous-request shortcut")
        inspectorWindow.contentView = nil; inspectorWindow.close()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(pane)
        let parent = bench.model.chats.remove(at: 0)
        XCTAssertFalse(pane.canBackToSubagentParent)
        bench.model.chats.insert(parent, at: 0)
        XCTAssertTrue(pane.canBackToSubagentParent)
        XCTAssertTrue(window.performKeyEquivalent(with: key), "The main child pane owns Back to Parent")
        for _ in 0..<20 where bench.model.selectedID != parent.id { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(bench.model.selectedID, parent.id)
    }

    @MainActor func testEarlierVersionReturnNamesExactCardWithoutChangingDraftOrOtherFolds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-return-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let view = SessionDisplay(id: "chat-parent")
        view.historyState = .ready; view.draft = "My unsent parent draft"
        view.messages = [TranscriptMessage(id: "new-turn", role: "user", text: "Edited task")]
        view.versionView = TranscriptVersionView(latestID: "new-turn", index: 1, count: 2, ids: ["turn", "new-turn"], live: 2,
            rows: [TranscriptMessage(id: "turn", role: "user", text: "Task", earlierVersion: true),
                   TranscriptMessage(id: "reply", role: "assistant", text: "", tools: [SubagentTranscriptTests.tool], earlierVersion: true)], loading: false)
        bench.model.displays[view.id] = view; bench.model.selectedID = view.id; bench.model.selected = view; bench.model.focusedSessionID = view.id
        await bench.model.revealSubagentCall(SubagentTranscriptTests.link)
        XCTAssertEqual(view.reveal?.messageID, "reply"); XCTAssertEqual(view.reveal?.toolCallID, "call")
        XCTAssertEqual(view.versionView?.index, 1)
        XCTAssertEqual(view.draft, "My unsent parent draft")
        XCTAssertTrue(bench.model.sessionOpenings.isEmpty, "An already shown old version needs no helper")
    }

    @MainActor func testTargetedOldVersionReplacesAnAlreadyLoadedPageWithoutChangingTheLiveRows() async throws {
        let fixture = try ConversationPaneTests.Pane(messages: MessageVersionTranscriptTests.editedRows())
        defer { fixture.close() }
        let old = MessageVersionTranscriptTests.versionOne
        fixture.model.versionPageLoader = { _, _ in (old, []) }
        fixture.model.showVersion(sessionID: fixture.chat.id, latestID: "u2b", index: 1, count: 2, ids: ["u2", "u2b"])
        await fixture.session.versionLoad?.value
        fixture.session.versionView?.rows = [old[0]]
        fixture.model.showVersion(sessionID: fixture.chat.id, latestID: "u2b", index: 1, count: 2, ids: ["u2", "u2b"], around: "a2")
        await fixture.session.versionLoad?.value
        XCTAssertEqual(fixture.session.versionView?.rows.map(\.id), ["a2"])
        XCTAssertNil(fixture.session.versionView?.rows.first?.versions, "A targeted assistant row is not a user version switcher")
        XCTAssertEqual(fixture.session.messages.map(\.id), MessageVersionTranscriptTests.editedRows().map(\.id))
    }

    @MainActor func testReturnRevealsTheExactToolBelowALongReply() async throws {
        let tools = (0..<18).map { index -> ToolView in
            var tool = SubagentTranscriptTests.tool; tool.id = "call-\(index)"; return tool
        }
        let fixture = try ConversationPaneTests.Pane(messages: [
            TranscriptMessage(id: "turn", role: "user", text: "Review"),
            TranscriptMessage(id: "reply", role: "assistant", text: String(repeating: "A paragraph before the delegated tasks.\n\n", count: 80), tools: tools, turn: "turn")
        ])
        defer { fixture.close() }
        await fixture.settle()
        let pane = try XCTUnwrap(ConversationPaneTests.views(ConversationPaneView.self, in: fixture.hosted).first)
        pane.transcript.scrollView.contentView.scroll(to: .zero)
        pane.transcript.scrollView.reflectScrolledClipView(pane.transcript.scrollView.contentView)
        await fixture.settle()
        let accepted = await fixture.model.revealInTranscript(sessionID: fixture.chat.id, messageID: "reply", toolCallID: "call-17")
        XCTAssertTrue(accepted)
        await fixture.settle(35)
        let row = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeActionRow.self, in: pane).first { $0.tool?.id == "call-17" })
        let clip = pane.transcript.scrollView.contentView
        let frame = row.convert(row.bounds, to: clip)
        XCTAssertTrue(clip.bounds.intersects(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 24)), "Back must reveal the issuing card, not only the beginning of its long reply")
        XCTAssertNotNil(row.card)
    }

}
