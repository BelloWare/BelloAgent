import XCTest
@testable import PiApp

/// The journal reader pages a chat in whole display turns (0.1.131), as the
/// helper does (`HistoryWindowPolicy.page`): a page starts at a question of
/// the reader's and ends where a turn does, so a turn's work folds the same
/// however much of the chat the transcript has read. An agent's delivery is a
/// user row inside a turn, never where a page starts.
final class HistoryTurnPagingTests: XCTestCase {
    /// Turns of 120 to 210 tool calls, an agent's delivery every fortieth
    /// step, and an answer: about 3,600 rows. Returns the file and its rows'
    /// ids in order.
    private func journal(turns: Int = 12) throws -> (path: URL, ids: [String]) {
        let encoder = JSONEncoder()
        var data = try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("turns")]); data.append(10)
        var parent: String?, ids: [String] = []
        func add(_ id: String, _ message: [String: WireValue]) throws {
            data.append(try encoder.encode(["type": WireValue.string("message"), "id": .string(id), "parentId": parent.map(WireValue.string) ?? .null,
                                            "message": .object(message)]))
            data.append(10); parent = id; ids.append(id)
        }
        for turn in 0..<turns {
            try add("q\(turn)", ["role": .string("user"), "content": .string("Question \(turn)")])
            for step in 0..<(120 + turn * 13 % 90) {
                if step % 40 == 39 {
                    try add("d\(turn)_\(step)", ["role": .string("user"), "content": .string("{\"report\":\"done\"}"),
                                                 "nativeAgentDelivery": .object(["version": .number(1), "author": .string("subagent")])])
                    continue
                }
                try add("a\(turn)_\(step)", ["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("c\(turn)_\(step)"),
                                                                                                       "name": .string("read"), "arguments": .object(["path": .string("f\(step)")])])])])
                try add("r\(turn)_\(step)", ["role": .string("toolResult"), "toolCallId": .string("c\(turn)_\(step)"), "toolName": .string("read"),
                                             "content": .array([.object(["type": .string("text"), "text": .string("output \(step)")])])])
            }
            try add("z\(turn)", ["role": .string("assistant"), "content": .string("Answer \(turn)")])
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("turn-pages-" + UUID().uuidString + ".jsonl")
        try data.write(to: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return (path, ids)
    }

    func testJournalPagesHoldWholeTurnsAndNeverStartAtAnAgentsDelivery() async throws {
        let (path, ids) = try journal()
        let reader = HistoryReader()
        func check(_ page: HistoryPage, _ label: String) {
            let shown = page.messages.map(\.id)
            XCTAssertTrue(shown.first?.hasPrefix("q") == true, "\(label) starts at \(shown.first ?? "-"), not at a question")
            XCTAssertNil(page.partialTurnInput, label)
            XCTAssertLessThanOrEqual(shown.count, HistoryWindowPolicy.pageRows, label)
            let after = (ids.firstIndex(of: shown.last ?? "") ?? ids.count) + 1
            XCTAssertEqual(page.endsTurn, after >= ids.count || ids[after].hasPrefix("q"), "\(label) says where it ends")
            XCTAssertTrue(after >= ids.count || ids[after].hasPrefix("q"), "\(label) ends inside a turn, before \(ids[min(after, ids.count - 1)])")
        }
        var page = try await reader.window(path: path.path), back: [String] = [], pages = 0
        while true {
            pages += 1; check(page, "page \(pages) back")
            back = page.messages.map(\.id) + back
            guard let older = page.older else { break }
            page = try await reader.window(path: path.path, cursor: older)
        }
        XCTAssertGreaterThan(pages, 2, "The chat is several pages long")
        XCTAssertEqual(back, ids, "Read back, the pages cover every row once")
        page = try await reader.window(path: path.path, start: true)
        var forward: [String] = []
        while true {
            check(page, "page forward from \(page.messages.first?.id ?? "-")")
            forward += page.messages.map(\.id)
            guard let newer = page.newer else { break }
            page = try await reader.window(path: path.path, cursor: newer, newer: true)
        }
        XCTAssertEqual(forward, ids, "Read forward, the pages cover every row once")
        // Around a delivery, and at a row in the middle of a turn: the page
        // starts at the question of that turn, so the turn reads whole.
        let around = try await reader.window(path: path.path, around: "d5_79")
        XCTAssertEqual(around.messages.first?.id, "q5")
        let middle = try XCTUnwrap(ids.firstIndex(of: "a7_100"))
        let placed = try await reader.window(path: path.path, position: middle)
        XCTAssertEqual(placed.messages.first?.id, "q7"); XCTAssertEqual(placed.start, ids.firstIndex(of: "q7"))
        XCTAssertTrue(placed.messages.contains { $0.id == "a7_100" })
    }

    /// A chat opened from its metadata file is indexed from the rows its
    /// last compaction kept, which can begin inside a turn. The newest page
    /// starts at the first question among them, and the page before reads
    /// the whole journal so that it holds that turn whole.
    func testACheckpointIndexThatStartsInsideATurnPagesFromAQuestion() async throws {
        struct Journal {
            var data = Data(), parent: String?
            var spans: [String: (offset: UInt64, length: Int)] = [:], lines: [String: Data] = [:]
            mutating func append(_ id: String, _ fields: [String: WireValue], timestamp: Bool = true) throws {
                var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
                if timestamp { record["timestamp"] = .string("2026-10-22T13:57:00Z") }
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
        func message(_ role: String, _ text: String) -> [String: WireValue] {
            ["type": .string("message"), "message": .object(["role": .string(role), "content": .string(text)])]
        }
        var journal = Journal()
        try journal.append("chat", ["type": .string("session"), "version": .number(3)], timestamp: false); journal.parent = nil
        try journal.append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1"), "data": .object(["version": .number(1)])])
        for turn in 0..<2 { try journal.append("q\(turn)", message("user", "Question \(turn)")); try journal.append("a\(turn)", message("assistant", "Answer \(turn)")) }
        // A turn of work: the compaction keeps its last two rows, not its question.
        try journal.append("q2", message("user", "Question 2"))
        for step in 0..<3 { try journal.append("w\(step)", message("assistant", "Work \(step)")) }
        try journal.append("q3", message("user", "Question 3")); try journal.append("a3", message("assistant", "Answer 3"))
        let kept = ["w1", "w2", "q3", "a3"]
        try journal.append("summary", ["type": .string("compaction"), "summary": .string("Work was done."),
                                       "nativeKeptIDs": .array(kept.map(WireValue.string)), "tokensBefore": .number(100)])
        let checkpoint = JournalCheckpoint(sessionID: "chat", header: journal.check("chat"), marker: journal.check("native"),
                                           last: journal.check("summary"), lastID: "summary",
                                           rows: kept.map { journal.row($0, .message) } + [journal.row("summary", .compaction)], rowsBefore: 6,
                                           context: ["summary"] + kept, lineage: nil, state: nil, stateKey: nil,
                                           assistantMessageCount: 6, latestAssistantMessageID: "a3", versions: MessageVersionLedger(), tasks: [], helper: "{}")
        for turn in 4..<6 { try journal.append("q\(turn)", message("user", "Question \(turn)")); try journal.append("a\(turn)", message("assistant", "Answer \(turn)")) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-turns-" + UUID().uuidString + ".jsonl")
        try journal.data.write(to: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path); JournalCheckpoint.remove(for: path) }
        try checkpoint.write(for: path)
        let reader = HistoryReader()
        let newest = try await reader.window(path: path.path)
        XCTAssertNil(newest.notice)
        XCTAssertEqual(newest.messages.map(\.id), ["q3", "a3", "summary", "q4", "a4", "q5", "a5"], "Not the kept rows of a turn whose question is not among them")
        XCTAssertNil(newest.partialTurnInput)
        let older = try XCTUnwrap(newest.older)
        let earlier = try await reader.window(path: path.path, cursor: older)
        XCTAssertEqual(earlier.messages.map(\.id), ["q0", "a0", "q1", "a1", "q2", "w0", "w1", "w2"], "The turn the kept rows began inside reads whole")
        XCTAssertTrue(earlier.endsTurn)
    }
}
