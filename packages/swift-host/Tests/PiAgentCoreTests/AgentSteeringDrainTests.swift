import XCTest
@testable import PiAgentCore

final class AgentSteeringDrainTests: HelperTestCase {
    func testNoDrainClosesBeforeFollowupCanOpen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let enteringClose = CutinLatch(), releaseClose = CutinLatch(), opens = DrainOpenProbe()
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            try await opens.open(env,plan)
        },settled:{ child in
            await enteringClose.release(); await releaseClose.wait()
            await child.close()
        })
        let client = AccountedAgentScript([answer("First"),answer("Second")])
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        let spawn = ToolCall(id:"spawn",name:"spawn_agent",arguments:["task_name":"worker","message":"Work","fork_turns":"none"])
        let key = try await parent.agentFixtureCall(spawn,newTask:true)
        let receipt = try await coordinator.prepare(spawn,key:key,parent:parent)
        let child = try XCTUnwrap(receipt["child_id"].text)
        await enteringClose.wait()
        let follow = ToolCall(id:"follow",name:"followup_task",arguments:["target":"worker","message":"Again"])
        let followKey = try await parent.agentFixtureCall(follow)
        _ = try await coordinator.prepare(follow,key:followKey,parent:parent)
        let jobs = await coordinator.jobs
        XCTAssertNotNil(jobs["\(child):1"],"The old job owns the writer until close returns")
        XCTAssertEqual(jobs["\(child):2"]?.allocated,false,"A new open cannot overtake close")
        await releaseClose.release()
        try await eventually { let latest = await parent.agentState().latest(child); return latest?.turn == 2 && latest?.status.terminal == true }
        let checks = await opens.closedBeforeOpen
        XCTAssertEqual(checks,[true]); let count = await client.requests.count; XCTAssertEqual(count,2)
        await coordinator.drain(); await parent.close()
        try SessionJournal.verifyManagedChild(url:root.appendingPathComponent(child + ".jsonl"),id:child)
    }
}
private actor DrainOpenProbe {
    var previous: AgentSession?
    var closedBeforeOpen: [Bool] = []
    func open(_ env: SubagentEnvironment, _ plan: SubagentPlan) async throws -> AgentSession {
        if let previous { closedBeforeOpen.append(await previous.closed) }
        let child = try AgentSteeringCoordinator.makeChild(env,plan); previous = child; return child
    }
}
