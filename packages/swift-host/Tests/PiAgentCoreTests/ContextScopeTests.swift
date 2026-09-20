import XCTest
@testable import PiAgentCore

private actor PreparingClient: ModelClient {
    var started=false, released=false
    func release() { released=true }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { answer("unused") }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onObservation:@escaping @Sendable (RequestObservation) async -> Void,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        started=true
        // Deliberately no attempt/body observation until capture preparation ends.
        while !released { try await Task.sleep(for:.milliseconds(5)) }
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID)
        var observation=RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:"recorded",purpose:purpose,fingerprint:try RequestContextCounter.fingerprint(body,profile:profile),profile:profile)
        await onObservation(observation)
        _=observation.consume(["status":"completed","usage":["input_tokens":38,"output_tokens":302,"output_tokens_details":["reasoning_tokens":253]]],streaming:false,at:1)
        await onObservation(observation)
        return answer("done")
    }
}
private actor ContextDefinitionGate: ToolExecuting {
    var blocked=true, entered=false
    func release() { blocked=false }
    func definitions(readOnly:Bool) async -> [ToolDefinition] {
        entered=true
        while blocked { try? await Task.sleep(for:.milliseconds(5)) }
        return []
    }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON { resultText("unused") }
}

final class ContextScopeTests: XCTestCase {
    func testPreparingIsPublishedBeforeSlowRecorderWithoutWaitingForMetrics() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PreparingClient()
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:DisabledTools(),traces:TraceStore(),autoCompaction:false)
        addTeardownBlock { await session.close() }
        _=try await session.submit(Submission(commandID:"send",turnID:"turn",text:"hello"),steer:false)
        try await eventually { await client.started }
        let preparing=await session.snapshot(["includeMetrics":false],traceSnapshot:{ XCTFail("Preparing context may not wait for capture metrics"); return (.null,"off") })
        XCTAssertEqual(preparing["contextState"]["phase"].text,"preparing")
        let planned=preparing["contextState"]["currentRequest"]
        XCTAssertEqual(planned["phase"].text,"preparing"); XCTAssertTrue(planned["attemptID"].isNull)
        XCTAssertNotNil(planned["estimate"]["tokens"].int)
        let unchanged=await session.snapshot(["includeMetrics":false,"contextStateRevision":preparing["contextStateRevision"],"contextObservationRevision":preparing["contextObservationRevision"]])
        XCTAssertTrue(unchanged["contextState"].isNull); XCTAssertTrue(unchanged["requestObservation"].isNull)
        let preview=try await session.prepareContext(["text":"unsent"])
        _=try await session.readPreparedContext(["revision":preview["revision"],"section":"request"])
        await session.clearPreparedContext(preview["revision"].text)
        let after=await session.snapshot(["includeMetrics":false])
        XCTAssertEqual(after["contextState"],preparing["contextState"],"Inspect/open/read/close must not mutate preflight or generation")
        await client.release(); try await eventually { !(await session.isRunning) }
        let final=await session.snapshot(["includeMetrics":false])
        XCTAssertEqual(final["contextState"]["phase"].text,"next-input")
        XCTAssertTrue(final["contextState"]["currentRequest"].isNull)
        XCTAssertEqual(final["contextState"]["lastRequest"]["usage"]["input"].int,38)
        XCTAssertEqual(final["contextState"]["lastRequest"]["generation"],planned["generation"])
        XCTAssertGreaterThan(final["contextState"]["replayRevision"].int!,preparing["contextState"]["replayRevision"].int!)
    }
    func testPreviewSurvivesOutputOnlyEventsButRejectsCommittedInputDuringAwait() async throws {
        for changesInput in [false,true] {
            let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let tools=ContextDefinitionGate()
            let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:tools,traces:TraceStore(),autoCompaction:false)
            let pending=Task { try await session.prepareContext(["text":"unsent"]) }
            try await eventually { await tools.entered }
            if changesInput { try await session.appendContextFixtureInput() }
            else { await session.emitContextFixtureEvents() }
            await tools.release()
            do {
                let result=try await pending.value
                XCTAssertFalse(changesInput,"A tool result/steering append supersedes the preview")
                let snapshot=await session.snapshot(["includeMetrics":false])
                XCTAssertEqual(result["replayRevision"],snapshot["contextState"]["replayRevision"])
                XCTAssertLessThan(result["seq"].int!,snapshot["seq"].int!,"Event traffic does not invalidate replay identity")
                XCTAssertTrue(snapshot["contextState"]["count"]["tokens"].isNull,"Preview is observational")
            } catch let error as AgentError {
                XCTAssertTrue(changesInput); XCTAssertEqual(error.code,"context_changed")
            }
            await session.close()
        }
    }
    func testContextEnvelopeIsCapturedBeforeTraceAwaitAndResetIndependentOfMetrics() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),autoCompaction:false)
        addTeardownBlock { await session.close() }
        let captured=await session.snapshot([:],traceSnapshot:{
            try? await session.appendContextFixtureInput()
            return (.null,"off")
        })
        let newer=await session.snapshot(["includeMetrics":false])
        XCTAssertEqual(captured["contextState"]["replayRevision"].int,0)
        XCTAssertEqual(newer["contextState"]["replayRevision"].int,1)
        XCTAssertLessThan(captured["seq"].int!,newer["seq"].int!)
        let generation=await session.beginObservationGeneration()
        await session.clearRequestObservation()
        let reset=await session.snapshot(["includeMetrics":false])
        XCTAssertTrue(reset["contextState"]["currentRequest"].isNull)
        XCTAssertGreaterThan(reset["contextState"]["generation"].int!,Int(generation))
    }
}
private extension AgentSession {
    func appendContextFixtureInput() throws { try append(ChatMessage(role:"user",content:[textBlock("delivered steering")])); event("message_end") }
    func emitContextFixtureEvents() {
        for _ in 0..<50 { event("text_delta"); event("thinking_delta"); event("request.usage"); event("queue.changed") }
    }
}
