import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp

final class SmoothPaneAndKeyboardTests: SmoothShellTestCase {
    // MARK: 6. The split pane

    // MARK: 7. Keyboard paths for the row's own actions

    /// Archive, Pin, Move to Topic and Mark as Read existed only under a
    /// right-click on a sidebar row. They act on the focused chat now, and
    /// the menu's own enablement follows what the chat can do.
    @MainActor func testTheRowActionsActOnTheFocusedChatFromTheMenu() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("smooth-commands-" + UUID().uuidString)
        let bench = try Self.workbench(root: root, names: ["Focused", "Other"], rows: 6)
        let model = bench.model, chats = bench.chats
        registerWorkspaceFixtureTeardown(model, root: root)
        _ = await model.prepareStore()
        for chat in chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.select(chats[1].id)
        model.focusedSessionID = chats[0].id
        XCTAssertEqual(model.commandChat?.id, chats[0].id, "the menu must act on the chat with keyboard focus")

        model.pinCommandChat()
        try await waitFor("the focused chat is pinned") { model.chatRecord(chats[0].id)?.isPinned == true }
        model.pinCommandChat()
        try await waitFor("the focused chat is unpinned again") { model.chatRecord(chats[0].id)?.isPinned == false }

        let topic = try await model.createTopic(in: bench.project.id, title: "Payments")
        XCTAssertEqual(model.commandTopicChoices.map(\.id), [topic.id])
        model.moveCommandChat(toTopic: topic.id)
        try await waitFor("the focused chat moved into the topic") { model.chatRecord(chats[0].id)?.topicID == topic.id }

        model.unreadStates[chats[0].id] = SessionReadState(id: chats[0].id, observedAssistantCount: 2, latestAssistantID: "m", unreadOutputs: 2)
        XCTAssertEqual(model.unreadOutputCount(sessionID: chats[0].id), 2)
        model.markCommandChatRead()
        XCTAssertEqual(model.unreadOutputCount(sessionID: chats[0].id), 0, "Mark as Read left the dot on the row")

        model.archiveCommandChat()
        try await waitFor("the focused chat is archived") { model.chatRecord(chats[0].id)?.isArchived == true }
        model.archiveCommandChat()
        try await waitFor("the focused chat is restored") { model.chatRecord(chats[0].id)?.isArchived == false }

        // The report page owns the window: the chat menus stop acting.
        model.openReport()
        XCTAssertNil(model.commandChat, "the row actions must not act on a chat the reader cannot see")
        model.closeReport()
    }

    /// Folding a turn was a click on its chevron. The keyboard folds the turn
    /// the reader is on — the one holding their anchor row — and the pair
    /// that folds every turn works on a long chat.
    @MainActor func testFoldingTheFocusedTurnFromTheKeyboard() async throws {
        let shell = try shell(["Folding"], rows: 40)
        let model = shell.model
        let session = try XCTUnwrap(model.displays[shell.chats[0].id])
        await model.select(shell.chats[0].id)
        await shell.settle(1.0)
        XCTAssertTrue(model.canFoldTurns)
        let keysInOrder = WorkspaceModel.turnKeys(in: session.presentedMessages)
        let newest = try XCTUnwrap(keysInOrder.last)
        // A chat nobody has scrolled yet folds its newest turn.
        XCTAssertEqual(WorkspaceModel.turnKey(holding: nil, in: session.presentedMessages), newest)
        // A question the reader is looking at belongs to the turn under it.
        XCTAssertEqual(WorkspaceModel.turnKey(holding: shell.chats[0].id + "-m10", in: session.presentedMessages),
                       "block:" + shell.chats[0].id + "-m11")

        // In the window: the fold follows the row the transcript last
        // reported, and moves when the reader does.
        try await waitFor("the transcript reported where the reader is") { session.scrollAnchor != nil }
        let opened = try XCTUnwrap(model.setFocusedTurnFolded(true))
        XCTAssertFalse(session.disclosure.isOpen(.work(opened)), "the turn the reader is on did not fold")
        XCTAssertEqual(model.setFocusedTurnFolded(false), opened)
        XCTAssertTrue(session.disclosure.isOpen(.work(opened)))
        await shell.scrollAwayFromTheBottom(by: 1_400)
        try await waitFor("the transcript reported the new reading position") {
            WorkspaceModel.turnKey(holding: session.scrollAnchor?.id, in: session.presentedMessages) != opened
        }
        let anchored = try XCTUnwrap(model.setFocusedTurnFolded(true))
        XCTAssertNotEqual(anchored, opened, "the fold must follow the reader up the chat")
        XCTAssertFalse(session.disclosure.isOpen(.work(anchored)))
        model.setFocusedTurnFolded(false)

        let keys = WorkspaceModel.turnKeys(in: session.presentedMessages)
        XCTAssertEqual(model.setEveryTurnFolded(true), keys.count)
        XCTAssertTrue(keys.allSatisfy { !session.disclosure.isOpen(.work($0)) }, "Fold Every Turn left turns open")
        XCTAssertEqual(model.setEveryTurnFolded(false), keys.count)
        XCTAssertTrue(keys.allSatisfy { session.disclosure.isOpen(.work($0)) })
    }

    // MARK: 8. Closing a sheet that watches its window

    /// The visibility reader told its owner "not on screen" from inside
    /// SwiftUI's own teardown, which writes the `@State` SwiftUI is already
    /// holding: "Fatal access conflict detected" and the process aborts. The
    /// gallery hit it closing the request inspector. The reader still has to
    /// say so — just not in the middle of the teardown.
    @MainActor func testClosingAViewThatWatchesItsWindowDoesNotAbort() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = VisibilityRecorder()
        window.contentView = NSHostingView(rootView: WindowVisibilityProbe(recorder: recorder))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }
        XCTAssertFalse(recorder.reports.isEmpty, "the reader never said whether its window was on screen")
        recorder.reports.removeAll()
        // Teardown, exactly as dismissing a sheet performs it.
        window.contentView = nil
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(recorder.reports.last, false, "a torn-down reader has to report that it is gone")
    }
}

extension SmoothPaneAndKeyboardTests {
    /// The pane is kept across chats, so a switch hands the composer the
    /// arriving chat's draft. That is not typing: it used to write the
    /// unchanged draft back to the store on every click in the sidebar.
    @MainActor func testSwitchingChatsDoesNotWriteTheArrivingDraftBack() async throws {
        let shell = try shell(["First", "Second"], rows: 8)
        defer { shell.close() }
        let store = try XCTUnwrap(shell.model.store)
        for chat in [shell.chats[0], shell.chats[1], shell.chats[0], shell.chats[1], shell.chats[0]] {
            await shell.model.select(chat.id)
            await shell.settle(0.5)
        }
        XCTAssertEqual(shell.editor?.string, "An unsent draft for First")
        for chat in shell.chats {
            let written = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
            XCTAssertNil(written, "Showing \(chat.title) wrote its unchanged draft back to the store")
        }
        // Typing is still saved.
        let editor = try XCTUnwrap(shell.editor)
        XCTAssertTrue(shell.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("!", replacementRange: editor.selectedRange())
        await shell.settle(0.6)
        let typed = try await store.get(DraftRecord.self, kind: "draft", id: shell.chats[0].id)
        XCTAssertEqual(typed?.text, "An unsent draft for First!")
    }
}
