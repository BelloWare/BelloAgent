import XCTest
@testable import PiAgentCore

/// Sides never start or message sub-agents (owner, 2026-10-16). They keep the
/// parent's offered tools for its prompt cache and refuse the call instead.
final class SideDelegationTests: XCTestCase {
    func testSidesAtEveryDepthRefuseDelegationWithTheParentsExactTools() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(AgentSteeringCoordinator())
        let parentTools = await parent.sessionDefinitions()
        XCTAssertTrue(parentTools.contains { $0.name == "subagent_start" },"The fixture parent can delegate")
        var ancestor = parent, sides: [AgentSession] = []
        for depth in 1...3 {
            let seed = await ancestor.sideSeed()
            let side = try AgentSession(id:"side-\(depth)",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
            _ = try await side.preserveSide()
            await side.enableSubagents(SubagentCoordinator()); await side.enableAgentSteering(AgentSteeringCoordinator())
            let offered = await side.sessionDefinitions()
            XCTAssertEqual(offered,parentTools,"depth \(depth): the side offers the parent's exact tools")
            for name in ["subagent_start","subagent_send","subagent"] {
                let call = ToolCall(id:name,name:name,arguments:["task":"Work","mode":"background","child_id":"child","message":"More"])
                let refusal = await side.sideRefusal(call)
                XCTAssertEqual(refusal?.code,"read_only","depth \(depth): \(name)")
                XCTAssertTrue(refusal?.message.contains("main chat") == true,"depth \(depth): \(name) points to the main chat")
                do { _ = try await side.invokeTool(call); XCTFail("depth \(depth): \(name) must be refused") }
                catch { XCTAssertEqual((error as? AgentError)?.code,"read_only") }
            }
            // Reading or stopping children a 0.1.128 side already owns stays.
            for name in ["subagent_wait","subagent_status","subagent_stop"] {
                let refused = await side.sideDelegationRefusal(ToolCall(id:name,name:name,arguments:[:]))
                XCTAssertNil(refused,"depth \(depth): \(name)")
            }
            let state = await side.agentState(), plans = await side.subagents.plans
            XCTAssertTrue(state.turns.isEmpty); XCTAssertTrue(plans.isEmpty)
            ancestor = side; sides.append(side)
        }
        // A fork is a chat of its own: it may still delegate.
        let fork = await parent.sideSeed()
        var info = fork.info; info["relationship"] = "fork"
        let forked = try AgentSession(id:"fork",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:fork.messages,parent:info)
        let allowed = await forked.sideDelegationRefusal(ToolCall(id:"start",name:"subagent_start",arguments:[:]))
        XCTAssertNil(allowed)
        await forked.close()
        for side in sides.reversed() { await side.close() }
        await parent.close()
    }

    /// The model in a kept side asks for a sub-agent: the call is answered
    /// with the refusal, nothing is accepted or opened, and the turn goes on.
    func testSideRunRefusesSubagentStartAndContinues() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try familyFixture(root:root)
        let seed = await parent.sideSeed()
        let client = ScriptClient([agentCallReply("start","subagent_start",["task":"Delegated work","mode":"background"]),answer("I'll answer here instead")])
        let coordinator = AgentSteeringCoordinator()
        let side = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
        _ = try await side.preserveSide()
        await side.enableSubagents(SubagentCoordinator()); await side.enableAgentSteering(coordinator)
        _ = try await side.submit(Submission(commandID:"command",turnID:"turn",text:"Split this up"),steer:false)
        try await eventually { !(await side.isRunning) }
        let history = await side.history, state = await side.state, family = await side.agentState(), jobs = await coordinator.jobs
        let refused = try XCTUnwrap(history.last { $0.toolName == "subagent_start" })
        XCTAssertEqual(refused.isError,true)
        XCTAssertTrue(refused.text.contains("cannot start or message sub-agents"),refused.text)
        XCTAssertEqual(state,.idle)
        XCTAssertEqual(history.last?.text,"I'll answer here instead")
        XCTAssertTrue(family.operations.isEmpty); XCTAssertTrue(family.turns.isEmpty); XCTAssertTrue(jobs.isEmpty)
        await side.close(); await parent.close()
    }
}
