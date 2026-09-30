import XCTest
import AppKit
import ApplicationServices
@testable import PiApp
@testable import FileView

/// The measures of the standard style, which every view here is drawn in.
@MainActor private var standardMetrics: FileTextMetrics { FileTextMetrics(FileTextStyle()) }

/// The file viewer's text (`FileTextView`): lines set only as they come into
/// view, whatever the file's size; selection by mouse and keyboard as in any
/// Mac text view; copy; and the text VoiceOver reads, asked for through the
/// accessibility interface VoiceOver itself uses.
final class FileTextViewTests: XCTestCase {

    // MARK: Sources

    /// Millions of lines, made as they are read, every one the same length so
    /// where each starts is arithmetic: a file too big to hold, and a count of
    /// how much of it was read.
    @MainActor final class GeneratedLines: FileTextSource {
        static let width = 60
        let lineCount: Int
        let generation = 0
        private(set) var read = 0
        init(_ count: Int) { lineCount = count }
        static func line(_ index: Int) -> String {
            let number = String(index)
            let text = "Line " + String(repeating: "0", count: max(0, 8 - number.count)) + number + " · the quick brown fox jumps over"
            return text.padding(toLength: width, withPad: ".", startingAt: 0)
        }
        var arrival: ((ClosedRange<Int>) -> Void)?
        func fetch(from start: FileTextPosition, to end: FileTextPosition, completion: @escaping @MainActor (String?) -> Void) { completion(text(from: start, to: end)) }
        func utf16Length(ofLine index: Int) -> Int { Self.width }
        func text(ofLine index: Int, range: Range<Int>) -> String? {
            let line = Self.line(index) as NSString
            let low = max(0, min(range.lowerBound, line.length)), high = max(low, min(range.upperBound, line.length))
            read += high - low
            return line.substring(with: NSRange(location: low, length: high - low))
        }
        func utf16Start(ofLine index: Int) -> Int { index * (Self.width + 1) }
        func line(atUTF16 offset: Int) -> Int { max(0, min(lineCount - 1, offset / (Self.width + 1))) }
        var utf16Length: Int { lineCount * (Self.width + 1) - 1 }
        var longestLine: Int { Self.width }
    }

    /// One line of `length` UTF-16 units, "0123456789" over and over, made
    /// where it is read.
    @MainActor final class LongLine: FileTextSource {
        let length: Int
        let lineCount = 1
        let generation = 0
        /// Where a 😀 (two UTF-16 units) sits instead of two digits, if anywhere.
        let emoji: Int?
        /// Where 漢, each a unit and wider than a column, stand instead of digits.
        let wide: Range<Int>
        private(set) var read = 0
        init(_ length: Int, emojiAt emoji: Int? = nil, wide: Range<Int> = 0..<0) { self.length = length; self.emoji = emoji; self.wide = wide }
        var arrival: ((ClosedRange<Int>) -> Void)?
        func fetch(from start: FileTextPosition, to end: FileTextPosition, completion: @escaping @MainActor (String?) -> Void) { completion(text(from: start, to: end)) }
        func utf16Length(ofLine index: Int) -> Int { length }
        func text(ofLine index: Int, range: Range<Int>) -> String? {
            let low = max(0, range.lowerBound), high = min(length, range.upperBound)
            guard high > low else { return "" }
            read += high - low
            let digits = Array("0123456789".utf16), face = Array("😀".utf16)
            let units = (low..<high).map { index -> UInt16 in
                if wide.contains(index) { return 0x6F22 }
                if let emoji, index == emoji { return face[0] }
                if let emoji, index == emoji + 1 { return face[1] }
                return digits[index % 10]
            }
            return String(utf16CodeUnits: units, count: units.count)
        }
        func utf16Start(ofLine index: Int) -> Int { 0 }
        func line(atUTF16 offset: Int) -> Int { 0 }
        var utf16Length: Int { length }
        var longestLine: Int { length }
    }

