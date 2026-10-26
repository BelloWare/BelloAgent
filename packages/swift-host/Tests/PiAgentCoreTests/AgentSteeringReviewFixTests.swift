import XCTest
@testable import PiAgentCore

final class AgentSteeringReviewFixTests: HelperTestCase {
    func testPromotionFencesReentrantAppendsAndPreservesTheChain() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let box = PromotionReentryBox()
        let journal = try SessionJournal(url:root.appendingPathComponent("parent.jsonl"),id:"parent",cwd:root,binding:fixtureProfile().binding,create:true,beforeSynchronize:{ box.appendDuringPromotion() })
        try journal.append(["type":"custom","customType":"fixture"],id:"before",flush:false)
        box.journal = journal
        try journal.promoteToSteering(managedChild:false)
        XCTAssertEqual(box.error,"subagent_promotion_busy")
        XCTAssertEqual(journal.head,"before","No reentrant append may escape the promotion fence")
        try journal.append(["type":"custom","customType":"fixture"],id:"after")
        XCTAssertEqual(journal.markerKind,JournalRecordKind.steeringMarker)
        XCTAssertEqual(journal.head,"after")
    }
    func testReplacementStartsHaveNoEpochAllowance() throws {
        var state = AgentFamilyState(ownerID:"parent")
        for index in 0..<100 {
            let op = replacement(index)
            try AgentMailboxPolicy.validate(op,state:state); try state.operation(op)
        }
        let restored = try JSONDecoder().decode(AgentFamilyState.self,from:subagentJSON(state).data())
        XCTAssertNoThrow(try AgentMailboxPolicy.validate(replacement(100),state:restored), "No cap on starts (owner, 2026-10-26)")
    }
    func testManyContinuationsStillStartAndSendWork() throws {
        var state = AgentFamilyState(ownerID:"parent"); state.run = AgentFamilyRun(epoch:"epoch",reportContinuations:500)
        XCTAssertNoThrow(try AgentMailboxPolicy.validate(replacement(0),state:state))
        let message = AgentFamilyMessage(id:"m",sequence:1,childID:"child",turn:1,author:"parent",kind:"steer",text:"Keep going",task:"Task",epoch:"epoch")
        let op = AgentOperation(key:.init(parentSessionID:"parent",assistantMessageID:"a",toolCallID:"send"),digest:"d",receipt:[:],message:message,epoch:"epoch")
        XCTAssertNoThrow(try AgentMailboxPolicy.validate(op,state:state))
    }
    func testResultOnlyDeliveryConsumesContinuationBeforePublishingContext() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent, coordinator) = try await fixture(root)
        try await parent.appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:"epoch"))
        let event = AgentFamilyMessage(id:"r",sequence:1,childID:"child",turn:1,author:"subagent",kind:"result",text:"done",task:"Task",epoch:"epoch")
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,event)
        let delivered = try await coordinator.boundary(parent,final:false)
        XCTAssertTrue(delivered)
        let state = await parent.agentState()
        XCTAssertEqual(state.run?.reportContinuations,1)
        XCTAssertEqual(state.messages["r"]?.disposition,"delivered")
        await parent.close()
    }
    func testCancelledAcceptedControlReturnsReceiptDuringLiveSettlement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent, coordinator) = try await fixture(root)
        let call = ToolCall(id:"start",name:"subagent_start",arguments:["task":"Work","mode":"wait"])
        let key = try await parent.agentFixtureCall(call,newTask:true)
        let receipt = try await coordinator.prepare(call,key:key,parent:parent)
        let outcome = await parent.runToolCall(call,index:0,cancelledBeforeInvocation:true)
        XCTAssertFalse(outcome.message.isError)
        let value = try? JSON.parse(Data(outcome.message.text.utf8))
        XCTAssertEqual(value?["accepted"].flag,true)
        XCTAssertEqual(value?["child_id"],receipt["child_id"])
        XCTAssertEqual(value?["wait"]["wake_reason"].text,"stopped")
        XCTAssertEqual(outcome.message.id,"agent-receipt:" + AgentOperation.id(key))
        await coordinator.drain(); await parent.close()
    }
    func testHeldInboxDoesNotWakeWaitAndReleaseSignalsActiveRun() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent, coordinator) = try await fixture(root)
        let op = replacement(0,status:.running)
        try await parent.appendAgentRecord(JournalRecordKind.agentOperation,op)
        let report = AgentFamilyMessage(id:"question",sequence:1,childID:op.turn!.childID,turn:1,author:"subagent",kind:"question",text:"Which path?",task:"Task",epoch:"epoch")
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,report)
        await parent.reviewHoldFixture(true)
        let result = try await coordinator.wait(["child_id":JSON(op.turn!.childID),"turn":1],args:["mode":"one","timeout_ms":20],parent:parent)
        XCTAssertEqual(result["wake_reason"].text,"timeout","Held events are not deliverable wakeups")
        let signal = await coordinator.signal(parent.id), before = await signal.revision
        await parent.reviewHoldFixture(false)
        try await Task.sleep(for:.milliseconds(20))
        let after = await signal.revision
        XCTAssertGreaterThan(after,before,"Releasing an edit must wake a family even without queued user input")
        await parent.close()
    }
    func testListRevisionUsesDurableFamilyStateInsteadOfRuntimeEvents() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent, coordinator) = try await fixture(root)
        try await parent.appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:"epoch"))
        await parent.reviewRuntimeEvents()
        let listing = await coordinator.list(parent:parent,cursor:0,limit:10), state = await parent.agentState()
        XCTAssertEqual(listing["revision"].int,state.revision)
        await parent.close()
    }
    private func replacement(_ index: Int, status: SubagentStatus = .completed) -> AgentOperation {
        let key = SubagentCallKey(parentSessionID:"parent",assistantMessageID:"a\(index)",toolCallID:"start\(index)")
        let turn = AgentChildTurn(childID:"child\(index)",turn:1,executionID:"c\(index)",parentExecutionID:"epoch",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"i\(index)",task:"Replacement",call:key,status:status)
        return AgentOperation(key:key,digest:"d",receipt:[:],turn:turn,epoch:"epoch")
    }
    private func fixture(_ root: URL) async throws -> (AgentSession,AgentSteeringCoordinator) {
        let coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:AccountedAgentScript([answer("done")]),tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        return (parent,coordinator)
    }
}
private final class PromotionReentryBox: @unchecked Sendable {
    weak var journal: SessionJournal?
    var error: String?
    func appendDuringPromotion() {
        guard let journal else { return }; self.journal = nil
        do { try journal.append(["type":"custom","customType":"unexpected"],id:"reentrant",flush:false) }
        catch { self.error = (error as? AgentError)?.code }
    }
}
extension AgentSession {
    func reviewHoldFixture(_ held: Bool) {
        queueEdit = held ? QueueEditHold(editID:"edit",turnID:"queued",lane:"follow-up",sequence:1) : nil
        if !held { releaseHeldInput() }
    }
    func reviewRuntimeEvents() { for _ in 0..<100 { event("fixture") } }
}
