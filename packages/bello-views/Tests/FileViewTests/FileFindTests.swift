import XCTest
import AppKit
@testable import FileView

/// Finding in a text view (`FileFind`): a query shows the first match at or
/// after where finding began, and keeps it as more is typed while it still
/// matches; Next and Previous go on in the order asked; a reader who moves
/// the selection meanwhile has the last word; matches are drawn only on the
/// lines drawn; a match along a long line is scrolled to sideways; a file
/// read again is searched again.
final class FileFindTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = scratchRoot("file-find")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }
    private func file(_ text: String) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }
    @MainActor private func shown(_ source: FileTextSource, width: CGFloat = 500) -> FileTextScrollView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        window.contentView = scroll
        scroll.textView.show(source, name: "find.txt")
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return scroll
    }
    @MainActor private func opened(_ url: URL, _ options: FileDocument.Options = FileDocument.Options()) async throws -> FileDocument {
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("read through") { document.status != .indexing }
        return document
    }
    @MainActor private func draw(_ scroll: FileTextScrollView) {
        let view = scroll.textView
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return }
        view.cacheDisplay(in: view.visibleRect, to: bitmap)
    }
    private func lines(_ count: Int, _ body: (Int) -> String) -> String { (0..<count).map(body).joined(separator: "\n") }

    @MainActor func testTypingShowsTheFirstMatchFromWhereFindingBeganAndKeepsIt() async throws {
        let text = lines(400) { $0 == 120 ? "the needle here" : ($0 == 300 ? "needles and a needle" : "hay \($0)") }
        let scroll = shown(FileTextLines(text))
        let view = scroll.textView
        view.select(from: FileTextPosition(line: 100, column: 0), to: FileTextPosition(line: 100, column: 0))
        let find = FileFind(view: view)
        find.set(query: "need", matchCase: false)
        try await eventually("shown") { find.current != nil }
        XCTAssertEqual(find.current?.start, FileTextPosition(line: 120, column: 4))
        XCTAssertEqual(view.selectedRange.start, FileTextPosition(line: 120, column: 4))
        XCTAssertEqual(view.selectedRange.end, FileTextPosition(line: 120, column: 8))
        XCTAssertTrue(view.visibleLines.contains(120), "scrolled to")
        find.set(query: "needle", matchCase: false)
        try await eventually("typed on") { find.current?.columns == 4..<10 && !find.isFinding }
        XCTAssertEqual(find.current?.line, 120, "kept while it still matches")
        find.set(query: "needles", matchCase: false)
        try await eventually("moved on") { find.current?.line == 300 }
        try await eventually("counted") { !find.isCounting }
        XCTAssertEqual(find.count, 1)
        XCTAssertEqual(find.ordinal, 1)
        find.set(query: "nothing like it", matchCase: false)
        try await eventually("none") { !find.isCounting && !find.isFinding }
        XCTAssertNil(find.current)
        XCTAssertEqual(find.count, 0)
    }

    @MainActor func testNextAndPreviousGoOnInTheOrderAsked() async throws {
        let text = lines(3_000) { $0 % 100 == 7 ? "match \($0)" : "line \($0)" }
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforeFind = { await gate.wait() }
        let document = try await opened(try file(text), options)
        let scroll = shown(document)
        let find = FileFind(view: scroll.textView)
        find.set(query: "match", matchCase: true)
        // Asked for while the first find waits: each goes from the one before
        // (7, then 107, 207, back to 107, on to 207).
        find.next(); find.next(); find.previous(); find.next()
        await gate.open()
        try await eventually("all done") { !find.isFinding && find.current?.line == 207 }
        try await eventually("counted") { !find.isCounting }
        XCTAssertEqual(find.ordinal, 3)
        XCTAssertEqual(find.count, 30)
        // Back to the first, and around the start to the last.
        find.previous(); find.previous(); find.previous()
        try await eventually("around to the last") { !find.isFinding && find.current?.line == 2_907 }
        XCTAssertEqual(find.ordinal, 30)
    }

    @MainActor func testAReaderMovingTheSelectionDropsWhatWasAskedBefore() async throws {
        let text = lines(2_000) { $0 % 100 == 7 ? "match \($0)" : "line \($0)" }
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforeFind = { await gate.wait() }
        let document = try await opened(try file(text), options)
        let scroll = shown(document)
        let view = scroll.textView
        let find = FileFind(view: view)
        find.set(query: "match", matchCase: true)
        find.next(); find.next()
        // The reader clicks elsewhere before any of it is done.
        view.select(from: FileTextPosition(line: 1_500, column: 2), to: FileTextPosition(line: 1_500, column: 2))
        await gate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.selectedRange.start, FileTextPosition(line: 1_500, column: 2), "the reader's selection stays")
        XCTAssertNil(find.current)
        find.next()
        try await eventually("on from there") { find.current != nil && !find.isFinding }
        XCTAssertEqual(find.current?.line, 1_507)
    }

    @MainActor func testMatchesAreDrawnOnlyOnTheLinesDrawn() async throws {
        let text = lines(20_000) { "line \($0) with a word" }
        let document = try await opened(try file(text))
        let scroll = shown(document)
        let find = FileFind(view: scroll.textView)
        find.set(query: "word", matchCase: false)
        try await eventually("shown") { find.current != nil }
        draw(scroll)
        let visible = scroll.textView.visibleLines.count
        let matched = try XCTUnwrap(find.search?.wholeLines.count)
        XCTAssertGreaterThan(matched, 0)
        XCTAssertLessThanOrEqual(matched, visible * 3 + 2, "only lines on or around the screen are matched to be drawn")
        find.close()
        XCTAssertNil(scroll.textView.find)
        XCTAssertNil(find.search)
    }

    @MainActor func testAMatchAlongALongLineIsScrolledToSideways() async throws {
        let long = String(repeating: "x", count: 150_000) + "needle" + String(repeating: "x", count: 1_000)
        let document = try await opened(try file("first\n" + long + "\nlast"))
        let scroll = shown(document)
        let view = scroll.textView
        let find = FileFind(view: view)
        find.set(query: "needle", matchCase: false)
        try await eventually("shown") { find.current != nil }
        XCTAssertEqual(find.current?.start, FileTextPosition(line: 1, column: 150_000))
        let x = view.x(of: FileTextPosition(line: 1, column: 150_000))
        XCTAssertTrue(view.visibleRect.minX <= x && x <= view.visibleRect.maxX, "sideways into view")
    }

    /// Wide characters on a long line are drawn narrower, so further along
    /// than their columns: the matches behind them are drawn wherever they are.
    @MainActor func testMatchesBehindWideCharactersDrawnPastTheirColumns() async throws {
        let long = String(repeating: "漢", count: 100) + String(repeating: "x", count: 200_000)
        let document = try await opened(try file(long + "\nend"))
        let scroll = shown(document)
        let view = scroll.textView
        let find = FileFind(view: view)
        find.set(query: "漢", matchCase: false)
        try await eventually("shown") { find.current != nil }
        // Scrolled to where the columns start past the wide characters, which
        // are still on screen.
        let x = FileTextMetrics.left + 110 * view.metrics.advance
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually("drawn with the pieces there") {
            self.draw(scroll)
            return view.matchedColumns[0] != nil
        }
        XCTAssertLessThanOrEqual(view.matchedColumns[0]?.lowerBound ?? .max, 99, "the wide characters' columns are matched")
    }

    /// A line set whole with a match in every column: only the pieces drawn
    /// are set for its bands, and what is noted of a drawing is that drawing's.
    @MainActor func testBandsSetNoPieceOffScreen() async throws {
        let line = String(repeating: "e", count: 65_000)
        let document = try await opened(try file(line + "\n" + (0..<200).map { "e \($0)" }.joined(separator: "\n")))
        let scroll = shown(document)
        let view = scroll.textView
        let find = FileFind(view: view)
        find.set(query: "e", matchCase: false)
        try await eventually("shown") { find.current != nil }
        try await eventually("drawn") { self.draw(scroll); return view.matchedColumns[0] != nil }
        FileTextRenderCount.reset()
        view.needsDisplay = true
        draw(scroll)
        XCTAssertLessThan(FileTextRenderCount.pieces, 16, "no piece set off screen for a band")
        XCTAssertLessThan(view.matchedColumns[0]?.upperBound ?? .max, 4_096, "the columns drawn")
        // Scrolled down: what is noted is this drawing's lines.
        view.scrollTo(line: 150)
        draw(scroll)
        XCTAssertNil(view.matchedColumns[0])
        XCTAssertTrue(view.matchedColumns.keys.allSatisfy { view.visibleLines.contains($0) || abs($0 - 150) < 60 })
    }

    /// A selection too long to be a query is not read to find out.
    @MainActor func testALongSelectionIsNotReadForAQuery() async throws {
        let document = try await opened(try file(String(repeating: "abc ", count: 250_000) + "\nend"))
        let scroll = shown(document)
        let view = scroll.textView
        view.select(from: FileTextPosition(line: 0, column: 0), to: FileTextPosition(line: 0, column: 900_000))
        let asked = document.windowRequests
        XCTAssertNil(FileFind.query(fromSelectionIn: view))
        XCTAssertEqual(document.windowRequests, asked, "nothing read")
        view.select(from: FileTextPosition(line: 0, column: 500_000), to: FileTextPosition(line: 0, column: 500_003))
        var query: String?
        try await eventually("a short one read") {
            query = FileFind.query(fromSelectionIn: view)
            return query != nil
        }
        XCTAssertEqual(query, "abc")
        view.select(from: FileTextPosition(line: 0, column: 5), to: FileTextPosition(line: 1, column: 1))
        XCTAssertNil(FileFind.query(fromSelectionIn: view), "not across lines")
    }

    @MainActor func testAFileReadAgainIsSearchedAgain() async throws {
        var data = Data(lines(3_000) { "row \($0) needle" }.utf8)
        data.append(contentsOf: [0x0A, 0x66, 0xFF])
        let url = folder.appendingPathComponent("latin1.txt")
        try data.write(to: url)
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 16 << 10; options.firstPublishBytes = 16 << 10
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("first lines") { document.lineCount > 1 }
        let scroll = shown(document)
        let find = FileFind(view: scroll.textView)
        find.set(query: "needle", matchCase: false)
        let first = find.search
        await chunks.open()
        try await eventually("read again") { document.fellBack && document.status == .ready }
        try await eventually("searched again") { find.search !== first && find.search?.isCounting == false }
        XCTAssertEqual(find.count, 3_000)
        XCTAssertNotNil(find.current)
    }
}