    /// A text whose lines come only when the test lets them: what a file on
    /// a slow disk looks like to the view. Lines asked for are remembered.
    @MainActor final class DelayedLines: FileTextSource {
        let whole: FileTextLines
        private(set) var ready: Set<Int> = []
        private(set) var asked: Set<Int> = []
        var arrival: ((ClosedRange<Int>) -> Void)?
        init(_ text: String) { whole = FileTextLines(text) }
        /// Whether what has not come may still come.
        var isReading = true
        /// Lets lines go again, as a full cache does.
        func evict(_ lines: ClosedRange<Int>) { ready.subtract(lines) }
        /// Lets lines come, and tells the view.
        func release(_ lines: ClosedRange<Int>) {
            ready.formUnion(lines)
            arrival?(lines)
        }
        var lineCount: Int { whole.lineCount }
        let generation = 0
        func utf16Length(ofLine index: Int) -> Int { whole.utf16Length(ofLine: index) }
        /// A line that comes by itself once it is asked for, on the next turn
        /// of the run loop: while a press is held, say; and what happens next.
        var comesWhenAsked: Int?
        var afterComing: (() -> Void)?
        func text(ofLine index: Int, range: Range<Int>) -> String? {
            guard ready.contains(index) else {
                asked.insert(index)
                if comesWhenAsked == index {
                    comesWhenAsked = nil
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.release(index...index); self.afterComing?() } }
                }
                return nil
            }
            return whole.text(ofLine: index, range: range)
        }
        func utf16Start(ofLine index: Int) -> Int { whole.utf16Start(ofLine: index) }
        func line(atUTF16 offset: Int) -> Int { whole.line(atUTF16: offset) }
        var utf16Length: Int { whole.utf16Length }
        var longestLine: Int { whole.longestLine }
        func showScreen(lines: ClosedRange<Int>, columns: Range<Int>) { asked.formUnion(lines) }
        private var fetches: [(FileTextPosition, FileTextPosition, @MainActor (String?) -> Void)] = []
        func fetch(from start: FileTextPosition, to end: FileTextPosition, completion: @escaping @MainActor (String?) -> Void) {
            if let text = text(from: start, to: end) { completion(text) } else { fetches.append((start, end, completion)) }
        }
        /// Finishes the fetches whose lines have all come.
        func finishFetches() {
            let waiting = fetches; fetches = []
            for (start, end, completion) in waiting { fetch(from: start, to: end, completion: completion) }
        }
    }

    // MARK: Fixture

    /// The view the text sits in, which takes Escape when the text passes it on.
    final class Holder: NSView {
        var cancelled = 0
        override func cancelOperation(_ sender: Any?) { cancelled += 1 }
    }

    @MainActor final class Fixture {
        let window: NSWindow
        let scroll: FileTextScrollView
        let holder: Holder
        let name: String
        var text: FileTextView { scroll.textView }
        init(window: NSWindow, scroll: FileTextScrollView, holder: Holder, name: String) {
            self.window = window; self.scroll = scroll; self.holder = holder; self.name = name
        }
        /// Draws what is on screen now, as the next display would: the text
        /// and its gutter, at once, not at the end of the run loop's turn.
        func draw() {
            holder.layoutSubtreeIfNeeded()
            for view in [text, scroll.numbers as NSView] {
                let rect = view.visibleRect
                guard !rect.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                view.cacheDisplay(in: rect, to: bitmap)
            }
        }
    }

    @MainActor private func fixture(_ source: FileTextSource, width: CGFloat = 640, height: CGFloat = 400) -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let holder = Holder(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let scroll = FileTextScrollView(frame: holder.bounds)
        scroll.autoresizingMask = [.width, .height]
        holder.addSubview(scroll)
        window.contentView = holder
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("file-text-tests-" + UUID().uuidString))
        scroll.textView.pasteboard = pasteboard
        let name = "probe-\(UUID().uuidString.prefix(8)).txt"
        window.title = "File text test " + name
        scroll.textView.show(source, name: name)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(scroll.textView)
        addTeardownBlock { @MainActor in
            pasteboard.releaseGlobally()
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        let fixture = Fixture(window: window, scroll: scroll, holder: holder, name: name)
        fixture.draw()
        return fixture
    }

    /// A point in the text view at a line and a column, where that column's
    /// character starts.
    @MainActor private func point(_ fixture: Fixture, line: Int, column: Int, inset: CGFloat = 0) -> NSPoint {
        let at = fixture.text.point(of: FileTextPosition(line: line, column: column))
        return NSPoint(x: at.x + inset, y: at.y + fixture.text.lineHeight / 2)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1,
                                  modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                                         context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    /// A real press: the drags and the release put on the application's own
    /// queue, the press then handed to the view, whose tracking takes the rest
    /// from the queue as it would from the reader's hand.
    @MainActor private func press(at start: NSPoint, dragging points: [NSPoint] = [], in view: NSView,
                                  clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
        while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil {}
        for point in points { NSApp.postEvent(try mouse(.leftMouseDragged, at: point, in: view, clicks: clicks, modifiers: modifiers), atStart: false) }
        NSApp.postEvent(try mouse(.leftMouseUp, at: points.last ?? start, in: view, clicks: clicks, modifiers: modifiers), atStart: false)
        view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view, clicks: clicks, modifiers: modifiers))
    }

    /// A key, as the keyboard sends it, through the view's key bindings.
    @MainActor private func key(_ fixture: Fixture, _ code: UInt16, _ character: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        let flags = arrows.contains(code) ? modifiers.union([.function, .numericPad]) : modifiers
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                                                   context: nil, characters: character, charactersIgnoringModifiers: character,
                                                   isARepeat: false, keyCode: code))
        fixture.text.keyDown(with: event)
    }
    private let left: (UInt16, String) = (123, "\u{F702}"), right: (UInt16, String) = (124, "\u{F703}")
    private let down: (UInt16, String) = (125, "\u{F701}"), up: (UInt16, String) = (126, "\u{F700}")

    @MainActor private func selection(_ fixture: Fixture) -> (FileTextPosition, FileTextPosition) { fixture.text.selectedRange }
    private func at(_ line: Int, _ column: Int) -> FileTextPosition { FileTextPosition(line: line, column: column) }

    // MARK: Only what is seen

    @MainActor func testSyntaxIsRequestedOnlyForDrawnLinesInALargeFile() {
        let source = GeneratedLines(3_000_000)
        let fixture = fixture(source)
        var coloured = Set<Int>()
        fixture.text.syntax = { line, _, text in
            coloured.insert(line)
            return [FileTextColorRun(range: NSRange(location: 0, length: min(4, text.utf16.count)), color: .red)]
        }
        fixture.draw()
        XCTAssertFalse(coloured.isEmpty)
        XCTAssertTrue(coloured.allSatisfy { $0 < 100 }, "the three-million-line prefix is not coloured")
        coloured = []
        fixture.text.scrollToEndOfDocument(nil)
        fixture.draw()
        XCTAssertFalse(coloured.isEmpty)
        XCTAssertTrue(coloured.allSatisfy { $0 > 2_999_900 }, "only the last visible lines are coloured at the end")
    }

    /// A file of three million lines sets and reads the lines on screen and no
    /// others, at its start and at its end, and its gutter fits its numbers.
    @MainActor func testOnlyTheLinesOnScreenAreSetAndRead() throws {
        let source = GeneratedLines(3_000_000)
        FileTextRenderCount.reset()
        let fixture = fixture(source)
        let text = fixture.text
        // How many lines the view shows, from its height alone, not from the
        // view's own reckoning.
        let visible = Int(ceil(fixture.scroll.contentView.bounds.height / standardMetrics.lineHeight)) + 1
        XCTAssertEqual(text.frame.height, text.top(ofLine: 3_000_000) + FileTextMetrics.bottom, "the document is as tall as the file")
        XCTAssertGreaterThan(FileTextRenderCount.pieces, 0, "the first screen is drawn")
        XCTAssertLessThanOrEqual(FileTextRenderCount.pieces, visible + 4, "only the lines on screen are set")
        XCTAssertLessThanOrEqual(source.read, (visible + 4) * GeneratedLines.width, "and only they are read")

        FileTextRenderCount.reset()
        let before = source.read
        text.scrollToEndOfDocument(nil)
        fixture.draw()
        XCTAssertEqual(text.visibleLines.upperBound, 2_999_999, "the last line is reached")
        XCTAssertLessThanOrEqual(FileTextRenderCount.pieces, visible + 4, "at the end, too, only the lines on screen are set")
        XCTAssertLessThanOrEqual(source.read - before, (visible + 4) * GeneratedLines.width)
        XCTAssertGreaterThanOrEqual(fixture.scroll.numbers.ruleThickness, 7 * 6, "the gutter is wide enough for seven digits")
    }

    /// Where a column is drawn is where a click there puts the insertion point.
    @MainActor func testAPointAndAPositionAreTheSamePlace() throws {
        let fixture = fixture(FileTextLines("let answer = 42\nprint(answer)\n"))
        let text = fixture.text
        for column in 0...15 {
            let point = text.point(of: at(0, column))
            XCTAssertEqual(point.x, FileTextMetrics.left + CGFloat(column) * standardMetrics.advance, accuracy: 0.01, "column \(column)")
            XCTAssertEqual(text.position(at: NSPoint(x: point.x + 1, y: point.y + 8)), at(0, column), "a click just after column \(column)'s start")
        }
        XCTAssertEqual(text.position(at: NSPoint(x: 5_000, y: text.top(ofLine: 1) + 8)), at(1, 13), "past a line's end is its end")
        XCTAssertEqual(text.position(at: NSPoint(x: 40, y: 1)), .start, "above the text is its start")
        XCTAssertEqual(text.position(at: NSPoint(x: 40, y: text.top(ofLine: 3) + 30)), at(2, 0), "below it, its end")
    }

    // MARK: Mouse

    @MainActor func testClickingDraggingAndShiftClickingSelect() throws {
        let fixture = fixture(FileTextLines("alpha beta\ngamma delta\nepsilon zeta\neta theta"))
        let text = fixture.text
        try press(at: point(fixture, line: 0, column: 2, inset: 1), dragging: [point(fixture, line: 1, column: 3, inset: 1), point(fixture, line: 2, column: 4, inset: 1)], in: text)
        XCTAssertTrue(selection(fixture) == (at(0, 2), at(2, 4)), "a drag selects from where it started to where it ended")
        XCTAssertEqual(text.selectedText, "pha beta\ngamma delta\nepsi")
        try press(at: point(fixture, line: 3, column: 3, inset: 1), in: text, modifiers: .shift)
        XCTAssertTrue(selection(fixture) == (at(0, 2), at(3, 3)), "Shift-click extends the selection from its anchor")
        try press(at: point(fixture, line: 1, column: 1, inset: 1), in: text)
        XCTAssertFalse(text.hasSelection, "a plain click leaves only the insertion point")
        XCTAssertEqual(text.focus, at(1, 1))
        XCTAssertTrue(fixture.window.firstResponder === text, "and the text has the keyboard")
    }

    @MainActor func testDoubleClickTakesAWordAndTripleClickALineAndDraggingKeepsThem() throws {
        let fixture = fixture(FileTextLines("let firstName = user.name\nlet lastName = user.surname\nreturn firstName"))
        let text = fixture.text
        try press(at: point(fixture, line: 0, column: 6, inset: 1), in: text, clicks: 2)
        XCTAssertEqual(text.selectedText, "firstName", "a double-click takes the word")
        // Dragging on from a double-click extends by whole words.
        try press(at: point(fixture, line: 0, column: 6, inset: 1), dragging: [point(fixture, line: 1, column: 6, inset: 1)], in: text, clicks: 2)
        XCTAssertEqual(text.selectedText, "firstName = user.name\nlet lastName", "a drag from a double-click takes whole words")
        try press(at: point(fixture, line: 1, column: 3, inset: 1), in: text, clicks: 3)
        XCTAssertEqual(text.selectedText, "let lastName = user.surname\n", "a triple-click takes the line and its line ending")
        try press(at: point(fixture, line: 1, column: 3, inset: 1), dragging: [point(fixture, line: 2, column: 2, inset: 1)], in: text, clicks: 3)
        XCTAssertEqual(text.selectedText, "let lastName = user.surname\nreturn firstName", "a drag from a triple-click takes whole lines")
    }

    /// Dragging below the view scrolls it and keeps selecting.
    @MainActor func testDraggingPastTheBottomScrollsAndSelectsOn() throws {
        let fixture = fixture(GeneratedLines(10_000))
        let text = fixture.text, clip = fixture.scroll.contentView
        let before = clip.bounds.minY
        let below = NSPoint(x: 80, y: text.visibleRect.maxY + 60)
        try press(at: point(fixture, line: 2, column: 4, inset: 1), dragging: [below, below, below], in: text)
        XCTAssertGreaterThan(clip.bounds.minY, before, "the view scrolls under a drag past its edge")
        XCTAssertEqual(selection(fixture).0, at(2, 4))
        XCTAssertGreaterThan(selection(fixture).1.line, text.lines(in: NSRect(x: 0, y: before, width: 10, height: clip.bounds.height)).upperBound,
                           "and the selection runs on to lines that were below it")
    }

    // MARK: Keys

    @MainActor func testKeysMoveAndExtendByCharacterWordLineAndDocument() throws {
        // A thumbs-up with its skin tone is four UTF-16 units and one
        // character; an e with a combining accent is two units and one.
        let fixture = fixture(FileTextLines("a👍🏽b e\u{301}x\nsecond line here\nthird"))
        let text = fixture.text
        try key(fixture, right.0, right.1)
        XCTAssertEqual(text.focus, at(0, 1))
        try key(fixture, right.0, right.1)
        XCTAssertEqual(text.focus, at(0, 5), "Right steps over a whole emoji with its modifier")
        try key(fixture, right.0, right.1, .shift); try key(fixture, right.0, right.1, .shift); try key(fixture, right.0, right.1, .shift)
        XCTAssertEqual(text.selectedText, "b e\u{301}", "Shift-Right extends a character at a time, an accent with its letter")
        try key(fixture, left.0, left.1)
        XCTAssertFalse(text.hasSelection); XCTAssertEqual(text.focus, at(0, 5), "Left without Shift goes to the selection's start")
        try key(fixture, right.0, right.1, [.option, .shift])
        XCTAssertEqual(text.selectedText, "b", "Option-Shift-Right takes the next word")
        try key(fixture, right.0, right.1, [.command, .shift])
        XCTAssertEqual(text.focus, at(0, 10), "Command-Shift-Right extends to the line's end")
        try key(fixture, down.0, down.1, [.command, .shift])
        XCTAssertEqual(text.focus, at(2, 5), "Command-Shift-Down to the end of the text")
        XCTAssertEqual(text.anchor, at(0, 5), "the anchor stays where the selection began")
        try key(fixture, up.0, up.1, .command)
        XCTAssertEqual(text.focus, .start); XCTAssertFalse(text.hasSelection, "Command-Up goes to the start")
        text.selectAll(nil)
        XCTAssertEqual(text.selectedText, "a👍🏽b e\u{301}x\nsecond line here\nthird")
    }

    /// Up and Down keep the column the reader started from, through a short line.
    @MainActor func testUpAndDownKeepTheirColumnAcrossShortLines() throws {
        let fixture = fixture(FileTextLines("a long first line\nab\nanother long line"))
        let text = fixture.text
        text.select(from: at(0, 10), to: at(0, 10))
        try key(fixture, down.0, down.1)
        XCTAssertEqual(text.focus, at(1, 2), "a short line stops at its end")
        try key(fixture, down.0, down.1)
        XCTAssertEqual(text.focus, at(2, 10), "and the next long one gets the column back")
        try key(fixture, up.0, up.1, .shift); try key(fixture, up.0, up.1, .shift)
        XCTAssertEqual(text.focus, at(0, 10)); XCTAssertEqual(text.anchor, at(2, 10), "Shift-Up extends upward by lines")
    }

    @MainActor func testEscapeGoesOnAndTypingAndDeletingChangeNothing() throws {
        let fixture = fixture(FileTextLines("read only"))
        let text = fixture.text
        text.select(from: at(0, 0), to: at(0, 4))
        try key(fixture, 53, "\u{1B}")
        XCTAssertEqual(fixture.holder.cancelled, 1, "Escape goes on to whoever closes things")
        try key(fixture, 0, "x"); try key(fixture, 51, "\u{7F}"); try key(fixture, 36, "\r")
        XCTAssertEqual(text.source.line(0), "read only", "nothing is typed into or deleted from a file")
        XCTAssertEqual(text.selectedText, "read", "and the selection is untouched")
        // Space pages down; Shift-Space back.
        let long = self.fixture(GeneratedLines(1_000))
        let clip = long.scroll.contentView
        try key(long, 49, " ")
        XCTAssertGreaterThan(clip.bounds.minY, 200, "the space bar pages")
        try key(long, 49, " ", .shift)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 1, "Shift-Space pages back")
    }

    // MARK: Copy

    /// A selection copies its lines joined by one "\n", whatever line endings
    /// the file used.
    @MainActor func testCopyJoinsLinesWithOneNewlineWhateverTheFilesEndings() throws {
        let fixture = fixture(FileTextLines("one\r\ntwo\rthree\nfour"))
        let text = fixture.text
        XCTAssertEqual(text.source.lineCount, 4)
        text.select(from: at(0, 1), to: at(3, 2))
        XCTAssertTrue(text.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(FileTextView.copy(_:)), keyEquivalent: "c")))
        text.copy(nil)
        XCTAssertEqual(text.pasteboard.string(forType: .string), "ne\ntwo\nthree\nfo")
        text.select(from: at(1, 1), to: at(1, 1))
        XCTAssertFalse(text.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(FileTextView.copy(_:)), keyEquivalent: "c")),
                       "Copy is offered only with something selected")
    }

    // MARK: Long lines

    /// A long line is set only where it is seen. Up to 65,536 units it is set
    /// piece after piece as far as the view reaches; beyond that on a grid, so
    /// its far end is reached, and clicked, without setting what is before it.
    @MainActor func testALongLineIsSetOnlyWhereItIsSeen() throws {
        for (length, grid) in [(40_000, false), (50_000_000, true)] {
            let source = LongLine(length)
            FileTextRenderCount.reset()
            let fixture = fixture(source)
            let text = fixture.text
            XCTAssertLessThanOrEqual(FileTextRenderCount.pieces, 2, "\(length): only the line's start is set")
            // Off the grid a line is read whole (at most 65,536 units) and
            // kept; on it, only the pieces drawn are read.
            XCTAssertLessThanOrEqual(source.read, grid ? 3 * FileTextMetrics.piece : length)
            XCTAssertEqual(text.layout(0)?.grid, grid)
            // The far end.
            let clip = fixture.scroll.contentView
            clip.scroll(to: NSPoint(x: text.frame.width - clip.bounds.width, y: 0)); fixture.scroll.reflectScrolledClipView(clip)
            FileTextRenderCount.reset()
            let read = source.read
            fixture.draw()
            let end = text.point(of: at(0, length))
            XCTAssertEqual(end.x, FileTextMetrics.left + CGFloat(length) * standardMetrics.advance, accuracy: CGFloat(length) * 0.0001 + 0.5,
                           "\(length): the line's end is where its columns put it")
            let near = length - 37
            XCTAssertEqual(text.position(at: NSPoint(x: text.point(of: at(0, near)).x + 1, y: 12)), at(0, near), "\(length): a click near the far end lands there")
            XCTAssertGreaterThan(FileTextRenderCount.pieces + (grid ? 0 : 1), 0, "\(length): the far end is drawn")
            // Accessibility's outline of a range there is where it is drawn,
            // scrolled sideways as it is.
            let outline = text.accessibilityFrame(for: NSRange(location: near, length: 3))
            let screen = fixture.window.convertToScreen(fixture.scroll.convert(fixture.scroll.bounds, to: nil))
            XCTAssertTrue(screen.contains(NSPoint(x: outline.midX, y: outline.midY)), "\(length): the outline of text at the far end is on screen")
            if grid {
                XCTAssertLessThanOrEqual(FileTextRenderCount.pieces, 4, "on the grid, only the pieces at the far end are set")
                XCTAssertLessThanOrEqual(source.read - read, 8 * FileTextMetrics.piece, "and only they are read")
            } else {
                XCTAssertLessThanOrEqual(FileTextRenderCount.pieces, length / FileTextMetrics.piece + 2, "short of the grid, each piece is set once")
            }
        }
    }

    /// A long line drawn again reads nothing more: the pieces set, and where
    /// they start, are kept.
    @MainActor func testALongLineDrawnAgainReadsNothingMore() throws {
        let source = LongLine(3_000_000)
        let fixture = fixture(source)
        fixture.draw()
        let read = source.read
        XCTAssertGreaterThan(read, 0)
        fixture.draw(); fixture.draw()
        XCTAssertEqual(source.read, read)
    }

    /// A tab keeps to the line's tab stops, every four columns from its start,
    /// in a piece set apart from the line's start.
    @MainActor func testTabsKeepTheLinesStopsAcrossPieces() throws {
        // Pieces end after a space, so a tab lands at the start of a piece.
        // Seven-column words: the second piece starts two columns past a stop.
        let words = String(repeating: "abcdef ", count: 147) + "\tafter"
        let fixture = fixture(FileTextLines(words))
        let text = fixture.text
        let tab = words.utf16.count - 6
        let line = try XCTUnwrap(text.layout(0))
        let after = line.x(at: tab + 1)
        let interval = standardMetrics.tabInterval
        XCTAssertEqual(after.truncatingRemainder(dividingBy: interval), 0, accuracy: 0.01, "the text after a tab starts on a stop")
        XCTAssertGreaterThan(after, line.x(at: tab), "and past where the tab began")
        XCTAssertLessThanOrEqual(after - line.x(at: tab), interval + 0.01)
    }

    /// On the grid, a character cut by a piece's multiple belongs to the next
    /// piece, and drawing across it goes on: it used to ask for the same
    /// piece for ever.
    @MainActor func testAGridPieceCutThroughACharacterIsDrawnAndPassed() throws {
        let source = LongLine(200_000, emojiAt: FileTextMetrics.piece - 1)
        let fixture = fixture(source)
        let text = fixture.text
        let layout = try XCTUnwrap(text.layout(0))
        XCTAssertTrue(layout.grid)
        let around = layout.pieces(from: CGFloat(1_000) * standardMetrics.advance, to: CGFloat(1_100) * standardMetrics.advance)
        XCTAssertEqual(around.map(\.range), [0..<1_023, 1_023..<2_048], "the emoji starts the second piece; the first ends before it")
        let clip = fixture.scroll.contentView
        clip.scroll(to: NSPoint(x: CGFloat(1_000) * standardMetrics.advance, y: 0)); fixture.scroll.reflectScrolledClipView(clip)
        fixture.draw()
        XCTAssertEqual(text.position(at: NSPoint(x: text.point(of: at(0, 1_025)).x + 1, y: 12)), at(0, 1_025), "a click just past the emoji lands after it")
    }

    /// A line far wider than its length says (two thousand tabs) widens the
    /// view as its pieces are set, so its end can be scrolled to.
    @MainActor func testALineWiderThanItsLengthWidensTheViewToItsEnd() async throws {
        let line = String(repeating: "\t", count: 2_000) + "END"
        let fixture = fixture(FileTextLines(line))
        let text = fixture.text, clip = fixture.scroll.contentView
        for _ in 0..<6 {
            clip.scroll(to: NSPoint(x: max(0, text.frame.width - clip.bounds.width), y: 0)); fixture.scroll.reflectScrolledClipView(clip)
            fixture.draw()
            try await Task.sleep(for: .milliseconds(20))
        }
        let end = text.point(of: at(0, 2_003))
        XCTAssertGreaterThanOrEqual(end.x, FileTextMetrics.left + 2_000 * standardMetrics.tabInterval - 1, "two thousand tabs reach two thousand stops")
        XCTAssertLessThanOrEqual(end.x, text.frame.width, "and the view is wide enough to show where the line ends")
        XCTAssertTrue(text.visibleRect.contains(NSPoint(x: text.point(of: at(0, 2_000)).x + 2, y: 10)), "scrolled right, END is on screen")
    }

    /// Text that runs right to left is selected where its glyphs are: a
    /// later character further left.
    @MainActor func testRightToLeftTextIsSelectedWhereItIsDrawn() throws {
        let arabic = "مرحبا بالعالم"
        let fixture = fixture(FileTextLines(arabic + "\nabc " + arabic + " def"))
        let text = fixture.text
        let whole = try XCTUnwrap(text.layout(0)).spans(from: 0, to: (arabic as NSString).length)
        let covered = whole.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertGreaterThan(covered, 40, "the whole Arabic line is covered")
        XCTAssertEqual(text.accessibilityFrame(for: NSRange(location: 0, length: (arabic as NSString).length)).width, covered, accuracy: 1,
                       "and so is its outline for VoiceOver")
        // In a line that runs left to right, the Arabic words sit between
        // "abc " and " def".
        let mixed = try XCTUnwrap(text.layout(1))
        let start = 4, end = 4 + (arabic as NSString).length
        let spans = mixed.spans(from: start, to: end)
        let left = spans.map(\.lowerBound).min() ?? 0, right = spans.map(\.upperBound).max() ?? 0
        // Where a direction changes a caret has two places, so the edges are
        // taken from the glyphs either side.
        let before = mixed.spans(from: 3, to: 4).first?.upperBound ?? -1
        let after = mixed.spans(from: end, to: end + 1).first?.lowerBound ?? -1
        XCTAssertEqual(left, before, accuracy: 1, "the Arabic starts where \"abc \" ends")
        XCTAssertEqual(right, after, accuracy: 1, "and ends where \" def\" begins")
    }

    /// All of a line of fifty million characters selected draws what is on
    /// screen of it, and its outline for VoiceOver is found without setting it.
    @MainActor func testSelectingAllOfAHugeLineSetsOnlyWhatIsOnScreen() throws {
        let source = LongLine(50_000_000)
        let fixture = fixture(source)
        let text = fixture.text
        text.selectAll(nil)
        FileTextRenderCount.reset()
        let started = ProcessInfo.processInfo.systemUptime
        fixture.draw()
        let frame = text.accessibilityFrame(for: NSRange(location: 0, length: 50_000_000))
        XCTAssertLessThanOrEqual(FileTextRenderCount.pieces, 8, "the selection is drawn where the screen is, not along the whole line")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(frame.width, 50_000_000 * standardMetrics.advance, accuracy: 1, "its outline is the whole line's")
    }

    /// On the grid, wide characters are drawn squeezed into their piece, so
    /// a window scrolled into a piece still meets glyphs its columns alone
    /// would put further left: a selection there is still highlighted.
    @MainActor func testASelectionAmongSqueezedWideCharactersIsDrawnWhereTheyAre() throws {
        let fixture = fixture(LongLine(200_000, wide: 0..<100))
        let layout = try XCTUnwrap(fixture.text.layout(0))
        XCTAssertTrue(layout.grid)
        let drawn = layout.spans(from: 60, to: 70)
        XCTAssertFalse(drawn.isEmpty)
        let left = drawn.map(\.lowerBound).min() ?? 0
        XCTAssertGreaterThan(left, 60 * standardMetrics.advance + 20, "squeezed wide glyphs sit right of their columns")
        // A window whose left edge is past the selection's columns but not
        // past its glyphs.
        let window = (left + 5)...(left + 600)
        XCTAssertGreaterThan(window.lowerBound / standardMetrics.advance, 70)
        XCTAssertFalse(layout.spans(from: 60, to: 70, within: window).isEmpty, "the selection is still drawn in that window")
    }

    /// The outline of a long range on the grid reaches its last glyph, even
    /// where wide characters there push glyphs right of their columns.
    @MainActor func testTheOutlineOfALongGridRangeReachesItsLastGlyph() throws {
        let fixture = fixture(LongLine(210_000, wide: 4_096..<4_196))
        let text = fixture.text
        let layout = try XCTUnwrap(text.layout(0))
        let lastGlyph = try XCTUnwrap(layout.spans(from: 4_165, to: 4_166).map(\.upperBound).max())
        XCTAssertGreaterThan(lastGlyph, 4_166 * standardMetrics.advance + 50, "the wide glyphs sit right of their columns")
        let outline = text.accessibilityFrame(for: NSRange(location: 0, length: 4_166))
        let origin = fixture.window.convertToScreen(text.convert(NSRect(x: FileTextMetrics.left, y: 0, width: 1, height: 1), to: nil)).minX
        XCTAssertGreaterThanOrEqual(outline.maxX - origin, lastGlyph - 0.5, "the outline encloses the last selected glyph")
    }

    /// Part of a ligature selected takes that part of the glyph: the alef of
    /// a lam-alef, drawn as one glyph, is selected on its own.
    @MainActor func testPartOfALigatureIsSelectedAsPartOfItsGlyph() throws {
        let fixture = fixture(FileTextLines("لا"))
        let layout = try XCTUnwrap(fixture.text.layout(0))
        let whole = layout.spans(from: 0, to: 2).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let alef = layout.spans(from: 1, to: 2).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertGreaterThan(alef, 0, "the alef alone is highlighted")
        XCTAssertLessThan(alef, whole, "and only its share of the glyph")
        XCTAssertGreaterThan(fixture.text.accessibilityFrame(for: NSRange(location: 1, length: 1)).width, 1)
    }

    /// A double-click takes a word whole however long it is, and a word
    /// movement goes past its end.
    @MainActor func testALongWordIsTakenWhole() throws {
        let word = String(repeating: "a", count: 800)
        let fixture = fixture(FileTextLines(word + " end"))
        let text = fixture.text
        let range = try XCTUnwrap(text.wordRange(at: at(0, 400)))
        XCTAssertTrue(range == (at(0, 0), at(0, 800)), "the whole 800-character word")
        text.select(from: at(0, 400), to: at(0, 400))
        try key(fixture, right.0, right.1, .option)
        XCTAssertEqual(text.focus, at(0, 800), "Option-Right goes to the word's end, past what was read first")
    }

    // MARK: Text not come yet

    /// A line whose text has not come is drawn empty, asked for, and drawn
    /// when it comes; nothing waits for it.
    @MainActor func testALineNotComeYetIsDrawnWhenItComes() throws {
        let source = DelayedLines("one\ntwo\nthree")
        FileTextRenderCount.reset()
        let fixture = fixture(source)
        XCTAssertEqual(FileTextRenderCount.pieces, 0, "nothing is set before its text has come")
        XCTAssertTrue(source.asked.isSuperset(of: [0, 1, 2]), "the lines on screen were asked for")
        source.release(0...1)
        fixture.draw()
        XCTAssertEqual(FileTextRenderCount.pieces, 2, "the lines that came are set and drawn")
        source.release(2...2)
        fixture.draw()
        XCTAssertEqual(FileTextRenderCount.pieces, 3)
    }

    /// A key that needs text not come yet waits for it, the selection left
    /// as it was, and moves when it comes; if the reader moves on meanwhile,
    /// it is dropped.
    @MainActor func testAKeyThatNeedsTextNotComeYetWaitsForIt() throws {
        let source = DelayedLines("first line\nsecond line\nthird line")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(0, 3), to: at(0, 3))
        try key(fixture, down.0, down.1, .shift)
        XCTAssertEqual(text.focus, at(0, 3), "Shift-Down into a line not come yet waits")
        source.release(1...1)
        XCTAssertEqual(text.focus, at(1, 3), "and moves when it comes")
        XCTAssertEqual(text.anchor, at(0, 3))
        try key(fixture, down.0, down.1)
        XCTAssertEqual(text.focus, at(1, 3), "Down waits again")
        text.select(from: at(0, 0), to: at(0, 0))
        source.release(2...2)
        XCTAssertEqual(text.focus, at(0, 0), "a movement the reader moved on from is dropped")
    }

    /// Keys pressed while the text they need has not come are all done when
    /// it comes, in order, each from where the one before ended.
    @MainActor func testKeysPressedWhileTextIsComingAreAllDone() throws {
        let source = DelayedLines("first line\nsecond line")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(1, 0), to: at(1, 0))
        try key(fixture, right.0, right.1)
        try key(fixture, right.0, right.1)
        try key(fixture, right.0, right.1, .shift)
        XCTAssertEqual(text.focus, at(1, 0), "waiting for the line")
        source.release(1...1)
        XCTAssertEqual(text.anchor, at(1, 2))
        XCTAssertEqual(text.focus, at(1, 3), "two moves and an extend, in order")
    }

    /// Right after Shift-Right, both waiting, collapses the selection the
    /// first made, as Right does: the collapse is decided when it is done.
    @MainActor func testAWaitingRightCollapsesTheSelectionAWaitingShiftRightMade() throws {
        let source = DelayedLines("first line\nsecond line")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(1, 0), to: at(1, 0))
        try key(fixture, right.0, right.1, .shift)
        try key(fixture, right.0, right.1)
        source.release(1...1)
        XCTAssertEqual(selection(fixture).0, at(1, 1))
        XCTAssertEqual(selection(fixture).1, at(1, 1), "Right collapsed the one-character selection at its end")
    }

    /// A movement waiting for text that will not come (the file changed and
    /// is no longer read) is dropped, and keys after it are done at once.
    @MainActor func testAMovementWhoseTextWillNotComeIsDropped() throws {
        let source = DelayedLines("first line\nsecond line\nthird")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(1, 3), to: at(1, 3))
        try key(fixture, right.0, right.1)
        XCTAssertEqual(text.focus, at(1, 3), "waiting")
        source.isReading = false
        source.arrival?(0...2)
        // Were it still waiting, the line coming now would move it.
        source.isReading = true; source.release(1...1)
        XCTAssertEqual(text.focus, at(1, 3), "dropped when the text stopped coming")
        try key(fixture, up.0, up.1, .command)
        XCTAssertEqual(text.focus, .start, "Command-Up is done, not queued behind the dropped movement")
    }

    /// A waiting movement is dropped when the selection is changed by
    /// anything else, even back to where it was.
    @MainActor func testAWaitingMovementIsDroppedWhenTheSelectionChangesAndComesBack() throws {
        let source = DelayedLines("first line\nsecond line")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(1, 0), to: at(1, 0))
        try key(fixture, right.0, right.1)
        text.select(from: at(0, 2), to: at(0, 2))
        text.select(from: at(1, 0), to: at(1, 0))
        source.release(1...1)
        XCTAssertEqual(text.focus, at(1, 0), "the movement from before the change is not done")
    }

    /// A double-click on a word whose text has not come takes the word when
    /// it comes; a drag or click meanwhile drops it.
    @MainActor func testADoubleClickOnAWordNotComeYetTakesItWhenItComes() throws {
        let source = DelayedLines("first line\nlet greeting = hello")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        try press(at: point(fixture, line: 1, column: 6, inset: 2), in: text, clicks: 2)
        XCTAssertFalse(text.hasSelection, "a click while the word has not come")
        source.release(1...1)
        XCTAssertEqual(text.selectedText, "greeting", "the word, once it came")
        let other = DelayedLines("first line\nlet greeting = hello")
        text.show(other, name: "again.txt")
        other.release(0...0)
        try press(at: point(fixture, line: 1, column: 6, inset: 2), in: text, clicks: 2)
        text.select(from: at(0, 1), to: at(0, 1))
        other.release(1...1)
        XCTAssertEqual(text.focus, at(0, 1), "a word the reader moved on from is not taken")
    }

    /// A word wider than the screen, double-clicked before its text came,
    /// is taken when it comes without the view moving to its end: the click
    /// was where the reader was looking.
    @MainActor func testAWordTakenLaterDoesNotScrollTheView() throws {
        let source = DelayedLines("first line\n" + String(repeating: "a", count: 1_000) + " end")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        try press(at: point(fixture, line: 1, column: 3, inset: 2), in: text, clicks: 2)
        source.release(1...1)
        XCTAssertEqual(text.selectedRange.start, at(1, 0))
        XCTAssertEqual(text.selectedRange.end, at(1, 1_000), "the whole word")
        XCTAssertEqual(fixture.scroll.contentView.bounds.minX, 0, "the view did not move to its end")
    }

    /// A press drops keys still waiting for text: Right waiting at the caret,
    /// then a double-click there on a word not come yet, takes the word when
    /// it comes, without the Right and without scrolling for it.
    @MainActor func testAPressDropsKeysStillWaiting() throws {
        let source = DelayedLines("first line\n" + String(repeating: "a", count: 1_000) + " end")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(1, 3), to: at(1, 3))
        try key(fixture, right.0, right.1)
        try press(at: point(fixture, line: 1, column: 3, inset: 2), in: text, clicks: 2)
        source.release(1...1)
        XCTAssertEqual(text.selectedRange.start, at(1, 0))
        XCTAssertEqual(text.selectedRange.end, at(1, 1_000), "the word")
        XCTAssertEqual(fixture.scroll.contentView.bounds.minX, 0, "and no scrolling for the dropped key")
    }

    /// A word whose text comes while the double-click's press is still held
    /// is taken as the press goes on: held still, the selection is the word.
    @MainActor func testAWordComingWhileThePressIsHeldIsTaken() throws {
        let source = DelayedLines("first line\nlet greeting = hello")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        let at = point(fixture, line: 1, column: 6, inset: 2)
        let still = try mouse(.leftMouseDragged, at: at, in: text, clicks: 2), up = try mouse(.leftMouseUp, at: at, in: text, clicks: 2)
        // The line comes while the press waits for the pointer, which then
        // stays where it was until the release.
        source.comesWhenAsked = 1
        source.afterComing = { NSApp.postEvent(still, atStart: false); NSApp.postEvent(up, atStart: false) }
        while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil {}
        text.mouseDown(with: try mouse(.leftMouseDown, at: at, in: text, clicks: 2))
        XCTAssertEqual(text.selectedText, "greeting")
    }

    /// A double-clicked word that came while the press is held stays taken
    /// for the rest of the press even if its text goes again at once (a
    /// word of many windows, let go of by a full cache once taken): the
    /// press keeps the word found when it came, and never shrinks it to the
    /// click.
    @MainActor func testAWordTakenDuringAPressStaysTakenThoughItsTextGoes() throws {
        let source = DelayedLines("first line\nlet greeting = hello")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        let spot = point(fixture, line: 1, column: 6, inset: 2)
        let still = try mouse(.leftMouseDragged, at: spot, in: text, clicks: 2), up = try mouse(.leftMouseUp, at: spot, in: text, clicks: 2)
        source.comesWhenAsked = 1
        source.afterComing = {
            source.evict(1...1)
            NSApp.postEvent(still, atStart: false); NSApp.postEvent(up, atStart: false)
        }
        while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil {}
        text.mouseDown(with: try mouse(.leftMouseDown, at: spot, in: text, clicks: 2))
        XCTAssertEqual(text.selectedRange.start, at(1, 4))
        XCTAssertEqual(text.selectedRange.end, at(1, 12), "the word, not shrunk to the click")
    }

    /// Text that comes after accessibility found it missing is announced:
    /// the value once for all that comes in a turn of the run loop, and the
    /// selection's text when it was among it.
    @MainActor func testTextThatComesIsAnnouncedToAccessibility() async throws {
        let source = DelayedLines("one\ntwo\nthree")
        let fixture = fixture(source)
        let text = fixture.text
        var heard: [NSAccessibility.Notification] = []
        text.announce = { heard.append($0) }
        text.select(from: at(1, 0), to: at(1, 3))
        heard.removeAll()
        source.release(0...0); source.release(1...1); source.release(2...2)
        XCTAssertTrue(heard.isEmpty, "not at each arrival")
        try await eventually("announced") { !heard.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard.filter { $0 == .valueChanged }.count, 1, "the value once for the three lines")
        XCTAssertEqual(heard.filter { $0 == .selectedTextChanged }.count, 1, "and the selection's text")
    }

    /// Copy of text not come yet copies it when it comes; a later Copy of
    /// another selection supersedes it.
    @MainActor func testCopyOfTextNotComeYetCopiesItWhenItComes() throws {
        let source = DelayedLines("alpha\nbeta\ngamma")
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        text.select(from: at(0, 2), to: at(1, 2))
        text.copy(nil)
        XCTAssertNil(text.pasteboard.string(forType: .string), "nothing is copied before the text has come")
        source.release(1...1); source.finishFetches()
        XCTAssertEqual(text.pasteboard.string(forType: .string), "pha\nbe", "it is copied when it comes")
        text.select(from: at(1, 0), to: at(2, 3))
        text.copy(nil)
        text.select(from: at(0, 0), to: at(0, 2))
        text.copy(nil)
        source.release(2...2); source.finishFetches()
        XCTAssertEqual(text.pasteboard.string(forType: .string), "al", "the last Copy is what is copied")
    }

    /// Accessibility is handed only text that has come: nothing for text
    /// not come yet, which is then asked for, and the text once it has.
    @MainActor func testAccessibilityGetsTextOnceItHasCome() throws {
        let source = DelayedLines("one\ntwo")
        let fixture = fixture(source)
        let text = fixture.text
        XCTAssertNil(text.accessibilityString(for: NSRange(location: 4, length: 3)), "nothing before it has come")
        XCTAssertTrue(source.asked.contains(1), "it is asked for")
        XCTAssertNil(text.accessibilityValue())
        source.release(0...1)
        XCTAssertEqual(text.accessibilityString(for: NSRange(location: 4, length: 3)), "two", "and read once it has")
        XCTAssertEqual(text.accessibilityValue() as? String, "one\ntwo")
    }

    /// Down into a long line whose text has not come waits for it, and then
    /// lands where a character starts, never inside one.
    @MainActor func testDownIntoALongLineNotComeYetLandsBetweenCharacters() throws {
        let source = DelayedLines("ab\n😀" + String(repeating: "0123456789", count: 7_000))
        let fixture = fixture(source)
        let text = fixture.text
        source.release(0...0)
        XCTAssertEqual(text.layout(1)?.grid, true, "the long line is on the grid")
        text.select(from: at(0, 1), to: at(0, 1))
        try key(fixture, down.0, down.1)
        XCTAssertEqual(text.focus, at(0, 1), "Down waits for the line")
        source.release(1...1)
        XCTAssertEqual(text.focus.line, 1, "and moves when it comes")
        XCTAssertTrue([0, 2].contains(text.focus.column), "to either side of the 😀, not between its halves: \(text.focus.column)")
    }

    /// Accessibility asking for the character at an offset not read yet is
    /// told it is not known, and told once it has come.
    @MainActor func testAccessibilityIsToldNoCharacterBeforeItHasCome() throws {
        let source = DelayedLines("a👍🏽b\nsecond")
        let fixture = fixture(source)
        let text = fixture.text
        XCTAssertEqual(text.accessibilityRange(for: 2).location, NSNotFound, "not known before it has come")
        source.release(0...1)
        XCTAssertEqual(text.accessibilityRange(for: 2), NSRange(location: 1, length: 4), "then the 👍🏽 whole")
    }

    // MARK: Gutter

    @MainActor func testTheGutterSelectsTheLinesClickedAndDragged() throws {
        let fixture = fixture(FileTextLines("one\ntwo\nthree\nfour\nfive"))
        let text = fixture.text, ruler = fixture.scroll.numbers!
        func inRuler(_ line: Int) -> NSPoint { ruler.convert(NSPoint(x: 8, y: text.top(ofLine: line) + 8), from: text) }
        try press(at: inRuler(1), in: ruler)
        XCTAssertEqual(text.selectedText, "two\n", "a click on a line's number selects the line")
        try press(at: inRuler(1), dragging: [inRuler(3)], in: ruler)
        XCTAssertEqual(text.selectedText, "two\nthree\nfour\n", "a drag down the numbers selects the lines crossed")
        try press(at: inRuler(4), in: ruler, modifiers: .shift)
        XCTAssertEqual(text.selectedText, "two\nthree\nfour\nfive", "Shift-click extends by lines")

        // Far down a long file, scrolled part way into a line, a click on the
        // last number on screen selects that line.
        let long = self.fixture(GeneratedLines(100_000))
        let clip = long.scroll.contentView, longRuler = long.scroll.numbers!
        clip.scroll(to: NSPoint(x: 0, y: long.text.top(ofLine: 97_000) + 6.5)); long.scroll.reflectScrolledClipView(clip)
        long.draw()
        let last = long.text.visibleLines.upperBound - 1
        try press(at: longRuler.convert(NSPoint(x: 8, y: long.text.top(ofLine: last) + 8), from: long.text), in: longRuler)
        XCTAssertEqual(long.text.selectedRange.start, at(last, 0), "the line under the number is the one selected")
        XCTAssertEqual(long.text.selectedText, GeneratedLines.line(last) + "\n")
    }

    /// A press whose release never arrives (the window closed under it, the
    /// button let go elsewhere) ends: the main thread does not wait for it.
    /// The periodic events that scroll under a held press used to keep it
    /// going for ever.
    @MainActor func testAPressWhoseReleaseGoesMissingEnds() throws {
        let fixture = fixture(FileTextLines("first line\nsecond line"))
        let text = fixture.text
        while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil {}
        NSApp.postEvent(try mouse(.leftMouseDragged, at: point(fixture, line: 1, column: 6, inset: 1), in: text), atStart: false)
        let started = ProcessInfo.processInfo.systemUptime
        text.mouseDown(with: try mouse(.leftMouseDown, at: point(fixture, line: 0, column: 2, inset: 1), in: text))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1, "the press ends once the button is found up")
        XCTAssertEqual(text.selectedText, "rst line\nsecond", "and keeps what it had selected")
    }

    // MARK: Accessibility

    /// What VoiceOver gets, asked through the accessibility interface off the
    /// main thread, as VoiceOver asks: the text area, its text, its lines, its
    /// characters, where they are drawn, and its selection, which can be set
    /// while the text cannot.
    @MainActor func testVoiceOverReadsTheTextThroughTheAccessibilityInterface() async throws {
        let sample = "func greet() {\n    print(\"héllo 👋🏽\")\n}\n"
        let fixture = fixture(FileTextLines(sample))
        let pid = getpid(), label = "Contents of \(fixture.name)"
        let read = try AXProbe.read(pid: pid, label: label)
        XCTAssertEqual(read.role, "AXTextArea")
        XCTAssertEqual(read.value, sample, "the whole text is the value of a small file")
        XCTAssertEqual(read.characters, (sample as NSString).length)
        XCTAssertEqual(read.lineTwo, "    print(\"héllo 👋🏽\")\n", "a line's range holds the line and its line ending")
        XCTAssertEqual(read.lineOfOffset20, 1)
        XCTAssertEqual(read.stringAcrossLines, "{\n    pr", "a range across lines reads with one newline")
        XCTAssertEqual(read.emojiRange, NSRange(location: 32, length: 4), "the character at an offset is the whole emoji")
        XCTAssertTrue(read.attributedHasFont, "the attributed text describes its font for VoiceOver")
        XCTAssertFalse(read.valueSettable, "the text cannot be changed")
        XCTAssertFalse(read.selectedTextSettable)
        XCTAssertTrue(read.selectedRangeSettable, "its selection can")
        XCTAssertEqual(read.visible, NSRange(location: 0, length: (sample as NSString).length), "everything is on screen")

        // Where a range is, on screen, is where it is drawn.
        let expected = fixture.text.accessibilityFrame(for: NSRange(location: 19, length: 5))
        let height = NSScreen.screens.first?.frame.height ?? 0
        XCTAssertEqual(read.bounds.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(read.bounds.minY, height - expected.maxY, accuracy: 0.5, "the bounds VoiceOver outlines are the text's")
        XCTAssertEqual(read.bounds.width, 5 * standardMetrics.advance, accuracy: 0.5)

        // Selecting through accessibility selects in the view.
        try AXProbe.select(pid: pid, label: label, range: NSRange(location: 19, length: 5))
        XCTAssertEqual(fixture.text.selectedText, "print")
        XCTAssertEqual(fixture.text.accessibilityInsertionPointLineNumber(), 1)
        let selected = try AXProbe.selected(pid: pid, label: label)
        XCTAssertEqual(selected.text, "print"); XCTAssertEqual(selected.range, NSRange(location: 19, length: 5))

        // The character under a point is the one whose glyphs hold it.
        func inside(_ offset: Int) -> CGPoint {
            let frame = fixture.text.accessibilityFrame(for: NSRange(location: offset, length: 1))
            return CGPoint(x: frame.midX, y: height - frame.midY)
        }
        XCTAssertEqual(try AXProbe.range(pid: pid, label: label, at: inside(20)), NSRange(location: 20, length: 1), "the r of print")
        let emoji = fixture.text.accessibilityFrame(for: NSRange(location: 32, length: 4))
        XCTAssertEqual(try AXProbe.range(pid: pid, label: label, at: CGPoint(x: emoji.midX, y: height - emoji.midY)), NSRange(location: 32, length: 4),
                       "the emoji with its modifier, whole")
    }

    /// A file too big to hand over whole is read by range, far below the
    /// screen as well as on it, and nothing reads more than was asked for.
    @MainActor func testALargeFileIsReadThroughRangesWithoutBuildingItWhole() async throws {
        let source = GeneratedLines(3_000_000)
        let fixture = fixture(source)
        let pid = getpid(), label = "Contents of \(fixture.name)"
        let before = source.read
        let far = 2_999_000 * (GeneratedLines.width + 1)
        let read = try AXProbe.readLarge(pid: pid, label: label, offset: far)
        XCTAssertNil(read.value, "a file of 180 million characters is not handed over whole")
        XCTAssertEqual(read.characters, source.utf16Length)
        XCTAssertEqual(read.farLine, GeneratedLines.line(2_999_000) + "\n", "a line far below the screen reads right")
        XCTAssertEqual(read.lineOfFarOffset, 2_999_000)
        XCTAssertLessThanOrEqual(source.read - before, 16 * GeneratedLines.width, "and reading it read that line, not the file")

        // Everything selected: the selection's text is not built for
        // accessibility either, nor is a range of the whole file.
        fixture.text.selectAll(nil)
        let selected = source.read
        XCTAssertNil(fixture.text.accessibilitySelectedText(), "a selection of the whole of a huge file is not handed over")
        XCTAssertNil(fixture.text.accessibilityString(for: NSRange(location: 0, length: source.utf16Length)))
        XCTAssertEqual(fixture.text.accessibilitySelectedTextRange(), NSRange(location: 0, length: source.utf16Length), "though its range is")
        XCTAssertEqual(source.read, selected, "and nothing was read to answer")
    }

    /// An empty file is one empty line; a file ending in a newline has an
    /// empty last line; both read as a text view reads them.
    @MainActor func testEmptyAndTrailingNewlineTexts() throws {
        let empty = fixture(FileTextLines(""))
        XCTAssertEqual(empty.text.source.lineCount, 1)
        XCTAssertEqual(empty.text.accessibilityNumberOfCharacters(), 0)
        XCTAssertEqual(empty.text.accessibilityRange(forLine: 0), NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.text.accessibilityRange(for: 0), NSRange(location: 0, length: 0), "the end of an empty text is an empty range")
        empty.text.selectAll(nil)
        XCTAssertFalse(empty.text.hasSelection)

        let trailing = fixture(FileTextLines("a\n"))
        XCTAssertEqual(trailing.text.source.lineCount, 2)
        XCTAssertEqual(trailing.text.accessibilityNumberOfCharacters(), 2)
        XCTAssertEqual(trailing.text.accessibilityRange(forLine: 0), NSRange(location: 0, length: 2), "the first line with its newline")
        XCTAssertEqual(trailing.text.accessibilityRange(forLine: 1), NSRange(location: 2, length: 0), "the empty last line at the end")
        XCTAssertEqual(trailing.text.accessibilityRange(for: 1), NSRange(location: 1, length: 1), "the newline is a character")
        XCTAssertEqual(trailing.text.accessibilityLine(for: 2), 1, "the end of the text is on the last line")
        trailing.text.selectAll(nil)
        XCTAssertEqual(trailing.text.selectedText, "a\n")
    }
}

