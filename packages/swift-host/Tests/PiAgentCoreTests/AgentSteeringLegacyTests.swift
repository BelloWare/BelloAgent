import XCTest
@testable import PiAgentCore

final class AgentSteeringLegacyTests: XCTestCase {
    func testLegacyFallbackSnapshotIsFrozenOnceAndSurvivesReopen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile()
        var first = try await Resources(cwd:root,home:root).resolve(); first.prompt = "LEGACY_ADOPTED_INSTRUCTIONS"; first.revision = "legacy-current"
        let client = AccountedAgentScript([answer("Legacy answer"),answer("First follow-up"),answer("Second follow-up")])
        let parent = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(frozen:first),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator())
        let legacy = ToolCall(id:"v2",name:"subagent",arguments:["task":"Legacy task"])
        _ = try await parent.agentFixtureCall(legacy,newTask:true); try await parent.runToolBatch([legacy])
        let plans = await parent.subagents.plans
        let child = try XCTUnwrap(plans.values.first?.origin.link.childSessionID)
        XCTAssertNil(plans.values.first?.origin.frozenResources)
        let coordinator = AgentSteeringCoordinator(); await parent.enableAgentSteering(coordinator)
        let send = ToolCall(id:"follow",name:"subagent_send",arguments:["child_id":JSON(child),"message":"First follow-up"])
        let key = try await parent.agentFixtureCall(send,newTask:true)
        _ = try await coordinator.prepare(send,key:key,parent:parent)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        await coordinator.drain(); await parent.close()
        var changed = first; changed.prompt = "CHANGED_AFTER_ADOPTION"; changed.revision = "changed"
        let reopened = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(frozen:changed),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:root.appendingPathComponent("parent.jsonl").path)
        let next = AgentSteeringCoordinator(); await reopened.enableSubagents(SubagentCoordinator()); await reopened.enableAgentSteering(next)
        let follow = ToolCall(id:"next",name:"subagent_send",arguments:["child_id":JSON(child),"message":"Second follow-up"])
        let nextKey = try await reopened.agentFixtureCall(follow,newTask:true)
        _ = try await next.prepare(follow,key:nextKey,parent:reopened)
        try await eventually { await reopened.agentState().latest(child)?.status.terminal == true }
        let instructions = await client.instructionHistory, requests = await client.requests
        XCTAssertEqual(instructions.count,3)
        XCTAssertTrue(instructions[2].contains("LEGACY_ADOPTED_INSTRUCTIONS"))
        XCTAssertFalse(instructions[2].contains("CHANGED_AFTER_ADOPTION"))
        XCTAssertTrue(requests[2].contains { $0.text == "Legacy answer" })
        XCTAssertTrue(requests[2].contains { $0.text == "First follow-up" })
        await next.drain(); await reopened.close()
    }
}
