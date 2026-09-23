import XCTest
@testable import PiApp

/// The Session Inspector's navigator model: the session's requests grouped
/// into turns, read from the request log's typed columns, merged with the
/// helper's live records and the replies' own records, and stepped through.
final class InspectorIndexTests: XCTestCase {
    private func row(_ id: String, turn: String?, wall: Double, purpose: String = "turn", outcome: String = "completed",
                     input: Double? = 1_000, cached: Double? = 800, output: Double? = 100, cost: Double? = 0.001,
                     alias: String? = "ui-fixture", model: String? = "gpt-5.4") -> InspectorRequestRow {
        InspectorRequestRow(id: id, wall: wall, turn: turn, purpose: purpose, api: "openai-responses", alias: alias, model: model,
                            outcome: outcome, input: input, cached: cached, output: output, cost: cost,
                            ttft: 400, decode: 1_000, duration: 1_500, http: 1_550)
    }
    private func wire(_ json: String) throws -> [String: WireValue] {
        try JSONDecoder().decode([String: WireValue].self, from: Data(json.utf8))
    }

    func testTurnsGroupRequestsInTheOrderTheyRanWithOtherRequestsLast() {
        let index = InspectorIndex(archived: [
            row("b2", turn: "t2", wall: 30), row("a1", turn: "t1", wall: 10), row("x", turn: nil, wall: 15, purpose: "title"),
            row("a2", turn: "t1", wall: 20), row("c1", turn: "t2", wall: 25)])
        XCTAssertEqual(index.turns.map(\.id), ["t1", "t2", InspectorTurn.otherID])
        XCTAssertEqual(index.turns.map(\.number), [1, 2, 0])
        XCTAssertEqual(index.turn("t1")?.requests.map(\.id), ["a1", "a2"])
        XCTAssertEqual(index.turn("t2")?.requests.map(\.id), ["c1", "b2"])
        XCTAssertEqual(index.requests.map(\.id), ["a1", "a2", "c1", "b2", "x"], "Navigation runs turn by turn, the other requests last")
        XCTAssertEqual(index.turn(containing: "c1")?.id, "t2")
        XCTAssertEqual(index.turn("t1")?.summary, "2 requests · $0.002")
        XCTAssertEqual(index.turn(InspectorTurn.otherID)?.summary, "1 request · $0.001")
        XCTAssertEqual(index.turn("t1")?.started, 10)
        XCTAssertFalse(index.isEmpty)
        XCTAssertTrue(InspectorIndex().isEmpty)
    }

