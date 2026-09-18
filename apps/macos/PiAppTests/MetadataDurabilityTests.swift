import XCTest
@testable import PiApp

final class MetadataDurabilityTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("metadata-durability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testClockCorrectionCannotDiscardRenamePinArchiveOrLaterDrafts() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = try MetadataStore(url: url)
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
        let reopened = try MetadataStore(url: url)
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
        let store = try MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
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
        let store = try MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        await store.close()
        do { _ = try await store.get(DraftRecord.self, kind: "draft", id: "missing"); XCTFail("Unavailable is not absent") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        do { _ = try await store.list(DraftRecord.self, kind: "draft"); XCTFail("Unavailable is not an empty list") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
    }
}
