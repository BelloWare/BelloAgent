import XCTest
@testable import PiAgentCore

/// A model client that reports what each attempt cost the way the gateway
/// telemetry does: the attempt's final observation, sent before its request
/// returns or throws, carries `gateway.cost` and an ended `outcome`. A nil
/// cost is an attempt whose gateway reported none.
private actor BillingClient: ModelClient {
    enum Step { case reply(ModelReply, cost: Double?), fail(AgentError, cost: Double?) }
    private var turns: [Step], summaries: [Step]
    private(set) var purposes: [String] = []
    /// Turn request numbers (1-based) that wait for `release()` before answering.
    private var holds: Set<Int>
    private(set) var holding = false
    private var turnCount = 0, held: Int?
    init(turns: [Step], summaries: [Step] = [], hold: Set<Int> = []) { self.turns = turns; self.summaries = summaries; self.holds = hold }
    var requests: Int { purposes.count }
    var turnRequests: Int { purposes.filter { $0 == "turn" }.count }
    var summaryRequests: Int { purposes.filter { $0 == "compaction" }.count }
    /// Lets the held request answer; later holds still hold.
    func release() { if let held { holds.remove(held) } }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile: profile, apiKey: apiKey, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, turnID: turnID, purpose: purpose, onObservation: { _ in }, onDelta: onDelta)
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        purposes.append(purpose)
        let step: Step
        if purpose == "compaction" {
            guard !summaries.isEmpty else { throw AgentError("fixture_exhausted", "Unexpected summary request") }
            step = summaries.removeFirst()
        } else {
            turnCount += 1
            let number = turnCount
            while holds.contains(number) { held = number; holding = true; try await Task.sleep(nanoseconds: 2_000_000) }
            holding = false; held = nil
            guard !turns.isEmpty else { throw AgentError("fixture_exhausted", "Unexpected model request") }
            step = turns.removeFirst()
        }
        let attempt = UUID().uuidString
        var observation = RequestObservation(sessionID: sessionID, turnID: turnID, attemptID: attempt, purpose: purpose, fingerprint: "fixture", profile: profile)
        func report(_ cost: Double?, outcome: String) async {
            observation.phase = outcome == "completed" ? "final" : "interrupted"
            observation.monitoring = ["gateway": ["version": 1, "cost": ["status": cost == nil ? "unreported" : "reported", "usd": cost.map { JSON($0) } ?? .null]],
                                      "outcome": JSON(outcome)]
            await onObservation(observation)
        }
        switch step {
        case .reply(var reply, let cost):
            try await onDelta(.text(reply.message.text))
            reply.message.requestAttemptIDs = [attempt]
            await report(cost, outcome: "completed")
            return reply
        case .fail(let error, let cost):
            await report(cost, outcome: "failed")
            throw AgentError(error.code, error.message, failure: error.failure, attemptID: attempt)
        }
    }
}

/// Every call writes a large result, so a context rejection finds history to summarize.
private actor EvidenceTools: ToolExecuting {
    private(set) var count = 0
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("write", "Append once", ["type": "object", "properties": ["value": ["type": "integer"]]])] }
    func invoke(_ call: ToolCall, readOnly: Bool) -> JSON { count += 1; return resultText("APPENDED ONCE\n" + String(repeating: "observed evidence ", count: 1500)) }
}

