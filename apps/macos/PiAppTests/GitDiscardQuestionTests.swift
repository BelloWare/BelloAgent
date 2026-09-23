import XCTest
import SwiftUI
import AppKit
@testable import PiApp

final class GitDiscardQuestionTests: GitPanelTestCase {

    /// Discarding asks on a sheet. A modal loop would stop git, the terminal
    /// and every other window until the reader answered.
    @MainActor func testDiscardAsksOnASheetWithoutStoppingTheMainThread() async throws {
        let entries = ["one.txt", "two.txt"].map { GitStatusEntry(path: $0, originalPath: nil, indexState: ".", worktreeState: "M", untracked: false) }
        let questions = PiQuestion()
        var asked: [NSAlert] = []
        var answer: ((NSApplication.ModalResponse) -> Void)?
        questions.present = { alert, _, complete in asked.append(alert); answer = complete }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var discarded: [[GitStatusEntry]] = []
        GitDiscard.ask(questions, discarding: entries, in: window) { discarded.append($0) }
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.messageText, "Discard changes to 2 files?")
        XCTAssertTrue(questions.asking)

        // A second right-click while the question is up does not stack another.
        GitDiscard.ask(questions, discarding: entries, in: window) { discarded.append($0) }
        XCTAssertEqual(asked.count, 1, "one question at a time")

        answer?(.alertSecondButtonReturn)                       // Cancel
        XCTAssertTrue(discarded.isEmpty, "Cancel discards nothing")
        XCTAssertFalse(questions.asking)

        GitDiscard.ask(questions, discarding: [entries[0]], in: window) { discarded.append($0) }
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked.last?.messageText, "Discard changes to one.txt?", "one file is named")
        XCTAssertEqual(asked.last?.buttons.first?.title, "Discard")
        XCTAssertTrue(asked.last?.buttons.first?.hasDestructiveAction == true)
        answer?(.alertFirstButtonReturn)
        XCTAssertEqual(discarded.map { $0.map(\.path) }, [["one.txt"]])

        // No window to put the sheet on is no question and no discard.
        GitDiscard.ask(questions, discarding: entries, in: nil) { discarded.append($0) }
        XCTAssertEqual(asked.count, 2)
        XCTAssertFalse(questions.asking)
    }

    /// The same question through AppKit: a real sheet attaches to the panel and
    /// the caller carries on, which a modal loop would never allow.
    @MainActor func testTheDiscardSheetAttachesAndTheCallerKeepsRunning() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let questions = PiQuestion()
        let entries = [GitStatusEntry(path: "doomed.txt", originalPath: nil, indexState: ".", worktreeState: "M", untracked: false)]
        var discarded = false
        GitDiscard.ask(questions, discarding: entries, in: window) { _ in discarded = true }

        // Reached only because nothing is blocking the main thread.
        try await eventually("attach the sheet") { window.attachedSheet != nil }
        XCTAssertTrue(questions.asking)
        XCTAssertFalse(discarded)
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await eventually("act on the answer") { discarded }
        XCTAssertFalse(questions.asking)
        XCTAssertNil(window.attachedSheet)
    }
}
