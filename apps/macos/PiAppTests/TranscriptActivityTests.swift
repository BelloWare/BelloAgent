import XCTest
@testable import PiApp

/// The transcript's reading of a conversation, ported case for case from the
/// transcript's former JavaScript suite: descriptions, summaries, blocks and
/// turns, usage aggregation, per-request accounting lines, diffs and clocks.
final class TranscriptActivityTests: XCTestCase {
    private func tool(_ id: String, _ name: String, state: String = "completed", input: String = "{}", output: String = "", durationMs: Double? = nil, truncated: Bool = false, path: String? = nil, added: Int? = nil, removed: Int? = nil) -> ToolView {
        ToolView(id: id, name: name, state: state, input: input, output: output, durationMs: durationMs, truncated: truncated, path: path, added: added, removed: removed)
    }
    private func message(_ id: String, _ role: String, _ text: String, thinking: String? = nil, tools: [ToolView]? = nil, state: String? = nil, accounting: GatewayTotals? = nil, kind: String? = nil, at: Double? = nil, turn: String? = nil, modelMs: Double? = nil) -> TranscriptMessage {
        TranscriptMessage(id: id, role: role, text: text, thinking: thinking, tools: tools, state: state, truncated: nil, accounting: accounting, kind: kind, detail: nil, at: at, turn: turn, modelMs: modelMs)
    }
    private func reported(_ patch: (inout GatewayTotals) -> Void = { _ in }) -> GatewayTotals {
        var a = GatewayTotals()
        a.requests = 1; a.costSamples = 1; a.costUSD = 0.000421875
        a.cacheHits = 0; a.cacheMisses = 1; a.cacheUnreported = 0; a.cacheConflicts = 0
        a.cacheReadTokens = 0; a.cacheWriteTokens = 0; a.cacheReadSamples = 1; a.cacheWriteSamples = 1
        a.tokens = GatewayTokenTotals(input: 38, output: 423, total: 461, inputSamples: 1, outputSamples: 1, samples: 1)
        patch(&a)
        return a
    }
    private func blocks(_ items: [TranscriptItem]) -> [TranscriptBlock] { items.compactMap { if case .block(let block) = $0 { return block }; return nil } }
    private func kinds(_ items: [TranscriptItem]) -> [String] { items.map { if case .block(let block) = $0 { return "block:" + (block.message?.id ?? "-") }; return "message" } }

