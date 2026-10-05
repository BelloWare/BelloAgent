import XCTest
import AppKit
@testable import PiApp

/// The cursor a terminal shows is where the next typed character lands: in
/// the emulator, against a real zsh line editor and full-screen programs,
/// and in the pixels the view draws.
final class TerminalCursorAlignmentTests: XCTestCase {

    // MARK: Drawing: the cursor and the next glyph share a cell

    /// Pixels of one rendering, as RGBA bytes, with the scale they were drawn at.
    private struct Rendering {
        let width: Int, height: Int, scale: CGFloat
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
    }
    @MainActor private func render(_ view: TerminalView, scale: CGFloat) throws -> Rendering {
        let size = view.bounds.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.bitmapData)
        return Rendering(width: width, height: height, scale: scale, bytes: Array(UnsafeBufferPointer(start: data, count: width * height * 4)))
    }
    /// Columns (in pixels) inside rows `top..<bottom` where `test` holds.
    private func columns(_ rendering: Rendering, rows: Range<Int>, where test: (Int, Int) -> Bool) -> ClosedRange<Int>? {
        var low = Int.max, high = Int.min
        for y in rows where y >= 0 && y < rendering.height {
            for x in 0..<rendering.width where test(x, y) { low = min(low, x); high = max(high, x) }
        }
        return low <= high ? low...high : nil
    }
    private func differs(_ a: Rendering, _ b: Rendering, _ x: Int, _ y: Int) -> Bool {
        let p = a.pixel(x, y), q = b.pixel(x, y)
        return abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 60
    }

    /// Types `typed` after `prompt`, and checks that the block cursor drawn
    /// before the next character covers the ink of that character drawn after.
    @MainActor private func assertNextGlyphFillsTheCursor(prompt: String, typed: String = "W", next: String = "W", fontSize: CGFloat, scale: CGFloat,
                                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let terminal = TerminalEmulator(columns: 80, rows: 4)
        let view = TerminalView(emulator: terminal, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 120)
        view.layoutSubtreeIfNeeded()
        _ = view.becomeFirstResponder()
        terminal.feed(prompt + typed)
        let cursor = terminal.cursor
        view.refresh()
        let withCursor = try render(view, scale: scale)
        terminal.feed("\u{1b}[?25l"); view.refresh()
        let before = try render(view, scale: scale)
        terminal.feed(next); view.refresh()
        let after = try render(view, scale: scale)
        XCTAssertEqual(terminal.cursor.x, cursor.x + 1, "the next character takes the cursor's cell", file: file, line: line)

        // The row the cursor is on, a pixel short of its top and bottom.
        let band = (0..<withCursor.height).filter { y in (0..<withCursor.width).contains { differs(withCursor, before, $0, y) } }
        let rows = (band.min() ?? 0)..<((band.max() ?? 0) + 1)
        let drawnCursor = try XCTUnwrap(columns(withCursor, rows: rows) { differs(withCursor, before, $0, $1) }, "no cursor was drawn", file: file, line: line)
        let glyph = try XCTUnwrap(columns(after, rows: rows) { differs(after, before, $0, $1) }, "no glyph was drawn", file: file, line: line)
        let slack = Int(ceil(scale))   // antialiasing at either edge
        XCTAssertGreaterThanOrEqual(glyph.lowerBound, drawnCursor.lowerBound - slack,
                                    "\(fontSize)pt @\(scale)x: the glyph starts left of the cursor (glyph \(glyph), cursor \(drawnCursor))", file: file, line: line)
        XCTAssertLessThanOrEqual(glyph.upperBound, drawnCursor.upperBound + slack,
                                 "\(fontSize)pt @\(scale)x: the glyph ends right of the cursor (glyph \(glyph), cursor \(drawnCursor))", file: file, line: line)
    }

    @MainActor func testTheCursorSitsWhereTheNextGlyphIsDrawnAtEveryFontSizeAndScale() throws {
        for scale: CGFloat in [1, 2] {
            for size: CGFloat in [10, 11, 12, 13, 14, 16, 18] {
                try assertNextGlyphFillsTheCursor(prompt: "admin@mac pi-app % ", typed: "echo hello world and more", fontSize: size, scale: scale)
            }
        }
    }

    @MainActor func testTheCursorFollowsColouredRunsWideCharactersAndPowerlineGlyphs() throws {
        let prompts = [
            "\u{1b}[1;32madmin@mac\u{1b}[0m \u{1b}[34mpi-app\u{1b}[0m % ",           // colours and bold
            "\u{1b}[44m main \u{1b}[0m\u{1b}[34m\u{e0b0}\u{1b}[0m ",                    // a Powerline arrow
            "漢字 😀 ✅ % ",                                                            // wide characters
            "cafe\u{301} \u{1b}[7m e\u{301}\u{1b}[0m % ",                               // combining marks
        ]
        for prompt in prompts {
            for scale: CGFloat in [1, 2] { try assertNextGlyphFillsTheCursor(prompt: prompt, typed: "git status", fontSize: 12, scale: scale) }
        }
    }

    @MainActor func testTheCursorOverAWideCharacterCoversBothCells() throws {
        let terminal = TerminalEmulator(columns: 40, rows: 3)
        let view = TerminalView(emulator: terminal)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        view.layoutSubtreeIfNeeded()
        _ = view.becomeFirstResponder()
        // The text after the wide characters is an ASCII run, drawn as one line.
        terminal.feed("ab漢字cdefghijklmnop\u{1b}[3G")
        view.refresh()
        XCTAssertEqual(terminal.cursor.x, 2)
        let withCursor = try render(view, scale: 2)
        terminal.feed("\u{1b}[?25l"); view.refresh()
        let hidden = try render(view, scale: 2)
        terminal.feed("\u{1b}[?25h\u{1b}[18G"); view.refresh()
        let atP = try render(view, scale: 2)
        let wide = try XCTUnwrap(columns(withCursor, rows: 0..<withCursor.height) { differs(withCursor, hidden, $0, $1) })
        let narrow = try XCTUnwrap(columns(atP, rows: 0..<atP.height) { differs(atP, hidden, $0, $1) })
        let cell = Double(narrow.count)
        XCTAssertEqual(Double(wide.count), cell * 2, accuracy: 3, "a cursor on a wide character covers its two cells")
        XCTAssertEqual(Double(narrow.lowerBound - wide.lowerBound), cell * 15, accuracy: 3,
                       "the cursor on column 18 sits fifteen cells right of the one on column 3")
    }

    // MARK: Widths the shell agrees with

    func testEmojiModifiersAndTextPictographsTakeTheWidthsTheShellGivesThem() {
        // zsh's line editor counts these widths when it moves the cursor; a
        // terminal that counts others draws the cursor away from the input.
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f3fd}"), 2, "a skin tone modifier is a wide character of its own")
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f322}"), 1, "a pictograph that is no emoji is narrow")
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f6e6}"), 1)
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f5a5}"), 2, "an emoji is wide even without emoji presentation, as zsh counts it")
        XCTAssertEqual(TerminalEmulator.width(of: "\u{3248}"), 1, "circled numbers on black squares are ambiguous, so narrow")
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f600}"), 2)
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f9e0}"), 2)
        XCTAssertEqual(TerminalEmulator.width(of: "\u{1f680}"), 2)
        XCTAssertEqual(TerminalEmulator.width(of: "漢"), 2)
        XCTAssertEqual(TerminalEmulator.width(of: "\u{e0b0}"), 1)
        XCTAssertEqual(TerminalEmulator.width(of: "\u{301}"), 0)
        XCTAssertEqual(TerminalEmulator.width(of: "\u{fe0f}"), 0)
        let terminal = TerminalEmulator(columns: 20, rows: 2)
        terminal.feed("👍🏽x")
        XCTAssertEqual(terminal.cursor.x, 5, "the thumb, its modifier and x take five cells")
        terminal.feed("\u{8}\u{8}\u{8}Z")
        XCTAssertEqual(terminal.text(ofRow: 0), "👍Z x", "three backspaces from after x reach the modifier, as zsh counts them; Z covers its first cell")
    }

    func testAModifiedEmojiComesBackFromHistoryInItsOwnCells() {
        let terminal = TerminalEmulator(columns: 12, rows: 1, scrollbackLimit: 10)
        terminal.feed("👍\u{1b}[31m🏽\u{1b}[0mX ok\r\n")
        let line = terminal.scrollback[0].cells
        XCTAssertEqual(line.prefix(6).map(\.text), ["👍", "", "🏽", "", "X", " "], "the X stays in the fifth cell, where the cursor counted it")
        XCTAssertEqual(line[2].style.foreground, .indexed(1))
    }

    func testWritingIntoHalfAWideCharacterShowsWhatWasWritten() {
        for sequence in ["\u{1b}[2G\u{1b}[@X", "\u{1b}[2G\u{1b}[PX", "\u{1b}[2G\u{1b}[XX", "\u{1b}[2G\u{1b}[1KX"] {
            let terminal = TerminalEmulator(columns: 10, rows: 1)
            terminal.feed("漢ab" + sequence)
            let row = terminal.screen[0]
            XCTAssertEqual(row[1].text, "X", sequence)
            XCTAssertEqual(row[1].width, 1, sequence)
            XCTAssertNotEqual(row[0].width, 2, "\(sequence): a leading half without its trailing half would hide the X")
            for (x, cell) in row.enumerated() where cell.width == 2 { XCTAssertEqual(row[x + 1].width, 0, sequence) }
            for (x, cell) in row.enumerated() where cell.width == 0 { XCTAssertEqual(row[x - 1].width, 2, sequence) }
        }
    }

    func testRestoringTheCursorOrChangingItsShapeRedrawsItsRows() {
        let terminal = TerminalEmulator(columns: 10, rows: 4)
        terminal.feed("\u{1b}[1;3H\u{1b}[s\u{1b}[4;5H")
        terminal.clearDirty()
        terminal.feed("\u{1b}[u")
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 2, y: 0))
        XCTAssertEqual(terminal.dirtyRows.map { Set($0) }, Set([0, 3]), "the row the cursor left and the row it returns to are redrawn")
        terminal.clearDirty()
        terminal.feed("\u{1b}[5 q")
        XCTAssertEqual(terminal.cursorShape, .bar)
        XCTAssertEqual(terminal.dirtyRows.map { Set($0) }, Set([0]), "a new cursor shape is drawn")
    }

    @MainActor func testTheInputMethodAnchorIsTheCursorCell() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        let terminal = TerminalEmulator(columns: 40, rows: 6)
        let view = TerminalView(emulator: terminal)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        terminal.feed("% ")
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        XCTAssertLessThan(frame.maxY - rect.maxY, 20, "the candidate window follows the cursor on the top row, not the bottom: \(rect) in \(frame)")
        XCTAssertGreaterThan(rect.minX, frame.minX + 8)
    }

    @MainActor func testAFontWhoseLettersDifferInWidthStillDrawsEachOnItsCell() throws {
        let font = try XCTUnwrap(NSFont(name: "Times New Roman", size: 12) ?? NSFont(name: "Helvetica", size: 12))
        let terminal = TerminalEmulator(columns: 40, rows: 2)
        let view = TerminalView(emulator: terminal, font: font)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        view.layoutSubtreeIfNeeded()
        _ = view.becomeFirstResponder()
        terminal.feed("WWWWWWWiiiiiii")
        view.refresh()
        let withCursor = try render(view, scale: 2)
        terminal.feed("\u{1b}[?25l"); view.refresh()
        let before = try render(view, scale: 2)
        terminal.feed("W"); view.refresh()
        let after = try render(view, scale: 2)
        let drawnCursor = try XCTUnwrap(columns(withCursor, rows: 0..<withCursor.height) { differs(withCursor, before, $0, $1) })
        let glyph = try XCTUnwrap(columns(after, rows: 0..<after.height) { differs(after, before, $0, $1) })
        XCTAssertGreaterThanOrEqual(glyph.lowerBound, drawnCursor.lowerBound - 4, "glyph \(glyph), cursor \(drawnCursor)")
        XCTAssertLessThanOrEqual(glyph.lowerBound, drawnCursor.upperBound, "glyph \(glyph), cursor \(drawnCursor)")
    }

    // MARK: A real shell: the next character lands on the cursor

    /// A zsh with the system's startup files and a prompt of the test's
    /// choosing, its output fed to an emulator.
    @MainActor private final class Shell {
        let terminal: TerminalEmulator
        let process = PseudoTerminal()
        private(set) var output = Data()
        private var lastOutput = ProcessInfo.processInfo.systemUptime
        let home: URL
        init(prompt: String, columns: Int = 60, rows: Int = 12) throws {
            terminal = TerminalEmulator(columns: columns, rows: rows)
            home = FileManager.default.temporaryDirectory.appendingPathComponent("pi-term-cursor-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let rc = """
            PS1=$'\(prompt)'
            RPS1=''
            unsetopt PROMPT_SP
            setopt EXTENDED_GLOB
            HISTFILE=/dev/null
            # Where the line editor believes its cursor is: the prompt's cells
            # and the cells of the text before the cursor, as zsh counts them.
            _pi_where() {
              local p=${(%)PS1}
              p=${p//$'\\e'\\[[0-9;]#m/}
              print -r -- $(( ${(m)#p} + ${(m)#LBUFFER} )) > $HOME/where.tmp && mv $HOME/where.tmp $HOME/where
            }
            zle -N _pi_where
            bindkey '^X^W' _pi_where
            """
            try rc.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            terminal.onOutput = { [process] in process.write($0) }
            process.onData = { [weak self] data in
                guard let self else { return }
                self.output.append(data); self.lastOutput = ProcessInfo.processInfo.systemUptime
                self.terminal.feed(data)
            }
            try process.start(executable: "/bin/zsh", arguments: ["zsh", "-i"],
                              environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "ZDOTDIR": home.path, "HOME": home.path],
                              directory: home.path, columns: columns, rows: rows)
        }
        deinit { try? FileManager.default.removeItem(at: home) }
        /// Waits until the shell has written something and then been quiet for a moment.
        func settle(_ timeout: TimeInterval = 10) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            let seen = output.count
            while ProcessInfo.processInfo.systemUptime - start < timeout {
                try await Task.sleep(for: .milliseconds(20))
                if ProcessInfo.processInfo.systemUptime - lastOutput > 0.25, output.count > seen || ProcessInfo.processInfo.systemUptime - start > 1 { return }
            }
        }
        func type(_ text: String) async throws { process.write(Data(text.utf8)); try await settle() }
        func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 10) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            while !condition(), ProcessInfo.processInfo.systemUptime - start < timeout { try await Task.sleep(for: .milliseconds(20)) }
        }
        /// The column the line editor believes its cursor is at, counted from the prompt's start.
        func editorColumn() async throws -> Int? {
            let file = home.appendingPathComponent("where")
            try? FileManager.default.removeItem(at: file)
            process.write(Data("\u{18}\u{17}".utf8))
            try await waitFor { FileManager.default.fileExists(atPath: file.path) }
            return (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        func resize(columns: Int, rows: Int) { terminal.resize(columns: columns, rows: rows); process.resize(columns: columns, rows: rows) }
        func end() { process.terminate() }
    }

    /// The cursor is where the line editor believes it is (unless `editing`
    /// is false, for a full-screen program), and the next character typed
    /// appears in the cell the cursor is on.
    @MainActor private func assertNextCharacterLandsOnTheCursor(_ shell: Shell, _ context: String, editing: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws {
        let cursor = shell.terminal.cursor
        if editing {
            let believed = try await shell.editorColumn()
            XCTAssertEqual(cursor.x, believed.map { $0 % shell.terminal.columns }, "\(context): the cursor is drawn at column \(cursor.x), but zsh's line editor puts its cursor at \(believed.map(String.init) ?? "?"):\n\(shell.terminal.screenText)", file: file, line: line)
        }
        try await shell.type("Q")
        let cell = shell.terminal.screen[cursor.y][cursor.x]
        XCTAssertEqual(cell.text, "Q", "\(context): Q was typed with the cursor at column \(cursor.x), row \(cursor.y), but landed elsewhere:\n\(shell.terminal.screenText)", file: file, line: line)
    }

    @MainActor func testZshPlacesTypedCharactersOnTheCursorAfterPromptsAndLineEditing() async throws {
        let prompts = [
            "%n@%m %1~ %# ",
            "%F{green}%B%n%b%f %F{blue}\\ue0b0%f %F{yellow}漢字%f 😀 ✅ cafe\\u0301 ❯ ",
        ]
        for prompt in prompts {
            let shell = try Shell(prompt: prompt)
            defer { shell.end() }
            try await shell.settle()
            try await shell.type("echo hello")
            try await assertNextCharacterLandsOnTheCursor(shell, "after the prompt \(prompt)")
            // Wide, combining and modified characters in the line, then editing across them.
            try await shell.type(" 漢字 e\u{301} 👍🏽 x")
            try await assertNextCharacterLandsOnTheCursor(shell, "after wide characters")
            try await shell.type("\u{1b}[D\u{1b}[D\u{1b}[D")
            try await assertNextCharacterLandsOnTheCursor(shell, "after moving left over a modified emoji")
            try await shell.type("\u{1b}[D\u{1b}[D\u{1b}[D\u{1b}[D\u{7f}")
            try await assertNextCharacterLandsOnTheCursor(shell, "after Backspace over a combining character")
            try await shell.type("\u{1b}[D\u{1b}[D\u{1b}[D\u{7f}\u{7f}")
            try await assertNextCharacterLandsOnTheCursor(shell, "after Backspace over wide characters")
            try await shell.type("\u{1}")
            try await assertNextCharacterLandsOnTheCursor(shell, "at the start of the line")
            try await shell.type("\u{5}")
            try await assertNextCharacterLandsOnTheCursor(shell, "at the end of the line")
        }
    }

    @MainActor func testZshPlacesTypedCharactersOnTheCursorAfterClearResizeAndAtTheRightEdge() async throws {
        let shell = try Shell(prompt: "%F{red}❯%f ", columns: 30, rows: 8)
        defer { shell.end() }
        try await shell.settle()
        try await shell.type("echo one\r")
        try await shell.type("clear\r")
        try await shell.waitFor { shell.terminal.text(ofRow: 0).hasPrefix("❯") }
        try await assertNextCharacterLandsOnTheCursor(shell, "after clear")
        try await shell.type("\u{15}")
        // A line that fills the row exactly: the prompt's two cells and 28 more.
        try await shell.type(String(repeating: "a", count: 27))
        let row = shell.terminal.cursor.y
        try await assertNextCharacterLandsOnTheCursor(shell, "one cell from the right edge")
        // The row is exactly full now; the next character starts the next row.
        XCTAssertEqual(shell.terminal.text(ofRow: row).count, 30)
        try await assertNextCharacterLandsOnTheCursor(shell, "with the row exactly full")
        XCTAssertEqual(shell.terminal.cursor, TerminalCursor(x: 1, y: row + 1), "after the edge the input continues on the next row:\n\(shell.terminal.screenText)")
        try await shell.type("\u{15}echo resized")
        shell.resize(columns: 50, rows: 10)
        try await shell.settle()
        try await assertNextCharacterLandsOnTheCursor(shell, "after the window grew")
        shell.resize(columns: 24, rows: 6)
        try await shell.settle()
        try await assertNextCharacterLandsOnTheCursor(shell, "after the window shrank")
    }

    @MainActor func testFullScreenProgramsPutTheCursorWhereTheyInsert() async throws {
        let shell = try Shell(prompt: "%# ", columns: 40, rows: 10)
        defer { shell.end() }
        try await shell.settle()
        let file = shell.home.appendingPathComponent("notes.txt")
        try "first line\n漢字 wide line\nthird\n".write(to: file, atomically: true, encoding: .utf8)
        try await shell.type("vim -u NONE -N notes.txt\r")
        try await shell.waitFor { shell.terminal.alternateScreen && shell.terminal.text(ofRow: 1).hasPrefix("漢字") }
        XCTAssertTrue(shell.terminal.alternateScreen, "vim runs in the alternate screen:\n\(shell.terminal.screenText)")
        try await shell.settle()
        try await shell.type("j$")      // the end of the wide line
        XCTAssertEqual(shell.terminal.cursor.y, 1)
        XCTAssertEqual(shell.terminal.cursor.x, 13, "vim's cursor is on the last character, after the two wide ones:\n\(shell.terminal.screenText)")
        try await shell.type("0w")      // the word after the wide characters
        XCTAssertEqual(shell.terminal.cursor.x, 5)
        try await shell.type("i")
        try await assertNextCharacterLandsOnTheCursor(shell, "inserting in vim after wide characters", editing: false)
        try await shell.type("\u{1b}:q!\r")
        try await shell.waitFor { !shell.terminal.alternateScreen }
        XCTAssertFalse(shell.terminal.alternateScreen)
        try await shell.settle()
        try await assertNextCharacterLandsOnTheCursor(shell, "back at the prompt after vim")
    }

    // MARK: Hidden and shown again

    func testLinesBackFromHistoryKeepTheirTextWhenTheWindowGrows() {
        let terminal = TerminalEmulator(columns: 20, rows: 4)
        terminal.feed("first long line\r\nsecond long line\r\nthird\r\n% ")
        terminal.resize(columns: 5, rows: 1)
        terminal.resize(columns: 20, rows: 4)
        XCTAssertEqual(terminal.text(ofRow: 0), "first long line", "a line that went to history whole comes back whole")
        XCTAssertEqual(terminal.text(ofRow: 1), "second long line")
        XCTAssertEqual(terminal.cursor, TerminalCursor(x: 2, y: 3))
    }

    @MainActor func testATerminalHiddenAtZeroSizeKeepsItsScreenAndCursor() {
        let terminal = TerminalEmulator(columns: 80, rows: 4)
        let view = TerminalView(emulator: terminal)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        view.layoutSubtreeIfNeeded()
        let columns = terminal.columns, rows = terminal.rows
        terminal.feed("line one\r\nline two\r\nadmin@mac pi-app % echo hi")
        let cursor = terminal.cursor
        let screen = terminal.screenText
        var sizes: [String] = []
        view.onResize = { sizes.append("\($0)x\($1)") }
        // A tab switch or a collapsing panel can lay the view out at no size before it shows again.
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.columns, columns); XCTAssertEqual(terminal.rows, rows)
        XCTAssertEqual(terminal.screenText, screen, "the screen survives being laid out at no size")
        XCTAssertEqual(terminal.cursor, cursor)
        XCTAssertEqual(sizes, [], "the shell is not told its window shrank to nothing")
    }
}
