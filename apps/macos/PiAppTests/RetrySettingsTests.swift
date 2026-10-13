import XCTest
import AppKit
@testable import PiApp

/// Settings ▸ Connections ▸ Retries: one retry setting for every connection
/// (pi's settings.retry), saved in the vault with the other preferences,
/// shown with its back-off, and handed to every helper when it starts and
/// whenever it changes. The end-to-end case runs the packaged helper; no
/// request leaves the machine.
@MainActor final class RetrySettingsTests: XCTestCase {
    func testPiDefaultsAndTheBackoffDoubles() {
        let retry = RetryPreferences()
        XCTAssertEqual(retry, RetryPreferences(enabled: true, maxRetries: 3, baseDelaySeconds: 2), "pi's settings.retry")
        XCTAssertEqual(retry.delays, [2, 4, 8])
        XCTAssertEqual(retry.summary, "Waits 2 s, 4 s, 8 s")
        XCTAssertEqual(RetryPreferences(enabled: true, maxRetries: 5, baseDelaySeconds: 3).delays, [3, 6, 12, 24, 48], "first delay × 2^(n−1)")
        XCTAssertEqual(RetryPreferences(enabled: true, maxRetries: 10, baseDelaySeconds: 60).summary,
                       "Waits 60 s, 2 min, 4 min, 8 min, 16 min, 32 min, 64 min, 2.1 h, 4.3 h, 8.5 h")
        XCTAssertEqual(RetryPreferences(enabled: false, maxRetries: 3, baseDelaySeconds: 2).summary, "Off: a failed request stops at once.")
        XCTAssertEqual(RetryPreferences(enabled: true, maxRetries: 0, baseDelaySeconds: 2).summary, "No retries: a failed request stops at once.")
        XCTAssertEqual(RetryPreferences(enabled: true, maxRetries: 4, baseDelaySeconds: 5).wire,
                       .object(["enabled": .bool(true), "maxRetries": .number(4), "baseDelayMs": .number(5_000)]))
    }

