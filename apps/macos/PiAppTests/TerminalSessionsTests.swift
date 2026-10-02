import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Several terminals per project: each keeps its shell, output and name;
/// restarting or closing one touches only that one, after asking while its
/// shell is running, and only if it is still the terminal asked about.
@MainActor final class TerminalSessionsTests: XCTestCase {
    private let registry = TerminalRegistry.shared
    private var asked: [NSAlert] = []
    private var cleaning = false

    /// Every test starts with no terminals and ends every shell it started.
    private func workspace(_ name: String) -> WorkspaceRecord {
        if !cleaning {
            cleaning = true; registry.shutdown()
            addTeardownBlock { @MainActor in TerminalRegistry.shared.shutdown(); PiQuestion.shared.answerAlert = nil; PiQuestion.shared.enterText = nil }
        }
        let folder = scratchRoot("terminals-" + name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WorkspaceRecord(id: name + "-" + UUID().uuidString, path: folder.path, trusted: true)
    }
    private func answer(_ response: NSApplication.ModalResponse, also: @escaping @MainActor () -> Void = {}) {
        PiQuestion.shared.answerAlert = { [unowned self] alert in asked.append(alert); also(); return response }
    }
    private func running(_ sessions: [TerminalSession]) async throws {
        try await eventually("every shell started", timeout: .seconds(20)) { sessions.allSatisfy(\.process.running) }
    }
    /// Types a line into a shell and waits for it to show on that terminal.
    private func mark(_ session: TerminalSession, _ text: String) async throws {
        session.process.write(Data("echo \(text)\n".utf8))
        try await eventually("\(text) shows", timeout: .seconds(20)) {
            (0..<session.emulator.lineCount).contains { session.emulator.text(atLine: $0).hasPrefix(text) }
        }
    }
    private func shows(_ session: TerminalSession, _ text: String) -> Bool {
        (0..<session.emulator.lineCount).contains { session.emulator.text(atLine: $0).hasPrefix(text) }
    }

    func testEachTerminalKeepsItsShellOutputAndNameAcrossProjects() async throws {
        let a = workspace("a"), b = workspace("b")
        let a1 = try XCTUnwrap(registry.ensureInitialSession(for: a)), a2 = registry.create(for: a), a3 = registry.create(for: a)
        let b1 = try XCTUnwrap(registry.ensureInitialSession(for: b)), b2 = registry.create(for: b)
        XCTAssertEqual(registry.sessions(for: a.id).map(\.displayName), ["Terminal 1", "Terminal 2", "Terminal 3"])
        XCTAssertEqual(registry.sessions(for: b.id).map(\.displayName), ["Terminal 1", "Terminal 2"])
        XCTAssertTrue(registry.selected(for: a.id) === a3, "a new terminal is shown at once")
        try await running([a1, a2, a3, b1, b2])
        try await mark(a2, "MARK-A2"); try await mark(b1, "MARK-B1")
        registry.select(a1.id, in: a.id)
        XCTAssertTrue(registry.selected(for: a.id) === a1); XCTAssertTrue(registry.selected(for: b.id) === b2, "each project keeps its own choice")
        XCTAssertTrue(shows(a2, "MARK-A2")); XCTAssertFalse(shows(a1, "MARK-A2")); XCTAssertFalse(shows(b2, "MARK-B1"))
        XCTAssertEqual(Set([a1, a2, a3, b1, b2].map(\.process.processID)).count, 5, "five shells")
    }

    /// The reader's name stays; the shell's title is kept beside it.
    func testARenameIsNotReplacedByTheShellsTitle() async throws {
        let a = workspace("rename")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        registry.rename(one.id, in: a.id, to: "  Build  ")
        one.emulator.feed(Data("\u{1b}]0;zsh: ~/project\u{07}".utf8))
        XCTAssertEqual(one.displayName, "Build"); XCTAssertEqual(one.shellTitle, "zsh: ~/project")
        registry.rename(one.id, in: a.id, to: String(repeating: "é", count: 100))
        XCTAssertEqual(one.displayName.count, TerminalRegistry.nameLimit)
        registry.rename(one.id, in: a.id, to: "   ")
        XCTAssertEqual(one.displayName, "Terminal 1")
    }

    func testRenameAsksForTheNameAndCancelChangesNothing() async throws {
        let a = workspace("rename-ask")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        PiQuestion.shared.enterText = { _, _ in nil }
        await registry.requestRename(one.id, generation: one.generation, in: a.id, over: nil)
        XCTAssertEqual(one.displayName, "Terminal 1")
        PiQuestion.shared.enterText = { title, value in XCTAssertEqual(title, "Rename “Terminal 1”"); XCTAssertEqual(value, ""); return "Server" }
        await registry.requestRename(one.id, generation: one.generation, in: a.id, over: nil)
        XCTAssertEqual(one.displayName, "Server")
    }

    /// Restarting A2 asks, then starts a new shell in A2 only: the others keep
    /// their shells and output; A2 keeps its name, place and number.
    func testRestartingOneTerminalTouchesNoOther() async throws {
        let a = workspace("restart"), b = workspace("restart-b")
        let a1 = try XCTUnwrap(registry.ensureInitialSession(for: a)), a2 = registry.create(for: a), a3 = registry.create(for: a)
        let b1 = try XCTUnwrap(registry.ensureInitialSession(for: b))
        try await running([a1, a2, a3, b1])
        try await mark(a1, "KEEP-A1"); try await mark(a2, "LOSE-A2")
        registry.rename(a2.id, in: a.id, to: "Server")
        let pids = [a1, a3, b1].map(\.process.processID)
        answer(.alertFirstButtonReturn)
        let ended = await registry.requestEnding(.restart, a2.id, generation: a2.generation, in: a, over: nil)
        let fresh = try XCTUnwrap(ended)
        XCTAssertEqual(asked.count, 1)
        let alert = try XCTUnwrap(asked.first)
        XCTAssertEqual(alert.messageText, "Restart “Server” in “\((a.path as NSString).lastPathComponent)”?")
        XCTAssertTrue(alert.informativeText.contains("may interrupt") && alert.informativeText.contains("scrollback is removed"), alert.informativeText)
        XCTAssertEqual(alert.buttons.map(\.title), ["Restart Terminal", "Cancel"])
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "Cancel is the default")
        XCTAssertTrue(fresh !== a2); XCTAssertEqual(fresh.id, a2.id); XCTAssertEqual(fresh.displayName, "Server"); XCTAssertEqual(fresh.generation, 1)
        XCTAssertEqual(registry.sessions(for: a.id).map(\.id), [a1.id, a2.id, a3.id], "same place among its neighbours")
        XCTAssertTrue(registry.selected(for: a.id) === a3, "the shown terminal stays shown")
        XCTAssertEqual([a1, a3, b1].map(\.process.processID), pids); XCTAssertTrue([a1, a3, b1].allSatisfy(\.process.running))
        XCTAssertTrue(shows(a1, "KEEP-A1")); XCTAssertFalse(shows(fresh, "LOSE-A2"))
        try await eventually("the old shell ended", timeout: .seconds(10)) { !a2.process.running }
    }

