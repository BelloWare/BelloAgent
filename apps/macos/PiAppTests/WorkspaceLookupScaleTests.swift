import XCTest
@testable import PiApp

/// Looking a chat up by id is the app's most repeated model operation: the
/// sidebar does it twice per row per redraw, the Dock badge does it per unread
/// chat, the menu bar does it per row, and a streamed snapshot does it five
/// times per delta. A linear scan made all of those O(chats²).
final class WorkspaceLookupScaleTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("lookup-scale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func model(chats count: Int, unread: Int, root: URL) -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        model.chats = (0..<count).map { ChatRecord(id: "chat-\($0)", workspaceID: "w", title: "Chat \($0)", path: nil, profileID: "p") }
        model.unreadStates = Dictionary(uniqueKeysWithValues: (0..<unread).map {
            ("chat-\($0)", SessionReadState(id: "chat-\($0)", observedAssistantCount: 2, latestAssistantID: "a", unreadOutputs: 1))
        })
        return model
    }

    /// One sidebar redraw plus the Dock badge over a large history. Before the
    /// id index this pass was two nested scans of every chat and took tens of
    /// milliseconds of main-actor time on every redraw.
    @MainActor func testOneSidebarPassOverManyChatsStaysOffTheMainActorBudget() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(chats: 400, unread: 400, root: root)
        defer { model.shutdown() }
        // Warm the index once, as the first redraw after a mutation does.
        _ = model.record("chat-0")
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<4 {
            for chat in model.chats {
                _ = model.unreadOutputCount(sessionID: chat.id)
                _ = model.unreadFailure(sessionID: chat.id)
            }
            model.updateDockBadge()
            _ = model.unreadCount
        }
        let perPass = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 4
        // The same pass through the scan this replaced, for a like-for-like
        // number in whatever configuration the suite is built in.
        let scanStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<4 {
            for chat in model.chats {
                _ = model.chats.first { $0.id == chat.id }
                _ = model.chats.first { $0.id == chat.id }
            }
            _ = model.unreadStates.keys.filter { id in model.chats.first { $0.id == id } != nil }.count
        }
        let scanPass = (ProcessInfo.processInfo.systemUptime - scanStart) * 1000 / 4
        print("PERF sidebar lookup pass (400 chats, 400 unread) = \(String(format: "%.2f", perPass)) ms; the linear scan it replaced = \(String(format: "%.2f", scanPass)) ms")
        XCTAssertLessThan(perPass, 20, "a redraw's chat lookups must not scan the whole history per row")
        XCTAssertLessThan(perPass * 4, scanPass, "the index must be decisively cheaper than the scan it replaced")
        try await model.traces.close(); await model.store?.close()
    }

    /// Cold launch and first chat open against a large metadata store and a
    /// large journal, with a watch on how long the main actor is ever denied a
    /// turn. Opt in with PI_APP_SCALE_PERF=1; it writes an 8000-record journal.
    @MainActor func testLaunchAndFirstChatOpenWithALargeHistory() async throws {
        let opted = testEnvironment("PI_APP_SCALE_PERF")
        try XCTSkipUnless(opted == "1", "set PI_APP_SCALE_PERF=1 to measure")
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let count = 400, records = 8000
        var journal = Data("{\"type\":\"session\",\"version\":3,\"id\":\"chat-0\"}\n".utf8)
        for index in 0..<records {
            let value: [String: Any] = ["type": "message", "id": "m\(index)", "parentId": index == 0 ? NSNull() : "m\(index - 1)" as Any,
                                        "message": ["role": index % 2 == 0 ? "user" : "assistant", "content": String(repeating: "x", count: 400)]]
            journal.append(try JSONSerialization.data(withJSONObject: value)); journal.append(10)
        }
        let path = root.appendingPathComponent("chat-0.jsonl"); try journal.write(to: path)
        let seed = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let store = try XCTUnwrap(seed.store)
        for index in 0..<count {
            let chat = ChatRecord(id: "chat-\(index)", workspaceID: "w", title: "Chat \(index)", path: index == 0 ? path.path : nil, profileID: "p")
            try await store.put(chat, kind: "chat", id: chat.id)
            try await store.put(SessionReadState(id: chat.id, observedAssistantCount: 3, latestAssistantID: "a", unreadOutputs: index % 3), kind: "session-read", id: chat.id)
        }
        seed.shutdown(); try await seed.traces.close(); await store.close()

        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        var profile = ProfileRecord(); profile.id = "p"; profile.modelId = "fixture"
        model.profiles = [profile]
        let hitches = MainActorTurnWatch(); hitches.start(); await Task.yield()
        let launch = ProcessInfo.processInfo.systemUptime
        await model.restore()
        let restored = (ProcessInfo.processInfo.systemUptime - launch) * 1000
        let opening = ProcessInfo.processInfo.systemUptime
        await model.select("chat-0")
        let opened = (ProcessInfo.processInfo.systemUptime - opening) * 1000
        hitches.stop()
        print("PERF restore(\(count) chats) = \(String(format: "%.1f", restored)) ms")
        print("PERF first open of a \(records)-record journal = \(String(format: "%.1f", opened)) ms")
        print("PERF worst main-actor stall across launch and first open = \(String(format: "%.1f", hitches.worst)) ms")
        XCTAssertEqual(model.chats.count, count)
        XCTAssertFalse(model.displays["chat-0"]?.messages.isEmpty ?? true)
        XCTAssertLessThan(hitches.worst, 100, "journal indexing and metadata reads must stay off the main actor")
        try await model.traces.close(); await model.store?.close()
    }

    /// Records the longest span in which the main actor never got a turn.
    @MainActor private final class MainActorTurnWatch {
        private(set) var worst = 0.0
        private var task: Task<Void, Never>?
        func start() {
            task = Task { @MainActor in
                var last = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    await Task.yield()
                    let now = ProcessInfo.processInfo.systemUptime
                    worst = max(worst, (now - last) * 1000); last = now
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
    }

    /// The index is a cache: every mutation of `chats` has to invalidate it,
    /// and sides still resolve through their in-memory record.
    @MainActor func testTheLookupIndexFollowsEveryMutationOfTheChatList() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(chats: 8, unread: 0, root: root)
        defer { model.shutdown() }
        XCTAssertEqual(model.record("chat-3")?.title, "Chat 3")
        model.chats[3].title = "Renamed"
        XCTAssertEqual(model.record("chat-3")?.title, "Renamed", "an in-place edit must be visible to the next lookup")
        model.chats.removeAll { $0.id == "chat-3" }
        XCTAssertNil(model.record("chat-3"))
        XCTAssertEqual(model.record("chat-7")?.title, "Chat 7", "removing one chat must not shift another's lookup")
        model.chats.insert(ChatRecord(id: "fresh", workspaceID: "w", title: "Fresh", path: nil, profileID: "p"), at: 0)
        XCTAssertEqual(model.record("fresh")?.title, "Fresh")
        XCTAssertEqual(model.record("chat-0")?.title, "Chat 0")
        model.chats = []
        XCTAssertNil(model.record("chat-0"))
        // A side that is not yet a saved chat still resolves through its record.
        model.sides["parent"] = .init(id: "side", parentID: "parent", workspaceID: "w", profileID: "p", title: "Side")
        XCTAssertEqual(model.record("side")?.title, "Side")
        XCTAssertNil(model.chatRecord("side"), "the chat index holds only saved chats")
        // A duplicate id resolves to the first entry, as the previous scan did.
        model.chats = [ChatRecord(id: "dupe", workspaceID: "w", title: "First", path: nil, profileID: "p"),
                       ChatRecord(id: "dupe", workspaceID: "w", title: "Second", path: nil, profileID: "p")]
        XCTAssertEqual(model.record("dupe")?.title, "First")
        try await model.traces.close(); await model.store?.close()
    }
}
