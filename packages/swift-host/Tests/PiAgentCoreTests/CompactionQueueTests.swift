import XCTest
@testable import PiAgentCore

/// A turn that runs until it is released, a summary request that waits
/// until it is released, and every other turn answered at once.
private actor HeldTurnClient: ModelClient {
    var holdTurn = true, holdCompaction = true, ignoresCancel = false
    private(set) var turns: [String] = [], compactions = 0
    func release() { holdTurn = false }
    func releaseCompaction() { holdCompaction = false }
    func ignoreCancel() { ignoresCancel = true }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        if purpose == "compaction" {
            compactions += 1
            while holdCompaction { try await Task.sleep(nanoseconds: 1_000_000) }
            return answer("Summary of the earlier questions")
        }
        turns.append(turnID)
        guard turnID == "long" else { return answer("Answer to \(turnID)") }
        while holdTurn {
            if ignoresCancel { try? await Task.sleep(nanoseconds: 1_000_000) } else { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        try Task.checkCancellation()
        return answer("Long answer")
    }
}

final class CompactionQueueTests: XCTestCase {
    private func session(_ client: HeldTurnClient, root: URL) async throws -> AgentSession {
        let session = try AgentSession(id: "compact-queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, compactionPolicy: CompactionSnapshotTests.smallTail)
        for index in 0..<2 {
            _ = try await session.submit(Submission(commandID: "turn-\(index)", turnID: "turn-\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        _ = try await session.submit(Submission(commandID: "long", turnID: "long", text: "A long question"), steer: false)
        try await eventually { await client.turns.contains("long") }
        return session
    }

    /// /compact during a run stops the turn, which pauses the queue; a
    /// follow-up sent while "Compacting…" is delivered after the summary,
    /// as in pi, instead of waiting behind a pause nobody asked for.
    func testFollowUpSentDuringCompactionIsDeliveredAfterIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = HeldTurnClient(), session = try await session(client, root: root)
        addTeardownBlock { await session.close() }
        try await session.compact(commandID: "compact")
        try await eventually { await client.compactions == 1 }
        let accepted = try await session.submit(Submission(commandID: "follow", turnID: "follow", text: "Follow-up while compacting"), steer: false)
        XCTAssertEqual(accepted["queued"].flag, true)
        await client.releaseCompaction()
        try await eventually { await client.turns.contains("follow") }
        try await eventually { !(await session.isRunning) }
        let settled = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(settled["queuePaused"].flag, false)
        XCTAssertEqual(settled["queueCount"].int, 0)
        XCTAssertNotNil(settled["latestSuccessfulCompaction"]["id"].text)
    }

    /// A Stop pressed while /compact waits for the running turn to wind down
    /// cancels the compaction: no summary request is sent or billed.
    func testStopWhileCompactionWaitsForTheTurnCancelsIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = HeldTurnClient(); await client.ignoreCancel()
        let session = try await session(client, root: root)
        addTeardownBlock { await session.close() }
        let compacting = Task { try await session.compact(commandID: "compact") }
        try await eventually { await session.stopCount == 1 }
        await session.stop()
        await client.release()
        do { try await compacting.value; XCTFail("a stopped compaction must not run") } catch let error as AgentError { XCTAssertEqual(error.code, "compaction_cancelled") }
        try await eventually { !(await session.isRunning) }
        let compactions = await client.compactions
        XCTAssertEqual(compactions, 0, "no summary request was sent")
        let settled = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(settled["queuePaused"].flag, true, "a Stop still pauses the queue")
        XCTAssertTrue(settled["latestSuccessfulCompaction"].isNull)
    }
}
