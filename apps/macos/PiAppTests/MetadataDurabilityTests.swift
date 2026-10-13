import XCTest
import Darwin
@testable import PiApp

final class MetadataDurabilityTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("metadata-durability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Inspect only this fixture's descriptors; unrelated app and test activity
    /// can open files concurrently without affecting the assertion.
    private func openFiles(in root: URL) throws -> [String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name in
            guard let descriptor = Int32(name) else { return nil }
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            let result = path.withUnsafeMutableBytes { buffer -> Int32 in
                guard let pointer = buffer.baseAddress else { return -1 }
                return fcntl(descriptor, F_GETPATH, pointer)
            }
            guard result == 0 else { return nil }
            let value = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)).resolvingSymlinksInPath().path
            return value.hasPrefix(prefix) ? value : nil
        }
    }

    func testDroppingStoreClosesItsOwnedDatabase() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var store: MetadataStore? = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        weak var released = store
        // Construction is cheap and opens nothing; the first use opens SQLite.
        XCTAssertEqual(try openFiles(in: root), [], "Constructing the store must not open its database")
        try await store?.open()
        XCTAssertFalse(try openFiles(in: root).isEmpty, "The live store must actually own an open fixture file")
        store = nil
        XCTAssertNil(released)
        XCTAssertEqual(try openFiles(in: root), [], "Dropping the store must release the database, WAL and shared-memory descriptors")
    }

    func testRepeatedFailedInitializationDoesNotLeakDatabaseHandles() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("corrupt.sqlite")
        let original = Data(repeating: 0x78, count: 256)
        try original.write(to: url)
        for _ in 0..<12 {
            let store = MetadataStore(url: url)
            do { try await store.open(); XCTFail("An unreadable database must report itself") }
            catch { XCTAssertEqual(error as? StoreError, .unavailable) }
            // A failed open must not be retried into a second leaked handle.
            do { try await store.open(); XCTFail("An unreadable database must report itself") }
            catch { XCTAssertEqual(error as? StoreError, .unavailable) }
            XCTAssertEqual(try openFiles(in: root), [], "A schema/pragma failure after opening SQLite must release the handle")
        }
        XCTAssertEqual(try Data(contentsOf: url), original, "Failed initialization must preserve the unreadable database")
    }

    func testExplicitCloseReleasesFilesAndRejectsWritesAndTransactions() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let draft = DraftRecord(id: "chat", text: "Saved before close")
        try await store.put(draft, kind: "draft", id: draft.id)
        XCTAssertFalse(try openFiles(in: root).isEmpty)
        await store.close(); await store.close()
        XCTAssertEqual(try openFiles(in: root), [])
        do { try await store.put(draft, kind: "draft", id: draft.id, revision: 1); XCTFail("A closed store must reject explicit-revision writes") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        let chat = ChatRecord(id: draft.id, workspaceID: "w", title: "Closed", path: nil, profileID: "p")
        do { try await store.commitPortableHandoff(chat, draft: draft, provenance: nil); XCTFail("A closed store must reject transactions") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        let reopened = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let retained = try await reopened.get(DraftRecord.self, kind: "draft", id: draft.id)
        XCTAssertEqual(retained?.text, draft.text)
        await reopened.close()
    }

    func testClockCorrectionCannotDiscardRenamePinArchiveOrLaterDrafts() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Before clock correction", path: nil, profileID: "p")
        let future = Int64(Date().timeIntervalSince1970 * 1_000_000) + 1_000_000_000_000
        try await store.put(chat, kind: "chat", id: chat.id, revision: future)
        try await store.put(DraftRecord(id: chat.id, text: "Old"), kind: "draft", id: chat.id, revision: future)
        _ = try await store.updateChatOrganization(id: chat.id, change: .title("After clock correction"))
        _ = try await store.updateChatOrganization(id: chat.id, change: .pinned(true))
        _ = try await store.updateChatOrganization(id: chat.id, change: .archived(true))
        let old = try await store.reserveRevision(kind: "draft", id: chat.id)
        let newer = try await store.reserveRevision(kind: "draft", id: chat.id)
        XCTAssertGreaterThan(old, future); XCTAssertGreaterThan(newer, old)
        try await store.put(DraftRecord(id: chat.id, text: "Latest draft"), kind: "draft", id: chat.id, revision: newer)
        do {
            try await store.put(DraftRecord(id: chat.id, text: "Delayed old draft"), kind: "draft", id: chat.id, revision: old)
            XCTFail("Explicitly stale writes must be rejected")
        } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        await store.close()
        let reopened = MetadataStore(url: url)
        let saved = try await reopened.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(saved?.title, "After clock correction"); XCTAssertTrue(saved?.isPinned == true); XCTAssertTrue(saved?.isArchived == true)
        let draft = try await reopened.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(draft?.text, "Latest draft")
        let afterRestart = try await reopened.reserveRevision(kind: "draft", id: chat.id)
        XCTAssertGreaterThan(afterRestart, newer, "The persisted revision remains authoritative after a restart")
        await reopened.close()
    }

    func testPortableHandoffCommitsChatDraftAndProvenanceTogether() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let chat = ChatRecord(id: "handoff", workspaceID: "w", title: "Handoff", path: nil, profileID: "p")
        let draft = DraftRecord(id: chat.id, text: "Source conversation, ready for review")
        let tooLarge = String(repeating: "x", count: 524_289)
        for (text, provenance) in [(tooLarge, WireValue.string("source")), (draft.text, .string(tooLarge))] {
            do {
                try await store.commitPortableHandoff(chat, draft: DraftRecord(id: chat.id, text: text), provenance: provenance)
                XCTFail("An oversized record must roll back the whole handoff")
            } catch { XCTAssertEqual(error as? StoreError, .invalidRecord) }
            let chats = try await store.loadChats()
            let saved = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
            let source = try await store.get(WireValue.self, kind: "handoff", id: chat.id)
            XCTAssertTrue(chats.isEmpty); XCTAssertNil(saved); XCTAssertNil(source)
        }
        let provenance = WireValue.object(["source": .string("original.jsonl")])
        try await store.commitPortableHandoff(chat, draft: draft, provenance: provenance)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
        let source = try await store.get(WireValue.self, kind: "handoff", id: chat.id)
        XCTAssertEqual(saved?.text, draft.text); XCTAssertEqual(source, provenance)
        await store.close()
    }

    func testUnavailableDatabaseDoesNotReadAsEmptySuccess() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        await store.close()
        do { _ = try await store.get(DraftRecord.self, kind: "draft", id: "missing"); XCTFail("Unavailable is not absent") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        do { _ = try await store.list(DraftRecord.self, kind: "draft"); XCTFail("Unavailable is not an empty list") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
    }
}

