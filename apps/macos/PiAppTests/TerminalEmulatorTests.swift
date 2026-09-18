import XCTest
import AppKit
@testable import PiApp

/// The app's own terminal: the VT parser and grid, the keys it sends, and the
/// pseudo-terminal that runs a real shell with job control.
final class TerminalEmulatorTests: XCTestCase {
    private func emulator(_ columns: Int = 20, _ rows: Int = 5) -> TerminalEmulator { TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 100) }
    private func rows(_ terminal: TerminalEmulator) -> [String] { (0..<terminal.rows).map { terminal.text(ofRow: $0) } }

    func testPrintingWrapsScrollsAndKeepsScrollback() {
        let terminal = emulator(10, 3)
        terminal.feed("hello world!\r\nline two\r\nline three\r\nline four")
        XCTAssertEqual(rows(terminal), ["line two", "line three", "line four"])
        XCTAssertEqual(terminal.scrollback.map(TerminalEmulator.text(of:)), ["hello worl", "d!"], "a wrapped line scrolls off in two pieces")
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 9, y: 2))
        terminal.feed("\u{1b}[?7l")
        terminal.feed("\r\nabcdefghijklmnop")
        XCTAssertEqual(terminal.text(ofRow: 2), "abcdefghip", "without autowrap the last column overwrites")
        XCTAssertEqual(terminal.scrollback.count, 3)
    }

    func testCursorMovementErasingAndEditing() {
        let terminal = emulator(10, 4)
        terminal.feed("abcdefghij\r\n1234567890\r\nxyz")
        terminal.feed("\u{1b}[1;1H\u{1b}[K")                    // erase first row to the right
        XCTAssertEqual(terminal.text(ofRow: 0), "")
        terminal.feed("\u{1b}[2;5H\u{1b}[2P")                   // delete two characters in row 2
        XCTAssertEqual(terminal.text(ofRow: 1), "12347890")
        terminal.feed("\u{1b}[2;1H\u{1b}[2@AB")                 // insert two blanks then type over them
        XCTAssertEqual(terminal.text(ofRow: 1), "AB12347890")
        terminal.feed("\u{1b}[3;2H\u{1b}[X")                    // erase one character
        XCTAssertEqual(terminal.text(ofRow: 2), "x z")
        terminal.feed("\u{1b}[2;1H\u{1b}[L")                    // insert a line above row 2
        XCTAssertEqual(rows(terminal), ["", "", "AB12347890", "x z"])
        terminal.feed("\u{1b}[M")                               // delete it again
        XCTAssertEqual(rows(terminal), ["", "AB12347890", "x z", ""])
        terminal.feed("\u{1b}[4;3H\u{1b}[1J")                   // erase above and to the left
        XCTAssertEqual(rows(terminal), ["", "", "", ""])
        terminal.feed("\u{1b}[H\u{1b}[2A\u{1b}[5C\u{1b}[3D")    // moves clamp to the screen
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 2, y: 0))
        terminal.feed("\u{1b}[3;3H\u{1b}[6n")                   // cursor position report
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 2, y: 2))
    }

    func testScrollRegionOriginModeAndReverseIndex() {
        let terminal = emulator(10, 5)
        terminal.feed("\u{1b}[2;4r")                            // rows 2-4 scroll
        terminal.feed("\u{1b}[1;1Htop\u{1b}[5;1Hbottom")
        terminal.feed("\u{1b}[2;1Ha\r\nb\r\nc\r\nd\r\ne")
        XCTAssertEqual(rows(terminal), ["top", "c", "d", "e", "bottom"], "scrolling stays inside the region")
        XCTAssertTrue(terminal.scrollback.isEmpty, "lines leaving an inner region are not history")
        terminal.feed("\u{1b}[?6h\u{1b}[HZ")                    // origin mode: home is the region's top
        XCTAssertEqual(terminal.text(ofRow: 1), "Z")
        terminal.feed("\u{1b}M\u{1b}M")                         // reverse index at the region top scrolls down, twice
        XCTAssertEqual(rows(terminal), ["top", "", "", "Z", "bottom"])
        terminal.feed("\u{1b}[r")
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 0, y: 0))
    }

    func testGraphicRenditionsInEveryColourForm() {
        let terminal = emulator(40, 2)
        terminal.feed("\u{1b}[1;3;4;31mA\u{1b}[0m\u{1b}[38;5;208mB\u{1b}[48;2;10;20;30mC\u{1b}[38:2::1:2:3mD\u{1b}[7;9;2mE\u{1b}[22;27;29;39;49mF\u{1b}[94;100mG")
        let cells = terminal.screen[0]
        XCTAssertEqual(cells[0].style, CellStyle(foreground: .indexed(1), bold: true, italic: true, underline: true))
        XCTAssertEqual(cells[1].style, CellStyle(foreground: .indexed(208)))
        XCTAssertEqual(cells[2].style, CellStyle(foreground: .indexed(208), background: .rgb(10, 20, 30)))
        XCTAssertEqual(cells[3].style, CellStyle(foreground: .rgb(1, 2, 3), background: .rgb(10, 20, 30)))
        XCTAssertEqual(cells[4].style, CellStyle(foreground: .rgb(1, 2, 3), background: .rgb(10, 20, 30), dim: true, inverse: true, strikethrough: true))
        XCTAssertEqual(cells[5].style, .plain)
        XCTAssertEqual(cells[6].style, CellStyle(foreground: .indexed(12), background: .indexed(8)))
        terminal.feed("\u{1b}[44m\u{1b}[K")
        XCTAssertEqual(terminal.screen[0][20].style, CellStyle(background: .indexed(4)), "erasing paints the current background")
    }

    func testWideCharactersCombiningMarksAndSplitUTF8() {
        let terminal = emulator(6, 3)
        let bytes = Array("中文e\u{301}!".utf8)
        terminal.feed(Data(bytes[0..<2])); terminal.feed(Data(bytes[2...]))
        XCTAssertEqual(terminal.screen[0].map(\.width), [2, 0, 2, 0, 1, 1])
        XCTAssertEqual(terminal.screen[0][4].text, "e\u{301}", "the combining acute joins its base")
        XCTAssertEqual(terminal.text(ofRow: 0), "中文e\u{301}!")
        terminal.feed("\r\n12345中")
        XCTAssertEqual(terminal.text(ofRow: 1), "12345", "a wide character never splits across the edge")
        XCTAssertEqual(terminal.text(ofRow: 2), "中"); XCTAssertEqual(terminal.cursor, TerminalCursor(x: 2, y: 2))
        terminal.feed("\u{1b}[1;2HX")
        XCTAssertEqual(terminal.screen[0][0].text, " ", "overwriting half a wide character clears the other half")
        XCTAssertEqual(TerminalEmulator.width(of: "🌍"), 2); XCTAssertEqual(TerminalEmulator.width(of: "a"), 1); XCTAssertEqual(TerminalEmulator.width(of: "\u{200d}"), 0)
    }

    func testAlternateScreenModesRepliesAndTitles() {
        let terminal = emulator(12, 3)
        var replies = Data(), titles: [String] = []
        terminal.onOutput = { replies.append($0) }; terminal.onTitleChange = { titles.append($0) }
        terminal.feed("main text\r\n")
        terminal.feed("\u{1b}[?1049h\u{1b}[Halt\u{1b}[?25l\u{1b}[?2004h\u{1b}[?1h\u{1b}=")
        XCTAssertTrue(terminal.alternateScreen); XCTAssertEqual(rows(terminal), ["alt", "", ""])
        XCTAssertFalse(terminal.cursorVisible); XCTAssertTrue(terminal.bracketedPaste); XCTAssertTrue(terminal.applicationCursorKeys); XCTAssertTrue(terminal.applicationKeypad)
        terminal.feed("\u{1b}[?2004$p\u{1b}[c\u{1b}[5n\u{1b}[18t\u{1b}]11;?\u{1b}\\")
        terminal.feed("\u{1b}[?1049l\u{1b}[?25h")
        XCTAssertFalse(terminal.alternateScreen); XCTAssertEqual(rows(terminal), ["main text", "", ""]); XCTAssertEqual(terminal.cursor, TerminalCursor(x: 0, y: 1))
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1b}[?2004;1$y\u{1b}[?62;22c\u{1b}[0n\u{1b}[8;3;12t\u{1b}]11;rgb:f7f7/f2f2/ecec\u{1b}\\")
        terminal.feed("\u{1b}]0;my shell\u{07}\u{1b}]2;renamed\u{1b}\\")
        XCTAssertEqual(titles, ["my shell", "renamed"]); XCTAssertEqual(terminal.title, "renamed")
        terminal.feed("\u{1b}]7;file://host/Users/me/project\u{07}")
        XCTAssertEqual(terminal.currentDirectory, "/Users/me/project")
    }

    func testTabsRepeatsLineDrawingAndAlignment() {
        let terminal = emulator(20, 2)
        terminal.feed("a\tb\tc")
        XCTAssertEqual(terminal.cursor.x, 17); XCTAssertEqual(terminal.screen[0][8].text, "b"); XCTAssertEqual(terminal.screen[0][16].text, "c")
        terminal.feed("\r\u{1b}[3g\u{1b}[5G\u{1b}H\r\tX")
        XCTAssertEqual(terminal.screen[0][4].text, "X", "a custom tab stop after clearing them all")
        terminal.feed("\u{1b}[Z")
        XCTAssertEqual(terminal.cursor.x, 4, "back-tab returns to the stop")
        terminal.feed("\r\n=\u{1b}[3b")
        XCTAssertEqual(terminal.text(ofRow: 1), "====", "REP repeats the last character")
        terminal.feed("\u{1b}(0lqk\u{1b}(B")
        XCTAssertEqual(terminal.text(ofRow: 1), "====┌─┐", "DEC special graphics draw boxes")
        terminal.feed("\u{1b}#8")
        XCTAssertEqual(terminal.text(ofRow: 0), String(repeating: "E", count: 20))
    }

    func testResizeKeepsContentAndReflowsHistory() {
        let terminal = emulator(10, 4)
        terminal.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive")
        XCTAssertEqual(rows(terminal), ["two", "three", "four", "five"]); XCTAssertEqual(terminal.scrollback.count, 1)
        terminal.resize(columns: 8, rows: 2)
        XCTAssertEqual(rows(terminal), ["four", "five"]); XCTAssertEqual(terminal.scrollback.map(TerminalEmulator.text(of:)), ["one", "two", "three"])
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 4, y: 1))
        terminal.resize(columns: 8, rows: 5)
        XCTAssertEqual(rows(terminal), ["one", "two", "three", "four", "five"], "history comes back when the screen grows")
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 4, y: 4)); XCTAssertTrue(terminal.scrollback.isEmpty)
        terminal.feed("\u{1b}[?1049h\u{1b}[Hxyz")
        terminal.resize(columns: 6, rows: 3)
        XCTAssertEqual(rows(terminal), ["xyz", "", ""], "the alternate screen simply fits, dropping blank rows first")
        terminal.feed("\u{1b}[?1049l")
        XCTAssertEqual(terminal.rows, 3); XCTAssertEqual(terminal.columns, 6)
    }

    func testKeysHonourApplicationModesAndModifiers() {
        func text(_ key: TerminalKeyEncoder.Key, app: Bool = false, shift: Bool = false, control: Bool = false, option: Bool = false) -> String {
            String(decoding: TerminalKeyEncoder.encode(key, applicationCursor: app, shift: shift, control: control, option: option), as: UTF8.self)
        }
        XCTAssertEqual(text(.up), "\u{1b}[A"); XCTAssertEqual(text(.up, app: true), "\u{1b}OA"); XCTAssertEqual(text(.up, shift: true), "\u{1b}[1;2A")
        XCTAssertEqual(text(.home, control: true), "\u{1b}[1;5H"); XCTAssertEqual(text(.pageDown, option: true), "\u{1b}[6;3~")
        XCTAssertEqual(text(.function(1)), "\u{1b}OP"); XCTAssertEqual(text(.function(5)), "\u{1b}[15~"); XCTAssertEqual(text(.function(12), shift: true), "\u{1b}[24;2~")
        XCTAssertEqual(text(.backspace), "\u{7f}"); XCTAssertEqual(text(.backspace, option: true), "\u{1b}\u{7f}"); XCTAssertEqual(text(.backTab), "\u{1b}[Z")
    }

    @MainActor func testShellRunsWithAControllingTerminalAndReportsItsSize() async throws {
        let terminal = TerminalEmulator(columns: 60, rows: 12)
        let process = PseudoTerminal()
        var exitCode: Int32?
        process.onData = { terminal.feed($0) }
        process.onExit = { exitCode = $0 }
        try process.start(executable: "/bin/sh", arguments: ["sh", "-c", "tty >/dev/null && echo HASCTTY || echo NOCTTY; stty size; printf 'cwd=%s\\n' \"$PWD\"; exit 3"],
                          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], directory: "/private/tmp", columns: 60, rows: 12)
        for _ in 0..<200 where exitCode == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(exitCode, 3)
        let screen = terminal.screenText
        XCTAssertTrue(screen.contains("HASCTTY"), "the shell must own its terminal for job control: \(screen)")
        XCTAssertTrue(screen.contains("12 60"), "the window size reaches the shell: \(screen)")
        XCTAssertTrue(screen.contains("cwd=/private/tmp"), "the shell starts in the project directory: \(screen)")
    }

    @MainActor func testViewDrawsSelectsAndCopiesWithoutAWindow() {
        let terminal = TerminalEmulator(columns: 20, rows: 3)
        let view = TerminalView(emulator: terminal)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(terminal.columns, 20, "the grid takes the width the view offers")
        terminal.feed("hello brave world\r\nsecond line")
        view.refresh()
        view.selectAll(nil)
        XCTAssertEqual(view.selectedText, "hello brave world\nsecond line")
        var sent = Data()
        view.onInput = { sent.append($0) }
        terminal.feed("\u{1b}[?2004h")
        view.pasteText("ls\n")
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "\u{1b}[200~ls\r\u{1b}[201~")
        let image = NSImage(size: view.bounds.size)
        image.lockFocus(); view.draw(view.bounds); image.unlockFocus()
        XCTAssertEqual(view.accessibilityValue() as? String, terminal.screenText)
    }
}

