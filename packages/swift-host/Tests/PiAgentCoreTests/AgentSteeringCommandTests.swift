import XCTest
@testable import PiAgentCore

final class AgentSteeringCommandTests: HelperTestCase {
    func testUnlistedModelStartReportsFallbackAndFollowUpKeepsIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = AccountedAgentScript([answer("First answer"), answer("Follow-up answer")])
        let coordinator = AgentSteeringCoordinator()
        let profile = try fixtureProfile()
        let parent = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = ToolCall(id:"start",name:"subagent_start",arguments:["task":"Original task","mode":"background","model":"not-offered"])
        let key = try await parent.agentFixtureCall(start,newTask:true)
        try await parent.runToolBatch([start])
        let results = await parent.history.filter { $0.toolCallId == start.id }
        let result = try XCTUnwrap(results.last)
        XCTAssertFalse(result.isError)
        let receipt = try JSON.parse(Data(result.text.utf8))
        XCTAssertEqual(receipt["accepted"].flag, true)
        XCTAssertEqual(receipt["model"].text, profile.model)
        XCTAssertEqual(receipt["model_notice"].text, "Requested model 'not-offered' is not offered for this connection; using the parent's model 'fixture-model' instead.")
        let child = try XCTUnwrap(receipt["child_id"].text)
        let duplicate = try await coordinator.prepare(start,key:key,parent:parent)
        XCTAssertEqual(duplicate, receipt)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let send = ToolCall(id:"follow",name:"subagent_send",arguments:["child_id":JSON(child),"message":"Follow up"])
        let followKey = try await parent.agentFixtureCall(send,newTask:true)
        let follow = try await coordinator.prepare(send,key:followKey,parent:parent)
        XCTAssertEqual(follow["model"].text, profile.model)
        try await eventually {
            let latest = await parent.agentState().latest(child)
            return latest?.turn == 2 && latest?.status.terminal == true
        }
        let profiles = await client.profiles
        XCTAssertEqual(profiles.map(\.model), [profile.model, profile.model])
        XCTAssertTrue(profiles.allSatisfy { $0.id == profile.id && $0.endpoint == profile.endpoint })
        await coordinator.drain(); await parent.close()
    }

    func testStartWithWaitIDListsItsAcceptedTurnBeforeAndAfterReopen() async throws {
        try await startWaitLookup(legacy: false)
    }
    func testLegacyStartWithWaitIDListsItsAcceptedTurnAfterReopen() async throws {
        try await startWaitLookup(legacy: true)
    }
    private func startWaitLookup(legacy: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = AccountedAgentScript([answer("Child answer")], held: true), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = ToolCall(id:"start",name:"subagent_start",arguments:["task":"Inspect the project","mode":"wait","timeout_ms":0])
        _ = try await parent.agentFixtureCall(start,newTask:true)
        try await parent.runToolBatch([start])
        let results = await parent.history.filter { $0.toolCallId == start.id }
        let receipt = try JSON.parse(Data(try XCTUnwrap(results.last).text.utf8))
        let waitID = try XCTUnwrap(receipt["wait"]["wait_id"].text), child = try XCTUnwrap(receipt["child_id"].text)
        XCTAssertEqual(receipt["wait"]["wake_reason"].text,"timeout")
        let args: JSON = ["action":"list","wait_id":JSON(waitID)]
        func check(_ session: AgentSession) async {
            do {
                let listed = try await coordinator.status(args,parent:session)
                XCTAssertEqual(listed["total"].int,1)
                XCTAssertEqual(listed["children"].list.first?["child_id"].text,child)
                XCTAssertEqual(listed["children"].list.first?["turn"].int,1)
            } catch { XCTFail("Returned wait ID must remain usable: \(error)") }
        }
        if !legacy {
            let operation = await parent.agentState().operations[waitID]
            XCTAssertEqual(operation?.waitTargets, [.init(childID:child,turn:1)])
            await check(parent)
        }
        await client.release(); try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let saved = await parent.path, path = try XCTUnwrap(saved)
        await coordinator.drain(); await parent.close()
        if legacy {
            let lines = try String(contentsOfFile:path,encoding:.utf8).split(separator:"\n").map { line -> String in
                var record = try JSON.parse(Data(line.utf8))
                if record["customType"].text == JournalRecordKind.agentOperation { record["data"] = record["data"].removing(["waitTargets"]) }
                return record.encoded()
            }
            try (lines.joined(separator:"\n") + "\n").write(toFile:path,atomically:true,encoding:.utf8)
        }
        let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path)
        await check(reopened)
        await reopened.close()
    }

    func testAcceptedStartDeduplicatesAndFollowUpUsesSameConversation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("First answer"),answer("Second answer")])
        let coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = ToolCall(id:"start",name:"subagent_start",arguments:["task":"Original task","mode":"background"])
        let key = try await parent.agentFixtureCall(start,newTask:true)
        let receipt = try await coordinator.prepare(start,key:key,parent:parent)
        let duplicate = try await coordinator.prepare(start,key:key,parent:parent)
        XCTAssertEqual(receipt,duplicate)
        let child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let first = await parent.agentState()
        XCTAssertEqual(first.latest(child)?.status,.completed,"\(String(describing:first.latest(child)?.result))")
        XCTAssertEqual(first.turns.count,1); XCTAssertEqual(first.operations.count,1)
        let send = ToolCall(id:"send",name:"subagent_send",arguments:["child_id":JSON(child),"message":"Explain your first answer","expected_turn":1])
        let sendKey = try await parent.agentFixtureCall(send,newTask:true)
        let follow = try await coordinator.prepare(send,key:sendKey,parent:parent)
        XCTAssertEqual(follow["route"].text,"follow_up"); XCTAssertEqual(follow["turn"].int,2)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let requests = await client.requests, family = await parent.agentState()
        XCTAssertEqual(requests.count,2)
        XCTAssertTrue(requests.last?.contains { $0.text == "First answer" } == true)
        XCTAssertTrue(requests.last?.contains { $0.text == "Original task" } == true)
        XCTAssertEqual(family.turns[AgentTurnTarget(childID:child,turn:1).id]?.result?.envelope["text"].text,"First answer")
        XCTAssertEqual(family.latest(child)?.result?.envelope["text"].text,"Second answer")
        XCTAssertEqual(Set(requests.flatMap { $0.filter { $0.role == "user" }.compactMap { $0.nativeAgentDelivery?["author"].text } }),["parent"])
        await coordinator.drain(); await parent.close()
    }
    func testConflictingOperationCannotChangeAcceptedBody() throws {
        let key = SubagentCallKey(parentSessionID:"parent",assistantMessageID:"a",toolCallID:"c")
        var state = AgentFamilyState(ownerID:"parent")
        var op = AgentOperation(key:key,digest:"original",receipt:["accepted":true],epoch:"e")
        try state.operation(op); try state.operation(op)
        XCTAssertEqual(state.operations.count,1); XCTAssertEqual(state.revision,1)
        op.digest = "changed"
        XCTAssertThrowsError(try state.operation(op))
        XCTAssertEqual(state.operations[op.id]?.digest,"original")
    }
}
extension AgentSession {
    func agentFixtureCall(_ call: ToolCall, newTask: Bool = false) throws -> SubagentCallKey {
        if newTask { queuePaused = false; beginPresentedTask(UUID().uuidString); currentTurnID = activeTaskPresentation!.rootID }
        var row = ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(call.id),"name":JSON(call.name),"arguments":call.arguments]])
        row.id = UUID().uuidString; try append(row)
        return try agentToolKey(call)
    }
}