    func testArchivedRowsReadTypedColumnsOnly() throws {
        let columns = Set(InspectorRequestRow.columns.split(separator: ",").map(String.init))
        XCTAssertFalse(columns.contains("metadata"), "The navigator never reads a metadata blob")
        XCTAssertTrue(columns.isSuperset(of: ["id", "wall", "turn", "purpose", "alias", "response_model", "outcome", "input_tokens", "cost_usd"]))
        let sql: [String: CaptureSQLValue] = [
            "id": .text("A"), "wall": .real(100), "turn": .text("t"), "purpose": .text("turn"), "api": .text("openai-responses"),
            "alias": .text("fixture-fast"), "model": .text("gpt-5.4-mini-2026-03"), "response_model": .text("gpt-5.4-mini"),
            "outcome": .text("completed"), "metrics_retained": .integer(1), "dispatch": .real(5),
            "ttft_ms": .real(820), "stream_ms": .real(2_500), "request_ms": .real(3_400), "http_ms": .real(3_450),
            "input_tokens": .real(18_240), "cache_read_tokens": .real(15_112), "cache_write_tokens": .null,
            "output_tokens": .real(1_104), "reasoning_tokens": .real(640), "cost_usd": .real(0.0213)]
        let row = try InspectorRequestRow.archived(sql)
        XCTAssertEqual(row.id, "A"); XCTAssertEqual(row.wall, 100); XCTAssertEqual(row.turn, "t")
        XCTAssertEqual(row.alias, "fixture-fast")
        XCTAssertEqual(row.model, "gpt-5.4-mini", "The response body's name is the one shown")
        XCTAssertEqual(row.ttft, 820); XCTAssertEqual(row.decode, 2_500); XCTAssertEqual(row.duration, 3_400); XCTAssertEqual(row.http, 3_450)
        XCTAssertEqual(row.input, 18_240); XCTAssertEqual(row.cached, 15_112); XCTAssertNil(row.cacheWrite)
        XCTAssertEqual(row.output, 1_104); XCTAssertEqual(row.reasoning, 640); XCTAssertEqual(row.cost, 0.0213)
        XCTAssertTrue(row.dispatched); XCTAssertTrue(row.metricsRetained); XCTAssertEqual(row.source, .log)
        XCTAssertEqual(row.route.label, "fixture-fast → gpt-5.4-mini")
        XCTAssertEqual(row.tokenFlow, "18.2K → 1.1K")
        XCTAssertEqual(try XCTUnwrap(row.cachedShare), 15_112 / 18_240, accuracy: 1e-9)
        XCTAssertNotNil(row.settledRate)
        XCTAssertEqual(row.settledRate, row.sample.settledTokensPerSecond, "The rate is the settled rate the charts plot")
        XCTAssertEqual(row.sample.id, "A"); XCTAssertEqual(row.sample.model, "gpt-5.4-mini"); XCTAssertEqual(row.sample.turn, "t")
        XCTAssertThrowsError(try InspectorRequestRow.archived(["wall": .real(1)]), "A row without an id is corrupt")
        let expired = try InspectorRequestRow.archived(["id": .text("B"), "wall": .real(1), "turn": .text(""), "purpose": .text("title"),
                                                        "api": .text(""), "alias": .text("mini"), "outcome": .text("completed"), "metrics_retained": .integer(0)])
        XCTAssertNil(expired.turn, "An empty turn column is no turn")
        XCTAssertFalse(expired.metricsRetained); XCTAssertFalse(expired.dispatched)
        XCTAssertNil(expired.tokenFlow); XCTAssertNil(expired.cost)
        XCTAssertEqual(expired.route.label, "mini → —")
        let running = try InspectorRequestRow.archived(["id": .text("C"), "wall": .real(2), "purpose": .text("turn"), "api": .text(""), "outcome": .text("running")])
        XCTAssertTrue(running.running); XCTAssertFalse(running.failed)
        let failed = try InspectorRequestRow.archived(["id": .text("D"), "wall": .real(2), "purpose": .text("turn"), "api": .text(""), "outcome": .text("interrupted")])
        XCTAssertTrue(failed.failed); XCTAssertFalse(failed.running)
    }

    func testLiveRecordsMergeWithoutDuplicatesAndKeepTheNewestRunningFigures() throws {
        let metadata = try wire("""
        {"attemptId":"L","sessionId":"s","turnId":"t","purpose":"turn","api":"openai-responses","requestedModel":"ui-fixture",
         "outcome":"running","wallTimestamp":50,"dispatchWallTimestamp":51,"metrics":{"observedTTFTms":300},
         "usage":{"inputIncludingCache":900,"cacheRead":700,"output":12}}
        """)
        let live = try XCTUnwrap(InspectorRequestRow.live(metadata))
        XCTAssertEqual(live.source, .live); XCTAssertEqual(live.id, "L"); XCTAssertEqual(live.wall, 51)
        XCTAssertTrue(live.running); XCTAssertEqual(live.alias, "ui-fixture"); XCTAssertEqual(live.turn, "t")
        XCTAssertEqual(live.ttft, 300); XCTAssertEqual(live.input, 900); XCTAssertEqual(live.cached, 700); XCTAssertEqual(live.output, 12)
        XCTAssertNil(InspectorRequestRow.live(try wire("{\"sessionId\":\"s\"}")), "A record without an attempt id is not a request")

        let durableRunning = row("L", turn: "t", wall: 51, outcome: "running", output: nil)
        let durableDone = row("D", turn: "t", wall: 40)
        var liveDone = row("D", turn: "t", wall: 40, outcome: "completed", output: 999); liveDone.source = .live
        var liveOnly = row("N", turn: "t", wall: 60, outcome: "running"); liveOnly.source = .live
        let merged = InspectorIndex.merge(durable: [durableRunning, durableDone], live: [live, liveDone, liveOnly])
        XCTAssertEqual(merged.map(\.id), ["D", "L", "N"], "One row per request, in the order they ran")
        XCTAssertEqual(merged.first { $0.id == "L" }?.source, .live, "A running request shows the helper's newer figures")
        XCTAssertEqual(merged.first { $0.id == "D" }?.source, .log, "A settled request keeps the log's record")
        XCTAssertEqual(merged.first { $0.id == "D" }?.output, 100)
        XCTAssertEqual(merged.first { $0.id == "N" }?.source, .live, "A request only the helper has seen so far is listed")
    }

