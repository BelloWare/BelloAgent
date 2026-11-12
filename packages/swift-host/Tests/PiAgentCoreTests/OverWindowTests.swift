import XCTest
@testable import PiAgentCore

// A request larger than the model's declared window, 0.1.138. The live case
// (2026-11-12, a Gemini model through LiteLLM, declared window 50,000): one
// reply asked for ten file reads at once; the next request measured 78,362
// tokens, went out with `max_output_tokens: 16`, and its 17-token reply, cut at
// that cap, was taken as the task's answer with the chat idle.
//
// What must stay (the request, steering, the newest batch of results) is never
// dropped, and a declared window can be conservative. So such a request goes
// out whole and with the model's ordinary output limit; the chat says once per
// task that it is over the window; a provider's refusal takes the overflow
// path; and a reply cut at the output limit ends its task as stopped early.

/// Records each turn request's body and the profile it was dispatched with,
/// and answers from a script. The request numbered `hold` (from 0) waits for
/// `release()`, so a test can stop the run while it is in flight.
private actor OverClient: ModelClient {
    enum Step { case reply(ModelReply), fail(AgentError) }
    var script: [Step]
    var sent: [(purpose: String, body: JSON, cap: Int?)] = []
    var hold: Int?
    init(_ script: [Step], hold: Int? = nil) { self.script = script; self.hold = hold }
    func release() { hold = nil }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let body = try ProviderClient.requestBody(profile: profile, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, compaction: purpose == "compaction")
        let index = sent.count
        sent.append((purpose, body, profile.wireOutputLimit))
        while hold == index { try await Task.sleep(for: .milliseconds(5)) }
        guard !script.isEmpty else { throw AgentError("fixture_exhausted", "Unexpected model request") }
        switch script.removeFirst() {
        case .fail(let error): throw error
        case .reply(var reply):
            let input = RequestContextCounter.projectedTokens(body)
            if reply.usage.isNull || reply.usage["input"].int == 100 {
                reply.usage = ["input": JSON(input), "output": 10, "inputIncludingCache": JSON(input), "total": JSON(input + 10)]
            }
            return reply
        }
    }
    var count: Int { sent.count }
}
/// Every read returns `chars` characters that name the call.
private actor LargeReads: ToolExecuting {
    let chars: Int
    var invoked: [String] = []
    init(chars: Int) { self.chars = chars }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("read", "test", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        invoked.append(call.id)
        return resultText("RESULT-\(call.id) " + String(repeating: "r", count: chars))
    }
}
private func reads(_ round: Int, _ count: Int) -> ModelReply {
    let calls = (0..<count).map { ToolCall(id: "c\(round)-\($0)", name: "read", arguments: ["path": JSON("f\(round)-\($0)")]) }
    var message = ChatMessage(role: "assistant", content: calls.map { ["type": "toolCall", "id": JSON($0.id), "name": JSON($0.name), "arguments": $0.arguments] })
    message.providerItems = calls.map { ["type": "function_call", "id": JSON("fc_" + $0.id), "call_id": JSON($0.id), "name": JSON($0.name), "arguments": JSON($0.arguments.encoded())] }
    return ModelReply(message: message, calls: calls, terminal: ModelTerminalOutcome(status: "completed"))
}
/// A reply the provider cut at the output limit the request carried.
private func cut(_ text: String) -> ModelReply {
    ModelReply(message: ChatMessage(role: "assistant", content: [textBlock(text)]), usage: ["input": 100, "output": 17, "inputIncludingCache": 100, "total": 117],
               truncated: true, terminal: ModelTerminalOutcome(status: "incomplete", incompleteReason: "max_output_tokens"))
}
private func outputs(_ body: JSON) -> [String] {
    body["input"].list.filter { $0["type"].text == "function_call_output" }.map { String(($0["output"].text ?? "").split(separator: " ").first ?? "") }
}
private func texts(_ body: JSON) -> String {
    body["input"].list.map { $0["content"].text ?? $0["content"].list.compactMap { $0["text"].text }.joined() + ($0["output"].text ?? "") }.joined(separator: "\n")
}

