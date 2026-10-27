import XCTest
@testable import PiAgentCore

final class AgentCodexDeliveryTests: HelperTestCase {
    func testAllFittingMessagesDeliverInOneFairRowWithoutOldCaps() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent, coordinator) = try await fixture(root)
        for index in 0..<20 {
            try await parent.appendAgentRecord(JournalRecordKind.agentMessage,message(index,text:String(repeating:"useful finding ",count:150)))
        }
        let delivered = try await coordinator.deliver(owner:parent,recipient:parent,childTurn:nil,canCompact:false)
        XCTAssertEqual(delivered,.delivered)
        let state = await parent.agentState(), rows = await parent.history.filter { $0.nativeAgentDelivery != nil }
        XCTAssertEqual(rows.count,1)
        let events = try XCTUnwrap(rows.first?.nativeAgentDelivery?["events"].list)
        XCTAssertEqual(events.count,20); XCTAssertGreaterThan(rows[0].text.utf8.count,16384)
        XCTAssertEqual(Set(events.prefix(10).compactMap { $0["sender"].text }).count,10)
        XCTAssertTrue(state.messages.values.allSatisfy { $0.disposition == "delivered" })
        XCTAssertEqual(state.deliveryCursors?["parent"],events.last?["sender"].text)
        await parent.close()
    }
    func testContextCapacityStillRejectsWholeOversizeMessage() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent,coordinator) = try await fixture(root,small:true)
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,message(0,text:String(repeating:"large message ",count:15000)))
        do { _ = try await coordinator.deliver(owner:parent,recipient:parent,childTurn:nil,canCompact:false); XCTFail("Accepted message bypassed the real context budget") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"coordination_limit") }
        let state = await parent.agentState(), rows = await parent.history
        XCTAssertEqual(state.messages["message-0"]?.disposition,"pending")
        XCTAssertFalse(rows.contains { $0.nativeAgentDelivery != nil })
        await parent.close()
    }
    private func fixture(_ root: URL, small: Bool = false) async throws -> (AgentSession,AgentSteeringCoordinator) {
        let profile = try fixtureProfile().overriding(model:nil,thinkingLevel:nil,contextWindow:small ? 4096 : 100000,maxOutputTokens:512)
        let parent = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        let coordinator = AgentSteeringCoordinator(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        try await parent.appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:"epoch"))
        return (parent,coordinator)
    }
    private func message(_ index: Int, text: String) -> AgentFamilyMessage {
        var row = AgentFamilyMessage(id:"message-\(index)",sequence:index+1,childID:"child-\(index/2)",turn:1,author:"subagent",kind:"note",text:text,task:"Task",epoch:"epoch")
        row.type = "MESSAGE"; row.sender = "/root/agent_\(index/2)"; row.recipient = "/root"; row.senderChildID = row.childID; row.queueOnly = true
        return row
    }
}
