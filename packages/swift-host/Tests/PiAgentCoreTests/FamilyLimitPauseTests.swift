import XCTest
@testable import PiAgentCore

/// The shared cost limit pauses the whole family at once and resumes only on
/// Resume (owner, 2026-10-16). Replaces 0.1.128's drain-then-block table.
final class FamilyLimitPauseTests: XCTestCase {
    enum Phase: String, CaseIterable { case idle, ownRequest, childrenDispatched, sideRequest, preLedgerRequest, tools }
    enum Crosser: String, CaseIterable { case own, backgroundChild, waitedChild, nestedSide, sideChild }

    /// Every phase × charge source: the crossing settlement cancels every
    /// other dispatched request at once (no drain), with one Stop, and those
    /// requests can still record what they reported; unknown stays unknown.
    func testEveryPhaseAndChargeSourceAbortsInFlightWorkAtOnce() async throws {
        for phase in Phase.allCases { for crosser in Crosser.allCases {
            let label = "\(phase)/\(crosser)", root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at:root) }
            let owner = try familyFixture(root:root)
            await owner.enableFamilyBudget(); await owner.beginPresentedTask("turn"); await owner.setCostLimit(0.5)
            let side = try await self.side("side",parent:owner,root:root)
            let nested = try await self.side("nested",parent:side,root:root)
            let child = try await self.child("child",parent:owner,root:root)
            let sideChild = try await self.child("side-child",parent:side,root:root)
            let source: AgentSession
            switch crosser {
            case .own: source = owner
            case .backgroundChild, .waitedChild: source = child
            case .nestedSide: source = nested
            case .sideChild: source = sideChild
            }
            let crossing = try await start(source,"crossing")
            var held: (RequestLifecycle,RequestPermit)?
            switch phase {
            case .ownRequest: held = try await start(owner,"held")
            case .childrenDispatched: held = try await start(child,"held")
            case .sideRequest: held = try await start(nested,"held")
            default: break
            }
            await owner.limitFixturePhase(model:phase == .ownRequest || phase == .preLedgerRequest,
                tools:phase == .tools || crosser == .waitedChild)
            try await finish(crossing.0,"crossing",cost:0.6)
            // No drain fence: the Stop is issued by the crossing settlement.
            let stopped = await owner.stopCount
            XCTAssertEqual(stopped,1,"\(label): the family stops at once")
            if let held {
                // A side's request is cancelled by its own pause, delivered
                // from the root without waiting for anything to settle.
                try await eventually(timeout:.seconds(2)) { (try? held.1.check()) == nil }
                // An aborted request still records what it reported.
                let reported = phase != .childrenDispatched
                try await finish(held.0,"held",cost:reported ? 0.1 : nil)
            }
            await owner.stopFamilyAtLimit()
            let again = await owner.stopCount, spend = await owner.spend
            XCTAssertEqual(again,1,"\(label): one Stop per exhaustion")
            XCTAssertEqual(spend.usd,held == nil || phase == .childrenDispatched ? 0.6 : 0.7,accuracy:1e-9,label)
            XCTAssertEqual(spend.unreported,phase == .childrenDispatched ? 1 : 0,"\(label): unknown cost stays unknown")
            do { _ = try await crossing.0.admitAttempt("denied"); XCTFail("\(label): admitted past the limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit",label) }
            await sideChild.close(); await child.close(); await nested.close(); await side.close(); await owner.close()
        } }
    }

    /// Sixteen dispatched and two queued children, crossed by every source:
    /// the dispatched requests are cancelled at once, all 18 turns stay
    /// queued (never not_executed), runtimes are released, and Resume runs
    /// each from where it stopped under the resumed execution.
    func testQueuedAndRunningChildrenParkForEveryChargeSourceAndResumeInPlace() async throws {
        for crosser in Crosser.allCases {
            let label = "\(crosser)", root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at:root) }
            let client = LimitRunClient(mode:"queued"), runtimes = LimitChildRuntimes()
            let coordinator = AgentSteeringCoordinator(open:{ try await runtimes.open($0,$1) },settled:{ await runtimes.settle($0) })
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
                readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
            await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            await owner.setCostLimit(0.5)
            let side = try await self.side("side",parent:owner,root:root)
            let nested = try await self.side("nested",parent:side,root:root)
            var accepted: [String] = []
            for index in 0..<18 {
                let call = ToolCall(id:"start-\(index)",name:"subagent_start",arguments:["task":JSON("Worker \(index)"),"mode":"background"])
                let key = try await owner.agentFixtureCall(call,newTask:index == 0)
                let receipt = try await coordinator.prepare(call,key:key,parent:owner)
                accepted.append(try XCTUnwrap(receipt["child_id"].text))
            }
            try await eventually { await client.children.count == 16 }
            let child = try await self.child("child",parent:owner,root:root)
            let sideChild = try await self.child("side-child",parent:side,root:root)
            let source: AgentSession
            switch crosser {
            case .own: source = owner
            case .backgroundChild, .waitedChild: source = child
            case .nestedSide: source = nested
            case .sideChild: source = sideChild
            }
            let crossing = try await start(source,"crossing")
            try await finish(crossing.0,"crossing",cost:0.6)
            // All sixteen dispatched requests end without being released.
            try await eventually(timeout:.seconds(3)) { await client.cancelled.count == 16 }
            try await eventually(timeout:.seconds(3)) { await coordinator.jobs.isEmpty }
            let paused = await owner.costPaused, family = await owner.agentState(), released = await runtimes.released
            XCTAssertTrue(paused,label)
            XCTAssertEqual(family.turns.count,18,label)
            XCTAssertTrue(family.turns.values.allSatisfy { $0.status == .queued && $0.result == nil },"\(label): every turn keeps its place")
            XCTAssertEqual(released.count,18,"\(label): no parked runtime stays pinned")
            for id in accepted.suffix(2) {
                let reader = try JournalRecordReader(root.appendingPathComponent(id + ".jsonl"))
                while let row = try reader.next() { XCTAssertNotEqual(row["customType"].text,JournalRecordKind.agentTerminal,"\(label): queued work is never sealed") }
            }
            let listed = await coordinator.list(parent:owner,cursor:0,limit:100)["children"].list
            XCTAssertEqual(listed.filter { $0["costPaused"].flag == true && $0["status"].text == "queued" }.count,18,label)
            // Raising the limit resumes nothing; Resume below the limit only.
            do { try await owner.requireCostResumeRoom(); XCTFail("\(label): resumed at the limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit",label) }
            await owner.setCostLimit(20)
            try await Task.sleep(for:.milliseconds(50))
            let idle = await client.children.count, stillPaused = await owner.costPaused
            XCTAssertEqual(idle,16,"\(label): raising the limit starts nothing"); XCTAssertTrue(stillPaused,label)
            try await owner.requireCostResumeRoom()
            _ = await owner.endCostPause()
            await owner.beginResumeFixture()
            let presented = await owner.activeTaskPresentation?.executionID, execution = try XCTUnwrap(presented)
            await client.releaseAll()
            try await coordinator.resumeParked(owner:owner,generation:1)
            try await eventually { await coordinator.jobs.isEmpty }
            let resumed = await owner.agentState(), dispatched = await client.children
            XCTAssertTrue(resumed.turns.values.allSatisfy { $0.status == .completed },label)
            XCTAssertTrue(resumed.turns.values.allSatisfy { $0.continuations?.count == 1 && $0.currentParentExecutionID == execution },label)
            XCTAssertEqual(dispatched.count,34,"\(label): 16 resumed and 2 first runs, nothing replayed twice")
            for id in accepted {
                let opened = await runtimes.opened[id], reopened = try XCTUnwrap(opened)
                let mirror = await reopened.agentState().turns[AgentTurnTarget(childID:id,turn:1).id]
                XCTAssertEqual(mirror,resumed.turns[AgentTurnTarget(childID:id,turn:1).id],"\(label): child and owner agree")
                let users = await reopened.history.filter { $0.role == "user" }.count
                XCTAssertEqual(users,1,"\(label): a resumed task is not sent again")
            }
            await runtimes.close(); await sideChild.close(); await child.close(); await nested.close(); await side.close(); await owner.close()
        }
    }

    /// A real parent run in every delegation shape: the crossing aborts the
    /// other child requests and the parent at once, executes no tool, keeps
    /// the family paused, and Resume finishes everything once raised.
    func testRealRunPausesTheFamilyAndResumesItAfterTheLimitIsRaised() async throws {
        for mode in ["background","wait","tool-reply","queued"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = LimitRunClient(mode:mode), coordinator = AgentSteeringCoordinator(), tools = RecordingTools()
            let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
            await parent.enableFamilyBudget(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
            await parent.setCostLimit(0.5)
            _ = try await parent.submit(Submission(commandID:"command",turnID:"turn",text:"Two workers"),steer:false)
            let expected = mode == "queued" ? 16 : 2
            try await eventually { await client.children.count == expected }
            if mode == "queued" || mode == "tool-reply" { try await eventually { await client.parentCount == 2 } }
            await client.releaseFirst()
            try await eventually(timeout:.seconds(3)) { !(await parent.isRunning) }
            try await eventually(timeout:.seconds(3)) { await coordinator.jobs.isEmpty }
            let state = await parent.state, code = await parent.errorCode, paused = await parent.costPaused
            let cancelled = await client.cancelled, calls = await tools.calls, family = await parent.agentState()
            XCTAssertEqual(state,.paused,mode); XCTAssertEqual(code,"cost_limit",mode); XCTAssertTrue(paused,mode)
            XCTAssertEqual(cancelled.count,expected - 1,"\(mode): other dispatched children are cancelled without release")
            XCTAssertTrue(calls.isEmpty,"\(mode): no tool runs once the family is paused")
            XCTAssertFalse(family.turns.values.contains { $0.status == .notExecuted || $0.status == .interrupted },mode)
            let snapshot = await parent.snapshot()
            XCTAssertEqual(snapshot["costPaused"].flag,true,mode); XCTAssertEqual(snapshot["cost"]["paused"].flag,true,mode)
            XCTAssertEqual(snapshot["continuable"].flag,true,mode)
            // A message sent after raising waits for Resume.
            await parent.setCostLimit(20)
            let sent = try await parent.submit(Submission(commandID:"later",turnID:"later",text:"Afterwards"),steer:false)
            XCTAssertEqual(sent["delivery"].text,"after-resume",mode)
            let running = await parent.isRunning; XCTAssertFalse(running,"\(mode): raising or sending resumes nothing")
            await client.releaseAll()
            try await parent.requireCostResumeRoom()
            let reply = try await parent.continueRun(commandID:"resume")
            XCTAssertEqual(reply["resumedFamily"].flag,true,mode)
            try await eventually(timeout:.seconds(10)) { let busy = await parent.isRunning, jobs = await coordinator.jobs.isEmpty; return !busy && jobs }
            let final = await parent.agentState(), finalState = await parent.state, after = await parent.costPaused
            XCTAssertTrue(final.turns.values.allSatisfy { $0.status == .completed },"\(mode): \(final.turns.values.map(\.status))")
            XCTAssertEqual(finalState,.idle,mode); XCTAssertFalse(after,mode)
            let users = await parent.history.filter { $0.role == "user" }.map(\.text)
            XCTAssertEqual(users.last,"Afterwards","\(mode): the waiting message goes after the resumed run")
            await coordinator.drain(); await parent.close()
        }
    }

    /// Quit or helper restart while paused, and a crash before the pause
    /// parked its turns: reopening keeps the pause and the queued turns;
    /// nothing runs until Resume, which completes the family.
    func testPauseSurvivesReopenAndACrashBeforeParkingThenResumes() async throws {
        for crashed in [false, true] {
            let label = crashed ? "crash" : "reopen", root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at:root) }
            let client = LimitRunClient(mode:"background"), coordinator = AgentSteeringCoordinator()
            let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
            await parent.enableFamilyBudget(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
            await parent.setCostLimit(0.5)
            _ = try await parent.submit(Submission(commandID:"command",turnID:"turn",text:"Two workers"),steer:false)
            try await eventually { await client.children.count == 2 }
            await client.releaseFirst()
            try await eventually(timeout:.seconds(3)) { let busy = await parent.isRunning, jobs = await coordinator.jobs.isEmpty; return !busy && jobs }
            let saved = await parent.path, path = try XCTUnwrap(saved)
            var parked = await parent.agentState().turns.values.filter { !$0.status.terminal }
            XCTAssertFalse(parked.isEmpty,label)
            await parent.close()
            if crashed {
                // The helper died after the pause was saved but before its
                // turns were parked: they still read as running.
                let journal = try SessionJournal(url:URL(fileURLWithPath:path),id:"parent",cwd:root,binding:nil,create:false)
                for var turn in parked { turn.status = .running
                    try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentTurnState),"ownerID":"parent","data":try subagentJSON(turn)],flush:true) }
            }
            let reopenedCoordinator = AgentSteeringCoordinator()
            let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path)
            await reopened.enableSubagents(SubagentCoordinator()); await reopened.enableAgentSteering(reopenedCoordinator)
            await reopened.setCostLimit(0.5)
            let state = await reopened.state, code = await reopened.errorCode, paused = await reopened.costPaused
            XCTAssertEqual(state,.paused,label); XCTAssertEqual(code,"cost_limit",label); XCTAssertTrue(paused,label)
            parked = await reopened.agentState().turns.values.filter { !$0.status.terminal }
            XCTAssertFalse(parked.isEmpty,label)
            XCTAssertTrue(parked.allSatisfy { $0.status == .queued },"\(label): reopening holds the turns, never interrupts them")
            for turn in parked {
                let child = try AgentSession(id:turn.childID,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                    resources:Resources(cwd:root,home:root),client:client,tools:DisabledTools(),traces:TraceStore(),resumePath:root.appendingPathComponent(turn.childID + ".jsonl").path)
                let mirror = await child.agentState().turns[turn.id]
                XCTAssertEqual(mirror?.status,.queued,"\(label): the child mirror agrees"); await child.close()
            }
            do { try await reopened.requireCostResumeRoom(); XCTFail("\(label): resumed at the limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit",label) }
            await reopened.setCostLimit(20); await client.releaseAll()
            try await reopened.requireCostResumeRoom()
            _ = try await reopened.continueRun(commandID:"resume")
            try await eventually(timeout:.seconds(10)) { let busy = await reopened.isRunning, jobs = await reopenedCoordinator.jobs.isEmpty; return !busy && jobs }
            let final = await reopened.agentState()
            XCTAssertTrue(final.turns.values.allSatisfy { $0.status == .completed },"\(label): \(final.turns.values.map(\.status))")
            await reopenedCoordinator.drain(); await reopened.close()
        }
    }

    /// Sides and nested sides with running tools stop at once when another
    /// member crosses. Each paused side registers with the root, whose
    /// Resume names them; each side resumes only below the root's limit.
    func testSidesPauseImmediatelyAndTheRootsResumeNamesThem() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), tools = LimitHeldTools()
        await owner.setCostLimit(0.5)
        let side = try await side("side",parent:owner,root:root)
        let nested = try await self.side("nested",parent:side,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
        _ = try await nested.submit(Submission(commandID:"command",turnID:"turn",text:"Work"),steer:false)
        try await eventually { await tools.started }
        let held = try await start(owner,"held"), crossing = try await start(side,"crossing")
        try await finish(crossing.0,"crossing",cost:0.6)
        // No request has to settle first: the root's dispatched request and
        // the nested side's tool are both cancelled.
        XCTAssertThrowsError(try held.1.check())
        try await eventually(timeout:.seconds(2)) { !(await nested.isRunning) }
        let cancelled = await tools.cancelled, code = await nested.errorCode, state = await nested.state, paused = await nested.costPaused
        XCTAssertTrue(cancelled); XCTAssertEqual(code,"cost_limit"); XCTAssertEqual(state,.paused); XCTAssertTrue(paused)
        try await eventually { await owner.costPausedMembers == ["nested"] }
        let rootPaused = await owner.costPaused, sidePaused = await side.costPaused
        XCTAssertTrue(rootPaused,"The root shows the family's pause"); XCTAssertFalse(sidePaused,"An idle side has nothing to resume")
        do { try await nested.requireCostResumeRoom(); XCTFail("A side resumed at the root's limit") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        await owner.setCostLimit(20)
        let stillPaused = await nested.costPaused, running = await nested.isRunning
        XCTAssertTrue(stillPaused); XCTAssertFalse(running)
        try await owner.requireCostResumeRoom()
        let reply = try await owner.continueRun(commandID:"resume-root")
        XCTAssertEqual(reply["pausedMembers"].list.compactMap(\.text),["nested"])
        XCTAssertEqual(reply["continued"].flag,false)
        try await nested.requireCostResumeRoom()
        let resumed = try await nested.continueRun(commandID:"resume-nested")
        XCTAssertEqual(resumed["continued"].flag,true)
        try await eventually { await tools.starts == 2 }
        let after = await nested.costPaused, members = await owner.costPausedMembers
        XCTAssertFalse(after); XCTAssertTrue(members.isEmpty)
        await nested.stop()
        try await finish(held.0,"held",cost:0.1)
        await nested.close(); await side.close(); await owner.close()
    }

    /// Lowering the limit below the spend pauses work in flight; raising it
    /// again changes nothing until Resume. Repeated readings stop once.
    func testLoweringTheLimitPausesAndRaisingItResumesNothing() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), tools = LimitHeldTools()
        let side = try await side("side",parent:owner,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
        await owner.setCostLimit(5)
        let paid = try await start(owner,"paid"); try await finish(paid.0,"paid",cost:0.9)
        _ = try await side.submit(Submission(commandID:"command",turnID:"turn",text:"Work"),steer:false)
        try await eventually { await tools.started }
        await owner.setCostLimit(0.5)
        try await eventually(timeout:.seconds(2)) { !(await side.isRunning) }
        let paused = await side.costPaused, stops = await owner.stopCount
        XCTAssertTrue(paused); XCTAssertEqual(stops,1)
        await owner.setCostLimit(0.5); await owner.stopFamilyAtLimit()
        let again = await owner.stopCount; XCTAssertEqual(again,1)
        await owner.setCostLimit(2)
        try await Task.sleep(for:.milliseconds(50))
        let starts = await tools.starts, still = await side.costPaused
        XCTAssertEqual(starts,1); XCTAssertTrue(still)
        await side.close(); await owner.close()
    }

    /// A child that reaches its final boundary as the pause lands is not
    /// sealed (Stop would read as interrupted): its turn waits for Resume.
    func testChildFinalBoundaryDuringThePauseDefersItsSeal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:LimitRunClient(mode:"queued"),tools:RecordingTools(),traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        let call = ToolCall(id:"start",name:"subagent_start",arguments:["task":"Worker","mode":"background"])
        let key = try await owner.agentFixtureCall(call,newTask:true)
        // Paused before the turn gets a slot: it stays queued with its
        // prepared child, which then reaches a final boundary.
        await coordinator.fixturePause("parent")
        let receipt = try await coordinator.prepare(call,key:key,parent:owner)
        let id = try XCTUnwrap(receipt["child_id"].text), target = AgentTurnTarget(childID:id,turn:1)
        let job = await coordinator.jobs[target.id], child = try XCTUnwrap(job?.child)
        await child.stop()
        do { _ = try await coordinator.boundary(child,final:true); XCTFail("A paused family's child sealed its turn") }
        catch { XCTAssertTrue(error is CancellationError) }
        let turn = await owner.agentState().turns[target.id]
        XCTAssertEqual(turn?.status,.queued); XCTAssertNil(turn?.result)
        await child.close(); await owner.close()
    }

    /// Retry backoff is not a request in flight: the pause cuts it short.
    func testRetryBackoffIsCutShortByThePause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root,client:LimitRunClient(mode:"retry"))
        let side = try await side("side",parent:owner,root:root)
        await owner.setCostLimit(0.5); await owner.useRetrySettings(.init(maxRetries:1,baseDelayMs:30_000))
        _ = try await owner.submit(Submission(commandID:"command",turnID:"turn",text:"Retry"),steer:false)
        try await eventually { await owner.runStatus == .retrying }
        let crossing = try await start(side,"crossing")
        try await finish(crossing.0,"crossing",cost:0.6)
        do { try await eventually(timeout:.seconds(2)) { !(await owner.isRunning) } }
        catch { await side.close(); await owner.close(); throw error }
        let code = await owner.errorCode, paused = await owner.costPaused
        XCTAssertEqual(code,"cost_limit"); XCTAssertTrue(paused)
        await side.close(); await owner.close()
    }

    private func side(_ id: String, parent: AgentSession, root: URL, client: any ModelClient = ScriptClient([]), tools: any ToolExecuting = DisabledTools()) async throws -> AgentSession {
        let seed = await parent.sideSeed()
        let side = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),seed:seed.messages,parent:seed.info)
        try await side.bindSideBudget(to:parent); await side.beginPresentedTask("turn")
        return side
    }
    private func child(_ id: String, parent: AgentSession, root: URL) async throws -> AgentSession {
        var origin = subagentFixtureOrigin()
        let parentID = await parent.id
        origin.link.childSessionID = id; origin.link.budgetOwnerSessionID = parentID
        origin.link.call.parentSessionID = parentID
        origin.link.parentExecutionID = await parent.activeTaskPresentation!.executionID
        try await parent.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Task",resultMessageID:"result-\(id)"))
        let child = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
        try await child.bindBudgetOwner(parent,generation:0)
        return child
    }
    private func start(_ session: AgentSession, _ attempt: String) async throws -> (RequestLifecycle,RequestPermit) {
        let value = try await session.requestLifecycle(turnID:"turn",purpose:"turn"), hooks = try XCTUnwrap(value)
        let permit = try await hooks.admitAttempt(attempt); try await hooks.willDispatch(attempt)
        return (hooks,permit)
    }
    private func finish(_ hooks: RequestLifecycle, _ attempt: String, cost: Double?) async throws {
        let observation = billingObservation(profile:try fixtureProfile(),session:hooks.scope.sourceSessionID,attempt:attempt,cost:cost)
        try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
    }
}

