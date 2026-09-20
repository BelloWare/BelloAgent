import Foundation

// A terminal emulator written for the app: an xterm-style VT parser over a
// cell grid with scrollback, an alternate screen, scroll regions, tab stops,
// the usual modes and the replies programs ask for. It knows nothing about
// drawing or processes; TerminalView draws it and PseudoTerminal feeds it.
//
// Isolation: deliberately unannotated and deliberately not Sendable. One
// main-actor TerminalSession owns each emulator, and both the view that
// draws it and the pseudo-terminal that feeds it reach the main actor before
// they touch it, which is what lets the parser skip exclusivity checks below.

final class TerminalEmulator {
    // The state every byte touches skips Swift's dynamic exclusivity checks: the emulator is fed from one thread and
    // the checks cost more than the parsing did.
    @exclusivity(unchecked) private(set) var columns: Int
    @exclusivity(unchecked) private(set) var rows: Int
    @exclusivity(unchecked) private(set) var screen: [[TerminalCell]]
    @exclusivity(unchecked) private(set) var scrollback: [TerminalHistoryLine] = []
    /// Lines dropped from the front of the scrollback since the start, so absolute line numbers stay stable.
    private(set) var trimmedLines = 0
    let scrollbackLimit: Int
    @exclusivity(unchecked) private(set) var cursor = TerminalCursor()
    private(set) var cursorVisible = true
    private(set) var cursorShape = TerminalCursorShape.block
    private(set) var title = ""
    private(set) var currentDirectory: String?
    private(set) var applicationCursorKeys = false
    private(set) var applicationKeypad = false
    private(set) var bracketedPaste = false
    private(set) var focusReporting = false
    @exclusivity(unchecked) private(set) var alternateScreen = false
    private(set) var mouseReporting = false
    private(set) var originMode = false
    @exclusivity(unchecked) private(set) var autowrap = true
    @exclusivity(unchecked) private(set) var insertMode = false
    private(set) var newlineMode = false
    @exclusivity(unchecked) private(set) var style = CellStyle.plain
    @exclusivity(unchecked) private(set) var scrollTop = 0
    @exclusivity(unchecked) private(set) var scrollBottom: Int
    /// Rows of the screen that changed since the last `clearDirty`; nil means everything.
    @exclusivity(unchecked) private(set) var dirtyRows: Set<Int>? = nil
    /// The pixel size of a cell, reported to programs that ask (XTWINOPS 14).
    var cellPixelSize = (width: 8, height: 16)
    /// The colours a program gets when it asks what the default foreground and background are (OSC 10/11).
    var defaultForegroundRGB: (UInt8, UInt8, UInt8) = (0x1d, 0x1b, 0x17)
    var defaultBackgroundRGB: (UInt8, UInt8, UInt8) = (0xf7, 0xf2, 0xec)

    var onOutput: ((Data) -> Void)?
    var onBell: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?

    // Parser state
    private enum State { case ground, escape, escapeIntermediate, csiEntry, csiParam, csiIntermediate, csiIgnore, oscString, dcsString, apcString }
    @exclusivity(unchecked) private var state = State.ground
    @exclusivity(unchecked) private var parameters: [[Int]] = []
    @exclusivity(unchecked) private var parameterValue = 0, parameterDigits = 0
    @exclusivity(unchecked) private var subParameters: [Int] = []
    @exclusivity(unchecked) private var intermediates: [UInt8] = []
    @exclusivity(unchecked) private var privateMarker: UInt8 = 0
    private var oscBuffer: [UInt8] = []
    private var stringEscape = false
    private var utf8Pending: [UInt8] = []
    @exclusivity(unchecked) private var utf8Needed = 0

    // Screen state
    @exclusivity(unchecked) private var wrapNext = false
    private var tabStops: Set<Int> = []
    private var savedCursor = TerminalCursor(), savedStyle = CellStyle.plain, savedOrigin = false, savedAutowrap = true, savedWrapNext = false, savedCharset = 0, savedCharsets: [Int] = [0, 0]
    private var savedMainScreen: [[TerminalCell]]? = nil
    private var savedMainCursor = TerminalCursor()
    /// G0 and G1 designations: 0 ASCII, 1 DEC special graphics. `charset` picks the active one (SI/SO).
    @exclusivity(unchecked) private var charsets = [0, 0]
    @exclusivity(unchecked) private var charset = 0

