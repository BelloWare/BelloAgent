import Foundation

/// A journal line's top-level `id`, `parentId` and `customType`, read without
/// building the rest of the record. Opening a chat checks that its journal is
/// one unbroken chain before it replays it, and that check needs only these
/// three fields; parsing every record in full for it, and again for the
/// replay, was most of the time a long chat took to open.
///
/// The scan walks the line's structure (strings, escapes, nesting), not its
/// text, so a key named inside a message's content is never mistaken for the
/// record's own. It answers nil for anything it does not read plainly — a key
/// or one of these values written with an escape, a value that is not a
/// string or null, a line that is not one object — and the caller then parses
/// the line in full, as before.
enum JournalLineScan {
    struct Fields: Equatable {
        var id: String?
        var parentID: String?
        var customType: String?
    }

    /// How every run-state record this helper writes begins: the journal is
    /// written with sorted keys, and `customType` sorts first.
    static let statePrefix = Data(#"{"customType":"pi-app.native.state.v1","#.utf8)

    /// A run-state record's own id and parent, read from the end of its line.
    /// The journal writes keys sorted, so such a record ends with its id,
    /// parent, timestamp and type, and none of those can hold a quote: the
    /// last `,"id":"` in the line is the record's own, and the rest of the
    /// line must be exactly that ending. The snapshot before it is not read at
    /// all; superseded run state is never used, and a long chat holds
    /// thousands of them. Anything else answers nil, and the caller reads the
    /// line as before.
    static func stateTail(_ line: Data) -> Fields? {
        guard line.starts(with: statePrefix) else { return nil }
        return line.withUnsafeBytes { raw -> Fields? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let marker: [UInt8] = Array(#","id":""#.utf8)
            var start = bytes.count - marker.count
            search: while start > statePrefix.count {
                for offset in 0..<marker.count where bytes[start + offset] != marker[offset] { start -= 1; continue search }
                break
            }
            // The data object ends right before the record's own id.
            guard start > statePrefix.count, bytes[start - 1] == UInt8(ascii: "}") else { return nil }
            var scanner = Scanner(bytes: bytes, index: start)
            return scanner.stateTail()
        }
    }

    static func fields(_ line: Data) -> Fields? {
        line.withUnsafeBytes { raw -> Fields? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = Scanner(bytes: bytes)
            return scanner.fields()
        }
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

        /// `,"id":"…","parentId":"…"|null,"timestamp":"…","type":"custom"}`
        /// and nothing after it but white space.
        mutating func stateTail() -> Fields? {
            guard literal(#","id":"#), let id = plainString(), literal(#","parentId":"#) else { return nil }
            let parent: String?
            if peek == Self.quote { guard let text = plainString() else { return nil }; parent = text }
            else if literal("null") { parent = nil }
            else { return nil }
            guard literal(#","timestamp":"#), plainString() != nil, literal(#","type":"custom"}"#), finished() else { return nil }
            return Fields(id: id, parentID: parent, customType: "pi-app.native.state.v1")
        }

        mutating func fields() -> Fields? {
            var fields = Fields(), seen = Set<String>()
            skipSpace()
            guard take(UInt8(ascii: "{")) else { return nil }
            skipSpace()
            if take(UInt8(ascii: "}")) { return finished() ? fields : nil }
            while true {
                skipSpace()
                guard let key = plainString() else { return nil }
                skipSpace()
                guard take(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                switch key {
                case "id", "parentId", "customType":
                    // A repeated key is the parser's to settle: it keeps the first.
                    guard seen.insert(key).inserted else { return nil }
                    let value: String?
                    if peek == Self.quote { guard let text = plainString() else { return nil }; value = text }
                    else if literal("null") { value = nil }
                    else { return nil }
                    switch key {
                    case "id": fields.id = value
                    case "parentId": fields.parentID = value
                    default: fields.customType = value
                    }
                default:
                    guard skipValue() else { return nil }
                }
                skipSpace()
                if take(UInt8(ascii: ",")) { continue }
                guard take(UInt8(ascii: "}")) else { return nil }
                return finished() ? fields : nil
            }
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
        private mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1; return true
        }
        private mutating func skipSpace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }
        mutating func finished() -> Bool { skipSpace(); return index == bytes.count }
        mutating func literal(_ word: StaticString) -> Bool {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { return false }
            for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { return false }
            index += count; return true
        }
        /// A string with no escapes, as text; nil for one with an escape,
        /// which the caller leaves to the full parser.
        mutating func plainString() -> String? {
            guard take(Self.quote) else { return nil }
            let start = index
            while let byte = peek {
                if byte == Self.quote {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                    index += 1; return text
                }
                if byte == Self.backslash || byte < 0x20 { return nil }
                index += 1
            }
            return nil
        }
        /// Past one value of any kind: strings and their escapes, and nesting.
        private mutating func skipValue() -> Bool {
            guard let first = peek else { return false }
            if first == Self.quote { return skipString() }
            if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
                var depth = 0
                while let byte = peek {
                    switch byte {
                    case Self.quote: guard skipString() else { return false }; continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default: break
                    }
                    index += 1
                }
                return false
            }
            // A number or a literal runs to the next delimiter.
            let start = index
            while let byte = peek, byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"), byte != UInt8(ascii: "]"),
                  byte != 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { index += 1 }
            return index > start
        }
        private mutating func skipString() -> Bool {
            guard take(Self.quote) else { return false }
            while let byte = peek {
                index += 1
                if byte == Self.backslash { guard peek != nil else { return false }; index += 1 }
                else if byte == Self.quote { return true }
            }
            return false
        }
    }
}