    func testTheVaultKeepsItAndOlderVaultsRetryAsPiDoes() async throws {
        let older = try JSONDecoder().decode(VaultConfiguration.self, from: JSONEncoder().encode(VaultConfiguration()))
        XCTAssertNil(older.retry); XCTAssertEqual(older.retrySettings, RetryPreferences())
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.retry = RetryPreferences(enabled: false, maxRetries: 6, baseDelaySeconds: 9) }
        let saved = try await vault.load()
        XCTAssertEqual(saved.retrySettings, RetryPreferences(enabled: false, maxRetries: 6, baseDelaySeconds: 9))
        for bad in [RetryPreferences(enabled: true, maxRetries: 11, baseDelaySeconds: 2), RetryPreferences(enabled: true, maxRetries: -1, baseDelaySeconds: 2),
                    RetryPreferences(enabled: true, maxRetries: 3, baseDelaySeconds: 0), RetryPreferences(enabled: true, maxRetries: 3, baseDelaySeconds: 61)] {
            var configuration = VaultConfiguration(); configuration.retry = bad
            XCTAssertThrowsError(try configuration.validate(persisted: false), "\(bad)")
        }
    }

    private func settingsFixture() async throws -> (WorkspaceModel, ConfigurationVault, ConnectionSettingsController) {
        let root = scratchRoot("retry-settings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        var profile = ProfileRecord(); profile.name = "Team"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "team-model"
        profile.contextWindow = 16000; profile.maxOutputTokens = 2048
        let connection = VaultProfile(profile: profile, apiKey: "sk-saved")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        addTeardownBlock { @MainActor in model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        return (model, vault, controller)
    }

    /// An edit marks Connections unsaved; Save All writes it, Discard drops it.
    func testAnEditIsUnsavedUntilSaveAllAndDiscardDropsIt() async throws {
        let (model, vault, controller) = try await settingsFixture()
        controller.preferences.retrySettings.maxRetries = 5
        XCTAssertEqual(controller.editedSections, [.connections])
        let outcome = await controller.saveAll()
        XCTAssertEqual(outcome, .saved, controller.message)
        let saved = try await vault.load()
        XCTAssertEqual(saved.retrySettings, RetryPreferences(enabled: true, maxRetries: 5, baseDelaySeconds: 2))
        XCTAssertEqual(model.configuration.retrySettings.maxRetries, 5)
        XCTAssertFalse(controller.isDirty)
        controller.preferences.retrySettings.enabled = false
        XCTAssertTrue(controller.isDirty)
        controller.discardAll()
        XCTAssertFalse(controller.isDirty); XCTAssertTrue(controller.preferences.retrySettings.enabled)
        // Choosing the saved value again is not an edit.
        controller.preferences.retrySettings = RetryPreferences(enabled: true, maxRetries: 5, baseDelaySeconds: 2)
        XCTAssertFalse(controller.isDirty)
    }

    /// The group sits on the Connections page, with Pi controls, and its
    /// summary follows every edit.
    func testTheGroupShowsTheBackoffAsItIsEdited() async throws {
        let (model, _, controller) = try await settingsFixture()
        model.settingsSection = .connections
        let view = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        addTeardownBlock { @MainActor in window.close() }
        view.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, _ id: String) -> T? {
            func walk(_ v: NSView) -> T? { if let t = v as? T, t.accessibilityIdentifier() == id { return t }; for s in v.subviews { if let f = walk(s) { return f } }; return nil }
            return walk(view)
        }
        var summary: RowText?
        for _ in 0..<200 where summary == nil { view.refresh(); view.layoutSubtreeIfNeeded(); summary = find(RowText.self, "settings-retry-summary"); if summary == nil { try await Task.sleep(for: .milliseconds(10)) } }
        let line = try XCTUnwrap(summary, "the Retries group is on the Connections page")
        XCTAssertEqual(line.block.text, "Waits 2 s, 4 s, 8 s")
        let toggle = try XCTUnwrap(find(PiKit.Switch.self, "settings-retry-enabled"))
        let maximum = try XCTUnwrap(find(PiKit.Stepper.self, "settings-retry-maximum"))
        let delay = try XCTUnwrap(find(PiKit.Stepper.self, "settings-retry-delay"))
        XCTAssertTrue(toggle.isOn); XCTAssertEqual(maximum.value, 3); XCTAssertEqual(delay.value, 2)
        maximum.increase.performClick(nil); delay.increase.performClick(nil)
        XCTAssertEqual(controller.preferences.retrySettings, RetryPreferences(enabled: true, maxRetries: 4, baseDelaySeconds: 3))
        view.refresh()
        XCTAssertEqual(line.block.text, "Waits 3 s, 6 s, 12 s, 24 s")
        toggle.performClick(nil)
        XCTAssertFalse(controller.preferences.retrySettings.enabled)
        view.refresh()
        XCTAssertEqual(line.block.text, "Off: a failed request stops at once.")
        XCTAssertEqual(controller.editedSections, [.connections])
    }

    /// Every helper starts with the saved setting, and every running helper
    /// takes a saved change: one project's and another's alike.
    func testEveryHelperGetsTheSettingAtStartAndWhenItChanges() async throws {
        let root = scratchRoot("retry-helpers")
        let first = root.appendingPathComponent("one"), second = root.appendingPathComponent("two")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "retry-one", path: first.path, trusted: true), WorkspaceRecord(id: "retry-two", path: second.path, trusted: true)]
        configuration.retry = RetryPreferences(enabled: true, maxRetries: 5, baseDelaySeconds: 7)
        let vault = try ConfigurationVault(storage: MemoryVaultStorage(JSONEncoder().encode(configuration)))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        await model.restore()
        let one = try await model.host(for: XCTUnwrap(model.workspace(for: "retry-one")))
        func helperRetry(_ host: HostSupervisor) async throws -> WireValue? { try await host.request("runtime.info").object?["retry"] }
        let started = try await helperRetry(one)
        XCTAssertEqual(started, .object(["enabled": .bool(true), "maxRetries": .number(5), "baseDelayMs": .number(7_000)]), "workspace.open carries the saved setting")

        let two = try await model.host(for: XCTUnwrap(model.workspace(for: "retry-two")))
        var changed = model.configuration; changed.retry = RetryPreferences(enabled: false, maxRetries: 2, baseDelaySeconds: 1)
        try await model.savePreferences(changed, expectedRevision: model.configuration.revision)
        let expected = WireValue.object(["enabled": .bool(false), "maxRetries": .number(2), "baseDelayMs": .number(1_000)])
        for host in [one, two] {
            var seen: WireValue?
            for _ in 0..<500 { seen = try await helperRetry(host); if seen == expected { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(seen, expected, "a running helper takes the saved change")
        }
        XCTAssertNil(model.error, model.error ?? "")
    }
}
