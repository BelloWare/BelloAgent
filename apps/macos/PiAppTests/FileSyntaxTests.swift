import AppKit
import XCTest
@testable import FileView
@testable import PiApp

// The shared-pass byte counts depend on concurrent requests reaching the
// reader together. Competing test hosts change that batching window.
final class FileSyntaxTests: XCTestCase, SerialTestLane {
    @MainActor func testPaintingBeforeOpenDoesNotCacheAnEmptyFirstLine() async throws {
        try await paintProvisionalLine(beforeOpen: true)
    }

    @MainActor func testPaintingAGrowingLineDoesNotCacheItsPartialTokens() async throws {
        try await paintProvisionalLine(beforeOpen: false)
    }

    @MainActor func testDelayedSyntaxGallery() async throws {
        guard let path = testEnvironment("PI_ROUND2_GITFILES_GALLERY") else { throw XCTSkip("Set PI_ROUND2_GITFILES_GALLERY to capture") }
        try await paintProvisionalLine(beforeOpen: true, gallery: URL(fileURLWithPath: path))
    }

    @MainActor private func paintProvisionalLine(beforeOpen: Bool, gallery: URL? = nil) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-opening-\(UUID().uuidString).swift")
        try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = SyntaxOpenGate()
        addTeardownBlock { await gate.release() }
        let tab = FileTab(url: url, projectID: nil)
        if beforeOpen {
            tab.documentReadOptions.beforeOpen = { await gate.wait() }
        } else {
            tab.documentReadOptions.chunkBytes = 4
            tab.documentReadOptions.firstPublishBytes = 4
            tab.documentReadOptions.beforeChunk = { if $0 == 4 { await gate.wait() } }
        }
        let content = tab.makeAppKitContent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content
        defer { tab.willClose(); window.contentView = nil; window.close() }
        tab.didShow()
        let document = try XCTUnwrap(tab.document), view = try XCTUnwrap(tab.scroll?.textView)
        try await waitForSyntax { document.utf16Length(ofLine: 0) == (beforeOpen ? 0 : 4) }
        XCTAssertFalse(document.isLineFinal(0))
        let syntax = try XCTUnwrap(view.syntax)
        var painted = false
        view.syntax = { line, piece, text in
            if line == 0 { painted = true }
            return syntax(line, piece, text)
        }
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        XCTAssertTrue(painted, "the mounted tab paints its provisional first line")
        // Give the tiny initial syntax task time to complete while I/O stays
        // held, so the regression covers a cached result, not just a race.
        try await Task.sleep(for: .milliseconds(150))
        await gate.release()
        try await waitForSyntax { document.status == .ready }
        try await waitForSyntax { syntax(0, 0..<13, "let value = 1").count == 2 }
        let runs = syntax(0, 0..<13, "let value = 1")
        XCTAssertEqual(runs.map(\.range), [NSRange(location: 0, length: 3), NSRange(location: 12, length: 1)])
        XCTAssertEqual(runs.map(\.color), [TranscriptNSPalette.keyword, TranscriptNSPalette.number])
        if let gallery {
            try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
            window.makeKeyAndOrderFront(nil)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for width in [800, 420] {
                    window.appearance = NSAppearance(named: appearance)
                    window.setContentSize(NSSize(width: width, height: 300))
                    content.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: gallery.appendingPathComponent("syntax-\(name)-\(width).png"))
                }
            }
        }
    }

    @MainActor func testScrollingUpKeepsTheNewViewportColouredWithoutRelexing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-lru-\(UUID().uuidString).swift")
        try String(repeating: "let value = 1\n", count: 1_400).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = FileView.FileDocument(url: url)
        defer { document.close() }
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 340))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let view = scroll.textView
        let syntax = try XCTUnwrap(FileSyntax(source: document, view: view, extension: "swift"))
        try await waitForSyntax { document.status == .ready }
        view.show(document, name: "fixture.swift")
        scroll.layoutSubtreeIfNeeded()
        func colour(_ line: Int) -> Bool {
            !syntax.colors(line: line, piece: 0..<13, text: "").isEmpty
        }
        for line in 1_000..<1_256 { try await waitForSyntax { colour(line) } }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: view.top(ofLine: 100)))
        let visible = view.visibleLines
        XCTAssertGreaterThan(visible.count, 2)
        XCTAssertGreaterThanOrEqual(visible.lowerBound, 100)
        for line in visible { try await waitForSyntax { colour(line) } }
        let before = await syntax.reader.colourCount
        let hits = visible.filter { colour($0) }.count
        print("FILE_SYNTAX upward cache hits=\(hits)/\(visible.count)")
        XCTAssertEqual(hits, visible.count, "every newly coloured visible line must survive the full cache")
        // A late offscreen completion also cannot evict the screen's ink.
        try await waitForSyntax { colour(1_300) }
        XCTAssertTrue(visible.allSatisfy { colour($0) })
        let after = await syntax.reader.colourCount
        XCTAssertEqual(after, before + 1, "only the late offscreen line was lexed, not the revisited viewport")
    }

    func testSyntaxDiagnosticsRetainNoLineIdentitiesInAnyConfiguration() async {
        let reader = FileSyntaxReader()
        for line in 0..<100_000 {
            _ = await reader.tokens(line: line, text: "let a = 1", language: .swift, load: { _ in nil })
        }
        let count = await reader.colourCount, retained = await reader.retainedDiagnosticLines
        print("FILE_SYNTAX diagnostic count=\(count) retained line IDs=\(retained)")
        XCTAssertEqual(count, 100_000)
        XCTAssertEqual(retained, 0, "Debug and Release both use a counter, with no visited-line identities")
    }

    @MainActor private func waitForSyntax(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(ready(), "syntax fixture did not finish")
    }

    func testResumingKeepsNestedCommentsAndMultilineStringsAcrossLines() {
        var state = SyntaxHighlighter.State()
        func read(_ line: String) -> [SyntaxHighlighter.TokenKind] {
            let scan = SyntaxHighlighter.resume(line + "\n", language: .swift, state: state)
            state = scan.state
            return scan.tokens.map(\.kind)
        }
        XCTAssertEqual(read("/* outside"), [.comment])
        XCTAssertEqual(read("/* nested */ still outside"), [.comment])
        XCTAssertEqual(read("*/ let count = 1"), [.comment, .keyword, .number])
        XCTAssertEqual(state.commentDepth, 0)
        XCTAssertEqual(read("let value = \"\"\""), [.keyword, .string])
        XCTAssertEqual(read("a string, not let or // a comment"), [.string])
        XCTAssertEqual(read("\"\"\"; return value"), [.string, .keyword])
        XCTAssertNil(state.delimiter)
        XCTAssertEqual(read("struct"), [.keyword])
        XCTAssertEqual(read("Widget {}"), [.title], "a declaration can name its type on the next line")
    }

    /// A load over lines in memory, as FileSyntax's reads the file: whole
    /// lines while they fit in `units`, a long line `units` at a time.
    final class Lines: @unchecked Sendable {
        let lines: [String], units: Int
        var loads: [(start: FileTextPosition, units: Int)] = []
        init(_ lines: [String], units: Int = 64) { self.lines = lines; self.units = units }
        var load: FileSyntaxReader.Load {
            { [self] start in
                var line = start.line, column = start.column, used = 0, parts: [String] = []
                while true {
                    let text = Array(lines[line].utf16)
                    if text.count - column > units - used, used == 0 {
                        let end = column + units
                        parts.append(String(decoding: text[column..<end], as: UTF16.self))
                        loads.append((start, units))
                        return .init(text: parts.joined(separator: "\n"), end: FileTextPosition(line: line, column: end), endsLine: false)
                    }
                    parts.append(String(decoding: text[column...], as: UTF16.self)); used += text.count - column + 1
                    if line + 1 >= lines.count || used + lines[line + 1].utf16.count > units {
                        loads.append((start, used))
                        return .init(text: parts.joined(separator: "\n"), end: FileTextPosition(line: line, column: text.count), endsLine: true)
                    }
                    line += 1; column = 0
                }
            }
        }
    }

    @MainActor func testDeepVisibleLinesUseBoundedCheckpointsWithoutColouringThePrefix() async {
        let reader = FileSyntaxReader()
        let lines = Lines((0..<300).map { index in index == 0 ? "/* comment" : index == 269 ? "*/" : "still a comment" })
        let ink = await reader.tokens(line: 270, text: "😀 let count = 1", language: .swift, load: lines.load)
        XCTAssertEqual(ink.first?.kind, .keyword)
        XCTAssertEqual(ink.first?.range, 3..<6, "colours address UTF-16 after a surrogate pair")
        XCTAssertTrue(lines.loads.allSatisfy { $0.units <= 64 })
        let coloured = await reader.colourCount
        XCTAssertEqual(coloured, 1, "prefix work produces states, not colours")
        let before = lines.loads.count
        _ = await reader.tokens(line: 271, text: "let next = 2", language: .swift, load: lines.load)
        XCTAssertEqual(lines.loads.count, before, "the line below starts where the coloured one ended")
        _ = await reader.tokens(line: 200, text: "still a comment", language: .swift, load: lines.load)
        XCTAssertTrue(lines.loads.dropFirst(before).allSatisfy { $0.start.line >= 128 }, "earlier checkpoints are reused")
    }

    /// Text cut into chunks anywhere — inside a delimiter, an escape, a word,
    /// a comment — leaves each line in the state lexing it whole does.
    func testChunkedStateMatchesWholeLinesWhereverTheCutsFall() {
        let pieces = ["/", "*", "\\", "\"", "'", "`", "$", "#", "a", "l", "s", " ", "\t", "1", "x_", "😀", "é", "//", "/*", "*/",
                      "\"\"\"", "'''", "$#", "class", "func", "def", "function", "let", String(repeating: "w", count: 40),
                      String(repeating: "q", count: 31) + "class", String(repeating: "/", count: 9), String(repeating: "\\", count: 7),
                      String(repeating: "\"", count: 5)]
        var random = SystemRandomNumberGenerator()
        for round in 0..<3_000 {
            let language = SyntaxHighlighter.Language.allCases[round % SyntaxHighlighter.Language.allCases.count]
            var whole = SyntaxHighlighter.State(), advance = SyntaxHighlighter.Advance(language: language, state: .init())
            for row in 0..<4 {
                let line = (0..<Int.random(in: 0...14, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
                whole = SyntaxHighlighter.resume(line + "\n", language: language, state: whole, collect: false).state
                var scalars = Array(line.unicodeScalars)[...]
                while !scalars.isEmpty, Bool.random(using: &random) {
                    let cut = Int.random(in: 0...scalars.count, using: &random)
                    advance.feed(String(String.UnicodeScalarView(scalars.prefix(cut))), endsLine: false); scalars = scalars.dropFirst(cut)
                }
                advance.feed(String(String.UnicodeScalarView(scalars)), endsLine: true)
                XCTAssertEqual(advance.state, whole, "round \(round), \(language), line \(row): \(line.debugDescription)")
                if advance.state != whole { return }
            }
        }
        // A scalar at a time through long hazard-only runs and a huge word.
        let runs: [(SyntaxHighlighter.Language, String)] = [
            (.javascript, "/*" + String(repeating: "*", count: 5_000) + "/ let"),
            (.python, "x = \"" + String(repeating: "\\\"", count: 3_000) + "\" def"),
            (.swift, String(repeating: "/", count: 4_000) + " class"),
            (.swift, String(repeating: "z", count: 10_000) + "func Name"),
        ]
        for (language, line) in runs {
            var advance = SyntaxHighlighter.Advance(language: language, state: .init())
            for scalar in line.unicodeScalars { advance.feed(String(scalar), endsLine: false) }
            advance.feed("", endsLine: true)
            XCTAssertEqual(advance.state, SyntaxHighlighter.resume(line + "\n", language: language, state: .init(), collect: false).state, line.prefix(8) + "…")
            XCTAssertLessThanOrEqual(advance.largestInput, SyntaxHighlighter.longestWord + 4, "only a few scalars are held")
        }
    }

    /// Lines asked for together, out of order, share one pass, and colour as
    /// one read of the whole text would.
    @MainActor func testLinesAskedTogetherShareOnePass() async {
        let text = (0..<400).map { $0 % 37 == 0 ? "/* open" : $0 % 37 == 5 ? "close */ let a = \"s" : "x = 1 // c" }
        let lines = Lines(text, units: 300), reader = FileSyntaxReader()
        let asked = [390, 12, 260, 3, 391, 130]
        let inks = await withTaskGroup(of: (Int, [FileSyntaxReader.Ink]).self) { group in
            for line in asked { group.addTask { (line, await reader.tokens(line: line, text: text[line], language: .javascript, load: lines.load)) } }
            var result: [Int: [FileSyntaxReader.Ink]] = [:]
            for await (line, ink) in group { result[line] = ink }
            return result
        }
        var state = SyntaxHighlighter.State()
        for (index, line) in text.enumerated() {
            if asked.contains(index) {
                let expected = SyntaxHighlighter.resume(line, language: .javascript, state: state).tokens.map(\.kind)
                XCTAssertEqual(inks[index]?.map(\.kind), expected, "line \(index)")
            }
            state = SyntaxHighlighter.resume(line + "\n", language: .javascript, state: state, collect: false).state
        }
        let read = lines.loads.reduce(0) { $0 + $1.units }, size = text.reduce(0) { $0 + $1.utf16.count + 1 }
        XCTAssertLessThanOrEqual(read, size + 300, "the text before the lines asked was read once")
    }

    /// A line in a later block waits for a pass that ends in an earlier one,
    /// then goes on from where it ended; it never waits for it again.
    @MainActor func testAPassEndingInAnEarlierBlockIsWaitedForOnce() async throws {
        let reader = FileSyntaxReader(), lines = Lines((0..<400).map { _ in "let a = 1" }, units: 40)
        final class Gate: @unchecked Sendable { var held: CheckedContinuation<Void, Never>?; var calls = 0 }
        let gate = Gate()
        let load: FileSyntaxReader.Load = { start in
            gate.calls += 1
            if gate.calls == 1 { await withCheckedContinuation { gate.held = $0 } }
            return await lines.load(start)
        }
        let near = Task { await reader.tokens(line: 130, text: "let a = 1", language: .swift, load: load) }
        while gate.held == nil { await Task.yield() }
        let far = Task { await reader.tokens(line: 300, text: "let a = 1", language: .swift, load: load) }
        for _ in 0..<50 { await Task.yield() }
        gate.held?.resume()
        // A pass waited for over and over would never end: stop the reader then.
        let watchdog = Task { try? await Task.sleep(for: .seconds(20)); reader.cancel() }
        _ = await near.value; _ = await far.value; watchdog.cancel()
        XCTAssertFalse(reader.stop.isStopped, "both lines were coloured before the watchdog")
        let read = lines.loads.reduce(0) { $0 + $1.units }
        XCTAssertLessThanOrEqual(read, 301 * 10 + 40, "the lines before 300 were read once")
    }

    /// Lines coloured in one block, then a line in a later one: it goes on
    /// from them, and the long first line is not read again.
    @MainActor func testALaterBlockGoesOnFromTheLinesColouredLast() async {
        let reader = FileSyntaxReader(), lines = Lines([String(repeating: "a b ", count: 2_000)] + (1..<300).map { _ in "let a = 1" }, units: 256)
        _ = await reader.tokens(line: 40, text: "let a = 1", language: .swift, load: lines.load)
        let before = lines.loads.count
        let ink = await reader.tokens(line: 150, text: "let a = 1", language: .swift, load: lines.load)
        XCTAssertEqual(ink.first?.kind, .keyword)
        XCTAssertTrue(lines.loads.dropFirst(before).allSatisfy { $0.start.line >= 41 }, "\(lines.loads.dropFirst(before).map(\.start))")
    }

    /// The last line while the file is still being read may grow: its
    /// colours do not decide where the next line starts.
    @MainActor func testALineStillGrowingGivesNoStateForTheNext() async {
        let reader = FileSyntaxReader(), lines = Lines((0..<10).map { $0 == 5 ? "let a = 1 /* opened later" : "let a = 1" })
        _ = await reader.tokens(line: 5, text: "let a = 1", final: false, language: .javascript, load: lines.load)
        let ink = await reader.tokens(line: 6, text: "let a = 1", language: .javascript, load: lines.load)
        XCTAssertEqual(ink.map(\.kind), [.comment], "line 6 is read on from the whole of line 5")
    }

    /// A reader stopped while a read is held reads no more and keeps nothing
    /// from it, and what is asked of it afterwards reads nothing.
    @MainActor func testAStoppedReaderReadsNoMore() async {
        let reader = FileSyntaxReader(), lines = Lines((0..<300).map { _ in "let a = 1" })
        final class Gate: @unchecked Sendable { var held: CheckedContinuation<Void, Never>?; var calls = 0 }
        let gate = Gate()
        let load: FileSyntaxReader.Load = { start in
            gate.calls += 1
            if gate.calls == 1 { await withCheckedContinuation { gate.held = $0 } }
            return await lines.load(start)
        }
        let first = Task { await reader.tokens(line: 250, text: "let a = 1", language: .swift, load: load) }
        while gate.held == nil { await Task.yield() }
        reader.cancel()
        gate.held?.resume()
        let ink = await first.value
        XCTAssertTrue(ink.isEmpty)
        XCTAssertEqual(gate.calls, 1, "no read after the stop")
        let chunks = await reader.chunkLoads
        XCTAssertEqual(chunks, 0, "the held read was dropped")
        let later = await reader.tokens(line: 10, text: "let a = 1", language: .swift, load: load)
        XCTAssertTrue(later.isEmpty); XCTAssertEqual(gate.calls, 1)
    }

    /// The review's file: a 64 MiB comment as the first line, then short
    /// lines. Colouring them reads the long line once, a chunk at a time, and
    /// no read or lex is bigger than a chunk. So too for an unclosed long
    /// comment, and for a long line inside the block before the line asked.
    @MainActor func testALongFirstLineIsReadOnceInBoundedChunks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ parts: [Data]) throws -> URL {
            let url = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            for part in parts { try handle.write(contentsOf: part) }
            try handle.close(); return url
        }
        let filler = Data(String(repeating: "lorem ipsum dolor sit amet, ", count: 2_341).utf8)
        func long(_ bytes: Int) -> [Data] { Array(repeating: filler, count: bytes / filler.count) }
        let tail = Data(String(repeating: "\nconst value = 1;", count: 40).utf8)
        let cases: [(name: String, parts: [Data], asked: [Int], comment: Bool)] = [
            ("closed.js", [Data("/* ".utf8)] + long(64 << 20) + [Data(" */".utf8), tail], Array(1...40), false),
            ("open.js", [Data("/* ".utf8)] + long(4 << 20) + [tail], [1, 40], true),
            ("block.js", [Data(String(repeating: "let a = 'x'\n", count: 130).utf8), Data("/* ".utf8)] + long(8 << 20)
                + [Data(" */".utf8), Data(String(repeating: "\nlet b = 2", count: 69).utf8)], [199, 160, 131], false),
        ]
        for test in cases {
            let url = try write(test.name, test.parts)
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            let document = FileView.FileDocument(url: url)
            defer { document.close() }
            let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            let syntax = try XCTUnwrap(FileSyntax(source: document, view: scroll.textView, extension: "js"))
            let clock = ContinuousClock(), deadline = clock.now + .seconds(180)
            while document.isIndexing, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let afterIndex = document.bytesRead
            var colours: [Int: [FileTextColorRun]] = [:]
            while colours.count < test.asked.count, clock.now < deadline {
                for line in test.asked where colours[line] == nil {
                    let runs = syntax.colors(line: line, piece: 0..<document.utf16Length(ofLine: line), text: "")
                    if !runs.isEmpty { colours[line] = runs }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(colours.count, test.asked.count, "\(test.name): every line asked was coloured")
            for line in test.asked {
                let actual = try XCTUnwrap(colours[line]?.first?.color)
                // SwiftUI's NSColor bridge creates a new dynamic provider.
                // Compare its resolved colours, rather than provider identity.
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    let appearance = try XCTUnwrap(NSAppearance(named: name))
                    appearance.performAsCurrentDrawingAppearance {
                        // Frozen e59e41a7 TranscriptMarkdown.swift palette,
                        // independent of the production dynamic provider.
                        let dark = name == .darkAqua
                        let hex = test.comment ? (dark ? 0x9a968d : 0x7a766d) : (dark ? 0xd7a5ee : 0x8a3fb0)
                        let expected = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                               green: CGFloat((hex >> 8) & 255) / 255,
                                               blue: CGFloat(hex & 255) / 255, alpha: 1)
                        guard let actual = actual.usingColorSpace(.sRGB),
                              let expected = expected.usingColorSpace(.sRGB) else {
                            XCTFail("\(test.name) line \(line): unresolved \(name.rawValue) colour")
                            return
                        }
                        for (value, reference) in zip(
                            [actual.redComponent, actual.greenComponent, actual.blueComponent, actual.alphaComponent],
                            [expected.redComponent, expected.greenComponent, expected.blueComponent, expected.alphaComponent]
                        ) {
                            XCTAssertEqual(value, reference, accuracy: 0.000001, "\(test.name) line \(line), \(name.rawValue)")
                        }
                    }
                }
            }
            XCTAssertLessThanOrEqual(document.largestFetchRead, 512 << 10, "\(test.name): no read bigger than a chunk and its page")
            XCTAssertLessThanOrEqual(document.bytesRead - afterIndex, size + (2 << 20), "\(test.name): the text before the lines was read once")
            let lexed = await syntax.reader.largestLexInput
            XCTAssertLessThanOrEqual(lexed, FileSyntax.chunkUnits + 64, "\(test.name): no lex bigger than a chunk")
        }
    }
}

private actor SyntaxOpenGate {
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
