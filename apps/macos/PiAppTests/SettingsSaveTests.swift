import XCTest
@testable import PiApp

final class SettingsSaveTests: XCTestCase {
    @MainActor func testMiniModelSavesIndependentlyOfConversationModelAndCanReturnToCatalogDefault() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.modelId = "conversation-router"
        profile.catalogUrl = "https://catalog.example/models"
        profile.advancedJSON = #"{"thinkingLevel":"high","reasoning":true}"#
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-only")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let baseline = SettingsConnectionForm.loaded(profile, isSaved: true)
        var edited = baseline; edited.profile.miniModelId = "catalog-utility"
        let savedID = try await edited.save(to: model, comparedTo: baseline, key: "", headers: "",
                                           preferences: model.configuration, expectedRevision: model.configuration.revision)
        let saved = try XCTUnwrap(model.profiles.first { $0.id == savedID })
        XCTAssertEqual(savedID, profile.id, "Utility choices do not create a new conversation route")
        XCTAssertEqual(saved.miniModelId, "catalog-utility")
        XCTAssertEqual(saved.modelId, profile.modelId); XCTAssertEqual(saved.contextWindow, profile.contextWindow)
        XCTAssertEqual(saved.maxOutputTokens, profile.maxOutputTokens)
        XCTAssertEqual(saved.configuration["thinkingLevel"], .string("high"))

