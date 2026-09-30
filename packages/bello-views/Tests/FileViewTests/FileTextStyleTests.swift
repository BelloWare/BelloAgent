import XCTest
import AppKit
@testable import FileView

/// How a file's text looks is the host's to say (`FileTextStyle`): its font
/// sets where every character sits, its line height where every line does,
/// its line numbers' font how wide the gutter is, and its colours what the
/// text is drawn in. The engine knows no app.
final class FileTextStyleTests: XCTestCase {
    @MainActor func testTheHostsFontAndLineHeightPlaceTheText() throws {
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let text = scroll.textView
        text.show(FileTextLines(String(repeating: "0123456789\n", count: 2_000)), name: "styled.txt")
        let standard = FileTextMetrics(FileTextStyle())
        XCTAssertEqual(text.point(of: FileTextPosition(line: 1, column: 3)).x, FileTextMetrics.left + 3 * standard.advance, accuracy: 0.01)
        XCTAssertEqual(text.point(of: FileTextPosition(line: 1, column: 3)).y, FileTextMetrics.top + standard.lineHeight)
        let gutter = scroll.numbers.ruleThickness

        let large = FileTextStyle(font: .monospacedSystemFont(ofSize: 18, weight: .regular), lineNumberFont: .monospacedDigitSystemFont(ofSize: 16, weight: .regular),
                                  lineHeight: 26, text: .systemRed)
        text.style = large
        let metrics = FileTextMetrics(large)
        XCTAssertGreaterThan(metrics.advance, standard.advance)
        XCTAssertEqual(text.point(of: FileTextPosition(line: 1, column: 3)).x, FileTextMetrics.left + 3 * metrics.advance, accuracy: 0.01, "columns are the font's")
        XCTAssertEqual(text.point(of: FileTextPosition(line: 1, column: 3)).y, FileTextMetrics.top + 26, "lines are the style's height")
        XCTAssertEqual(text.frame.height, FileTextMetrics.top + 26 * CGFloat(text.source.lineCount) + FileTextMetrics.bottom, accuracy: 1, "and the text as tall as its lines")
        XCTAssertGreaterThan(scroll.numbers.ruleThickness, gutter, "the gutter fits the larger numbers")
        XCTAssertEqual(text.style.text, .systemRed)
        XCTAssertEqual(FileTextStyle.standard.lineHeight, 17, "the host's style is the view's own, not the default")
    }
    /// Up and Down keep their column across a change of font: the column,
    /// not the points it was at in the old font.
    @MainActor func testUpAndDownKeepTheirColumnAcrossAChangeOfFont() {
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let text = scroll.textView
        text.show(FileTextLines(String(repeating: "0123456789abcdef\n", count: 20)), name: "goal.txt")
        text.select(from: FileTextPosition(line: 0, column: 10), to: FileTextPosition(line: 0, column: 10))
        text.moveDown(nil)
        XCTAssertEqual(text.focus, FileTextPosition(line: 1, column: 10))
        text.style = FileTextStyle(font: .monospacedSystemFont(ofSize: 22, weight: .regular), lineHeight: 30)
        text.moveDown(nil)
        XCTAssertEqual(text.focus, FileTextPosition(line: 2, column: 10))
    }

    /// A change of font shows other columns of the same lines: a new screen,
    /// read ahead for again, though the lines are the same.
    @MainActor func testAChangeOfFontIsANewScreen() {
        final class Counting: FileTextSource {
            let whole = FileTextLines(String(repeating: "0123456789", count: 20_000))
            var screens = 0
            var lineCount: Int { whole.lineCount }
            var utf16Length: Int { whole.utf16Length }
            var longestLine: Int { whole.longestLine }
            let generation = 0
            var arrival: ((ClosedRange<Int>) -> Void)?
            func utf16Length(ofLine index: Int) -> Int { whole.utf16Length(ofLine: index) }
            func text(ofLine index: Int, range: Range<Int>) -> String? { whole.text(ofLine: index, range: range) }
            func utf16Start(ofLine index: Int) -> Int { whole.utf16Start(ofLine: index) }
            func line(atUTF16 offset: Int) -> Int { whole.line(atUTF16: offset) }
            func showScreen(lines: ClosedRange<Int>, columns: Range<Int>) { screens += 1 }
            func fetch(from start: FileTextPosition, to end: FileTextPosition, completion: @escaping @MainActor (String?) -> Void) { completion(text(from: start, to: end)) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = scroll
        let source = Counting()
        scroll.textView.show(source, name: "wide.txt")
        func draw() {
            let view = scroll.textView, rect = view.visibleRect
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) { view.cacheDisplay(in: rect, to: bitmap) }
        }
        scroll.contentView.scroll(to: NSPoint(x: 50_000, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        draw(); draw()
        XCTAssertEqual(source.screens, 1, "one screen, told once")
        scroll.textView.style = FileTextStyle(font: .monospacedSystemFont(ofSize: 16, weight: .regular), lineHeight: 22)
        draw()
        XCTAssertEqual(source.screens, 2, "the same lines in another font are another screen")
    }
}