actor AccountedAgentScript: ModelClient {
    var replies: [ModelReply], requests: [[ChatMessage]] = [], scopes: [RequestScope?] = []
    var instructionHistory: [String] = []
    var profiles: [Profile] = []
    var held: Bool
    init(_ replies: [ModelReply], held: Bool = false) { self.replies = replies; self.held = held }
    func release() { held = false }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString
        let permit = try await lifecycle?.admitAttempt(attempt); defer { permit?.finish() }
        try await lifecycle?.willDispatch(attempt)
        let index = requests.count; requests.append(messages); scopes.append(lifecycle?.scope); instructionHistory.append(instructions); profiles.append(profile)
        guard index < replies.count else { throw AgentError("fixture_exhausted","Unexpected request") }
        while held { try await Task.sleep(for:.milliseconds(5)) }
        var reply = replies[index]
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        observation.fields = ["input":10,"output":2,"total":12]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation); reply.message.requestAttemptIDs = [attempt]; return reply
    }
}

extension AgentSteeringCommandTests {
    func testV3DoesNotExecuteHiddenV2ToolOrOfferDelegationToChild() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(AgentSteeringCoordinator())
        let definitions = await parent.sessionDefinitions()
        XCTAssertFalse(definitions.contains { $0.name == "subagent" })
        XCTAssertTrue(Set(SubagentSteeringContract.parentNames).isSubset(of:Set(definitions.map(\.name))))
        let call = ToolCall(id:"hidden",name:"subagent",arguments:["task":"Must not execute"])
        _ = try await parent.agentFixtureCall(call,newTask:true)
        try await parent.runToolBatch([call])
        let state = await parent.subagents, results = await parent.history.filter { $0.toolCallId == "hidden" }
        XCTAssertTrue(state.plans.isEmpty)
        XCTAssertEqual(results.count,1); XCTAssertTrue(results[0].isError)
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),prepared:nil,subagentOrigin:subagentFixtureOrigin())
        await child.enableSubagents(SubagentCoordinator()); await child.enableAgentSteering(AgentSteeringCoordinator())
        let offered = await child.sessionDefinitions()
        XCTAssertTrue(offered.contains { $0.name == "subagent_report" })
        XCTAssertFalse(offered.contains { SubagentSteeringContract.parentNames.contains($0.name) })
        await child.close(); await parent.close()
    }
}
