import XCTest
@testable import PiApp

final class WorkspaceDurabilityTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("workspace-durability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor func testDraftDebounceAndQuitFlushSurviveFutureClockRecordsWithoutRestoringOlderText() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let store = try XCTUnwrap(model.store), view = SessionDisplay(id: "chat")
        model.displays[view.id] = view
        let future = Int64(Date().timeIntervalSince1970 * 1_000_000) + 1_000_000_000_000
        try await store.put(DraftRecord(id: view.id, text: "Before clock correction"), kind: "draft", id: view.id, revision: future)
        view.draft = "After clock correction"; model.draftChanged(view)
        try await Task.sleep(for: .milliseconds(200))
        let debounced = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(debounced?.text, view.draft)
        view.draft = "Pending older edit"; model.draftChanged(view)
        view.draft = "Last edit before quitting"
        view.editingMessageID = "original-message"; view.draftBeforeEdit = .init(id: view.id, text: "Displaced draft")
        try await model.flushDrafts()
        try await Task.sleep(for: .milliseconds(200))
        let flushed = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(flushed?.text, "Last edit before quitting")
        XCTAssertEqual(flushed?.edit?.messageID, "original-message"); XCTAssertEqual(flushed?.edit?.originalText, "Displaced draft")
        XCTAssertNil(model.error)
        await store.close()
        do { try await model.flushDrafts(); XCTFail("Quit must learn that the draft was not saved") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        XCTAssertEqual(view.draft, "Last edit before quitting")
        model.shutdown(); try await model.traces.close()
    }

    /// Quitting with text in a chat that never sent used to write the draft
    /// under an id no launch would ever list again: the text was gone and the
    /// row stayed behind forever. An empty never-sent chat still writes nothing.
    @MainActor func testQuittingWithTextInANeverSentChatKeepsBothTheChatAndItsDraft() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let store = try XCTUnwrap(model.store)
        let typed = ChatRecord(id: "typed-in", workspaceID: "w", title: "New chat", path: nil, profileID: "p")
        let untouched = ChatRecord(id: "never-touched", workspaceID: "w", title: "New chat", path: nil, profileID: "p")
        model.chats = [typed, untouched]
        model.pendingChatIDs = [typed.id, untouched.id]
        let view = SessionDisplay(id: typed.id); view.draft = "Half-written question I want back"
        model.displays[typed.id] = view
        model.displays[untouched.id] = SessionDisplay(id: untouched.id)

        try await model.flushDrafts()

        let savedDraft = try await store.get(DraftRecord.self, kind: "draft", id: typed.id)
        let savedChat = try await store.get(ChatRecord.self, kind: "chat", id: typed.id)
        XCTAssertEqual(savedDraft?.text, view.draft)
        XCTAssertEqual(savedChat?.id, typed.id, "a draft must never be written under an id no launch will list")
        XCTAssertFalse(model.pendingChatIDs.contains(typed.id))
        let emptyChat = try await store.get(ChatRecord.self, kind: "chat", id: untouched.id)
        let emptyDraft = try await store.get(DraftRecord.self, kind: "draft", id: untouched.id)
        XCTAssertNil(emptyChat, "an empty never-sent chat still writes nothing")
        XCTAssertNil(emptyDraft)

        // The next launch finds the chat and the text together.
        let reopened = try await store.loadChats()
        XCTAssertEqual(reopened.map(\.id), [typed.id])
        model.shutdown(); try await model.traces.close(); await store.close()
    }

    @MainActor func testUnavailableStoreStopsCopyHandoffAndAutomaticHostOpening() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("desktop.sqlite"), withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        // The database opens off the main actor, so "there is no storage" is
        // something launch finds out, not something construction blocks on.
        let ready = await model.prepareStore()
        XCTAssertFalse(ready); XCTAssertNil(model.store)
        XCTAssertTrue(model.error?.contains("Cannot open desktop metadata") == true)
        var profile = ProfileRecord(); profile.id = "p"; profile.modelId = "fixture"
        let chat = ChatRecord(id: "source", workspaceID: "w", title: "Source", path: root.appendingPathComponent("source.jsonl").path, profileID: profile.id)
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        model.profiles = [profile]; model.profileChoice = profile.id; model.chats = [chat]; model.selectedID = chat.id
        model.error = nil; model.continueCopy()
        XCTAssertTrue(model.error?.contains("Desktop storage") == true)
        model.error = nil; model.portableHandoff()
        XCTAssertTrue(model.error?.contains("Desktop storage") == true)
        do { _ = try await model.open(chat); XCTFail("Opening must require durable desktop storage") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertEqual(model.chats, [chat])
        model.shutdown(); try await model.traces.close()
    }

    @MainActor func testFailedSavedSideCloseKeepsDraftAndEditingFailureKeepsReadOnlyMode() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let store = try XCTUnwrap(model.store), view = SessionDisplay(id: "side")
        let chat = ChatRecord(id: view.id, workspaceID: "w", title: "Side", path: nil, profileID: "p", toolMode: "read-only", parentSessionID: "parent")
        try await store.put(chat, kind: "chat", id: chat.id)
        model.chats = [chat]; model.displays[view.id] = view; view.draft = "Unsent side draft"
        model.sides["parent"] = .init(id: view.id, parentID: "parent", workspaceID: "w", profileID: "p", title: "Side", kept: true)
        await store.close()
        model.closeSide(view.id)
        for _ in 0..<100 where view.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.sides["parent"], "A failed save must not dismiss the only visible draft")
        XCTAssertEqual(view.draft, "Unsent side draft"); XCTAssertNotNil(model.error)
        model.sides.removeAll()
        do { try await model.enableEditingAfterConfirmation(view.id); XCTFail("A failed save must not enable editing in memory") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        XCTAssertEqual(model.chats.first?.toolMode, "read-only")
        XCTAssertFalse(view.loading, "A failed save must release the composer gate")
        XCTAssertNotEqual(view.notice, "Editing tools apply to the next turn.")
        model.shutdown(); try await model.traces.close()
    }

    @MainActor func testBadSideRecoveryDoesNotBlockOtherValidSavedChildren() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let store = try XCTUnwrap(model.store)
        for (id, journalID) in [("valid", "valid"), ("damaged", "wrong-identity")] {
            let path = root.appendingPathComponent(id + ".jsonl")
            try Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(journalID)\"}\n".utf8).write(to: path)
            let chat = ChatRecord(id: id, workspaceID: "w", title: id, path: path.path, profileID: "p", toolMode: "read-only", parentSessionID: "parent")
            try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: id)
        }
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.chats.map(\.id), ["valid"])
        let damaged = try await store.get(SideKeepIntent.self, kind: "side-keep", id: "damaged")
        let registered = try await store.get(SideKeepIntent.self, kind: "side-keep", id: "valid")
        XCTAssertNotNil(damaged); XCTAssertNil(registered); XCTAssertNotNil(model.error)
        model.sides["parent"] = .init(id: "unregistered", parentID: "parent", workspaceID: "w", profileID: "p", title: "Unregistered")
        await model.applySideStatus(id: "unregistered", result: ["ephemeral": .bool(false), "path": .string("missing")])
        XCTAssertTrue(model.error?.contains("recovery intent") == true)
        XCTAssertFalse(model.sides["parent"]?.kept ?? true)
        model.shutdown(); try await model.traces.close(); await store.close()
    }

    @MainActor func testFailedHistoryNavigationDoesNotDisableLiveTranscriptOrReplaceMessages() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: root.appendingPathComponent("missing.jsonl").path, profileID: "p")
        let view = SessionDisplay(id: chat.id)
        view.messages = [.init(id: "visible", role: "assistant", text: "Still streaming")]
        model.chats = [chat]; model.displays[chat.id] = view
        for wasBrowsing in [false, true] {
            view.browsingHistory = wasBrowsing
            do { try await model.revealConversationHit(chat.id, hit: .init(id: "missing", position: 1, preview: "Earlier")); XCTFail("The removed journal must not load") }
            catch { }
            XCTAssertEqual(view.browsingHistory, wasBrowsing)
            XCTAssertEqual(view.messages.map(\.id), ["visible"]); XCTAssertNil(view.scrollAnchor)
        }
        model.shutdown(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testDeletedChatPreferenceCleanupPreservesRetainedPrivacyChoices() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.capture.sessionModes = ["deleted": "persist", "retained": "off"]
            $0.capture.sessionSince = ["deleted": "old", "retained": "kept"]
        }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        model.chats = [.init(id: "retained", workspaceID: "w", title: "Retained", path: nil, profileID: "p")]
        try await model.reloadConfiguration()
        do { try await model.removeDeletedCapturePreference(sessionID: "retained"); XCTFail("A retained chat's opt-out must not be removed") }
        catch { XCTAssertEqual(error as? StoreError, .invalidRecord) }
        try await model.removeDeletedCapturePreference(sessionID: "deleted")
        XCTAssertEqual(model.configuration.capture.sessionModes, ["retained": "off"])
        XCTAssertEqual(model.configuration.capture.sessionSince, ["retained": "kept"])
        let retained = try await model.capturePreference(sessionID: "retained")
        XCTAssertEqual(retained.mode, "off")
        model.shutdown(); try await model.traces.close(); await model.store?.close()
    }
}
