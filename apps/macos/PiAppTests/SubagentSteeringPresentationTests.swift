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
    @MainActor func testBackgroundCardHeaderHasFiniteGeometryBeforePlacement() throws {
        let row = TranscriptNativeActionRow()
        row.update(tool: Self.tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        for width: CGFloat in [0, 0.5, 600] {
            row.line.frame = CGRect(x: 0, y: 0, width: width, height: 24)
            row.line.layout()
            let outline = try XCTUnwrap(row.line.subviews.compactMap { $0 as? TranscriptPanel }.first { $0.stroke != nil })
            XCTAssertEqual(outline.frame, CGRect(x: 0.5, y: 0.5, width: max(0, width - 1), height: 23), "The focus outline stays inset even before the header has room")
            for view in row.line.subviews {
                XCTAssertTrue(view.frame.origin.x.isFinite && view.frame.origin.y.isFinite, "\(type(of: view)) at width \(width): \(view.frame)")
                XCTAssertTrue(view.frame.width.isFinite && view.frame.height.isFinite)
            }
        }
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
    func testMessageAndWaitReceiptsKeepTheirOwnDeliveryState() {
        var tool = Self.tool; tool.name = "subagent_send"
        tool.nativeSubagent?.object.map { fields in
            var fields = fields; fields["route"] = .string("steer"); tool.nativeSubagent = .object(fields)
        }
        tool.output = "{\"accepted\":true,\"child_id\":\"chat-child\",\"turn\":1,\"message_id\":\"steer\"}"
        tool.agentDeliveryState = "pending"
        XCTAssertEqual(SubagentToolView(tool).label, "Queued for steering · turn 1", "The child running does not prove it consumed a message")
        XCTAssertEqual(SubagentToolView(tool).target?.messageID, "steer", "Open must reveal this steer, not the turn's initial task")
        tool.agentDeliveryState = "delivered"
        XCTAssertEqual(SubagentToolView(tool).label, "Delivered · turn 1")
        tool.agentDeliveryState = "held"
        XCTAssertEqual(SubagentToolView(tool).label, "Pending for parent Resume")
        tool.name = "subagent_wait"; tool.subagent = nil; tool.nativeSubagent = nil; tool.agentDeliveryState = nil
        tool.output = "{\"version\":3,\"wake_reason\":\"message\",\"pending_count\":1}"
        XCTAssertEqual(SubagentToolView(tool).label, "Wait ended · new report")
        tool.output = "{\"version\":3,\"accepted\":false,\"code\":\"subagent_stopped\",\"message\":\"Held by user Stop\"}"
        XCTAssertEqual(SubagentToolView(tool).label, "Not accepted")
        XCTAssertEqual(SubagentToolView(tool).error, "Held by user Stop")
    }
    @MainActor func testNewRuntimeDropsOldProgressAndHumanStopHoldsTheCard() {
        let view = SessionDisplay(id: "chat-parent"); view.historyState = .ready; view.runState = .running
        var tool = Self.tool
        tool.subagent?.progressEpoch = "old-runtime"
        tool.subagent?.progress = .init(phase: "model", elapsedMs: 100, requests: 1, tools: 0, preview: "Old preview", usd: 0.01, reported: 1, unreported: 0)
        var current = tool.subagent!; current.progressEpoch = "new-runtime"; current.progress = nil
        view.childSummaries["chat-child"] = current
        view.messages = [.init(id: "source", role: "assistant", text: "", tools: [tool])]
        let shown = view.presentedMessages.first { $0.id == "source" }?.tools?.first
        XCTAssertNil(shown?.subagent?.progress, "Progress belongs to the current helper runtime")
        current.turn = 3; view.childSummaries["chat-child"] = current
        view.heldAgentChildren = ["chat-child"]
        let held = view.presentedMessages.first { $0.id == "source" }?.tools?.first
        XCTAssertEqual(held.map { SubagentToolView($0).label }, "Stopped by you · turn 3")
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