extension TerminalEmulatorTests {
    /// The panel's own shell start: the login shell with the app's environment must read the user's rc files.
    @MainActor func testPanelShellReadsTheLoginAndRcFiles() async throws {
        let session = TerminalSession(workspaceID: "rc-probe", directory: NSTemporaryDirectory())
        for _ in 0..<200 where !session.emulator.screenText.contains("%") && !session.emulator.screenText.contains("$") { try await Task.sleep(for: .milliseconds(25)) }
        session.process.write(Data("print -r -- MARK1; print -r -- aliases=$(alias | wc -l | tr -d ' ') nvm=$(whence -w nvm 2>&1 | cut -c1-20) brew=$(whence -p brew 2>&1 | cut -c1-40) node=$(whence -p node 2>&1 | cut -c1-60); print -r -- MARK2\n".utf8))
        for _ in 0..<200 where !session.emulator.screenText.contains("MARK2") { try await Task.sleep(for: .milliseconds(25)) }
        let text = session.emulator.screenText
        print("PROBE-RC", text.components(separatedBy: "\n").filter { $0.contains("aliases=") || $0.contains("nvm=") }.joined(separator: " | "))
        print("PROBE-ENV SHELL=\(ProcessInfo.processInfo.environment["SHELL"] ?? "nil") HOME=\(ProcessInfo.processInfo.environment["HOME"] ?? "nil")")
        session.process.write(Data("exit\n".utf8))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(text.contains("MARK2"), text)
    }

