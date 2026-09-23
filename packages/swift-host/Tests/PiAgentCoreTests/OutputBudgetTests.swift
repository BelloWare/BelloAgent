import XCTest
@testable import PiAgentCore

final class OutputBudgetTests: XCTestCase {
    /// The budget is metadata for the local estimate; the model's ceiling is the
    /// cap a conversation request carries, and a bounded task's explicit cap wins.
    func testTheCeilingReachesTheWireAndTheBudgetNeverDoes() throws {
        var raw = try fixtureProfile().raw
        raw["modelOutputLimit"] = 65_536
        let profile = try Profile(raw)
        XCTAssertEqual(profile.maxOutput, 4_096); XCTAssertEqual(profile.modelOutputLimit, 65_536); XCTAssertEqual(profile.wireOutputLimit, 65_536)
        let body = try ProviderClient.requestBody(profile: profile, messages: [], instructions: "test", tools: [], sessionID: "session")
        XCTAssertEqual(body["max_output_tokens"].int, 65_536, "the model's own limit, not the budget")
        XCTAssertTrue(body["modelOutputLimit"].isNull, "Capability metadata belongs to preflight, not the provider request")
        XCTAssertEqual(try Profile(profile.raw).modelOutputLimit, 65_536)
        let unknown = try Profile(raw.removing(["modelOutputLimit"]))
        XCTAssertEqual(unknown.maxOutput, 4_096); XCTAssertNil(unknown.modelOutputLimit); XCTAssertNil(unknown.wireOutputLimit)
        XCTAssertTrue(try ProviderClient.requestBody(profile: unknown, messages: [], instructions: "test", tools: [], sessionID: "session")["max_output_tokens"].isNull,
            "without a ceiling nothing is sent; the gateway decides where the reply stops")
        let task = try profile.capped(256)
        XCTAssertEqual(task.wireOutputLimit, 256); XCTAssertEqual(task.maxOutput, 4_096)
        XCTAssertEqual(try ProviderClient.requestBody(profile: task, messages: [], instructions: "test", tools: [], sessionID: "session")["max_output_tokens"].int, 256)
        var omitting = profile.raw; omitting["compat"]["supportsMaxOutputTokens"] = false
        XCTAssertNil(try Profile(omitting).wireOutputLimit)
        for invalid: JSON in [0, -1, "256", 1_000_001] { var candidate = raw; candidate["outputCap"] = invalid; XCTAssertThrowsError(try Profile(candidate)) }
    }

    func testModelOverrideCeilingDoesNotLeakFromPreviousAlias() throws {
        var raw = try fixtureProfile().raw; raw["modelOutputLimit"] = 8_192
        let profile = try Profile(raw)
        let same = try profile.overriding(model: profile.model, thinkingLevel: "low")
        XCTAssertEqual(same.modelOutputLimit, 8_192)
        let other = try profile.overriding(model: "other", thinkingLevel: nil)
        XCTAssertNil(other.modelOutputLimit); XCTAssertEqual(other.maxOutput, 4_096)
        let selected = try profile.overriding(model: "smaller", thinkingLevel: nil, contextWindow: 16_000, maxOutputTokens: 2_048, modelOutputLimit: 2_048)
        XCTAssertEqual(selected.modelOutputLimit, 2_048); XCTAssertEqual(selected.maxOutput, 2_048)
        // The budget and the ceiling are independent: either may be the larger.
        let smallerCeiling = try profile.overriding(model: "smaller", thinkingLevel: nil, modelOutputLimit: 2_048)
        XCTAssertEqual(smallerCeiling.wireOutputLimit, 2_048); XCTAssertEqual(smallerCeiling.maxOutput, 4_096)
        let largerBudget = try profile.overriding(model: nil, thinkingLevel: nil, maxOutputTokens: 10_000)
        XCTAssertEqual(largerBudget.maxOutput, 10_000); XCTAssertEqual(largerBudget.wireOutputLimit, 8_192)
    }

    func testCapabilityCeilingIsIndependentOfTheBudgetWhichOnlyHasToFitTheWindow() throws {
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 8_192; raw["maxOutputTokens"] = 2_048
        raw["modelOutputLimit"] = 16_384
        XCTAssertNoThrow(try Profile(raw))
        for invalid: JSON in [0, -1, true, "4096", 1.5, 1_000_001] {
            var candidate = raw; candidate["modelOutputLimit"] = invalid
            XCTAssertThrowsError(try Profile(candidate))
            XCTAssertThrowsError(try NativeHostService.turnOverrides(["modelOutputLimit": invalid]))
        }
        var below = raw; below["modelOutputLimit"] = 1_024
        XCTAssertEqual(try Profile(below).wireOutputLimit, 1_024, "a ceiling below the budget is simply what the request carries")
        var excessive = raw; excessive["maxOutputTokens"] = 8_192
        XCTAssertThrowsError(try Profile(excessive), "the reserve must leave room for input")
        let overrides = try NativeHostService.turnOverrides(["model":"selected", "contextWindow":16_000, "maxOutputTokens":2_048, "modelOutputLimit":8_192])
        XCTAssertEqual(overrides.maxOutputTokens, 2_048); XCTAssertEqual(overrides.modelOutputLimit, 8_192)
    }

    /// Pi's mapStopReason: a reply the provider stopped for another reason
    /// (its content filter) is an error, never an output limit, and its calls
    /// do not run. A reply cut at the output limit fails its calls with pi's
    /// text and the loop asks again.
    func testAReplyStoppedByTheContentFilterIsNotAnOutputLimit() async throws {
        for reason in ["content_filter", "max_output_tokens"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            var cut = toolReply(["first"]); cut.truncated = true
            cut.terminal = ModelTerminalOutcome(status: "incomplete", incompleteReason: reason)
            let tools = RecordingTools()
            let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([cut, answer("done")]), tools: tools, traces: TraceStore(), autoCompaction: false)
            _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
            try await eventually { !(await session.isRunning) }
            let snapshot = await session.snapshot(), calls = await tools.calls
            let events = await session.eventPage(since: 0)["events"].list.compactMap { $0["type"].text }
            let reply = snapshot["messages"].list.first { $0["role"].text == "assistant" }
            let result = snapshot["messages"].list.first { $0["role"].text == "tool" }?["text"].text ?? ""
            XCTAssertTrue(calls.isEmpty, "\(reason): an incomplete reply's calls never run")
            if reason == "content_filter" {
                XCTAssertEqual(snapshot["state"].text, "error")
                XCTAssertEqual(snapshot["preflightError"].text, "Response incomplete: content_filter")
                XCTAssertFalse(events.contains("output_limit"))
            } else {
                XCTAssertEqual(reply?["stopReason"].text, "length")
                XCTAssertFalse(events.contains("output_limit"), "The loop continues after the failed calls")
                XCTAssertEqual(snapshot["messages"].list.last?["text"].text, "done")
                XCTAssertTrue(result.contains("the response hit the output token limit"), result)
            }
            await session.close()
        }
    }
}
