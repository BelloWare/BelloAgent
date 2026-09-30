import XCTest
import SwiftUI
import AppKit
@testable import PiApp
@testable import GitView

/// A change to the Changes panel draws the parts that show it. The panel
/// observes its controller, and every change to it used to draw the whole
/// panel again: the toolbar, every row of the list in view, the commit box
/// and the diff's heading, for a character typed or a box ticked. Choosing
/// the next file after a long diff held the main thread for about 50 ms in a
/// Debug build, a commit of four hundred files 45; the parts now keep to
/// their own inputs (`RedrawCounter`), and switching the diff to side by
/// side builds nothing in the toolbar however long its tabs glide.
final class GitPanelRedrawTests: GitPanelTestCase {
    /// SwiftUI takes a change on its next pass, not in the turn that made
    /// it: the change is given that pass, then the window is drawn.
    @MainActor private func draw(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(15))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    /// A repository with a dozen changed files and four commits.
    private func fixture(_ name: String) throws -> URL {
        let root = try repository(name)
        try start(root)
        func write(_ index: Int, _ text: String) throws {
            try text.write(to: root.appendingPathComponent("file\(index).swift"), atomically: false, encoding: .utf8)
        }
        for index in 0..<12 { try write(index, "let value = \(index)\n") }
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        for step in 1...3 {
            try write(step, "let value = \(step * 10)\n")
            try git(["commit", "-q", "-am", "Change \(step)"], in: root)
        }
        for index in 0..<12 { try write(index, "let value = \(index)\nlet more = \(index * 2)\n") }
        return root
    }

    @MainActor func testEachPartOfThePanelDrawsOnlyForWhatItShows() async throws {
        let root = try fixture("git-redraw")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        let window = host(GitPanelView(controller: controller))
        defer { window.contentView = nil; window.close() }
        try await eventually("the first read") { controller.status.entries.count == 12 && !controller.diff.isEmpty && !controller.diffLoading && controller.commits.count == 4 }
        for _ in 0..<4 { try await draw(window) }
        RedrawCounter.recording = true
        defer { RedrawCounter.recording = false; RedrawCounter.reset() }
        func drawn(_ change: () async throws -> Void) async throws -> [String: Int] {
            RedrawCounter.reset()
            try await change()
            for _ in 0..<3 { try await draw(window) }
            return RedrawCounter.counts
        }

        let typing = try await drawn {
            for character in "Tidy" { controller.commitMessage.append(character); try await draw(window) }
        }
        XCTAssertGreaterThanOrEqual(typing["GitCommitBox", default: 0], 4, "Typing draws the commit box: \(typing)")
        for part in ["GitPanelToolbar", "GitChangesList", "GitFileRow", "GitPanelDetail", "GitPanelHeader"] {
            XCTAssertEqual(typing[part, default: 0], 0, "Typing draws no \(part): \(typing)")
        }

        let path = controller.status.entries[5].path
        let next = try await drawn {
            controller.selection = GitController.Selection(path: path, staged: false)
            try await eventually("the next file's diff") { controller.diff.first?.path == path && !controller.diffLoading }
        }
        XCTAssertGreaterThanOrEqual(next["GitPanelDetail", default: 0], 1, "Another file draws the diff: \(next)")
        XCTAssertLessThanOrEqual(next["GitFileRow", default: 0], 4, "and the row left and the row chosen, of twelve: \(next)")
        for part in ["GitPanelToolbar", "GitCommitBox", "GitPanelHeader"] {
            XCTAssertEqual(next[part, default: 0], 0, "Another file draws no \(part): \(next)")
        }

        let tick = try await drawn { controller.checked.remove(path) }
        XCTAssertEqual(tick["GitFileRow", default: 0], 1, "A tick draws its row: \(tick)")
        XCTAssertGreaterThanOrEqual(tick["GitCommitBox", default: 0], 1, "and the commit box's count: \(tick)")
        for part in ["GitPanelToolbar", "GitPanelDetail", "GitPanelHeader"] {
            XCTAssertEqual(tick[part, default: 0], 0, "A tick draws no \(part): \(tick)")
        }

        // Side by side, and the tabs' glide over some 300 ms: the diff draws
        // itself, and nothing of the panel is built again.
        let split = try await drawn {
            controller.splitDiff = true
            for _ in 0..<25 { try await draw(window) }
        }
        for part in ["GitPanelToolbar", "GitRemoteIconButtons", "GitChangesList", "GitFileRow", "GitCommitBox", "GitPanelDetail", "GitPanelHeader"] {
            XCTAssertEqual(split[part, default: 0], 0, "Side by side draws no \(part): \(split)")
        }

        controller.panel = .history
        try await eventually("the history") { !controller.commits.isEmpty }
        for _ in 0..<3 { try await draw(window) }
        let commit = try XCTUnwrap(controller.commits.dropFirst().first)
        let chosen = try await drawn {
            controller.selectedCommit = commit
            try await eventually("the commit") { controller.detail?.commit == commit && !controller.commitLoading }
        }
        XCTAssertGreaterThanOrEqual(chosen["GitPanelDetail", default: 0], 1, "A commit draws the detail: \(chosen)")
        XCTAssertLessThanOrEqual(chosen["GitCommitRow", default: 0], 4, "and the commit left and the commit chosen, of four: \(chosen)")
        XCTAssertEqual(chosen["GitPanelToolbar", default: 0], 0, "A commit draws no toolbar: \(chosen)")
    }

