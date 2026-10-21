import XCTest
@testable import PiAgentCore

final class SubagentForkTests: HelperTestCase {
    private let sourceID = "parent-with-subagents-long-identity"
    private func session(_ root: URL, _ id: String, path: String? = nil,
                         prepared: JournalReplayConsumer? = nil, client: any ModelClient = ScriptClient([])) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                         resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),
                         resumePath:path,prepared:prepared,autoCompaction:false)
    }
    private func family(_ root: URL) async throws -> AgentSession {
        let parent = try session(root,sourceID,client:AccountedAgentScript([answer("First child result"),answer("Second child result")]))
        let coordinator = AgentSteeringCoordinator()
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        try await parent.forkFixtureReply("before")
        for point in ["between", "after"] {
            let call = ToolCall(id:point,name:"subagent_start",arguments:["task":JSON(point),"mode":"background"])
            _ = try await parent.agentFixtureCall(call,newTask:true)
            try await parent.runToolBatch([call])
            try await eventually { await parent.agentState().turns.values.allSatisfy { $0.status.terminal } }
            _ = try await coordinator.deliver(owner:parent,recipient:parent,childTurn:nil)
            try await parent.forkFixtureReply(point)
            if point == "between" { try await parent.forkFixtureCheckpoint() }
        }
        await coordinator.drain()
        return parent
    }
    private func records(_ path: String) throws -> [JSON] {
        let reader = try JournalRecordReader(URL(fileURLWithPath:path)); var rows: [JSON] = []
        while let row = try reader.next() { rows.append(row) }; return rows
    }

    func testCopiedV3FamilyForkHasOneMarkerAndReopens() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try await family(root)
        let id = "copy-with-an-identity-longer-than-the-parent-to-force-the-copy-fallback"
        let made = try await parent.forked(to:id)
        let path = try XCTUnwrap(made.result["path"].text)
        XCTAssertEqual(try records(path).filter { JournalRecordKind.isMarker($0["customType"].text) }.count,1)
        await parent.close()
        let fork = try session(root,id,path:path,prepared:made.replay)
        let state = await fork.subagents, spend = await fork.spend
        XCTAssertTrue(state.plans.isEmpty); XCTAssertTrue(state.family?.turns.isEmpty ?? true)
        XCTAssertEqual(spend,SessionSpend())
        await fork.close()
        let reopened = try session(root,id,path:path); await reopened.close()
    }

    func testClonedV3FamilyForkCheckpointAndReplayAgree() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try await family(root)
        let made = try await parent.forked(to:"clone")
        let path = try XCTUnwrap(made.result["path"].text), url = URL(fileURLWithPath:path)
        let checkpoint = try XCTUnwrap(JournalCheckpoint.read(for:url))
        let journal = try SessionJournal(url:url,id:"clone",cwd:root,binding:fixtureProfile().binding,create:false,checkpoint:checkpoint)
        XCTAssertNotNil(journal.resumedFrom,"Promotion must not leave a stale v1 marker digest in the fork checkpoint")
        let full = try AgentSession.replay(journal,url:url,id:"clone",binding:fixtureProfile().binding,spendTracked:false,resume:false)
        XCTAssertEqual(try made.replay.finished().subagents,full.subagents)
        XCTAssertEqual(checkpoint,full.captured)
        await parent.close()
    }

    func testCopyAtEveryFamilyBoundaryWithAndWithoutSourceCheckpoint() async throws { try await boundaries(copy:true) }
    func testCloneAndTruncateAtEveryFamilyBoundaryWithAndWithoutSourceCheckpoint() async throws { try await boundaries(copy:false) }

    private func boundaries(copy: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let live = try await family(root); await live.close()
        let source = root.appendingPathComponent(sourceID + ".jsonl")
        for cached in [true,false] {
            if !cached { JournalCheckpoint.remove(for:source) }
            let parent = try session(root,sourceID,path:source.path)
            let partial = await parent.partialHistory
            XCTAssertEqual(partial,cached)
            let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
            let before = try files.map { try Data(contentsOf:$0) }
            for point in ["before","between","after","whole"] {
                let id = (copy ? "copied-with-a-much-longer-session-identity-than-the-source-" : "f-") + point + String(cached)
                let made = try await parent.forked(to:id,at:point == "whole" ? nil : point)
                let path = try XCTUnwrap(made.result["path"].text), url = URL(fileURLWithPath:path)
                let rows = try records(path)
                XCTAssertEqual(rows.filter { JournalRecordKind.isMarker($0["customType"].text) }.map { $0["customType"].text },[JournalRecordKind.steeringMarker])
                XCTAssertEqual(rows.contains { $0["data"]["source"].text == "fork" && $0["data"]["reset"].flag == true },!copy,"The APFS path must remain active")
                let expected = try made.replay.finished()
                XCTAssertEqual(expected.context.last?.id,point == "whole" ? "after" : point)
                XCTAssertEqual(expected.context.filter { $0.nativeAgentDelivery != nil }.count,point == "before" ? 0 : point == "between" ? 1 : 2)
                for useCheckpoint in [true,false] {
                    if !useCheckpoint { JournalCheckpoint.remove(for:url) }
                    let fork = try session(root,id,path:path)
                    let context = await fork.context, state = await fork.subagents, accounting = await fork.accounting, spend = await fork.spend
                    XCTAssertEqual(context,expected.context)
                    XCTAssertEqual(state,expected.subagents)
                    XCTAssertTrue(state.plans.isEmpty); XCTAssertNil(state.origin)
                    XCTAssertTrue(state.family?.operations.isEmpty ?? true); XCTAssertTrue(state.family?.turns.isEmpty ?? true)
                    XCTAssertTrue(state.family?.messages.isEmpty ?? true); XCTAssertTrue(state.family?.deliveries.isEmpty ?? true)
                    XCTAssertNil(state.family?.run)
                    XCTAssertEqual(accounting,AttemptAccounting()); XCTAssertEqual(spend,SessionSpend())
                    await fork.close()
                }
            }
            XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before,"Fork/open must not modify the source or any child")
            await parent.close()
        }
    }

    func testDuplicateMarkerDamageIsRejectedWithoutChangingJournal() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("fork_damaged.jsonl"), profile = try fixtureProfile()
        do {
            let journal = try SessionJournal(url:url,id:"damaged",cwd:root,binding:profile.binding,create:true)
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.steeringMarker),"data":["binding":profile.binding,"version":1]])
        }
        let before = try Data(contentsOf:url)
        XCTAssertThrowsError(try session(root,"damaged",path:url.path)) {
            XCTAssertEqual(($0 as? AgentError)?.code,"session_damaged")
            XCTAssertTrue($0.localizedDescription.contains("format marker"))
        }
        XCTAssertEqual(try Data(contentsOf:url),before)
    }

    func testCopyRecognizesAnEscapedV3MarkerThroughTheParserFallback() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("source.jsonl")
        do {
            let journal = try SessionJournal(url:url,id:"source",cwd:root,binding:fixtureProfile().binding,create:true)
            try journal.promoteToSteering(managedChild:false)
            try journal.append(["type":"message","message":["role":"assistant","content":"Saved reply"]],id:"reply")
        }
        let escaped = try String(contentsOf:url).replacingOccurrences(of:"pi-app.native.v3",with:"pi-app.native.v\\u0033")
        try Data(escaped.utf8).write(to:url)
        let source = try session(root,"source",path:url.path)
        let made = try await source.forked(to:"a-long-identity-for-the-parser-copy-fallback")
        let path = try XCTUnwrap(made.result["path"].text)
        XCTAssertEqual(try records(path).filter { JournalRecordKind.isMarker($0["customType"].text) }.count,1)
        let fork = try session(root,"a-long-identity-for-the-parser-copy-fallback",path:path)
        await fork.close()
        XCTAssertEqual(try Data(contentsOf:url),Data(escaped.utf8))
        await source.close()
    }

    func testLegacyFamilyCopiesAndClonesKeepOneV1MarkerAndAnIndependentBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try session(root,sourceID,client:AccountedAgentScript([answer("Legacy child result")]))
        await parent.enableSubagents(SubagentCoordinator(),steering:false)
        let call = ToolCall(id:"legacy",name:"subagent",arguments:["task":"Legacy task"])
        _ = try await parent.agentFixtureCall(call,newTask:true); try await parent.runToolBatch([call])
        try await parent.forkFixtureReply("after")
        let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
        let before = try files.map { try Data(contentsOf:$0) }
        for id in ["clone","a-longer-identity-to-force-the-legacy-family-copy-fallback"] {
            let made = try await parent.forked(to:id)
            let path = try XCTUnwrap(made.result["path"].text)
            XCTAssertEqual(try records(path).filter { JournalRecordKind.isMarker($0["customType"].text) }.map { $0["customType"].text },[JournalRecordKind.marker])
            let fork = try session(root,id,path:path,prepared:made.replay)
            let state = await fork.subagents, spend = await fork.spend, history = await fork.history
            XCTAssertTrue(state.plans.isEmpty); XCTAssertNil(state.origin); XCTAssertEqual(spend,SessionSpend())
            XCTAssertTrue(history.contains { $0.role == "toolResult" && $0.text.contains("Legacy child result") })
            await fork.close()
        }
        XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before)
        await parent.close()
    }

    func testRunningAndStoppedParentsForkWithoutAdoptingPendingChildren() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentBoundaryClient(starts:2), parent = try session(root,"parent",client:client)
        await parent.enableSubagents(SubagentCoordinator())
        _ = try await parent.submit(Submission(commandID:"start",turnID:"task",text:"Delegate"),steer:false)
        try await eventually { await parent.familyWaiting }
        for stopped in [false,true] {
            if stopped { await parent.stop(); try await eventually { !(await parent.isRunning) } }
            let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
            let before = try files.map { try Data(contentsOf:$0) }
            for id in [stopped ? "end" : "run", "copied-family-" + String(stopped)] {
                let made = try await parent.forked(to:id)
                let fork = try session(root,id,path:made.result["path"].text,prepared:made.replay)
                let state = await fork.subagents, cost = await fork.spend, snapshot = await fork.snapshot()
                XCTAssertTrue(state.plans.isEmpty); XCTAssertTrue(state.family?.turns.isEmpty ?? true)
                XCTAssertTrue(state.family?.messages.isEmpty ?? true); XCTAssertNil(state.family?.run)
                XCTAssertEqual(cost,SessionSpend()); XCTAssertNotEqual(snapshot["familyWaiting"].flag,true)
                await fork.close()
            }
            XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before)
        }
        await parent.close()
    }

    func testForkAtStartReceiptResumesOnlyTheForkWithoutReplayingTheChild() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try await family(root)
        let reply = await parent.history.first { $0.content.contains { $0["name"].text == "subagent_start" } }?.id
        let point = try XCTUnwrap(reply)
        let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
        let before = try files.map { try Data(contentsOf:$0) }
        for id in ["receipt","a-longer-identity-for-copying-the-start-receipt-boundary"] {
            let made = try await parent.forked(to:id,at:point), client = AccountedAgentScript([answer("Independent synthesis")])
            let fork = try session(root,id,path:made.result["path"].text,prepared:made.replay,client:client)
            await fork.enableSubagents(SubagentCoordinator())
            let context = await fork.context, continuable = await fork.canContinue
            XCTAssertEqual(context.last?.role,"toolResult"); XCTAssertTrue(continuable)
            _ = try await fork.continueRun(commandID:"resume")
            try await eventually { !(await fork.isRunning) }
            let requests = await client.requests, plans = await fork.subagents.plans
            XCTAssertEqual(requests.count,1); XCTAssertTrue(plans.isEmpty)
            XCTAssertTrue(requests[0].contains { $0.role == "toolResult" && $0.nativeSubagent != nil })
            await fork.close()
        }
        XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before)
        await parent.close()
    }

    func testForkResumesStartsItsOwnChildFollowsUpAndReopensWithoutSourceWrites() async throws { try await independentRuntime(copy:false) }
    func testCopiedForkResumesStartsItsOwnChildFollowsUpAndReopensWithoutSourceWrites() async throws { try await independentRuntime(copy:true) }

    private func independentRuntime(copy: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try await family(root); await parent.close()
        let source = try session(root,sourceID,path:root.appendingPathComponent(sourceID + ".jsonl").path)
        let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
        let before = try files.map { try Data(contentsOf:$0) }
        let id = copy ? "a-long-identity-to-force-copying-before-new-subagent-work" : "fork"
        let made = try await source.forked(to:id), client = ForkRunClient(parentID:id)
        let fork = try session(root,id,path:made.result["path"].text,prepared:made.replay,client:client)
        await fork.enableSubagents(SubagentCoordinator())
        _ = try await fork.submit(Submission(commandID:"new",turnID:"new",text:"Start independent work"),steer:false)
        try await eventually { await client.parentCalls == 1 }
        await fork.stop(); try await eventually { !(await fork.isRunning) }
        let continuable = await fork.canContinue; XCTAssertTrue(continuable)
        _ = try await fork.continueRun(commandID:"resume")
        try await eventually { !(await fork.isRunning) }
        let first = await fork.agentState(), plans = await fork.subagents.plans
        let child = try XCTUnwrap(plans.values.first?.origin.link.childSessionID)
        XCTAssertEqual(plans.count,1); XCTAssertEqual(plans.values.first?.origin.link.budgetOwnerSessionID,id)
        let sourceChildren = await source.subagents.plans.values.map { $0.origin.link.childSessionID }
        XCTAssertFalse(sourceChildren.contains(child))
        XCTAssertEqual(first.latest(child)?.turn,1); XCTAssertEqual(first.latest(child)?.status,.completed)
        _ = try await fork.submit(Submission(commandID:"follow",turnID:"follow",text:"Follow up"),steer:false)
        try await eventually { !(await fork.isRunning) }
        let second = await fork.agentState(), spend = await fork.spend, state = await fork.state
        XCTAssertEqual(state,.idle)
        XCTAssertEqual(second.latest(child)?.turn,2); XCTAssertEqual(second.latest(child)?.status,.completed)
        let completedRequests = await client.completedRequests
        XCTAssertEqual(spend.usd,Double(completedRequests) * 0.01,accuracy:0.000001,"Only this fork's completed physical requests are charged")
        await fork.close()
        JournalCheckpoint.remove(for:URL(fileURLWithPath:made.result["path"].text!))
        let reopened = try session(root,id,path:made.result["path"].text,client:client)
        await reopened.enableSubagents(SubagentCoordinator())
        let saved = await reopened.agentState(), cost = await reopened.spend
        XCTAssertEqual(saved,second); XCTAssertEqual(cost,spend)
        _ = try await reopened.submit(Submission(commandID:"after-relaunch",turnID:"after-relaunch",text:"Continue"),steer:false)
        try await eventually { !(await reopened.isRunning) }
        XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before,"No source journal or child receives fork recovery, control or spend writes")
        await reopened.close(); await source.close()
    }

    func testManagedChildForkIsRejectedWithoutWritingAnyFamilyFile() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let parent = try await family(root); await parent.close()
        let plans = await parent.subagents.plans
        let id = try XCTUnwrap(plans.values.first?.origin.link.childSessionID), path = root.appendingPathComponent(id + ".jsonl")
        let child = try session(root,id,path:path.path)
        let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
        let before = try files.map { try Data(contentsOf:$0) }
        do { _ = try await child.fork(to:"child-fork"); XCTFail("Managed child acquired an independent command") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"managed_subagent") }
        XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("fork_child-fork.jsonl").path))
        await child.close()
    }
}

