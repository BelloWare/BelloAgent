import XCTest
@testable import PiApp

/// Settings' one save contract: Save All saves everything, Cancel discards
/// everything, and closing, reloading or quitting with unsaved edits asks
/// Save All, Discard Changes or Keep Editing instead of dropping them.
@MainActor final class SettingsUnsavedTests: XCTestCase {
    private let secret = "sk-settings-secret-typed"
    private var asked: [NSAlert] = []

    /// A vault with one saved connection, "Team", and a controller loaded on it.
    private func fixture() async throws -> (WorkspaceModel, MemoryVaultStorage, ConnectionSettingsController) {
        let root = scratchRoot("settings-unsaved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        var profile = ProfileRecord(); profile.name = "Team"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "team-model"
        profile.contextWindow = 16000; profile.maxOutputTokens = 2048
        let connection = VaultProfile(profile: profile, apiKey: "sk-saved")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        addTeardownBlock { @MainActor in model.shutdown() }
        try await model.reloadConfiguration()
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        XCTAssertTrue(controller.isSaved); XCTAssertFalse(controller.isDirty)
        return (model, storage, controller)
    }
    private func answer(_ response: NSApplication.ModalResponse, also: @escaping @MainActor () -> Void = {}) {
        addTeardownBlock { @MainActor in PiQuestion.shared.answerAlert = nil }
        PiQuestion.shared.answerAlert = { [unowned self] alert in asked.append(alert); also(); return response }
    }
    private let save = NSApplication.ModalResponse.alertFirstButtonReturn
    private let discard = NSApplication.ModalResponse.alertSecondButtonReturn
    private let keep = NSApplication.ModalResponse.alertThirdButtonReturn

    func testEveryKindOfEditMarksItsSection() async throws {
        let (_, _, controller) = try await fixture()
        controller.draft.key = secret
        XCTAssertEqual(controller.editedSections, [.connections])
        controller.draft.key = ""; controller.preferences.capture.retentionDays += 1
        XCTAssertEqual(controller.editedSections, [.usage])
        controller.preferences.playsCompletionSound.toggle()
        XCTAssertEqual(controller.editedSections, [.usage, .chats])
        controller.preferences.automaticUpdateChecks.toggle()
        XCTAssertEqual(controller.editedSections, [.usage, .chats, .app])
        controller.startNew(); controller.draft.profile.name = "Second"
        XCTAssertTrue(controller.editedSections.contains(.connections))
    }

    func testDiscardAllDropsEveryEditAndWritesNothing() async throws {
        let (model, storage, controller) = try await fixture()
        let writes = storage.writes
        controller.draft.profile.name = "Renamed"; controller.draft.key = secret
        controller.startNew(); controller.draft.profile.name = "Draft"
        controller.preferences.playsCompletionSound.toggle()
        controller.confirmingTest = true; controller.confirmingDelete = true
        controller.discardAll()
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(controller.draft.profile.name, model.profiles.first?.name)
        XCTAssertFalse(controller.tabs.contains { $0.1.contains("Draft") })
        XCTAssertFalse(controller.confirmingTest); XCTAssertFalse(controller.confirmingDelete)
        XCTAssertEqual(storage.writes, writes)
    }

    func testCloseWhenCleanAsksNothing() async throws {
        let (_, _, controller) = try await fixture()
        answer(keep)
        let closed = await controller.requestClose()
        XCTAssertTrue(closed); XCTAssertTrue(asked.isEmpty)
    }

    func testKeepEditingKeepsEverythingAndStaysOpen() async throws {
        let (_, storage, controller) = try await fixture()
        let writes = storage.writes
        controller.draft.profile.name = "Renamed"; controller.preferences.playsCompletionSound.toggle()
        answer(keep)
        let closed = await controller.requestClose()
        XCTAssertFalse(closed)
        XCTAssertEqual(asked.count, 1)
        let alert = try XCTUnwrap(asked.first)
        XCTAssertEqual(alert.buttons.map(\.title), ["Save All", "Discard Changes", "Keep Editing"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "d", "\u{1b}"])
        XCTAssertTrue(alert.informativeText.contains("Connections") && alert.informativeText.contains("Chats & notifications"), alert.informativeText)
        XCTAssertEqual(controller.draft.profile.name, "Renamed"); XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(storage.writes, writes)
    }

    func testDiscardClosesWithoutWriting() async throws {
        let (_, storage, controller) = try await fixture()
        let writes = storage.writes
        controller.draft.profile.name = "Renamed"; controller.draft.key = secret
        answer(discard)
        let closed = await controller.requestClose()
        XCTAssertTrue(closed); XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(storage.writes, writes)
    }

    func testSaveAllFromTheQuestionSavesThenCloses() async throws {
        let (model, _, controller) = try await fixture()
        controller.draft.profile.name = "Renamed"; controller.preferences.playsCompletionSound.toggle()
        let sound = controller.preferences.completionSoundEnabled
        answer(save)
        let closed = await controller.requestClose()
        XCTAssertTrue(closed); XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(model.profiles.first?.name, "Renamed")
        let stored = try await model.vault.load()
        XCTAssertEqual(stored.completionSoundEnabled, sound)
    }

    /// Save All from the question fails: Settings stays open with every edit
    /// and the reason, and the typed key appears nowhere in it.
    func testAFailedSaveFromTheQuestionStaysOpenWithTheEdits() async throws {
        let (model, _, controller) = try await fixture()
        controller.draft.profile.baseUrl = "not a url"; controller.draft.key = secret
        answer(save)
        let closed = await controller.requestClose()
        XCTAssertFalse(closed)
        XCTAssertEqual(controller.draft.profile.baseUrl, "not a url"); XCTAssertEqual(controller.draft.key, secret)
        XCTAssertTrue(controller.isDirty); XCTAssertEqual(controller.messageTone, .danger)
        XCTAssertFalse(controller.message.contains(secret)); XCTAssertFalse((model.error ?? "").contains(secret))
    }

    func testASaveUnderWayKeepsSettingsOpenWithoutAsking() async throws {
        let (_, _, controller) = try await fixture()
        controller.draft.profile.name = "Renamed"
        controller.busy = true
        answer(discard)
        let closed = await controller.requestClose()
        XCTAssertFalse(closed); XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(controller.message, "Wait for the save to finish.")
        controller.busy = false
    }

    /// A second Escape or close while the question is up asks nothing more.
    func testRepeatedClosesAskOnce() async throws {
        let (_, _, controller) = try await fixture()
        controller.draft.profile.name = "Renamed"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil)
        controller.presentationWindow = window
        var shown: [NSAlert] = [], reply: ((NSApplication.ModalResponse) -> Void)?
        let present = PiQuestion.shared.present
        addTeardownBlock { @MainActor in PiQuestion.shared.present = present; window.orderOut(nil) }
        PiQuestion.shared.present = { alert, _, answer in shown.append(alert); reply = answer }
        let first = Task { await controller.requestClose() }
        try await eventually("the question is up") { reply != nil }
        let second = await controller.requestClose()
        XCTAssertFalse(second)
        XCTAssertEqual(shown.count, 1)
        reply?(.alertThirdButtonReturn)
        let closed = await first.value
        XCTAssertFalse(closed); XCTAssertEqual(shown.count, 1)
    }

