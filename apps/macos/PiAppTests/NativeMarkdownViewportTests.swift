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

    @MainActor func testLargeMarkdownScrollKeepsExactHeightAndSelectedTextWithFewMountedBlocks() async throws {
        let (_, window, outer, hosted) = fixture()
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        XCTAssertEqual(body.retainedBlockCount, 160, "Every heading, paragraph, code fence, and table remains available")
        XCTAssertLessThan(body.mountedBlockCount, 30, "Native views are bounded by the viewport, not the whole answer")
        let initialHeight = hosted.frame.height
        XCTAssertGreaterThan(initialHeight, 10 * outer.contentView.bounds.height)
        let field = try XCTUnwrap(descendants(NSTextField.self, in: body).first { $0.stringValue.hasPrefix("Selectable paragraph 0 ") && $0.isSelectable })
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor())
        editor.selectedRange = NSRange(location: 0, length: 10)
        let selection = editor.selectedRange
        await nextMainTurn()
        let measured = body.blockMeasurementCount

        await scroll(to: initialHeight - outer.contentView.bounds.height, scroll: outer, hosted: hosted, window: window)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(field.currentEditor() === editor, "A selected native field stays attached even outside the viewport")
        XCTAssertEqual(editor.selectedRange, selection)
        XCTAssertTrue(descendants(NSTextField.self, in: body).contains { $0.stringValue.contains("let result39 = inspect(index: 39)") }, "The end of the full answer renders without truncation or a Show More gate")
        XCTAssertLessThan(body.mountedBlockCount, 30)
        XCTAssertEqual(hosted.frame.height, initialHeight, accuracy: 0.5)

        await scroll(to: 0, scroll: outer, hosted: hosted, window: window)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange, selection)
        XCTAssertEqual(body.blockMeasurementCount, measured, "Scrolling reuses exact block measurements")
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

    @MainActor func testLargeMarkdownAppendAndWidthChangeRetainTheSelectedNativeField() async throws {
        let (model, window, outer, hosted) = fixture()
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        let field = try XCTUnwrap(descendants(NSTextField.self, in: body).first { $0.stringValue.hasPrefix("Selectable paragraph 0 ") && $0.isSelectable })
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor())
        editor.selectedRange = NSRange(location: 11, length: 9)
        let selected = editor.selectedRange
        let originalHeight = hosted.frame.height
        let beforeAppendMeasurements = body.blockMeasurementCount

        model.source += "\n\n" + Self.section(40)
        await settle(hosted, scroll: outer, window: window)
        XCTAssertTrue(descendants(NativeMarkdownContainer.self, in: hosted).first === body)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, selected)
        XCTAssertEqual(body.retainedBlockCount, 164)
        XCTAssertGreaterThan(hosted.frame.height, originalHeight)
        XCTAssertLessThanOrEqual(body.blockMeasurementCount - beforeAppendMeasurements, 8, "Appending four blocks must not remeasure all settled paragraphs")

        let wideHeight = hosted.frame.height
        model.width = 340
        await settle(hosted, scroll: outer, window: window)
        XCTAssertGreaterThan(hosted.frame.height, wideHeight, "The exact height follows the real narrower text wrapping")
        XCTAssertTrue(field.currentEditor() === editor, "Reflow preserves the native field and its selection")
        XCTAssertEqual(editor.selectedRange, selected)
    }
    @MainActor func testSelectedCodeSurvivesAppendScrollAndReflowInsideItsHostedBlock() async throws {
        let (model, window, outer, hosted) = fixture(largeCode: true)
        defer { window.contentView = nil; window.close() }
        await settle(hosted, scroll: outer, window: window)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: hosted).first)
        let code = try XCTUnwrap(descendants(TranscriptCodeTextView.self, in: body).first { $0.string.hasPrefix("let result0 =") })
        XCTAssertTrue(window.makeFirstResponder(code))
        let selected = (code.string as NSString).range(of: "result0")
        code.setSelectedRange(selected)
        await scroll(to: hosted.frame.height - outer.contentView.bounds.height, scroll: outer, hosted: hosted, window: window)
        XCTAssertTrue(window.firstResponder === code)
        XCTAssertTrue(code.isDescendant(of: body), "Selection retains a code block outside the viewport")
        model.source = model.source.replacingOccurrences(of: "print(result0)", with: "print(result0)\nprint(\"appended 中文🙂\")")
        model.source += "\n\n" + Self.section(40)
        await settle(hosted, scroll: outer, window: window)
        XCTAssertTrue(code.string.contains("appended 中文🙂"))
        XCTAssertEqual(code.selectedRange(), selected)
        XCTAssertTrue(window.firstResponder === code)
        model.width = 340
        await settle(hosted, scroll: outer, window: window)
        XCTAssertTrue(window.firstResponder === code)
        XCTAssertEqual(code.selectedRange(), selected)
        let board = NSPasteboard(name: .init("hosted-code-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        XCTAssertTrue(code.writeSelection(to: board, types: code.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "result0")
    }

}
