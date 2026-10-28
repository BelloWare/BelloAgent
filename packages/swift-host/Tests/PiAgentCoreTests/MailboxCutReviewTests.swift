import XCTest
@testable import PiAgentCore

actor CutinLatch {
    private var released = false
    private var waiting: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiting.append($0) } } }
    func release() { released = true; let saved = waiting; waiting.removeAll(); for item in saved { item.resume() } }
}

final class MailboxCutReviewTests: HelperTestCase {
    private struct Fixture {
        let parent: AgentSession, child: AgentSession, coordinator: AgentSteeringCoordinator, client: CutinReviewClient
        let root: URL
        func close() async { await client.finish.release(); await client.drain.release(); await parent.close() }
    }
    private func fixture(retryCut: Bool = false, holdDrain: Bool = false) async throws -> Fixture {
        let root = try temporaryDirectory(); addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let client = CutinReviewClient(retryCut:retryCut,holdDrain:holdDrain), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        let spawn = ToolCall(id:"spawn",name:"spawn_agent",arguments:["task_name":"worker","message":"Work","fork_turns":"none"])
        let key = try await parent.agentFixtureCall(spawn,newTask:true)
        _ = try await coordinator.prepare(spawn,key:key,parent:parent)
        try await parent.runToolBatch([spawn])
        await client.started.wait()
        let jobs = await coordinator.jobs
        let child = try XCTUnwrap(jobs.values.first?.child)
        let mail = ToolCall(id:"mail",name:"send_message",arguments:["target":"worker","message":"CUT-MAIL"])
        let mailKey = try await parent.agentFixtureCall(mail)
        _ = try await coordinator.prepare(mail,key:mailKey,parent:parent)
        try await parent.runToolBatch([mail])
        return Fixture(parent:parent,child:child,coordinator:coordinator,client:client,root:root)
    }
    func testQueueEditAfterPreparationDoesNotStopOrDamageAccounting() async throws {
        for target in ["recipient","owner","tombstone"] {
            let f = try await fixture(), prepared = CutinLatch(), commit = CutinLatch()
            await f.coordinator.reviewCutBarrier { await prepared.release(); await commit.wait() }
            await f.client.candidate.release(); await prepared.wait()
            if target == "recipient" { await f.child.reviewHoldFixture(true) }
            else if target == "owner" { await f.parent.reviewHoldFixture(true) }
            else { try await f.parent.reviewWithdrawMail() }
            await commit.release(); await f.client.attempted.wait()
            let failure = await f.parent.accountingFailure, cuts = await f.client.cuts
            XCTAssertNil(failure); XCTAssertEqual(cuts,1,"A late \(target) cannot decline the prepared cut")
            // The next request is the ordinary retained-prefix continuation,
            // even if the hold/withdrawal made its delivery boundary empty.
            await f.client.continued.wait()
            let requests = await f.client.requests
            guard requests.count > 1 else { XCTFail("No continuation after cut"); await f.close(); continue }
            XCTAssertTrue(requests[1].contains { $0.nativeMailboxCut != nil })
            if target != "owner" { XCTAssertFalse(requests[1].contains { $0.text.contains("CUT-MAIL") }) }
            await f.child.reviewHoldFixture(false); await f.parent.reviewHoldFixture(false)
            await f.client.finish.release(); await f.child.waitForSubagent()
            let status = await f.parent.agentState().latest(f.child.id)?.status
            XCTAssertEqual(status,.completed)
            await f.close()
        }
    }
    func testStopAfterPreparationPrecedesOwnerValidationAndAllowsNewFamilyTurn() async throws {
        let f = try await fixture(), prepared = CutinLatch(), commit = CutinLatch()
        await f.coordinator.reviewCommitBarrier { await prepared.release(); await commit.wait() }
        await f.client.candidate.release(); await prepared.wait()
        await f.parent.stop()
        try await f.parent.finishPresentedTask("interrupted")
        await commit.release(); await f.client.attempted.wait(); await f.child.waitForSubagent()
        let failure = await f.parent.accountingFailure, stopped = await f.client.cancelled
        XCTAssertNil(failure); XCTAssertTrue(stopped)
        await f.coordinator.drain()
        await f.client.finish.release()
        _ = try await f.parent.submit(Submission(commandID:"after-stop",turnID:"after-stop",text:"A fresh turn in the same family"),steer:false)
        await f.parent.waitForSubagent()
        let after = await f.parent.accountingFailure, history = await f.parent.history
        let error = await f.parent.errorMessage
        XCTAssertNil(after); XCTAssertTrue(history.contains { $0.role == "assistant" && $0.text == "Ordinary answer" },String(describing:error))
        await f.close()
    }
    func testPrecheckDeclineCanCutAtLaterEligibleItemInSameStream() async throws {
        for target in ["recipient","owner"] {
            let f = try await fixture(retryCut:true)
            if target == "recipient" { await f.child.reviewHoldFixture(true) } else { await f.parent.reviewHoldFixture(true) }
            await f.client.candidate.release(); await f.client.declined.wait()
            let cuts = await f.child.subagents.cuts
            XCTAssertTrue(cuts?.preparations.isEmpty ?? true,"A declined pre-check must not write preparation")
            await f.child.reviewHoldFixture(false); await f.parent.reviewHoldFixture(false)
            await f.client.nextItem.release(); await f.client.attempted.wait(); await f.client.continued.wait()
            let count = await f.client.cuts, requests = await f.client.requests
            XCTAssertEqual(count,1); XCTAssertEqual(requests.count,2)
            guard requests.count > 1 else { await f.close(); continue }
            XCTAssertTrue(requests[1].contains { $0.nativeMailboxCut?["itemId"].text == "second-item" })
            await f.close()
        }
    }
    func testOwnerCloseAndInterruptSettleParkedDrainExactlyOnce() async throws {
        for action in ["close","interrupt","stop"] {
            let f = try await fixture(holdDrain:true)
            await f.client.candidate.release(); await f.client.continued.wait(); await f.client.finish.release()
            await f.child.waitForSubagent()
            // A coordinator barrier signals after finishJob has released its slot.
            let wake = await f.coordinator.signal(f.parent.id)
            while await f.coordinator.hasReviewJob(f.child.id) {
                let revision = await wake.revision
                if await f.coordinator.hasReviewJob(f.child.id) { await wake.wait(after:revision) }
            }
            let parked = await f.coordinator.drainingChildren[f.child.id], active = await f.coordinator.active[f.parent.id]
            XCTAssertTrue(parked?.child === f.child); XCTAssertEqual(active,0)
            if action == "close" { await f.parent.close() }
            else if action == "stop" { await f.parent.stop(); await f.coordinator.drain() }
            else {
                let call = ToolCall(id:"interrupt",name:"interrupt_agent",arguments:["target":"worker"])
                let key = try await f.parent.agentFixtureCall(call)
                _ = try await f.coordinator.prepare(call,key:key,parent:f.parent)
            }
            await f.client.settled.wait()
            await f.coordinator.drain()
            let failure = await f.parent.accountingFailure, settlements = await f.client.drainSettlements
            XCTAssertNil(failure); XCTAssertEqual(settlements,1)
            let rows = try Data(contentsOf:f.root.appendingPathComponent("parent.jsonl")).split(separator:10).map { try JSON.parse(Data($0)) }
            let costs = rows.filter { $0["customType"].text == JournalRecordKind.cost && $0["data"]["attemptId"].text == "review-attempt-0" }
            XCTAssertEqual(costs.count,1); XCTAssertEqual(costs.first?["data"]["unreported"].int,1)
            await f.close()
        }
    }
}

