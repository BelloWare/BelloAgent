import XCTest
@testable import PiApp

@MainActor final class DraftConcurrencyTests: XCTestCase {
    private func fixture(saved: Bool = true) async throws -> (WorkspaceModel, SessionDisplay, WorkspaceModel, SessionDisplay) {
        let root = scratchRoot("draft-concurrency")
        let first = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let second = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Shared chat", profileID: "p")
        try await first.store?.put(chat, kind: "chat", id: chat.id)
        if saved { try await first.store?.put(DraftRecord(id: chat.id, text: ""), kind: "draft", id: chat.id) }
        for model in [first, second] {
            model.prewarmsHelpers = false; model.chats = [chat]
            let view = SessionDisplay(id: chat.id); model.displays[chat.id] = view
            let loaded = try await model.reconcileSubmissionDraft(chat, view: view, current: { true })
            XCTAssertTrue(loaded); XCTAssertTrue(view.selectionMetadataLoaded)
        }
        return (first, try XCTUnwrap(first.displays[chat.id]), second, try XCTUnwrap(second.displays[chat.id]))
    }

    func testUnchangedStaleInstanceDoesNotOverwriteAnotherInstancesDraft() async throws {
        for saved in [false, true] {
            let (first, a, second, _) = try await fixture(saved: saved)
            a.draft = "Saved by A"; first.draftChanged(a)
            await first.draftWrites.tasks[a.id]?.value
            try await first.flushDrafts()
            try await second.flushDrafts()
            let persisted = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
            XCTAssertEqual(persisted?.text, "Saved by A")
        }
    }

    func testConflictingEditsStayInTheirComposerAndRefuseTheQuitFlush() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Saved by A"; try await first.flushDrafts()
        b.draft = "Still owned by B"
        do { try await second.flushDrafts(); XCTFail("A conflicting draft must not silently replace another instance's text") } catch { }
        XCTAssertEqual(b.draft, "Still owned by B")
        let persisted = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(persisted?.text, "Saved by A")
        // A debounce must use the same optimistic check as Quit.
        second.draftChanged(b); await second.draftWrites.tasks[b.id]?.value
        let afterDebounce = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(afterDebounce?.text, "Saved by A"); XCTAssertNotNil(second.error)
    }

    func testUnchangedLegacyEditedDraftDoesNotBecomeANewWrite() async throws {
        let (first, a, second, b) = try await fixture()
        let legacy = DraftRecord(id: a.id, text: "Edited message", edit: MessageEditDraft(messageID: "m", originalText: "Parked draft"))
        try await first.store?.put(legacy, kind: "draft", id: a.id)
        for (model, view) in [(first, a), (second, b)] {
            view.selectionMetadataLoaded = false
            _ = try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true })
        }
        a.draft = "A newer edit"; try await first.flushDrafts()
        try await second.flushDrafts()
        let saved = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(saved?.text, "A newer edit")
    }

    func testFlushWaitsForAnAdmittedWriteBeforeSkippingAnUnchangedDraft() async throws { try await admittedWrite(flush: true) }
    func testDebounceWaitsForAnAdmittedWriteBeforeSkippingAnUnchangedDraft() async throws { try await admittedWrite(flush: false) }

    private func admittedWrite(flush: Bool) async throws {
        let (model, view, _, _) = try await fixture()
        let store = try XCTUnwrap(model.store), gate = AsyncGate(), token = UUID()
        let revision = try await store.reserveRevision(kind: "draft", id: view.id)
        // A write already dispatched to the actor is not withdrawn by Task
        // cancellation. Hold its completion while the composer returns to
        // the initially loaded empty draft.
        let admitted = Task {
            defer { if model.draftWrites.tokens[view.id] == token { model.draftWrites.tasks[view.id] = nil; model.draftWrites.tokens[view.id] = nil } }
            await gate.wait()
            try? await store.put(DraftRecord(id: view.id, text: "Older queued write"), kind: "draft", id: view.id, revision: revision, draftVersion: view.draftVersion)
        }
        model.draftWrites.tasks[view.id] = admitted; model.draftWrites.tokens[view.id] = token
        var finished = false
        let latest = Task {
            if flush { try await model.flushDrafts() }
            else { model.draftChanged(view); await model.draftWrites.tasks[view.id]?.value }
            finished = true
        }
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(finished, "An admitted older write must settle before an unchanged draft can skip saving")
        await gate.open(); await admitted.value; try await latest.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "", "Undoing back to the loaded draft must survive the older in-flight write")
    }

    func testFailedSubmissionTransactionDoesNotAdvanceTheDraftVersion() async throws {
        let (model, view, _, _) = try await fixture()
        let store = try XCTUnwrap(model.store), revision = view.draftVersion.snapshot.revision
        let invalid = CommandIntent(id: "bad", sessionID: view.id, turnID: "t", text: String(repeating: "x", count: MetadataStore.inputRecordByteLimit), state: "intent")
        do {
            try await store.recordSubmission(invalid, draft: DraftRecord(id: view.id, text: "Rolled back"), draftVersion: view.draftVersion)
            XCTFail("The oversized intent must roll back its draft too")
        } catch { XCTAssertEqual(error as? StoreError, .invalidRecord) }
        XCTAssertEqual(view.draftVersion.snapshot.revision, revision)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "")
        view.draft = "Retry after rollback"; try await model.flushDrafts()
        let retried = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(retried?.text, view.draft)
    }

    func testConcurrentDraftFlushesHaveOneWinnerAndPreserveTheOtherInput() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "A"; b.draft = "B"
        let one = Task { () -> Bool in do { try await first.flushDrafts(); return true } catch { return false } }
        let two = Task { () -> Bool in do { try await second.flushDrafts(); return true } catch { return false } }
        let results = await [one.value, two.value]
        XCTAssertEqual(results.filter { $0 }.count, 1, "The draft comparison and write must be atomic across store actors")
        XCTAssertEqual(a.draft, "A"); XCTAssertEqual(b.draft, "B")
        let persisted = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(persisted?.text, results[0] ? "A" : "B")
    }
}
