import XCTest
import SQLite3
@testable import PiApp

final class RecoveredDraftTests: XCTestCase {
    @MainActor private func fixture() async throws -> (WorkspaceModel, SessionDisplay, MetadataStore, CommandIntent) {
        let root = scratchRoot("recovered-draft")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let store = try XCTUnwrap(model.store)
        let view = SessionDisplay(id: "chat"); view.selectionMetadataLoaded = true; view.draft = "Current draft"
        model.displays[view.id] = view
        let intent = CommandIntent(id: "command", sessionID: view.id, turnID: "turn", text: "Interrupted message", state: "intent")
        try await store.recordSubmission(intent, draft: view.savedDraft, draftVersion: view.draftVersion)
        view.recovered = [intent]; view.uncertain = true
        return (model, view, store, intent)
    }
    private func image(_ n: Int) -> AttachmentRecord { .init(id: "i\(n)", path: "/fixture/i\(n).png", sha256: "h", bytes: 1, mimeType: "image/png") }
    private func skill(_ n: Int) -> SkillChip { .init(id: "s\(n)", name: "s\(n)", path: "/fixture/s\(n)", contentHash: "h", metadataHash: "m") }

    @MainActor func testFullComposerKeepsTheWholeIntentAndExplainsWhatDidNotFit() async throws {
        let (model, view, store, original) = try await fixture()
        view.attachments = (0..<4).map(image); view.skills = (0..<8).map(skill)
        var intent = original; intent.attachments = [image(4)]; intent.skills = [skill(8)]
        try await store.recordSubmission(intent, draft: view.savedDraft, draftVersion: view.draftVersion); view.recovered = [intent]
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery answered") { !view.notice.isEmpty || view.recovered.isEmpty }
        XCTAssertEqual(view.draft, "Current draft"); XCTAssertEqual(view.attachments, (0..<4).map(image)); XCTAssertEqual(view.skills, (0..<8).map(skill))
        XCTAssertEqual(view.recovered, [intent]); XCTAssertTrue(view.uncertain)
        XCTAssertTrue(view.notice.contains("5 images")); XCTAssertTrue(view.notice.contains("9 skills"))
        let saved = try await store.get(CommandIntent.self, kind: "pending:chat", id: intent.id)
        XCTAssertEqual(saved, intent, "Nothing is discarded when the recovered submission cannot fit")
    }

