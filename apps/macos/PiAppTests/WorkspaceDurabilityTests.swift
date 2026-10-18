import XCTest
@testable import PiApp

final class WorkspaceDurabilityTests: XCTestCase {
    @MainActor func testImportingUnlistedArchivedSideRetainsBudgetAncestorsBeforeSelection() async throws {
        let root = try scratch(), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model,root:root)
        model.automaticContextOperation = { _,_ in throw CancellationError() }
        let store = try XCTUnwrap(model.store), directory = try model.subagentDirectory("pane-project")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let parent = ChatRecord(id:"unlisted-parent",workspaceID:"pane-project",title:"Parent",path:directory.appendingPathComponent("unlisted-parent.jsonl").path,profileID:"fixture")
        let side = ChatRecord(id:"unlisted-side",workspaceID:parent.workspaceID,title:"Archived side",path:directory.appendingPathComponent("side_unlisted-side.jsonl").path,profileID:parent.profileID,archivedAt:Date(),parentSessionID:parent.id)
        for chat in [parent,side] {
            try SideKeepRecoveryTests.journal(id:chat.id).write(to:URL(fileURLWithPath:try XCTUnwrap(chat.path)))
            try await store.put(chat,kind:"chat",id:chat.id)
        }
        XCTAssertNil(model.record(parent.id)); XCTAssertNil(model.record(side.id))
        await model.importChat(from:URL(fileURLWithPath:try XCTUnwrap(side.path)),workspaceID:side.workspaceID,store:store)
        XCTAssertEqual(model.selectedID,side.id)
        XCTAssertEqual(model.record(parent.id)?.id,parent.id,"Import must retain out-of-window ancestors before exposing the side")
        XCTAssertTrue(model.deletionNeedsAncestorRepair(side),"Deleting the archived side must repair spend into its surviving parent")
        XCTAssertEqual(model.budgetOwner(for:side).id,parent.id)
        XCTAssertTrue(model.hosts.isEmpty,"An archived import must not require a running helper to discover ancestry")
    }

    @MainActor func testImportingOwnedJournalSelectsExistingChatAndRefusesAnotherProject() async throws {
        let root = try scratch(), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model,root:root)
        model.automaticContextOperation = { _,_ in throw CancellationError() }
        let store = try XCTUnwrap(model.store)
        _ = try SubagentDiscoveryTests.family(model)
        let original = model.chats[0], path = URL(fileURLWithPath:try XCTUnwrap(original.path))
        try await store.putChats(model.chats)
        let count = model.chats.count
        // The owner can be outside the sidebar window. A symlink is the same
        // native journal, not a new imported original.
        model.chats.removeFirst()
        let alias = root.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:path)
        await model.importChat(from:alias,workspaceID:original.workspaceID,store:store)
        XCTAssertEqual(model.selectedID,original.id)
        XCTAssertEqual(model.chats.count,count)
        XCTAssertFalse(model.chats.contains { $0.imported },"Never register an alias to app-owned data")
        let hardLink = root.appendingPathComponent("hard-link.jsonl")
        try FileManager.default.linkItem(at:path,to:hardLink)
        var unnamed = original; unnamed.path = nil
        try await store.put(unnamed,kind:"chat",id:original.id)
        if let index = model.chats.firstIndex(where: { $0.id == original.id }) { model.chats[index].path = nil }
        await model.importChat(from:hardLink,workspaceID:original.workspaceID,store:store)
        XCTAssertEqual(model.selectedID,original.id)
        XCTAssertEqual(model.record(original.id)?.path.map { URL(fileURLWithPath:$0).lastPathComponent },path.lastPathComponent)
        XCTAssertEqual(model.chats.count,count)
        model.error = nil
        await model.importChat(from:path,workspaceID:"another-project",store:store)
        XCTAssertEqual(model.chats.count,count)
        XCTAssertTrue(model.error?.contains("another project") == true,model.error ?? "No refusal notice")
        let saved = try await store.loadChats()
        XCTAssertEqual(saved.count,count)
        XCTAssertFalse(saved.contains { $0.imported })
        // An unlisted native file is still app-owned; do not register an alias
        // merely because its desktop metadata is absent.
        try await store.remove(kind:"chat",id:original.id); model.chats.removeAll { $0.id == original.id }
        model.error = nil
        await model.importChat(from:path,workspaceID:original.workspaceID,store:store)
        XCTAssertFalse(model.chats.contains { $0.imported })
        XCTAssertNotNil(model.error)
        let caseAlias = URL(fileURLWithPath:path.path.replacingOccurrences(of:"/Workspaces/",with:"/WORKSPACES/"))
        if FileManager.default.fileExists(atPath:caseAlias.path) {
            await model.importChat(from:caseAlias,workspaceID:original.workspaceID,store:store)
            XCTAssertFalse(model.chats.contains { $0.imported },"Filesystem spelling cannot bypass native ownership")
        }
        let external = root.appendingPathComponent("external-copy.jsonl")
        try FileManager.default.copyItem(at:path,to:external)
        model.error = nil
        await model.importChat(from:external,workspaceID:original.workspaceID,store:store)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.chats.first { $0.imported }?.path,external.path,"An independent external file remains importable")
        XCTAssertEqual(try Data(contentsOf:external),try Data(contentsOf:path))
    }

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
        view.selectionMetadataLoaded = true
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
        model.error = nil; model.recoverCopy(chat.id)
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
        model.chats = [chat]; model.displays[view.id] = view; view.selectionMetadataLoaded = true; view.draft = "Unsent side draft"
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
        XCTAssertNotNil(damaged); XCTAssertNil(registered); XCTAssertEqual(model.sideKeepIssues.map(\.id), ["damaged"])
        model.sides["parent"] = .init(id: "unregistered", parentID: "parent", workspaceID: "w", profileID: "p", title: "Unregistered")
        await model.applySideStatus(id: "unregistered", result: ["ephemeral": .bool(false), "path": .string("missing")])
        XCTAssertTrue(model.error?.contains("Could not add “Unregistered” to saved chats.") == true)
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
