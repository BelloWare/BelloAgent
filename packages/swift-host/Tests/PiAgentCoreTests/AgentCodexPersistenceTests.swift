import XCTest
@testable import PiAgentCore

final class AgentCodexPersistenceTests: HelperTestCase {
    func testForkReferenceExcludesBodiesFromOperationsAndCheckpoint() throws {
        var sizes: [(Int,Int)] = []
        for bytes in [16,4 * 1024 * 1024] {
            var row = ChatMessage(role:"user",content:[textBlock("SEED_BODY_ONLY_" + String(repeating:"x",count:bytes))])
            row.id = "seed-row"
            row = SubagentCodexContract.inherited(row,from:"parent",cutoff:row.id)
            let seed = AgentForkSeed(from:"parent",cutoffEntryID:row.id,messages:[row])
            var state = SubagentJournalState(), operationBytes = 0
            for index in 0..<4 {
                var origin = subagentFixtureOrigin(); origin.taskName = "/root/audit_\(index)"; origin.forkTurns = "all"
                origin.link.childSessionID = "child-\(index)"; origin.link.delegationID = "delegation-\(index)"; origin.link.call.toolCallID = "call-\(index)"
                let plan = SubagentPlan(origin:origin,task:"Task",resultMessageID:"receipt-\(index)",forkSeed:seed)
                var turn = AgentChildTurn(childID:origin.link.childSessionID,turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input-\(index)",task:plan.task,call:origin.link.call)
                turn.taskName = origin.taskName; turn.forkTurns = "all"
                let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:["version":4,"output":"accepted"],plan:plan,turn:turn,epoch:"epoch",acceptedAt:123)
                let accepted: JSON = ["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":try subagentJSON(op)]
                operationBytes = accepted.encoded().utf8.count
                XCTAssertLessThan(operationBytes,16384)
                XCTAssertFalse(accepted.encoded().contains("SEED_BODY_ONLY_"))
                try state.consume(accepted,sessionID:"parent")
            }
            let helper = AgentSession.checkpointHelper(spend:SessionSpend(),spendTracked:true,failedCompactionFingerprint:nil,contextRecovery:[:],compactionState:[:],parentInfo:[:],presentationOrdinal:0,subagents:state).encoded()
            XCTAssertFalse(helper.contains("SEED_BODY_ONLY_"))
            sizes.append((operationBytes,helper.utf8.count))
            print("F1 SIZE context=\(bytes) spawns=4 operation=\(operationBytes) helper=\(helper.utf8.count)")
        }
        XCTAssertEqual(sizes[0].0,sizes[1].0); XCTAssertEqual(sizes[0].1,sizes[1].1)
    }

