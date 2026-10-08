import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - The follow-up queue

extension ConversationPaneTests {
    /// The hit-testing shapes SwiftUI puts behind its controls.
    @MainActor static func controls(in view: NSView) -> [NSView] {
        let mine = (view as? PiKit.ButtonBase).map { $0.isHidden ? [] : [$0] } ?? []
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
            try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).first { $0 is QueueListScrollView })
        }
        let idle = try list().frame.height
        XCTAssertEqual(idle, QueuePanel.listHeight(rows: 4), accuracy: 0.5)
        let queued = QueuedMessage.from(pane.session.queue)[1]

        pane.model.editQueued("q1", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q1" }
        await pane.settle(24)
        XCTAssertEqual(pane.editor?.string, queued.text, "The composer holds the queued message")
        XCTAssertEqual(pane.session.savedDraft.text, "unsent thought", "The draft saved for the chat stays the one typed")
        XCTAssertEqual(try list().frame.height, idle, accuracy: 0.5, "No row grows: the rewrite is in the composer")
        XCTAssertTrue(Self.views(NSTextField.self, in: try list()).allSatisfy { !$0.isEditable }, "The panel opens no field of its own")
        let panel = try list().convert(try list().bounds, to: nil)
        let field = try XCTUnwrap(pane.editor?.enclosingScrollView)
        XCTAssertFalse(panel.intersects(field.convert(field.bounds, to: nil)), "The queue panel must never reach the composer")

        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        try await waitFor("Cancel never finished") { pane.session.queueEditingID == nil }
        await pane.settle(12)
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
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        await pane.settle(10)
        let editor = try XCTUnwrap(pane.editor)
        XCTAssertTrue(pane.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(", rewritten", replacementRange: editor.selectedRange())
        await pane.settle(6)
        type("\r", into: editor, keyCode: 36)
        try await waitFor("Return never saved the rewrite") { pane.session.queueEditingID == nil }
        await pane.settle(10)
        XCTAssertEqual(pane.edits.calls.last?.params["text"]?.string, "Short one, rewritten", "Return saved the rewrite")
        XCTAssertTrue(pane.session.sendingRows.isEmpty, "Nothing was queued as a new message")
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The set-aside draft comes back")
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// The composer takes a queued message only once the helper holds the
    /// chat's pending input and has read the whole message: a long one
    /// arrives complete, not as its preview, and until then the composer and
    /// its draft are left alone.
    @MainActor func testRewritingALongQueuedMessageWaitsForTheHoldAndItsWholeText() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        let whole = "Rewrite the retry loop. " + String(repeating: "Here is another paragraph of the original instruction. ", count: 120)
        let preview = String(whole.prefix(1_024))
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"),
                               "text": .string(preview), "textBytes": .number(Double(whole.utf8.count)), "textTruncated": .bool(true)]]
        pane.session.state = "running"
        pane.session.draft = "unsent thought"
        pane.edits.wholeTexts["q0"] = whole
        let gate = AsyncGate(); pane.edits.gates["queue.edit.begin"] = gate
        await pane.settle(16)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        await pane.settle(10)
        XCTAssertEqual(pane.session.queueEditPreparing, "q0", "The row shows the hold being taken")
        XCTAssertNil(pane.session.queueEditingID, "Nothing is open for rewriting until the helper answers")
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The composer keeps the draft meanwhile")
        await gate.open()
        try await waitFor("The whole message never reached the composer") { pane.session.queueEditingID == "q0" }
        await pane.settle(8)
        XCTAssertEqual(pane.editor?.string, whole, "The composer holds the complete message, not the first kilobyte")
        XCTAssertNil(pane.session.queueEditPreparing)
        XCTAssertEqual(pane.edits.calls.first?.params["turnId"]?.string, "q0")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        try await waitFor("Cancel never finished") { pane.session.queueEditingID == nil }
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// A message the run already took can't be edited: the chat says so and
    /// leaves the composer and its draft alone. With no answer at all, the
    /// same edit is asked after, so a hold the helper took is never left.
    @MainActor func testARefusedOrUnansweredBeginLeavesTheComposerAlone() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        pane.session.draft = "unsent thought"
        pane.edits.failures["queue.edit.begin"] = HostError.rejected("queue_delivering", "That message is already being sent")
        await pane.settle(14)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The refused Begin never ended") { pane.session.queueEditPreparing == nil && !pane.session.notice.isEmpty }
        XCTAssertTrue(pane.session.notice.contains("already being sent"), pane.session.notice)
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The draft stays in the composer")

        pane.session.notice = ""
        pane.edits.failures["queue.edit.begin"] = HostError.failure("The helper stopped answering.")
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The unanswered Begin was never asked after") { pane.edits.count("queue.edit.cancel") == 1 && !pane.session.notice.isEmpty }
        let lost = pane.edits.calls.last { $0.method == "queue.edit.begin" }?.params["editId"]
        XCTAssertEqual(pane.edits.calls.first { $0.method == "queue.edit.status" }?.params["editId"], lost, "the status asked is that edit's")
        XCTAssertEqual(pane.edits.calls.last?.params["editId"], lost, "never granted, it is cancelled by its identity so a late Begin can't take the hold")
        XCTAssertTrue(pane.session.notice.contains("not opened"), pane.session.notice)

        // Granted, but the answer lost: asked after, it opens; nothing is released.
        pane.session.notice = ""
        pane.edits.lostReplies.insert("queue.edit.begin")
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The granted edit never opened") { pane.session.queueEditingID == "q0" }
        XCTAssertNotNil(pane.edits.hold, "the hold stays the reader's")
        XCTAssertEqual(pane.edits.count("queue.edit.cancel"), 1, "nothing more was cancelled")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        try await waitFor("Cancel never finished") { pane.session.queueEditingID == nil }
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.editor?.string, "unsent thought")
    }

    /// Save keeps the editor, and the rewrite, until the helper confirms:
    /// another Return sends nothing more; a refused Save keeps the rewrite and
    /// the hold; an unanswered one says so; a Save that goes through closes
    /// the editor and brings the draft back.
    @MainActor func testSaveClosesTheEditorOnlyWhenTheHelperConfirms() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Short one")]]
        pane.session.draft = "unsent thought"
        await pane.settle(12)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        pane.session.draft = "Short one, rewritten"

        pane.edits.failures["queue.edit.save"] = HostError.rejected("fixture_write", "The journal refused the write.")
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await waitFor("The refused Save never ended") { !pane.session.queueEditResolving && !pane.session.notice.isEmpty }
        XCTAssertEqual(pane.session.queueEditingID, "q0", "A refused Save keeps the editor")
        XCTAssertEqual(pane.session.draft, "Short one, rewritten", "and the rewrite")
        XCTAssertTrue(pane.session.notice.contains("still paused"), pane.session.notice)

        pane.edits.failures["queue.edit.save"] = HostError.failure("No answer")
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await waitFor("The unanswered Save was never asked after") { !pane.session.queueEditResolving && pane.session.notice.contains("did not reach") }
        XCTAssertEqual(pane.session.queueEditingID, "q0", "the helper says the edit is still open: the editor stays")

        let gate = AsyncGate(); pane.edits.gates["queue.edit.save"] = gate
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        await pane.settle(6)
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        pane.model.submitComposer(intent: .followUp, sessionID: pane.session.id)
        await pane.settle(6)
        XCTAssertTrue(pane.session.queueEditResolving)
        XCTAssertEqual(pane.session.queueEditingID, "q0", "The editor waits for the answer")
        XCTAssertEqual(pane.editor?.string, "Short one, rewritten")
        XCTAssertEqual(pane.edits.count("queue.edit.save"), 3, "repeated presses send no second Save")
        XCTAssertTrue(pane.session.sendingRows.isEmpty, "Return queued nothing new")
        let activityBeforeSave = pane.model.record(pane.session.id)?.lastActivityAt
        await gate.open()
        try await waitFor("The confirmed Save never closed the editor") { pane.session.queueEditingID == nil }
        XCTAssertGreaterThan(pane.model.record(pane.session.id)?.lastActivityAt ?? 0, activityBeforeSave ?? 0,
                             "a saved rewrite is activity: the chat moves up its sidebar group (0.1.122)")
        await pane.settle(6)
        XCTAssertEqual(pane.editor?.string, "unsent thought", "The set-aside draft comes back")
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).first?.text, "Short one, rewritten")
        XCTAssertNil(pane.session.queueEditHold)
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// What is typed after Save is pressed and before the helper answers is
    /// not lost: the rewrite saved is the one pressed, the rest stays.
    @MainActor func testTextTypedWhileASaveIsAnsweredIsKept() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Short one")]]
        pane.session.draft = "unsent thought"
        await pane.settle(10)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        pane.session.draft = "Saved version"
        let gate = AsyncGate(); pane.edits.gates["queue.edit.save"] = gate
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        await pane.settle(4)
        XCTAssertTrue(pane.editor.map { !$0.isEditable } ?? false, "the rewrite holds still while the helper answers")
        pane.session.draft = "Saved version, and more"
        await gate.open()
        try await waitFor("The Save never finished") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.edits.calls.last { $0.method == "queue.edit.save" }?.params["text"]?.string, "Saved version")
        XCTAssertEqual(pane.session.draft, "Saved version, and more\n\nunsent thought", "nothing typed is lost")
    }

    /// Resume Edit after a reopen whose answer never came brings back the
    /// rewrite recovered for that edit, not the original.
    @MainActor func testResumingAnEditBringsBackItsRecoveredRewrite() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        pane.session.unreconciledQueuedEdit = QueuedEditDraft(editID: "left", turnID: "q0", rewrite: "", original: "Queued")
        await pane.settle(8)
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "left")
        try await waitFor("Resume Edit never opened") { pane.session.queueEditingID == "q0" }
        XCTAssertEqual(pane.session.draft, "", "an empty rewrite comes back empty, as it was saved")
        XCTAssertNil(pane.session.unreconciledQueuedEdit)
    }

    /// A Begin answered after a newer report says its hold went (Cancel Edit
    /// from the row, say) opens no editor.
    @MainActor func testALateBeginAnswerOpensNoEditorAfterTheHoldWent() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        let gate = AsyncGate(); pane.edits.gates["queue.edit.begin"] = gate
        await pane.settle(8)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        await pane.settle(4)
        pane.session.adoptQueueEditHold(nil, revision: 99)
        await gate.open()
        try await waitFor("The Begin never ended") { pane.session.queueEditPreparing == nil }
        await pane.settle(6)
        XCTAssertNil(pane.session.queueEditingID, "an answer older than the newest report opens nothing")
    }

    /// Reopened after a Save whose answer was lost while the reader typed
    /// on: what was saved is not that rewrite, so the rewrite stays.
    @MainActor func testAReopenAfterAnEarlierSaveKeepsTheNewerRewrite() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("e")])
        _ = try await pane.edits.handler(pane.session)("queue.edit.save", pane.session.id, ["editId": .string("e"), "text": .string("First save")])
        let reopened = SessionDisplay(id: pane.session.id)
        pane.model.queueEditOperation = pane.edits.handler(reopened)
        reopened.restoreDraft(DraftRecord(id: reopened.id, text: "unsent thought"))
        await pane.model.reconcileQueuedEdit(reopened, QueuedEditDraft(editID: "e", turnID: "q0", rewrite: "Typed on after", original: "Queued"))
        XCTAssertEqual(reopened.draft, "Typed on after\n\nunsent thought")
        // Typed back to the original after the earlier Save: still kept.
        let back = SessionDisplay(id: pane.session.id)
        pane.model.queueEditOperation = pane.edits.handler(back)
        back.restoreDraft(DraftRecord(id: back.id, text: ""))
        await pane.model.reconcileQueuedEdit(back, QueuedEditDraft(editID: "e", turnID: "q0", rewrite: "Queued", original: "Queued"))
        XCTAssertEqual(back.draft, "Queued", "what was saved is not this rewrite, so it stays")
        let same = SessionDisplay(id: pane.session.id)
        pane.model.queueEditOperation = pane.edits.handler(same)
        same.restoreDraft(DraftRecord(id: same.id, text: "unsent thought"))
        await pane.model.reconcileQueuedEdit(same, QueuedEditDraft(editID: "e", turnID: "q0", rewrite: "First save", original: "Queued"))
        XCTAssertEqual(same.draft, "unsent thought", "the rewrite that was saved needs nothing more")
    }

    /// A Save that took effect but whose answer was lost: asked after, it is
    /// known saved, and the editor closes as on any Save.
    @MainActor func testASaveWhoseAnswerWasLostIsKnownSaved() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Short one")]]
        pane.session.draft = "unsent thought"
        await pane.settle(10)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        pane.session.draft = "Short one, saved"
        pane.edits.lostReplies.insert("queue.edit.save")
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await waitFor("The lost Save was never settled") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.session.draft, "unsent thought")
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).first?.text, "Short one, saved")
        XCTAssertEqual(pane.edits.count("queue.edit.save"), 1, "asked after, not saved twice")
    }

    /// A Save never confirmed, even after asking: only the same Save may
    /// follow, never a Cancel or another text that could cross it.
    @MainActor func testAnUnconfirmedSaveAllowsOnlyItsOwnRetry() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Short one")]]
        await pane.settle(10)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        pane.session.draft = "Short one, saved"
        pane.edits.failures["queue.edit.save"] = HostError.failure("No answer")
        pane.edits.unansweredStatuses = 3
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await waitFor("The unanswered Save never gave up asking", seconds: 10) { !pane.session.queueEditResolving && pane.session.notice.contains("not known yet") }
        XCTAssertEqual(pane.session.queueEditPendingOperation, "save")
        XCTAssertEqual(pane.session.savedDraft.queuedEdit?.pending, "save", "the saved draft says what is unconfirmed")
        let saves = pane.edits.count("queue.edit.save")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        await pane.settle(4)
        XCTAssertEqual(pane.edits.count("queue.edit.cancel"), 0, "no Cancel crosses an unconfirmed Save")
        // The Cancel asks after the Save instead, which the helper now
        // answers: the edit is still open, so the Save is not pending any more.
        try await waitFor("The guard never settled") { !pane.session.queueEditResolving && pane.session.queueEditPendingOperation == nil }
        XCTAssertEqual(pane.session.queueEditingID, "q0")
        // The helper now answers: still open, so the Save may be sent again.
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await waitFor("The repeated Save never finished") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.edits.count("queue.edit.save"), saves + 1)
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).first?.text, "Short one, saved")
    }

    /// An earlier edit whose outcome is unknown is settled, by its own
    /// identity, before another can begin.
    @MainActor func testAnEarlierUncertainEditIsSettledBeforeAnother() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")],
                              ["turnId": .string("q1"), "kind": .string("follow-up"), "text": .string("Other")]]
        await pane.settle(8)
        pane.session.unreconciledQueuedEdit = QueuedEditDraft(editID: "earlier", turnID: "q0", rewrite: "", original: "", beginOnly: true)
        pane.model.editQueued("q1", sessionID: pane.session.id)
        XCTAssertTrue(pane.session.notice.contains("earlier queued edit"), pane.session.notice)
        try await waitFor("The earlier edit was never settled") { pane.session.unreconciledQueuedEdit == nil }
        XCTAssertEqual(pane.edits.calls.first?.method, "queue.edit.status")
        XCTAssertEqual(pane.edits.calls.first?.params["editId"]?.string, "earlier")
        XCTAssertFalse(pane.edits.calls.contains { $0.method == "queue.edit.begin" }, "no second edit began beside it")
        pane.model.editQueued("q1", sessionID: pane.session.id)
        try await waitFor("The new edit never opened") { pane.session.queueEditingID == "q1" }
    }

    /// A side lost while rewriting a queued message gives its parent both
    /// its own draft and the rewrite.
    @MainActor func testALostSideGivesBackItsDraftAndItsRewrite() {
        let side = SessionDisplay(id: "side")
        side.queueEditingID = "q0"; side.queueEditOriginal = "Queued"
        side.draftBeforeQueueEdit = DraftRecord(id: "side", text: "the side's own draft")
        side.draft = "Queued, rewritten"
        let moving = WorkspaceModel.unsentDraft(of: side, to: "parent")
        XCTAssertEqual(moving.text, "the side's own draft\n\nQueued, rewritten")
        side.draft = "Queued"
        XCTAssertEqual(WorkspaceModel.unsentDraft(of: side, to: "parent").text, "the side's own draft", "an unchanged rewrite adds nothing")
        WorkspaceModel.consumeUnsentDraft(of: side)
        XCTAssertTrue(WorkspaceModel.unsentDraft(of: side, to: "parent").isBlank, "once moved, both parts are gone from the side: nothing moves twice")
    }

    /// An image chosen before a queued edit began, arriving after: it joins
    /// the draft set aside, not the rewrite, and comes back with it.
    @MainActor func testAnImageArrivingDuringAQueuedEditJoinsTheSetAsideDraft() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        pane.session.draft = "unsent thought"
        await pane.settle(8)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        let image = AttachmentRecord(id: "late", path: "/tmp/late.png", sha256: "00", bytes: 3, mimeType: "image/png")
        pane.model.receiveAttachments([image], into: pane.session)
        XCTAssertTrue(pane.session.attachments.isEmpty, "the rewrite takes no image")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        try await waitFor("Cancel never finished") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.session.attachments, [image], "it comes back with the draft it was chosen for")
        XCTAssertEqual(pane.session.draft, "unsent thought")
    }

    /// Cancel Edit on an edit with a change sent and never answered asks
    /// after that change first; an older status settles nothing.
    @MainActor func testCancelEditWaitsForAnUnansweredChange() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        var record = QueuedEditDraft(editID: "left", turnID: "q0", rewrite: "rewrite", original: "Queued", pending: "save")
        record.sentDigest = QueuedEditDraft.digest("rewrite")
        pane.session.unreconciledQueuedEdit = record
        await pane.settle(6)
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        try await waitFor("The pending change was never asked after") { pane.edits.count("queue.edit.status") == 1 }
        XCTAssertEqual(pane.edits.count("queue.edit.cancel"), 0, "no Cancel crosses the unanswered Save")

        // An older report than one already taken settles nothing.
        let stale = SessionDisplay(id: pane.session.id)
        stale.adoptQueueEditHold(QueueEditHold(["editId": .string("other"), "turnId": .string("q0")]), revision: 999)
        pane.model.queueEditOperation = pane.edits.handler(stale)
        let unknown = QueuedEditDraft(editID: "never", turnID: "q0", rewrite: "", original: "", beginOnly: true)
        await pane.model.reconcileQueuedEdit(stale, unknown)
        XCTAssertEqual(stale.unreconciledQueuedEdit, unknown, "the record stays to be asked after again")
        XCTAssertFalse(pane.edits.calls.contains { $0.method == "queue.edit.cancel" && $0.params["editId"]?.string == "never" }, "nothing is cancelled on an old answer")
    }

    /// Cancel Edit on a hold a restart left, still being answered: Resume
    /// Edit of that edit waits, so no editor opens on a hold being let go.
    @MainActor func testResumeWaitsForACancelEditInFlight() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        let gate = AsyncGate(); pane.edits.gates["queue.edit.cancel"] = gate
        await pane.settle(6)
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        try await waitFor("The Cancel never started") { pane.session.queueEditCancelling == "left" }
        XCTAssertEqual(pane.session.savedDraft.queuedEdit?.pending, "cancel", "the saved draft says a Cancel is unanswered")
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "left")
        XCTAssertEqual(pane.edits.count("queue.edit.begin"), 1, "no Resume while the Cancel is unanswered")
        await gate.open()
        try await waitFor("The Cancel never settled") { pane.session.queueEditCancelling == nil && pane.session.unreconciledQueuedEdit == nil }
        XCTAssertNil(pane.session.queueEditingID, "no editor opened on a released hold")
    }

    /// Resume Edit asked, then Cancel Edit before it answers: no editor
    /// opens, and the edit is cancelled by its identity. After a Cancel left
    /// unanswered, Resume asks after it instead of crossing it.
    @MainActor func testCancelEditDuringAResumeAbandonsIt() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        let gate = AsyncGate(); pane.edits.gates["queue.edit.begin"] = gate
        await pane.settle(6)
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "left")
        await pane.settle(4)
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        pane.edits.gates["queue.edit.begin"] = nil
        await gate.open()
        try await waitFor("The abandoned Resume never cancelled") { pane.edits.hold == nil && pane.session.unreconciledQueuedEdit == nil }
        XCTAssertNil(pane.session.queueEditingID, "no editor opened")

        // With a recovered rewrite and a Cancel left unanswered, the record
        // keeps the rewrite; with a Save left unanswered, no Cancel is sent.
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("kept")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("kept"), "turnId": .string("q0")]), revision: pane.edits.revision)
        pane.session.unreconciledQueuedEdit = QueuedEditDraft(editID: "kept", turnID: "q0", rewrite: "my rewrite", original: "Queued")
        let held = AsyncGate(); pane.edits.gates["queue.edit.begin"] = held
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "kept")
        await pane.settle(4)
        pane.edits.failures["queue.edit.cancel"] = HostError.failure("No answer")
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        pane.edits.gates["queue.edit.begin"] = nil
        await held.open()
        try await waitFor("The abandoned Resume never tried to cancel") { pane.edits.failures["queue.edit.cancel"] == nil && pane.session.unreconciledQueuedEdit?.pending == "cancel" && pane.session.queueEditCancelling == nil }
        XCTAssertEqual(pane.session.unreconciledQueuedEdit?.rewrite, "my rewrite", "the recovered rewrite is kept until the Cancel is confirmed")
        _ = try await pane.edits.handler(pane.session)("queue.edit.cancel", pane.session.id, ["editId": .string("kept")])
        pane.session.unreconciledQueuedEdit = nil
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("saving")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("saving"), "turnId": .string("q0")]), revision: pane.edits.revision)
        pane.session.unreconciledQueuedEdit = QueuedEditDraft(editID: "saving", turnID: "q0", rewrite: "x", original: "Queued", pending: "save", sent: "x")
        let cancels = pane.edits.count("queue.edit.cancel")
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        try await waitFor("The pending Save was never asked after") { pane.edits.calls.last?.method == "queue.edit.status" }
        XCTAssertEqual(pane.edits.count("queue.edit.cancel"), cancels, "no Cancel crosses an unanswered Save")
        pane.session.unreconciledQueuedEdit = nil
        _ = try await pane.edits.handler(pane.session)("queue.edit.cancel", pane.session.id, ["editId": .string("saving")])

        // A Cancel the helper never answered: Resume asks after it.
        pane.session.queueEditingID = nil
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("second")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("second"), "turnId": .string("q0")]), revision: pane.edits.revision)
        pane.edits.failures["queue.edit.cancel"] = HostError.failure("No answer")
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        try await waitFor("The unanswered Cancel never ended") { pane.session.queueEditCancelling == nil && pane.session.unreconciledQueuedEdit?.pending == "cancel" }
        let begins = pane.edits.count("queue.edit.begin")
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "second")
        try await waitFor("The unanswered Cancel was never settled") { pane.edits.hold == nil && pane.session.unreconciledQueuedEdit == nil }
        XCTAssertEqual(pane.edits.count("queue.edit.begin"), begins, "Resume never crossed the Cancel")
        XCTAssertNil(pane.session.queueEditingID)
    }

    /// A reopen's status question and a Resume both still on their way when
    /// Cancel Edit is pressed: neither opens an editor, and the edit is let go.
    @MainActor func testCancelEditBeatsAnEarlierStatusAndAResume() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        let status = AsyncGate(), begin = AsyncGate()
        pane.edits.gates["queue.edit.status"] = status; pane.edits.gates["queue.edit.begin"] = begin
        await pane.settle(4)
        let record = QueuedEditDraft(editID: "left", turnID: "q0", rewrite: "my rewrite", original: "Queued")
        let reconciling = Task { await pane.model.reconcileQueuedEdit(pane.session, record) }
        await pane.settle(2)
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "left")
        await pane.settle(2)
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        pane.edits.gates = [:]
        await status.open(); await reconciling.value
        XCTAssertNil(pane.session.queueEditingID, "the earlier status opened nothing")
        await begin.open()
        try await waitFor("The edit was never let go") { pane.edits.hold == nil && pane.session.unreconciledQueuedEdit == nil }
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertTrue(pane.session.draft.contains("my rewrite"), "the rewrite that differs from the message stays")
    }

    /// Cancel Edit twice during a Resume: the second confirms, the rewrite
    /// comes back once; the Resume answering late (unanswered) brings it back
    /// no second time, and another edit's editor is left alone.
    @MainActor func testALateAbandonedResumeRestoresNothingTwice() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")],
                              ["turnId": .string("q1"), "kind": .string("follow-up"), "text": .string("Other")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        pane.session.unreconciledQueuedEdit = QueuedEditDraft(editID: "left", turnID: "q0", rewrite: "my rewrite", original: "Queued")
        let begin = AsyncGate(); pane.edits.gates["queue.edit.begin"] = begin
        await pane.settle(4)
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "left")
        await pane.settle(2)
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        pane.model.cancelHeldQueueEdit(sessionID: pane.session.id)
        try await waitFor("The second Cancel never settled") { pane.edits.hold == nil && pane.session.unreconciledQueuedEdit == nil }
        XCTAssertEqual(pane.session.draft.components(separatedBy: "my rewrite").count - 1, 1, "the rewrite comes back once")
        // Another edit opens meanwhile; then the old Resume goes unanswered.
        pane.edits.gates["queue.edit.begin"] = nil
        pane.model.editQueued("q1", sessionID: pane.session.id)
        try await waitFor("The other edit never opened") { pane.session.queueEditingID == "q1" }
        pane.edits.failures["queue.edit.begin"] = HostError.failure("No answer")
        await begin.open()
        await pane.settle(10)
        XCTAssertEqual(pane.session.draft, "Other", "the other edit's text is untouched")
        XCTAssertEqual((pane.session.draftBeforeQueueEdit?.text ?? "").components(separatedBy: "my rewrite").count - 1, 1, "and the rewrite is not added a second time")
    }

    /// A reopen that finds an unanswered Save keeps saying so in the draft
    /// it saves, before and after the editor opens again.
    @MainActor func testAReopenedEditKeepsItsUnansweredSaveInTheSavedDraft() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("e")])
        let reopened = SessionDisplay(id: pane.session.id)
        reopened.queue = pane.session.queue
        pane.model.queueEditOperation = pane.edits.handler(reopened)
        let record = QueuedEditDraft(editID: "e", turnID: "q0", rewrite: "rewrite", original: "Queued", pending: "save", sent: "rewrite")
        await pane.model.reconcileQueuedEdit(reopened, record)
        XCTAssertEqual(reopened.queueEditingID, "q0")
        XCTAssertEqual(reopened.savedDraft.queuedEdit?.pending, "save")
        XCTAssertEqual(reopened.savedDraft.queuedEdit?.sentDigest, QueuedEditDraft.digest("rewrite"))
    }

    /// Cancel pressed while the helper is still taking the hold: when it
    /// answers, the hold is let go of rather than left with no editor.
    @MainActor func testCancellingBeforeTheHoldIsAnsweredLetsItGo() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        pane.session.draft = "unsent thought"
        let gate = AsyncGate(); pane.edits.gates["queue.edit.begin"] = gate
        await pane.settle(10)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        await pane.settle(4)
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        await gate.open()
        try await waitFor("The granted hold was never let go of") { pane.edits.count("queue.edit.cancel") == 1 && pane.edits.hold == nil }
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.editor?.string, "unsent thought")
    }

    /// A rewrite in progress is saved with the chat's draft. Reopened, an
    /// edit the helper still holds is the composer's again with that
    /// rewrite; one that ended keeps a changed rewrite in the composer.
    @MainActor func testAReopenedChatReconcilesItsQueuedRewrite() async throws {
        let pane = try Pane(width: 900, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        pane.session.draft = "unsent thought"
        await pane.settle(10)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        pane.session.draft = "Queued, rewritten"
        let saved = pane.session.savedDraft
        XCTAssertEqual(saved.text, "unsent thought", "the draft saved is the one set aside")
        let record = try XCTUnwrap(saved.queuedEdit)
        XCTAssertEqual(record.rewrite, "Queued, rewritten"); XCTAssertEqual(record.turnID, "q0"); XCTAssertTrue(record.isOriginal("Queued"))

        // As a reopen finds it: the draft restored, the edit still held.
        let reopened = SessionDisplay(id: pane.session.id)
        reopened.queue = pane.session.queue
        pane.model.queueEditOperation = pane.edits.handler(reopened)
        reopened.restoreDraft(saved)
        await pane.model.reconcileQueuedEdit(reopened, record)
        XCTAssertEqual(reopened.queueEditingID, "q0", "a held edit is the composer's again")
        XCTAssertEqual(reopened.draft, "Queued, rewritten", "with the rewrite as it was saved")
        XCTAssertEqual(reopened.savedDraft.text, "unsent thought")

        // Ended meanwhile (cancelled elsewhere): the changed rewrite stays.
        let ended = SessionDisplay(id: pane.session.id)
        _ = try await pane.edits.handler(ended)("queue.edit.cancel", ended.id, ["editId": .string(record.editID)])
        ended.restoreDraft(saved)
        pane.model.queueEditOperation = pane.edits.handler(ended)
        await pane.model.reconcileQueuedEdit(ended, record)
        XCTAssertNil(ended.queueEditingID)
        XCTAssertEqual(ended.draft, "Queued, rewritten\n\nunsent thought", "nothing typed is lost")
        XCTAssertNil(ended.savedDraft.queuedEdit, "reconciled, the record goes")
    }

    /// An edit the helper holds that this composer doesn't (a restart left
    /// it): the row says so and offers to resume or cancel it; resuming
    /// takes the same edit, so its text comes back.
    @MainActor func testAHoldLeftByARestartCanBeResumed() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Queued")]]
        _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
        await pane.settle(12)
        pane.model.editQueued("q1-other", sessionID: pane.session.id)
        XCTAssertTrue(pane.session.notice.contains("Another queued message"), "a second edit waits for the first")
        pane.model.editQueued("q0", sessionID: pane.session.id, resuming: "left")
        try await waitFor("Resume Edit never opened the edit") { pane.session.queueEditingID == "q0" }
        XCTAssertEqual(pane.session.queueEditID, "left")
        XCTAssertEqual(pane.editor?.string, "Queued")
        pane.model.cancelQueuedEdit(sessionID: pane.session.id)
        try await waitFor("Cancel never finished") { pane.session.queueEditingID == nil && pane.edits.hold == nil }
    }

    /// A row gone from a snapshot doesn't end the edit: the helper holds the
    /// message. If the edit had ended elsewhere, Save says so and keeps the
    /// rewrite in the composer.
    @MainActor func testARowGoneFromASnapshotKeepsTheEditUntilTheHelperAnswers() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.draft = "unsent thought"
        pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Follow-up 0")]]
        await pane.settle(12)
        pane.model.editQueued("q0", sessionID: pane.session.id)
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q0" }
        pane.session.draft = "Follow-up 0, rewritten"
        pane.session.queue = []
        await pane.settle(12)
        XCTAssertEqual(pane.session.queueEditingID, "q0", "a snapshot without the row doesn't end the edit")
        // Ended elsewhere meanwhile.
        _ = try await pane.edits.handler(pane.session)("queue.edit.remove", pane.session.id, ["editId": .string(pane.session.queueEditID ?? "")])
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await waitFor("The Save never ended") { pane.session.queueEditingID == nil }
        await pane.settle(6)
        XCTAssertEqual(pane.editor?.string, "Follow-up 0, rewritten\n\nunsent thought", "Nothing typed is lost")
        XCTAssertTrue(pane.session.notice.contains("already ended"), pane.session.notice)
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// Every waiting message is in the panel, steering and follow-ups under
    /// their own headings, each row with its detail, steer, edit and remove
    /// controls while the run goes on; past four and a half rows the list
    /// scrolls, and the last row can be reached.
    @MainActor func testQueuedMessagesAllStayReachableInsideTheBoundedPanel() async throws {
        let pane = try Pane(width: 1000, height: 760); defer { pane.close() }
        pane.session.queue = (0..<5).map { index in
            ["turnId": .string("q\(index)"), "kind": .string(index == 0 ? "steering" : "followup"),
             "text": .string("Follow-up \(index): " + String(repeating: "a long queued instruction that keeps going. ", count: 3))]
        }
        pane.session.state = "running"
        await pane.settle(20)
        let list = try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).first { $0 is QueueListScrollView })
        XCTAssertEqual(list.frame.height, QueuePanel.listHeight(rows: 5, sections: 2), accuracy: 0.5)
        XCTAssertLessThan(list.frame.height, CGFloat(5) * QueuePanel.rowHeight + 2 * QueuePanel.sectionHeaderHeight, "the list is capped")
        let panel = list.convert(list.bounds, to: nil)
        let rows = Self.views(NSTableRowView.self, in: list).filter { !$0.isGroupRowStyle }
        XCTAssertFalse(rows.isEmpty)
        // Heading rows have no controls; each message row offers detail, edit
        // and remove, and a follow-up also steer while the run goes on.
        let counts = rows.filter { $0.convert($0.bounds, to: nil).intersects(panel) }.map { Self.controls(in: $0).count }.filter { $0 > 0 }
        XCTAssertFalse(counts.isEmpty)
        XCTAssertTrue(counts.allSatisfy { $0 >= 3 }, "every message row keeps its controls: \(counts)")
        // Scrolled to its end, the last row is inside the panel.
        list.documentView?.scroll(NSPoint(x: 0, y: list.documentView?.bounds.maxY ?? 0))
        await pane.settle(10)
        let table = try XCTUnwrap(Self.views(NSTableView.self, in: list).first)
        let last = table.rect(ofRow: table.numberOfRows - 1)
        XCTAssertTrue(list.contentView.documentVisibleRect.intersects(last), "the last waiting message can be scrolled to")
        let field = try XCTUnwrap(Self.views(ComposerTextView.self, in: pane.hosted).first?.enclosingScrollView)
        XCTAssertFalse(field.convert(field.bounds, to: nil).intersects(panel), "The queue panel must not cover the composer")
    }

    /// At the 920×600 minimum window with 1, 5, 20 and 64 messages waiting,
    /// the panel stays within its bound: the transcript keeps reading space
    /// and the composer stays where it is.
    @MainActor func testTheQueueKeepsTheTranscriptReadableAtTheMinimumWindow() async throws {
        // A tall draft takes the room the queue gives up: twenty waiting
        // leave the window no taller than one does.
        var heights: [CGFloat] = []
        for count in [1, 20] {
            let pane = try Pane(width: 920, height: 600); defer { pane.close() }
            pane.session.state = "running"
            pane.session.queue = (0..<count).map { ["turnId": .string("q\($0)"), "kind": .string("follow-up"), "text": .string("Message \($0)")] }
            pane.session.draft = (0..<20).map { "Line \($0) of a long draft" }.joined(separator: "\n")
            await pane.settle(30)
            heights.append(pane.window.contentLayoutRect.height)
        }
        XCTAssertEqual(heights[1], heights[0], accuracy: 1, "the queue's length never pushes the window taller (\(heights))")
        for count in [1, 5, 20, 64] {
            let pane = try Pane(width: 920, height: 600); defer { pane.close() }
            pane.session.state = "running"
            pane.session.queue = (0..<count).map { index in
                ["turnId": .string("q\(index)"), "kind": .string(index % 4 == 0 ? "steering" : "follow-up"), "text": .string("Message \(index)")]
            }
            await pane.settle(16)
            let list = try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).first { $0 is QueueListScrollView })
            let sections = count > 1 ? 2 : 1
            XCTAssertLessThanOrEqual(list.frame.height, QueuePanel.visibleRows * QueuePanel.rowHeight + CGFloat(sections) * QueuePanel.sectionHeaderHeight + 0.5, "\(count) waiting")
            let transcript = try XCTUnwrap(Self.views(NSScrollView.self, in: pane.hosted).filter { !($0 is QueueListScrollView) && $0.documentView !== pane.editor }.max { $0.frame.height < $1.frame.height })
            XCTAssertGreaterThanOrEqual(transcript.frame.height, 150, "\(count) waiting leave the transcript \(transcript.frame.height) pt")
        }
    }

    /// Collapsing the panel hides its rows and keeps the count and the
    /// state in its header; it asks the helper for nothing.
    @MainActor func testCollapsingTheQueueIsPresentationOnly() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.state = "idle"; pane.session.queuePaused = true
        pane.session.queue = (0..<3).map { ["turnId": .string("q\($0)"), "kind": .string("follow-up"), "text": .string("Message \($0)")] }
        await pane.settle(12)
        let before = pane.session.queue
        pane.session.queueCollapsed = true
        await pane.settle(40)
        XCTAssertNil(Self.views(NSScrollView.self, in: pane.hosted).first { $0 is QueueListScrollView }, "collapsed: no rows")
        XCTAssertEqual(QueueTiming(pane.session).header(count: 3), "Paused · 3")
        XCTAssertEqual(pane.session.queue, before)
        XCTAssertTrue(pane.edits.calls.isEmpty)
        pane.session.queueCollapsed = false
        await pane.settle(12)
        XCTAssertNotNil(Self.views(NSScrollView.self, in: pane.hosted).first { $0 is QueueListScrollView })
    }

    /// The headings say when messages go, and a hold or a pause comes before
    /// any promise to send.
    @MainActor func testQueueTimingNeverPromisesWhatAHoldPrevents() async throws {
        let session = SessionDisplay(id: "timing")
        session.state = "running"
        XCTAssertEqual(QueueTiming(session), .running)
        XCTAssertEqual(QueueTiming(session).steering, "Steering · after the current tool batch")
        XCTAssertEqual(QueueTiming(session).followUps, "Follow-ups · when this run finishes")
        session.adoptQueueEditHold(QueueEditHold(["editId": .string("e"), "turnId": .string("q")]), revision: 1)
        XCTAssertEqual(QueueTiming(session), .editing, "an edit hold comes before the running promise")
        XCTAssertEqual(QueueTiming(session).header(count: 2), "Paused while a message is edited · 2")
        XCTAssertEqual(QueueTiming(session).steering, "Steering · waits until resumed")
        session.adoptQueueEditHold(nil, revision: 2)
        session.state = "idle"; session.queuePaused = true
        XCTAssertEqual(QueueTiming(session), .paused)
        session.queuePaused = false
        XCTAssertEqual(QueueTiming(session).followUps, "Follow-ups · next")
        session.state = "error"
        XCTAssertEqual(QueueTiming(session), .failed)
        session.state = "interrupted"
        XCTAssertEqual(QueueTiming(session), .paused, "a lost helper's queue waits for Resume")
    }

    /// The detail view shows a waiting message whole with the choices it
    /// was queued with, not the composer's current ones; legacy rows say
    /// the connection default. Reading it takes no hold; a message that
    /// leaves meanwhile says so.
    @MainActor func testTheDetailShowsTheWholeMessageAndItsCapturedChoices() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = [
            ["turnId": .string("a"), "kind": .string("follow-up"), "text": .string("Model A, high"), "model": .string("model-a"), "thinkingLevel": .string("high")],
            ["turnId": .string("b"), "kind": .string("follow-up"), "text": .string("Legacy row")],
        ]
        await pane.settle(10)
        func detail(_ id: String) -> QueuedMessageDetailView {
            let view = QueuedMessageDetailView(model: pane.model, session: pane.session, turnID: id)
            view.frame = NSRect(x: 0, y: 0, width: 340, height: 360); view.layoutSubtreeIfNeeded(); return view
        }
        func text(_ view: NSView) -> String { (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElementProtocol).flatMap { ($0 as AnyObject).accessibilityLabel?() ?? nil } }.joined(separator: " | ") }
        let a = QueuedMessage.from(pane.session.queue)[0], b = QueuedMessage.from(pane.session.queue)[1]
        XCTAssertEqual(a.model, "model-a"); XCTAssertEqual(a.thinkingLevel, "high")
        XCTAssertNil(b.model); XCTAssertNil(b.thinkingLevel)
        let shownA = detail("a"); _ = detail("b")
        await pane.settle(6)
        // Each choice is one element to VoiceOver, name and value together.
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let spoken = descendants(shownA).filter { $0.isAccessibilityElement() }.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(spoken.contains("Model, model-a"), "\(spoken)")
        XCTAssertTrue(spoken.contains("Reasoning, High"), "\(spoken)")
        XCTAssertTrue(pane.edits.calls.isEmpty, "reading a detail takes no hold")
        XCTAssertEqual(pane.session.draft, "", "and leaves the composer alone")
        pane.session.queue.removeAll { $0["turnId"]?.string == "a" }
        XCTAssertNil(QueuedMessage.from(pane.session.queue).first { $0.id == "a" }, "the detail of a message that left shows that it left")
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
        try await waitFor("The edit never opened") { pane.session.queueEditingID == "q1" }
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
        try await waitFor("Cancel never finished") { pane.session.queueEditingID == nil }
        await pane.settle(6)
        XCTAssertEqual(pane.editor?.string, "unsent thought", "Cancel brings back the draft set aside")
        pane.session.state = "idle"
        await pane.settle(4)
    }
}
