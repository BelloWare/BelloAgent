import XCTest
import SwiftUI
@testable import PiApp

final class NativeMarkdownViewportTests: XCTestCase {
    @MainActor private final class FixtureModel: ObservableObject {
        @Published var source: String
        @Published var width: CGFloat = 620
        init(source: String) { self.source = source }
    }
    private struct FixtureBody: View {
        @ObservedObject var model: FixtureModel
        var body: some View {
            MarkdownBodyView(source: model.source, copyTargets: TranscriptCopy.targets(in: model.source))
                .frame(width: model.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private static func section(_ index: Int) -> String {
        """
        ## Section \(index)

        Selectable paragraph \(index) has enough words to wrap when the pane is narrow. This text stays the same while other sections arrive and when the reader scrolls away and back.

        ```swift
        let result\(index) = inspect(index: \(index))
        print(result\(index))
        ```

        | Check | Status |
        | --- | --- |
        | Section \(index) | Complete |
        | Content | Selectable |
        """
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    @MainActor private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    @MainActor private func settle(_ hosted: NSHostingView<FixtureBody>, scroll: NSScrollView, window: NSWindow) async {
        // The fixture uses the production MarkdownBodyView and a real outer
        // NSScrollView. Adopt its exact fitting height as the document, then
        // allow the representable and viewport observer to finish their work.
        for _ in 0..<4 {
            hosted.setFrameSize(NSSize(width: scroll.contentSize.width, height: hosted.fittingSize.height))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await nextMainTurn()
        }
    }
    @MainActor private func scroll(to y: CGFloat, scroll: NSScrollView, hosted: NSView, window: NSWindow) async {
        scroll.transcriptReading.readerMoved()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        await nextMainTurn()
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    @MainActor private func fixture(largeCode: Bool = false) -> (FixtureModel, NSWindow, NSScrollView, NSHostingView<FixtureBody>) {
        var source = (0..<40).map(Self.section).joined(separator: "\n\n")
        if largeCode {
            source = source.replacingOccurrences(of: "print(result0)", with: "print(result0)\n" + String(repeating: "// retained literal code context\n", count: 600))
        }
        let model = FixtureModel(source: source)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        scroll.hasVerticalScroller = true
        let hosted = NSHostingView(rootView: FixtureBody(model: model))
        hosted.safeAreaRegions = []
        scroll.documentView = hosted
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        return (model, window, scroll, hosted)
    }

    @MainActor func testLargeMarkdownScrollKeepsExactHeightAndSelectedText() async throws {
        let (_, window, outer, hosted) = fixture()
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        XCTAssertEqual(body.retainedBlockCount, 160, "Every heading, paragraph, code fence, and table is in the text")
        XCTAssertEqual(descendants(MarkdownTextView.self, in: body).count, 1, "The whole answer is one text")
        let initialHeight = hosted.frame.height
        XCTAssertGreaterThan(initialHeight, 10 * outer.contentView.bounds.height)
        let text = body.textView
        XCTAssertTrue(window.makeFirstResponder(text))
        let selection = NSRange(location: (text.string as NSString).range(of: "Selectable paragraph 0 ").location, length: 10)
        text.setSelectedRange(selection)
        await nextMainTurn()
        let passes = body.layoutPasses

        await scroll(to: initialHeight - outer.contentView.bounds.height, scroll: outer, hosted: hosted, window: window)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertTrue(text.string.contains("let result39 = inspect(index: 39)"), "The end of the full answer renders without truncation or a Show More gate")
        XCTAssertEqual(hosted.frame.height, initialHeight, accuracy: 0.5)

        await scroll(to: 0, scroll: outer, hosted: hosted, window: window)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertEqual(body.layoutPasses, passes, "Scrolling lays nothing out again")
        XCTAssertEqual(outer.contentView.bounds.minY, 0, accuracy: 0.5)
        XCTAssertEqual(hosted.frame.height, initialHeight, accuracy: 0.5)

        if let path = testEnvironment("PI_APP_SCROLL_CAPTURE"), !path.isEmpty {
            await scroll(to: (initialHeight - outer.contentView.bounds.height) / 2, scroll: outer, hosted: hosted, window: window)
            let bitmap = try XCTUnwrap(outer.bitmapImageRepForCachingDisplay(in: outer.bounds))
            outer.cacheDisplay(in: outer.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output)
            print("SCROLL CAPTURE \(output.path)")
        }
    }

    @MainActor func testLargeMarkdownAppendAndWidthChangeRetainTheSelection() async throws {
        let (model, window, outer, hosted) = fixture()
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        let text = body.textView
        XCTAssertTrue(window.makeFirstResponder(text))
        let selected = NSRange(location: (text.string as NSString).range(of: "Selectable paragraph 0 ").location + 11, length: 9)
        text.setSelectedRange(selected)
        let originalHeight = hosted.frame.height, originalLength = body.textLength

        model.source += "\n\n" + Self.section(40)
        await settle(hosted, scroll: outer, window: window)
        XCTAssertTrue(descendants(NativeMarkdownContainer.self, in: hosted).first === body)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertEqual(body.retainedBlockCount, 164)
        XCTAssertGreaterThan(hosted.frame.height, originalHeight)
        XCTAssertGreaterThanOrEqual(body.lastReplacedLocation, originalLength - 1, "Appending four blocks sets only their text")

        let wideHeight = hosted.frame.height
        model.width = 340
        await settle(hosted, scroll: outer, window: window)
        XCTAssertGreaterThan(hosted.frame.height, wideHeight, "The exact height follows the real narrower text wrapping")
        XCTAssertTrue(window.firstResponder === text, "Reflow keeps the text and its selection")
        XCTAssertEqual(text.selectedRange(), selected)
    }
    @MainActor func testSelectedCodeSurvivesAppendScrollAndReflow() async throws {
        let (model, window, outer, hosted) = fixture(largeCode: true)
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        let text = body.textView
        XCTAssertTrue(window.makeFirstResponder(text))
        let selected = (text.string as NSString).range(of: "result0")
        text.setSelectedRange(selected)
        await scroll(to: hosted.frame.height - outer.contentView.bounds.height, scroll: outer, hosted: hosted, window: window)
        XCTAssertTrue(window.firstResponder === text)
        model.source = model.source.replacingOccurrences(of: "print(result0)", with: "print(result0)\nprint(\"appended 中文🙂\")")
        model.source += "\n\n" + Self.section(40)
        await settle(hosted, scroll: outer, window: window)
        XCTAssertTrue(text.string.contains("appended 中文🙂"))
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertTrue(window.firstResponder === text)
        model.width = 340
        await settle(hosted, scroll: outer, window: window)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(text.selectedRange(), selected)
        let board = NSPasteboard(name: .init("hosted-code-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        XCTAssertTrue(text.writeSelection(to: board, types: text.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "result0")
    }

    @MainActor func testProvisionalCorrectionsPreserveLogicalBlockAndLatestScrollWins() async throws {
        let (_, window, outer, hosted) = fixture()
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        outer.transcriptReading.readerMoved()
        outer.contentView.scroll(to: NSPoint(x: 0, y: hosted.frame.height * 0.45))
        hosted.layoutSubtreeIfNeeded()
        let anchor = try XCTUnwrap(outer.transcriptReading.readingAnchor ?? body.preparedLogicalAnchor)
        await settle(hosted, scroll: outer, window: window)
        XCTAssertEqual(body.displacement(of: anchor) ?? .infinity, 0, accuracy: 1)
        outer.transcriptReading.readerMoved()
        outer.contentView.scroll(to: NSPoint(x: 0, y: hosted.frame.height * 0.25))
        hosted.layoutSubtreeIfNeeded()
        // A second gesture occurs before the first correction's queued callback.
        outer.transcriptReading.readerMoved()
        outer.contentView.scroll(to: NSPoint(x: 0, y: hosted.frame.height * 0.8))
        hosted.layoutSubtreeIfNeeded()
        let revision = outer.transcriptReading.readerRevision
        let newer = try XCTUnwrap(outer.transcriptReading.readingAnchor ?? body.preparedLogicalAnchor)
        await settle(hosted, scroll: outer, window: window)
        XCTAssertEqual(outer.transcriptReading.readerRevision, revision)
        XCTAssertEqual(body.displacement(of: newer) ?? .infinity, 0, accuracy: 1)
    }

}
