import XCTest
@testable import PiApp

/// Selecting a chat indexes its journal from the helper's metadata file
/// (`JournalCheckpoint`): the rows from the latest checkpoint, then only the
/// records after it. What the page shows is the end of what a full index
/// shows; older rows are indexed when a page reaches them; a file the
/// journal no longer matches, or an edit after the checkpoint, and the whole
/// journal is indexed as before.
final class HistoryReaderCheckpointTests: XCTestCase {
    /// A journal as the helper writes one: sorted keys, a timestamp after the parent.
    private struct Journal {
        var data = Data(), parent: String?
        var spans: [String: (offset: UInt64, length: Int)] = [:], lines: [String: Data] = [:]
        mutating func append(_ id: String, _ fields: [String: WireValue], timestamp: Bool = true) throws {
            var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            if timestamp { record["timestamp"] = .string("2026-09-28T13:57:00Z") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let line = try encoder.encode(record)
            spans[id] = (UInt64(data.count), line.count); lines[id] = line
            data.append(line); data.append(10); parent = id
        }
        func check(_ id: String) -> JournalCheckpoint.Check {
            .init(offset: spans[id]!.offset, length: spans[id]!.length, sha256: JournalCheckpoint.digest(lines[id]!))
        }
        func row(_ id: String, _ kind: JournalCheckpoint.Row.Kind) -> JournalCheckpoint.Row {
            .init(id: id, kind: kind, offset: spans[id]!.offset, length: spans[id]!.length)
        }
    }
    private func message(_ role: String, _ text: String) -> [String: WireValue] {
        ["type": .string("message"), "message": .object(["role": .string(role), "content": .string(text)])]
    }
    /// Four turns, a compaction keeping the last two, two turns after it; with
    /// `edit`, an edit of the last question after those.
    private func journal(edit: Bool = false) throws -> (path: URL, checkpoint: JournalCheckpoint) {
        var journal = Journal()
        try journal.append("chat", ["type": .string("session"), "version": .number(3)], timestamp: false); journal.parent = nil
        try journal.append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1"), "data": .object(["version": .number(1)])])
        for turn in 0..<4 { try journal.append("q\(turn)", message("user", "Question \(turn)")); try journal.append("a\(turn)", message("assistant", "Answer \(turn)")) }
        let kept = ["q2", "a2", "q3", "a3"]
        try journal.append("summary", ["type": .string("compaction"), "summary": .string("Four questions were answered."),
                                       "nativeKeptIDs": .array(kept.map(WireValue.string)), "tokensBefore": .number(100)])
        let checkpoint = JournalCheckpoint(sessionID: "chat", header: journal.check("chat"), marker: journal.check("native"),
                                           last: journal.check("summary"), lastID: "summary",
                                           rows: kept.map { journal.row($0, .message) } + [journal.row("summary", .compaction)], rowsBefore: 4,
                                           context: ["summary"] + kept, lineage: nil, state: nil, stateKey: nil,
                                           assistantMessageCount: 4, latestAssistantMessageID: "a3", versions: MessageVersionLedger(), tasks: [], helper: "{}")
        for turn in 4..<6 { try journal.append("q\(turn)", message("user", "Question \(turn)")); try journal.append("a\(turn)", message("assistant", "Answer \(turn)")) }
        if edit {
            try journal.append("edit", ["type": .string("branch"), "fromMessageId": .string("q5"),
                                        "keptIds": .array((["summary"] + kept + ["q4", "a4"]).map(WireValue.string))])
            try journal.append("q5b", message("user", "Question 5, edited"))
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("checkpointed-" + UUID().uuidString + ".jsonl")
        try journal.data.write(to: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path); JournalCheckpoint.remove(for: path) }
        return (path, checkpoint)
    }

