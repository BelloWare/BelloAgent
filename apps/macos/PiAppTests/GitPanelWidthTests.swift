import XCTest
import SwiftUI
import AppKit
@testable import PiApp
@testable import GitView

/// The panel as wide as a window, and as narrow as the pane beside the chat.
/// Wide, the list is beside the diff; narrow, above it, and the toolbar takes
/// two rows. Crossing from one to the other keeps what the reader had: the
/// same diff table, the file chosen, where the diff and the list were
/// scrolled, the keys in the commit message, and a panel that never went
/// away. A short window keeps the commit box whole, and a file chip wider
/// than its row is cut to it.
final class GitPanelWidthTests: GitPanelTestCase {
    /// Thirty small changed files and one long one.
    private func fixture() throws -> URL {
        let root = try repository("git-width")
        try start(root)
        func write(_ name: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(name), atomically: false, encoding: .utf8) }
        for index in 0..<30 { try write("file\(index).swift", "let value = \(index)\n") }
        try write("long.swift", (0..<400).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n")
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        for index in 0..<30 { try write("file\(index).swift", "let value = \(index + 100)\n") }
        try write("long.swift", (0..<400).map { "let changed\($0) = \($0 * 3)" }.joined(separator: "\n") + "\n")
        return root
    }
    @MainActor private func draw(_ window: NSWindow, passes: Int = 3) async throws {
        for _ in 0..<passes {
            try await Task.sleep(for: .milliseconds(15))
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
    }
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    /// A view's frame in its window.
    @MainActor private func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    /// Compare the row the reader sees, rather than an offset that changes
    /// when the lazy list remeasures its rows at a new width.
    @MainActor private func firstVisibleRow(in list: NSScrollView) -> String? {
        guard let window = list.window else { return nil }
        let visible = window.convertToScreen(list.contentView.convert(list.contentView.bounds, to: nil))
        var queue: [Any] = [list], visited = 0
        var rows: [(id: String, frame: NSRect)] = []
        while !queue.isEmpty, visited < 20_000 {
            let next = queue.removeFirst(); visited += 1
            guard let element = next as? NSAccessibilityProtocol else { continue }
            if let id = element.accessibilityIdentifier(), id.hasPrefix("git-file-"), !id.hasPrefix("git-file-history-"),
               element.accessibilityFrame().intersection(visible).height > 1 {
                rows.append((id, element.accessibilityFrame()))
            }
            queue += element.accessibilityChildren() ?? []
        }
        return rows.max(by: { $0.frame.maxY < $1.frame.maxY })?.id
    }
    @MainActor private func resize(_ window: NSWindow, width: CGFloat, height: CGFloat? = nil) async throws {
        window.setContentSize(NSSize(width: width, height: height ?? window.contentLayoutRect.height))
        try await draw(window)
    }

    @MainActor func testTheListGoesAboveTheDiffWhereThePanelIsNarrowAndTheReaderKeepsTheirPlace() async throws {
        let root = try fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        let window = host(GitPanelView(controller: controller), width: 1280, height: 820)
        defer { window.contentView = nil; window.close() }
        try await eventually("the first read") { controller.status.entries.count == 31 && !controller.diffLoading && !controller.diff.isEmpty }
        let chosen = GitController.Selection(path: "long.swift", staged: false)
        controller.selection = chosen
        try await eventually("the long diff") { controller.diff.first?.path == "long.swift" && !controller.diffLoading }
        try await draw(window)
        let table = try XCTUnwrap(views(GitDiffTableView.self, in: window.contentView!).first, "The diff table")
        let diff = try XCTUnwrap(table.enclosingScrollView)
        let list = try XCTUnwrap(views(NSScrollView.self, in: window.contentView!).first { $0 !== diff && frame($0).maxX <= frame(diff).minX + 1 && frame($0).height > 200 },
                                 "The list, beside the diff")
        XCTAssertEqual(frame(list).width, GitPanelSplit.listWidth, accuracy: 1, "Wide: the list 340 points wide")
        XCTAssertEqual(frame(diff).minX, GitPanelSplit.listWidth + 1, accuracy: 1, "and the diff beside it")
        // Where the reader was: the diff and the list scrolled, the keys in the commit message.
        diff.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900)); diff.reflectScrolledClipView(diff.contentView)
        list.contentView.setBoundsOrigin(NSPoint(x: 0, y: 240)); list.reflectScrolledClipView(list.contentView)
        let field = try XCTUnwrap(views(NSTextField.self, in: window.contentView!).first { $0.isEditable && $0.placeholderString == "Commit message" }, "The commit message")
        XCTAssertTrue(window.makeFirstResponder(field))
        func typing() -> Bool { (window.firstResponder as? NSTextView)?.delegate === field || window.firstResponder === field }
        XCTAssertTrue(typing())
        try await draw(window)
        let shown = controller.shownChanges
        let firstRow = try XCTUnwrap(firstVisibleRow(in: list), "A visible file row in the scrolled list")

