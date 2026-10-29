import XCTest
@testable import PiAgentCore

/// Keep the reference frozen: this checks the parser's values AND its exact
/// refusal reasons, including which error wins in a multiply damaged string.
final class JSONParserDifferentialTests: HelperTestCase {
    private struct Counts {
        var accepted = 0
        var refused = 0
        var total: Int { accepted + refused }
    }

    /// JSON's equality intentionally treats canonically equivalent strings
    /// and signed zero as equal. Here also check their bytes and double bits.
    private func identical(_ a: JSON, _ b: JSON) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x.utf8.elementsEqual(y.utf8)
        case (.number(let x), .number(let y)): return x.bitPattern == y.bitPattern
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(identical)
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { key, value in
                guard let index = y.index(forKey: key) else { return false }
                return key.utf8.elementsEqual(y[index].key.utf8) && identical(value, y[index].value)
            }
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    @discardableResult
    private func compare(_ data: Data, _ label: String, _ counts: inout Counts,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let expected = Result { try ReferenceJSONByteParser.parse(data) }
        let actual = Result { try JSON.parse(data) }
        let same: Bool
        switch (expected, actual) {
        case (.success(let a), .success(let b)):
            counts.accepted += 1
            same = identical(a, b)
        case (.failure(let a as AgentError), .failure(let b as AgentError)):
            counts.refused += 1
            same = a.code == b.code && a.message == b.message
        default: same = false
        }
        if !same {
            // A bounded diagnostic even for the MiB cases. The seed and case
            // number reproduce the full input without logging fixture bodies.
            XCTFail("\(label), \(data.count) bytes, prefix \(Array(data.prefix(96))): reference \(summary(expected)), actual \(summary(actual))", file: file, line: line)
        }
        return same
    }

    private func summary(_ result: Result<JSON, Error>) -> String {
        switch result {
        case .success: return "accepted"
        case .failure(let error): return String(describing: error)
        }
    }

    private func report(_ label: String, _ counts: Counts) {
        print("JSON_DIFFERENTIAL \(label) total=\(counts.total) accepted=\(counts.accepted) refused=\(counts.refused)")
    }

