import XCTest
@testable import PiAgentCore

final class SubagentCacheTests: XCTestCase {
    func testChildFollowUpsKeepInputPrefixAcrossEffortChangesAndColdOpen() async throws {
        for initial in ["low", "default"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            try FileManager.default.createDirectory(at:root.appendingPathComponent(".git"),withIntermediateDirectories:true)
            let client = CacheRecordingClient(), profile = try fixtureProfile()
            func parent(resume: Bool) throws -> AgentSession {
                try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                    resources:Resources(cwd:root,options:["codexHome":JSON(root.appendingPathComponent("codex").path),"skills":false],home:root),client:client,tools:RecordingTools(),traces:TraceStore(),
                    resumePath:resume ? root.appendingPathComponent("parent.jsonl").path : nil)
            }
            var owner = try parent(resume:false), coordinator = AgentSteeringCoordinator()
            await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            var child = ""
            for (index, effort) in [initial, "high", "default", "low"].enumerated() {
                if index == 3 {
                    await coordinator.drain(); await owner.close()
                    owner = try parent(resume:true); coordinator = AgentSteeringCoordinator()
                    await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
                }
                let call = ToolCall(id:"call-\(index)",name:index == 0 ? "subagent_start" : "subagent_send",
                    arguments:index == 0 ? ["task":"Keep the original task", "mode":"background", "effort":JSON(effort)]
                        : ["child_id":JSON(child), "message":JSON("Follow up \(index)"), "effort":JSON(effort)])
                let key = try await owner.agentFixtureCall(call,newTask:true)
                let receipt = try await coordinator.prepare(call,key:key,parent:owner)
                child = try XCTUnwrap(receipt["child_id"].text)
                let target = child, session = owner
                try await eventually { await session.agentState().latest(target)?.status.terminal == true }
            }
            await coordinator.drain(); await owner.close()
            let bodies = await client.bodies
            XCTAssertEqual(bodies.count,4)
            for (previous, next) in zip(bodies,bodies.dropFirst()) {
                XCTAssertTrue(next["input"].list.prefix(previous["input"].list.count) == previous["input"].list[...],
                    "An effort-only follow-up must append to the child's prior provider input")
                XCTAssertEqual(next["tools"],previous["tools"])
                XCTAssertEqual(next["prompt_cache_key"],previous["prompt_cache_key"])
                XCTAssertEqual(next["metadata"],previous["metadata"])
            }
            XCTAssertEqual(bodies.first?["input"].list.first?["role"],initial == "default" ? "system" : "developer")
            XCTAssertEqual(bodies[1]["reasoning"]["effort"],"high")
            XCTAssertTrue(bodies[2]["reasoning"].isNull, "Model default still omits reasoning options")
            XCTAssertTrue(bodies[2]["include"].isNull)
        }
    }

    func testModelGrantOrderDoesNotChangeParentSchemas() throws {
        let profile = try fixtureProfile()
        for mixed in [false, true] {
            let grants = [SubagentModelGrant(model:"z-model",reasoning:["high","low"]),
                          SubagentModelGrant(model:"a-model",reasoning:mixed ? [] : ["low","high"]),
                          SubagentModelGrant(model:profile.model,reasoning:["low","high"])]
            let forward = SubagentSteeringContract.definitions(child:false,models:grants,profile:profile,connectionSupportsReasoning:true)
            let reversed = SubagentSteeringContract.definitions(child:false,models:grants.reversed(),profile:profile,connectionSupportsReasoning:true)
            XCTAssertTrue(forward.map(\.schema) == reversed.map(\.schema), "Catalog ordering is not a capability change")
            XCTAssertTrue(SubagentSpec.definition(models:grants).schema == SubagentSpec.definition(models:grants.reversed()).schema)
        }
    }

    func testOrdinaryPromptRoleAndDefaultOptionsKeepPiParity() throws {
        let high = try fixtureProfile().overriding(model:nil,thinkingLevel:"high")
        let normal = try high.overriding(model:nil,thinkingLevel:"default")
        for (profile, role) in [(high,"developer"),(normal,"system")] {
            let body = try ProviderClient.requestBody(profile:profile,messages:[],instructions:"Unchanged",tools:[],sessionID:"ordinary")
            XCTAssertEqual(body["input"],[["content":"Unchanged","role":JSON(role)]])
        }
    }

    func testChildSummaryRequestRetainsInstructionRoleAfterEffortChange() throws {
        for developer in [true, false] {
            var raw = try fixtureProfile().raw
            raw["compat"] = ["supportsDeveloperRole":JSON(developer)]
            let initial = try Profile(raw).overriding(model:nil,thinkingLevel:"high").fixingInstructionRole()
            let followUp = try initial.overriding(model:nil,thinkingLevel:"default")
            let messages = [ChatMessage(role:"user",content:[textBlock("Saved task")])]
            let normal = try ProviderClient.requestBody(profile:followUp,messages:messages,instructions:"Frozen policy",tools:[],sessionID:"child")
            let summaryProfile = try CompactionPolicy().summaryProfile(followUp,cap:1024)
            let summary = try ProviderClient.requestBody(profile:summaryProfile,messages:messages + [ChatMessage(role:"user",content:[textBlock("Summarize")])],instructions:"Frozen policy",tools:[],sessionID:"child",compaction:true)
            XCTAssertTrue(summary["input"].list.dropLast() == normal["input"].list[...])
            XCTAssertEqual(summary["input"].list.first?["role"],developer ? "developer" : "system")
            XCTAssertTrue(summary["reasoning"].isNull)
        }
    }
}

private actor CacheRecordingClient: ModelClient {
    var bodies: [JSON] = []
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Missing accounting")
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString
        let permit = try await lifecycle?.admitAttempt(attempt); defer { permit?.finish() }
        try await lifecycle?.willDispatch(attempt)
        // Exercise the production builder, including the output-cap copy.
        bodies.append(try ProviderClient.requestBody(profile:profile.capped(1024),messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,cacheSessionID:cacheSessionID))
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0]]]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation)
        return answer("Saved answer \(bodies.count)")
    }
}