    func testReloadAsksAndKeepEditingKeepsTheEdits() async throws {
        let (_, storage, controller) = try await fixture()
        let writes = storage.writes
        controller.draft.profile.name = "Renamed"
        answer(.alertSecondButtonReturn)
        await controller.requestReload()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.messageText, "Discard unsaved changes and reload?")
        XCTAssertEqual(controller.draft.profile.name, "Renamed")
        XCTAssertEqual(storage.writes, writes)
    }

    func testReloadConfirmedDropsTheEdits() async throws {
        let (_, _, controller) = try await fixture()
        controller.draft.profile.name = "Renamed"
        answer(.alertFirstButtonReturn)
        await controller.requestReload()
        XCTAssertEqual(controller.draft.profile.name, "Team"); XCTAssertFalse(controller.isDirty)
    }

    /// A reload that can't read the vault leaves the only copy of the edits alone.
    func testAFailedReloadKeepsTheEdits() async throws {
        let (_, storage, controller) = try await fixture()
        controller.draft.profile.name = "Renamed"; controller.preferences.playsCompletionSound.toggle()
        storage.readError = .busy
        answer(.alertFirstButtonReturn)
        await controller.requestReload()
        XCTAssertEqual(controller.draft.profile.name, "Renamed"); XCTAssertTrue(controller.editedSections.contains(.chats))
        XCTAssertEqual(controller.messageTone, .danger)
        storage.readError = nil
    }

    /// The first tab saves, the second fails: Settings says which saved,
    /// keeps the failed tab's edits on screen, and counts the saved ones (and
    /// the preferences saved with them) as saved.
    func testASecondTabFailingAfterTheFirstSavedSaysWhatSaved() async throws {
        let (model, _, controller) = try await fixture()
        controller.draft.profile.name = "Team renamed"
        controller.preferences.playsCompletionSound.toggle()
        controller.startNew()
        controller.draft.profile.name = "Broken"; controller.draft.profile.baseUrl = "not a url"; controller.draft.profile.modelId = "x"; controller.draft.key = secret
        let saved = await controller.saveAll()
        XCTAssertEqual(saved, .failed)
        XCTAssertTrue(controller.message.hasPrefix("Saved “Team renamed” and your preferences. “Broken” was not saved:"), controller.message)
        XCTAssertEqual(model.error, controller.message)
        XCTAssertFalse(controller.message.contains(secret))
        XCTAssertEqual(model.profiles.first?.name, "Team renamed")
        XCTAssertEqual(controller.draft.profile.name, "Broken", "the failed tab is the one shown")
        XCTAssertEqual(controller.editedSections, [.connections], "only the failed tab is still unsaved")
        XCTAssertFalse(controller.isEdited(model.profiles[0].id))
    }

    /// Two quick Save All clicks write once.
    func testRepeatedSaveAllWritesOnce() async throws {
        let (_, storage, controller) = try await fixture()
        controller.draft.profile.name = "Renamed"
        let writes = storage.writes
        async let first = controller.saveAll()
        async let second = controller.saveAll()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes.filter { $0 == .saved }.count, 1)
        XCTAssertEqual(storage.writes, writes + 1)
    }

    /// The sheet's editor outlives one showing of the sheet: closed by
    /// anything other than Cancel, Save or Discard, its edits are kept.
    func testTheSheetEditorKeepsItsEditsAcrossShowings() async throws {
        let (model, _, _) = try await fixture()
        let editor = model.settingsSheetEditor()
        await editor.load(discardingDrafts: false)
        editor.draft.profile.name = "Kept"
        XCTAssertTrue(model.settingsSheetEditor() === editor)
        XCTAssertTrue(model.settingsEditors.allObjects.contains { $0 === editor })
        await editor.load(discardingDrafts: false)
        XCTAssertEqual(editor.draft.profile.name, "Kept")
    }

    /// Showing Settings again keeps what was typed: edited preferences and
    /// a new connection with its key, not yet stashed in a tab.
    func testReopeningKeepsEditedPreferencesAndANewConnection() async throws {
        let (_, _, controller) = try await fixture()
        controller.preferences.capture.retentionDays = 77
        controller.startNew(); controller.draft.profile.name = "Fresh"; controller.draft.key = secret
        await controller.load(discardingDrafts: false)
        XCTAssertEqual(controller.preferences.capture.retentionDays, 77)
        XCTAssertEqual(controller.draft.profile.name, "Fresh"); XCTAssertEqual(controller.draft.key, secret)
        XCTAssertEqual(controller.editedSections, [.connections, .usage])
    }

    /// The Settings window saves a preference; the sheet, loaded before that,
    /// then saves a rename. The window's preference stays.
    func testAnotherEditorsSavedPreferenceSurvivesThisEditorsSave() async throws {
        let (model, _, sheet) = try await fixture()
        let window = ConnectionSettingsController(model: model)
        await window.load(discardingDrafts: false)
        window.preferences.capture.retentionDays = 99
        let first = await window.saveAll()
        XCTAssertEqual(first, .saved)
        sheet.draft.profile.name = "Renamed"
        let second = await sheet.saveAll()
        XCTAssertEqual(second, .saved)
        let stored = try await model.vault.load()
        XCTAssertEqual(stored.capture.retentionDays, 99)
        XCTAssertEqual(stored.profiles.first?.profile.name, "Renamed")
    }

    // MARK: Quitting

    /// Once the app has begun quitting or updating, Settings writes nothing:
    /// a Save All or a deletion already on its way is refused.
    func testNothingIsWrittenOnceTheAppIsQuitting() async throws {
        let (model, storage, controller) = try await fixture()
        let writes = storage.writes
        controller.draft.profile.name = "Too late"
        model.installPreparing = true
        let saved = await controller.saveAll()
        XCTAssertEqual(saved, .failed)
        await controller.delete()
        XCTAssertEqual(storage.writes, writes); XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(controller.message, ConnectionSettingsController.closingNotice)
        model.installPreparing = false
    }

    private func lifecycle(_ model: WorkspaceModel) -> (ApplicationLifecycle, () -> [Bool], () -> Int) {
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        var answers: [Bool] = [], retries = 0
        lifecycle.answerTermination = { answers.append($0) }
        lifecycle.retryTermination = { retries += 1 }
        return (lifecycle, { answers }, { retries })
    }

    func testQuitSaveAllSavesThenQuitsAgain() async throws {
        let (model, _, controller) = try await fixture()
        controller.draft.profile.name = "Saved on quit"
        let (lifecycle, answers, retries) = lifecycle(model)
        answer(save)
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try await eventually("the quit was answered") { !answers().isEmpty }
        try await eventually("quit asked again") { retries() == 1 }
        XCTAssertEqual(answers(), [false])
        XCTAssertEqual(asked.first?.messageText, "Save your Settings changes before quitting?")
        XCTAssertEqual(model.profiles.first?.name, "Saved on quit")
        XCTAssertFalse(controller.isDirty)
    }

    func testQuitDiscardQuitsAgainWithoutWriting() async throws {
        let (model, storage, controller) = try await fixture()
        let writes = storage.writes
        controller.draft.profile.name = "Dropped"
        let (lifecycle, answers, retries) = lifecycle(model)
        answer(discard)
        _ = lifecycle.applicationShouldTerminate(NSApplication.shared)
        try await eventually("quit asked again") { retries() == 1 }
        XCTAssertEqual(answers(), [false]); XCTAssertEqual(storage.writes, writes)
        XCTAssertFalse(controller.isDirty)
    }

    func testQuitKeepEditingStaysOpen() async throws {
        let (model, _, controller) = try await fixture()
        controller.draft.profile.name = "Kept"
        let (lifecycle, answers, retries) = lifecycle(model)
        answer(keep)
        _ = lifecycle.applicationShouldTerminate(NSApplication.shared)
        try await eventually("the quit was answered") { !answers().isEmpty }
        XCTAssertEqual(answers(), [false]); XCTAssertEqual(retries(), 0)
        XCTAssertEqual(controller.draft.profile.name, "Kept")
    }

    func testQuitWithAFailingSaveStaysOpen() async throws {
        let (model, _, controller) = try await fixture()
        controller.draft.profile.baseUrl = "not a url"
        let (lifecycle, answers, retries) = lifecycle(model)
        answer(save)
        _ = lifecycle.applicationShouldTerminate(NSApplication.shared)
        try await eventually("the quit was answered") { !answers().isEmpty }
        XCTAssertEqual(answers(), [false]); XCTAssertEqual(retries(), 0)
        XCTAssertEqual(controller.draft.profile.baseUrl, "not a url")
    }

    /// Clean but still saving: the quit is refused, not run under the write.
    func testQuitDuringASaveIsRefused() async throws {
        let (model, _, controller) = try await fixture()
        controller.busy = true
        let (lifecycle, _, retries) = lifecycle(model)
        answer(discard)
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertTrue(asked.isEmpty); XCTAssertEqual(retries(), 0)
        XCTAssertNotNil(model.error)
        controller.busy = false
    }
}
