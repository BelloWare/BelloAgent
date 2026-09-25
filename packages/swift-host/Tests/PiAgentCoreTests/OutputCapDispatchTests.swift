import XCTest
@testable import PiAgentCore

/// The output budget is metadata: a local reserve that decides when a chat
/// compacts and never a cap on the wire. A conversation request carries the
/// model's catalog ceiling, clipped as pi's clampMaxTokensToContext clips it
/// (window − pi's estimate − 4,096, at least 1); bounded tasks carry their own
/// small caps. Like pi, no estimate ever stops a turn before its request.
final class OutputCapDispatchTests: XCTestCase {
    private func session(_ client: ScriptClient, profile: Profile, root: URL, autoCompaction: Bool = false, titleTask: Bool = false) throws -> AgentSession {
        try AgentSession(id: "cap", profile: profile, apiKey: "synthetic-cap-fixture-secret", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                         resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: autoCompaction, titleTask: titleTask)
    }
    private func body(_ profile: Profile) throws -> JSON {
        try ProviderClient.requestBody(profile: profile, messages: [], instructions: "", tools: [], sessionID: "cap")
    }

    func testAConversationTurnSendsTheModelCeilingNotTheBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw; raw["modelOutputLimit"] = 65_536   // the budget stays at 4,096
        let client = ScriptClient([answer("long reply")])
        let session = try session(client, profile: try Profile(raw), root: root)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: "write a lot"), steer: false)
        try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles; let sent = try XCTUnwrap(profiles.first)
        XCTAssertEqual(sent.maxOutput, 4_096, "the budget travels as metadata")
        XCTAssertEqual(sent.wireOutputLimit, 65_536, "the ceiling is the cap")
        XCTAssertEqual(try body(sent)["max_output_tokens"].int, 65_536)
        let context = await session.contextInfo()
        XCTAssertEqual(context["outputCap"].int, 65_536); XCTAssertEqual(context["outputBudget"].int, 4_096)
        await session.close()
    }

    func testWithoutACeilingNoCapIsSentAndTheBudgetStillIsNot() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("reply")], holdFirst: true)
        let session = try session(client, profile: try fixtureProfile(), root: root)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: "hello"), steer: false)
        try await eventually { await client.count == 1 }
        // The live count, inspected while the request is held, is the one the dispatch used.
        let context = await session.inspectContext()["context"]
        XCTAssertTrue(context["outputCap"].isNull)
        XCTAssertTrue(context["warnings"].list.contains { $0.text?.contains("no output ceiling") == true }, context["warnings"].encoded())
        await client.release(); try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles; let sent = try XCTUnwrap(profiles.first)
        XCTAssertNil(sent.wireOutputLimit); XCTAssertTrue(try body(sent)["max_output_tokens"].isNull)
        await session.close()
    }

    func testTheCapIsClippedToTheRoomTheWindowLeavesAndTheReserveNeverStopsATurn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 16_000; raw["maxOutputTokens"] = 13_000; raw["modelOutputLimit"] = 14_000
        let client = ScriptClient([answer("fits")], holdFirst: true)
        let session = try session(client, profile: try Profile(raw), root: root)   // no automatic compaction
        // About 3,000 tokens of input: beside a 13,000 reserve it would not fit, on its own it does.
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: String(repeating: "x", count: 12_000)), steer: false)
        try await eventually { await client.count == 1 }
        let context = await session.inspectContext()["context"]
        await client.release(); try await eventually { !(await session.isRunning) }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        let profiles = await client.profiles; let sent = try XCTUnwrap(profiles.first)
        XCTAssertEqual(context["fits"].flag, false); XCTAssertEqual(context["inputFits"].flag, true)
        let cap = try XCTUnwrap(sent.wireOutputLimit), sized = try XCTUnwrap(context["requestTokens"].int)
        XCTAssertEqual(cap, context["outputCap"].int)
        XCTAssertEqual(context["tokens"].int, 3_000, "the meter reads pi's figure: 12,000 characters over four")
        XCTAssertEqual(context["requestMethod"].text, "characters", "no reply has measured this request yet")
        XCTAssertEqual(cap, 16_000 - sized - 4_096, "clampMaxTokensToContext: the window less pi's estimate and 4,096")
        XCTAssertLessThan(cap, 14_000); XCTAssertGreaterThan(cap, 0)
        XCTAssertEqual(try body(sent)["max_output_tokens"].int, cap)
        await session.close()
    }

    func testInputBeyondTheWindowIsStillSentWithTheSixteenTokenCapPiSends() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 4_000; raw["maxOutputTokens"] = 1_000; raw["modelOutputLimit"] = 5_000
        let client = ScriptClient([answer("the gateway decides")])
        let session = try session(client, profile: try Profile(raw), root: root)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: String(repeating: "x", count: 15_000)), steer: false)
        try await eventually { !(await session.isRunning) }
        let snapshot = await session.snapshot(); let requests = await client.count
        XCTAssertEqual(requests, 1, "pi never refuses a request on its estimate; the gateway decides")
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        let profiles = await client.profiles
        XCTAssertEqual(try XCTUnwrap(profiles.first).wireOutputLimit, 16, "clampMaxTokensToContext leaves one token, and buildParams sends at least 16")
        await session.close()
    }

    /// The reported failure: "Estimated request input plus the safety margin
    /// exceeds configured capacity" on a chat pi measures well inside the
    /// window, because the whole request's UTF-8 bytes over three (JSON escapes
    /// included) sized it instead of pi's estimate.
    func testAChatPiMeasuresInsideTheWindowIsSentWhateverItsBytes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 32_000; raw["maxOutputTokens"] = 2_000; raw["modelOutputLimit"] = 8_000
        let pasted = String(repeating: "{\"k\": \"v\"}\n", count: 9_000)   // 99,000 characters, 144,000 bytes once JSON escapes them
        let measured = ModelReply(message: ChatMessage(role: "assistant", content: [textBlock("read it")]),
                                  usage: ["input": 25_000, "output": 5, "inputIncludingCache": 25_000])
        let client = ScriptClient([measured, answer("second")])
        let session = try session(client, profile: try Profile(raw), root: root)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: pasted), steer: false)
        try await eventually { !(await session.isRunning) }
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        _ = try await session.submit(Submission(commandID: "b", turnID: "b", text: "and now?"), steer: false)
        try await eventually { !(await session.isRunning) }
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        let requests = await client.count, profiles = await client.profiles, sentMessages = await client.requests, instructions = await client.instructions
        XCTAssertEqual(requests, 2)
        guard requests == 2 else { return }
        // First request: nothing measured yet, so the rows' characters over four plus the prefix.
        let firstBody = try ProviderClient.requestBody(profile: profiles[0], messages: sentMessages[0], instructions: instructions[0],
                                                       tools: await session.sessionDefinitions(), sessionID: "cap")
        let firstSized = RequestContextCounter.projectedTokens(firstBody)
        XCTAssertEqual(profiles[0].wireOutputLimit, min(8_000, 32_000 - firstSized - 4_096))
        // Second request: the reply's reported 25,005 plus "and now?" (8 characters, 2 tokens).
        XCTAssertEqual(profiles[1].wireOutputLimit, min(8_000, 32_000 - 25_015 - 4_096))
        let context = await session.contextInfo()
        XCTAssertEqual(context["requestMethod"].text, "last-reply-usage", context.encoded())
        await session.close()
    }

    func testPreparedRequestUsesTheSameClippedCeilingAsDispatch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 6000; raw["maxOutputTokens"] = 2500; raw["modelOutputLimit"] = 5000
        let client = ScriptClient([answer("fits")])
        let session = try session(client, profile: Profile(raw), root: root)
        let text = String(repeating: "x", count: 12000)
        let preview = try await session.prepareContext(["text": JSON(text)])
        let page = try await session.readPreparedContext(["revision": preview["revision"], "section": "request"])
        let prepared = try JSON.parse(Data(try XCTUnwrap(page["text"].text).utf8))
        XCTAssertEqual(prepared["max_output_tokens"], preview["count"]["outputCap"], "The displayed full request and its count must name the same output cap")
        _ = try await session.submit(Submission(commandID: "send", turnID: "send", text: text), steer: false)
        try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles, requests = await client.requests, instructions = await client.instructions
        let dispatched = try ProviderClient.requestBody(profile: XCTUnwrap(profiles.first), messages: XCTUnwrap(requests.first), instructions: XCTUnwrap(instructions.first), tools: await session.sessionDefinitions(), sessionID: "cap")
        XCTAssertTrue(prepared == dispatched, "The prepared request must show the request that will actually be sent")
        await session.close()
    }

    func testATitleTaskSendsItsSmallBudgetAsItsCap() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw; raw["modelOutputLimit"] = 16_000
        let client = ScriptClient([answer("A short title")])
        let session = try session(client, profile: try Profile(raw), root: root, titleTask: true)
        var submission = Submission(commandID: "t", turnID: "t", text: "Summarize"); submission.model = "mini-fixture"; submission.contextWindow = 16_000; submission.maxOutputTokens = 512
        _ = try await session.submit(submission, steer: false)
        try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles; let sent = try XCTUnwrap(profiles.first)
        XCTAssertEqual(sent.wireOutputLimit, 512, "a bounded task keeps its explicit cap")
        XCTAssertEqual(try body(sent)["max_output_tokens"].int, 512)
        await session.close()
    }
}
