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
    /// While set, a summary request waits (until cancelled or released).
    private(set) var holdingSummary = false, summaryCancelled = 0, summaryThinking: [String?] = [], summaryTexts: [String] = []
    private var summaryHold = false
    func holdSummaries(_ on: Bool) { summaryHold = on }
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
            summaryThinking.append(profile.raw["thinkingLevel"].text); summaryTexts.append(messages.map(\.text).joined(separator: "\n"))
            do { while summaryHold { holdingSummary = true; try await Task.sleep(nanoseconds: 2_000_000) } }
            catch { holdingSummary = false; summaryCancelled += 1; throw error }
            holdingSummary = false
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

/// A tool that runs until released, then returns its real result.
private actor SlowTools: ToolExecuting {
    private(set) var started = 0, finished = 0, cancelled = 0
    private var released = false
    func release() { released = true }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first","test",[:]),ToolDefinition("second","test",[:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        started += 1
        do { while !released { try await Task.sleep(for: .milliseconds(2)) } } catch { cancelled += 1; throw error }
        finished += 1
        return resultText("REAL " + call.name)
    }
}

/// Definitions can be held once, as a call's own preparation reads them.
private actor GatedDefinitionsTools: ToolExecuting {
    private(set) var calls: [String] = [], waiting = false
    private var gate = false
    func close() { gate = true }
    func open() { gate = false }
    func definitions(readOnly: Bool) async -> [ToolDefinition] {
        while gate { waiting = true; try? await Task.sleep(nanoseconds: 2_000_000) }
        waiting = false
        return [ToolDefinition("first","test",[:])]
    }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON { calls.append(call.name); return resultText("done " + call.name) }
}

/// The first definitions read after `arm()` passes; the second waits until
/// `open()`. Invocations run until `release()`.
private actor OneGatedCallTools: ToolExecuting {
    private(set) var invoked: [String] = [], cancelled = 0, waiting = false
    private var armed = false, reads = 0, gate = true, released = false
    func arm() { armed = true }
    func open() { gate = false }
    func release() { released = true }
    func definitions(readOnly: Bool) async -> [ToolDefinition] {
        if armed { reads += 1; if reads == 2 { while gate { waiting = true; try? await Task.sleep(nanoseconds: 2_000_000) } } }
        return [ToolDefinition("first","test",[:]),ToolDefinition("second","test",[:])]
    }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        invoked.append(call.name)
        do { while !released { try await Task.sleep(nanoseconds: 2_000_000) } } catch { cancelled += 1; throw error }
        return resultText("done " + call.name)
    }
}

/// Records each call with how many turn requests its client had made.
private actor RequestCountingTools: ToolExecuting {
    let client: BillingClient
    private(set) var calls: [(name: String, requests: Int)] = []
    init(client: BillingClient) { self.client = client }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first","test",[:]),ToolDefinition("second","test",[:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON { calls.append((call.name, await client.turnRequests)); return resultText("done " + call.name) }
}

/// Every call writes a large result, so a context rejection finds history to summarize.
private actor EvidenceTools: ToolExecuting {
    private(set) var count = 0
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("write", "Append once", ["type": "object", "properties": ["value": ["type": "integer"]]])] }
    func invoke(_ call: ToolCall, readOnly: Bool) -> JSON { count += 1; return resultText("APPENDED ONCE\n" + String(repeating: "observed evidence ", count: 1500)) }
}

/// Watches a chat's run-state records and journal syncs: what a crash or
/// power loss at each point would leave.
private final class StateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var states: [JSON] = []
    /// Once armed: whether the first state record that no longer holds the
    /// calls was written, and whether a sync followed it yet.
    private(set) var releaseWritten = false, releaseSynced = false
    private var armed = false
    /// Once set: the journal is copied at the first sync after a run-state
    /// record of a Resume's run that no longer shows the pause.
    private var copy: (from: URL, to: URL)?, acceptedPending = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func copyAtAcceptedResume(from: URL, to: URL) { lock.lock(); copy = (from, to); lock.unlock() }
    func beforeAppend(_ record: JSON) {
        guard record["customType"].text == JournalRecordKind.state else { return }
        lock.lock(); defer { lock.unlock() }
        let data = record["data"]; states.append(data)
        if armed, !releaseWritten, data["costPendingCalls"].isNull { releaseWritten = true }
        if copy != nil, data["active"].flag == true, data["costPaused"].isNull { acceptedPending = true }
    }
    func beforeSynchronize() {
        lock.lock(); defer { lock.unlock() }
        if releaseWritten { releaseSynced = true }
        if acceptedPending, let copy { try? FileManager.default.copyItem(at: copy.from, to: copy.to); self.copy = nil; acceptedPending = false }
    }
}

