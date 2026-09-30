import XCTest
import AppKit
@testable import FileView

/// Searching a file (`FileSearch`): the count is every match whole lines
/// give, however the file falls into pages and a long line into windows; going
/// to the next match or the one before meets them all in order and goes
/// around the ends; neither waits for the other; a search whose file is read
/// again, or changes, says so; lines held whole agree with a file on disk.
final class FileSearchTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = scratchRoot("file-search")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }
    private func file(_ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
    @MainActor private func opened(_ url: URL, _ options: FileDocument.Options = FileDocument.Options()) async throws -> FileDocument {
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the file was read to its end") { document.status != .indexing }
        return document
    }
    @MainActor private func counted(_ search: FileSearch) async throws {
        try await eventually("the count ended", timeout: .seconds(30)) { !search.isCounting }
    }

    /// Every match, as whole lines matched from their starts give them.
    @MainActor private func reference(_ text: String, _ matcher: FileMatcher) -> [(line: Int, columns: Range<Int>)] {
        let lines = FileTextLines(text)
        return (0..<lines.lineCount).flatMap { line in matcher.matches(in: lines.line(line) ?? "").map { (line, $0) } }
    }

    /// Lines of a mix of pieces that match and nearly match, with every line
    /// ending, and now and then a line long enough to be read by windows.
    private func mixedText(lines count: Int = 3_000, seed: UInt64 = 7) -> String {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["ab", "aba", "AB", "x", " ", "é", "É", "😀", "\u{212A}", "k", "aa", "a", "ba", "Ab"]
        let endings = ["\n", "\r\n", "\r"]
        var text = ""
        for line in 0..<count {
            let length = line % 500 == 250 ? 40_000 + next(20_000) : next(30)
            for _ in 0..<length { text += pieces[next(pieces.count)] }
            text += endings[next(endings.count)]
        }
        return text
    }

    @MainActor func testTheCountIsEveryMatchLineByLine() async throws {
        let text = mixedText()
        let document = try await opened(try file(Data(text.utf8)))
        XCTAssertEqual(document.status, .ready)
        for (query, matchCase) in [("ab", true), ("AB", false), ("aba", false), ("aa", true), ("é", false), ("😀", true), ("k", false), ("xa", false), ("zz", false)] {
            let matcher = FileMatcher(query: query, matchCase: matchCase)
            let search = document.search(matcher)
            try await counted(search)
            XCTAssertNil(search.stopped)
            XCTAssertEqual(search.count, reference(text, matcher).count, "\(query) \(matchCase)")
        }
    }

    /// Counted past the first pages asked for: every page, to the end.
    @MainActor func testTheCountGoesOnToTheEnd() async throws {
        let text = (0..<30_000).map { "line \($0) ab" }.joined(separator: "\n")
        let document = try await opened(try file(Data(text.utf8)))
        let search = document.search(FileMatcher(query: "ab", matchCase: true))
        try await counted(search)
        XCTAssertEqual(search.count, 30_000)
    }

    @MainActor func testGoingOnAndBackMeetsEveryMatchInOrderAndAroundTheEnds() async throws {
        let text = mixedText(lines: 1_200, seed: 11)
        let document = try await opened(try file(Data(text.utf8)))
        for query in ["aba", "k😀"] {
            let matcher = FileMatcher(query: query, matchCase: false)
            let expected = reference(text, matcher)
            XCTAssertGreaterThan(expected.count, 20, query)
            let search = document.search(matcher)
            try await counted(search)
            // On from the start: each in turn, then around to the first.
            var at = FileTextPosition.start
            for (index, match) in expected.prefix(400).enumerated() {
                let hit = await search.find(from: at, forward: true)
                XCTAssertEqual(hit?.line, match.line, "\(query) #\(index)")
                XCTAssertEqual(hit?.columns, match.columns, "\(query) #\(index)")
                XCTAssertEqual(hit.flatMap(search.ordinal), index + 1, "\(query) #\(index)")
                at = hit?.end ?? at
            }
            let last = expected[expected.count - 1]
            let around = await search.find(from: FileTextPosition(line: last.line, column: last.columns.upperBound), forward: true)
            XCTAssertEqual(around?.line, expected[0].line, "around the end to the first")
            XCTAssertEqual(around?.columns, expected[0].columns)
            // Back from the end: each in turn, then around to the last.
            at = FileTextPosition(line: document.lineCount - 1, column: document.utf16Length(ofLine: document.lineCount - 1))
            for (index, match) in expected.suffix(400).reversed().enumerated() {
                let hit = await search.find(from: at, forward: false)
                XCTAssertEqual(hit?.line, match.line, "\(query) back #\(index)")
                XCTAssertEqual(hit?.columns, match.columns, "\(query) back #\(index)")
                XCTAssertEqual(hit.flatMap(search.ordinal), expected.count - index, "\(query) back #\(index)")
                at = hit?.start ?? at
            }
            let first = expected[0]
            let back = await search.find(from: FileTextPosition(line: first.line, column: first.columns.lowerBound), forward: false)
            XCTAssertEqual(back?.line, last.line, "around the start to the last")
            XCTAssertEqual(back?.columns, last.columns)
        }
    }

    /// Matches that could overlap, along lines long enough to be read by
    /// windows: counted, gone to and drawn exactly as matching each line
    /// whole from its start has them, across every cut between windows.
    @MainActor func testMatchesAlongALongLineKeepToTheLineAcrossItsWindows() async throws {
        let runs = String(repeating: "a", count: 200_000)
        let pairs = String(repeating: "ab", count: 90_000) + "a"
        let wide = String(repeating: "😀", count: 50_000)
        let text = [runs, "short aaa line", pairs, wide, "end"].joined(separator: "\n")
        let document = try await opened(try file(Data(text.utf8)))
        for (query, line) in [("aaa", 0), ("Aa", 0), ("aba", 2), ("😀😀", 3), ("😀😀😀", 3)] {
            let matcher = FileMatcher(query: query, matchCase: false)
            let expected = reference(text, matcher)
            let inLine = expected.filter { $0.line == line }.map(\.columns)
            // Before the count: going to matches along the line, both ways,
            // works out where matching resumes along it (a third of the way,
            // half way and near the end: windows whose starts fall in and
            // out of step with the matches).
            for index in [inLine.count / 3, inLine.count / 2, inLine.count - 3] {
                let early = document.search(matcher)
                let near = inLine[index]
                let before = await early.find(from: FileTextPosition(line: line, column: near.lowerBound - 1), forward: true)
                XCTAssertEqual(before?.columns, near, "\(query): on, before the count, #\(index)")
                let back = await early.find(from: FileTextPosition(line: line, column: near.lowerBound), forward: false)
                XCTAssertEqual(back?.columns, inLine[index - 1], "\(query): back, before the count, #\(index)")
                early.cancel()
            }

            let search = document.search(matcher)
            try await counted(search)
            XCTAssertEqual(search.count, expected.count, query)
            // Drawn: the matches meeting a few columns, anywhere along the line.
            for from in [0, 16_380, 16_383, 32_766, 65_530, 99_999] where from < document.utf16Length(ofLine: line) {
                let columns = from..<(from + 10)
                var drawn: [Range<Int>]?
                try await eventually("\(query) drawn at \(from)") {
                    drawn = search.matches(inLine: line, columns: columns)
                    return drawn != nil
                }
                XCTAssertEqual(drawn, inLine.filter { $0.overlaps(columns) }, "\(query) drawn at \(from)")
            }
            // Gone to, both ways, across cuts.
            for index in [1, inLine.count / 2, inLine.count - 2] {
                let hit = await search.find(from: FileTextPosition(line: line, column: inLine[index - 1].upperBound), forward: true)
                XCTAssertEqual(hit?.columns, inLine[index], "\(query) on to #\(index)")
                XCTAssertEqual(hit.flatMap(search.ordinal), expected.firstIndex { $0.line == line && $0.columns == inLine[index] }.map { $0 + 1 })
                let back = await search.find(from: FileTextPosition(line: line, column: inLine[index].lowerBound), forward: false)
                XCTAssertEqual(back?.columns, inLine[index - 1], "\(query) back from #\(index)")
            }
        }
    }

    @MainActor func testGoingToAMatchDoesNotWaitForTheCount() async throws {
        let text = mixedText(lines: 2_000, seed: 3)
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforeCount = { page in if page > 0 { await gate.wait() } }
        let document = try await opened(try file(Data(text.utf8)), options)
        let matcher = FileMatcher(query: "xk", matchCase: false)
        let expected = reference(text, matcher)
        let search = document.search(matcher)
        let far = expected[expected.count - 2]
        let hit = await search.find(from: FileTextPosition(line: far.line, column: far.columns.lowerBound), forward: true)
        XCTAssertEqual(hit?.line, far.line)
        XCTAssertEqual(hit?.columns, far.columns)
        XCTAssertTrue(search.isCounting, "found while the count waits")
        XCTAssertNil(hit.flatMap(search.ordinal), "its place is not known yet")
        await gate.open()
        try await counted(search)
        XCTAssertEqual(hit.flatMap(search.ordinal), expected.count - 1)
    }

    @MainActor func testASearchOfAFileReadAgainAsLatin1SaysItIsOver() async throws {
        var data = Data(mixedText(lines: 2_000, seed: 5).utf8)
        data.append(contentsOf: [0x0A, 0x61, 0x62, 0xFF, 0x0A])
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 16 << 10; options.firstPublishBytes = 16 << 10
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        let document = FileDocument(url: try file(data), options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first lines came") { document.lineCount > 1 }
        let search = document.search(FileMatcher(query: "ab", matchCase: false))
        await chunks.open()
        try await eventually("read again") { document.fellBack && document.status == .ready }
        try await counted(search)
        XCTAssertTrue(search.isStale)
        let again = document.search(FileMatcher(query: "ab", matchCase: false))
        try await counted(again)
        XCTAssertFalse(again.isStale)
        XCTAssertGreaterThan(again.count, 0)
    }

    @MainActor func testASearchOfAFileThatChangesStopsAndSaysSo() async throws {
        let url = try file(Data(mixedText(lines: 2_000, seed: 9).utf8))
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforeCount = { page in if page > 2 { await gate.wait() } }
        let document = try await opened(url, options)
        let search = document.search(FileMatcher(query: "ab", matchCase: false))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("more\n".utf8)); try handle.close()
        await gate.open()
        try await counted(search)
        XCTAssertEqual(search.stopped, "Changed on disk")
    }

    /// A file that changes after the count is done: going to a match says so.
    @MainActor func testGoingToAMatchInAFileChangedSinceSaysSo() async throws {
        let url = try file(Data(mixedText(lines: 1_000, seed: 17).utf8))
        let document = try await opened(url)
        let search = document.search(FileMatcher(query: "ab", matchCase: false))
        try await counted(search)
        XCTAssertNil(search.stopped)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("more\n".utf8)); try handle.close()
        var changed = false
        search.onChange = { changed = true }
        let hit = await search.find(from: FileTextPosition(line: 500, column: 0), forward: true)
        XCTAssertNil(hit)
        XCTAssertEqual(search.stopped, "Changed on disk")
        XCTAssertTrue(changed, "told")
    }

    /// A search asked for before a file turns out not to be text hears so.
    @MainActor func testASearchOfAFileThatIsNotTextSaysSo() async throws {
        let gate = Gate()
        var options = FileDocument.Options()
        options.beforeOpen = { await gate.wait() }
        let document = FileDocument(url: try file(Data([0x00, 0x01, 0x02, 0x61, 0x62])), options: options)
        addTeardownBlock { @MainActor in document.close() }
        let search = document.search(FileMatcher(query: "ab", matchCase: false))
        await gate.open()
        try await counted(search)
        XCTAssertEqual(search.stopped, "Not text")
    }

    /// A long line still being read through: its matches are drawn from the
    /// text around the columns drawn alone, and for a query whose matches
    /// could overlap, not at all until the count has been along it.
    @MainActor func testDrawingALineStillBeingReadReadsOnlyAroundIt() async throws {
        let line = String(repeating: "ab ", count: 1_000_000)
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 256 << 10; options.firstPublishBytes = 256 << 10
        options.beforeChunk = { offset in if offset >= 1 << 20 { await chunks.wait() } }
        let document = FileDocument(url: try file(Data(line.utf8)), options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first of it found") { document.utf16Length(ofLine: 0) >= 256 << 10 }
        XCTAssertTrue(document.isIndexing)
        let search = document.search(FileMatcher(query: "b a", matchCase: false))
        let asked = document.windowRequests
        var drawn: [Range<Int>]?
        try await eventually("drawn around the columns") {
            drawn = search.matches(inLine: 0, columns: 200_000..<200_030)
            return drawn != nil
        }
        XCTAssertEqual(drawn, stride(from: 199_999, through: 200_029, by: 3).map { $0..<($0 + 3) })
        XCTAssertLessThanOrEqual(document.windowRequests - asked, 2, "the windows around the columns alone")
        let overlapping = document.search(FileMatcher(query: "abab", matchCase: false))
        let before = document.windowRequests
        XCTAssertNil(overlapping.matches(inLine: 0, columns: 200_000..<200_030), "not before the count has been along it")
        XCTAssertEqual(document.windowRequests, before, "nothing read for it")
        await chunks.open()
        overlapping.cancel(); search.cancel()
    }

    /// Matches kept for drawing keep to a budget, however many a line holds.
    @MainActor func testMatchesKeptForDrawingKeepToABudget() async throws {
        let lines = FileTextLines((0..<600).map { _ in String(repeating: "e", count: 1_000) }.joined(separator: "\n"))
        let search = lines.search(FileMatcher(query: "e", matchCase: false))
        for line in 0..<600 { XCTAssertEqual(search.matches(inLine: line, columns: 0..<10)?.count, 10) }
        XCTAssertLessThanOrEqual(search.wholeLinesKept, FileSearch.wholeLinesBudget)
        XCTAssertEqual(search.wholeLinesKept, search.wholeLines.values.reduce(0) { $0 + $1.matches.count + FileSearch.wholeLineCost })
        search.cancel()
    }

    /// The line the pass is still in is matched again as it grows, not kept
    /// as it was.
    @MainActor func testTheLineStillBeingReadIsMatchedAgainAsItGrows() async throws {
        let text = String(repeating: "ab\n", count: 20_000) + String(repeating: "ab ", count: 10_000)
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 64 << 10; options.firstPublishBytes = 64 << 10
        options.beforeChunk = { offset in if offset >= 64 << 10 { await chunks.wait() } }
        let document = FileDocument(url: try file(Data(text.utf8)), options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("into the last line") { document.lineCount == 20_001 && document.utf16Length(ofLine: 20_000) > 0 }
        let search = document.search(FileMatcher(query: "ab", matchCase: true))
        var early: [Range<Int>]?
        try await eventually("its matches so far") {
            early = search.matches(inLine: 20_000, columns: 0..<100_000)
            return early != nil
        }
        await chunks.open()
        try await eventually("read through") { document.status == .ready }
        var later: [Range<Int>]?
        try await eventually("its matches now") {
            later = search.matches(inLine: 20_000, columns: 0..<100_000)
            return later != nil && later!.count == 10_000
        }
        XCTAssertLessThan(early?.count ?? 0, 10_000)
        search.cancel()
    }

    /// Matches that could overlap along a long line held whole: none drawn
    /// until where matching resumes along it has been worked out, away from
    /// the main thread, its units as they are (an edge between the halves of
    /// a pair included); then drawn as matching it whole has them, reading
    /// only around what is drawn.
    @MainActor func testMatchesAlongALongLineHeldWholeAreWorkedOutAwayFromTheMainThread() async throws {
        for (line, query, places) in [(String(repeating: "a", count: 300_000), "aaa", [0, 16_383, 16_384, 20_000, 40_000, 70_000, 99_998, 250_001]),
                                      ("a" + String(repeating: "😀", count: 50_000), "😀😀😀", [0, 16_380, 16_386, 32_760, 49_150, 99_990]),
                                      // Folded letters outside the first plane, their halves apart at every edge.
                                      ("a" + String(repeating: "\u{10400}", count: 50_000), "\u{10428}\u{10428}\u{10428}", [0, 16_380, 16_386, 32_760, 49_150, 99_990])] {
            let lines = FileTextLines(line + "\nend")
            let matcher = FileMatcher(query: query, matchCase: false)
            var read = 0
            let search = FileSearch(matcher: matcher, reader: FileLinesSearchReader(lines: [line, "end"]),
                                    lineText: { line, range in read += range.count; return lines.text(ofLine: line, range: range) },
                                    lineLength: { lines.utf16Length(ofLine: $0) }, longPage: { _ in nil }, linesAtHand: true)
            var told = false
            search.onChange = { told = true }
            XCTAssertNil(search.matches(inLine: 0, columns: 100..<120), "\(query): not before it is worked out")
            try await eventually("\(query) worked out") { told && search.matches(inLine: 0, columns: 100..<120) != nil }
            let whole = matcher.matches(in: line)
            for from in places {
                let columns = from..<(from + 20)
                XCTAssertEqual(search.matches(inLine: 0, columns: columns), whole.filter { $0.overlaps(columns) }, "\(query) at \(from)")
            }
            read = 0
            _ = search.matches(inLine: 0, columns: 90_000..<90_100)
            XCTAssertLessThan(read, FileSearch.heldWindow + 200, "\(query): only around what is drawn")
            search.cancel()
        }
    }

    /// Lines kept with no match cost the budget too.
    @MainActor func testLinesKeptWithNoMatchCostTheBudget() async throws {
        let lines = FileTextLines((0..<50_000).map { "line \($0)" }.joined(separator: "\n"))
        let search = lines.search(FileMatcher(query: "zzz", matchCase: false))
        for line in 0..<50_000 { XCTAssertEqual(search.matches(inLine: line, columns: 0..<10), []) }
        XCTAssertLessThanOrEqual(search.wholeLines.count, FileSearch.wholeLinesBudget / FileSearch.wholeLineCost)
        search.cancel()
    }

    /// A read that fails while going to a match is said, as the count says it.
    @MainActor func testAReadFailingWhileGoingToAMatchIsSaid() async throws {
        final class Failing: FileSearchReader, @unchecked Sendable {
            let lines: FileLinesSearchReader
            var failing = false
            init(_ lines: [String]) { self.lines = FileLinesSearchReader(lines: lines) }
            func pages(from first: Int, limit: Int) async throws -> FileSearchPages { try await lines.pages(from: first, limit: limit) }
            func page(holding line: Int) async throws -> FileSearchPage { try await lines.page(holding: line) }
            func pageCount() async throws -> Int { try await lines.pageCount() }
            func text(of page: FileSearchPage) throws -> FileSearchText {
                if failing { throw POSIXError(.EIO) }
                return try lines.text(of: page)
            }
            func window(_ window: Int, of page: FileSearchPage) throws -> [UInt16] { [] }
        }
        let text = (0..<1_000).map { "line \($0) ab" }
        let reader = Failing(text)
        let search = FileSearch(matcher: FileMatcher(query: "ab", matchCase: true), reader: reader,
                                lineText: { _, _ in nil }, lineLength: { _ in 0 }, longPage: { _ in nil })
        try await counted(search)
        XCTAssertEqual(search.count, 1_000)
        reader.failing = true
        let hit = await search.find(from: FileTextPosition(line: 500, column: 0), forward: true)
        XCTAssertNil(hit)
        XCTAssertEqual(search.stopped, POSIXError(.EIO).localizedDescription)
    }

    @MainActor func testLinesHeldWholeAgreeWithTheFileOnDisk() async throws {
        let text = mixedText(lines: 900, seed: 13)
        let document = try await opened(try file(Data(text.utf8)))
        let lines = FileTextLines(text)
        for query in ["ab", "aa", "😀k"] {
            let matcher = FileMatcher(query: query, matchCase: false)
            let onDisk = document.search(matcher), held = lines.search(matcher)
            try await counted(onDisk); try await counted(held)
            XCTAssertEqual(onDisk.count, held.count, query)
            var at = FileTextPosition(line: 400, column: 0)
            for _ in 0..<30 {
                let a = await onDisk.find(from: at, forward: true), b = await held.find(from: at, forward: true)
                XCTAssertEqual(a?.start, b?.start, query)
                XCTAssertEqual(a.flatMap(onDisk.ordinal), b.flatMap(held.ordinal), query)
                at = a?.end ?? at
            }
        }
    }

    /// A search decodes pages quickly, and exactly as the view does: the
    /// same units, split into the same lines.
    @MainActor func testQuickDecodingIsTheViewsDecoding() {
        let texts = [mixedText(lines: 300, seed: 21), "a\r\nb\rc\n", "end\n", "", "\n\n", "no ending", "12345678\n12345678\r\n1234567\r"]
        for text in texts {
            let bytes = Array(text.utf8)
            for last in [true, false] {
                let wanted = FileTextLines(text).lineCount - (last ? 0 : 1)
                bytes.withUnsafeBytes { raw in
                    let quick = FileDocument.quickText(of: raw, latin1: false, last: last, lines: wanted)
                    let plain = FileDocument.plainText(of: raw, encoding: .utf8, last: last, lines: wanted)
                    XCTAssertEqual(quick?.units, plain.units)
                    XCTAssertEqual(quick?.starts, plain.starts)
                    let latin = FileDocument.quickText(of: raw, latin1: true, last: last, lines: wanted)
                    let latinPlain = FileDocument.plainText(of: raw, encoding: .latin1, last: last, lines: wanted)
                    XCTAssertEqual(latin?.units, latinPlain.units)
                    XCTAssertEqual(latin?.starts, latinPlain.starts)
                }
            }
        }
        // Not UTF-8: left to the view's own decoding.
        for bad: [UInt8] in [[0x61, 0xFF], [0xC0, 0x80], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x61, 0xE2, 0x82]] {
            bad.withUnsafeBytes { XCTAssertNil(FileDocument.quickText(of: $0, latin1: false, last: true, lines: 1), "\(bad)") }
        }
    }

    @MainActor func testNothingIsSearchedForAQueryThatMatchesNothing() async throws {
        let document = try await opened(try file(Data("one\ntwo\n".utf8)))
        for query in ["", "o\nt", String(repeating: "o", count: FileMatcher.characterLimit + 1)] {
            let search = document.search(FileMatcher(query: query, matchCase: false))
            XCTAssertFalse(search.isCounting)
            XCTAssertEqual(search.count, 0)
            let hit = await search.find(from: .start, forward: true)
            XCTAssertNil(hit)
        }
    }
}
