import XCTest
@testable import PiApp

final class RoutingConfigurationTests: XCTestCase {
    func testNativeSettingsRequireExplicitSafeMetadataAndFixedReplayContracts() throws {
        try RoutingConfiguration.validate(.object(["replayPolicy": .string("portable")]))
        try RoutingConfiguration.validate(.object(["reference": .string("Fixture v1"), "deploymentHeader": .string("x-litellm-model-id")]))
        for header in ["authorization", "x-api-key", "set-cookie", "x-access-token", "location"] {
            XCTAssertThrowsError(try RoutingConfiguration.validate(.object(["reference": .string("fixture"), "modelHeader": .string(header)])))
        }
        XCTAssertThrowsError(try RoutingConfiguration.validate(.object(["modelHeader": .string("x-model")])))
        XCTAssertThrowsError(try RoutingConfiguration.validate(.object(["replayPolicy": .string("pinned"), "expectedModel": .string("actual-a")])))
        try RoutingConfiguration.validate(.object(["replayPolicy": .string("pinned"), "expectedModel": .string("actual-a"), "replayContract": .string("Gateway fixes a compatible upstream")]))
    }
    func testVaultKeepsRoutingAndOptionalDashboardFiltersInOneConfiguration() throws {
        var profile=ProfileRecord()
        profile.providerId="litellm"; profile.modelId="auto-router"; profile.baseUrl="https://example.invalid/proxy"
        profile.advancedJSON="{\"routing\":{\"replayPolicy\":\"portable\",\"reference\":\"fixture v1\",\"modelHeader\":\"x-model\"}}"
        var config=VaultConfiguration(); config.captureKey=Data(repeating:3,count:32)
        config.profiles=[VaultProfile(profile:profile,apiKey:"synthetic-only")]
        config.dashboard.requestedAlias="auto-router"; config.dashboard.unreportedModelOnly=true
        try config.validate()
        let saved=try JSONDecoder().decode(VaultConfiguration.self,from:JSONEncoder().encode(config))
        XCTAssertEqual(saved,config)
        let original=Data("{\"windowHours\":24,\"status\":\"completed\",\"metricRetentionDays\":90}".utf8)
        let old=try JSONDecoder().decode(DashboardPreferences.self,from:original)
        XCTAssertNil(old.effectiveModel); XCTAssertNil(old.unreportedModelOnly)
    }
}
