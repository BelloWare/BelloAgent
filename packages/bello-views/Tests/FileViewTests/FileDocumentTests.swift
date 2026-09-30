import XCTest
import AppKit
@testable import FileView

/// The measures of the standard style, which every view here is drawn in.
@MainActor private var standardMetrics: FileTextMetrics { FileTextMetrics(FileTextStyle()) }

/// A file on disk as the viewer's text (`FileDocument`): where its lines are,
/// found away from the main thread and exactly as a text held whole finds
/// them, whatever its line endings, encoding and size, and wherever its
/// chunks fall; its text read only as asked for, never on the main thread;
/// and a file that changes under it said to have changed.
final class FileDocumentTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = scratchRoot("file-document")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    private func file(_ data: Data, _ name: String = UUID().uuidString) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    private func file(_ text: String) throws -> URL { try file(Data(text.utf8)) }

    /// Opens a file and waits for its whole pass.
    @MainActor private func opened(_ url: URL, _ options: FileDocument.Options = FileDocument.Options()) async throws -> FileDocument {
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the file was read to its end") { document.status != .indexing }
        return document
    }
    /// Waits for lines' text to come, and returns it.
    @MainActor private func text(_ document: FileDocument, line: Int, range: Range<Int>? = nil) async throws -> String {
        let range = range ?? 0..<document.utf16Length(ofLine: line)
        var found: String?
        try await eventually("line \(line) came") {
            found = document.text(ofLine: line, range: range)
            return found != nil
        }
        return found ?? ""
    }
    /// A document in the viewer's scroll view, in a window of its own.
    @MainActor private func shown(_ document: FileDocument, height: CGFloat = 300) -> FileTextScrollView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: height))
        window.contentView = scroll
        scroll.textView.pasteboard = NSPasteboard(name: NSPasteboard.Name("file-document-tests-" + UUID().uuidString))
        addTeardownBlock { @MainActor in scroll.textView.pasteboard.releaseGlobally(); window.contentView = nil; window.close() }
        scroll.textView.show(document, name: "document.txt")
        return scroll
    }
    /// Draws the text on screen now, as the next display would.
    @MainActor private func draw(_ scroll: FileTextScrollView) {
        let view = scroll.textView, rect = view.visibleRect
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) { view.cacheDisplay(in: rect, to: bitmap) }
    }

    /// Every place and every piece of text the document gives is the same
    /// as a text held whole gives, for every line ending, for characters of
    /// one to four bytes, and wherever the chunks read fall: one byte at a
    /// time, seven, a few thousand.
    @MainActor func testWhereLinesAreAndWhatTheySayIsWhatTheWholeTextSays() async throws {
        let texts = [
            "", "a", "a\n", "\n", "\n\n", "one\ntwo\nthree", "crlf\r\nline\r\n", "cr\ronly\rlines", "mixed\r\nendings\rhere\nand\r\r\n",
            "héllo wörld\n日本語のテキスト\nemoji 👋🏽 and 😀😀\ncombining e\u{301} and n\u{303}\n",
            String(repeating: "line of text with some length\n", count: 400) + "last",
        ]
        for text in texts {
            for chunk in [1, 7, 4_096] {
                var options = FileDocument.Options()
                options.chunkBytes = chunk; options.firstPublishBytes = 5; options.publishBytes = 40
                let document = try await opened(try file(text), options)
                let whole = FileTextLines(text)
                let label = "\(text.prefix(20).debugDescription), chunks of \(chunk)"
                XCTAssertEqual(document.status, .ready, label)
                XCTAssertEqual(document.lineCount, whole.lineCount, label)
                XCTAssertEqual(document.utf16Length, whole.utf16Length, label)
                XCTAssertEqual(document.longestLine, whole.longestLine, label)
                for line in 0..<whole.lineCount {
                    XCTAssertEqual(document.utf16Length(ofLine: line), whole.utf16Length(ofLine: line), "\(label), line \(line)")
                    XCTAssertEqual(document.utf16Start(ofLine: line), whole.utf16Start(ofLine: line), "\(label), line \(line)")
                }
                for offset in stride(from: 0, through: whole.utf16Length, by: max(1, whole.utf16Length / 300)) {
                    XCTAssertEqual(document.line(atUTF16: offset), whole.line(atUTF16: offset), "\(label), offset \(offset)")
                }
                for line in 0..<min(whole.lineCount, 12) {
                    let length = whole.utf16Length(ofLine: line)
                    let got = try await self.text(document, line: line)
                    XCTAssertEqual(got, whole.line(line), "\(label), line \(line)")
                    // Slices, through the middle of pairs and marks as well.
                    for low in stride(from: 0, to: length, by: 3) {
                        XCTAssertEqual(document.text(ofLine: line, range: low..<min(length, low + 5)), whole.text(ofLine: line, range: low..<min(length, low + 5)),
                                       "\(label), line \(line), from \(low)")
                    }
                }
            }
        }
    }

    /// A file's first lines are there before the rest of it has been read,
    /// and lines far into it read right once it has.
    @MainActor func testTheFirstLinesComeBeforeTheWholeFileIsRead() async throws {
        let lines = 200_000
        var data = Data()
        for index in 0..<lines { data.append(contentsOf: "line \(index) of the file, with some words after it\n".utf8) }
        let url = try file(data)
        let gate = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 1 << 20; options.firstPublishBytes = 64 << 10
        options.beforeChunk = { offset in if offset > 0 { await gate.wait() } }
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first lines came") { document.lineCount > 1 }
        XCTAssertEqual(document.status, .indexing, "the rest is still being read")
        XCTAssertLessThan(document.lineCount, 2_000, "the first read was the first lines' worth")
        let awaited1 = try await text(document, line: 0)
        XCTAssertEqual(awaited1, "line 0 of the file, with some words after it")
        await gate.open()
        try await eventually("the whole file was read") { document.status == .ready }
        XCTAssertEqual(document.lineCount, lines + 1, "every line, and the empty one after the last line ending")
        let awaited2 = try await text(document, line: 187_654)
        XCTAssertEqual(awaited2, "line 187654 of the file, with some words after it")
        XCTAssertLessThan(document.bytesRead, 2 << 20, "reading two places read two pages, not the file")
    }

    /// Nothing waits for the disk on the main thread, opening included: a
    /// document whose opening and first read are held back is shown and
    /// drawn at once, with nothing to draw, and its lines are drawn when
    /// they come.
    @MainActor func testOpeningAndTheFirstReadHoldNothingUp() async throws {
        let opening = Gate(), reading = Gate()
        var options = FileDocument.Options()
        options.beforeOpen = { await opening.wait() }
        options.beforeChunk = { _ in await reading.wait() }
        let url = try file((0..<300).map { "line \($0)" }.joined(separator: "\n"))
        // Were opening done here, this would wait for the gate forever.
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        XCTAssertNil(document.identity, "the file is opened away from the main thread")
        let scroll = shown(document)
        draw(scroll)
        await opening.open()
        try await eventually("the file was opened") { document.identity != nil }
        draw(scroll)
        XCTAssertEqual(document.status, .indexing)
        XCTAssertEqual(document.lineCount, 1, "nothing is known of its lines before the first read")
        FileTextRenderCount.reset()
        await reading.open()
        try await eventually("the lines came and were drawn") {
            draw(scroll)
            return FileTextRenderCount.pieces > 0
        }
        let first = try await text(document, line: 0)
        XCTAssertEqual(first, "line 0")
    }

    /// Bytes that stop being UTF-8 part way through: the file is read again
    /// as Latin-1, as a new reading, and says so. What was shown of its valid
    /// start (characters of more than one byte among it) goes.
    @MainActor func testBytesThatAreNotUTF8AreReadAsLatin1() async throws {
        var data = Data()
        for _ in 0..<2_000 { data.append(contentsOf: "héllo wörld\n".utf8) }
        data.append(contentsOf: [0x66, 0xFF, 0x0A])
        var options = FileDocument.Options()
        options.chunkBytes = 1_024; options.firstPublishBytes = 256
        let document = FileDocument(url: try file(data), options: options)
        addTeardownBlock { @MainActor in document.close() }
        var generations: Set<Int> = []
        document.arrival = { _ in generations.insert(document.generation) }
        try await eventually("read to its end") { document.status == .ready }
        XCTAssertEqual(document.encoding, .latin1)
        XCTAssertTrue(document.fellBack, "the document says it is showing Latin-1")
        XCTAssertTrue(generations.contains(0) && generations.contains(1), "the valid start was shown, then read again as a new text")
        let whole = FileTextLines(String(data: data, encoding: .isoLatin1)!)
        XCTAssertEqual(document.lineCount, whole.lineCount)
        let awaited3 = try await text(document, line: 0)
        XCTAssertEqual(awaited3, "hÃ©llo wÃ¶rld", "each byte one character")
        let awaited4 = try await text(document, line: 2_000)
        XCTAssertEqual(awaited4, "f\u{FF}")
    }

    /// A byte order mark says what a file is; zero bytes without one say it
    /// is not text.
    @MainActor func testByteOrderMarksAndBinaries() async throws {
        let text = "first\r\nsecond 👋🏽\nthird"
        let whole = FileTextLines(text)
        var utf8 = Data([0xEF, 0xBB, 0xBF]); utf8.append(contentsOf: text.utf8)
        var little = Data([0xFF, 0xFE]); little.append(text.data(using: .utf16LittleEndian)!)
        var big = Data([0xFE, 0xFF]); big.append(text.data(using: .utf16BigEndian)!)
        for (data, encoding) in [(utf8, FileEncoding.utf8), (little, .utf16LittleEndian), (big, .utf16BigEndian)] {
            var options = FileDocument.Options(); options.chunkBytes = 3
            let document = try await opened(try file(data), options)
            XCTAssertEqual(document.encoding, encoding)
            XCTAssertEqual(document.lineCount, whole.lineCount, "\(encoding)")
            XCTAssertEqual(document.utf16Length, whole.utf16Length, "\(encoding)")
            for line in 0..<whole.lineCount {
                let got = try await self.text(document, line: line)
                XCTAssertEqual(got, whole.line(line), "\(encoding) line \(line)")
            }
        }
        let binary = try await opened(try file(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])))
        XCTAssertEqual(binary.status, .binary)
        XCTAssertEqual(binary.lineCount, 1)
    }

    /// A UTF-16 file that ends one byte into a character: the byte is a
    /// replacement character, and the file is read, not said to have changed.
    @MainActor func testAUTF16FileEndingHalfWayThroughACharacterIsRead() async throws {
        let cases: [(Data, [String])] = [
            (Data([0xFF, 0xFE, 0x41]), ["\u{FFFD}"]),
            (Data([0xFE, 0xFF, 0x00]), ["\u{FFFD}"]),
            (Data([0xFF, 0xFE, 0x41, 0x00, 0x0A, 0x00, 0x42]), ["A", "\u{FFFD}"]),
        ]
        for (data, lines) in cases {
            for chunk in [1, 4_096] {
                var options = FileDocument.Options(); options.chunkBytes = chunk
                let document = try await opened(try file(data), options)
                XCTAssertEqual(document.status, .ready, "\(Array(data)), chunks of \(chunk)")
                XCTAssertEqual(document.lineCount, lines.count)
                for (index, line) in lines.enumerated() {
                    let got = try await text(document, line: index)
                    XCTAssertEqual(got, line, "\(Array(data)), line \(index)")
                }
            }
        }
    }

    /// A line of megabytes is read by the part asked for: its far end without
    /// what comes before it.
    @MainActor func testALongLineIsReadByThePartAskedFor() async throws {
        var line = ""
        line.reserveCapacity(5_100_000)
        for index in 0..<500_000 { line += index % 1_000 == 999 ? "é漢😀123" : "0123456789" }
        let url = try file(line + "\nafter")
        let document = try await opened(url)
        let whole = line as NSString
        XCTAssertEqual(document.utf16Length(ofLine: 0), whole.length)
        let before = document.bytesRead
        let far = whole.length - 5_000
        let got = try await text(document, line: 0, range: far..<(far + 1_024))
        XCTAssertEqual(got, whole.substring(with: NSRange(location: far, length: 1_024)), "the far end reads right")
        XCTAssertLessThan(document.bytesRead - before, 3 * Int(FileScanner.markBytes), "and reading it read a window or two, not the line")
        let awaited5 = try await text(document, line: 1)
        XCTAssertEqual(awaited5, "after")
    }

    /// A copy of a few characters far along a long line reads around them,
    /// not the line; a copy from there on to the next line reads from there;
    /// and a copy up to a long line's start reads none of it.
    @MainActor func testCopiesAtALongLineReadOnlyAroundTheirEnds() async throws {
        var line = ""
        line.reserveCapacity(4_100_000)
        for index in 0..<400_000 { line += index % 1_000 == 999 ? "é漢😀123" : "0123456789" }
        let document = try await opened(try file("short\n" + line + "\nafter"))
        let whole = line as NSString
        func copy(_ from: FileTextPosition, _ to: FileTextPosition) async throws -> String? {
            var copied: String??
            document.fetch(from: from, to: to) { copied = .some($0) }
            try await eventually("copied") { copied != nil }
            return copied ?? nil
        }
        let far = whole.length - 7_000
        var before = document.bytesRead
        let few = try await copy(FileTextPosition(line: 1, column: far), FileTextPosition(line: 1, column: far + 40))
        XCTAssertEqual(few, whole.substring(with: NSRange(location: far, length: 40)))
        XCTAssertLessThan(document.bytesRead - before, 5 * Int(FileScanner.markBytes), "a window or two around it, twice at most")
        before = document.bytesRead
        let on = try await copy(FileTextPosition(line: 1, column: far), FileTextPosition(line: 2, column: 3))
        XCTAssertEqual(on, whole.substring(from: far) + "\naft")
        XCTAssertLessThan(document.bytesRead - before, 5 * Int(FileScanner.markBytes) + 7_000 * 4, "from the mark before it on")
        before = document.bytesRead
        let upTo = try await copy(FileTextPosition(line: 0, column: 2), FileTextPosition(line: 1, column: 0))
        XCTAssertEqual(upTo, "ort\n")
        XCTAssertLessThan(document.bytesRead - before, 1_024, "nothing of the long line")
    }

    /// A line the view sets on its grid, a piece at a time, is read a part
    /// at a time too: drawing its start reads a window of it, not the line.
    @MainActor func testALineOnTheViewsGridIsReadByParts() async throws {
        XCTAssertLessThanOrEqual(FileScanner.longLineBytes, Int64(FileTextMetrics.gridLine))
        let length = FileTextMetrics.gridLine + 1_000
        let document = try await opened(try file(String(repeating: "x", count: length) + "\nafter"))
        let scroll = shown(document)
        try await eventually("drawn") {
            draw(scroll)
            return document.readsUnderWay == 0 && document.bytesRead > 0
        }
        XCTAssertEqual(scroll.textView.layout(0)?.grid, true)
        XCTAssertLessThan(document.bytesRead, length / 2, "a window of it, not the line")
    }

    /// Lines just short of long share pages only up to 256 KiB: reading one
    /// reads at most that and a line, not the run of such lines.
    @MainActor func testLinesJustShortOfLongKeepPagesSmall() async throws {
        let big = String(repeating: "x", count: Int(FileScanner.longLineBytes) - 10)
        let url = try file(Array(repeating: big, count: 12).joined(separator: "\n") + "\nshort")
        let document = try await opened(url)
        let before = document.bytesRead
        _ = try await text(document, line: 7)
        XCTAssertLessThanOrEqual(document.bytesRead - before, Int(FileScanner.checkpointBytes + FileScanner.longLineBytes), "a page of such lines, not the run")
    }

    /// A file changed or cut short while it is read is said to have changed,
    /// and nothing read of it afterwards is used.
    @MainActor func testAFileChangedWhileReadIsSaidToHaveChanged() async throws {
        for cut in [false, true] {
            var data = Data()
            for index in 0..<50_000 { data.append(contentsOf: "row \(index)\n".utf8) }
            let url = try file(data)
            var options = FileDocument.Options()
            options.chunkBytes = 64 << 10
            let path = url.path, size = data.count
            options.beforeChunk = { offset in
                guard offset > 0, offset < 70 << 10 else { return }
                // The same size, the line endings elsewhere; or the file cut short.
                if cut { truncate(path, off_t(size / 3)) }
                else if let handle = FileHandle(forWritingAtPath: path) {
                    try? handle.write(contentsOf: Data(repeating: 0x61, count: 64 << 10)); try? handle.close()
                }
            }
            let document = FileDocument(url: url, options: options)
            addTeardownBlock { @MainActor in document.close() }
            try await eventually(cut ? "the cut was seen" : "the change was seen") { document.status == .changed }
        }
    }

    /// Once a file is found to have changed, nothing more is read of it,
    /// however often its lines are asked for.
    @MainActor func testOnceAFileHasChangedNothingMoreIsRead() async throws {
        let reads = ReadCounter()
        var options = FileDocument.Options()
        options.beforePage = { await reads.add() }
        var data = Data()
        for index in 0..<20_000 { data.append(contentsOf: "row \(index)\n".utf8) }
        let url = try file(data)
        let document = try await opened(url, options)
        let first = try await text(document, line: 0)
        XCTAssertEqual(first, "row 0")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("more\n".utf8)); try handle.close()
        _ = document.text(ofLine: 10_000, range: 0..<3)
        try await eventually("the change was seen") { document.status == .changed }
        let seen = await reads.count
        for line in stride(from: 0, to: 20_000, by: 97) { _ = document.text(ofLine: line, range: 0..<3) }
        document.prefetch(lines: 5_000...9_000)
        try await Task.sleep(for: .milliseconds(200))
        let after = await reads.count
        XCTAssertEqual(after, seen, "nothing more was read")
        XCTAssertEqual(document.readsUnderWay, 0)
        XCTAssertEqual(document.text(ofLine: 0, range: 0..<5), "row 0", "what was read of it as it was still shows")
    }

    /// Closed while it is being read, a document stops: nothing more comes.
    @MainActor func testClosingStopsTheReading() async throws {
        var data = Data()
        for index in 0..<100_000 { data.append(contentsOf: "row \(index)\n".utf8) }
        let gate = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 64 << 10
        options.beforeChunk = { offset in if offset > 0 { await gate.wait() } }
        let document = FileDocument(url: try file(data), options: options)
        try await eventually("the first lines came") { document.lineCount > 1 }
        var arrivals = 0
        document.arrival = { _ in arrivals += 1 }
        document.close()
        await gate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(arrivals, 0, "nothing comes after closing")
        XCTAssertEqual(document.status, .indexing)
    }

    /// Past the lines it keeps, a document stops and says how many it
    /// shows, and its last kept line reads the run it is in, not the rest
    /// of the file.
    @MainActor func testMoreLinesThanAreKeptAreSaidSo() async throws {
        var options = FileDocument.Options()
        options.lineLimit = 1_000; options.chunkBytes = 4_096
        let document = try await opened(try file(String(repeating: "row\n", count: 50_000)), options)
        XCTAssertEqual(document.status, .truncated(limit: 1_000))
        XCTAssertEqual(document.lineCount, 1_000)
        XCTAssertEqual(document.utf16Length, 1_000 * 4 - 1)
        let awaited6 = try await text(document, line: 999)
        XCTAssertEqual(awaited6, "row")
        XCTAssertLessThan(document.bytesRead, 4 << 10, "a run of lines read, not the rest of the file")
    }

    /// A line read while the pass was still in it, cut in the middle of a
    /// character, is read again once the pass has found the rest: what was
    /// read of it before is not kept.
    @MainActor func testALineReadBeforeThePassHadFoundAllOfItIsReadAgain() async throws {
        let chunks = Gate(), pages = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 3; options.firstPublishBytes = 3
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        options.beforePage = { await pages.wait() }
        // The first read ends inside the 😀.
        let document = FileDocument(url: try file("a😀\nb"), options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first bytes were read") { document.utf16Length(ofLine: 0) == 3 }
        XCTAssertEqual(document.status, .indexing)
        XCTAssertNil(document.text(ofLine: 0, range: 0..<3), "asked for, and being read")
        await chunks.open()
        try await eventually("the pass finished") { document.status == .ready }
        await pages.open()
        let first = try await text(document, line: 0)
        XCTAssertEqual(first, "a😀", "the line as it is, not as it was when first read")
        let second = try await text(document, line: 1)
        XCTAssertEqual(second, "b")
    }

    /// Empty lines cost the cache too: a file of nothing but line endings,
    /// read ahead from end to end, keeps only as many pages as it holds.
    @MainActor func testEmptyLinesCountAgainstTheCache() async throws {
        var options = FileDocument.Options()
        options.cacheUnits = 20_000
        let document = try await opened(try file(String(repeating: "\n", count: 100_000)), options)
        for start in stride(from: 0, to: 100_000, by: 512) {
            document.prefetch(lines: start...(start + 511))
            try await eventually("read") { document.readsUnderWay == 0 }
        }
        XCTAssertGreaterThan(document.bytesRead, 50_000, "the file was read")
        XCTAssertLessThanOrEqual(document.cachedPages, 10, "and only what the cache holds is kept")
    }

    /// A screen of lines too long for the cache to hold many of is read
    /// once: each run of lines on screen once, nothing else, however often
    /// the screen is drawn.
    @MainActor func testAScreenOfLongLinesIsReadOnceHoweverOftenItIsDrawn() async throws {
        // Each line 60,005 bytes: five to a run of lines (256 KiB).
        let body = String(repeating: "x", count: 60_000)
        let text = (0..<300).map { String(format: "%03d ", $0) + body }.joined(separator: "\n")
        var options = FileDocument.Options()
        options.cacheUnits = 1 << 20
        let document = try await opened(try file(text), options)
        let scroll = shown(document)
        var reads: [Int] = []
        for _ in 0..<5 {
            draw(scroll)
            try await eventually("the reads came") { document.readsUnderWay == 0 }
            reads.append(document.bytesRead)
        }
        let runs = scroll.textView.visibleLines.upperBound / 5 + 1
        XCTAssertGreaterThan(runs * 5 * 60_000, options.cacheUnits, "more is on screen than the cache holds")
        XCTAssertEqual(Set(reads.dropFirst()).count, 1, "drawing again read nothing: \(reads)")
        XCTAssertEqual(document.pageLoads, document.pagesEverLoaded.count, "no run of lines was read twice")
        XCTAssertLessThanOrEqual(reads.last ?? 0, (runs + 1) * 5 * 60_005, "the runs on screen, and at most one read ahead: \(reads)")
    }

    /// With the screen keeping more than the budget, a request that needs
    /// two windows of a long line at once (a few characters across a cut)
    /// still gets both: the latest asked for are kept together.
    @MainActor func testARequestNeedingTwoWindowsGetsThemWhenTheScreenFillsTheCache() async throws {
        var options = FileDocument.Options()
        options.cacheUnits = 80_000
        let rows = (0..<10_000).map { "row \($0)" }.joined(separator: "\n")
        let document = try await opened(try file(rows + "\n" + String(repeating: "y", count: 100_000) + "\nend"), options)
        document.beginDrawing()
        document.prefetch(lines: 0...0)
        for run in 0..<30 { _ = document.text(ofLine: run * 128, range: 0..<3) }
        document.endDrawing()
        try await eventually("read") { document.readsUnderWay == 0 }
        XCTAssertGreaterThan(document.cachedCost, options.cacheUnits, "the screen keeps more than the budget")
        let cut = Int(FileScanner.markBytes)
        let across = try await text(document, line: 10_000, range: (cut - 10)..<(cut + 10))
        XCTAssertEqual(across, String(repeating: "y", count: 20))
    }

    /// A request bigger than half the budget, while the screen fills the
    /// cache, still gets all its parts at once: the latest request is kept
    /// whole, whatever it needs.
    @MainActor func testTheLatestRequestIsKeptWholeHoweverBig() async throws {
        var options = FileDocument.Options()
        options.cacheUnits = 80_000
        let rows = (0..<10_000).map { "row \($0)" }.joined(separator: "\n")
        let document = try await opened(try file(rows + "\n" + String(repeating: "y", count: 100_000) + "\nend"), options)
        document.beginDrawing()
        document.prefetch(lines: 0...0)
        for run in 0..<30 { _ = document.text(ofLine: run * 128, range: 0..<3) }
        document.endDrawing()
        try await eventually("read") { document.readsUnderWay == 0 }
        let most = try await text(document, line: 10_000, range: 0..<50_000)
        XCTAssertEqual(most.utf16.count, 50_000, "four windows, all at hand at once")
    }

    /// Accessibility asking for text not at hand is told nothing, the text is
    /// read in one go away from the screen's, accessibility is told it came,
    /// and asking again gets it.
    @MainActor func testAccessibilityGetsTextReadForItInOneGo() async throws {
        let document = try await opened(try file((0..<5_000).map { "row \($0)" }.joined(separator: "\n")))
        let scroll = shown(document)
        draw(scroll)
        // The screen's own lines come, and are announced, first.
        try await eventually("the screen read") { document.readsUnderWay == 0 }
        try await Task.sleep(for: .milliseconds(50))
        let text = scroll.textView
        var heard = 0
        text.announce = { if $0 == .valueChanged { heard += 1 } }
        let start = document.utf16Start(ofLine: 4_000)
        let range = NSRange(location: start, length: 20)
        XCTAssertNil(text.accessibilityString(for: range), "not at hand")
        try await eventually("told it came") { heard > 0 }
        XCTAssertEqual(text.accessibilityString(for: range), "row 4000\nrow 4001\nro")
        XCTAssertEqual(document.cachedPages, 1, "read in one go, not into the screen's cache")
    }

    /// Accessibility's reads belong to the text shown: a read for the text
    /// shown before is not answered for the one shown now, and asking for
    /// the same span again while it is read reads it once; a few at most at
    /// a time.
    @MainActor func testAccessibilityReadsBelongToTheTextShownAndAreNotRepeated() async throws {
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforePage = { await gate.wait() }
        let first = try await opened(try file((0..<5_000).map { "first \($0)" }.joined(separator: "\n")), options)
        let second = try await opened(try file((0..<5_000).map { "second \($0)" }.joined(separator: "\n")))
        let scroll = shown(first)
        let text = scroll.textView
        let far = NSRange(location: first.utf16Start(ofLine: 4_000), length: 10)
        XCTAssertNil(text.accessibilityString(for: far))
        XCTAssertNil(text.accessibilityString(for: far))
        XCTAssertEqual(first.fetchReads, 1, "the same span is read once while it is read")
        for extra in 1...8 { _ = text.accessibilityString(for: NSRange(location: far.location + extra, length: 10)) }
        XCTAssertEqual(first.fetchReads, FileTextView.answeringLimit, "a few at most at a time")
        text.show(second, name: "second.txt")
        await gate.open()
        try await eventually("the reads for the first text finished") { first.readsUnderWay == 0 }
        let asked = NSRange(location: second.utf16Start(ofLine: 4_000), length: 10)
        var answer: String?
        try await eventually("answered for the second text") {
            answer = text.accessibilityString(for: asked)
            return answer != nil
        }
        XCTAssertEqual(answer, "second 400", "never the first text's")
    }

    /// Scrolling sideways along a long line shows a new screen each time:
    /// what the screens left behind used is let go of, within the budget.
    @MainActor func testScrollingSidewaysAlongALongLineKeepsToTheBudget() async throws {
        var options = FileDocument.Options()
        options.cacheUnits = 100_000
        let document = try await opened(try file(String(repeating: "0123456789", count: 400_000)), options)
        let scroll = shown(document)
        let clip = scroll.contentView
        for step in 0..<40 {
            clip.scroll(to: NSPoint(x: CGFloat(step * 20_000) * standardMetrics.advance, y: 0))
            scroll.reflectScrolledClipView(clip)
            draw(scroll)
            try await eventually("read") { document.readsUnderWay == 0 }
        }
        XCTAssertGreaterThan(document.windowRequests, 30, "each screen read its own windows")
        XCTAssertLessThanOrEqual(document.cachedCost, options.cacheUnits + 3 * (Int(FileScanner.markBytes) + 64), "the budget, and at most the screen now shown")
    }

    /// Read ahead at one place after another while the disk is slow: what
    /// comes for the places left behind is not kept past the budget.
    @MainActor func testReadingAheadAtPlacesLeftBehindKeepsToTheBudget() async throws {
        let gate = Gate()
        var options = FileDocument.Options()
        options.cacheUnits = 50_000
        options.beforePage = { await gate.wait() }
        let document = try await opened(try file((0..<100_000).map { "row \($0)" }.joined(separator: "\n")), options)
        for place in stride(from: 0, to: 100_000, by: 10_000) { document.prefetch(lines: place...(place + 511)) }
        XCTAssertGreaterThan(document.readsUnderWay, 20, "each place asked for its runs")
        await gate.open()
        try await eventually("read") { document.readsUnderWay == 0 }
        XCTAssertGreaterThan(document.cachedPages, 0)
        XCTAssertLessThanOrEqual(document.cachedCost, options.cacheUnits, "the places left behind were let go of")
    }

    /// What a screen used is kept past the budget while it is shown, and let
    /// go of once another screen is shown; what is read for anything but the
    /// screen (a movement, accessibility) is kept only within the budget.
    @MainActor func testWhatAScreenUsesIsKeptWhileItIsShownAndNoLonger() async throws {
        var options = FileDocument.Options()
        options.cacheUnits = 20_000
        let document = try await opened(try file((0..<100_000).map { "row \($0)" }.joined(separator: "\n")), options)
        document.beginDrawing()
        document.prefetch(lines: 0...0)
        for run in 0..<10 { _ = document.text(ofLine: run * 128, range: 0..<3) }
        document.endDrawing()
        try await eventually("read") { document.readsUnderWay == 0 }
        let screen = document.cachedCost
        XCTAssertGreaterThan(screen, options.cacheUnits, "kept past the budget while the screen uses it")
        for place in stride(from: 20_000, to: 100_000, by: 8_000) {
            let asked = try await text(document, line: place, range: 0..<3)
            XCTAssertEqual(asked, "row", "what was asked for away from the screen came, and stayed to be read")
        }
        let before = document.pageLoads
        for run in 0..<10 { XCTAssertNotNil(document.text(ofLine: run * 128, range: 0..<3), "the screen's line \(run * 128) is still at hand") }
        XCTAssertEqual(document.pageLoads, before, "reading for accessibility pushed out none of the screen's lines")
        XCTAssertLessThanOrEqual(document.cachedCost, screen + options.cacheUnits / 2 + 3_500, "and of its own kept only the latest, up to half the budget")
        document.beginDrawing(); document.prefetch(lines: 50_000...50_010); document.endDrawing()
        try await eventually("read") { document.readsUnderWay == 0 }
        XCTAssertLessThanOrEqual(document.cachedCost, options.cacheUnits, "let go of once another screen is shown")
    }

    /// Copy builds nothing big on the main thread: a copy of millions of
    /// empty lines, or of most of a long line not read yet, reads nothing
    /// there and asks for nothing to be read for the screen; it is read and
    /// built away from it, and comes whole.
    @MainActor func testCopyingALotBuildsNothingOnTheMainThread() async throws {
        let empty = try await opened(try file(String(repeating: "\n", count: 2_000_000)))
        var copied: String?
        empty.fetch(from: .start, to: FileTextPosition(line: 2_000_000, column: 0)) { copied = $0 }
        XCTAssertNil(copied, "not built on the main thread")
        try await eventually("copied") { copied != nil }
        XCTAssertEqual(copied?.utf16.count, 2_000_000)
        let long = try await opened(try file(String(repeating: "0123456789", count: 200_000)))
        let asked = long.windowRequests
        var most: String?
        long.fetch(from: FileTextPosition(line: 0, column: 10), to: FileTextPosition(line: 0, column: 1_900_000)) { most = $0 }
        XCTAssertNil(most)
        XCTAssertEqual(long.windowRequests, asked, "nothing asked for to be read for the screen")
        try await eventually("copied") { most != nil }
        XCTAssertEqual(most?.utf16.count, 1_899_990)
        XCTAssertEqual(most?.prefix(12), "012345678901")
    }

    /// A copy of the line the pass is still in, read as far as the pass had
    /// gone and cut inside a character, gets the whole character, though
    /// what is drawn of it meanwhile has placeholders.
    @MainActor func testCopyingWhatThePassHasHalfReadGetsTheWholeCharacter() async throws {
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 3; options.firstPublishBytes = 3
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        let document = FileDocument(url: try file("a😀\nb"), options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first bytes were read") { document.utf16Length(ofLine: 0) == 3 }
        let shown = try await text(document, line: 0)
        XCTAssertEqual(shown, "a\u{FFFD}\u{FFFD}", "drawn with placeholders for the character cut short")
        var copied: String?
        document.fetch(from: .start, to: FileTextPosition(line: 0, column: 3)) { copied = $0 }
        try await eventually("copied") { copied != nil }
        XCTAssertEqual(copied, "a😀")
        await chunks.open()
    }

    /// A line longer than a length can be kept as stops the pass as too
    /// long, wherever its characters were counted: here in the run of plain
    /// characters counted eight at a time, at the file's very end.
    func testALineTooLongToKeepStopsThePass() {
        let bytes = Array("ééééé".utf8) + Array(repeating: UInt8(ascii: "x"), count: 16)
        var over = FileScanner(encoding: .utf8, start: 0, unitLimit: 20)
        bytes.withUnsafeBytes { over.feed($0) }
        over.finish()
        XCTAssertTrue(over.invalid && over.overflow, "21 units, where 20 can be kept")
        var within = FileScanner(encoding: .utf8, start: 0, unitLimit: 21)
        bytes.withUnsafeBytes { within.feed($0) }
        within.finish()
        XCTAssertFalse(within.invalid)
        XCTAssertEqual(within.take().lengths, [21])
    }

    /// A UTF-16 line of low surrogates on their own (each a replacement
    /// character) is read by the part asked for, as any long line is; and a
    /// line of pairs is never cut between the halves of one, even where a
    /// cut would fall there (the pairs start a unit into the line).
    @MainActor func testLongUTF16LinesAreCutOnlyBetweenCharacters() async throws {
        var data = Data([0xFF, 0xFE])
        for _ in 0..<200_000 { data.append(contentsOf: [0x00, 0xDC]) }
        data.append(contentsOf: [0x0A, 0x00, 0x61, 0x00, 0x0A, 0x00, 0x61, 0x00])
        for _ in 0..<100_000 { data.append(contentsOf: [0x3D, 0xD8, 0x00, 0xDE]) }
        let document = try await opened(try file(data))
        XCTAssertEqual(document.utf16Length(ofLine: 0), 200_000)
        let before = document.bytesRead
        let far = try await text(document, line: 0, range: 150_000..<150_100)
        XCTAssertEqual(far, String(repeating: "\u{FFFD}", count: 100))
        XCTAssertLessThan(document.bytesRead - before, 3 * Int(FileScanner.markBytes), "a window or two, not the line")
        let pairs = try await text(document, line: 2)
        XCTAssertEqual(pairs, "a" + String(repeating: "😀", count: 100_000), "every pair whole")
    }

    /// Where a long range of a long line is drawn, for VoiceOver, is found
    /// from its ends alone: nothing between them is read, and ends not
    /// read yet are where their columns are.
    @MainActor func testTheFrameOfALongRangeOfALongLineReadsOnlyItsEnds() async throws {
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforePage = { await gate.wait() }
        let document = try await opened(try file(String(repeating: "0123456789", count: 200_000) + "\nafter"), options)
        let scroll = shown(document)
        draw(scroll)
        let before = document.windowRequests
        let frame = scroll.textView.accessibilityFrame(for: NSRange(location: 100, length: 1_900_000))
        XCTAssertLessThanOrEqual(document.windowRequests - before, 4, "the windows at its ends, not the line's")
        XCTAssertEqual(frame.width, 1_900_000 * standardMetrics.advance, accuracy: standardMetrics.advance, "from its first column to its last")
        await gate.open()
    }

    /// A slow disk does not hold up the screen: the view draws at once, the
    /// lines not read yet empty, and draws them when they come. Copy of
    /// lines not read yet copies them once read.
    @MainActor func testASlowDiskLeavesTheViewDrawing() async throws {
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforePage = { await gate.wait() }
        let text = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let document = try await opened(try file(text), options)
        let scroll = shown(document)
        FileTextRenderCount.reset()
        let started = ProcessInfo.processInfo.systemUptime
        draw(scroll)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1, "drawing does not wait for the disk")
        XCTAssertEqual(FileTextRenderCount.pieces, 0, "nothing is set before its text has come")
        // Copy of lines far below, not read yet.
        scroll.textView.select(from: FileTextPosition(line: 480, column: 5), to: FileTextPosition(line: 481, column: 4))
        scroll.textView.copy(nil)
        await gate.open()
        try await eventually("the lines came and were drawn") {
            draw(scroll)
            return FileTextRenderCount.pieces > 0
        }
        try await eventually("the copy was made once read") { scroll.textView.pasteboard.string(forType: .string) == "480\nline" }
    }
}

/// A gate a background read waits at until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// How many times something happened, counted from any thread.
actor ReadCounter {
    private(set) var count = 0
    func add() { count += 1 }
}
