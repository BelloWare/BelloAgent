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

    /// A failure migrating local chat limits used to report the vault itself as
    /// unloaded, which disables Save, Test Connection and the model catalog —
    /// and "Reload vault" repeated the same failure, so Settings became
    /// unusable with no way out inside the app.
    @MainActor func testAFailedChatMigrationLeavesTheLoadedVaultUsable() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.modelId = "router"
        let connection = VaultProfile(profile: profile, apiKey: "sk-fixture")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        let store = try XCTUnwrap(model.store)
        // A chat from before output budgets were separated: the migration reads
        // the local store to finish it.
        var legacy = ChatRecord(id: "legacy", workspaceID: "w", title: "Legacy", path: nil, profileID: profile.id)
        legacy.outputBudgetVersion = nil; legacy.maxOutputTokens = 8_000
        model.chats = [legacy]
        await store.close()

        try await model.reloadConfiguration()

        XCTAssertTrue(model.configurationLoaded, "a local store failure is not a vault failure")
        XCTAssertEqual(model.profiles.map(\.id), [profile.id])
        XCTAssertNotNil(model.error, "the migration failure is still reported")
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        XCTAssertTrue(controller.loaded, "Settings must still be able to save")
        try await model.traces.close()
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

        // A running chat never blocks a save: the vault takes the edit, the run keeps going on its own settings.
        var changed = baseline; changed.allowFallbacks = true
        _ = try await changed.save(to: model, comparedTo: baseline, key: "", headers: "", preferences: preferences, expectedRevision: preferences.revision)
        XCTAssertEqual(storage.writes, 2)
        let edited = try await vault.load()
        XCTAssertEqual(edited.profiles.first?.profile.id, profile.id, "an option edit keeps the connection's identity")
        XCTAssertTrue(edited.profiles.first?.profile.advancedJSON?.contains("allowFallbacks") == true, edited.profiles.first?.profile.advancedJSON ?? "")
        XCTAssertTrue(display.hasWork); XCTAssertEqual(display.state, "running"); XCTAssertEqual(display.draft, "Keep this draft")
        XCTAssertTrue(model.opened.contains(chat.id), "no host is attached here, so nothing was closed")
        let editedBaseline = SettingsConnectionForm.loaded(try XCTUnwrap(model.profiles.first { $0.id == profile.id }), isSaved: true)
        var preferencesAgain = model.configuration; preferencesAgain.runtime.workspaceConcurrency = 3

        var form = editedBaseline; form.advanced = editedBaseline.advanced.isEmpty ? " { \n } " : editedBaseline.advanced + " "
        _ = try await form.save(to: model, comparedTo: editedBaseline, key: "", headers: "", preferences: preferencesAgain, expectedRevision: preferencesAgain.revision)

        let saved = try await vault.load()
        XCTAssertEqual(saved.profiles, edited.profiles, "Reformatting the JSON is not a connection edit")
        XCTAssertEqual(saved.runtime.workspaceConcurrency, 3)
        XCTAssertTrue(display.hasWork); XCTAssertEqual(display.draft, "Keep this draft")
        XCTAssertTrue(model.opened.contains(chat.id)); XCTAssertEqual(storage.writes, 3, "the initial connection, the edit, then the preferences")
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
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("settings-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

extension SettingsSaveTests {
    @MainActor private func deletionFixture(baseURL: String = "http://127.0.0.1:1") async throws -> (WorkspaceModel, ChatRecord, ProfileRecord, URL) {
        let root = try scratch()
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        var draft = ProfileRecord(); draft.baseUrl = baseURL; draft.modelId = "fixture"
        let profile = draft, project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        _ = try await vault.update(expectedRevision: 0) {
            $0.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-only")]
            $0.workspaces = [project]
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "deletion-chat", workspaceID: project.id, title: "Retained", path: nil, profileID: profile.id, connectionTest: true)
        model.chats = [chat]; model.displays[chat.id] = SessionDisplay(id: chat.id)
        model.displays[chat.id]?.draft = "Keep this draft"
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        return (model, chat, profile, root)
    }

    @MainActor func testDeletingConnectionStopsHelperWorkEvenWhenTheDisplayIsIdle() async throws {
        let requested = expectation(description: "local request is held open")
        requested.assertForOverFulfill = false
        let gateway = try ModelListGateway { _ in requested.fulfill(); return nil }
        let url = try await gateway.start(); defer { gateway.stop() }
        let (model, chat, profile, root) = try await deletionFixture(baseURL: url)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = try await model.open(chat)
        host.onEvent = nil // The display has not received the helper's running event.
        _ = try await host.request("turn.submit", sessionID: chat.id, params: ["text": .string("Held locally"), "clientTurnId": .string("active")])
        await fulfillment(of: [requested], timeout: 3)
        _ = try await host.request("turn.submit", sessionID: chat.id, params: ["text": .string("Do not start this follow-up"), "clientTurnId": .string("queued")])
        XCTAssertFalse(try XCTUnwrap(model.displays[chat.id]).hasWork)
        let active = try await host.request("session.status", sessionID: chat.id)
        XCTAssertEqual(active.object?["state"]?.string, "running")

        try await model.deleteProfile(profile.id)

        do {
            let stopped = try await host.request("session.status", sessionID: chat.id)
            XCTAssertTrue(["stopping", "paused", "interrupted"].contains(stopped.object?["state"]?.string ?? ""))
            XCTAssertEqual(stopped.object?["queuePaused"]?.bool, true)
            XCTAssertTrue(model.opened.contains(chat.id), "A busy close rejection must retain runtime tracking")
        } catch HostError.rejected(let code, _) { XCTAssertEqual(code, "session_missing") }
        XCTAssertEqual(gateway.requests.count, 1, "The queued request must not start after deleting its connection")
        XCTAssertEqual(model.displays[chat.id]?.draft, "Keep this draft")
        let saved = try await model.vault.load(); XCTAssertFalse(saved.profiles.contains { $0.profile.id == profile.id })
        try await host.shutdownAndWait(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testStopFailurePreservesVaultAndRevokesAlreadyWaitingOperations() async throws {
        let (model, chat, profile, root) = try await deletionFixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let lease = try model.connectionLease(for: chat)
        model.hosts[chat.workspaceID] = HostSupervisor(); model.opened.insert(chat.id)
        let before = try await model.vault.load()

        do { try await model.deleteProfile(profile.id); XCTFail("A failed Stop must not claim the connection was deleted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Host is unavailable")) }

        let after = try await model.vault.load(); XCTAssertEqual(after, before)
        XCTAssertTrue(model.profiles.contains { $0.id == profile.id })
        XCTAssertEqual(model.displays[chat.id]?.draft, "Keep this draft")
        XCTAssertThrowsError(try model.requireConnection(lease), "An operation waiting before deletion must not resume after the failed teardown")
        XCTAssertNoThrow(try model.connectionLease(for: chat), "A new operation may use the retained connection after failure")
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testSuspendedDispatchCannotUseARecreatedConnection() async throws {
        let (model, chat, profile, root) = try await deletionFixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = try await model.open(chat), lease = try model.connectionLease(for: chat)
        let waiting = expectation(description: "command preparation suspended")
        let gate = SettingsConnectionGate(entered: waiting)
        defer { gate.release() }
        let operation = Task {
            await gate.hold()
            try model.requireConnection(lease)
            _ = try await host.request("turn.submit", sessionID: chat.id, params: ["text": .string("Must never dispatch"), "clientTurnId": .string("revoked")])
        }
        await fulfillment(of: [waiting], timeout: 2)
        try await model.deleteProfile(profile.id)
        try await model.saveProfile(profile, key: "synthetic-only")
        _ = try await model.open(try XCTUnwrap(model.chats.first))
        gate.release()
        do { try await operation.value; XCTFail("A recreated profile must not revive a previously prepared command") }
        catch HostError.rejected(let code, _) { XCTAssertEqual(code, "connection_unavailable") }
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id)
        XCTAssertTrue(snapshot.object?["messages"]?.array?.isEmpty == true)
        XCTAssertEqual(model.displays[chat.id]?.draft, "Keep this draft")
        try await host.shutdownAndWait(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testLateSuccessfulOpenIsClosedWithoutResurrectingLostHostTracking() async throws {
        for loseHost in [false, true] {
            let (model, chat, profile, root) = try await deletionFixture()
            defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
            let host = try await model.host(for: XCTUnwrap(model.workspace(for: chat.workspaceID)))
            let lease = try model.connectionLease(for: chat)
            let waiting = expectation(description: "open acknowledgment suspended")
            let gate = SettingsConnectionGate(entered: waiting)
            defer { gate.release() }
            let opening = Task {
                try await model.withConnectionOpen(chat, lease: lease, host: host) {
                    _ = try await host.request("session.open", sessionID: chat.id,
                                               params: ["profile": profile.wire, "apiKey": .string("synthetic-only"), "connectionTest": .bool(true)])
                    await gate.hold()
                }
            }
            await fulfillment(of: [waiting], timeout: 2)
            XCTAssertFalse(model.opened.contains(chat.id))
            try await model.deleteProfile(profile.id)
            if loseHost { try await host.shutdownAndWait() }
            gate.release()
            do { try await opening.value; XCTFail("A late open must reject its deleted connection") }
            catch HostError.rejected(let code, _) { XCTAssertEqual(code, "connection_unavailable") }
            XCTAssertFalse(model.opened.contains(chat.id), "Cleanup must not add a phantom session after host loss")
            if !loseHost {
                do { _ = try await host.request("session.status", sessionID: chat.id); XCTFail("The late runtime must be closed") }
                catch HostError.rejected(let code, _) { XCTAssertEqual(code, "session_missing") }
                try await host.shutdownAndWait()
            }
            XCTAssertEqual(model.displays[chat.id]?.draft, "Keep this draft")
            try await model.traces.close(); await model.store?.close()
        }
    }

    @MainActor func testDeletedConnectionCannotReuseAnAlreadyOpenHelperSession() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        var draft = ProfileRecord(); draft.baseUrl = "http://127.0.0.1:1"; draft.modelId = "fixture"
        let profile = draft
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        _ = try await vault.update(expectedRevision: 0) {
            $0.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-only")]
            $0.workspaces = [project]
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "retained-runtime", workspaceID: project.id, title: "Retained", path: nil, profileID: profile.id)
        model.chats = [chat]; model.displays[chat.id] = SessionDisplay(id: chat.id)
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        let host = try await model.open(chat)
        XCTAssertTrue(host.isReady); XCTAssertTrue(model.opened.contains(chat.id))
        // A vault reload can remove a connection while its helper still holds
        // the previous key. Reusing that runtime must not bypass validation.
        _ = try await vault.update(expectedRevision: model.configuration.revision) { $0.profiles = [] }
        try await model.reloadConfiguration()
        do { _ = try await model.open(chat); XCTFail("The cached helper must not authorize a deleted connection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("connection is unavailable")) }
        try await host.shutdownAndWait()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testDeletingConnectionAlsoStopsUnregisteredSidesAndPreservesDrafts() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        try await model.saveProfile(profile, key: "synthetic-only")
        let parent = ChatRecord(id: "parent", workspaceID: "project", title: "Parent", path: nil, profileID: profile.id)
        model.chats = [parent]
        let side = SideRecord(id: "publishing-side", parentID: parent.id, workspaceID: parent.workspaceID, profileID: profile.id, title: "Side")
        model.sides[parent.id] = side
        let view = SessionDisplay(id: side.id); view.state = "running"; view.queueCount = 1; view.draft = "Keep my draft"
        model.displays[side.id] = view
        try await model.deleteProfile(profile.id)
        XCTAssertEqual(view.state, "interrupted"); XCTAssertEqual(view.queueCount, 0)
        XCTAssertTrue(view.notice.contains("connection was deleted")); XCTAssertEqual(view.draft, "Keep my draft")
        XCTAssertNotNil(model.sides[parent.id], "A deletion must not discard an unsent side draft")
        try await model.traces.close(); await model.store?.close()
    }

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

@MainActor private final class SettingsConnectionGate {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
