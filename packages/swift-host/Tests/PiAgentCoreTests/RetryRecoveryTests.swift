import XCTest
@testable import PiAgentCore

private actor RetryRecoveryClient: ModelClient {
    private var holdFirst = true
    private(set) var requests: [[ChatMessage]] = []
    private(set) var turns: [String] = []
    func release() { holdFirst = false }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests.append(messages); turns.append(turnID)
        let index = requests.count - 1
        while index == 0 && holdFirst { try await Task.sleep(nanoseconds: 1_000_000) }
        if index == 0 { throw AgentError("provider_http", "Provider returned HTTP 401. Fixture failure.") }
        return answer(index == 1 ? "Retried original request" : "Answered steering")
    }
}

final class RetryRecoveryTests: XCTestCase {
    func testRetryFinishesTheFailedRequestBeforeDeliveringPausedSteering() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = RetryRecoveryClient()
        let session = try AgentSession(id: "retry", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Original request"), steer: false)
        try await eventually { await client.requests.count == 1 }
        _ = try await session.submit(Submission(commandID: "steering", turnID: "steering", text: "After the current model turn"), steer: true)
        await client.release(); try await eventually { !(await session.isRunning) }
        try await session.retryRun()
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests, turns = await client.turns
        XCTAssertEqual(requests.count, 3, "Retry must complete the failed request before consuming paused steering")
        XCTAssertEqual(requests[1].map(\.text), ["Original request"])
        XCTAssertEqual(turns, ["first", "first", "steering"])
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["state"].text, "idle")
        XCTAssertEqual(snapshot["queueCount"].int, 0)
        await session.close()
    }

    func testRecoveryPairsEachReusedToolCallWithItsOwnResult() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), path = directory.appendingPathComponent("recover.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: path, id: "recover", cwd: root, binding: profile.binding, create: true)
        let first = toolReply(["read"]).message
        try journal?.append(["type": "message", "message": first.pi], id: first.id)
        var earlier = ChatMessage(role: "toolResult", content: [textBlock("Earlier completed result")])
        earlier.toolCallId = "call-0"; earlier.toolName = "read"
        try journal?.append(["type": "message", "message": earlier.pi], id: earlier.id)
        var interrupted = toolReply(["read"]).message
        interrupted.turn = "interrupted-turn"; interrupted.requestAttemptIDs = ["interrupted-attempt"]
        try journal?.append(["type": "message", "message": interrupted.pi], id: interrupted.id)
        journal = nil
        let client = ScriptClient([]), tools = RecordingTools()
        let session = try AgentSession(id: "recover", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), resumePath: path.path, autoCompaction: false)
        let snapshot = await session.snapshot(), seed = await session.sideSeed()
        let results = seed.messages.filter { $0.role == "toolResult" }
        XCTAssertEqual(results.count, 2, "An old result cannot satisfy a reused ID in a later interrupted request")
        XCTAssertEqual(results.first?.text, "Earlier completed result")
        XCTAssertTrue(results.last?.isError == true)
        XCTAssertTrue(results.last?.text.contains("Outcome unknown") == true)
        XCTAssertEqual(results.last?.turn, "interrupted-turn")
        XCTAssertEqual(results.last?.requestAttemptIDs, ["interrupted-attempt"])
        XCTAssertEqual(snapshot["state"].text, "paused")
        XCTAssertEqual(snapshot["messages"].list.first { $0["id"].text == first.id }?["tools"].list.first?["output"].text, "Earlier completed result")
        let invocations = await tools.calls, requests = await client.count
        XCTAssertEqual(invocations, []); XCTAssertEqual(requests, 0, "Recovery never replays the interrupted operation")
        await session.close()
    }
}