    init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000) {
        self.columns = max(2, columns); self.rows = max(1, rows); self.scrollbackLimit = max(0, scrollbackLimit)
        screen = Array(repeating: Array(repeating: .blank, count: max(2, columns)), count: max(1, rows))
        scrollBottom = max(1, rows) - 1
        resetTabStops()
    }

    // MARK: Dirty rows

    func clearDirty() { dirtyRows = []; lastDirtyRow = -1 }
    /// The row marked last: printing marks the same row for every cell of a line.
    @exclusivity(unchecked) private var lastDirtyRow = -1
    private func markDirty(_ row: Int) {
        guard dirtyRows != nil, row != lastDirtyRow else { return }
        dirtyRows?.insert(row); lastDirtyRow = row
    }
    private func markAllDirty() { dirtyRows = nil; lastDirtyRow = -1 }

    // MARK: Feeding bytes

    func feed(_ data: Data) {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            let count = bytes.count
            while index < count {
                let byte = bytes[index]
                // Printable ASCII in the ground state, which is nearly everything a terminal sees, prints a run at a time.
                if byte >= 0x20, byte < 0x7f, state == .ground, utf8Needed == 0, !insertMode, charsets[charset] == 0 {
                    index += printRun(bytes, from: index)
                } else {
                    process(byte); index += 1
                }
            }
        }
    }
    /// Prints the printable ASCII run starting at `start`, as far as the current line takes it; returns the bytes consumed.
    private func printRun(_ bytes: UnsafeRawBufferPointer, from start: Int) -> Int {
        if wrapNext {
            if autowrap { cursor.x = 0; lineFeed() } else { cursor.x = columns - 1 }
            wrapNext = false
        }
        let y = cursor.y, columns = self.columns, style = self.style, count = bytes.count
        var x = cursor.x, index = start
        screen[y].withUnsafeMutableBufferPointer { row in
            while index < count, x < columns {
                let byte = bytes[index]
                guard byte >= 0x20, byte < 0x7f else { break }
                // Overwriting one half of a wide character clears the other half.
                let existing = row[x]
                if existing.width == 2, x + 1 < columns { row[x + 1] = TerminalCell(text: " ", width: 1, style: existing.style) }
                else if existing.width == 0, x > 0 { row[x - 1] = TerminalCell(text: " ", width: 1, style: row[x - 1].style) }
                row[x] = TerminalCell(text: Self.asciiText[Int(byte)], width: 1, style: style)
                x += 1; index += 1
            }
        }
        lastPrinted = Unicode.Scalar(bytes[index - 1])
        markDirty(y)
        if x >= columns { cursor.x = columns - 1; wrapNext = true } else { cursor.x = x }
        return index - start
    }
    func feed(_ text: String) { feed(Data(text.utf8)) }

    private func process(_ byte: UInt8) {
        // C0 controls act in every state except inside strings, where they mostly end the string.
        switch state {
        case .ground:
            if byte >= 0x80 || utf8Needed > 0 { decodeUTF8(byte); return }
            if byte < 0x20 || byte == 0x7f { control(byte); return }
            // Printable ASCII is nearly everything a terminal sees: one cell, no Unicode lookups.
            if charsets[charset] == 0 { print(Unicode.Scalar(byte), width: 1) } else { print(Unicode.Scalar(byte)) }
        case .escape:
            utf8Pending.removeAll(); utf8Needed = 0
            switch byte {
            case 0x5b:
                state = .csiEntry; parameters.removeAll(keepingCapacity: true); intermediates.removeAll(keepingCapacity: true); privateMarker = 0
                parameterValue = 0; parameterDigits = 0; subParameters.removeAll(keepingCapacity: true)
            case 0x5d: state = .oscString; oscBuffer = []; stringEscape = false
            case 0x50: state = .dcsString; stringEscape = false
            case 0x58, 0x5e, 0x5f: state = .apcString; stringEscape = false
            case 0x20...0x2f: intermediates = [byte]; state = .escapeIntermediate
            case 0x18, 0x1a: state = .ground
            case 0x1b: break
            default:
                if byte < 0x20 { control(byte) } else { escape(byte, intermediates: []); state = .ground }
            }
        case .escapeIntermediate:
            if (0x20...0x2f).contains(byte) { if intermediates.count < 2 { intermediates.append(byte) } }
            else if byte < 0x20 { control(byte) }
            else { escape(byte, intermediates: intermediates); state = .ground }
        case .csiEntry, .csiParam, .csiIntermediate, .csiIgnore:
            csi(byte)
        case .oscString:
            switch byte {
            case 0x07: finishOSC(); state = .ground
            case 0x1b: stringEscape = true
            case 0x5c where stringEscape: finishOSC(); state = .ground
            case 0x18, 0x1a: state = .ground
            default:
                if stringEscape { stringEscape = false; if oscBuffer.count < 65_536 { oscBuffer.append(0x1b) } }
                if oscBuffer.count < 65_536 { oscBuffer.append(byte) }
            }
        case .dcsString, .apcString:
            switch byte {
            case 0x07: state = .ground
            case 0x1b: stringEscape = true
            case 0x5c where stringEscape: state = .ground
            case 0x18, 0x1a: state = .ground
            default: stringEscape = false
            }
        }
    }

    private func decodeUTF8(_ byte: UInt8) {
        if utf8Needed == 0 {
            if byte & 0xe0 == 0xc0 { utf8Needed = 1 } else if byte & 0xf0 == 0xe0 { utf8Needed = 2 } else if byte & 0xf8 == 0xf0 { utf8Needed = 3 }
            else { print("\u{fffd}"); return }
            utf8Pending = [byte]; return
        }
        guard byte & 0xc0 == 0x80 else {
            // A broken sequence: show the replacement character and reinterpret this byte.
            utf8Pending.removeAll(); utf8Needed = 0
            print("\u{fffd}")
            process(byte); return
        }
        utf8Pending.append(byte); utf8Needed -= 1
        if utf8Needed == 0 {
            let scalar = String(decoding: utf8Pending, as: UTF8.self).unicodeScalars.first ?? "\u{fffd}"
            utf8Pending.removeAll()
            print(scalar)
        }
    }

    // MARK: Controls and escapes

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x07: onBell?()
        case 0x08: if cursor.x > 0 { cursor.x -= 1 }; wrapNext = false; markDirty(cursor.y)
        case 0x09: tab()
        case 0x0a, 0x0b, 0x0c: lineFeed(); if newlineMode { cursor.x = 0 }
        case 0x0d: cursor.x = 0; wrapNext = false; markDirty(cursor.y)
        case 0x0e: charset = 1
        case 0x0f: charset = 0
        case 0x1b: state = .escape
        default: break
        }
    }

    private func escape(_ final: UInt8, intermediates: [UInt8]) {
        if let first = intermediates.first {
            switch (first, final) {
            case (0x28, _): charsets[0] = final == 0x30 ? 1 : 0     // ESC ( X designates G0
            case (0x29, _): charsets[1] = final == 0x30 ? 1 : 0     // ESC ) X designates G1
            case (0x23, 0x38): alignmentPattern()                    // DECALN
            default: break
            }
            return
        }
        switch final {
        case 0x37: saveCursor()                                       // DECSC
        case 0x38: restoreCursor()                                    // DECRC
        case 0x44: lineFeed()                                         // IND
        case 0x45: lineFeed(); cursor.x = 0                           // NEL
        case 0x48: tabStops.insert(cursor.x)                          // HTS
        case 0x4d: reverseIndex()                                     // RI
        case 0x3d: applicationKeypad = true                           // DECKPAM
        case 0x3e: applicationKeypad = false                          // DECKPNM
        case 0x63: reset()                                            // RIS
        default: break
        }
    }

    private func csi(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39, 0x3a, 0x3b:
            if state == .csiIgnore { return }
            if state == .csiIntermediate { state = .csiIgnore; return }
            state = .csiParam
            if byte == 0x3b { pushParameter() }
            else if byte == 0x3a {
                guard subParameters.count < 32 else { state = .csiIgnore; return }
                subParameters.append(parameterDigits > 0 ? parameterValue : 0); parameterValue = 0; parameterDigits = 0
            }
            else { if parameterDigits < 16 { parameterValue = parameterValue * 10 + Int(byte - 0x30); parameterDigits += 1 } }
        case 0x3c...0x3f:
            if state == .csiEntry { privateMarker = byte; state = .csiParam } else { state = .csiIgnore }
        case 0x20...0x2f:
            if state != .csiIgnore {
                guard intermediates.count < 2 else { state = .csiIgnore; return }
                intermediates.append(byte); state = .csiIntermediate
            }
        case 0x40...0x7e:
            if state != .csiIgnore { pushParameter(); dispatchCSI(final: byte) }
            state = .ground
        case 0x18, 0x1a: state = .ground
        case 0x1b: state = .escape
        case 0x00...0x1f: control(byte)
        default: state = .csiIgnore
        }
    }
    private func pushParameter() {
        guard parameterDigits > 0 || !subParameters.isEmpty || !parameters.isEmpty || state == .csiParam else { return }
        var parts = subParameters; parts.append(parameterDigits > 0 ? parameterValue : 0)
        parameters.append(parts)
        subParameters.removeAll(keepingCapacity: true); parameterValue = 0; parameterDigits = 0
        if parameters.count > 32 { parameters.removeLast() }
    }
    private func parameter(_ index: Int, default value: Int = 0) -> Int {
        guard index < parameters.count, let first = parameters[index].first, first != 0 else { return value }
        return first
    }

    private func dispatchCSI(final: UInt8) {
        let p0 = parameter(0, default: 1)
        if privateMarker == 0x3f {
            switch final {
            case 0x68: for group in parameters { setPrivateMode(group.first ?? 0, on: true) }
            case 0x6c: for group in parameters { setPrivateMode(group.first ?? 0, on: false) }
            case 0x70 where intermediates == [0x24]: reportPrivateMode(parameters.first?.first ?? 0)   // DECRQM
            case 0x4a: if parameter(0) == 3 { clearScrollback(); markAllDirty() } // xterm erases saved lines via ?3J too
            default: break
            }
            return
        }
        if privateMarker == 0x3e {
            if final == 0x63 { respond("\u{1b}[>1;10;0c") }         // secondary DA
            return
        }
        if privateMarker != 0 { return }
        if intermediates == [0x20] {
            if final == 0x71 { cursorShape = [3, 4].contains(parameter(0)) ? .underline : [5, 6].contains(parameter(0)) ? .bar : .block }  // DECSCUSR
            return
        }
        if intermediates == [0x24] { if final == 0x70 { reportMode(parameters.first?.first ?? 0) }; return }
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x40: insertBlanks(p0)                                                  // ICH
        case 0x41: moveCursor(dy: -p0)                                               // CUU
        case 0x42, 0x65: moveCursor(dy: p0)                                          // CUD, VPR
        case 0x43, 0x61: moveCursor(dx: p0)                                          // CUF, HPR
        case 0x44: moveCursor(dx: -p0)                                               // CUB
        case 0x45: moveCursor(dy: p0); cursor.x = 0                                  // CNL
        case 0x46: moveCursor(dy: -p0); cursor.x = 0                                 // CPL
        case 0x47, 0x60: setCursor(x: p0 - 1, y: cursor.y)                           // CHA, HPA
        case 0x48, 0x66: setCursor(x: parameter(1, default: 1) - 1, y: p0 - 1, origin: true)  // CUP, HVP
        case 0x49: for _ in 0..<min(p0, columns) { tab() }                           // CHT: further tabs stay at the edge
        case 0x4a: eraseInDisplay(parameter(0))                                      // ED
        case 0x4b: eraseInLine(parameter(0))                                         // EL
        case 0x4c: insertLines(p0)                                                   // IL
        case 0x4d: deleteLines(p0)                                                   // DL
        case 0x50: deleteCharacters(p0)                                              // DCH
        case 0x53: scrollUp(p0)                                                      // SU
        case 0x54: scrollDown(p0)                                                    // SD
        case 0x58: eraseCharacters(p0)                                               // ECH
        case 0x5a: for _ in 0..<min(p0, columns) { backTab() }                        // CBT
        case 0x62: repeatLast(p0)                                                    // REP
        case 0x63: respond("\u{1b}[?62;22c")                                          // DA1
        case 0x64: setCursor(x: cursor.x, y: p0 - 1, origin: true)                   // VPA
        case 0x67: if parameter(0) == 3 { tabStops.removeAll() } else if parameter(0) == 0 { tabStops.remove(cursor.x) }  // TBC
        case 0x68: for group in parameters { setMode(group.first ?? 0, on: true) }   // SM
        case 0x6c: for group in parameters { setMode(group.first ?? 0, on: false) }  // RM
        case 0x6d: selectGraphicRendition()                                          // SGR
        case 0x6e: deviceStatus(parameter(0))                                        // DSR
        case 0x72: setScrollRegion(top: parameter(0, default: 1) - 1, bottom: parameter(1, default: rows) - 1)  // DECSTBM
        case 0x73: savedCursor = cursor                                              // SCOSC
        case 0x74: windowOperation(parameter(0))                                     // XTWINOPS
        case 0x75: cursor = savedCursor; clampCursor()                               // SCORC
        default: break
        }
    }

    private func finishOSC() {
        let content = String(decoding: oscBuffer, as: UTF8.self)
        guard let separator = content.firstIndex(of: ";") ?? (content.allSatisfy(\.isNumber) ? content.endIndex : nil) else { return }
        let code = Int(content[..<separator]) ?? -1
        let argument = separator < content.endIndex ? String(content[content.index(after: separator)...]) : ""
        switch code {
        case 0, 2: title = argument; onTitleChange?(argument)
        case 1: if title.isEmpty { title = argument; onTitleChange?(argument) }
        case 7:
            let directory = URL(string: argument).flatMap { $0.isFileURL ? $0.path : nil }
            currentDirectory = directory; onDirectoryChange?(directory)
        case 10, 11:
            guard argument == "?" else { return }
            let (r, g, b) = code == 10 ? defaultForegroundRGB : defaultBackgroundRGB
            respond(String(format: "\u{1b}]%d;rgb:%02x%02x/%02x%02x/%02x%02x\u{1b}\\", code, r, r, g, g, b, b))
        default: break
        }
    }

    // MARK: Modes

    private func setMode(_ mode: Int, on: Bool) {
        switch mode {
        case 4: insertMode = on
        case 20: newlineMode = on
        default: break
        }
    }
    private func setPrivateMode(_ mode: Int, on: Bool) {
        switch mode {
        case 1: applicationCursorKeys = on
        case 6: originMode = on; setCursor(x: 0, y: 0, origin: true)
        case 7: autowrap = on
        case 25: cursorVisible = on; markDirty(cursor.y)
        case 47, 1047: switchScreen(alternate: on, saveCursor: false)
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049: switchScreen(alternate: on, saveCursor: true)
        case 1000, 1002, 1003, 1006: mouseReporting = on
        case 1004: focusReporting = on
        case 2004: bracketedPaste = on
        default: break
        }
    }
    private func switchScreen(alternate: Bool, saveCursor save: Bool) {
        guard alternate != alternateScreen else { return }
        if alternate {
            if save { saveCursor() }
            savedMainScreen = screen; savedMainCursor = cursor
            screen = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
            alternateScreen = true
        } else {
            if let main = savedMainScreen { screen = Self.fit(main, columns: columns, rows: rows) }
            cursor = savedMainCursor; clampCursor()
            savedMainScreen = nil
            alternateScreen = false
            if save { restoreCursor() }
        }
        wrapNext = false
        markAllDirty()
    }

    // MARK: Cursor

    private func clampCursor() {
        cursor.x = min(max(0, cursor.x), columns - 1)
        cursor.y = min(max(0, cursor.y), rows - 1)
    }
    private func moveCursor(dx: Int = 0, dy: Int = 0) {
        let previous = cursor.y
        wrapNext = false
        if dx != 0 { cursor.x = min(max(0, cursor.x + dx), columns - 1) }
        if dy != 0 {
            // Movement never leaves the scroll region when the cursor is inside it.
            let top = cursor.y >= scrollTop ? scrollTop : 0
            let bottom = cursor.y <= scrollBottom ? scrollBottom : rows - 1
            cursor.y = min(max(top, cursor.y + dy), bottom)
        }
        markDirty(previous); markDirty(cursor.y)
    }
    private func setCursor(x: Int, y: Int, origin: Bool = false) {
        let previous = cursor.y
        wrapNext = false
        cursor.x = min(max(0, x), columns - 1)
        if origin && originMode { cursor.y = min(max(scrollTop, y + scrollTop), scrollBottom) }
        else { cursor.y = min(max(0, y), rows - 1) }
        markDirty(previous); markDirty(cursor.y)
    }
    private func saveCursor() {
        savedCursor = cursor; savedStyle = style; savedOrigin = originMode; savedAutowrap = autowrap; savedWrapNext = wrapNext
        savedCharset = charset; savedCharsets = charsets
    }
    private func restoreCursor() {
        let previous = cursor.y
        cursor = savedCursor; style = savedStyle; originMode = savedOrigin; autowrap = savedAutowrap; wrapNext = savedWrapNext
        charset = savedCharset; charsets = savedCharsets
        clampCursor(); markDirty(previous); markDirty(cursor.y)
    }
    private func tab() {
        wrapNext = false
        let next = tabStops.filter { $0 > cursor.x }.min() ?? (columns - 1)
        cursor.x = min(next, columns - 1); markDirty(cursor.y)
    }
    private func backTab() {
        wrapNext = false
        cursor.x = tabStops.filter { $0 < cursor.x }.max() ?? 0; markDirty(cursor.y)
    }
    private func resetTabStops() { tabStops = Set(stride(from: 8, to: max(columns, 9), by: 8)) }

    // MARK: Printing

    @exclusivity(unchecked) private var lastPrinted: Unicode.Scalar? = nil
    private func print(_ scalar: Unicode.Scalar) {
        var scalar = scalar
        if charsets[charset] == 1, let mapped = Self.specialGraphics[scalar] { scalar = mapped }
        print(scalar, width: cellWidth(of: scalar))
    }
    /// Widths of the scalars printed so far: the Unicode property lookups behind `width(of:)` cost more than printing itself.
    @exclusivity(unchecked) private var widthCache: [UInt32: Int] = [:]
    private func cellWidth(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value >= 0x20 && value < 0x7f { return 1 }
        if let known = widthCache[value] { return known }
        let width = Self.width(of: scalar)
        if widthCache.count < 4_096 { widthCache[value] = width }
        return width
    }
    private static let asciiText: [String] = (0..<128).map { String(Unicode.Scalar(UInt8($0))) }
    static let cellTextByteLimit = 64
    var onTextLimit: (() -> Void)?
    private var reportedTextLimit = false
    private func print(_ scalar: Unicode.Scalar, width: Int) {
        lastPrinted = scalar
        if width == 0 {
            // A combining mark joins the cell before the cursor.
            var x = cursor.x - (wrapNext ? 0 : 1)
            if x < 0 { return }
            if screen[cursor.y][x].width == 0 { x -= 1 }
            guard x >= 0 else { return }
            guard !screen[cursor.y][x].combiningTruncated else { return }
            guard screen[cursor.y][x].text.utf8.count + scalar.utf8.count <= Self.cellTextByteLimit else {
                screen[cursor.y][x].text = "�"; screen[cursor.y][x].combiningTruncated = true
                markDirty(cursor.y)
                if !reportedTextLimit { reportedTextLimit = true; onTextLimit?() }
                return
            }
            screen[cursor.y][x].text.unicodeScalars.append(scalar); markDirty(cursor.y)
            return
        }
        if wrapNext {
            if autowrap { cursor.x = 0; lineFeed() } else { cursor.x = columns - 1 }
            wrapNext = false
        }
        if width == 2 && cursor.x == columns - 1 {
            // A wide character never splits: leave a blank in the last column and start a new line.
            if autowrap { screen[cursor.y][cursor.x] = TerminalCell(text: " ", width: 1, style: blankStyle); markDirty(cursor.y); cursor.x = 0; lineFeed() }
            else { screen[cursor.y][cursor.x] = TerminalCell(text: " ", width: 1, style: blankStyle); markDirty(cursor.y); return }
        }
        if insertMode { insertBlanks(width) }
        // Overwriting one half of a wide character clears the other half.
        clearWideNeighbour(at: cursor.x)
        if width == 2 { clearWideNeighbour(at: cursor.x + 1) }
        screen[cursor.y][cursor.x] = TerminalCell(text: scalar.value < 128 ? Self.asciiText[Int(scalar.value)] : String(scalar), width: UInt8(width), style: style)
        if width == 2 { screen[cursor.y][cursor.x + 1] = TerminalCell(text: "", width: 0, style: style) }
        markDirty(cursor.y)
        cursor.x += width
        if cursor.x >= columns { cursor.x = columns - 1; wrapNext = true }
    }
    private func clearWideNeighbour(at x: Int) {
        guard x < columns else { return }
        let cell = screen[cursor.y][x]
        if cell.width == 2, x + 1 < columns { screen[cursor.y][x + 1] = TerminalCell(text: " ", width: 1, style: cell.style) }
        if cell.width == 0, x > 0 { screen[cursor.y][x - 1] = TerminalCell(text: " ", width: 1, style: screen[cursor.y][x - 1].style) }
    }
    private func repeatLast(_ count: Int) {
        guard let scalar = lastPrinted else { return }
        for _ in 0..<min(count, columns * rows) { print(scalar) }
    }
    private var blankStyle: CellStyle { CellStyle(background: style.background) }
    private func blank() -> TerminalCell { TerminalCell(text: " ", width: 1, style: blankStyle) }

    // MARK: Scrolling and lines

    private func lineFeed() {
        wrapNext = false
        if cursor.y == scrollBottom { scrollUp(1) }
        else if cursor.y < rows - 1 { cursor.y += 1; markDirty(cursor.y - 1); markDirty(cursor.y) }
    }
    private func reverseIndex() {
        wrapNext = false
        if cursor.y == scrollTop { scrollDown(1) }
        else if cursor.y > 0 { cursor.y -= 1; markDirty(cursor.y + 1); markDirty(cursor.y) }
    }
    /// Lines leaving the top of the scroll region go to the scrollback when the region starts at the top of the main screen.
    private func scrollUp(_ count: Int) {
        let count = min(max(1, count), scrollBottom - scrollTop + 1)
        for _ in 0..<count {
            let line = screen.remove(at: scrollTop)
            if scrollTop == 0 && !alternateScreen { pushScrollback(line) }
            screen.insert(Array(repeating: blank(), count: columns), at: scrollBottom)
        }
        if scrollTop == 0 && scrollBottom == rows - 1 { markAllDirty() } else { for row in scrollTop...scrollBottom { markDirty(row) } }
    }
    private func scrollDown(_ count: Int) {
        let count = min(max(1, count), scrollBottom - scrollTop + 1)
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: blank(), count: columns), at: scrollTop)
        }
        for row in scrollTop...scrollBottom { markDirty(row) }
    }
    /// Cells the history may hold. A line costs as many cells as the terminal
    /// is wide, so a very wide window would otherwise let ten thousand lines
    /// grow to hundreds of megabytes, once per project with a shell open.
    static let scrollbackCellLimit = 2_000_000
    static let scrollbackByteLimit = 16 * 1024 * 1024
    private(set) var scrollbackBytes = 0
    @exclusivity(unchecked) private var scrollbackCells = 0
    private func pushScrollback(_ line: [TerminalCell]) {
        var end = line.count
        while end > 0, line[end - 1].isBlank, line[end - 1].style == .plain { end -= 1 }
        let history = TerminalHistoryLine(line[..<end])
        scrollback.append(history); scrollbackBytes += history.retainedBytes
        scrollbackCells += end
        if scrollback.count > scrollbackLimit {
            // Shifting the whole history for every line would cost more than the line: the oldest go in batches.
            let excess = scrollback.count - scrollbackLimit + scrollbackLimit / 32
            dropOldest(excess)
        } else if scrollbackCells > Self.scrollbackCellLimit {
            var excess = 0, freed = 0
            while excess < scrollback.count, freed < scrollbackCells - Self.scrollbackCellLimit + Self.scrollbackCellLimit / 32 {
                freed += scrollback[excess].cellCount; excess += 1
            }
            dropOldest(excess)
        }
        if scrollbackBytes > Self.scrollbackByteLimit {
            var excess = 0, freed = 0
            while excess < scrollback.count, freed < scrollbackBytes - Self.scrollbackByteLimit + Self.scrollbackByteLimit / 32 {
                freed += scrollback[excess].retainedBytes; excess += 1
            }
            dropOldest(excess)
        }
    }
    private func clearScrollback() { scrollback.removeAll(); scrollbackCells = 0; scrollbackBytes = 0; trimmedLines = 0 }
    /// Gives up the oldest lines of the history, keeping the counts with them.
    private func dropOldest(_ count: Int) {
        let count = min(count, scrollback.count)
        guard count > 0 else { return }
        for index in 0..<count { scrollbackCells -= scrollback[index].cellCount; scrollbackBytes -= scrollback[index].retainedBytes }
        scrollback.removeFirst(count); trimmedLines += count
    }
    private func insertLines(_ count: Int) {
        guard cursor.y >= scrollTop, cursor.y <= scrollBottom else { return }
        wrapNext = false
        for _ in 0..<min(count, scrollBottom - cursor.y + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: blank(), count: columns), at: cursor.y)
        }
        for row in cursor.y...scrollBottom { markDirty(row) }
    }
    private func deleteLines(_ count: Int) {
        guard cursor.y >= scrollTop, cursor.y <= scrollBottom else { return }
        wrapNext = false
        for _ in 0..<min(count, scrollBottom - cursor.y + 1) {
            screen.remove(at: cursor.y)
            screen.insert(Array(repeating: blank(), count: columns), at: scrollBottom)
        }
        for row in cursor.y...scrollBottom { markDirty(row) }
    }
    private func insertBlanks(_ count: Int) {
        wrapNext = false
        let count = min(count, columns - cursor.x)
        var row = screen[cursor.y]
        row.removeLast(count)
        row.insert(contentsOf: Array(repeating: blank(), count: count), at: cursor.x)
        screen[cursor.y] = row; markDirty(cursor.y)
    }
    private func deleteCharacters(_ count: Int) {
        wrapNext = false
        let count = min(count, columns - cursor.x)
        var row = screen[cursor.y]
        row.removeSubrange(cursor.x..<cursor.x + count)
        row.append(contentsOf: Array(repeating: blank(), count: count))
        screen[cursor.y] = row; markDirty(cursor.y)
    }
    private func eraseCharacters(_ count: Int) {
        wrapNext = false
        for x in cursor.x..<min(columns, cursor.x + count) { screen[cursor.y][x] = blank() }
        markDirty(cursor.y)
    }
    private func eraseInLine(_ mode: Int) {
        wrapNext = false
        let range: Range<Int>
        switch mode {
        case 1: range = 0..<min(columns, cursor.x + 1)
        case 2: range = 0..<columns
        default: range = cursor.x..<columns
        }
        for x in range { screen[cursor.y][x] = blank() }
        markDirty(cursor.y)
    }
    private func eraseInDisplay(_ mode: Int) {
        wrapNext = false
        switch mode {
        case 1:
            for row in 0..<cursor.y { screen[row] = Array(repeating: blank(), count: columns); markDirty(row) }
            eraseInLine(1)
        case 2:
            for row in 0..<rows { screen[row] = Array(repeating: blank(), count: columns) }
            markAllDirty()
        case 3:
            clearScrollback(); markAllDirty()
        default:
            eraseInLine(0)
            if cursor.y + 1 < rows { for row in cursor.y + 1..<rows { screen[row] = Array(repeating: blank(), count: columns); markDirty(row) } }
        }
    }
    private func setScrollRegion(top: Int, bottom: Int) {
        let top = min(max(0, top), rows - 1), bottom = min(max(0, bottom), rows - 1)
        guard bottom > top else { return }
        scrollTop = top; scrollBottom = bottom
        setCursor(x: 0, y: 0, origin: true)
    }
    private func alignmentPattern() {
        for row in 0..<rows { screen[row] = Array(repeating: TerminalCell(text: "E", width: 1, style: .plain), count: columns) }
        scrollTop = 0; scrollBottom = rows - 1
        setCursor(x: 0, y: 0); markAllDirty()
    }

    // MARK: SGR

    private func selectGraphicRendition() {
        if parameters.isEmpty { style = .plain; return }
        var index = 0
        while index < parameters.count {
            let group = parameters[index]
            let code = group.first ?? 0
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = group.count > 1 ? group[1] != 0 : true
            case 5, 6: break
            case 7: style.inverse = true
            case 8: style.hidden = true
            case 9: style.strikethrough = true
            case 21: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 28: style.hidden = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(UInt8(code - 30))
            case 39: style.foreground = .standard
            case 40...47: style.background = .indexed(UInt8(code - 40))
            case 49: style.background = .standard
            case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48, 58:
                // Either colon-separated within the group or semicolon-separated across groups.
                var arguments = Array(group.dropFirst())
                var consumed = 0
                if arguments.isEmpty {
                    let rest = parameters[(index + 1)...].map { $0.first ?? 0 }
                    if rest.first == 5 { arguments = Array(rest.prefix(2)); consumed = 2 }
                    else if rest.first == 2 { arguments = Array(rest.prefix(4)); consumed = 4 }
                }
                var colour: TerminalColor? = nil
                if arguments.first == 5, arguments.count >= 2 { colour = .indexed(UInt8(clamping: arguments[1])) }
                else if arguments.first == 2, arguments.count >= 4 {
                    // 38:2::r:g:b carries a colour-space id; 38;2;r;g;b does not.
                    let rgb = arguments.count >= 5 ? Array(arguments[2...4]) : Array(arguments[1...3])
                    colour = .rgb(UInt8(clamping: rgb[0]), UInt8(clamping: rgb[1]), UInt8(clamping: rgb[2]))
                }
                if let colour { if code == 38 { style.foreground = colour } else if code == 48 { style.background = colour } }
                index += consumed
            default: break
            }
            index += 1
        }
    }

    // MARK: Resize and reset

    /// Fits the screen to a new size: columns are cut or padded, and when the
    /// screen shrinks the lines above the cursor go to the scrollback, coming
    /// back when it grows again.
    func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(2, newColumns), newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }
        if newRows < rows {
            var remove = rows - newRows
            // Prefer dropping blank lines below the cursor; then push lines from the top into the scrollback.
            while remove > 0, screen.count > cursor.y + 1, Self.text(of: screen[screen.count - 1]).isEmpty { screen.removeLast(); remove -= 1 }
            while remove > 0, !screen.isEmpty {
                let line = screen.removeFirst()
                if !alternateScreen { pushScrollback(line) }
                cursor.y -= 1; remove -= 1
            }
        } else if newRows > rows {
            var add = newRows - rows
            while add > 0, !alternateScreen, let line = scrollback.popLast() {
                scrollbackCells -= line.cellCount
                scrollbackBytes -= line.retainedBytes
                screen.insert(Self.fit([line.cells], columns: columns, rows: 1)[0], at: 0); cursor.y += 1; add -= 1
            }
            while add > 0 { screen.append(Array(repeating: .blank, count: columns)); add -= 1 }
        }
        columns = newColumns; rows = newRows
        screen = Self.fit(screen, columns: columns, rows: rows)
        if let main = savedMainScreen { savedMainScreen = Self.fit(main, columns: columns, rows: rows) }
        scrollTop = 0; scrollBottom = rows - 1
        clampCursor(); savedCursor.x = min(savedCursor.x, columns - 1); savedCursor.y = min(savedCursor.y, rows - 1)
        savedMainCursor.x = min(savedMainCursor.x, columns - 1); savedMainCursor.y = min(savedMainCursor.y, rows - 1)
        wrapNext = false
        resetTabStops()
        markAllDirty()
    }
    private static func fit(_ lines: [[TerminalCell]], columns: Int, rows: Int) -> [[TerminalCell]] {
        var result = lines.prefix(rows).map { line -> [TerminalCell] in
            var row = Array(line.prefix(columns))
            if row.last?.width == 2 { row[row.count - 1] = .blank }
            if row.count < columns { row.append(contentsOf: Array(repeating: TerminalCell.blank, count: columns - row.count)) }
            return row
        }
        while result.count < rows { result.append(Array(repeating: .blank, count: columns)) }
        return result
    }
    func reset() {
        screen = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        savedMainScreen = nil; alternateScreen = false
        cursor = TerminalCursor(); savedCursor = TerminalCursor(); style = .plain; savedStyle = .plain
        scrollTop = 0; scrollBottom = rows - 1
        cursorVisible = true; cursorShape = .block; originMode = false; autowrap = true; insertMode = false; newlineMode = false
        applicationCursorKeys = false; applicationKeypad = false; bracketedPaste = false; focusReporting = false; mouseReporting = false
        charsets = [0, 0]; charset = 0; wrapNext = false
        resetTabStops(); markAllDirty()
    }
    /// DEC special graphics, so line-drawing programs draw boxes rather than letters.
    private static let specialGraphics: [Unicode.Scalar: Unicode.Scalar] = [
        "`": "\u{25c6}", "a": "\u{2592}", "b": "\u{2409}", "c": "\u{240c}", "d": "\u{240d}", "e": "\u{240a}", "f": "\u{00b0}", "g": "\u{00b1}",
        "h": "\u{2424}", "i": "\u{240b}", "j": "\u{2518}", "k": "\u{2510}", "l": "\u{250c}", "m": "\u{2514}", "n": "\u{253c}", "o": "\u{23ba}",
        "p": "\u{23bb}", "q": "\u{2500}", "r": "\u{23bc}", "s": "\u{23bd}", "t": "\u{251c}", "u": "\u{2524}", "v": "\u{2534}", "w": "\u{252c}",
        "x": "\u{2502}", "y": "\u{2264}", "z": "\u{2265}", "{": "\u{03c0}", "|": "\u{2260}", "}": "\u{00a3}", "~": "\u{00b7}",
    ]
}
