import XCTest
@testable import PiAgentCore

final class GatewayTelemetryTests: XCTestCase {
    private func profile(_ api: String = "openai-responses", cacheHeader: Bool = true) throws -> Profile {
        var routing: JSON = ["replayPolicy":"portable"]
        if cacheHeader { routing["reference"]="fixture-v1"; routing["cacheHeader"]="x-fixture-cache" }
        return try Profile(["id":"p","providerId":"litellm","api":JSON(api),"modelId":"alias","baseUrl":"http://127.0.0.1","contextWindow":100000,"maxOutputTokens":4096,"routing":routing])
    }
    func testStreamingHeaderPlaceholderIsNotZeroCostAndTerminalCostIsNotAddedTwice() throws {
        var report = GatewayTelemetry(profile:try profile())
        report.head(["content-type":"text/event-stream","x-litellm-response-cost":"0","x-fixture-cache":"MISS"],excluding:{ _ in false })
        XCTAssertEqual(report.json["cost"]["status"].text,"unreported"); XCTAssertTrue(report.json["cost"]["usd"].isNull)
        let terminal: JSON = ["type":"response.completed","response":["usage":["cost":0.0123]]]
        report.body(terminal,streaming:true,excluding:{ _ in false }); report.body(terminal,streaming:true,excluding:{ _ in false })
        XCTAssertEqual(report.json["cost"]["usd"].double,0.0123); XCTAssertEqual(report.json["cost"]["evidence"].list.count,1)
        XCTAssertEqual(report.json["cache"]["status"].text,"miss")
        XCTAssertEqual(report.json["cost"]["streamingHeaderUSD"].double,0)
    }
    func testExplicitZeroAndNonstreamHeaderHaveProvenanceAndConflictIsNotCharged() throws {
        var report = GatewayTelemetry(profile:try profile())
        report.head(["content-type":"application/json","x-litellm-response-cost":"0","x-fixture-cache":"true"],excluding:{ _ in false })
        XCTAssertEqual(report.json["cost"]["status"].text,"reported"); XCTAssertEqual(report.json["cost"]["usd"].double,0)
        XCTAssertEqual(report.json["cost"]["source"].text,"header:x-litellm-response-cost"); XCTAssertEqual(report.json["cache"]["status"].text,"hit")
        report.body(["usage":["cost":0.1]],streaming:false,excluding:{ _ in false })
        XCTAssertEqual(report.json["cost"]["status"].text,"conflict"); XCTAssertTrue(report.json["cost"]["usd"].isNull)
    }
    func testInterimUsageCannotBecomeFinalAttemptCost() throws {
        var report = GatewayTelemetry(profile:try profile())
        let interim: JSON = ["type":"response.in_progress","response":["usage":["cost":0.01]]]
        report.body(interim,streaming:true,excluding:{ _ in false })
        XCTAssertEqual(report.json["cost"]["status"].text,"unreported"); XCTAssertTrue(report.json["cost"]["usd"].isNull)
        let final: JSON = ["type":"response.completed","response":["usage":["cost":0.02]]]
        report.body(final,streaming:true,excluding:{ _ in false })
        XCTAssertEqual(report.json["cost"]["usd"].double,0.02); XCTAssertEqual(report.json["cost"]["status"].text,"reported")
    }
    func testMalformedNegativeNonfiniteHugeAndConflictingAmountsStayMissing() throws {
        for value: JSON in [-1, "NaN", "infinity", 1_000_000_000_001, "not-a-number", true] {
            var report = GatewayTelemetry(profile:try profile())
            report.body(["usage":["cost":value]],streaming:false,excluding:{ _ in false })
            XCTAssertEqual(report.json["cost"]["status"].text,"invalid"); XCTAssertTrue(report.json["cost"]["usd"].isNull)
        }
        var conflicting = GatewayTelemetry(profile:try profile())
        conflicting.body(["usage":["cost":1,"response_cost":2]],streaming:false,excluding:{ _ in false })
        XCTAssertEqual(conflicting.json["cost"]["status"].text,"conflict")
    }
    func testCacheIdentityProviderCachedTokensAndUnconfiguredHeadersCannotClaimHit() throws {
        var report = GatewayTelemetry(profile:try profile(cacheHeader:false))
        report.head(["x-litellm-cache-key":"a-key","x-fixture-cache":"true"],excluding:{ _ in false })
        report.body(["usage":["input_tokens_details":["cached_tokens":4000],"cache_read_input_tokens":4000]],streaming:false,excluding:{ _ in false })
        XCTAssertEqual(report.json["cache"]["status"].text,"unreported"); XCTAssertEqual(report.json["cost"]["status"].text,"unreported")
        var invalid = GatewayTelemetry(profile:try profile())
        invalid.head(["x-fixture-cache":"hit,miss"],excluding:{ _ in false })
        XCTAssertEqual(invalid.json["cache"]["status"].text,"invalid")
    }
    func testReportedTelemetryCannotEchoCredentialsOrGrowWithoutBound() throws {
        var report = GatewayTelemetry(profile:try profile())
        report.head(["content-type":"application/json","x-litellm-call-id":"secret","x-litellm-version":"secret","x-fixture-cache":"secret","x-litellm-response-cost":"secret"],excluding:{ $0.contains("secret") })
        XCTAssertFalse(report.json.encoded().contains("secret")); XCTAssertEqual(report.json["cost"]["status"].text,"invalid")
        for i in 0..<100 { report.body(["usage":["cost":JSON(i)]],streaming:false,excluding:{ _ in false }) }
        XCTAssertLessThanOrEqual(report.json["cost"]["evidence"].list.count,16); XCTAssertEqual(report.json["cost"]["status"].text,"invalid")
    }
    func testCacheHeaderNeedsAnUnambiguousNonsecretDeploymentContract() throws {
        for routing: JSON in [["cacheHeader":"x-cache"],["reference":"v1","cacheHeader":"authorization"],["reference":"v1","cacheHeader":"x-cache","modelHeader":"X-Cache"]] {
            XCTAssertThrowsError(try RoutingContract(routing))
        }
        XCTAssertNoThrow(try RoutingContract(["reference":"v1","cacheHeader":"x-cache"]))
    }
    func testMissingProviderCacheWriteUsageRemainsUnavailable() throws {
        for api in ["openai-responses","anthropic-messages"] {
            var accumulator = ProviderAccumulator(api:api)
            let response: JSON = api == "openai-responses" ? ["status":"completed","output":[],"usage":["input_tokens":10,"output_tokens":2]] : ["type":"message","role":"assistant","content":[],"stop_reason":"end_turn","usage":["input_tokens":10,"output_tokens":2]]
            try accumulator.acceptJSON(response)
            let usage = try accumulator.result().usage
            XCTAssertTrue(usage["cacheWrite"].isNull); XCTAssertTrue(usage["cacheRead"].isNull)
            XCTAssertEqual(usage["inputIncludingCache"].int,10)
        }
    }
}
