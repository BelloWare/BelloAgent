import XCTest
@testable import PiApp

private final class DelayedSettingsStorage: VaultStorage, @unchecked Sendable {
    let memory: MemoryVaultStorage
    let entered: XCTestExpectation
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false, failing = false
    init(_ configuration: VaultConfiguration, entered: XCTestExpectation) throws {
        memory = MemoryVaultStorage(try JSONEncoder().encode(configuration)); self.entered = entered
    }
    func arm(failing: Bool = false) { lock.lock(); armed = true; self.failing = failing; lock.unlock() }
    func read() throws -> Data? { try memory.read() }
    func replace(expected: Data?, with replacement: Data) throws {
        lock.lock(); let wait = armed, fail = failing; armed = false; lock.unlock()
        if wait { entered.fulfill(); gate.wait() }
        if wait && fail { throw VaultError.invalid("Synthetic late write failure") }
        try memory.replace(expected: expected, with: replacement)
    }
}

@MainActor final class KeychainSettingsTimeoutTests: XCTestCase {
    private func fixture() throws -> (WorkspaceModel, ConnectionSettingsController, DelayedSettingsStorage) {
        var configuration = VaultConfiguration(), profile = ProfileRecord()
        profile.id = "original"; profile.name = "Original"; profile.api = LiteLLMConfiguration.supportedAPI
        profile.baseUrl = "https://fixture.invalid"; profile.modelId = "synthetic"
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-key")]
        let storage = try DelayedSettingsStorage(configuration, entered: expectation(description: "fake write started"))
        let root = scratchRoot("keychain-timeout")
        let vault = ConfigurationVault(storage: storage, worker: KeychainWorker(timeout: .milliseconds(120)))
        let model = makeWorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        return (model, ConnectionSettingsController(model: model), storage)
    }

    func testLateRouteSaveRefreshesSavedSettingsAndKeepsNewEditsWithoutDuplicatingTheConnection() async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        controller.draft.profile.baseUrl = "https://changed.invalid"
        controller.draft.profile.name = "Submitted"; controller.draft.key = "submitted-key"
        controller.preferences.playsCompletionSound = false
        storage.arm()
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(controller.message.contains("may have been saved"), controller.message)
        XCTAssertFalse(controller.message.contains("was not saved"), controller.message)
        XCTAssertTrue(model.error?.contains("may have been saved") == true, model.error ?? "No banner")
        controller.draft.profile.name = "Typed after timeout"; controller.draft.key = "later-key"
        controller.draft.headers = #"{"x-fixture":"later"}"#
        controller.preferences.runtime.idleGraceSeconds = 150
        storage.gate.signal()
        try await eventually("late save refreshes Settings") { model.profiles.contains { $0.name == "Submitted" } && !controller.busy }
        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertEqual(controller.revision, 1)
        XCTAssertEqual(controller.draft.profile.name, "Typed after timeout")
        XCTAssertEqual(controller.draft.key, "later-key"); XCTAssertEqual(controller.draft.headers, #"{"x-fixture":"later"}"#)
        XCTAssertEqual(controller.preferences.runtime.idleGraceSeconds, 150)
        XCTAssertFalse(controller.preferences.playsCompletionSound)
        let retry = await controller.saveAll()
        XCTAssertEqual(retry, .failed, "Reload must reconcile the route's new identity before another save")
        XCTAssertTrue(controller.message.contains("Reload"), controller.message)
        XCTAssertEqual(storage.memory.writes, 1)
        await controller.load(discardingDrafts: true)
        let unchanged = await controller.saveAll()
        XCTAssertNotEqual(unchanged, .failed)
        XCTAssertEqual(model.profiles.count, 2, "A late route save must never fork a duplicate on retry")
    }

