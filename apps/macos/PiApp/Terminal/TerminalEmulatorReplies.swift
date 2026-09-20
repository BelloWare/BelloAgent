import Foundation

// The replies programs ask the terminal for: which modes are set, where the
// cursor is, how big the window is. Each is called from the CSI dispatch in
// `TerminalEmulator.swift` and writes back through `onOutput`.

// The parser in `TerminalEmulator.swift` calls each of these, so they are
// internal rather than private: the split is by concern, not by visibility.
extension TerminalEmulator {
    func reportPrivateMode(_ mode: Int) {
        let value: Int
        switch mode {
        case 1: value = applicationCursorKeys ? 1 : 2
        case 6: value = originMode ? 1 : 2
        case 7: value = autowrap ? 1 : 2
        case 25: value = cursorVisible ? 1 : 2
        case 47, 1047, 1049: value = alternateScreen ? 1 : 2
        case 1004: value = focusReporting ? 1 : 2
        case 2004: value = bracketedPaste ? 1 : 2
        case 2026: value = 2
        default: value = 0
        }
        respond("\u{1b}[?\(mode);\(value)$y")
    }
    func reportMode(_ mode: Int) {
        let value = mode == 4 ? (insertMode ? 1 : 2) : mode == 20 ? (newlineMode ? 1 : 2) : 0
        respond("\u{1b}[\(mode);\(value)$y")
    }
    func deviceStatus(_ kind: Int) {
        switch kind {
        case 5: respond("\u{1b}[0n")
        case 6: respond("\u{1b}[\(cursor.y - (originMode ? scrollTop : 0) + 1);\(cursor.x + 1)R")
        default: break
        }
    }
    func windowOperation(_ operation: Int) {
        switch operation {
        case 14: respond("\u{1b}[4;\(rows * cellPixelSize.height);\(columns * cellPixelSize.width)t")
        case 18: respond("\u{1b}[8;\(rows);\(columns)t")
        default: break
        }
    }
    func respond(_ text: String) { onOutput?(Data(text.utf8)) }
}