    func testRecordLinesFillRequestsMissingFromTheLog() {
        var inLog = TurnRequestLine(reply: TranscriptMessage(id: "m1", role: "assistant", text: "", at: 10_000,
                                                             reply: ReplyRecord(attempt: "a1", requested: "ui-fixture")))
        inLog.source = .record
        let missing = TranscriptMessage(id: "m2", role: "assistant", text: "", at: 20_000, turn: "t1",
                                        reply: ReplyRecord(attempt: "gone", requested: "ui-fixture",
                                                           models: [.init(name: "gpt-5.4", source: "body.model")],
                                                           usage: .init(input: 100, output: 20, cacheRead: 50)))
        let line = TurnRequestLine(reply: missing)
        let index = InspectorIndex(archived: [row("a1", turn: "t1", wall: 10)], records: ["t1": [inLog, line]])
        XCTAssertEqual(index.turn("t1")?.requests.map(\.id), ["a1", "gone"], "The log's request once, then the one only the reply recorded")
        let record = try? XCTUnwrap(index.request("gone"))
        XCTAssertEqual(record?.source, .record)
        XCTAssertEqual(record?.input, 150, "The record's input counts its cache reads, as the gateway does")
        XCTAssertEqual(record?.cached, 50); XCTAssertEqual(record?.output, 20); XCTAssertEqual(record?.model, "gpt-5.4")
        XCTAssertEqual(record?.wall, 20)
        XCTAssertEqual(index.latestRequestID, "a1", "Only a request with a log row can open on its own")
        XCTAssertEqual(index.history.requests.map(\.id), ["a1"], "The charts draw the log's requests")
    }

    func testNavigationStepsAcrossTurnsAndCountsWithinATurn() {
        let index = InspectorIndex(archived: [row("a1", turn: "t1", wall: 10), row("a2", turn: "t1", wall: 11), row("a3", turn: "t1", wall: 12),
                                              row("b1", turn: "t2", wall: 20)])
        XCTAssertEqual(index.position(of: "a2")?.index, 2); XCTAssertEqual(index.position(of: "a2")?.count, 3)
        XCTAssertEqual(index.position(of: "b1")?.index, 1); XCTAssertEqual(index.position(of: "b1")?.count, 1)
        XCTAssertNil(index.position(of: "nope"))
        XCTAssertEqual(index.adjacent(to: "a3", step: 1), "b1", "Stepping past a turn's last request opens the next turn's first")
        XCTAssertEqual(index.adjacent(to: "b1", step: -1), "a3")
        XCTAssertNil(index.adjacent(to: "b1", step: 1))
        XCTAssertNil(index.adjacent(to: "a1", step: -1))
        XCTAssertEqual(index.latestRequestID, "b1")
    }