/// The accessibility client side: what VoiceOver asks, asked through the
/// same interface (the attribute names and parameters AppKit answers). Asked
/// of this process, the interface answers on the calling thread, so it is
/// asked on the main thread, and only of the test's own window.
@MainActor enum AXProbe {
    struct NotFound: Error {}

    static func find(pid: pid_t, label: String) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 10)
        let title = "File text test " + label.replacingOccurrences(of: "Contents of ", with: "")
        let windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var stack = windows.filter { copy($0, kAXTitleAttribute) as? String == title }
        while let element = stack.popLast() {
            if copy(element, kAXDescriptionAttribute) as? String == label { return element }
            stack += (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        throw NotFound()
    }
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    static func copy(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success ? value : nil
    }
    static func rangeValue(_ range: NSRange) -> AXValue {
        var cf = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cf)!
    }
    static func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &cf) ? NSRange(location: cf.location, length: cf.length) : nil
    }
    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
    static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    struct Read: Sendable {
        var role: String?, value: String?, characters: Int?
        var lineTwo: String?, lineOfOffset20: Int?, stringAcrossLines: String?, emojiRange: NSRange?
        var attributedHasFont = false, valueSettable = true, selectedTextSettable = true, selectedRangeSettable = false
        var visible: NSRange?, bounds = CGRect.zero
    }
    static func read(pid: pid_t, label: String) throws -> Read {
        let element = try find(pid: pid, label: label)
        var read = Read()
        read.role = copy(element, kAXRoleAttribute) as? String
        read.value = copy(element, kAXValueAttribute) as? String
        read.characters = copy(element, kAXNumberOfCharactersAttribute) as? Int
        if let line = range(copy(element, kAXRangeForLineParameterizedAttribute, NSNumber(value: 1))) {
            read.lineTwo = copy(element, kAXStringForRangeParameterizedAttribute, rangeValue(line)) as? String
        }
        read.lineOfOffset20 = copy(element, kAXLineForIndexParameterizedAttribute, NSNumber(value: 20)) as? Int
        read.stringAcrossLines = copy(element, kAXStringForRangeParameterizedAttribute, rangeValue(NSRange(location: 13, length: 8))) as? String
        read.emojiRange = range(copy(element, kAXRangeForIndexParameterizedAttribute, NSNumber(value: 33)))
        if let attributed = copy(element, kAXAttributedStringForRangeParameterizedAttribute, rangeValue(NSRange(location: 0, length: 4))) as? NSAttributedString,
           attributed.length > 0 {
            read.attributedHasFont = attributed.attribute(.accessibilityFont, at: 0, effectiveRange: nil) != nil
        }
        read.valueSettable = settable(element, kAXValueAttribute)
        read.selectedTextSettable = settable(element, kAXSelectedTextAttribute)
        read.selectedRangeSettable = settable(element, kAXSelectedTextRangeAttribute)
        read.visible = range(copy(element, kAXVisibleCharacterRangeAttribute))
        read.bounds = rect(copy(element, kAXBoundsForRangeParameterizedAttribute, rangeValue(NSRange(location: 19, length: 5)))) ?? .zero
        return read
    }
    static func select(pid: pid_t, label: String, range: NSRange) throws {
        let element = try find(pid: pid, label: label)
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue(range))
    }
    static func selected(pid: pid_t, label: String) throws -> (text: String?, range: NSRange?) {
        let element = try find(pid: pid, label: label)
        return (copy(element, kAXSelectedTextAttribute) as? String, range(copy(element, kAXSelectedTextRangeAttribute)))
    }
    static func range(pid: pid_t, label: String, at point: CGPoint) throws -> NSRange? {
        let element = try find(pid: pid, label: label)
        var point = point
        return range(copy(element, kAXRangeForPositionParameterizedAttribute, AXValueCreate(.cgPoint, &point)!))
    }
    struct Large: Sendable { var value: String?, characters: Int?, farLine: String?, lineOfFarOffset: Int? }
    static func readLarge(pid: pid_t, label: String, offset: Int) throws -> Large {
        let element = try find(pid: pid, label: label)
        var large = Large()
        large.value = copy(element, kAXValueAttribute) as? String
        large.characters = copy(element, kAXNumberOfCharactersAttribute) as? Int
        large.lineOfFarOffset = copy(element, kAXLineForIndexParameterizedAttribute, NSNumber(value: offset)) as? Int
        if let line = large.lineOfFarOffset, let range = range(copy(element, kAXRangeForLineParameterizedAttribute, NSNumber(value: line))) {
            large.farLine = copy(element, kAXStringForRangeParameterizedAttribute, rangeValue(range)) as? String
        }
        return large
    }
}
