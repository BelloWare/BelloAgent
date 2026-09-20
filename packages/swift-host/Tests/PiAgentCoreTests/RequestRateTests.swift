import XCTest
@testable import PiAgentCore

final class RequestRateTests: XCTestCase {
    private func metadata(usage: JSON = ["output": 600], dispatch: Double? = 1_000, terminal: Double? = 3_000,
                          outcome: String = "completed", modelOutcome: String = "completed") async throws -> JSON {
        let traces = TraceStore()
        let id = await traces.begin(session: "rate", turn: "turn", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        if let dispatch { await traces.dispatched(id, at: dispatch) }
        if let terminal { await traces.terminal(id, at: terminal) }
        await traces.usage(id, usage)
        await traces.finish(id, outcome: outcome, modelOutcome: modelOutcome)
        return await traces.latest("rate")
    }

    func testHiddenReasoningUsesReportedOutputOnceWithoutVisibleText() async throws {
        let response: JSON = ["status": "completed", "output": [
            ["type": "reasoning", "encrypted_content": "opaque-hidden-reasoning", "summary": []]
        ], "usage": ["input_tokens": 100, "output_tokens": 600, "output_tokens_details": ["reasoning_tokens": 500]]]
        var accumulator = ProviderAccumulator(api: "openai-responses")
        try accumulator.acceptJSON(response)
        let reply = try accumulator.result()
        XCTAssertTrue(reply.message.text.isEmpty); XCTAssertTrue(reply.message.thinking.isEmpty)
        XCTAssertEqual(reply.usage["output"].int, 600); XCTAssertEqual(reply.usage["reasoning"].int, 500)
        let traces = TraceStore()
        let id = await traces.begin(session: "hidden", turn: "turn", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await traces.dispatched(id, at: 1_000)
        await traces.append(id, data: try response.data())
        await traces.terminal(id, at: 3_000)
        await traces.usage(id, reply.usage)
        await traces.transport(id, observation: ["dispatch": 1_000, "httpEnd": 9_000, "transportOutcome": "eof"])
        let pending = await traces.latest("hidden")
        XCTAssertTrue(pending["metrics"]["outputTokensPerSecond"].isNull, "Terminal bytes alone do not establish a completed attempt")
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let completed = await traces.latest("hidden")
        XCTAssertEqual(completed["metrics"]["outputTokensPerSecond"].double, 300, "600 reported output / 2 seconds; reasoning is already included and HTTP tail time is excluded")
        XCTAssertTrue(completed["metrics"]["firstTextMs"].isNull)
        XCTAssertTrue(completed["metrics"]["observedTTFTms"].isNull)
    }

    func testVisibleBodyLengthCannotSubstituteForMissingUsage() async throws {
        let traces = TraceStore()
        let id = await traces.begin(session: "unreported", turn: "turn", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await traces.dispatched(id, at: 1_000)
        await traces.append(id, data: Data(String(repeating: "Visible text 中文🙂", count: 10_000).utf8))
        await traces.content(id, text: true, at: 1_500)
        await traces.terminal(id, at: 3_000)
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let completed = await traces.latest("unreported")
        XCTAssertTrue(completed["metrics"]["outputTokensPerSecond"].isNull)
        let reasoningOnly = try await metadata(usage: ["reasoning": 500])
        XCTAssertTrue(reasoningOnly["metrics"]["outputTokensPerSecond"].isNull, "A reasoning subset cannot substitute for an absent output total")
        let zeroOutput = try await metadata(usage: ["output": 0])
        XCTAssertEqual(zeroOutput["metrics"]["outputTokensPerSecond"].double, 0, "Reported zero output remains distinct from missing usage")
    }

    func testRateRequiresFinitePositiveDispatchToModelTerminalDuration() async throws {
        let boundaries: [(Double?, Double?)] = [
            (nil, 3_000), (1_000, nil), (1_000, 1_000), (2_000, 1_000),
            (.infinity, 3_000), (1_000, .infinity), (.nan, 3_000), (1_000, .nan),
            (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
            (0, Double.leastNonzeroMagnitude)
        ]
        for (dispatch, terminal) in boundaries {
            let value = try await metadata(dispatch: dispatch, terminal: terminal)
            XCTAssertTrue(value["metrics"]["outputTokensPerSecond"].isNull, "Invalid request boundaries must not produce a rate: \(String(describing: dispatch)), \(String(describing: terminal))")
        }
    }

    func testFailedCancelledTruncatedAndUnfinishedAttemptsDoNotPublishRates() async throws {
        for (outcome, modelOutcome) in [("running", "pending"), ("failed", "failed"), ("cancelled", "interrupted"),
                                        ("truncated", "truncated"), ("failed", "completed"), ("completed", "interrupted")] {
            let value = try await metadata(outcome: outcome, modelOutcome: modelOutcome)
            XCTAssertTrue(value["metrics"]["outputTokensPerSecond"].isNull, outcome + "/" + modelOutcome)
        }
    }

    func testInvalidUsageOrOverflowCannotPublishANumericRate() async throws {
        for output in [-1.0, .infinity, .nan, Double.greatestFiniteMagnitude] {
            let value = try await metadata(usage: ["output": JSON(output)], dispatch: 0, terminal: 1)
            XCTAssertTrue(value["metrics"]["outputTokensPerSecond"].isNull)
        }
    }
}