    func testActivityDescriptionsSummariesAndDurationsReadAsVerbAndObject() {
        let bash = tool("b", "bash", input: "{\"command\":\"npm test -- --watch=false\\necho done\"}", durationMs: 1234)
        let edit = tool("e", "edit", input: "{\"path\":\"/repo/Sources/App/Retry.swift\",\"oldText\":\"a\",\"newText\":\"b\"}", output: "Edited", durationMs: 5, path: "/repo/Sources/App/Retry.swift", added: 11, removed: 3)
        var created = edit; created.id = "w"; created.name = "write"; created.added = 40; created.removed = 0
        XCTAssertEqual(TranscriptActivity.describe(bash), ActionDescription(kind: .command, verb: "Ran", object: "npm test -- --watch=false"))
        XCTAssertEqual(TranscriptActivity.describe(edit), ActionDescription(kind: .write, verb: "Edited", object: "App/Retry.swift", path: "/repo/Sources/App/Retry.swift"))
        XCTAssertEqual(TranscriptActivity.describe(created).verb, "Created")
        XCTAssertEqual(TranscriptActivity.describe(tool("g", "grep", input: "{\"pattern\":\"TODO\"}")).object, "TODO")
        XCTAssertEqual(TranscriptActivity.describe(tool("m", "mcp", input: "{\"server\":\"fixture\",\"tool\":\"echo\"}")).object, "fixture · echo")
        let read = { (id: String, path: String, state: String) in self.tool(id, "read", state: state, input: "{\"path\":\"\(path)\"}") }
        XCTAssertEqual(TranscriptActivity.summarize([bash, edit, created, read("r", "x", "completed")]), "Edited 1 file, ran 1 command, read 1 file", "two calls on one path are one file")
        var elsewhere = created; elsewhere.path = "/repo/Sources/App/New.swift"
        XCTAssertEqual(TranscriptActivity.summarize([bash, edit, elsewhere]), "Edited 2 files, ran 1 command")
        XCTAssertEqual(TranscriptActivity.summarize([read("r1", "a", "completed"), read("r2", "a", "completed"), read("r3", "a", "completed")]), "Read 1 file", "three reads of one file are one file, not three")
        XCTAssertEqual(TranscriptActivity.summarize([read("r1", "a", "completed"), tool("l", "ls", input: "{\"path\":\"/repo\"}")]), "Read 1 file, listed 1 directory", "a listing is not a file read")
        var failedEdit = edit; failedEdit.id = "e2"; failedEdit.state = "failed"
        XCTAssertEqual(TranscriptActivity.summarize([edit, failedEdit, read("r4", "b", "cancelled"), read("r5", "c", "running")]), "Edited 1 file, 1 call failed, 1 call skipped", "failed and skipped calls are attempts, never work done; a running one waits")
        var running = bash; running.state = "running"
        XCTAssertEqual(TranscriptActivity.describe(running).verb, "Running"); XCTAssertEqual(TranscriptActivity.describe(failedEdit).verb, "Failed editing"); XCTAssertEqual(TranscriptActivity.describe(read("r6", "x", "cancelled")).verb, "Skipped reading")
        var preparing = bash; preparing.state = "preparing"; var failed = bash; failed.state = "failed"; var cancelled = bash; cancelled.state = "cancelled"
        XCTAssertEqual([bash, preparing, failed, cancelled].map(TranscriptActivity.outcome), [.done, .running, .failed, .cancelled])
        XCTAssertEqual(TranscriptActivity.describe(tool("m1", "mcp", input: "{\"action\":\"list\"}")), ActionDescription(kind: .mcp, verb: "Listed", object: "MCP servers"))
        XCTAssertEqual(TranscriptActivity.describe(tool("m2", "mcp", input: "{\"action\":\"list\",\"server\":\"fixture\"}")), ActionDescription(kind: .mcp, verb: "Listed", object: "tools on fixture"))
        XCTAssertEqual(TranscriptActivity.describe(tool("m3", "mcp", input: "{\"action\":\"describe\",\"targets\":[{\"server\":\"a\",\"tool\":\"x\"},{\"server\":\"a\",\"tool\":\"y\"}]}")), ActionDescription(kind: .mcp, verb: "Loaded", object: "2 tool schemas"))
        XCTAssertEqual(TranscriptActivity.describe(tool("m4", "mcp", state: "running", input: "{\"action\":\"invoke\",\"server\":\"fixture\",\"tool\":\"echo\",\"arguments\":{}}")), ActionDescription(kind: .mcp, verb: "Calling", object: "fixture · echo"))
        var otherFile = edit; otherFile.id = "e3"; otherFile.state = "failed"; otherFile.path = "/other.swift"
        XCTAssertEqual(TranscriptActivity.changedFiles([edit, created, otherFile]), 1, "only completed edits count toward files changed")
        XCTAssertEqual(TranscriptActivity.formatDuration(400), "0.4s"); XCTAssertEqual(TranscriptActivity.formatDuration(72_000), "1m 12s"); XCTAssertEqual(TranscriptActivity.formatDuration(3_753_000), "1h 2m")
        XCTAssertEqual(TranscriptActivity.formatDuration(12_500), "13s"); XCTAssertEqual(TranscriptActivity.formatDuration(-1), "")
        XCTAssertEqual(TranscriptActivity.state(of: [bash, running]), .running); XCTAssertEqual(TranscriptActivity.state(of: [bash, failed]), .failed); XCTAssertEqual(TranscriptActivity.state(of: [bash]), .completed)
        XCTAssertEqual(TranscriptActivity.summarizeWork([], reasoned: true), "Reasoned"); XCTAssertEqual(TranscriptActivity.summarizeWork([bash], reasoned: true), "Reasoned, ran 1 command"); XCTAssertNil(TranscriptActivity.summarizeWork([], reasoned: false))
    }