    func testLateDeletionIsReportedAsUncertainAndRefreshesTheSavedList() async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        storage.arm()
        let deletion = Task { await controller.delete() }
        await fulfillment(of: [storage.entered], timeout: 2)
        await deletion.value
        XCTAssertTrue(controller.message.contains("may have been deleted"), controller.message)
        XCTAssertFalse(controller.message.contains("was not deleted"), controller.message)
        storage.gate.signal()
        try await eventually("late deletion refreshes Settings") { model.profiles.isEmpty && !controller.busy }
        XCTAssertEqual(controller.revision, 1)
    }

    func testLateSaveKeepsAPostTimeoutCorrectionBackToTheOriginalPreference() async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        XCTAssertEqual(controller.preferences.runtime.idleGraceSeconds, 120)
        controller.preferences.runtime.idleGraceSeconds = 150
        controller.preferences.playsCompletionSound = false
        storage.arm()
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        controller.preferences.runtime.idleGraceSeconds = 120
        XCTAssertTrue(controller.editedSections.contains(.app), "The correction must stay dirty while the submitted value is uncertain")
        storage.gate.signal()
        try await eventually("refresh the late preference save") { controller.revision == 1 && !controller.busy }
        XCTAssertEqual(model.configuration.runtime.idleGraceSeconds, 150)
        XCTAssertEqual(controller.preferences.runtime.idleGraceSeconds, 120, "Restoring the original value is still a post-submission edit")
        XCTAssertFalse(controller.preferences.playsCompletionSound)
        XCTAssertTrue(controller.editedSections.contains(.app), "The correction still differs from what reached storage")
        XCTAssertTrue(controller.isDirty)
    }

    func testALateFailedSaveKeepsTheSubmittedPreferencesDirty() async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        controller.preferences.runtime.idleGraceSeconds = 150
        storage.arm(failing: true)
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        storage.gate.signal()
        try await eventually("refresh after the late write failed") { controller.message.contains("finished the earlier operation") && !controller.busy }
        XCTAssertEqual(model.configuration.runtime.idleGraceSeconds, 120)
        XCTAssertEqual(controller.preferences.runtime.idleGraceSeconds, 150, "A completion signal does not mean the write succeeded")
        XCTAssertTrue(controller.editedSections.contains(.app))
        XCTAssertEqual(storage.memory.writes, 0)
    }

    private func correctedConnection(switchTabs: Bool) async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        let id = controller.draft.profile.id
        controller.draft.profile.name = "Submitted"
        storage.arm()
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        controller.draft.profile.name = "Original"
        XCTAssertTrue(controller.isEdited(id), "The correction differs from the in-flight submission")
        if switchTabs { controller.startNew() }
        storage.gate.signal()
        try await eventually("refresh the late connection save") { controller.revision == 1 && !controller.busy }
        if switchTabs { controller.select(id: id) }
        XCTAssertEqual(model.profiles.first?.name, "Submitted")
        XCTAssertEqual(controller.draft.profile.name, "Original")
        XCTAssertTrue(controller.isEdited(id), "The correction still differs from saved settings after refresh")
        XCTAssertEqual(controller.draft.profile.revision, model.profiles.first?.revision)
    }

    func testLateSaveKeepsAConnectionCorrectionBackToItsOriginalValue() async throws { try await correctedConnection(switchTabs: false) }
    func testLateSaveKeepsAStashedConnectionCorrectionBackToItsOriginalValue() async throws { try await correctedConnection(switchTabs: true) }

    private func discardedConnection(all: Bool, editAgain: Bool) async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        let id = controller.draft.profile.id
        controller.draft.profile.name = "Submitted"
        controller.preferences.runtime.idleGraceSeconds = 150
        storage.arm()
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        if all { controller.discardAll() } else { controller.discardCurrent() }
        XCTAssertFalse(controller.isEdited(id), "Discard must clear the connection's pending edits")
        if all { XCTAssertFalse(controller.isDirty, "Discard All must clear pending preference edits too") }
        if editAgain {
            controller.draft.profile.name = "After discard"
            controller.preferences.runtime.idleGraceSeconds = 90
        }
        storage.gate.signal()
        try await eventually("refresh after discarding pending edits") { controller.revision == 1 && !controller.busy }
        XCTAssertEqual(model.profiles.first?.name, "Submitted")
        XCTAssertEqual(model.configuration.runtime.idleGraceSeconds, 150)
        XCTAssertEqual(controller.draft.profile.name, editAgain ? "After discard" : "Submitted")
        XCTAssertEqual(controller.preferences.runtime.idleGraceSeconds, editAgain ? 90 : 150)
        XCTAssertEqual(controller.isEdited(id), editAgain)
        XCTAssertEqual(controller.isDirty, editAgain)
    }

    func testDiscardAllDuringATimedOutSaveAdoptsTheLateResult() async throws { try await discardedConnection(all: true, editAgain: false) }
    func testDiscardCurrentDuringATimedOutSaveAdoptsTheLateResult() async throws { try await discardedConnection(all: false, editAgain: false) }
    func testEditsAfterDiscardAllSurviveTheLateSave() async throws { try await discardedConnection(all: true, editAgain: true) }
    func testEditsAfterDiscardCurrentSurviveTheLateSave() async throws { try await discardedConnection(all: false, editAgain: true) }

    func testALateSuccessfulSaveWithoutNewEditsLeavesSettingsClean() async throws {
        let (_, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        controller.draft.profile.name = "Submitted"
        controller.preferences.runtime.idleGraceSeconds = 150
        storage.arm()
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        storage.gate.signal()
        try await eventually("refresh the successful late save") { controller.revision == 1 && !controller.busy }
        XCTAssertEqual(controller.draft.profile.name, "Submitted")
        XCTAssertEqual(controller.preferences.runtime.idleGraceSeconds, 150)
        XCTAssertFalse(controller.isEdited(controller.draft.profile.id), "Saved normalization is not an unsaved edit")
        XCTAssertFalse(controller.isDirty)
    }

    private func lateFallbackToggle(revert: Bool) async throws {
        let (model, controller, storage) = try fixture()
        defer { storage.gate.signal() }
        await controller.load(discardingDrafts: false)
        controller.draft.allowFallbacks = true
        storage.arm()
        let save = Task { await controller.saveAll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let outcome = await save.value
        XCTAssertEqual(outcome, .failed)
        if revert { controller.draft.allowFallbacks = false }
        storage.gate.signal()
        try await eventually("refresh the late fallback save") { controller.revision == 1 && !controller.busy }
        let saved = try XCTUnwrap(model.profiles.first)
        XCTAssertTrue(SettingsConnectionForm.loaded(saved, isSaved: true).allowFallbacks)
        XCTAssertEqual(controller.draft.allowFallbacks, !revert)
        XCTAssertEqual(controller.isDirty, revert, "Only a newer fallback edit should remain unsaved after successful normalization")
    }

    func testALateSuccessfulFallbackToggleLeavesSettingsClean() async throws { try await lateFallbackToggle(revert: false) }
    func testALateSuccessfulFallbackToggleKeepsANewerCorrection() async throws { try await lateFallbackToggle(revert: true) }
}
