import XCTest
@testable import PiAgentCore

private actor CompactionOutcomeClient: ModelClient {
    var hold = false
    private(set) var compacting = false
    func holdCompaction() { hold = true }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        guard purpose == "compaction" else { return answer(String(repeating:"Completed answer with evidence. ",count:100)) }
        compacting = true
        while hold { try await Task.sleep(nanoseconds: 1_000_000) }
        throw AgentError("fixture_compaction_failure", "Summary request failed")
    }
}

final class CompactionSnapshotTests: XCTestCase {
    /// A one-token tail, so two short turns have history to summarize.
    static let smallTail: CompactionPolicy = { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }()
    func testFailedAndCancelledCompactionDoNotPublishSuccess() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = CompactionOutcomeClient()
        let session = try AgentSession(id: "outcomes", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, compactionPolicy: CompactionSnapshotTests.smallTail)
        addTeardownBlock { await session.close() }
        for index in 0..<2 {
            _ = try await session.submit(Submission(commandID: "turn-\(index)", turnID: "turn-\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        try await session.compact(commandID: "failed")
        try await eventually { !(await session.isRunning) }
        let failed = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(failed["latestSuccessfulCompaction"].isNull)
        XCTAssertNotEqual(failed["runStatus"].text, "compacting")
        XCTAssertTrue(failed["preflightError"].text?.contains("Summary request failed") == true)

        await client.holdCompaction()
        try await session.compact(commandID: "cancelled")
        try await eventually { await session.snapshot(["includeMessages": false])["runStatus"].text == "compacting" }
        await session.stop()
        try await eventually { !(await session.isRunning) }
        let cancelled = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(cancelled["latestSuccessfulCompaction"].isNull)
        XCTAssertNotEqual(cancelled["runStatus"].text, "compacting")
    }

    func testFailedRetryLeavesPreviousSuccessfulSummaryIdentityUnchanged() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AgentSession(id: "retry", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([answer(String(repeating:"Completed first task evidence. ",count:80)), answer("Second"), answer("Summary"), answer("Third")]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, compactionPolicy: CompactionSnapshotTests.smallTail)
        addTeardownBlock { await session.close() }
        for index in 0..<2 {
            _ = try await session.submit(Submission(commandID: "turn-\(index)", turnID: "turn-\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        try await session.compact(commandID: "success"); try await eventually { !(await session.isRunning) }
        let success = await session.snapshot(["includeMessages": false])["latestSuccessfulCompaction"]
        XCTAssertNotNil(success["id"].text)
        _ = try await session.submit(Submission(commandID: "third", turnID: "third", text: "Third question"), steer: false)
        try await eventually { !(await session.isRunning) }
        try await session.compact(commandID: "failure"); try await eventually { !(await session.isRunning) }
        let failed = await session.snapshot(["includeMessages": false])
        XCTAssertNotNil(failed["preflightError"].text)
        XCTAssertEqual(failed["latestSuccessfulCompaction"], success, "A failed request cannot appear as a new successful summary")
    }

    func testAbandonedCompactionInRetainedJournalIsNotReportedAsActiveSuccess() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), path = directory.appendingPathComponent("branched.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: path, id: "branched", cwd: root, binding: profile.binding, create: true)
        try journal!.append(["type": "message", "message": ["role": "user", "content": "Original question"]], id: "old-user")
        try journal!.append(["type": "compaction", "summary": "Old summary", "nativeKeptIDs": ["old-user"], "tokensBefore": 10000], id: "abandoned-summary")
        try journal!.append(["type": "branch", "fromMessageId": "old-user", "keptIds": []], id: "branch")
        try journal!.append(["type": "message", "message": ["role": "user", "content": "Replacement"]], id: "replacement")
        journal = nil
        let session = try AgentSession(id: "branched", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path, autoCompaction: false)
        addTeardownBlock { await session.close() }
        let snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(snapshot["latestSuccessfulCompaction"].isNull)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("abandoned-summary"), "The original journal is still retained")
    }
}
