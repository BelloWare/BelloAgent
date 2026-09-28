import XCTest
@testable import PiAgentCore

/// `JSON.parse` reads bytes itself; it must give exactly the values the
/// `Codable` decoding it replaced gave, and refuse what it refused. Every
/// journal line and protocol frame goes through it.
final class JSONParseTests: XCTestCase {
    private func codable(_ data: Data) -> Result<JSON, Error> { Result { try JSONDecoder().decode(JSON.self, from: data) } }
    private func parsed(_ data: Data) -> Result<JSON, Error> { Result { try JSON.parse(data) } }
    /// Foundation's JSONDecoder aborts the process, through a `try!` of its
    /// own, on invalid UTF-8 and on a bad escape, instead of throwing. It
    /// cannot be asked about those; the parser must refuse them.
    private func codableAborts(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil else { return true }
        let bytes = [UInt8](data), hex = Set("0123456789abcdefABCDEF".utf8), escapes = Set("\"\\/bfnrt".utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\") else { index += 1; continue }
            guard index + 1 < bytes.count else { return true }
            let escape = bytes[index + 1]
            if escape == UInt8(ascii: "u") {
                guard index + 5 < bytes.count, bytes[(index + 2)...(index + 5)].allSatisfy(hex.contains) else { return true }
                index += 6
            } else {
                guard escapes.contains(escape) else { return true }
                index += 2
            }
        }
        return false
    }
    /// The same value, or both refused; where JSONDecoder would abort, the parser refuses.
    private func agree(_ data: Data) -> Bool {
        if codableAborts(data) { if case .failure = parsed(data) { return true }; return false }
        switch (codable(data), parsed(data)) {
        case (.success(let a), .success(let b)): return a == b && a.encoded() == b.encoded()
        case (.failure, .failure): return true
        default: return false
        }
    }
    private func describe(_ data: Data) -> String {
        "\(String(decoding: data, as: UTF8.self).debugDescription): Codable \(codableAborts(data) ? "aborts" : "\(codable(data))"), parser \(parsed(data))"
    }

    func testDocumentsReadAsCodableReadThem() throws {
        let documents = [
            #"{"type":"message","id":"a1","message":{"role":"user","content":[{"type":"text","text":"Hello \"quoted\" \\ back\/slash é 中文 🙂 é 😀"}]}}"#,
            #"{"n":[0,-0,1,-1,1.5,-2.25,1e3,1E-3,1e+3,123456789012345678901234567890,9007199254740993,0.1,2.5e-320,1.7976931348623157e308,0.012958288192749023]}"#,
            #"{"t":true,"f":false,"z":null,"e":{},"a":[],"nested":[[[{"k":[true,1,"1",null]}]]]}"#,
            #"{"dup":1,"dup":2}"#, #"[1,"two",false,null,{"x":[]}]"#,
            #""a lone string""#, "42", "true", "null", " \t\r\n{ \"spaced\" : [ 1 , 2 ] } \n",
            "[1,]", #"{"a":1,}"#,
        ]
        for text in documents { XCTAssertTrue(agree(Data(text.utf8)), describe(Data(text.utf8))) }
        XCTAssertEqual(try JSON.parse(Data("[true,1,0,false]".utf8)), [.bool(true), .number(1), .number(0), .bool(false)])
        // A double written by the journal's encoder reads back as the same double.
        XCTAssertEqual(try JSON.parse(Data("0.012958288192749023".utf8)).double, 0.012958288192749023)
    }

    func testEdgeCasesAcceptedOrRefusedAsCodableDid() {
        let cases: [String] = [
            #""\ud800""#, #""\udc00""#, #""\ud800A""#, #""😀""#, "\"a\u{01}b\"", "\"tab\there\"", #""\x""#, #""\u12""#, #""\u00zz""#,
            "01", "-01", "-", "1.", ".5", "+1", "1e", "1e+", "1e400", "-1e400", "1e-400", "0e0", "-0.0", "1E2", "2.", "0x10",
            "\u{FEFF}{\"a\":1}", "[1 2]", "{\"a\" 1}", "{\"a\":1 \"b\":2}", "{a:1}", "tru", "nulll", "[", "]", "{", "}", "[,]", "{,}",
            "[1,,2]", "{\"a\":1,,}", "\"unterminated", "", " ", "{} {}", "[] x", "[[[[[[]]]]]]", "{\"\":\"\"}",
        ]
        let disagreements = cases.map { Data($0.utf8) }.filter { !agree($0) }.map(describe)
        XCTAssertTrue(disagreements.isEmpty, disagreements.joined(separator: "\n"))
    }