    func testStringAndDocumentBoundaries() {
        var counts = Counts()
        var cases = [
            "", " ", "\t\r\n", "null", "true", "false", "tru", "nulll", "{} {}", "[] x",
            "[]", "{}", "[1,]", #"{"a":1,}"#, #"{"dup":1,"dup":2}"#,
            #"{"dup":null,"dup":2}"#, #"{"é":1,"e\u0301":2}"#,
            #"{"\u0061":1,"a":2}"#, "[1,,2]", "{,}", "[", "{", "]", "}",
            #""""#, #""\"\\\/\b\f\n\r\t""#, #""\ud800\udc00""#, #""\uDBFF\uDFFF""#,
            #""\ud800""#, #""\udc00""#, #""\ud800\n""#, #""\ud800\u0041""#,
            #""\ud800\ud800""#, #""\udfff\ud800""#, #""\x""#, #""\u12""#, #""\u00zz""#,
            "\"a\\", "\"a\\n", "\"a\\n\\", "\"a\\u", "\"a\\u123", "\"a\\ud800\\u",
            "-0", "-0.0", "-0e-400", "0e400", "1e-400", "1e400", "-1e400", "01", "-01",
            "1.", "1e", "1e+", ".5", "+1", "0x10", "-", "1e-324", "5e-324", "2.5e-320",
            "1.7976931348623157e308", "1.7976931348623159e308", "9007199254740993",
            "0.012958288192749023", "0." + String(repeating: "0", count: 400) + "1",
            String(repeating: "9", count: 1000) + "e-999",
            "0." + String(repeating: "0", count: 1000),
            "-0." + String(repeating: "0", count: 1000),
        ]
        for depth in [0, 1, 511, 512, 513, 514] {
            cases.append(String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth))
            cases.append(String(repeating: #"{"a":"#, count: depth) + "0" + String(repeating: "}", count: depth))
        }
        for space in [" ", "\t", "\r", "\n", " \t\r\n", "\u{0B}", "\u{0C}", "\u{00A0}"] {
            cases.append(space + #"{"a""# + space + ":" + space + "[1,2,]}" + space)
        }
        // Tiny strings, allocation boundaries, long runs, and escaped scalars
        // at either side of a MiB run. BOMs inside a string are text, too.
        for size in [0, 1, 7, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 4095, 4096, 1 << 20] {
            for run in [String(repeating: "a", count: size), String(repeating: "é中🙂", count: size / 9)] {
                for (prefix, suffix) in [("", ""), (#"\n"#, ""), ("", #"\n"#), (#"\uD83D\uDE42"#, #"\""#)] {
                    cases.append("\"" + prefix + run + suffix + "\"")
                }
            }
        }
        for text in ["\u{FEFF}", "\u{FFFF}", "\u{10FFFF}", "é", "e\u{0301}", "\u{7F}"] {
            cases += ["\"" + text + "\"", "\"" + text + #"\n""#,
                      #""\n"# + text + "\"", #""a\n"# + text + #"\t""#]
        }
        for (i, text) in cases.enumerated() {
            guard compare(Data(text.utf8), "boundary \(i)", &counts) else { return }
        }
        // Exhaust the BMP escape decoder, including every lone surrogate.
        for unit in 0...0xFFFF {
            let text = String(format: "\"\\u%04x\"", unit)
            guard compare(Data(text.utf8), "BMP \(unit)", &counts) else { return }
        }
        let invalid: [[UInt8]] = [
            [0x80], [0xBF], [0xC0, 0xAF], [0xC1, 0xBF], [0xC2], [0xC3, 0x28],
            [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xE4, 0xB8],
            [0xF0, 0x80, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
            [0xF0, 0x9F, 0x99], [0xFF], [0xFE],
        ]
        for bad in invalid + (0...31).map({ [UInt8($0)] }) {
            // Completed invalid runs precede every kind of later failure;
            // unfinished invalid runs must not hide controls or truncation.
            for prefix in ["a", #"a\n"#, #"a\u00e9"#] {
                for suffix in ["\"", "", #"\n""#, #"\x""#, "\\", #"\u12"#,
                               #"\uZZZZ""#, #"\ud800\n""#, "\u{01}\"", "\u{01}\\n\""] {
                    let data = Data(("\"" + prefix).utf8) + Data(bad) + Data(suffix.utf8)
                    guard compare(data, "bad bytes \(bad), \(prefix), \(suffix.debugDescription)", &counts) else { return }
                }
            }
        }
        report("boundaries", counts)
    }

    func testEncodingsAndTruncatedCodeUnits() {
        var counts = Counts()
        let texts = [#"{"a":[1,"é🙂\n\uD83D\uDE42",null]}"#, #""\ud800""#, "[1,]", "1", "", "\"a\u{01}b\"", #""\uZZZZ""#]
        for text in texts {
            var documents = [Data(text.utf8), Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)]
            for (encoding, bom): (String.Encoding, [UInt8]) in [
                (.utf16BigEndian, [0xFE, 0xFF]), (.utf16LittleEndian, [0xFF, 0xFE]),
                (.utf32BigEndian, [0, 0, 0xFE, 0xFF]), (.utf32LittleEndian, [0xFF, 0xFE, 0, 0]),
            ] {
                let data = text.data(using: encoding)!
                documents += [data, Data(bom) + data]
                for removed in 1...4 where data.count >= removed {
                    documents += [data.dropLast(removed), Data(bom) + data.dropLast(removed)]
                }
            }
            for data in documents { guard compare(data, "encoding", &counts) else { return } }
        }
        for bytes: [UInt8] in [[0xEF, 0xBB, 0xBF], [0xFE, 0xFF, 0, 0x22, 0xD8, 0, 0, 0x22],
                               [0, 0, 0xFE, 0xFF, 0, 0x11, 0, 0], [0xFF, 0xFE, 0x22, 0, 0, 0xDC, 0x22, 0]] {
            guard compare(Data(bytes), "invalid encoding", &counts) else { return }
        }
        report("encodings", counts)
    }

    func testSeededDocuments() {
        let env = ProcessInfo.processInfo.environment
        let seed = env["PI_JSON_FUZZ_SEED"].flatMap(UInt64.init) ?? 0xA136_B17E_5EED
        // The regular gate stays small; the validation run sets 1,000,000.
        let count = max(1, env["PI_JSON_FUZZ_COUNT"].flatMap(Int.init) ?? 20_000)
        print("JSON_DIFFERENTIAL seed=\(seed) count=\(count)")
        var random = JSONParserRandom(seed: seed)
        var counts = Counts()
        for i in 0..<count {
            guard compare(random.document(), "seed \(seed) case \(i)", &counts) else { return }
        }
        XCTAssertEqual(counts.total, count)
        report("fuzz seed=\(seed)", counts)
    }

    func testGeneratedJournalLines() throws {
        guard let path = ProcessInfo.processInfo.environment["PI_JSON_FIXTURE_JOURNAL"] else {
            throw XCTSkip("Set PI_JSON_FIXTURE_JOURNAL to a generated perf-longchat fixture")
        }
        var counts = Counts()
        for (i, line) in try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 0x0A).enumerated() {
            guard compare(Data(line), "journal line \(i + 1)", &counts) else { return }
        }
        XCTAssertGreaterThan(counts.accepted, 10_000)
        XCTAssertEqual(counts.refused, 0)
        report("generated journal", counts)
    }

    func testCommittedJournalAndFrameFixtures() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../fixtures/native").standardizedFileURL
        var counts = Counts()
        var files = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted(by: { $0.path < $1.path }) where ["json", "jsonl", "meta"].contains(url.pathExtension) {
            files += 1
            let data = try Data(contentsOf: url)
            let documents = url.pathExtension == "jsonl" ? data.split(separator: 0x0A).map { Data($0) } : [data]
            for (i, document) in documents.enumerated() {
                guard compare(document, "\(url.lastPathComponent):\(i + 1)", &counts) else { return }
            }
        }
        XCTAssertGreaterThanOrEqual(files, 8)
        XCTAssertEqual(counts.refused, 0)
        report("committed fixtures files=\(files)", counts)
    }

    /// Reuse standalone JSON literals already present in the helper tests.
    /// Computed/interpolated Swift strings are covered by those actual tests;
    /// this collector only decodes ordinary JSON-compatible Swift literals
    /// and raw one-hash strings, without evaluating any test source.
    func testExistingHelperLiteralCorpus() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let raw = try NSRegularExpression(pattern: ##"(?s)#"(.*?)"#"##)
        let ordinary = try NSRegularExpression(pattern: #""(?:\\.|[^"\\\r\n])*""#)
        var corpus = Set<Data>()
        var files = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "swift" && !url.lastPathComponent.contains("JSONParser") {
            files += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in raw.matches(in: source, range: range) {
                if let range = Range(match.range(at: 1), in: source) { collect(String(source[range]), into: &corpus) }
            }
            for match in ordinary.matches(in: source, range: range) {
                guard let range = Range(match.range, in: source),
                      let text = try? ReferenceJSONByteParser.parse(Data(source[range].utf8)).text else { continue }
                collect(text, into: &corpus)
            }
        }
        var counts = Counts()
        for data in corpus.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard compare(data, "helper literal", &counts) else { return }
        }
        XCTAssertGreaterThan(counts.accepted, 50)
        report("helper literals files=\(files)", counts)
    }

    private func collect(_ text: String, into corpus: inout Set<Data>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return }
        corpus.insert(Data(text.utf8))
    }

    /// Opt-in Release microbenchmark: setup/filtering is outside the timer.
    /// The frozen parser and optimized parser run in the same test binary.
    func testReleaseMicrobenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PI_JSON_BENCHMARK_JOURNAL"] else { throw XCTSkip("Opt-in Release microbenchmark") }
        #if DEBUG
        throw XCTSkip("Use swift test -c release for throughput evidence")
        #else
        for measurement in try JSONParserBenchmark.run(path: path, environment: env) {
            XCTAssertGreaterThan(measurement.checksum, 0)
        }
        #endif
    }
}

/// SplitMix64 and byte-level generation: malformed input is intentional, so
/// neither JSON's encoder nor Unicode repair can sanitize the fuzz corpus.
private struct JSONParserRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func choose(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

    private static let pieces: [[UInt8]] = [
        "a", "", "normal ASCII run", "é中🙂", "e\u{0301}", "\u{FEFF}", "\u{10FFFF}",
        #"\""#, #"\\"#, #"\/"#, #"\b"#, #"\f"#, #"\n"#, #"\r"#, #"\t"#,
        #"\u0000"#, #"\u007f"#, #"\u0080"#, #"\u07ff"#, #"\u0800"#, #"\uffff"#,
        #"\ud800\udc00"#, #"\udbff\udfff"#, #"\ud800"#, #"\udc00"#, #"\ud800\n"#,
        #"\ud800\u0041"#, #"\u"#, #"\u12"#, #"\uGGGG"#, #"\x"#, #"\"#,
    ].map { Array($0.utf8) } + [
        [0x80], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
        [0xF5, 0x80, 0x80, 0x80], [0xE4, 0xB8], [0xF0, 0x9F, 0x99], [0xFF],
    ]

    mutating func string() -> [UInt8] {
        var bytes: [UInt8] = [0x22]
        for _ in 0..<choose(12) {
            switch choose(20) {
            case 0: bytes.append(UInt8(choose(32)))
            case 1: bytes += Array(String(format: "\\u%04x", choose(65536)).utf8)
            case 2:
                bytes += Array(String(format: "\\u%04x\\u%04x", 0xD800 + choose(1024), 0xDC00 + choose(1024)).utf8)
            case 3: bytes += Array(repeating: UInt8(0x20 + choose(95)), count: choose(256))
            default: bytes += Self.pieces[choose(Self.pieces.count)]
            }
        }
        if choose(10) != 0 { bytes.append(0x22) }
        return bytes
    }

    mutating func document() -> Data {
        // Rare large/deep cases keep the seeded corpus broad without making
        // the normal run spend all its time allocating giant documents.
        switch choose(8192) {
        case 0:
            let depth = 511 + choose(4)
            return Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
        case 1:
            let run = String(repeating: choose(2) == 0 ? "a" : "é", count: 1 << 20)
            return Data((#""\n"# + run + #"\uD83D\uDE42""#).utf8)
        case 2:
            return Data(("0." + String(repeating: "0", count: 300 + choose(800)) + "1e" + String(choose(600))).utf8)
        default: break
        }
        var bytes: [UInt8]
        switch choose(10) {
        case 0:
            let number = ["-0", "1e-400", "1e400", "01", "-01", "0.00001", "1e+", "5e-324",
                          "1.7976931348623157e308", "9007199254740993"][choose(10)]
            bytes = Array(number.utf8)
            if choose(2) == 0 { bytes += Array(String(next()).utf8) }
        case 1: bytes = Array(["null", "true", "false", "tru", "", "[]", "{}", "[1,]", "{,}"][choose(9)].utf8)
        default: bytes = string()
        }
        switch choose(6) {
        case 0: bytes = Array(#"{"key":"#.utf8) + bytes + Array(#", "key":2,}"#.utf8)
        case 1: bytes = [0x5B] + bytes + [0x2C, 0x5D]
        case 2: bytes = [0x20, 0x09, 0x0D, 0x0A] + bytes + [0x20, 0x0A]
        default: break
        }
        if choose(10) == 0, !bytes.isEmpty {
            let index = choose(bytes.count)
            switch choose(3) {
            case 0: bytes[index] = UInt8(choose(256))
            case 1: bytes.remove(at: index)
            default: bytes.insert(UInt8(choose(256)), at: index)
            }
        }
        switch choose(100) {
        case 0: return Data([0xEF, 0xBB, 0xBF] + bytes)
        case 1...4:
            if let text = String(bytes: bytes, encoding: .utf8) {
                let encodings: [String.Encoding] = [.utf16BigEndian, .utf16LittleEndian, .utf32BigEndian, .utf32LittleEndian]
                return text.data(using: encodings[choose(4)])!
            }
        default: break
        }
        return Data(bytes)
    }
}
