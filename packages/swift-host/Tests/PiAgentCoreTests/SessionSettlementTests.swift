import XCTest
@testable import PiAgentCore

private actor SettlementGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    var entered: Bool { waiter != nil }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private extension AgentSession {
    func holdFinalLinks(at gate: SettlementGate) { beforeFinalRequestLinks = { await gate.wait() } }
}

final class SessionSettlementTests: XCTestCase {
    func testSteeringIsAcceptedFromLaunchThroughTheActiveRequest() async throws {
        let root = try temporaryDirectory()
        let client = ScriptClient([answer("Done"), answer("Steered"), answer("More")], holdFirst: true)
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root,
            directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root),
            client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        addTeardownBlock { await client.release(); await session.close(); try? FileManager.default.removeItem(at: root) }
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        // Admission must work immediately after launch, before modelActive
        // or the presentation has necessarily been installed.
        _ = try await session.submit(Submission(commandID: "early", turnID: "early", text: "Early steer"), steer: true)
        try await eventually(timeout: .seconds(60)) { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "queued", turnID: "queued", text: "Move this"), steer: false)
        try await session.steerQueued("queued")
        let steering = await session.steering
        XCTAssertEqual(steering.last?.turnID, "queued")
        await client.release()
        try await eventually(timeout: .seconds(60)) { !(await session.isRunning) }
        let history = await session.history
        XCTAssertEqual(history.filter { $0.id == "early" }.count, 1)
        XCTAssertEqual(history.filter { $0.id == "queued" }.count, 1)
    }

    func testCompletedRunRejectsSteeringWhileFinalLinksAreHeldAndDeliversItsNextMessage() async throws {
        try await checkSteeringDuringSettlement(.idle)
    }
    func testStoppedRunRejectsSteeringWhileFinalLinksAreHeldAndKeepsItsQueue() async throws {
        try await checkSteeringDuringSettlement(.paused)
    }
    func testFailedRunRejectsSteeringWhileFinalLinksAreHeldAndKeepsItsQueue() async throws {
        try await checkSteeringDuringSettlement(.error)
    }
    func testEnabledAgentToolsPreserveOrdinaryFailureAndStopGeneration() async throws {
        try await checkSteeringDuringSettlement(.error, agentTools: true)
    }

    private func checkSteeringDuringSettlement(_ terminal: SessionState, agentTools: Bool = false) async throws {
        let root = try temporaryDirectory()
        let client = ScriptClient(terminal == .error ? [] : [answer("Done"), answer("Next done")], holdFirst: true)
        let gate = SettlementGate()
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root,
            directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root),
            client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        addTeardownBlock { await gate.release(); await session.close(); try? FileManager.default.removeItem(at: root) }
        if agentTools { await session.enableSubagents(SubagentCoordinator()) }
        await session.holdFinalLinks(at: gate)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually(timeout: .seconds(60)) { await client.count == 1 }
        if terminal == .paused { await session.stop() } else { await client.release() }
        try await eventually(timeout: .seconds(60)) { await gate.entered }
        let state = await session.state, running = await session.isRunning
        XCTAssertEqual(state, terminal)
        if agentTools {
            let generation = await session.stopCount
            XCTAssertEqual(generation, 0, "Offering agent tools must not stop an ordinary failed run")
        }
        XCTAssertTrue(running, "Final request links still own the task, but its run has ended")
        _ = try await session.submit(Submission(commandID: "next", turnID: "next", text: "Next question"), steer: false)
        do {
            _ = try await session.submit(Submission(commandID: "stale", turnID: "stale", text: "Keep this draft"), steer: true)
            XCTFail("A terminal run cannot accept steering while saving its links")
        } catch let error as AgentError { XCTAssertEqual(error.code, "not_running") }
        do {
            try await session.steerQueued("next")
            XCTFail("The pending follow-up must stay in its lane")
        } catch let error as AgentError { XCTAssertEqual(error.code, "not_running") }
        let queue = await session.queue, steering = await session.steering, commands = await session.commands
        XCTAssertEqual(queue.map(\.turnID), ["next"])
        XCTAssertTrue(steering.isEmpty)
        XCTAssertFalse(commands.contains { $0["turnId"].text == "stale" }, "A refused draft has no acceptance receipt")
        await gate.release()
        try await eventually(timeout: .seconds(60)) { !(await session.isRunning) }
        let snapshot = await session.snapshot(), requests = await client.requests
        if terminal == .idle {
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.last?.last?.text, "Next question")
            XCTAssertEqual(snapshot["queueCount"].int, 0, "Finalization hands a normal submission to the next run")
        } else {
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(snapshot["queueCount"].int, 1)
            XCTAssertEqual(snapshot["queuePaused"].flag, true)
        }
    }

    func testASecondStopDuringCancelledSettlementLeavesResumeAvailable() async throws { try await check(cancel: true) }
    func testStopDuringSuccessfulSettlementDoesNotLeaveStopping() async throws { try await check(cancel: false) }

    private func check(cancel: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("Done")], holdFirst: cancel), gate = SettlementGate()
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        await session.holdFinalLinks(at: gate)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Question"), steer: false)
        if cancel {
            try await eventually { await client.count == 1 }
            await session.stop()
        }
        try await eventually { await gate.entered }
        let terminal = await session.state
        XCTAssertEqual(terminal, cancel ? .paused : .idle)
        await session.stop()
        await gate.release()
        try await eventually { !(await session.isRunning) }
        let snapshot = await session.snapshot(), canContinue = await session.canContinue
        XCTAssertEqual(snapshot["state"].text, "paused")
        XCTAssertEqual(snapshot["queuePaused"].flag, true)
        XCTAssertEqual(canContinue, cancel)
        await session.close()
    }
}
