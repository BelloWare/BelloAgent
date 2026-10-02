import Foundation
import XCTest
@testable import PiAgentCore

/// Holds the second delivery's resource validation until released, so a
/// test can act while one pending message is being delivered.
private actor HeldDeliveryTools: ToolExecuting {
    private var deliveries = 0, held = true
    private(set) var waiting = false
    let holdAt: Int
    init(holdAt: Int = 2) { self.holdAt = holdAt }
    func release() { held = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [] }
    func capabilityIDs(readOnly: Bool) async -> [String] {
        deliveries += 1
        if deliveries == holdAt { waiting = true; while held { try? await Task.sleep(nanoseconds: 1_000_000) } }
        return []
    }
    func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON { throw AgentError("fixture", "No tool execution expected") }
}

/// Refuses run-state records while armed: a definite write failure.
private final class HoldStateWriteFailure: @unchecked Sendable {
    private let lock = NSLock(); private var armed = false
    func arm(_ on: Bool) { lock.lock(); armed = on; lock.unlock() }
    func check(_ record: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        if armed, record["customType"].text == JournalRecordKind.state { throw AgentError("fixture_write", "Definite write refusal") }
    }
}

/// Editing a queued message holds every pending message in its chat until
/// the edit is saved, cancelled or the message removed (handoff D2).
final class QueueEditHoldTests: XCTestCase {
    private func open(_ root: URL, client: ScriptClient, tools: any ToolExecuting = RecordingTools(), directory: String = "state", resume: String? = nil,
                      failure: HoldStateWriteFailure? = nil) throws -> AgentSession {
        try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent(directory), readOnly: true,
                         resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), resumePath: resume, autoCompaction: false,
                         beforeJournalAppend: { try failure?.check($0) })
    }
    private func assertEditState(_ session: AgentSession, _ editID: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let status = try await session.queueEditStatus(editID: editID)
        XCTAssertEqual(status["state"].text, expected, file: file, line: line)
    }
    /// A chat stopped mid-run with "Alpha" (turn `a`) left waiting, paused.
    private func pausedWithPending(_ session: AgentSession, _ client: ScriptClient) async throws {
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha"), steer: false)
        await session.stop(); await client.release()
        try await eventually { !(await session.isRunning) }
    }
    private func userTexts(_ request: [ChatMessage]) -> [String] { request.filter { $0.role == "user" }.map { $0.displayText ?? $0.text } }

    /// The run that is going finishes; held steering and follow-ups wait,
    /// with no further model request, and go once the edit is saved, with
    /// the rewrite in place of the original.
    func testAHeldQueueWaitsForTheEditThenGoesWithTheRewrite() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two"), answer("three"), answer("four")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "steer", text: "Steer this"), steer: true)
        _ = try await session.submit(Submission(commandID: "c2", turnID: "follow", text: "Original follow-up", thinkingLevel: "high"), steer: false)
        let begun = try await session.beginQueueEdit(turnID: "follow", editID: "e1")
        XCTAssertEqual(begun["text"].text, "Original follow-up"); XCTAssertEqual(begun["kind"].text, "follow-up"); XCTAssertEqual(begun["thinkingLevel"].text, "high")
        // A repeated Begin is the same edit.
        let again = try await session.beginQueueEdit(turnID: "follow", editID: "e1")
        XCTAssertEqual(again["sequence"], begun["sequence"])
        // A new message joins the held queue.
        let late = try await session.submit(Submission(commandID: "c3", turnID: "late", text: "Late"), steer: false)
        XCTAssertEqual(late["delivery"].text, "after-edit")
        await client.release()
        try await eventually { !(await session.isRunning) }
        var count = await client.count
        XCTAssertEqual(count, 1, "held steering and follow-ups cause no model request")
        var snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["state"].text, "idle"); XCTAssertEqual(snapshot["queueCount"].int, 3)
        XCTAssertEqual(snapshot["queueEdit"]["editId"].text, "e1")

        let saved = try await session.saveQueueEdit(editID: "e1", text: "Rewritten follow-up")
        XCTAssertEqual(saved["outcome"].text, "saved")
        try await eventually { await client.count == 4 }
        try await eventually { !(await session.isRunning) }
        count = await client.count
        XCTAssertEqual(count, 4, "released once: steering, then each follow-up at its boundary")
        let requests = await client.requests
        XCTAssertEqual(userTexts(requests[1]), ["First", "Steer this"])
        XCTAssertEqual(userTexts(requests[3]).last, "Late")
        XCTAssertEqual(userTexts(requests[2]), ["First", "Steer this", "Rewritten follow-up"], "the rewrite, in its place; never the original")
        XCTAssertFalse(requests.flatMap { self.userTexts($0) }.contains("Original follow-up"))
        let history = await session.history
        let delivered = history.first { $0.id == "follow" }
        XCTAssertEqual(delivered?.displayText, "Rewritten follow-up")
        snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["queueCount"].int, 0); XCTAssertEqual(snapshot["state"].text, "idle")
        await session.close()
    }

    /// Delivery claimed the message first: Begin is refused, and nothing
    /// else changes. Both lanes.
    func testDeliveryThatClaimedTheMessageFirstWinsFollowUp() async throws { try await checkDeliveryWins(steer: false) }
    func testDeliveryThatClaimedTheMessageFirstWinsSteering() async throws { try await checkDeliveryWins(steer: true) }
    private func checkDeliveryWins(steer: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = HeldDeliveryTools(), client = ScriptClient([answer("one"), answer("two")], holdFirst: true)
        let session = try open(root, client: client, tools: tools)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "claimed", text: "Claimed"), steer: steer)
        await client.release()
        try await eventually { await tools.waiting }
        do { _ = try await session.beginQueueEdit(turnID: "claimed", editID: "late"); XCTFail("a message being delivered can't be edited") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_delivering") }
        let hold = await session.queueEdit
        XCTAssertNil(hold)
        await tools.release()
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.last.map { self.userTexts($0) }, ["First", "Claimed"])
        await session.close()
    }

    /// Begin wins while an all-mode batch is being delivered: the message
    /// already claimed finishes; none of the rest of the batch is sent.
    func testBeginDuringAnAllBatchStopsTheRestOfTheBatchFollowUp() async throws { try await checkBatch(steer: false) }
    func testBeginDuringAnAllBatchStopsTheRestOfTheBatchSteering() async throws { try await checkBatch(steer: true) }
    private func checkBatch(steer: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = HeldDeliveryTools(), client = ScriptClient([answer("one"), answer("two"), answer("three")], holdFirst: true)
        let session = try open(root, client: client, tools: tools)
        try await session.configureQueue(["steeringMode": "all", "followUpMode": "all"])
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        for name in ["x", "y", "z"] { _ = try await session.submit(Submission(commandID: "c-" + name, turnID: name, text: name.uppercased()), steer: steer) }
        await client.release()
        try await eventually { await tools.waiting }
        _ = try await session.beginQueueEdit(turnID: "z", editID: "e")
        await tools.release()
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(userTexts(requests[1]), ["First", "X"], "only the message claimed before the hold was delivered")
        let pending = (await session.queue) + (await session.steering)
        XCTAssertEqual(pending.map(\.turnID), ["y", "z"])
        _ = try await session.cancelQueueEdit(editID: "e")
        try await eventually { await client.count == 3 }
        try await eventually { !(await session.isRunning) }
        let last = await client.requests.last
        XCTAssertEqual(last.map { self.userTexts($0) }, ["First", "X", "Y", "Z"], "cancel keeps the original")
        await session.close()
    }

    /// A run started for pending input that a hold took before its first
    /// claim settles without asking the model about the old context.
    func testARunWhoseInputWasHeldBeforeItsFirstClaimMakesNoRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "next", text: "Next"), steer: false)
        _ = try await session.beginQueueEdit(turnID: "next", editID: "e")
        await session.stop(); await client.release()
        try await eventually { !(await session.isRunning) }
        // The launch that pending input makes, here with the hold already taken.
        await session.launch()
        try await eventually { !(await session.isRunning) }
        let count = await client.count
        XCTAssertEqual(count, 1, "no request about the old context")
        let queue = await session.queue
        XCTAssertEqual(queue.map(\.turnID), ["next"])
        let history = await session.history
        XCTAssertFalse(history.contains { $0.role == "assistant" && $0.id != history.first { $0.role == "assistant" }?.id }, "no new reply")
        await session.close()
    }

    /// Resume can't go around a hold; Stop during an edit keeps the queue
    /// paused after it resolves; Resume then sends it.
    func testResumeIsRefusedWhileHeldAndStopOutlivesTheEdit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two"), answer("three")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "q", text: "Queued"), steer: false)
        _ = try await session.beginQueueEdit(turnID: "q", editID: "e")
        await session.stop()
        try await eventually { !(await session.isRunning) }
        do { try await session.resumeQueue(); XCTFail("Resume must not bypass the hold") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_active") }
        do { try await session.reorderQueue(["q"]); XCTFail("reorder waits for the edit") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_active") }
        _ = try await session.saveQueueEdit(editID: "e", text: "Queued, revised")
        var count = await client.count
        XCTAssertEqual(count, 1, "the Stop pause survives the edit")
        let paused = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(paused["queuePaused"].flag, true)
        try await session.resumeQueue()
        try await eventually { await client.count == 2 }
        try await eventually { !(await session.isRunning) }
        count = await client.count
        XCTAssertEqual(count, 2)
        let last = await client.requests.last
        XCTAssertEqual(last.map { self.userTexts($0) }?.last, "Queued, revised")
        await session.close()
    }

    /// Each edit is recognised by its identity: a repeated Save answers as
    /// it did, a different one is refused, a late Cancel can't undo a Save,
    /// a late Save can't override a Cancel, and a new edit is a new identity.
    func testOutcomesAreRecognisedAcrossRepeatsAndLateCommands() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one")] + (0..<4).map { answer("more \($0)") }, holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha"), steer: false)
        _ = try await session.submit(Submission(commandID: "c2", turnID: "b", text: "Beta"), steer: false)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        do { _ = try await session.beginQueueEdit(turnID: "b", editID: "e2"); XCTFail("one edit per chat") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_busy") }
        do { try await session.updateQueued("b", text: "x"); XCTFail("no other rewrite while held") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_active") }
        _ = try await session.saveQueueEdit(editID: "e1", text: "Alpha 2")
        let repeated = try await session.saveQueueEdit(editID: "e1", text: "Alpha 2")
        XCTAssertEqual(repeated["repeated"].flag, true)
        do { _ = try await session.saveQueueEdit(editID: "e1", text: "Alpha 3"); XCTFail("a saved edit can't save other text") }
        catch let error as AgentError { XCTAssertEqual(error.code, "command_conflict") }
        do { _ = try await session.cancelQueueEdit(editID: "e1"); XCTFail("a late Cancel can't undo a Save") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_saved") }
        do { _ = try await session.beginQueueEdit(turnID: "a", editID: "e1"); XCTFail("a resolved edit doesn't start again") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_saved") }
        _ = try await session.beginQueueEdit(turnID: "b", editID: "e2")
        _ = try await session.cancelQueueEdit(editID: "e2")
        do { _ = try await session.saveQueueEdit(editID: "e2", text: "late"); XCTFail("a late Save can't override a Cancel") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_cancelled") }
        let status = try await session.queueEditStatus(editID: "e2")
        XCTAssertEqual(status["state"].text, "cancelled")
        try await assertEditState(session, "nobody", "unknown")
        let queue = await session.queue
        XCTAssertEqual(queue.map(\.text), ["Alpha 2", "Beta"])
        await session.close()
    }

    /// Removing the message being edited resolves the hold with it, in one
    /// step, through either command.
    func testRemovingTheHeldMessageResolvesTheHoldInOneStep() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two"), answer("three")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha"), steer: false)
        _ = try await session.submit(Submission(commandID: "c2", turnID: "b", text: "Beta"), steer: false)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        try await session.removeQueued("a")
        let hold = await session.queueEdit
        XCTAssertNil(hold)
        try await assertEditState(session, "e1", "removed")
        _ = try await session.beginQueueEdit(turnID: "b", editID: "e2")
        _ = try await session.removeQueueEdit(editID: "e2")
        await client.release()
        try await eventually { !(await session.isRunning) }
        let count = await client.count
        XCTAssertEqual(count, 1, "both removed; nothing sent")
        let snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["commands"].list.first { $0["turnId"].text == "a" }?["status"].text, "removed")
        await session.close()
    }

    /// A Save whose write fails keeps the original text and the hold; one
    /// that then succeeds goes on.
    func testAFailedWriteKeepsTheOriginalAndTheHold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let failure = HoldStateWriteFailure(), client = ScriptClient([answer("one"), answer("two")], holdFirst: true)
        let session = try open(root, client: client, failure: failure)
        try await pausedWithPending(session, client)
        failure.arm(true)
        do { _ = try await session.beginQueueEdit(turnID: "a", editID: "e0"); XCTFail("an unwritten hold isn't granted") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fixture_write") }
        var hold = await session.queueEdit
        XCTAssertNil(hold)
        failure.arm(false)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        failure.arm(true)
        for attempt in [{ _ = try await session.saveQueueEdit(editID: "e1", text: "Alpha 2") }, { _ = try await session.cancelQueueEdit(editID: "e1") }, { _ = try await session.removeQueueEdit(editID: "e1") }] {
            do { try await attempt(); XCTFail("the write was refused") } catch let error as AgentError { XCTAssertEqual(error.code, "fixture_write") }
            hold = await session.queueEdit
            XCTAssertEqual(hold?.editID, "e1", "the hold stays")
            let queue = await session.queue
            XCTAssertEqual(queue.map(\.text), ["Alpha"], "the original stays")
            try await assertEditState(session, "e1", "active")
        }
        failure.arm(false)
        _ = try await session.saveQueueEdit(editID: "e1", text: "Alpha 2")
        let queue = await session.queue
        XCTAssertEqual(queue.map(\.text), ["Alpha 2"])
        await session.close()
    }

    /// The hold and the outcomes are in the journal: a reopen after Begin
    /// finds the edit open and the queue paused; one after Save finds the
    /// rewrite saved and recognises the edit; nothing is sent either time.
    func testTheHoldAndItsOutcomeSurviveARestart() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha", thinkingLevel: "low"), steer: true)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        let sessionPath = await session.path
        let source = URL(fileURLWithPath: try XCTUnwrap(sessionPath))
        func crashCopy(_ name: String) throws -> URL {
            let dir = root.appendingPathComponent(name), copy = dir.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy); return copy
        }
        let afterBegin = try crashCopy("after-begin")
        _ = try await session.saveQueueEdit(editID: "e1", text: "Alpha 2")
        let afterSave = try crashCopy("after-save")
        await session.stop(); await client.release()
        try await eventually { !(await session.isRunning) }
        await session.close()

        let idle = ScriptClient([])
        let reopened = try open(root, client: idle, directory: "after-begin", resume: afterBegin.path)
        let status = try await reopened.queueEditStatus(editID: "e1")
        XCTAssertEqual(status["state"].text, "active"); XCTAssertEqual(status["text"].text, "Alpha"); XCTAssertEqual(status["kind"].text, "steering")
        do { try await reopened.resumeQueue(); XCTFail("still held") } catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_active") }
        _ = try await reopened.cancelQueueEdit(editID: "e1")
        var sent = await idle.count
        XCTAssertEqual(sent, 0, "a reopen pauses the queue; resolving the edit doesn't send it")
        await reopened.close()

        let second = try open(root, client: idle, directory: "after-save", resume: afterSave.path)
        try await assertEditState(second, "e1", "saved")
        let repeated = try await second.saveQueueEdit(editID: "e1", text: "Alpha 2")
        XCTAssertEqual(repeated["repeated"].flag, true, "a Save whose reply was lost is recognised after a restart")
        let steering = await second.steering
        XCTAssertEqual(steering.map(\.text), ["Alpha 2"]); XCTAssertEqual(steering.first?.thinkingLevel, "low"); XCTAssertEqual(steering.first?.commandID, "c1")
        sent = await idle.count
        XCTAssertEqual(sent, 0)
        await second.close()
    }

    /// Saved while the run still goes: the held work goes at its lane's
    /// usual boundary in that run, once.
    func testReleaseDuringARunGoesAtTheNextBoundaryOnce() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two"), answer("three")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha"), steer: false)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        _ = try await session.saveQueueEdit(editID: "e1", text: "Alpha 2")
        await client.release()
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(userTexts(requests[1]), ["First", "Alpha 2"])
        let history = await session.history
        XCTAssertEqual(history.filter { $0.id == "a" }.count, 1)
        await session.close()
    }

    /// A journal whose write may not have landed vouches for no edit: Begin
    /// and Status say so instead of answering from memory.
    func testAnUnsureJournalAnswersNoEditCommand() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        final class SyncFailure: @unchecked Sendable { private let lock = NSLock(); private var armed = false
            func arm() { lock.withLock { armed = true } }
            func check() throws { try lock.withLock { if armed { throw AgentError("fixture_sync", "fsync failed") } } } }
        let failure = SyncFailure(), client = ScriptClient([answer("one")], holdFirst: true)
        let session = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false,
                                       beforeJournalSynchronize: { try failure.check() })
        try await pausedWithPending(session, client)
        // The journal is confirmed on disk first; then the hold's own write fails.
        _ = try await session.queueEditStatus(editID: "nothing")
        failure.arm()
        do { _ = try await session.beginQueueEdit(turnID: "a", editID: "e1"); XCTFail("the hold's write failed") }
        catch let error as AgentError { XCTAssertEqual(error.code, AgentErrorCode.journalUncertain) }
        for attempt in [{ _ = try await session.beginQueueEdit(turnID: "a", editID: "e1") }, { _ = try await session.queueEditStatus(editID: "e1") }, { _ = try await session.saveQueueEdit(editID: "e1", text: "x") }] {
            do { try await attempt(); XCTFail("an unsure journal answers nothing as certain") }
            catch let error as AgentError { XCTAssertEqual(error.code, AgentErrorCode.journalUncertain) }
        }
        let hold = await session.queueEdit
        XCTAssertNotNil(hold, "the hold stays in memory: nothing waiting is claimed")
        await session.close()
    }

    /// A Cancel for an edit never granted is remembered, so a Begin with
    /// that identity arriving later can't take the hold; and once outcomes
    /// are forgotten, a Begin asked before them is refused as too old.
    func testCancelledAndForgottenIdentitiesCantTakeTheHold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one")], holdFirst: true)
        let session = try open(root, client: client)
        try await pausedWithPending(session, client)
        let early = try await session.cancelQueueEdit(editID: "lost")
        XCTAssertEqual(early["outcome"].text, "cancelled")
        do { _ = try await session.beginQueueEdit(turnID: "a", editID: "lost"); XCTFail("a cancelled identity can't begin") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_cancelled") }
        let basis = await session.queueEditRevision
        for index in 0..<(AgentSession.queueEditOutcomeLimit + 2) {
            let seen = await session.queueEditRevision
            _ = try await session.beginQueueEdit(turnID: "a", editID: "e\(index)", basis: seen)
            _ = try await session.cancelQueueEdit(editID: "e\(index)")
        }
        do { _ = try await session.beginQueueEdit(turnID: "a", editID: "stale", basis: basis); XCTFail("a Begin from before the forgotten outcomes is refused") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_expired") }
        do { _ = try await session.beginQueueEdit(turnID: "a", editID: "no-basis"); XCTFail("a Begin that says nothing of when it was asked is refused once outcomes are forgotten") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_expired") }
        let now = await session.queueEditRevision
        let fresh = try await session.beginQueueEdit(turnID: "a", editID: "fresh", basis: now)
        XCTAssertEqual(fresh["editId"].text, "fresh")
        let status = try await session.queueEditStatus(editID: "e0")
        XCTAssertEqual(status["held"]["editId"].text, "fresh", "every answer carries the hold as it stands")
        _ = try await session.cancelQueueEdit(editID: "fresh")
        await session.close()
    }

    /// Removing the message being edited releases only the hold: a Stop's
    /// pause stays, though nothing is left waiting.
    func testRemovingTheHeldMessageKeepsAStopPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one"), answer("two")], holdFirst: true)
        let session = try open(root, client: client)
        _ = try await session.submit(Submission(commandID: "c0", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "c1", turnID: "a", text: "Alpha"), steer: false)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        await session.stop(); await client.release()
        try await eventually { !(await session.isRunning) }
        _ = try await session.removeQueueEdit(editID: "e1")
        let snapshot = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(snapshot["queuePaused"].flag, true, "the Stop pause is not the edit's to release")
        XCTAssertEqual(snapshot["queueCount"].int, 0)
        await session.close()
    }

    /// A reopened journal whose last sync may have failed before a restart is
    /// forced to disk before any edit is answered; a failure says so.
    func testAReopenedJournalIsSyncedBeforeAnEditIsAnswered() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("one")], holdFirst: true)
        let session = try open(root, client: client)
        try await pausedWithPending(session, client)
        _ = try await session.beginQueueEdit(turnID: "a", editID: "e1")
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        await session.close()
        final class Failing: @unchecked Sendable { func check() throws { throw AgentError("fixture_sync", "fsync failed") } }
        let failing = Failing()
        let reopened = try AgentSession(id: "queue", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                        resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path,
                                        autoCompaction: false, beforeJournalSynchronize: { try failing.check() })
        do { _ = try await reopened.queueEditStatus(editID: "e1"); XCTFail("an unconfirmed journal answers nothing as certain") }
        catch let error as AgentError { XCTAssertEqual(error.code, AgentErrorCode.journalUncertain) }
        await reopened.close()
    }
}
