import Foundation

/// The bytes a key sends, honouring the application cursor and keypad modes.
enum TerminalKeyEncoder {
    enum Key { case up, down, left, right, home, end, pageUp, pageDown, insert, delete, tab, backTab, enter, escape, backspace, function(Int) }
    static func encode(_ key: Key, applicationCursor: Bool, shift: Bool = false, control: Bool = false, option: Bool = false) -> Data {
        let modifier: String = {
            var value = 1
            if shift { value += 1 }
            if option { value += 2 }
            if control { value += 4 }
            return value == 1 ? "" : ";\(value)"
        }()
        func csi(_ final: String) -> String { modifier.isEmpty ? "\u{1b}[\(final)" : "\u{1b}[1\(modifier)\(final)" }
        func ss3(_ final: String) -> String { modifier.isEmpty ? (applicationCursor ? "\u{1b}O\(final)" : "\u{1b}[\(final)") : "\u{1b}[1\(modifier)\(final)" }
        func tilde(_ number: Int) -> String { "\u{1b}[\(number)\(modifier)~" }
        let text: String
        switch key {
        case .up: text = ss3("A")
        case .down: text = ss3("B")
        case .right: text = ss3("C")
        case .left: text = ss3("D")
        case .home: text = ss3("H")
        case .end: text = ss3("F")
        case .pageUp: text = tilde(5)
        case .pageDown: text = tilde(6)
        case .insert: text = tilde(2)
        case .delete: text = tilde(3)
        case .tab: text = "\t"
        case .backTab: text = "\u{1b}[Z"
        case .enter: text = "\r"
        case .escape: text = "\u{1b}"
        case .backspace: text = option ? "\u{1b}\u{7f}" : "\u{7f}"
        case .function(let number):
            switch number {
            case 1: text = modifier.isEmpty ? "\u{1b}OP" : csi("P")
            case 2: text = modifier.isEmpty ? "\u{1b}OQ" : csi("Q")
            case 3: text = modifier.isEmpty ? "\u{1b}OR" : csi("R")
            case 4: text = modifier.isEmpty ? "\u{1b}OS" : csi("S")
            case 5: text = tilde(15)
            case 6: text = tilde(17)
            case 7: text = tilde(18)
            case 8: text = tilde(19)
            case 9: text = tilde(20)
            case 10: text = tilde(21)
            case 11: text = tilde(23)
            default: text = tilde(24)
            }
        }
        return Data(text.utf8)
    }
}
