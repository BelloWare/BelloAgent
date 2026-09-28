import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - The follow-up queue

extension ConversationPaneTests {
    /// The hit-testing shapes SwiftUI puts behind its controls.
    @MainActor static func controls(in view: NSView) -> [NSView] {
        let mine = String(describing: Swift.type(of: view)).contains("ShapeHitTesting") ? [view] : []
        return mine + view.subviews.flatMap { controls(in: $0) }
    }

    /// Rewriting a queued follow-up happens in the chat's own composer, in
    /// its look, not in a plain field squeezed into the row: the pencil puts
    /// the message there and sets the draft aside, the panel keeps its size
    /// and marks the row, and Cancel brings the draft back untouched.
    @MainActor func testRewritingAQueuedFollowUpOpensItInTheComposer() async throws {
        let pane = try Pane(width: 620, height: 760); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = (0..<4).map { index in
            ["turnId": .string("q\(index)"), "kind": .string("follow-up"),
             "text": .string("Follow-up \(index): " + String(repeating: "a long queued instruction that keeps going. ", count: 6))]
        }
        pane.session.draft = "unsent thought"
        await pane.settle(20)
        func list() throws -> NSScrollView {
            try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).first { String(describing: Swift.type(of: $0)).contains("ListCore") })
        }
        let idle = try list().frame.height
        XCTAssertEqual(idle, QueuePanel.listHeight(rows: 4), accuracy: 0.5)
        let queued = QueuedMessage.from(pane.session.queue)[1]

        pane.model.editQueued("q1", sessionID: pane.session.id)
        await pane.settle(24)
        XCTAssertEqual(pane.session.queueEditingID, "q1")
        XCTAssertEqual(pane.editor?.string, queued.text, "The composer holds the queued message")
        XCTAssertEqual(pane.session.savedDraft.text, "unsent thought", "The draft saved for the chat stays the one typed")
        XCTAssertEqual(try list().frame.height, idle, accuracy: 0.5, "No row grows: the rewrite is in the composer")
        XCTAssertTrue(Self.views(NSTextField.self, in: try list()).allSatisfy { !$0.isEditable }, "The panel opens no field of its own")
        let panel = try list().convert(try list().bounds, to: nil)
        let field = try XCTUnwrap(pane.editor?.enclosingScrollView)
        XCTAssertFalse(panel.intersects(field.convert(field.bounds, to: nil)), "The queue panel must never reach the composer")

        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        await pane.settle(12)
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.editor?.string, "unsent thought", "Cancel brings the draft back")
        XCTAssertEqual(QueuedMessage.from(pane.session.queue)[1].text, queued.text, "Cancel leaves the queued message as it was")
    }

    /// Return in the composer saves the rewrite rather than queueing it as a
    /// new message, and brings the set-aside draft back.
    @MainActor func testReturnSavesTheRewriteInsteadOfQueueingANewMessage() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Short one")]]
        pane.session.draft = "unsent thought"
        await pane.settle(14)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        await pane.settle(10)
        let editor = try XCTUnwrap(pane.editor)
        XCTAssertTrue(pane.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(", rewritten", replacementRange: editor.selectedRange())
        await pane.settle(6)
        type("\r", into: editor, keyCode: 36)
        await pane.settle(10)
        XCTAssertNil(pane.session.queueEditingID, "Return saved the rewrite")
        XCTAssertTrue(pane.session.sendingRows.isEmpty, "Nothing was queued as a new message")
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The set-aside draft comes back")
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// A queued submission longer than the snapshot's preview: the composer
    /// takes it only once the helper's whole copy is read, so the preview can
    /// never be saved over it, and it holds the complete text.
    @MainActor func testRewritingALongQueuedMessageWaitsForItsWholeText() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        let whole = "Rewrite the retry loop. " + String(repeating: "Here is another paragraph of the original instruction. ", count: 120)
        let preview = String(whole.prefix(1_024))
        XCTAssertGreaterThan(whole.count, preview.count, "The fixture really is longer than its preview")
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"),
                               "text": .string(preview), "textBytes": .number(Double(whole.utf8.count)), "textTruncated": .bool(true)]]
        pane.session.state = "running"
        pane.session.draft = "unsent thought"
        let gate = AsyncGate()
        pane.model.queueReadOperation = { sessionID, turnID in
            XCTAssertEqual(turnID, "q0"); XCTAssertEqual(sessionID, pane.session.id)
            await gate.wait()
            return ["turnId": .string(turnID), "text": .string(whole), "textBytes": .number(Double(whole.utf8.count))]
        }
        await pane.settle(16)
        XCTAssertTrue(QueuedMessage.from(pane.session.queue)[0].truncated, "The row says its text is a preview")

        pane.model.editQueued("q0", sessionID: pane.session.id)
        await pane.settle(10)
        XCTAssertEqual(pane.session.queueEditPreparing, "q0", "The row shows the read in progress")
        XCTAssertNil(pane.session.queueEditingID, "Nothing is open for rewriting until the whole message is in")
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The composer keeps the draft meanwhile")
        await gate.open()
        try await waitFor("The whole message never reached the composer") { pane.session.queueEditingID == "q0" }
        await pane.settle(8)
        XCTAssertEqual(pane.editor?.string, whole, "The composer holds the complete message, not the first kilobyte")
        XCTAssertNil(pane.session.queueEditPreparing)

        // A row that is not a preview opens straight from the snapshot.
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        await pane.settle(6)
        pane.session.queue = [["turnId": .string("q1"), "kind": .string("follow-up"), "text": .string("Short one")]]
        await pane.settle(8)
        pane.model.editQueued("q1", sessionID: pane.session.id)
        await pane.settle(10)
        XCTAssertEqual(pane.editor?.string, "Short one", "A short follow-up needs no read")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// When the whole message cannot be read, the chat says so and leaves the
    /// composer and its draft alone, instead of opening the preview to be
    /// saved over the original.
    @MainActor func testAFailedQueueReadLeavesTheComposerAloneWithANotice() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"),
                               "text": .string(String(repeating: "preview ", count: 120)), "textTruncated": .bool(true)]]
        pane.session.draft = "unsent thought"
        pane.model.queueReadOperation = { _, _ in throw HostError.failure("The helper is no longer running this chat.") }
        await pane.settle(14)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The failed read never ended") { pane.session.queueEditPreparing == nil && !pane.session.notice.isEmpty }
        await pane.settle(8)
        XCTAssertTrue(pane.session.notice.contains("could not be read"), "The chat says why it did not open: “\(pane.session.notice)”")
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The draft stays in the composer")
    }

    /// The message being rewritten can be sent before the rewrite is saved.
    /// An untouched rewrite gives the composer its draft back; a changed one
    /// stays in the composer, ahead of that draft, and the chat says why.
    /// This holds when the queue empties and its panel leaves the page.
    @MainActor func testRewritingStopsWhenTheFollowUpLeavesTheQueue() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.draft = "unsent thought"
        pane.session.queue = (0..<2).map { index in
            ["turnId": .string("q\(index)"), "kind": .string("follow-up"), "text": .string("Follow-up \(index)")]
        }
        await pane.settle(16)
        pane.model.editQueued("q1", sessionID: pane.session.id)
        await pane.settle(12)
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Follow-up 0")]]
        await pane.settle(16)
        XCTAssertNil(pane.session.queueEditingID, "A delivered follow-up ends the rewrite")
        XCTAssertEqual(pane.editor?.string, "unsent thought", "An untouched rewrite gives the draft back")
        XCTAssertFalse(pane.session.notice.contains("left the queue"), "Nothing typed was lost, so nothing to explain")

        pane.model.editQueued("q0", sessionID: pane.session.id)
        await pane.settle(12)
        pane.session.draft = "Follow-up 0, rewritten"
        await pane.settle(4)
        pane.session.queue = []
        await pane.settle(16)
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.editor?.string, "Follow-up 0, rewritten\n\nunsent thought", "Nothing typed is lost")
        XCTAssertTrue(pane.session.notice.contains("left the queue"), pane.session.notice)
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// Every queued follow-up stays on screen, inside the panel, with its
    /// steer, edit and remove controls, while the run that queued them goes on.
    @MainActor func testQueuedFollowUpsAllStayInsideThePanel() async throws {
        let pane = try Pane(width: 1000, height: 760); defer { pane.close() }
        pane.session.queue = (0..<5).map { index in
            ["turnId": .string("q\(index)"), "kind": .string(index == 0 ? "steering" : "followup"),
             "text": .string("Follow-up \(index): " + String(repeating: "a long queued instruction that keeps going. ", count: 3))]
        }
        pane.session.state = "running"
        await pane.settle(20)
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).count, 5, "Every queued submission is listed")
        let list = try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).first { String(describing: Swift.type(of: $0)).contains("ListCore") })
        let rows = Self.views(NSTableRowView.self, in: list)
        XCTAssertEqual(rows.count, 4, "The four follow-ups each take a row; steering is shown above them")
        let panel = list.convert(list.bounds, to: nil)
        var previous: CGRect?
        for row in rows.sorted(by: { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }) {
            let frame = row.convert(row.bounds, to: nil)
            XCTAssertLessThanOrEqual(frame.maxY, panel.maxY + 0.5, "A queued row is clipped by the panel \(panel)")
            XCTAssertGreaterThanOrEqual(frame.minY, panel.minY - 0.5, "A queued row is clipped by the panel \(panel)")
            if let previous { XCTAssertEqual(frame.maxY, previous.minY, accuracy: 0.5, "Queued rows must stack, not overlap") }
            previous = frame
            XCTAssertEqual(Self.controls(in: row).count, 3, "A follow-up offers steer, edit and remove while the run is going")
        }
        // The composer sits below the queue, never behind it.
        let field = try XCTUnwrap(Self.views(ComposerTextView.self, in: pane.hosted).first?.enclosingScrollView)
        XCTAssertFalse(field.convert(field.bounds, to: nil).intersects(panel), "The queue panel must not cover the composer")
    }
}

