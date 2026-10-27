import XCTest
@testable import PiAgentCore

final class AgentCodexRuntimeTests: HelperTestCase {
    func testForkAcceptanceWholeResultsIdleMailAndFollowup() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let long = String(repeating:"Complete answer 😀\n",count:5000)
        let client = CodexProbeClient([answer(long),answer("second turn")]), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        try await parent.codexFixtureSeed()
        let expectedTools = await parent.sessionDefinitions()
        let start = ToolCall(id:"start",name:"spawn_agent",arguments:["task_name":"audit","message":"Audit the journal"])
        let key = try await parent.agentFixtureCall(start,newTask:true)
        let receipt = try await coordinator.prepare(start,key:key,parent:parent)
        let duplicate = try await coordinator.prepare(start,key:key,parent:parent)
        XCTAssertEqual(receipt,duplicate)
        let plans = await parent.subagents.plans
        let child = try XCTUnwrap(plans.values.first?.origin.link.childSessionID)
        try await eventually { await parent.agentState().messages["result:\(child):1"] != nil }
        let request = await client.requests.first, instructions = await client.instructions.first, cache = await client.caches.first, definitions = await client.definitions.first
        XCTAssertEqual(request?.first?.text,"Inherited context")
        XCTAssertTrue(request?.filter { $0.nativeInherited != nil }.allSatisfy { $0.userInput == nil } == true)
        XCTAssertFalse(request?.contains { $0.content.contains { $0["type"].text == "toolCall" && $0["name"].text == "spawn_agent" } } == true)
        XCTAssertEqual(definitions,expectedTools); XCTAssertEqual(cache,"parent")
        let snapshot = try await parent.resources.resolve()
        XCTAssertEqual(instructions,AgentSession.requestInstructions(snapshot.prompt,tools:expectedTools))
        var family = await parent.agentState()
        XCTAssertEqual(family.messages["result:\(child):1"]?.text,long)
        _ = try await coordinator.boundary(parent,final:false)
        let send = ToolCall(id:"mail",name:"send_message",arguments:["target":"audit","message":"For the next task"])
        let mailKey = try await parent.agentFixtureCall(send)
        _ = try await coordinator.prepare(send,key:mailKey,parent:parent)
        family = await parent.agentState()
        XCTAssertEqual(family.turns.count,1)
        XCTAssertEqual(family.messages.values.filter { $0.text == "For the next task" && $0.disposition == "pending" }.count,1)
        let closed = try await parent.closeAgentFamilyFence(); XCTAssertTrue(closed)
        let follow = ToolCall(id:"follow",name:"followup_task",arguments:["target":"/root/audit","message":"Second task"])
        let followKey = try await parent.agentFixtureCall(follow,newTask:true)
        _ = try await coordinator.prepare(follow,key:followKey,parent:parent)
        try await eventually { let state = await parent.agentState(); return state.latest(child)?.turn == 2 && state.messages["result:\(child):2"] != nil }
        family = await parent.agentState()
        XCTAssertEqual(family.messages["result:\(child):2"]?.text,"second turn")
        var details: [JSON] = [], cursor = 0
        repeat {
            let page = try await coordinator.codexDetails(["detail":"messages","childId":JSON(child)],parent:parent,cursor:cursor,limit:100)
            details += page["messages"].list
            guard let next = page["cursor"].int else { break }; cursor = next
        } while true
        XCTAssertEqual(details.first { $0["text"].text == "For the next task" }?["turn"].int,2)