    func testAChatIsIndexedFromItsCheckpoint() async throws {
        let (path, checkpoint) = try journal()
        let full = try await HistoryReader().read(path: path.path)
        XCTAssertEqual(full.messages.count, 13); XCTAssertNil(full.older)
        try checkpoint.write(for: path)
        let reader = HistoryReader()
        let partial = try await reader.read(path: path.path)
        XCTAssertNil(partial.notice)
        XCTAssertEqual(partial.messages.map(\.id), ["q2", "a2", "q3", "a3", "summary", "q4", "a4", "q5", "a5"], "The checkpoint's rows, then what followed")
        XCTAssertEqual(partial.messages.map(\.text), full.messages.suffix(partial.messages.count).map(\.text), "The rows read as a full index reads them")
        XCTAssertEqual(partial.total, full.total, "Every shown row is counted")
        XCTAssertEqual(partial.assistantMessageCount, full.assistantMessageCount); XCTAssertEqual(partial.latestAssistantMessageID, full.latestAssistantMessageID)
        XCTAssertEqual(partial.lineage, full.lineage)
        XCTAssertNotNil(partial.older, "Older rows are offered though not indexed yet")
        let older = try await reader.read(path: path.path, before: "q2")
        XCTAssertEqual(older.messages.map(\.id), ["q0", "a0", "q1", "a1"], "Reaching past the checkpoint indexes the whole journal")
        XCTAssertNil(older.older)
    }

    func testTheSelectionPathPagesPastTheCheckpoint() async throws {
        let (path, checkpoint) = try journal()
        try checkpoint.write(for: path)
        let reader = HistoryReader()
        var page = try await reader.window(path: path.path), seen = page.messages.map(\.id)
        XCTAssertNotNil(page.older, "The first page offers older rows")
        // Page back as the reader scrolls up, until nothing is older.
        for _ in 0..<8 {
            guard let cursor = page.older else { break }
            page = try await reader.window(path: path.path, cursor: cursor)
            seen = page.messages.map(\.id) + seen
        }
        XCTAssertNil(page.older)
        XCTAssertEqual(seen, ["q0", "a0", "q1", "a1", "q2", "a2", "q3", "a3", "summary", "q4", "a4", "q5", "a5"], "Every row, once, in order")
    }

    /// Search, copy, an edit's timeline and a row's role read the whole chat:
    /// they index the whole journal, whatever the page before them did.
    func testWholeChatReadersIndexTheWholeJournal() async throws {
        let (path, checkpoint) = try journal()
        try checkpoint.write(for: path)
        let reader = HistoryReader()
        let page = try await reader.read(path: path.path)
        XCTAssertNotNil(page.older, "The page came from the checkpoint")
        let found = try await reader.searchContent(path: path.path, query: "Question 0", start: 0)
        XCTAssertEqual(found.hits.map(\.id), ["q0"], "Search covers the rows before the checkpoint")
        XCTAssertEqual(found.total, 13)
        let role = try await reader.messageRole(path: path.path, id: "q1")
        XCTAssertEqual(role, "user")
    }

    func testAFileTheJournalDoesNotMatchIsNotUsed() async throws {
        let (path, checkpoint) = try journal()
        let full = try await HistoryReader().read(path: path.path)
        var wrong = checkpoint; wrong.last.sha256 = String(repeating: "0", count: 64)
        try wrong.write(for: path)
        let checked = try await HistoryReader().read(path: path.path)
        XCTAssertEqual(checked.messages.map(\.id), full.messages.map(\.id)); XCTAssertNil(checked.older)
        var moved = checkpoint; moved.rows[1].offset += 1
        try moved.write(for: path)
        let rowMoved = try await HistoryReader().read(path: path.path)
        XCTAssertEqual(rowMoved.messages.map(\.id), full.messages.map(\.id))
    }

    func testAnEditAfterTheCheckpointIsIndexedFromTheStart() async throws {
        let (path, checkpoint) = try journal(edit: true)
        let full = try await HistoryReader().read(path: path.path)
        try checkpoint.write(for: path)
        let read = try await HistoryReader().read(path: path.path)
        XCTAssertEqual(read.messages.map(\.id), full.messages.map(\.id), "The edit is replayed over the whole journal")
        XCTAssertEqual(read.lineage, full.lineage)
        XCTAssertNil(read.older)
    }
}