    func testCancelLeavesTheTerminalAlone() async throws {
        let a = workspace("cancel")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        try await running([one])
        answer(.alertSecondButtonReturn)
        let restarted = await registry.requestEnding(.restart, one.id, generation: one.generation, in: a, over: nil)
        await registry.requestEnding(.close, one.id, generation: one.generation, in: a, over: nil)
        XCTAssertNil(restarted); XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(registry.selected(for: a.id) === one); XCTAssertTrue(one.process.running)
    }

    /// The terminal was restarted elsewhere while the question was up: the
    /// answer doesn't restart or close the new one.
    func testAnAnswerAboutAReplacedTerminalDoesNothing() async throws {
        let a = workspace("stale")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        try await running([one])
        var replacement: TerminalSession?
        answer(.alertFirstButtonReturn) { replacement = self.registry.restart(one.id, in: a.id, generation: 0) }
        await registry.requestEnding(.close, one.id, generation: one.generation, in: a, over: nil)
        let now = try XCTUnwrap(registry.selected(for: a.id))
        XCTAssertTrue(now === replacement, "the replacement was not closed")
        XCTAssertEqual(now.generation, 1)
    }

    /// The reader switches project while the question is up: the terminal
    /// asked about is the one that goes; the other project is untouched.
    func testTheCapturedTerminalIsTheOneThatGoes() async throws {
        let a = workspace("captured"), b = workspace("captured-b")
        let a1 = try XCTUnwrap(registry.ensureInitialSession(for: a)), a2 = registry.create(for: a)
        let b1 = try XCTUnwrap(registry.ensureInitialSession(for: b))
        try await running([a1, a2, b1])
        answer(.alertFirstButtonReturn) { self.registry.select(a1.id, in: a.id) }
        await registry.requestEnding(.close, a2.id, generation: a2.generation, in: a, over: nil)
        XCTAssertEqual(registry.sessions(for: a.id).map(\.id), [a1.id])
        XCTAssertTrue(registry.selected(for: b.id) === b1); XCTAssertTrue(b1.process.running)
    }

