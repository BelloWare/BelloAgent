import XCTest
@testable import PiApp

final class SubagentModelGrantTests: XCTestCase {
    @MainActor func testTurnGrantsStartLoadingAnUnopenedCatalog() async throws {
        try await checkColdCatalog(turn: true)
    }

    @MainActor func testSessionOpenGrantsStartLoadingAnUnopenedCatalog() async throws {
        try await checkColdCatalog(turn: false)
    }

    @MainActor private func checkColdCatalog(turn: Bool) async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("subagent-models-" + UUID().uuidString)
        let catalog = ModelCatalog(readBundled: { [ModelDescriptor(id: "offered", name: "Offered")] })
        let model = makeWorkspaceModel(stateRoot: root, modelCatalog: catalog)
        defer { model.shutdown() }
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "parent-model"
        model.profiles = [profile]
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: profile.id)
        let initial = turn ? model.turnOverrides(for: chat)["subagentModels"] : model.subagentModels(for: chat)
        XCTAssertEqual(initial?.array, [], "Sending proceeds with the current grants before the catalog finishes")
        try await eventually("Grant preparation starts the catalog without opening a picker") { model.catalogEntry(for: profile).fetchedAt != nil }
        let later = model.turnOverrides(for: chat)["subagentModels"]
        XCTAssertEqual(later?.array?.compactMap { $0.object?["model"]?.string }, ["offered"])
        await model.store?.close()
    }

    func testSummaryEffortWireAndOlderSummaryRemainReadable() throws {
        let data = Data(#"{"link":{"version":1,"delegationID":"d","childSessionID":"child","budgetOwnerSessionID":"parent","call":{"parentSessionID":"parent","assistantMessageID":"a","toolCallID":"t"},"parentTurnID":"turn","parentExecutionID":"execution","depth":1},"description":"Task","model":"model","status":"completed","revision":1,"effort":"low"}"#.utf8)
        let summary = try JSONDecoder().decode(SubagentSummary.self,from:data)
        XCTAssertEqual(summary.effort,"low")
        XCTAssertEqual(try JSONDecoder().decode(SubagentSummary.self,from:JSONEncoder().encode(summary)),summary)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        older.removeValue(forKey:"effort")
        XCTAssertNil(try JSONDecoder().decode(SubagentSummary.self,from:JSONSerialization.data(withJSONObject:older)).effort)
    }
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
        let wire = try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(grants))
        XCTAssertEqual(wire.array?.first?.object?["reasoning"]?.array, [])
        XCTAssertEqual(wire.array?.last?.object?["reasoning"]?.array?.compactMap(\.string), ["high"])
        chat.model = "manual-alias"
        XCTAssertEqual(entry.subagentGrants(chat: chat, profile: profile).map(\.model), ["other"])
        XCTAssertTrue(ModelCatalog.Entry().subagentGrants(chat: chat, profile: profile).isEmpty)
    }
}