    func testToolRoundsFoldIntoTheReplyAndTurnsCarryTheirTotals() {
        let items = TranscriptActivity.blocks(of: [
            message("u", "user", "Read it", at: 1_000),
            message("a-tool", "assistant", "", tools: [tool("call", "read", input: "{\"path\":\"fixture.txt\"}", output: "Contents", durationMs: 10)], at: 3_000),
            message("t", "tool", "Contents", at: 3_020),
            message("a-final", "assistant", "Done", at: 5_000),
        ])
        XCTAssertEqual(kinds(items), ["message", "block:a-final"], "the tool round folds into the reply and the tool result row disappears")
        let block = blocks(items)[0]
        XCTAssertEqual(block.key, "block:a-tool"); XCTAssertEqual(block.id, "a-final"); XCTAssertEqual(block.activity.map(\.id), ["a-tool"])
        XCTAssertEqual(block.modelMs, 2_000 + 1_980, "model time is the gap before each reply"); XCTAssertEqual(block.toolMs, 10)
        XCTAssertEqual(block.endedAt! - block.startedAt!, 4_000)
        XCTAssertEqual(block.turn, TurnSummary(replies: 1, tools: 1, startedAt: 1_000, endedAt: 5_000, elapsedMs: 4_000, modelMs: 3_980, toolMs: 10, live: false, files: 0, partial: false, accounting: TurnAccounting(), requests: [], current: nil, notice: nil), "a single-reply turn carries its totals too")
        let chained = TranscriptActivity.blocks(of: [
            message("u", "user", "Go"),
            message("a1", "assistant", "", tools: [tool("t1", "read", input: "{\"path\":\"a\"}", durationMs: 1)]),
            message("a2", "assistant", "", tools: [tool("t2", "bash", input: "{\"command\":\"ls\"}", durationMs: 2)]),
            message("a3", "assistant", "Now edit", tools: [tool("t3", "edit", input: "{\"path\":\"b\"}", durationMs: 3)]),
            message("a4", "assistant", "", tools: [tool("t4", "bash", input: "{\"command\":\"pwd\"}", durationMs: 4)]),
        ])
        XCTAssertEqual(kinds(chained), ["message", "block:a3", "block:-"])
        let first = blocks(chained)[0], trailing = blocks(chained)[1]
        XCTAssertEqual(first.tools.map(\.id), ["t1", "t2", "t3"], "a reply owns the work before it and its own calls")
        XCTAssertEqual(trailing.tools.map(\.id), ["t4"], "work the turn ended on forms a trailing block without prose")
        XCTAssertEqual(first.toolMs, 6); XCTAssertEqual(trailing.toolMs, 4)
        XCTAssertNil(first.turn)
        XCTAssertEqual(trailing.turn, TurnSummary(replies: 2, tools: 4, startedAt: nil, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 10, live: false, files: 1, partial: false, accounting: TurnAccounting(), requests: [], current: nil, notice: nil), "the last block of a multi-reply turn totals the turn, counting the file its edit touched")
        let multi = TranscriptActivity.blocks(of: [
            message("u", "user", "Go", at: 1_000),
            message("a1", "assistant", "First", tools: [tool("t1", "read", input: "{\"path\":\"a\"}", durationMs: 500)], at: 3_000),
            message("a2", "assistant", "Second", at: 6_000),
            message("u2", "user", "More", at: 9_000),
            message("a3", "assistant", "Third", at: 9_500),
        ])
        let turnBlocks = blocks(multi)
        XCTAssertEqual(turnBlocks.map { $0.turn?.replies ?? 0 }, [0, 2, 1], "only the last reply of a turn carries totals; the next turn starts fresh")
        XCTAssertEqual(turnBlocks[1].turn, TurnSummary(replies: 2, tools: 1, startedAt: 1_000, endedAt: 6_000, elapsedMs: 5_000, modelMs: 5_000, toolMs: 500, live: false, files: 0, partial: false, accounting: TurnAccounting(), requests: [], current: nil, notice: nil))
        let live = blocks(TranscriptActivity.blocks(of: [
            message("u", "user", "Go", at: 1_000),
            message("a1", "assistant", "First", at: 2_000),
            message("a2", "assistant", "", tools: [tool("t", "bash", state: "running", input: "{\"command\":\"npm test\"}")], state: "streaming"),
        ]))
        XCTAssertEqual(live.count, 2); XCTAssertEqual(live[1].live, true); XCTAssertEqual(live[1].turn?.live, true); XCTAssertEqual(live[1].turn?.startedAt, 1_000)
        XCTAssertEqual(live[1].turn?.current?.id, "t", "a live turn names the tool call under way")
        let retrying = TranscriptActivity.blocks(of: [
            message("u", "user", "Go", at: 1_000),
            message("stream:a", "assistant", "", state: "streaming"),
            message("notice:retry", "system", "Retrying (attempt 2 of 3) after: stream dropped", kind: "notice"),
        ])
        XCTAssertEqual(retrying.count, 2, "a trailing retry notice folds into the live turn instead of taking a row")
        XCTAssertEqual(blocks(retrying)[0].turn?.notice, "Retrying (attempt 2 of 3) after: stream dropped")
    }

