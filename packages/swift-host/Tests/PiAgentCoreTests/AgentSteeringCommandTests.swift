import XCTest
@testable import PiAgentCore

final class AgentSteeringCommandTests: XCTestCase {
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
        if newTask { beginPresentedTask(UUID().uuidString); currentTurnID = activeTaskPresentation!.rootID }
        var row = ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(call.id),"name":JSON(call.name),"arguments":call.arguments]])
        row.id = UUID().uuidString; try append(row)
        return try agentToolKey(call)
    }
}

actor AccountedAgentScript: ModelClient {
    var replies: [ModelReply], requests: [[ChatMessage]] = [], scopes: [RequestScope?] = []
    init(_ replies: [ModelReply]) { self.replies = replies }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString
        let permit = try await lifecycle?.admitAttempt(attempt); defer { permit?.finish() }
        try await lifecycle?.willDispatch(attempt)
        let index = requests.count; requests.append(messages); scopes.append(lifecycle?.scope)
        guard index < replies.count else { throw AgentError("fixture_exhausted","Unexpected request") }
        var reply = replies[index]
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        observation.fields = ["input":10,"output":2,"total":12]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation); reply.message.requestAttemptIDs = [attempt]; return reply
    }
}
