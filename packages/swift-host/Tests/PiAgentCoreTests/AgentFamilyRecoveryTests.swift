import XCTest
@testable import PiAgentCore

final class AgentFamilyRecoveryTests: HelperTestCase {
    func testAcceptedStartReopensWithSameReceiptAndNeverExecutesChild() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile(), url = root.appendingPathComponent("parent.jsonl")
        let origin = subagentFixtureOrigin(), plan = SubagentPlan(origin:origin,task:"Do not replay",resultMessageID:"receipt")
        let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
        let receipt: JSON = ["version":3,"accepted":true,"child_id":"child","turn":1,"route":"start"]
        let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:receipt,plan:plan,turn:turn,epoch:"epoch")
        var journal: SessionJournal? = try SessionJournal(url:url,id:"parent",cwd:root,binding:profile.binding,create:true)
        try journal!.promoteToSteering(managedChild:false)
        var assistant = ChatMessage(role:"assistant",content:[["type":"toolCall","id":"call","name":"subagent_start","arguments":["task":"Do not replay","mode":"background"]]])
        assistant.id = "reply"; try journal!.append(["type":"message","message":assistant.pi],id:assistant.id)
        try journal!.append(["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":subagentJSON(op)])
        journal = nil
        let client = AccountedAgentScript([answer("Resume considers the saved outcome")])
        let parent = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:url.path)
        let state = await parent.agentState(), history = await parent.history, requests = await client.requests
        XCTAssertEqual(state.latest("child")?.status,.notExecuted)
        XCTAssertTrue(requests.isEmpty)
        let result = try XCTUnwrap(history.first { $0.toolCallId == "call" })
        XCTAssertEqual(try JSON.parse(Data(result.text.utf8))["child_id"].text,"child")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(state.messages.values.filter { $0.kind == "result" }.count,1)
        do { _ = try await parent.submit(Submission(commandID:"new",turnID:"new",text:"Requires v3"),steer:false); XCTFail("Disabled v3 executed a promoted family") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_steering_disabled") }
        do { _ = try await parent.continueRun(commandID:"resume"); XCTFail("Disabled v3 resumed a promoted family") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_steering_disabled") }
        await parent.close()
        let again = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:url.path)
        let second = await again.agentState(), secondHistory = await again.history
        XCTAssertEqual(second.messages.count,state.messages.count)
        XCTAssertEqual(secondHistory.filter { $0.toolCallId == "call" }.count,1)
        await again.close()
    }
}

