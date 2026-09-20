import XCTest
import Combine
import SQLite3
@testable import PiApp

final class OrganizationBatchTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: scratchBase()).appendingPathComponent("organization-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func chat(_ id: String, _ order: Int64 = 0) -> ChatRecord {
        ChatRecord(id: id, workspaceID: "p", title: id, path: nil, profileID: "gateway", sidebarOrder: -order)
    }
    @MainActor private func model(_ root: URL, count: Int) async throws -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "p", path: root.path, trusted: true)]
        model.chats = (0..<count).map { chat("chat\($0)", Int64($0)) }
        for row in model.chats { try await model.store?.put(row, kind: "chat", id: row.id) }
        model.selectedID = "chat0"; model.focusedSessionID = "chat0"
        return model
    }

    @MainActor func test500ArchivesPublishOnceAndOpenOnlyFinalDestination() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root, count: 501); defer { model.shutdown() }
        var publications = 0, selections: [String] = []
        let rows = model.$chats.dropFirst().sink { _ in publications += 1 }
        let navigation = model.$selectedID.dropFirst().sink { if let id = $0 { selections.append(id) } }
        defer { rows.cancel(); navigation.cancel() }
        model.unreadStates["chat1"] = SessionReadState(id: "chat1", observedAssistantCount: 1, latestAssistantID: "reply", unreadOutputs: 1, unreadFailure: true)
        let result = try await model.enqueueOrganization((0..<500).map { "chat\($0)" }, change: .archived(true)).value
        XCTAssertEqual(result.changed.count, 500)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(selections, ["chat500"])
        XCTAssertEqual(Set(model.displays.keys), ["chat500"], "No intermediate history, composer, accounting or context loads")
        XCTAssertEqual(model.unreadStates["chat1"]?.unreadFailure, true)
        XCTAssertEqual(model.unreadStates["chat1"]?.unreadOutputs, 1)
        let commits = await model.store?.organizationCommits
        XCTAssertEqual(commits, 1)
        await model.store?.close()
    }

    @MainActor func testNavigationDuringCommitWinsAndCurrentMetadataIsRebased() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root, count: 3); defer { model.shutdown() }
        let store = try XCTUnwrap(model.store)
        var release: CheckedContinuation<Void, Never>?
        model.organizationWrite = { ids, change in
            await withCheckedContinuation { release = $0 }
            return try await store.updateChatOrganizations(ids: ids, change: change)
        }
        let operation = model.enqueueOrganization(["chat0", "chat1"], change: .archived(true))
        while release == nil { await Task.yield() }
        model.page = .report
        model.chats[0].path = "/new/journal.jsonl"; model.chats[0].model = "new-model"
        model.chats.removeAll { $0.id == "chat1" }
        release?.resume()
        _ = try await operation.value
        XCTAssertEqual(model.page, .report); XCTAssertEqual(model.selectedID, "chat0")
        XCTAssertTrue(model.displays.isEmpty)
        XCTAssertNil(model.record("chat1"))
        XCTAssertEqual(model.record("chat0")?.path, "/new/journal.jsonl")
        XCTAssertEqual(model.record("chat0")?.model, "new-model")
        XCTAssertTrue(model.record("chat0")?.isArchived == true)
        await store.close()
    }

    @MainActor func testRestorePinRenameAndTopicMoveRemainInIntentOrder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root, count: 2); defer { model.shutdown() }
        let store = try XCTUnwrap(model.store)
        let topic = try await model.createTopic(in: "p", title: "Topic")
        var release: CheckedContinuation<Void, Never>?, calls = 0
        model.organizationWrite = { ids, change in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return try await store.updateChatOrganizations(ids: ids, change: change)
        }
        let archive = model.enqueueOrganization(["chat1"], change: .archived(true))
        let restore = model.enqueueOrganization(["chat1"], change: .archived(false))
        let pin = model.enqueueOrganization(["chat1"], change: .pinned(true))
        let rename = model.enqueueOrganization(["chat1"], change: .title("Saved title"))
        let move = Task { try await model.moveSessions(["chat1"], in: "p", toTopic: topic.id) }
        while release == nil { await Task.yield() }
        XCTAssertEqual(calls, 1)
        release?.resume()
        _ = try await archive.value; _ = try await restore.value; _ = try await pin.value; _ = try await rename.value; try await move.value
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: "chat1")
        XCTAssertEqual(saved?.title, "Saved title"); XCTAssertEqual(saved?.topicID, topic.id)
        XCTAssertFalse(saved?.isArchived ?? true); XCTAssertTrue(saved?.isPinned == true)
        XCTAssertEqual(model.record("chat1"), saved)
        XCTAssertFalse(model.organizationScheduler.inFlight)
        await store.close()
    }

    @MainActor func testArchiveAllKeepsFinalArchivedPaneAndFailureDoesNotPublish() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root, count: 2); defer { model.shutdown() }
        let before = model.chats
        model.organizationWrite = { _, _ in throw StoreError.unavailable }
        do { _ = try await model.enqueueOrganization(["chat0", "chat1"], change: .archived(true)).value; XCTFail() } catch { }
        XCTAssertEqual(model.chats, before); XCTAssertEqual(model.selectionRevision, 0)
        model.organizationWrite = nil
        _ = try await model.enqueueOrganization(["chat0", "chat1"], change: .archived(true)).value
        XCTAssertEqual(model.selectedID, "chat0"); XCTAssertEqual(model.focusedSessionID, "chat0")
        XCTAssertFalse(model.showArchivedSessions); XCTAssertEqual(model.selectionRevision, 0)
        await model.store?.close()
    }

    func testBatchClassifiesMissingUnchangedAndInvalidRecordsAndSurvivesRestart() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        var unchanged = chat("unchanged"); unchanged.archivedAt = Date()
        var invalid = chat("invalid"); invalid.organizationRevision = Int64.max
        for row in [chat("changed"), unchanged, invalid] { try await store.put(row, kind: "chat", id: row.id) }
        let batch = try await store.updateChatOrganizations(ids: ["changed", "changed", "unchanged", "invalid", "missing"], change: .archived(true))
        XCTAssertEqual(batch.changed, ["changed"]); XCTAssertEqual(batch.unchanged, ["unchanged"])
        XCTAssertEqual(batch.rejected, ["invalid"]); XCTAssertEqual(batch.missing, ["missing"])
        await store.close()
        let reopened = MetadataStore(url: url)
        let saved = try await reopened.get(ChatRecord.self, kind: "chat", id: "changed")
        let skipped = try await reopened.get(ChatRecord.self, kind: "chat", id: "invalid")
        XCTAssertTrue(saved?.isArchived == true); XCTAssertFalse(skipped?.isArchived ?? true)
        await reopened.close()
    }

    func testSQLiteFailureRollsBackEveryPatch() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        for id in ["a", "b"] { try await store.put(chat(id), kind: "chat", id: id) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_b BEFORE UPDATE ON records WHEN new.id='b' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        do { _ = try await store.updateChatOrganizations(ids: ["a", "b"], change: .archived(true)); XCTFail() } catch { }
        for id in ["a", "b"] {
            let saved = try await store.get(ChatRecord.self, kind: "chat", id: id)
            XCTAssertFalse(saved?.isArchived ?? true)
        }
        let commits = await store.organizationCommits; XCTAssertEqual(commits, 0)
        await store.close()
    }
}