    func testAsciiRunsRespectWideCharactersAndTrimmedHistoryStaysCounted() {
        let terminal = emulator(20, 3)
        terminal.feed("中文ab")
        XCTAssertEqual(terminal.text(ofRow: 0), "中文ab"); XCTAssertEqual(terminal.cursor.x, 6)
        terminal.feed("\rx")
        XCTAssertEqual(terminal.line(at: terminal.scrollback.count)[0].text, "x", "an ASCII run over the first half of a wide character")
        XCTAssertEqual(terminal.line(at: terminal.scrollback.count)[1].text, " ", "clears the other half")
        XCTAssertEqual(terminal.text(ofRow: 0), "x 文ab")
        terminal.feed("\u{1b}[4Gy")
        XCTAssertEqual(terminal.text(ofRow: 0), "x  yab", "and over the second half")
        terminal.feed("\r\u{1b}[31mred\u{1b}[0m and \u{1b}[38:2:1:2:3mtrue\u{1b}[m")
        XCTAssertEqual(terminal.text(ofRow: 0), "red and true")
        XCTAssertEqual(terminal.line(at: terminal.scrollback.count)[0].style.foreground, .indexed(1))
        XCTAssertEqual(terminal.line(at: terminal.scrollback.count)[8].style.foreground, .rgb(1, 2, 3), "colon sub-parameters still carry a colour")
        XCTAssertEqual(terminal.line(at: terminal.scrollback.count)[4].style, .plain)
        let history = TerminalEmulator(columns: 20, rows: 2, scrollbackLimit: 100)
        for index in 0..<400 { history.feed("line \(index)\r\n") }
        XCTAssertLessThanOrEqual(history.scrollback.count, 100, "the history never exceeds its limit")
        XCTAssertGreaterThanOrEqual(history.scrollback.count, 96, "and gives up the oldest in small batches")
        XCTAssertEqual(history.scrollback.count + history.trimmedLines, 399, "every line that left the screen is kept or counted")
        XCTAssertEqual(TerminalEmulator.text(of: history.scrollback.last ?? []), "line 398")
    }
}
