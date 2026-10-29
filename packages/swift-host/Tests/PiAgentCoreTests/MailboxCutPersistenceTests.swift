import XCTest
@testable import PiAgentCore

final class MailboxCutPersistenceTests: HelperTestCase {
    private struct Fixture {
        let root: URL, path: URL, profile: Profile, preparation: JSON, commit: JSON, rows: [ChatMessage]
        func open(_ id: String = "source", path: String? = nil) throws -> AgentSession {
            try AgentSession(id:id,profile:profile,apiKey:"generated",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),
                resumePath:path ?? self.path.path,autoCompaction:false)
        }
    }
    private func fixture(projected: Int = 2, committed: Bool = true) throws -> Fixture {
        let root = try temporaryDirectory(); addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("source.jsonl"), profile = try fixtureProfile()
        let scope = RequestScope(sourceSessionID:"source",budgetOwnerSessionID:"source",turnID:"turn",executionID:"execution",purpose:"turn",ownerGeneration:0,delegation:nil)
        var assistant = ChatMessage(role:"assistant",content:[["type":"toolCall","id":"call","name":"bash","arguments":["command":"never"]]])
        assistant.id = "prefix"; assistant.turn = "turn"; assistant.timestamp = 123
        assistant.providerItems = [["type":"reasoning","id":"rs","encrypted_content":"opaque-雪-+/=","summary":[]],
            ["type":"function_call","id":"fc","call_id":"call","name":"bash","arguments":"{ \"command\": \"never\" }"]]
        assistant.requestAttemptIDs = ["attempt"]
        assistant.nativeMailboxCut = ["version":1,"cutId":"cut","attemptId":"attempt","responseId":"response","itemId":"rs"]
        var result = ChatMessage(role:"toolResult",content:[textBlock("Not executed: agent message arrived before dispatch.")])
        result.id = "cancelled"; result.turn = "turn"; result.toolName = "bash"; result.toolCallId = "call"; result.isError = true; result.timestamp = 123
        result.nativeAgentCallCancellation = ["version":1,"cutId":"cut","reason":"agent_message"]
        // Production projection decodes the reserved wire rows before append.
        let rows = try [assistant,result].map { try ChatMessage(id:$0.id,pi:$0.pi) }
        var preparation: JSON = ["version":1,"cutId":"cut","attemptId":"attempt","turnId":"turn","branchId":"turn","generation":0,
            "recipientSessionId":"source","eventIds":["mail"],"rows":.array(rows.map { ["id":JSON($0.id),"message":$0.pi] })]
        preparation["digest"] = JSON(MailboxCutJournal.digest(preparation))
        let commit = preparation.removing(["turnId","branchId","generation","eventIds","rows"])
        do {
            let journal = try SessionJournal(url:path,id:"source",cwd:root,binding:profile.binding,create:true)
            try journal.promoteToCodex(managedChild:false)
            try journal.append(["type":"message","message":ChatMessage(role:"user",content:[textBlock("Generated task")]).pi],id:"turn")
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.familyRun),"ownerID":"source","data":subagentJSON(AgentFamilyRun(epoch:"execution"))])
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.budgetAttempt),"data":["attemptId":"attempt","sourceSessionId":"source","budgetOwnerSessionId":"source","purpose":"turn","state":"dispatched","scope":subagentJSON(scope),"accountingRevision":1]])
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentCutPrepared),"ownerID":"source","data":preparation])
            if committed {
                try journal.promoteToMailboxCut(managedChild:false)
                try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentCutCommitted),"ownerID":"source","data":commit])
                for row in rows.prefix(projected) { try journal.append(["type":"message","message":row.pi],id:row.id) }
                if projected == 2 { try journal.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":["turn","prefix","cancelled"]]]) }
            }
            try journal.synchronize()
        }
        return Fixture(root:root,path:path,profile:profile,preparation:preparation,commit:commit,rows:rows)
    }
    func testCommittedPrefixRepairsEveryMissingRowOnceAndPreparationAloneDoesNotProject() async throws {
        for count in 0...2 {
            let f = try fixture(projected:count)
            for _ in 0...1 {
                let session = try f.open(), rows = await session.context
                XCTAssertEqual(rows.suffix(2).map(\.pi),f.rows.map(\.pi))
                let final = await session.agentFinalProduced; XCTAssertFalse(final)
                let running = await session.isRunning; XCTAssertFalse(running)
                await session.close()
            }
            let saved = try records(f.path)
            for id in ["prefix","cancelled"] { XCTAssertEqual(saved.filter { $0["id"].text == id }.count,1) }
        }
        let f = try fixture(projected:0,committed:false), session = try f.open()
        let rows = await session.context; XCTAssertEqual(rows.map(\.id),["turn"])
        await session.close()
        XCTAssertEqual(try records(f.path)[1]["customType"].text,JournalRecordKind.codexMarker)
    }
    func testUncommittedPreparationAllowsNormalReplyWithReservedPartialID() async throws {
        let f = try fixture(projected:0,committed:false)
        do {
            let journal = try SessionJournal(url:f.path,id:"source",cwd:f.root,binding:f.profile.binding,create:false)
            var normal = ChatMessage(role:"assistant",content:[textBlock("Ordinary complete reply")]); normal.turn = "turn"
            try journal.append(["type":"message","message":normal.pi],id:"prefix")
        }
        for _ in 0..<2 {
            let session = try f.open(), rows = await session.context
            XCTAssertEqual(rows.map(\.id),["turn","prefix"])
            XCTAssertEqual(rows.last?.text,"Ordinary complete reply"); XCTAssertNil(rows.last?.nativeMailboxCut)
            await session.close(); JournalCheckpoint.remove(for:f.path)
        }
    }
    func testCommittedHistoryDescriptionRequiresEveryCutProjection() async throws {
        for count in 0...2 {
            let f = try fixture(projected: count), session = try f.open()
            let complete = try await session.committedHistorySource()
            XCTAssertNotNil(complete, "Opening must finish crash recovery before offering the file source")
            await session.removeCutProjectionFixture()
            let incomplete = try await session.committedHistorySource()
            XCTAssertNil(incomplete, "A committed cut with one missing projection must stay on the helper path")
            await session.close()
        }
        let f = try fixture(projected: 0, committed: false), session = try f.open()
        let source = try await session.committedHistorySource()
        XCTAssertNotNil(source); XCTAssertEqual(source?.total, 1, "A preparation alone adds no displayed row")
        await session.close()
    }
    func testCheckpointColdReplaySlimmingAndForkKeepExactHistoryWithoutExecutionAuthority() async throws {
        let f = try fixture(), session = try f.open()
        let forked = try await session.fork(to:"fork",at:"prefix")
        await session.close()
        let checkpoint = try XCTUnwrap(JournalCheckpoint.read(for:f.path))
        XCTAssertEqual(checkpoint.version,3)
        var old = checkpoint; old.version = 2
        XCTAssertNil(AgentSession.loadCheckpoint(old,url:f.path))
        for cold in [false,true] {
            if cold { JournalCheckpoint.remove(for:f.path) }
            let reopened = try f.open(), rows = await reopened.context
            XCTAssertEqual(rows.suffix(2).map(\.pi),f.rows.map(\.pi))
            let commits = await reopened.subagents.cuts?.commits; XCTAssertEqual(commits?["cut"],f.commit)
            await reopened.close()
        }
        let outcome = try JournalSlimming.slim(url:f.path,id:"source",minimumSaving:0,discard:{ try FileManager.default.removeItem(at:$0) })
        XCTAssertTrue(outcome.slimmed || outcome.reason == "little-to-gain",outcome.reason ?? "")
        let slim = try f.open(), slimRows = await slim.context
        XCTAssertEqual(slimRows.suffix(2).map(\.pi),f.rows.map(\.pi)); await slim.close()
        let forkPath = try XCTUnwrap(forked["path"].text), fork = try f.open("fork",path:forkPath)
        let copied = await fork.context, authority = await fork.subagents.cuts?.commits
        XCTAssertEqual(copied.suffix(2).map(\.pi),f.rows.map(\.pi)); XCTAssertTrue(authority?.isEmpty ?? true)
        XCTAssertEqual(try records(URL(fileURLWithPath:forkPath))[1]["customType"].text,JournalRecordKind.cutinMarker)
        await fork.close()
    }
    func testPreparationDigestPairingStableIDsAndInheritedAuthorityFailClosed() throws {
        let f = try fixture()
        XCTAssertEqual(try MailboxCutJournal.rows(f.preparation,commit:f.commit).map(\.pi),f.rows.map(\.pi))
        for field in ["cutId","attemptId","recipientSessionId","digest"] {
            var changed = f.commit; changed[field] = "changed"
            XCTAssertThrowsError(try MailboxCutJournal.rows(f.preparation,commit:changed),field)
        }
        var missing = f.preparation; missing["rows"] = .array(Array(missing["rows"].list.prefix(1))); missing["digest"] = JSON(MailboxCutJournal.digest(missing))
        var commit = f.commit; commit["digest"] = missing["digest"]
        XCTAssertThrowsError(try MailboxCutJournal.rows(missing,commit:commit))
        for field in ["version","attemptId","reason"] {
            var prepared = f.preparation, rows = prepared["rows"].list
            if field == "reason" { rows[1]["message"]["nativeAgentCallCancellation"][field] = "other" }
            else { rows[0]["message"]["nativeMailboxCut"][field] = field == "version" ? 2 : "other" }
            prepared["rows"] = .array(rows); prepared["digest"] = JSON(MailboxCutJournal.digest(prepared))
            var committed = f.commit; committed["digest"] = prepared["digest"]
            XCTAssertThrowsError(try MailboxCutJournal.rows(prepared,commit:committed),field)
        }
        var state = SubagentJournalState(); state.family = AgentFamilyState(ownerID:"source")
        for kind in [JournalRecordKind.agentCutPrepared,JournalRecordKind.agentCutCommitted] {
            try state.consume(["type":"custom","customType":JSON(kind),"ownerID":"source","data":kind == JournalRecordKind.agentCutPrepared ? f.preparation : f.commit],sessionID:"source")
        }
        var projection: JSON = ["type":"message","id":"prefix","message":f.rows[0].pi]
        try state.consume(projection,sessionID:"source"); try state.consume(projection,sessionID:"source")
        projection["message"]["content"] = []
        XCTAssertThrowsError(try state.consume(projection,sessionID:"source"))
        state.retarget("fork"); XCTAssertTrue(state.cuts?.commits.isEmpty ?? true); XCTAssertTrue(state.cuts?.preparations.isEmpty ?? true)
        let historical = state.cuts?.projected
        let inherited = SubagentCodexContract.inherited(f.rows[0],from:"source",cutoff:"prefix")
        try state.consume(["type":"message","id":"prefix","message":inherited.pi],sessionID:"fork")
        XCTAssertEqual(state.cuts?.projected,historical)
    }
    func testNoMailboxAndSourceGenerationBranchHoldAndTombstoneFences() async throws {
        for change in ["no-mail","generation","branch","closed"] {
            let f = try fixture(), session = try f.open(), coordinator = AgentSteeringCoordinator()
            await session.enableAgentSteering(coordinator,codex:true)
            let scope = try await session.armCutFixture()
            var reply = answer("Retained commentary")
            reply.message.requestAttemptIDs = ["new-attempt"]
            reply.mailboxCut = MailboxCut(cutId:"new-cut",attemptId:"new-attempt",responseId:"response",itemId:"item")
            if change == "no-mail" {
                let cut = try await coordinator.cut(reply,recipient:session,scope:scope,fence:await session.mailboxCutFence)
                XCTAssertNil(cut)
            } else {
                let prepared = try await session.prepareMailboxCut(reply,events:["new-mail"],scope:scope,fence:await session.mailboxCutFence)
                let preparation = try XCTUnwrap(prepared)
                await session.changeCutFixture(change)
                do { try await session.promoteMailboxCut(preparation); XCTFail("Cut survived \(change)") } catch { }
            }
            await session.clearCutFixture(); await session.close()
        }
    }
    func testInterruptCancelsAnAlreadySealedRecipientsDrainAndSettlementIsIdempotent() async throws {
        let f = try fixture(), session = try f.open()
        let permit = await session.installOldCutDrainFixture()
        await session.cancelMailboxDrains(source:"source")
        XCTAssertThrowsError(try permit.check())
        let scope = RequestScope(sourceSessionID:"source",budgetOwnerSessionID:"source",turnID:"turn",executionID:"execution",purpose:"turn",ownerGeneration:0,delegation:nil)
        var observation = RequestObservation(sessionID:"source",turnID:"turn",attemptID:"attempt",purpose:"turn",fingerprint:"generated",profile:f.profile)
        _ = observation.consume(["type":"response.completed","response":["usage":["input_tokens":100,"output_tokens":2000,"cost":0.02]]],streaming:true,at:1,credentials:CaptureCredentials(headers:[:],configuredNames:[]))
        let settlement = AttemptSettlement(scope:scope,observation:observation,dispatched:true)
        _ = try await session.settleOwnedAttempt(settlement)
        let first = await session.spend.record
        _ = try await session.settleOwnedAttempt(settlement)
        let second = await session.spend.record; XCTAssertEqual(first,second)
        await session.close()
        XCTAssertEqual(try records(f.path).filter { $0["customType"].text == JournalRecordKind.cost && $0["data"]["attemptId"].text == "attempt" }.count,1)
    }
    func testInheritedChildAndKeptSideRequireV5WithoutInheritingCutAuthority() async throws {
        let f = try fixture(), parent = try f.open()
        let inherited = f.rows.map { SubagentCodexContract.inherited($0,from:"source",cutoff:"cancelled") }
        var origin = subagentFixtureOrigin(); origin.taskName = "/root/audit"; origin.forkTurns = "all"
        let seed = AgentForkSeed(from:"source",cutoffEntryID:"cancelled",messages:inherited)
        let plan = SubagentPlan(origin:origin,task:"Inherited cut",resultMessageID:"receipt",forkSeed:seed)
        var turn = AgentChildTurn(childID:origin.link.childSessionID,turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
        turn.taskName = origin.taskName; turn.forkTurns = "all"
        let resources = Resources(cwd:f.root,home:f.root)
        let env = SubagentEnvironment(parent:parent,ownerID:"source",turnID:"turn",executionID:"execution",parentAttemptID:nil,generation:0,runtimeID:"runtime",profile:f.profile,apiKey:"fixture",connectionSupportsReasoning:false,models:[origin.model],definitions:[],capabilities:[],mcpPolicy:nil,tools:RecordingTools(),client:ScriptClient([]),resources:try await resources.resolve(),cwd:f.root,directory:f.root,readOnly:true,traces:TraceStore(),retry:.init(),changed:{ _,_ in })
        try await AgentSteeringCoordinator().publishQueuedChild(env,plan:plan,turn:turn,seedMessages:inherited)
        let childPath = f.root.appendingPathComponent(origin.link.childSessionID + ".jsonl")
        XCTAssertEqual(try records(childPath)[1]["customType"].text,JournalRecordKind.cutinMarker)
        let side = try AgentSession(id:"side",profile:f.profile,apiKey:"fixture",cwd:f.root,directory:f.root,readOnly:true,resources:resources,client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),seed:inherited)
        let saved = try await side.keep(whenFinished:false), path = try XCTUnwrap(saved["path"].text)
        await side.close(); await parent.close()
        XCTAssertEqual(try records(URL(fileURLWithPath:path))[1]["customType"].text,JournalRecordKind.cutinMarker)
        let reopened = try f.open("side",path:path), state = await reopened.subagents.cuts
        XCTAssertTrue(state?.commits.isEmpty ?? true); XCTAssertTrue(state?.preparations.isEmpty ?? true)
        await reopened.close()
    }
    func testCutIsNeitherAProducedFinalNorAFinalResult() async throws {
        let f = try fixture(), session = try f.open()
        for cut in [true,false] {
            let result = await session.finalCutFixture(cut)
            XCTAssertEqual(result.0,!cut)
            XCTAssertEqual(result.1,cut ? "" : "Retained note")
        }
        await session.close()
    }
    private func records(_ path: URL) throws -> [JSON] { try Data(contentsOf:path).split(separator:10).map { try JSON.parse(Data($0)) } }
}