        let second = await client.requests.last!
        XCTAssertEqual(second.filter { $0.nativeInherited != nil }.count,1)
        XCTAssertTrue(second.contains { $0.text.contains("For the next task") })
        XCTAssertTrue(second.contains { $0.text.contains("Second task") })
        await coordinator.drain(); await parent.close()
    }
    func testMultiMiBForkAcceptanceJournalAndCheckpointCarryOnlyReferences() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:CodexProbeClient([]),tools:RecordingTools(),traces:TraceStore())
        let coordinator = AgentSteeringCoordinator(open:{ _,_ in throw AgentError("fixture","Publication only") })
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        try await parent.codexFixtureSeed("LIVE_SEED_BODY_" + String(repeating:"x",count:4 * 1024 * 1024))
        let call = ToolCall(id:"spawn",name:"spawn_agent",arguments:["task_name":"audit","message":"Task"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        _ = try await coordinator.prepare(call,key:key,parent:parent)
        try await eventually { await parent.agentState().turns.values.first?.status.terminal == true }
        await parent.refreshCheckpoint()
        let url = root.appendingPathComponent("parent.jsonl"), reader = try JournalRecordReader(url)
        var operations = 0
        while let line = try reader.nextLine() {
            let row = try JSON.parse(line)
            if row["customType"].text == JournalRecordKind.agentOperation {
                operations += 1; XCTAssertLessThan(line.count,16384)
                XCTAssertFalse(String(decoding:line,as:UTF8.self).contains("LIVE_SEED_BODY_"))
            }
        }
        XCTAssertEqual(operations,1)
        let checkpoint = try XCTUnwrap(JournalCheckpoint.read(for:url))
        XCTAssertFalse(checkpoint.helper.contains("LIVE_SEED_BODY_"))
        let plan = await parent.subagents.plans.values.first!
        XCTAssertNoThrow(try plan.forkSeed?.requirePublished(at:root.appendingPathComponent(plan.origin.link.childSessionID + ".jsonl")))
        await coordinator.drain(); await parent.close()
    }

    func testPausedV3RunKeepsItsContractUntilAFreshTask() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        let coordinator = AgentSteeringCoordinator()
        await parent.enableSubagents(SubagentCoordinator(),codex:false)
        try await parent.appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:"old"))
        await parent.codexFixtureCostPause(true)
        await parent.enableAgentSteering(coordinator,codex:true)
        let paused = await parent.sessionDefinitions()
        XCTAssertTrue(paused.contains { $0.name == "subagent_start" }); XCTAssertFalse(paused.contains { $0.name == "spawn_agent" })
        let frozen = await parent.agentContractVersion; XCTAssertEqual(frozen,3)
        await parent.codexFixtureCostPause(false)
        try await parent.startAgentEpoch(startingFresh:true)
        let fresh = await parent.sessionDefinitions()
        XCTAssertTrue(fresh.contains { $0.name == "spawn_agent" }); XCTAssertFalse(fresh.contains { $0.name == "subagent_start" })
        await parent.close()
    }
    func testFailedChildPublicationDisposesItsTaskAndLetsFamilyClose() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexProbeClient([]), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),beforeJournalAppend:{ row in
            if row["customType"].text == JournalRecordKind.agentOperation, let id = row["data"]["turn"]["childID"].text {
                try FileManager.default.createDirectory(at:root.appendingPathComponent(id + ".jsonl"),withIntermediateDirectories:true)
            }
        })
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        let call = ToolCall(id:"start",name:"spawn_agent",arguments:["task_name":"audit","message":"Task"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        _ = try await coordinator.prepare(call,key:key,parent:parent)
        let state = await parent.agentState(), turn = try XCTUnwrap(state.turns.values.first)
        XCTAssertEqual(turn.status,.notExecuted)
        XCTAssertEqual(state.messages[turn.inputID]?.disposition,"not_delivered_interrupted")
        _ = try await coordinator.boundary(parent,final:false)
        let closed = try await parent.closeAgentFamilyFence(); XCTAssertTrue(closed)
        let requests = await client.requests; XCTAssertTrue(requests.isEmpty)
        await parent.close()
    }
    func testNewRunAdvertisesV4AndPromotesMarker() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator(), client = CodexProbeClient([answer("done")])
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        let definitions = await parent.sessionDefinitions()
        XCTAssertTrue(SubagentCodexContract.names.isSubset(of:Set(definitions.map(\.name))))
        XCTAssertTrue(SubagentPolicy.capabilities.contains("subagents-codex-v4"))
        let call = ToolCall(id:"start",name:"spawn_agent",arguments:["task_name":"audit","message":"check","fork_turns":"none"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        _ = try await coordinator.prepare(call,key:key,parent:parent)
        let marker = await parent.journal?.markerKind
        XCTAssertEqual(marker,"pi-app.native.v4")
        await coordinator.drain(); await parent.close()
    }
}

extension AgentSession {
    func codexFixtureSeed(_ text: String = "Inherited context") throws {
        var row = ChatMessage(role:"user",content:[textBlock(text)]); row.userInput = ["skills":[["id":"explicit"]]]
        try append(row); boundary = context
    }
}
actor CodexProbeClient: ModelClient {
    var replies: [ModelReply]
    var requests: [[ChatMessage]] = [], instructions: [String] = [], definitions: [[ToolDefinition]] = [], caches: [String] = []
    init(_ replies: [ModelReply]) { self.replies = replies }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString, permit = try await lifecycle?.admitAttempt(UUID().uuidString)
        defer { permit?.finish() }
        requests.append(messages); self.instructions.append(instructions); definitions.append(tools); caches.append(cacheSessionID)
        guard !replies.isEmpty else { throw AgentError("fixture_exhausted",attempt) }
        return replies.removeFirst()
    }
}
