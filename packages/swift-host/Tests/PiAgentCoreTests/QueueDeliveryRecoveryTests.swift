import Foundation
import XCTest
@testable import PiAgentCore

private final class QueueCheckpointFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var committedUser = false, failed = false
    func beforeAppend(_ record: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        if record["type"].text == "message", record["id"].text == "victim" { committedUser = true }
        if committedUser, !failed, record["customType"].text == "pi-app.native.state.v1" {
            failed = true
            throw AgentError("session_limit", "Fixture: queue checkpoint cannot fit after the committed user message")
        }
    }
}

final class QueueDeliveryRecoveryTests: XCTestCase {
    func testFollowUpCheckpointFailureDoesNotRequeueCommittedUserMessage() async throws { try await checkRecovery(steer: false) }
    func testSteeringCheckpointFailureDoesNotRequeueCommittedUserMessage() async throws { try await checkRecovery(steer: true) }

    private func checkRecovery(steer: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), directory = root.appendingPathComponent("state"), resources = Resources(cwd: root, home: root)
        let failure = QueueCheckpointFailure(), client = ScriptClient([answer("First answer"), answer("Remaining answer")], holdFirst: true)
        let session = try AgentSession(id: "recovery", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, beforeJournalAppend: { try failure.beforeAppend($0) })
        _ = try await session.submit(Submission(commandID: "first-command", turnID: "first", text: "First question"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "victim-command", turnID: "victim", text: "Preserve this exact question"), steer: steer)
        _ = try await session.submit(Submission(commandID: "remaining-command", turnID: "remaining", text: "Remaining question"), steer: steer)
        await client.release()
        try await eventually { !(await session.isRunning) }
        let failed = await session.snapshot()
        XCTAssertEqual(failed["state"].text, "error")
        XCTAssertEqual(failed["queueCount"].int, 1, "A committed user is retained in history, never put back into either queue")
        XCTAssertEqual(failed["queue"].list.first?["turnId"].text, "remaining")
        XCTAssertEqual(failed["messages"].list.filter { $0["id"].text == "victim" }.count, 1)
        XCTAssertEqual(failed["commands"].list.first { $0["turnId"].text == "victim" }?["status"].text, "failed")
        let beforeResume = await client.count
        XCTAssertEqual(beforeResume, 1, "A failed checkpoint must not dispatch the next request automatically")
        try await session.resumeQueue()
        try await eventually { !(await session.isRunning) }
        let resumed = await session.snapshot(), requests = await client.requests
        XCTAssertEqual(resumed["state"].text, "idle")
        XCTAssertEqual(resumed["queueCount"].int, 0)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.filter { $0.id == "victim" }.count, 1, "Resume must not repeat the committed turn in provider context")
        let savedPath = await session.path, path = try XCTUnwrap(savedPath)
        await session.close()
        let records = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map { try JSON.parse(Data($0)) }
        XCTAssertEqual(records.filter { $0["type"].text == "message" && $0["id"].text == "victim" }.count, 1)
        let reopened = try AgentSession(id: "recovery", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path, autoCompaction: false)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["messages"].list.filter { $0["id"].text == "victim" }.count, 1)
        XCTAssertEqual(restored["queueCount"].int, 0)
        await reopened.close()
    }
}
