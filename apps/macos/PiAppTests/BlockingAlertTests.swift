import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Every question the app asks has to arrive on a sheet. A modal run loop
/// stops the main thread: other windows freeze, git reads and terminal output
/// stop being delivered, and AppKit re-enters its own callbacks from inside
/// the one that is running.
final class BlockingAlertTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            PiQuestion.shared.answerAlert = nil
            PiQuestion.shared.chooseFiles = nil
        }
        super.tearDown()
    }
    private func scratch(_ name: String) throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Never \(what)", file: file, line: line)
    }
    @MainActor private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    // MARK: The mechanism

    /// The question attaches to the window, the caller carries on while it is
    /// up, and the answer comes back through the completion handler.
    @MainActor func testAQuestionAttachesToTheWindowAndTheCallerKeepsRunning() async throws {
        let host = window(); defer { host.close() }
        var answer: Bool?
        let asked = Task { answer = await PiQuestion.shared.confirm("Discard the draft?", "It cannot be brought back.", action: "Discard", destructive: true, over: host) }

        // Reached only because nothing is blocking the main thread.
        try await eventually("attach the sheet") { host.attachedSheet != nil }
        XCTAssertTrue(PiQuestion.shared.asking)
        XCTAssertNil(answer, "nothing is decided until the reader answers")

        // A second question while one is up is answered, not stacked.
        let second = await PiQuestion.shared.confirm("Another question?", "", over: host)
        XCTAssertFalse(second, "a second question is refused, not queued behind the first")
        XCTAssertEqual(host.sheets.count, 1, "and only one sheet is on the window")

        host.endSheet(try XCTUnwrap(host.attachedSheet), returnCode: .alertFirstButtonReturn)
        await asked.value
        XCTAssertEqual(answer, true)
        XCTAssertFalse(PiQuestion.shared.asking)
        XCTAssertNil(host.attachedSheet)
    }

    /// Cancelling answers false and the window is left as it was.
    @MainActor func testCancellingAQuestionAnswersFalse() async throws {
        let host = window(); defer { host.close() }
        var answer: Bool?
        let asked = Task { answer = await PiQuestion.shared.confirm("Enable editing tools?", "", action: "Enable", over: host) }
        try await eventually("attach the sheet") { host.attachedSheet != nil }
        host.endSheet(try XCTUnwrap(host.attachedSheet), returnCode: .alertSecondButtonReturn)
        await asked.value
        XCTAssertEqual(answer, false)
        XCTAssertFalse(PiQuestion.shared.asking)
    }

    /// Which window a sheet hangs on, and the destructive shape of a warning.
    @MainActor func testTheHostWindowAndTheShapeOfTheQuestion() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        XCTAssertTrue(PiQuestion.host(second) === second, "the window the caller names is used")
        var answer: Bool?
        let asked = Task { answer = await PiQuestion.shared.confirm("Busy?", "", over: second) }
        try await eventually("attach the sheet") { second.attachedSheet != nil }
        XCTAssertFalse(PiQuestion.host(second) === second, "a window already showing a sheet cannot take another")
        second.endSheet(try XCTUnwrap(second.attachedSheet), returnCode: .alertSecondButtonReturn)
        await asked.value
        XCTAssertEqual(answer, false)

        var seen: NSAlert?
        PiQuestion.shared.answerAlert = { alert in seen = alert; return .alertFirstButtonReturn }
        let agreed = await PiQuestion.shared.confirm("Delete it?", "It cannot be brought back.", action: "Delete", destructive: true)
        XCTAssertTrue(agreed)
        let alert = try XCTUnwrap(seen)
        XCTAssertEqual(alert.messageText, "Delete it?")
        XCTAssertEqual(alert.buttons.first?.title, "Delete")
        XCTAssertTrue(alert.buttons.first?.hasDestructiveAction == true)
        XCTAssertEqual(alert.buttons.last?.title, "Cancel")
        XCTAssertEqual(alert.alertStyle, .warning)
    }

    /// The completion-handler form, for AppKit delegates that cannot await.
    @MainActor func testTheCompletionFormAnswersTheSameWay() async throws {
        let host = window(); defer { host.close() }
        var answered: NSApplication.ModalResponse?
        let alert = NSAlert(); alert.messageText = "Finish or stop active work before updating."
        PiQuestion.shared.ask(alert, over: host) { answered = $0 }
        try await eventually("attach the sheet") { host.attachedSheet != nil }
        host.endSheet(try XCTUnwrap(host.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await eventually("answer") { answered != nil }
        XCTAssertEqual(answered, .alertFirstButtonReturn)
    }

    // MARK: The sites, driven through the model

    /// Choosing a project's folders.
    @MainActor func testChoosingFoldersAnswersThroughTheSheet() async throws {
        let root = try scratch("folders"); defer { try? FileManager.default.removeItem(at: root) }
        PiQuestion.shared.chooseFiles = { [] }
        let cancelled = await WorkspaceModel.chooseFolders(message: "Choose a folder", multiple: false)
        XCTAssertTrue(cancelled.isEmpty, "cancelling the chooser picks nothing")

        let picked = root.appendingPathComponent("picked")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        PiQuestion.shared.chooseFiles = { [picked] }
        let chosen = await WorkspaceModel.chooseFolders(message: "Choose a folder", multiple: false)
        XCTAssertEqual(chosen, [picked.resolvingSymlinksInPath().path], "and a chosen folder comes back with its links resolved")
    }

    /// The export screens all ask where to write through the same door.
    @MainActor func testAFileChooserAnswersWithWhatTheReaderPicked() async throws {
        let root = try scratch("chooser"); defer { try? FileManager.default.removeItem(at: root) }
        PiQuestion.shared.chooseFiles = { [] }
        let cancelledSave = await PiQuestion.shared.save(NSSavePanel())
        XCTAssertNil(cancelledSave, "cancelling writes nothing")
        let cancelledOpen = await PiQuestion.shared.open(NSOpenPanel())
        XCTAssertTrue(cancelledOpen.isEmpty)

        let destination = root.appendingPathComponent("PiTrace-metadata.json")
        PiQuestion.shared.chooseFiles = { [destination] }
        let saved = await PiQuestion.shared.save(NSSavePanel())
        XCTAssertEqual(saved, destination)
        let opened = await PiQuestion.shared.open(NSOpenPanel())
        XCTAssertEqual(opened, [destination])

        // A chooser is refused while a question is already up, like any other.
        PiQuestion.shared.chooseFiles = nil
        let host = window(); defer { host.close() }
        var answer: Bool?
        let asked = Task { answer = await PiQuestion.shared.confirm("Export sensitive retained body bytes?", "", over: host) }
        try await eventually("attach the sheet") { host.attachedSheet != nil }
        let refusedSave = await PiQuestion.shared.save(NSSavePanel(), over: host)
        let refusedOpen = await PiQuestion.shared.open(NSOpenPanel(), over: host)
        XCTAssertNil(refusedSave, "one question at a time, choosers included")
        XCTAssertTrue(refusedOpen.isEmpty)
        XCTAssertEqual(host.sheets.count, 1)
        host.endSheet(try XCTUnwrap(host.attachedSheet), returnCode: .alertSecondButtonReturn)
        await asked.value
        XCTAssertEqual(answer, false)
    }

    // MARK: Nothing blocking is left

    /// Every screen converted in this pass, checked at the source: a modal run
    /// loop must not come back into any of them.
    func testNoConvertedScreenStopsTheMainThreadAnyMore() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PiApp")
        let converted = [
            "Workspaces/WorkspaceFolders.swift",
            "Inspector/Session/InspectorRawTab.swift", "Inspector/ResourceInspector.swift",
            "Inspector/ConversationContentView.swift", "Application/UpdateController.swift",
            "Application/WindowActivityGuard.swift", "Git/GitPanel.swift",
        ]
        for path in converted + ["Workspaces/WorkspaceManagerView.swift"] {
            let file = source.appendingPathComponent(path)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                throw XCTSkip("The sources are not beside the test bundle in this run")
            }
            XCTAssertFalse(text.contains("runModal()"), "\(path) still stops the main thread with a modal run loop")
            if converted.contains(path) {
                XCTAssertTrue(text.contains("PiQuestion") || text.contains("beginSheetModal"), "\(path) should ask on a sheet")
            }
        }
        // The only modal loops left are the fallbacks with no window to use.
        let fallback = try String(contentsOf: source.appendingPathComponent("Design/PiQuestion.swift"), encoding: .utf8)
        XCTAssertEqual(fallback.components(separatedBy: "runModal()").count - 1, 2,
                       "one fallback for an alert, one for a file panel, and no more")
        XCTAssertTrue(fallback.contains("guard let host = Self.host(window, showing: sessionID) else"),
                      "and each is reached only when no window can host a sheet")
    }
}
