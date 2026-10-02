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

    /// A message taken from the queue for delivery stays in the saved state
    /// until its user record is written: a crash while it is validated (here,
    /// while another queued message is removed, which saves the queue) leaves
    /// a journal that brings it back, once, paused, with nothing sent.
    func testAFollowUpBeingDeliveredSurvivesACrashOneAtATime() async throws { try await checkCrashDuringDelivery(steer: false, mode: "one-at-a-time") }
    func testAFollowUpBeingDeliveredSurvivesACrashAll() async throws { try await checkCrashDuringDelivery(steer: false, mode: "all") }
    func testASteerBeingDeliveredSurvivesACrashOneAtATime() async throws { try await checkCrashDuringDelivery(steer: true, mode: "one-at-a-time") }
    func testASteerBeingDeliveredSurvivesACrashAll() async throws { try await checkCrashDuringDelivery(steer: true, mode: "all") }

    private func checkCrashDuringDelivery(steer: Bool, mode: String) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = HeldQueueDeliveryTools(), client = ScriptClient([answer("first reply"), answer("delivered reply"), answer("more")], holdFirst: true)
        func open(_ directory: URL, resume: String? = nil, client: ScriptClient, tools: any ToolExecuting) throws -> AgentSession {
            try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: Resources(cwd: root, home: root),
                             client: client, tools: tools, traces: TraceStore(), resumePath: resume, autoCompaction: false)
        }
        let session = try open(root.appendingPathComponent("state"), client: client, tools: tools)
        try await session.configureQueue(["steeringMode": JSON(mode), "followUpMode": JSON(mode)])
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "claimed", turnID: "claimed", text: "Deliver this"), steer: steer)
        _ = try await session.submit(Submission(commandID: "removed", turnID: "removed", text: "Remove this"), steer: steer)
        await client.release()
        try await eventually { await tools.waiting }
        try await session.removeQueued("removed")
        // The journal as a crash now would leave it.
        let sessionPath = await session.path
        let source = URL(fileURLWithPath: try XCTUnwrap(sessionPath))
        let crashed = root.appendingPathComponent("crashed"), copy = crashed.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        await tools.release()
        try await eventually { !(await session.isRunning) }
        await session.close()

        let idle = ScriptClient([])
        let recovered = try open(crashed, resume: copy.path, client: idle, tools: RecordingTools())
        let snapshot = await recovered.snapshot(), history = await recovered.history
        XCTAssertEqual(snapshot["state"].text, "paused", "undelivered work comes back paused")
        let pending = (await recovered.queue) + (await recovered.steering)
        XCTAssertEqual(pending.map(\.turnID), ["claimed"], "the message being delivered, once; the removed one stays removed")
        XCTAssertEqual(pending.first?.text, "Deliver this")
        let steering = await recovered.steering
        XCTAssertEqual(steering.count, steer ? 1 : 0)
        XCTAssertFalse(history.contains { $0.id == "claimed" })
        let requests = await idle.count
        XCTAssertEqual(requests, 0, "nothing is sent on reopening")
        await recovered.close()

        // Delivered, it is the conversation's, and only there.
        let reopened = try open(root.appendingPathComponent("state"), resume: source.path, client: ScriptClient([]), tools: RecordingTools())
        let after = await reopened.history, left = (await reopened.queue) + (await reopened.steering)
        XCTAssertEqual(after.filter { $0.id == "claimed" }.count, 1)
        XCTAssertTrue(left.isEmpty)
        await reopened.close()
    }

    /// The message being delivered counts toward the queue's limits, so what
    /// was accepted while it was held still fits when a crash puts it back.
    func testWorkAcceptedDuringADeliveryStillResumesAfterACrash() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = HeldQueueDeliveryTools(), client = ScriptClient([answer("first reply")] + (0..<40).map { answer("reply \($0)") }, holdFirst: true)
        let session = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), autoCompaction: false)
        let large = String(repeating: "x", count: 250_000)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "claimed", turnID: "claimed", text: large), steer: false)
        await client.release()
        try await eventually { await tools.waiting }
        var accepted = 0
        do { while accepted < 64 { _ = try await session.submit(Submission(commandID: "m\(accepted)", turnID: "m\(accepted)", text: large), steer: false); accepted += 1 } }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_limit") }
        let sessionPath = await session.path
        let source = URL(fileURLWithPath: try XCTUnwrap(sessionPath))
        let crashed = root.appendingPathComponent("crashed"), copy = crashed.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        await session.stop(); await tools.release()
        try await eventually { !(await session.isRunning) }
        await session.close()

        let recovered = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: crashed, readOnly: true,
                                         resources: Resources(cwd: root, home: root), client: ScriptClient((0..<40).map { answer("again \($0)") }), tools: RecordingTools(),
                                         traces: TraceStore(), resumePath: copy.path, autoCompaction: false)
        let pending = await recovered.queue
        XCTAssertEqual(pending.count, accepted + 1)
        XCTAssertEqual(pending.first?.turnID, "claimed")
        try await recovered.resumeQueue()
        await recovered.stop()
        try await eventually { !(await recovered.isRunning) }
        await recovered.close()
    }

    /// An order dragged before a follow-up was taken for delivery names a
    /// message no longer pending: it is refused, and the queue stays as it is.
    func testAnOrderFromBeforeADeliveryIsRefused() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = HeldQueueDeliveryTools(), client = ScriptClient([answer("one"), answer("two"), answer("three"), answer("four")], holdFirst: true)
        let session = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        for name in ["a", "b", "c"] { _ = try await session.submit(Submission(commandID: "c-" + name, turnID: name, text: name), steer: false) }
        let dragged = ["c", "b", "a"]
        await client.release()
        try await eventually { await tools.waiting }   // "a" is being delivered
        do { try await session.reorderQueue(dragged); XCTFail("an order naming a delivered message is refused") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_order") }
        let queue = await session.queue
        XCTAssertEqual(queue.map(\.turnID), ["b", "c"], "the queue stays as it was")
        await session.stop(); await tools.release()
        try await eventually { !(await session.isRunning) }
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
