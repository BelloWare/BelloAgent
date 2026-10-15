import AppKit
import XCTest
@testable import PiApp

final class SubagentSteeringWorkspaceTests: XCTestCase {
    @MainActor func testSlowSourceLookupCannotReplaceANewerSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let link = try XCTUnwrap(model.chats[1].delegation)
        let header = SubagentHeader(link: link, description: "Task", model: .init(model: "fixture"), readOnly: true)
        let path = root.appendingPathComponent("source.jsonl")
        try Self.write([
            ["type":.string("session"),"id":.string(link.budgetOwnerSessionID)],
            ["type":.string("custom"),"customType":.string("pi-app.subagent-call.v1"),"data":.object(["origin":try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(header))])],
            ["type":.string("custom"),"customType":.string("pi-app.agent-operation.v1"),"data":.object([
                "key":.object(["parentSessionID":.string(link.budgetOwnerSessionID),"assistantMessageID":.string("follow-up"),"toolCallID":.string("send")]),
                "turn":.object(["childID":.string(link.childSessionID),"turn":.number(2),"inputID":.string("input-2")])])]
        ], to: path)
        model.chats[0].path = path.path
        let view = SessionDisplay(id: link.budgetOwnerSessionID); view.historyState = .ready
        view.messages = [.init(id: "follow-up", role: "assistant", text: "Saved source")]
        model.displays[view.id] = view; model.selected = view; model.selectedID = view.id
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), reader = model.history
        let blocking = Task.detached { await reader.holdSteeringRead(entered, release) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        var started = false
        let click = Task { started = true; await model.openAgentSource(.init(childID: link.childSessionID, turn: 2, eventID: "input-2"), from: link.childSessionID) }
        while !started { await Task.yield() }
        let selection = Task { await model.select("chat-side") }
        while model.selectedID != "chat-side" { await Task.yield() }
        release.signal(); await blocking.value; await click.value; await selection.value
        XCTAssertNil(view.reveal, "A source read belongs to the selection that requested it")
    }
    func testSteerRevealSelectsItsDeliveredEventRatherThanTheInitialTask() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var bytes = Data()
        for (id, event, turn) in [("task-row", "task", 1), ("steer-row", "steer", 1), ("follow-row", "follow", 2)] {
            let row: WireValue = .object(["type":.string("message"),"id":.string(id),"message":.object([
                "role":.string("user"),"content":.string("Saved input"),"nativeAgentDelivery":.object([
                    "version":.number(1),"author":.string("parent"),"childId":.string("child"),"turn":.number(Double(turn)),"eventIds":.array([.string(event)])])])])
            bytes.append(try JSONEncoder().encode(row)); bytes.append(10)
        }
        try bytes.write(to: path)
        let history = HistoryReader()
        let steer = try await history.subagentTurnMessage(path: path, childID: "child", turn: 1, messageID: "steer")
        let follow = try await history.subagentTurnMessage(path: path, childID: "child", turn: 2, messageID: nil)
        let foreign = try await history.subagentTurnMessage(path: path, childID: "other", turn: 1, messageID: "steer")
        XCTAssertEqual(steer, "steer-row"); XCTAssertEqual(follow, "follow-row"); XCTAssertNil(foreign)
    }
    @MainActor func testFinalFamilyWaitAndPendingDeliveryHoldTheParent() {
        let view = SessionDisplay(id: "parent"); view.historyState = .ready
        view.messages = [.init(id: "answer", role: "assistant", text: "The first check is complete.")]
        view.observeRunState(["state":.string("running"), "familyWaiting":.bool(true), "agentInboxPending":.number(1)])
        XCTAssertTrue(view.presentedMessages.contains { $0.text == "Waiting for sub-agents" })
        XCTAssertEqual(view.runHold, "active")
        view.observeRunState(["state":.string("idle"), "familyWaiting":.bool(false), "agentInboxPending":.number(1)])
        XCTAssertEqual(view.runHold, "paused", "An undelivered agent event is not idle")
        XCTAssertTrue(view.presentedMessages.contains { $0.text.contains("Pending for parent Resume") })
        view.observeRunState(["state":.string("idle"), "agentInboxPending":.number(0)])
        XCTAssertNil(view.runHold)
        XCTAssertFalse(view.presentedMessages.contains { $0.text == "Waiting for sub-agents" })
    }
    @MainActor func testV3DiscoveryUsesLatestTurnAndKeepsOneChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let parent = try XCTUnwrap(model.chats[0].path)
        var parentRows = try String(contentsOfFile: parent, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String:WireValue].self, from: Data($0.utf8)) }
        let plan = try XCTUnwrap(parentRows[1]["data"])
        parentRows[1] = ["type":.string("custom"), "customType":.string("pi-app.agent-operation.v1"), "data":.object(["plan":plan])]
        try Self.write(parentRows, to: URL(fileURLWithPath: parent))
        var childRows = try String(contentsOf: family.path, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String:WireValue].self, from: Data($0.utf8)) }
        childRows[1]["customType"] = .string("pi-app.native.v3")
        for (turn, status, kind) in [(1, "completed", "terminal"), (2, "queued", "state")] {
            childRows.append(["type":.string("custom"), "customType":.string("pi-app.subagent-turn-\(kind).v1"), "data":.object([
                "childID":.string(family.child), "turn":.number(Double(turn)), "executionID":.string("execution-\(turn)"), "status":.string(status)])])
        }
        try Self.write(childRows, to: family.path)
        try await model.store?.putChats(model.chats)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        await model.reconcileSubagents()
        XCTAssertEqual(model.chats.filter { $0.id == family.child }.count, 1)
        XCTAssertEqual(model.subagentSummaries[family.child]?.turn, 2)
        XCTAssertEqual(model.subagentSummaries[family.child]?.status, .interrupted, "A queued saved turn requires parent Resume; old success is not its outcome")
        let children = try await model.history.subagentPlans(path: URL(fileURLWithPath: parent), ownerID: "chat-parent")
        XCTAssertEqual(children.count, 1)
        if let summary = model.subagentSummaries[family.child] {
            var target = SubagentTarget(summary.link); target.turn = 2; target.receiptSource = true
            target.assistantID = "follow-up-assistant"; target.toolCallID = "send-call"
            let header = try await model.history.subagentHeader(path: family.path, directory: family.path.deletingLastPathComponent(), expected: target)
            XCTAssertEqual(header.link, summary.link, "Follow-up navigation keeps immutable creation provenance")
            var next = summary; next.turn = 3; next.status = .running; next.revision = 20
            try await model.registerListedSubagent(next, parent: model.chats[0], task: "task")
            await model.reconcileSubagents()
            XCTAssertEqual(model.subagentSummaries[family.child]?.turn, 3)
            XCTAssertEqual(model.subagentSummaries[family.child]?.status, .running)
        }
    }
    private static func write(_ rows: [[String:WireValue]], to url: URL) throws {
        var bytes = Data(); for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }; try bytes.write(to: url)
    }
}

private extension HistoryReader {
    func holdSteeringRead(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
        entered.signal(); _ = release.wait(timeout: .now() + 5)
    }
}