    /// Random documents, written as the journal writes them, read the same way.
    func testRandomDocumentsReadAsCodableReadThem() {
        var random = SeededRandom(seed: 0x5EED_1234)
        for _ in 0..<400 {
            let value = random.document(depth: 0)
            let data = (try? value.data()) ?? Data()
            XCTAssertTrue(agree(data), describe(data))
            XCTAssertEqual(try JSON.parse(data), value, "Round trip through the journal's encoder")
        }
    }

    /// Damaged documents are accepted or refused exactly as before.
    func testDamagedDocumentsAreTreatedAsCodableTreatedThem() {
        var random = SeededRandom(seed: 0xDA4A_6ED)
        let pieces: [UInt8] = Array("{}[]\",:\\ 0123456789.eE+-tfnul".utf8)
        var disagreements: [String] = []
        for _ in 0..<600 {
            var bytes = [UInt8]((try? random.document(depth: 0).data()) ?? Data())
            guard !bytes.isEmpty else { continue }
            for _ in 0..<Int(random.next() % 3 + 1) {
                // Damage lands on ASCII bytes only: JSONDecoder aborts the
                // process on invalid UTF-8 (a `try!` inside Foundation), so
                // it cannot be the reference for that; the test below is.
                let ascii = bytes.indices.filter { bytes[$0] < 0x80 }
                guard !ascii.isEmpty else { break }
                let position = ascii[Int(random.next() % UInt64(ascii.count))]
                switch random.next() % 3 {
                case 0: bytes.remove(at: position); if bytes.isEmpty { bytes = [0x20] }
                case 1: bytes.insert(pieces[Int(random.next() % UInt64(pieces.count))], at: position)
                default: bytes[position] = pieces[Int(random.next() % UInt64(pieces.count))]
                }
            }
            let data = Data(bytes)
            if !agree(data) { disagreements.append(describe(data)) }
        }
        XCTAssertTrue(disagreements.isEmpty, "\(disagreements.count) disagreements:\n" + disagreements.prefix(10).joined(separator: "\n"))
    }
}

extension JSONParseTests {
    /// Invalid UTF-8 is refused with an error. JSONDecoder aborted the whole
    /// process on it, so a damaged journal line took the helper down.
    func testInvalidUTF8IsRefusedNotACrash() {
        for bytes: [UInt8] in [[0x22, 0xC3, 0x22], [0x22, 0xE4, 0xB8, 0x22], [0x22, 0xFF, 0x22], [0x7B, 0x22, 0xC3, 0x28, 0x22, 0x3A, 0x31, 0x7D],
                               [0x22, 0x61, 0x5C, 0x6E, 0xC3, 0x22]] {
            XCTAssertThrowsError(try JSON.parse(Data(bytes)), "\(bytes)")
        }
        XCTAssertEqual(try JSON.parse(Data([0x22, 0xC3, 0xA9, 0x22])), .string("é"))
    }

    /// A UTF-8 byte-order mark is skipped, and UTF-16 and UTF-32 are read,
    /// with or without a mark, as JSONDecoder read them.
    func testOtherEncodingsReadAsCodableReadThem() {
        let text = #"{"a":[1,"é🙂",null]}"#
        var documents = [Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)]
        for encoding: String.Encoding in [.utf16BigEndian, .utf16LittleEndian, .utf32BigEndian, .utf32LittleEndian, .utf16, .utf32] {
            documents.append(text.data(using: encoding)!)
        }
        documents.append(Data([0x31, 0x00]))  // "1" in UTF-16, told by its zero byte
        documents.append(Data([0x00, 0x00, 0xFE, 0xFF]) + text.data(using: .utf32BigEndian)!)
        for data in documents {
            let expected = codable(data), actual = parsed(data)
            switch (expected, actual) {
            case (.success(let a), .success(let b)): XCTAssertEqual(a, b, "\([UInt8](data))")
            case (.failure, .failure): break
            default: XCTFail("\([UInt8](data)): Codable \(expected), parser \(actual)")
            }
        }
    }
}