private extension AgentSteeringCoordinator {
    func fixturePause(_ owner: String) { paused.insert(owner) }
}

private extension AgentSession {
    func limitFixturePhase(model: Bool, tools: Bool) { modelActive = model; runStatus = tools ? .waitingTool : .running }
    /// What a Resume's run establishes before it resumes parked turns.
    func beginResumeFixture() { queuePaused = false; beginPresentedTask(UUID().uuidString) }
}

/// Uses the same unload guard as HostService's open/release callbacks rather
/// than closing every child unconditionally, which would hide a pinned runtime.
private actor LimitChildRuntimes {
    var opened: [String:AgentSession] = [:]
    var settled: [String] = []
    var released: Set<String> = []
    func open(_ environment: SubagentEnvironment, _ plan: SubagentPlan) async throws -> AgentSession {
        let id = plan.origin.link.childSessionID
        if let previous = opened[id], !(await previous.unloadIfIdle()) {
            throw AgentError("session_busy","Child is still settling")
        }
        let child = try AgentSteeringCoordinator.makeChild(environment,plan)
        opened[id] = child; return child
    }
    func settle(_ child: AgentSession) async {
        guard let turn = await child.agentLease else { return }
        settled.append(turn.id)
        if await child.unloadIfIdle() { released.insert(turn.childID) }
    }
    func close() async { for child in opened.values { await child.close() } }
}

