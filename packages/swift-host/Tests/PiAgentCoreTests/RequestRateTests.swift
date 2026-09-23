import XCTest
@testable import PiAgentCore

/// The one rate the helper publishes for an attempt, `metrics.decodeTokensPerSecond`:
/// the gateway-reported output tokens after the first over first → last
/// output, for a completed attempt only, and never from anything but reported
/// usage. `metrics.streamDurationMs` is the same span.
final class RequestRateTests: XCTestCase {
    /// One attempt on the store's own clock: output opens at `first`, the last
    /// output arrives at `last`, and the terminal event at `terminal`.
    private func metadata(usage: JSON = ["output": 601], dispatch: Double? = 500, first: Double? = 1_000, last: Double? = 3_000, terminal: Double? = 3_500,
                          outcome: String = "completed", modelOutcome: String = "completed") async throws -> JSON {
        let traces = TraceStore()
        let id = await traces.begin(session: "rate", turn: "turn", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        if let dispatch { await traces.dispatched(id, at: dispatch) }
        if let first { await traces.opened(id, at: first) }
        if let last { await traces.closed(id, at: last) }
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
        // The reasoning item opens at 1 s and completes at 3 s; the gateway
        // sends the terminal event with the usage at 3.5 s, and the HTTP
        // exchange ends at 9 s.
        let traces = TraceStore()
        let id = await traces.begin(session: "hidden", turn: "turn", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await traces.dispatched(id, at: 500)
        await traces.opened(id, at: 1_000)
        await traces.append(id, data: try response.data())
        await traces.closed(id, at: 3_000)
        await traces.terminal(id, at: 3_500)
        await traces.usage(id, reply.usage)
        await traces.transport(id, observation: ["dispatch": 500, "httpEnd": 9_000, "transportOutcome": "eof"])
        let pending = await traces.latest("hidden")
        XCTAssertTrue(pending["metrics"]["decodeTokensPerSecond"].isNull, "Terminal bytes alone do not establish a completed attempt")
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let completed = await traces.latest("hidden")
        XCTAssertEqual(completed["metrics"]["decodeTokensPerSecond"].double, 299.5,
                       "The 599 reported tokens after the first over the 2 s the reasoning item was open: reasoning is already included, and neither the held terminal nor the HTTP tail is decode time")
        XCTAssertEqual(completed["metrics"]["streamDurationMs"].double, 2_000)
        XCTAssertTrue(completed["metrics"]["firstTextMs"].isNull, "No visible text was observed")
        XCTAssertEqual(completed["metrics"]["observedTTFTms"].double, 500, "The hidden reasoning's item is the first output")
        XCTAssertNil(completed["metrics"].map["outputTokensPerSecond"], "No round-trip rate is published beside the decode rate")
    }

    func testVisibleBodyLengthCannotSubstituteForMissingUsage() async throws {
        let traces = TraceStore()
        let id = await traces.begin(session: "unreported", turn: "turn", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await traces.dispatched(id, at: 1_000)
        await traces.append(id, data: Data(String(repeating: "Visible text 中文🙂", count: 10_000).utf8))
        await traces.content(id, text: true, at: 1_500)
        await traces.content(id, text: true, at: 2_500)
        await traces.terminal(id, at: 3_000)
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let completed = await traces.latest("unreported")
        XCTAssertEqual(completed["metrics"]["streamDurationMs"].double, 1_000, "The decode span was observed")
        XCTAssertTrue(completed["usage"]["output"].isNull)
        XCTAssertTrue(completed["metrics"]["decodeTokensPerSecond"].isNull, "Visible bytes are never a token count")
        let reasoningOnly = try await metadata(usage: ["reasoning": 500])
        XCTAssertTrue(reasoningOnly["metrics"]["decodeTokensPerSecond"].isNull, "A reasoning subset cannot substitute for an absent output total")
        let zeroOutput = try await metadata(usage: ["output": 0])
        XCTAssertEqual(zeroOutput["usage"]["output"].double, 0, "Reported zero output remains distinct from missing usage")
        XCTAssertTrue(zeroOutput["metrics"]["decodeTokensPerSecond"].isNull, "and with no token after a first it has no decode speed")
        let measured = try await metadata()
        XCTAssertEqual(measured["metrics"]["decodeTokensPerSecond"].double, 300, "The control: 600 tokens after the first over 2 s")
    }

    func testRateRequiresAFiniteDecodeSpanFromFirstToLastOutput() async throws {
        let boundaries: [(Double?, Double?)] = [
            (nil, 3_000), (1_000, 1_000), (2_000, 1_000),
            (.infinity, 3_000), (.nan, 3_000),
            (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
            (0, Double.leastNonzeroMagnitude)
        ]
        for (first, last) in boundaries {
            let value = try await metadata(first: first, last: last)
            XCTAssertTrue(value["metrics"]["decodeTokensPerSecond"].isNull, "Invalid decode boundaries must not produce a rate: \(String(describing: first)), \(String(describing: last))")
        }
        // A last output never stamped (or not a time) leaves the terminal as
        // the only end: 600 tokens after the first over first output → 3.5 s.
        for last in [nil, Double.infinity, Double.nan] {
            let value = try await metadata(last: last)
            XCTAssertEqual(value["metrics"]["streamDurationMs"].double, 2_500, String(describing: last))
            XCTAssertEqual(value["metrics"]["decodeTokensPerSecond"].double, 240, String(describing: last))
        }
        // No terminal event observed: no span at all, whatever arrived.
        let open = try await metadata(terminal: nil)
        XCTAssertTrue(open["metrics"]["streamDurationMs"].isNull)
        XCTAssertTrue(open["metrics"]["decodeTokensPerSecond"].isNull)
    }

    func testFailedCancelledTruncatedAndUnfinishedAttemptsDoNotPublishRates() async throws {
        let control = try await metadata()
        XCTAssertEqual(control["metrics"]["decodeTokensPerSecond"].double, 300, "The same timings and usage, completed, do")
        for (outcome, modelOutcome) in [("running", "pending"), ("failed", "failed"), ("cancelled", "interrupted"),
                                        ("truncated", "truncated"), ("failed", "completed"), ("completed", "interrupted")] {
            let value = try await metadata(outcome: outcome, modelOutcome: modelOutcome)
            XCTAssertTrue(value["metrics"]["decodeTokensPerSecond"].isNull, outcome + "/" + modelOutcome)
        }
    }

    func testInvalidUsageOrOverflowCannotPublishANumericRate() async throws {
        for output in [-1.0, .infinity, .nan, Double.greatestFiniteMagnitude] {
            // Over the 250 ms floor itself, the largest finite count overflows.
            let value = try await metadata(usage: ["output": JSON(output)], first: 1_000, last: 1_250)
            XCTAssertTrue(value["metrics"]["decodeTokensPerSecond"].isNull, String(describing: output))
        }
    }
}