    func testPredecessorIsTheTurnsPreviousRequestElseThePreviousTurnsLast() {
        let index = InspectorIndex(archived: [
            row("a1", turn: "t1", wall: 10), row("a2", turn: "t1", wall: 11),
            row("c1", turn: "t2", wall: 19, purpose: "compaction"), row("b1", turn: "t2", wall: 20), row("b2", turn: "t2", wall: 21),
            row("c2", turn: "t3", wall: 29, purpose: "compaction"), row("t", turn: nil, wall: 30, purpose: "title")])
        XCTAssertNil(index.predecessor(of: "a1"), "The session's first request has nothing before it")
        XCTAssertEqual(index.predecessor(of: "a2")?.id, "a1")
        XCTAssertEqual(index.predecessor(of: "b1")?.id, "a2", "A turn's first request follows the previous turn's last, past the compaction")
        XCTAssertEqual(index.predecessor(of: "b2")?.id, "b1")
        XCTAssertNil(index.predecessor(of: "c1"), "A compaction has no earlier compaction to compare with")
        XCTAssertEqual(index.predecessor(of: "c2")?.id, "c1", "A compaction follows the previous compaction")
        XCTAssertNil(index.predecessor(of: "t"))
    }

    func testKindsNameFirstRequestToolRoundRetryAndCompaction() {
        let index = InspectorIndex(archived: [
            row("a1", turn: "t1", wall: 10), row("a2", turn: "t1", wall: 11, outcome: "failed"), row("a3", turn: "t1", wall: 12),
            row("a4", turn: "t1", wall: 13), row("c1", turn: "t1", wall: 14, purpose: "compaction"), row("x", turn: nil, wall: 20, purpose: "title")])
        XCTAssertEqual(index.kind(of: "a1"), "first request")
        XCTAssertEqual(index.kind(of: "a2"), "tool round")
        XCTAssertEqual(index.kind(of: "a3"), "retry", "A request after a failed one repeats it")
        XCTAssertEqual(index.kind(of: "a4"), "tool round")
        XCTAssertEqual(index.kind(of: "c1"), "compaction")
        XCTAssertEqual(index.kind(of: "x"), "title")
        XCTAssertEqual(index.kind(of: "missing"), "request")
    }

    func testFocusResolvesToTheRequestTheMessageCameFromElseItsTurn() {
        let index = InspectorIndex(archived: [row("a1", turn: "u1", wall: 10), row("a2", turn: "u1", wall: 11), row("b1", turn: "u2", wall: 20)])
        XCTAssertEqual(index.resolve(.overview), .overview)
        XCTAssertEqual(index.resolve(.nextRequest), .nextRequest)
        XCTAssertEqual(index.resolve(.latestRequest), .request("b1"))
        XCTAssertEqual(index.resolve(.turn("u1")), .turn("u1"))
        XCTAssertNil(index.resolve(.turn("unknown")), "An unknown turn waits for the next read")
        XCTAssertEqual(index.resolve(.request("a2")), .request("a2"))
        XCTAssertEqual(index.resolve(.message("m"), message: InspectorMessageHint(id: "m", role: "assistant", attempt: "a2", turn: "u1")), .request("a2"))
        XCTAssertEqual(index.resolve(.message("u2"), message: InspectorMessageHint(id: "u2", role: "user", attempt: nil, turn: "u2")), .turn("u2"),
                       "A prompt opens its turn")
        XCTAssertEqual(index.resolve(.message("tool"), message: InspectorMessageHint(id: "tool", role: "tool", attempt: nil, turn: "u1")), .turn("u1"),
                       "A row with no request of its own opens its turn")
        XCTAssertEqual(index.resolve(.message("m"), message: InspectorMessageHint(id: "m", role: "assistant", attempt: "expired", turn: "u2")), .turn("u2"),
                       "A request the log no longer has falls back to its turn")
        XCTAssertNil(index.resolve(.message("m"), message: nil))
        XCTAssertEqual(InspectorIndex().resolve(.latestRequest), .overview, "An empty session opens on its overview")
    }