    /// A second click while the question is up asks nothing more.
    func testRepeatedClicksAskOnce() async throws {
        let a = workspace("repeat")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        try await running([one])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil)
        var shown = 0, reply: ((NSApplication.ModalResponse) -> Void)?
        let present = PiQuestion.shared.present
        addTeardownBlock { @MainActor in PiQuestion.shared.present = present; window.orderOut(nil) }
        PiQuestion.shared.present = { _, _, answer in shown += 1; reply = answer }
        let first = Task { await self.registry.requestEnding(.restart, one.id, generation: one.generation, in: a, over: window) }
        try await eventually("the question is up") { reply != nil }
        let second = await registry.requestEnding(.restart, one.id, generation: one.generation, in: a, over: window)
        XCTAssertNil(second); XCTAssertEqual(shown, 1)
        reply?(.alertFirstButtonReturn)
        let restarted = await first.value
        XCTAssertEqual(restarted?.generation, 1); XCTAssertEqual(registry.selected(for: a.id)?.generation, 1, "restarted once")
    }

    /// Two Restart clicks on an exited terminal: the second was for the old
    /// shell and does nothing to the new one.
    func testAClickMadeBeforeARestartDoesNothingToTheNewShell() async throws {
        let a = workspace("queued")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        try await running([one])
        one.process.write(Data("exit\n".utf8))
        try await eventually("the shell exited", timeout: .seconds(20)) { !one.process.running }
        answer(.alertFirstButtonReturn)
        let first = await registry.requestEnding(.restart, one.id, generation: 0, in: a, over: nil)
        let second = await registry.requestEnding(.restart, one.id, generation: 0, in: a, over: nil)
        XCTAssertNotNil(first); XCTAssertNil(second)
        XCTAssertEqual(registry.selected(for: a.id)?.generation, 1); XCTAssertTrue(asked.isEmpty)
    }

    /// The terminal is restarted while its Rename question is up: the name
    /// isn't given to the new shell.
    func testARenameAnsweredAfterARestartChangesNothing() async throws {
        let a = workspace("rename-stale")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        var fresh: TerminalSession?
        PiQuestion.shared.enterText = { _, _ in fresh = self.registry.restart(one.id, in: a.id, generation: 0); return "Late" }
        await registry.requestRename(one.id, generation: 0, in: a.id, over: nil)
        XCTAssertEqual(fresh?.displayName, "Terminal 1")
    }

    /// A shell that has exited goes without a question.
    func testAnExitedShellRestartsWithoutAsking() async throws {
        let a = workspace("exited")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a))
        try await running([one])
        one.process.write(Data("exit\n".utf8))
        try await eventually("the shell exited", timeout: .seconds(20)) { !one.process.running }
        answer(.alertSecondButtonReturn)
        let ended = await registry.requestEnding(.restart, one.id, generation: one.generation, in: a, over: nil)
        let fresh = try XCTUnwrap(ended)
        XCTAssertTrue(asked.isEmpty)
        fresh.process.terminate()
        try await eventually("the new shell ended", timeout: .seconds(20)) { !fresh.process.running }
        let again = await registry.requestEnding(.restart, fresh.id, generation: fresh.generation, in: a, over: nil)
        XCTAssertEqual(again?.generation, 2, "an exited shell restarts at once each time")
    }

    /// Closing the shown terminal shows the next one, or the one before; the
    /// last one closed leaves the project empty until a new one is asked for,
    /// and numbers aren't reused.
    func testClosingChoosesANeighbourAndTheLastLeavesNone() async throws {
        let a = workspace("close")
        let one = try XCTUnwrap(registry.ensureInitialSession(for: a)), two = registry.create(for: a), three = registry.create(for: a)
        registry.select(two.id, in: a.id)
        registry.close(two.id, in: a.id, generation: 0)
        XCTAssertTrue(registry.selected(for: a.id) === three, "the next one")
        registry.close(one.id, in: a.id, generation: 0)
        XCTAssertTrue(registry.selected(for: a.id) === three, "closing another keeps the shown one")
        registry.close(three.id, in: a.id, generation: 0)
        XCTAssertNil(registry.selected(for: a.id))
        XCTAssertNil(registry.ensureInitialSession(for: a), "a closed shell is not started again unasked")
        XCTAssertFalse(registry.openWorkspaceIDs.contains(a.id))
        XCTAssertEqual(registry.create(for: a).displayName, "Terminal 4")
        try await eventually("the closed shells ended", timeout: .seconds(10)) { ![one, two, three].contains(where: \.process.running) }
    }

    func testRemovingAProjectOrQuittingEndsEveryShell() async throws {
        let a = workspace("end"), b = workspace("end-b")
        let a1 = try XCTUnwrap(registry.ensureInitialSession(for: a)), a2 = registry.create(for: a)
        let b1 = try XCTUnwrap(registry.ensureInitialSession(for: b))
        try await running([a1, a2, b1])
        registry.close(workspaceID: a.id)
        try await eventually("project A's shells ended", timeout: .seconds(10)) { !a1.process.running && !a2.process.running }
        XCTAssertTrue(b1.process.running)
        XCTAssertNotNil(registry.ensureInitialSession(for: a), "a project opened again starts afresh")
        registry.shutdown()
        try await eventually("every shell ended", timeout: .seconds(10)) { !b1.process.running }
        XCTAssertTrue(registry.openWorkspaceIDs.isEmpty)
    }
}