    func testBlocksKeepTheirKeyWhileTheReplyArrivesAndStatusRowsNeverSplitATurn() {
        let activityOnly = message("a1", "assistant", "", tools: [tool("t1", "read", input: "{\"path\":\"a\"}", durationMs: 1)], turn: "u")
        let before = blocks(TranscriptActivity.blocks(of: [message("u", "user", "Go", turn: "u"), activityOnly]))
        let after = blocks(TranscriptActivity.blocks(of: [message("u", "user", "Go", turn: "u"), activityOnly, message("a2", "assistant", "Done", turn: "u")]))
        XCTAssertEqual(before[0].key, "block:a1"); XCTAssertEqual(after[0].key, "block:a1", "the key stays with the first row, so the view keeps the block mounted and open")
        XCTAssertEqual(after[0].id, "a2", "the id still follows the reply for anchors"); XCTAssertEqual(after[0].turnID, "u")
        let interrupted = blocks(TranscriptActivity.blocks(of: [
            message("u", "user", "Go", at: 1_000, turn: "u"),
            message("a1", "assistant", "First", tools: [tool("t1", "edit", input: "{\"path\":\"a\"}", durationMs: 1, path: "/repo/a")], at: 2_000, turn: "u"),
            message("c", "system", "Conversation summary", kind: "compaction", at: 2_500),
            message("n", "system", "Retrying (attempt 2 of 3)", kind: "notice"),
            message("a2", "assistant", "Second", at: 4_000, turn: "u"),
            message("f", "system", "Run failed.", kind: "failure"),
            message("u2", "user", "More", at: 9_000, turn: "u2"),
            message("a3", "assistant", "Third", at: 9_500, turn: "u2"),
        ]))
        XCTAssertEqual(interrupted.map { $0.turn?.replies ?? 0 }, [0, 2, 1], "a compaction summary, a retry notice and a failure sit inside the turn instead of ending it")
        XCTAssertEqual(interrupted[1].turn?.files, 1); XCTAssertEqual(interrupted[1].turn?.partial, false); XCTAssertEqual(interrupted[2].turn?.partial, false)
        let plainSystem = blocks(TranscriptActivity.blocks(of: [message("u", "user", "Go"), message("a1", "assistant", "One"), message("s", "system", "Imported context"), message("a2", "assistant", "Two")]))
        XCTAssertEqual(plainSystem.map { $0.turn?.replies ?? 0 }, [1, 1], "a plain system row still separates turns")
        let midHistory = blocks(TranscriptActivity.blocks(of: [
            message("a1", "assistant", "Late in turn one", at: 1_000, turn: "t1"),
            message("a2", "assistant", "Turn two", at: 2_000, turn: "t2"),
            message("u3", "user", "Three", at: 3_000, turn: "t3"),
            message("a3", "assistant", "Turn three", at: 4_000, turn: "t3"),
        ]))
        XCTAssertEqual(midHistory.map { [$0.turn?.replies ?? 0, $0.turn?.partial == true ? 1 : 0] }, [[1, 1], [1, 1], [1, 0]], "host turn ids separate replies with no user row between them and mark turns that began before the loaded page")
        let measured = blocks(TranscriptActivity.blocks(of: [message("u", "user", "Go", at: 1_000), message("a1", "assistant", "Reply", at: 5_000, modelMs: 700)]))
        XCTAssertEqual(measured[0].modelMs, 700, "the host's request timing wins over the gap between rows"); XCTAssertEqual(measured[0].turn?.modelMs, 700)
        let failure = TranscriptActivity.blocks(of: [message("u", "user", "Go", at: 1_000), message("a", "assistant", "Half", state: "error", at: 2_000), message("failure:s", "system", "Failed", kind: "failure")])
        XCTAssertEqual(kinds(failure), ["message", "block:a", "message"], "a failure row follows the reply it interrupted and never folds into a block")
    }

