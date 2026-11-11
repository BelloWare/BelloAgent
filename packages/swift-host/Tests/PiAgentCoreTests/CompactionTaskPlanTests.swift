import XCTest
@testable import PiAgentCore

// The planner's rules without a session (owner, 2026-11-11: "remove the cap
// directly"), and what must not change for checkpoints written before them:
// "It has to be backward compatible".

private func user(_ id: String, _ text: String = "input", root: String? = nil) -> ChatMessage {
    var message=ChatMessage(role:"user",content:[textBlock(text)]); message.id=id; message.taskRootID=root ?? id; return message
}
private func mail(_ id: String, root: String) -> ChatMessage {
    var message=user(id,"Agent mail",root:root); message.nativeAgentDelivery=["version":1]; message.inputLane="agent"; message.kind="agent_message"; return message
}
private func reply(_ id: String, _ text: String = "Answer.", root: String) -> ChatMessage {
    var message=ChatMessage(role:"assistant",content:[textBlock(text)]); message.id=id; message.taskRootID=root; return message
}
private func batch(_ id: String, results: Int = 1, chars: Int = 400, root: String) -> [ChatMessage] {
    var call=ChatMessage(role:"assistant",content:(0..<results).map { ["type":"toolCall","id":JSON("\(id)-\($0)"),"name":"read","arguments":[:]] })
    call.id=id; call.taskRootID=root
    return [call]+(0..<results).map { n in
        var result=ChatMessage(role:"toolResult",content:[textBlock(String(repeating:"r",count:chars))])
        result.id="\(id)-result-\(n)"; result.toolCallId="\(id)-\(n)"; result.toolName="read"; result.taskRootID=root
        return result
    }
}
private func kept(_ source: CompactionPlanner.Source, _ cut: Int) -> [String] { CompactionPlanner.plan(source,cut:cut).keptMessages.map(\.id) }

final class CompactionTaskPlanTests: HelperTestCase {
    private let earlier=[user("old","Earlier task."),reply("old-reply",root:"old")]

    func testAWorkingTaskIsItsRootsRowsWhateverJoinedIt() throws {
        var context=earlier+[user("task","Port the parser.")]
        context += batch("a",root:"task"); context.append(user("steer","Keep the old entry point.",root:"task"))
        context += batch("b",root:"task"); context.append(mail("mail",root:"task")); context += batch("c",results:2,root:"task")
        let source=try CompactionPlanner.source(context:context,taskRoot:"task")
        XCTAssertTrue(source.inProgress)
        XCTAssertEqual(source.whole,2,"The task starts at its request; steering and mail do not start another")
        XCTAssertEqual(source.required,7,"The batch awaiting its reply")
        XCTAssertEqual(source.protectedIDs,["task","steer"],"The owner's inputs; mail is the task's material, not a request")
        XCTAssertEqual(kept(source,source.whole),Array(context.dropFirst(2).map(\.id)),"Every row of the task, in order")
        XCTAssertEqual(kept(source,source.required),["task","steer","c","c-result-0","c-result-1"],"The least a compaction may keep")
        XCTAssertEqual(CompactionPlanner.plan(source,cut:source.whole).summarized.map(\.id),["old","old-reply"])
    }

    /// A parent waiting for its family has an answer in place and is still
    /// working: the task's lifecycle says so, not the look of its last row.
    func testAnAnswerInPlaceDoesNotEndATaskThatIsOpen() throws {
        var context=earlier+[user("task","Delegate it.")]; context += batch("spawn",root:"task"); context.append(reply("waiting","Waiting for the agents.",root:"task"))
        let waiting=try CompactionPlanner.source(context:context,taskRoot:"task")
        XCTAssertTrue(waiting.inProgress); XCTAssertEqual(waiting.whole,2); XCTAssertEqual(waiting.required,5,"Nothing awaits a reply")
        // Mail delivered after it is what the next request answers.
        let woken=try CompactionPlanner.source(context:context+[mail("mail",root:"task")],taskRoot:"task")
        XCTAssertEqual(woken.required,5); XCTAssertEqual(kept(woken,woken.required),["task","mail"])
        // Idle, its last task finished: the exchange stays, not its tool rounds.
        let idle=try CompactionPlanner.source(context:context,taskRoot:"task",taskOpen:false)
        XCTAssertFalse(idle.inProgress); XCTAssertEqual(kept(idle,idle.whole),["task","waiting"])
    }

