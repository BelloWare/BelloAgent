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

    /// Rewriting a queued follow-up opens a field that needs more room than a
    /// one-line row. The panel has to grow with it: the row being typed into
    /// and the follow-ups under it must all stay inside the panel.
    @MainActor func testRewritingAQueuedFollowUpKeepsEveryRowInsideThePanel() async throws {
        // A narrow pane, as a side leaves, so the message really does wrap.
        let pane = try Pane(width: 620, height: 760); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = (0..<4).map { index in
            ["turnId": .string("q\(index)"), "kind": .string("follow-up"),
             "text": .string("Follow-up \(index): " + String(repeating: "a long queued instruction that keeps going. ", count: 6))]
        }
        await pane.settle(20)
        let field = try XCTUnwrap(Self.views(ComposerTextView.self, in: pane.hosted).first?.enclosingScrollView)
        let composer = field.convert(field.bounds, to: nil)
        func list() throws -> NSScrollView {
            try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).first { String(describing: Swift.type(of: $0)).contains("ListCore") })
        }
        let idle = try list().frame.height
        XCTAssertEqual(idle, QueuePanel.listHeight(rows: 4, editing: false), accuracy: 0.5)

        // The chat starts rewriting the second follow-up, exactly as the pencil does.
        pane.session.queueEditingID = "q1"
        await pane.settle(24)
        let editing = try list()
        XCTAssertGreaterThan(editing.frame.height, idle, "The panel makes room for the field being typed into")
        let panel = editing.convert(editing.bounds, to: nil)
        let rows = Self.views(NSTableRowView.self, in: editing)
        XCTAssertEqual(rows.count, 4, "Every follow-up stays on screen while one is rewritten")
        var previous: CGRect?
        for row in rows.sorted(by: { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }) {
            let frame = row.convert(row.bounds, to: nil)
            XCTAssertLessThanOrEqual(frame.maxY, panel.maxY + 0.5, "Row \(frame) is clipped by the panel \(panel)")
            XCTAssertGreaterThanOrEqual(frame.minY, panel.minY - 0.5, "Row \(frame) is clipped by the panel \(panel)")
            if let previous { XCTAssertEqual(frame.maxY, previous.minY, accuracy: 0.5, "Queued rows must stack, not overlap") }
            previous = frame
        }
        // The field itself is inside the panel, and tall enough to have grown.
        let fields = Self.views(NSView.self, in: editing).filter { String(describing: Swift.type(of: $0)).contains("TextField") }
        let edited = try XCTUnwrap(fields.first, "The row being rewritten shows its field")
        let editedFrame = edited.convert(edited.bounds, to: nil)
        XCTAssertLessThanOrEqual(editedFrame.maxY, panel.maxY + 0.5, "The field being typed into is clipped by the panel")
        XCTAssertGreaterThanOrEqual(editedFrame.minY, panel.minY - 0.5, "The field being typed into is clipped by the panel")
        XCTAssertGreaterThan(editedFrame.height, 30, "The field wraps the long message it is rewriting")
        XCTAssertFalse(panel.intersects(composer), "The queue panel must never reach the composer")
        print(String(format: "PERF queue panel %.0f -> %.0f points, field %.0f tall, composer at %.0f",
                     idle, editing.frame.height, editedFrame.height, composer.minY))
        // Leaving the edit gives the room back.
        pane.session.queueEditingID = nil
        await pane.settle(20)
        XCTAssertEqual(try list().frame.height, idle, accuracy: 0.5, "Closing the field gives the panel's room back")
    }

    /// A queued submission longer than the snapshot's preview: the field must
    /// wait for the helper's whole copy, refuse to save the preview, and show
    /// the complete text once it lands.
    @MainActor func testRewritingALongQueuedMessageWaitsForItsWholeText() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        let whole = "Rewrite the retry loop. " + String(repeating: "Here is another paragraph of the original instruction. ", count: 120)
        let preview = String(whole.prefix(1_024))
        XCTAssertGreaterThan(whole.count, preview.count, "The fixture really is longer than its preview")
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"),
                               "text": .string(preview), "textBytes": .number(Double(whole.utf8.count)), "textTruncated": .bool(true)]]
        pane.session.state = "running"
        let gate = AsyncGate()
        pane.model.queueReadOperation = { sessionID, turnID in
            XCTAssertEqual(turnID, "q0"); XCTAssertEqual(sessionID, pane.session.id)
            await gate.wait()
            return ["turnId": .string(turnID), "text": .string(whole), "textBytes": .number(Double(whole.utf8.count))]
        }
        await pane.settle(16)
        XCTAssertTrue(QueuedMessage.from(pane.session.queue)[0].truncated, "The row says its text is a preview")

        pane.session.queueEditingID = "q0"
        await pane.settle(10)
        func field() -> NSTextField? {
            Self.views(NSTextField.self, in: pane.hosted).first { $0.isEditable || !$0.isEnabled }
        }
        let editing = try XCTUnwrap(field(), "The row opens a field")
        XCTAssertFalse(editing.isEnabled, "The field is held while the whole message is being read, so the preview cannot be saved over it")
        XCTAssertEqual(editing.stringValue, preview, "Until it lands, the field shows what the snapshot carried")
        await gate.open()
        try await waitFor("The whole message never reached the field") { field()?.stringValue == whole }
        await pane.settle(8)
        let loaded = try XCTUnwrap(field())
        XCTAssertTrue(loaded.isEnabled, "Once the whole message is in, the field takes edits again")
        XCTAssertEqual(loaded.stringValue, whole, "The field holds the complete message, not the first kilobyte")

        // A row that is not a preview opens straight from the snapshot.
        pane.session.queueEditingID = nil
        await pane.settle(6)
        pane.session.queue = [["turnId": .string("q1"), "kind": .string("follow-up"), "text": .string("Short one")]]
        await pane.settle(8)
        pane.session.queueEditingID = "q1"
        await pane.settle(10)
        let short = try XCTUnwrap(field())
        XCTAssertTrue(short.isEnabled, "A short follow-up needs no read")
        XCTAssertEqual(short.stringValue, "Short one")
    }

    /// When the whole message cannot be read, the chat says so and closes the
    /// field instead of leaving the preview open to be saved over the original.
    @MainActor func testAFailedQueueReadClosesTheFieldWithANotice() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"),
                               "text": .string(String(repeating: "preview ", count: 120)), "textTruncated": .bool(true)]]
        pane.model.queueReadOperation = { _, _ in throw HostError.failure("The helper is no longer running this chat.") }
        await pane.settle(14)
        pane.session.queueEditingID = "q0"
        try await waitFor("The failed read never closed the field") { pane.session.queueEditingID == nil }
        await pane.settle(8)
        XCTAssertTrue(pane.session.notice.contains("could not be read"), "The chat says why it did not open: “\(pane.session.notice)”")
        XCTAssertTrue(Self.views(NSTextField.self, in: pane.hosted).allSatisfy { !$0.isEditable },
                      "No field is left open on the row")
    }

    /// The chat drops the row it was rewriting when that follow-up is delivered
    /// or removed, instead of leaving an open field on a row that is gone.
    @MainActor func testRewritingStopsWhenTheFollowUpLeavesTheQueue() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = (0..<2).map { index in
            ["turnId": .string("q\(index)"), "kind": .string("follow-up"), "text": .string("Follow-up \(index)")]
        }
        await pane.settle(16)
        pane.session.queueEditingID = "q1"
        await pane.settle(12)
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Follow-up 0")]]
        await pane.settle(16)
        XCTAssertNil(pane.session.queueEditingID, "A delivered follow-up closes the field that was rewriting it")
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
    /// The field rewriting a queued follow-up lives in a panel rebuilt for
    /// each chat. Looking at another chat and coming back showed the original
    /// message again, and the rewrite typed so far was gone.
    @MainActor func testARewriteInProgressSurvivesLookingAtAnotherChat() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q1"), "kind": .string("follow-up"), "text": .string("Short one")]]
        pane.session.state = "running"
        await pane.settle(12)
        pane.session.queueEditingID = "q1"
        await pane.settle(10)
        func field() -> NSTextField? { Self.views(NSTextField.self, in: pane.hosted).first { $0.isEditable } }
        let editing = try XCTUnwrap(field())
        XCTAssertTrue(pane.window.makeFirstResponder(editing))
        let editor = try XCTUnwrap(editing.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(", rewritten", replacementRange: editor.selectedRange())
        await pane.settle(6)
        XCTAssertEqual(field()?.stringValue, "Short one, rewritten")
        // Another chat in the pane, then this one again: the panel is rebuilt.
        let other = SessionDisplay(id: "other")
        pane.hosted.rootView = ConversationPane(model: pane.model, session: other, chat: ChatRecord(id: "other", workspaceID: pane.chat.workspaceID, title: "Other", path: nil, profileID: pane.chat.profileID), paneWidth: 900)
        // Long enough for the panel's exit transition to finish: until it
        // has, coming back would revive the same panel rather than build one.
        for _ in 0..<4 { await pane.settle(20); try await Task.sleep(for: .milliseconds(150)) }
        XCTAssertNil(field(), "The other chat has no queue panel")
        pane.hosted.rootView = ConversationPane(model: pane.model, session: pane.session, chat: pane.chat, paneWidth: 900)
        await pane.settle(10)
        XCTAssertEqual(field()?.stringValue, "Short one, rewritten", "The rewrite typed so far is still there")
        pane.session.queueEditingID = nil
        await pane.settle(6)
        XCTAssertNil(pane.session.queueEditText, "Closing the field forgets the rewrite")
        pane.session.state = "idle"
        await pane.settle(4)
    }
}
