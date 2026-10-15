import AppKit
@testable import FileView
import XCTest
@testable import PiApp

final class FileHiddenReadTests: XCTestCase {
    @MainActor func testSuspendingSyntaxReleasesItsCompletedLexicalReader() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let document = try XCTUnwrap(fixture.tab.document), view = try XCTUnwrap(fixture.tab.scroll?.textView)
        let syntax = try XCTUnwrap(FileSyntax(source: document, view: view, extension: "swift"))
        for line in 0..<256 { _ = await syntax.reader.tokens(line: line, text: "let value = 1", language: .swift, load: { _ in nil }) }
        weak var old = syntax.reader
        XCTAssertNotNil(old)
        syntax.suspend()
        try await eventually("lexical reader released") { old == nil }
        XCTAssertTrue(syntax.colors(line: 0, piece: 0..<13, text: "").isEmpty)
        syntax.resume()
        let count = await syntax.reader.colourCount
        XCTAssertEqual(count, 0)
    }

    @MainActor func testHiddenOpenGateReadsNoBytesAndResumes() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let tab = fixture.tab, gate = FileReviewGate(), read = FileReviewFlag()
        tab.documentReadOptions.beforeOpen = { await gate.wait() }
        tab.documentReadOptions.didReadBytes = { _ in read.set(true) }
        let document = try XCTUnwrap(tab.document)
        await gate.entered()
        let work = document.indexingWork
        tab.didHide()
        await gate.open(); await work?.value
        XCTAssertFalse(document.isReading)
        XCTAssertFalse(read.value)
        tab.didShow()
        try await eventually("reopened") { document.status == .ready }
        XCTAssertTrue(read.value)
    }

    @MainActor func testSuspendedDetachedPreviewDoesNotBeginDecodeOrAdoptStaleResult() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let gate = FileReviewGate()
        let preview = FilePreview(url: fixture.root.appendingPathComponent("absent.png"))
        defer { preview.close() }
        preview.beforeDecode = { await gate.wait() }
        preview.load()
        let work = try XCTUnwrap(preview.readingTask)
        await gate.entered()
        preview.suspend()
        await gate.open(); await work.value
        XCTAssertEqual(preview.decodeStarts, 0)
        XCTAssertNil(preview.error, "cancelled failure must not publish")
        XCTAssertFalse(preview.loading)
        preview.resume()
        try await eventually("resumed decode reports missing file") { preview.error != nil }
        XCTAssertEqual(preview.decodeStarts, 1)
    }
    @MainActor func testHidingSuspendsDocumentAndFindAndShowingResumesWithoutMovingSelection() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let tab = fixture.tab, scroll = try XCTUnwrap(fixture.tab.scroll)
        fixture.window.contentView = scroll
        try await eventually("ready") { tab.status == .ready }
        tab.openFind(); tab.findQuery = "CONTENT"
        try await eventually("find") { scroll.textView.find?.current != nil }
        scroll.textView.select(from: .init(line: 121, column: 3), to: .init(line: 124, column: 8))
        let document = try XCTUnwrap(tab.document)
        tab.didHide()
        XCTAssertFalse(document.isReading, "hidden readers must not admit disk reads")
        XCTAssertNil(scroll.textView.find?.search, "hidden find counting must release its reader")
        tab.didShow()
        try await eventually("resumed") { document.isReading && scroll.textView.find?.count == 500 }
        XCTAssertEqual(scroll.textView.anchor, .init(line: 121, column: 3))
        XCTAssertEqual(scroll.textView.focus, .init(line: 124, column: 8))
    }

    @MainActor func testSuspendingPreviewReleasesDecodedPixelsAndReloads() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = fixture.root.appendingPathComponent("preview.png")
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        let tab = FileTab(url: url, projectID: nil)
        defer { tab.willClose() }
        tab.didShow(); tab.preview.load()
        try await eventually("decoded") { tab.preview.image != nil }
        tab.didHide()
        XCTAssertNil(tab.preview.image)
        tab.didShow()
        try await eventually("decoded on return") { tab.preview.image != nil }
    }
}

actor FileReviewGate {
    private var entry: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didEnter = false
    private var released = false
    func wait() async {
        didEnter = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async { if !didEnter { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
