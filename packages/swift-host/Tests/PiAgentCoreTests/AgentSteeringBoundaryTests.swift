import XCTest
@testable import PiAgentCore

final class AgentSteeringBoundaryTests: XCTestCase {
    func testParentFinalWaitKeepsFamilyAliveAndDeliversResultOnce() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentBoundaryClient(), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"user",text:"Delegate then synthesize"),steer:false)
        try await eventually { await client.parentCount >= 2 }
        try await eventually { let waiting = await parent.familyWaiting, running = await parent.isRunning; return waiting || !running }
        let running = await parent.isRunning
        XCTAssertTrue(running,"Final-wait fence: a parent cannot finish with an active child")
        await client.release()
        try await eventually { !(await parent.isRunning) }
        let rows = await parent.history.filter { $0.nativeAgentDelivery?["author"].text == "subagent" }
        XCTAssertEqual(rows.count,1)
        let requests = await client.parentRequests
        XCTAssertEqual(requests.count,3)
        XCTAssertTrue(requests.last?.contains { $0.text.contains("Child final") } == true)
        XCTAssertTrue(rows.allSatisfy { $0.userInput == nil })
        await coordinator.drain(); await parent.close()
    }
    func testQuestionWakesStartWaitAndParentReplySteersBusyChild() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentBoundaryClient(reports:true), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"user",text:"Work together"),steer:false)
        try await eventually { let p = await client.parentCount, c = await client.childCount; return p >= 3 && c >= 2 }
        let before = await client.childRequests
        XCTAssertFalse(before[1].contains { $0.text.contains("Use the safe path") },"No splice into an in-flight request")
        await client.release()
        try await eventually { !(await parent.isRunning) }
        let requests = await client.childRequests, family = await parent.agentState(), rows = await parent.history
        XCTAssertEqual(requests.count,3)
        XCTAssertTrue(requests.last?.contains { $0.nativeAgentDelivery?["author"].text == "parent" && $0.text.contains("Use the safe path") } == true)
        XCTAssertEqual(family.messages.values.filter { $0.kind == "question" && $0.disposition == "delivered" }.count,1)
        XCTAssertEqual(family.messages.values.filter { $0.kind == "steer" && $0.disposition == "delivered" }.count,1)
        XCTAssertEqual(rows.filter { $0.nativeAgentDelivery?["events"].list.contains { $0["kind"].text == "question" } == true }.count,1)
        await coordinator.drain(); await parent.close()
    }

}
actor AgentBoundaryClient: ModelClient {
    let reports: Bool, starts: Int
    init(reports: Bool = false, starts: Int = 1) { self.reports = reports; self.starts = starts }
    var parentCount = 0, childCount = 0, released = false
    var parentRequests: [[ChatMessage]] = [], childRequests: [[ChatMessage]] = []
    func release() { released = true }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString
        let permit = try await lifecycle?.admitAttempt(attempt); defer { permit?.finish() }
        try await lifecycle?.willDispatch(attempt)
        var reply: ModelReply
        if sessionID == "parent" {
            parentCount += 1; parentRequests.append(messages)
            if parentCount == 1 {
                reply = ModelReply(message:ChatMessage(role:"assistant",content:[]))
                for index in 0..<starts { let start = agentCallReply("start-\(index)","subagent_start",["task":"Child task","mode":JSON(reports ? "wait" : "background")]); reply.calls += start.calls; reply.message.content += start.message.content }
            }
            else if reports && parentCount == 2 {
                let event = messages.flatMap { $0.nativeAgentDelivery?["events"].list ?? [] }.first { $0["kind"].text == "question" }
                reply = agentCallReply("send","subagent_send",["child_id":event?["child_id"] ?? "missing","message":"Use the safe path","reply_to":event?["event_id"] ?? "missing"])
            } else { reply = answer("Parent final") }
        } else {
            childCount += 1; childRequests.append(messages)
            if reports && childCount == 1 { reply = agentCallReply("report","subagent_report",["kind":"question","message":"Which path is safe?"]) }
            else {
                while !released { try await Task.sleep(for:.milliseconds(5)) }
                try permit?.check(); reply = answer("Child final")
            }
        }
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation); reply.message.requestAttemptIDs = [attempt]; return reply
    }
}
func agentCallReply(_ id: String, _ name: String, _ arguments: JSON) -> ModelReply {
    let call = ToolCall(id:id,name:name,arguments:arguments)
    return ModelReply(message:ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(id),"name":JSON(name),"arguments":arguments]]),calls:[call])
}

