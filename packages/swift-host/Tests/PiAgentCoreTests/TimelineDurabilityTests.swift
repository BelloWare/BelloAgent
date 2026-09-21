import XCTest
@testable import PiAgentCore

private actor TimelineFixtureClient: ModelClient {
    private(set) var calls = 0
    let holdsFirst: Bool
    var released = false
    init(holdsFirst: Bool = false) { self.holdsFirst = holdsFirst }
    func release() { released = true }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,turnID:turnID,purpose:purpose,onObservation:{ _ in },onDelta:onDelta)
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        calls += 1
        let number = calls
        let attempt = "attempt-\(turnID)-\(number)"
        await onObservation(RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile))
        var adapter = ProviderDisplayEvents(api:"openai-responses",attempt:attempt)
        let frames: [JSON] = [
            ["type":"response.output_text.delta","output_index":0,"item_id":"m","content_index":0,"delta":"First "],
            ["type":"response.reasoning_summary_text.delta","output_index":1,"item_id":"r","summary_index":0,"delta":"Returned explanation"],
            ["type":"response.output_text.delta","output_index":0,"item_id":"m","content_index":0,"delta":"continued"]]
        for frame in frames {
            for part in adapter.consume(frame,at:nowMS()) { try await onDelta(.part(part)) }
            if frame["type"].text == "response.output_text.delta" { try await onDelta(.text(frame["delta"].text!)) }
            else { try await onDelta(.thinking(frame["delta"].text!)) }
        }
        while holdsFirst && number == 1 && !released { try await Task.sleep(nanoseconds:1_000_000) }
        var reply = answer("First continued")
        adapter.timeline.finish("completed"); reply.message.responseTimeline = adapter.timeline
        return reply
    }
}

final class TimelineDurabilityTests: XCTestCase {
    private func make(_ root: URL, id: String = "timeline", client: any ModelClient, path: String? = nil, seed: [ChatMessage] = [], ephemeral: Bool = false) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path,seed:ephemeral ? seed : nil,autoCompaction:false)
    }
    func testObservedInterleavingSurvivesRestartForkEditAndSavedSide() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = TimelineFixtureClient(), session = try make(root,client:client)
        _ = try await session.submit(Submission(commandID:"one",turnID:"one",text:"First task"),steer:false)
        try await eventually { !(await session.isRunning) }
        _ = try await session.submit(Submission(commandID:"two",turnID:"two",text:"Second task"),steer:false)
        try await eventually { !(await session.isRunning) }
        let original = await session.history
        let replies = original.filter { $0.role == "assistant" }
        XCTAssertEqual(replies.count,2)
        for reply in replies {
            XCTAssertEqual(reply.responseTimeline?.segments.map(\.text),["First ","Returned explanation","continued"])
            XCTAssertTrue(reply.responseTimeline?.segments.allSatisfy { $0.part.sessionOrdinal != nil } == true)
        }
        let savedPath = await session.path
        let fork = try await session.fork(to:"fork")
        let sideSeed = await session.sideSeed()
        let side = try make(root,id:"side",client:ScriptClient([]),seed:sideSeed.messages,ephemeral:true)
        let savedSide = try await side.keep(whenFinished:false); await side.close()
        let kept = try make(root,id:"side",client:ScriptClient([]),path:savedSide["path"].text)
        let keptReplies = await kept.history.filter { $0.role == "assistant" }
        XCTAssertEqual(keptReplies.map(\.responseTimeline),replies.map(\.responseTimeline)); await kept.close()
        await session.close()
        let reopened = try make(root,client:ScriptClient([]),path:try XCTUnwrap(savedPath))
        let restored = await reopened.history
        XCTAssertEqual(restored.map(\.id),original.map(\.id))
        XCTAssertEqual(restored.map(\.responseTimeline),original.map(\.responseTimeline)); await reopened.close()
        let child = try make(root,id:"fork",client:TimelineFixtureClient(),path:fork["path"].text)
        let childBefore = await child.visible.filter { $0.role == "assistant" }
        XCTAssertEqual(childBefore.map(\.responseTimeline),replies.map(\.responseTimeline))
        _ = try await child.edit(fromMessageID:"two",input:Submission(commandID:"edit",turnID:"replacement",text:"Replacement task"))
        try await eventually { !(await child.isRunning) }
        let visible = await child.visible
        XCTAssertFalse(visible.contains { $0.id == replies[1].id })
        XCTAssertFalse(visible.contains { $0.presentationSourceID == replies[1].id })
        let grandchild = try await child.fork(to:"grandchild")
        let inherited = try make(root,id:"grandchild",client:ScriptClient([]),path:grandchild["path"].text)
        let inheritedVisible = await inherited.visible
        XCTAssertEqual(inheritedVisible.map(\.id),visible.map(\.id))
        XCTAssertEqual(inheritedVisible.map(\.responseTimeline),visible.map(\.responseTimeline))
        await inherited.close(); await child.close()
    }
    func testCrashBetweenSemanticRecordsKeepsPrefixAndNoTerminalReceiptWithoutDispatch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = TimelineFixtureClient(holdsFirst:true), session = try make(root,client:client)
        _ = try await session.submit(Submission(commandID:"one",turnID:"one",text:"Task"),steer:false)
        try await eventually { await session.partialTimeline.segments.count == 3 }
        let savedPath = await session.path
        let crash = root.appendingPathComponent("state/crash.jsonl")
        try FileManager.default.copyItem(atPath:try XCTUnwrap(savedPath),toPath:crash.path)
        let noDispatch = ScriptClient([]), resumed = try make(root,client:noDispatch,path:crash.path)
        let ledger = await resumed.visible.first { $0.kind == "requestLedger" }
        XCTAssertEqual(ledger?.responseTimeline?.segments.map(\.text),["First ","Returned explanation","continued"])
        XCTAssertEqual(ledger?.responseTimeline?.terminal,"interrupted")
        XCTAssertEqual(ledger?.responseTimeline?.coverage,"partial")
        let calls = await noDispatch.count; XCTAssertEqual(calls,0)
        let context = await resumed.context
        XCTAssertFalse(context.contains { $0.kind == "requestLedger" })
        await resumed.close(); await client.release(); await session.close()
    }
}
