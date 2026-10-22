import XCTest
@testable import PiApp

final class DraftSizeTests: XCTestCase {
    @MainActor func testMaximumEscapedDraftsAndDisplacedEditsFlushAndReloadExactly() async throws {
        let root = scratchRoot("draft-size")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); view.selectionMetadataLoaded = true; model.displays[view.id] = view
        let store = try XCTUnwrap(model.store)
        for character in ["\"", "\\", "\u{001b}"] {
            let text = String(repeating: character, count: SubmissionLimits.messageBytes)
            view.draft = text
            view.draftBeforeEdit = DraftRecord(id: view.id, text: text)
            view.editingMessageID = "historical"
            let expected = view.savedDraft
            do { try await model.flushDrafts() }
            catch { XCTFail("Accepted-size edited and displaced drafts must flush: \(error)"); continue }
            let reopened = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
            let saved = try await reopened.get(DraftRecord.self, kind: "draft", id: view.id)
            let listed = try await reopened.list(DraftRecord.self, kind: "draft")
            XCTAssertTrue(saved == expected); XCTAssertTrue(listed == [expected])
            let intent = CommandIntent(id: "command", sessionID: view.id, turnID: "turn", text: text, state: "intent")
            try await store.recordSubmission(intent, draft: expected, draftVersion: view.draftVersion)
            let pending = try await reopened.list(CommandIntent.self, kind: "pending:chat")
            XCTAssertTrue(pending == [intent], "Submission intent must preserve every input byte")
            await reopened.close()
        }
    }

    func testMaximumQueuedRewriteAndParkedDraftRoundTrip() async throws {
        let root = scratchRoot("queued-draft-size")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        var draft = DraftRecord(id: "chat", text: String(repeating: "\u{001b}", count: SubmissionLimits.messageBytes))
        draft.queuedEdit = QueuedEditDraft(editID: "edit", turnID: "turn", rewrite: String(repeating: "\"", count: SubmissionLimits.messageBytes), original: "Original")
        try await store.put(draft, kind: "draft", id: draft.id)
        let read = try await store.get(DraftRecord.self, kind: "draft", id: draft.id)
        XCTAssertTrue(read == draft)
        await store.close()
    }
}