extension AgentSteeringCoordinator {
    func reviewCommitBarrier(_ hook: @escaping @Sendable () async -> Void) { beforeMailboxCutCommit = hook }
    func reviewCutBarrier(_ hook: @escaping @Sendable () async -> Void) { afterMailboxCutPrepared = hook }
    func hasReviewJob(_ child: String) -> Bool { jobs.values.contains { $0.turn.childID == child } }
}
private extension AgentSession {
    func reviewWithdrawMail() throws {
        guard var message = agentState().messages.values.first(where: { $0.text == "CUT-MAIL" }) else { throw SubagentRecovery.damaged() }
        message.disposition = "tombstoned"
        try appendAgentRecord(JournalRecordKind.agentMessage,message)
    }
}

actor CutinReviewClient: ModelClient {
    let started = CutinLatch(), candidate = CutinLatch(), declined = CutinLatch(), nextItem = CutinLatch(), attempted = CutinLatch()
    let continued = CutinLatch(), finish = CutinLatch(), drain = CutinLatch(), settled = CutinLatch()
    let retryCut: Bool, holdDrain: Bool
    var requests: [[ChatMessage]] = [], cuts = 0, cancelled = false, drainSettlements = 0
    init(retryCut: Bool, holdDrain: Bool) { self.retryCut = retryCut; self.holdDrain = holdDrain }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture","Missing lifecycle") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let lifecycle = try XCTUnwrap(lifecycle), index = requests.count, attempt = "review-attempt-\(requests.count)"
        let permit = try await lifecycle.admitAttempt(attempt); try await lifecycle.willDispatch(attempt)
        requests.append(messages)
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"generated",profile:profile)
        var reply = answer("Ordinary answer"); reply.message.requestAttemptIDs = [attempt]
        if index == 0 {
            await started.release(); await candidate.wait()
            var prefix = answer("Retained prefix"); prefix.message.requestAttemptIDs = [attempt]
            prefix.mailboxCut = MailboxCut(cutId:"review-cut",attemptId:attempt,responseId:"response",itemId:"first-item")
            do {
                var cut = try await lifecycle.prepareMailboxCut?(prefix)
                if retryCut, cut == nil {
                    await declined.release(); await nextItem.wait()
                    prefix.mailboxCut = MailboxCut(cutId:"review-cut-later",attemptId:attempt,responseId:"response",itemId:"second-item")
                    cut = try await lifecycle.prepareMailboxCut?(prefix)
                }
                if let cut { cuts += 1; reply = cut }
                await attempted.release()
            } catch {
                cancelled = error is CancellationError
                try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true))
                await declined.release(); await attempted.release(); await continued.release()
                throw error
            }
            if holdDrain, reply.mailboxCut != nil {
                let drain = drain
                permit.installCancellation { Task { await drain.release() } }
                let pending = observation
                Task {
                    await drain.wait()
                    try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:pending,dispatched:true))
                    self.drainSettlements += 1; await self.settled.release()
                }
                return reply
            }
        } else { await continued.release(); await finish.wait() }
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        observation.fields = ["input":10,"output":2,"total":12]
        try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true))
        return reply
    }
}
