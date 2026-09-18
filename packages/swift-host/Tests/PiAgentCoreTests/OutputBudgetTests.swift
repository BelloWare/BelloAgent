import XCTest
@testable import PiAgentCore

final class OutputBudgetTests: XCTestCase {
    func testProfileBudgetAndModelCeilingRemainSeparateInActualRequest() throws {
        var raw = try fixtureProfile().raw
        raw["modelOutputLimit"] = 65_536
        let profile = try Profile(raw)
        XCTAssertEqual(profile.maxOutput, 4_096); XCTAssertEqual(profile.modelOutputLimit, 65_536)
        let body = try ProviderClient.requestBody(profile: profile, messages: [], instructions: "test", tools: [], sessionID: "session")
        XCTAssertEqual(body["max_output_tokens"].int, 4_096)
        XCTAssertTrue(body["modelOutputLimit"].isNull, "Capability metadata belongs to preflight, not the provider request")
        XCTAssertEqual(try Profile(profile.raw).modelOutputLimit, 65_536)
        let old = try Profile(raw.removing(["modelOutputLimit"]))
        XCTAssertEqual(old.maxOutput, 4_096); XCTAssertNil(old.modelOutputLimit)
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
        XCTAssertThrowsError(try profile.overriding(model: "smaller", thinkingLevel: nil, modelOutputLimit: 2_048))
        XCTAssertThrowsError(try profile.overriding(model: nil, thinkingLevel: nil, maxOutputTokens: 10_000))
    }

    func testCapabilityCeilingMayExceedContextButBudgetMustFitBoth() throws {
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 8_192; raw["maxOutputTokens"] = 2_048
        raw["modelOutputLimit"] = 16_384
        XCTAssertNoThrow(try Profile(raw))
        for invalid: JSON in [0, -1, true, "4096", 1.5, 1_000_001] {
            var candidate = raw; candidate["modelOutputLimit"] = invalid
            XCTAssertThrowsError(try Profile(candidate))
            XCTAssertThrowsError(try NativeHostService.turnOverrides(["modelOutputLimit": invalid]))
        }
        var below = raw; below["modelOutputLimit"] = 1_024
        XCTAssertThrowsError(try Profile(below))
        var excessive = raw; excessive["maxOutputTokens"] = 8_192
        XCTAssertThrowsError(try Profile(excessive))
        let overrides = try NativeHostService.turnOverrides(["model":"selected", "contextWindow":16_000, "maxOutputTokens":2_048, "modelOutputLimit":8_192])
        XCTAssertEqual(overrides.maxOutputTokens, 2_048); XCTAssertEqual(overrides.modelOutputLimit, 8_192)
    }
}