/// Children hold their requests until released. A cancelled child request
/// settles as unreported (its usage unknown) and is listed in `cancelled`.
/// A child's first request after `releaseFirst` costs $0.60; others $0.20.
private actor LimitRunClient: ModelClient {
    let mode: String
    var parentCount = 0, children: [String] = [], cancelled: [String] = []
    var firstReleased = false, allReleased = false, firstSettled = false, firstTaken = false
    init(mode: String) { self.mode = mode }
    private func observation(_ profile: Profile, _ session: String, _ turn: String, _ attempt: String, cost: Double?) -> RequestObservation {
        var observation = RequestObservation(sessionID:session,turnID:turn,attemptID:attempt,purpose:"turn",fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":JSON(cost == nil ? "unreported" : "reported"),"usd":cost.map { JSON($0) } ?? .null]]]
        return observation
    }
    func releaseFirst() { firstReleased = true }
    func releaseAll() { allReleased = true }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Expected admission")
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,cacheSessionID:String,turnID:String,purpose:String,lifecycle:RequestLifecycle?,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), attempt = UUID().uuidString
        let permit = try await hooks.admitAttempt(attempt); defer { permit.finish() }
        try await hooks.willDispatch(attempt)
        var reply = answer("Finished"), cost = 0.01
        if mode == "side-tool" { reply = toolReply(["first"]) }
        else if sessionID == "parent" {
            parentCount += 1
            if parentCount == 1 {
                reply = ModelReply(message:ChatMessage(role:"assistant",content:[]))
                for n in 0..<(mode == "queued" ? 18 : 2) {
                    let start = agentCallReply("start-\(n)","subagent_start",["task":JSON("Worker \(n)"),"mode":JSON(mode == "wait" && n == 1 ? "wait" : "background")])
                    reply.calls += start.calls; reply.message.content += start.message.content
                }
            }
            else if mode == "tool-reply" && parentCount == 2 {
                do { while !firstSettled { try permit.check(); try await Task.sleep(for:.milliseconds(2)) } }
                catch {
                    let final = observation(profile,sessionID,turnID,attempt,cost:nil)
                    try await hooks.settleAttempt(.init(scope:hooks.scope,observation:final,dispatched:true)); throw error
                }
                reply = toolReply(["first"])
            }
        } else {
            children.append(sessionID)
            do {
                while !(allReleased || (firstReleased && !firstTaken)) { try permit.check(); try await Task.sleep(for:.milliseconds(2)) }
                try permit.check(); try Task.checkCancellation()
            } catch {
                cancelled.append(sessionID)
                let final = observation(profile,sessionID,turnID,attempt,cost:nil)
                try await hooks.settleAttempt(.init(scope:hooks.scope,observation:final,dispatched:true))
                throw error
            }
            let first = !firstTaken && !allReleased
            if first { firstTaken = true }
            cost = first ? 0.6 : 0.2
        }
        let observation = observation(profile,sessionID,turnID,attempt,cost:cost)
        try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
        if cost == 0.6 { firstSettled = true }
        await onObservation(observation); reply.message.requestAttemptIDs = [attempt]
        if mode == "retry" { throw AgentError("provider_http","HTTP 503 server unavailable",attemptID:attempt) }
        return reply
    }
}

