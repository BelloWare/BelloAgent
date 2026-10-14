import XCTest
@testable import PiApp

final class SubagentModelGrantTests: XCTestCase {
    @MainActor func testGrantsAreExactlyTheSavedConnectionsOfferedPickerModels() throws {
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "current"
        var chat = try JSONDecoder().decode(ChatRecord.self, from: Data(#"{"id":"c","workspaceID":"w","title":"Chat","profileID":"fixture"}"#.utf8))
        chat.thinkingLevel = "max"
        let entry = ModelCatalog.Entry(descriptors: [
            ModelDescriptor(id: "current", name: "Current", contextWindow: 32000, maxOutputTokens: 4000, reasoning: [], deprecated: true),
            ModelDescriptor(id: "retired", name: "Retired", deprecated: true),
            ModelDescriptor(id: "other", name: "Other", contextWindow: 64000, maxOutputTokens: 8000, reasoning: ["high"])
        ])
        let grants = entry.subagentGrants(chat: chat, profile: profile)
        XCTAssertEqual(grants.map(\.model), entry.offered(current: "current").map(\.id))
        XCTAssertEqual(grants.first?.thinkingLevel, "default")
        XCTAssertEqual(grants.first?.modelOutputLimit, 4000)
        XCTAssertEqual(grants.first?.input, ["text"])
        XCTAssertTrue(grants.allSatisfy { $0.thinkingLevel == "default" })
        chat.model = "manual-alias"
        XCTAssertEqual(entry.subagentGrants(chat: chat, profile: profile).map(\.model), ["other"])
        XCTAssertTrue(ModelCatalog.Entry().subagentGrants(chat: chat, profile: profile).isEmpty)
    }
}