    func testAtSendTheExchangeBeforeTheMessageStays() throws {
        var context=earlier+[user("prev","Give me two options.")]; context += batch("look",chars:40_000,root:"prev")
        context += [user("prev-steer","Short ones.",root:"prev"),mail("prev-mail",root:"prev"),reply("options","1) A 2) B",root:"prev"),user("task","Yes, do the second one.")]
        let source=try CompactionPlanner.source(context:context,taskRoot:"task")
        XCTAssertFalse(source.inProgress)
        XCTAssertEqual(kept(source,source.whole),["prev","prev-steer","options","task"],"The earlier request and its steering, the reply itself, the new message")
        XCTAssertEqual(source.required,source.whole)
        XCTAssertEqual(Set(CompactionPlanner.plan(source,cut:source.whole).protected.map(\.role)),["user"],"The reply is an ordinary retained row, never a protected input")
        // A task that ended without a reply leaves its inputs only.
        let stopped=try CompactionPlanner.source(context:Array(context.prefix(5))+[user("task","Go on.")],taskRoot:"task")
        XCTAssertEqual(kept(stopped,stopped.whole),["prev","task"])
        // Several messages delivered together are one task.
        let two=try CompactionPlanner.source(context:context+[user("more","And the tests.",root:"task")],taskRoot:"task")
        XCTAssertEqual(kept(two,two.whole),["prev","prev-steer","options","task","more"])
    }

    func testASubAgentsTaskIsTheMailThatStartedIt() throws {
        var context=[user("inherited","The parent's request.")]; context[0].nativeInherited=["version":1]
        context.append(reply("inherited-reply",root:"inherited")); context.append(mail("task",root:"task")); context += batch("a",root:"task")
        let source=try CompactionPlanner.source(context:context,taskRoot:"task")
        XCTAssertEqual(source.protectedIDs,["task"]); XCTAssertEqual(kept(source,source.whole),["task","a","a-result-0"])
        XCTAssertNotNil(CompactionPlanner.plan(source,cut:source.required).protected.first?.nativeAgentDelivery,"Kept as the agent's, not made the owner's")
    }

    /// An old context without task metadata: the surviving body is the task,
    /// and nothing is guessed from its last user row.
    func testAContextWithoutTaskMetadataIsKeptAndFallsBack() throws {
        var context=[ChatMessage(role:"user",content:[textBlock("One.")]),ChatMessage(role:"assistant",content:[textBlock("Done.")]),ChatMessage(role:"user",content:[textBlock("Two.")])]
        for index in context.indices { context[index].id="m\(index)" }
        context += batch("a",root:"").map { var row=$0; row.taskRootID=nil; return row }
        let source=try CompactionPlanner.source(context:context,taskRoot:nil)
        XCTAssertEqual(source.whole,0); XCTAssertEqual(source.required,3); XCTAssertFalse(source.inProgress)
        XCTAssertEqual(CompactionPlanner.fallbackCut(source,target:0),3)
        let unknown=try CompactionPlanner.source(context:context,taskRoot:"gone")
        XCTAssertEqual(unknown.whole,0); XCTAssertEqual(unknown.required,3)
    }

    func testSkillAndPermissionCarriersStay() throws {
        var skilled=user("task","Use the skill."); skilled.userInput=["version":1,"skills":[["id":"s"]]]
        var noted=user("noted","Earlier.",root:"old"); noted.contextNote=ContextNote(kind:"side-read-only",text:"Read-only side.")
        var context=[noted,reply("old-reply",root:"old"),skilled]; context += batch("a",root:"task"); context += batch("b",root:"task")
        let source=try CompactionPlanner.source(context:context,taskRoot:"task")
        XCTAssertEqual(source.protectedIDs,["task","noted"])
        XCTAssertEqual(kept(source,source.required),["noted","task","b","b-result-0"])
    }

