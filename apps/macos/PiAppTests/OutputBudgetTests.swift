import XCTest
@testable import PiApp

final class OutputBudgetTests: XCTestCase {
    private func profile() -> ProfileRecord {
        var value = ProfileRecord(); value.id = "connection"; value.modelId = "configured"
        value.baseUrl = "https://gateway.example/v1"; value.maxOutputTokens = 8_192
        return value
    }

    func testCatalogCeilingDoesNotRaiseBudgetAndSmallerModelClampsIt() throws {
        let configured = profile()
        let larger = ModelDescriptor(id: "large", name: "Large", contextWindow: 1_048_576, maxOutputTokens: 393_216).applying(to: configured)
        XCTAssertEqual(larger.maxOutputTokens, 8_192)
        XCTAssertEqual(larger.modelOutputLimit, 393_216)
        XCTAssertEqual(larger.wire.object?["maxOutputTokens"], .number(8_192))
        XCTAssertEqual(larger.wire.object?["modelOutputLimit"], .number(393_216))
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(larger, headers: [:]))
        let smaller = ModelDescriptor(id: "small", name: "Small", contextWindow: 32_000, maxOutputTokens: 2_000).applying(to: configured)
        XCTAssertEqual(smaller.maxOutputTokens, 2_000); XCTAssertEqual(smaller.modelOutputLimit, 2_000)
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(smaller, headers: [:]))
        var manual = larger; manual.modelId = "unknown-route"
        XCTAssertNil(manual.modelOutputLimit, "A manual alias cannot inherit another model's capability")
        XCTAssertEqual(manual.maxOutputTokens, 8_192)
    }

    func testIndependentCeilingMayExceedContextOrSitBelowTheBudget() throws {
        let records = try ModelCatalogEndpoint().parse(Data(#"[{"id":"wide-output","contextWindow":4096,"maxOutputTokens":8192}]"#.utf8))
        let selected = try XCTUnwrap(records.first).applying(to: profile())
        XCTAssertEqual(selected.modelOutputLimit, 8_192)
        XCTAssertEqual(selected.maxOutputTokens, 4_095)
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(selected, headers: [:]))
        for ceiling in [0, -1, 1_000_001] {
            var invalid = profile(); invalid.modelOutputLimit = ceiling
            XCTAssertThrowsError(try LiteLLMConfiguration.validate(invalid, headers: [:]))
        }
        // The budget is a local reserve and the ceiling is what requests carry: a ceiling below the budget is fine.
        var lower = profile(); lower.modelOutputLimit = 8_191
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(lower, headers: [:]))
        XCTAssertEqual(lower.maxOutputTokens, 8_192)
    }

    func testOldExplicitProfileBudgetIsPreservedAndNewFieldsRoundTrip() throws {
        let bytes = Data(#"{"id":"connection","revision":"r","name":"Existing","providerId":"litellm","modelId":"configured","api":"openai-responses","baseUrl":"https://gateway.example","contextWindow":128000,"maxOutputTokens":32000}"#.utf8)
        var restored = try JSONDecoder().decode(ProfileRecord.self, from: bytes)
        XCTAssertEqual(restored.maxOutputTokens, 32_000, "Historical configured budgets have no provenance; never guess that a user's setting was a catalog default")
        XCTAssertNil(restored.modelOutputLimit)
        restored.modelOutputLimit = 65_536
        let again = try JSONDecoder().decode(ProfileRecord.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(again, restored)
        XCTAssertEqual(again.wire.object?["modelOutputLimit"], .number(65_536))
    }

    func testLegacyChatCeilingMigratesOnceToConfiguredBudgetAndPersists() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("output-budget-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let raw = Data(#"{"id":"chat","workspaceID":"project","title":"Old chat","profileID":"connection","toolMode":"editing","imported":false,"model":"large","contextWindow":1048576,"maxOutputTokens":393216}"#.utf8)
        let legacy = try JSONDecoder().decode(ChatRecord.self, from: raw)
        XCTAssertNil(legacy.outputBudgetVersion)
        try await store.put(legacy, kind: "chat", id: legacy.id)
        let configured = profile()
        let migratedChats = try await store.loadChats(profiles: [configured])
        let migrated = try XCTUnwrap(migratedChats.first)
        XCTAssertEqual(migrated.modelOutputLimit, 393_216); XCTAssertEqual(migrated.maxOutputTokens, 8_192)
        XCTAssertEqual(migrated.outputBudgetVersion, 1)
        let wire = TurnOverrides.params(for: migrated)
        XCTAssertEqual(wire["maxOutputTokens"], .number(8_192)); XCTAssertEqual(wire["modelOutputLimit"], .number(393_216))
        await store.close()
        let reopened = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        var changed = configured; changed.maxOutputTokens = 1_024
        let retained = try await reopened.loadChats(profiles: [changed])
        XCTAssertEqual(retained.first, migrated, "Migration must not keep rewriting an established chat budget")
        await reopened.close()
    }

    func testLegacyDefaultsMigrateButTitleTaskBudgetAndNewChatBudgetRemainExplicit() throws {
        let raw = Data(#"{"model":"large","thinkingLevel":"high","contextWindow":1048576,"maxOutputTokens":131072}"#.utf8)
        let legacy = try JSONDecoder().decode(ChatModelDefaults.self, from: raw)
        var next = ChatRecord(id: "next", workspaceID: "project", title: "New", path: nil, profileID: "connection")
        legacy.apply(to: &next, profile: profile())
        XCTAssertEqual(next.maxOutputTokens, 8_192); XCTAssertEqual(next.modelOutputLimit, 131_072)
        let remembered = ChatModelDefaults(chat: next)
        let restored = try JSONDecoder().decode(ChatModelDefaults.self, from: JSONEncoder().encode(remembered))
        XCTAssertEqual(restored, remembered)
        var other = ChatRecord(id: "other", workspaceID: "project", title: "New", path: nil, profileID: "connection")
        restored.apply(to: &other, profile: profile())
        XCTAssertEqual(other.maxOutputTokens, 8_192); XCTAssertEqual(other.modelOutputLimit, 131_072)
        var task = ChatRecord(id: "title", workspaceID: "scratch", title: "Title generation", path: nil, profileID: "connection", maxOutputTokens: 512, outputBudgetVersion: nil)
        task.backgroundTask = "session-title"; task.migrateOutputBudget(profile: profile())
        XCTAssertEqual(task.maxOutputTokens, 512); XCTAssertNil(task.modelOutputLimit)
        var explicit = ChatRecord(id: "explicit", workspaceID: "project", title: "New", path: nil, profileID: "connection", maxOutputTokens: 16_000, modelOutputLimit: 32_000)
        explicit.migrateOutputBudget(profile: profile())
        XCTAssertEqual(explicit.maxOutputTokens, 16_000); XCTAssertEqual(explicit.modelOutputLimit, 32_000)
    }

    @MainActor func testConfigurationReloadMigratesPreviouslyUnavailableBudgetWithoutReplacingLiveChat() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("output-budget-reload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = profile(), vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [VaultProfile(profile: configured, apiKey: "synthetic-only")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        var legacy = ChatRecord(id: "legacy", workspaceID: "project", title: "Saved title", path: nil, profileID: configured.id,
                                model: "large", contextWindow: 1_048_576, maxOutputTokens: 393_216, outputBudgetVersion: nil)
        try await model.store?.put(legacy, kind: "chat", id: legacy.id)
        legacy.title = "Live title"; model.chats = [legacy]
        let display = SessionDisplay(id: legacy.id); display.draft = "Do not replace my draft"; model.displays[legacy.id] = display
        try await model.reloadConfiguration()
        XCTAssertEqual(model.chats.first?.maxOutputTokens, 8_192)
        XCTAssertEqual(model.chats.first?.modelOutputLimit, 393_216)
        XCTAssertEqual(model.chats.first?.title, "Live title")
        XCTAssertEqual(display.draft, "Do not replace my draft")
        let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: legacy.id)
        XCTAssertEqual(stored?.maxOutputTokens, 8_192); XCTAssertEqual(stored?.outputBudgetVersion, 1)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testPickerPersistsConfiguredBudgetBesideCatalogCeilingAndSideRetainsBoth() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("output-budget-picker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let configured = profile(); model.profiles = [configured]
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "New", path: nil, profileID: configured.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        _ = await model.listModels(for: configured)
        await model.setModel("deepseek-v4.1-flash", for: chat.id)
        let selected = try XCTUnwrap(model.record(chat.id))
        XCTAssertEqual(selected.maxOutputTokens, 8_192); XCTAssertEqual(selected.modelOutputLimit, 393_216)
        let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(stored, selected)
        let side = SideRecord(id: "side", parentID: chat.id, workspaceID: chat.workspaceID, profileID: chat.profileID, title: "Side", model: selected.model, contextWindow: selected.contextWindow, maxOutputTokens: selected.maxOutputTokens, modelOutputLimit: selected.modelOutputLimit)
        XCTAssertEqual(TurnOverrides.params(for: side.chat)["maxOutputTokens"], .number(8_192))
        XCTAssertEqual(TurnOverrides.params(for: side.chat)["modelOutputLimit"], .number(393_216))
        await model.store?.close()
    }
}
