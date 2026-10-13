import XCTest
@testable import PiAgentCore

private actor SettlementGate {
    private var waiter: CheckedContinuation<Void, Never>?
    var entered: Bool { waiter != nil }
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}

private extension AgentSession {
    func holdFinalLinks(at gate: SettlementGate) { beforeFinalRequestLinks = { await gate.wait() } }
}

final class SessionSettlementTests: XCTestCase {
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
