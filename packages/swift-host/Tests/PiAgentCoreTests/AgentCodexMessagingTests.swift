import XCTest
@testable import PiAgentCore

final class AgentCodexMessagingTests: HelperTestCase {
    func testMissingChildSenderNameFailsClosed() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexFamilyClient(steps:["/root/a":[answer("done")]],held:["/root/a:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        let id = try await spawn("a",parent,coordinator)
        try await eventually { await client.requests.count == 1 }
        let job = await coordinator.jobs[id + ":1"], child = try XCTUnwrap(job?.child)
        let saved = await parent.subagents
        await parent.codexFixtureForgetNamesAndPlans()
        let call = ToolCall(id:"nameless",name:"send_message",arguments:["target":"/root","message":"Must not impersonate root"])
        let key = try await child.agentFixtureCall(call)
        do { _ = try await coordinator.prepareCodex(call,key:key,caller:child); XCTFail("Nameless child sent as /root") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_recovery") }
        let messages = await parent.agentState().messages
        XCTAssertFalse(messages.values.contains { $0.text == "Must not impersonate root" })
        await parent.codexFixtureRestoreState(saved)
        await coordinator.drain(); await parent.close()
    }

    func testSiblingMessagesTasksAndRootOnlySpawn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let calls = [agentCallReply("forbidden","spawn_agent",["task_name":"nested","message":"Forbidden"]),agentCallReply("mail","send_message",["target":"b","message":"Sibling information"]),agentCallReply("task","followup_task",["target":"/root/b","message":"Sibling task"])]
        var reply = ModelReply(message:ChatMessage(role:"assistant",content:[])); reply.calls = calls.flatMap(\.calls); reply.message.content = calls.flatMap { $0.message.content }
        let client = CodexFamilyClient(steps:["/root/a":[reply,answer("A final")],"/root/b":[agentCallReply("boundary","read",["path":"fixture"]),answer("B final")]],held:["/root/a:1","/root/b:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        let a = try await spawn("a",parent,coordinator), b = try await spawn("b",parent,coordinator)
        try await eventually { await client.requests.count == 2 }
        await client.release("/root/a:1")
        try await eventually { await parent.agentState().messages["result:\(a):1"] != nil }
        var family = await parent.agentState()
        XCTAssertEqual(family.turns.count,2,"A busy sibling receives NEW_TASK in its current turn")
        XCTAssertEqual(family.messages.values.filter { $0.sender == "/root/a" && $0.recipient == "/root/b" }.count,2)
        await client.release("/root/b:1")
        try await eventually { await parent.agentState().messages["result:\(b):1"] != nil }
        let request = await client.requests.last { $0.name == "/root/b" }!
        XCTAssertTrue(request.messages.contains { $0.text.contains("Sibling information") && $0.text.contains("Sibling task") })
        let aRequest = await client.requests.last { $0.name == "/root/a" }!
        XCTAssertTrue(aRequest.messages.contains { $0.toolName == "spawn_agent" && $0.isError && $0.text.contains("agent_spawn_root_only") })
        family = await parent.agentState()
        XCTAssertEqual(family.messages.values.filter { $0.type == "FINAL_ANSWER" && $0.recipient == "/root" }.count,2)
        await coordinator.drain(); await parent.close()
    }
    func testFinalDefersQueueOnlyMailWithoutAnotherRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexFamilyClient(steps:["/root/a":[answer("A final"),answer("Next final")]],held:["/root/a:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        let a = try await spawn("a",parent,coordinator)
        try await eventually { await client.requests.count == 1 }
        _ = try await command("send_message",["target":"a","message":"Deliver next time"],parent,coordinator)
        await client.release("/root/a:1")
        try await eventually { await parent.agentState().messages["result:\(a):1"] != nil }
        let count = await client.requests.count; XCTAssertEqual(count,1)
        let family = await parent.agentState()
        XCTAssertEqual(family.messages.values.first { $0.text == "Deliver next time" }?.disposition,"pending")
        _ = try await command("followup_task",["target":"a","message":"Next task"],parent,coordinator)
        try await eventually { let state = await parent.agentState(); return state.latest(a)?.turn == 2 && state.messages["result:\(a):2"] != nil }
        let last = await client.requests.last!.messages
        let mail = last.firstIndex { $0.text.contains("Deliver next time") }, task = last.firstIndex { $0.text.contains("Next task") }
        XCTAssertNotNil(mail); XCTAssertNotNil(task); if let mail, let task { XCTAssertLessThan(mail,task) }
        await coordinator.drain(); await parent.close()
    }
    func testRootInterruptSuppressesResultAndNextTaskCarriesNote() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexFamilyClient(steps:["/root/a":[answer("cancelled"),answer("Next final")]],held:["/root/a:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        let a = try await spawn("a",parent,coordinator)
        try await eventually { await client.requests.count == 1 }
        let result = try await command("interrupt_agent",["target":"a"],parent,coordinator)
        XCTAssertEqual(result["output"].text,"{\"previous_status\":\"running\"}")
        try await eventually { await parent.agentState().messages["result:\(a):1"] != nil }
        var family = await parent.agentState()
        XCTAssertEqual(family.latest(a)?.interruptedBy,"/root")
        XCTAssertEqual(family.messages["result:\(a):1"]?.disposition,"suppressed")
        _ = try await command("followup_task",["target":"a","message":"Try again"],parent,coordinator)
        try await eventually { let state = await parent.agentState(); return state.latest(a)?.turn == 2 && state.messages["result:\(a):2"] != nil }
        let last = await client.requests.last!.messages
        XCTAssertTrue(last.contains { $0.text.contains("The previous turn was interrupted on purpose by /root.") })
        family = await parent.agentState(); XCTAssertEqual(family.messages["result:\(a):2"]?.disposition,"pending")
        await coordinator.drain(); await parent.close()
    }
    func testSiblingInterruptAndUserHold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexFamilyClient(steps:["/root/a":[agentCallReply("interrupt","interrupt_agent",["target":"b"]),answer("A final")],"/root/b":[answer("cancelled")]],held:["/root/a:1","/root/b:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        let a = try await spawn("a",parent,coordinator), b = try await spawn("b",parent,coordinator)
        try await eventually { await client.requests.count == 2 }; await client.release("/root/a:1")
        try await eventually { await parent.agentState().messages["result:\(b):1"] != nil }
        let family = await parent.agentState()
        XCTAssertEqual(family.messages["result:\(b):1"]?.text,"Agent interrupted by /root/a.")
        try await coordinator.stop(parent:parent,target:.init(childID:a,turn:1),human:true)
        do { _ = try await command("followup_task",["target":"a","message":"Must not lift Stop"],parent,coordinator); XCTFail("User hold was lifted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_stopped") }
        await coordinator.drain(); await parent.close()
    }
    func testParentHumanStopRecordsTheInitiator() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexFamilyClient(steps:["/root/a":[answer("cancelled")]],held:["/root/a:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        let a = try await spawn("a",parent,coordinator)
        try await eventually { await client.requests.count == 1 }
        await parent.stop()
        try await eventually { await parent.agentState().messages["result:\(a):1"] != nil }
        let family = await parent.agentState()
        XCTAssertEqual(family.latest(a)?.interruptedBy,"the user")
        XCTAssertEqual(family.messages["result:\(a):1"]?.text,"Agent stopped by the user.")
        await coordinator.drain(); await parent.close()
    }
    func testWaitMailboxSteerStopCostAndTimeout() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = CodexFamilyClient(steps:["/root/a":[answer("A final")]],held:["/root/a:1"])
        let (parent,coordinator) = try await setup(root,client:client)
        _ = try await spawn("a",parent,coordinator)
        let wait = Task { await coordinator.codexWait(["timeout_ms":10000],caller:parent) }
        await client.release("/root/a:1")
        let woke = await wait.value; XCTAssertEqual(woke,"Wait completed: updates from /root/a.")
        _ = try await coordinator.boundary(parent,final:false)
        await parent.codexFixtureSteer()
        let steer = await coordinator.codexWait([:],caller:parent); XCTAssertEqual(steer,"Wait interrupted by new input.")
        await parent.codexFixtureClearSteer()
        let stopped = Task { await coordinator.codexWait([:],caller:parent) }; stopped.cancel()
        let stop = await stopped.value; XCTAssertEqual(stop,"Wait interrupted by Stop.")
        await parent.codexFixtureCostPause(true)
        let cost = await coordinator.codexWait([:],caller:parent); XCTAssertEqual(cost,"Wait interrupted by cost limit.")
        await parent.codexFixtureCostPause(false)
        let timed = await coordinator.codexWait(["timeout_ms":0],caller:parent)
        XCTAssertEqual(timed,"Wait timed out. Timeout raised to 10000 ms.")
        await coordinator.drain(); await parent.close()
    }
    private func setup(_ root: URL, client: CodexFamilyClient) async throws -> (AgentSession,AgentSteeringCoordinator) {
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        let coordinator = AgentSteeringCoordinator(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        return (parent,coordinator)
    }
    private func spawn(_ name: String, _ parent: AgentSession, _ coordinator: AgentSteeringCoordinator) async throws -> String {
        let receipt = try await command("spawn_agent",["task_name":JSON(name),"message":"Task","fork_turns":"none"],parent,coordinator,newTask:await parent.activeTaskPresentation == nil)
        return receipt["child_id"].text!
    }
    private func command(_ name: String, _ args: JSON, _ parent: AgentSession, _ coordinator: AgentSteeringCoordinator, newTask: Bool = false) async throws -> JSON {
        let call = ToolCall(id:UUID().uuidString,name:name,arguments:args), key = try await parent.agentFixtureCall(call,newTask:newTask)
        return try await coordinator.prepare(call,key:key,parent:parent)
    }
}

extension AgentSession {
    func codexFixtureForgetNamesAndPlans() { subagents.plans = [:]; subagents.family?.names = [:] }
    func codexFixtureRestoreState(_ state: SubagentJournalState) { subagents = state }

    func codexFixtureSteer() { steering = [Submission(commandID:"steer",turnID:"steer",text:"New input")] }
    func codexFixtureClearSteer() { steering = [] }
    func codexFixtureCostPause(_ paused: Bool) { costPaused = paused }
}
actor CodexFamilyClient: ModelClient {
    struct Request { var name: String, messages: [ChatMessage] }
    var steps: [String:[ModelReply]], held: Set<String>, counts: [String:Int] = [:], requests: [Request] = []
    init(steps: [String:[ModelReply]], held: Set<String> = []) { self.steps = steps; self.held = held }
    func release(_ key: String) { held.remove(key) }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let name = messages.flatMap { $0.nativeAgentDelivery?["events"].list ?? [] }.first { $0["type"].text == "NEW_TASK" }?["recipient"].text ?? "/root"
        let attempt = UUID().uuidString, permit = try await lifecycle?.admitAttempt(UUID().uuidString); defer { permit?.finish() }
        counts[name,default:0] += 1; let number = counts[name]!
        requests.append(Request(name:name,messages:messages))
        while held.contains(name + ":" + String(number)) { try await Task.sleep(for:.milliseconds(5)) }
        guard let replies = steps[name], number <= replies.count else { throw AgentError("fixture_exhausted",attempt) }
        return replies[number-1]
    }
}
