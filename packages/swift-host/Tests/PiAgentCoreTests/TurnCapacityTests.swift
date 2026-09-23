import XCTest
@testable import PiAgentCore

final class TurnCapacityTests: XCTestCase {
    func testExplicitEffortDoesNotDependOnProfileReasoningFlagAndDefaultOmitsOptions() throws {
        var raw = try fixtureProfile().raw; raw["reasoning"] = false; raw["thinkingLevelMap"] = ["high": "unsupported-profile-effort"]
        let base = try Profile(raw)
        let high = try base.overriding(model: "another", thinkingLevel: "high", contextWindow: 16000, maxOutputTokens: 2048)
        XCTAssertTrue(high.raw["thinkingLevelMap"].isNull, "A different alias cannot inherit another model's effort translation")
        let body = try ProviderClient.requestBody(profile: high, messages: [], instructions: "", tools: [], sessionID: "s")
        XCTAssertTrue(body["max_output_tokens"].isNull, "No ceiling is known for the override alias, so no cap is sent; the budget is a local reserve")
        XCTAssertEqual(high.maxOutput, 2048)
        XCTAssertEqual(body["reasoning"]["effort"].text, "high")
        let modelDefault = try high.overriding(model: nil, thinkingLevel: "default")
        let defaultBody = try ProviderClient.requestBody(profile: modelDefault, messages: [], instructions: "", tools: [], sessionID: "s")
        for key in ["reasoning", "thinking", "output_config", "include"] { XCTAssertTrue(defaultBody[key].isNull, key) }
        XCTAssertEqual(try high.overriding(model: nil, thinkingLevel: nil).raw, high.raw)
    }

    func testFallbacksAreDisabledUnlessTheProfileAllowsThem() throws {
        let base = try fixtureProfile()
        let body = try ProviderClient.requestBody(profile: base, messages: [], instructions: "", tools: [], sessionID: "s")
        XCTAssertEqual(body["disable_fallbacks"].flag, true, "Every request opts out of gateway fallbacks by default")
        var raw = base.raw; raw["compat"] = ["allowFallbacks": true]
        let allowing = try ProviderClient.requestBody(profile: try Profile(raw), messages: [], instructions: "", tools: [], sessionID: "s")
        XCTAssertTrue(allowing["disable_fallbacks"].isNull, "compat.allowFallbacks restores the gateway's configured fallbacks")
    }

    func testLimitValidationRejectsMalformedOrIncompatibleOverridesBeforeEditing() async throws {
        for value: JSON in [0, -1, 1.5, "16000", true, 10_000_001] {
            XCTAssertThrowsError(try NativeHostService.turnOverrides(["contextWindow": value]))
        }
        for value: JSON in [0, -1, 1.5, "2048", true, 1_000_001] {
            XCTAssertThrowsError(try NativeHostService.turnOverrides(["maxOutputTokens": value]))
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AgentSession(id: "limits", profile: fixtureProfile(), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([answer("old answer")]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "old question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let before = await session.snapshot(), path = await session.path!, journal = try Data(contentsOf: URL(fileURLWithPath: path))
        for (context, output) in [(1000, 1000), (1000, 2000), (0, 1), (10_000_001, 1), (2_000_000, 1_000_001)] {
            do {
                _ = try await session.edit(fromMessageID: "first", input: Submission(commandID: "edit", turnID: "edit", text: "replacement", contextWindow: context, maxOutputTokens: output))
                XCTFail("Invalid capacity pair accepted")
            } catch let error as AgentError { XCTAssertEqual(error.code, "invalid_params") }
        }
        let after = await session.snapshot()
        XCTAssertEqual(after["messages"], before["messages"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), journal)
        await session.close()
    }

    func testLimitsApplyToEveryToolRoundAndActiveMetricsThenRevert() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), client = ScriptClient([toolReply(["first"]), answer("limited answer"), answer("base answer")], holdFirst: true)
        let session = try AgentSession(id: "limits", profile: profile, apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "limited", turnID: "limited", text: "question", model: "limited-model", thinkingLevel: "high", contextWindow: 16000, maxOutputTokens: 2048), steer: false)
        try await eventually { await client.count == 1 }
        let active = await session.inspectContext()
        XCTAssertEqual(active["context"]["contextWindow"].int, 16000)
        XCTAssertEqual(active["context"]["outputReserve"].int, 2048)
        XCTAssertEqual(active["outputReserve"].int, 2048)
        await client.release(); try await eventually { !(await session.isRunning) }
        _ = try await session.submit(Submission(commandID: "base", turnID: "base", text: "back"), steer: false)
        try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles
        XCTAssertEqual(profiles.map(\.contextWindow), [16000, 16000, profile.contextWindow])
        XCTAssertEqual(profiles.map(\.maxOutput), [2048, 2048, profile.maxOutput])
        XCTAssertEqual(profiles.map(\.model), ["limited-model", "limited-model", profile.model])
        let idle = await session.contextInfo()
        XCTAssertEqual(idle["contextWindow"].int, profile.contextWindow)
        XCTAssertEqual(idle["outputReserve"].int, profile.maxOutput)
        await session.close()
    }