private actor LimitHeldTools: ToolExecuting {
    var started = false, cancelled = false
    var starts = 0, cancellations = 0
    func definitions(readOnly:Bool) -> [ToolDefinition] { [ToolDefinition("first","Held fixture tool",[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON {
        started = true; starts += 1
        do { while true { try await Task.sleep(for:.milliseconds(2)) } }
        catch { cancelled = true; cancellations += 1; throw error }
    }
}

/// Review round 1 (Codex) regressions for the Resume lifecycle.
extension FamilyLimitPauseTests {
    private func steeringOwner(_ root: URL, client: any ModelClient, coordinator: AgentSteeringCoordinator) async throws -> AgentSession {
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        return owner
    }
    private func startChild(_ owner: AgentSession, _ coordinator: AgentSteeringCoordinator, _ id: String, newTask: Bool = true) async throws -> String {
        let call = ToolCall(id:id,name:"subagent_start",arguments:["task":JSON("Worker \(id)"),"mode":"background"])
        let key = try await owner.agentFixtureCall(call,newTask:newTask)
        let receipt = try await coordinator.prepare(call,key:key,parent:owner)
        return try XCTUnwrap(receipt["child_id"].text)
    }

    /// A Resume with no parked turn still releases the coordinator's hold:
    /// later delegation runs instead of queueing forever.
    func testResumeWithoutParkedTurnsReleasesTheCoordinatorHold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        await owner.beginResumeFixture()
        await owner.fixtureCostPause()
        await coordinator.pause(owner:owner,generation:0)
        let held = await coordinator.paused.contains("parent"); XCTAssertTrue(held)
        let reply = try await owner.continueRun(commandID:"resume")
        XCTAssertEqual(reply["resumedFamily"].flag,true); XCTAssertEqual(reply["continued"].flag,false)
        try await eventually(timeout:.seconds(2)) { !(await coordinator.paused.contains("parent")) }
        await client.releaseAll()
        _ = try await startChild(owner, coordinator, "after")
        try await eventually(timeout:.seconds(3)) { await client.children.count == 1 }
        await coordinator.drain(); await owner.close()
    }

    /// Resume waits for the pause's runners to finish parking: a turn still
    /// settling is resumed, not stranded without a continuation.
    func testResumeWaitsForTurnsStillParking() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        await coordinator.fixturePause("parent")
        let child = try await startChild(owner, coordinator, "settling")
        let target = AgentTurnTarget(childID:child,turn:1)
        await owner.beginResumeFixture(); await client.releaseAll()
        let resume = Task { try await coordinator.resumeParked(owner:owner,generation:0) }
        try await Task.sleep(for:.milliseconds(100))
        let early = await owner.agentState().turns[target.id]?.continuations
        XCTAssertNil(early,"Nothing is resumed while the turn is still settling")
        await coordinator.pause(owner:owner,generation:0)   // the pause's runner parks it now
        try await resume.value
        try await eventually { await owner.agentState().turns[target.id]?.status == .completed }
        let resumed = await owner.agentState().turns[target.id]
        XCTAssertEqual(resumed?.continuations?.count,1)
        await coordinator.drain(); await owner.close()
    }

    /// Delivery is decided from durable evidence: a task whose row left the
    /// loaded window (compaction, checkpoint) still continues; one accepted
    /// but not delivered is released, never submitted a second time.
    func testResumedTurnStartUsesDurableEvidence() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        await coordinator.fixturePause("parent")
        _ = try await startChild(owner, coordinator, "evidence")
        let jobs = await coordinator.jobs, job = try XCTUnwrap(jobs.values.first), turn = job.turn, child = try XCTUnwrap(job.child)
        let fresh = await child.agentTurnStart(turn); XCTAssertEqual(fresh,.fresh)
        await child.fixtureReceipt(turn.inputID,state:"delivered")
        let delivered = await child.agentTurnStart(turn)
        XCTAssertEqual(delivered,.delivered,"A receipt proves delivery when the row is not loaded")
        await child.fixtureForgetReceipts()
        await child.fixtureQueue(Submission(commandID:turn.executionID,turnID:turn.inputID,text:turn.task))
        var resumedTurn = turn; resumedTurn.continuations = [AgentTurnContinuation(parentExecutionID:turn.parentExecutionID,generation:0,runtimeID:turn.runtimeID,epoch:turn.epoch)]
        try await child.resumeAgentTurn(resumedTurn,owner:owner,coordinator:coordinator)
        let accepted = await child.agentTurnStart(resumedTurn), kept = await child.queue.map(\.turnID)
        XCTAssertEqual(accepted,.accepted); XCTAssertEqual(kept,[turn.inputID],"The accepted task is kept for release")
        await child.close(); await owner.close()
    }

    /// A resumed child that had already answered still takes its final
    /// boundary: steering accepted for that turn is delivered, not dropped.
    func testAnsweredResumedChildDeliversPendingSteeringBeforeSealing() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AnsweringChildClient(), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        let child = try await startChild(owner, coordinator, "answered")
        try await eventually { await client.waiting }
        await coordinator.fixturePause("parent")
        await client.release()
        try await eventually { await coordinator.jobs.isEmpty }
        let target = AgentTurnTarget(childID:child,turn:1)
        let parked = await owner.agentState().turns[target.id]?.status; XCTAssertEqual(parked,.queued)
        let sequence = await owner.agentState().sequence
        let steer = AgentFamilyMessage(id:"steer-1",sequence:sequence + 1,childID:child,turn:1,author:"parent",kind:"steer",text:"Also check escapes",task:"Worker",epoch:"e")
        try await owner.appendAgentRecord(JournalRecordKind.agentMessage,steer)
        await owner.beginResumeFixture()
        try await coordinator.resumeParked(owner:owner,generation:1)
        try await eventually { await owner.agentState().turns[target.id]?.status.terminal == true }
        let message = await owner.agentState().messages["steer-1"], requests = await client.requests
        XCTAssertEqual(message?.disposition,"delivered")
        XCTAssertEqual(requests,2,"The answered turn asks again only to answer the steering")
        await coordinator.drain(); await owner.close()
    }

    /// Side membership survives the root's Resume until each side resumes;
    /// a retried Resume still names them; a refused Resume changes nothing.
    func testRootKeepsPausedSidesUntilTheyResumeAndRefusalsChangeNothing() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([answer("Went on")]),tools:RecordingTools(),traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.setCostLimit(5)
        try await owner.append(ChatMessage(role:"user",content:[textBlock("Go on")]))
        await owner.fixtureCostPause()
        await owner.notePausedMember("side-a"); await owner.notePausedMember("side-b")
        // An invalid override fails validation after the pause was checked.
        do { _ = try await owner.continueRun(commandID:"bad",overrides:["input":5]); XCTFail("Invalid input accepted") } catch {}
        let stillPaused = await owner.costPaused, kept = await owner.costPausedMembers
        XCTAssertTrue(stillPaused,"A refused Resume leaves the pause"); XCTAssertEqual(kept,["side-a","side-b"])
        await owner.stop()
        let reply = try await owner.continueRun(commandID:"resume")
        XCTAssertEqual(reply["pausedMembers"].list.compactMap(\.text),["side-a","side-b"])
        let retained = await owner.costPausedMembers; XCTAssertEqual(retained,["side-a","side-b"])
        await owner.stop()
        let again = try await owner.continueRun(commandID:"resume")
        XCTAssertEqual(again["duplicate"].flag,true)
        XCTAssertEqual(again["pausedMembers"].list.compactMap(\.text),["side-a","side-b"],"A lost reply can be retried")
        await owner.forgetPausedMember("side-a")
        let left = await owner.costPausedMembers; XCTAssertEqual(left,["side-b"])
        await owner.close()
    }
}

