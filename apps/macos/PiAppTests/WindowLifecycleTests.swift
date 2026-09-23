import XCTest
import AppKit
@testable import PiApp

/// Closing the last window with a running turn, and quitting with unsaved
/// state. Both used to run an application-modal alert from inside an AppKit
/// callback that was already deciding whether to close or terminate.
final class WindowLifecycleTests: XCTestCase, SerialTestLane {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("window-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func makeModel(_ root: URL) -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.chats = [ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "fixture")]
        return model
    }
    /// The runner hosts the real app, whose own windows are on screen. Hide
    /// them so this fixture window is the last one, as it is for a user.
    @MainActor private func onlyWindow() -> (NSWindow, () -> Void) {
        let others = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible && $0.sheetParent == nil }
        others.forEach { $0.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        // Loading NSAlert's interface the first time costs real milliseconds
        // and would otherwise be mistaken for a blocked callback below.
        _ = NSAlert().window
        return (window, { window.close(); others.forEach { $0.orderFront(nil) } })
    }
    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A run in flight refuses the close and says why in a sheet. The refusal
    /// itself must be immediate: a modal run loop here re-enters AppKit's
    /// window and application callbacks from inside this one.
    @MainActor func testClosingTheLastWindowWithARunningTurnRefusesWithoutBlockingAppKit() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let view = SessionDisplay(id: "chat"); view.state = "running"
        model.displays["chat"] = view
        XCTAssertTrue(model.hasActiveWork)
        let (window, restore) = onlyWindow(); defer { restore() }
        let guarded = WindowActivityGuard.Coordinator(model)
        guarded.attach(window)
        XCTAssertTrue(window.delegate === guarded)

        let start = ProcessInfo.processInfo.systemUptime
        let allowed = guarded.windowShouldClose(window)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertFalse(allowed, "the last window must not close over a running turn")
        XCTAssertLessThan(elapsed, 1000, "the close decision must not run a modal loop")
        await settle { window.attachedSheet != nil }
        XCTAssertNotNil(window.attachedSheet, "the reason belongs in a sheet on the window being closed")
        // A second attempt while the explanation is up must not stack another.
        XCTAssertFalse(guarded.windowShouldClose(window))
        XCTAssertNotNil(window.attachedSheet)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        await settle { window.attachedSheet == nil }

        // With the run finished the guard steps out of the way again.
        view.state = "idle"
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertTrue(guarded.windowShouldClose(window))
        guarded.detach()
        XCTAssertFalse(window.delegate === guarded, "detaching must give the window's delegate back")
        try await model.traces.close(); await model.store?.close()
    }

    /// Quit with a run in flight asks first, in a sheet, and saves nothing
    /// until the answer arrives. Cancelling leaves the app exactly as it was.
    @MainActor func testQuittingWithARunningTurnAsksInASheetAndCancelChangesNothing() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let view = SessionDisplay(id: "chat"); view.state = "running"; view.draft = "Unsaved text"
        model.displays["chat"] = view
        let (window, restore) = onlyWindow(); defer { restore() }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }

        let start = ProcessInfo.processInfo.systemUptime
        let reply = lifecycle.applicationShouldTerminate(NSApp)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertLessThan(elapsed, 1000, "the terminate decision must not run a modal loop")
        await settle { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet, "the question belongs in a sheet")
        XCTAssertTrue(answers.isEmpty, "nothing is decided while the question is still open")
        XCTAssertFalse(model.installPreparing, "the app keeps working until the user answers")
        // Asking again while the sheet is up must not stack a second question.
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertTrue(window.attachedSheet === sheet)

        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await settle { !answers.isEmpty }
        XCTAssertEqual(answers, [false], "Cancel must refuse the quit")
        XCTAssertFalse(model.installPreparing)
        XCTAssertEqual(view.draft, "Unsaved text")
        try await model.traces.close(); await model.store?.close()
    }

    /// With nothing running, quit goes straight to saving and answers only
    /// once every draft and preference has actually landed.
    @MainActor func testQuittingWithNothingRunningFlushesTheDraftBeforeAnswering() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let store = try XCTUnwrap(model.store)
        let view = SessionDisplay(id: "chat"); view.selectionMetadataLoaded = true; view.draft = "Last thing typed"
        model.displays["chat"] = view
        XCTAssertFalse(model.hasActiveWork)
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        await settle { !answers.isEmpty }
        XCTAssertEqual(answers, [true])
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: "chat")
        XCTAssertEqual(saved?.text, "Last thing typed")
        try await model.traces.close(); await store.close()
    }
}