    /// The fallback takes whole groups, newest first, in one pass; what is
    /// required stays whatever the target.
    func testFallbackAddsNewestWholeGroupsWithinItsTarget() throws {
        var context=earlier+[user("task","Port the parser.")]
        for round in 0..<6 { context += batch("r\(round)",chars:4_000,root:"task") }
        let source=try CompactionPlanner.source(context:context,taskRoot:"task")
        XCTAssertEqual(source.whole,2); XCTAssertEqual(source.required,8)
        XCTAssertEqual(CompactionPlanner.fallbackCut(source,target:0),8,"Required material passes any target")
        XCTAssertEqual(CompactionPlanner.fallbackCut(source,target:3_100),6,"Three rounds of 1,000 tokens and the request")
        XCTAssertEqual(CompactionPlanner.fallbackCut(source,target:1_000_000),2,"Never past the task: earlier tasks are the summary")
        XCTAssertEqual(kept(source,6),["task","r3","r3-result-0","r4","r4-result-0","r5","r5-result-0"])
    }

    func testThresholdsFollowTheUsableInput() throws {
        func profile(_ window: Int, budget: Int) throws -> Profile {
            var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window); raw["maxOutputTokens"]=JSON(budget); raw["modelOutputLimit"]=100_000
            return try Profile(raw)
        }
        let policy=CompactionPolicy()
        // U = W - M - max(O, G + I); R = min(max(16,384, 15% of W), U / 4).
        let medium=try profile(128_000,budget:8_192), usable=try policy.usable(profile:medium,instructionTokens:500)
        XCTAssertEqual(usable,128_000-1_024-(16_384+500))
        XCTAssertEqual(policy.growthReserve(profile:medium,usable:usable),19_200)
        XCTAssertEqual(try policy.trigger(profile:medium,instructionTokens:500),90_892)
        XCTAssertEqual(try policy.trigger(profile:medium,instructionTokens:500,taskStart:true),77_064)
        XCTAssertEqual(try policy.usable(profile:try profile(128_000,budget:64_000),instructionTokens:500),128_000-1_024-64_000,"Whichever needs more output room")
        // Pi's reserve is the floor; a small window keeps three quarters of what is usable.
        let hundred=try profile(100_000,budget:4_096), small=try profile(16_000,budget:512)
        XCTAssertEqual(policy.growthReserve(profile:hundred,usable:try policy.usable(profile:hundred,instructionTokens:500)),16_384)
        let room=try policy.usable(profile:small,instructionTokens:500)
        XCTAssertEqual(room,16_000-160-4_500); XCTAssertEqual(try policy.trigger(profile:small,instructionTokens:500),room-room/4)
        XCTAssertThrowsError(try policy.trigger(profile:medium,instructionTokens:Int.max)); XCTAssertThrowsError(try policy.trigger(profile:medium,instructionTokens:-1))
        var raw=try fixtureProfile().raw; raw["contextWindow"]=8_000; raw["maxOutputTokens"]=7_950
        XCTAssertThrowsError(try policy.trigger(profile:Profile(raw),instructionTokens:500),"No usable input: compaction is unavailable")
    }

    /// A replacement can fit its token estimate and still pass the gateway's
    /// 32 MiB request limit: its bytes are checked as well.
    func testAReplacementIsMeasuredInBytesToo() throws {
        var frozen=(0..<4).flatMap { n in [user("old\(n)",String(repeating:"u",count:20_000)),reply("old\(n)-reply",String(repeating:"a",count:20_000),root:"old\(n)")] }
        frozen.append(user("task","Port the parser."))
        for round in 0..<6 { frozen += batch("r\(round)",chars:8_000,root:"task") }
        func plan(_ limit: Int) throws -> [String] {
            var policy=CompactionPolicy(); policy.maximumRequestBytes=limit
            return try CompactionPlanner.prepare(frozen:frozen,profile:fixtureProfile(),instructions:"Policy",definitions:[],sessionID:"s",cacheSessionID:"s",taskRoot:"task",policy:policy,
                                                 reason:"threshold",focus:nil).plan.keptMessages.map(\.id)
        }
        XCTAssertEqual(try plan(ProviderClient.maximumRequestBytes).count,13,"The whole task")
        XCTAssertThrowsError(try plan(100_000),"The whole task is 114 KB with its summary allowance, and the fallback keeps no less within 30%") { XCTAssertEqual(($0 as? AgentError)?.code,"compact_unavailable") }
    }

    // MARK: compatibility

    private func record(kept: [String], protected: [String]? = nil, source: [String], continuation: String? = nil, legacy: Bool = false) -> JSON {
        var record: JSON=["type":"compaction","id":"summary","summary":"Earlier work.","nativeKeptIDs":.array(kept.map { JSON($0) }),"tokensBefore":100]
        guard !legacy else { return record }
        var metadata: JSON=["version":2,"operationId":"op","sourceIDs":.array(source.map { JSON($0) }),"keptIDs":.array(kept.map { JSON($0) }),
                            "protectedIDs":.array((protected ?? []).map { JSON($0) }),"dependencyIDs":.array(source.map { JSON($0) }),"taskRootId":"task"]
        if let continuation { metadata["continuationText"]=JSON(continuation) }
        record["nativeCompactionVersion"]=2; record["nativeCompaction"]=metadata
        return record
    }
    private func item(_ summary: ChatMessage) -> String { ProviderClient.userContent(summary,images:false).first?["text"].text ?? "" }

    /// Checkpoints as earlier versions wrote them restore to the same rows
    /// and replay as the same bytes: nothing is planned again, and no
    /// framing is added to a record that has none.
    func testEarlierCheckpointsRestoreAndReplayUnchanged() throws {
        var context=[user("q0"),reply("a0",root:"q0"),user("task")]; context += batch("r0",root:"task"); context += batch("r1",root:"task")
        let ids=context.map(\.id), wrapper=ProviderClient.compactionSummaryPrefix+"Earlier work."+ProviderClient.compactionSummarySuffix
        // Before 0.1.64: no native metadata, a contiguous tail.
        let legacy=try CompactionCheckpoint.restore(record(kept:Array(ids.suffix(2)),source:ids,legacy:true),context:context)
        XCTAssertEqual(legacy.kept.map(\.id),["r1","r1-result-0"]); XCTAssertNil(legacy.summary.compaction?["version"].int)
        XCTAssertEqual(legacy.summary.text,CompactionCheckpoint.legacyReplayPrefix+"Earlier work."); XCTAssertEqual(item(legacy.summary),wrapper)
        // 0.1.64 to 0.1.135: version 2, a protected input ahead of the tail.
        let protected=try CompactionCheckpoint.restore(record(kept:["task","r1","r1-result-0"],protected:["task"],source:ids),context:context)
        XCTAssertEqual(protected.kept.map(\.id),["task","r1","r1-result-0"]); XCTAssertEqual(item(protected.summary),wrapper)
        XCTAssertEqual(protected.summary.compaction?["protectedIDs"].list.compactMap(\.text),["task"])
        // Retained groups need not be contiguous, only in order and whole.
        let scattered=try CompactionCheckpoint.restore(record(kept:["q0","r0","r0-result-0","r1","r1-result-0"],protected:["q0"],source:ids),context:context)
        XCTAssertEqual(scattered.kept.map(\.id),["q0","r0","r0-result-0","r1","r1-result-0"])
        // The contracts both readers check still refuse what they refused.
        for bad in [record(kept:["r1","r1-result-0","task"],protected:["task"],source:ids),record(kept:["a0","r1","r1-result-0"],protected:["a0"],source:ids),
                    record(kept:["r1-result-0","r1"],source:ids),record(kept:["r1","r1-result-0"],source:Array(ids.dropLast()))] {
            XCTAssertThrowsError(try CompactionCheckpoint.restore(bad,context:context)) { XCTAssertEqual(($0 as? AgentError)?.code,"session_damaged") }
        }
        // 0.1.136: the same version, one optional field, rendered after the wrapper.
        let framed=try CompactionCheckpoint.restore(record(kept:["task","r1","r1-result-0"],protected:["task"],source:ids,continuation:CompactionCheckpoint.continuationText),context:context)
        XCTAssertEqual(item(framed.summary),wrapper+"\n\n"+CompactionCheckpoint.continuationText)
        XCTAssertEqual(framed.summary.text,protected.summary.text,"The summary a later compaction reads is the summary alone")
        // A later compaction of a restored checkpoint treats its protected inputs as before.
        let later=try CompactionPlanner.source(context:[protected.summary]+protected.kept+batch("r2",root:"task"),taskRoot:"task")
        XCTAssertEqual(later.carried.map(\.id),["task"]); XCTAssertEqual(later.whole,0); XCTAssertEqual(later.newSince,1)
    }

    /// The published fixture journal (a 2026-09-30 build, a version-2
    /// checkpoint with no protected inputs) opens from its records as it did:
    /// the same context, pi's wrapper alone, and nothing suppressed.
    func testAnEarlierJournalReplaysWithNothingNew() throws {
        var repo=URL(fileURLWithPath:#filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let copy=root.appendingPathComponent("fork-clone.jsonl")
        try FileManager.default.copyItem(at:repo.appendingPathComponent("fixtures/native/fork-clone.jsonl"),to:copy)
        let profile=try fixtureProfile(), journal=try SessionJournal(url:copy,id:"fork-001",cwd:root,binding:profile.binding,create:false)
        let read=try AgentSession.replay(journal,url:copy,id:"fork-001",binding:profile.binding,spendTracked:false,resume:false)
        let summary=try XCTUnwrap(read.context.first)
        XCTAssertEqual(summary.kind,"compaction"); XCTAssertNil(summary.compaction?["continuationText"].text)
        XCTAssertEqual(item(summary),ProviderClient.compactionSummaryPrefix+"Summary of everything so far."+ProviderClient.compactionSummarySuffix)
        XCTAssertNil(read.suppressedCompactionTask); XCTAssertNil(read.failedCompactionFingerprint)
        // A failure record as 0.1.135 wrote it suppresses nothing; one with its task does.
        try journal.append(["type":"custom","customType":JSON(JournalRecordKind.compactionFailure),"data":["fingerprint":"abc"]],flush:true)
        var again=try AgentSession.replay(journal,url:copy,id:"fork-001",binding:profile.binding,spendTracked:false,resume:false)
        XCTAssertEqual(again.failedCompactionFingerprint,"abc"); XCTAssertNil(again.suppressedCompactionTask)
        try journal.append(["type":"custom","customType":JSON(JournalRecordKind.compactionFailure),"data":["fingerprint":"abc","taskRootId":"u3"]],flush:true)
        again=try AgentSession.replay(journal,url:copy,id:"fork-001",binding:profile.binding,spendTracked:false,resume:false)
        XCTAssertEqual(again.suppressedCompactionTask,"u3")
        XCTAssertEqual(again.context.map(\.id),read.context.map(\.id))
    }

    /// The same chat opened from its metadata file and from its whole
    /// journal: the framing and the suppressed task are in both.
    func testANewCheckpointOpensFromItsMetadataFileAsFromItsJournal() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let directory=root.appendingPathComponent("state")
        var seed=[user("q0",String(repeating:"u",count:40_000)),reply("a0",String(repeating:"a",count:40_000),root:"q0"),user("task","Port the parser.")]
        seed += batch("r0",chars:8_000,root:"task")
        func open(_ path: String?, client: ScriptClient, seed: [ChatMessage]? = nil) throws -> AgentSession {
            try AgentSession(id:"compat",profile:fixtureProfile(),apiKey:"synthetic",cwd:root,directory:directory,readOnly:true,resources:Resources(cwd:root,home:root),
                             client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path,seed:seed)
        }
        let s=try open(nil,client:ScriptClient([answer("Summary of the earlier task.")]),seed:seed)
        _=try await s.keep(whenFinished:false)
        try await s.compactContext(reason:"threshold"); await s.suppressAutomaticCompaction()
        try await s.persistState(); await s.refreshCheckpoint()
        let written=await s.context, path=await s.path, saved=try XCTUnwrap(path); await s.close()
        XCTAssertEqual(written.map(\.id).dropFirst(),["task","r0","r0-result-0"]); XCTAssertEqual(written.first?.compaction?["continuationText"].text,CompactionCheckpoint.continuationText)
        XCTAssertNotNil(JournalCheckpoint.read(for:URL(fileURLWithPath:saved)),"Opened from its metadata file")
        let quick=try open(saved,client:ScriptClient([])), fromFile=await quick.context, heldFile=await quick.suppressedCompactionTask; await quick.close()
        JournalCheckpoint.remove(for:URL(fileURLWithPath:saved))
        let whole=try open(saved,client:ScriptClient([])), fromJournal=await whole.context, heldJournal=await whole.suppressedCompactionTask; await whole.close()
        for restored in [fromFile,fromJournal] {
            XCTAssertEqual(restored.map(\.id),written.map(\.id)); XCTAssertEqual(restored.first?.compaction?["continuationText"],written.first?.compaction?["continuationText"])
            XCTAssertEqual(try ProviderClient.responsesInput(restored,instructions:"",profile:fixtureProfile()),try ProviderClient.responsesInput(written,instructions:"",profile:fixtureProfile()))
        }
        XCTAssertEqual(heldFile,"task"); XCTAssertEqual(heldJournal,"task")
    }
}
