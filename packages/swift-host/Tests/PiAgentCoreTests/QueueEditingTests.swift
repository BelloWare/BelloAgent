import XCTest
@testable import PiAgentCore

/// Pending follow-ups can be reordered, rewritten and promoted to steering
/// while a run is active; each change is durable and visible in the snapshot.
final class QueueEditingTests: XCTestCase {
    func testQueuedFollowUpsReorderRewriteAndSteerWhileRunning() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two"), answer("three"), answer("four")], holdFirst: true)
        let session = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "Start"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha"), steer: false)
        _ = try await session.submit(Submission(commandID: "c2", turnID: "b", text: "Beta"), steer: false)
        _ = try await session.submit(Submission(commandID: "c3", turnID: "c", text: "Gamma"), steer: false)
        var snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["queue"].list.map { $0["turnId"].text }, ["a", "b", "c"])

        try await session.reorderQueue(["c", "a", "b"])
        snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["queue"].list.map { $0["turnId"].text }, ["c", "a", "b"], "Follow-ups take the requested order")
        do { try await session.reorderQueue(["a", "b"]); XCTFail("An order that drops a pending turn is refused") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_order") }
        do { try await session.reorderQueue(["a", "b", "b"]); XCTFail("Duplicates are refused") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_order") }

        try await session.updateQueued("a", text: "Alpha, revised")
        snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["queue"].list.first { $0["turnId"].text == "a" }?["text"].text, "Alpha, revised")
        do { try await session.updateQueued("a", text: ""); XCTFail("An empty rewrite is refused") }
        catch let error as AgentError { XCTAssertEqual(error.code, "empty_message") }
        do { try await session.updateQueued("missing", text: "x"); XCTFail("Unknown turns are refused") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_missing") }

        try await session.steerQueued("b")
        snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["steering"].list.map { $0["turnId"].text }, ["b"], "The promoted message waits in the steering lane")
        XCTAssertEqual(snapshot["queue"].list.filter { $0["kind"].text == "follow-up" }.map { $0["turnId"].text }, ["c", "a"])
        XCTAssertEqual(snapshot["queueCount"].int, 3)

        // The reordered, rewritten and steered messages are delivered in that shape.
        await client.release(); try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 4)
        let userTexts = requests.dropFirst().map { $0.last?.text ?? "" }
        XCTAssertTrue(userTexts.contains("Beta"), "steering delivered")
        XCTAssertEqual(Array(userTexts.suffix(2)), ["Gamma", "Alpha, revised"], "follow-ups run in the reordered sequence with the revised text")
        let finished = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(finished["queueCount"].int, 0); XCTAssertEqual(finished["state"].text, "idle")
        do { try await session.steerQueued("nothing"); XCTFail("Steering needs a pending follow-up") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_missing") }
        await session.close()
    }
}
