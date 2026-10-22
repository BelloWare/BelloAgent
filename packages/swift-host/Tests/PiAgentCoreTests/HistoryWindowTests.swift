import XCTest
@testable import PiAgentCore

final class HistoryWindowTests: HelperTestCase {
    func testReaderRebindsTheSameBoundaryAcrossRuntimeReplacement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var rows: [ChatMessage] = []
        // Longer than a page, so a page around m12 has rows after it.
        for index in 0..<(HistoryWindowPolicy.pageRows + 30) {
            var row = ChatMessage(role: index % 2 == 0 ? "user" : "assistant", content: [textBlock("Message \(index)")])
            row.id = "m\(index)"; rows.append(row)
        }
        func runtime() throws -> AgentSession {
            try AgentSession(id: "same-child", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent(UUID().uuidString), readOnly: true,
                resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: rows, autoCompaction: false)
        }
        let first = try runtime(), replacement = try runtime()
        addTeardownBlock { await first.close(); await replacement.close() }
        let held = try await first.historyWindow(["around": "m12"])
        for (direction, cursor) in [("older", held["older"]), ("newer", held["newer"])] {
            XCTAssertFalse(cursor.isNull)
            let expected = try await first.historyWindow(["cursor": cursor, "direction": JSON(direction)])
            let rebound = try await replacement.historyWindow(["cursor": cursor, "direction": JSON(direction), "rebind": true])
            XCTAssertEqual(rebound["messages"], expected["messages"])
            XCTAssertNotEqual(rebound["incarnation"], held["incarnation"])
            var branch = cursor, missing = cursor
            branch["lineage"] = "different-branch"; missing["entry"] = "missing-message"
            for invalid in [branch, missing] {
                do { _ = try await replacement.historyWindow(["cursor": invalid, "rebind": true]); XCTFail("Rebinding must validate lineage and message") }
                catch let error as AgentError { XCTAssertEqual(error.code, "history_changed") }
            }
        }
    }

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
        // Whole turns of a question and a reply, a page's rows of them.
        XCTAssertEqual(ids, ((2202 - HistoryWindowPolicy.pageRows)..<2202).map { "m\($0)" })
        XCTAssertEqual(page["endsTurn"], true)
        while !page["older"].isNull {
            page = try await session.historyWindow(["cursor": page["older"]])
            XCTAssertLessThan(try page.data().count + 1024, HistoryWindowPolicy.pageBytes)
            XCTAssertTrue(page["messages"].list.first?["role"].text == "user", "Every page starts at a question")
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
        // A page can be read at any row of the timeline: where the reader
        // dragged the transcript's scroller to. It starts where that row's
        // turn does, so the turn reads whole, and says where it stands.
        let middle = try await session.historyWindow(["position": 1101])
        XCTAssertEqual(middle["messages"].list.first?["id"].text, "m1100")
        XCTAssertEqual(middle["start"].int, 1100); XCTAssertEqual(middle["total"].int, 2202)
        XCTAssertFalse(middle["older"].isNull); XCTAssertFalse(middle["newer"].isNull)
        let past = try await session.historyWindow(["position": 9999])
        XCTAssertEqual(past["messages"].list.last?["id"].text, "m2201", "a position past the end reads the last row's page")
        XCTAssertTrue(past["newer"].isNull)
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
    /// History pages hold whole display turns (0.1.131): a page starts where
    /// a turn does and ends where one does, whatever the turns' lengths, so a
    /// turn's work folds the same however much of the chat is read; only a
    /// turn longer than the resident window is cut. Read back, forward, or
    /// around any row, the pages cover every row exactly once.
    func testPagesHoldWholeTurnsAndCoverTheTimeline() {
        let longest = HistoryWindowPolicy.residentRows, rows = HistoryWindowPolicy.pageRows
        for seed in 1...60 {
            var state = UInt64(seed)
            func next(_ bound: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(bound))
            }
            // Rows before the first question (a chat that opens on a notice),
            // then turns of a few rows to more than a page, a few longer than
            // the resident window.
            var starts: [Int] = [], count = next(3)
            for _ in 0..<(2 + next(12)) {
                starts.append(count)
                count += next(10) == 0 ? longest + 1 + next(500) : 1 + next(seed % 3 == 0 ? 1_500 : 140)
            }
            let opens = Set(starts)
            let giant = Set(zip(starts, starts.dropFirst() + [count]).filter { $1 - $0 > longest }.flatMap { Array($0.0..<$0.1) })
            func check(_ range: Range<Int>, _ label: String) {
                XCTAssertFalse(range.isEmpty, label)
                XCTAssertTrue(range.lowerBound == 0 || opens.contains(range.lowerBound) || giant.contains(range.lowerBound), "\(label): starts inside a turn at \(range.lowerBound)")
                XCTAssertTrue(range.upperBound == count || opens.contains(range.upperBound) || giant.contains(range.upperBound - 1), "\(label): ends inside a turn at \(range.upperBound)")
                XCTAssertLessThanOrEqual(range.count, longest, label)
                if range.count > rows {
                    XCTAssertTrue(opens.filter { range.contains($0) && $0 != range.lowerBound }.isEmpty, "\(label): a page past \(rows) rows holds one turn")
                }
            }
            var end = count, back: [Int] = []
            while end > 0 {
                let range = HistoryWindowPolicy.page(count: count, before: end, startsTurn: opens.contains)
                check(range, "seed \(seed), back from \(end)")
                back = Array(range) + back; end = range.lowerBound
            }
            XCTAssertEqual(back, Array(0..<count), "seed \(seed): reading back covers every row once")
            var after = -1, forward: [Int] = []
            while after < count - 1 {
                let range = HistoryWindowPolicy.page(count: count, after: after, startsTurn: opens.contains)
                check(range, "seed \(seed), forward after \(after)")
                forward += range; after = range.upperBound - 1
            }
            XCTAssertEqual(forward, back, "seed \(seed): reading forward covers every row once")
            for row in stride(from: 0, to: count, by: max(1, count / 37)) {
                let range = HistoryWindowPolicy.page(count: count, around: row, startsTurn: opens.contains)
                check(range, "seed \(seed), around \(row)")
                XCTAssertTrue(range.contains(row), "seed \(seed): the page around \(row) holds it")
                if !giant.contains(row) {
                    XCTAssertEqual(range.lowerBound, starts.last { $0 <= row } ?? 0, "seed \(seed): the page around \(row) starts at its turn")
                }
            }
        }
        // A timeline that holds only the newest rows of a longer one (a chat
        // opened from its metadata file) does not start a page at its first
        // row unless a turn starts there: that row's turn began before it.
        let newest = HistoryWindowPolicy.page(count: 50, before: 50, firstIsStart: false, startsTurn: { $0 == 10 || $0 == 30 })
        XCTAssertEqual(newest, 10..<50)
        XCTAssertEqual(HistoryWindowPolicy.page(count: 50, before: 50, startsTurn: { $0 == 10 || $0 == 30 }), 0..<50)
    }

    /// A page filled within its byte budget keeps whole turns: one that runs
    /// out of room ends where its last whole turn does, read forward or back.
    /// Its first turn alone may take the resident window's bytes; only a
    /// turn longer still is cut.
    func testAPageFilledWithinItsBytesKeepsWholeTurns() {
        let page = HistoryWindowPolicy.pageBytes
        func fill(_ sizes: [Int], starts: Set<Int>, forward: Bool) -> Int {
            var fill = HistoryWindowPolicy.PageFill(forward: forward)
            for index in (forward ? Array(sizes.indices) : sizes.indices.reversed()) {
                guard fill.admit(sizes[index], startsTurn: starts.contains(index)) else { break }
            }
            return fill.kept
        }
        // Turns of four rows, each row a tenth of a page: two whole turns fit.
        let tenth = Array(repeating: page / 10, count: 40), fours = Set(stride(from: 0, to: 40, by: 4))
        XCTAssertEqual(fill(tenth, starts: fours, forward: true), 8)
        XCTAssertEqual(fill(tenth, starts: fours, forward: false), 8)
        // Rows that all fit are all kept.
        XCTAssertEqual(fill(Array(repeating: 100, count: 40), starts: fours, forward: true), 40)
        // A first turn of two pages is read whole, and nothing after it.
        let long = Array(repeating: page / 10, count: 20) + Array(repeating: 100, count: 4)
        XCTAssertEqual(fill(long, starts: [0, 20], forward: true), 20)
        XCTAssertEqual(fill(long.reversed(), starts: [0, 4], forward: false), 20)
        // A turn longer than the resident window is cut where the bytes run out.
        let giant = Array(repeating: HistoryWindowPolicy.residentBytes / 10, count: 30)
        XCTAssertEqual(fill(giant, starts: [0], forward: true), 9)
        // One row larger than any budget still makes a page.
        XCTAssertEqual(fill([HistoryWindowPolicy.residentBytes * 2, 10], starts: [0, 1], forward: true), 1)
    }

    /// The helper pages a long tool-heavy chat in whole turns: an agent's
    /// delivery inside a turn is never where a page starts, every page says
    /// whether it ends where its turn does, and no page names a partial turn.
    func testHelperPagesStartAtTheReadersQuestionsNeverAtAgentDeliveries() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var rows: [ChatMessage] = []
        for turn in 0..<12 {
            var question = ChatMessage(role: "user", content: [textBlock("Question \(turn)")]); question.id = "u\(turn)"; rows.append(question)
            for step in 0..<(120 + turn * 13 % 90) {
                if step % 40 == 39 {
                    var delivery = ChatMessage(role: "user", content: [textBlock("{\"report\":\"done\"}")]); delivery.id = "d\(turn)_\(step)"
                    delivery.nativeAgentDelivery = ["version": 1, "author": "subagent"]; delivery.kind = "agent_message"
                    rows.append(delivery); continue
                }
                var call = ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON("c\(turn)_\(step)"), "name": "read", "arguments": ["path": JSON("f\(step)")]]])
                call.id = "a\(turn)_\(step)"
                var result = ChatMessage(role: "toolResult", content: [textBlock("output \(step)")]); result.id = "r\(turn)_\(step)"; result.toolCallId = "c\(turn)_\(step)"
                rows += [call, result]
            }
            var answer = ChatMessage(role: "assistant", content: [textBlock("Answer \(turn)")]); answer.id = "z\(turn)"; rows.append(answer)
        }
        let session = try AgentSession(id: "deliveries", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: rows, autoCompaction: false)
        addTeardownBlock { await session.close() }
        let ids = rows.map(\.id)
        var page = try await session.historyWindow([:]), walked: [String] = [], pages = 0
        while true {
            let shown = page["messages"].list.compactMap { $0["id"].text }
            pages += 1
            XCTAssertTrue(shown.first?.hasPrefix("u") == true, "page \(pages) starts at \(shown.first ?? "-"), not at a question")
            XCTAssertTrue(page["partialTurnInput"].isNull)
            let after = (ids.firstIndex(of: shown.last ?? "") ?? ids.count) + 1
            XCTAssertEqual(page["endsTurn"].flag, after >= ids.count || ids[after].hasPrefix("u"))
            // A page's rows, or one turn alone that is longer than a page.
            let questions = shown.filter { $0.hasPrefix("u") }.count
            XCTAssertTrue(shown.count <= HistoryWindowPolicy.pageRows || questions == 1, "page \(pages): \(shown.count) rows in \(questions) turns")
            XCTAssertLessThanOrEqual(shown.count, HistoryWindowPolicy.residentRows)
            walked = shown + walked
            if page["older"].isNull { break }
            page = try await session.historyWindow(["cursor": page["older"]])
        }
        XCTAssertGreaterThan(pages, 1, "The chat is longer than a page")
        XCTAssertEqual(walked, ids)
        // Around a delivery, the page starts at the question of its turn.
        let around = try await session.historyWindow(["around": "d5_79"])
        XCTAssertEqual(around["messages"].list.first?["id"].text, "u5")
    }

    /// A page read around a row starts at the question of its turn, so the
    /// turn reads whole; when the rows before that row are past the turn's
    /// byte budget on their own, the page starts at the row instead, as it
    /// did before pages held whole turns: a page read around a row holds it.
    func testAPageAroundARowPastItsTurnsBudgetStartsAtTheRow() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var question = ChatMessage(role: "user", content: [textBlock("Read the logs")]); question.id = "u"
        var huge = ChatMessage(role: "assistant", content: [textBlock(String(repeating: "log line\n", count: 20_000))]); huge.id = "huge"
        var target = ChatMessage(role: "assistant", content: [textBlock("The error is on line 12.")]); target.id = "target"
        var next = ChatMessage(role: "user", content: [textBlock("Fix it")]); next.id = "u2"
        let session = try AgentSession(id: "around", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: [question, huge, target, next], autoCompaction: false)
        addTeardownBlock { await session.close() }
        // A turn's budget smaller than its long reply (180 KB), as the
        // resident window's 6 MB is smaller than a reply longer still.
        await session.limitHistoryPages(.init(rows: 1_000, bytes: 64 * 1024, turnRows: 3_000, turnBytes: 128 * 1024))
        let page = try await session.historyWindow(["around": "target"])
        XCTAssertEqual(page["messages"].list.map { $0["id"].text }, ["target", "u2"])
        XCTAssertEqual(page["partialTurnInput"].text, "u", "The page starts inside the turn and says whose turn it is")
        // A turn that fits reads whole from its question.
        let whole = try await session.historyWindow(["around": "u2"])
        XCTAssertEqual(whole["messages"].list.map { $0["id"].text }, ["u2"])
    }

    func testLongToolTurnKeepsOccurrenceResultsAndByteBoundedViews() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var user = ChatMessage(role: "user", content: [textBlock("Inspect the fixtures")]); user.id = "input"
        var rows = [user]
        // One turn longer than the resident window: no page holds it whole.
        let calls = HistoryWindowPolicy.residentRows / 2 + 50
        for index in 0..<calls {
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
            XCTAssertLessThan(try page.data().count + 1024, HistoryWindowPolicy.residentBytes)
            XCTAssertLessThanOrEqual(page["messages"].list.count, HistoryWindowPolicy.residentRows)
            if page["older"].isNull { break }
            page = try await session.historyWindow(["cursor":page["older"]])
        }
        XCTAssertEqual(walked, rows.map(\.id))
        let detail = try await session.toolInput(messageID: "call-0", callID: "reused-provider-id")
        XCTAssertTrue(detail["input"].text?.contains("file-0") == true)
        let huge: JSON = ["id":"large", "role":"assistant", "text":JSON(String(repeating:"\u{0001}",count:100_000)), "tools":[]]
        let bounded = await session.boundedDisplayRow(huge)
        XCTAssertEqual(bounded, huge, "A page budget must not truncate individual content")
        let snapshot = await session.snapshot(["includeMetrics":false])
        XCTAssertLessThan(try snapshot.data().count, HistoryWindowPolicy.envelopeBytes)
    }

}
