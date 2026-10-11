import XCTest
@testable import PiApp

/// The whole chat as one document: a history page says where it stands in
/// the timeline, a page can be read at any row of it, and the transcript
/// knows how many rows lie before and after the window it holds.
final class HistoryExtentTests: XCTestCase {
    @MainActor private func journal(turns: Int) throws -> URL {
        let root = scratchRoot("history-extent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.jsonl")
        try LongChatScroll.journal(turns: turns).write(to: file)
        return file
    }

    /// Each turn of the fixture is five rows: question, reply with two
    /// calls, their two results, and the closing reply.
    @MainActor func testAPageSaysWhereItStandsAndAnyRowCanBeRead() async throws {
        let file = try journal(turns: 40)
        let reader = HistoryReader()
        let newest = try await reader.window(path: file.path)
        XCTAssertEqual(newest.total, 200)
        XCTAssertEqual(newest.start, 200 - newest.messages.count, "the newest page ends at the last row")
        let middle = try await reader.window(path: file.path, position: 101)
        XCTAssertEqual(middle.start, 101)
        XCTAssertEqual(middle.messages.first?.id, "a20a", "row 101 is turn 20's first reply")
        XCTAssertNotNil(middle.older); XCTAssertNotNil(middle.newer)
        let first = try await reader.window(path: file.path, position: 0)
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.messages.first?.id, "u0")
        XCTAssertNil(first.older)
        // Past the end reads the last row's page.
        let past = try await reader.window(path: file.path, position: 10_000)
        XCTAssertEqual(past.messages.last?.id, "a39b")
        XCTAssertNil(past.newer)
    }

    @MainActor func testTheRowsBeforeAndAfterTheWindowAreCounted() throws {
        func row(_ id: String) -> TranscriptMessage { TranscriptMessage(id: id, role: "assistant", text: id) }
        func page(_ ids: [String], start: Int, total: Int) throws -> ConversationHistoryPage {
            let messages: [WireValue] = ids.map { .object(["id": .string($0), "role": .string("assistant"), "text": .string($0)]) }
            return try ConversationHistoryPage(.object(["version": .number(2), "messages": .array(messages), "incarnation": .string("i"), "lineage": .string("l"),
                                                        "older": .null, "newer": .null, "start": .number(Double(start)), "total": .number(Double(total))]))
        }
        let positions = HistoryPositions()
        XCTAssertNil(positions.extent(of: [row("x")], reachesStart: false, reachesEnd: false), "nothing is known before a page says")
        positions.reset(try page(["m10", "m11", "m12"], start: 10, total: 50))
        XCTAssertEqual(positions.extent(of: ["m10", "m11", "m12"].map(row), reachesStart: false, reachesEnd: false),
                       HistoryExtent(before: 10, after: 37, total: 50))
        // A row the window let go of at the front, and a live row at the end
        // no page has named: counted from the rows that are known.
        XCTAssertEqual(positions.extent(of: ["m11", "m12", "live"].map(row), reachesStart: false, reachesEnd: false),
                       HistoryExtent(before: 11, after: 36, total: 50))
        // A page read below joins the window.
        positions.record(try page(["m13", "m14"], start: 13, total: 50))
        XCTAssertEqual(positions.extent(of: ["m10", "m11", "m12", "m13", "m14"].map(row), reachesStart: false, reachesEnd: false)?.after, 35)
        // The window that holds the first and the newest rows has no room around it.
        XCTAssertNil(positions.extent(of: ["m10"].map(row), reachesStart: true, reachesEnd: true))
        XCTAssertEqual(positions.extent(of: ["m10"].map(row), reachesStart: false, reachesEnd: true), HistoryExtent(before: 10, after: 0, total: 50))
        // Live rows a run adds take their places from the window, so it is
        // still placed once every row a page named has left it.
        let live = ["m13", "m14", "live1", "live2"]
        XCTAssertEqual(positions.extent(of: live.map(row), reachesStart: false, reachesEnd: true), HistoryExtent(before: 13, after: 0, total: 50))
        XCTAssertEqual(positions.extent(of: ["live1", "live2", "live3"].map(row), reachesStart: false, reachesEnd: true),
                       HistoryExtent(before: 15, after: 0, total: 50))
        // A chat just made: its one page is the whole timeline, said or not,
        // and the rows a run adds are placed from it.
        let fresh = HistoryPositions()
        fresh.reset(try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]), "incarnation": .string("new:x"), "lineage": .string("root"),
                                                          "older": .null, "newer": .null])))
        XCTAssertNil(fresh.extent(of: ["n0", "n1"].map(row), reachesStart: true, reachesEnd: true))
        XCTAssertEqual(fresh.extent(of: ["n1", "n2"].map(row), reachesStart: false, reachesEnd: true), HistoryExtent(before: 1, after: 0, total: 3))
        // A timeline that changed knows nothing until the next page.
        positions.forget()
        XCTAssertNil(positions.extent(of: ["m10"].map(row), reachesStart: false, reachesEnd: false))
    }
}
