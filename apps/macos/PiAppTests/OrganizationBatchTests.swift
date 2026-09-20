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

    @MainActor func testBusyArchivesBoundStopsAndRestoreSupersedesOnlyQueuedStops() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root, count: 13); defer { model.shutdown() }
        var commands: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { commands.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts["p"] = host
        for index in 1...12 {
            let display = SessionDisplay(id: "chat\(index)")
            display.state = index.isMultiple(of: 3) ? "compacting" : "running"
            display.queueCount = index.isMultiple(of: 2) ? 1 : 0
            model.displays[display.id] = display; model.opened.insert(display.id)
        }
        _ = try await model.enqueueOrganization((1...12).map { "chat\($0)" }, change: .archived(true)).value
        for _ in 0..<200 where commands.count < 4 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(commands.filter { $0["method"]?.string == "turn.stop" }.count, 4)
        XCTAssertEqual(model.archiveStopWorkers, 4)
        XCTAssertEqual(model.archiveStopQueue.count, 8)
        XCTAssertTrue((1...12).allSatisfy { model.record("chat\($0)")?.isArchived == true }, "Metadata need not await a blocked helper acknowledgement")
        _ = try await model.enqueueOrganization(["chat12"], change: .archived(false)).value
        host.receive(.failed("Synthetic disconnected helper"), connectionID: try XCTUnwrap(host.connectionID))
        for _ in 0..<200 where model.archiveStopWorkers > 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(model.archiveStopWorkers, 0); XCTAssertTrue(model.archiveStopQueue.isEmpty)
        XCTAssertEqual(model.displays["chat12"]?.state, "compacting", "Restore prevents an older queued Stop; already issued commands cannot be undone")
        XCTAssertFalse(model.record("chat12")?.isArchived ?? true)
        XCTAssertTrue(model.displays["chat1"]?.uncertain == true)
        XCTAssertFalse(model.displays["chat1"]?.notice.isEmpty ?? true)
        try await host.shutdownAndWait(); await model.store?.close()
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
        XCTAssertEqual(model.selectedID, "chat1"); XCTAssertEqual(model.focusedSessionID, "chat1")
        XCTAssertFalse(model.showArchivedSessions); XCTAssertFalse(model.projectShowsArchive("p")); XCTAssertEqual(model.selectionRevision, 1)
        await model.store?.close()
    }

    func testSelectionReducerMatchesLegacyPolicyForFirstMiddleLastAndAllTargets() {
        let original = (0..<6).map { chat("chat\($0)", Int64($0)) } + [ChatRecord(id: "other", workspaceID: "other", title: "Other", path: nil, profileID: "gateway")]
        for selected in original.map(\.id) {
            for targets in [["chat0"], ["chat0", "chat2", "chat4"], ["chat5", "chat3", "chat1"], (0..<6).map({ "chat\($0)" }), (0..<6).reversed().map({ "chat\($0)" })] {
                var before = original, expected = selected
                for id in targets {
                    guard let index = before.firstIndex(where: { $0.id == id }) else { continue }
                    before[index].archivedAt = Date()
                    if expected == id, let next = before.filter({ $0.workspaceID == before[index].workspaceID && !$0.isArchived }).sorted(by: ChatRecord.sidebarPrecedes).first { expected = next.id }
                }
                XCTAssertEqual(SessionOrganizationSelection.afterArchive(selected: selected, targets: targets, archived: Set(targets), records: before, includeBackground: false), expected)
            }
        }
    }

    @MainActor func testArchiveScaleMatrixHasOneCommitAndPublicationPerAction() async throws {
        for count in [100, 1_000, 10_000] {
            let root = try scratch()
            let model = try await model(root, count: count)
            for size in [1, 5, 25, 100, 500] where size <= count {
                let ids = size == count ? (0..<size).map { "chat\($0)" } : (1...size).map { "chat\($0)" }
                for archived in [true, false] {
                    let revision = model.chatsRevision, commits = await model.store?.organizationCommits ?? 0
                    let selections = model.selectionRevision
                    let start = ProcessInfo.processInfo.systemUptime
                    let operation = model.enqueueOrganization(ids, change: .archived(archived))
                    let acknowledged = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                    let result = try await operation.value
                    let afterCommits = await model.store?.organizationCommits ?? 0
                    XCTAssertEqual(result.changed.count, size)
                    XCTAssertEqual(model.chatsRevision - revision, 1)
                    XCTAssertEqual(afterCommits - commits, 1)
                    XCTAssertEqual(model.selectionRevision - selections, size == count && archived ? 1 : 0)
                    if size < count { XCTAssertTrue(model.displays.isEmpty) }
                    print("PERF organization store=\(count) targets=\(size) archive=\(archived) acknowledgeMs=\(acknowledged) transactionMs=\(result.transactionMilliseconds) endToEndMs=\((ProcessInfo.processInfo.systemUptime-start)*1_000)")
                }
            }
            model.shutdown(); await model.store?.close()
            try FileManager.default.removeItem(at: root)
        }
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