    func testForkPublicationChecksReferenceOrderAndRoundTripDigest() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let messages = ["a","b"].map { id in
            var row = ChatMessage(role:"user",content:[textBlock(id)]); row.id = id
            return SubagentCodexContract.inherited(row,from:"parent",cutoff:"b")
        }
        let seed = AgentForkSeed(from:"parent",cutoffEntryID:"b",messages:messages)
        let digestRows = messages.map { JSON.array([JSON($0.id),.array($0.content),$0.nativeInherited ?? .null]) }
        XCTAssertEqual(seed.reference["digest"].text,sha256(Data(JSON.array(digestRows).encoded().utf8)))
        for variant in ["valid","order","content","reference","missing","consent"] {
            let url = root.appendingPathComponent(variant + ".jsonl")
            let child = try SessionJournal(url:url,id:variant,cwd:root,binding:fixtureProfile().binding,create:true)
            var saved = variant == "order" ? messages.reversed().map { $0 } : messages
            if variant == "content" { saved[0].content = [textBlock("changed")] }
            if variant == "missing" { saved.removeLast() }
            if variant == "consent" { saved[0].userInput = ["skills":[["id":"consent"]]] }
            for row in saved { try child.append(["type":"message","message":row.pi],id:row.id) }
            var reference = seed.reference
            if variant == "reference" { reference["digest"] = "changed" }
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.agentForkSeed),"data":reference])
            if variant == "valid" { XCTAssertNoThrow(try seed.requirePublished(at:url)) }
            else { XCTAssertThrowsError(try seed.requirePublished(at:url),variant) }
        }
    }

    func testForkPublicationStopsAtTheSeedInALongLivedChild() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let inherited = (0..<24).map { index in
            var row = ChatMessage(role:index.isMultiple(of:2) ? "user" : "assistant",content:[textBlock("Inherited \(index)")])
            row.id = "seed-\(index)"
            return SubagentCodexContract.inherited(row,from:"parent",cutoff:"seed-23")
        }
        let seed = AgentForkSeed(from:"parent",cutoffEntryID:"seed-23",messages:inherited)
        for turns in [0,10_000] {
            let url = root.appendingPathComponent("child-\(turns).jsonl")
            let child = try SessionJournal(url:url,id:"child-\(turns)",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
            try child.promoteToCodex(managedChild:true)
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(subagentFixtureOrigin())],flush:false)
            for row in inherited { try child.append(["type":"message","message":row.pi],id:row.id,flush:false) }
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(seed.ids.map(JSON.string))]],flush:false)
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.agentForkSeed),"data":seed.reference],flush:true)
            let prefixBytes = child.size
            for turn in 0..<turns {
                for role in ["user","assistant"] {
                    let row = ChatMessage(role:role,content:[textBlock("Turn \(turn). " + String(repeating:"Generated child history. ",count:12))])
                    try child.append(["type":"message","message":row.pi],id:row.id,flush:false)
                }
            }
            try child.synchronize()
            var milliseconds: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                try seed.requirePublished(at:url)
                milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            print("DEBUG fork publication turns=\(turns) prefixBytes=\(prefixBytes) journalBytes=\(child.size) medianMs=\(milliseconds.sorted()[2])")
            // Replay owns validation of later turns. A publication check must
            // stop at its intact prefix, even if the unrelated tail is torn.
            let tail = try FileHandle(forWritingTo:url); defer { try? tail.close() }
            try tail.seekToEnd(); try tail.write(contentsOf:Data("{torn later turn".utf8))
            XCTAssertNoThrow(try seed.requirePublished(at:url))
        }
    }

    func testForkRecoveryStillRejectsReusedInheritedIDsAfterTheSeed() {
        var inherited = ChatMessage(role:"user",content:[textBlock("Inherited")]); inherited.id = "seed"
        inherited = SubagentCodexContract.inherited(inherited,from:"parent",cutoff:inherited.id)
        let seed = AgentForkSeed(from:"parent",cutoffEntryID:inherited.id,messages:[inherited])
        var later = ChatMessage(role:"assistant",content:[textBlock("Later answer")])
        XCTAssertTrue(seed.complete(rows:[inherited,later],reference:seed.reference))
        later.id = inherited.id
        XCTAssertFalse(seed.complete(rows:[inherited,later],reference:seed.reference))
    }

    func testForkRecoveryUsesReopenedParentContextAndFailsClosedOnChangedOrMissingRows() async throws {
        for damage in ["none","changed","missing"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let profile = try fixtureProfile(), client = CodexProbeClient([answer("explicit later task")])
            var origin = subagentFixtureOrigin(); origin.taskName = "/root/audit"; origin.forkTurns = "all"
            var first = ChatMessage(role:"user",content:[textBlock("Original seed body")]); first.id = "first"; first.userInput = ["skills":[["id":"consent"]]]
            var last = ChatMessage(role:"assistant",content:[textBlock("Complete boundary")]); last.id = "last"
            let inherited = [first,last].map { SubagentCodexContract.inherited($0,from:"parent",cutoff:last.id) }
            let seed = AgentForkSeed(from:"parent",cutoffEntryID:last.id,messages:inherited)
            let plan = SubagentPlan(origin:origin,task:"Do not replay",resultMessageID:"receipt",forkSeed:seed)
            var turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
            turn.taskName = origin.taskName; turn.forkTurns = "all"
            let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:["version":4,"output":"accepted"],plan:plan,turn:turn,epoch:"epoch")
            let path = root.appendingPathComponent("parent.jsonl"), childPath = root.appendingPathComponent("child.jsonl")
            do {
                let parent = try SessionJournal(url:path,id:"parent",cwd:root,binding:profile.binding,create:true)
                try parent.promoteToCodex(managedChild:false)
                if damage == "changed" { first.content = [textBlock("Changed seed body")] }
                for row in damage == "missing" ? [last] : [first,last] { try parent.append(["type":"message","message":row.pi],id:row.id) }
                let assistant = ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(origin.link.call.toolCallID),"name":"spawn_agent","arguments":["task_name":"audit","message":"Do not replay"]]])
                try parent.append(["type":"message","message":assistant.pi],id:origin.link.call.assistantMessageID)
                try parent.append(["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":subagentJSON(op)])
                let child = try SessionJournal(url:childPath,id:"child",cwd:root,binding:profile.binding,create:true,managedChild:true)
                try child.promoteToCodex(managedChild:true)
                try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(origin)])
                try child.append(["type":"message","message":inherited[0].pi],id:inherited[0].id)
            }
            let parent = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path.path)
            let state = await parent.agentState(); XCTAssertEqual(state.latest("child")?.status,.notExecuted)
            let before = await client.requests.count; XCTAssertEqual(before,0,"Opening never executes turn 1")
            let coordinator = AgentSteeringCoordinator()
            await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
            let call = ToolCall(id:"follow",name:"followup_task",arguments:["target":"audit","message":"Explicit later task"])
            let key = try await parent.agentFixtureCall(call,newTask:true)
            if damage == "none" {
                XCTAssertNoThrow(try seed.requirePublished(at:childPath))
                _ = try await coordinator.prepare(call,key:key,parent:parent)
                try await eventually { await parent.agentState().messages["result:child:2"] != nil }
                let requests = await client.requests
                XCTAssertEqual(requests.count,1); XCTAssertEqual(requests.first?.filter { $0.nativeInherited != nil }.map(\.id),seed.reference["ids"].list.compactMap(\.text))
                XCTAssertTrue(requests.first?.filter { $0.nativeInherited != nil }.allSatisfy { $0.userInput == nil } == true)
            } else {
                XCTAssertThrowsError(try seed.requirePublished(at:childPath))
                do { _ = try await coordinator.prepare(call,key:key,parent:parent); XCTFail("Damaged parent enabled follow-up: " + damage) }
                catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_fork_publication") }
                let requests = await client.requests.count; XCTAssertEqual(requests,0)
                let latest = await parent.agentState().latest("child"); XCTAssertEqual(latest?.turn,1)
            }
            await coordinator.drain(); await parent.close()
        }
    }

    func testV3NamesAdoptOnceWithLifetimeUniquenessAndCheckpointReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile(), client = AccountedAgentScript([answer("first"),answer("second")]), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator(),codex:false); await parent.enableAgentSteering(coordinator)
        for index in 0..<2 {
            let call = ToolCall(id:"old-\(index)",name:"subagent_start",arguments:["task":"Audit journal!","mode":"background"])
            let key = try await parent.agentFixtureCall(call,newTask:index == 0)
            let result = try await coordinator.prepare(call,key:key,parent:parent), child = result["child_id"].text!
            try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
        }
        await coordinator.drain()
        let before = try Data(contentsOf:root.appendingPathComponent("parent.jsonl"))
        await parent.enableAgentSteering(coordinator,codex:true)
        let list = ToolCall(id:"list",name:"list_agents",arguments:[:]), key = try await parent.agentFixtureCall(list,newTask:true)
        let receipt = try await coordinator.prepare(list,key:key,parent:parent)
        let values = try JSON.parse(Data(receipt["output"].text!.utf8))["agents"].list
        XCTAssertEqual(values.compactMap { $0["agent_name"].text },["/root","/root/audit_journal","/root/audit_journal_2"])
        let names = await parent.agentState().names
        try await parent.adoptCodexNames()
        let marker = await parent.journal?.markerKind; XCTAssertEqual(marker,JournalRecordKind.codexMarker)
        let call = ToolCall(id:"duplicate",name:"spawn_agent",arguments:["task_name":"audit_journal","message":"Must retain old name"])
        let duplicateKey = try await parent.agentFixtureCall(call)
        do { _ = try await coordinator.prepare(call,key:duplicateKey,parent:parent); XCTFail("Reused a lifetime name") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"agent_name_taken") }
        await parent.close()
        let rows = try String(contentsOf:root.appendingPathComponent("parent.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(rows.filter { $0["customType"].text == JournalRecordKind.agentNames }.count,1)
        let oldRows = try String(decoding:before,as:UTF8.self).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }.filter { $0["type"].text == "message" }
        XCTAssertTrue(oldRows.allSatisfy { rows.contains($0) },"Adoption preserves v3 message bytes and identities")
        for removeCheckpoint in [false,true] {
            if removeCheckpoint { try? FileManager.default.removeItem(at:JournalCheckpoint.url(for:root.appendingPathComponent("parent.jsonl"))) }
            let reopened = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:root.appendingPathComponent("parent.jsonl").path)
            let restored = await reopened.agentState().names
            XCTAssertEqual(restored,names)
            await reopened.close()
        }
        let requests = await client.requests; XCTAssertEqual(requests.count,2,"Reopening never replays accepted work")
    }
    func testPartialForkPublicationRecoversNotExecutedAndNoConsent() throws {
        for stage in ["missing","partial","complete"] {
            let published = stage == "complete"
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let profile = try fixtureProfile()
            var origin = subagentFixtureOrigin(); origin.taskName = "/root/audit"; origin.forkTurns = "all"
            var inherited = ChatMessage(role:"user",content:[textBlock("History")]); inherited.userInput = ["skills":[["id":"selection"]]]
            inherited = SubagentCodexContract.inherited(inherited,from:"parent",cutoff:inherited.id)
            let seed = AgentForkSeed(from:"parent",cutoffEntryID:inherited.id,messages:[inherited])
            let plan = SubagentPlan(origin:origin,task:"Do not replay",resultMessageID:"receipt",forkSeed:seed)
            var turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
            turn.taskName = origin.taskName; turn.forkTurns = "all"
            let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:["version":4,"output":"accepted"],plan:plan,turn:turn,epoch:"epoch")
            let parent = try SessionJournal(url:root.appendingPathComponent("parent.jsonl"),id:"parent",cwd:root,binding:profile.binding,create:true)
            try parent.promoteToCodex(managedChild:false)
            var child: SessionJournal?
            if stage != "missing" {
            child = try SessionJournal(url:root.appendingPathComponent("child.jsonl"),id:"child",cwd:root,binding:profile.binding,create:true,managedChild:true)
            try child!.promoteToCodex(managedChild:true)
            try child!.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(origin)])
            try child!.append(["type":"message","message":inherited.pi],id:inherited.id)
            if published { try child!.append(["type":"custom","customType":JSON(JournalRecordKind.agentForkSeed),"data":seed.reference],flush:true) }
            child = nil
            }
            if published { XCTAssertNoThrow(try seed.requirePublished(at:root.appendingPathComponent("child.jsonl"))) }
            else { XCTAssertThrowsError(try seed.requirePublished(at:root.appendingPathComponent("child.jsonl"))) }
            var state = SubagentJournalState(), accounting = AttemptAccounting(), spend = SessionSpend()
            let accepted: JSON = ["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":try subagentJSON(op)]
            try state.consume(accepted,sessionID:"parent"); try parent.append(accepted)
            try AgentFamilyRecovery.recover(state:&state,parent:parent,owner:"parent",directory:root,accounting:&accounting,spend:&spend,costPaused:!published,context:[inherited, spawningRow(origin)])
            XCTAssertEqual(state.family?.latest("child")?.status,.notExecuted,"Partial publication cannot become resumable work even across a cost pause")
            XCTAssertEqual(state.family?.messages["result:child:1"]?.type,"FINAL_ANSWER")
            XCTAssertEqual(state.family?.names?["child"],"/root/audit")
            try AgentFamilyRecovery.recover(state:&state,parent:parent,owner:"parent",directory:root,accounting:&accounting,spend:&spend)
            XCTAssertEqual(state.family?.messages.count,1)
            let reader = try JournalRecordReader(root.appendingPathComponent("child.jsonl"))
            var reference: JSON?
            while let row = try reader.next() { if row["customType"].text == JournalRecordKind.agentForkSeed { reference = row["data"] } }
            XCTAssertEqual(reference,seed.reference,"Recovery completes publication for a later explicit follow-up, without rerunning turn 1")
        }
    }
    func testLateMirrorsKeepInterruptNotesAndUndeliveredTasksStayTyped() throws {
        let origin = subagentFixtureOrigin()
        var turn = AgentChildTurn(childID:"child",turn:1,executionID:"run",parentExecutionID:"owner",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:"Task",call:origin.link.call)
        turn.taskName = "/root/audit"
        var state = AgentFamilyState(ownerID:"parent")
        state.turns[turn.id] = turn
        var stopped = turn; stopped.interruptedBy = "the user"
        try state.consume(["customType":JSON(JournalRecordKind.agentTurnState),"data":subagentJSON(stopped)])
        turn.status = .running
        try state.consume(["customType":JSON(JournalRecordKind.agentTurnState),"data":subagentJSON(turn)])
        XCTAssertEqual(state.latest("child")?.interruptedBy,"the user")
        var task = AgentFamilyMessage(id:"internal-message-id",sequence:1,childID:"child",turn:1,author:"subagent",kind:"steer",text:"Task",task:"Task",epoch:"epoch")
        task.type = "NEW_TASK"; task.sender = "/root/peer"; task.recipient = "/root/audit"; task.recipientChildID = "child"
        let notice = AgentFamilyMessage.undelivered(task,sequence:2,legacyText:"internal-message-id")
        XCTAssertEqual(notice.deliveryEvent?.type,"MESSAGE")
        XCTAssertEqual(notice.deliveryEvent?.sender,"/root/audit"); XCTAssertEqual(notice.deliveryEvent?.recipient,"/root")
        XCTAssertFalse(notice.text.contains("internal-message-id"))
    }
    func testInterruptOfNamedIdleV2AgentSucceedsWithoutAdoptingATurn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript([answer("Legacy answer")])
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator(),steering:false)
        let old = ToolCall(id:"old",name:"subagent",arguments:["task":"Legacy audit"])
        _ = try await parent.agentFixtureCall(old,newTask:true); try await parent.runToolBatch([old])
        let coordinator = AgentSteeringCoordinator(); await parent.enableAgentSteering(coordinator,codex:true)
        let call = ToolCall(id:"stop",name:"interrupt_agent",arguments:["target":"legacy_audit"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        let result = try await coordinator.prepare(call,key:key,parent:parent)
        XCTAssertEqual(result["output"].text,"{\"previous_status\":\"idle\"}")
        let state = await parent.agentState(); XCTAssertTrue(state.turns.isEmpty)
        let requests = await client.requests; XCTAssertEqual(requests.count,1)
        await parent.close()
    }
    func testWholeResultValidityBoundAndFailurePayloads() throws {
        var origin = subagentFixtureOrigin(); origin.taskName = "/root/audit"
        let plan = SubagentPlan(origin:origin,task:"Task",resultMessageID:"receipt")
        var turn = AgentChildTurn(childID:"child",turn:2,executionID:"run",parentExecutionID:"owner",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
        turn.taskName = origin.taskName
        for status in [SubagentStatus.completed,.outputLimited,.failed,.notExecuted,.cancelled,.interrupted] {
            turn.status = status; turn.interruptedBy = status == .cancelled ? "the user" : status == .interrupted ? "/root/peer" : nil
            turn.result = SubagentToolResult(plan:plan,status:status,text:String(repeating:"é",count:600000),error:status == .failed ? AgentError("fixture","Failure") : nil,textLimit:1048576)
            turn.normalizeResult()
            let event = AgentFamilyMessage.resultEvent(turn,task:"Task",sequence:1)
            XCTAssertEqual(event.type,"FINAL_ANSWER"); XCTAssertEqual(event.recipient,"/root"); XCTAssertEqual(event.turn,2)
            if status == .completed { XCTAssertTrue(event.text.utf8.count <= 1048576); XCTAssertTrue(event.text.contains("truncated")) }
            if status == .outputLimited { XCTAssertTrue(event.text.hasSuffix("(The answer stopped at the model's output limit.)")) }
            if status == .failed { XCTAssertTrue(event.text.contains("use followup_task")) }
            if status == .cancelled { XCTAssertEqual(event.text,"Agent stopped by the user.") }
            if status == .interrupted { XCTAssertEqual(event.text,"Agent interrupted by /root/peer.") }
        }
    }
}

private func spawningRow(_ origin: SubagentOrigin) -> ChatMessage {
    var row = ChatMessage(role:"assistant",content:[]); row.id = origin.link.call.assistantMessageID; return row
}