    @MainActor func testRecoveryIsDurableWhenTheBannerClears() async throws {
        let (model, view, store, intent) = try await fixture()
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery finished") { view.recovered.isEmpty }
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "Current draft\n\nInterrupted message", "Clearing the banner promises the text is already on disk")
        XCTAssertFalse(view.uncertain)
        let left = try await store.list(CommandIntent.self, kind: "pending:chat")
        XCTAssertTrue(left.isEmpty)
    }

    @MainActor func testClosingAKeptSideWaitsForRecoveryBeforeSavingItsDraft() async throws {
        let (model, view, store, original) = try await fixture()
        let parent = SessionDisplay(id: "parent"); model.displays[parent.id] = parent
        model.sides[parent.id] = SideRecord(id: view.id, parentID: parent.id, workspaceID: "w", profileID: "p", title: "Side", kept: true)
        model.selectedID = parent.id; model.selected = parent; model.focusedSessionID = view.id
        view.attachments = [image(0)]; view.skills = [skill(0)]
        var intent = original; intent.attachments = [image(1)]; intent.skills = [skill(1)]
        try await store.recordSubmission(intent, draft: view.savedDraft, draftVersion: view.draftVersion); view.recovered = [intent]
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        model.recoverDraft(intent, insert: true)
        let recovery = try XCTUnwrap(model.draftWrites.recoveries[view.id])
        try await eventually("recovery is committing") { view.recoveringDraft }
        model.closeSide(view.id)
        // Let closure reach the blocked store while recovery still owns the
        // draft. Its write must not capture the pre-recovery composer.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(view.loading); XCTAssertEqual(model.sides[parent.id]?.id, view.id)
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        await recovery.value
        // A crash has no later debounce to repair a stale close write.
        let debounce = model.draftWrites.tasks[view.id]; debounce?.cancel(); await debounce?.value
        try await eventually("side closed") { model.sides[parent.id] == nil && !view.loading }
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:chat", id: intent.id)
        XCTAssertEqual(saved?.text, "Current draft\n\nInterrupted message")
        XCTAssertEqual(saved?.attachments, [image(0), image(1)]); XCTAssertEqual(saved?.skills, [skill(0), skill(1)])
        XCTAssertEqual(saved?.submissionReviews, [intent.id]); XCTAssertNil(pending)
        XCTAssertTrue(view.recovered.isEmpty); XCTAssertEqual(model.focusedSessionID, parent.id)
    }

    @MainActor func testFailedTransactionLeavesDraftIntentAndBannerForRetry() async throws {
        let (model, view, store, intent) = try await fixture()
        try Self.sql("CREATE TRIGGER refuse_recovery BEFORE DELETE ON records WHEN OLD.kind='pending:chat' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: model.root)
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery error") { model.error != nil }
        // Let any debounce settle: it must not save a half-completed recovery.
        for task in model.draftWrites.tasks.values { await task.value }
        XCTAssertEqual(view.draft, "Current draft"); XCTAssertEqual(view.recovered, [intent]); XCTAssertTrue(view.uncertain)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:chat", id: intent.id)
        XCTAssertEqual(saved?.text, "Current draft"); XCTAssertEqual(pending, intent)
        try Self.sql("DROP TRIGGER refuse_recovery", root: model.root)
        model.recoverDraft(intent, insert: true)
        try await eventually("retry finished") { view.recovered.isEmpty }
        XCTAssertEqual(view.draft, "Current draft\n\nInterrupted message", "Retry inserts the text exactly once")
    }

    @MainActor func testRecoveryWaitsForAnEditAndDoesNotChangeItsParkedDraft() async throws {
        let (model, view, store, intent) = try await fixture()
        view.queueEditingID = "queued"; view.queueEditID = "edit"
        view.draftBeforeQueueEdit = view.savedDraft; view.draft = "Rewrite"
        model.recoverDraft(intent, insert: true)
        try await eventually("edit refusal") { !view.notice.isEmpty || view.recovered.isEmpty }
        XCTAssertEqual(view.draft, "Rewrite"); XCTAssertEqual(view.draftBeforeQueueEdit?.text, "Current draft")
        XCTAssertEqual(view.recovered, [intent])
        let pending = try await store.get(CommandIntent.self, kind: "pending:chat", id: intent.id)
        XCTAssertEqual(pending, intent)
    }

    @MainActor func testDoubleInsertAndTypingDuringRecoveryKeepBothMessagesOnce() async throws {
        let (model, view, store, intent) = try await fixture()
        model.draftChanged(view)
        model.recoverDraft(intent, insert: true); model.recoverDraft(intent, insert: true)
        view.draft += " with newer typing"; model.draftChanged(view)
        try await model.flushDrafts()
        try await eventually("recovery finished") { view.recovered.isEmpty }
        XCTAssertEqual(view.draft, "Current draft with newer typing\n\nInterrupted message")
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, view.draft)
    }

    @MainActor func testRecoveryPreservesIndentationAndTrailingNewlines() async throws {
        let (model, view, store, original) = try await fixture()
        var intent = original; intent.text = "    indented code\n\n"
        try await store.put(intent, kind: "pending:chat", id: intent.id); view.recovered = [intent]
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery finished") { view.recovered.isEmpty }
        XCTAssertEqual(view.draft, "Current draft\n\n    indented code\n\n")
    }

    @MainActor func testUnreconciledQueuedEditKeepsRecoveryPending() async throws {
        let (model, view, _, intent) = try await fixture()
        view.unreconciledQueuedEdit = QueuedEditDraft(editID: "edit", turnID: "queued", rewrite: "Rewrite", original: "Original")
        model.recoverDraft(intent, insert: true)
        XCTAssertEqual(view.recovered, [intent]); XCTAssertFalse(view.notice.isEmpty)
        XCTAssertEqual(view.draft, "Current draft")
    }

    @MainActor func testLateImageConversionWaitsForTheValidatedRecovery() async throws {
        let (model, view, store, original) = try await fixture()
        view.attachments = (0..<3).map(image)
        var intent = original; intent.attachments = [image(3)]; view.recovered = [intent]
        try await store.recordSubmission(intent, draft: view.savedDraft, draftVersion: view.draftVersion)
        // Hold only this fixture database while the store waits to begin its
        // transaction, so a completed paste can arrive at that exact point.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery is committing") { view.recoveringDraft }
        let side = SideRecord(id: "side", parentID: view.id, workspaceID: "w", profileID: "p", title: "Side", kept: false)
        model.sides[view.id] = side
        XCTAssertThrowsError(try model.bringBack("Side summary", from: side.id, replace: true))
        model.receiveAttachments([image(4)], into: view)
        XCTAssertEqual(view.attachments.count, 3, "The paste waits behind the frozen candidate")
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await eventually("recovery finished and paste answered") { view.recovered.isEmpty && view.notice.contains("could not be attached") }
        XCTAssertEqual(view.attachments, (0..<4).map(image))
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.attachments, view.attachments)
    }

    @MainActor func testByteAndArgumentLimitsKeepTheIntent() async throws {
        let (model, view, store, original) = try await fixture()
        var intent = original
        view.attachments = (10..<13).map { AttachmentRecord(id: "i\($0)", path: "/fixture/i\($0).png", sha256: "h", bytes: 8 * 1024 * 1024, mimeType: "image/png") }
        // Four images, one byte over the 32 MiB a message holds.
        intent.attachments = [AttachmentRecord(id: "other", path: "/fixture/other", sha256: "h", bytes: 8 * 1024 * 1024 + 1, mimeType: "image/png")]
        var chip = skill(1); chip.arguments = String(repeating: "x", count: 16_385); intent.skills = [chip]
        intent.text = String(repeating: "x", count: SubmissionLimits.messageBytes)
        try await store.put(intent, kind: "pending:chat", id: intent.id); view.recovered = [intent]
        model.recoverDraft(intent, insert: true)
        XCTAssertEqual(view.recovered, [intent]); XCTAssertEqual(view.draft, "Current draft")
        XCTAssertTrue(view.notice.contains("256 KiB")); XCTAssertTrue(view.notice.contains("more than 32 MiB of images")); XCTAssertTrue(view.notice.contains("arguments over 16 KiB"))
    }

    /// Four images of 8 MiB, 32 MiB in all, are what a message holds: the
    /// recovered submission joins a draft that has three of them.
    @MainActor func testFourImagesOfEightMiBStillInsert() async throws {
        let (model, view, store, original) = try await fixture()
        let images = (10..<14).map { AttachmentRecord(id: "i\($0)", path: "/fixture/i\($0).png", sha256: "h", bytes: 8 * 1024 * 1024, mimeType: "image/png") }
        view.attachments = Array(images.prefix(3))
        var intent = original; intent.attachments = [images[3]]
        // Versioned like the fixture's own record: an unversioned draft write
        // is another instance's and would rightly stop the recovery.
        try await store.recordSubmission(intent, draft: view.savedDraft, draftVersion: view.draftVersion); view.recovered = [intent]
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery finished") { view.recovered.isEmpty }
        XCTAssertEqual(view.attachments, images, view.notice)
    }

    @MainActor func testAStaleBannerCannotInsertAKnownAcceptedCommand() async throws {
        let (model, view, _, intent) = try await fixture()
        view.receipts = [["commandId": .string(intent.id), "state": .string("dispatched")]]
        model.recoverDraft(intent, insert: true)
        await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, "Current draft"); XCTAssertTrue(view.recovered.isEmpty)
    }

    @MainActor func testAcceptanceWhileWaitingForTheOldDraftWriteCancelsRecovery() async throws {
        for evidence in ["reply", "receipt", "retired"] {
            let (model, view, store, intent) = try await fixture()
            var release: CheckedContinuation<Void, Never>?
            let previous = Task { await withCheckedContinuation { release = $0 } }
            try await eventually("old draft write suspended") { release != nil }
            model.draftWrites.tasks[view.id] = previous
            model.recoverDraft(intent, insert: true)
            let recovery = try XCTUnwrap(model.draftWrites.recoveries[view.id])
            if evidence == "reply" { view.acceptedCommands.insert(intent.id) }
            else if evidence == "receipt" { view.receipts = [["commandId": .string(intent.id), "state": .string("dispatched")]] }
            else { view.recovered = [] }
            release?.resume(); await recovery.value
            XCTAssertEqual(view.draft, "Current draft", evidence)
            let draft = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(draft?.text, "Current draft", evidence)
        }
    }
    @MainActor func testAcceptanceDuringRecoveryCommitKeepsADurableReviewGate() async throws {
        let (model, view, store, original) = try await fixture()
        var intent = original; intent.draftReviewTracked = true
        try await store.put(intent, kind: "pending:chat", id: intent.id); view.recovered = [intent]
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        model.recoverDraft(intent, insert: true)
        try await eventually("recovery candidate frozen") { view.recoveringDraft }
        view.acceptedCommands.insert(intent.id); view.recovered = []; view.uncertain = false
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        await model.draftWrites.recoveries[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.submissionReviews, [intent.id], "The gate commits before the intent is removed")
        XCTAssertEqual(view.submissionReviews, [intent.id])
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "Fixture", profileID: "p")]
        var asked = 0; model.questions.answer = { _ in asked += 1; return false }
        model.send(sessionID: view.id); XCTAssertEqual(asked, 1)
        try await eventually("send settled") { !view.loading }
    }

    static func sql(_ sql: String, root: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("desktop.sqlite").path, &db) == SQLITE_OK, let db else { throw StoreError.unavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
    }
}
