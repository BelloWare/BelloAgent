import Foundation
import XCTest
@testable import PiAgentCore

enum CheckpointParityCorpus {
    static func generate(in root: URL) async throws -> [URL] {
        var files: [URL] = []
        for variant in 0..<4 {
            let directory = root.appendingPathComponent("turns-\(variant)")
            try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
            let profile = try fixtureProfile(), resources = Resources(cwd:directory, home:directory)
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            let replies = [toolReply(["first"])] + (0..<12).map { answer("Answer \(variant)-\($0) " + String(repeating:"generated evidence 雪\n", count:80+variant)) }
            let session = try AgentSession(id:"parent", profile:profile, apiKey:"synthetic-only", cwd:directory, directory:directory,
                readOnly:true, resources:resources, client:ScriptClient(replies), tools:RecordingTools(), traces:TraceStore(),
                autoCompaction:false, compactionPolicy:policy)
            func send(_ id: String) async throws {
                _ = try await session.submit(Submission(commandID:id, turnID:id, text:"Question \(id)"), steer:false)
                try await eventually { !(await session.isRunning) }
            }
            try await send("t0")
            try await session.parityContextAnchor()
            try await send("t1")
            _ = try await session.edit(fromMessageID:"t1", input:Submission(commandID:"edit", turnID:"edited", text:"Edited question"))
            try await eventually { !(await session.isRunning) }
            try await send("t2")
            try await session.compact(commandID:"compact")
            try await eventually { !(await session.isRunning) }
            try await send("t3")
            let end = try await session.fork(to:"fork-end")
            let first = await session.history.first { $0.role == "assistant" && $0.kind == nil && !$0.content.contains(where:{ $0["type"].text == "toolCall" }) }?.id
            let early = try await session.fork(to:"fork-early", at:try XCTUnwrap(first))
            for fork in [end,early] { files.append(URL(fileURLWithPath:try XCTUnwrap(fork["path"].text))) }
            let seed = await session.sideSeed()
            let side = try AgentSession(id:"side", profile:profile, apiKey:"synthetic-only", cwd:directory, directory:directory,
                readOnly:true, resources:resources, client:ScriptClient([answer("Bound side result")]), tools:RecordingTools(),
                traces:TraceStore(), seed:seed.messages, parent:seed.info, autoCompaction:false)
            try await side.bindSideBudget(to:session)
            let saved = try await side.preserveSide()
            _ = try await side.submit(Submission(commandID:"side-turn", turnID:"side-turn", text:"Bound side question"), steer:false)
            try await eventually { !(await side.isRunning) }
            await side.close(); await session.close()
            files.append(URL(fileURLWithPath:try XCTUnwrap(saved["path"].text)))
            let parent = directory.appendingPathComponent("parent.jsonl")
            do {
                let journal = try SessionJournal(url:parent,id:"parent",cwd:directory,binding:profile.binding,create:false)
                var raw = profile.raw; raw["modelId"] = JSON("rebound-\(variant)")
                try journal.rebind(to:Profile(raw).binding)
                try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.state),
                    "data":["active":false,"runStatus":"idle","queue":[],"steering":[],"commands":[],CommandReceipts.deltaKey:true]])
            }
            files.append(parent)
            files.append(try family(in:root.appendingPathComponent("family-\(variant)"), variant:variant))
        }
        return files
    }

    private static func family(in root: URL, variant: Int) throws -> URL {
        try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true)
        let fixture = try RefreshJournalFixture(root:root,profile:fixtureProfile(),cuts:true), journal = fixture.journal
        func custom(_ kind: String, _ data: JSON) throws {
            try journal.append(["type":"custom","customType":JSON(kind),"ownerID":"refresh","data":data])
        }
        func settled() throws { try fixture.state(RefreshJournalFixture.settledState) }
        try custom(JournalRecordKind.context,["ids":["turn","answer"]]); try settled()
        let origin = subagentFixtureOrigin(child:"child-\(variant)",parent:"refresh")
        let plan = SubagentPlan(origin:origin,task:"Generated task",resultMessageID:"delegated-result")
        var turn = AgentChildTurn(childID:origin.link.childSessionID,turn:1,executionID:"child-execution",
            parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"child-input",task:"Generated task",call:origin.link.call)
        let operation = AgentOperation(key:origin.link.call,digest:"generated",receipt:["version":4,"accepted":true],plan:plan,
            turn:turn,epoch:"epoch",acceptedAt:123)
        try custom(JournalRecordKind.familyRun,subagentJSON(AgentFamilyRun(epoch:"epoch")))
        try custom(JournalRecordKind.agentOperation,subagentJSON(operation)); try settled()
        let result = SubagentToolResult(plan:plan,status:.completed,text:"Child terminal result",messageIDs:["child-answer"],began:true)
        turn.status = .completed; turn.result = result
        try custom(JournalRecordKind.agentTerminal,subagentJSON(turn)); try settled()
        let message = AgentFamilyMessage(id:"mail",sequence:1,childID:turn.childID,turn:1,author:"subagent",kind:"message",
            text:"Generated mail",task:"Task",epoch:"epoch",type:"MESSAGE",sender:"/root/child",recipient:"/root",senderChildID:turn.childID)
        try custom(JournalRecordKind.agentMessage,subagentJSON(message)); try settled()
        var delivery = AgentDelivery(rowID:"delivered-mail",recipientID:"refresh",eventIDs:["mail"],payload:"Generated mail")
        try custom(JournalRecordKind.agentDelivery,subagentJSON(delivery))
        delivery.committed = true
        try custom(JournalRecordKind.agentDelivery,subagentJSON(delivery)); try settled()
        // Exercise both completed contributions and a permit that never sent.
        let scope = RequestScope(sourceSessionID:"refresh",budgetOwnerSessionID:"refresh",turnID:"turn",executionID:"execution",purpose:"turn",ownerGeneration:0,delegation:nil)
        var admission: JSON = ["attemptId":"never-sent","sourceSessionId":"refresh","budgetOwnerSessionId":"refresh","purpose":"turn",
            "state":"admitted","scope":try subagentJSON(scope),"accountingRevision":3]
        try custom(JournalRecordKind.budgetAttempt,admission); try settled()
        admission["state"] = "not_dispatched"; admission["accountingRevision"] = 4
        try custom(JournalRecordKind.budgetAttempt,admission); try settled()
        try fixture.appendCut(projected:variant-1); try settled()
        if variant == 3 {
            try custom(JournalRecordKind.contextRecovery,["status":"settled","attempts":1])
            try custom(JournalRecordKind.compactionFailure,["fingerprint":"generated-fingerprint"])
            try settled()
            // The branch later lies before the rows loaded from compaction.
            try journal.append(["type":"branch","fromMessageId":"turn","keptIds":["turn"]],id:"edit-marker")
            try journal.append(["type":"message","message":ChatMessage(role:"user",content:[textBlock("After edit")]).pi],id:"new-turn")
            try journal.append(["type":"compaction","summary":"Generated summary","nativeKeptIDs":["new-turn"],"tokensBefore":9000],id:"summary")
            try settled()
            try custom(JournalRecordKind.context,["ids":["summary","new-turn"]]); try settled()
        }
        return fixture.url
    }
}

private extension AgentSession {
    func parityContextAnchor() throws {
        try journal?.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(context.map { JSON($0.id) })]])
        try persistState(active:false,durable:true)
    }
}
