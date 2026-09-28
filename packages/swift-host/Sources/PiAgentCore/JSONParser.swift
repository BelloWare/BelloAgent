import Foundation

/// JSON text to `JSON`, byte by byte. Every journal line and protocol frame
/// is read here. Decoding the enum through `JSONDecoder` tried each kind in
/// turn and threw for every miss, and `JSONSerialization` builds Foundation
/// objects first and reads some doubles back a unit off in the last place;
/// this reads each value once, into the enum, and a number through
/// `Double(_:)`, which returns the double the text names, as `JSONDecoder`
/// did. What `JSONDecoder` accepted and refused, this accepts and refuses,
/// including a trailing comma before `]` or `}`.
struct JSONByteParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    /// Deeper nesting than any record or frame has; a bound, not a trim.
    private static let maximumDepth = 512

    static func parse(_ data: Data) throws -> JSON {
        try data.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: UInt8.self)
            let (encoding, mark) = Self.encoding(of: all)
            if encoding == .utf8 {
                var parser = JSONByteParser(bytes: UnsafeBufferPointer(rebasing: all[mark...]))
                return try parser.document()
            }
            guard let text = String(bytes: all[mark...], encoding: encoding) else { throw invalid("invalid text encoding") }
            return try Array(text.utf8).withUnsafeBufferPointer { utf8 in
                var parser = JSONByteParser(bytes: utf8)
                return try parser.document()
            }
        }
    }
    private init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    private static func invalid(_ reason: String) -> AgentError { AgentError("invalid_json", "Invalid JSON: " + reason) }

    /// JSONDecoder skipped a UTF-8 byte-order mark and read UTF-16 and
    /// UTF-32 too, told by their mark or by where the zero bytes fall; so
    /// does this. Every journal line and frame is UTF-8 without a mark.
    private static func encoding(of bytes: UnsafeBufferPointer<UInt8>) -> (String.Encoding, mark: Int) {
        let count = bytes.count
        guard count >= 2 else { return (.utf8, 0) }
        if count >= 4 {
            if bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return (.utf8, 3) }
            if bytes[0] == 0, bytes[1] == 0, bytes[2] == 0xFE, bytes[3] == 0xFF { return (.utf32BigEndian, 4) }
        }
        // UTF-32's little-endian mark begins with UTF-16's, and JSONDecoder
        // took it for that one.
        if bytes[0] == 0xFF, bytes[1] == 0xFE { return (.utf16LittleEndian, 2) }
        if bytes[0] == 0xFE, bytes[1] == 0xFF { return (.utf16BigEndian, 2) }
        if count >= 4 {
            switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
            case (0, 0, 0, _): return (.utf32BigEndian, 0)
            case (_, 0, 0, 0): return (.utf32LittleEndian, 0)
            case (0, _, 0, _): return (.utf16BigEndian, 0)
            case (_, 0, _, 0): return (.utf16LittleEndian, 0)
            default: return (.utf8, 0)
            }
        }
        if bytes[0] == 0 { return (.utf16BigEndian, 0) }
        if bytes[1] == 0 { return (.utf16LittleEndian, 0) }
        return (.utf8, 0)
    }

    private mutating func document() throws -> JSON {
        skipSpace()
        let value = try value(depth: 0)
        skipSpace()
        guard index == bytes.count else { throw Self.invalid("unexpected text after the value") }
        return value
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    private mutating func skipSpace() {
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 else { return }
            index += 1
        }
    }
    private mutating func expect(_ byte: UInt8, _ what: String) throws {
        guard peek == byte else { throw Self.invalid("expected \(what)") }
        index += 1
    }

    private mutating func value(depth: Int) throws -> JSON {
        guard let byte = peek else { throw Self.invalid("unexpected end") }
        switch byte {
        case UInt8(ascii: "{"): return try object(depth: depth + 1)
        case UInt8(ascii: "["): return try array(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw Self.invalid("unexpected character")
        }
    }

    private mutating func literal(_ word: StaticString) throws {
        let count = word.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw Self.invalid("unexpected end") }
        for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { throw Self.invalid("unexpected literal") }
        index += count
    }

    private mutating func object(depth: Int) throws -> JSON {
        guard depth <= Self.maximumDepth else { throw Self.invalid("nested too deeply") }
        index += 1
        var members: [String: JSON] = [:]
        skipSpace()
        if peek == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipSpace()
            guard peek == UInt8(ascii: "\"") else { throw Self.invalid("expected a key") }
            let key = try string()
            skipSpace()
            try expect(UInt8(ascii: ":"), "':'")
            skipSpace()
            let member = try value(depth: depth)
            // A repeated key keeps its first value, as JSONDecoder kept it.
            if members[key] == nil { members[key] = member }
            skipSpace()
            if peek == UInt8(ascii: ",") {
                index += 1; skipSpace()
                // JSONDecoder allowed a trailing comma; so does this.
                if peek == UInt8(ascii: "}") { index += 1; return .object(members) }
                continue
            }
            try expect(UInt8(ascii: "}"), "',' or '}'")
            return .object(members)
        }
    }

    private mutating func array(depth: Int) throws -> JSON {
        guard depth <= Self.maximumDepth else { throw Self.invalid("nested too deeply") }
        index += 1
        var elements: [JSON] = []
        skipSpace()
        if peek == UInt8(ascii: "]") { index += 1; return .array(elements) }
        while true {
            skipSpace()
            elements.append(try value(depth: depth))
            skipSpace()
            if peek == UInt8(ascii: ",") {
                index += 1; skipSpace()
                if peek == UInt8(ascii: "]") { index += 1; return .array(elements) }
                continue
            }
            try expect(UInt8(ascii: "]"), "',' or ']'")
            return .array(elements)
        }
    }

    /// A string's text. The common case has no escapes: one pass to find its
    /// end, one to decode it. A string with escapes is built piece by piece.
    private mutating func string() throws -> String {
        index += 1
        let start = index
        var ascii = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let text = try Self.text(UnsafeBufferPointer(rebasing: bytes[start..<index]), ascii: ascii)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { index = start; return try escapedString() }
            guard byte >= 0x20 else { throw Self.invalid("control character in a string") }
            if byte >= 0x80 { ascii = false }
            index += 1
        }
        throw Self.invalid("unterminated string")
    }

    private static func text(_ slice: UnsafeBufferPointer<UInt8>, ascii: Bool) throws -> String {
        if ascii { return String(decoding: slice, as: UTF8.self) }
        // Invalid UTF-8 is refused, as JSONDecoder refused it, not repaired.
        guard let text = String(bytes: slice, encoding: .utf8) else { throw invalid("invalid UTF-8") }
        return text
    }

    private mutating func escapedString() throws -> String {
        var scalars = String.UnicodeScalarView()
        var runStart = index
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                try appendRun(runStart, index, to: &scalars)
                index += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                try appendRun(runStart, index, to: &scalars)
                index += 1
                guard let escape = peek else { throw Self.invalid("unterminated escape") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let unit = try hexUnit()
                    if (0xD800...0xDBFF).contains(unit) {
                        // A high surrogate must be followed by its low half.
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw Self.invalid("unpaired surrogate")
                        }
                        index += 2
                        let low = try hexUnit()
                        guard (0xDC00...0xDFFF).contains(low),
                              let scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)) else {
                            throw Self.invalid("unpaired surrogate")
                        }
                        scalars.append(scalar)
                    } else {
                        guard let scalar = Unicode.Scalar(UInt32(unit)) else { throw Self.invalid("unpaired surrogate") }
                        scalars.append(scalar)
                    }
                default: throw Self.invalid("unknown escape")
                }
                runStart = index
            default:
                guard byte >= 0x20 else { throw Self.invalid("control character in a string") }
                index += 1
            }
        }
        throw Self.invalid("unterminated string")
    }

    private func appendRun(_ start: Int, _ end: Int, to scalars: inout String.UnicodeScalarView) throws {
        guard end > start else { return }
        scalars.append(contentsOf: try Self.text(UnsafeBufferPointer(rebasing: bytes[start..<end]), ascii: false).unicodeScalars)
    }

    private mutating func hexUnit() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw Self.invalid("short unicode escape") }
        var unit: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
            default: throw Self.invalid("bad unicode escape")
            }
            unit = unit << 4 | digit
            index += 1
        }
        return unit
    }

    /// A number as JSON writes it, read by `Double(_:)`: the nearest double
    /// to the text, as JSONDecoder read it.
    private mutating func number() throws -> Double {
        let start = index
        if peek == UInt8(ascii: "-") { index += 1 }
        guard let first = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { throw Self.invalid("bad number") }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) { throw Self.invalid("leading zero") }
        } else { skipDigits() }
        if peek == UInt8(ascii: ".") {
            index += 1
            guard skipDigits() else { throw Self.invalid("bad fraction") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            index += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            guard skipDigits() else { throw Self.invalid("bad exponent") }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        guard let value = Double(text), value.isFinite else { throw Self.invalid("number out of range") }
        // Like JSONDecoder: a number too small for a double is refused, not
        // read as zero; one that only loses precision is read.
        if value == 0, let digits = text.split(whereSeparator: { $0 == "e" || $0 == "E" }).first,
           digits.contains(where: { ("1"..."9").contains($0) }) { throw Self.invalid("number out of range") }
        return value
    }
    @discardableResult private mutating func skipDigits() -> Bool {
        let start = index
        while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        return index > start
    }
}
