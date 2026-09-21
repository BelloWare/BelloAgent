import XCTest
@testable import PiAgentCore

final class HistoryWindowTests: XCTestCase {
    func testHelperTurnWindowsTraverseIdenticalTimelineAndPreserveModelContext() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var rows: [ChatMessage] = []
        for index in 0..<2202 {
            var message = ChatMessage(role: index % 2 == 0 ? "user" : "assistant", content: [textBlock("Evidence \(index)")])
            message.id = "m\(index)"; message.turn = "task-\(index / 6)" // Includes distinct delivered inputs within a task.
            rows.append(message)
        }
        let session = try AgentSession(id: "history", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: rows, autoCompaction: false)
        addTeardownBlock { await session.close() }
        let before = await session.context.map(\.id)
        var page = try await session.historyWindow([:]), ids = page["messages"].list.compactMap { $0["id"].text }
        XCTAssertEqual(ids, (2196..<2202).map { "m\($0)" })
        while !page["older"].isNull {
            page = try await session.historyWindow(["cursor": page["older"]])
            XCTAssertLessThan(try page.data().count + 1024, HistoryWindowPolicy.envelopeBytes)
            ids = page["messages"].list.compactMap { $0["id"].text } + ids
        }
        XCTAssertEqual(ids, rows.map(\.id))
        var forward = page["messages"].list.compactMap { $0["id"].text }
        while !page["newer"].isNull {
            page = try await session.historyWindow(["cursor": page["newer"], "direction": "newer"])
            forward += page["messages"].list.compactMap { $0["id"].text }
        }
        XCTAssertEqual(forward, ids)
        let after = await session.context.map(\.id)
        XCTAssertEqual(after, before, "Presentation windows must not become model context")
        let around = try await session.historyWindow(["around": "m4"])
        XCTAssertEqual(around["messages"].list.first?["id"].text, "m4")
        do { _ = try await session.historyWindow(["cursor": ["incarnation":"stale", "lineage":"root", "entry":"m4"]]); XCTFail("Stale source accepted") } catch { }
    }

    func testPropertyGeneratedTurnRangesHaveNoOmissionsAcrossSegmentation() {
        for seed in 1...60 {
            let count = seed * 31, users = Set((0..<count).filter { $0 % (seed + 1) == 0 })
            var end = count, walked: [Int] = [], pages: [Range<Int>] = []
            while end > 0 {
                let range = HistoryWindowPolicy.range(count: count, before: end, isUser: users.contains)
                XCTAssertFalse(range.isEmpty); XCTAssertLessThanOrEqual(range.count, 60)
                pages.append(range); walked = Array(range) + walked; end = range.lowerBound
            }
            XCTAssertEqual(walked, Array(0..<count))
            var start = -1, forward: [Int] = []
            while start < count - 1 {
                let range = HistoryWindowPolicy.range(count: count, after: start, isUser: users.contains)
                forward += range; start = range.upperBound - 1
            }
            XCTAssertEqual(forward, walked)
        }
    }
    func testLongToolTurnKeepsOccurrenceResultsAndByteBoundedViews() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var user = ChatMessage(role: "user", content: [textBlock("Inspect the fixtures")]); user.id = "input"
        var rows = [user]
        for index in 0..<101 {
            var call = ChatMessage(role: "assistant", content: [["type":"toolCall", "id":"reused-provider-id", "name":"read", "arguments":["path":JSON("file-\(index)")]]])
            call.id = "call-\(index)"
            var result = ChatMessage(role: "toolResult", content: [textBlock("result-\(index)")]); result.id = "result-\(index)"; result.toolCallId = "reused-provider-id"
            rows += [call, result]
        }
        let session = try AgentSession(id: "tools", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: rows, autoCompaction: false)
        addTeardownBlock { await session.close() }
        var page = try await session.historyWindow([:]), walked: [String] = []
        XCTAssertEqual(page["partialTurnInput"].text, "input")
        while true {
            let ids = page["messages"].list.compactMap { $0["id"].text }
            walked = ids + walked
            for row in page["messages"].list where row["role"].text == "assistant" {
                let index = String((row["id"].text ?? "").dropFirst(5))
                XCTAssertEqual(row["tools"].list.first?["output"].text, "result-" + index)
                XCTAssertEqual(row["toolCallCount"].int, 1)
            }
            XCTAssertLessThan(try page.data().count + 1024, HistoryWindowPolicy.envelopeBytes)
            if page["older"].isNull { break }
            page = try await session.historyWindow(["cursor":page["older"]])
        }
        XCTAssertEqual(walked, rows.map(\.id))
        let detail = try await session.toolInput(messageID: "call-0", callID: "reused-provider-id")
        XCTAssertTrue(detail["input"].text?.contains("file-0") == true)
        let huge: JSON = ["id":"large", "role":"assistant", "text":JSON(String(repeating:"\u{0001}",count:100_000)), "tools":[]]
        let bounded = await session.boundedDisplayRow(huge)
        XCTAssertTrue(bounded["truncated"].flag == true)
        XCTAssertLessThan(try bounded.data().count, 8192)
        let snapshot = await session.snapshot(["includeMetrics":false])
        XCTAssertLessThan(try snapshot.data().count, HistoryWindowPolicy.envelopeBytes)
    }

}
