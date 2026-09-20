import XCTest
@testable import PiAgentCore

private actor HeldQueueDeliveryTools: ToolExecuting {
    private var deliveries = 0, held = true
    private(set) var waiting = false
    func release() { held = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [] }
    func capabilityIDs(readOnly: Bool) async -> [String] {
        deliveries += 1
        if deliveries == 2 {
            waiting = true
            while held { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        return []
    }
    func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON { throw AgentError("fixture", "No tool execution expected") }
}

/// Pending follow-ups can be reordered, rewritten and promoted to steering
/// while a run is active; each change is durable and visible in the snapshot.
final class QueueEditingTests: XCTestCase {
    func testRemovingFollowUpDuringAllDeliveryDoesNotCrashOrDispatchRemovedText() async throws { try await checkRemovalDuringDelivery(steer: false) }
    func testRemovingSteeringDuringAllDeliveryDoesNotCrashOrDispatchRemovedText() async throws { try await checkRemovalDuringDelivery(steer: true) }
    func testNewFollowUpCannotReplaceRemovedItemInAnInFlightAllBatch() async throws { try await checkRemovalDuringDelivery(steer: false, addNew: true) }
    func testNewSteeringCannotReplaceRemovedItemInAnInFlightAllBatch() async throws { try await checkRemovalDuringDelivery(steer: true, addNew: true) }

    private func checkRemovalDuringDelivery(steer: Bool, addNew: Bool = false) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = HeldQueueDeliveryTools(), client = ScriptClient([answer("first reply"), answer("batch reply"), answer("new batch reply")], holdFirst: true)
        let session = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), autoCompaction: false)
        try await session.configureQueue(["steeringMode": "all", "followUpMode": "all"])
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "delivered", turnID: "delivered", text: "Deliver this"), steer: steer)
        _ = try await session.submit(Submission(commandID: "removed", turnID: "removed", text: "Remove this"), steer: steer)
        await client.release()
        try await eventually { await tools.waiting }
        try await session.removeQueued("removed")
        if addNew { _ = try await session.submit(Submission(commandID: "new", turnID: "new", text: "New batch"), steer: steer) }
        await tools.release()
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests, snapshot = await session.snapshot()
        XCTAssertEqual(requests.count, addNew ? 3 : 2)
        XCTAssertEqual(requests[1].filter { $0.role == "user" }.map(\.text), ["First", "Deliver this"])
        if addNew { XCTAssertEqual(requests.last?.filter { $0.role == "user" }.map(\.text), ["First", "Deliver this", "New batch"]) }
        XCTAssertEqual(snapshot["state"].text, "idle")
        XCTAssertEqual(snapshot["queueCount"].int, 0)
        XCTAssertEqual(snapshot["commands"].list.first { $0["turnId"].text == "removed" }?["status"].text, "removed")
        await session.close()
    }

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

/// A queued message the app can edit must be readable in full: the snapshot
/// row carries a 1 KiB preview, and an editor that wrote that preview back
/// would discard everything the user typed past it.
final class QueuedTextReadTests: XCTestCase {
    func testLongQueuedMessageIsFlaggedAndReadableWhole() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // The first request is held so the follow-up is still pending while it
        // is read and edited. Without the hold, a Release build answers the
        // first turn and delivers the follow-up before the read happens.
        let client = ScriptClient([answer("first"), answer("second")], holdFirst: true)
        let session = try AgentSession(id: "queued-text", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"),
                                       readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        addTeardownBlock { await session.close() }
        let long = String(repeating: "paragraph of a long queued message\n", count: 300)
        XCTAssertGreaterThan(long.utf8.count, 4096)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "first"), steer: false)
        _ = try await session.submit(Submission(commandID: "c2", turnID: "t2", text: long), steer: false)
        let snapshot = await session.snapshot()
        let row = try XCTUnwrap(snapshot["queue"].list.first { $0["turnId"].text == "t2" })
        XCTAssertLessThanOrEqual((row["text"].text ?? "").utf8.count, 1024)
        XCTAssertEqual(row["textTruncated"].flag, true)
        XCTAssertEqual(row["textBytes"].int, long.utf8.count)
        let whole = try await session.queuedText("t2")
        XCTAssertEqual(whole["text"].text, long, "The editor gets every byte the user queued")
        XCTAssertEqual(whole["kind"].text, "follow-up")
        // Saving the full text back round-trips; saving the preview would not.
        try await session.updateQueued("t2", text: long + "tail")
        let reread = try await session.queuedText("t2")
        XCTAssertEqual(reread["text"].text, long + "tail")
        do { _ = try await session.queuedText("absent"); XCTFail("An unknown turn must not resolve") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "queue_missing") }
        await session.stop(); await client.release()
    }
}
