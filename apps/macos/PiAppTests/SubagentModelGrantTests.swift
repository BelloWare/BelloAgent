import XCTest
@testable import PiApp

final class SubagentModelGrantTests: XCTestCase {
    @MainActor func testOpeningSessionLoadsCatalogForSubsequentTurnGrants() async throws {
        try await checkColdCatalog(reopen: false)
    }

    @MainActor func testOpeningAlreadyOpenSessionReloadsInvalidatedCatalog() async throws {
        try await checkColdCatalog(reopen: true)
    }

    @MainActor private func checkColdCatalog(reopen: Bool) async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("subagent-models-" + UUID().uuidString)
        let catalog = ModelCatalog(readBundled: { [ModelDescriptor(id: "offered", name: "Offered")] })
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "parent-model"
        profile.baseUrl = "http://127.0.0.1:1"
        var configuration = VaultConfiguration()
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-grant-key")]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))), modelCatalog: catalog)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: WorkspaceRecord.scratchID, title: "Chat", path: nil, profileID: profile.id, connectionTest: true)
        model.chats = [chat]
        if reopen {
            _ = try await model.open(chat)
            try await eventually("The first opening loads its catalog") { model.catalogEntry(for: profile).fetchedAt != nil }
            catalog.invalidate(profileID: profile.id)
        }
        let initial = model.turnOverrides(for: chat)["subagentModels"]
        XCTAssertEqual(initial?.array, [], "Sending proceeds with the current grants before the catalog finishes")
        _ = try await model.open(try XCTUnwrap(model.record(chat.id)))
        try await eventually("Session opening starts the catalog without opening a picker") { model.catalogEntry(for: profile).fetchedAt != nil }
        let later = model.turnOverrides(for: chat)["subagentModels"]
        XCTAssertEqual(later?.array?.compactMap { $0.object?["model"]?.string }, ["offered"])
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