final class CostLimitTests: XCTestCase {
    /// A one-token recent tail, so any history is something to summarize.
    private static let smallTail: CompactionPolicy = { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }()
    private func session(_ root: URL, id: String = UUID().uuidString, client: any ModelClient, tools: any ToolExecuting = RecordingTools(), limit: Double?, resume: String? = nil, policy: CompactionPolicy = CompactionPolicy(), probe: StateProbe? = nil) async throws -> AgentSession {
        let session = try AgentSession(id: id, profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false,
                                       resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), resumePath: resume, compactionPolicy: policy,
                                       beforeJournalAppend: { probe?.beforeAppend($0) }, beforeJournalSynchronize: { probe?.beforeSynchronize() })
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

    func testClosingCountsTheAdmittedRequestsFinalChargeBeforeDetachingTheJournal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = CancellationBillingClient()
        let s = try await session(root, id: "closing", client: client, limit: 1)
        try await send(s, "First")
        _ = try await settled(s)
        try await send(s, "Cancelled while closing")
        try await eventually { await client.requests == 2 }
        let path = await s.path
        await s.close()
        let reopened = try await session(root, id: "closing", client: ScriptClient([]), limit: 1, resume: path)
        // Once a journal tracks costs, an archive seed cannot repair an omitted charge.
        await reopened.adoptSpendSeed(SessionSpend(usd: 1.10, reported: 2))
        let state = await reopened.snapshot()
        assertSpend(state, usd: 1.10, reported: 2, unreported: 0)
        XCTAssertEqual(state["cost"]["reached"].flag, true)
        do { try await send(reopened, "Must not dispatch"); XCTFail("The closing request exhausted the limit") }
        catch let error as AgentError { XCTAssertEqual(error.code, "cost_limit") }
        await reopened.close()
    }

    /// Two tool rounds cost 6 cents against a 5-cent limit (owner,
    /// 2026-10-17: every chat pauses). The second reply crosses the limit: the
    /// chat pauses at once and that reply's tool call is held, not run. A
    /// follow-up queued behind the run stays queued. After a raise, Resume
    /// runs the held call first, from the same reply (no new request), then
    /// asks for the answer, then sends the follow-up.
    func testRunPausesWhenSpendReachesTheLimitAndHeldToolsRunFirstOnResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.03), .reply(toolReply(["second"]), cost: 0.03), .reply(answer("Done"), cost: 0.01), .reply(answer("Follow-up done"), cost: 0.01)], hold: [2])
        let tools = RequestCountingTools(client: client)
        let s = try await session(root, client: client, tools: tools, limit: 0.05)
        try await send(s, "Work through it")
        try await eventually { await client.holding }
        try await send(s, "And then this")
        await client.release()
        var state = try await settled(s)
        var turnRequests = await client.turnRequests, ran = await tools.calls
        XCTAssertEqual(turnRequests, 2, "The request after the limit was reached must not be sent")
        XCTAssertEqual(ran.map(\.name), ["first"], "The crossing reply's call is held, never run at the limit")
        XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(state["errorCode"].text, "cost_limit"); XCTAssertEqual(state["costPaused"].flag, true)
        XCTAssertEqual(state["preflightError"].text, "Paused at the cost limit: $0.06 spent of $0.05. Raise the limit above the spend, then choose Resume.")
        XCTAssertEqual(state["cost"]["limitUSD"].double, 0.05); XCTAssertEqual(state["cost"]["reached"].flag, true)
        assertSpend(state, usd: 0.06, reported: 2, unreported: 0)
        XCTAssertEqual(state["queueCount"].int, 1, "The follow-up stays queued"); XCTAssertEqual(state["queuePaused"].flag, true)
        do { try await send(s, "One more"); XCTFail("A chat at its limit must refuse a new message") }
        catch let error as AgentError { XCTAssertEqual(error.code, "cost_limit") }
        do { try await s.requireCostResumeRoom(); XCTFail("Resume at the limit") } catch { XCTAssertEqual((error as? AgentError)?.code, "cost_limit") }
        await s.setCostLimit(1)
        let still = await s.snapshot(); XCTAssertEqual(still["costPaused"].flag, true, "Raising alone resumes nothing")
        try await s.requireCostResumeRoom()
        _ = try await s.continueRun(commandID: "resume")
        state = try await settled(s)
        turnRequests = await client.turnRequests; ran = await tools.calls
        XCTAssertEqual(ran.map(\.name), ["first", "second"])
        XCTAssertEqual(ran.last?.requests, 2, "The held call ran before any new model request")
        XCTAssertEqual(turnRequests, 4); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        let users = await s.history.filter { $0.role == "user" }.map(\.text)
        XCTAssertEqual(users.last, "And then this")
        await s.close()
    }

    /// Owner, 2026-10-17: a tool already running when the chat reaches its
    /// limit is not cut. It finishes with its real result; then no request
    /// goes, and the chat is paused. Quit while it still runs: the quit
    /// interrupts it as Stop does, and the reopened chat is still paused.
    func testARunningToolSurvivesThePauseAndARelaunchKeepsThePause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for quitEarly in [false, true] {
            let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.02), .reply(answer("Done"), cost: 0.01)])
            let tools = SlowTools()
            let s = try await session(root, client: client, tools: tools, limit: 1)
            try await send(s, "Work")
            try await eventually { await tools.started == 1 }
            await s.setCostLimit(0.01)   // already spent 0.02: the chat pauses now
            try await eventually { await s.snapshot()["costPaused"].flag == true }
            let running = await s.isRunning; XCTAssertTrue(running, "The tool is still running")
            var path = await s.path
            if quitEarly {
                await s.close()
            } else {
                await tools.release()
                let state = try await settled(s)
                let finished = await tools.finished, cut = await tools.cancelled, requests = await client.turnRequests
                XCTAssertEqual(finished, 1); XCTAssertEqual(cut, 0); XCTAssertEqual(requests, 1, "No request after the tool")
                XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(state["costPaused"].flag, true)
                let kept = await s.history.contains { $0.role == "toolResult" && $0.text == "REAL first" }
                XCTAssertTrue(kept, "Its real result is kept")
                path = await s.path; await s.close()
            }
            let sessionID = await s.id
            let reopened = try await session(root, id: sessionID, client: client, tools: tools, limit: 0.01, resume: path)
            let state = await reopened.snapshot()
            XCTAssertEqual(state["costPaused"].flag, true, "Still paused after the relaunch"); XCTAssertEqual(state["state"].text, "paused")
            let result = await reopened.history.last { $0.role == "toolResult" }?.text ?? ""
            XCTAssertTrue(quitEarly ? result.contains("interrupted") || result.contains("Interrupted") : result == "REAL first", result)
            await reopened.setCostLimit(1)
            _ = try await reopened.continueRun(commandID: "resume")
            let resumed = try await settled(reopened)
            XCTAssertEqual(resumed["state"].text, "idle", resumed["preflightError"].encoded())
            let requests = await client.turnRequests; XCTAssertEqual(requests, 2, "Resume asks once; the tool is not run again")
            await reopened.close()
        }
    }

    /// Calls the pause held before they started stay pending across a
    /// relaunch (no invented outcome) and run on Resume before any request.
    func testHeldToolCallsSurviveARelaunchAndRunFirstOnResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.06), .reply(answer("Done"), cost: 0.01)])
        let tools = RequestCountingTools(client: client)
        let s = try await session(root, id: "held", client: client, tools: tools, limit: 0.05)
        try await send(s, "Work")
        let state = try await settled(s)
        XCTAssertEqual(state["costPaused"].flag, true)
        let path = await s.path; await s.close()
        let reopened = try await session(root, id: "held", client: client, tools: tools, limit: 0.05, resume: path)
        let pending = await reopened.history.filter { $0.role == "toolResult" }
        XCTAssertTrue(pending.isEmpty, "A held call gets no invented outcome")
        await reopened.setCostLimit(1)
        _ = try await reopened.continueRun(commandID: "resume")
        let done = try await settled(reopened)
        let ran = await tools.calls, requests = await client.turnRequests
        XCTAssertEqual(ran.map(\.name), ["first"]); XCTAssertEqual(ran.first?.requests, 1, "Ran before any new request")
        XCTAssertEqual(requests, 2); XCTAssertEqual(done["state"].text, "idle", done["preflightError"].encoded())
        await reopened.close()
    }

    /// Round 9: a held call's card says it is held (`queued`), live and after
    /// a reopen, never running or run.
    func testAHeldCallsCardShowsItHeldAcrossAReopen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.06)])
        let s = try await session(root, id: "card", client: client, tools: RecordingTools(), limit: 0.05)
        try await send(s, "Work")
        _ = try await settled(s)
        let saved = await s.path, path = try XCTUnwrap(saved); await s.close()
        let reopened = try await session(root, id: "card", client: client, tools: RecordingTools(), limit: 0.05, resume: path)
        let last = await reopened.history.last { $0.role == "assistant" }, reply = try XCTUnwrap(last)
        let row = await reopened.displayMessage(reply)
        XCTAssertEqual(row["tools"].list.first?["state"].text, "queued")
        await reopened.close()
    }

    /// Owner, 2026-10-17 (round 2): a compaction summary in flight is a model
    /// request too. The pause cuts it; it is not recorded as a failure of the
    /// context; Resume compacts again and completes.
    func testThePauseCutsACompactionSummaryAndResumeCompactsAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["write"]), cost: 0.02), .reply(answer("Done"), cost: 0.01)],
                                   summaries: [.reply(answer("Summary of the retained history."), cost: 0.005)])
        let s = try await session(root, client: client, tools: EvidenceTools(), limit: 1, policy: Self.smallTail)
        try await send(s, "Append once")
        _ = try await settled(s)
        await client.holdSummaries(true)
        try await s.compact()
        try await eventually { await client.holdingSummary }
        await s.setCostLimit(0.01)
        var state = try await settled(s)
        let cut = await client.summaryCancelled
        XCTAssertEqual(cut, 1, "The summary request in flight is cut at once")
        XCTAssertEqual(state["costPaused"].flag, true); XCTAssertEqual(state["state"].text, "paused")
        XCTAssertNotEqual(state["compaction"]["phase"].text, "completed")
        let saved = await s.path, path = try XCTUnwrap(saved)
        let journal = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(journal.contains(JournalRecordKind.compactionFailure), "A cut summary is not a failed compaction of this context")
        await client.holdSummaries(false); await s.setCostLimit(1)
        let reply = try await s.continueRun(commandID: "resume", overrides: ["thinkingLevel": "high"])
        XCTAssertEqual(reply["compacting"].flag, true)
        state = try await settled(s)
        let summaries = await client.summaryRequests, thinking = await client.summaryThinking
        XCTAssertEqual(thinking.last ?? nil, "high", "The redone summary uses the Resume's choices")
        XCTAssertEqual(summaries, 2, "Resume compacted again")
        XCTAssertEqual(state["compaction"]["phase"].text, "completed"); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        await s.close()
    }

    /// Round 2: Resume records that a held call is no longer held before it
    /// runs, so a crash during it leaves an unknown outcome, never a replay.
    func testResumedHeldCallIsDurablyConsumedBeforeItRuns() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.06), .reply(answer("Done"), cost: 0.01)])
        let tools = SlowTools()
        let s = try await session(root, client: client, tools: tools, limit: 0.05)
        try await send(s, "Work")
        _ = try await settled(s)
        await s.setCostLimit(1)
        _ = try await s.continueRun(commandID: "resume")
        try await eventually { await tools.started == 1 }
        let saved = await s.path, path = try XCTUnwrap(saved)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let lastState = try XCTUnwrap(lines.last { $0.contains("pi-app.native.state.v1") })
        XCTAssertFalse(lastState.contains("costPendingCalls"), "Saved before the tool began: no longer held")
        await tools.release()
        _ = try await settled(s)
        await s.close()
    }

    /// Round 4 (P1): the record that the held calls are no longer held is
    /// forced to disk before any of them begins. A power loss during the
    /// tool then leaves an unknown outcome, never a held call to run again.
    func testHeldCallReleaseIsSyncedBeforeTheToolBegins() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.06), .reply(answer("Done"), cost: 0.01)])
        let tools = SlowTools(), probe = StateProbe()
        let s = try await session(root, client: client, tools: tools, limit: 0.05, probe: probe)
        try await send(s, "Work")
        _ = try await settled(s)
        await s.setCostLimit(1)
        probe.arm()
        _ = try await s.continueRun(commandID: "resume")
        try await eventually { await tools.started == 1 }
        XCTAssertTrue(probe.releaseWritten)
        XCTAssertTrue(probe.releaseSynced, "The release is on stable storage before the tool begins")
        await tools.release()
        _ = try await settled(s)
        await s.close()
    }

    /// Round 4: an accepted Resume keeps the pause on disk until its run has
    /// taken the paused work. The helper then ends after that (the pause is
    /// over on disk) but before the run took the held calls. The reopened
    /// chat still offers Resume, a message sent meanwhile waits behind the
    /// calls, and Resume runs them first, before any model request.
    func testHeldCallsLeftByAnAcceptedResumeKeepResumeAndGoBeforeASend() async throws {
        let root = try temporaryDirectory(), copyRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: copyRoot) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.06), .reply(answer("Done"), cost: 0.01)])
        let probe = StateProbe()
        let s = try await session(root, id: "held", client: client, tools: RecordingTools(), limit: 0.05, probe: probe)
        try await send(s, "Work")
        _ = try await settled(s)
        await s.setCostLimit(1)
        let saved = await s.path, path = try XCTUnwrap(saved)
        try FileManager.default.createDirectory(at: copyRoot.appendingPathComponent("state"), withIntermediateDirectories: true)
        let crash = copyRoot.appendingPathComponent("state").appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        probe.copyAtAcceptedResume(from: URL(fileURLWithPath: path), to: crash)
        _ = try await s.continueRun(commandID: "resume")
        _ = try await settled(s); await s.close()
        let accepted = try XCTUnwrap(probe.states.first { $0["commands"].list.contains { $0["turnId"].text == "continue:resume" } })
        XCTAssertEqual(accepted["costPaused"].flag, true, "Accepted, not yet taken: still paused on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: crash.path), "The run's record was copied")
        let after = BillingClient(turns: [.reply(answer("Done"), cost: 0.01), .reply(answer("Later done"), cost: 0.01)])
        let tools = RequestCountingTools(client: after)
        let reopened = try await session(copyRoot, id: "held", client: after, tools: tools, limit: 1, resume: crash.path)
        var state = await reopened.snapshot()
        XCTAssertNotEqual(state["costPaused"].flag, true, "The pause was over on disk")
        XCTAssertEqual(state["continuable"].flag, true, "Held calls keep their Resume")
        let sent = try await reopened.submit(Submission(commandID: "later", turnID: "later", text: "Later"), steer: false)
        XCTAssertEqual(sent["delivery"].text, "after-resume", "A message waits behind the held calls")
        var ran = await tools.calls, requests = await after.turnRequests
        XCTAssertTrue(ran.isEmpty); XCTAssertEqual(requests, 0)
        _ = try await reopened.continueRun(commandID: "resume-again")
        state = try await settled(reopened)
        ran = await tools.calls; requests = await after.turnRequests
        XCTAssertEqual(ran.map(\.name), ["first"]); XCTAssertEqual(ran.first?.requests, 0, "Ran before any model request")
        let users = await reopened.history.filter { $0.role == "user" }.map(\.text)
        XCTAssertEqual(users.last, "Later"); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        await reopened.close()
    }

    /// Round 4: the manual compaction a pause cuts is pending in the same
    /// record as the pause, so no crash between them can lose it; its
    /// `/compact <instructions>` focus is kept with it, also across a
    /// reopen, and the redone summary request carries it.
    func testACutCompactionIsSavedWithThePauseAndKeepsItsFocusAcrossAReopen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["write"]), cost: 0.02), .reply(answer("Done"), cost: 0.01)],
                                   summaries: [.reply(answer("Summary of the retained history."), cost: 0.005)])
        let probe = StateProbe()
        let s = try await session(root, id: "focus", client: client, tools: EvidenceTools(), limit: 1, policy: Self.smallTail, probe: probe)
        try await send(s, "Append once")
        _ = try await settled(s)
        await client.holdSummaries(true)
        try await s.compact(focus: "KEEP-THE-API-NOTES")
        try await eventually { await client.holdingSummary }
        await s.setCostLimit(0.01)
        _ = try await settled(s)
        let pause = try XCTUnwrap(probe.states.first { $0["costPaused"].flag == true })
        XCTAssertEqual(pause["costPendingCompaction"].flag, true, "Pending in the pause's own record")
        XCTAssertEqual(pause["costPendingCompactionFocus"].text, "KEEP-THE-API-NOTES")
        let saved = await s.path, path = try XCTUnwrap(saved); await s.close()
        await client.holdSummaries(false)
        let reopened = try await session(root, id: "focus", client: client, tools: EvidenceTools(), limit: 1, resume: path, policy: Self.smallTail)
        let reply = try await reopened.continueRun(commandID: "resume")
        XCTAssertEqual(reply["compacting"].flag, true)
        let state = try await settled(reopened)
        let texts = await client.summaryTexts
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts.last?.contains("KEEP-THE-API-NOTES") == true, "The redone summary keeps the focus")
        XCTAssertEqual(state["compaction"]["phase"].text, "completed"); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        await reopened.close()
    }

    /// Round 4 sibling: a compaction the pause cut is work of its own. Left
    /// by a helper that ended once the Resume's run had ended the pause on
    /// disk, it keeps Resume, holds a message sent meanwhile, and runs.
    func testACutCompactionLeftAfterThePauseEndedKeepsResume() async throws {
        let root = try temporaryDirectory(), copyRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: copyRoot) }
        let client = BillingClient(turns: [.reply(toolReply(["write"]), cost: 0.02), .reply(answer("Done"), cost: 0.01), .reply(answer("Later done"), cost: 0.01)],
                                   summaries: [.reply(answer("Summary of the retained history."), cost: 0.005), .reply(answer("Summary again."), cost: 0.005)])
        let probe = StateProbe()
        let s = try await session(root, id: "cut", client: client, tools: EvidenceTools(), limit: 1, policy: Self.smallTail, probe: probe)
        try await send(s, "Append once")
        _ = try await settled(s)
        await client.holdSummaries(true)
        try await s.compact()
        try await eventually { await client.holdingSummary }
        await s.setCostLimit(0.01)
        _ = try await settled(s)
        await s.setCostLimit(1)
        let saved = await s.path, path = try XCTUnwrap(saved)
        try FileManager.default.createDirectory(at: copyRoot.appendingPathComponent("state"), withIntermediateDirectories: true)
        let crash = copyRoot.appendingPathComponent("state").appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        probe.copyAtAcceptedResume(from: URL(fileURLWithPath: path), to: crash)
        await client.holdSummaries(false)
        _ = try await s.continueRun(commandID: "resume")
        _ = try await settled(s); await s.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: crash.path))
        let reopened = try await session(copyRoot, id: "cut", client: client, tools: EvidenceTools(), limit: 1, resume: crash.path, policy: Self.smallTail)
        var state = await reopened.snapshot()
        XCTAssertNotEqual(state["costPaused"].flag, true); XCTAssertEqual(state["continuable"].flag, true, "The cut compaction keeps Resume")
        let sent = try await reopened.submit(Submission(commandID: "later", turnID: "later", text: "Later"), steer: false)
        XCTAssertEqual(sent["delivery"].text, "after-resume")
        let reply = try await reopened.continueRun(commandID: "resume-again")
        XCTAssertEqual(reply["compacting"].flag, true)
        state = try await settled(reopened)
        let summaries = await client.summaryRequests
        XCTAssertEqual(summaries, 3, "Cut, done before the copy's end, and done again here")
        XCTAssertEqual(state["compaction"]["phase"].text, "completed"); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        await reopened.close()
    }

    /// Round 2: the limit is crossed after the batch's gate, while a call is
    /// still preparing. That call is held at its own gate, not failed.
    func testACallHeldAtItsOwnGateRunsOnResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.02), .reply(answer("Done"), cost: 0.01)], hold: [1])
        let tools = GatedDefinitionsTools()
        let s = try await session(root, client: client, tools: tools, limit: 1)
        try await send(s, "Work")
        try await eventually { await client.holding }
        await tools.close()
        await client.release()
        try await eventually { await tools.waiting }
        await s.setCostLimit(0.01)
        await tools.open()
        var state = try await settled(s)
        var ran = await tools.calls
        XCTAssertTrue(ran.isEmpty); XCTAssertEqual(state["costPaused"].flag, true)
        let results = await s.history.filter { $0.role == "toolResult" }
        XCTAssertTrue(results.isEmpty, "Held, not given a failed result")
        await s.setCostLimit(1)
        _ = try await s.continueRun(commandID: "resume")
        state = try await settled(s)
        ran = await tools.calls
        XCTAssertEqual(ran, ["first"]); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        await s.close()
    }

    /// Round 3: a call held at its own gate while another call still runs is
    /// saved at once: a quit then interrupts the running call (unknown
    /// outcome) and the held one is still held after reopening, to run on Resume.
    func testACallHeldWhileAnotherRunsSurvivesAQuit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first","second"]), cost: 0.02), .reply(answer("Done"), cost: 0.01)], hold: [1])
        let tools = OneGatedCallTools()
        let s = try await session(root, id: "held-quit", client: client, tools: tools, limit: 1)
        try await send(s, "Work")
        try await eventually { await client.holding }
        await tools.arm(); await client.release()
        try await eventually { let invoked = await tools.invoked.count, waiting = await tools.waiting; return invoked == 1 && waiting }
        await s.setCostLimit(0.01)
        await tools.open()
        try await eventually { await s.snapshot()["costPaused"].flag == true }
        try await Task.sleep(for: .milliseconds(100))
        let saved = await s.path, path = try XCTUnwrap(saved)
        await s.close()
        let reopened = try await session(root, id: "held-quit", client: client, tools: tools, limit: 1, resume: path)
        let results = await reopened.history.filter { $0.role == "toolResult" }
        XCTAssertEqual(results.count, 1, "Only the call that ran gets an (interrupted) outcome")
        let state = await reopened.snapshot(); XCTAssertEqual(state["costPaused"].flag, true)
        await tools.release()
        _ = try await reopened.continueRun(commandID: "resume")
        let done = try await settled(reopened)
        let invoked = await tools.invoked
        XCTAssertEqual(invoked.count, 2, "The held call ran on Resume; the interrupted one was not replayed")
        XCTAssertEqual(done["state"].text, "idle", done["preflightError"].encoded())
        await reopened.close()
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

    /// A limit lowered below the spend while a request is in flight: that
    /// request's reply pauses the chat with its tool call held; raising the
    /// limit resumes nothing; Resume runs the held call, then goes on.
    func testLoweringTheLimitMidRequestPausesAndResumeGoesOn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 0.02), .reply(toolReply(["second"]), cost: 0.02), .reply(answer("Done"), cost: 0.02)], hold: [1, 2])
        let tools = RecordingTools()
        let s = try await session(root, client: client, tools: tools, limit: 1)
        try await send(s, "Work")
        try await eventually { await client.holding }
        await s.setCostLimit(0.01)
        await client.release()
        var state = try await settled(s)
        var requests = await client.turnRequests
        var ran = await tools.calls
        XCTAssertEqual(requests, 1); XCTAssertTrue(ran.isEmpty); XCTAssertEqual(state["costPaused"].flag, true)
        await s.setCostLimit(0.03)
        state = await s.snapshot()
        XCTAssertEqual(state["cost"]["reached"].flag, false); XCTAssertEqual(state["costPaused"].flag, true)
        do { try await s.retryRun(); XCTFail("Retry is not the pause's Resume") } catch {}
        _ = try await s.continueRun(commandID: "resume")
        try await eventually { await client.holding }
        await s.setCostLimit(1)
        await client.release()
        state = try await settled(s)
        requests = await client.turnRequests; ran = await tools.calls
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
            let client = BillingClient(turns: [.reply(toolReply(["write"]), cost: 0.04), .fail(rejected, cost: 0.02), .reply(answer("Resumed"), cost: 0.01)],
                                       summaries: [.reply(answer("Should not be requested"), cost: 0.005)])
            let tools = EvidenceTools()
            let s = try await session(root, client: client, tools: tools, limit: 0.05, policy: Self.smallTail)
            try await send(s, "Append the counter once")
            var state = try await settled(s)
            var summaries = await client.summaryRequests
            let writes = await tools.count
            XCTAssertEqual(summaries, 0, "A recovery summary is a model request and must not go at the limit")
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(state["errorCode"].text, "cost_limit")
            XCTAssertEqual(state["compaction"]["phase"].text, "failed"); XCTAssertEqual(state["compaction"]["errorCode"].text, "cost_limit")
            assertSpend(state, usd: 0.06, reported: 2, unreported: 0)
            // A manual compaction at the limit stops before its summary request too.
            try await s.compact()
            state = try await settled(s)
            summaries = await client.summaryRequests
            XCTAssertEqual(summaries, 0); XCTAssertEqual(state["errorCode"].text, "cost_limit")
            // Raised, Resume goes on from where the pause left the run.
            await s.setCostLimit(1)
            _ = try await s.continueRun(commandID: "resume")
            state = try await settled(s)
            XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded()); XCTAssertTrue(state["errorCode"].isNull); XCTAssertTrue(state["preflightError"].isNull)
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
        let source = await s.id
        var observation = RequestObservation(sessionID: source, turnID: "t", attemptID: "zero", purpose: "turn", fingerprint: "f", profile: try fixtureProfile())
        observation.monitoring = ["gateway": ["cost": ["status": "reported", "usd": 0]], "outcome": "completed"]
        await s.countAttempt(observation)
        // A conflicting or invalid report is no amount either.
        for status in ["conflict", "invalid"] {
            var other = RequestObservation(sessionID: source, turnID: "t", attemptID: status, purpose: "turn", fingerprint: "f", profile: try fixtureProfile())
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

    /// The stop notice writes an amount as the app writes a cost limit
    /// (`CostLimit.dollars`), value for value: the `limit` column of the app's
    /// SidebarFigureGoldenTests. Rounded half-up in decimal, so $2.675 is
    /// $2.68 in both, and an amount too small for six places is `<$0.000001`.
    private static let dollars: [(value: Double, text: String)] = [
        (0, "$0.00"), (1e-12, "<$0.000001"), (1e-7, "<$0.000001"), (4.9e-7, "<$0.000001"), (5e-7, "$0.000001"),
        (0.000001, "$0.000001"), (0.0000015, "$0.000002"), (0.00004, "$0.00004"), (0.00005, "$0.00005"), (0.00015, "$0.00015"),
        (0.000421875, "$0.000422"), (0.0005, "$0.0005"), (0.001, "$0.001"), (0.00125, "$0.00125"), (0.005, "$0.005"),
        (0.0099, "$0.0099"), (0.0099949, "$0.009995"), (0.00995, "$0.00995"), (0.0099995, "$0.01"), (0.01, "$0.01"),
        (0.015, "$0.02"), (0.125, "$0.13"), (0.5, "$0.50"), (1, "$1.00"), (1.005, "$1.01"), (2.675, "$2.68"), (4.125, "$4.13"),
        (25, "$25.00"), (99.995, "$100.00"), (1234.5678, "$1234.57"), (1_000_000, "$1000000.00"),
        (-1, "$0.00"), (.nan, "$0.00"), (.infinity, "$0.00"),
    ]

    func testTheStopNoticeWritesDollarsAsTheAppWritesALimit() {
        for row in Self.dollars { XCTAssertEqual(AgentSession.costText(row.value), row.text, "\(row.value)") }
    }

    /// A tie the binary value rounds down: the notice says the limit as the
    /// chat's limit field shows it, $2.68, and its words are otherwise as
    /// they were.
    func testTheNoticeSaysATiedLimitAsTheAppShowsIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = BillingClient(turns: [.reply(toolReply(["first"]), cost: 2.675), .reply(answer("Done"), cost: 0.01)])
        let s = try await session(root, client: client, limit: 2.675)
        try await send(s, "Work through it")
        let state = try await settled(s)
        XCTAssertEqual(state["errorCode"].text, "cost_limit")
        XCTAssertEqual(state["preflightError"].text, "Paused at the cost limit: $2.68 spent of $2.68. Raise the limit above the spend, then choose Resume.")
        await s.close()
    }
}

/// The gateway finishes accounting only after the in-flight request is cancelled.
private actor CancellationBillingClient: ModelClient {
    private(set) var requests = 0
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile: profile, apiKey: apiKey, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, turnID: turnID, purpose: purpose, onObservation: { _ in }, onDelta: onDelta)
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1
        let cancelling = requests == 2
        if cancelling {
            do { while true { try await Task.sleep(nanoseconds: 5_000_000) } }
            catch { /* The final gateway accounting still arrives. */ }
        }
        var observation = RequestObservation(sessionID: sessionID, turnID: turnID, attemptID: UUID().uuidString, purpose: purpose, fingerprint: "fixture", profile: profile)
        observation.phase = cancelling ? "interrupted" : "final"
        observation.monitoring = ["outcome": cancelling ? "cancelled" : "completed", "gateway": ["cost": ["status": "reported", "usd": JSON(cancelling ? 0.70 : 0.40)]]]
        await onObservation(observation)
        if cancelling { throw CancellationError() }
        return answer("First completed")
    }
}