extension AgentFamilyRecoveryTests {
    /// A reader Stop is durable before the child's terminal result. A crash
    /// during the family pause must not turn that Stop into resumable work.
    func testRecoveryKeepsExplicitlyStoppedChildrenOutOfThePausedQueue() throws {
        for status in [SubagentStatus.queued, .running, .stopping] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let origin = subagentFixtureOrigin(), plan = SubagentPlan(origin:origin,task:"Stopped work",resultMessageID:"receipt")
            var turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
            turn.status = status
            let profile = try fixtureProfile()
            let parent = try SessionJournal(url:root.appendingPathComponent("parent.jsonl"),id:"parent",cwd:root,binding:profile.binding,create:true)
            try parent.promoteToSteering(managedChild:false)
            var child: SessionJournal? = try SessionJournal(url:root.appendingPathComponent("child.jsonl"),id:"child",cwd:root,binding:profile.binding,create:true,managedChild:true)
            try child!.promoteToSteering(managedChild:true)
            try child!.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(origin)])
            let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:["accepted":true],plan:plan,turn:turn,epoch:"epoch")
            var state = SubagentJournalState(), accounting = AttemptAccounting(), spend = SessionSpend()
            let accepted: JSON = ["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":try subagentJSON(op)]
            try state.consume(accepted,sessionID:"parent"); try parent.append(accepted); try child!.append(accepted)
            child = nil
            let stopped: JSON = ["type":"custom","customType":JSON(JournalRecordKind.familyRun),"ownerID":"parent","data":try subagentJSON(AgentFamilyRun(epoch:"epoch",heldChildren:["child"]))]
            try state.consume(stopped,sessionID:"parent"); try parent.append(stopped,flush:true)
            try AgentFamilyRecovery.recover(state:&state,parent:parent,owner:"parent",directory:root,accounting:&accounting,spend:&spend,costPaused:true)
            let recovered = try XCTUnwrap(state.family?.latest("child"))
            XCTAssertEqual(recovered.status,status == .queued ? .notExecuted : .interrupted,"\(status): Stop survives the pause")
            XCTAssertNotNil(recovered.result)
            let reader = try JournalRecordReader(root.appendingPathComponent("child.jsonl"))
            var mirror = SubagentJournalState()
            while let row = try reader.next() { try mirror.consume(row,sessionID:"child") }
            XCTAssertEqual(mirror.family?.latest("child"),recovered)
            try AgentFamilyRecovery.recover(state:&state,parent:parent,owner:"parent",directory:root,accounting:&accounting,spend:&spend,costPaused:true)
            XCTAssertEqual(state.family?.messages.values.filter { $0.kind == "result" }.count,1,"One terminal report across repeated recovery")
        }
    }

    func testRecoveryMirrorsFailedPublicationAndPromotesQueuedChild() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let origin = subagentFixtureOrigin(), plan = SubagentPlan(origin:origin,task:"Never executed",resultMessageID:"receipt")
        var turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
        let profile = try fixtureProfile()
        let parent = try SessionJournal(url:root.appendingPathComponent("parent.jsonl"),id:"parent",cwd:root,binding:profile.binding,create:true)
        try parent.promoteToSteering(managedChild:false)
        var child: SessionJournal? = try SessionJournal(url:root.appendingPathComponent("child.jsonl"),id:"child",cwd:root,binding:profile.binding,create:true,managedChild:true)
        try child!.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(origin)])
        child = nil
        let op = AgentOperation(key:origin.link.call,digest:"digest",receipt:["accepted":true],plan:plan,turn:turn,epoch:"epoch")
        var state = SubagentJournalState(), accounting = AttemptAccounting(), spend = SessionSpend()
        let accepted: JSON = ["type":"custom","customType":JSON(JournalRecordKind.agentOperation),"ownerID":"parent","data":try subagentJSON(op)]
        try state.consume(accepted,sessionID:"parent"); try parent.append(accepted)
        turn.status = .notExecuted; turn.result = SubagentToolResult(plan:plan,status:.notExecuted); turn.normalizeResult()
        let terminal: JSON = ["type":"custom","customType":JSON(JournalRecordKind.agentTerminal),"ownerID":"parent","data":try subagentJSON(turn)]
        try state.consume(terminal,sessionID:"parent"); try parent.append(terminal)
        try AgentFamilyRecovery.recover(state:&state,parent:parent,owner:"parent",directory:root,accounting:&accounting,spend:&spend)
        let reader = try JournalRecordReader(root.appendingPathComponent("child.jsonl"))
        var restored = SubagentJournalState(), promoted = false
        while let row = try reader.next() {
            promoted = promoted || row["customType"].text == JournalRecordKind.steeringMarker
            try restored.consume(row,sessionID:"child")
        }
        XCTAssertTrue(promoted)
        XCTAssertEqual(restored.family?.latest("child"),turn)
        XCTAssertEqual(state.family?.messages.count,1)
    }

    func testBudgetAdmissionRefusesBeforeWritingAnyAttempt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        await owner.agentAdmissionAtLimitFixture()
        let lifecycle = try await owner.requestLifecycle(turnID:"turn",purpose:"turn")
        let hooks = try XCTUnwrap(lifecycle)
        do { _ = try await hooks.admitAttempt("must-not-admit"); XCTFail("Cost-limit admission guard was bypassed") }
        catch { XCTAssertEqual((error as? AgentError)?.code,AgentSession.costLimitCode) }
        let entries = await owner.accounting.attempts
        XCTAssertTrue(entries.isEmpty)
        await owner.close()
    }
}
extension AgentSession {
    func agentAdmissionAtLimitFixture() { familyBudgetEnabled = true; spend.usd = 1; costLimitUSD = 1 }
}
