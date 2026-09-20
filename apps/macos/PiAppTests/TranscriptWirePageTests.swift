import XCTest
@testable import PiApp

/// The direct projector reads the helper's display rows out of the decoded
/// frame instead of encoding that frame back to JSON for Codable. These tests
/// hold the two answers identical — as values and as bytes — over a page the
/// real helper produced and over every row shape the wire can carry, and they
/// hold the fallback honest for everything the projector declines.
final class TranscriptWirePageTests: XCTestCase {
    private static let sorted: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }()
    private func codable(_ value: WireValue) throws -> [TranscriptMessage] {
        try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value))
    }
    /// Same rows, and the same bytes when written back out.
    private func assertIdentical(_ value: WireValue, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let projected = try TranscriptMessage.projected(value), decoded = try codable(value)
        XCTAssertEqual(projected, decoded, what, file: file, line: line)
        XCTAssertEqual(try Self.sorted.encode(projected), try Self.sorted.encode(decoded), what + " (bytes)", file: file, line: line)
        XCTAssertEqual(try TranscriptMessage.page(value), decoded, what + " (page)", file: file, line: line)
    }
    private func wire(_ object: Any) throws -> WireValue {
        try JSONDecoder().decode(WireValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// `fixtures/native/display-page.json` is a page the helper itself wrote —
    /// captured from `AgentSession.snapshot` after two plain turns, a committed
    /// compaction summary, an edit-and-resend branch, a reply that stopped at
    /// its output limit, a tool call with its result row, and a reply still
    /// arriving with reasoning and a live card. It is here so the projector is
    /// held against rows the helper really emits, not only against rows this
    /// test imagines.
    func testAPageTheHelperWroteProjectsExactlyAsCodableDecodesIt() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let url = repository.appendingPathComponent("fixtures/native/display-page.json")
        let value = try JSONDecoder().decode(WireValue.self, from: Data(contentsOf: url))
        let rows = try TranscriptMessage.projected(value)
        try assertIdentical(value, "helper page")
        // The fixture must keep earning its place.
        XCTAssertGreaterThanOrEqual(rows.count, 12)
        XCTAssertTrue(rows.contains { $0.kind == "compaction" && $0.detail?.isEmpty == false }, "no compaction summary")
        XCTAssertTrue(rows.contains { $0.kind == "branch" }, "no edit branch marker")
        XCTAssertTrue(rows.contains { $0.stopReason == "length" && $0.truncated == true }, "no capped reply")
        XCTAssertTrue(rows.contains { $0.role == "tool" }, "no tool result row")
        XCTAssertTrue(rows.contains { $0.state == "streaming" && $0.tools?.isEmpty == false }, "no live card")
        XCTAssertTrue(rows.contains { ($0.tools ?? []).contains { $0.state == "completed" && $0.durationMs != nil && $0.path == nil } },
                      "no settled card with a measured duration and an absent path")
        XCTAssertTrue(rows.contains { ($0.thinking?.isEmpty == false) }, "no reasoning")
    }

    /// Every field, at every shape the wire can give it.
    func testEveryRowShapeProjectsExactlyAsCodableDecodesIt() throws {
        func card(_ overrides: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["id": "call-1", "name": "read", "state": "completed", "input": "{\"path\":\"a.swift\"}",
                                        "output": "ok", "durationMs": 12.5, "truncated": false]
            for (key, item) in overrides { value[key] = item }
            return value
        }
        let rows: [(String, [String: Any])] = [
            ("bare required fields only", ["id": "m1", "role": "user", "text": "Question"]),
            ("every optional explicitly null", ["id": "m2", "role": "assistant", "text": "", "thinking": NSNull(), "tools": NSNull(),
                                                "state": NSNull(), "truncated": NSNull(), "stopReason": NSNull(), "kind": NSNull(),
                                                "detail": NSNull(), "at": NSNull(), "turn": NSNull(), "modelMs": NSNull(), "accounting": NSNull()]),
            ("every optional set", ["id": "m3", "role": "assistant", "text": "Answer", "thinking": "Reasoning", "tools": [card()],
                                    "state": "complete", "truncated": true, "stopReason": "length", "kind": "compaction",
                                    "detail": "Compacted 900 tokens · 4 messages kept", "at": 1_700_000_000_000, "turn": "t1", "modelMs": 840.25]),
            ("empty card list", ["id": "m4", "role": "assistant", "text": "No tools", "tools": []]),
            ("card with file counts", ["id": "m5", "role": "assistant", "text": "Edited", "tools": [card(["path": "/tmp/a.swift", "added": 12, "removed": 3])]]),
            ("card with nulled file counts", ["id": "m6", "role": "assistant", "text": "Ran", "tools": [card(["path": NSNull(), "added": NSNull(), "removed": NSNull(), "durationMs": NSNull()])]]),
            ("truncated card input", ["id": "m7", "role": "assistant", "text": "Cut", "tools": [card(["inputTruncated": true, "inputBytes": 200_000, "truncated": true])]]),
            ("card flags explicitly false", ["id": "m8", "role": "assistant", "text": "Whole", "tools": [card(["inputTruncated": false, "inputBytes": 0])]]),
            ("many cards", ["id": "m9", "role": "assistant", "text": "Batch", "tools": (0..<32).map { card(["id": "call-\($0)", "state": ["prepared", "preparing", "running", "completed", "failed"][$0 % 5]]) }]),
            ("tool result row", ["id": "m10", "role": "tool", "text": "fixture file contents", "tools": [], "state": "complete", "truncated": false]),
            ("branch marker", ["id": "m11", "role": "system", "kind": "branch", "text": "Edited from here · earlier replies stay in the journal", "tools": [], "state": "complete", "truncated": false]),
            ("app notice", ["id": "notice:retry:s", "role": "system", "kind": "notice", "text": "Retrying (attempt 2 of 3) after: overloaded"]),
            ("app failure with detail", ["id": "failure:run:s", "role": "system", "kind": "failure", "text": "Run failed.", "detail": "Queued follow-ups are paused."]),
            ("whole numbers as doubles", ["id": "m12", "role": "assistant", "text": "n", "at": 1.7e12, "modelMs": 0, "tools": [card(["added": 0.0, "removed": 4.0, "inputBytes": 23.0, "durationMs": 0])]]),
            ("unicode and escapes", ["id": "m13", "role": "assistant", "text": "🦉 \"quoted\" \\ / \n\t 漢字 \u{0}", "thinking": "\u{fffd}👩‍👩‍👧‍👦",
                                     "tools": [card(["input": "{\"q\":\"🦉/\\\\\"}", "output": "漢字\n"])]]),
            ("very long strings", ["id": "m14", "role": "assistant", "text": String(repeating: "long ", count: 4000), "thinking": String(repeating: "why ", count: 2000)]),
            ("negative and fractional", ["id": "m15", "role": "assistant", "text": "n", "modelMs": -1.5, "at": 0, "tools": [card(["added": -3, "durationMs": 0.0009])]]),
        ]
        for (what, row) in rows { try assertIdentical(try wire([row]), what) }
        try assertIdentical(try wire(rows.map(\.1)), "the whole corpus as one page")
        try assertIdentical(try wire([[String: Any]]()), "an empty page")
    }

    /// Anything the projector is not certain about falls back to Codable, and
    /// the fallback is what the app used to do.
    func testDeclinedShapesFallBackToTheSameAnswerCodableGives() throws {
        let declined: [(String, Any)] = [
            ("missing text", [["id": "m", "role": "user"]]),
            ("missing id", [["role": "user", "text": "t"]]),
            ("null role", [["id": "m", "role": NSNull(), "text": "t"]]),
            ("number where a string belongs", [["id": "m", "role": "user", "text": 7]]),
            ("string where a flag belongs", [["id": "m", "role": "user", "text": "t", "truncated": "yes"]]),
            ("flag where a number belongs", [["id": "m", "role": "user", "text": "t", "at": true]]),
            ("fractional integer", [["id": "m", "role": "user", "text": "t",
                                     "tools": [["id": "c", "name": "n", "state": "s", "input": "i", "output": "o", "truncated": false, "added": 1.5]]]]),
            ("card missing its flag", [["id": "m", "role": "user", "text": "t",
                                        "tools": [["id": "c", "name": "n", "state": "s", "input": "i", "output": "o"]]]]),
            ("card is not an object", [["id": "m", "role": "user", "text": "t", "tools": ["nope"]]]),
            ("tools is not a list", [["id": "m", "role": "user", "text": "t", "tools": ["id": "c"]]]),
            ("row is not an object", ["not a row"]),
            ("page is not a list", ["messages": []]),
            ("accounting present", [["id": "m", "role": "user", "text": "t",
                                     "accounting": ["requests": 2, "costSamples": 1, "cacheHits": 0, "cacheMisses": 1,
                                                    "cacheUnreported": 0, "cacheConflicts": 0, "cacheReadSamples": 0,
                                                    "cacheWriteSamples": 0, "expiredRecords": 0]]]),
        ]
        for (what, object) in declined {
            let value = try wire(object)
            XCTAssertThrowsError(try TranscriptMessage.projected(value), what)
            let fallback = try? TranscriptMessage.page(value), reference = try? codable(value)
            XCTAssertEqual(fallback, reference, what + ": the fallback must answer exactly what Codable answers")
            if what == "accounting present" {
                XCTAssertEqual(reference?.first?.accounting?.requests, 2, "the fallback must still carry accounting through")
            }
        }
    }

    func testWholePageCostsLessThanTheCodableRoundTrip() throws {
        let rows: [[String: Any]] = (0..<300).map { index in
            ["id": "m\(index)", "role": index.isMultiple(of: 2) ? "user" : "assistant",
             "text": "Row \(index). " + String(repeating: "Keep this conversation's exact native layout and selectable text. ", count: 8),
             "thinking": "", "tools": [], "state": "complete", "truncated": false,
             "at": Double(index) * 1000, "turn": "m\(index - index % 2)"]
        }
        let value = try wire(rows)
        try assertIdentical(value, "the 300-row page")
        _ = try TranscriptMessage.projected(value); _ = try codable(value)
        var round = 0.0, direct = 0.0
        for _ in 0..<20 {
            var start = ProcessInfo.processInfo.systemUptime
            _ = try codable(value)
            round += ProcessInfo.processInfo.systemUptime - start
            start = ProcessInfo.processInfo.systemUptime
            _ = try TranscriptMessage.projected(value)
            direct += ProcessInfo.processInfo.systemUptime - start
        }
        print(String(format: "PERF 300-row page into rows: Codable round trip %.3f ms, direct projection %.3f ms", round * 50, direct * 50))
        XCTAssertLessThan(direct, round, "The direct projection must not be slower than the round trip it replaces")
    }
}