final class OverWindowTests: HelperTestCase {
    private let task = "OWNER-TASK: read the ten parts and list their markers."
    private let ceiling = 16_384
    /// The live case's shape: a 50,000-token window, a 16,384-token model ceiling.
    private func profile(window: Int = 50_000) throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["contextWindow"] = JSON(window); raw["maxOutputTokens"] = 8_192; raw["modelOutputLimit"] = JSON(ceiling)
        return try Profile(raw)
    }
    private func session(_ root: URL, _ client: OverClient, chars: Int = 28_000, resumePath: String? = nil) throws -> AgentSession {
        try AgentSession(id: "over", profile: profile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                         resources: Resources(cwd: root, home: root), client: client, tools: LargeReads(chars: chars), traces: TraceStore(), resumePath: resumePath)
    }
    private func settled(_ s: AgentSession) async throws -> JSON {
        try await eventually(timeout: .seconds(30)) { !(await s.isRunning) }
        return await s.snapshot()
    }
    /// The over-window notices of the chat: presentation rows, never replayed.
    private func notices(_ s: AgentSession) async -> [ChatMessage] {
        await s.history.filter { $0.kind == "execution" && ($0.detail ?? "").hasPrefix("Context · ") }
    }

    /// Ten reads in one batch: 70,000 tokens of results in a 50,000-token
    /// window, and nothing older to summarize.
    func testAnOversizeBatchGoesOutWholeWithTheOrdinaryOutputLimit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OverClient([.reply(reads(0, 10)), .reply(answer("part-01: amber"))])
        let s = try session(root, client)
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        let state = try await settled(s), sent = await client.sent
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        XCTAssertEqual(sent.map(\.purpose), ["turn", "turn"], "Nothing can be summarized: no summary request")
        let second = try XCTUnwrap(sent.last)
        XCTAssertGreaterThan(RequestContextCounter.projectedTokens(second.body), 50_000, "The fixture's request is over the window")
        XCTAssertEqual(outputs(second.body).count, 10, "Every result of the batch is sent"); XCTAssertTrue(texts(second.body).contains(task), "and the request as written")
        XCTAssertEqual(second.cap, ceiling, "The model's ordinary output limit, not one squeezed to the room a too-small window leaves")
        XCTAssertEqual(second.body["max_output_tokens"].int, ceiling)
        let rows = await notices(s), row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1, "One notice")
        let text = try XCTUnwrap(row.detail)
        XCTAssertFalse(row.replayEligible, "The notice is shown, never sent to the model")
        for needed in ["50,000-token window", "Nothing was summarized away", "sent whole", "may refuse it", "cut the reply short"] {
            XCTAssertTrue(text.contains(needed), "\(needed): \(text)")
        }
        let measured = await s.contextInfo()
        XCTAssertFalse(sent.contains { texts($0.body).contains("Nothing was summarized away") }, "No request carries the notice")
        XCTAssertEqual(measured["contextWindow"].int, 50_000)
        await s.close()
    }

    /// Three more rounds over the window, a Stop while one is in flight and a
    /// Resume: the task has said it once. The next task says it again.
    func testTheNoticeIsOncePerTaskAlsoAfterStopAndResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OverClient([.reply(reads(0, 10)), .reply(reads(1, 1)), .reply(reads(2, 1)), .reply(answer("First done.")), .reply(answer("Second done."))], hold: 2)
        let s = try session(root, client)
        _ = try await s.keep(whenFinished: false)
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        try await eventually(timeout: .seconds(30)) { await client.count == 3 }
        var rows = await notices(s)
        XCTAssertEqual(rows.count, 1, "Two requests over the window so far, one notice")
        await s.stop(); _ = try await settled(s)
        await client.release()
        _ = try await s.continueRun(commandID: "resume")
        var state = try await settled(s)
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        rows = await notices(s)
        XCTAssertEqual(rows.count, 1, "The resumed task does not say it again")
        _ = try await s.submit(Submission(commandID: "d", turnID: "next", text: "And now?"), steer: false)
        state = try await settled(s); rows = await notices(s)
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        XCTAssertEqual(rows.count, 2, "A new task whose first request is over the window says so for itself")
        XCTAssertEqual(Set(rows.compactMap(\.taskRootID)), ["task", "next"])
        await s.close()
    }

    /// A request that fitted fails for a passing reason, and steering that
    /// arrives during the wait makes the retried request another, larger
    /// one: it is said for that request as for any other.
    func testARetriedRequestThatSteeringMadeTooLargeSaysSoToo() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let busy = AgentError("provider_http", "HTTP 503 overloaded")
        let client = OverClient([.fail(busy), .reply(answer("Read it."))])
        let s = try session(root, client)
        await s.useRetrySettings(.init(enabled: true, maxRetries: 1, baseDelayMs: 1_500))
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        try await eventually(timeout: .seconds(30)) { await s.snapshot(["includeMessages": false])["runStatus"].text == "retrying" }
        _ = try await s.submit(Submission(commandID: "d", turnID: "steer", text: "Also this: " + String(repeating: "s", count: 240_000)), steer: true)
        let state = try await settled(s), sent = await client.sent, rows = await notices(s)
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        XCTAssertEqual(sent.count, 2); XCTAssertGreaterThan(RequestContextCounter.projectedTokens(try XCTUnwrap(sent.last).body), 50_000, "The retried request carries the steering")
        XCTAssertEqual(sent.last?.cap, ceiling)
        XCTAssertEqual(rows.count, 1, "The enlarged request is over the window, and the chat says so")
        await s.close()
    }

    /// The notice is in the journal: a reopened chat resumes the same task
    /// without saying it again.
    func testAReopenedChatDoesNotRepeatTheTasksNotice() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let refused = AgentError("provider_http", "HTTP 500 upstream unavailable")
        let client = OverClient([.reply(reads(0, 10)), .fail(refused)])
        let s = try session(root, client)
        _ = try await s.keep(whenFinished: false)
        await s.useRetrySettings(.init(enabled: false, maxRetries: 0, baseDelayMs: 1))
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        let failed = try await settled(s), path = await s.path, saved = try XCTUnwrap(path)
        XCTAssertEqual(failed["state"].text, "error")
        let before = await notices(s); XCTAssertEqual(before.count, 1)
        await s.close()
        try export(root, journal: saved)
        let later = OverClient([.reply(answer("Done after all."))])
        let reopened = try session(root, later, resumePath: saved)
        try await reopened.retryRun()
        let end = try await settled(reopened), after = await notices(reopened), sent = await later.sent
        XCTAssertEqual(end["state"].text, "idle", end["preflightError"].encoded())
        XCTAssertEqual(after.count, 1, "The task's notice is the one from before the reopen")
        XCTAssertEqual(sent.first?.cap, ceiling)
        await reopened.close()
    }

    /// For `scripts/older-reader-check.sh`: with `PI_OVERWINDOW_COMPAT_OUT`
    /// set, the failed chat (its journal with the notice's row, its
    /// checkpoint file and its connection) is left there for an earlier
    /// release's helper to open (`fixtures/native/older-reader/OlderReaderTests.swift`).
    private func export(_ root: URL, journal: String) throws {
        guard let out = ProcessInfo.processInfo.environment["PI_OVERWINDOW_COMPAT_OUT"], !out.isEmpty else { return }
        let target = URL(fileURLWithPath: out), state = root.appendingPathComponent("state")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: state, to: target.appendingPathComponent("state"))
        let relative = String(URL(fileURLWithPath: journal).standardizedFileURL.path.dropFirst(state.standardizedFileURL.path.count + 1))
        try JSON.object(["journal": JSON(relative), "profile": try profile().raw]).data().write(to: target.appendingPathComponent("export.json"))
    }

    /// The provider's real window is the declared one: its refusal is the
    /// overflow it always was. Recovery cannot plan around required rows, so
    /// the run ends on the provider's error, and no tool runs again.
    func testAProviderRefusalOfTheOversizeRequestTakesTheOverflowPath() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let rejected = AgentError("provider_http", "HTTP 400 rejected input", failure: .inputContextExceeded)
        let client = OverClient([.reply(reads(0, 10)), .fail(rejected)])
        let tools = LargeReads(chars: 28_000)
        let s = try AgentSession(id: "over", profile: profile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                 resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore())
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        let state = try await settled(s), sent = await client.sent, invoked = await tools.invoked, rows = await notices(s)
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "provider_http")
        XCTAssertEqual(sent.map(\.purpose), ["turn", "turn"], "Nothing to summarize for the recovery either")
        XCTAssertEqual(sent.last?.cap, ceiling); XCTAssertEqual(invoked.count, 10, "Each read ran once")
        XCTAssertEqual(rows.count, 1)
        await s.close()
    }

    /// The owner turned automatic compaction off: the meter shows the fill,
    /// and nothing claims a summary was considered. The cap rule is the same.
    func testWithoutAutomaticCompactionTheRequestStillGoesWholeAndNothingIsSaid() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OverClient([.reply(reads(0, 10)), .reply(answer("Done."))])
        let s = try AgentSession(id: "over", profile: profile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                 resources: Resources(cwd: root, home: root), client: client, tools: LargeReads(chars: 28_000), traces: TraceStore(), autoCompaction: false)
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        let state = try await settled(s), sent = await client.sent, rows = await notices(s)
        XCTAssertEqual(state["state"].text, "idle"); XCTAssertEqual(sent.last?.cap, ceiling); XCTAssertTrue(rows.isEmpty)
        await s.close()
    }

    /// A reply cut at the output limit is a row that says so, and its task
    /// ends as stopped early: the chat is idle, and its state names why.
    func testAReplyCutAtTheOutputLimitEndsItsTaskAsStoppedEarly() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OverClient([.reply(cut("uniqueItems:[] }")), .reply(answer("Whole answer."))])
        let s = try session(root, client)
        _ = try await s.submit(Submission(commandID: "c", turnID: "task", text: task), steer: false)
        var state = try await settled(s)
        let last = await s.history.last { $0.role == "assistant" }
        XCTAssertEqual(last?.stopReason, "length", "The reply's row says it stopped at the output limit")
        XCTAssertEqual(state["state"].text, "idle"); XCTAssertEqual(state["runStatus"].text, "idle")
        XCTAssertEqual(state["taskPresentation"]["recent"].list.last?["outcome"].text, "output-limited", "The task did not complete")
        XCTAssertEqual(state["stoppedEarly"].text, "output-limit", "The idle chat's state says its last task stopped early")
        _ = try await s.submit(Submission(commandID: "d", turnID: "next", text: "Continue."), steer: false)
        state = try await settled(s)
        XCTAssertEqual(state["taskPresentation"]["recent"].list.last?["outcome"].text, "completed")
        XCTAssertTrue(state["stoppedEarly"].isNull, "A task that completes says nothing of the kind")
        await s.close()
    }
}