        var cycles = try await layoutCycles {
            try await resize(window, width: 700)
        }
        XCTAssertTrue(views(GitDiffTableView.self, in: window.contentView!).first === table, "Narrow: the same diff table")
        XCTAssertTrue(list.window === window, "and the same list")
        XCTAssertEqual(frame(diff).width, 700, accuracy: 1, "The diff the panel's width")
        XCTAssertEqual(frame(list).width, 700, accuracy: 1, "and the list too")
        XCTAssertGreaterThanOrEqual(frame(list).minY, frame(diff).maxY, "the list above the diff")
        XCTAssertEqual(controller.selection, chosen, "The file chosen stays chosen")
        XCTAssertEqual(diff.contentView.bounds.origin.y, 900, accuracy: 1, "the diff where it was")
        XCTAssertEqual(firstVisibleRow(in: list), firstRow, "the same file is first visible after rows remeasure")
        XCTAssertTrue(typing(), "the keys still in the commit message")

        cycles += try await layoutCycles {
            try await resize(window, width: 1280)
        }
        XCTAssertTrue(views(GitDiffTableView.self, in: window.contentView!).first === table, "Wide again: the same diff table")
        XCTAssertEqual(frame(list).width, GitPanelSplit.listWidth, accuracy: 1)
        XCTAssertEqual(frame(diff).minX, GitPanelSplit.listWidth + 1, accuracy: 1)
        XCTAssertEqual(diff.contentView.bounds.origin.y, 900, accuracy: 1)
        XCTAssertEqual(firstVisibleRow(in: list), firstRow)
        XCTAssertTrue(typing())

        // Back and forth across the line, a point either side of it.
        cycles += try await layoutCycles {
            for width in [899, 900, 901, 899, 901, 900] as [CGFloat] {
                try await resize(window, width: width)
                let beside = frame(diff).minX > 1
                XCTAssertEqual(beside, width >= GitPanelView.wideWidth, "At \(width) points the list is \(beside ? "beside" : "above") the diff")
            }
        }
        XCTAssertEqual(cycles, 0, "No layout cycle across the line")
        XCTAssertEqual(controller.shownChanges, shown, "The panel never left the screen")
        XCTAssertTrue(views(GitDiffTableView.self, in: window.contentView!).first === table)
    }

    /// A window too short for the list, the commit box and the diff keeps the
    /// commit box whole, a five-line message included: the diff gives way.
    @MainActor func testAShortNarrowPanelKeepsTheCommitBoxWhole() async throws {
        let root = try fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        controller.commitMessage = "Tidy\n\nOne\nTwo\nThree"
        for (height, diffShown) in [(640, true), (420, false)] as [(CGFloat, Bool)] {
            let window = host(GitPanelView(controller: controller), width: 700, height: height)
            defer { window.contentView = nil; window.close() }
            try await eventually("the first read") { controller.status.entries.count == 31 && !controller.diffLoading && !controller.diff.isEmpty }
            try await draw(window, passes: 4)
            let content = window.contentLayoutRect
            let field = try XCTUnwrap(views(NSTextField.self, in: window.contentView!).first { $0.isEditable && $0.placeholderString == "Commit message" })
            XCTAssertTrue(content.contains(frame(field)), "At \(height) points the whole commit message fits: \(frame(field)) in \(content)")
            XCTAssertEqual(field.stringValue, controller.commitMessage, "the five-line draft is retained")
            let diff = try XCTUnwrap(views(GitDiffTableView.self, in: window.contentView!).first?.enclosingScrollView)
            if diffShown { XCTAssertGreaterThanOrEqual(frame(diff).height, 170, "Tall enough, the diff keeps its room") }
            else { XCTAssertLessThan(frame(diff).height, 170, "Too short for both, the diff gives way") }
        }
        controller.letGo()
    }

    /// A chip whose file's name is wider than the row is cut to the row, its
    /// name cut in the middle; its help keeps the whole path.
    @MainActor func testAChipWiderThanItsRowIsCutToIt() throws {
        let commit = GitCommit(hash: String(repeating: "c", count: 40), shortHash: "ccccccc", author: "Fixture", date: Date(), subject: "Long", parents: [])
        let long = "src/" + String(repeating: "AVeryLongComponentName", count: 12) + ".swift"
        let files = [GitStatusEntry(path: "a.swift", originalPath: nil, indexState: "M", worktreeState: ".", untracked: false),
                     GitStatusEntry(path: long, originalPath: nil, indexState: "M", worktreeState: ".", untracked: false)]
        let detail = GitCommitDetail(commit: commit, message: "Long", files: files, stats: [:])
        let holder = ChipHolder()
        let window = host(GitCommitFileChips(detail: detail, selected: Binding(get: { holder.selected }, set: { holder.selected = $0 }),
                                             shown: Binding(get: { holder.shown }, set: { holder.shown = $0 }), showHistory: { _ in })
                            .frame(width: 320), width: 400, height: 300)
        defer { window.contentView = nil; window.close() }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let chips = try XCTUnwrap(views(GitFileChipsView.self, in: window.contentView!).first)
        let elements = try XCTUnwrap(chips.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(elements.count, 3)
        for element in elements {
            XCTAssertLessThanOrEqual(element.accessibilityFrameInParentSpace().maxX, chips.bounds.width + 0.5, "\(element.accessibilityLabel() ?? "") fits its row")
        }
        let cut = elements[2].accessibilityFrameInParentSpace()
        XCTAssertEqual(chips.view(chips, stringForToolTip: 0, point: NSPoint(x: cut.midX, y: cut.midY), userData: nil), long, "Its help: the whole path")
    }
}
