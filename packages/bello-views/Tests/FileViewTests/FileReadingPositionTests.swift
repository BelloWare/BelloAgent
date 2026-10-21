import AppKit
import XCTest
@testable import FileView

final class FileReadingPositionTests: ViewsTestCase {
    @MainActor func testHorizontalTabsAndWideTextRestoreEvenAfterWideLineScrollsOffscreen() async throws {
        for text in [String(repeating: "\t", count: 100), String(repeating: "界", count: 200)] {
            let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            let lines = FileTextLines(text + String(repeating: "\nshort", count: 100))
            scroll.textView.show(lines, name: "wide")
            var syntaxRequests = 0
            scroll.textView.syntax = { _, _, _ in syntaxRequests += 1; return [] }
            let saved = FileReadingPosition(topLine: 50, horizontalColumns: 250, horizontalExtentLine: 0,
                anchor: .init(line: 55, column: 2), focus: .init(line: 56, column: 3))
            scroll.textView.restoreReadingPosition(saved)
            try await eventually("horizontal restoration") { scroll.contentView.bounds.minX > 0 }
            XCTAssertEqual(scroll.textView.readingPosition.horizontalColumns, 250, accuracy: 0.01)
            XCTAssertEqual(scroll.textView.readingPosition.horizontalExtentLine, 0)
            XCTAssertEqual(syntaxRequests, 0, "width-only restoration never starts offscreen lexical scans")
            let roundTrip = scroll.textView.readingPosition
            scroll.textView.show(lines, name: "wide")
            scroll.textView.restoreReadingPosition(roundTrip)
            try await eventually("horizontal round trip") { scroll.contentView.bounds.minX > 0 }
            XCTAssertEqual(scroll.textView.readingPosition.horizontalColumns, 250, accuracy: 0.01)
            scroll.textView.show(FileTextLines("short"), name: "short", preservingPosition: true)
            try await eventually("shortened horizontal clamp") { scroll.textView.readingPosition.horizontalColumns == 0 }
            XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
            XCTAssertEqual(scroll.textView.focus, .init(line: 0, column: 3))
        }
    }

    @MainActor func testChangedPartialIndexKeepsPendingPositionForTheReplacement() async throws {
        let root = scratchRoot("position-partial-replaced")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt"), text = String(repeating: "row with content\n", count: 400)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let gate = ReadingGate()
        var options = FileDocument.Options(); options.chunkBytes = 128; options.firstPublishBytes = 128
        options.beforeChunk = { offset in if offset > 0 { await gate.wait() } }
        let partial = FileDocument(url: url, options: options)
        defer { partial.close() }
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.textView.show(partial, name: "file")
        let saved = FileReadingPosition(topLine: 200, anchor: .init(line: 210, column: 2), focus: .init(line: 211, column: 3))
        scroll.textView.restoreReadingPosition(saved)
        await gate.entered()
        XCTAssertLessThan(partial.lineCount, 200)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await gate.open()
        try await eventually("old index changed") { partial.status == .changed }
        XCTAssertEqual(scroll.textView.readingPosition, saved)
        let replacement = FileDocument(url: url)
        defer { replacement.close() }
        scroll.textView.show(replacement, name: "file", preservingPosition: true)
        try await eventually("fresh index") { replacement.status == .ready }
        XCTAssertEqual(scroll.textView.focus, .init(line: 211, column: 3))
        XCTAssertEqual(scroll.textView.readingPosition.topLine, 200)
    }

    @MainActor func testLogicalStateRoundTripsAndClampsShorterText() throws {
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.textView.show(FileTextLines("one\ntwo"), name: "short")
        let saved = FileReadingPosition(topLine: Int.max, lineFraction: 0.5, horizontalColumns: 999,
            anchor: .init(line: 999, column: 999), focus: .init(line: -30, column: -1))
        let decoded = try JSONDecoder().decode(FileReadingPosition.self, from: JSONEncoder().encode(saved))
        scroll.textView.restoreReadingPosition(decoded)
        XCTAssertEqual(scroll.textView.anchor, .init(line: 1, column: 3))
        XCTAssertEqual(scroll.textView.focus, .start)
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
    }

