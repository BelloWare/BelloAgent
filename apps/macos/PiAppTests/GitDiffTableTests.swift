import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The diff as a native table does what the SwiftUI rows did, and a little
/// more: text is selected and copied across lines as well as within one, a
/// word or a line at a click, all of it at once; the keys scroll it; Escape
/// still closes the sheet around it; every row says what it shows; and a
/// commit's file chips narrow the diff, add the next step, name their file
/// and offer its history.
final class GitDiffTableTests: GitPanelTestCase {
    static let patch = """
    diff --git a/Sources/Engine/Router.swift b/Sources/Engine/Router.swift
    --- a/Sources/Engine/Router.swift
    +++ b/Sources/Engine/Router.swift
    @@ -18,9 +18,12 @@ struct Router {
         let profile: Profile
    -    var timeout: Duration = .seconds(30)
    -    func route(_ request: Request) throws -> Route {
    +    var timeout: Duration = .seconds(45)
    +    var retries = 2
    +    func route(_ request: Request, attempt: Int = 0) throws -> Route {
             guard let host = request.host else { throw RouterError.noHost }
    -        return Route(host: host, timeout: timeout)
    +        let budget = timeout / Duration.seconds(max(1, retries - attempt))
    +        return Route(host: host, timeout: budget)
         }
     }

    """

