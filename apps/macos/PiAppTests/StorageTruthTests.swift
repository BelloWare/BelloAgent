import XCTest
@testable import PiApp

/// What the storage layer tells the user, and what it costs to ask. Reading a
/// conversation used to report write failures, claim preserved files that were
/// gone, call a long conversation damaged, drop chats in silence, and re-read
/// the whole journal for every page.
final class StorageTruthTests: XCTestCase {
    private func scratch(_ name: String) throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("storage-truth-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// A journal whose records carry no `id`, as an imported or foreign Pi
    /// session does. `read()` addresses them by offset; so must everything else.
    private func journal(at url: URL, records: Int, identified: Bool, body: Int = 64) throws {
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        var previous: Any = NSNull()
        for index in 0..<records {
            var value: [String: Any] = ["type": "message", "parentId": previous,
                                        "message": ["role": index % 2 == 0 ? "user" : "assistant",
                                                    "content": [["type": "text", "text": "message \(index) " + String(repeating: "x", count: body)]]]]
            if identified { value["id"] = "m\(index)"; previous = "m\(index)" }
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: url)
    }

    func testAJournalWithoutRecordIdsCanStillOpenItsRetainedMessage() async throws {
        let root = try scratch("idless"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("imported.jsonl")
        try journal(at: path, records: 6, identified: false)
        let reader = HistoryReader()
        let page = try await reader.read(path: path.path)
        XCTAssertNil(page.notice)
        let shown = try XCTUnwrap(page.messages.last)
        XCTAssertTrue(shown.id.hasPrefix("record-"), "an id-less record is addressed by its offset: \(shown.id)")
        // The same identity the transcript displayed must open the full text.
        let (text, total) = try await reader.message(path: path.path, id: shown.id, field: "content", offset: 0)
        XCTAssertTrue(text.contains("message 5"), text)
        XCTAssertEqual(total, (text as NSString).length)
    }

    func testPagingALargeMessageDecodesItOnceInsteadOfPerPage() async throws {
        let root = try scratch("paging"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("long.jsonl")
        // One record far larger than a 16 KiB page, behind many others.
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        for index in 0..<200 {
            let long = index == 199 ? String(repeating: "y", count: 200_000) : "short"
            let value: [String: Any] = ["type": "message", "id": "m\(index)", "parentId": index == 0 ? NSNull() : "m\(index - 1)" as Any,
                                        "message": ["role": "user", "content": [["type": "text", "text": long]]]]
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: path)
        let reader = HistoryReader()
        _ = try await reader.read(path: path.path)
        let before = await reader.decodedRecords
        var offset = 0, pages = 0, assembled = ""
        while true {
            let (text, total) = try await reader.message(path: path.path, id: "m199", field: "content", offset: offset)
            assembled += text; pages += 1
            offset += (text as NSString).length
            if offset >= total || text.isEmpty { break }
        }
        let decodes = await reader.decodedRecords - before
        print("PERF paging a 200 KB message took \(pages) pages and \(decodes) record decodes")
        XCTAssertGreaterThan(pages, 10, "the fixture must actually page")
        XCTAssertEqual(decodes, 1, "a message is decoded once, not once per page")
        XCTAssertTrue(assembled.hasSuffix("yyy"))
    }

    func testCopyingOneConversationRecordDecodesItOncePerRecordNotPerPage() async throws {
        let root = try scratch("copy"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("copy.jsonl")
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        for index in 0..<3 {
            let value: [String: Any] = ["type": "message", "id": "m\(index)", "parentId": index == 0 ? NSNull() : "m\(index - 1)" as Any,
                                        "message": ["role": "user", "content": [["type": "text", "text": String(repeating: "z", count: 120_000)]]]]
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: path)
        let reader = HistoryReader()
        let page = try await reader.read(path: path.path)
        let revision = try XCTUnwrap(page.revision).stamp
        let before = await reader.decodedRecords
        var cursor: ContentCursor? = ContentCursor(index: 1, offset: 0), pages = 0
        while let next = cursor {
            let result = try await reader.copyContentPage(path: path.path, first: 1, last: 3, cursor: next, revision: revision)
            cursor = result.next; pages += 1
            XCTAssertLessThan(pages, 200, "the copy loop must terminate")
        }
        let decodes = await reader.decodedRecords - before
        print("PERF copying 3 records of 120 KB took \(pages) pages and \(decodes) record decodes")
        XCTAssertGreaterThan(pages, 20, "the fixture must actually page")
        XCTAssertEqual(decodes, 3, "each record is decoded once for the whole copy, not once per page")
    }

    func testTheJournalIndexIsRetainedForAsManyChatsAsThePagesAre() async throws {
        let root = try scratch("lru"); defer { try? FileManager.default.removeItem(at: root) }
        let reader = HistoryReader()
        var paths: [String] = []
        for index in 0..<8 {
            let path = root.appendingPathComponent("chat-\(index).jsonl")
            try journal(at: path, records: 20, identified: true)
            paths.append(path.path)
            _ = try await reader.read(path: path.path)
        }
        let retained = await reader.retainedIndexCount
        XCTAssertEqual(retained, 8, "one index per retained transcript page")
        // Re-reading the oldest of the eight must not have to index it again.
        let before = await reader.decodedRecords
        _ = try await reader.readIfChanged(path: paths[0], since: nil)
        let reread = await reader.decodedRecords - before
        XCTAssertLessThanOrEqual(reread, 20, "a cached index only decodes the page it shows: \(reread)")
        let ninth = root.appendingPathComponent("chat-8.jsonl")
        try journal(at: ninth, records: 20, identified: true)
        _ = try await reader.read(path: ninth.path)
        let afterNinth = await reader.retainedIndexCount
        XCTAssertEqual(afterNinth, 8, "the ninth evicts the least recent, not the whole cache")
    }

    @MainActor func testAMissingJournalSaysSoInsteadOfClaimingItsFilesWerePreserved() async throws {
        let root = try scratch("missing"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gone.jsonl")
        let reader = HistoryReader()
        do { _ = try await reader.read(path: path.path); XCTFail("A journal that is not there cannot be read") }
        catch {
            XCTAssertEqual(error as? StoreError, .missingJournal(path.path))
            let message = try XCTUnwrap(error.localizedDescription)
            XCTAssertTrue(message.contains("no longer at"), message)
            XCTAssertFalse(message.contains("could not be saved"), "a read failure must not be reported as a failed save")
        }
        // The same failure reaches the chat pane without the false claim.
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.chats = [ChatRecord(id: "gone", workspaceID: "w", title: "Gone", path: path.path, profileID: "p")]
        await model.select("gone")
        let notice = try XCTUnwrap(model.displays["gone"]?.notice)
        XCTAssertTrue(notice.contains("no longer at"), notice)
        XCTAssertFalse(notice.contains("Original files were preserved"), notice)
        try await model.traces.close(); await model.store?.close()
    }

    func testAnUnreadableConversationReportsAReadFailureNotAFailedSave() async throws {
        let root = try scratch("readerror"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("huge.jsonl")
        // Over the reader's own size ceiling: a read refusal, not a save.
        let handle = FileManager.default.createFile(atPath: path.path, contents: nil)
        XCTAssertTrue(handle)
        let file = try FileHandle(forWritingTo: path)
        try file.truncate(atOffset: 134_217_729); try file.close()
        let reader = HistoryReader()
        do { _ = try await reader.read(path: path.path); XCTFail("An oversized journal cannot be indexed") }
        catch {
            XCTAssertEqual(error as? StoreError, .unreadableRecord)
            XCTAssertEqual(error.localizedDescription, "This conversation file could not be read. Its bytes were left untouched.")
        }
    }

    /// A conversation longer than one index holds is not damaged. Calling it
    /// damaged blocked search, copying and Continue on a file whose bytes are
    /// all intact, and there was no way to tell the user which it was.
    func testAConversationLongerThanOneIndexIsBrowsableNotDamaged() async throws {
        let root = try scratch("cap"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("long.jsonl")
        try journal(at: path, records: 120, identified: true)
        let reader = HistoryReader()
        await reader.setIndexRecordLimit(50)
        let page = try await reader.read(path: path.path)
        XCTAssertNil(page.notice, "an intact conversation is never reported as damaged")
        let limit = try XCTUnwrap(page.limitNotice)
        XCTAssertTrue(limit.contains("longer than"), limit)
        XCTAssertTrue(limit.contains("searchable"), limit)
        XCTAssertEqual(page.total, 50)
        // Search and copying both keep working over the part that is indexed.
        let found = try await reader.searchContent(path: path.path, query: "message 4", start: 0)
        XCTAssertFalse(found.hits.isEmpty)
        let revision = try XCTUnwrap(page.revision).stamp
        let copied = try await reader.copyContentPage(path: path.path, first: 1, last: 3, cursor: .init(index: 1, offset: 0), revision: revision)
        XCTAssertFalse(copied.text.isEmpty)
        // A partial count must not manufacture unread replies.
        XCTAssertNil(page.assistantMessageCount)
        XCTAssertNotNil(page.revision, "a bounded index is still a stable revision")
        let safe = try await reader.allowsAutomaticContext(path: path.path, id: "fixture")
        XCTAssertFalse(safe, "automatic context cannot vouch for a tail it never read")
    }

    @MainActor func testChatsTheSidebarCouldNotListAreReportedOnce() async throws {
        let root = try scratch("unlisted"); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let store = try XCTUnwrap(model.store)
        try await store.put(ChatRecord(id: "readable", workspaceID: "w", title: "Readable", path: nil, profileID: "p"), kind: "chat", id: "readable")
        for index in 0..<2 {
            try await store.put(WireValue.object(["id": .string("newer-\(index)"), "title": .string("Newer shape")]), kind: "chat", id: "newer-\(index)")
        }
        await model.restore()
        XCTAssertEqual(model.chats.map(\.id), ["readable"])
        let message = try XCTUnwrap(model.error)
        XCTAssertTrue(message.contains("2 saved chats could not be listed"), message)
        XCTAssertTrue(message.contains("untouched"), message)
        try await model.traces.close(); await store.close()
    }

    func testGroupingOnlyReadsTheChatsItActuallyMoves() async throws {
        let root = try scratch("grouping"); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let topic = try await store.createTopic(TopicRecord(id: "release", workspaceID: "project", title: "Release"))
        for index in 0..<300 {
            try await store.put(ChatRecord(id: "chat-\(index)", workspaceID: "project", title: "Chat \(index)", path: nil, profileID: "p"),
                                kind: "chat", id: "chat-\(index)")
        }
        // One saved side hanging off the chat being moved: it moves with it.
        try await store.put(ChatRecord(id: "side", workspaceID: "project", title: "Side", path: nil, profileID: "p", parentSessionID: "chat-7"),
                            kind: "chat", id: "side")
        let before = await store.decodedChats
        let moved = try await store.moveChatsToTopic(ids: ["chat-7"], workspaceID: "project", topicID: topic.id)
        let decoded = await store.decodedChats - before
        print("PERF one drop into a topic over 301 chats decoded \(decoded) chat records")
        XCTAssertEqual(Set(moved.map(\.id)), ["chat-7", "side"])
        XCTAssertLessThan(decoded, 20, "a drop must not materialise every chat in the database")
        let removed = await store.decodedChats
        _ = try await store.removeTopic(id: topic.id)
        let removalDecodes = await store.decodedChats - removed
        print("PERF deleting that topic decoded \(removalDecodes) chat records")
        XCTAssertLessThan(removalDecodes, 20, "deleting a topic must not materialise every chat either")
        await store.close()
    }

    @MainActor func testBuildingTheModelDoesNotOpenSQLiteOnTheMainActor() async throws {
        let root = try scratch("deferred"); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("desktop.sqlite")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path),
                       "the first body evaluation must not open the desktop database")
        let ready = await model.prepareStore()
        XCTAssertTrue(ready)
        XCTAssertNotNil(model.store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertNil(model.error)
        try await model.traces.close(); await model.store?.close()
    }

    func testAStalledKeychainCallDoesNotLockOutEveryLaterOperation() async throws {
        let worker = KeychainWorker(timeout: .milliseconds(120))
        let gate = DispatchSemaphore(value: 0)
        do { _ = try await worker.perform { gate.wait() }; XCTFail("A stalled Keychain call must release its caller") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not respond"), error.localizedDescription) }
        // The stalled call keeps its place on the serial queue, but a retry is
        // still admitted and reports the same actionable timeout.
        do { _ = try await worker.perform { 1 }; XCTFail("The retry queues behind the stalled call") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not respond"), error.localizedDescription) }
        gate.signal()
        var recovered = false
        for _ in 0..<100 where !recovered {
            if (try? await worker.perform { 7 }) == 7 { recovered = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(recovered, "once the stalled call returns the worker must be usable again")
    }
}
