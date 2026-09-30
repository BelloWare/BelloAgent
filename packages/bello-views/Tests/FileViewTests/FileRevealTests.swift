import XCTest
import AppKit
@testable import FileView

/// Lines a file is opened at (`FileTextView.reveal`): set apart and shown,
/// the insertion point at the first, once the text has them; the last line
/// if the text ends before them, whether it ended, was cut short or failed.
final class FileRevealTests: XCTestCase {
    @MainActor private func shown(_ source: FileTextSource) -> (NSWindow, FileTextScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = scroll
        scroll.textView.show(source, name: "reveal.txt")
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return (window, scroll)
    }

    @MainActor func testLinesTheTextHasAreShownAtOnce() {
        let (_, scroll) = shown(FileTextLines((0..<500).map { "line \($0)" }.joined(separator: "\n")))
        scroll.textView.reveal(lines: 200...202)
        XCTAssertEqual(scroll.textView.emphasized, 200...202)
        XCTAssertEqual(scroll.textView.focus, FileTextPosition(line: 200, column: 0))
        XCTAssertTrue(scroll.textView.visibleLines.contains(200), "scrolled to")
    }

    @MainActor func testLinesNotFoundYetAreShownWhenFoundAndPastTheEndAtTheLastLine() async throws {
        let folder = scratchRoot("file-reveal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reveal.txt")
        try Data((0..<50_000).map { "row \($0)" }.joined(separator: "\n").utf8).write(to: url)
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 64 << 10
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first lines came") { document.lineCount > 1 }
        let (_, scroll) = shown(document)
        scroll.textView.reveal(lines: 40_000...40_000)
        XCTAssertNil(scroll.textView.emphasized, "not found yet")
        await chunks.open()
        try await eventually("shown once found") { scroll.textView.emphasized == 40_000...40_000 }
        XCTAssertEqual(scroll.textView.focus, FileTextPosition(line: 40_000, column: 0))
        scroll.textView.reveal(lines: 90_000...90_005)
        XCTAssertEqual(scroll.textView.emphasized, 49_999...49_999, "past the end of a file read through: its last line")
    }

    /// Lines found in part are shown, their band growing until the rest are.
    @MainActor func testLinesFoundInPartAreSetApartAsTheRestAreFound() async throws {
        let folder = scratchRoot("file-reveal-part")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("part.txt")
        try Data((0..<20_000).map { "row \($0)" }.joined(separator: "\n").utf8).write(to: url)
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 16 << 10; options.firstPublishBytes = 16 << 10
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        try await eventually("the first lines came") { document.lineCount > 1 }
        let found = document.lineCount
        XCTAssertLessThan(found, 5_000)
        let (_, scroll) = shown(document)
        scroll.textView.reveal(lines: 100...5_000)
        XCTAssertEqual(scroll.textView.emphasized?.lowerBound, 100, "shown once the first is found")
        XCTAssertLessThan(scroll.textView.emphasized?.upperBound ?? 0, 5_000)
        XCTAssertEqual(scroll.textView.focus, FileTextPosition(line: 100, column: 0))
        await chunks.open()
        try await eventually("the whole band once the rest came") { scroll.textView.emphasized == 100...5_000 }
    }

    /// Lines shown before the file turned out not to be UTF-8, whether all
    /// of them had been found or only some, are shown again once found again
    /// in the Latin-1 reading.
    @MainActor func testLinesShownBeforeALatin1RereadAreShownAgain() async throws {
        try await revealAcrossALatin1Reread(500...500, "found in full")
        try await revealAcrossALatin1Reread(500...15_000, "found in part")
    }
    @MainActor private func revealAcrossALatin1Reread(_ target: ClosedRange<Int>, _ label: String) async throws {
        let folder = scratchRoot("file-reveal-latin1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("latin1.txt")
        var data = Data((0..<20_000).map { "row \($0)" }.joined(separator: "\n").utf8)
        data.append(contentsOf: [0x0A, 0x66, 0xFF])
        try data.write(to: url)
        let chunks = Gate()
        var options = FileDocument.Options()
        options.chunkBytes = 16 << 10; options.firstPublishBytes = 16 << 10
        options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
        let document = FileDocument(url: url, options: options)
        defer { document.close() }
        try await eventually("the first lines came (\(label))") { document.lineCount > 1 }
        XCTAssertLessThan(document.lineCount, 15_000, label)
        let (_, scroll) = shown(document)
        scroll.textView.reveal(lines: target)
        XCTAssertEqual(scroll.textView.focus, FileTextPosition(line: 500, column: 0), label)
        await chunks.open()
        try await eventually("read again as Latin-1, through (\(label))") { document.fellBack && document.status == .ready }
        try await eventually("shown again (\(label))") { scroll.textView.emphasized == target }
        XCTAssertEqual(scroll.textView.focus, FileTextPosition(line: 500, column: 0), "back at the lines, not left at the start (\(label))")
    }

    @MainActor func testLinesPastWhatIsKeptEndAtTheLastLineKept() async throws {
        let folder = scratchRoot("file-reveal-cut")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cut.txt")
        try Data(String(repeating: "row\n", count: 5_000).utf8).write(to: url)
        var options = FileDocument.Options()
        options.lineLimit = 1_000; options.chunkBytes = 4_096
        let document = FileDocument(url: url, options: options)
        addTeardownBlock { @MainActor in document.close() }
        let (_, scroll) = shown(document)
        scroll.textView.reveal(lines: 3_000...3_000)
        try await eventually("cut short") { document.status == .truncated(limit: 1_000) }
        try await eventually("shown at the last line kept") { scroll.textView.emphasized == 999...999 }
    }
}
