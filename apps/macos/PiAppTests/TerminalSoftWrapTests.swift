import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalSoftWrapTests: XCTestCase {
    private func copied(_ text: String, columns: Int = 80, rows: Int = 4) -> String? {
        let emulator = TerminalEmulator(columns: columns, rows: rows)
        let view = TerminalView(emulator: emulator)
        emulator.feed(text)
        view.selectAll(nil)
        return view.selectedText
    }

    func testCopyJoinsAutomaticWrapsAndPreservesExplicitLineBreaks() {
        let text = String(repeating: "a", count: 81)
        XCTAssertEqual(copied(text), text)
        XCTAssertEqual(copied(String(repeating: "a", count: 80) + "\r\nb"), String(repeating: "a", count: 80) + "\nb")
        XCTAssertEqual(copied("first\r\nsecond"), "first\nsecond")
    }

    func testCopyPreservesBoundarySpacesAndOmitsWideCharacterPadding() {
        let spaces = String(repeating: "x", count: 78) + "  tail"
        XCTAssertEqual(copied(spaces), spaces)
        let wide = String(repeating: "x", count: 79) + "中e\u{301}tail"
        XCTAssertEqual(copied(wide), wide)
    }

    func testSoftWrapsSurviveHistoryAndSplitFeeds() {
        let emulator = TerminalEmulator(columns: 8, rows: 2)
        let view = TerminalView(emulator: emulator)
        let text = "https://example.test/a/very/long/path"
        for byte in text.utf8 { emulator.feed(Data([byte])) }
        XCTAssertFalse(emulator.scrollback.isEmpty)
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, text)
    }

    func testWrapBoundariesSurviveColumnGrowthAndHistoryRestoration() {
        let emulator = TerminalEmulator(columns: 8, rows: 2)
        let view = TerminalView(emulator: emulator)
        let text = "123456  abcdefghijklmnop"
        emulator.feed(text)
        emulator.resize(columns: 12, rows: 4)
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, text, "new padding is not part of the original wrapped text")
        emulator.resize(columns: 12, rows: 1)
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, text, "rearchiving preserves the logical boundary and significant spaces")
    }

    func testErasingAndDeletingRowsBreakObsoleteWrapConnections() {
        let emulator = TerminalEmulator(columns: 4, rows: 5)
        let view = TerminalView(emulator: emulator)
        emulator.feed("abcdef\r\ntail")
        emulator.feed("\u{1b}[2;1H\u{1b}[M")
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "abcd\ntail", "deleting the continuation breaks the join")
        emulator.feed("\u{1b}[H\u{1b}[2Knew")
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "new\ntail")
    }

    func testInsertedRowsMoveWrapMetadataWithTheirCells() {
        let emulator = TerminalEmulator(columns: 4, rows: 5)
        let view = TerminalView(emulator: emulator)
        emulator.feed("abcdef")
        emulator.feed("\u{1b}[H\u{1b}[L")
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "\nabcdef")
        emulator.feed("\u{1b}[M")
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "abcdef")
    }

    func testAlternateScreenCopiesOnlyItsOwnRowsAndRestoresNormalWraps() {
        let emulator = TerminalEmulator(columns: 8, rows: 2)
        let view = TerminalView(emulator: emulator)
        let normal = "normal history wrapped across several rows"
        emulator.feed(normal)
        emulator.feed("\u{1b}[?1049h\u{1b}[Halternate text")
        view.refresh(); view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "alternate text")
        emulator.feed("\u{1b}[?1049l")
        view.refresh(); view.selectAll(nil)
        XCTAssertEqual(view.selectedText, normal)
    }

    func testErasingTheScreenBreaksTheHistoryJoinBeforeNewContent() {
        let emulator = TerminalEmulator(columns: 4, rows: 2)
        let view = TerminalView(emulator: emulator)
        emulator.feed("abcdefghij")
        emulator.feed("\u{1b}[2J\u{1b}[HNEW")
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "abcd\nNEW")
        emulator.resize(columns: 6, rows: 3)
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "abcd\nNEW", "the broken join stays broken when history returns to the grid")
    }
}