final class CostLimitTests: XCTestCase {
    /// A one-token recent tail, so any history is something to summarize.
    private static let smallTail: CompactionPolicy = { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }()
    private func session(_ root: URL, id: String = UUID().uuidString, client: any ModelClient, tools: any ToolExecuting = RecordingTools(), limit: Double?, resume: String? = nil, policy: CompactionPolicy = CompactionPolicy()) async throws -> AgentSession {
        let session = try AgentSession(id: id, profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false,
                                       resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), resumePath: resume, compactionPolicy: policy)
        await session.setCostLimit(limit)
        return session
    }
    private func send(_ session: AgentSession, _ text: String, turn: String = UUID().uuidString) async throws {
        _ = try await session.submit(Submission(commandID: turn, turnID: turn, text: text), steer: false)
    }
    private func settled(_ session: AgentSession) async throws -> JSON {
        try await eventually { !(await session.isRunning) }
        return await session.snapshot()
    }
    private func assertSpend(_ state: JSON, usd: Double, reported: Int, unreported: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state["cost"]["spentUSD"].double ?? -1, usd, accuracy: 1e-9, "spent", file: file, line: line)
        XCTAssertEqual(state["cost"]["reportedRequests"].int, reported, "reported attempts", file: file, line: line)
        XCTAssertEqual(state["cost"]["unreportedRequests"].int, unreported, "unreported attempts", file: file, line: line)
    }

    /// Two tool rounds cost 6 cents against a 5-cent limit: the second
    /// request was sent below the limit and its tool ran, and the third —
    /// the answer — never goes. A follow-up queued behind the run stays queued.
    func testRunStopsBeforeTheNextRequestOnceSpendReachesTheLimit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.03), .reply(toolReply(["second"]), cost: 0.03), .reply(answer("Done"), cost: 0.01)], hold: [2])
        let tools = RecordingTools()
        let s = try await session(root, client: client, tools: tools, limit: 0.05)
        try await send(s, "Work through it")
        try await eventually { await client.holding }
        try await send(s, "And then this")
        await client.release()
        let state = try await settled(s)
        let turnRequests = await client.turnRequests, ran = await tools.calls
        XCTAssertEqual(turnRequests, 2, "The request after the limit was reached must not be sent")
        XCTAssertEqual(ran, ["first", "second"], "The request in flight when the limit was reached is never cut; its tool runs")
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "cost_limit")
        XCTAssertEqual(state["preflightError"].text, "This chat reached its $0.05 cost limit ($0.06 spent). Raise the limit to continue.")
        XCTAssertEqual(state["cost"]["limitUSD"].double, 0.05); XCTAssertEqual(state["cost"]["reached"].flag, true)
        assertSpend(state, usd: 0.06, reported: 2, unreported: 0)
        XCTAssertEqual(state["queueCount"].int, 1, "The follow-up stays queued"); XCTAssertEqual(state["queuePaused"].flag, true)
        // Sending again is refused where it was typed, with the same words.
        do { try await send(s, "One more"); XCTFail("A chat at its limit must refuse a new message") }
        catch let error as AgentError { XCTAssertEqual(error.code, "cost_limit"); XCTAssertEqual(error.message, state["preflightError"].text) }
        await s.close()
    }

    /// No limit, or a limit removed, never stops a run however much it spends.
    func testNoLimitNeverStops() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for removed in [false, true] {
            let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 40), .reply(toolReply(["second"]), cost: 40), .reply(answer("Done"), cost: 40)])
            let s = try await session(root, client: client, limit: removed ? 0.01 : nil)
            if removed { await s.setCostLimit(nil) }
            try await send(s, "Spend freely")
            let state = try await settled(s)
            let requests = await client.turnRequests
            XCTAssertEqual(requests, 3); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
            XCTAssertTrue(state["errorCode"].isNull); XCTAssertTrue(state["cost"]["limitUSD"].isNull); XCTAssertEqual(state["cost"]["reached"].flag, false)
            assertSpend(state, usd: 120, reported: 3, unreported: 0)
            try await send(s, "And more")
            await s.close()
        }
    }

    /// A limit changed while a request is in flight is the one the next
    /// request is checked against: lowered, the run stops there; raised
    /// after a stop, the stopped turn continues where it stopped.
    func testRaisingTheLimitMidSessionContinues() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.02), .reply(toolReply(["second"]), cost: 0.02), .reply(answer("Done"), cost: 0.02)], hold: [1, 2])
        let tools = RecordingTools()
        let s = try await session(root, client: client, tools: tools, limit: 1)
        try await send(s, "Work")
        try await eventually { await client.holding }
        // Lowered below what the request in flight will cost: that request
        // still completes, and the run stops before the next one.
        await s.setCostLimit(0.01)
        await client.release()
        var state = try await settled(s)
        var requests = await client.turnRequests
        XCTAssertEqual(requests, 1); XCTAssertEqual(state["errorCode"].text, "cost_limit")
        XCTAssertEqual(state["preflightError"].text, "This chat reached its $0.01 cost limit ($0.02 spent). Raise the limit to continue.")
        // Raised: the stopped turn continues from where it stopped, with no restart.
        await s.setCostLimit(0.03)
        state = await s.snapshot()
        XCTAssertEqual(state["cost"]["reached"].flag, false); XCTAssertEqual(state["cost"]["limitUSD"].double, 0.03)
        try await s.retryRun()
        try await eventually { await client.holding }
        // Raised again while the second request is in flight: the third goes.
        await s.setCostLimit(1)
        await client.release()
        state = try await settled(s)
        requests = await client.turnRequests
        let ran = await tools.calls
        XCTAssertEqual(requests, 3); XCTAssertEqual(ran, ["first", "second"])
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded()); XCTAssertTrue(state["errorCode"].isNull)
        assertSpend(state, usd: 0.06, reported: 3, unreported: 0)
        await s.close()
    }

    /// Context recovery and compaction summaries are model requests of the
    /// chat: their cost counts, and at the limit they are not sent either.
    func testCompactionAndRecoveryRequestsCountAndAreStopped() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let rejected = AgentError("provider_http", "HTTP 400 rejected input", failure: .inputContextExceeded)
        // Below the limit: the rejected attempt, the recovery summary and the
        // retried request all count, whatever each one's purpose.
        do {
            let client = BillingClient(turns: [.reply(toolReply(["write"]), cost: 0.04), .fail(rejected, cost: 0.01), .reply(answer("Done without repeated writes"), cost: 0.02)],
                                       summaries: [.reply(answer("Counter append completed once. Continue without rerunning tools."), cost: 0.005)])
            let s = try await session(root, client: client, tools: EvidenceTools(), limit: 1, policy: Self.smallTail)
            try await send(s, "Append the counter once")
            let state = try await settled(s)
            let summaries = await client.summaryRequests
            XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded()); XCTAssertEqual(summaries, 1)
            XCTAssertEqual(state["compaction"]["recovery"]["consumed"].flag, true)
            assertSpend(state, usd: 0.075, reported: 4, unreported: 0)
            await s.close()
        }
        // At the limit: the rejected request's own cost reaches it, and the
        // recovery's summary request is never sent.
        do {
            let client = BillingClient(turns: [.reply(toolReply(["write"]), cost: 0.04), .fail(rejected, cost: 0.02)],
                                       summaries: [.reply(answer("Should not be requested"), cost: 0.005)])
            let tools = EvidenceTools()
            let s = try await session(root, client: client, tools: tools, limit: 0.05, policy: Self.smallTail)
            try await send(s, "Append the counter once")
            var state = try await settled(s)
            var summaries = await client.summaryRequests
            let writes = await tools.count
            XCTAssertEqual(summaries, 0, "A recovery summary is a model request and must not go at the limit")
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "cost_limit")
            XCTAssertEqual(state["compaction"]["phase"].text, "failed"); XCTAssertEqual(state["compaction"]["errorCode"].text, "cost_limit")
            assertSpend(state, usd: 0.06, reported: 2, unreported: 0)
            // A manual compaction at the limit stops before its summary request too.
            try await s.compact()
            state = try await settled(s)
            summaries = await client.summaryRequests
            XCTAssertEqual(summaries, 0); XCTAssertEqual(state["errorCode"].text, "cost_limit")
            // Raised, a stop with nothing left to continue ends on Resume.
            await s.setCostLimit(1)
            try await s.resumeQueue()
            state = await s.snapshot()
            XCTAssertEqual(state["state"].text, "idle"); XCTAssertTrue(state["errorCode"].isNull); XCTAssertTrue(state["preflightError"].isNull)
            await s.close()
        }
    }

    /// What a chat spent is in its journal: a reopened chat — a restarted
    /// helper — is checked against the same spend, attempt for attempt.
    func testSpendSurvivesReopen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = "reopened"
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.02), .reply(answer("Done"), cost: nil)])
        let s = try await session(root, id: id, client: client, limit: nil)
        try await send(s, "Work")
        let before = try await settled(s)
        assertSpend(before, usd: 0.02, reported: 1, unreported: 1)
        let held = await s.path
        let path = try XCTUnwrap(held)
        await s.close()
        let fresh = BillingClient(turns: [.reply(answer("Should not be sent"), cost: 0.01)])
        let reopened = try await session(root, id: id, client: fresh, limit: 0.02, resume: path)
        var state = await reopened.snapshot()
        assertSpend(state, usd: 0.02, reported: 1, unreported: 1)
        XCTAssertEqual(state["cost"]["reached"].flag, true)
        do { try await send(reopened, "Continue"); XCTFail("The reopened chat is at its limit") }
        catch let error as AgentError { XCTAssertEqual(error.code, "cost_limit") }
        let sent = await fresh.requests
        XCTAssertEqual(sent, 0)
        // The app's figure for a chat's earlier spend is taken only by a
        // journal that has never recorded costs; this one has.
        await reopened.adoptSpendSeed(SessionSpend(usd: 5, reported: 9, unreported: 0))
        state = await reopened.snapshot()
        assertSpend(state, usd: 0.02, reported: 1, unreported: 1)
        await reopened.close()
    }

    /// A chat written before cost records existed takes the spend the app's
    /// request log holds for it, once; reopened again, it is not added twice.
    func testChatWithoutCostRecordsTakesTheAppsSpendOnce() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = "legacy"
        let s = try await session(root, id: id, client: BillingClient(turns: []), limit: nil)
        try await s.append(ChatMessage(role: "user", content: [textBlock("An earlier question")]))
        let held = await s.path
        let path = try XCTUnwrap(held)
        await s.close()
        for _ in 0..<2 {
            let reopened = try await session(root, id: id, client: BillingClient(turns: []), limit: 25, resume: path)
            await reopened.adoptSpendSeed(SessionSpend(usd: 30.5, reported: 12, unreported: 2))
            let state = await reopened.snapshot()
            assertSpend(state, usd: 30.5, reported: 12, unreported: 2)
            XCTAssertEqual(state["cost"]["reached"].flag, true)
            await reopened.close()
        }
    }

    /// An attempt whose gateway reported no cost is unknown: it is counted as
    /// one more unreported request, adds nothing to the spend, and cannot
    /// bring a chat to its limit.
    func testUnreportedAttemptsAreCountedAsUnknownNotZero() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: nil), .reply(toolReply(["second"]), cost: nil), .reply(answer("Done"), cost: 0.001)])
        let s = try await session(root, client: client, limit: 0.002)
        try await send(s, "Work")
        let state = try await settled(s)
        let requests = await client.turnRequests
        XCTAssertEqual(requests, 3, "Unreported attempts cannot reach a limit"); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        assertSpend(state, usd: 0.001, reported: 1, unreported: 2)
        // A zero the gateway reported is a reported zero, not an unknown.
        var observation = RequestObservation(sessionID: "x", turnID: "t", attemptID: "zero", purpose: "turn", fingerprint: "f", profile: try fixtureProfile())
        observation.monitoring = ["gateway": ["cost": ["status": "reported", "usd": 0]], "outcome": "completed"]
        await s.countAttempt(observation)
        // A conflicting or invalid report is no amount either.
        for status in ["conflict", "invalid"] {
            var other = RequestObservation(sessionID: "x", turnID: "t", attemptID: status, purpose: "turn", fingerprint: "f", profile: try fixtureProfile())
            other.monitoring = ["gateway": ["cost": ["status": JSON(status), "usd": .null]], "outcome": "completed"]
            await s.countAttempt(other)
        }
        // One attempt is counted once, however often its end is reported.
        await s.countAttempt(observation)
        let counted = await s.snapshot()
        assertSpend(counted, usd: 0.001, reported: 2, unreported: 4)
        await s.close()
    }

    /// The wire value: an object with a positive `usd`, or `usd: null` for
    /// none; anything else is refused before it changes anything.
    func testCostLimitWireValue() throws {
        XCTAssertTrue(try AgentSession.costLimit(.null) == nil)
        XCTAssertEqual(try AgentSession.costLimit(["usd": 25]), .some(25))
        XCTAssertEqual(try AgentSession.costLimit(["usd": .null]), .some(nil))
        for bad: JSON in [5, ["usd": 0], ["usd": -1], ["usd": "5"], ["usd": 2_000_000]] { XCTAssertThrowsError(try AgentSession.costLimit(bad)) }
        XCTAssertEqual(AgentSession.costText(5), "$5.00"); XCTAssertEqual(AgentSession.costText(5.123), "$5.12"); XCTAssertEqual(AgentSession.costText(0.00125), "$0.00125")
    }
}
