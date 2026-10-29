import XCTest
@testable import PiApp

/// `HistoryIndexScan` against a frozen copy of the decoding it replaces
/// (`ReferenceIndexRecord`, below): every document is accepted or rejected
/// alike and indexes the same facts. A document the scanner does not read
/// itself goes to `JSONDecoder`, as before; the scanner must never answer a
/// record the frozen decoding would reject or read differently.
final class HistoryIndexScanTests: XCTestCase {
    struct Tally: CustomStringConvertible {
        var documents = 0, scanned = 0, accepted = 0, rejected = 0, mismatches = 0, trapping = 0
        var description: String { "documents=\(documents) scanned=\(scanned) accepted=\(accepted) rejected=\(rejected) trapping=\(trapping) mismatches=\(mismatches)" }
    }
    /// The facts of one record, named alike for both decodings.
    static func facts(_ value: Any?) -> String {
        guard let value else { return "rejected" }
        return String(reflecting: value)
            .replacingOccurrences(of: "PiAppTests.ReferenceIndexRecord", with: "IndexRecord")
            .replacingOccurrences(of: "PiApp.HistoryReader.IndexRecord", with: "IndexRecord")
    }
    /// What production indexes a line with: the scanner, else `JSONDecoder`.
    static func candidate(_ bytes: [UInt8]) -> (record: HistoryReader.IndexRecord?, scanned: Bool) {
        if let record = bytes.withUnsafeBytes({ HistoryIndexScan.record($0) }) { return (record, true) }
        return (try? JSONDecoder().decode(HistoryReader.IndexRecord.self, from: Data(bytes)), false)
    }
    /// A line on which `JSONDecoder` itself traps rather than throwing: an
    /// object key it cannot decode (invalid UTF-8, a control character, a bad
    /// escape or a lone surrogate) reaches a `try!` in Foundation's
    /// JSONDecoder.swift when the object is decoded. Both the decoding this
    /// replaces and the production fallback trap alike on such a line, so it
    /// is never decoded in the test process; the scanner must leave every one
    /// of them to `JSONDecoder`. Any string where a key may stand counts.
    static func trapsDecoder(_ bytes: [UInt8]) -> Bool {
        // A line it reads as UTF-16 or UTF-32 is transcoded first; keep
        // those out too, so no transcoding path is exercised in-process.
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.prefix(4).contains(0) { return true }
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        var i = 0, previous: UInt8 = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x22 {
                var j = i + 1
                while j < bytes.count, bytes[j] != 0x22 { j += bytes[j] == 0x5C ? 2 : 1 }
                var next = j + 1
                while next < bytes.count, space.contains(bytes[next]) { next += 1 }
                let key = previous == 0x7B || previous == 0x2C || (next < bytes.count && bytes[next] == 0x3A)
                if key, (try? JSONDecoder().decode(String.self, from: Data([0x22] + bytes[(i + 1)..<min(j, bytes.count)] + [0x22]))) == nil { return true }
                i = j + 1; previous = 0x22; continue
            }
            if !space.contains(byte) { previous = byte }
            i += 1
        }
        return false
    }
    @discardableResult
    static func compare(_ bytes: [UInt8], _ tally: inout Tally, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if trapsDecoder(bytes) {
            tally.documents += 1; tally.trapping += 1
            guard bytes.withUnsafeBytes({ HistoryIndexScan.record($0) }) == nil else {
                tally.mismatches += 1
                XCTFail("Scanner read a line JSONDecoder traps on: \(String(decoding: bytes.prefix(200), as: UTF8.self))", file: file, line: line)
                return false
            }
            return true
        }
        let reference = try? JSONDecoder().decode(ReferenceIndexRecord.self, from: Data(bytes))
        let (record, scanned) = candidate(bytes)
        tally.documents += 1; if scanned { tally.scanned += 1 }
        if reference == nil { tally.rejected += 1 } else { tally.accepted += 1 }
        let expected = facts(reference), actual = facts(record)
        guard expected != actual else { return true }
        tally.mismatches += 1
        if tally.mismatches <= 20 {
            let shown = String(decoding: bytes.prefix(600), as: UTF8.self)
            XCTFail("Scanner \(scanned ? "read" : "fell back on") a document differently.\ndocument: \(shown)\nexpected: \(expected.prefix(800))\nactual:   \(actual.prefix(800))", file: file, line: line)
        }
        return false
    }

    /// Every line of a journal the real helper wrote, as the parity tests
    /// create them (`CommittedHistoryTests.fixture`).
    static func assertJournalMatchesFrozenDecoding(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var tally = Tally()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        for record in data.split(separator: 10, omittingEmptySubsequences: false) where !record.isEmpty {
            compare(Array(record), &tally, file: file, line: line)
        }
        XCTAssertEqual(tally.mismatches, 0, "Scanner parity on \(path): \(tally)", file: file, line: line)
    }

    func testGeneratedCorpusMatchesFrozenDecoding() throws {
        let count = testEnvironment("PI_HIST_SCAN_CORPUS").flatMap(Int.init) ?? 1_100_000
        var corpus = IndexScanCorpus(seed: 136), tally = Tally()
        for _ in 0..<count { Self.compare(corpus.document(), &tally) }
        print("HISTSCAN corpus " + tally.description + " kinds=\(corpus.kinds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        XCTAssertEqual(tally.mismatches, 0)
        // The corpus must exercise both paths, and both outcomes.
        XCTAssertGreaterThan(tally.scanned, count / 4)
        XCTAssertGreaterThan(tally.rejected, count / 10)
        XCTAssertGreaterThan(tally.accepted - tally.scanned, count / 10)
    }

    /// Every line of the generated seed-136 journals named in
    /// `PI_HIST_SCAN_FIXTURES` (colon-separated paths).
    func testSeed136FixturesMatchFrozenDecoding() throws {
        let paths = (testEnvironment("PI_HIST_SCAN_FIXTURES") ?? "").split(separator: ":").map(String.init)
        try XCTSkipIf(paths.isEmpty, "Set PI_HIST_SCAN_FIXTURES to generated journals")
        for path in paths {
            var tally = Tally()
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
            try data.withUnsafeBytes { raw in
                var start = 0
                while start < raw.count {
                    autoreleasepool {
                        let end = raw[start...].firstIndex(of: 10) ?? raw.count
                        Self.compare(Array(raw[start..<end]), &tally)
                        start = end + 1
                    }
                    if tally.mismatches > 20 { throw XCTSkip("Too many mismatches") }
                }
            }
            print("HISTSCAN fixture \(path) " + tally.description)
            XCTAssertEqual(tally.mismatches, 0, path)
            XCTAssertGreaterThan(tally.scanned, tally.documents / 2, path)
        }
    }

    /// The index's own row encoding keeps every field, absent and empty alike.
    func testIndexPayloadKeepsEveryField() throws {
        var corpus = IndexScanCorpus(seed: 7)
        func text(_ n: UInt64) -> String { ["", "a", "call-1", "é中🙂", String(repeating: "x", count: 300), "nul\u{0}byte"][Int(n % 6)] }
        func texts(_ n: UInt64) -> [String]? { n % 3 == 0 ? nil : (0..<Int(n % 4)).map { text(n &+ UInt64($0)) } }
        for _ in 0..<20_000 {
            let n = corpus.next(), m = corpus.next()
            let ref = HistoryOffset(id: text(n), parent: n & 1 == 0 ? nil : text(m), offset: m, length: Int(truncatingIfNeeded: Int64(bitPattern: n >> 3)),
                                    type: n & 2 == 0 ? nil : text(m >> 3), fromMessageID: n & 4 == 0 ? nil : text(m >> 5), keptIDs: texts(m >> 7),
                                    role: n & 8 == 0 ? nil : text(m >> 9), presentation: n & 16 != 0, adopted: n & 32 != 0, calls: texts(m >> 11),
                                    resultCall: n & 64 == 0 ? nil : text(m >> 13), operationID: n & 128 == 0 ? nil : text(m >> 15),
                                    selectedPrefix: texts(m >> 17), contextSelection: texts(m >> 19),
                                    turnStart: [nil, false, true][Int((n >> 8) % 3)], taskKey: n & 512 == 0 ? nil : text(m >> 21))
            let decoded = try ref.indexPayload.withUnsafeBytes { try HistoryOffset(indexPayload: $0) }
            XCTAssertEqual(decoded, ref)
        }
        XCTAssertThrowsError(try [UInt8]([1]).withUnsafeBytes { try HistoryOffset(indexPayload: $0) })
    }

    /// Rows inserted each after its parent are replayed in insertion order
    /// without a walk; any other chain is walked from its leaf. Both give
    /// the rows on the leaf's chain, root first.
    func testChainReplayFollowsTheLeafWithOrWithoutAWalk() throws {
        var corpus = IndexScanCorpus(seed: 11)
        for trial in 0..<40 {
            let index = try HistoryOffsetIndex(directory: URL(fileURLWithPath: scratchBase()))
            var parents: [String: String?] = [:], order: [String] = []
            let count = 1 + Int(corpus.next() % 300)
            for n in 0..<count {
                // Even trials are linear; odd ones branch from earlier rows.
                let parent: String? = n == 0 ? nil : trial % 2 == 0 || corpus.next() % 4 != 0 ? order.last : order[Int(corpus.next() % UInt64(order.count))]
                let id = "r\(n)"
                try index.insert(HistoryOffset(id: id, parent: parent, offset: UInt64(n), length: 1, type: "message"))
                parents[id] = parent; order.append(id)
            }
            let leaf = trial % 3 == 1 ? order[Int(corpus.next() % UInt64(order.count))] : order.last!
            var expected: [String] = [], id: String? = leaf
            while let current = id { expected.insert(current, at: 0); id = parents[current] ?? nil }
            try index.constructChain(leaf: leaf)
            var replayed: [String] = []
            try index.replayChain { replayed.append($0.id) }
            XCTAssertEqual(replayed, expected, "trial \(trial)")
        }
    }

    /// Documents whose outcome is known: what the scanner reads itself and
    /// what it leaves to `JSONDecoder`.
    func testScannerReadsPlainRecordsAndLeavesEveryUnusualOneToJSONDecoder() throws {
        let read: [String] = [
            #"{"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/"}"#,
            #"{"id":"u","message":{"content":"Question","role":"user"},"parentId":null,"type":"message"}"#,
            #"{"id":"a","message":{"content":[{"type":"text","text":"x"},{"type":"toolCall","id":"c","name":"read","arguments":{"path":"a"}},{"type":"toolCall","name":"x"}],"role":"assistant"},"parentId":"u","type":"message"}"#,
            #"{"id":"r","message":{"content":[],"role":"toolResult","toolCallId":"c","nativeTaskExecution":"e","nativeTaskRoot":"u"},"parentId":"a","type":"message"}"#,
            #"{"id":"d","message":{"content":"Mail","role":"user","nativeAgentDelivery":{"version":2}},"parentId":"r","type":"message"}"#,
            #"{"id":"p","customType":"pi-app.presentation.update.v1","data":{"id":"l","extra":[1,2]},"message":{"content":[],"role":"system","nativeKind":"requestLedger"},"type":"custom"}"#,
            #"{"id":"t","customType":"pi-app.task-terminal.v1","data":{"rootID":"u","executionID":"e","startedAt":1,"endedAt":2,"outcome":"completed","phase":"terminal","issuedCalls":0,"preparingCalls":0,"replies":1,"modelMs":0,"toolMs":0},"type":"custom"}"#,
            #"{"id":"c","nativeKeptIDs":["u","a"],"summary":"S","tokensBefore":10,"type":"compaction","nativeCompaction":null}"#,
            " \t{\"id\":\"w\",\"type\":\"custom\"}\r ",
        ]
        let left: [String] = [
            "\u{FEFF}" + #"{"id":"u","type":"message"}"#,
            #"{"id":"u","id":"v","type":"message"}"#,
            "{\"" + IndexScanCorpus.u("0069") + "d\":\"u\",\"type\":\"message\"}",
            "{\"id\":\"u\",\"\u{212A}\":1,\"type\":\"message\"}",
            "{\"id\":\"u" + IndexScanCorpus.u("0041") + "\",\"type\":\"message\"}",
            "{\"id\":\"u\",\"type\":\"message\",\"x\":\"" + IndexScanCorpus.u("D800") + "\"}",
            #"{"id":"u","type":"message",}"#,
            #"{"id":"u","type":"message","version":1.0}"#,
            #"{"id":"u","type":"message","version":-0}"#,
            #"{"id":"u","type":"branch","fromMessageId":"a","keptIds":[]}"#,
            #"{"id":"u","customType":"pi-app.native.state.v1","data":{},"type":"custom"}"#,
            #"{"id":"u","customType":"pi-app.native.context.v1","data":{"ids":[]},"type":"custom"}"#,
            #"{"id":"u","message":{"content":{"type":"text"},"role":"user"},"type":"message"}"#,
            #"{"id":"u","message":{"content":[null],"role":"user"},"type":"message"}"#,
            #"{"id":"u","message":{"nativeCompaction":{"version":2},"role":"user"},"type":"message"}"#,
            #"{"id":"u","message":{"nativeTaskExecution":"e","nativeTaskRoot":7},"type":"message"}"#,
            #"{"id":1,"type":"message"}"#,
            "[]",
            "",
        ]
        for text in read {
            var tally = Tally()
            XCTAssertTrue(Self.compare(Array(text.utf8), &tally), text)
            XCTAssertEqual(tally.scanned, 1, "Read by the scanner: \(text)")
        }
        for text in left {
            var tally = Tally()
            XCTAssertTrue(Self.compare(Array(text.utf8), &tally), text)
            XCTAssertEqual(tally.scanned, 0, "Left to JSONDecoder: \(text)")
        }
        // A task-root of another type is never read without an execution.
        var tally = Tally()
        XCTAssertTrue(Self.compare(Array(#"{"id":"u","message":{"nativeTaskRoot":7,"role":"user"},"type":"message"}"#.utf8), &tally))
        XCTAssertEqual(tally.scanned, 1)
    }
}

/// A seeded generator of journal lines: realistic records of every kind
/// the index reads, then mutations of their keys, values, encoding and
/// bytes (invalid UTF-8, escapes, surrogates, duplicate and escaped keys,
/// number forms, null and missing fields, wrong types, deep nesting, long
/// strings, byte-order marks, truncation).
struct IndexScanCorpus {
    private var state: UInt64
    private(set) var kinds: [String: Int] = [:]
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    private mutating func random() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    private mutating func below(_ n: Int) -> Int { Int(random() % UInt64(max(1, n))) }
    private mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    private mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }

    /// A JSON value whose strings and keys are raw bytes between quotes.
    indirect enum Node {
        case object([(key: [UInt8], value: Node)])
        case array([Node])
        case string([UInt8])
        case raw([UInt8])
    }
    /// A JSON escape, built so no tool reading this source decodes it.
    static let slash = String(UnicodeScalar(92))
    static func u(_ hex: String) -> String { slash + "u" + hex }
    private static func s(_ text: String) -> Node { .string(Array(text.utf8)) }
    private static func r(_ text: String) -> Node { .raw(Array(text.utf8)) }
    private static func k(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Values

    private mutating func id() -> String {
        switch below(10) {
        case 0: return UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012llx", random() & 0xFFFF_FFFF_FFFF))")!.uuidString
        case 1: return "record-\(below(5000))"
        case 2: return "id-ü-\(below(100))"
        case 3: return "🙂\(below(100))"
        case 4: return ""
        default: return pick(["u", "a", "r", "m", "t", "c"]) + "\(below(2000))" + (chance(30) ? "_z" : "")
        }
    }
    /// Raw string contents, usually plain, sometimes escaped or invalid.
    private mutating func stringBytes(plain: String) -> [UInt8] {
        switch below(40) {
        case 0: return Array(plain.utf8) + Array(Self.u("0041").utf8)
        case 1: return Array(#"\/\n\t\"\\\b\f\r"#.utf8) + Array(plain.utf8)
        case 2: return Array(plain.utf8) + Array((Self.u("D83D") + Self.u("DE00")).utf8)
        case 3: return Array(plain.utf8) + Array(Self.u("0000").utf8)
        case 4: return Array(plain.utf8) + pick([[0xC3, 0x28], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xFF], [0xE2, 0x82], [0xF0, 0x9F, 0x98], [0x80]])
        case 5: return Array(plain.utf8) + [pick([0x01, 0x09, 0x1F, 0x7F, 0x0D])]
        case 6: return Array(plain.utf8) + Array(pick([Self.slash + "x", Self.u("12G4"), Self.slash + "u", Self.slash + "u00", Self.slash + "'", Self.slash + "U0041"]).utf8)
        case 7: return Array(plain.utf8) + Array(pick([Self.u("D800"), Self.u("DC00"), Self.u("DC00") + Self.u("D800"), Self.u("D800") + Self.u("0041"), Self.u("D800") + "x", Self.u("DBFF") + Self.u("DFFF")]).utf8)
        case 8: return Array((plain + "é中🙂\u{212A}\u{FFFF}\u{2028}").utf8)
        default: return Array(plain.utf8)
        }
    }
    private mutating func text(_ plain: String) -> Node { .string(stringBytes(plain: plain)) }
    private mutating func number() -> Node {
        Self.r(pick(["0", "7", "-3", "12", "1730000000000", "0.5", "1.0", "1e2", "1E+2", "-1.5e-3", "100e-2", "123456789012345678", "1234567890123456789",
                     "9223372036854775807", "9223372036854775808", "-0", "01", "-", "1.", ".5", "+1", "NaN", "1e", "0x10", "--1", "1e999999",
                     String(repeating: "9", count: 40)]))
    }
    private mutating func scalar() -> Node {
        switch below(6) {
        case 0: return number()
        case 1: return Self.r(pick(["true", "false", "null", "tru", "nul", "True", "fals"]))
        default: return text("value \(below(100))")
        }
    }
    /// A value of another JSON type than a field expects.
    private mutating func wrong() -> Node {
        pick([Self.r("7"), Self.r("true"), Self.r("null"), .array([Self.s("x")]), .object([(Self.k("a"), Self.s("b"))]), Self.r("[]"), Self.r("{}"), Self.s("x")])
    }
    private mutating func nested(_ depth: Int) -> Node {
        var node: Node = scalar()
        for level in 0..<depth { node = level % 2 == 0 ? .array([node]) : .object([(Self.k("n"), node)]) }
        return node
    }
    /// A long string: usually kilobytes, rarely most of a megabyte.
    private mutating func long() -> Node {
        let unit = pick(["Long retained output line \\n", "x", "é", "🙂", "\\\"quoted\\\" ", "\\u00e9"])
        let count = below(500) == 0 ? 1_000_000 / unit.utf8.count : pick([100, 300, 1_000, 3_000])
        return .string(Array(String(repeating: unit, count: count).utf8))
    }
    /// A field's value: usually right, else null, a wrong type, an escaped,
    /// invalid or very long string.
    private mutating func field(_ right: Node) -> Node {
        switch below(30) {
        case 0: return Self.r("null")
        case 1: return wrong()
        case 2: return text("variant")
        default: return right
        }
    }
    private mutating func ids(_ count: Int) -> Node {
        var values: [Node] = (0..<count).map { _ in Self.s(id()) }
        if chance(5) { values.append(pick([Self.r("null"), Self.r("1"), .array([]), text("x")])) }
        return .array(values)
    }

    // MARK: Records

    private mutating func block() -> Node {
        switch below(6) {
        case 0: return .object([(Self.k("type"), Self.s("text")), (Self.k("text"), text("Answer text \(below(100))"))])
        case 1: return .object([(Self.k("type"), Self.s("thinking")), (Self.k("thinking"), text("Reasoning"))])
        case 2: return .object([(Self.k("type"), Self.s("image")), (Self.k("mimeType"), Self.s("image/png")), (Self.k("data"), Self.s("iVBORw0KGgo="))])
        default:
            var fields: [(key: [UInt8], value: Node)] = [(Self.k("type"), field(Self.s("toolCall"))), (Self.k("name"), Self.s(pick(["read", "bash", "subagent"]))),
                                                        (Self.k("arguments"), .object([(Self.k("path"), text("file.txt")), (Self.k("n"), number())]))]
            if !chance(10) { fields.insert((Self.k("id"), field(Self.s("call-\(below(500))"))), at: below(fields.count + 1)) }
            return .object(fields)
        }
    }
    private mutating func content(role: String) -> Node {
        switch below(10) {
        case 0: return Self.r("null")
        case 1: return wrong()
        case 2, 3: return text("Question \(below(1000))")
        default: return .array((0..<below(5)).map { _ in block() })
        }
    }
    private mutating func message(role: String) -> Node {
        var fields: [(key: [UInt8], value: Node)] = [(Self.k("role"), field(Self.s(role))), (Self.k("content"), content(role: role)),
                                                    (Self.k("timestamp"), Self.r("1730000000000"))]
        if role == "toolResult" { fields.append((Self.k("toolCallId"), field(Self.s("call-\(below(500))")))); fields.append((Self.k("toolName"), Self.s("read"))) }
        if chance(25) { fields.append((Self.k("nativeKind"), field(Self.s(pick(["requestLedger", "execution", "compaction"]))))) }
        if chance(15) { fields.append((Self.k("nativeOperationID"), field(Self.s("op-\(below(50))")))) }
        if chance(25) { fields.append((Self.k("nativeTaskExecution"), field(Self.s("exec-\(below(50))")))) }
        if chance(25) { fields.append((Self.k("nativeTaskRoot"), chance(80) ? field(Self.s("u\(below(50))")) : wrong())) }
        if chance(15) { fields.append((Self.k("nativeReplayEligible"), field(Self.r(pick(["true", "false"]))))) }
        if chance(10) { fields.append((Self.k("nativeAgentDelivery"), pick([Self.r("null"), .object([(Self.k("version"), Self.r("2"))]), Self.r("1"), Self.s("x")]))) }
        if chance(5) { fields.append((Self.k("nativeCompaction"), pick([Self.r("null"), .object([(Self.k("version"), Self.r("2")), (Self.k("sourceIDs"), ids(2)), (Self.k("protectedIDs"), ids(0)), (Self.k("keptIDs"), ids(1))])]))) }
        if chance(20) { fields.append((Self.k("usage"), .object([(Self.k("input"), number()), (Self.k("output"), number())]))) }
        if chance(10) { fields.append((Self.k("nativeResponseTimeline"), .object([(Self.k("segments"), .array([.object([(Self.k("kind"), Self.s("text"))])]))]))) }
        return .object(fields)
    }
    private mutating func task(valid: Bool) -> Node {
        var fields: [(key: [UInt8], value: Node)] = [
            (Self.k("rootID"), Self.s("u\(below(100))")), (Self.k("executionID"), Self.s("exec-\(below(100))")), (Self.k("startedAt"), Self.r(pick(["100", "1.5", "0"]))),
            (Self.k("endedAt"), Self.r(pick(["200", "250.25"]))), (Self.k("outcome"), Self.s(pick(["completed", "failed", "cancelled", "interrupted"]))),
            (Self.k("phase"), Self.s("terminal")), (Self.k("issuedCalls"), Self.r("1")), (Self.k("preparingCalls"), Self.r("0")), (Self.k("replies"), Self.r("1")),
            (Self.k("modelMs"), Self.r("12.5")), (Self.k("toolMs"), Self.r("3")), (Self.k("lastSourceID"), Self.s("a\(below(100))")), (Self.k("anchorSourceID"), Self.s("u\(below(100))"))]
        if !valid {
            let at = below(fields.count)
            switch below(4) {
            case 0: fields.remove(at: at)
            case 1: fields[at].value = wrong()
            case 2: fields[at].value = Self.r("-1")
            default: fields.removeAll { $0.key == Self.k("outcome") }
            }
        }
        return .object(fields)
    }
    private mutating func record() -> (String, Node) {
        let parent: Node = chance(10) ? Self.r("null") : Self.s(id())
        var fields: [(key: [UInt8], value: Node)] = []
        let kind: String
        switch below(24) {
        case 0:
            kind = "session"
            fields = [(Self.k("type"), Self.s("session")), (Self.k("version"), field(Self.r("3"))), (Self.k("id"), Self.s(id())), (Self.k("timestamp"), Self.s("2026-10-29T00:00:00Z")), (Self.k("cwd"), Self.s("/tmp"))]
        case 1...7:
            kind = "message"
            let role = pick(["user", "assistant", "assistant", "toolResult", "system"])
            fields = [(Self.k("type"), Self.s("message")), (Self.k("id"), field(Self.s(id()))), (Self.k("parentId"), parent), (Self.k("timestamp"), Self.s("2026")), (Self.k("message"), message(role: role))]
        case 8:
            kind = "compaction"
            fields = [(Self.k("type"), Self.s("compaction")), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent), (Self.k("summary"), text("Summary")),
                      (Self.k("nativeKeptIDs"), field(ids(below(4)))), (Self.k("tokensBefore"), number())]
            if chance(30) { fields.append((Self.k("keptIds"), field(ids(below(3))))) }
            if chance(30) { fields.append((Self.k("nativeCompactionVersion"), field(Self.r(pick(["2", "1", "2.0", "-0", "01"]))))) }
            if chance(30) { fields.append((Self.k("nativeCompaction"), pick([Self.r("null"), .object([(Self.k("version"), Self.r("2")), (Self.k("sourceIDs"), ids(2)), (Self.k("protectedIDs"), ids(0)), (Self.k("keptIDs"), ids(2)), (Self.k("operationId"), Self.s("op"))])]))) }
        case 9:
            kind = "branch"
            fields = [(Self.k("type"), Self.s("branch")), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent), (Self.k("fromMessageId"), field(Self.s(id()))), (Self.k("keptIds"), field(ids(3)))]
            if chance(40) { fields += [(Self.k("nativeBranchVersion"), Self.r("2")), (Self.k("selectedTimelinePrefix"), ids(2)), (Self.k("sourceTimelineDigest"), Self.s("d"))] }
            if chance(30) { fields.append((Self.k("nativeState"), .object([(Self.k("active"), Self.r("false")), (Self.k("queue"), .array([]))]))) }
        case 10:
            kind = "state"
            let data: Node = .object([(Self.k("active"), field(Self.r(pick(["true", "false"])))), (Self.k("queue"), .array([.object([(Self.k("turnID"), Self.s("q")), (Self.k("text"), text("queued"))])])),
                                      (Self.k("runStatus"), field(Self.s(pick(["failed", "completed"])))), (Self.k("errorMessage"), text("Failure"))])
            fields = [(Self.k("customType"), Self.s("pi-app.native.state.v1")), (Self.k("data"), field(data)), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent),
                      (Self.k("timestamp"), Self.s("2026")), (Self.k("type"), Self.s("custom"))]
        case 11, 12:
            kind = "presentation"
            let data: Node = chance(85) ? .object([(Self.k("id"), field(Self.s(id())))] + (chance(20) ? [(Self.k("note"), scalar())] : [])) : wrong()
            fields = [(Self.k("type"), Self.s("custom")), (Self.k("customType"), Self.s("pi-app.presentation.update.v1")), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent),
                      (Self.k("data"), data), (Self.k("message"), message(role: "system"))]
            if chance(10) { fields.removeAll { $0.key == Self.k("data") } }
        case 13, 14:
            kind = "task"
            fields = [(Self.k("type"), Self.s("custom")), (Self.k("customType"), Self.s("pi-app.task-terminal.v1")), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent),
                      (Self.k("data"), chance(10) ? wrong() : task(valid: chance(80)))]
        case 15:
            kind = "context"
            fields = [(Self.k("type"), Self.s("custom")), (Self.k("customType"), Self.s("pi-app.native.context.v1")), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent),
                      (Self.k("data"), field(.object([(Self.k("ids"), field(ids(3))), (Self.k("visibleIDs"), field(ids(2)))])))]
        case 16, 17:
            kind = "custom"
            fields = [(Self.k("type"), Self.s("custom")), (Self.k("customType"), field(Self.s(pick(["pi-app.native.v1", "pi-app.native.v5", "pi-app.family-run.v1", "pi-app.cost.v1", "agent_cut_prepared"])))),
                      (Self.k("id"), field(Self.s(id()))), (Self.k("parentId"), parent), (Self.k("data"), .object([(Self.k("epoch"), Self.s("e")), (Self.k("n"), number())]))]
            if chance(20) { fields.append((Self.k("version"), field(Self.r(pick(["1", "3", "1.0", "1e0"]))))) }
            if chance(20) { fields.append((Self.k("fromMessageId"), field(Self.s(id())))) }
        case 18:
            kind = "noid"
            fields = [(Self.k("type"), Self.s("message")), (Self.k("message"), message(role: "user"))]
        case 19:
            kind = "value"
            return (kind, pick([.array([scalar()]), scalar(), Self.r("{}"), .object([])]))
        default:
            kind = "plain"
            fields = [(Self.k("type"), Self.s("message")), (Self.k("id"), Self.s(id())), (Self.k("parentId"), parent),
                      (Self.k("message"), .object([(Self.k("role"), Self.s(pick(["user", "assistant"]))), (Self.k("content"), chance(50) ? Self.s("Plain text") : .array([block(), block()]))]))]
        }
        if chance(50) { fields.shuffle(using: &self) }
        return (kind, .object(fields))
    }

    // MARK: Mutations

    /// The object at `path` in `node`, changed by `body`.
    private mutating func mutateObject(_ node: inout Node, depth: Int = 0) {
        guard case .object(var fields) = node else { return }
        // Descend into the message, a data object or a block sometimes.
        if depth < 3, chance(35), let at = fields.indices.filter({ if case .object = fields[$0].value { return true }; if case .array = fields[$0].value { return true }; return false }).randomElement(using: &self) {
            if case .array(var items) = fields[at].value, !items.isEmpty {
                let item = below(items.count); mutateObject(&items[item], depth: depth + 1); fields[at].value = .array(items)
            } else { mutateObject(&fields[at].value, depth: depth + 1) }
            node = .object(fields); return
        }
        let keys = ["type", "id", "parentId", "customType", "data", "message", "version", "keptIds", "nativeKeptIDs", "fromMessageId", "nativeCompactionVersion",
                    "nativeCompaction", "role", "content", "toolCallId", "nativeKind", "nativeOperationID", "nativeTaskRoot", "nativeTaskExecution",
                    "nativeReplayEligible", "nativeAgentDelivery", "nativeState", "nativeBranchVersion"]
        switch below(12) {
        case 0 where !fields.isEmpty:   // duplicate a key, with the same or another value
            let at = below(fields.count)
            fields.insert((fields[at].key, chance(50) ? fields[at].value : pick([Self.r("null"), scalar(), wrong()])), at: below(fields.count + 1))
        case 1 where !fields.isEmpty:   // drop a key
            fields.remove(at: below(fields.count))
        case 2 where !fields.isEmpty:   // null or a wrong type
            fields[below(fields.count)].value = chance(50) ? Self.r("null") : wrong()
        case 3 where !fields.isEmpty:   // an escaped, decorated or look-alike key
            let at = below(fields.count), key = String(decoding: fields[at].key, as: UTF8.self)
            switch below(5) {
            case 0: fields[at].key = Array((Self.slash + "u00").utf8) + Array(String(format: "%02x", fields[at].key.first ?? 0x61).utf8) + Array(fields[at].key.dropFirst())
            case 1: fields[at].key = Array(key.replacingOccurrences(of: "K", with: "\u{212A}").utf8) + (key.contains("K") ? [] : Array("\u{212A}".utf8))
            case 2: fields[at].key = Array(key.uppercased().utf8)
            case 3: fields[at].key = Array((key + " ").utf8)
            default: fields[at].key = Array((key + "é").utf8)
            }
        case 4:   // a relevant key with a variant value
            fields.insert((Self.k(pick(keys)), field(pick([scalar(), wrong(), ids(2), Self.r("null")]))), at: below(fields.count + 1))
        case 5:   // deep nesting
            fields.insert((Self.k(chance(70) ? "deep" : pick(keys)), nested(pick([10, 63, 64, 65, 120, 511, 512, 513, 600]))), at: below(fields.count + 1))
        case 6:   // a long string
            fields.insert((Self.k(chance(80) ? "output" : pick(keys)), long()), at: below(fields.count + 1))
        case 7 where !fields.isEmpty:   // a string value made escaped, invalid or non-ASCII
            let at = below(fields.count)
            if case .string(let bytes) = fields[at].value { fields[at].value = .string(stringBytes(plain: String(decoding: bytes, as: UTF8.self))) }
        default: break
        }
        node = .object(fields)
    }
    private mutating func render(_ node: Node, into out: inout [UInt8]) {
        func space() { if chance(3) { out += pick([[0x20], [0x09], [0x0D], [0x20, 0x20], [0x0D, 0x0A]]) } }
        switch node {
        case .raw(let bytes): out += bytes
        case .string(let bytes): out.append(0x22); out += bytes; out.append(0x22)
        case .array(let items):
            out.append(0x5B); space()
            for (index, item) in items.enumerated() { if index > 0 { out.append(0x2C); space() }; render(item, into: &out); space() }
            out.append(0x5D)
        case .object(let fields):
            out.append(0x7B); space()
            for (index, field) in fields.enumerated() {
                if index > 0 { out.append(0x2C); space() }
                out.append(0x22); out += field.key; out.append(0x22); space(); out.append(0x3A); space()
                render(field.value, into: &out); space()
            }
            out.append(0x7D)
        }
    }
    /// One document of the corpus.
    mutating func document() -> [UInt8] {
        var (kind, node) = record()
        let mutations = chance(35) ? 0 : 1 + below(3)
        for _ in 0..<mutations { mutateObject(&node) }
        var out: [UInt8] = []
        render(node, into: &out)
        // Byte-level changes: encodings, framing, truncation and damage.
        if chance(12) {
            switch below(12) {
            case 0: out = [0xEF, 0xBB, 0xBF] + out
            case 1: out = pick([[0xFF, 0xFE], [0xFE, 0xFF], [0x00], [0x0C], [0xC2, 0xA0]]) + out
            case 2: out += Array(pick([" x", ",", "}", "]", "\u{0}", " \u{0C}", "{}"]).utf8)
            case 3 where out.count > 1: out = Array(out.prefix(below(out.count)))
            case 4 where !out.isEmpty: out.remove(at: below(out.count))
            case 5: out.insert(pick([0x22, 0x5C, 0x2C, 0x7D, 0x5D, 0x7B, 0x5B, 0x3A, 0x00, 0x80, 0xC3, 0x20, 0x09, 0x0D, 0x0C, 0x30, 0x2D]), at: below(out.count + 1))
            case 6 where !out.isEmpty: out[below(out.count)] = UInt8(truncatingIfNeeded: random())
            case 7:   // a trailing comma before a closing bracket
                if let at = out.indices.filter({ out[$0] == 0x7D || out[$0] == 0x5D }).randomElement(using: &self) { out.insert(0x2C, at: at) }
            case 8:   // UTF-16 of a plain record
                let text = String(decoding: out, as: UTF8.self)
                out = chance(50) ? text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } : text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            default: out = Array(" \t".utf8) + out + Array("\r".utf8)
            }
            kind += "+bytes"
        }
        if mutations > 0 { kind += "+fields" }
        kinds[kind, default: 0] += 1
        return out
    }
}

extension IndexScanCorpus: RandomNumberGenerator {
    mutating func next() -> UInt64 { random() }
}
