import XCTest
@testable import PiAgentCore

private actor ProjectionClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var completed = false
    private var failure: AgentError?
    var ready: Bool { callback != nil }
    func emit(_ text: String) async throws { try await callback?(.text(text)) }
    func finish() { completed = true }
    func fail() { failure=AgentError("fixture_failure","Fixture failure") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while !completed && failure == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        if let failure { throw failure }
        return answer("Finished")
    }
}

private actor ProjectionLinkGate {
    private var pending: CheckedContinuation<Bool,Never>?
    private var released=false
    var waiting: Bool { pending != nil }
    func accept(_ packet: JSON) async -> Bool {
        guard packet["type"].text=="links", !packet["outputMessageIds"].list.isEmpty, !released else { return true }
        return await withCheckedContinuation { pending=$0 }
    }
    func release(accepted: Bool = true) { released=true; pending?.resume(returning:accepted); pending=nil }
}

final class SnapshotProjectionTests: XCTestCase {
    private func history(count: Int = 80, bytes: Int = 4096) -> [ChatMessage] {
        (0..<count).map { index in
            var message=ChatMessage(role:index.isMultiple(of: 2) ? "user" : "assistant",content:[textBlock("Row \(index): " + String(repeating: "x",count:bytes))])
            message.id="message-\(index)"
            return message
        }
    }
    private func session(root: URL, id: String, seed: [ChatMessage], client: any ModelClient = ScriptClient([])) throws -> AgentSession {
        var profile=try fixtureProfile().raw; profile["contextWindow"]=1_000_000
        return try AgentSession(id:id,profile:Profile(profile),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed,autoCompaction:false)
    }