extension AgentSteeringBoundaryTests {
    func testWaitOneAnyAllFreezeTargetsAndForeignReportWakesWait() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        let coordinator = AgentSteeringCoordinator()
        let key = SubagentCallKey(parentSessionID:"parent",assistantMessageID:"a",toolCallID:"wait")
        var one = AgentChildTurn(childID:"one",turn:1,executionID:"e1",parentExecutionID:"parent-e",generation:0,runtimeID:"runtime",epoch:"parent-e",inputID:"input1",task:"task",call:key)
        let two = AgentChildTurn(childID:"two",turn:1,executionID:"e2",parentExecutionID:"parent-e",generation:0,runtimeID:"runtime",epoch:"parent-e",inputID:"input2",task:"task",call:key)
        one.status = .completed
        try await parent.appendAgentRecord(JournalRecordKind.agentTurn,one); try await parent.appendAgentRecord(JournalRecordKind.agentTurn,two)
        let frozen = try await coordinator.waitTargets(["mode":"all"],state:parent.agentState(),execution:"parent-e")
        let op = AgentOperation(key:key,digest:"d",receipt:[:],waitTargets:frozen,epoch:"parent-e")
        try await parent.appendAgentRecord(JournalRecordKind.agentOperation,op)
        let receipt: JSON = ["wait_id":JSON(op.id)]
        let any = try await coordinator.wait(receipt,args:["mode":"any","timeout_ms":0],parent:parent)
        let all = try await coordinator.wait(receipt,args:["mode":"all","timeout_ms":0],parent:parent)
        XCTAssertEqual(any["wake_reason"].text,"settled"); XCTAssertEqual(all["wake_reason"].text,"timeout")
        XCTAssertEqual(all["pending_count"].int,1)
        let report = AgentFamilyMessage(id:"outside",sequence:1,childID:"another",turn:1,author:"subagent",kind:"blocker",text:"Important",task:"Another task",epoch:"parent-e")
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,report)
        let woke = try await coordinator.wait(receipt,args:["mode":"all","timeout_ms":60000],parent:parent)
        XCTAssertEqual(woke["wake_reason"].text,"message"); XCTAssertEqual(woke["target_count"].int,2)
        let state = await parent.agentState()
        do { _ = try await coordinator.waitTargets(["mode":"one","targets":[["child_id":"foreign","turn":1]]],state:state,execution:"parent-e"); XCTFail("Unknown target accepted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_scope") }
        await parent.close()
    }
}

extension AgentSteeringBoundaryTests {
    func testChildCostLimitStopsParentInUnrelatedToolAndSettlesFamily() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tools = AgentBudgetHoldTools(), client = AgentBudgetClient(), coordinator = AgentSteeringCoordinator()
        await client.bind(tools)
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        try await parent.setCostLimit(0.015)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"user",text:"Parallel work"),steer:false)
        try await eventually { !(await parent.isRunning) }
        let spend = await parent.spend, family = await parent.agentState(), entered = await tools.entered, calls = await client.requests
        XCTAssertTrue(entered)
        XCTAssertEqual(spend.usd,0.02,accuracy:0.000001)
        XCTAssertEqual(calls,2,"No third request may pass family admission")
        XCTAssertTrue(family.turns.values.allSatisfy { $0.status.terminal })
        XCTAssertEqual(family.turns.count,1)
        let code = await parent.errorCode
        XCTAssertEqual(code,AgentSession.costLimitCode)
        await parent.close()
    }
}
actor AgentBudgetHoldTools: ToolExecuting {
    var entered = false
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("hold","fixture unrelated tool",["type":"object","properties":[:]])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        entered = true
        while true { try await Task.sleep(for:.seconds(1)) }
    }
}
actor AgentBudgetClient: ModelClient {
    var tools: AgentBudgetHoldTools?, requests = 0
    func bind(_ tools: AgentBudgetHoldTools) { self.tools = tools }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString
        let permit = try await lifecycle?.admitAttempt(attempt); defer { permit?.finish() }
        try await lifecycle?.willDispatch(attempt); requests += 1
        var reply: ModelReply
        if sessionID == "parent" {
            reply = agentCallReply("start","subagent_start",["task":"Child task","mode":"background"])
            let hold = agentCallReply("hold","hold",[:]); reply.calls += hold.calls; reply.message.content += hold.message.content
        } else {
            while !(await self.tools!.entered) { try await Task.sleep(for:.milliseconds(5)) }
            reply = answer("Discovery costing the rest of the budget")
        }
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation); reply.message.requestAttemptIDs = [attempt]; return reply
    }
}

extension AgentSteeringBoundaryTests {
    func testCloseDrainsSixteenActiveAndTwoQueuedTurnsWithoutDispatchingQueuedWork() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentBoundaryClient(starts:18), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"user",text:"Parallel work"),steer:false)
        try await eventually { await client.childCount == 16 }
        try await eventually { await parent.familyWaiting }
        let pending = await coordinator.list(parent:parent,cursor:0,limit:100)
        XCTAssertEqual(pending["active"].int,16)
        XCTAssertEqual(pending["children"].list.filter { $0["status"].text == "queued" }.count,2)
        await parent.close()
        let family = await parent.agentState(), calls = await client.childCount
        XCTAssertEqual(calls,16)
        XCTAssertEqual(family.turns.values.filter { $0.status == .notExecuted }.count,2)
        XCTAssertTrue(family.turns.values.allSatisfy { $0.status.terminal })
        for turn in family.turns.values {
            let reader = try JournalRecordReader(root.appendingPathComponent(turn.childID + ".jsonl"))
            var state = SubagentJournalState()
            while let row = try reader.next() { try state.consume(row,sessionID:turn.childID) }
            XCTAssertEqual(state.family?.latest(turn.childID)?.status,turn.status)
        }
    }
}
