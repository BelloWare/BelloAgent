import XCTest
import SwiftUI
import AppKit
import ObjectiveC
@testable import PiApp
@testable import GitView

/// The diff as a native table does what the SwiftUI rows did, and a little
/// more: text is selected and copied across lines as well as within one, a
/// word or a line at a click, all of it at once; the keys scroll it; Escape
/// still closes the sheet around it; every row says what it shows; and a
/// commit's file chips narrow the diff, add the next step, name their file
/// and offer its history.
final class GitDiffTableTests: GitPanelTestCase, SerialTestLane {
    @MainActor private var restorePasteboard: (() -> Void)?
    @MainActor override func setUp() async throws {
        // The app and the package's default menu both use +general. Keep
        // these serial tests on one private board without touching the desktop.
        let board = NSPasteboard(name: .init("git-diff-tests-" + UUID().uuidString))
        let method = try XCTUnwrap(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)))
        let replacement = imp_implementationWithBlock({ (_: AnyObject) -> NSPasteboard in board } as @convention(block) (AnyObject) -> NSPasteboard)
        let original = method_setImplementation(method, replacement)
        restorePasteboard = {
            method_setImplementation(method, original); imp_removeBlock(replacement); board.releaseGlobally()
        }
        guard NSPasteboard.general.name == board.name else {
            restorePasteboard?(); restorePasteboard = nil
            throw NSError(domain: "GitDiffTableTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not isolate the copy destination."])
        }
    }
    @MainActor override func tearDown() async throws {
        restorePasteboard?(); restorePasteboard = nil
    }

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
        init(files: [GitDiffFile], split: Bool = false, width: CGFloat = 820, height: CGFloat = 420, openFile: ((String, Int) -> Void)? = nil) {
            self.split = split
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let holder = holder
            window.contentView = makeDiffView(files: files, title: "Sources/Engine/Router.swift", subtitle: "Working tree versus index", identity: "tests",
                                              split: split, holder: holder, openFile: openFile)
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

    @MainActor private func drawingTable(_ text: String, split: Bool, wrap: Bool) -> GitDiffTable {
        let diff = GitDiffTable()
        diff.frame = NSRect(x: 0, y: 0, width: 700, height: 220)
        let files = GitDiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-" + text + "\n+" + text + "\n")
        diff.update(files: files, split: split, wrap: wrap, showAll: true, identity: "drawing", top: TestDiffHeading("Heading"), topHeightKey: 0, more: nil)
        let window = host(diff, width: 700, height: 220)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        diff.layoutSubtreeIfNeeded(); diff.table.layoutSubtreeIfNeeded()
        return diff
    }

    /// Draw a small tile of an enormous row, as AppKit does while scrolling.
    @MainActor private func drawTile(_ cell: GitDiffRowCell, rect: NSRect) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.translateBy(x: 0, y: -rect.minY)
        graphics.cgContext.clip(to: rect)
        cell.draw(rect)
    }

    /// Hosting may change the table width after its first height pass. The
    /// final geometry is asynchronous; a synchronous layout alone cannot
    /// establish that drawing and row heights are using the same width.
    @MainActor private func waitForWrapGeometry(_ diff: GitDiffTable) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        repeat {
            diff.layoutSubtreeIfNeeded(); diff.table.layoutSubtreeIfNeeded()
            if !diff.coordinator.preparingWrapGeometry,
               diff.coordinator.wrappingWidth == diff.table.bounds.width { return }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        XCTFail("wrap geometry did not settle at the hosted table's width")
    }

    @MainActor func testRebuiltWrappedRowsFinalizeAfterLiveResizeAtTheSameWidth() async throws {
        try await rebuiltRowsFinalize(pendingRefresh: false)
    }

    @MainActor func testPendingStateDoesNotDropWrappedRowFinalizationAtTheSameWidth() async throws {
        try await rebuiltRowsFinalize(pendingRefresh: true)
    }

    @MainActor private func rebuiltRowsFinalize(pendingRefresh: Bool) async throws {
        for split in [false, true] {
            let diff = drawingTable("initial", split: split, wrap: true)
            defer { diff.close() }
            try await waitForWrapGeometry(diff)
            let table = diff.table
            table.viewWillStartLiveResize()
            let text = String(repeating: "words to wrap ", count: 80)
            let files = GitDiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-" + text + "\n+" + text + "\n")
            let heading = TestDiffHeading("Heading")
            diff.update(files: files, split: split, wrap: true, showAll: true, identity: "rebuilt",
                        top: heading, topHeightKey: 0, more: nil)
            diff.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
            let row = try XCTUnwrap(lineRows(table).first)
            let provisional = table.rect(ofRow: row).height
            XCTAssertEqual(provisional, GitDiffMetrics.monoLine + 2)
            XCTAssertEqual(diff.coordinator.wrappingWidth, table.bounds.width, "a rebuild already recorded the final width")
            // Detach only to control when the pending state is laid out;
            // AppKit otherwise applies it automatically in the run loop.
            if pendingRefresh { diff.window?.contentView = nil }
            table.viewDidEndLiveResize()
            if pendingRefresh {
                diff.update(files: files, split: split, wrap: true, showAll: true, identity: "rebuilt",
                            top: heading, topHeightKey: 1, more: nil)
                let deadline = ContinuousClock.now + .seconds(20)
                while diff.coordinator.preparingWrapGeometry, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertFalse(diff.coordinator.preparingWrapGeometry)
                XCTAssertEqual(diff.coordinator.wrappingWidth, table.bounds.width)
            }
            try await waitForWrapGeometry(diff)
            let card = diff.coordinator.cardWidth(table.bounds.width)
            let width = split ? GitDiffMetrics.textWidth(split: card) : GitDiffMetrics.textWidth(unified: card)
            let expected = CGFloat(GitDiffText.lineCount(text, font: GitDiffMetrics.mono, width: width)) * GitDiffMetrics.monoLine + 2
            print("GIT_DIFF rebuilt split=\(split) refresh=\(pendingRefresh) provisional=\(provisional) final=\(table.rect(ofRow: row).height) expected=\(expected)")
            XCTAssertGreaterThan(expected, provisional)
            for row in lineRows(table) {
                XCTAssertEqual(table.rect(ofRow: row).height, expected, "AppKit's cached provisional height must be invalidated")
            }
        }
    }

    @MainActor func testWrappedDiffDrawingVisitsOnlyTheDirtyFragments() async throws {
        for split in [false, true] {
            let diff = drawingTable(String(repeating: "wrap 😀 me ", count: 10_000), split: split, wrap: true)
            defer { diff.close() }
            try await waitForWrapGeometry(diff)
            let row = try XCTUnwrap(lineRows(diff.table).first)
            // Establish the height pass before resetting the counters. No
            // drawing or direct call to lines(of:) may warm the tile below.
            let height = diff.coordinator.tableView(diff.table, heightOfRow: row)
            let cell = GitDiffRowCell(); cell.coordinator = diff.coordinator; cell.row = row
            cell.frame = NSRect(x: 0, y: 0, width: diff.table.bounds.width, height: height)
            let tile = NSRect(x: 0, y: 1 + 700 * GitDiffMetrics.monoLine, width: cell.bounds.width, height: 150)
            XCTAssertGreaterThan(cell.bounds.height, tile.maxY)
            GitDiffRenderCount.reset()
            try drawTile(cell, rect: tile)
            let first = GitDiffRenderCount.textShapes
            print("GIT_DIFF wrapped split=\(split) fragments=\(GitDiffRenderCount.fragments) shapes=\(first) wrap passes=\(GitDiffRenderCount.wraps)")
            XCTAssertEqual(GitDiffRenderCount.fragments, split ? 20 : 10)
            XCTAssertLessThanOrEqual(first, split ? 20 : 10)
            XCTAssertEqual(GitDiffRenderCount.wraps, 0, "drawing reuses geometry already measured for the row")
            GitDiffRenderCount.reset()
            try drawTile(cell, rect: tile)
            XCTAssertEqual(GitDiffRenderCount.textShapes, 0, "an unchanged tile reuses its shaped lines")
            XCTAssertEqual(GitDiffRenderCount.wraps, 0)
            let nextTile = tile.offsetBy(dx: 0, dy: 150)
            try drawTile(cell, rect: nextTile)
            XCTAssertLessThanOrEqual(GitDiffRenderCount.textShapes, split ? 20 : 10)
        }
    }

    @MainActor func testUnselectedDiffTextIsShapedOnceAndReusedOnRedraw() throws {
        let diff = drawingTable("a short line", split: false, wrap: false)
        defer { diff.close() }
        let row = try XCTUnwrap(lineRows(diff.table).first)
        let cell = GitDiffRowCell(); cell.coordinator = diff.coordinator; cell.row = row
        cell.frame = NSRect(x: 0, y: 0, width: diff.table.bounds.width, height: 17)
        GitDiffRenderCount.reset()
        try drawTile(cell, rect: cell.bounds)
        XCTAssertEqual(GitDiffRenderCount.textShapes, 1, "selection and painting share one shaped line")
        GitDiffRenderCount.reset()
        try drawTile(cell, rect: cell.bounds)
        XCTAssertEqual(GitDiffRenderCount.textShapes, 0)
        diff.coordinator.select(from: GitDiffTextPoint(row: row, index: 0), to: GitDiffTextPoint(row: row, index: 5), side: .whole)
        try drawTile(cell, rect: cell.bounds)
        XCTAssertEqual(GitDiffRenderCount.textShapes, 0, "selection uses the same cached shape")
    }

    @MainActor func testLiveResizeKeepsProvisionalHeightsAndInstallsFinalGeometryAtTheReadingAnchor() async throws {
        let diff = GitDiffTable(), heading = TestDiffHeading("Heading")
        diff.frame = NSRect(x: 0, y: 0, width: 700, height: 220)
        let line = String(repeating: "words to wrap ", count: 30)
        let files = GitDiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,10000 +1,10000 @@\n" + String(repeating: " " + line + "\n", count: 10_000))
        diff.update(files: files, split: false, wrap: true, showAll: true, identity: "resize", top: heading, topHeightKey: 0, more: nil)
        let window = host(diff, width: 700, height: 220)
        diff.layoutSubtreeIfNeeded(); diff.table.layoutSubtreeIfNeeded()
        defer { diff.close(); window.contentView = nil; window.close() }
        try await waitForWrapGeometry(diff)
        let table = diff.table, row = 5_000
        let originalHeight = table.rect(ofRow: row).height
        diff.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + 3))
        table.viewWillStartLiveResize()
        GitDiffRenderCount.reset()
        for width in stride(from: 680, through: 440, by: -30) {
            window.setContentSize(NSSize(width: width, height: 220))
            diff.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
            // AppKit can ask for offscreen heights on every resize step.
            for index in diff.coordinator.rows.indices { _ = diff.coordinator.tableView(table, heightOfRow: index) }
            XCTAssertEqual(table.rect(ofRow: row).height, originalHeight, "live resize keeps provisional row geometry")
        }
        print("GIT_DIFF resize main-thread wrap passes=\(GitDiffRenderCount.wraps) for 10000 rows × 9 widths")
        XCTAssertLessThanOrEqual(GitDiffRenderCount.wraps, 50, "work on a resize step must be limited to the visible area")
        let anchor = table.row(at: NSPoint(x: 1, y: diff.contentView.bounds.minY))
        let offset = diff.contentView.bounds.minY - table.rect(ofRow: anchor).minY
        table.viewDidEndLiveResize()
        let deadline = ContinuousClock.now + .seconds(20)
        while diff.coordinator.preparingWrapGeometry, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(diff.coordinator.preparingWrapGeometry)
        XCTAssertEqual(diff.coordinator.wrappingWidth, table.bounds.width)
        let expected = CGFloat(GitDiffText.lineCount(line, font: GitDiffMetrics.mono,
            width: GitDiffMetrics.textWidth(unified: diff.coordinator.cardWidth(table.bounds.width)))) * GitDiffMetrics.monoLine + 2
        XCTAssertEqual(table.rect(ofRow: row).height, expected)
        XCTAssertGreaterThan(expected, originalHeight)
        XCTAssertEqual(diff.contentView.bounds.minY - table.rect(ofRow: anchor).minY, offset, accuracy: 1)
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

    @MainActor func testAUnifiedDiffLineOffersOpeningItsFileAtThatLine() throws {
        let files = GitDiffParser.parse(Self.patch)
        var opened: (String, Int)?
        let pane = Pane(files: files, openFile: { opened = ($0, $1) }); defer { pane.close() }
        for (row, line) in zip(lineRows(pane.table), files[0].hunks[0].lines) {
            let menu = try XCTUnwrap(pane.table.menu(for: pane.event(.rightMouseDown, at: pane.point(row: row, x: 4))))
            let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "git-diff-open-file" })
            menu.performActionForItem(at: menu.index(of: item))
            XCTAssertEqual(opened?.0, files[0].path)
            XCTAssertEqual(opened?.1, line.newNumber ?? line.oldNumber)
        }
        let hunk = try XCTUnwrap(pane.table.coordinator?.rows.firstIndex { $0.kind == .hunk })
        XCTAssertNil(pane.table.coordinator?.fileLine(at: hunk, side: .whole), "a header has no numbered line")
    }

    @MainActor func testASplitDiffUsesTheLineNumberUnderThePointerAndLeavesEmptySidesWithoutAnAction() throws {
        let files = GitDiffParser.parse(Self.patch)
        let pane = Pane(files: files, split: true); defer { pane.close() }
        let pairs = files[0].hunks[0].splitRows()
        for (row, pair) in zip(lineRows(pane.table), pairs) {
            XCTAssertEqual(pane.table.coordinator?.fileLine(at: row, side: .left)?.line, pair.left?.oldNumber)
            XCTAssertEqual(pane.table.coordinator?.fileLine(at: row, side: .right)?.line, pair.right?.newNumber)
        }
        XCTAssertTrue(pairs.contains { $0.left == nil || $0.right == nil }, "the fixture covers an empty side")
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
            let table = GitDiffTable()
            table.update(files: files, split: false, wrap: false, showAll: false, identity: "menu", top: TestDiffHeading("Heading"), topHeightKey: 0, more: nil, menu: menu)
            window.contentView = table
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
            let table = GitDiffTable()
            table.update(files: files, split: false, wrap: wrap, showAll: false, identity: "wrap", top: TestDiffHeading("Heading"), topHeightKey: 0, more: nil)
            window.contentView = table
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

    /// ⌘W closes the Changes tab, in a window of its own, when the diff has
    /// the keyboard: the diff takes the keys it scrolls with and no others.
    @MainActor func testCommandWClosesTheChangesTabFromTheDiff() async throws {
        let root = try repository("diff-close")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try "two\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let host = TabHost(defaults: nil)
        host.showsWindows = false
        defer { host.tearDown() }
        let tab = host.open(kind: ChangesTab.kind, key: "diff-close") { ChangesTab(projectID: "diff-close", name: "diff-close", roots: [root.path]) } as! ChangesTab
        let popped = host.popOut(tab)
        let window = try XCTUnwrap(host.window(of: popped))
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("the diff") {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return tab.hasController && !tab.controller.diff.isEmpty && Pane.views(in: window.contentView!).first != nil
        }
        let table = try XCTUnwrap(Pane.views(in: window.contentView!).first)
        XCTAssertTrue(window.makeFirstResponder(table))
        let commandW = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                      isARepeat: false, keyCode: 13))
        XCTAssertTrue(window.performKeyEquivalent(with: commandW), "⌘W is taken")
        XCTAssertTrue(host.allTabs.isEmpty, "The Changes tab closed, and its window with it")
        XCTAssertTrue(host.windows.isEmpty)
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
            window.contentView = makeChipsView(detail, holder: holder) { history.append($0) }
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