private extension AgentSession {
    func fixtureCostPause() {
        costPaused = true; queuePaused = true; errorCode = AgentSession.costLimitCode; errorMessage = costPausedMessage
        if runTask == nil { state = .paused; runStatus = .cancelled }
    }
    func fixtureReceipt(_ turnID: String, state: String) { commands.append(["commandId":JSON(UUID().uuidString),"turnId":JSON(turnID),"state":JSON(state),"status":JSON(state)]) }
    func fixtureForgetReceipts() { commands.removeAll() }
    func fixtureQueue(_ submission: Submission) { queue.append(submission) }
}

/// The child's first request is held until released, then answers; any
/// later request answers too. Costs are tiny.
private actor AnsweringChildClient: ModelClient {
    var waiting = false, released = false, requests = 0
    func release() { released = true }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Expected admission")
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,cacheSessionID:String,turnID:String,purpose:String,lifecycle:RequestLifecycle?,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), attempt = UUID().uuidString
        let permit = try await hooks.admitAttempt(attempt); defer { permit.finish() }
        try await hooks.willDispatch(attempt)
        requests += 1
        if requests == 1 { waiting = true; while !released { try await Task.sleep(for:.milliseconds(2)) } }
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:"turn",fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.001]]]
        try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
        await onObservation(observation)
        var reply = answer(requests == 1 ? "Child answer" : "Steered answer"); reply.message.requestAttemptIDs = [attempt]
        return reply
    }
}