/// Opening a chat checks its chain with a scan of each record's id, parent
/// and kind; the scan must read what the parser reads, or leave the line to it.
final class JournalLineScanTests: XCTestCase {
    private func scanned(_ text: String) -> JournalLineScan.Fields? { JournalLineScan.fields(Data(text.utf8)) }
    private func parsedFields(_ text: String) -> JournalLineScan.Fields? {
        guard let item = try? JSON.parse(Data(text.utf8)) else { return nil }
        return .init(id: item["id"].text, parentID: item["parentId"].text, customType: item["customType"].text)
    }

    func testTheRecordsOwnFieldsAreRead() {
        XCTAssertEqual(scanned(#"{"customType":"pi-app.native.v1","data":{"id":"inner","parentId":"x"},"id":"a1","parentId":null}"#),
                       .init(id: "a1", parentID: nil, customType: "pi-app.native.v1"))
        XCTAssertEqual(scanned(#"{"id":"b2","message":{"content":[{"text":"\"id\":\"fake\" {[","type":"text"}],"id":"m"},"parentId":"a1","type":"message"}"#),
                       .init(id: "b2", parentID: "a1", customType: nil))
        XCTAssertEqual(scanned(" {\"id\" : \"c3\" , \"n\" : -1.5e3 , \"ok\" : true , \"parentId\" : \"b2\" } "), .init(id: "c3", parentID: "b2", customType: nil))
    }

    func testWhatItCannotReadPlainlyIsLeftToTheParser() {
        let escape = #"\"#  // an escape in the id, or in the key
        for text in [#"{"id":"a"# + escape + #"u0031"}"#, #"{"id":1}"#, #"["id"]"#, #"{"id":"a""#, #"{"id":"a"} x"#, #"{"i"# + escape + #"u0064":"a"}"#, "",
                     #"{"id":"a","id":"b"}"#, #"{"id":"a","parentId":"p","parentId":null}"#, "{\"id\":\"a\tb\"}"] {
            XCTAssertNil(scanned(text), text)
        }
    }

    /// Records as the journal writes them, with the three fields among others.
    func testTheScanAgreesWithTheParser() {
        var random = SeededRandom(seed: 0x5CA7)
        let keys = ["id", "parentId", "customType", "type", "data", "message", "timestamp"]
        var read = 0
        for _ in 0..<400 {
            var record: [String: JSON] = [:]
            for key in keys where random.next() % 3 != 0 {
                switch key {
                case "id", "parentId", "customType": record[key] = random.next() % 5 == 0 ? .null : .string(random.plainIdentity())
                default: record[key] = random.document(depth: 1)
                }
            }
            let text = (try? JSON.object(record).data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            guard let fields = scanned(text) else { continue }
            read += 1
            XCTAssertEqual(fields, parsedFields(text), text)
        }
        XCTAssertGreaterThan(read, 300, "Plain records are read by the scan")
    }
}

/// SplitMix64: the same documents on every run.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func document(depth: Int) -> JSON {
        switch next() % (depth > 3 ? 4 : 6) {
        case 0: return .string(text())
        case 1: return .number(number())
        case 2: return next() % 3 == 0 ? .null : .bool(next() % 2 == 0)
        case 3: return .string(text())
        case 4: return .array((0..<Int(next() % 5)).map { _ in document(depth: depth + 1) })
        default:
            var object: [String: JSON] = [:]
            for _ in 0..<Int(next() % 5) { object[text()] = document(depth: depth + 1) }
            return .object(object)
        }
    }
    mutating func number() -> Double {
        switch next() % 4 {
        case 0: return Double(Int64(bitPattern: next()) % 1_000_000)
        case 1: return Double(bitPattern: next() & 0x7FEF_FFFF_FFFF_FFFF) * (next() % 2 == 0 ? 1 : -1)
        case 2: return Double(next() % 100_000) / 1_000
        default: return Double(bitPattern: next()).isFinite ? Double(bitPattern: next() & 0x3FFF_FFFF_FFFF_FFFF) : 0.5
        }
    }
    mutating func plainIdentity() -> String {
        let alphabet = Array("abcXYZ0189._:-")
        return String((0..<Int(next() % 12 + 1)).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
    }
    mutating func text() -> String {
        let alphabet: [Unicode.Scalar] = ["a", "Z", "0", " ", "\"", "\\", "/", "\n", "\t", "\u{01}", "\u{1F}", "é", "中", "🙂", "\u{FFFF}", "\u{10FFFF}", "\u{7F}", "\u{2028}"]
        var scalars = String.UnicodeScalarView()
        for _ in 0..<Int(next() % 12) { scalars.append(alphabet[Int(next() % UInt64(alphabet.count))]) }
        return String(scalars)
    }
}
