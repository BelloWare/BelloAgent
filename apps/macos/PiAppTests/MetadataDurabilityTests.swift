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
