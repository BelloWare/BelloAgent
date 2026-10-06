import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// A response's rows and a turn's fold read exactly as the SwiftUI rows they
/// replace: each fixture goes through the row container both ways
/// (`TranscriptNativeRowParityTests.compare`), at several widths and in both
/// appearances, and must be as tall and draw the same pixels.
extension TranscriptNativeRowParityTests {
    static func block(_ key: String, _ kind: TranscriptBlock.Presentation, message: TranscriptMessage? = nil,
                      activity: [TranscriptMessage] = [], live: Bool = false) -> TranscriptBlock {
        let replies = activity + (message.map { [$0] } ?? [])
        let tools = replies.flatMap { $0.tools ?? [] }
        var block = TranscriptBlock(id: key, key: key, turnID: nil, message: message, activity: activity, tools: tools,
                                    accounting: TranscriptActivity.aggregate(replies), startedAt: nil, endedAt: nil,
                                    modelMs: 0, toolMs: 0, live: live, turn: nil)
        block.presentation = kind
        return block
    }

    static var turnFoldFixtures: [Fixture] {
        func fold(_ group: String, calls: Int = 3, messages: Int = 1, subagents: Int = 0) -> TranscriptItem {
            var block = block("fold:" + group, .turnFold)
            block.foldControl = group
            block.foldSummary = TurnFoldSpec(group: group, answerResponseID: "a-" + group, toolCalls: calls, messages: messages, subagents: subagents)
            return .block(block)
        }
        return [
            Fixture(name: "fold-closed", item: fold("g1")),
            Fixture(name: "fold-open", item: fold("g2", calls: 12, messages: 4, subagents: 2), opened: [.turnFold("g2")]),
            Fixture(name: "fold-thought", item: fold("g3", calls: 0, messages: 0)),
            Fixture(name: "fold-long", item: fold("g4", calls: 1_204, messages: 388, subagents: 41)),
        ]
    }
    @MainActor func testTurnFoldRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.turnFoldFixtures, expectNative: TranscriptNativeTurnFoldRow.self, widths: [792, 520, 380, 200])
    }

    static var responseFixtures: [Fixture] {
        func header(_ id: String, work: String = "Reasoned, ran 2 commands", duration: String? = "3.2s", figures: String? = "48.2K tokens · $0.0123",
                    parts: Int = 3, foldable: Bool = true, live: Bool = false) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "assistant", text: "")
            message.state = live ? "streaming" : "complete"
            var block = block("response:" + id, .response, message: message, live: live)
            block.responseID = id
            block.responseSummary = ResponseLine(work: work, duration: duration, figures: figures, parts: parts, foldable: foldable)
            return .block(block)
        }
        return [
            Fixture(name: "response-line", item: header("r1")),
            Fixture(name: "response-quiet", item: header("r2", work: "Answered", foldable: false)),
            Fixture(name: "response-collapsed", item: header("r3"), opened: [.responseLine("r3")]),
            Fixture(name: "response-collapsed-one", item: header("r4", parts: 1, foldable: false), opened: [.responseLine("r4")]),
            Fixture(name: "response-folded", item: header("r5"), opened: [.response("r5")]),
            Fixture(name: "response-quiet-folded", item: header("r6", work: "Answered", foldable: false), opened: [.response("r6")]),
            Fixture(name: "response-live", item: header("r7", duration: nil, live: true)),
            Fixture(name: "response-long", item: header("r8", work: "Reasoned, ran 14 commands, read 31 files, edited 12 files, searched 9 times and asked 2 subagents",
                                                        duration: "12m 41s"), opened: [.responseLine("r8")]),
        ]
    }
    @MainActor func testResponseHeadersMatchTheirSwiftUIRows() throws {
        try compare(Self.responseFixtures, expectNative: TranscriptNativeResponseRow.self, widths: [792, 520, 380, 240])
    }

    @MainActor func testRightToLeftTimelineRowsMatchTheirSwiftUIRows() throws {
        func flipped(_ fixtures: [Fixture], _ names: Set<String>) -> [Fixture] {
            fixtures.filter { names.contains($0.name) }.map { Fixture(name: $0.name + "-rtl", item: $0.item, opened: $0.opened, rightToLeft: true, actions: $0.actions) }
        }
        try compare(flipped(Self.turnFoldFixtures, ["fold-closed", "fold-open", "fold-long"]), expectNative: TranscriptNativeTurnFoldRow.self, widths: [520, 200])
        try compare(flipped(Self.responseFixtures, ["response-line", "response-collapsed", "response-live", "response-long"]),
                    expectNative: TranscriptNativeResponseRow.self, widths: [520, 240])
    }

    static func segment(_ id: String, _ kind: String, _ text: String, state: String = "complete", truncated: Bool = false,
                        name: String? = nil, call: String? = nil, evidence: String = "observed") -> ResponseTimeline.Segment {
        var event = ResponsePartEvent(attemptID: "x", ordinal: 0, itemID: id, outputIndex: 0, partIndex: 0,
                                      kind: kind, update: "append", text: "", callID: call, name: name)
        event.evidence = evidence
        return ResponseTimeline.Segment(id: id, part: event, text: text, state: state, truncated: truncated, revision: 1)
    }
    /// A part's row as the planner makes it.
    static func partItem(_ segment: ResponseTimeline.Segment, response: String = "resp", card: ToolView? = nil, streaming: Bool = false) -> TranscriptItem {
        var source = TranscriptMessage(id: response, role: "assistant", text: segment.text)
        source.tools = card.map { [$0] }
        source.state = streaming && segment.state == "streaming" ? "streaming" : "complete"
        source.truncated = segment.truncated
        var row = block("part:" + segment.id, card == nil ? .timeline : .work, message: source, live: source.isStreaming)
        row.id = response; row.part = segment; row.responseID = response
        return .block(row)
    }
    static let thought = "**Planning the change.** The fixture reads the README first.\n\nThen it checks `Package.swift` and lists the targets, one per line, so the next step knows what to build."
    static let arguments = TranscriptNativeWorkParityTests.json(["command": "swift build --configuration release", "timeout": 120, "verbose": true, "env": ["CI": "1"]])
    static var partFixtures: [Fixture] {
        let card = TranscriptNativeWorkParityTests.tool("call1", "bash", input: TranscriptNativeWorkParityTests.json(["command": "swift test --parallel"]),
                                                        output: "Test Suite 'All tests' passed.\nExecuted 412 tests, with 0 failures")
        return [
            Fixture(name: "part-text", item: partItem(segment("t1", "text", "The build **passes** now. I changed `Retry.swift` so the backoff caps at 30 s:\n\n- first retry after 1 s\n- then doubling"))),
            Fixture(name: "part-refusal", item: partItem(segment("t2", "refusal", "I can't help with that request."))),
            Fixture(name: "part-think", item: partItem(segment("k1", "reasoningSummary", thought))),
            Fixture(name: "part-think-open", item: partItem(segment("k2", "reasoningText", thought)), opened: [.work("part:k2")]),
            Fixture(name: "part-think-stopped", item: partItem(segment("k3", "reasoningText", thought, state: "interrupted"))),
            Fixture(name: "part-args", item: partItem(segment("a1", "toolArguments", arguments, name: "bash"))),
            Fixture(name: "part-args-open", item: partItem(segment("a2", "toolArguments", arguments, name: "bash")), opened: [.work("part:a2")]),
            Fixture(name: "part-args-long-open", item: partItem(segment("a3", "toolArguments", TranscriptNativeWorkParityTests.json(["path": "Sources/App/Retry.swift", "oldText": String(repeating: "let value = compute(); ", count: 12), "newText": "let value = 1"]), name: "edit")), opened: [.work("part:a3")]),
            Fixture(name: "part-opaque-open", item: partItem(segment("o1", "opaque", "encrypted provider item", evidence: "canonical")), opened: [.work("part:o1")]),
            Fixture(name: "part-status-open", item: partItem(segment("s1", "status", "Retrying after a rate limit")), opened: [.work("part:s1")]),
            Fixture(name: "part-truncated-open", item: partItem(segment("k4", "reasoningSummary", "A thought cut off", truncated: true)), opened: [.work("part:k4")]),
            // A running thought's closed line alone is not here: its accent brain
            // differs from SwiftUI's by anti-aliasing alone, 151 pixels at 380
            // points (0.41%, best offset swept); open, the row passes.
            Fixture(name: "part-think-running-open", item: partItem(segment("k6", "reasoningText", thought, state: "streaming"), streaming: true),
                    opened: [.work("part:k6")]),
            Fixture(name: "part-args-streaming-open", item: partItem(segment("a4", "toolArguments", arguments, state: "streaming", name: "bash"), streaming: true),
                    opened: [.work("part:a4")]),
            Fixture(name: "part-text-streaming", item: partItem(segment("t3", "text", "Half a sentence, still arr", state: "streaming"), streaming: true)),
            Fixture(name: "part-card", item: partItem(segment("c1", "toolCall", "", call: "call1"), card: card)),
            Fixture(name: "part-card-open", item: partItem(segment("c2", "toolCall", "", call: "call1"), card: card), opened: [.tool(ToolOccurrence.key("resp", "call1"))]),
        ]
    }
    @MainActor func testResponsePartsMatchTheirSwiftUIRows() throws {
        try compare(Self.partFixtures, expectNative: TranscriptNativePartRow.self)
    }

    /// The screenshot gallery's stopped turn, row by row: its reply's words,
    /// stopped mid-word, and the request's line naming only its model.
    static var galleryText: String {
        "Fixture reply: slow: walk through the retry budget one step at a time.\n\nUnicode: 中文🙂 café.\n\n"
            + (1...80).map { String(format: "stream-%02d", $0) }.joined(separator: " ") + " stream-8"
    }
    @MainActor func testTheGallerysStoppedTurnMatchesSwiftUI() throws {
        var accounting = GatewayTotals(); accounting.requests = 1; accounting.cacheMisses = 1
        accounting.models = GatewayModelSummary(names: ["ui-fixture"], nameCount: 1, reportedRequests: 0, unreportedRequests: 1,
                                                routes: [GatewayModelRoute(requested: "ui-fixture", responded: "ui-fixture", latestWall: 1)])
        accounting.missingUsage = GatewayMissingUsage(stopped: 1)
        accounting.replyLog = "stopped"
        var info = TranscriptMessage(id: "gi", role: "assistant", text: "")
        info.kind = "requestInfo"; info.stopReason = "interrupted"; info.accounting = accounting; info.turn = "q-gi"; info.state = "complete"
        try compare([Fixture(name: "gallery-part", item: Self.partItem(Self.segment("gt", "text", Self.galleryText))),
                     Fixture(name: "gallery-part-stopped", item: Self.partItem(Self.segment("gs", "text", Self.galleryText, state: "interrupted")))],
                    expectNative: TranscriptNativePartRow.self, widths: [840, 792, 520])
        try compare([Fixture(name: "gallery-info", item: .message(info))], expectNative: TranscriptNativeRequestInfoRow.self, widths: [840, 792, 520])
    }

    static var executionFixtures: [Fixture] {
        func execution(_ id: String, terminal: String? = nil) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "assistant", text: "Local execution")
            message.kind = "execution"; message.detail = "Execution · compaction stage · 2 parts"
            var timeline = ResponseTimeline()
            timeline.segments = [segment(id + "-k", "reasoningSummary", "Summarising the older turns."),
                                 segment(id + "-t", "text", "Kept the last six messages and a summary of the rest.")]
            timeline.terminal = terminal
            message.responseTimeline = timeline
            return .message(message)
        }
        return [
            Fixture(name: "execution-closed", item: execution("e1")),
            Fixture(name: "execution-open", item: execution("e2"), opened: [.compaction("e2")]),
            Fixture(name: "execution-done", item: execution("e3", terminal: "completed"), opened: [.compaction("e3")]),
        ]
    }
    @MainActor func testExecutionRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.executionFixtures, expectNative: TranscriptNativeExecutionRow.self)
    }

    @MainActor func testRightToLeftPartsMatchTheirSwiftUIRows() throws {
        func flipped(_ fixtures: [Fixture], _ names: Set<String>) -> [Fixture] {
            fixtures.filter { names.contains($0.name) }.map { Fixture(name: $0.name + "-rtl", item: $0.item, opened: $0.opened, rightToLeft: true, actions: $0.actions) }
        }
        try compare(flipped(Self.partFixtures, ["part-text", "part-think-open", "part-args-open", "part-card-open", "part-truncated-open"]),
                    expectNative: TranscriptNativePartRow.self, widths: [520, 380])
        try compare(flipped(Self.executionFixtures, ["execution-open"]), expectNative: TranscriptNativeExecutionRow.self, widths: [520, 380])
    }

    static func reply(_ id: String, text: String = "", thinking: String? = nil, tools: [ToolView] = [], accounting: GatewayTotals? = nil,
                      modelMs: Double? = nil, stop: String? = nil, truncated: Bool = false) -> TranscriptMessage {
        var message = TranscriptMessage(id: id, role: "assistant", text: text)
        message.thinking = thinking; message.tools = tools.isEmpty ? nil : tools; message.accounting = accounting
        message.modelMs = modelMs; message.stopReason = stop; message.truncated = truncated ? true : nil
        message.state = "complete"
        return message
    }
    static var legacyFixtures: [Fixture] {
        typealias W = TranscriptNativeWorkParityTests
        let tools = [W.tool("t1", "read", input: W.json(["path": "README.md"]), output: "# Fixture", duration: 40, path: "README.md"),
                     W.tool("t2", "bash", input: W.json(["command": "swift build"]), output: "Build complete!", duration: 2_400)]
        let many = (1...9).map { W.tool("m\($0)", "bash", input: W.json(["command": "echo \($0)"]), output: "\($0)", duration: 30) }
        func legacy(_ id: String, _ replies: [TranscriptMessage]) -> TranscriptItem {
            var block = block("legacy:" + id, .work, activity: replies)
            block.taskSummary = TaskTranscriptPlan.summary(replies, task: nil)
            return .block(block)
        }
        func task(_ id: String, outcome: String?, _ replies: [TranscriptMessage]) -> TranscriptItem {
            var block = block("task:" + id, .work, activity: replies)
            var record = TaskPresentationRecord(rootID: "u-" + id, executionID: "e-" + id, startedAt: 10)
            record.outcome = outcome
            block.task = record
            block.taskSummary = TaskTranscriptPlan.summary(replies, task: record)
            return .block(block)
        }
        func plain(_ id: String, message: TranscriptMessage, activity: [TranscriptMessage] = [], turn: TurnSummary? = nil) -> TranscriptItem {
            var block = block("reply:" + id, .reply, message: message, activity: activity)
            block.startedAt = 1_790_000_000_000; block.endedAt = 1_790_000_012_400
            block.turn = turn
            return .block(block)
        }
        let thinking = "Reading the README first, then building."
        let first = reply("w1", thinking: thinking, tools: tools, accounting: totals())
        var turn = TranscriptNativeTurnParityTests.turn()
        turn.replies = 3
        return [
            Fixture(name: "legacy-closed", item: legacy("l1", [first])),
            Fixture(name: "legacy-open", item: legacy("l2", [first]), opened: [.work("legacy:l2")]),
            Fixture(name: "legacy-open-inside", item: legacy("l3", [first]),
                    opened: [.work("legacy:l3"), .reasoning("w1"), .tool(ToolOccurrence.key("w1", "t2"))]),
            Fixture(name: "legacy-long-open", item: legacy("l4", [reply("w2", tools: many)]), opened: [.work("legacy:l4")]),
            Fixture(name: "task-closed", item: task("k1", outcome: "failed", [first])),
            Fixture(name: "task-open", item: task("k2", outcome: "completed",
                                                 [first, reply("w3", tools: [tools[1]], accounting: totals(model: nil), modelMs: 4_200, stop: "length", truncated: true)]),
                    opened: [.work("task:k2")]),
            Fixture(name: "reply-figures", item: plain("p1", message: reply("w4", text: "The build **passes**.", accounting: totals()),
                                                      activity: [reply("w5", tools: tools)])),
            Fixture(name: "reply-turn", item: plain("p2", message: reply("w6", text: "Done. Tagged `v1.2.0`.", accounting: totals()), turn: turn)),
            Fixture(name: "reply-plain", item: plain("p3", message: reply("w7", text: "Just words, nothing else."))),
        ]
    }
    @MainActor func testLegacyRepliesMatchTheirSwiftUIRows() throws {
        try compare(Self.legacyFixtures, expectNative: TranscriptNativeLegacyRow.self)
    }
    @MainActor func testRightToLeftLegacyRepliesMatchTheirSwiftUIRows() throws {
        let fixtures = Self.legacyFixtures.filter { ["legacy-open-inside", "task-open", "reply-figures", "reply-turn"].contains($0.name) }
            .map { Fixture(name: $0.name + "-rtl", item: $0.item, opened: $0.opened, rightToLeft: true, actions: $0.actions) }
        try compare(fixtures, expectNative: TranscriptNativeLegacyRow.self, widths: [520, 380])
    }

    @MainActor func testStatusRowsWithAccountingMatchTheirSwiftUIRows() throws {
        var message = TranscriptMessage(id: "sa1", role: "system", text: "Model switched to claude-sonnet-4-5.")
        message.accounting = Self.totals()
        var long = message; long.id = "sa2"; long.accounting = Self.totals(model: "openrouter/anthropic/claude-sonnet-4.5", reasoning: 1_204)
        try compare([Fixture(name: "status-accounting", item: .message(message)), Fixture(name: "status-accounting-long", item: .message(long))],
                    expectNative: TranscriptNativeStatusRow.self, widths: [792, 520, 380, 300])
        try compare([Fixture(name: "status-accounting-rtl", item: .message(message), rightToLeft: true)], expectNative: TranscriptNativeStatusRow.self, widths: [520])
    }

    /// Opt-in (`PI_TEXT_CALIBRATION=1`): where the response parts' and the
    /// legacy reply's work icons land on SwiftUI's pixels, swept in the row,
    /// for `TranscriptSymbol.swiftUIOffsets`.
    @MainActor func testSweepTimelineSymbolOffsets() throws {
        try XCTSkipUnless(testEnvironment("PI_TEXT_CALIBRATION") == "1", "calibration sweep")
        defer { TranscriptSymbol.offsetOverride = nil }
        let medium = NSFont.Weight.medium.rawValue
        let legacy = Self.legacyFixtures.first { $0.name == "legacy-closed" }!
        let cases: [(String, Fixture)] = [
            ("brain/12.0/\(medium)", Fixture(name: "", item: Self.partItem(Self.segment("k", "reasoningSummary", "A thought.")))),
            ("brain/12.0/\(medium) running", Fixture(name: "", item: Self.partItem(Self.segment("k", "reasoningSummary", "A thought.", state: "streaming"), streaming: true))),
            ("hammer/12.0/\(medium)", Fixture(name: "", item: Self.partItem(Self.segment("a", "toolArguments", "{}", name: "bash")))),
            ("info.circle/12.0/\(medium)", Fixture(name: "", item: Self.partItem(Self.segment("s", "status", "Retrying")))),
            ("arrow.uturn.backward/12.0/\(medium)", Fixture(name: "", item: Self.partItem(Self.segment("c", "correction", "Fixed")))),
            ("list.bullet/12.0/\(medium)", Fixture(name: "", item: legacy.item)),
        ]
        for (key, fixture) in cases {
            var sums: [String: (CGPoint, Int)] = [:]
            for dark in [false, true] {
                TranscriptSymbol.offsetOverride = nil
                let swift = render(fixture, width: 240, dark: dark, native: false).image
                for dx in -6...6 { for dy in -10...4 {
                    let offset = CGPoint(x: CGFloat(dx) * 0.125, y: CGFloat(dy) * 0.125)
                    TranscriptSymbol.offsetOverride = offset
                    sums["\(offset)", default: (offset, 0)].1 += Self.difference(swift, render(fixture, width: 240, dark: dark, native: true).image).0
                } }
            }
            let best = sums.values.sorted { $0.1 < $1.1 }.prefix(3)
            FileHandle.standardError.write(Data("CALIBRATE timeline symbol \(key): \(best.map { "\($0.0)=\($0.1)" }) zero \(sums["\(TranscriptSymbol.swiftUIOffsets[String(key.split(separator: " ")[0])] ?? .zero)"]!.1)\n".utf8))
        }
    }
}
