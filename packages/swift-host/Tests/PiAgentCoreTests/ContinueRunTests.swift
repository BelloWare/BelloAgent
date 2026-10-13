import XCTest
@testable import PiAgentCore

/// A model client that plays one step per request: a reply, a reply held
/// until released, or a reply that streams some text and then never ends
/// (until the run is stopped).
private actor ContinueClient: ModelClient {
    enum Step { case reply(ModelReply), held(ModelReply), streamForever(String) }
    private var steps: [Step]
    private var released = false
    private(set) var requests: [[ChatMessage]] = [], turns: [String] = [], streamed = 0
    init(_ steps: [Step]) { self.steps = steps }
    func release() { released = true }
    var count: Int { requests.count }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests.append(messages); turns.append(turnID)
        guard !steps.isEmpty else { throw AgentError("fixture_exhausted", "Unexpected model request") }
        switch steps.removeFirst() {
        case .reply(let reply): return reply
        case .held(let reply):
            while !released { try await Task.sleep(nanoseconds: 2_000_000) }
            return reply
        case .streamForever(let text):
            try await onDelta(.text(text)); streamed += 1
            while true { try await Task.sleep(nanoseconds: 2_000_000) }
        }
    }
}

/// The run-state records a session writes, in order.
private final class RecordedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [JSON] = []
    func add(_ record: JSON) { lock.lock(); records.append(record); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    func states(from index: Int) -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        return records[index...].filter { $0["customType"].text == "pi-app.native.state.v1" }.map { $0["data"] }
    }
}

/// Tools that run until they are stopped: a call cut off mid-run.
private actor EndlessTools: ToolExecuting {
    private(set) var started: [String] = []
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "test", [:]), ToolDefinition("second", "test", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        started.append(call.name)
        while true { try await Task.sleep(nanoseconds: 2_000_000) }
    }
}

