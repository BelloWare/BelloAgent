import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class NativeCodeTextTests: XCTestCase {
    @MainActor func testStreamingFenceStartsNativeAndKeepsSelectionThroughGrowthAndCompletion() throws {
        var source = "let selected = 1\n"
        let host = NSHostingView(rootView: CodeBlockView(language: "swift", code: source, streaming: true).frame(width: 620).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func find(_ view: NSView) -> TranscriptCodeTextView? {
            if let code = view as? TranscriptCodeTextView { return code }
            return view.subviews.compactMap { find($0) }.first
        }
        host.layoutSubtreeIfNeeded()
        let code = try XCTUnwrap(find(host))
        XCTAssertTrue(window.makeFirstResponder(code))
        let selected = (source as NSString).range(of: "selected")
        code.setSelectedRange(selected)
        var samples: [Double] = []
        for index in 0..<160 {
            source += "// v\(index) " + String(repeating: "x", count: 110) + "\n"
            let start = ProcessInfo.processInfo.systemUptime
            host.rootView = CodeBlockView(language: "swift", code: source, streaming: index < 159).frame(width: 620).fixedSize(horizontal: false, vertical: true)
            host.layoutSubtreeIfNeeded(); _ = host.fittingSize
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertTrue(find(host) === code)
            XCTAssertEqual(code.selectedRange(), selected)
        }
        XCTAssertEqual(code.string, source)
        XCTAssertGreaterThan(source.utf8.count, NativeCodeText.minimumBytes)
        let sorted = samples.sorted()
        print("PERF growing live code samples=160 p50Ms=\(sorted[79]) p95Ms=\(sorted[151]) maxMs=\(sorted.last!)")
    }

    @MainActor func testNativeCodeAppendsWithoutReplacingSelectionOrChangingLiteralSource() throws {
        let view = TranscriptCodeTextView()
        let code = "let value = \"中文🙂\" // literal https://example.invalid\nprint(value)\n"
        view.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        let size = view.measure(width: 320)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))
        let selection = (code as NSString).range(of: "中文🙂")
        view.setSelectedRange(selection)
        let next = code + "print(\"next\")\n"
        view.update(source: next, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        XCTAssertEqual(view.string, next); XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === view); XCTAssertEqual(view.appendCount, 1)
        XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isEditable)
        XCTAssertNil(view.textStorage?.attribute(.link, at: (next as NSString).range(of: "https").location, effectiveRange: nil), "Literal code must not acquire clickable links")
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("code-selection-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        // Use the native Copy path's advertised types (AppKit exposes the
        // legacy string type here and bridges it when reading .string).
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "中文🙂")
        let narrow = view.measure(width: 120), wide = view.measure(width: 640)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(view.measure(width: 120), narrow)
        XCTAssertEqual(view.selectedRange(), selection)
        var dark = TranscriptRowEnvironment(); dark.colorScheme = .dark
        view.update(source: next, language: "swift", size: 13, environment: dark)
        XCTAssertEqual(view.string, next); XCTAssertEqual(view.selectedRange(), selection)
        view.update(source: "short", language: nil, size: 13, environment: dark)
        XCTAssertLessThanOrEqual(NSMaxRange(view.selectedRange()), view.string.utf16.count)
    }
    @MainActor func testByteExactReplacementAndWidthProbesPreserveTheDisplayedLayout() {
        let view = TranscriptCodeTextView()
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let first = "let café = 1\n" + String(repeating: "abc ", count: 30)
        view.update(source: first, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        let wide = view.measure(width: 320)
        let narrow = view.measure(width: 80)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(view.textContainer?.containerSize.width, 320)
        XCTAssertEqual(view.measure(width: 320), wide)
        XCTAssertEqual(view.textContainer?.containerSize.width, 320)
        // String.hasPrefix compares canonical characters; incremental edits
        // need a byte-identical prefix to avoid slicing a combining scalar.
        let replacement = first.replacingOccurrences(of: "é", with: "e\u{301}") + "\nnext"
        view.update(source: replacement, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        XCTAssertEqual(Array(view.string.utf8), Array(replacement.utf8))
        XCTAssertEqual(view.appendCount, 0)
    }
    @MainActor func testLargeLiteralCodeMeasuresWithoutTruncationAndKeepsTheLastLine() {
        let view = TranscriptCodeTextView()
        let code = (0..<2500).map { "let value\($0) = inspect(index: \($0))" }.joined(separator: "\n")
        let start = ProcessInfo.processInfo.systemUptime
        view.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        let size = view.measure(width: 590)
        print("REVIEW native code leaf \(code.utf8.count) bytes: update+sizing \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms, height \(size.height)")
        XCTAssertEqual(view.string, code)
        XCTAssertGreaterThan(size.height, 30_000)
        XCTAssertEqual(view.layoutManager?.numberOfGlyphs, view.string.utf16.count)
        let originalHeight = size.height
        view.update(source: code + "\nlast line 中文🙂", language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        XCTAssertGreaterThan(view.measure(width: 590).height, originalHeight)
        XCTAssertTrue(view.string.hasSuffix("last line 中文🙂"))
        XCTAssertEqual(view.appendCount, 1)
    }
    @MainActor func testLargeStreamingFenceUsesNativeTextWithTheSameCompleteHeight() {
        let prior = NativeCodeText.enabled
        defer { NativeCodeText.enabled = prior }
        let source = (0..<2500).map { "let value\($0) = inspect(index: \($0))" }.joined(separator: "\n")
        var heights: [CGFloat] = []
        for native in [false, true] {
            NativeCodeText.enabled = native
            // Completed giant fences now use bounded code sections. An active
            // fence is still continuous: compare both renderers in that mode.
            let host = NSHostingView(rootView: CodeBlockView(language: "swift", code: source, streaming: true).frame(width: 620).fixedSize(horizontal: false, vertical: true))
            let start = ProcessInfo.processInfo.systemUptime
            let size = host.fittingSize
            print("REVIEW large fence native=\(native): fitting \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms, height \(size.height)")
            XCTAssertGreaterThan(size.height, 30_000)
            heights.append(size.height)
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 1, "The optimized leaf must retain the full fence height")
    }

}
