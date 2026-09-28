import XCTest
@testable import PiApp

/// The app indexes a chat's journal when the chat is selected. Run-state
/// records are written several times a turn and only the newest counts: the
/// others join the index by their id and parent alone, read from the end of
/// the line, and the newest is decoded in full.
final class HistoryReaderStateTailTests: XCTestCase {
    /// A journal written the way the helper writes one: sorted keys, and a
    /// timestamp after the parent.
    private struct Journal {
        var data = Data(), parent: String?
        mutating func append(_ id: String, _ fields: [String: WireValue], timestamp: Bool = true) throws {
            var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            if timestamp { record["timestamp"] = .string("2026-09-28T13:57:00Z") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data.append(try encoder.encode(record)); data.append(10); parent = id
        }
        static func state(_ fields: [String: WireValue]) -> [String: WireValue] {
            ["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "data": .object(fields)]
        }
    }
    private func receipts(_ count: Int) -> WireValue {
        .array((0..<count).map { .object(["commandId": .string("c\($0)"), "turnId": .string("t\($0)"), "status": .string("delivered"), "state": .string("delivered")]) })
    }
    private func journal(newest: [String: WireValue], damage: (older: Bool, newest: Bool) = (false, false)) throws -> String {
        var journal = Journal()
        try journal.append("chat", ["type": .string("session"), "version": .number(3)], timestamp: false); journal.parent = nil
        try journal.append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1")])
        try journal.append("question", ["type": .string("message"), "message": .object(["role": .string("user"), "content": .string("Question")])])
        for index in 0..<40 {
            try journal.append("state-\(index)", Journal.state(["active": .bool(false), "queue": .array([]), "steering": .array([]), "commands": receipts(index),
                                                                   "runStatus": .string("failed"), "errorMessage": .string("An older failure \(index)")]))
        }
        try journal.append("answer", ["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .string("Answer")])])
        try journal.append("newest", Journal.state(newest))
        var text = String(decoding: journal.data, as: UTF8.self)
        if damage.older { text = text.replacingOccurrences(of: #""errorMessage":"An older failure 7""#, with: #""errorMessage":An older failure 7""#) }
        if damage.newest { text = text.replacingOccurrences(of: #"{"active":true"#, with: #"{"active":tru"#) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("state-tail-" + UUID().uuidString + ".jsonl")
        try Data(text.utf8).write(to: path); addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path.path
    }
    private let followUp: WireValue = .object(["commandID": .string("c1"), "turnID": .string("t-follow"), "text": .string("and then summarize"), "attachments": .array([]), "skills": .array([])])

    func testTheTailOfAStateLineIsItsIdAndParent() throws {
        var journal = Journal(); journal.parent = "before"
        try journal.append("state", Journal.state(["commands": receipts(3), "note": .string(#"a ,"id":"decoy" inside"#)]))
        let line = journal.data.dropLast()
        let tail = try XCTUnwrap(StateRecordTail.read(Data(line)))
        XCTAssertEqual(tail.id, "state"); XCTAssertEqual(tail.parent, "before")
        XCTAssertNil(StateRecordTail.read(Data(line.dropLast())), "A line that does not end as the helper writes one is decoded instead")
    }

    func testTheNewestRunStateSaysWhatIsUnfinished() async throws {
        let path = try journal(newest: ["active": .bool(true), "queue": .array([followUp]), "steering": .array([]), "commands": receipts(40),
                                        "runStatus": .string("running"), "queuePaused": .bool(false)])
        let page = try await HistoryReader().read(path: path)
        XCTAssertNil(page.notice)
        XCTAssertEqual(page.messages.map(\.id), ["question", "answer"])
        XCTAssertNil(page.failureMessage, "An older failed run is superseded")
        XCTAssertEqual(page.retainedRun?.active, true)
        XCTAssertEqual(page.retainedRun?.queue.first?["text"]?.string, "and then summarize")
    }

    func testANewestFailureIsReadAndAnOlderOneIsNot() async throws {
        let path = try journal(newest: ["active": .bool(false), "queue": .array([]), "steering": .array([]), "runStatus": .string("failed"), "errorMessage": .string("The newest failure")])
        let page = try await HistoryReader().read(path: path)
        XCTAssertNil(page.notice); XCTAssertEqual(page.failureMessage, "The newest failure"); XCTAssertNil(page.retainedRun)
    }

    /// Superseded run state is not read, so damage inside it is passed over,
    /// as the helper passes it over; damage in the newest is said.
    func testDamageIsSaidOnlyWhereTheStateIsRead() async throws {
        let newest: [String: WireValue] = ["active": .bool(true), "queue": .array([followUp]), "steering": .array([]), "runStatus": .string("running")]
        let older = try await HistoryReader().read(path: try journal(newest: newest, damage: (older: true, newest: false)))
        XCTAssertNil(older.notice); XCTAssertEqual(older.retainedRun?.active, true)
        let damaged = try await HistoryReader().read(path: try journal(newest: newest, damage: (older: false, newest: true)))
        XCTAssertNotNil(damaged.notice, "The run state that counts is damaged")
    }
}

/// Opening a long chat's journal the way selecting it does. Opt-in:
/// `PI_PERF_OPEN_JOURNAL` names a journal (the helper's
/// `SessionOpenPerformanceTests` keeps one with `PI_PERF_KEEP_JOURNAL`).
final class HistoryReaderOpenPerformanceTests: XCTestCase {
    func testIndexingAKeptJournal() async throws {
        guard let path = testEnvironment("PI_PERF_OPEN_JOURNAL") else { throw XCTSkip("Set PI_PERF_OPEN_JOURNAL to measure indexing a long chat.") }
        let repeats = testEnvironment("PI_PERF_REPEAT").flatMap(Int.init) ?? 3
        for attempt in 1...repeats {
            let clock = ContinuousClock(), start = clock.now
            let page = try await HistoryReader().window(path: path)
            let took = clock.now - start
            XCTAssertNil(page.notice)
            print("PERF app index open \(attempt): \(page.total) rows, \(took.formatted(.units(allowed: [.milliseconds])))")
        }
    }
}