    func testFiveBackgroundSessionsNeverBuildHiddenTranscriptPages() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let seed=history(bytes:16_384)
        let sessions=try (0..<5).map { try session(root:root,id:"background-\($0)",seed:seed) }
        addTeardownBlock { for session in sessions { await session.close() } }
        let start=ProcessInfo.processInfo.systemUptime
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask {
                    for _ in 0..<20 {
                        let status=await session.snapshot(["includeMessages":false])
                        XCTAssertTrue(status["messages"].isNull)
                        XCTAssertNotNil(status["displayRevision"].text)
                        XCTAssertEqual(status["total"].int,80)
                        XCTAssertEqual(status["assistantMessageCount"].int,40)
                    }
                }
            }
        }
        for session in sessions {
            let builds=await session.displayProjectionBuildCount, rows=await session.displayRowProjectionCount
            XCTAssertEqual(builds,0,"Background activity must not serialize or hash an unseen transcript")
            XCTAssertEqual(rows,0)
        }
        print("PERF five-background-status-100 ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
    }

    func testRepeatedVisibleReadsAndQueueStateReuseCurrentProjection() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let session=try session(root:root,id:"cached",seed:history())
        addTeardownBlock { await session.close() }
        let first=await session.snapshot()
        for _ in 0..<5 {
            let next=await session.snapshot()
            XCTAssertEqual(next["messages"],first["messages"])
            XCTAssertEqual(next["displayRevision"],first["displayRevision"])
        }
        try await session.configureQueue(["followUpMode":"all"])
        let queue=await session.snapshot(["displayRevision":first["displayRevision"]])
        XCTAssertTrue(queue["messages"].isNull)
        XCTAssertEqual(queue["displayRevision"],first["displayRevision"])
        let builds=await session.displayProjectionBuildCount, rows=await session.displayRowProjectionCount
        XCTAssertEqual(builds,1); XCTAssertEqual(rows,6, "Only the latest three two-message turns need projection")
    }

    func testStreamingProjectsOnlyChangedTailAndStatusDoesNotConsumeIt() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ProjectionClient(), session=try session(root:root,id:"streaming",seed:history(count:60,bytes:1024),client:client)
        addTeardownBlock { await session.close() }
        _=try await session.submit(Submission(commandID:"start",turnID:"start",text:"Question"),steer:false)
        try await eventually { await client.ready }
        let first=await session.snapshot(), initialRows=await session.displayRowProjectionCount
        var previous=first, text=""
        for index in 0..<10 {
            let part="chunk-\(index) "; text += part
            try await client.emit(part)
            let beforeStatus=await session.displayProjectionBuildCount
            let status=await session.snapshot(["includeMessages":false])
            let afterStatus=await session.displayProjectionBuildCount
            XCTAssertEqual(afterStatus,beforeStatus)
            XCTAssertTrue(status["messages"].isNull)
            let next=await session.snapshot(["displayRevision":previous["displayRevision"]])
            XCTAssertEqual(next["messages"].list.last?["text"].text,text)
            XCTAssertNotEqual(next["displayRevision"],previous["displayRevision"])
            previous=next
        }
        let finalRows=await session.displayRowProjectionCount
        XCTAssertEqual(finalRows,initialRows,"Streamed text must reuse every retained completed row")
        await client.finish(); try await eventually { !(await session.isRunning) }
        let completed=await session.snapshot(["displayRevision":previous["displayRevision"]])
        XCTAssertEqual(completed["messages"].list.last?["state"].text,"complete")
        XCTAssertEqual(completed["messages"].list.last?["text"].text,"Finished")
    }

    func testLinearByteLimitMatchesEncodedProjectionWithEscapedUnicode() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var seed=history()
        for index in seed.indices {
            // A long three-turn conversation still reaches the independent byte cap.
            seed[index].role = [0, 26, 54].contains(index) ? "user" : "assistant"
            seed[index].content=[textBlock(String(repeating:"\"quoted\"\\line\n🦉/",count:900))]
        }
        let session=try session(root:root,id:"bytes",seed:seed)
        addTeardownBlock { await session.close() }
        var expected=seed.suffix(60).map { $0.view() }, start=seed.count-60
        while try JSON.array(expected).data().count>253_952, expected.count>1 { expected.removeFirst(); start += 1 }
        let projection=await session.snapshot()
        XCTAssertEqual(projection["messages"],.array(expected))
        XCTAssertEqual(projection["before"].int,start)
        XCTAssertLessThanOrEqual(try projection["messages"].data().count,253_952)
        let rows=await session.displayRowProjectionCount
        XCTAssertEqual(rows,expected.count+1,"Only the byte-bounded suffix and its one boundary candidate need projection")
        let status=await session.snapshot(["includeMessages":false])
        XCTAssertEqual(status["before"],projection["before"],"A warm status can reuse an already known cursor")
    }

    func testCancelledEmptyPartialInvalidatesCachedPlaceholder() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ProjectionClient(), session=try session(root:root,id:"cancel",seed:[],client:client)
        addTeardownBlock { await session.close() }
        _=try await session.submit(Submission(commandID:"start",turnID:"start",text:"Question"),steer:false)
        try await eventually { await client.ready }
        let running=await session.snapshot()
        XCTAssertEqual(running["messages"].list.last?["state"].text,"streaming")
        await session.stop(); try await eventually { !(await session.isRunning) }
        let stopped=await session.snapshot(["displayRevision":running["displayRevision"]])
        XCTAssertNotEqual(stopped["displayRevision"],running["displayRevision"])
        XCTAssertFalse(stopped["messages"].list.contains { $0["state"].text=="streaming" })
        XCTAssertEqual(stopped["messages"].list.count,1)
    }

    func testReplacementRuntimeCannotReuseRetiredProjectionRevision() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let seed=history(count:4)
        let old=try session(root:root,id:"same",seed:seed)
        let previous=await old.snapshot(); await old.close()
        let replacement=try session(root:root,id:"same",seed:seed)
        addTeardownBlock { await replacement.close() }
        let refreshed=await replacement.snapshot(["displayRevision":previous["displayRevision"]])
        XCTAssertNotEqual(refreshed["displayRevision"],previous["displayRevision"])
        XCTAssertEqual(refreshed["messages"],previous["messages"])
    }

    func testFailedAndCancelledPartialsHaveOneIdentityWhileOutputLinksArePersisting() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        for failure in [false,true] {
            let client=ProjectionClient(), gate=ProjectionLinkGate(), traces=TraceStore(sink:{ await gate.accept($0) })
            let profile=try fixtureProfile(), id=failure ? "failed-links" : "cancel-links"
            let session=try AgentSession(id:id,profile:profile,apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:traces,autoCompaction:false)
            addTeardownBlock { await gate.release(); await session.close() }
            _=try await session.submit(Submission(commandID:"start",turnID:"start",text:"Question"),steer:false)
            try await eventually { await client.ready }
            _=await traces.begin(session:id,turn:"start",profile:profile,purpose:"turn",body:Data(),headers:[:])
            try await client.emit("Keep this partial reply")
            _=await session.snapshot()
            if failure { await client.fail() } else { await session.stop() }
            try await eventually { await gate.waiting }
            let during=await session.snapshot()
            let ids=during["messages"].list.compactMap { $0["id"].text }
            XCTAssertEqual(ids.count,Set(ids).count,"Reentrant presentation must not duplicate a saved partial's stable row ID")
            XCTAssertEqual(during["messages"].list.filter { $0["role"].text=="assistant" }.count,1)
            XCTAssertEqual(during["messages"].list.last?["text"].text,"Keep this partial reply")
            XCTAssertEqual(during["messages"].list.last?["state"].text,"complete")
            XCTAssertEqual(during["state"].text,failure ? "error" : "paused")
            XCTAssertFalse(during["preflightError"].text?.isEmpty ?? true)
            await gate.release(accepted:!failure); try await eventually { !(await session.isRunning) }
            let settled=await session.snapshot()
            XCTAssertEqual(settled["messages"].list.last?["text"].text,"Keep this partial reply")
            XCTAssertEqual(settled["state"].text,failure ? "error" : "paused")
            await session.close()
        }
    }
}