/// The panel in a window with several terminals: the shown one has the
/// keyboard and is the only one in the window; hiding the panel and showing
/// it again comes back to it; a restart hands the keyboard to the new shell.
final class TerminalTabsPanelTests: XCTestCase, SerialTestLane {
    @MainActor func testTheShownTerminalHasTheKeyboardAndTheOthersStayOutOfTheWindow() async throws {
        let registry = TerminalRegistry.shared
        registry.shutdown()
        let folder = scratchRoot("terminal-tabs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "tabs-" + UUID().uuidString, path: folder.path, trusted: true)
        let model = makeWorkspaceModel(stateRoot: folder.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalPanel(model: model, workspace: project))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close(); registry.shutdown(); model.shutdown() }

        try await eventually("Terminal 1 opened") { registry.selected(for: project.id) != nil }
        let one = try XCTUnwrap(registry.selected(for: project.id))
        try await eventually("Terminal 1 has the keyboard") { window.firstResponder === one.view }
        let two = registry.create(for: project), three = registry.create(for: project)
        try await eventually("Terminal 3 has the keyboard") { window.firstResponder === three.view }
        XCTAssertNil(one.view.window); XCTAssertNil(two.view.window)
        XCTAssertEqual(three.view.superview?.subviews.count, 1, "one terminal in the panel")

        registry.select(one.id, in: project.id)
        try await eventually("Terminal 1 has the keyboard again") { window.firstResponder === one.view }
        XCTAssertNil(three.view.window, "the hidden terminal left the window")
        XCTAssertTrue(three.process.running, "and kept its shell")

        // Hidden and shown again: the same terminal.
        window.contentView = NSView()
        try await eventually("the panel is gone") { one.view.window == nil }
        window.contentView = NSHostingView(rootView: TerminalPanel(model: model, workspace: project))
        try await eventually("Terminal 1 is back with the keyboard") { window.firstResponder === one.view }
        XCTAssertEqual(registry.sessions(for: project.id).count, 3, "showing the panel again opened no new terminal")

        // A restart of the shown terminal gives the new shell the keyboard.
        let fresh = try XCTUnwrap(registry.restart(one.id, in: project.id, generation: one.generation))
        try await eventually("the new shell has the keyboard") { window.firstResponder === fresh.view }
        XCTAssertNil(one.view.window)
    }

    /// Opt-in pictures of the panel with several terminals, wide and narrow,
    /// light and dark: `PI_APP_TERMINAL_SNAPSHOT=<folder>`.
    @MainActor func testSnapshotOfSeveralTerminals() async throws {
        guard let path = testEnvironment("PI_APP_TERMINAL_SNAPSHOT") else { throw XCTSkip("Set PI_APP_TERMINAL_SNAPSHOT to take the pictures") }
        let registry = TerminalRegistry.shared
        registry.shutdown()
        let folder = scratchRoot("terminal-snapshot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "snap-" + UUID().uuidString, path: folder.path, trusted: true)
        let model = makeWorkspaceModel(stateRoot: folder.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { registry.shutdown(); model.shutdown() }
        let one = registry.create(for: project), two = registry.create(for: project)
        for _ in 0..<4 { registry.create(for: project) }
        registry.rename(two.id, in: project.id, to: "Dev server with a rather long name")
        registry.select(one.id, in: project.id)
        one.emulator.feed(Data("\u{1b}]0;zsh — ~/projects/app\u{07}$ npm test\r\n".utf8))
        registry.select(registry.sessions(for: project.id).last!.id, in: project.id)
        registry.sessions(for: project.id).last!.exited = true
        registry.sessions(for: project.id).last!.failure = "Terminal input queue is full; the newest input was dropped so the shell can catch up with what was already typed."
        for (width, label) in [(CGFloat(900), "wide"), (CGFloat(600), "narrow"), (CGFloat(310), "split")] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
                window.contentView = NSHostingView(rootView: TerminalPanel(model: model, workspace: project))
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(600))
                let view = try XCTUnwrap(window.contentView)
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("terminals-\(label)-\(name).png"))
                window.contentView = nil; window.close()
            }
        }
    }
}