    /// Resizing the panel draws none of its parts while the list stays where
    /// it is; crossing from beside the diff to above it draws the toolbar,
    /// which takes a second row, and nothing else.
    @MainActor func testResizingDrawsOnlyTheToolbarAndOnlyWhenTheLayoutChanges() async throws {
        let root = try fixture("git-redraw-resize")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        let window = host(GitPanelView(controller: controller), width: 1280, height: 820)
        defer { window.contentView = nil; window.close() }
        try await eventually("the first read") { controller.status.entries.count == 12 && !controller.diff.isEmpty && !controller.diffLoading }
        for _ in 0..<4 { try await draw(window) }
        RedrawCounter.recording = true
        defer { RedrawCounter.recording = false; RedrawCounter.reset() }
        func drawn(widths: [CGFloat]) async throws -> [String: Int] {
            RedrawCounter.reset()
            for width in widths {
                window.setContentSize(NSSize(width: width, height: 820))
                for _ in 0..<3 { try await draw(window) }
            }
            return RedrawCounter.counts
        }
        let parts = ["GitPanelToolbar", "GitPanelHeader", "GitChangesList", "GitCommitBox", "GitPanelDetail", "GitRemoteIconButtons"]
        let wide = try await drawn(widths: [1200, 1100, 1000, 950])
        for part in parts { XCTAssertEqual(wide[part, default: 0], 0, "Resizing a wide panel draws no \(part): \(wide)") }
        let crossing = try await drawn(widths: [800])
        XCTAssertGreaterThanOrEqual(crossing["GitPanelToolbar", default: 0], 1, "Crossing draws the toolbar: \(crossing)")
        for part in parts.dropFirst() where part != "GitRemoteIconButtons" {
            XCTAssertEqual(crossing[part, default: 0], 0, "Crossing draws no \(part): \(crossing)")
        }
        let narrow = try await drawn(widths: [760, 700, 640])
        for part in parts where part != "GitRemoteIconButtons" {
            XCTAssertEqual(narrow[part, default: 0], 0, "Resizing a narrow panel draws no \(part): \(narrow)")
        }
    }

    /// Fetch, pull and push say their names where the toolbar has room for
    /// them, and are three symbols where it has not. The symbols are built
    /// only when they are what shows: measured in the toolbar's every layout,
    /// they were built afresh each time, every frame of the tabs' glide.
    @MainActor func testTheRemoteControlsAreSymbolsOnlyWhereTheirNamesDoNotFit() async throws {
        for (branch, named) in [("main", true), ("feature/" + String(repeating: "a-very-long-branch-name-", count: 5) + "end", false)] {
            let root = try repository("git-remote-forms")
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try start(root)
            try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
            if branch != "main" { try git(["checkout", "-q", "-b", branch], in: root) }
            RedrawCounter.reset(); RedrawCounter.recording = true
            defer { RedrawCounter.recording = false; RedrawCounter.reset() }
            let controller = GitController(roots: [root.path])
            let window = host(GitPanelView(controller: controller))
            defer { window.contentView = nil; window.close() }
            try await eventually("the branch") { controller.status.branch == branch && !controller.loading }
            for _ in 0..<6 { try await draw(window) }
            let symbols = RedrawCounter.counts["GitRemoteIconButtons", default: 0]
            if named { XCTAssertEqual(symbols, 0, "Named where they fit, and the symbols never built") }
            else { XCTAssertGreaterThanOrEqual(symbols, 1, "Symbols where a long branch name leaves no room") }
        }
    }
}