private actor ForkRunClient: ModelClient {
    let parentID: String
    private(set) var parentCalls = 0
    private(set) var completedRequests = 0
    private var started = false, sent = false
    init(parentID: String) { self.parentID = parentID }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Use the accounted fixture")
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let attempt = UUID().uuidString, permit = try await lifecycle?.admitAttempt(attempt)
        defer { permit?.finish() }; try await lifecycle?.willDispatch(attempt)
        var reply = answer("Independent result")
        if sessionID == parentID {
            parentCalls += 1
            if parentCalls == 1 { while true { try await Task.sleep(for:.seconds(1)) } }
            if !started { started = true; reply = agentCallReply("fork-start","subagent_start",["task":"Independent child","mode":"wait"]) }
            if !sent, messages.contains(where:{ $0.role == "user" && $0.text == "Follow up" }) {
                sent = true
                let result = try XCTUnwrap(messages.last { $0.toolCallId == "fork-start" })
                let child = try JSON.parse(Data(result.text.utf8))["child_id"]
                reply = agentCallReply("fork-send","subagent_send",["child_id":child,"message":"Continue in the same child","expected_turn":1])
            }
        }
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        if let lifecycle { try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true)) }
        await onObservation(observation); completedRequests += 1; reply.message.requestAttemptIDs = [attempt]; return reply
    }
}

private extension AgentSession {
    func forkFixtureReply(_ id: String) throws {
        var row = ChatMessage(role:"assistant",content:[textBlock(id)]); row.id = id
        try append(row); boundary = context
    }
    func forkFixtureCheckpoint() throws {
        try journal?.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(context.map { JSON($0.id) })]])
        refreshCheckpoint()
    }
}