extension ConversationPaneTests {
    /// A rewrite in progress is the chat's composer draft: looking at another
    /// chat and coming back finds it still there, still a rewrite, and Cancel
    /// then brings back the draft set aside for it.
    @MainActor func testARewriteInProgressSurvivesLookingAtAnotherChat() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q1"), "kind": .string("follow-up"), "text": .string("Short one")]]
        pane.session.state = "running"
        pane.session.draft = "unsent thought"
        await pane.settle(12)
        pane.model.editQueued("q1", sessionID: pane.session.id)
        await pane.settle(10)
        let editor = try XCTUnwrap(pane.editor)
        XCTAssertTrue(pane.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(", rewritten", replacementRange: editor.selectedRange())
        await pane.settle(6)
        XCTAssertEqual(pane.editor?.string, "Short one, rewritten")
        // Another chat in the pane, then this one again.
        let other = SessionDisplay(id: "other")
        pane.hosted.rootView = ConversationPane(model: pane.model, session: other, chat: ChatRecord(id: "other", workspaceID: pane.chat.workspaceID, title: "Other", path: nil, profileID: pane.chat.profileID), paneWidth: 900)
        for _ in 0..<4 { await pane.settle(20); try await Task.sleep(for: .milliseconds(150)) }
        XCTAssertNotEqual(pane.editor?.string, "Short one, rewritten", "The other chat has its own composer")
        pane.hosted.rootView = ConversationPane(model: pane.model, session: pane.session, chat: pane.chat, paneWidth: 900)
        await pane.settle(10)
        XCTAssertEqual(pane.editor?.string, "Short one, rewritten", "The rewrite typed so far is still there")
        XCTAssertEqual(pane.session.queueEditingID, "q1", "It is still a rewrite of the queued message")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        await pane.settle(6)
        XCTAssertEqual(pane.editor?.string, "unsent thought", "Cancel brings back the draft set aside")
        pane.session.state = "idle"
        await pane.settle(4)
    }
}