    func testSmallerModelPreflightAndCompactionUseItsOwnCapacity() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // The first reply reports what its 11,000-character input really cost.
        var first = answer("old answer"); first.usage = ["input": 4_000, "inputIncludingCache": 4_000, "output": 5]
        let client = ScriptClient([first, answer("short summary"), answer("new answer")])
        let session = try AgentSession(id: "compact", profile: fixtureProfile(), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore())
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: String(repeating: "x", count: 11000)), steer: false)
        try await eventually { !(await session.isRunning) }
        let preview = try await session.prepareContext(["text":"continue","model":"small-model","thinkingLevel":"default","contextWindow":5000,"maxOutputTokens":1000])
        XCTAssertEqual(preview["count"]["fits"], false, "The actual built input, rather than the retired fixed tool allowance, must cross the smaller model's input budget")
        _ = try await session.submit(Submission(commandID: "small", turnID: "small", text: "continue", model: "small-model", thinkingLevel: "default", contextWindow: 5000, maxOutputTokens: 1000), steer: false)
        try await eventually { !(await session.isRunning) }
        let purposes = await client.purposes, profiles = await client.profiles, snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        XCTAssertEqual(purposes, ["turn", "compaction", "turn"], "The previous reply's reported tokens are measured against the selected model's smaller window")
        XCTAssertEqual(profiles.map(\.contextWindow), [100000, 5000, 5000])
        XCTAssertEqual(profiles.map(\.maxOutput), [4096, 1000, 1000])
        XCTAssertEqual(profiles.map(\.model), ["fixture-model", "small-model", "small-model"])
        await session.close()
    }

    func testCompactionBoundsOversizedSourceBeforeDispatchToSmallerModel() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var first = answer("old answer"); first.usage = ["input": 4_600, "inputIncludingCache": 4_600, "output": 5]
        let client = ScriptClient([first, answer("Bounded summary of previous work"), answer("continued")])
        let session = try AgentSession(id: "compact", profile: fixtureProfile(), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore())
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: String(repeating: "x", count: 18000)), steer: false)
        try await eventually { !(await session.isRunning) }
        _ = try await session.submit(Submission(commandID: "small", turnID: "small", text: "continue", model: "small-model", contextWindow: 5000, maxOutputTokens: 1000), steer: false)
        try await eventually { !(await session.isRunning) }
        let count = await client.count, snapshot = await session.snapshot()
        XCTAssertEqual(count, 3)
        XCTAssertEqual(snapshot["state"].text, "idle",snapshot["preflightError"].encoded())
        let requests=await client.requests, profiles=await client.profiles
        let summaryBody=try ProviderClient.requestBody(profile:profiles[1],messages:requests[1],instructions:"",tools:[],sessionID:"compact")
        XCTAssertTrue(try RequestContextCounter().count(messages:requests[1],profile:profiles[1],request:summaryBody,reportedUsage:false).fits)
        XCTAssertTrue(requests[1][0].text.contains("EXCERPT"),"Oversized retained source is explicitly excerpted and recallable")
        await session.close()
    }

    func testQueuedAndSteeredLimitsSurvivePausedReload() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root), traces = TraceStore(), held = ScriptClient([answer("held")], holdFirst: true)
        let session = try AgentSession(id: "queue", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: held, tools: RecordingTools(), traces: traces, autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "first"), steer: false)
        try await eventually { await held.count == 1 }
        _ = try await session.submit(Submission(commandID: "queued", turnID: "queued", text: "follow up", model: "queued-model", contextWindow: 16000, maxOutputTokens: 2048), steer: false)
        _ = try await session.submit(Submission(commandID: "steered", turnID: "steered", text: "steer", model: "steered-model", contextWindow: 20000, maxOutputTokens: 3000), steer: true)
        await session.stop(); try await eventually { !(await session.isRunning) }
        let path = await session.path!; await session.close()
        let client = ScriptClient([answer("steered answer"), answer("queued answer")])
        let reopened = try AgentSession(id: "queue", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: client, tools: RecordingTools(), traces: traces, resumePath: path, autoCompaction: false)
        let paused = await reopened.snapshot(), initialCount = await client.count
        XCTAssertEqual(paused["state"].text, "paused"); XCTAssertEqual(paused["queueCount"].int, 2); XCTAssertEqual(initialCount, 0)
        try await reopened.resumeQueue(); try await eventually { !(await reopened.isRunning) }
        let profiles = await client.profiles
        XCTAssertEqual(profiles.map(\.model), ["steered-model", "queued-model"])
        XCTAssertEqual(profiles.map(\.contextWindow), [20000, 16000])
        XCTAssertEqual(profiles.map(\.maxOutput), [3000, 2048])
        await reopened.close()
    }
}
