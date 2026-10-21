import XCTest
@testable import PiAgentCore

final class AgentSteeringRetryTests: HelperTestCase {
    func testRetryRefreshConsumesAgentEventsAndRecordsTheRefreshedDeliveryIDs() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentRetryRefreshClient(), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        await parent.useRetrySettings(.init(enabled:true,maxRetries:1,baseDelayMs:150))
        _ = try await parent.submit(Submission(commandID:"user",turnID:"user",text:"Coordinate"),steer:false)
        try await eventually { !(await parent.isRunning) }
        let requests = await client.parents, scopes = await client.parentScopes
        XCTAssertGreaterThanOrEqual(requests.count,3)
        XCTAssertFalse(requests[1].contains { $0.text.contains("retry-window question") })
        XCTAssertTrue(requests[2].contains { $0.text.contains("retry-window question") },"The retry must refresh at the existing steering boundary")
        XCTAssertFalse(scopes[2]["agentDeliveryIDs"].list.isEmpty)
        XCTAssertNotEqual(scopes[1]["agentDeliveryIDs"],scopes[2]["agentDeliveryIDs"])
        await coordinator.drain(); await parent.close()
    }
}
actor AgentRetryRefreshClient: ModelClient {
    var parents: [[ChatMessage]] = [], parentScopes: [JSON] = [], children = 0
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture_unscoped","Missing accounting") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString
        let permit = try await lifecycle?.admitAttempt(attempt); defer { permit?.finish() }
        try await lifecycle?.willDispatch(attempt)
        let reply: ModelReply, failed: Bool
        if sessionID == "parent" {
            parents.append(messages); parentScopes.append(try lifecycle.map { try subagentJSON($0.scope) } ?? .null)
            failed = parents.count == 2
            reply = parents.count == 1 ? agentCallReply("start","subagent_start",["task":"Report a question","mode":"background"]) : answer("Parent final")
        } else {
            children += 1; failed = false
            while parents.count < 2 { try await Task.sleep(for:.milliseconds(2)) }
            reply = children == 1 ? agentCallReply("question","subagent_report",["kind":"question","message":"retry-window question"]) : answer("Child final")
        }
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:sha256(Data(messages.map(\.text).joined().utf8)),profile:profile)
        observation.monitoring = ["outcome":JSON(failed ? "failed" : "completed"),"gateway":["cost":["status":"reported","usd":0.01]]]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation)
        if failed { throw AgentError("provider_transport","Synthetic backoff") }
        return reply
    }
}