extension MetadataDurabilityTests {
    /// A queued rewrite beside a large draft set aside for it, too large to
    /// save together: the write fails (and says so) rather than dropping the
    /// rewrite, and the record saved before stays as it was.
    func testAnOversizedQueuedRewriteFailsWithoutReplacingTheSavedRecord() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        var small = DraftRecord(id: "chat", text: "draft")
        small.queuedEdit = QueuedEditDraft(editID: "e", turnID: "q", rewrite: "first rewrite", original: "o")
        try await store.put(small, kind: "draft", id: "chat")
        var large = DraftRecord(id: "chat", text: String(repeating: "d", count: 270_000))
        large.queuedEdit = QueuedEditDraft(editID: "e", turnID: "q", rewrite: String(repeating: "r", count: 270_000), original: "o")
        do { try await store.put(large, kind: "draft", id: "chat"); XCTFail("too large to save together") }
        catch { XCTAssertEqual(error as? StoreError, .invalidRecord) }
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: "chat")
        XCTAssertEqual(saved?.queuedEdit?.rewrite, "first rewrite", "the record saved before is not replaced")
        await store.close()
    }

    /// A chat row another version wrote without `toolMode` or `imported`
    /// (keys with a default here) lists and shows; it used to be skipped as
    /// undecodable and only counted as unlisted.
    func testAChatRowWithoutDefaultedKeysLoadsAndShows() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let row = ["id": "old", "workspaceID": "w", "title": "Older chat", "profileID": "p"]
        try await store.put(row, kind: "chat", id: "old")
        let chats = try await store.loadChats()
        XCTAssertEqual(chats.map(\.id), ["old"])
        let unlisted = await store.unlistedChats
        XCTAssertEqual(unlisted, 0)
        XCTAssertEqual(chats.first?.toolMode, ChatRecord.editingTools)
        XCTAssertEqual(chats.first?.imported, false)
        XCTAssertNotNil(chats.first?.sidebarOrder, "an older row still takes its order from the store")
        let fetched = try await store.get(ChatRecord.self, kind: "chat", id: "old")
        XCTAssertEqual(fetched?.title, "Older chat")
        // A key with no default stays required: such a row is still unlisted.
        try await store.put(["id": "bad", "workspaceID": "w", "title": "No profile"], kind: "chat", id: "bad")
        let after = try await store.loadChats().map(\.id)
        XCTAssertEqual(after, ["old"])
        let unlistedAfter = await store.unlistedChats
        XCTAssertEqual(unlistedAfter, 1)
        await store.close()
    }

    /// Every field survives a round trip, and the bytes written are the same
    /// as the synthesized encoding's (nil keys left out, nothing added).
    func testChatRecordRoundTripsEveryFieldUnchanged() throws {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var chat = ChatRecord(id: "c", workspaceID: "w", title: "T", path: "/j", profileID: "p", toolMode: ChatRecord.readOnlyTools, imported: true, connectionTest: true)
        chat.model = "m"; chat.thinkingLevel = "high"; chat.contextWindow = 1000; chat.maxOutputTokens = 100; chat.modelOutputLimit = 200
        chat.outputBudgetVersion = 7; chat.sidebarOrder = 11; chat.lastActivityAt = 12; chat.pinnedAt = date; chat.archivedAt = date
        chat.titleWasEdited = true; chat.titleWasGenerated = false; chat.titleTaskSessionID = "tt"; chat.backgroundTask = "title"
        chat.sourceSessionID = "s"; chat.backgroundTaskNotice = "n"; chat.backgroundTaskStartedAt = date; chat.backgroundTaskEndedAt = date
        chat.backgroundTaskOutcome = "completed"; chat.backgroundTaskResult = "r"; chat.organizationRevision = 3; chat.topicID = "t"
        chat.parentSessionID = "pp"; chat.costLimit = .usd(5); chat.webhookOff = true; chat.connectionRevision = 4; chat.journalRebind = true
        chat.costLimitRevision = 5
        for child in Mirror(reflecting: chat).children {
            let inner = Mirror(reflecting: child.value)
            if inner.displayStyle == .optional { XCTAssertFalse(inner.children.isEmpty, "fixture leaves \(child.label ?? "?") nil") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(chat)
        let decoded = try JSONDecoder().decode(ChatRecord.self, from: data)
        XCTAssertEqual(decoded, chat)
        XCTAssertEqual(try encoder.encode(decoded), data)
        // Optionals absent from a row stay nil (an upgrade fills them in), not
        // the defaults a new record starts with.
        let sparse = try JSONDecoder().decode(ChatRecord.self, from: Data(#"{"id":"c","workspaceID":"w","title":"T","profileID":"p","toolMode":"read-only","imported":true}"#.utf8))
        XCTAssertNil(sparse.sidebarOrder); XCTAssertNil(sparse.outputBudgetVersion)
        XCTAssertEqual(sparse.toolMode, ChatRecord.readOnlyTools); XCTAssertTrue(sparse.imported)
        let keys = try JSONSerialization.jsonObject(with: try encoder.encode(sparse)) as? [String: Any]
        XCTAssertEqual(Set(keys?.keys.map { $0 } ?? []), ["id", "workspaceID", "title", "profileID", "toolMode", "imported"])
    }

    /// Topics and read states written without a defaulted key decode with
    /// its default; a key with none stays required.
    func testTopicAndReadStateRowsWithoutDefaultedKeysDecode() throws {
        let topic = try JSONDecoder().decode(TopicRecord.self, from: Data(#"{"id":"t","workspaceID":"w","title":"T","createdAt":5,"revision":2}"#.utf8))
        XCTAssertTrue(topic.expanded); XCTAssertEqual(topic.revision, 2)
        XCTAssertThrowsError(try JSONDecoder().decode(TopicRecord.self, from: Data(#"{"id":"t","workspaceID":"w","title":"T","revision":2}"#.utf8)), "createdAt has no default when read")
        let read = try JSONDecoder().decode(SessionReadState.self, from: Data(#"{"id":"c","observedAssistantCount":3}"#.utf8))
        XCTAssertEqual(read.unreadOutputs, 0); XCTAssertEqual(read.revision, 0)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionReadState.self, from: Data(#"{"id":"c"}"#.utf8)))
        let full = SessionReadState(id: "c", observedAssistantCount: 3, latestAssistantID: "a", unreadOutputs: 2, unreadTargetID: "u", unreadFailure: true, markedUnread: true, baselinePending: true, revision: 9)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try JSONDecoder().decode(SessionReadState.self, from: try encoder.encode(full)), full)
        let fullTopic = TopicRecord(id: "t", workspaceID: "w", title: "T", createdAt: Date(timeIntervalSinceReferenceDate: 9), expanded: false, revision: 4)
        XCTAssertEqual(try JSONDecoder().decode(TopicRecord.self, from: try encoder.encode(fullTopic)), fullTopic)
    }
}