        let secondBaseline = SettingsConnectionForm.loaded(saved, isSaved: true)
        var cleared = secondBaseline; cleared.profile.miniModelId = nil
        _ = try await cleared.save(to: model, comparedTo: secondBaseline, key: "", headers: "",
                                   preferences: model.configuration, expectedRevision: model.configuration.revision)
        let restored = try await vault.load()
        XCTAssertNil(restored.profiles.first?.profile.miniModelId)
        XCTAssertEqual(restored.profiles.first?.profile.modelId, "conversation-router")
        XCTAssertEqual(restored.profiles.first?.apiKey, "synthetic-only")
        try await model.traces.close(); await model.store?.close()
    }

    func testMiniModelValidationRejectsEmptyControlAndOversizedAliases() throws {
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.modelId = "main"
        for invalid in ["", "  ", " mini", "mini ", "mini\nkey", "mini\u{7f}", String(repeating: "🧠", count: 51)] {
            profile.miniModelId = invalid
            XCTAssertThrowsError(try LiteLLMConfiguration.validate(profile, headers: [:]))
        }
        profile.miniModelId = "router/mini"
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(profile, headers: [:]))
        profile.miniModelId = nil
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(profile, headers: [:]))
    }

    @MainActor func testPreferencesPreserveUntouchedLegacyConnectionAndCredentials() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.api = "anthropic-messages"
        profile.baseUrl = "https://gateway.example/v1/messages"; profile.modelId = "legacy-router"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-legacy-key", headers: ["X-Team": "fixture"])
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let form = SettingsConnectionForm.loaded(profile, isSaved: true)
        var preferences = model.configuration; preferences.automaticUpdateChecks = false

        let savedID = try await form.save(to: model, comparedTo: form, key: "", headers: "", preferences: preferences, expectedRevision: preferences.revision)

        let saved = try await vault.load()
        XCTAssertEqual(savedID, profile.id)
        XCTAssertEqual(saved.profiles, [connection], "The displayed replay default must not rewrite a retained Messages connection")
        XCTAssertNil(saved.profiles.first?.profile.advancedJSON)
        XCTAssertFalse(saved.automaticUpdateChecks)
        XCTAssertEqual(storage.writes, 2)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testPreferencesDoNotRewriteAnActiveOnboardingConnectionForJSONFormatting() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = OnboardingState().profile
        profile.baseUrl = "https://gateway.example"; profile.modelId = "auto"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-active-key")
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "running-chat", workspaceID: "project", title: "Running", path: nil, profileID: profile.id)
        let display = SessionDisplay(id: chat.id); display.state = "running"; display.draft = "Keep this draft"
        model.chats = [chat]; model.displays[chat.id] = display; model.opened.insert(chat.id)
        let baseline = SettingsConnectionForm.loaded(profile, isSaved: true)
        var preferences = model.configuration; preferences.runtime.workspaceConcurrency = 3

        var changed = baseline; changed.allowFallbacks = true
        do {
            _ = try await changed.save(to: model, comparedTo: baseline, key: "", headers: "", preferences: preferences, expectedRevision: preferences.revision)
            XCTFail("Actual routing edits must still require the connection to be idle")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Stop this connection's work")) }
        XCTAssertEqual(storage.writes, 1)

        var form = baseline; form.advanced = " { \n } "
        _ = try await form.save(to: model, comparedTo: baseline, key: "", headers: "", preferences: preferences, expectedRevision: preferences.revision)

        let saved = try await vault.load()
        XCTAssertEqual(saved.profiles, [connection], "Pretty-printing the compact onboarding JSON is not a connection edit")
        XCTAssertEqual(saved.runtime.workspaceConcurrency, 3)
        XCTAssertTrue(display.hasWork); XCTAssertEqual(display.draft, "Keep this draft")
        XCTAssertTrue(model.opened.contains(chat.id)); XCTAssertEqual(storage.writes, 2)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testClearedSavedURLRejectsTheWholeSaveAndKeepsEditsForCorrection() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.modelId = "auto"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-original-key", headers: ["X-Team": "original"])
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let original = model.configuration, baseline = SettingsConnectionForm.loaded(profile, isSaved: true)
        var form = baseline; form.profile.baseUrl = ""; form.profile.name = "Edited connection"
        var preferences = original; preferences.automaticUpdateChecks = false
        let key = "synthetic-replacement-key", headers = #"{"X-Team":"changed"}"#

        do {
            _ = try await form.save(to: model, comparedTo: baseline, key: key, headers: headers, preferences: preferences, expectedRevision: original.revision)
            XCTFail("Clearing a saved URL must not silently discard the connection edits")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS URL")) }
        let rejected = try await vault.load()
        XCTAssertEqual(rejected, original); XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(form.profile.baseUrl, ""); XCTAssertEqual(form.profile.name, "Edited connection")
        XCTAssertEqual(form.profile.advancedJSON, profile.advancedJSON)

        form.profile.baseUrl = "https://new-gateway.example"
        let savedID = try await form.save(to: model, comparedTo: baseline, key: key, headers: headers, preferences: preferences, expectedRevision: original.revision)
        let saved = try await vault.load()
        let replacement = try XCTUnwrap(saved.profiles.first { $0.profile.id == savedID })
        XCTAssertNotEqual(savedID, profile.id)
        XCTAssertEqual(saved.profiles.first { $0.profile.id == profile.id }, connection)
        XCTAssertEqual(replacement.profile.name, "Edited connection"); XCTAssertEqual(replacement.profile.baseUrl, form.profile.baseUrl)
        XCTAssertEqual(replacement.apiKey, key); XCTAssertEqual(replacement.headers, ["X-Team": "changed"])
        XCTAssertFalse(saved.automaticUpdateChecks); XCTAssertEqual(storage.writes, 2)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testUntouchedNewFormAllowsPreferencesButPartialConnectionRequiresURL() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let baseline = SettingsConnectionForm.loaded(ProfileRecord(), isSaved: false)
        var preferences = model.configuration; preferences.automaticUpdateChecks = false
        _ = try await baseline.save(to: model, comparedTo: baseline, key: "", headers: "", preferences: preferences, expectedRevision: preferences.revision)
        let original = try await vault.load()
        XCTAssertTrue(original.profiles.isEmpty); XCTAssertFalse(original.automaticUpdateChecks)

        var form = baseline; form.profile.name = "New route"; form.profile.modelId = "auto"
        preferences = original; preferences.automaticUpdateChecks = true
        do {
            _ = try await form.save(to: model, comparedTo: baseline, key: "synthetic-new-key", headers: "", preferences: preferences, expectedRevision: original.revision)
            XCTFail("A partially entered connection must not disappear through a preferences-only save")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS URL")) }
        let rejected = try await vault.load()
        XCTAssertEqual(rejected, original); XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(form.profile.name, "New route"); XCTAssertEqual(form.profile.modelId, "auto")
        try await model.traces.close(); await model.store?.close()
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("settings-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

extension SettingsSaveTests {
    /// Deleting a connection removes it and its key from the vault; its chats stay and say so, and a run still going under it is stopped rather than blocking.
    @MainActor func testDeletingAConnectionStopsItsWorkAndKeepsItsChats() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("delete-connection-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        var first = ProfileRecord(); first.name = "Team router"; first.baseUrl = "https://a.invalid"; first.modelId = "a"
        var second = ProfileRecord(); second.name = "Backup"; second.baseUrl = "https://b.invalid"; second.modelId = "b"
        try await model.saveProfile(first, key: "sk-first"); try await model.saveProfile(second, key: "sk-second")
        XCTAssertEqual(model.profiles.count, 2)
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Uses the router", path: nil, profileID: first.id)
        model.chats = [chat]; let view = SessionDisplay(id: chat.id); model.displays[chat.id] = view
        view.state = "running"; view.queueCount = 2
        model.profileChoice = first.id
        try await model.deleteProfile(first.id)
        XCTAssertEqual(view.state, "interrupted", "a run under the deleted connection is stopped, not a reason to refuse")
        XCTAssertEqual(view.queueCount, 0)
        XCTAssertEqual(model.profiles.map(\.name), ["Backup"])
        XCTAssertEqual(model.profileChoice, second.id, "the choice moves to a remaining connection")
        XCTAssertEqual(model.chats.first?.profileID, first.id, "the chat keeps its history and its former connection id")
        XCTAssertTrue(view.notice.contains("connection was deleted"))
        do { _ = try await model.credentials(for: first); XCTFail("no key remains") } catch { }
        try await model.deleteProfile(second.id)
        XCTAssertTrue(model.profiles.isEmpty); XCTAssertEqual(model.profileChoice, "")
        // Renaming keeps the id: chats stay attached.
        var renamed = ProfileRecord(); renamed.name = "Router"; renamed.baseUrl = "https://c.invalid"; renamed.modelId = "c"
        try await model.saveProfile(renamed, key: "sk-c")
        let saved = try XCTUnwrap(model.profiles.first)
        var edited = saved; edited.name = "Router (renamed)"
        try await model.saveProfile(edited, key: "")
        XCTAssertEqual(model.profiles.first?.id, saved.id); XCTAssertEqual(model.profiles.first?.name, "Router (renamed)")
        let kept = try await model.credentials(for: model.profiles[0])
        XCTAssertEqual(kept["apiKey"]?.string, "sk-c", "the key survives a rename")
    }

    /// Editing a connection's route forks it and records catalog lineage between the two; deleting either must drop that link rather than fail the vault's validation.
    @MainActor func testDeletingAForkedConnectionDropsItsCatalogLinks() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("delete-fork-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        var original = ProfileRecord(); original.name = "Router"; original.baseUrl = "https://a.invalid"; original.modelId = "a"
        try await model.saveProfile(original, key: "sk-a")
        original = try XCTUnwrap(model.profiles.first)
        var edited = original; edited.modelId = "b"
        try await model.saveProfile(edited, key: "")
        let fork = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
        XCTAssertNotEqual(fork.id, original.id); XCTAssertEqual(model.profiles.count, 2)
        XCTAssertEqual(model.configuration.catalogSources, [original.id: fork.id], "the fork is the old route's catalog authority")
        // Deleting the authority: the old route stands on its own again.
        try await model.deleteProfile(fork.id)
        XCTAssertEqual(model.profiles.map(\.id), [original.id]); XCTAssertNil(model.configuration.catalogSources)
        // Fork again, then delete the old route that follows the fork.
        var again = original; again.modelId = "c"
        try await model.saveProfile(again, key: "")
        let second = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
        XCTAssertEqual(model.configuration.catalogSources, [original.id: second.id])
        try await model.deleteProfile(original.id)
        XCTAssertEqual(model.profiles.map(\.id), [second.id]); XCTAssertNil(model.configuration.catalogSources)
        let stored = try await model.vault.load()
        XCTAssertEqual(stored.profiles.map(\.profile.id), [second.id], "the vault itself no longer lists the deleted connections")
        // A stale list: deleting an id the vault no longer has reloads and says so.
        do { try await model.deleteProfile(original.id); XCTFail("nothing to delete") } catch { XCTAssertTrue(error.localizedDescription.contains("no longer in the vault")) }
    }
}
