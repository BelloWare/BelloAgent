import XCTest
@testable import PiAgentCore

private actor CompactionQueueClient: ModelClient {
    private var held = true
    private let failCompaction: Bool
    private(set) var requests: [[ChatMessage]] = []
    init(failCompaction: Bool = false) { self.failCompaction = failCompaction }
    func release() { held = false }
    var count: Int { requests.count }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition],
                  sessionID: String, turnID: String, purpose: String,
                  onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests.append(messages); let index = requests.count
        if index == 2 {
            while held { try await Task.sleep(nanoseconds: 1_000_000) }
            if failCompaction { throw AgentError("fixture", "Deterministic compaction failure") }
        }
        let text = index == 1 ? String(repeating: "Completed work with evidence. ", count: 300)
            : index == 2 ? "Preserve the original objective and verified evidence." : "Follow-up completed."
        return answer(text)
    }
}

final class QueueHandoffTests: XCTestCase {
    func testFollowUpsQueuedDuringManualCompactionRunExactlyOnceWithoutResume() async throws {
        try await exercise(fail: false, cancel: false)
    }
    func testFailedCompactionLeavesFollowUpsPausedUntilResume() async throws {
        try await exercise(fail: true, cancel: false)
    }
    func testStoppedCompactionLeavesFollowUpsPausedUntilResume() async throws {
        try await exercise(fail: false, cancel: true)
    }
    private func exercise(fail: Bool, cancel: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = CompactionQueueClient(failCompaction: fail)
        let session = try AgentSession(id:"handoff",profile:fixtureProfile(),apiKey:"fixture",cwd:root,
            directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),
            client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false,
            compactionPolicy:{ var policy=CompactionPolicy();policy.keepRecentTokens=1;return policy }())
        addTeardownBlock { await session.close() }
        // An earlier exchange for pi's cut to summarize; the objective and its
        // answer are the kept tail.
        var earlier=ChatMessage(role:"user",content:[textBlock("Earlier request")]);earlier.id="earlier";earlier.taskRootID="earlier"
        var earlierAnswer=ChatMessage(role:"assistant",content:[textBlock(String(repeating:"Earlier evidence. ",count:200))]);earlierAnswer.taskRootID="earlier"
        try await session.append(earlier);try await session.append(earlierAnswer)
        _ = try await session.submit(Submission(commandID:"first",turnID:"first",text:"Original objective"),steer:false)
        try await eventually { !(await session.isRunning) }
        try await session.compact(commandID:"compact")
        try await eventually { await client.count == 2 }
        for id in ["next", "last"] {
            let accepted = try await session.submit(Submission(commandID:id,turnID:id,text:id + " question"),steer:false)
            XCTAssertEqual(accepted["queued"].flag,true)
        }
        if cancel { await session.stop() }
        await client.release()
        if fail || cancel {
            try await eventually { !(await session.isRunning) }
            let paused = await session.snapshot()
            XCTAssertEqual(paused["queueCount"].int,2); XCTAssertEqual(paused["queuePaused"].flag,true)
            let count = await client.count; XCTAssertEqual(count,2)
            try await session.resumeQueue()
        }
        try await eventually { let count = await client.count, running = await session.isRunning; return count == 4 && !running }
        let snapshot = await session.snapshot(), messages = await session.context, requests = await client.requests
        XCTAssertEqual(snapshot["queueCount"].int,0); XCTAssertEqual(snapshot["state"].text,"idle")
        XCTAssertEqual(messages.filter { $0.id == "next" }.count,1); XCTAssertEqual(messages.filter { $0.id == "last" }.count,1)
        XCTAssertEqual(requests[2].last?.text,"next question"); XCTAssertEqual(requests[3].last?.text,"last question")
        let tasks = try JSONDecoder().decode(TaskPresentationProjection.self,from:snapshot["taskPresentation"].data())
        XCTAssertEqual(tasks.recent.filter { $0.rootID == "next" || $0.rootID == "last" }.map(\.outcome),["completed","completed"])
    }
}
