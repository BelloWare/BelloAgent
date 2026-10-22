import XCTest
@testable import PiAgentCore

final class SubagentPolicyEffortTests: HelperTestCase {
    static let policy = "Start sub-agents only when the user explicitly asks for sub-agents/agents, delegation, or parallel work; otherwise do the work yourself, even for large tasks."

    func testPromptRuleOnlyWhenParentDelegationToolsAreOffered() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try effortFixture(root:root)
        let snapshot = try await Resources(cwd:root,home:root).resolve()
        let disabled = try await parent.prepareRequest(snapshot)
        XCTAssertEqual(disabled.instructions, AgentSession.requestInstructions(snapshot.prompt))
        for steering in [false, true] {
            await parent.enableSubagents(SubagentCoordinator(),steering:steering)
            let request = try await parent.prepareRequest(snapshot)
            XCTAssertEqual(request.instructions, disabled.instructions + "\n" + Self.policy)
            XCTAssertTrue(request.definitions.first { $0.name == (steering ? "subagent_start" : "subagent") }?.description.contains(Self.policy) == true)
        }
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),prepared:nil,subagentOrigin:subagentFixtureOrigin())
        await child.enableAgentSteering(AgentSteeringCoordinator())
        let childRequest = try await child.prepareRequest(snapshot)
        XCTAssertEqual(childRequest.instructions,disabled.instructions)
        XCTAssertFalse(childRequest.definitions.contains { $0.name == "subagent_start" })
        await child.close(); await parent.close()
    }

    func testSchemaEffortUsesCurrentModelCapabilities() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile().overriding(model:nil,thinkingLevel:"high")
        let parent = try effortFixture(root:root,profile:profile)
        await parent.enableSubagents(SubagentCoordinator())
        let grant = try JSONDecoder().decode(SubagentModelGrant.self,from:JSON.object(["model":JSON(profile.model),"reasoning":["low","high"]]).data())
        try await parent.configureSubagentModels([grant])
        let definitions = await parent.sessionDefinitions()
        XCTAssertEqual(definitions.first { $0.name == "subagent_start" }?.schema["properties"]["effort"]["enum"].list.compactMap(\.text),["default","low","high"])
        let noEffort = try JSONDecoder().decode(SubagentModelGrant.self,from:JSON.object(["model":JSON(profile.model),"reasoning":[]]).data())
        try await parent.configureSubagentModels([noEffort])
        let disabled = await parent.sessionDefinitions()
        XCTAssertNil(disabled.first { $0.name == "subagent_start" }?.schema["properties"].map["effort"])
        await parent.close()
    }

    func testExplicitEffortReachesChildAndSummaryWire() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("done")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,profile:fixtureProfile().overriding(model:nil,thinkingLevel:"high"),client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let call = ToolCall(id:"start",name:"subagent_start",arguments:["task":"Task","mode":"background","effort":"low"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        let receipt = try await coordinator.prepare(call,key:key,parent:parent)
        let child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let profiles = await client.profiles
        XCTAssertEqual(profiles.first?.raw["thinkingLevel"].text,"low")
        XCTAssertEqual(receipt["effort"].text,"low")
        let wire = await coordinator.list(parent:parent,cursor:0,limit:10)
        XCTAssertEqual(wire["children"].list.first?["effort"].text,"low")
        let status = try await coordinator.status(["action":"list"],parent:parent)
        XCTAssertEqual(status["children"].list.first?["effort"].text,"low")
        await coordinator.drain(); await parent.close()
    }

    func testUnsupportedKnownEffortIsRejectedBeforeAcceptanceOrRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw = try fixtureProfile().raw; raw["thinkingLevelMap"] = ["max":.null]
        let client = AccountedAgentScript([answer("must not run")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,profile:Profile(raw),client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let call = ToolCall(id:"invalid",name:"subagent_start",arguments:["task":"Task","mode":"background","effort":"max"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        do { _ = try await coordinator.prepare(call,key:key,parent:parent); XCTFail("Unsupported effort accepted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_effort") }
        let state = await parent.agentState(), requests = await client.requests
        XCTAssertTrue(state.operations.isEmpty); XCTAssertTrue(state.turns.isEmpty); XCTAssertTrue(requests.isEmpty)
        await coordinator.drain(); await parent.close()
    }
}


private func effortFixture(root: URL, profile: Profile? = nil, client: any ModelClient = ScriptClient([]), traces: TraceStore = TraceStore(), resume: Bool = false) throws -> AgentSession {
    try AgentSession(id:"parent",profile:profile ?? fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
        resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:traces,
        resumePath:resume ? root.appendingPathComponent("parent.jsonl").path : nil)
}

extension SubagentPolicyEffortTests {
    func testPerModelSchemaBranchesAndNoEffortModel() throws {
        var raw = try fixtureProfile().raw; raw["thinkingLevelMap"] = ["max":.null,"low":"wire-low"]
        let profile = try Profile(raw)
        let models = [SubagentModelGrant(model:profile.model,reasoning:["low","high","max"]),
                      SubagentModelGrant(model:"other",reasoning:["medium","max"]),
                      SubagentModelGrant(model:"plain",reasoning:[])]
        let definitions = SubagentSteeringContract.definitions(child:false,models:models,profile:profile,connectionSupportsReasoning:true)
        let start = try XCTUnwrap(definitions.first { $0.name == "subagent_start" }).schema
        let variants = start["oneOf"].list
        XCTAssertEqual(variants.count,4)
        XCTAssertEqual(variants[0]["properties"]["effort"]["enum"].list.compactMap(\.text),["default","low","high"])
        let otherModel = try XCTUnwrap(variants.first { $0["properties"]["model"]["enum"].list.contains("other") })
        XCTAssertEqual(otherModel["properties"]["effort"]["enum"].list.compactMap(\.text),["default","medium","max"])
        let plainModel = try XCTUnwrap(variants.first { $0["properties"]["model"]["enum"].list.contains("plain") })
        XCTAssertNil(plainModel["properties"].map["effort"])
        let send = try XCTUnwrap(definitions.first { $0.name == "subagent_send" }).schema
        XCTAssertTrue(send["oneOf"].isNull)
        XCTAssertEqual(send["properties"]["effort"]["enum"].list.compactMap(\.text),Profile.thinkingLevels)
    }

    func testOmittedEffortInheritsEffectiveParentTurnAndClampsOnlyInheritance() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw = try fixtureProfile().raw; raw["thinkingLevelMap"] = ["minimal":.null]
        let client = AccountedAgentScript([answer("done")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,profile:Profile(raw),client:client)
        await parent.effortFixtureTurn(level:"minimal")
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let receipt = try await accept("subagent_start",["task":"Task","mode":"background"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let profiles = await client.profiles, state = await parent.subagents
        XCTAssertEqual(profiles.first?.raw["thinkingLevel"].text,"low")
        XCTAssertEqual(state.plans.values.first?.origin.model.thinkingLevel,"low")
        XCTAssertEqual(state.family?.latest(child)?.effort,"low")
        await coordinator.drain(); await parent.close()
    }

    func testInvalidEffortsAreToolErrorsWithoutAcceptanceOrRequests() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        for (index,value) in [JSON("ultra"),"HIGH"," high ","",.null,1,true].enumerated() {
            let call = ToolCall(id:"invalid-\(index)",name:"subagent_start",arguments:["task":"Task","mode":"background","effort":value])
            _ = try await parent.agentFixtureCall(call,newTask:index == 0)
            try await parent.runToolBatch([call])
            let result = await parent.history.last { $0.toolCallId == call.id }
            XCTAssertTrue(result?.isError == true)
            let envelope = try JSON.parse(Data((result?.text ?? "{}").utf8))
            XCTAssertEqual(envelope["accepted"],false)
        }
        let state = await parent.agentState(), requests = await client.requests
        XCTAssertTrue(state.operations.isEmpty); XCTAssertTrue(state.turns.isEmpty); XCTAssertTrue(requests.isEmpty)
        await coordinator.drain(); await parent.close()
    }

    func testOverrideValidatesChosenModelAndNoControlRejectsEffort() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("done"),answer("plain")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,profile:fixtureProfile().overriding(model:nil,thinkingLevel:"high"),client:client)
        let models = [SubagentModelGrant(model:"other",reasoning:["low"]),SubagentModelGrant(model:"plain",reasoning:[])]
        await parent.effortFixtureTurn(models:models)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        for (model,effort) in [("other","high"),("plain","low"),("plain","default")] {
            do { _ = try await accept("subagent_start",["task":"Bad","mode":"background","model":JSON(model),"effort":JSON(effort)],parent:parent,coordinator:coordinator); XCTFail("Unsupported model effort accepted") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_effort") }
        }
        let good = try await accept("subagent_start",["task":"Good","mode":"background","model":"other","effort":"low"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(good["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let plain = try await accept("subagent_start",["task":"Plain","mode":"background","model":"plain"],parent:parent,coordinator:coordinator)
        let plainID = try XCTUnwrap(plain["child_id"].text)
        try await eventually { await parent.agentState().latest(plainID)?.status.terminal == true }
        let profiles = await client.profiles
        XCTAssertEqual(profiles.map(\.model),["other","plain"])
        XCTAssertEqual(profiles.map { $0.raw["thinkingLevel"].text },["low","default"])
        XCTAssertEqual(profiles.last?.raw["reasoning"],false)
        await coordinator.drain(); await parent.close()
    }

    func testFollowUpEffortChangesOnlyNewTurnsAndOmissionInheritsCurrentParent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("first"),answer("second"),answer("third")]), coordinator = AgentSteeringCoordinator()
        let profile = try fixtureProfile().overriding(model:nil,thinkingLevel:"high")
        let parent = try effortFixture(root:root,profile:profile,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = try await accept("subagent_start",["task":"Task","mode":"background","effort":"low"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(start["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        do { _ = try await accept("subagent_send",["child_id":JSON(child),"message":"Invalid","effort":"ultra"],parent:parent,coordinator:coordinator); XCTFail("Invalid follow-up effort accepted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_effort") }
        let next = try await accept("subagent_send",["child_id":JSON(child),"message":"Next","effort":"max"],parent:parent,coordinator:coordinator)
        XCTAssertEqual(next["effort"],"max"); XCTAssertEqual(next["route"],"follow_up")
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let inherited = try await accept("subagent_send",["child_id":JSON(child),"message":"Third"],parent:parent,coordinator:coordinator)
        XCTAssertEqual(inherited["effort"],"high")
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let profiles = await client.profiles, state = await parent.agentState()
        XCTAssertEqual(profiles.map { $0.raw["thinkingLevel"].text },["low","max","high"])
        XCTAssertEqual(state.turns[AgentTurnTarget(childID:child,turn:1).id]?.effort,"low")
        XCTAssertEqual(state.turns[AgentTurnTarget(childID:child,turn:2).id]?.result?.envelope["effort"],"max")
        let read = try await coordinator.status(["action":"read_result","child_id":JSON(child),"turn":2],parent:parent)
        XCTAssertEqual(read["effort"],"max")
        await coordinator.drain(); await parent.close()
    }

    func testSteeringKeepsEffortAndRejectsUnknownWithoutChangingTurn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("before steer"),answer("after steer")],held:true), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = try await accept("subagent_start",["task":"Task","mode":"background","effort":"low"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(start["child_id"].text)
        try await eventually { await client.requests.count == 1 }
        do { _ = try await accept("subagent_send",["child_id":JSON(child),"message":"Invalid","effort":"ultra"],parent:parent,coordinator:coordinator,newTask:false); XCTFail("Invalid steering effort accepted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_effort") }
        let send = try await accept("subagent_send",["child_id":JSON(child),"message":"Refine","effort":"high"],parent:parent,coordinator:coordinator,newTask:false)
        XCTAssertEqual(send["route"],"steer"); XCTAssertEqual(send["effort"],"low")
        await client.release()
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let profiles = await client.profiles, state = await parent.agentState()
        XCTAssertEqual(profiles.map { $0.raw["thinkingLevel"].text },["low","low"])
        XCTAssertEqual(state.turns.count,1)
        await coordinator.drain(); await parent.close()
    }

    func testCompletedEffortSurvivesRelaunchAndLaterFollowUp() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("first"),answer("second")]), coordinator = AgentSteeringCoordinator()
        let profile = try fixtureProfile().overriding(model:nil,thinkingLevel:"high")
        let parent = try effortFixture(root:root,profile:profile,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = try await accept("subagent_start",["task":"Task","mode":"background","effort":"low"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(start["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let next = try await accept("subagent_send",["child_id":JSON(child),"message":"Next","effort":"max"],parent:parent,coordinator:coordinator)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        await coordinator.drain(); await parent.close()
        let reopenedClient = AccountedAgentScript([answer("third")]), reopenedCoordinator = AgentSteeringCoordinator()
        let reopened = try effortFixture(root:root,profile:profile,client:reopenedClient,resume:true)
        await reopened.enableSubagents(SubagentCoordinator()); await reopened.enableAgentSteering(reopenedCoordinator)
        let before = await reopened.agentState(), requestsBefore = await reopenedClient.requests
        XCTAssertEqual(before.latest(child)?.effort,"max"); XCTAssertTrue(requestsBefore.isEmpty)
        XCTAssertEqual(before.operations.values.first { $0.receipt["operation_id"] == next["operation_id"] }?.receipt,next)
        let listing = await reopenedCoordinator.list(parent:reopened,cursor:0,limit:10)
        let summary = try JSONDecoder().decode(SubagentSummary.self,from:try XCTUnwrap(listing["children"].list.first).data())
        XCTAssertEqual(summary.effort,"max")
        _ = try await accept("subagent_send",["child_id":JSON(child),"message":"After relaunch","effort":"medium"],parent:reopened,coordinator:reopenedCoordinator)
        try await eventually { await reopened.agentState().latest(child)?.status.terminal == true }
        let profiles = await reopenedClient.profiles, requests = await reopenedClient.requests
        XCTAssertEqual(profiles.first?.raw["thinkingLevel"],"medium")
        XCTAssertTrue(requests.first?.contains { $0.text == "first" } == true)
        XCTAssertTrue(requests.first?.contains { $0.text == "second" } == true)
        await reopenedCoordinator.drain(); await reopened.close()
    }

    func testOldJournalsWithoutEffortOrCapabilitiesStillInherit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("old answer")]), coordinator = AgentSteeringCoordinator()
        let profile = try fixtureProfile().overriding(model:nil,thinkingLevel:"high")
        let parent = try effortFixture(root:root,profile:profile,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let start = try await accept("subagent_start",["task":"Old task","mode":"background"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(start["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        await coordinator.drain(); await parent.close()
        func old(_ value: JSON) -> JSON {
            switch value {
            case .object(let fields): return .object(fields.filter { !["effort","reasoning"].contains($0.key) }.mapValues(old))
            case .array(let values): return .array(values.map(old))
            default: return value
            }
        }
        for id in ["parent",child] {
            let path = root.appendingPathComponent(id + ".jsonl")
            let rows = try String(contentsOf:path).split(separator:"\n").map { try old(JSON.parse(Data($0.utf8))).encoded() }
            try (rows.joined(separator:"\n") + "\n").write(to:path,atomically:true,encoding:.utf8)
        }
        let reopenedClient = AccountedAgentScript([answer("new answer")]), nextCoordinator = AgentSteeringCoordinator()
        let reopened = try effortFixture(root:root,profile:profile,client:reopenedClient,resume:true)
        await reopened.enableSubagents(SubagentCoordinator()); await reopened.enableAgentSteering(nextCoordinator)
        let oldState = await reopened.agentState()
        XCTAssertNil(oldState.latest(child)?.effort)
        let summary = await nextCoordinator.list(parent:reopened,cursor:0,limit:10)
        XCTAssertEqual(summary["children"].list.first?["effort"],"high")
        _ = try await accept("subagent_send",["child_id":JSON(child),"message":"Continue"],parent:reopened,coordinator:nextCoordinator)
        try await eventually { await reopened.agentState().latest(child)?.status.terminal == true }
        let profiles = await reopenedClient.profiles
        XCTAssertEqual(profiles.first?.raw["thinkingLevel"],"high")
        await nextCoordinator.drain(); await reopened.close()
    }

    func testQueuedRecoveryRetainsFrozenEffortWithoutDispatch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile(), origin = subagentFixtureOrigin()
        var plan = SubagentPlan(origin:origin,task:"Never replay",resultMessageID:"receipt")
        plan.origin.model.thinkingLevel = "low"
        let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call,effort:"low")
        let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:["version":3,"accepted":true,"child_id":"child","turn":1,"effort":"low"],plan:plan,turn:turn,epoch:"epoch")
        var journal: SessionJournal? = try SessionJournal(url:root.appendingPathComponent("parent.jsonl"),id:"parent",cwd:root,binding:profile.binding,create:true)
        try journal!.promoteToSteering(managedChild:false)
        try journal!.append(["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":subagentJSON(op)])
        journal = nil
        let client = AccountedAgentScript([])
        for _ in 0..<2 {
            let parent = try effortFixture(root:root,profile:profile,client:client,resume:true)
            let state = await parent.agentState()
            XCTAssertEqual(state.latest("child")?.effort,"low")
            XCTAssertEqual(state.latest("child")?.status,.notExecuted)
            XCTAssertEqual(state.latest("child")?.result?.envelope["effort"],"low")
            await parent.close()
        }
        let requests = await client.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testPreviewUsesPolicyAndDraftModelsEffortCapabilities() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try effortFixture(root:root)
        await parent.enableSubagents(SubagentCoordinator())
        let models: JSON = [["model":"other","reasoning":["high"]]]
        _ = try await parent.prepareContext(["model":"other","thinkingLevel":"high","subagentModels":models])
        let prepared = await parent.effortPreviewBody()
        let preview = try XCTUnwrap(prepared)
        XCTAssertTrue(RequestContextCounter.systemPrompt(preview)?.hasSuffix(Self.policy) == true)
        let schema = try XCTUnwrap(preview["tools"].list.first { $0["name"] == "subagent_start" })["parameters"]
        XCTAssertEqual(schema["properties"]["effort"]["enum"],["default","high"])
        await parent.close()
    }

    private func accept(_ name: String, _ args: JSON, parent: AgentSession, coordinator: AgentSteeringCoordinator, newTask: Bool = true) async throws -> JSON {
        let call = ToolCall(id:UUID().uuidString,name:name,arguments:args)
        let key = try await parent.agentFixtureCall(call,newTask:newTask)
        return try await coordinator.prepare(call,key:key,parent:parent)
    }
}

private extension AgentSession {
    func effortFixtureTurn(level: String? = nil, models: [SubagentModelGrant] = []) {
        activeSubmission = Submission(commandID:"fixture",turnID:"fixture",text:"",thinkingLevel:level)
        turnSubagentModels = models
    }
    func effortPreviewBody() -> JSON? { preparedContext?.body }
    func effortFixtureRetainedChildren(_ count: Int) {
        subagents.plans = Dictionary(uniqueKeysWithValues:(0..<count).map { index in
            let child = "retained-child-\(index)"
            var origin = subagentFixtureOrigin(child:child)
            origin.model.reasoning = [["low"], ["high"], []][index % 3]
            return (child, SubagentPlan(origin:origin,task:"Retained task",resultMessageID:"receipt-\(index)"))
        })
    }
}

extension SubagentPolicyEffortTests {
    func testSendSchemaAndPreviewStayFixedAcrossRetainedFamilyHistory() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw = try fixtureProfile().raw; raw["contextWindow"] = 16_384
        let parent = try effortFixture(root:root,profile:Profile(raw))
        await parent.enableSubagents(SubagentCoordinator())
        var baseline: String?, previewBaseline: String?
        for count in [0, 1, 3, 2_048] {
            await parent.effortFixtureRetainedChildren(count)
            let definitions = await parent.sessionDefinitions()
            let send = try XCTUnwrap(definitions.first { $0.name == "subagent_send" }).schema
            let encoded = send.encoded()
            if baseline == nil { baseline = encoded }
            XCTAssertEqual(encoded.utf8.count,baseline?.utf8.count,"Schema bytes must not grow with \(count) retained children")
            XCTAssertEqual(sha256(Data(encoded.utf8)),sha256(Data(baseline!.utf8)))
            XCTAssertLessThan(encoded.utf8.count,1_024)
            XCTAssertEqual(send["properties"]["effort"]["enum"].list.compactMap(\.text),Profile.thinkingLevels)
            XCTAssertNil(send["properties"]["child_id"].map["enum"])
            XCTAssertTrue(send.map["oneOf"] == nil)
            XCTAssertFalse(encoded.contains("retained-child-"))
            _ = try await parent.prepareContext([:])
            let body = await parent.effortPreviewBody(), tools = try XCTUnwrap(body)["tools"].encoded()
            if previewBaseline == nil { previewBaseline = tools }
            XCTAssertEqual(tools.utf8.count,previewBaseline?.utf8.count)
            XCTAssertEqual(sha256(Data(tools.utf8)),sha256(Data(previewBaseline!.utf8)),"The actual prepared request must also stay fixed")
        }
        await parent.close()
    }

    func testSendValidatesEachFrozenChildCapabilityBeforeAcceptanceOrRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("low"),answer("high"),answer("plain"),answer("follow-up")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,client:client)
        let models = [SubagentModelGrant(model:"low-model",reasoning:["low"]),SubagentModelGrant(model:"high-model",reasoning:["high"]),SubagentModelGrant(model:"plain-model",reasoning:[])]
        await parent.effortFixtureTurn(models:models)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        var children: [String] = []
        for model in models {
            let receipt = try await accept("subagent_start",["task":"Task","mode":"background","model":JSON(model.model)],parent:parent,coordinator:coordinator)
            let child = try XCTUnwrap(receipt["child_id"].text); children.append(child)
            try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        }
        for (index, effort) in [(0,"high"),(1,"low"),(2,"low"),(2,"default"),(0,"ultra")] {
            let call = ToolCall(id:UUID().uuidString,name:"subagent_send",arguments:["child_id":JSON(children[index]),"message":"Invalid effort","effort":JSON(effort)])
            _ = try await parent.agentFixtureCall(call,newTask:true)
            try await parent.runToolBatch([call])
            let result = await parent.history.last { $0.toolCallId == call.id }
            XCTAssertTrue(result?.isError == true)
            let envelope = try JSON.parse(Data((result?.text ?? "{}").utf8))
            XCTAssertEqual(envelope["accepted"],false)
            XCTAssertEqual(envelope["error"]["code"],"subagent_effort")
            XCTAssertEqual(envelope["error"]["message"],"Effort is not supported by the chosen child model")
        }
        let state = await parent.agentState(), requests = await client.requests
        XCTAssertEqual(state.operations.count,3); XCTAssertEqual(state.turns.count,3); XCTAssertEqual(requests.count,3)
        _ = try await accept("subagent_send",["child_id":JSON(children[1]),"message":"Valid follow-up","effort":"high"],parent:parent,coordinator:coordinator)
        try await eventually { await parent.agentState().latest(children[1])?.status.terminal == true }
        let profiles = await client.profiles
        XCTAssertEqual(profiles.last?.raw["thinkingLevel"],"high")
        await coordinator.drain(); await parent.close()
    }
}

extension SubagentPolicyEffortTests {
    func testModelDefaultKeepsUncataloguedEffortSchemaAndPreview() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile(), parent = try effortFixture(root:root,profile:profile)
        await parent.enableSubagents(SubagentCoordinator())
        for models in [[], [SubagentModelGrant(model:profile.model)], [SubagentModelGrant(model:"custom-alias")]] {
            await parent.effortFixtureTurn(level:"default",models:models)
            let effective = await parent.turnProfile
            XCTAssertEqual(effective.raw["reasoning"],false)
            let definitions = await parent.sessionDefinitions(subagentModels:models)
            let effort = try XCTUnwrap(definitions.first { $0.name == "subagent_start" }).schema["properties"]["effort"]
            XCTAssertEqual(effort["enum"].list.compactMap(\.text),Profile.thinkingLevels)
            XCTAssertEqual(effort["description"].text,"Reasoning effort for the chosen child model. Omit to inherit the parent's current effort; use \"default\" for the model's own default.")
            _ = try await parent.prepareContext(["thinkingLevel":"default","subagentModels":try subagentJSON(models)])
            let body = await parent.effortPreviewBody(), preview = try XCTUnwrap(body)
            let schema = try XCTUnwrap(preview["tools"].list.first { $0["name"] == "subagent_start" })["parameters"]
            XCTAssertEqual(schema["properties"]["effort"]["enum"].list.compactMap(\.text),Profile.thinkingLevels)
        }
        await parent.close()
    }

    func testModelDefaultAllowsExplicitEffortForManualAndCustomModels() async throws {
        for model in [String?.none, "custom-alias"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = AccountedAgentScript([answer("done")]), coordinator = AgentSteeringCoordinator()
            let parent = try effortFixture(root:root,client:client)
            await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
            await parent.effortFixtureTurn(level:"default",models:model.map { [SubagentModelGrant(model:$0)] } ?? [])
            var arguments: JSON = ["task":"Task","mode":"background","effort":"low"]
            if let model { arguments["model"] = JSON(model) }
            do {
                let receipt = try await accept("subagent_start",arguments,parent:parent,coordinator:coordinator)
                let child = try XCTUnwrap(receipt["child_id"].text)
                try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
                let profiles = await client.profiles
                XCTAssertEqual(profiles.first?.raw["thinkingLevel"],"low")
                XCTAssertEqual(profiles.first?.raw["reasoning"],true)
                XCTAssertEqual(profiles.first?.model,model ?? "fixture-model")
            } catch { XCTFail("Saved reasoning capability must permit explicit effort: \(error)") }
            await coordinator.drain(); await parent.close()
        }
    }

    func testModelDefaultFreezesCapabilitiesForFollowUpAfterRelaunch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("first")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        await parent.effortFixtureTurn(level:"default")
        let receipt = try await accept("subagent_start",["task":"Task","mode":"background"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let state = await parent.subagents, profiles = await client.profiles
        XCTAssertEqual(profiles.first?.raw["thinkingLevel"],"default")
        XCTAssertEqual(profiles.first?.raw["reasoning"],false)
        XCTAssertEqual(state.plans.values.first?.origin.model.reasoning,PiProviderRules.thinkingLevels)
        await coordinator.drain(); await parent.close()
        JournalCheckpoint.remove(for:root.appendingPathComponent("parent.jsonl"))
        let nextClient = AccountedAgentScript([answer("second")]), nextCoordinator = AgentSteeringCoordinator()
        let reopened = try effortFixture(root:root,client:nextClient,resume:true)
        await reopened.enableSubagents(SubagentCoordinator()); await reopened.enableAgentSteering(nextCoordinator)
        await reopened.effortFixtureTurn(level:"default")
        let definitions = await reopened.sessionDefinitions()
        XCTAssertEqual(definitions.first { $0.name == "subagent_send" }?.schema["properties"]["effort"]["enum"].list.compactMap(\.text),Profile.thinkingLevels)
        do {
            _ = try await accept("subagent_send",["child_id":JSON(child),"message":"Next","effort":"low"],parent:reopened,coordinator:nextCoordinator)
            try await eventually { await reopened.agentState().latest(child)?.status.terminal == true }
            let nextProfiles = await nextClient.profiles
            XCTAssertEqual(nextProfiles.first?.raw["thinkingLevel"],"low")
        } catch { XCTFail("Persisted capabilities must permit a follow-up effort: \(error)") }
        await nextCoordinator.drain(); await reopened.close()
    }

    func testEffectiveEffortDoesNotInventConnectionCapabilities() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw = try fixtureProfile().raw; raw["reasoning"] = false
        let client = AccountedAgentScript([]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,profile:Profile(raw),client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        await parent.effortFixtureTurn(level:"high")
        let definitions = await parent.sessionDefinitions()
        XCTAssertNil(definitions.first { $0.name == "subagent_start" }?.schema["properties"].map["effort"])
        do {
            _ = try await accept("subagent_start",["task":"Task","mode":"background","effort":"low"],parent:parent,coordinator:coordinator)
            XCTFail("An effective request flag cannot grant an unsupported effort")
        } catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_effort") }
        let state = await parent.agentState(), requests = await client.requests
        XCTAssertTrue(state.operations.isEmpty); XCTAssertTrue(requests.isEmpty)
        await coordinator.drain(); await parent.close()
    }

    func testOlderV3RecoveryWritesRetainEffortAcrossBothJournals() async throws {
        for status in [SubagentStatus.queued, .running] {
            for childTurnMirrored in [true, false] {
                for ownerTerminalWritten in [true, false] {
                    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                    let profile = try fixtureProfile()
                    var plan = SubagentPlan(origin:subagentFixtureOrigin(),task:"Never replay",resultMessageID:"receipt")
                    plan.origin.model.thinkingLevel = "low"; plan.origin.model.reasoning = ["low","high"]
                    let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:plan.origin.link.call,status:status,effort:"low")
                    let op = AgentOperation(key:turn.call,digest:"digest",receipt:["version":3,"accepted":true,"child_id":"child","turn":1,"effort":"low"],plan:plan,turn:turn,epoch:turn.epoch)
                    var terminal = turn
                    terminal.effort = nil // 0.1.127 decodes away this unknown optional field.
                    terminal.status = status == .running ? .interrupted : .notExecuted
                    terminal.result = SubagentToolResult(plan:plan,status:terminal.status,accountingRevision:0,began:status == .running)
                    terminal.normalizeResult()
                    let terminalRow: JSON = ["type":"custom","customType":JSON(JournalRecordKind.agentTerminal),"ownerID":"parent","data":try subagentJSON(terminal)]
                    for id in ["parent","child"] {
                        let journal = try SessionJournal(url:root.appendingPathComponent(id + ".jsonl"),id:id,cwd:root,binding:profile.binding,create:true,managedChild:id == "child")
                        try journal.promoteToSteering(managedChild:id == "child")
                        if id == "parent" {
                            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":try subagentJSON(op)])
                            if ownerTerminalWritten { try journal.append(terminalRow) }
                        } else {
                            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"ownerID":"parent","data":try subagentJSON(plan.origin)])
                            if childTurnMirrored { try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentTurn),"ownerID":"parent","data":try subagentJSON(turn)]) }
                            try journal.append(terminalRow)
                        }
                    }
                    let client = AccountedAgentScript([])
                    for _ in 0..<2 {
                        JournalCheckpoint.remove(for:root.appendingPathComponent("parent.jsonl"))
                        do {
                            let parent = try effortFixture(root:root,client:client,resume:true)
                            let state = await parent.agentState()
                            XCTAssertEqual(state.latest("child")?.status,terminal.status)
                            XCTAssertEqual(state.latest("child")?.effort,"low")
                            XCTAssertEqual(state.latest("child")?.result,terminal.result,"Keep the older helper's sealed result unchanged")
                            let listing = await AgentSteeringCoordinator().list(parent:parent,cursor:0,limit:10)
                            XCTAssertEqual(listing["children"].list.first?["effort"],"low")
                            await parent.close()
                        } catch { XCTFail("Mixed v3 recovery failed (\(status), mirrored=\(childTurnMirrored), ownerTerminal=\(ownerTerminalWritten)): \(error)") }
                    }
                    let requests = await client.requests; XCTAssertTrue(requests.isEmpty)
                }
            }
        }
    }

    func testOlderV3ReplayStillRejectsExplicitEffortAndIdentityChanges() throws {
        let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:"Task",call:subagentFixtureOrigin().link.call,effort:"low")
        func row(_ value: AgentChildTurn) throws -> JSON { ["customType":JSON(JournalRecordKind.agentTurnState),"data":try subagentJSON(value)] }
        var state = AgentFamilyState(ownerID:"parent")
        try state.consume(row(turn))
        for changedField in ["effort","inputID","executionID"] {
            var changed = try row(turn)
            changed["data"][changedField] = "different"
            XCTAssertThrowsError(try state.consume(changed)) { XCTAssertEqual(($0 as? AgentError)?.code,"subagent_recovery") }
        }
        var running = turn; running.effort = nil; running.status = .running
        try state.consume(row(running))
        XCTAssertEqual(state.latest("child")?.effort,"low")
        var terminal = running; terminal.status = .interrupted
        try state.consume(row(terminal)); try state.consume(row(terminal))
        XCTAssertEqual(state.latest("child")?.effort,"low")
        terminal.status = .completed
        XCTAssertThrowsError(try state.consume(row(terminal))) { XCTAssertEqual(($0 as? AgentError)?.code,"subagent_recovery") }
    }

    func testOlderV3OriginMirrorAllowsFollowUpButRejectsConflictingCapabilitiesOrIdentity() async throws {
        for mirror in ["missing-capabilities","conflicting-capabilities","changed-tools"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let profile = try fixtureProfile()
            var plan = SubagentPlan(origin:subagentFixtureOrigin(),task:"Never replay",resultMessageID:"receipt")
            plan.origin.model.thinkingLevel = "low"; plan.origin.model.reasoning = ["low","high"]
            let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:plan.origin.link.call,effort:"low")
            let op = AgentOperation(key:turn.call,digest:"digest",receipt:["version":3,"accepted":true,"child_id":"child","turn":1,"effort":"low"],plan:plan,turn:turn,epoch:turn.epoch)
            var oldOrigin = plan.origin; oldOrigin.model.reasoning = mirror == "conflicting-capabilities" ? [] : nil
            if mirror == "changed-tools" { oldOrigin.tools.append("not-granted") }
            var terminal = turn; terminal.effort = nil; terminal.status = .notExecuted
            terminal.result = SubagentToolResult(plan:plan,status:terminal.status,accountingRevision:0)
            terminal.normalizeResult()
            for id in ["parent","child"] {
                let journal = try SessionJournal(url:root.appendingPathComponent(id + ".jsonl"),id:id,cwd:root,binding:profile.binding,create:true,managedChild:id == "child")
                try journal.promoteToSteering(managedChild:id == "child")
                if id == "parent" {
                    try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":try subagentJSON(op)])
                } else {
                    // 0.1.127 completes publication for a marker-only child,
                    // decoding away the capability list and turn effort.
                    try journal.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":try subagentJSON(oldOrigin)])
                    try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentTerminal),"ownerID":"parent","data":try subagentJSON(terminal)])
                }
            }
            let client = AccountedAgentScript([answer("follow-up")]), coordinator = AgentSteeringCoordinator()
            if mirror != "missing-capabilities" {
                XCTAssertThrowsError(try effortFixture(root:root,client:client,resume:true)) { XCTAssertEqual(($0 as? AgentError)?.code,"subagent_recovery") }
                continue
            }
            let parent = try effortFixture(root:root,client:client,resume:true)
            await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
            let before = await client.requests; XCTAssertTrue(before.isEmpty)
            _ = try await accept("subagent_send",["child_id":"child","message":"Continue","effort":"high"],parent:parent,coordinator:coordinator)
            try await eventually { await parent.agentState().latest("child")?.status.terminal == true }
            let state = await parent.agentState(), profiles = await client.profiles
            XCTAssertEqual(state.latest("child")?.status,.completed)
            XCTAssertEqual(state.latest("child")?.effort,"high")
            XCTAssertEqual(profiles.first?.raw["thinkingLevel"],"high")
            await coordinator.drain(); await parent.close()
        }
    }

    func testOlderHelperCheckpointCannotDiscardAcceptedEffortOrCapabilities() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("first")]), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,client:client)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let receipt = try await accept("subagent_start",["task":"Task","mode":"background","effort":"low"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        await coordinator.drain(); await parent.refreshCheckpoint(); await parent.close()
        let path = root.appendingPathComponent("parent.jsonl")
        var checkpoint = try XCTUnwrap(JournalCheckpoint.read(for:path))
        XCTAssertNotNil(AgentSession.loadCheckpoint(checkpoint,url:path),"Current checkpoints remain usable")
        var helper = try JSON.parse(Data(checkpoint.helper.utf8))
        var state = try JSONDecoder().decode(SubagentJournalState.self,from:helper["subagents"].data())
        // Model the released helper's typed decode/re-encode. JSON result
        // envelopes stay intact, but unknown typed optional fields disappear.
        for id in state.plans.keys { state.plans[id]?.origin.model.reasoning = nil }
        for id in state.family!.operations.keys {
            state.family?.operations[id]?.plan?.origin.model.reasoning = nil
            state.family?.operations[id]?.turn?.effort = nil
        }
        for id in state.family!.turns.keys { state.family?.turns[id]?.effort = nil }
        helper["subagents"] = try subagentJSON(state)
        helper = helper.removing(["subagentEffortVersion"])
        checkpoint.helper = helper.encoded(); try checkpoint.write(for:path)
        XCTAssertNil(AgentSession.loadCheckpoint(checkpoint,url:path),"Replay the authoritative journal when an older cache omits effort")
        let nextClient = AccountedAgentScript([])
        let reopened = try effortFixture(root:root,client:nextClient,resume:true)
        let recovered = await reopened.subagents, requests = await nextClient.requests
        XCTAssertEqual(recovered.family?.latest(child)?.effort,"low")
        XCTAssertEqual(recovered.plans.values.first?.origin.model.reasoning,PiProviderRules.thinkingLevels)
        XCTAssertTrue(requests.isEmpty)
        await reopened.close()
    }
}

