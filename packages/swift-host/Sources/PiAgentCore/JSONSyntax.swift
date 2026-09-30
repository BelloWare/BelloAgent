import Foundation

/// Whether a line is JSON the parser takes, told without building it. A fork
/// leaves out a long chat's thousands of run-state records, and used to parse
/// each one only to find out it could; a malformed one then failed the fork,
/// and must still. `plainlyValid` answers true only for a line it is sure
/// `JSONByteParser` accepts: its grammar (with the trailing comma the parser
/// allows), strings in plain ASCII with the simple escapes, and numbers with
/// no exponent and at most fifteen digits, which are always a finite double.
/// Anything else, a `\u` escape, a byte past ASCII, a longer number, deeper
/// nesting than the parser allows, answers false, and the caller asks the
/// parser itself: nothing it refused is taken, nothing it took is refused.
enum JSONSyntax {
    static func plainlyValid(_ line: Data) -> Bool {
        line.withUnsafeBytes { raw -> Bool in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self))
            return scanner.document()
        }
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        /// The parser's own bound on nesting.
        private static let maximumDepth = 512

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func document() -> Bool {
            // A byte-order mark or another encoding is the parser's to read.
            guard let first = bytes.first, first != 0, first != 0xEF, first != 0xFE, first != 0xFF else { return false }
            skipSpace()
            guard value(depth: 0) else { return false }
            skipSpace()
            return index == bytes.count
        }
        private mutating func skipSpace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }
        private mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1; return true
        }
        private mutating func value(depth: Int) -> Bool {
            guard let byte = peek else { return false }
            switch byte {
            case UInt8(ascii: "{"): return object(depth: depth + 1)
            case UInt8(ascii: "["): return array(depth: depth + 1)
            case UInt8(ascii: "\""): return string()
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
            default: return false
            }
        }
        private mutating func literal(_ word: StaticString) -> Bool {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { return false }
            for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { return false }
            index += count; return true
        }
        private mutating func object(depth: Int) -> Bool {
            guard depth <= Self.maximumDepth else { return false }
            index += 1; skipSpace()
            if take(UInt8(ascii: "}")) { return true }
            while true {
                skipSpace()
                guard peek == UInt8(ascii: "\""), string() else { return false }
                skipSpace()
                guard take(UInt8(ascii: ":")) else { return false }
                skipSpace()
                guard value(depth: depth) else { return false }
                skipSpace()
                if take(UInt8(ascii: ",")) {
                    skipSpace()
                    if take(UInt8(ascii: "}")) { return true }
                    continue
                }
                return take(UInt8(ascii: "}"))
            }
        }
        private mutating func array(depth: Int) -> Bool {
            guard depth <= Self.maximumDepth else { return false }
            index += 1; skipSpace()
            if take(UInt8(ascii: "]")) { return true }
            while true {
                skipSpace()
                guard value(depth: depth) else { return false }
                skipSpace()
                if take(UInt8(ascii: ",")) {
                    skipSpace()
                    if take(UInt8(ascii: "]")) { return true }
                    continue
                }
                return take(UInt8(ascii: "]"))
            }
        }
        /// Plain ASCII, no control character, and only the escapes that stand
        /// for one ASCII character.
        private mutating func string() -> Bool {
            index += 1
            while let byte = peek {
                index += 1
                switch byte {
                case UInt8(ascii: "\""): return true
                case UInt8(ascii: "\\"):
                    guard let escape = peek, [UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                                              UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t")].contains(escape) else { return false }
                    index += 1
                default:
                    guard byte >= 0x20, byte < 0x80 else { return false }
                }
            }
            return false
        }
        /// JSON's grammar, with no exponent and at most fifteen digits.
        private mutating func number() -> Bool {
            var digits = 0
            _ = take(UInt8(ascii: "-"))
            guard let first = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return false }
            if first == UInt8(ascii: "0") {
                index += 1; digits += 1
                if let next = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) { return false }
            } else { digits += skipDigits() }
            if take(UInt8(ascii: ".")) {
                let fraction = skipDigits()
                guard fraction > 0 else { return false }
                digits += fraction
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") { return false }
            return digits <= 15
        }
        private mutating func skipDigits() -> Int {
            let start = index
            while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            return index - start
        }
    }
}
