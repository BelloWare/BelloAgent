import XCTest
@testable import PiApp

final class SessionOrganizationTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-organization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func chat(_ id: String, order: Int64 = 1, workspace: String = "w") -> ChatRecord {
        ChatRecord(id: id, workspaceID: workspace, title: id, path: nil, profileID: "p", sidebarOrder: order)
    }

    func testLegacyChatDefaultsAndNewOrganizationRoundTrip() throws {
        let data = Data(#"{"id":"old","workspaceID":"w","title":"Original","path":"/retained/session.jsonl","profileID":"p","toolMode":"editing","imported":false}"#.utf8)
        var old = try JSONDecoder().decode(ChatRecord.self, from: data)
        XCTAssertNil(old.sidebarOrder); XCTAssertNil(old.organizationRevision)
        XCTAssertFalse(old.isPinned); XCTAssertFalse(old.isArchived); XCTAssertNil(old.titleWasEdited)
        old.sidebarOrder = 5; old.pinnedAt = Date(timeIntervalSince1970: 30); old.archivedAt = Date(timeIntervalSince1970: 40)
        old.titleWasEdited = true; old.organizationRevision = 3
        XCTAssertEqual(try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(old)), old)
        XCTAssertEqual(old.path, "/retained/session.jsonl")
    }

    func testUpgradeFreezesLegacyOrderingAndPinUnpinSurvivesRestart() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        for (id, revision) in [("oldest", Int64(10)), ("middle", 20), ("newest", 30)] {
            let legacy: [String: WireValue] = ["id": .string(id), "workspaceID": .string("w"), "title": .string(id), "profileID": .string("p"), "toolMode": .string("editing"), "imported": .bool(false)]
            try await store.put(legacy, kind: "chat", id: id, revision: revision)
        }
        var loaded = try await store.loadChats()
        XCTAssertEqual(loaded.map(\.id), ["newest", "middle", "oldest"])
        XCTAssertEqual(loaded.map(\.sidebarOrder), [30, 20, 10])
        _ = try await store.updateChatOrganization(id: "oldest", change: .title("Renamed oldest"))
        loaded = try await store.loadChats()
        XCTAssertEqual(loaded.map(\.id), ["newest", "middle", "oldest"], "Renaming must not change an ordinary chat's order")
        _ = try await store.updateChatOrganization(id: "oldest", change: .pinned(true), now: Date(timeIntervalSince1970: 100))
        _ = try await store.updateChatOrganization(id: "middle", change: .pinned(true), now: Date(timeIntervalSince1970: 101))
        await store.close()
        let reopened = MetadataStore(url: url)
        loaded = try await reopened.loadChats()
        XCTAssertEqual(loaded.map(\.id), ["oldest", "middle", "newest"], "Pinned order is deterministic and retained across restart")
        XCTAssertEqual(loaded.first?.title, "Renamed oldest")
        _ = try await reopened.updateChatOrganization(id: "oldest", change: .pinned(false))
        loaded = try await reopened.loadChats()
        XCTAssertEqual(loaded.map(\.id), ["middle", "newest", "oldest"])
        await reopened.close()
    }

    func testUnrelatedLateMetadataWritesKeepNewTitlePinAndArchive() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        var stale = chat("session", order: 12)
        try await store.put(stale, kind: "chat", id: stale.id)
        _ = try await store.updateChatOrganization(id: stale.id, change: .title("My title"))
        _ = try await store.updateChatOrganization(id: stale.id, change: .pinned(true))
        _ = try await store.updateChatOrganization(id: stale.id, change: .archived(true))
        stale.title = "Automatic first prompt title"; stale.path = "/retained/new-path.jsonl"; stale.model = "different-model"
        try await store.put(stale, kind: "chat", id: stale.id)
        let stored = try await store.get(ChatRecord.self, kind: "chat", id: stale.id)
        let persisted = try XCTUnwrap(stored)
        XCTAssertEqual(persisted.title, "My title"); XCTAssertTrue(persisted.isPinned); XCTAssertTrue(persisted.isArchived)
        XCTAssertEqual(persisted.path, stale.path); XCTAssertEqual(persisted.model, stale.model)
        XCTAssertEqual(persisted.sidebarOrder, 12); XCTAssertEqual(persisted.organizationRevision, 3)
        await store.close()
    }

    @MainActor func testRenameTargetsRequestedRowAndValidatesWhitespaceWithoutChangingFocus() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.chats = [chat("selected"), chat("background")]; model.selectedID = "selected"; model.focusedSessionID = "selected"
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        try await model.setSessionTitle("background", title: "  New\n title 🌍  ")
        XCTAssertEqual(model.record("background")?.title, "New title 🌍"); XCTAssertEqual(model.record("background")?.titleWasEdited, true)
        XCTAssertEqual(model.selectedID, "selected"); XCTAssertEqual(model.focusedSessionID, "selected"); XCTAssertTrue(model.hosts.isEmpty)
        do { try await model.setSessionTitle("background", title: " \n\t "); XCTFail("An empty title should not replace the existing one") } catch { }
        XCTAssertEqual(model.record("background")?.title, "New title 🌍")
        try await model.setSessionTitle("background", title: String(repeating: "🌍", count: 130))
        XCTAssertEqual(model.record("background")?.title.count, 120)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: "background")
        XCTAssertEqual(saved?.title, model.record("background")?.title)
        await model.store?.close()
    }

    @MainActor func testArchiveKeepsRunningWorkDraftUnreadAndHistoryAndRestoresPinnedOrder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("saved.jsonl"), original = Data("retained history bytes\n".utf8)
        try original.write(to: journal)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        var running = chat("running", order: 1); running.path = journal.path
        model.chats = [running, chat("selected", order: 2)]; model.selectedID = "selected"; model.selectedWorkspaceID = "w"
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let display = SessionDisplay(id: running.id); display.state = "running"; display.queueCount = 1; display.draft = "Keep this draft"
        display.queue = [["id": .string("pending"), "text": .string("Do this next")]]
        model.displays[running.id] = display; model.opened.insert(running.id)
        let unread = SessionReadState(id: running.id, observedAssistantCount: 2, latestAssistantID: "reply", unreadOutputs: 1, unreadTargetID: "reply")
        model.unreadStates[running.id] = unread
        try await model.setSessionPinned(running.id, pinned: true)
        try await model.setSessionArchived(running.id, archived: true)
        XCTAssertEqual(model.selectedID, "selected"); XCTAssertFalse(model.showArchivedSessions)
        XCTAssertEqual(model.sidebarChats(in: "w", archived: false).map(\.id), ["selected"])
        XCTAssertEqual(model.sidebarChats(in: "w", archived: true).map(\.id), [running.id])
        XCTAssertTrue(model.displays[running.id] === display); XCTAssertEqual(display.state, "running"); XCTAssertEqual(display.queueCount, 1)
        XCTAssertEqual(display.queue.first?["id"]?.string, "pending"); XCTAssertEqual(display.draft, "Keep this draft")
        XCTAssertEqual(model.unreadStates[running.id], unread); XCTAssertTrue(model.opened.contains(running.id)); XCTAssertTrue(model.hasActiveWork)
        XCTAssertEqual(try Data(contentsOf: journal), original)
        let retained = try await model.store?.get(ChatRecord.self, kind: "chat", id: running.id)
        XCTAssertTrue(retained?.isArchived == true); XCTAssertEqual(retained?.path, journal.path)
        try await model.setSessionArchived(running.id, archived: false)
        XCTAssertEqual(model.sidebarChats(in: "w", archived: false).map(\.id), [running.id, "selected"])
        XCTAssertTrue(model.record(running.id)?.isPinned == true)
        // Avoid a live host refresh in teardown; the fixture owns only a display.
        display.state = "idle"; display.queueCount = 0; model.opened.remove(running.id)
        await model.store?.close()
    }

    @MainActor func testSelectedArchiveAndReportNavigationExposeArchiveWithoutRestoringIt() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let record = chat("target")
        model.chats = [record]; model.selectedID = record.id; model.selectedWorkspaceID = "w"
        try await model.store?.put(record, kind: "chat", id: record.id)
        try await model.setSessionArchived(record.id, archived: true)
        XCTAssertFalse(model.showArchivedSessions, "Archiving keeps the sidebar on active chats"); XCTAssertEqual(model.selectedID, record.id, "With no other active chat the archived one stays open")
        model.page = .report; model.showArchivedSessions = false
        await model.select(record.id)
        XCTAssertEqual(model.page, .chats); XCTAssertTrue(model.showArchivedSessions)
        XCTAssertTrue(model.record(record.id)?.isArchived == true, "Opening report-linked history must not silently restore a chat")
        XCTAssertTrue(model.hosts.isEmpty)
        try await model.setSessionArchived(record.id, archived: false)
        XCTAssertFalse(model.showArchivedSessions)
        await model.store?.close()
    }

    @MainActor func testSidebarScopingKeepsArchivedAndOtherWorkspaceOutOfActiveList() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        var pinned = chat("pin", order: 1); pinned.pinnedAt = Date(timeIntervalSince1970: 2)
        var archived = chat("archive", order: 50); archived.archivedAt = Date(timeIntervalSince1970: 3)
        model.chats = [chat("newest", order: 10), archived, chat("other", workspace: "other"), pinned, chat("side", order: 20)]
        XCTAssertEqual(model.sidebarChats(in: "w", archived: false, excluding: ["side"]).map(\.id), ["pin", "newest"])
        XCTAssertEqual(model.sidebarChats(in: "w", archived: true).map(\.id), ["archive"])
        XCTAssertEqual(model.sidebarChats(in: "other", archived: false).map(\.id), ["other"])
        XCTAssertTrue(model.sidebarChats(in: nil, archived: false).isEmpty)
    }

    func testSidebarRateKeepsCompletedUsageAcrossActivityChangesAndNeverUsesStreamedBytes() {
        let completed = SessionTimingSample(id: "streamed", wall: Date(), ttftMilliseconds: 200,
                                            streamingMilliseconds: 2_403, outputTokens: 302, requestMilliseconds: 2_603)
        let history = SessionTimingHistory(samples: [completed], historicalRate: HistoricalOutputRate(outputTokens: 1_000, generationMilliseconds: 10_000, samples: 2))
        var row = ChatRowStats(totals: nil, timing: history)
        XCTAssertEqual(row.rateLabel, "Latest 126 tok/s")
        for version in [1.0, 2.0] {
            for state in ["running", "compacting", "queued", "stopping", "paused", "error", "idle"] {
                for bytesRate in [0.0, 9999, -1, Double.infinity, Double.nan] {
                    let activity: [String: WireValue] = ["version": .number(version), "phase": .string("model"), "modelActive": .bool(true),
                        "estimatedOutputTokensPerSecond": .number(bytesRate), "outputBytes": .number(4_000_000)]
                    row.updateActivity(state: state, loading: false, activity: activity)
                    XCTAssertEqual(row.rateLabel, "Latest 126 tok/s", "Activity, old telemetry and visible text never replace reported request usage")
                    if state == "running" { XCTAssertTrue(row.generating) }
                }
            }
        }
        row.updateActivity(state: "running", loading: false, activity: ["version": .number(2), "phase": .string("tool")])
        XCTAssertEqual(row.state, "tool"); XCTAssertEqual(row.rateLabel, "Latest 126 tok/s")
        row.timing?.samples.append(SessionTimingSample(id: "missing", wall: Date(), ttftMilliseconds: 100, streamingMilliseconds: 900, outputTokens: nil, requestMilliseconds: 1_000))
        XCTAssertEqual(row.rateLabel, "Usage unavailable", "A new completed request without usage must not borrow an older rate or the average")
        row.timing = SessionTimingHistory()
        XCTAssertEqual(row.rateLabel, "Awaiting usage")
        // A buffered route that never emits a first-content event has no
        // decode span, so it has no settled rate — the sidebar says so rather
        // than dividing by the whole round trip and calling that decode speed.
        let buffered = SessionTimingSample(id: "hidden-reasoning", wall: Date(), ttftMilliseconds: nil,
                                           streamingMilliseconds: nil, outputTokens: 302, requestMilliseconds: 2_403)
        row.timing = SessionTimingHistory(samples: [buffered])
        XCTAssertEqual(row.rateLabel, "Usage unavailable")
    }
}
