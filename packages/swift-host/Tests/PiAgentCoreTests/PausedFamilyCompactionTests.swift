import XCTest
@testable import PiAgentCore

final class PausedFamilyCompactionTests: HelperTestCase {
    private func session(_ client: PausedSummaryClient, root: URL) async throws -> AgentSession {
        let owner = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: DisabledTools(), traces: TraceStore(),
            autoCompaction: false, compactionPolicy: CompactionSnapshotTests.smallTail)
        addTeardownBlock { await client.release(); await owner.close() }
        await owner.enableFamilyBudget(); await owner.setCostLimit(1)
        await owner.useRetrySettings(.init(maxRetries: 1, baseDelayMs: 1))
        for index in 0..<2 {
            _ = try await owner.submit(Submission(commandID: "turn-\(index)", turnID: "turn-\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await owner.isRunning) }
        }
        return owner
    }

    func testManualSummaryAndRetryPreservePausedFollowupsAfterStopOrFailure() async throws {
        for stopped in [true, false] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let client = PausedSummaryClient(), owner = try await session(client, root: root)
            _ = try await owner.submit(Submission(commandID: "held", turnID: "held", text: "Wait for a follow-up"), steer: false)
            try await eventually { await client.waiting }
            _ = try await owner.submit(Submission(commandID: "follow", turnID: "follow", text: "Keep queued"), steer: false)
            if stopped { await owner.stop() }
            await client.release()
            try await eventually { !(await owner.isRunning) }
            await client.failOneSummary()
            try await owner.compact(commandID: "manual")
            try await eventually { !(await owner.isRunning) }
            let snapshot = await owner.snapshot(), purposes = await client.purposes, spend = await owner.spend
            XCTAssertNotNil(snapshot["latestSuccessfulCompaction"]["id"].text, snapshot.encoded())
            XCTAssertEqual(snapshot["commands"].list.last?["state"].text, "completed")
            XCTAssertEqual(snapshot["queuePaused"].flag, true)
            XCTAssertEqual(snapshot["queueCount"].int, 1)
            XCTAssertEqual(purposes, ["turn", "turn", "turn", "compaction", "compaction"])
            XCTAssertEqual(spend.usd, 0.05, accuracy: 1e-9)
            let attempts = await owner.accounting.attempts
            XCTAssertEqual(attempts.count, 5)
            XCTAssertTrue(attempts.values.allSatisfy { $0.contribution != nil })
            await owner.close()
        }
    }

    func testStopAfterManualLifecycleWasCreatedRejectsItsLateAdmission() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = PausedSummaryClient(), owner = try await session(client, root: root)
        await owner.stop(); await client.holdSummary(beforeAdmission: true)
        try await owner.compact(commandID: "manual")
        try await eventually { await client.waiting }
        let value = await client.summaryLifecycle, hooks = try XCTUnwrap(value)
        await owner.stop()
        // This callback is deliberately outside the cancelled run task: the
        // owner's captured generation, not Task.isCancelled, must reject it.
        do { _ = try await hooks.admitAttempt("late"); XCTFail("A later Stop did not revoke manual compaction") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.release(); try await eventually { !(await owner.isRunning) }
        let snapshot = await owner.snapshot(), attempts = await owner.accounting.attempts
        XCTAssertTrue(snapshot["latestSuccessfulCompaction"].isNull)
        XCTAssertNil(attempts["late"])
        XCTAssertEqual(snapshot["queuePaused"].flag, true)
    }

    func testCancelledManualPermitCannotDispatchWhileQueueRemainsPaused() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = PausedSummaryClient(), owner = try await session(client, root: root)
        await owner.stop(); await client.holdSummary(beforeAdmission: false)
        try await owner.compact(commandID: "manual")
        try await eventually {
            let waiting = await client.waiting, running = await owner.isRunning
            return waiting || !running
        }
        let value = await client.summaryPermit, permit = try XCTUnwrap(value, "Manual summary must be admitted while paused")
        let lifecycle = await client.summaryLifecycle, hooks = try XCTUnwrap(lifecycle)
        permit.cancel()
        do { try await hooks.willDispatch(permit.attemptID); XCTFail("A cancelled summary permit dispatched") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.release(); try await eventually { !(await owner.isRunning) }
        let attempts = await owner.accounting.attempts, snapshot = await owner.snapshot()
        XCTAssertEqual(attempts[permit.attemptID]?.admission?["state"].text, "not_dispatched")
        XCTAssertTrue(snapshot["latestSuccessfulCompaction"].isNull)
    }

    func testPausedOwnerStillRejectsOrdinaryAndAutomaticSummaryRequests() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try familyFixture(root: root); await owner.enableFamilyBudget(); await owner.stop()
        for purpose in ["turn", "compaction"] {
            let value = try await owner.requestLifecycle(turnID: "automatic", purpose: purpose), hooks = try XCTUnwrap(value)
            do { _ = try await hooks.admitAttempt(purpose); XCTFail("Paused \(purpose) was admitted without explicit compaction") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await owner.close()
    }
}

private actor PausedSummaryClient: ModelClient {
    var purposes: [String] = []
    var summaryLifecycle: RequestLifecycle?, summaryPermit: RequestPermit?
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var holdBeforeAdmission: Bool?, summaryFailures = 0
    func holdSummary(beforeAdmission: Bool) { holdBeforeAdmission = beforeAdmission }
    func failOneSummary() { summaryFailures = 1 }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    private func hold() async {
        await withCheckedContinuation { continuation = $0; waiting = true }
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped", "Missing family accounting")
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), id = UUID().uuidString
        if purpose == "compaction" {
            summaryLifecycle = hooks
            if holdBeforeAdmission == true { await hold() }
        }
        let permit = try await hooks.admitAttempt(id); defer { permit.finish() }
        var dispatched = false, settled = false
        var observation = RequestObservation(sessionID: sessionID, turnID: turnID, attemptID: id, purpose: purpose, fingerprint: "fixture", profile: profile)
        observation.monitoring = ["outcome":"completed", "gateway":["cost":["status":"reported", "usd":0.01]]]
        do {
            if purpose == "compaction" {
                summaryPermit = permit
                if holdBeforeAdmission == false { await hold() }
            }
            try await hooks.willDispatch(id); dispatched = true; purposes.append(purpose)
            if turnID == "held" { await hold() }
            try await hooks.settleAttempt(AttemptSettlement(scope: hooks.scope, observation: observation, dispatched: true)); settled = true
            try Task.checkCancellation()
            if turnID == "held" { throw AgentError("fixture_failure", "Request failed") }
            if purpose == "compaction", summaryFailures > 0 {
                summaryFailures -= 1; throw AgentError("provider_http", "HTTP 503 server unavailable", attemptID: id)
            }
            var reply = answer(purpose == "compaction" ? "Summary of completed work" : String(repeating: "Completed task with evidence. ", count: 100))
            reply.message.requestAttemptIDs = [id]; return reply
        } catch {
            if !settled { try await hooks.settleAttempt(AttemptSettlement(scope: hooks.scope, observation: observation, dispatched: dispatched)) }
            throw error
        }
    }
}
