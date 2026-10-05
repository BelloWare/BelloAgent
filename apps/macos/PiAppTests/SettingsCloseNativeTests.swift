import SwiftUI
import XCTest
@testable import PiApp

/// The Settings window and sheet as a person closes them: the close button,
/// ⌘W, Escape and Cancel. Unsaved edits are asked about, never dropped by
/// the way out; a clean Settings closes as it always did.
@MainActor final class SettingsCloseNativeTests: XCTestCase, SerialTestLane {
    private var asked: [NSAlert] = []

    private func model(storage: MemoryVaultStorage = MemoryVaultStorage()) async throws -> WorkspaceModel {
        let root = scratchRoot("settings-close")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = ConfigurationVault(storage: storage)
        var profile = ProfileRecord(); profile.name = "Team"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "team-model"
        profile.contextWindow = 16000; profile.maxOutputTokens = 2048
        let connection = VaultProfile(profile: profile, apiKey: "sk-saved")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        addTeardownBlock { @MainActor in model.shutdown() }
        try await model.reloadConfiguration()
        return model
    }
    private func answer(_ response: NSApplication.ModalResponse) {
        addTeardownBlock { @MainActor in PiQuestion.shared.answerAlert = nil }
        PiQuestion.shared.answerAlert = { [unowned self] alert in asked.append(alert); return response }
    }

