import XCTest
@testable import PiApp

/// The Settings sheet's connection flow, driven the way a person drives it:
/// a new connection that lists models before it is saved, a rename that
/// sticks, edits that survive a tab switch, a save after another write moved
/// the vault on, a catalog URL change that relists, and a deletion that says
/// what happened.
final class ConnectionSettingsFlowTests: XCTestCase {
    private func scratch() throws -> URL {
        let parent = scratchBase()
        let root = URL(fileURLWithPath: parent).appendingPathComponent("connection-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private static let catalog = #"[{"id":"gateway-router","name":"Gateway router","contextWindow":200000,"maxOutputTokens":16000},{"id":"gateway-mini","name":"Gateway mini","mini":true}]"#
    private static let secondCatalog = #"[{"id":"second-router","name":"Second router"}]"#
    private static func unauthorized() -> ModelListGateway.Reply {
        ModelListGateway.Reply(bytes: Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }

    @MainActor func testANewConnectionListsModelsBeforeItIsSavedAndEveryEditSticks() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { request in
            let authorized = request.contains("Authorization: Bearer sk-typed")
            if request.hasPrefix("GET /catalog ") { return authorized ? .json(Self.catalog) : Self.unauthorized() }
            if request.hasPrefix("GET /second ") { return authorized ? .json(Self.secondCatalog) : Self.unauthorized() }
            return nil
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        XCTAssertTrue(controller.loaded); XCTAssertFalse(controller.isSaved, "an empty vault opens on a new connection")

        // The bundled catalog lists without a key, as soon as the URL is typed.
        controller.draft.profile.name = "Team"; controller.draft.profile.baseUrl = base
        let bundled = await controller.listModels()
        XCTAssertFalse(bundled.isEmpty, "the included Bello catalog needs no key")
        XCTAssertTrue(controller.tabs.contains { $0.0 == controller.draft.profile.id && $0.1 == "Team · new" })

        // A custom catalog on the gateway's origin needs the key: it says so, then lists with the key typed above.
        controller.draft.profile.catalogUrl = base + "/catalog"
        let withoutKey = await controller.listModels()
        XCTAssertTrue(withoutKey.isEmpty)
        XCTAssertEqual(controller.listingEntry.error, GatewayModelDiscovery.Failure.credential.localizedDescription)
        controller.draft.key = "sk-typed"
        let listed = await controller.listModels()
        XCTAssertEqual(listed, ["gateway-router", "gateway-mini"])
        let router = try XCTUnwrap(controller.listingEntry.descriptor(for: "gateway-router")), mini = try XCTUnwrap(controller.listingEntry.descriptor(for: "gateway-mini"))
        controller.choose(router); controller.chooseMini(mini)
        XCTAssertEqual(controller.draft.profile.modelId, "gateway-router"); XCTAssertEqual(controller.draft.profile.contextWindow, 200_000)
        XCTAssertEqual(controller.draft.profile.modelOutputLimit, 16_000); XCTAssertEqual(controller.draft.profile.miniModelId, "gateway-mini")

        // Save: the connection, its key and its choices are in the vault; the sheet may close.
        let saveResult1 = await controller.save(); XCTAssertTrue(saveResult1)
        let saved = try XCTUnwrap(model.profiles.first)
        XCTAssertEqual(saved.name, "Team"); XCTAssertEqual(saved.modelId, "gateway-router"); XCTAssertEqual(saved.miniModelId, "gateway-mini")
        let storedKey = try await model.vault.load().profiles.first?.apiKey; XCTAssertEqual(storedKey, "sk-typed")
        XCTAssertTrue(controller.isSaved); XCTAssertEqual(controller.draft.profile.id, saved.id); XCTAssertTrue(controller.drafts.isEmpty)
        XCTAssertEqual(controller.tabs.map(\.1), ["Team"])

        // Rename: the tab carries a dot until the save, then the name is everywhere.
        let revisionBefore = model.configuration.revision
        controller.draft.profile.name = "Team router"
        XCTAssertTrue(controller.isEdited(saved.id)); XCTAssertEqual(controller.tabs.map(\.1), ["Team router •"])
        let saveResult2 = await controller.save(); XCTAssertTrue(saveResult2)
        XCTAssertEqual(model.profiles.first?.name, "Team router"); XCTAssertEqual(model.profiles.first?.id, saved.id, "a rename keeps the id")
        let storedName = try await model.vault.load().profiles.first?.profile.name; XCTAssertEqual(storedName, "Team router")
        XCTAssertGreaterThan(model.configuration.revision, revisionBefore)
        XCTAssertEqual(controller.tabs.map(\.1), ["Team router"])

        // A second connection, then an edit on the first that survives switching tabs and saves with the rest.
        controller.startNew()
        XCTAssertFalse(controller.isSaved)
        controller.draft.profile.name = "Backup"; controller.draft.profile.baseUrl = "https://backup.invalid"; controller.draft.profile.modelId = "b"; controller.draft.key = "sk-b"
        let saveResult3 = await controller.save(); XCTAssertTrue(saveResult3)
        XCTAssertEqual(model.profiles.count, 2)
        let backup = try XCTUnwrap(model.profiles.first { $0.name == "Backup" })
        controller.select(id: saved.id)
        controller.draft.profile.name = "Team router 2"
        controller.select(id: backup.id)
        XCTAssertEqual(controller.draft.profile.id, backup.id)
        XCTAssertTrue(controller.isEdited(saved.id), "the edit waits in its tab")
        XCTAssertTrue(controller.tabs.contains { $0.0 == saved.id && $0.1 == "Team router 2 •" })
        controller.select(id: saved.id)
        XCTAssertEqual(controller.draft.profile.name, "Team router 2", "coming back shows the edit")
        controller.select(id: backup.id)
        controller.draft.profile.name = "Backup gateway"
        let savedAll = await controller.save(); XCTAssertTrue(savedAll, "Save writes every edited tab")
        XCTAssertEqual(Set(model.profiles.map(\.name)), ["Team router 2", "Backup gateway"])
        XCTAssertTrue(controller.drafts.isEmpty)

        // Another write moved the vault on while the sheet was open: the save still lands.
        try await model.updateConfiguration { $0.dashboard.windowHours = 5 }
        controller.select(id: saved.id)
        controller.draft.profile.name = "Team router 3"
        let saveResult4 = await controller.save(); XCTAssertTrue(saveResult4)
        XCTAssertEqual(model.profiles.first { $0.id == saved.id }?.name, "Team router 3")

        // A changed catalog URL on a saved connection relists, with the saved key, before anything is saved.
        controller.select(id: saved.id)
        controller.draft.profile.catalogUrl = base + "/second"
        let relisted = await controller.listModels()
        XCTAssertEqual(relisted, ["second-router"], "the list follows the URL as typed, using the saved key")
        controller.discardCurrent()
        XCTAssertEqual(controller.draft.profile.catalogUrl, base + "/catalog")

        // Deletion says what it did.
        controller.confirmingDelete = true
        await controller.delete()
        XCTAssertEqual(model.profiles.map(\.name), ["Backup gateway"])
        XCTAssertTrue(controller.message.contains("was deleted"), controller.message)
        XCTAssertEqual(controller.draft.profile.id, backup.id)
    }

    /// "Use Responses" on a saved Messages connection used to leave the model
    /// picker empty with no spinner and no error: the picker read the draft's
    /// catalog slot while the listing call still went to the saved connection,
    /// which refuses an unsupported API and so wrote nothing anywhere. Not even
    /// the bundled catalog, which needs no key at all, could be reached.
    @MainActor func testConvertingASavedMessagesConnectionToResponsesListsTheBundledCatalog() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy: ProfileRecord = {
            var value = ProfileRecord()
            value.api = "anthropic-messages"; value.name = "Team"
            value.baseUrl = "https://gateway.example/v1/messages"; value.modelId = "legacy-router"
            return value
        }()
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let connection = VaultProfile(profile: legacy, apiKey: "sk-legacy")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        XCTAssertEqual(controller.draft.profile.id, legacy.id)
        XCTAssertFalse(controller.supportedAPI)

        // The "Use Responses" button, with nothing else typed.
        controller.draft.profile.api = LiteLLMConfiguration.supportedAPI

        let listed = await controller.listModels()
        XCTAssertFalse(listed.isEmpty, "the converted draft lists through its own slot")
        XCTAssertEqual(controller.listingProfile.id, WorkspaceModel.draftListing(controller.draft.profile).id)
        XCTAssertEqual(controller.listingEntry.models, listed, "the picker reads the slot the listing filled")
        XCTAssertFalse(controller.listingEntry.loading)
        XCTAssertNil(controller.listingEntry.error, "an empty list with no error and no spinner is a dead end for the user")
        try await model.traces.close(); await model.store?.close()
    }

    /// The conflict retry re-read only the vault's revision and then wrote the
    /// sheet's whole stale preferences copy, silently reverting a capture mode,
    /// retention or update toggle another writer had just set.
    @MainActor func testAConflictRetryKeepsAnotherWritersPreferenceChange() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryVaultStorage()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { model.shutdown() }
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        controller.draft.profile.name = "Team"; controller.draft.profile.baseUrl = "https://gateway.example"
        controller.draft.profile.modelId = "router"; controller.draft.key = "sk-first"
        let firstSave = await controller.save(); XCTAssertTrue(firstSave)
        XCTAssertEqual(model.configuration.capture.retentionDays, 30)

        // Another writer changes a preference while this sheet is open.
        let elsewhere = ConfigurationVault(storage: storage)
        _ = try await elsewhere.update(expectedRevision: model.configuration.revision) {
            $0.capture.retentionDays = 3; $0.automaticUpdateChecks = false
        }
        // This sheet changes something else and saves against its stale revision.
        controller.draft.profile.name = "Team router"
        let retried = await controller.save()
        XCTAssertTrue(retried, controller.message)

        let final = try await elsewhere.load()
        XCTAssertEqual(final.profiles.first?.profile.name, "Team router", "this sheet's own edit still lands")
        XCTAssertEqual(final.capture.retentionDays, 3, "the other writer's retention change survives the retry")
        XCTAssertFalse(final.automaticUpdateChecks, "and so does their update-check change")
        try await model.traces.close(); await model.store?.close()
    }

    /// The merge keeps what this sheet edited and takes everything else from
    /// whatever the vault holds now.
    @MainActor func testPreferenceMergeKeepsThisSheetsEditsAndTheOtherWritersRest() {
        var baseline = VaultConfiguration()
        baseline.capture.retentionDays = 30; baseline.dashboard.windowHours = 24; baseline.automaticUpdateChecks = true
        var edits = baseline; edits.dashboard.windowHours = 12
        var current = baseline; current.capture.retentionDays = 3; current.automaticUpdateChecks = false; current.revision = 9
        let merged = ConnectionSettingsController.merging(edits, from: baseline, onto: current)
        XCTAssertEqual(merged.dashboard.windowHours, 12, "the field this sheet edited")
        XCTAssertEqual(merged.capture.retentionDays, 3, "the field someone else edited")
        XCTAssertFalse(merged.automaticUpdateChecks)
        XCTAssertEqual(merged.revision, 9, "always against the revision that is there now")
    }

    /// "+" picked an unsaved connection out of a dictionary, whose order is
    /// unspecified, so with two of them it jumped to either one.
    @MainActor func testNewConnectionOpensPendingDraftsInTheOrderTheTabsShow() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        // A saved connection so "+" has something to leave, then two unsaved ones.
        controller.draft.profile.name = "Team"; controller.draft.profile.baseUrl = "https://gateway.example"
        controller.draft.profile.modelId = "router"; controller.draft.key = "sk-first"
        let firstSave = await controller.save(); XCTAssertTrue(firstSave)
        let saved = try XCTUnwrap(model.profiles.first)

        controller.startNew(); controller.draft.profile.id = "bbb"; controller.draft.profile.name = "Second"
        controller.select(id: saved.id)
        controller.startNew(); controller.draft.profile.id = "aaa"; controller.draft.profile.name = "First"
        controller.select(id: saved.id)
        XCTAssertEqual(Set(controller.tabs.map(\.0)), [saved.id, "aaa", "bbb"])

        // Both unsaved connections are waiting: "+" takes the first of them,
        // in the same order the tab strip lists them, every time.
        for _ in 0..<5 {
            controller.startNew()
            XCTAssertEqual(controller.draft.profile.id, "aaa", "+ must not pick an arbitrary pending draft")
            controller.select(id: saved.id)
        }
        let unsavedTabs = controller.tabs.map(\.0).filter { $0 != saved.id }
        XCTAssertEqual(unsavedTabs, ["aaa", "bbb"], "and that is the order the tabs show")
        controller.discardCurrent()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testAFailedSaveStaysOnItsTabWithTheReason() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        controller.draft.profile.name = "Broken"; controller.draft.profile.baseUrl = "not a url"; controller.draft.profile.modelId = "x"; controller.draft.key = "sk-x"
        let saveResult5 = await controller.save(); XCTAssertFalse(saveResult5)
        XCTAssertEqual(controller.messageTone, .danger); XCTAssertFalse(controller.message.isEmpty)
        // A save that did not happen reaches the window's banner too, exactly
        // as a deletion that did not happen does: closing the sheet over a
        // silent failure left the user believing it was saved.
        XCTAssertTrue(model.error?.contains("was not saved") == true, model.error ?? "nil")
        XCTAssertEqual(controller.draft.profile.name, "Broken", "the form keeps what was typed")
        XCTAssertTrue(model.profiles.isEmpty)
        // A draft that is dropped disappears from the tabs; an empty vault still offers a fresh one.
        controller.discardCurrent()
        XCTAssertFalse(controller.tabs.contains { $0.1 == "Broken · new" })
        XCTAssertEqual(controller.tabs.map(\.1), ["New connection"]); XCTAssertEqual(controller.draft.profile.name, ProfileRecord().name)
    }
}