    func testChartsHistorySkipsRequestsThatNeverDispatchedOrExpired() {
        var undispatched = row("u", turn: "t1", wall: 5); undispatched.dispatched = false
        var expired = row("e", turn: "t1", wall: 6); expired.metricsRetained = false
        let index = InspectorIndex(archived: [row("a", turn: "t1", wall: 10), undispatched, expired, row("b", turn: "t2", wall: 20)], olderRequests: 7)
        XCTAssertEqual(index.history.requests.map(\.id), ["a", "b"])
        XCTAssertEqual(index.history.olderRequests, 7)
        XCTAssertEqual(index.olderRequests, 7)
    }

    func testArchiveReadsTheSessionsTypedColumnsWithoutDecodingMetadata() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("inspector-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 1_000_000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10_000_000)
        func metadata(_ id: String, session: String = "s", turn: String, wall: Double, output: Double) throws -> [String: WireValue] {
            try wire("""
            {"attemptId":"\(id)","sessionId":"\(session)","turnId":"\(turn)","purpose":"turn","api":"openai-responses",
             "requestedModel":"ui-fixture","mode":"off","outcome":"completed","wallTimestamp":\(wall - 1),"dispatchWallTimestamp":\(wall),
             "timingVersion":2,"timings":{"dispatch":100,"firstContent":300,"lastContent":1100,"modelComplete":1200,"httpEnd":1250},
             "usage":{"inputIncludingCache":500,"cacheRead":400,"output":\(output)},"outputMessageIds":["out-\(id)"]}
            """)
        }
        let ids = (0..<3).map { _ in UUID().uuidString }
        for (offset, id) in ids.enumerated() {
            let value = try metadata(id, turn: offset < 2 ? "u1" : "u2", wall: 999_000 + Double(offset), output: Double(10 + offset))
            try await archive.begin(value, workspace: "p"); try await archive.finish(value)
        }
        let other = try metadata(UUID().uuidString, session: "other", turn: "u1", wall: 999_100, output: 5)
        try await archive.begin(other, workspace: "p"); try await archive.finish(other)
        let decodedBefore = await archive.decodedMetadata
        let read = try await archive.inspectorRows(sessionID: "s", workspaceID: "p")
        let decodedAfter = await archive.decodedMetadata
        XCTAssertEqual(decodedAfter, decodedBefore, "Reading the navigator decodes no metadata blob")
        XCTAssertEqual(read.rows.map(\.id), ids, "The session's own requests, oldest first")
        XCTAssertEqual(read.older, 0)
        XCTAssertEqual(read.rows.map(\.output), [10, 11, 12])
        XCTAssertEqual(read.rows.first?.ttft, 200); XCTAssertEqual(read.rows.first?.input, 500); XCTAssertEqual(read.rows.first?.cached, 400)
        let bounded = try await archive.inspectorRows(sessionID: "s", workspaceID: "p", limit: 2)
        XCTAssertEqual(bounded.rows.map(\.id), Array(ids.suffix(2)), "The newest rows when a session has more than the bound")
        XCTAssertEqual(bounded.older, 1)
        let signature = try await archive.inspectorSignature(sessionID: "s", workspaceID: "p")
        XCTAssertFalse(signature.isEmpty)
        let next = try metadata(UUID().uuidString, turn: "u2", wall: 999_010, output: 3)
        try await archive.begin(next, workspace: "p")
        let changed = try await archive.inspectorSignature(sessionID: "s", workspaceID: "p")
        XCTAssertNotEqual(changed, signature, "A new request changes the signature the poll compares")
        let producing = try await archive.attempts(producing: "out-\(ids[1])", workspaceID: "p")
        XCTAssertEqual(producing, [ids[1]])
        let injected = try await archive.inspectorRows(sessionID: "s' OR 1=1 --", workspaceID: "p")
        XCTAssertTrue(injected.rows.isEmpty)
        try await archive.close()
    }
}