private extension AgentSession {
    func removeCutProjectionFixture() { subagents.cuts?.projected.removeValue(forKey: "cancelled") }
    func armCutFixture() throws -> RequestScope {
        enableFamilyBudget(); currentTurnID = "turn"; agentContractVersion = 4
        let scope = RequestScope(sourceSessionID:id,budgetOwnerSessionID:id,turnID:"turn",executionID:displayEpoch,purpose:"turn",ownerGeneration:stopCount,delegation:nil)
        _ = try admitAttempt(scope:scope,attemptID:"new-attempt"); try dispatchAttempt(scope:scope,attemptID:"new-attempt")
        return scope
    }
    func changeCutFixture(_ change: String) {
        switch change {
        case "generation": stopCount += 1
        case "branch": context.append(ChatMessage(role:"user",content:[textBlock("Different branch")]))
        case "hold": queuePaused = true
        case "closed": closed = true
        default: break
        }
    }
    func clearCutFixture() {
        closed = false; queuePaused = false
        for permit in requestPermits.values { permit.finish() }; requestPermits.removeAll(); finishRequestDrainWaiters()
    }
    func installOldCutDrainFixture() -> RequestPermit {
        let permit = RequestPermit("attempt"); requestPermits["attempt"] = permit; return permit
    }
    func finalCutFixture(_ cut: Bool) -> (Bool,String) {
        let priorContext = context, priorVisible = visible, priorLease = agentLease
        defer { context = priorContext; visible = priorVisible; agentLease = priorLease }
        let origin = subagentFixtureOrigin(), plan = SubagentPlan(origin:origin,task:"Task",resultMessageID:"receipt")
        let turn = AgentChildTurn(childID:id,turn:1,executionID:"execution",parentExecutionID:"parent-execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"turn",task:"Task",call:origin.link.call)
        var row = ChatMessage(role:"assistant",content:[textBlock("Retained note")]); row.taskRootID = "turn"
        if cut { row.nativeMailboxCut = ["version":1] }
        context = [row]; visible = [row]; agentLease = turn
        return (agentFinalProduced,agentResult(turn,plan:plan,cancelled:true).envelope["text"].text ?? "")
    }
}
