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

    @MainActor func testHighlightingResumesAtSafeLexicalCheckpointAndPreservesUTF16Selection() throws {
        for (language, opening, ending) in [("swift", "/* open\ncomment", "\nclosed */\nlet result = 42\n"),
                                              ("python", "value = \"\"\"open\n中文🙂", "\nclosed\"\"\"\nprint(value)\n"),
                                              ("typescript", "const value = `open\n🙂", "\nclosed`;\nconst x = 3;\n")] {
            let prefix = String(repeating: language == "python" ? "# stable prefix\n" : "// stable prefix\n", count: 40)
            let first = prefix + opening
            let view = TranscriptCodeTextView()
            view.update(source: first, language: language, size: 13, environment: .init())
            view.setSelectedRange(NSRange(location: 5, length: 4))
            let original = try XCTUnwrap(view.textStorage).attributedSubstring(from: NSRange(location: 0, length: 100))
            let visits = view.highlightedScalarVisits
            let final = first + ending
            view.update(source: final, language: language, size: 13, environment: .init())
            let full = TranscriptCodeTextView()
            full.update(source: final, language: language, size: 13, environment: .init())
            XCTAssertEqual(view.textStorage, full.textStorage, "Incremental attributes equal canonical scan, \(language)")
            XCTAssertEqual(view.textStorage?.attributedSubstring(from: NSRange(location: 0, length: 100)), original)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 4))
            // Python uses # comments, but these punctuation-delimited prefix
            // lines still have neutral checkpoints.
            XCTAssertLessThan(view.highlightedScalarVisits - visits, 150)
            XCTAssertGreaterThan(view.lastAttributeRange.location, 100)
        }
    }

    /// A token appended to a coloured fence is coloured from the scanner's
    /// last checkpoint on. Nothing before that checkpoint is visited again —
    /// not to scan it, and not to work out where its characters sit — so an
    /// append costs the same under forty lines of code as under three hundred.
    /// Both fences stay under the colouring limit, so both are coloured.
    @MainActor func testAnAppendColoursFromTheCheckpointWhateverCameBefore() throws {
        let rounds = 40
        var medians: [Int: Double] = [:]
        for lines in [40, 320] {
            var code = (0..<lines).map { "let value\($0) = compute(\($0)) // 中文 line \($0)" }.joined(separator: "\n") + "\n"
            XCTAssertLessThan(code.utf8.count + rounds * 8, SyntaxHighlighter.limit, "both fences must stay coloured")
            let view = TranscriptCodeTextView()
            view.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
            var samples: [Double] = []
            for round in 0..<rounds {
                code += round % 5 == 4 ? "x\(round)\n" : "x\(round) "
                let start = ProcessInfo.processInfo.systemUptime
                view.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
                samples.append(ProcessInfo.processInfo.systemUptime - start)
            }
            XCTAssertEqual(view.appendCount, rounds)
            // What the appends coloured is what colouring the whole code gives.
            let full = TranscriptCodeTextView()
            full.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
            XCTAssertEqual(view.textStorage, full.textStorage, "\(lines) lines: incremental colours must equal a full scan")
            medians[lines] = samples.sorted()[rounds / 2]
            print(String(format: "PERF appending a token to a %d-line coloured fence (%d bytes): %.3f ms (median of %d)",
                         lines, code.utf8.count, medians[lines]! * 1000, rounds))
        }
        let short = try XCTUnwrap(medians[40]), long = try XCTUnwrap(medians[320])
        XCTAssertLessThan(long, short * 3 + 0.000_2,
                          String(format: "an append cost %.3f ms under 320 lines against %.3f ms under 40", long * 1000, short * 1000))
    }

    /// Most lines of code end in a word. The word a line ends on only matters
    /// to the next line when it is a declaration keyword ("func" then a name
    /// on the next line), so every other line end is where colouring can
    /// resume, and an append colours the line it extends, not every line since
    /// the last one that happened to end in punctuation.
    @MainActor func testALineEndingInAWordIsWhereColouringResumes() throws {
        var code = (0..<200).map { "let value\($0) = compute(\($0)) + offset" }.joined(separator: "\n") + "\n"
        XCTAssertLessThan(code.utf8.count + 400, SyntaxHighlighter.limit, "the fence stays coloured")
        let scan = SyntaxHighlighter.scan(code, language: .swift)
        XCTAssertGreaterThanOrEqual(scan.checkpoints.count, 200, "every line end outside a string, comment or pending declaration is a checkpoint")
        // A declaration keyword at a line's end still reaches the next line.
        let declaration = SyntaxHighlighter.scan("func\nname()\n", language: .swift)
        XCTAssertFalse(declaration.checkpoints.contains(5), "the line after a bare declaration keyword is not a place to resume")
        XCTAssertEqual(declaration.tokens.last, SyntaxHighlighter.Token(range: 5..<9, kind: .title))
        let view = TranscriptCodeTextView()
        view.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        var visits: [Int] = [], times: [Double] = []
        for round in 0..<40 {
            code += round % 5 == 4 ? "total\(round)\n" : "x\(round) "
            let before = view.highlightedScalarVisits
            let start = ProcessInfo.processInfo.systemUptime
            view.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
            times.append(ProcessInfo.processInfo.systemUptime - start)
            visits.append(view.highlightedScalarVisits - before)
        }
        let full = TranscriptCodeTextView()
        full.update(source: code, language: "swift", size: 12.5, environment: TranscriptRowEnvironment())
        XCTAssertEqual(view.textStorage, full.textStorage, "colouring from the checkpoints equals colouring the whole code")
        let worst = try XCTUnwrap(visits.max())
        print(String(format: "PERF colouring an append to a %d-character fence whose lines end in words: at most %d characters scanned, %.3f ms (median of 40)",
                     code.count, worst, times.sorted()[20] * 1000))
        XCTAssertLessThan(worst, 120, "an append coloured \(worst) of the fence's \(code.count) characters")
    }

    @MainActor func testCodeHighlightLimitDoesNotStripPrefixStyle() throws {
        let view = TranscriptCodeTextView()
        let prefix = "let meaning = 42\n" + String(repeating: "// stable line\n", count: 1000)
        view.update(source: prefix, language: "swift", size: 13, environment: .init())
        let color = try XCTUnwrap(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        view.update(source: prefix + String(repeating: "// new line\n", count: 1000), language: "swift", size: 13, environment: .init())
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, color)
    }


}