/// The output limit a conversation request carries (`RequestContextCounter`):
/// the model's ceiling clipped to the room the estimate leaves in the window,
/// while that room still holds a reply.
final class OutputCapFloorTests: HelperTestCase {
    private func cap(window: Int = 100_000, reserve: Int = 8_192, ceiling: Int? = 64_000, taskCap: Int? = nil, characters: Int) throws -> (cap: Int?, tokens: Int) {
        var raw = try fixtureProfile().raw
        raw["contextWindow"] = JSON(window); raw["maxOutputTokens"] = JSON(reserve)
        if let ceiling { raw["modelOutputLimit"] = JSON(ceiling) }
        if let taskCap { raw["outputCap"] = JSON(taskCap) }
        let profile = try Profile(raw)
        var user = ChatMessage(role: "user", content: [textBlock(String(repeating: "x", count: characters))]); user.id = "u"
        let count = try RequestContextCounter().count(messages: [user], profile: profile)
        return (count.outputCap, count.requestTokens)
    }
    func testTheCeilingIsClippedToTheRoomWhileTheRoomHoldsAReply() throws {
        // 80,000 tokens of input: 100,000 − 4,096 − 80,000 = 15,904 of room.
        let roomy = try cap(characters: 320_000)
        XCTAssertEqual(roomy.tokens, 80_000); XCTAssertEqual(roomy.cap, 15_904, "pi's clampMaxTokensToContext, unchanged")
        // Exactly the least room is still clipped to.
        XCTAssertEqual(try cap(characters: 4 * (100_000 - 4_096 - 4_096)).cap, 4_096)
        XCTAssertEqual(try cap(characters: 4_000).cap, 64_000, "A short chat carries the ceiling")
        // A reserve smaller than 4,096 says a reply needs less: the clip holds down to it.
        XCTAssertEqual(try cap(reserve: 2_000, characters: 4 * (100_000 - 4_096 - 2_000)).cap, 2_000)
    }
    func testARoomTooSmallForAReplyIsNotClippedTo() throws {
        // One token less than the least room: the declared window is not what decides.
        XCTAssertEqual(try cap(characters: 4 * (100_000 - 4_096 - 4_095)).cap, 64_000)
        XCTAssertEqual(try cap(reserve: 2_000, characters: 4 * (100_000 - 4_096 - 1_999)).cap, 64_000)
        XCTAssertEqual(try cap(characters: 4 * 99_000).cap, 64_000, "Inside the window, with no room left by the estimate")
        XCTAssertEqual(try cap(characters: 4 * 160_000).cap, 64_000, "Over the window: never the 16 tokens pi sends")
    }
    func testASmallCeilingAndATasksOwnCapAreSentAsTheyAre() throws {
        XCTAssertEqual(try cap(ceiling: 3_000, characters: 4 * 90_000).cap, 3_000, "5,904 of room holds the whole ceiling")
        XCTAssertEqual(try cap(ceiling: 3_000, characters: 4 * 93_000).cap, 3_000, "2,904 of room is less than the ceiling: not squeezed below it")
        XCTAssertEqual(try cap(ceiling: 64_000, taskCap: 256, characters: 4 * 160_000).cap, 256, "A bounded task's own cap")
        XCTAssertNil(try cap(ceiling: nil, characters: 4 * 160_000).cap, "No ceiling, no limit")
    }
}
