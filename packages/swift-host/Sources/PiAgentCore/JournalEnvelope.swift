import Foundation

/// A journal record written again as another journal's own, byte for byte
/// but for its envelope: a fork's copy of a record keeps its `id` and every
/// other member exactly as they were written, with its `parentId` the new
/// journal's tail and its `timestamp` the time of the copy. Parsing each
/// record and encoding it again for that was most of the time a long chat's
/// fork took; the payload of a message or a tool's output never changes.
///
/// It reads the line's structure (strings, escapes, nesting), not its text, as
/// `JournalLineScan` does. Anything it does not read plainly answers nil, and
/// the caller copies the record as before, parsing it and encoding it again:
/// a line that is not exactly one object; a key written with an escape, or
/// twice; an `id`, `parentId` or `timestamp` that is not a plain string (a
/// null `parentId` excepted), or that is missing; and a `nativeState`, which
/// the copy leaves out and which is checked by parsing, as before.
enum JournalEnvelope {
    /// `line` with its `parentId` and `timestamp` replaced, if its `id` is
    /// `id`. The rest of the line's bytes are kept in place.
    static func rewritten(_ line: Data, id: String, parentID: String?, timestamp: String) -> Data? {
        line.withUnsafeBytes { raw -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = Scanner(bytes: bytes)
            guard let members = scanner.members() else { return nil }
            var found = (id: false, parent: false, time: false)
            for member in members {
                switch member.key {
                case "id":
                    guard case .string(let value) = member.value, value == id else { return nil }
                    found.id = true
                case "parentId":
                    switch member.value { case .string, .null: found.parent = true; default: return nil }
                case "timestamp":
                    guard case .string = member.value else { return nil }
                    found.time = true
                case "nativeState": return nil
                default: break
                }
            }
            guard found.id, found.parent, found.time else { return nil }
            var output = Data(capacity: bytes.count + 64)
            var copied = 0
            func keep(to end: Int) { if end > copied { output.append(UnsafeBufferPointer(rebasing: bytes[copied..<end])) }; copied = end }
            for member in members where member.key == "parentId" || member.key == "timestamp" {
                keep(to: member.valueStart)
                if member.key == "parentId" { output.append(contentsOf: parentID.map { quoted($0) } ?? Array("null".utf8)) }
                else { output.append(contentsOf: quoted(timestamp)) }
                copied = member.valueEnd
            }
            keep(to: bytes.count)
            return output
        }
    }

    /// A string the journal's encoder writes as it is: the identities and
    /// times put here never hold a quote, a backslash or a control character.
    private static func quoted(_ text: String) -> [UInt8] {
        precondition(!text.utf8.contains { $0 == 0x22 || $0 == 0x5C || $0 < 0x20 }, "An envelope value needs no escape")
        return [0x22] + Array(text.utf8) + [0x22]
    }

    private enum Value: Equatable { case string(String), null, other }
    private struct Member { var key: String; var value: Value; var valueStart: Int; var valueEnd: Int }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

        /// The object's members in order, or nil for anything but exactly one
        /// object whose keys are plain and each written once.
        mutating func members() -> [Member]? {
            var members: [Member] = [], keys = Set<String>()
            skipSpace()
            guard take(UInt8(ascii: "{")) else { return nil }
            skipSpace()
            if take(UInt8(ascii: "}")) { return finished() ? members : nil }
            while true {
                skipSpace()
                guard let key = plainString(), keys.insert(key).inserted else { return nil }
                skipSpace()
                guard take(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                let start = index
                let value: Value
                if peek == Self.quote, ["id", "parentId", "timestamp"].contains(key) {
                    guard let text = plainString() else { return nil }
                    value = .string(text)
                } else if literal("null") {
                    value = .null
                } else {
                    guard skipValue() else { return nil }
                    value = .other
                }
                members.append(Member(key: key, value: value, valueStart: start, valueEnd: index))
                skipSpace()
                if take(UInt8(ascii: ",")) { continue }
                guard take(UInt8(ascii: "}")) else { return nil }
                return finished() ? members : nil
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
        private mutating func literal(_ word: StaticString) -> Bool {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { return false }
            for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { return false }
            // A literal ends at a delimiter, never inside a longer word.
            if index + count < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index + count]) { return false }
            index += count; return true
        }
        /// A string with no escapes, as text; nil for one with an escape, or
        /// whose bytes are not UTF-8, which decoding would repair unseen.
        private mutating func plainString() -> String? {
            guard take(Self.quote) else { return nil }
            let start = index
            while let byte = peek {
                if byte == Self.quote {
                    guard let text = String(bytes: UnsafeBufferPointer(rebasing: bytes[start..<index]), encoding: .utf8) else { return nil }
                    index += 1; return text
                }
                if byte == Self.backslash || byte < 0x20 { return nil }
                index += 1
            }
            return nil
        }
        /// Past one value of any kind: strings and their escapes, and nesting.
        /// Its content is checked by the parse the copy's reader makes of the
        /// line it writes.
        private mutating func skipValue() -> Bool {
            guard let first = peek else { return false }
            if first == Self.quote { return skipString() }
            if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
                var stack: [UInt8] = []
                while let byte = peek {
                    switch byte {
                    case Self.quote: guard skipString() else { return false }; continue
                    case UInt8(ascii: "{"): stack.append(UInt8(ascii: "}"))
                    case UInt8(ascii: "["): stack.append(UInt8(ascii: "]"))
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        guard stack.popLast() == byte else { return false }
                        if stack.isEmpty { index += 1; return true }
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
                else if byte < 0x20 { return false }
            }
            return false
        }
    }
}