    @MainActor final class Pane {
        let window: NSWindow
        let holder = DiffHolder()
        var split = false
        init(files: [GitDiffFile], split: Bool = false, width: CGFloat = 820, height: CGFloat = 420) {
            self.split = split
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let holder = holder
            window.contentView = NSHostingView(rootView: DiffView(files: files, title: "Sources/Engine/Router.swift", subtitle: "Working tree versus index", identity: "tests",
                                                                   split: Binding(get: { split }, set: { _ in }), expanded: Binding(get: { holder.expanded }, set: { holder.expanded = $0 })))
            window.makeKeyAndOrderFront(nil)
            draw()
        }
        func draw() { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        var table: GitDiffTableView { views(GitDiffTableView.self, in: window.contentView!).first! }
        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) } }
        /// A row's text, from its left edge to `x` points in.
        func point(row: Int, x: CGFloat, side: GitDiffSide = .whole) -> NSPoint {
            let table = table, rect = table.rect(ofRow: row)
            let card = table.bounds.width - 2 * GitDiffMetrics.cardInset
            let kind = table.coordinator!.rows[row].kind
            let frame = GitDiffRowCell.textFrame(kind, side: side, card: card, rowWidth: table.bounds.width)
            return table.convert(NSPoint(x: frame.x + x, y: rect.minY + 8), to: nil)
        }
        func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        /// A press at `from`, dragged to `to` and let go.
        func drag(from: NSPoint, to: NSPoint, clicks: Int = 1) {
            NSApp.postEvent(event(.leftMouseDragged, at: to, clicks: clicks), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, at: to, clicks: clicks), atStart: false)
            table.mouseDown(with: event(.leftMouseDown, at: from, clicks: clicks))
            draw()
        }
        func copied() -> String? {
            NSPasteboard.general.clearContents()
            table.copy(nil)
            return NSPasteboard.general.string(forType: .string)
        }
        func key(_ code: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func close() { window.contentView = nil; window.close() }
    }

    /// The rows that hold a hunk's lines, in order.
    @MainActor private func lineRows(_ table: GitDiffTableView) -> [Int] {
        table.coordinator!.rows.indices.filter { [.line, .split].contains(table.coordinator!.rows[$0].kind) }
    }

    @MainActor func testTextIsSelectedAndCopiedWithinALineAndAcrossLines() throws {
        let files = GitDiffParser.parse(Self.patch)
        let lines = files[0].hunks[0].lines.map(\.text)
        let pane = Pane(files: files); defer { pane.close() }
        let rows = lineRows(pane.table)
        XCTAssertEqual(rows.count, lines.count, "One row a line")

        // Across three lines: from the start of the second to past the end of the fourth.
        pane.drag(from: pane.point(row: rows[1], x: 1), to: pane.point(row: rows[3], x: 2_000))
        XCTAssertEqual(pane.copied(), lines[1...3].joined(separator: "\n"))
        // Within a line: its first eight characters, dragged backwards.
        let eight = CGFloat(CTLineGetOffsetForStringIndex(GitDiffText.line(lines[5], font: GitDiffMetrics.mono), 8, nil))
        pane.drag(from: pane.point(row: rows[5], x: eight + 1), to: pane.point(row: rows[5], x: 0.5))
        XCTAssertEqual(pane.copied(), String(lines[5].prefix(8)))
        // A word at a double click, a line at a triple click.
        let word = CGFloat(CTLineGetOffsetForStringIndex(GitDiffText.line(lines[1], font: GitDiffMetrics.mono), 9, nil))
        pane.drag(from: pane.point(row: rows[1], x: word), to: pane.point(row: rows[1], x: word), clicks: 2)
        XCTAssertEqual(pane.copied(), "timeout")
        pane.drag(from: pane.point(row: rows[1], x: word), to: pane.point(row: rows[1], x: word), clicks: 3)
        XCTAssertEqual(pane.copied(), lines[1])
        // Everything: the file's path, then every line.
        pane.table.selectAll(nil)
        XCTAssertEqual(pane.copied(), (["Sources/Engine/Router.swift"] + lines).joined(separator: "\n"))
        // A click without a drag clears the selection, and Copy has nothing to copy.
        pane.drag(from: pane.point(row: rows[2], x: 3), to: pane.point(row: rows[2], x: 3))
        XCTAssertEqual(pane.copied(), nil)
    }

    @MainActor func testSideBySideSelectsOneSide() throws {
        let files = GitDiffParser.parse(Self.patch)
        let pairs = files[0].hunks[0].splitRows()
        let pane = Pane(files: files, split: true); defer { pane.close() }
        let rows = lineRows(pane.table)
        XCTAssertEqual(rows.count, pairs.count)
        // Down the right side, the new text, and nothing from the left.
        pane.drag(from: pane.point(row: rows[1], x: 1, side: .right), to: pane.point(row: rows[3], x: 2_000, side: .right))
        XCTAssertEqual(pane.copied(), pairs[1...3].compactMap { $0.right?.text }.joined(separator: "\n"))
        pane.drag(from: pane.point(row: rows[1], x: 1, side: .left), to: pane.point(row: rows[2], x: 2_000, side: .left))
        XCTAssertEqual(pane.copied(), pairs[1...2].compactMap { $0.left?.text }.joined(separator: "\n"))
    }

    @MainActor func testTheMenusOfferCopySelectAllAndTheFilesPath() throws {
        let pane = Pane(files: GitDiffParser.parse(Self.patch)); defer { pane.close() }
        let rows = lineRows(pane.table)
        func titles(row: Int) -> [String] {
            let menu = pane.table.menu(for: pane.event(.rightMouseDown, at: pane.point(row: row, x: 4)))
            return menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        }
        XCTAssertEqual(titles(row: rows[0]), ["Copy", "Select All"])
        let fileRow = try XCTUnwrap(pane.table.coordinator!.rows.firstIndex { $0.kind == .file })
        XCTAssertEqual(titles(row: fileRow), ["Copy", "Select All", "Copy Path"])
        let menu = try XCTUnwrap(pane.table.menu(for: pane.event(.rightMouseDown, at: pane.point(row: fileRow, x: 4))))
        let copyPath = try XCTUnwrap(menu.items.first { $0.title == "Copy Path" })
        NSPasteboard.general.clearContents()
        menu.performActionForItem(at: menu.index(of: copyPath))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Sources/Engine/Router.swift")
    }

    /// The app draws the diff in its own colours and gives it its own menu:
    /// the table's defaults are for other hosts.
    @MainActor func testTheAppGivesTheTableItsOwnColoursAndMenu() throws {
        let pane = Pane(files: GitDiffParser.parse(Self.patch)); defer { pane.close() }
        let coordinator = try XCTUnwrap(pane.table.coordinator)
        XCTAssertEqual(coordinator.colors, GitDiffColors.pi)
        XCTAssertNotEqual(coordinator.colors, GitDiffColors.system)
        XCTAssertNotNil(coordinator.menu, "The app's menu, not the plain one")
    }

    /// A host that gives the table no menu of its own gets the plain one:
    /// Copy (only with text selected), Select All and, over a file's header,
    /// Copy Path. A builder that answers nil shows none. The app gives its own
    /// (`GitDiffPiMenu`, tested above through `DiffView`).
    @MainActor func testATableGivenNoMenuOffersThePlainOne() throws {
        let files = GitDiffParser.parse(Self.patch)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func host(menu: GitDiffMenuBuilder?) throws -> GitDiffTableView {
            window.contentView = NSHostingView(rootView: GitDiffTable(files: files, split: false, wrap: false, showAll: false, identity: "menu",
                                                                      top: AnyView(Text("Heading")), topKey: 0, more: nil, menu: menu))
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return try XCTUnwrap(Pane.views(in: window.contentView!).first)
        }
        func menu(_ table: GitDiffTableView, row: Int) -> NSMenu? {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.minY + 8), to: nil)
            return table.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        let table = try host(menu: nil)
        let line = try XCTUnwrap(lineRows(table).first), file = try XCTUnwrap(table.coordinator!.rows.firstIndex { $0.kind == .file })
        let plain = try XCTUnwrap(menu(table, row: line))
        XCTAssertEqual(plain.items.map(\.title), ["Copy", "Select All"])
        XCTAssertEqual(plain.items.map { $0.identifier?.rawValue }, ["git-diff-copy", "git-diff-select-all"])
        XCTAssertFalse(plain.autoenablesItems)
        XCTAssertEqual(plain.items.map(\.isEnabled), [false, true], "Nothing selected: nothing to copy")
        plain.performActionForItem(at: 1)
        XCTAssertEqual(try XCTUnwrap(menu(table, row: line)).items.first?.isEnabled, true, "Select All ran; Copy has text now")
        let header = try XCTUnwrap(menu(table, row: file))
        XCTAssertEqual(header.items.map(\.title), ["Copy", "Select All", "", "Copy Path"])
        XCTAssertTrue(header.items[2].isSeparatorItem)
        NSPasteboard.general.clearContents()
        header.performActionForItem(at: 3)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Sources/Engine/Router.swift")

        XCTAssertNil(menu(try host(menu: { _ in nil }), row: line), "A builder that answers nil shows no menu")
    }

    @MainActor func testTheKeysScrollTheDiff() throws {
        let body = (0..<400).map { "+line \($0)" }.joined(separator: "\n")
        let files = GitDiffParser.parse("diff --git a/long.txt b/long.txt\n--- /dev/null\n+++ b/long.txt\n@@ -0,0 +1,400 @@\n" + body + "\n")
        let pane = Pane(files: files); defer { pane.close() }
        let table = pane.table, clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
        pane.window.makeFirstResponder(table)
        table.keyDown(with: pane.key(125)); pane.draw()
        XCTAssertEqual(clip.bounds.minY, GitDiffMetrics.monoLine + 2, "Down arrow: a row")
        table.keyDown(with: pane.key(121)); pane.draw()
        XCTAssertEqual(clip.bounds.minY, GitDiffMetrics.monoLine + 2 + clip.bounds.height - GitDiffMetrics.monoLine - 2, accuracy: 0.5, "Page Down: a page")
        table.keyDown(with: pane.key(119)); pane.draw()
        XCTAssertEqual(clip.bounds.maxY, table.frame.height, accuracy: 0.5, "End: the bottom")
        table.keyDown(with: pane.key(116)); pane.draw()
        XCTAssertLessThan(clip.bounds.maxY, table.frame.height - 100, "Page Up: a page back")
        table.keyDown(with: pane.key(115)); pane.draw()
        XCTAssertEqual(clip.bounds.minY, 0, "Home: the top")
        table.keyDown(with: pane.key(49, " ")); pane.draw()
        XCTAssertGreaterThan(clip.bounds.minY, 100, "Space: a page")
    }

    @MainActor func testWrappedLinesMakeTheirRowsTaller() throws {
        let long = String(repeating: "wrap me ", count: 60)
        let files = GitDiffParser.parse("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n-short\n+" + long + "\n context\n")
        var wrap = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func host() {
            window.contentView = NSHostingView(rootView: GitDiffTable(files: files, split: false, wrap: wrap, showAll: false, identity: "wrap",
                                                                      top: AnyView(Text("Heading")), topKey: 0, more: nil))
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func heights() throws -> [CGFloat] {
            let table = try XCTUnwrap(Pane.views(in: window.contentView!).first)
            return lineRows(table).map { table.rect(ofRow: $0).height }
        }
        host()
        XCTAssertEqual(try heights(), [17, 17, 17], "Cut to one line each, as before")
        wrap = true; host()
        let wrapped = try heights()
        XCTAssertEqual(wrapped[0], 17); XCTAssertEqual(wrapped[2], 17)
        XCTAssertGreaterThan(wrapped[1], 3 * GitDiffMetrics.monoLine, "The long line wraps")
        XCTAssertEqual((wrapped[1] - 2).truncatingRemainder(dividingBy: GitDiffMetrics.monoLine), 0, "A whole number of lines")
    }

    @MainActor func testRowsSayWhatTheyShow() throws {
        let pane = Pane(files: GitDiffParser.parse(Self.patch)); defer { pane.close() }
        XCTAssertEqual(pane.table.accessibilityIdentifier(), "git-diff-table")
        let rows = lineRows(pane.table)
        let removed = try XCTUnwrap(pane.table.view(atColumn: 0, row: rows[1], makeIfNecessary: true))
        XCTAssertEqual(removed.accessibilityValue() as? String, "Removed line 19: " + "    var timeout: Duration = .seconds(30)")
        let added = try XCTUnwrap(pane.table.view(atColumn: 0, row: rows[3], makeIfNecessary: true))
        XCTAssertEqual(added.accessibilityValue() as? String, "Added line 19: " + "    var timeout: Duration = .seconds(45)")
        XCTAssertNotNil(pane.views(GitDiffTableView.self, in: pane.window.contentView!).first?.window)
    }

    /// Escape still closes the Changes sheet when the diff has the keyboard.
    @MainActor func testEscapeClosesTheSheetFromTheDiff() async throws {
        let root = try repository("diff-escape")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try "two\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [root.path]), presenter = ChangesSheetPresenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChangesSheetHost(presenter: presenter, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { presenter.showing = false; window.contentView = nil; window.close() }
        presenter.showing = true
        try await eventually("the diff") { !controller.diff.isEmpty && window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.contentView?.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(Pane.views(in: sheet.contentView!).first)
        XCTAssertTrue(sheet.makeFirstResponder(table))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: 53))
        sheet.sendEvent(escape)
        try await eventually("the sheet to close") { !presenter.showing }
    }

    /// A commit's chips: "All" and the files, the file chosen, the next step
    /// of a commit with more files than one step, and a file's menu and help.
    @MainActor func testTheFileChipsChooseAFileAndShowMore() throws {
        let commit = GitCommit(hash: String(repeating: "b", count: 40), shortHash: "bbbbbbb", author: "Fixture", date: Date(), subject: "Wide", parents: [])
        let files = (0..<250).map { GitStatusEntry(path: "src/File\($0).swift", originalPath: nil, indexState: $0 == 3 ? "D" : "M", worktreeState: ".", untracked: false) }
        var stats: [String: GitDiffStat] = [:]
        for file in files { stats[file.path] = GitDiffStat(added: 3, removed: 1, binary: false) }
        let detail = GitCommitDetail(commit: commit, message: "Wide", files: files, stats: stats)
        let holder = ChipHolder()
        var history: [String] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func host() {
            window.contentView = NSHostingView(rootView: GitCommitFileChips(detail: detail, selected: Binding(get: { holder.selected }, set: { holder.selected = $0 }),
                                                                            shown: Binding(get: { holder.shown }, set: { holder.shown = $0 }), showHistory: { history.append($0) }))
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host()
        let view = try XCTUnwrap(Pane.views(GitFileChipsView.self, in: window.contentView!).first)
        let chips = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(chips.count, 1 + GitCommitFileChips.step + 1, "All, the first step of files, and the next step")
        XCTAssertEqual(chips.first?.accessibilityLabel(), "All 250 files")
        XCTAssertEqual(chips[4].accessibilityLabel(), "D File3.swift · +3 −1")
        XCTAssertEqual(chips[4].accessibilityIdentifier(), "git-commit-file-src/File3.swift")
        XCTAssertEqual(chips.last?.accessibilityLabel(), "50 more files")
        XCTAssertEqual(chips.last?.accessibilityIdentifier(), "git-commit-more-files")
        XCTAssertTrue(chips[4].accessibilityPerformPress())
        XCTAssertEqual(holder.selected, "src/File3.swift", "A file narrows the diff")
        host()
        let again = try XCTUnwrap(Pane.views(GitFileChipsView.self, in: window.contentView!).first)
        XCTAssertTrue((again.accessibilityChildren() as? [NSAccessibilityElement])?[4].accessibilityPerformPress() == true)
        XCTAssertNil(holder.selected, "and pressed again widens it")
        XCTAssertTrue((again.accessibilityChildren() as? [NSAccessibilityElement])?.last?.accessibilityPerformPress() == true)
        XCTAssertEqual(holder.shown, 2 * GitCommitFileChips.step, "More files, a step at a time")
        // A file chip's help and menu.
        let frame = try XCTUnwrap((again.accessibilityChildren() as? [NSAccessibilityElement])?[1].accessibilityFrameInParentSpace())
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(again.view(again, stringForToolTip: 0, point: middle, userData: nil), "src/File0.swift · +3 −1")
        let right = NSEvent.mouseEvent(with: .rightMouseDown, location: again.convert(middle, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(again.menu(for: right))
        XCTAssertEqual(menu.items.map(\.title), ["Show History of This File", "Copy Path"])
        menu.performActionForItem(at: 0)
        XCTAssertEqual(history, ["src/File0.swift"])
    }
}

extension GitDiffTableTests.Pane {
    @MainActor static func views(in view: NSView) -> [GitDiffTableView] { views(GitDiffTableView.self, in: view) }
    @MainActor static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) } }
}
