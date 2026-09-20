import XCTest
@testable import PiApp

/// A new chat or side exists only on screen until its first message: no chat
/// record, draft, journal or helper session is written for it.
final class DeferredCreationTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("deferred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func model(root: URL) async throws -> (WorkspaceModel, ProfileRecord) {
        var draft = ProfileRecord(); draft.api = "openai-responses"; draft.baseUrl = "http://127.0.0.1:1"; draft.modelId = "fixture"; draft.name = "Fixture"
        let profile = draft, project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [project]; $0.profiles = [VaultProfile(profile: profile, apiKey: "synthetic")] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        await model.restore()
        model.selectedWorkspaceID = "project"; model.profileChoice = profile.id
        return (model, profile)
    }
    @MainActor private func settle(_ model: WorkspaceModel, _ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition did not settle")
    }

    @MainActor func testNewChatIsWrittenOnlyWhenItIsUsed() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await model(root: root)
        let store = try XCTUnwrap(model.store)
        model.newChat()
        try await settle(model) { model.selectedID != nil }
        let id = try XCTUnwrap(model.selectedID)
        XCTAssertTrue(model.pendingChatIDs.contains(id)); XCTAssertEqual(model.chats.map(\.id), [id], "The chat is on screen")
        let stored = try await store.list(ChatRecord.self, kind: "chat")
        XCTAssertTrue(stored.isEmpty, "Nothing is written until a message is sent")
        model.newChat()
        try await settle(model) { model.chats.count == 1 }
        XCTAssertEqual(model.selectedID, id, "A second New Chat reuses the empty pending chat instead of stacking another")

        // Typing keeps the chat alive across a switch; an empty pending chat is dropped on the way out.
        let other = ChatRecord(id: "saved", workspaceID: "project", title: "Saved", path: nil, profileID: model.profileChoice)
        try await store.put(other, kind: "chat", id: other.id); model.chats.append(other)
        model.displays[id]?.draft = "Half a thought"
        await model.select(other.id)
        XCTAssertTrue(model.chats.contains { $0.id == id }, "A pending chat with a draft stays")
        let drafts = try await store.list(DraftRecord.self, kind: "draft")
        XCTAssertTrue(drafts.isEmpty, "Its draft is not written either")
        await model.select(id); model.displays[id]?.draft = ""
        await model.select(other.id)
        XCTAssertFalse(model.chats.contains { $0.id == id }, "An empty pending chat disappears when the user moves on")
        XCTAssertFalse(model.pendingChatIDs.contains(id))

        // A rename is a use: the record is written first, and the chat stops being pending.
        model.newChat(); try await settle(model) { model.selectedID != other.id && model.selectedID != nil }
        let renamed = try XCTUnwrap(model.selectedID)
        try await model.setSessionTitle(renamed, title: "Kept by name")
        XCTAssertFalse(model.pendingChatIDs.contains(renamed))
        let written = try await store.get(ChatRecord.self, kind: "chat", id: renamed)
        XCTAssertEqual(written?.title, "Kept by name")
        // Deleting a pending chat asks nothing and writes nothing.
        model.newChat(); try await settle(model) { model.selectedID != renamed && model.selectedID != nil }
        let doomed = try XCTUnwrap(model.selectedID)
        model.deleteChat(doomed)
        XCTAssertFalse(model.chats.contains { $0.id == doomed }); XCTAssertNil(model.selectedID)
        model.shutdown()
    }

    @MainActor func testSideOpensOnScreenAndIsCreatedByItsFirstMessage() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await model(root: root)
        let store = try XCTUnwrap(model.store)
        let parent = ChatRecord(id: "parent", workspaceID: "project", title: "Parent", path: nil, profileID: model.profileChoice)
        try await store.put(parent, kind: "chat", id: parent.id); model.chats.append(parent)
        await model.select(parent.id)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id])
        XCTAssertTrue(side.pending); XCTAssertFalse(side.kept)
        XCTAssertEqual(model.focusedSessionID, side.id, "The pane opens with its composer focused")
        XCTAssertTrue(model.hosts.isEmpty, "No helper session yet")
        let intents = try await store.list(SideKeepIntent.self, kind: "side-keep")
        XCTAssertTrue(intents.isEmpty, "No recovery intent yet")
        XCTAssertFalse(model.hasActiveWork, "A pending side never blocks quitting or updating")
        model.openSide(parentID: parent.id)
        XCTAssertEqual(model.sides[parent.id]?.id, side.id, "Opening again focuses the same pending side")
        XCTAssertNil(model.error)

        model.displays[side.id]?.draft = "Unsent side question"
        model.closeSide(side.id)
        XCTAssertNil(model.sides[parent.id]); XCTAssertNil(model.displays[side.id])
        XCTAssertEqual(model.displays[parent.id]?.draft, "Unsent side question", "Closing a pending side hands its text back to the parent")
        XCTAssertEqual(model.focusedSessionID, parent.id)
        model.shutdown()
    }
}
