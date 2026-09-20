import XCTest
@testable import PiApp

final class ToolCallSummaryTests: XCTestCase {
    private func tool(_ id: String = "reused", state: String = "completed", name: String = "read") -> ToolView {
        .init(id: id, name: name, state: state, input: "{\"path\":\"same\"}", output: "", durationMs: nil, truncated: false)
    }
    func testLogicalOccurrencesAndUnknownOutcomes() {
        let first = TranscriptMessage(id: "a", role: "assistant", text: "", tools: [tool(), tool("b"), tool("c"), tool("d", name: "bash")], toolCallCount: 4)
        let second = TranscriptMessage(id: "b", role: "assistant", text: "", tools: [tool(state: "failed", name: "mcp")], toolCallCount: 1)
        let summary = ToolCallSummary(rows: [first, second, first, .init(id: "result", role: "tool", text: "done")])
        XCTAssertEqual(summary.total, 5); XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.label(reasoned: true), "Reasoned · 5 tool calls · 1 failed")
        XCTAssertEqual(ToolCallSummary(tools: [tool(state: "recorded")]).label, "1 tool call · 1 outcome unknown")
        XCTAssertEqual(ToolCallSummary(tools: [tool(state: "cancelled")]).label, "1 tool call · 1 skipped")
        XCTAssertEqual(ToolCallSummary(tools: [tool(name: "mcp")]).total, 1)
        XCTAssertEqual(TranscriptActivity.changedFiles([tool(state: "recorded", name: "write")]), 0, "An imported call with no outcome cannot prove a write succeeded")
    }
    func testProvisionalArgumentsNeverInflateValidatedCount() {
        var row = TranscriptMessage(id: "a", role: "assistant", text: "", tools: [tool(state: "preparing")], state: "streaming", toolCallCount: 0)
        for _ in 0..<100 {
            row.tools?[0].input += "x"
            XCTAssertEqual(ToolCallSummary(rows: [row]).label, "Preparing tool call…")
            XCTAssertEqual(ToolCallSummary(rows: [row]).total, 0)
        }
        row.state = "complete"; row.tools?[0].state = "prepared"; row.toolCallCount = 1
        XCTAssertEqual(ToolCallSummary(rows: [row]).total, 1)
    }
    func testCompleteCountsSurviveBoundedCardsHistoryAndWirePaths() throws {
        let calls: [WireValue] = (0..<64).map { .object(["type": .string("toolCall"), "id": .string("call-\($0)"), "name": .string("read"), "arguments": .object([:])]) }
        let row = TranscriptMessage.project(id: "archive", message: ["role": .string("assistant"), "content": .array(calls)])
        XCTAssertEqual(row.tools?.count, 32); XCTAssertEqual(row.toolCallCount, 64)
        XCTAssertEqual(ToolCallSummary(rows: [row]).total, 64); XCTAssertFalse(ToolCallSummary(rows: [row]).partial)
        let encoded = try JSONEncoder().encode([row]), wire = try JSONDecoder().decode(WireValue.self, from: encoded)
        XCTAssertEqual(try TranscriptMessage.projected(wire), [row]); XCTAssertEqual(try TranscriptMessage.page(wire), [row])
        var legacy = row; legacy.toolCallCount = nil
        XCTAssertTrue(ToolCallSummary(rows: [legacy]).label?.hasPrefix("at least 32 tool calls") == true)
        let items = TranscriptActivity.blocks(of: [row, .init(id: "final", role: "assistant", text: "Done")])
        guard case .block(let block) = items.last else { return XCTFail("Missing group") }
        XCTAssertEqual(block.turn?.tools, 64); XCTAssertEqual(ToolCallSummary(rows: block.replies).total, 64)
    }
}

extension ToolCallSummaryTests {
    @MainActor func testTurnInformationCopyIncludesCountsTimingUsageAndUncertainty() throws {
        let rows=[TranscriptMessage(id:"u",role:"user",text:"ask",at:1000),
                  TranscriptMessage(id:"a",role:"assistant",text:"answer",state:"streaming",at:2000,turn:"u",modelMs:750,toolCallCount:4)]
        let blocks=TranscriptActivity.blocks(of:rows)
        let turn=try XCTUnwrap(blocks.compactMap { item -> TurnSummary? in
            if case .block(let block)=item { return block.turn }; return nil
        }.last)
        let copied=TurnLineView.copyText(turn,model:"gateway-model")
        XCTAssertTrue(copied.contains("4 tool calls")); XCTAssertTrue(copied.contains("Model time:"))
        XCTAssertTrue(copied.contains("Started:")); XCTAssertTrue(copied.contains("gateway-model"))
        XCTAssertTrue(copied.contains("incomplete"))
        var partial=turn; partial.partial=true; partial.toolCountPartial=true
        XCTAssertTrue(TurnLineView.copyText(partial).contains("partial loaded history"))
        XCTAssertTrue(TurnLineView.copyText(partial).contains("at least 4 tool calls"))
    }
}