    /// The window's delegate before the guard: it still has the last word.
    private final class Recorder: NSObject, NSWindowDelegate {
        var allow = true, asked = 0, closed = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { asked += 1; return allow }
        func windowWillClose(_ notification: Notification) { closed += 1 }
    }
    private func settingsWindow(_ model: WorkspaceModel) async throws -> (NSWindow, Recorder, ConnectionSettingsController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = Recorder(); window.delegate = recorder
        window.contentView = SettingsWindowView(model: model)
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.delegate = nil; window.orderOut(nil) }
        try await eventually("the editor loaded") { model.settingsEditors.allObjects.contains { $0.loaded } }
        let controller = try XCTUnwrap(model.settingsEditors.allObjects.first { $0.loaded })
        try await eventually("the close guard is attached") { window.delegate !== recorder }
        return (window, recorder, controller)
    }

    func testACleanWindowClosesAtOnce() async throws {
        let (window, recorder, _) = try await settingsWindow(try await model())
        answer(.alertThirdButtonReturn)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible); XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(recorder.asked, 1); XCTAssertEqual(recorder.closed, 1)
    }

    func testTheCloseButtonAsksAndKeepEditingKeepsTheWindow() async throws {
        let (window, _, controller) = try await settingsWindow(try await model())
        controller.draft.profile.name = "Renamed"
        answer(.alertThirdButtonReturn)
        window.standardWindowButton(.closeButton)?.performClick(nil)
        try await eventually("the question was asked") { asked.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.isVisible); XCTAssertEqual(controller.draft.profile.name, "Renamed")
    }

    func testDiscardClosesTheWindowAndTheOldDelegateStillDecides() async throws {
        let (window, recorder, controller) = try await settingsWindow(try await model())
        controller.draft.profile.name = "Renamed"
        recorder.allow = false
        answer(.alertSecondButtonReturn)
        window.performClose(nil)
        try await eventually("the question was asked") { asked.count == 1 }
        try await eventually("the previous delegate was consulted") { recorder.asked == 1 }
        XCTAssertTrue(window.isVisible, "the previous delegate's veto was ignored")
        XCTAssertFalse(controller.isDirty)
        recorder.allow = true
        window.performClose(nil)
        XCTAssertFalse(window.isVisible); XCTAssertEqual(recorder.closed, 1)
    }

    // MARK: The sheet

    private struct SheetHost: View {
        @ObservedObject var model: WorkspaceModel
        var body: some View {
            Color.clear.frame(width: 1000, height: 860)
                .background(WindowActivityGuardReference(model: model))
                .piSheetWindow(isPresented: $model.showProfiles) {
                    ProfileSettings(model: model, controller: model.settingsSheetEditor(), windowChrome: false).frame(width: 880, height: 780)
                }
        }
    }
    private func sheet(_ model: WorkspaceModel) async throws -> (NSWindow, NSWindow, ConnectionSettingsController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SheetHost(model: model))
        window.orderFront(nil)
        addTeardownBlock { @MainActor in model.showProfiles = false; window.orderOut(nil) }
        model.showProfiles = true
        try await eventually("Settings opened as a sheet") { window.attachedSheet != nil }
        let editor = model.settingsSheetEditor()
        try await eventually("the editor loaded") { editor.loaded }
        // The sheet's key handling is in place once it has shown.
        try await Task.sleep(for: .milliseconds(400))
        return (window, try XCTUnwrap(window.attachedSheet), editor)
    }
    private func escape(_ sheet: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(try XCTUnwrap(sheet.contentView).performKeyEquivalent(with: event), "Escape reached nothing")
    }

    func testEscapeWithUnsavedEditsAsksAndKeepEditingKeepsTheSheet() async throws {
        let model = try await model()
        let (window, sheet, editor) = try await sheet(model)
        editor.draft.profile.name = "Renamed"
        answer(.alertThirdButtonReturn)
        try escape(sheet)
        try await eventually("the question was asked") { asked.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(window.attachedSheet); XCTAssertTrue(model.showProfiles)
        XCTAssertEqual(editor.draft.profile.name, "Renamed")
    }

    func testEscapeThenDiscardClosesTheSheetAndReopensOnTheSavedState() async throws {
        let model = try await model()
        let (window, sheet, editor) = try await sheet(model)
        editor.draft.profile.name = "Renamed"
        answer(.alertSecondButtonReturn)
        try escape(sheet)
        try await eventually("the sheet closed") { window.attachedSheet == nil && !model.showProfiles }
        XCTAssertFalse(editor.isDirty)
        model.showProfiles = true
        try await eventually("Settings opened again") { window.attachedSheet != nil }
        XCTAssertEqual(model.settingsSheetEditor().draft.profile.name, "Team")
    }

    /// A reload in progress holds a read, not a write: Escape still closes
    /// the sheet (0.1.119's gate: a slow load swallowed Escape).
    func testEscapeWhileSettingsReloadsClosesTheSheet() async throws {
        let storage = MemoryVaultStorage()
        let model = try await model(storage: storage)
        let (window, sheet, editor) = try await sheet(model)
        let gate = DispatchSemaphore(value: 0); storage.readGate = gate
        addTeardownBlock { gate.signal() }
        answer(.alertThirdButtonReturn)
        Task { await editor.requestReload() }
        try await eventually("the reload is under way") { editor.busy }
        try escape(sheet)
        try await eventually("the sheet closed") { window.attachedSheet == nil && !model.showProfiles }
        XCTAssertTrue(asked.isEmpty)
        gate.signal()
        try await eventually("the reload finished") { !editor.busy }
    }

    /// The same for the Settings window's close button.
    func testTheCloseButtonWhileSettingsReloadsClosesTheWindow() async throws {
        let storage = MemoryVaultStorage()
        let (window, recorder, controller) = try await settingsWindow(try await model(storage: storage))
        let gate = DispatchSemaphore(value: 0); storage.readGate = gate
        addTeardownBlock { gate.signal() }
        answer(.alertThirdButtonReturn)
        Task { await controller.requestReload() }
        try await eventually("the reload is under way") { controller.busy }
        window.performClose(nil)
        XCTAssertFalse(window.isVisible); XCTAssertTrue(asked.isEmpty); XCTAssertEqual(recorder.closed, 1)
        // Nor does a reload hold up quitting.
        let mayQuit = await controller.resolveForQuit()
        XCTAssertTrue(mayQuit); XCTAssertTrue(asked.isEmpty)
        gate.signal()
        try await eventually("the reload finished") { !controller.busy }
    }

    func testEscapeOnACleanSheetClosesWithoutAsking() async throws {
        let model = try await model()
        let (window, sheet, _) = try await sheet(model)
        answer(.alertThirdButtonReturn)
        try escape(sheet)
        try await eventually("the sheet closed") { window.attachedSheet == nil }
        XCTAssertTrue(asked.isEmpty)
    }


    /// The window under the Settings sheet can't be closed out from under
    /// it: AppKit refuses to close a window wearing a sheet, so Settings and
    /// its edits stay.
    func testTheWindowUnderSettingsStaysWithItsEdits() async throws {
        let model = try await model()
        let (window, _, editor) = try await sheet(model)
        editor.draft.profile.name = "Renamed"
        answer(.alertSecondButtonReturn)
        window.performClose(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(window.isVisible); XCTAssertNotNil(window.attachedSheet); XCTAssertTrue(model.showProfiles)
        XCTAssertEqual(editor.draft.profile.name, "Renamed"); XCTAssertTrue(asked.isEmpty)
    }

    /// Settings edited while "Stop active work and quit?" is up are asked
    /// about before the app shuts down.
    func testSettingsEditedDuringTheStopAndQuitQuestionAreAskedAbout() async throws {
        let model = try await model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        let chat = ChatRecord(id: "busy", workspaceID: "p", title: "Busy", path: nil, profileID: "p")
        let view = SessionDisplay(id: chat.id); view.state = "running"
        model.chats = [chat]; model.displays[chat.id] = view
        let editor = ConnectionSettingsController(model: model)
        await editor.load(discardingDrafts: false)
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        var answers: [Bool] = [], retries = 0
        lifecycle.answerTermination = { answers.append($0) }
        lifecycle.retryTermination = { retries += 1 }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        var host: NSWindow? { NSApp.windows.first { $0.attachedSheet != nil } }
        try await eventually("the stop-and-quit question is up") { host != nil }
        editor.draft.profile.name = "Typed during the question"
        let parent = try XCTUnwrap(host), question = try XCTUnwrap(parent.attachedSheet)
        parent.endSheet(question, returnCode: .alertFirstButtonReturn)
        try await eventually("quit asked again for Settings") { retries == 1 }
        XCTAssertEqual(answers, [false])
        XCTAssertEqual(editor.draft.profile.name, "Typed during the question")
        view.state = "idle"
    }

    /// Opt-in picture of Settings with unsaved edits, light and dark, for
    /// looking at: `PI_APP_SETTINGS_SNAPSHOT=<folder>`.
    func testSnapshotOfUnsavedSettings() async throws {
        guard let path = testEnvironment("PI_APP_SETTINGS_SNAPSHOT") else { throw XCTSkip("Set PI_APP_SETTINGS_SNAPSHOT to take the picture") }
        let folder = URL(fileURLWithPath: path)
        let model = try await model()
        let (_, sheet, editor) = try await sheet(model)
        editor.draft.profile.name = "Team renamed"; editor.preferences.playsCompletionSound.toggle()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            sheet.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(500))
            let view = try XCTUnwrap(sheet.contentView)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("settings-unsaved-\(name).png"))
        }
    }
}
