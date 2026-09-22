import XCTest
@testable import PiApp

/// Scale of the real retained-accounting query, independently of HTTP or body
/// storage. Projection/migration correctness is covered by GatewayAccountingTests.
final class AccountingScaleTests: XCTestCase {
    private let recordCount = 100_000

    private func folder() throws -> URL {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("accounting-scale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seed(_ root: URL) throws {
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        // Seed the current typed projection with one SQLite transaction instead
        // of measuring 100,000 unrelated native capture begin/finish operations.
        try db.transaction {
            try db.execute("""
            WITH RECURSIVE sequence(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM sequence WHERE n<99999)
            INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,model,outcome,wall,updated,metadata,
              metrics_retained,dispatch,ttft_ms,stream_ms,http_ms,identity_status,
              cost_usd,cost_status,cache_status,cache_read_tokens,cache_write_tokens)
            SELECT printf('00000000-0000-0000-0000-%012d',n),
              CASE WHEN n>=90000 AND n<99000 THEN 'side' ELSE 'session' END,
              CASE WHEN n>=99000 THEN 'other-workspace' ELSE 'workspace' END,
              'turn-'||(n%100),'turn',CASE WHEN n%2=0 THEN 'openai-responses' ELSE 'anthropic-messages' END,
              'fixture-router','fixture-model','completed',1995,1995,X'7b7d',
              1,CASE WHEN n%10=0 THEN NULL ELSE 100 END,10,20,30,'reported',
              CASE n%4 WHEN 0 THEN NULL WHEN 1 THEN 0 WHEN 2 THEN 0.125 ELSE 0.25 END,
              CASE WHEN n%4=0 THEN 'unreported' ELSE 'reported' END,
              CASE n%5 WHEN 0 THEN 'hit' WHEN 1 THEN 'miss' WHEN 2 THEN 'unreported' WHEN 3 THEN 'invalid' ELSE 'conflict' END,
              CASE WHEN n%2=0 THEN 8 ELSE NULL END,CASE WHEN n%3=0 THEN 2 ELSE NULL END
            FROM sequence
            """)
            // Each answer has its originating request plus later context links.
            // A separate shared tool row has 100 origins and 100,000 input links;
            // the latter must never multiply its cost or dominate the origin query.
            try db.execute("""
            INSERT INTO message_links(attempt,message,role)
            SELECT id,'answer-'||(CAST(substr(id,25) AS INTEGER)%100),'output' FROM attempts
            """)
            try db.execute("""
            INSERT INTO message_links(attempt,message,role)
            SELECT id,'answer-'||((CAST(substr(id,25) AS INTEGER)+1)%100),'input' FROM attempts
            """)
            try db.execute("INSERT INTO message_links(attempt,message,role) SELECT id,'tool-shared','input' FROM attempts")
            try db.execute("""
            INSERT INTO message_links(attempt,message,role)
            SELECT id,'tool-shared','output' FROM attempts WHERE CAST(substr(id,25) AS INTEGER)<100
            """)
        }
        XCTAssertEqual(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE metrics_retained=1").first?["n"]?.number, Int64(recordCount))
        XCTAssertEqual(try db.rows("SELECT COUNT(*) AS n FROM message_links").first?["n"]?.number, 300_100)
    }

    /// Expected values are computed from the synthetic record specification, not
    /// by reusing the production SQL, gateway projection or aggregation helpers.
    private func add(_ n: Int, to total: inout GatewayTotals) {
        total.requests += 1
        // This fixture never reports input usage, so none of its cache counts
        // can form a paired input-minus-cache observation.
        total.uncachedInputSamples = 0
        // Each record carries a decode span, but none reports output tokens,
        // so no request can contribute to the settled rate. First-token
        // latency is recorded by every one of them.
        total.decodeSamples = 0
        total.ttftSamples = (total.ttftSamples ?? 0) + 1
        total.ttftMilliseconds = (total.ttftMilliseconds ?? 0) + 10
        if n % 4 != 0 {
            total.costSamples += 1
            let amount = n % 4 == 1 ? 0.0 : n % 4 == 2 ? 0.125 : 0.25
            total.costUSD = (total.costUSD ?? 0) + amount
        }
        switch n % 5 {
        case 0: total.cacheHits += 1
        case 1: total.cacheMisses += 1
        case 2: total.cacheUnreported += 1
        default: total.cacheConflicts += 1
        }
        if n % 2 == 0 { total.cacheReadSamples += 1; total.cacheReadTokens = (total.cacheReadTokens ?? 0) + 8 }
        if n % 3 == 0 { total.cacheWriteSamples += 1; total.cacheWriteTokens = (total.cacheWriteTokens ?? 0) + 2 }
    }

    func testHundredThousandRetainedAttemptsAndFullVisiblePagePreserveAttributionAndCoverage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await initial.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await initial.close()
        try seed(root)
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let messages = (0..<50).map { TranscriptMessage(id: "turn-\($0)", role: "user", text: "Synthetic user turn") }
            + (0..<50).map { TranscriptMessage(id: "answer-\($0)", role: "assistant", text: "Synthetic answer") }
            + [TranscriptMessage(id: "tool-shared", role: "tool", text: "Synthetic tool result")]
        XCTAssertEqual(messages.count, 101)

        var expectedSession = GatewayTotals(), expectedMessages: [String: GatewayTotals] = [:]
        for n in 0..<recordCount where n % 10 != 0 {
            if n < 90_000 {
                add(n, to: &expectedSession)
            }
            if n < 99_000, n % 100 < 50 { add(n, to: &expectedMessages["answer-\(n % 100)", default: GatewayTotals()]) }
        }
        // Every dispatched origin in the fixture reports the same resolved
        // model. Derive its coverage from the independently counted origins,
        // including inherited side output, without reusing production SQL.
        // Turns are `turn-(n%100)`: the session's dispatched records cover 90
        // of them, and each answer owns exactly one.
        expectedSession.turnCount = 90
        for message in Array(expectedMessages.keys) {
            expectedMessages[message]?.turnCount = 1
            let count = expectedMessages[message]!.requests
            expectedMessages[message]?.models = GatewayModelSummary(
                names: ["fixture-model"], nameCount: 1, reportedRequests: count,
                unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0, displayRequests: count,
                routes: [GatewayModelRoute(requested: "fixture-router", responded: "fixture-model", latestWall: 1995)])
        }

        let pageStart = ProcessInfo.processInfo.systemUptime
        let page = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: messages)
        let pageMS = (ProcessInfo.processInfo.systemUptime - pageStart) * 1000
        // The latest retained wall time rides along for the sidebar's recency stamp; the totals themselves are unchanged.
        XCTAssertEqual(page.session.lastActivity, 1_995)
        var comparableSession = page.session; comparableSession.lastActivity = nil
        XCTAssertEqual(comparableSession, expectedSession)
        XCTAssertTrue(page.messages.values.allSatisfy { $0.lastActivity != nil })
        XCTAssertEqual(page.messages.mapValues { var totals = $0; totals.lastActivity = nil; return totals }, expectedMessages)
        XCTAssertEqual(page.session.requests, 81_000, "Prepared requests and foreign session/workspace rows are excluded")
        XCTAssertEqual(page.session.costSamples, 63_000)
        XCTAssertEqual(page.session.costUSD, 7_875)
        XCTAssertNil(page.messages["turn-1"], "Linked assistants own completed requests")
        XCTAssertEqual(page.messages["answer-1"]?.requests, 990, "An inherited origin may appear without charging the side session to the main total")
        XCTAssertEqual(page.messages["answer-1"]?.models?.reportedRequests, 990, "Resolved-model coverage counts each attributed request once")
        XCTAssertEqual(page.messages["answer-1"]?.models?.names, ["fixture-model"], "Returned names remain separate from requested aliases")
        XCTAssertEqual(page.messages["answer-1"]?.models?.routes?.first?.label, "fixture-router → fixture-model")
        XCTAssertNil(page.session.models, "Per-message model attribution must not be copied into session totals")
        XCTAssertEqual(page.messages["answer-1"]?.costUSD, 0, "An explicit zero remains a reported sample")
        XCTAssertNil(page.messages["answer-4"]?.costUSD, "Unknown cost remains nil at scale")
        XCTAssertNil(page.messages["tool-shared"], "Tool rows do not duplicate inline usage")
        XCTAssertNil(page.messages["turn-0"], "Undispatched requests do not create a charged message")

        let sessionStart = ProcessInfo.processInfo.systemUptime
        let sessionOnly = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        let sessionMS = (ProcessInfo.processInfo.systemUptime - sessionStart) * 1000
        XCTAssertEqual(sessionOnly.session, page.session); XCTAssertTrue(sessionOnly.messages.isEmpty)
        let singleStart = ProcessInfo.processInfo.systemUptime
        let single = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [messages[50]])
        let singleMS = (ProcessInfo.processInfo.systemUptime - singleStart) * 1000
        XCTAssertEqual(single.session, page.session)
        XCTAssertEqual(single.messages, [:], "An assistant origin with no dispatched attempts remains absent")

        // Report real machine latency as evidence; do not encode a flaky CI wall-
        // clock threshold or confuse these query timings with input-to-paint time.
        print(String(format: "ACCOUNTING_SCALE retained=100000 links=300100 visible=101 page_ms=%.3f session_only_ms=%.3f single_message_ms=%.3f", pageMS, sessionMS, singleMS))
        try await archive.close()
    }
}
