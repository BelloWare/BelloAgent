import Foundation

/// The exact number of bytes `JSON.data()` produces for a value, computed
/// without encoding it. A streaming row grows by a token at a time; knowing
/// its encoded size must cost the token, not the reply so far. The escaping
/// cost of every ASCII byte is measured once from the encoder itself, so the
/// count follows the encoder of the system the helper runs on.
enum JSONSize {
    /// Encoded bytes of each ASCII byte inside a string (1, 2 or 6).
    private static let ascii: [Int] = (0..<128).map { byte in
        ((try? JSON.string(String(UnicodeScalar(UInt8(byte)))).data().count) ?? 8) - 2
    }
    /// Encoded bytes of U+2028 and U+2029, which some encoders escape.
    private static let separator: Int = ((try? JSON.string("\u{2028}").data().count) ?? 5) - 2
    /// Encoded bytes of UTF-8 text inside a string, without its quotes. The
    /// text must start and end on scalar boundaries, as any Swift string does.
    static func escaped<Bytes: Sequence>(_ bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        if let counted = bytes.withContiguousStorageIfAvailable({ escaped(buffer: $0) }) { return counted }
        var total = 0, first: UInt8 = 0, second: UInt8 = 0
        for byte in bytes {
            if byte < 0x80 { total += ascii[Int(byte)] }
            else {
                total += 1
                if separator != 3, first == 0xE2, second == 0x80, byte == 0xA8 || byte == 0xA9 { total += separator - 3 }
            }
            first = second; second = byte
        }
        return total
    }
    private static func escaped(buffer: UnsafeBufferPointer<UInt8>) -> Int {
        ascii.withUnsafeBufferPointer { costs in
            var total = 0, first: UInt8 = 0, second: UInt8 = 0
            for byte in buffer {
                if byte < 0x80 { total += costs[Int(byte)] }
                else {
                    total += 1
                    if separator != 3, first == 0xE2, second == 0x80, byte == 0xA8 || byte == 0xA9 { total += separator - 3 }
                }
                first = second; second = byte
            }
            return total
        }
    }
    /// The escaped size of `text`, kept current from what `counted` already
    /// covers: the text only grows until the partial is reset, so bringing
    /// the count up to date costs only what was appended since.
    static func escaped(_ text: String, counted: inout (utf8: Int, bytes: Int)) -> Int {
        let utf8 = text.utf8
        if utf8.count < counted.utf8 { counted = (0, 0) }
        if utf8.count > counted.utf8 {
            counted.bytes += escaped(utf8[utf8.index(utf8.startIndex, offsetBy: counted.utf8)...]); counted.utf8 = utf8.count
        }
        return counted.bytes
    }
    /// Encoded bytes of a string, quotes included.
    static func string(_ text: String) -> Int { 2 + escaped(text.utf8) }
    static func number(_ value: Double) -> Int {
        // Integral values print as plain digits; anything else is measured.
        if value.isFinite, value == value.rounded(), abs(value) < 1e15, !(value == 0 && value.sign == .minus) {
            let integer = Int(value)
            var digits = integer < 0 ? 2 : 1, rest = integer.magnitude
            while rest >= 10 { rest /= 10; digits += 1 }
            return digits
        }
        return (try? JSON.number(value).data().count) ?? 0
    }
    static func value(_ value: JSON) -> Int {
        switch value {
        case .null: return 4
        case .bool(let flag): return flag ? 4 : 5
        case .number(let number): return Self.number(number)
        case .string(let text): return string(text)
        case .array(let items): return 2 + items.reduce(0) { $0 + Self.value($1) } + max(0, items.count - 1)
        case .object(let fields): return object(fields, sized: [:])
        }
    }
    /// An object whose larger members' encoded sizes are already known.
    static func object(_ fields: [String: JSON], sized: [String: Int]) -> Int {
        var total = 2 + max(0, fields.count + sized.count - 1)
        for (key, member) in fields { total += string(key) + 1 + value(member) }
        for (key, size) in sized { total += string(key) + 1 + size }
        return total
    }
    /// An array whose elements' encoded sizes are known.
    static func array(_ sizes: [Int]) -> Int { 2 + sizes.reduce(0, +) + max(0, sizes.count - 1) }
}

/// The text a string holds after its first `offset` UTF-8 bytes: what a
/// reader that already has those bytes is missing. Nil when the string is
/// shorter than the reader's copy, which then needs the whole value again.
/// Constant time to find the boundary; the copy is only the new text.
func utf8Suffix(_ text: String, from offset: Int) -> String? {
    let bytes = text.utf8
    guard offset >= 0, offset <= bytes.count else { return nil }
    if offset == bytes.count { return "" }
    return String(decoding: bytes[bytes.index(bytes.startIndex, offsetBy: offset)...], as: UTF8.self)
}