    @MainActor func testExplicitTargetAndShowTopWinOverPendingRestoration() async throws {
        for showTop in [false, true] {
            let root = scratchRoot("position-target")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("file.txt")
            try String(repeating: "row\n", count: 400).write(to: url, atomically: true, encoding: .utf8)
            let gate = Gate()
            var options = FileDocument.Options(); options.beforeOpen = { await gate.wait() }
            let document = FileDocument(url: url, options: options)
            defer { document.close() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            window.contentView = scroll
            scroll.textView.show(document, name: "file")
            let saved = FileReadingPosition(topLine: 200, anchor: .init(line: 210, column: 2), focus: .init(line: 212, column: 2))
            scroll.textView.restoreReadingPosition(saved)
            XCTAssertEqual(scroll.textView.readingPosition, saved, "shutdown before index retains requested state")
            if showTop { scroll.textView.showTop() } else { scroll.textView.reveal(lines: 25...25) }
            await gate.open()
            try await eventually("ready") { document.status == .ready }
            XCTAssertEqual(scroll.textView.focus, .init(line: showTop ? 0 : 25, column: 0))
        }
    }

    @MainActor func testSuspendedFetchCompletesNilWithoutReadingAndResumeReadsBytes() async throws {
        let root = scratchRoot("position-suspend-fetch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try "original contents".write(to: url, atomically: true, encoding: .utf8)
        let gate = ReadingGate()
        let reads = ReadingBytes()
        var options = FileDocument.Options(); options.beforePage = { await gate.wait() }; options.didReadBytes = { reads.add($0) }
        let document = FileDocument(url: url, options: options)
        defer { document.close() }
        try await eventually("ready") { document.status == .ready }
        var completed = false, answer: String?
        document.fetch(from: .start, to: .init(line: 0, column: 17)) { answer = $0; completed = true }
        await gate.entered()
        let before = reads.count
        document.suspend()
        await gate.open()
        try await eventually("cancelled completion") { completed }
        XCTAssertNil(answer)
        XCTAssertEqual(document.bytesRead, 0)
        XCTAssertEqual(reads.count, before, "cancelled fetch does not read then merely drop its result")
        document.resume()
        completed = false
        document.fetch(from: .start, to: .init(line: 0, column: 17)) { answer = $0; completed = true }
        try await eventually("resumed completion") { completed }
        XCTAssertEqual(answer, "original contents")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original contents")
    }

    @MainActor func testSuspendedIndexDoesNotConsumeHeldChunkAndRestarts() async throws {
        let root = scratchRoot("position-suspend-index")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try String(repeating: "row\n", count: 400).write(to: url, atomically: true, encoding: .utf8)
        let gate = ReadingGate()
        let reads = ReadingBytes()
        var options = FileDocument.Options(); options.beforeChunk = { _ in await gate.wait() }; options.didReadBytes = { reads.add($0) }
        let document = FileDocument(url: url, options: options)
        defer { document.close() }
        await gate.entered()
        let pass = document.indexingWork, before = reads.count
        document.suspend()
        await gate.open()
        await pass?.value
        XCTAssertEqual(reads.count, before, "cancelled indexing stops before consuming the held chunk")
        XCTAssertEqual(document.lineCount, 1)
        XCTAssertFalse(document.isReading)
        document.resume()
        try await eventually("index resumes") { document.status == .ready }
        XCTAssertEqual(document.lineCount, 401)
    }
    @MainActor func testReplacementWaitsForIndexBeforeClampingSelection() async throws {
        let root = scratchRoot("reading-position")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (0..<500).map { "row \($0) with content" }.joined(separator: "\n")
        let url = root.appendingPathComponent("file.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.textView.show(FileTextLines(text), name: "file.txt")
        scroll.textView.select(from: .init(line: 126, column: 6), to: .init(line: 124, column: 2))
        let gate = Gate()
        var options = FileDocument.Options(); options.beforeOpen = { await gate.wait() }
        let document = FileDocument(url: url, options: options)
        defer { document.close() }
        scroll.textView.show(document, name: "file.txt", preservingPosition: true)
        await gate.open()
        try await eventually("index complete") { document.status == .ready }
        XCTAssertEqual(scroll.textView.anchor, .init(line: 126, column: 6))
        XCTAssertEqual(scroll.textView.focus, .init(line: 124, column: 2))
    }
}

private actor ReadingGate {
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var released = false
    func wait() async {
        didEnter = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { release = $0 } }
    }
    func entered() async { if !didEnter { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; release?.resume(); release = nil }
}

private final class ReadingBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add(_ bytes: Int) { lock.withLock { value += bytes } }
}