    func testRepliesCarryTheirOwnUsageAndTheTurnLineSumsEveryComponent() {
        let models = GatewayModelSummary(names: ["gpt-5.4"], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0)
        let items = TranscriptActivity.blocks(of: [
            message("u", "user", "Go", at: 1_000),
            message("a1", "assistant", "", tools: [tool("t", "read", input: "{\"path\":\"a\"}", durationMs: 5)], accounting: reported(), at: 2_000),
            message("a2", "assistant", "Done", accounting: reported { a in
                a.costUSD = 0.001; a.cacheReadTokens = 20
                a.tokens = GatewayTokenTotals(input: 62, output: 100, total: 162, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 30, reasoningSamples: 1)
                a.models = models
            }, at: 3_000),
            message("a3", "assistant", "Extra", at: 4_000),
        ])
        let first = blocks(items)[0], last = blocks(items)[1]
        XCTAssertEqual(first.accounting.requests, 2); XCTAssertEqual(first.accounting.input, 100); XCTAssertEqual(first.accounting.cached, 20); XCTAssertEqual(first.accounting.uncached, 80)
        XCTAssertEqual(first.accounting.output, 523); XCTAssertEqual(first.accounting.reasoning, 30); XCTAssertEqual(first.accounting.total, 623); XCTAssertEqual(first.accounting.costUSD, 0.001421875)
        XCTAssertEqual(first.accounting.model, "gpt-5.4"); XCTAssertEqual(first.accounting.modelMessageID, "a2")
        XCTAssertEqual(last.accounting.requests, 0)
        XCTAssertEqual(TranscriptActivity.tokens(of: first.accounting), 623)
        XCTAssertEqual(TranscriptActivity.usageBreakdown(last.turn!.accounting), "in 100 · 20 cached · 80 uncached · out 523 · 30 reasoning (1/2) · $0.00142", "only one of the two requests reported reasoning")
        let single = blocks(TranscriptActivity.blocks(of: [message("u", "user", "Go", at: 1_000), message("a", "assistant", "Done", accounting: reported { $0.cacheReadTokens = 8; $0.models = models }, at: 3_000)]))[0]
        XCTAssertEqual(TranscriptActivity.usageBreakdown(single.turn!.accounting), "in 38 · 8 cached · 30 uncached · out 423 · $0.00042")
        let partial = TranscriptActivity.aggregate([message("x", "assistant", "", accounting: reported { a in a.costSamples = 0; a.costUSD = nil; a.cacheReadSamples = 0; a.cacheReadTokens = nil; a.tokens = GatewayTokenTotals(input: 5, output: nil, total: nil, inputSamples: 1, outputSamples: 0, samples: 0) })])
        XCTAssertNil(partial.costUSD); XCTAssertEqual(partial.input, 5); XCTAssertNil(partial.output); XCTAssertNil(partial.total); XCTAssertNil(partial.uncached); XCTAssertNil(partial.reasoning)
        XCTAssertEqual(TranscriptActivity.usageBreakdown(partial), "in 5")
        let uncovered = TranscriptActivity.aggregate([message("y", "assistant", "", accounting: reported { $0.requests = 2; $0.costSamples = 1 })])
        XCTAssertEqual(TranscriptActivity.usageBreakdown(uncovered), "in 38 (1/2) · 0 cached (1/2) · out 423 (1/2) · $0.00042 (1/2)", "partial coverage stays visible, and an uncached share is not derived from partial input and cache reports")
        XCTAssertEqual(TranscriptActivity.formatCompactTokens(950), "950"); XCTAssertEqual(TranscriptActivity.formatCompactTokens(1_500), "1.5k"); XCTAssertEqual(TranscriptActivity.formatCompactTokens(2_000), "2k"); XCTAssertEqual(TranscriptActivity.formatCompactTokens(48_200), "48k"); XCTAssertEqual(TranscriptActivity.formatCompactTokens(2_500_000), "2.5M")
        XCTAssertEqual(TranscriptActivity.formatTokenCount(9_999), "9,999"); XCTAssertEqual(TranscriptActivity.formatTokenCount(12_000), "12k")
        XCTAssertEqual(TranscriptActivity.formatTurnCost(0), "$0"); XCTAssertEqual(TranscriptActivity.formatTurnCost(0.0004), "$0.0004"); XCTAssertEqual(TranscriptActivity.formatTurnCost(0.0123), "$0.012"); XCTAssertEqual(TranscriptActivity.formatTurnCost(2), "$2.00")
    }