/// Resume (`run.continue`, pi's continue): a stopped, cut-off or failed run
/// goes on from the chat's history with no new user message. A cut-off tool
/// call is never run again; its recorded result goes to the model.
final class ContinueRunTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile
        func session(_ client: any ModelClient, tools: any ToolExecuting = RecordingTools(), resume: String? = nil) throws -> AgentSession {
            try AgentSession(id: "resume", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false,
                             resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(),
                             resumePath: resume, autoCompaction: false)
        }
        var journal: String { state.appendingPathComponent("resume.jsonl").path }
    }
    private func chat() throws -> Chat {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile())
    }
    private func stopped(_ session: AgentSession) async throws {
        await session.stop()
        try await eventually { !(await session.isRunning) }
    }
    private func errorCode(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch { return (error as? AgentError)?.code ?? "\(error)" }
    }

    /// Stopped while its tool ran: the tool is not run again, and the
    /// continuation's request ends with that call's interrupted result.
    func testResumeAfterAStopMidToolSendsTheInterruptedResultAndNeverRerunsTheTool() async throws {
        let chat = try chat(), client = ContinueClient([.reply(toolReply(["first"])), .reply(answer("Picked up after the stop"))]), tools = EndlessTools()
        let session = try chat.session(client, tools: tools)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Edit the file"), steer: false)
        try await eventually { await tools.started.count == 1 }
        try await stopped(session)
        var state = await session.snapshot()
        XCTAssertEqual(state["state"].text, "paused")
        XCTAssertEqual(state["continuable"].flag, true, "a stopped tool batch is something the model has not answered")

        let accepted = try await session.continueRun(commandID: "resume-1")
        XCTAssertEqual(accepted["continued"].flag, true)
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests, turns = await client.turns
        XCTAssertEqual(requests.count, 2)
        let started = await tools.started
        XCTAssertEqual(started, ["first"], "the cut-off tool is never run again")
        let tail = try XCTUnwrap(requests[1].last)
        XCTAssertEqual(tail.role, "toolResult")
        XCTAssertEqual(tail.isError, true)
        XCTAssertTrue(tail.text.contains("Tool interrupted"), tail.text)
        XCTAssertFalse(requests[1].contains { $0.role == "user" && $0.text != "Edit the file" }, "no new user message")
        XCTAssertEqual(requests[1].filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(turns, ["t1", "t1"], "the continuation belongs to the turn it continues")
        let history = await session.history
        XCTAssertEqual(history.last?.text, "Picked up after the stop")
        XCTAssertEqual(history.last?.turn, "t1")
        state = await session.snapshot()
        XCTAssertEqual(state["state"].text, "idle")
        XCTAssertEqual(state["continuable"].flag, false, "an answered chat has nothing to resume")
        XCTAssertEqual(state["commands"].list.first { $0["commandId"].text == "resume-1" }?["state"].text, "completed")
        await session.close()
    }

    /// Stopped mid-stream: the cut-off reply stays as its interrupted row and
    /// is never sent again; the continuation is a new reply after it.
    func testResumeAfterAStopMidStreamKeepsTheCutOffReplyAndAnswersAfterIt() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Half an ans"), .reply(answer("The whole answer"))])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Explain the loop"), steer: false)
        try await eventually { await client.streamed == 1 }
        try await stopped(session)
        _ = try await session.continueRun(commandID: "resume-1")
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].map(\.role), ["user"], "the interrupted reply is not part of the request")
        let assistants = await session.history.filter { $0.role == "assistant" }
        XCTAssertEqual(assistants.map(\.text), ["Half an ans", "The whole answer"])
        XCTAssertEqual(assistants.first?.stopReason, "interrupted")
        XCTAssertEqual(assistants.first?.replayEligible, false)
        await session.close()
    }

    /// One Resume runs once: the same command again answers from its receipt
    /// (also after the chat is reopened from its journal), and a second
    /// Resume while the first runs is refused as busy.
    func testResumeIsIdempotentByCommandAndASecondResumeWhileRunningIsRefused() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Cut"), .held(answer("Resumed")), .reply(answer("Follow-up answered"))])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Question"), steer: false)
        try await eventually { await client.streamed == 1 }
        try await stopped(session)
        _ = try await session.continueRun(commandID: "resume-1")
        try await eventually { await client.count == 2 }
        let busy = await errorCode { _ = try await session.continueRun(commandID: "resume-2") }
        XCTAssertEqual(busy, "session_busy", "a double click or a Resume racing another is refused while one runs")
        let again = try await session.continueRun(commandID: "resume-1")
        XCTAssertEqual(again["duplicate"].flag, true)
        // A message sent meanwhile waits behind the resumed run.
        let sent = try await session.submit(Submission(commandID: "c2", turnID: "t2", text: "And then?"), steer: false)
        XCTAssertEqual(sent["queued"].flag, true)
        await client.release()
        try await eventually { !(await session.isRunning) }
        let count = await client.count
        XCTAssertEqual(count, 3, "the resumed run, then the follow-up; never a second continuation")
        let afterwards = try await session.continueRun(commandID: "resume-1")
        XCTAssertEqual(afterwards["duplicate"].flag, true)
        let unchanged = await client.count
        XCTAssertEqual(unchanged, 3)
        await session.close()
    }

    /// The receipt is saved before the run starts: a helper that died after
    /// taking the command (the app's reply lost) finds it in the journal and
    /// runs nothing when the same command comes again.
    func testAResumeSentAgainAfterTheHelperRestartedRunsNothing() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Cut"), .streamForever("Cut again")])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Question"), steer: false)
        try await eventually { await client.streamed == 1 }
        try await stopped(session)
        _ = try await session.continueRun(commandID: "resume-1")
        try await eventually { await client.streamed == 2 }
        await session.close()
        let later = ContinueClient([.reply(answer("Should not run"))])
        let reopened = try chat.session(later, resume: chat.journal)
        let state = await reopened.snapshot()
        XCTAssertEqual(state["state"].text, "paused")
        let again = try await reopened.continueRun(commandID: "resume-1")
        XCTAssertEqual(again["duplicate"].flag, true)
        let requests = await later.count
        XCTAssertEqual(requests, 0, "the same Resume never runs twice")
        await reopened.close()
    }

    /// A restart cut a tool call off before its result was saved: the reopen
    /// records its outcome as unknown, and Resume sends that to the model
    /// without running the tool.
    func testResumeAfterARestartAnswersTheUnknownToolOutcomeWithoutRunningIt() async throws {
        let chat = try chat()
        var journal: SessionJournal? = try SessionJournal(url: URL(fileURLWithPath: chat.journal), id: "resume", cwd: chat.root, binding: chat.profile.binding, create: true)
        var question = ChatMessage(role: "user", content: [textBlock("Write the file")]); question.id = "t1"; question.turn = "t1"
        try journal?.append(["type": "message", "message": question.pi], id: question.id)
        var call = toolReply(["first"]).message; call.turn = "t1"
        try journal?.append(["type": "message", "message": call.pi], id: call.id)
        journal = nil
        let client = ContinueClient([.reply(answer("Checked the file instead"))]), tools = RecordingTools()
        let session = try chat.session(client, tools: tools, resume: chat.journal)
        let state = await session.snapshot()
        XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(state["continuable"].flag, true)
        let before = await client.count
        XCTAssertEqual(before, 0, "nothing runs until Resume")
        _ = try await session.continueRun(commandID: "resume-1")
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests, calls = await tools.calls
        XCTAssertEqual(calls, [], "the interrupted call is never run")
        let tail = try XCTUnwrap(requests.first?.last)
        XCTAssertEqual(tail.role, "toolResult")
        XCTAssertTrue(tail.text.contains("Outcome unknown"), tail.text)
        await session.close()
    }

    /// Follow-ups queued behind a stop go after the resumed run, as after any run.
    func testQueuedFollowUpsGoAfterTheResumedRun() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Cut"), .reply(answer("Finished the first")), .reply(answer("Answered the follow-up"))])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "First"), steer: false)
        try await eventually { await client.streamed == 1 }
        _ = try await session.submit(Submission(commandID: "c2", turnID: "t2", text: "Second"), steer: false)
        try await stopped(session)
        let waiting = await session.snapshot()["queueCount"].int
        XCTAssertEqual(waiting, 1)
        // What an update's quiesce reads: not idle, but held for Resume.
        let idle = await session.isIdle, held = await session.isHeldForResume
        XCTAssertFalse(idle); XCTAssertTrue(held)
        _ = try await session.continueRun(commandID: "resume-1")
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].filter { $0.role == "user" }.map(\.text), ["First"], "the continuation comes first")
        XCTAssertEqual(requests[2].filter { $0.role == "user" }.map(\.text), ["First", "Second"])
        let left = await session.snapshot()["queueCount"].int
        XCTAssertEqual(left, 0)
        await session.close()
    }

    /// Nothing unanswered: Resume sends what waits (pi's continue from an
    /// assistant reply), or is refused when nothing does.
    func testAnAnsweredChatResumesOnlyWhatWaitsOrRefuses() async throws {
        let chat = try chat(), client = ContinueClient([.reply(answer("Done"))])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "First"), steer: false)
        try await eventually { !(await session.isRunning) }
        let nothing = await errorCode { _ = try await session.continueRun(commandID: "resume-1") }
        XCTAssertEqual(nothing, AgentErrorCode.nothingToContinue)
        await session.close()
        // Answered, with a follow-up paused behind it (as a restart leaves one).
        var journal: SessionJournal? = try SessionJournal(url: URL(fileURLWithPath: chat.journal), id: "resume", cwd: chat.root, binding: chat.profile.binding, create: false)
        let waiting = try JSON.parse(JSONEncoder().encode(Submission(commandID: "c2", turnID: "t2", text: "Second")))
        try journal?.append(["type": "custom", "customType": "pi-app.native.state.v1",
                             "data": ["active": false, "queue": .array([waiting]), "steering": .array([]), "runStatus": "cancelled", "queuePaused": true]])
        journal = nil
        let later = ContinueClient([.reply(answer("Follow-up done"))])
        let reopened = try chat.session(later, resume: chat.journal)
        let state = await reopened.snapshot()
        XCTAssertEqual(state["continuable"].flag, false); XCTAssertEqual(state["queuePaused"].flag, true)
        let resumed = try await reopened.continueRun(commandID: "resume-2")
        XCTAssertEqual(resumed["resumedQueue"].flag, true)
        try await eventually { !(await reopened.isRunning) }
        // Its receipt settles the app's record, and the same command again releases nothing.
        let receipt = await reopened.snapshot()["commands"].list.first { $0["commandId"].text == "resume-2" }
        XCTAssertEqual(receipt?["turnId"].text, "continue:resume-2")
        let again = try await reopened.continueRun(commandID: "resume-2")
        XCTAssertEqual(again["duplicate"].flag, true)
        let requests = await later.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.last?.text, "Second")
        await reopened.close()
    }

    /// The Resume is saved as a run under way, receipt included, before its
    /// run starts: a helper that dies before the run's own first record
    /// leaves the chat interrupted (Resume offered again), never idle.
    func testAnAcceptedResumeIsSavedAsARunUnderWay() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Cut"), .reply(answer("Resumed"))])
        let records = RecordedStates()
        let session = try AgentSession(id: "resume", profile: chat.profile, apiKey: "fixture", cwd: chat.root, directory: chat.state, readOnly: false,
                                       resources: Resources(cwd: chat.root, home: chat.root), client: client, tools: RecordingTools(), traces: TraceStore(),
                                       autoCompaction: false, beforeJournalAppend: { records.add($0) })
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Question"), steer: false)
        try await eventually { await client.streamed == 1 }
        try await stopped(session)
        let before = records.count
        _ = try await session.continueRun(commandID: "resume-1")
        let first = try XCTUnwrap(records.states(from: before).first, "the Resume wrote a run state")
        XCTAssertEqual(first["active"].flag, true)
        XCTAssertTrue(first["commands"].list.contains { $0["commandId"].text == "resume-1" })
        try await eventually { !(await session.isRunning) }
        await session.close()
    }

    /// A Resume stopped before its run began leaves nothing behind: the next
    /// message is answered as itself, not after another continuation.
    func testAResumeStoppedAtOnceDoesNotLeakIntoTheNextRun() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Cut"), .streamForever("Cut again"), .reply(answer("New answer")), .reply(answer("Extra"))])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Question"), steer: false)
        try await eventually { await client.streamed == 1 }
        try await stopped(session)
        _ = try await session.continueRun(commandID: "resume-1")
        await session.stop()
        try await eventually { !(await session.isRunning) }
        let before = await client.count
        _ = try await session.submit(Submission(commandID: "c2", turnID: "t2", text: "New message"), steer: false)
        try await eventually { await client.count > before }
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, before + 1, "one request for the new message")
        XCTAssertEqual(requests.last?.last?.text, "New message")
        await session.close()
    }

    /// At the chat's cost limit, Resume stops at once with the cost-limit
    /// notice the app draws, before any model request.
    func testResumeAtTheCostLimitStopsWithTheCostLimitNotice() async throws {
        let chat = try chat(), client = ContinueClient([.streamForever("Cut")])
        let session = try chat.session(client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Question"), steer: false)
        try await eventually { await client.streamed == 1 }
        try await stopped(session)
        await session.setCostLimit(0)
        _ = try await session.continueRun(commandID: "resume-1")
        try await eventually { !(await session.isRunning) }
        let state = await session.snapshot(), requests = await client.count
        XCTAssertEqual(requests, 1, "no model request at the limit")
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "cost_limit")
        XCTAssertEqual(state["commands"].list.first { $0["commandId"].text == "resume-1" }?["state"].text, "failed")
        await session.close()
    }

    /// The host routes `run.continue` with its command identity, and an
    /// update's quiesce takes a stopped chat.
    func testTheHostRoutesContinueAndQuiesceTakesAStoppedChat() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)])
        _ = try await host.command("session.open", sessionID: "s", params: ["profile": try fixtureProfile().raw, "apiKey": "fixture"])
        let nothing: String?
        do { _ = try await host.command("run.continue", sessionID: "s", params: [:], commandID: "r1"); nothing = nil }
        catch { nothing = (error as? AgentError)?.code }
        XCTAssertEqual(nothing, AgentErrorCode.nothingToContinue, "a new chat has nothing to resume")
        _ = try await host.command("turn.stop", sessionID: "s", params: [:])
        let quiesced = try await host.command("workspace.quiesce", sessionID: nil, params: [:])
        XCTAssertEqual(quiesced["quiesced"].flag, true, "a paused chat does not block an update")
        await host.shutdown()
    }
}
