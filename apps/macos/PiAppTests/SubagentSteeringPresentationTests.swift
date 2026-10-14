import AppKit
import XCTest
@testable import PiApp

final class SubagentSteeringPresentationTests: XCTestCase {
    static var delivery: WireValue { .object([
        "version":.number(1), "author":.string("subagent"), "childId":.string("chat-child"),
        "turn":.number(2), "eventIds":.array([.string("question-2")]), "task":.string("Check the parser"),
        "events":.array([.object(["event_id":.string("question-2"), "author":.string("subagent"), "child_id":.string("chat-child"),
            "turn":.number(2), "kind":.string("question"), "text":.string("Should I keep the legacy parser?"), "task":.string("Check the parser")])])
    ]) }
    static var tool: ToolView {
        var tool = SubagentTranscriptTests.tool
        tool.name = "subagent_start"; tool.output = "{\"status\":\"accepted\",\"route\":\"start\",\"turn\":1}"
        var metadata = SubagentTranscriptTests.metadata.object!
        metadata["version"] = .number(2); metadata["turn"] = .number(1); metadata["route"] = .string("start")
        tool.nativeSubagent = .object(metadata)
        tool.subagent = SubagentSummary(link: SubagentTranscriptTests.link, description: "Check the parser", model: "fixture", status: .running, revision: 3, turn: 1, deliveryState: "pending")
        return tool
    }
    @MainActor func testAcceptedBackgroundReceiptIsALiveChildCard() throws {
        let tool = Self.tool, value = SubagentToolView(tool)
        XCTAssertEqual(value.label, "Running in background · turn 1")
        XCTAssertEqual(value.target?.sessionID, "chat-child")
        XCTAssertEqual(value.result, "", "An acceptance receipt is not the child result")
        let row = TranscriptNativeActionRow()
        row.update(tool: tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        XCTAssertEqual(row.card?.accessibilityIdentifier(), "subagent-card")
        var saved = tool; saved.subagent = nil
        XCTAssertEqual(SubagentToolView(saved).target?.sessionID, "chat-child", "Saved v2 metadata retains navigation")
    }
    @MainActor func testTypedAgentRowsSurviveBothReadersAndNeverRenderAsHuman() throws {
        let saved: [String:WireValue] = ["role":.string("user"), "content":.string("agent envelope"), "nativeAgentDelivery":Self.delivery]
        let journal = TranscriptMessage.project(id: "delivery", message: saved)
        let live = try TranscriptMessage.projected(.array([.object(["id":.string("delivery"), "role":.string("user"), "text":.string("agent envelope"), "kind":.string("agent_message"), "nativeAgentDelivery":Self.delivery])]))[0]
        for row in [journal, live] {
            let wire = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(row))
            XCTAssertEqual(wire.object?["nativeAgentDelivery"], Self.delivery)
            XCTAssertEqual(row.kind, "agent_message")
            let item = TranscriptItem.message(row)
            XCTAssertFalse(TranscriptNativeUserRow.draws(item))
            let view = TranscriptRowRenderer.content(for: item, inputs: .init(item: item, fresh: false, actions: .init(), width: 600, environment: .init()))
            XCTAssertEqual(view.accessibilityIdentifier(), "agent-message-row")
            XCTAssertTrue(view.accessibilityLabel()?.contains("Sub-agent") == true)
        }
    }
    func testCaptureAcceptsANewerTurnButRejectsOldTerminalAndStalePackets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try CaptureDatabase(url: root.appendingPathComponent("capture.sqlite"))
        try db.execute("CREATE TABLE attempts(id TEXT, workspace TEXT, metadata BLOB, delegation TEXT)")
        try CaptureSubagents.prepare(db)
        var summary = Self.tool.subagent!; summary.status = .completed; summary.revision = 9
        try CaptureSubagents.record(summary, workspace: "workspace", db: db)
        let old = summary
        summary.turn = 2; summary.status = .running; summary.revision = 1
        try CaptureSubagents.record(summary, workspace: "workspace", db: db)
        try CaptureSubagents.record(old, workspace: "workspace", db: db)
        var stale = summary; stale.revision = 0; stale.status = .queued
        try CaptureSubagents.record(stale, workspace: "workspace", db: db)
        let bytes = try XCTUnwrap(db.rows("SELECT summary FROM subagent_groups").first?["summary"]?.data)
        XCTAssertEqual(try JSONDecoder().decode(SubagentSummary.self, from: bytes), summary)
    }
}