extension SubagentPolicyEffortTests {
    func testLoopbackRequestCaptureContainsActuallySentEffort() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gateway = try await PythonGateway.start(source:Self.effortGateway,root:root); defer { gateway.stop() }
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON(gateway.base + "/v1"); raw["thinkingLevel"] = "high"
        raw["thinkingLevelMap"] = ["low":"wire-low"]
        let traces = TraceStore(), coordinator = AgentSteeringCoordinator()
        let parent = try effortFixture(root:root,profile:Profile(raw),client:ProviderClient(traces:traces),traces:traces)
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        let receipt = try await accept("subagent_start",["task":"Task","mode":"background","effort":"low"],parent:parent,coordinator:coordinator)
        let child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        let state = await parent.agentState()
        XCTAssertEqual(state.latest(child)?.status,.completed)
        let sent = try JSON.parse(Data(contentsOf:root.appendingPathComponent("request.json")))
        XCTAssertEqual(sent["reasoning"]["effort"],"wire-low")
        let listed = try await traces.command("debug.list",session:child,params:[:])
        let attempt = try XCTUnwrap(listed["attempts"].list.first?["attemptId"].text)
        let page = try await traces.command("debug.body",session:child,params:["attemptId":JSON(attempt),"body":"request"])
        let bytes = try XCTUnwrap(Data(base64Encoded:page["bytes"].text ?? ""))
        let captured = try JSON.parse(bytes)
        XCTAssertEqual(captured["reasoning"],sent["reasoning"])
        XCTAssertEqual(listed["attempts"].list.first?["requestScope"]["sourceSessionID"],JSON(child))
        XCTAssertFalse(RequestContextCounter.systemPrompt(captured)?.contains(Self.policy) == true)
        await coordinator.drain(); await parent.close()
    }

    private static let effortGateway = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self, *args): pass
 def do_POST(self):
  (root/'request.json').write_bytes(self.rfile.read(int(self.headers['content-length'])))
  body = {'id':'r','model':'fixture-model','status':'completed','output':[{'id':'m','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Done'}]}],'usage':{'input_tokens':10,'output_tokens':2,'total_tokens':12}}
  raw = json.dumps(body).encode(); self.send_response(200)
  self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.send_header('x-litellm-response-cost','0.01'); self.end_headers(); self.wfile.write(raw)
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'ready.tmp').write_text(json.dumps({'port':server.server_port})); (root/'ready.tmp').replace(root/'ready.json'); server.serve_forever()
"""#
}