    func testDiffsTeasersAndClocks() {
        let edit = tool("e", "edit", input: "{\"path\":\"/repo/src/retry.swift\",\"oldText\":\"let a = 1\\nlet b = 2\\nlet c = 3\",\"newText\":\"let a = 1\\nlet b = 20\\nlet c = 3\\nlet d = 4\"}", output: "ok", durationMs: 3, path: "/repo/src/retry.swift", added: 2, removed: 1)
        XCTAssertEqual(TranscriptActivity.lineDiff("let a = 1\nlet b = 2\nlet c = 3", "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4"), [
            DiffRow(kind: .context, text: "let a = 1"), DiffRow(kind: .removed, text: "let b = 2"), DiffRow(kind: .added, text: "let b = 20"), DiffRow(kind: .context, text: "let c = 3"), DiffRow(kind: .added, text: "let d = 4"),
        ])
        let texts = TranscriptActivity.editTexts(edit)
        XCTAssertEqual(texts?.before, "let a = 1\nlet b = 2\nlet c = 3"); XCTAssertEqual(texts?.after, "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4")
        var write = edit; write.name = "write"; write.input = "{\"path\":\"x\",\"content\":\"new\"}"
        XCTAssertEqual(TranscriptActivity.editTexts(write)?.before, ""); XCTAssertEqual(TranscriptActivity.editTexts(write)?.after, "new")
        var bash = edit; bash.name = "bash"; bash.input = "{\"command\":\"ls\"}"
        XCTAssertNil(TranscriptActivity.editTexts(bash))
        let big = TranscriptActivity.lineDiff((0..<301).map { "l\($0)" }.joined(separator: "\n"), "x")
        XCTAssertEqual(big.filter { $0.kind == .removed }.count, 301); XCTAssertEqual(big.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(TranscriptActivity.reasoningTeaser("  First thought here. Then more.  "), "First thought here.")
        XCTAssertEqual(TranscriptActivity.reasoningTeaser(String(repeating: "x", count: 120)), String(repeating: "x", count: 89) + "…")
        XCTAssertNil(TranscriptActivity.reasoningTeaser("   "))
        XCTAssertEqual(TranscriptActivity.reasoningTeaser("Look at 3.5 versions. Then stop."), "Look at 3.5 versions.", "a dot inside a number is not a sentence end")
        XCTAssertNotNil(TranscriptActivity.formatClock(1_726_000_000_000).range(of: "^\\d{2}:\\d{2}:\\d{2}$", options: .regularExpression))
        XCTAssertEqual(TranscriptActivity.parseCommand("{\"command\":\"pwd\"}"), "pwd"); XCTAssertNil(TranscriptActivity.parseCommand("nope"))
    }

    func testAccountingLinesShowOnlyWhatTheGatewayReported() {
        let responses = TranscriptActivity.accountingPresentation(reported { $0.costUSD = nil; $0.costSamples = 0 })
        XCTAssertEqual(responses.summary, "38 in · 0 cached · 423 out · 461 total", "an unreported cost is left out rather than named")
        var nothing = GatewayTotals(); nothing.requests = 1; nothing.cacheUnreported = 1
        nothing.models = GatewayModelSummary(names: [], nameCount: 0, reportedRequests: 0, unreportedRequests: 1, conflictingRequests: 0, incompleteRequests: 0)
        XCTAssertEqual(TranscriptActivity.accountingPresentation(nothing).summary, "", "nothing reported means no line at all")
        XCTAssertTrue(responses.detail.contains("Uncached input: 38")); XCTAssertTrue(responses.detail.contains("Output includes reasoning tokens; they are not added again")); XCTAssertTrue(responses.detail.contains("cost 0/1 requests reported"))
        XCTAssertFalse(responses.summary.contains("$0"))
        let reasoning = TranscriptActivity.accountingPresentation(reported { a in
            a.costUSD = 0.0013875; a.reasoningCostUSD = 0.0011385; a.reasoningCostSamples = 1
            a.tokens = GatewayTokenTotals(input: 38, output: 302, total: 340, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 253, reasoningSamples: 1)
        })
        XCTAssertEqual(reasoning.summary, "38 in · 0 cached · 302 out (253 reasoning) · 340 total · $0.0013875 USD")
        XCTAssertTrue(reasoning.detail.contains("Reasoning cost: $0.0011385 USD (1/1 reported), a per-request output-cost breakdown, never added to total cost"))
        XCTAssertFalse(reasoning.summary.contains("593")); XCTAssertFalse(reasoning.summary.contains("$0.002526"))
        let legacy = TranscriptActivity.accountingPresentation(reported())
        XCTAssertTrue(legacy.detail.contains("Reasoning: tokens unavailable")); XCTAssertFalse(legacy.summary.contains("reasoning"))
        let missing = reported { a in a.tokens = nil; a.costSamples = 0; a.costUSD = nil; a.cacheReadTokens = nil; a.cacheWriteTokens = nil; a.cacheReadSamples = 0; a.cacheWriteSamples = 0; a.cacheMisses = 0; a.cacheUnreported = 1 }
        let absent = TranscriptActivity.accountingPresentation(missing)
        XCTAssertEqual(absent.summary, "", "unreported figures are left out of the line; the detail still explains them")
        XCTAssertTrue(absent.detail.contains("Response cache: 1 unreported"))
        XCTAssertNil(TranscriptActivity.uncachedInput(missing))
        XCTAssertNil(TranscriptActivity.uncachedInput(reported { $0.cacheReadTokens = nil; $0.cacheReadSamples = 0 }))
        XCTAssertNil(TranscriptActivity.uncachedInput(reported { $0.cacheReadTokens = 39 }))
        XCTAssertEqual(TranscriptActivity.uncachedInput(reported()), 38)
        let partial = reported { a in a.requests = 2; a.cacheReadTokens = 10; a.cacheMisses = 1; a.cacheUnreported = 1 }
        let partialLine = TranscriptActivity.accountingPresentation(partial)
        XCTAssertEqual(partialLine.summary, "38 in (1/2) · 10 cached (1/2) · 423 out (1/2) · 461 total (1/2) · $0.00042188 USD (1/2)")
        XCTAssertNil(TranscriptActivity.uncachedInput(partial))
        XCTAssertTrue(partialLine.detail.contains("Partial totals include only reported requests")); XCTAssertTrue(partialLine.detail.contains("Prompt-cache read 10 tokens (1/2 reported)"))
        let paired = reported { a in
            a.requests = 3; a.cacheReadTokens = 120; a.cacheReadSamples = 2
            a.tokens = GatewayTokenTotals(input: 500, output: nil, total: nil, inputSamples: 2, outputSamples: 0, samples: 0)
            a.uncachedInputReportedTokens = 30; a.uncachedInputSamples = 1; a.costUSD = 0.001; a.costSamples = 1; a.reasoningCostUSD = 0.002; a.reasoningCostSamples = 2
        }
        let pairedLine = TranscriptActivity.accountingPresentation(paired)
        XCTAssertEqual(TranscriptActivity.uncachedInput(paired), 30)
        XCTAssertTrue(pairedLine.detail.contains("Uncached input: 30 (1/3)")); XCTAssertTrue(pairedLine.detail.contains("Its reporting coverage may differ")); XCTAssertFalse(pairedLine.detail.contains("included in total cost"))
        var unpaired = paired; unpaired.uncachedInputSamples = 0; unpaired.uncachedInputReportedTokens = nil
        XCTAssertNil(TranscriptActivity.uncachedInput(unpaired))
        XCTAssertTrue(TranscriptActivity.accountingPresentation(reported { $0.costUSD = 0 }).summary.hasSuffix("$0 USD"))
        XCTAssertTrue(TranscriptActivity.accountingPresentation(reported { $0.costUSD = 1e-10 }).summary.hasSuffix("$1.00e-10 USD"))
        XCTAssertFalse(TranscriptActivity.accountingPresentation(reported { $0.costUSD = -1 }).summary.contains("USD"), "an invalid cost is left out")
        XCTAssertFalse(TranscriptActivity.accountingPresentation(reported { $0.costSamples = 0 }).summary.contains("USD"), "an unreported cost is left out")
        let single = GatewayModelSummary(names: ["gpt-5.4-mini"], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0)
        let named = TranscriptActivity.accountingPresentation(reported { $0.models = single })
        XCTAssertTrue(named.summary.hasPrefix("gpt-5.4-mini · 38 in")); XCTAssertEqual(named.modelLabel, "gpt-5.4-mini")
        XCTAssertTrue(named.detail.contains("The response body supplies the displayed name when available"))
        let mixed = TranscriptActivity.accountingPresentation(reported { $0.requests = 7; $0.models = GatewayModelSummary(names: ["one", "two", "three"], nameCount: 3, reportedRequests: 4, unreportedRequests: 1, conflictingRequests: 1, incompleteRequests: 1) })
        XCTAssertTrue(mixed.summary.hasPrefix("one · 38 in")); XCTAssertFalse(mixed.summary.contains("two")); XCTAssertFalse(mixed.summary.contains("three"))
        XCTAssertTrue(mixed.detail.contains("Reported models: one, two, three.")); XCTAssertTrue(mixed.detail.contains("Resolved identity 4/7"))
        let unknown = TranscriptActivity.accountingPresentation(reported { $0.models = GatewayModelSummary(names: [], nameCount: 0, reportedRequests: 0, unreportedRequests: 1, conflictingRequests: 0, incompleteRequests: 0) })
        XCTAssertFalse(unknown.summary.contains("Model not reported")); XCTAssertTrue(unknown.summary.hasPrefix("38 in"), "an unreported model is left out; the usage stands alone")
        let conflicting = reported { $0.models = GatewayModelSummary(names: ["gpt-5.4-mini"], nameCount: 1, reportedRequests: 0, unreportedRequests: 0, conflictingRequests: 1, incompleteRequests: 0, displayRequests: 1) }
        XCTAssertTrue(TranscriptActivity.validModelSummary(conflicting.models!, requests: 1))
        XCTAssertTrue(TranscriptActivity.accountingPresentation(conflicting).summary.hasPrefix("gpt-5.4-mini · ")); XCTAssertFalse(TranscriptActivity.accountingPresentation(conflicting).summary.contains("conflict"))
    }

    func testModelSummaryValidationRejectsUnboundedOrInconsistentMetadata() {
        let models = GatewayModelSummary(names: ["model"], nameCount: 1, reportedRequests: 1, unreportedRequests: 0, conflictingRequests: 0, incompleteRequests: 0)
        XCTAssertTrue(TranscriptActivity.validModelSummary(models, requests: 1))
        var same = models; same.names = ["same", "same"]; same.nameCount = 2
        var long = models; long.names = [String(repeating: "x", count: 257)]
        var broken = models; broken.names = ["line\nbreak"]
        var none = models; none.nameCount = 0
        var extra = models; extra.unreportedRequests = 1
        var negative = models; negative.displayRequests = -1
        var over = models; over.displayRequests = 2
        var zero = models; zero.displayRequests = 0
        var blank = models; blank.names = ["  "]
        var nine = models; nine.names = (0..<9).map(String.init); nine.nameCount = 9; nine.reportedRequests = 9
        for invalid in [same, long, broken, none, extra, negative, over, zero, blank, nine] { XCTAssertFalse(TranscriptActivity.validModelSummary(invalid, requests: 1), "\(invalid)") }
        var many = models; many.names = (0..<8).map { "model-\($0)" }; many.nameCount = 20; many.reportedRequests = 20
        XCTAssertTrue(TranscriptActivity.validModelSummary(many, requests: 20))
        var conflict = models; conflict.reportedRequests = 0; conflict.conflictingRequests = 1; conflict.displayRequests = 1
        XCTAssertTrue(TranscriptActivity.validModelSummary(conflict, requests: 1))
        var legacy = models; legacy.reportedRequests = 0; legacy.conflictingRequests = 1
        XCTAssertFalse(TranscriptActivity.validModelSummary(legacy, requests: 1), "Legacy summaries require verified model coverage")
    }

    func testReadReceiptsRequireACompletedAssistantAndReachingTheReplyEnd() {
        let messages = [message("u", "user", "Question"), message("a", "assistant", "Answer"), message("stream:next", "assistant", "Still working", state: "streaming")]
        XCTAssertEqual(TranscriptActivity.latestCompletedAssistant(messages), "a")
        XCTAssertNil(TranscriptActivity.latestCompletedAssistant([messages[0], messages[2]]))
        XCTAssertFalse(TranscriptActivity.replyEndIsVisible(top: 100, bottom: 900, height: 800, viewportHeight: 600), "Seeing only the first lines is not reading to the end")
        XCTAssertTrue(TranscriptActivity.replyEndIsVisible(top: -300, bottom: 500, height: 800, viewportHeight: 600), "The end of a long reply can be reached")
        XCTAssertFalse(TranscriptActivity.replyEndIsVisible(top: -500, bottom: -100, height: 400, viewportHeight: 600), "A reply completely above the viewport is not proof")
        XCTAssertFalse(TranscriptActivity.replyEndIsVisible(top: 0, bottom: 0, height: 0, viewportHeight: 600), "Hidden views produce no visible row")
        XCTAssertFalse(TranscriptActivity.replyEndIsVisible(top: 100, bottom: 500, height: 400, viewportHeight: 0))
        XCTAssertFalse(TranscriptActivity.replyEndIsVisible(top: 100, bottom: .nan, height: 400, viewportHeight: 600))
        XCTAssertTrue(TranscriptActivity.replyEndIsVisible(top: 100, bottom: 500, height: 400, viewportHeight: 600))
    }
}

extension TranscriptActivityTests {
    /// A delta to the arriving reply's text or reasoning patches the last block; anything else regroups.
    func testTextOnlyDeltasPatchTheLastBlockWithoutRegrouping() {
        func row(_ id: String, _ role: String, _ text: String, tools: [ToolView]? = nil, thinking: String? = nil, state: String? = nil, at: Double) -> TranscriptMessage {
            var message = TranscriptMessage(id: id, role: role, text: text, thinking: thinking, tools: tools, state: state, turn: "u1"); message.at = at; return message
        }
        let tool = ToolView(id: "t1", name: "read", state: "completed", input: "{}", output: "ok", durationMs: 5, truncated: false, path: "a.swift", added: nil, removed: nil)
        let previous = [row("u1", "user", "question", at: 1000), row("a1", "assistant", "", tools: [tool], at: 2000), row("stream:a2", "assistant", "partial", state: "streaming", at: 3000)]
        let items = TranscriptActivity.blocks(of: previous)
        var page = previous; page[2].text = "partial and more"
        let patched = TranscriptActivity.patched(items, from: previous, to: page)
        XCTAssertEqual(patched, TranscriptActivity.blocks(of: page), "the patched items read exactly as a regroup would")
        XCTAssertNotNil(patched)
        var reasoning = previous; reasoning[2] = row("stream:a2", "assistant", "", thinking: "thinking…", state: "streaming", at: 3000)
        let reasoningItems = TranscriptActivity.blocks(of: reasoning)
        var reasoningMore = reasoning; reasoningMore[2].thinking = "thinking more…"
        XCTAssertEqual(TranscriptActivity.patched(reasoningItems, from: reasoning, to: reasoningMore), TranscriptActivity.blocks(of: reasoningMore), "reasoning deltas patch the activity row")
        var withTool = page; withTool[2].tools = [tool]
        XCTAssertNil(TranscriptActivity.patched(items, from: previous, to: withTool), "a new tool call regroups")
        var settled = page; settled[2] = row("a2", "assistant", "done", at: 3000)
        XCTAssertNil(TranscriptActivity.patched(items, from: previous, to: settled), "a settled row has a new id and regroups")
        XCTAssertNil(TranscriptActivity.patched(items, from: previous, to: page + [row("n", "system", "notice", at: 4000)]), "a new row regroups")
        var textToActivity = previous; textToActivity[2] = row("stream:a2", "assistant", "", tools: [tool], state: "streaming", at: 3000)
        XCTAssertNil(TranscriptActivity.patched(items, from: previous, to: textToActivity), "a reply that becomes activity-only regroups")
        var earlierChanged = page; earlierChanged[0].text = "edited question"
        XCTAssertNil(TranscriptActivity.patched(items, from: previous, to: earlierChanged), "an earlier row changing regroups")
    }
}
