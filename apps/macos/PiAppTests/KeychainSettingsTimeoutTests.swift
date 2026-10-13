import XCTest
@testable import PiApp

private final class DelayedSettingsStorage: VaultStorage, @unchecked Sendable {
    let memory: MemoryVaultStorage
    let entered: XCTestExpectation
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    init(_ configuration: VaultConfiguration, entered: XCTestExpectation) throws {
        memory = MemoryVaultStorage(try JSONEncoder().encode(configuration)); self.entered = entered
    }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func read() throws -> Data? { try memory.read() }
    func replace(expected: Data?, with replacement: Data) throws {
        lock.lock(); let wait = armed; armed = false; lock.unlock()
        if wait { entered.fulfill(); gate.wait() }
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
}
