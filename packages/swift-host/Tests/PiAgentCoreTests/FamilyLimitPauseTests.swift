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
            // No drain fence, and not Stop (owner, 2026-10-17): the crossing
            // settlement cuts the other model requests and nothing else.
            let stopped = await owner.stopCount, issued = await owner.budgetStopIssued
            XCTAssertEqual(stopped,0,"\(label): the pause is not Stop"); XCTAssertTrue(issued,label)
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
            XCTAssertEqual(again,0,"\(label): repeated readings change nothing")
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
        // The root's dispatched request is cut at once; the nested side's
        // running tool is not (owner, 2026-10-17): it finishes for real.
        XCTAssertThrowsError(try held.1.check())
        try await eventually(timeout:.seconds(2)) { await nested.costPaused }
        try await Task.sleep(for:.milliseconds(100))
        let cut = await tools.cancelled, busy = await nested.isRunning
        XCTAssertFalse(cut,"A running tool survives the pause"); XCTAssertTrue(busy)
        await tools.release()
        try await eventually(timeout:.seconds(2)) { !(await nested.isRunning) }
        let code = await nested.errorCode, state = await nested.state, paused = await nested.costPaused
        XCTAssertEqual(code,"cost_limit"); XCTAssertEqual(state,.paused); XCTAssertTrue(paused)
        let result = await nested.history.last { $0.role == "toolResult" }?.text
        XCTAssertEqual(result,"REAL RESULT 1","The tool's real result is recorded")
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
        let after = await nested.costPaused, members = await owner.costPausedMembers, cuts = await tools.cancellations
        XCTAssertEqual(cuts,0)
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
        try await eventually(timeout:.seconds(2)) { await side.costPaused }
        let stops = await owner.stopCount, running = await side.isRunning
        XCTAssertEqual(stops,0); XCTAssertTrue(running,"Its tool goes on")
        await tools.release()
        try await eventually(timeout:.seconds(2)) { !(await side.isRunning) }
        let finished = await tools.finished, cuts = await tools.cancellations
        XCTAssertEqual(finished,1); XCTAssertEqual(cuts,0)
        await owner.setCostLimit(0.5); await owner.stopFamilyAtLimit()
        let again = await owner.stopCount; XCTAssertEqual(again,0)
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
    func fixturePark(_ id: String) async { if let job = jobs[id] { await park(job,child:job.child) } }
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

/// Each invocation runs until `release()` lets it finish with its real result.
private actor LimitHeldTools: ToolExecuting {
    var started = false, cancelled = false
    var starts = 0, cancellations = 0, releases = 0, finished = 0
    func release() { releases += 1 }
    func definitions(readOnly:Bool) -> [ToolDefinition] { [ToolDefinition("first","Held fixture tool",[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON {
        started = true; starts += 1; let number = starts
        do { while releases < number { try await Task.sleep(for:.milliseconds(2)) } }
        catch { cancelled = true; cancellations += 1; throw error }
        finished += 1
        return resultText("REAL RESULT \(number)")
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
        await coordinator.pause(owner:owner,generation:1)
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
        let tools = LimitHeldTools(), client = ChildToolClient(), coordinator = AgentSteeringCoordinator()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        await owner.setCostLimit(0.5)
        let child = try await startChild(owner, coordinator, "settling")
        let target = AgentTurnTarget(childID:child,turn:1)
        try await eventually { await tools.started }
        let crossing = try await start(owner,"crossing"); try await finish(crossing.0,"crossing",cost:0.6)
        await owner.setCostLimit(5); try await owner.requireCostResumeRoom()
        _ = try await owner.continueRun(commandID:"resume")
        try await Task.sleep(for:.milliseconds(100))
        let early = await owner.agentState().turns[target.id]?.continuations
        XCTAssertNil(early,"Nothing is resumed while the child's tool still runs")
        await tools.release()   // it finishes; the child's gate holds and it parks
        try await eventually { await owner.agentState().turns[target.id]?.status == .completed }
        let resumed = await owner.agentState().turns[target.id], finished = await tools.finished
        XCTAssertEqual(resumed?.continuations?.count,1); XCTAssertEqual(finished,1,"The tool ran once, to its end")
        try await eventually { !(await owner.isRunning) }
        await coordinator.drain(); await owner.close()
    }

    /// Delivery is decided from durable evidence: a task whose row left the
    /// loaded window (compaction, checkpoint) still continues; one accepted
    /// but not delivered is released, never submitted a second time.
    func testResumedTurnStartUsesDurableEvidence() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), opened = OpenedChildren()
        // Parked children are released by `settled`; keep this one open to inspect.
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            let child = try AgentSteeringCoordinator.makeChild(env,plan); await opened.add(child); return child
        }, settled:{ _ in })
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        await coordinator.fixturePause("parent")
        let id = try await startChild(owner, coordinator, "evidence")
        try await eventually { await coordinator.jobs.isEmpty }
        let state = await owner.agentState(), turn = try XCTUnwrap(state.latest(id)), list = await opened.children, child = try XCTUnwrap(list.first)
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
    /// boundary before its run ends: its turn is sealed (or pending steering
    /// delivered) before the final request links are written, so a parent
    /// message sent meanwhile becomes a follow-up, never stranded steering.
    func testAnsweredResumedChildSealsAtItsFinalBoundary() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AnsweringChildClient(), probe = FinalLinksProbe()
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            let child = try AgentSteeringCoordinator.makeChild(env,plan)
            await child.fixtureFinalLinks { await probe.observe() }
            return child
        })
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        await probe.watch(owner)
        let child = try await startChild(owner, coordinator, "answered")
        try await eventually { await client.waiting }
        await coordinator.fixturePause("parent")
        await client.release()
        try await eventually { await coordinator.jobs.isEmpty }
        let target = AgentTurnTarget(childID:child,turn:1)
        let parked = await owner.agentState().turns[target.id]?.status; XCTAssertEqual(parked,.queued)
        await probe.reset(target)
        await owner.beginResumeFixture()
        try await coordinator.resumeParked(owner:owner,generation:1)
        try await eventually { await owner.agentState().turns[target.id]?.status.terminal == true }
        let seen = await probe.seen, requests = await client.requests
        XCTAssertEqual(seen,.completed,"Sealed at the final boundary, before the run's last writes")
        XCTAssertEqual(requests,1,"An answered turn asks nothing again")
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
        costPaused = true; queuePaused = true; costPauseCount &+= 1; errorCode = AgentSession.costLimitCode; errorMessage = costPausedMessage
        if runTask == nil { state = .paused; runStatus = .cancelled }
    }
    func fixtureReceipt(_ turnID: String, state: String) { commands.append(["commandId":JSON(UUID().uuidString),"turnId":JSON(turnID),"state":JSON(state),"status":JSON(state)]) }
    func fixtureForgetReceipts() { commands.removeAll() }
    func fixtureQueue(_ submission: Submission) { queue.append(submission) }
    func fixtureFinalLinks(_ probe: @escaping @Sendable () async -> Void) { beforeFinalRequestLinks = probe }
}

/// Records the owner's view of a turn when a resumed child's run reaches its
/// final request-link writes.
private actor FinalLinksProbe {
    var owner: AgentSession?, target: AgentTurnTarget?, seen: SubagentStatus?
    func watch(_ owner: AgentSession) { self.owner = owner }
    func reset(_ target: AgentTurnTarget) { self.target = target; seen = nil }
    func observe() async {
        guard let owner, let target, seen == nil else { return }
        seen = await owner.agentState().turns[target.id]?.status
    }
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

/// Review round 2 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A child accepted just before the pause, whose runtime was still
    /// opening, parks when it is inserted: it never waits in a queue nothing
    /// pumps, and Resume does not wait for it forever.
    func testAChildOpenedAcrossThePauseParksOnInsertion() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate = OpenGate(), client = LimitRunClient(mode:"queued")
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            await gate.wait()
            return try AgentSteeringCoordinator.makeChild(env,plan)
        })
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        let call = ToolCall(id:"late",name:"subagent_start",arguments:["task":"Late","mode":"background"])
        let key = try await owner.agentFixtureCall(call,newTask:true)
        let accepting = Task { try await coordinator.prepare(call,key:key,parent:owner) }
        try await eventually { await gate.waiting }
        await coordinator.fixturePause("parent")
        await gate.open()
        let receipt = try await accepting.value, child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually(timeout:.seconds(2)) { await coordinator.jobs.isEmpty }
        let status = await owner.agentState().latest(child)?.status
        XCTAssertEqual(status,.queued,"Parked at insertion")
        let dispatched = await client.children.count; XCTAssertEqual(dispatched,0)
        await owner.beginResumeFixture(); await client.releaseAll()
        try await coordinator.resumeParked(owner:owner,generation:1)
        try await eventually { await owner.agentState().latest(child)?.status == .completed }
        await coordinator.drain(); await owner.close()
    }

    /// Stop while Resume waits for a child's running tool: the wait ends at
    /// once, the child's run is halted, and the family stays paused.
    func testStopWhileResumeWaitsHaltsHeldChildrenAndKeepsThePause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tools = LimitHeldTools(), client = ChildToolClient(), coordinator = AgentSteeringCoordinator()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        await owner.setCostLimit(0.5)
        let call = ToolCall(id:"tooling",name:"subagent_start",arguments:["task":"Use the tool","mode":"background","tools":["first"]])
        let key = try await owner.agentFixtureCall(call,newTask:true)
        _ = try await coordinator.prepare(call,key:key,parent:owner)
        try await eventually { await tools.started }
        let crossing = try await start(owner,"crossing")
        try await finish(crossing.0,"crossing",cost:0.6)
        let paused = await owner.costPaused; XCTAssertTrue(paused)
        await owner.setCostLimit(5); try await owner.requireCostResumeRoom()
        _ = try await owner.continueRun(commandID:"resume")
        try await Task.sleep(for:.milliseconds(100))
        let waiting = await owner.isRunning; XCTAssertTrue(waiting,"Resume waits for the child's running tool")
        await owner.stop()
        try await eventually(timeout:.seconds(2)) { !(await owner.isRunning) }
        let again = await owner.costPaused; XCTAssertTrue(again,"The family stays paused for the next Resume")
        try await eventually(timeout:.seconds(2)) { await coordinator.jobs.isEmpty }
        let halted = await tools.cancelled; XCTAssertTrue(halted,"Stop halts the held child's run")
        await coordinator.drain(); await owner.close()
    }

    /// A parked child whose task was accepted but not delivered can still be
    /// unloaded: its input is durable, and Resume reopens it.
    func testAParkedChildWithHeldInputUnloads() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let opened = OpenedChildren()
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            let child = try AgentSteeringCoordinator.makeChild(env,plan); await opened.add(child); return child
        }, settled:{ _ in })
        let owner = try await steeringOwner(root, client:LimitRunClient(mode:"queued"), coordinator:coordinator)
        await coordinator.fixturePause("parent")
        let id = try await startChild(owner, coordinator, "held-input")
        try await eventually { await coordinator.jobs.isEmpty }
        let state = await owner.agentState(), turn = try XCTUnwrap(state.latest(id)), list = await opened.children, child = try XCTUnwrap(list.first)
        await child.fixtureQueue(Submission(commandID:turn.executionID,turnID:turn.inputID,text:turn.task))
        let unloaded = await child.unloadIfIdle()
        XCTAssertTrue(unloaded,"Held input does not pin a parked child")
        await owner.close()
    }

    /// Pause generations belong to the owner runtime: after a resumed owner
    /// is replaced by a reopened one (its count starts again), the new
    /// runtime's first pause still holds its children.
    func testAReopenedOwnersFirstPauseIsNotMistakenForAnOldOne() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator()
        let first = try familyFixture(root:root)
        try await coordinator.resumeParked(owner:first,generation:1)
        let saved = await first.path; await first.close()
        let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:saved)
        await coordinator.pause(owner:reopened,generation:1)
        let held = await coordinator.paused.contains("parent"); XCTAssertTrue(held)
        await reopened.close()
    }
}

private actor OpenedChildren {
    var children: [AgentSession] = []
    func add(_ child: AgentSession) { children.append(child) }
}

private actor OpenGate {
    var waiting = false, opened = false
    func wait() async { waiting = true; while !opened { try? await Task.sleep(for:.milliseconds(2)) } }
    func open() { opened = true }
}

/// The child's first request asks for the "first" tool; later requests
/// answer. The parent is driven by fixtures and sends no requests.
private actor ChildToolClient: ModelClient {
    var requests = 0
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Expected admission")
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,cacheSessionID:String,turnID:String,purpose:String,lifecycle:RequestLifecycle?,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), attempt = UUID().uuidString
        let permit = try await hooks.admitAttempt(attempt); defer { permit.finish() }
        try await hooks.willDispatch(attempt)
        requests += 1
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:"turn",fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
        await onObservation(observation)
        var reply = requests == 1 ? toolReply(["first"]) : answer("Used the tool"); reply.message.requestAttemptIDs = [attempt]
        return reply
    }
}

/// Review round 3 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A pause that ends by itself (the crossing reply was the run's last
    /// word) also releases the coordinator: later sub-agents run.
    func testAnAutomaticallyClearedPauseReleasesTheCoordinator() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AnsweringChildClient(), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        await owner.setCostLimit(0.0005)
        _ = try await owner.submit(Submission(commandID:"command",turnID:"turn",text:"Answer"),steer:false)
        try await eventually { await client.waiting }
        await client.release()
        try await eventually { !(await owner.isRunning) }
        let paused = await owner.costPaused; XCTAssertFalse(paused,"Nothing waits: not left paused")
        try await eventually(timeout:.seconds(2)) { !(await coordinator.paused.contains("parent")) }
        await owner.setCostLimit(5)
        _ = try await startChild(owner, coordinator, "later")
        try await eventually(timeout:.seconds(3)) { await client.requests >= 2 }
        await coordinator.drain(); await owner.close()
    }

    /// Stop or quit sealed a resumed turn whose child never ran: its mirror
    /// lacks the continuation. Reopening catches the mirror up first instead
    /// of failing the whole family.
    func testReopenRepairsAMirrorThatMissedAContinuationBeforeSealing() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:LimitRunClient(mode:"queued"), coordinator:coordinator)
        await coordinator.fixturePause("parent")
        let id = try await startChild(owner, coordinator, "stale")
        try await eventually { await coordinator.jobs.isEmpty }
        let state = await owner.agentState(), plans = await owner.subagents.plans
        var turn = try XCTUnwrap(state.latest(id)); let plan = try XCTUnwrap(plans.values.first)
        turn.continuations = [AgentTurnContinuation(parentExecutionID:turn.parentExecutionID,generation:0,runtimeID:turn.runtimeID,epoch:turn.epoch)]
        try await owner.appendAgentRecord(JournalRecordKind.agentTurnState,turn)
        var sealed = turn; sealed.status = .notExecuted
        sealed.result = SubagentToolResult(plan:plan,status:.notExecuted,error:AgentError("subagent_stopped","Stopped before execution")); sealed.normalizeResult()
        try await owner.appendAgentRecord(JournalRecordKind.agentTerminal,sealed)
        let saved = await owner.path, path = try XCTUnwrap(saved)
        await owner.close()
        let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),resumePath:path)
        let child = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:root.appendingPathComponent(id + ".jsonl").path)
        let mirror = await child.agentState().turns[turn.id]
        XCTAssertEqual(mirror?.status,.notExecuted); XCTAssertEqual(mirror?.continuations?.count,1)
        await child.close(); await reopened.close()
    }

    /// A Compact Now refused during the pause is done again on Resume, and
    /// the paused sub-agents still resume (not stranded behind it).
    func testCompactionRedoneOnResumeStillResumesParkedChildren() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"background"), coordinator = AgentSteeringCoordinator()
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableFamilyBudget(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        await parent.setCostLimit(0.5)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"turn",text:"Two workers"),steer:false)
        try await eventually { await client.children.count == 2 }
        await client.releaseFirst()
        try await eventually(timeout:.seconds(3)) { let busy = await parent.isRunning, jobs = await coordinator.jobs.isEmpty; return !busy && jobs }
        try await parent.compact()
        try await eventually { !(await parent.isRunning) }
        let pending = await parent.costPendingCompaction, paused = await parent.costPaused
        XCTAssertTrue(pending,"The refused compaction waits for Resume"); XCTAssertTrue(paused)
        await parent.setCostLimit(20); await client.releaseAll()
        _ = try await parent.continueRun(commandID:"resume")
        try await eventually(timeout:.seconds(10)) { let busy = await parent.isRunning, jobs = await coordinator.jobs.isEmpty; return !busy && jobs }
        let family = await parent.agentState(), still = await parent.costPendingCompaction
        XCTAssertTrue(family.turns.values.allSatisfy { $0.status == .completed },"\(family.turns.values.map(\.status))")
        XCTAssertFalse(still)
        await coordinator.drain(); await parent.close()
    }

    /// The root's list of paused sides follows each side's own durable pause
    /// when the side binds again (a crash between the two saves).
    func testSideBindingRepairsTheRootsPausedMembers() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root)
        await owner.setCostLimit(5)
        let side = try await self.side("side",parent:owner,root:root)
        await side.fixtureCostPause()
        try await side.bindSideBudget(to:owner)
        let members = await owner.costPausedMembers, rootPaused = await owner.costPaused
        XCTAssertEqual(members,["side"]); XCTAssertTrue(rootPaused)
        await side.fixtureEndPause()
        try await side.bindSideBudget(to:owner)
        let after = await owner.costPausedMembers; XCTAssertTrue(after.isEmpty)
        await side.close(); await owner.close()
    }
}

private extension AgentSession {
    func fixtureEndPause() { costPaused = false; queuePaused = false; errorCode = nil; errorMessage = nil }
}

/// Review round 4 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// The pause arrives while an agent-control call waits for its
    /// admission: the closed admission (delegation unavailable once paused)
    /// holds the call for Resume instead of giving it a permanent failure.
    func testAPauseDuringAgentControlAdmissionHoldsTheCall() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator()
        let client = ScriptClient([agentCallReply("start-0","subagent_start",["task":"Worker","mode":"background"]), answer("Done")])
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        let lock = await coordinator.gate("parent"); try await lock.acquire()
        _ = try await owner.submit(Submission(commandID:"command",turnID:"turn",text:"Delegate"),steer:false)
        try await eventually { await owner.runStatus == .waitingTool }
        try await Task.sleep(for:.milliseconds(50))
        await owner.pauseAtCostLimit(AgentError(AgentSession.costLimitCode,"Fixture limit"))
        await lock.release()
        try await eventually { !(await owner.isRunning) }
        let results = await owner.history.filter { $0.role == "toolResult" }
        XCTAssertTrue(results.isEmpty, "Held, not failed: \(results.map(\.text))")
        let pending = await owner.costPendingCalls, paused = await owner.costPaused
        XCTAssertEqual(pending,["start-0"]); XCTAssertTrue(paused)
        await coordinator.drain(); await owner.close()
    }

    /// A turn parking at the pause lists as paused as soon as its queued
    /// state is saved, before its job goes; when the job goes, the family's
    /// discovery revision changes, so no reader keeps a stale queued row.
    func testAParkingTurnListsItsPauseAndItsJobsEndIsPublished() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate = OpenGate(), opened = OpenedChildren(), client = LimitRunClient(mode:"queued")
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            let child = try AgentSteeringCoordinator.makeChild(env,plan); await opened.add(child); return child
        }, settled:{ _ in await gate.wait() })
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        let id = try await startChild(owner, coordinator, "parking")
        try await eventually { await client.children.count == 1 }
        let target = AgentTurnTarget(childID:id,turn:1)
        await owner.fixtureCostPause()
        await coordinator.pause(owner:owner,generation:1)
        try await eventually { await gate.waiting }
        let status = await owner.agentState().turns[target.id]?.status
        XCTAssertEqual(status,.queued)
        let page = await coordinator.list(parent:owner,cursor:0,limit:10)
        XCTAssertEqual(page["children"].list.first?["costPaused"].flag,true,"Listed as paused while still parking")
        let before = await owner.snapshot()["subagentsRevision"]
        await gate.open()
        try await eventually { await coordinator.jobs.isEmpty }
        let after = await owner.snapshot()["subagentsRevision"]
        XCTAssertNotEqual(after,before,"The job's end is published")
        for child in await opened.children { await child.close() }
        await coordinator.drain(); await owner.close()
    }
}

/// Review round 5 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A pause's parking loop holds a snapshot across awaits. A Resume that
    /// reinstalled a turn under a new job meanwhile keeps that job: parking
    /// the stale snapshot acts on nothing, and the family completes.
    func testAStaleParkNeverRemovesAJobAResumeInstalled() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        for n in 0..<17 { _ = try await startChild(owner, coordinator, "turn-\(n)", newTask: n == 0) }
        try await eventually { await client.children.count == 16 }
        let queued = await coordinator.jobs.values.first { !$0.allocated }
        let stale = try XCTUnwrap(queued)
        await owner.fixtureCostPause()
        await coordinator.pause(owner:owner,generation:1)
        try await eventually(timeout:.seconds(5)) { await coordinator.jobs.isEmpty }
        await owner.fixtureEndPause(); await owner.beginResumeFixture()
        try await coordinator.resumeParked(owner:owner,generation:1)
        let reinstalled = await coordinator.jobs[stale.turn.id]
        XCTAssertNotNil(reinstalled)
        await coordinator.park(stale,child:nil)
        let kept = await coordinator.jobs[stale.turn.id]
        XCTAssertNotNil(kept,"The Resume's job for the turn is kept")
        XCTAssertEqual(kept?.parking,false,"Nor is it marked as parking, which would refuse its own park later")
        XCTAssertNotEqual(kept?.instance,stale.instance)
        await client.releaseAll()
        try await eventually(timeout:.seconds(10)) { await owner.agentState().turns.values.allSatisfy { $0.status == .completed } }
        await coordinator.drain(); await owner.close()
    }

    /// After the root's Resume, reopening a side it still lists (the app
    /// resumes it next) binds the side again: the root is not paused again,
    /// and the side stays listed until it resumes itself.
    func testRebindingASideTheRootsResumeCoversDoesNotPauseTheRootAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root)
        await owner.setCostLimit(5)
        let side = try await self.side("side",parent:owner,root:root)
        await side.fixtureCostPause()
        try await side.bindSideBudget(to:owner)
        var rootPaused = await owner.costPaused
        XCTAssertTrue(rootPaused, "A missing membership is repaired with the pause")
        let reply = try await owner.continueRun(commandID:"resume")
        XCTAssertEqual(reply["pausedMembers"].list.compactMap(\.text),["side"])
        rootPaused = await owner.costPaused; XCTAssertFalse(rootPaused)
        try await side.bindSideBudget(to:owner)
        rootPaused = await owner.costPaused
        let members = await owner.costPausedMembers
        XCTAssertFalse(rootPaused, "The root's Resume already covers the side")
        XCTAssertEqual(members,["side"])
        await side.fixtureEndPause()
        try await side.bindSideBudget(to:owner)
        let after = await owner.costPausedMembers; XCTAssertTrue(after.isEmpty)
        await side.close(); await owner.close()
    }
}

/// Review round 6 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// The Resume fence belongs to one owner runtime. A later runtime at the
    /// same address (a freed runtime's memory reused) still pauses.
    func testAPauseFenceIsNotInheritedByARuntimeAtAReusedAddress() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator()
        var reused = false
        for attempt in 0..<64 {
            var first: AgentSession? = try await steeringOwner(root.appendingPathComponent("a\(attempt)"), client:ScriptClient([]), coordinator:coordinator)
            let address = ObjectIdentifier(first!)
            await first!.beginResumeFixture()
            try await coordinator.resumeParked(owner:first!,generation:5)
            await first!.close(); first = nil
            let second = try await steeringOwner(root.appendingPathComponent("b\(attempt)"), client:ScriptClient([]), coordinator:coordinator)
            if ObjectIdentifier(second) == address {
                reused = true
                await coordinator.pause(owner:second,generation:1)
                let paused = await coordinator.paused.contains(second.id)
                XCTAssertTrue(paused,"A new runtime's first pause applies")
                await second.close(); break
            }
            await second.close()
        }
        try XCTSkipUnless(reused, "No address was reused in 64 attempts")
    }

    /// Editing an earlier message of a family whose turns the pause parked
    /// is refused as it is while those turns run (session_busy): Resume never
    /// restarts an abandoned branch's sub-agent work under the edit. So is it
    /// for parked turns left once the pause flag is gone.
    func testEditIsRefusedWhileThePauseHoldsParkedTurns() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        let message = try await owner.fixtureUserMessage("Delegate the work")
        _ = try await startChild(owner, coordinator, "parked")
        try await eventually { await client.children.count == 1 }
        await owner.fixtureCostPause()
        await coordinator.pause(owner:owner,generation:1)
        try await eventually(timeout:.seconds(5)) { await coordinator.jobs.isEmpty }
        await owner.setCostLimit(50)
        for phase in ["paused", "flag cleared"] {
            if phase == "flag cleared" { await owner.fixtureEndPause() }
            let idle = await owner.isIdle; XCTAssertTrue(idle, phase)
            do {
                _ = try await owner.edit(fromMessageID:message, input:Submission(commandID:UUID().uuidString,turnID:UUID().uuidString,text:"Something else"))
                XCTFail("\(phase): an edit abandoned parked work")
            } catch { XCTAssertEqual((error as? AgentError)?.code,"session_busy",phase) }
        }
        let parked = await owner.agentState().turns.values.filter { !$0.status.terminal }.count
        XCTAssertEqual(parked,1,"The parked turn waits for Resume")
        await client.releaseAll(); await coordinator.drain(); await owner.close()
    }
}

private extension AgentSession {
    func fixtureUserMessage(_ text: String) throws -> String {
        var row = ChatMessage(role:"user",content:[textBlock(text)]); row.id = UUID().uuidString
        try append(row); return row.id
    }
}

/// Review round 7 (Codex) regressions: the family's pause is latched, and
/// its sides' membership follows Resume, repair and deletion.
extension FamilyLimitPauseTests {
    /// A side pause issued at the limit still applies after the limit was
    /// raised (only Resume undoes a pause); one issued before a Resume does not.
    func testASidePauseIssuedBeforeARaiseStillPausesTheSide() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), tools = LimitHeldTools()
        await owner.setCostLimit(0.5)
        let side = try await side("side",parent:owner,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
        _ = try await side.submit(Submission(commandID:"command",turnID:"turn",text:"Work"),steer:false)
        try await eventually { await tools.started }
        await owner.setCostLimit(5)
        let resumes = await owner.costResumeCount
        let stops = await owner.sideBudgetStops
        let notify = try XCTUnwrap(stops["side"])
        await notify(AgentSession.costHoldError, resumes - 1)
        var paused = await side.costPaused; XCTAssertFalse(paused, "A pause older than a Resume is retired")
        await notify(AgentSession.costHoldError, resumes)
        paused = await side.costPaused; XCTAssertTrue(paused, "The latched pause holds the side after a raise")
        await tools.release()
        try await eventually { !(await side.isRunning) }
        let calls = await tools.starts; XCTAssertEqual(calls,1,"Its running tool finished; nothing new started")
        await side.close(); await owner.close()
    }

    /// A side asks its root's latched pause before any request, as it shares
    /// its spend: with the root paused (its limit since raised), the side's
    /// new message sends nothing and the side waits for Resume.
    func testASideStartsNothingWhileItsRootIsPausedAfterARaise() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), client = ScriptClient([answer("Side answer")])
        await owner.setCostLimit(5)
        let side = try await side("side",parent:owner,root:root,client:client)
        await owner.fixtureCostPause()
        _ = try await side.submit(Submission(commandID:"command",turnID:"turn",text:"Work"),steer:false)
        try await eventually { !(await side.isRunning) }
        let sent = await client.count, paused = await side.costPaused
        XCTAssertEqual(sent,0,"No request while the family is paused"); XCTAssertTrue(paused)
        await side.close(); await owner.close()
    }

    /// A side's durable pause repaired into a root that is running (after a
    /// raise) pauses the root as the limit does: its request in flight is
    /// cut and the pause has a new generation.
    func testRepairingASidesPauseIntoARunningRootPausesItFully() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root)
        await owner.setCostLimit(5)
        let side = try await side("side",parent:owner,root:root)
        await side.fixtureCostPause()
        let before = await owner.costPauseCount
        let held = try await start(owner,"held")
        try await side.bindSideBudget(to:owner)
        XCTAssertThrowsError(try held.1.check(),"The root's request in flight is cut")
        let after = await owner.costPauseCount, paused = await owner.costPaused
        XCTAssertEqual(after,before + 1); XCTAssertTrue(paused)
        try await finish(held.0,"held",cost:0.01)
        await side.close(); await owner.close()
    }

    /// The root's own Resume was accepted, its sides not yet resumed (the app
    /// quit in between): the root still shows the family's pause and offers
    /// Resume, which hands the sides out again.
    func testARootWithSidesStillWaitingKeepsOfferingTheFamilysResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // An ordinary chat (`DisabledTools` would make it a connection test).
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        await owner.setCostLimit(5)
        let side = try await side("side",parent:owner,root:root)
        await side.fixtureCostPause()
        try await side.bindSideBudget(to:owner)
        let first = try await owner.continueRun(commandID:"resume")
        XCTAssertEqual(first["pausedMembers"].list.compactMap(\.text),["side"])
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["costPaused"].flag,true); XCTAssertEqual(snapshot["cost"]["paused"].flag,true)
        XCTAssertEqual(snapshot["state"].text,"paused"); XCTAssertEqual(snapshot["continuable"].flag,true)
        let again = try await owner.continueRun(commandID:"resume-again")
        XCTAssertEqual(again["pausedMembers"].list.compactMap(\.text),["side"],"Resume hands the waiting side out again")
        let ownPause = await owner.costPaused; XCTAssertFalse(ownPause,"Nothing of the root's own is held")
        await side.close(); await owner.close()
    }

    /// An unkept side ends with its runtime: closing it takes it off its
    /// root's list, and a root paused only for it is not paused.
    func testClosingAnUnkeptPausedSideTakesItOffItsRootsPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root)
        await owner.setCostLimit(5)
        let side = try await side("side",parent:owner,root:root)
        await side.fixtureCostPause()
        try await side.bindSideBudget(to:owner)
        var members = await owner.costPausedMembers; XCTAssertEqual(members,["side"])
        await side.close()
        members = await owner.costPausedMembers
        let paused = await owner.costPaused
        XCTAssertTrue(members.isEmpty); XCTAssertFalse(paused)
        await owner.close()
    }

    /// A listed side whose journal is gone (deleted while the root was not
    /// loaded) is dropped when the root reopens, and a pause held only for it ends.
    func testAReopenedRootDropsListedSidesThatNoLongerExist() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore())
        await owner.notePausedMember("ghost")
        let paused = await owner.costPaused; XCTAssertTrue(paused)
        let saved = await owner.path, path = try XCTUnwrap(saved); await owner.close()
        let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path)
        let members = await reopened.costPausedMembers, still = await reopened.costPaused
        XCTAssertTrue(members.isEmpty); XCTAssertFalse(still)
        await reopened.close()
    }
}

/// Review round 8 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A side's summary request asks the family's latched pause as its turn
    /// requests do: with its root paused (the limit since raised) none goes.
    func testASidesSummaryRequestWaitsForTheFamilysResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), client = ScriptClient([answer("Summary")])
        await owner.setCostLimit(5)
        let side = try await side("side",parent:owner,root:root,client:client)
        await owner.fixtureCostPause()
        do { try await side.fixtureSummaryRequest(); XCTFail("A summary request went while the family was paused") }
        catch { XCTAssertEqual((error as? AgentError)?.code,AgentSession.costLimitCode) }
        let sent = await client.count; XCTAssertEqual(sent,0)
        await side.close(); await owner.close()
    }
}

private extension AgentSession {
    func fixtureSummaryRequest() async throws {
        var used = 0
        _ = try await summaryReply([],instructions:"",tools:[],profile:turnProfile,originalProfile:turnProfile,revision:contextMutation,limit:1,
                                   retry:.init(enabled:false,maxRetries:0,baseDelayMs:0),used:&used)
    }
}

/// Review round 9 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A Resume refused after the pause was ended in memory (here, an
    /// invalid override) restores the Resume count too: a side pause issued
    /// before it still applies.
    func testARefusedResumeKeepsPendingSidePausesValid() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        await owner.setCostLimit(5)
        _ = try await owner.fixtureUserMessage("Go on")
        await owner.fixtureCostPause()
        let before = await owner.costResumeCount
        do { _ = try await owner.continueRun(commandID:"resume",overrides:["thinkingLevel":"nonsense"]); XCTFail("An invalid override was accepted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"invalid_params") }
        let after = await owner.costResumeCount, paused = await owner.costPaused
        XCTAssertEqual(after,before,"Nothing was resumed"); XCTAssertTrue(paused)
        await owner.close()
    }
}

/// Review round 10 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A child stopped by the reader and still settling when the pause lands
    /// is sealed as stopped, not parked for Resume to restart.
    func testAChildStoppedBeforeThePauseIsNotParked() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        let id = try await startChild(owner, coordinator, "stopped")
        try await eventually { await client.children.count == 1 }
        let target = AgentTurnTarget(childID:id,turn:1)
        await coordinator.stop(owner:"parent",target:target,human:true)
        await coordinator.fixturePause("parent")
        try await eventually(timeout:.seconds(5)) { await coordinator.jobs.isEmpty }
        let state = await owner.agentState(), status = try XCTUnwrap(state.turns[target.id]?.status)
        XCTAssertTrue(status.terminal, "Sealed, not kept for Resume: \(status)")
        await client.releaseAll(); await coordinator.drain(); await owner.close()
    }
}

/// Review round 11 (Codex) regressions.
extension FamilyLimitPauseTests {
    /// A paused owner whose task root a compaction summarized away (reopened
    /// with no user row in context) still resumes its parked children.
    func testResumeWithoutATaskRootStillResumesParkedChildren() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root, client:client, coordinator:coordinator)
        _ = try await startChild(owner, coordinator, "parked")
        try await eventually { await client.children.count == 1 }
        await owner.fixtureCostPause()
        await coordinator.pause(owner:owner,generation:1)
        try await eventually(timeout:.seconds(5)) { await coordinator.jobs.isEmpty }
        await owner.fixtureForgetTask()
        await client.releaseAll()
        _ = try await owner.continueRun(commandID:"resume")
        try await eventually(timeout:.seconds(10)) {
            let busy = await owner.isRunning, jobs = await coordinator.jobs.isEmpty
            return !busy && jobs
        }
        let state = await owner.agentState(), paused = await owner.costPaused
        XCTAssertTrue(state.turns.values.allSatisfy { $0.status == .completed }, "\(state.turns.values.map(\.status))")
        XCTAssertFalse(paused, "Resume did not fail back into the pause")
        await coordinator.drain(); await owner.close()
    }

    /// A side's accepted Resume that is still waiting for its children to
    /// finish parking keeps its place in the root's list until its run has
    /// taken the work: a crash then still finds it from the root.
    func testASideStaysListedUntilItsResumeIsTaken() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        await owner.setCostLimit(5)
        let client = LimitRunClient(mode:"queued"), gate = OpenGate()
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in try AgentSteeringCoordinator.makeChild(env,plan) }, settled:{ child in await gate.wait(); await child.close() })
        let side = try await self.side("side",parent:owner,root:root,client:client,tools:RecordingTools())
        _ = try await side.keep(whenFinished:false)
        await side.enableSubagents(SubagentCoordinator()); await side.enableAgentSteering(coordinator)
        _ = try await startChild(side, coordinator, "kid")
        try await eventually { await client.children.count == 1 }
        await side.fixtureCostPause()
        await coordinator.pause(owner:side,generation:1)
        try await eventually { await gate.waiting }
        try await side.bindSideBudget(to:owner)
        _ = try await owner.continueRun(commandID:"resume-root")
        _ = try await side.continueRun(commandID:"resume-side")
        try await Task.sleep(for:.milliseconds(150))
        var members = await owner.costPausedMembers
        XCTAssertEqual(members,["side"],"Still listed while its Resume waits for parking")
        await gate.open(); await client.releaseAll()
        try await eventually(timeout:.seconds(10)) { await owner.costPausedMembers.isEmpty }
        members = await owner.costPausedMembers; XCTAssertTrue(members.isEmpty)
        await coordinator.drain(); await side.close(); await owner.close()
    }

    /// A hold an earlier runtime of a chat left in the coordinator goes when
    /// an unpaused runtime of it attaches.
    func testAnUnpausedRuntimeReleasesAStaleCoordinatorHold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let coordinator = AgentSteeringCoordinator()
        await coordinator.fixturePause("parent")
        let owner = try await steeringOwner(root, client:ScriptClient([]), coordinator:coordinator)
        try await eventually { !(await coordinator.paused.contains("parent")) }
        await owner.close()
    }
}

private extension AgentSession {
    func fixtureForgetTask() { taskRootID = nil; activeTaskPresentation = nil; currentTurnID = "" }
}

/// Review round 12 (Codex) regressions.
extension FamilyLimitPauseTests {
    func testAcceptedResumeRetiresPendingSidePausesButRefusalKeepsThem() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate = OpenGate(), tools = LimitHeldTools()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:AccountedAgentScript([answer("Resumed"),answer("Follow-up")]),tools:RecordingTools(),traces:TraceStore())
        let side = try await self.side("side",parent:owner,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
        _ = try await side.keep(whenFinished:false)
        _ = try await side.submit(Submission(commandID:"work",turnID:"work",text:"Use the tool"),steer:false)
        try await eventually { await tools.started }
        await owner.fixtureDelaySidePauses(gate)
        _ = try await owner.fixtureUserMessage("Go on")
        await owner.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Held input"))
        await owner.setCostLimit(0)
        try await eventually { await gate.waiting }
        await owner.setCostLimit(5)
        do { _ = try await owner.continueRun(commandID:"bad",overrides:["input":5]); XCTFail("Invalid override accepted") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"invalid_params") }
        let retained = await owner.costPendingSidePauses; XCTAssertEqual(retained,["side"],"Refusal retires no callback")
        _ = try await owner.continueRun(commandID:"resume")
        let pending = await owner.costPendingSidePauses; XCTAssertTrue(pending.isEmpty,"Accepted Resume retires callbacks that have not paused their side")
        let path = await owner.path, saved = try SideBudgetRecovery.pauseState(URL(fileURLWithPath:XCTUnwrap(path)),id:"parent").state
        XCTAssertTrue(saved["costPendingSidePauses"].list.isEmpty,"A restart cannot restore a retired fan-out")
        await gate.open(); await tools.release()
        await side.close(); await owner.close()
    }

    /// A reader command already in flight can reach the coordinator after
    /// its pause hold. Once accepted, that explicit Stop still wins.
    func testAnExplicitChildStopAcceptedDuringThePauseNeverResumes() async throws {
        for phase in ["running","parking","parked"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = LimitRunClient(mode:"queued"), gate = OpenGate()
            let coordinator = AgentSteeringCoordinator(settled:{ child in
                if phase == "parking" { await gate.wait() }
                await child.close()
            })
            let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
            if phase != "running" { await coordinator.fixturePause("parent") }
            let id = try await startChild(owner,coordinator,"stopped")
            if phase == "parking" { try await eventually { await gate.waiting } }
            else if phase == "parked" { try await eventually { await coordinator.jobs.isEmpty } }
            else { try await eventually { await client.children.count == 1 }; await coordinator.fixturePause("parent") }
            let target = AgentTurnTarget(childID:id,turn:1)
            try await coordinator.stop(parent:owner,target:target,human:true)
            await gate.open()
            await client.releaseAll()
            try await eventually { await coordinator.jobs.isEmpty }
            let stopped = await owner.agentState().latest(id)
            XCTAssertTrue(stopped?.status.terminal == true,"Accepted Stop must seal: \(phase)")
            let requests = await client.children.count
            await owner.beginResumeFixture()
            try await coordinator.resumeParked(owner:owner,generation:1)
            try await eventually { await coordinator.jobs.isEmpty }
            let after = await client.children.count
            XCTAssertEqual(after,requests,"Resume never restarts the stopped child")
            await owner.close()
        }
    }

    /// Snapshot while every fan-out callback is held: only the root has
    /// observed the limit. Saved active sides must still join Resume.
    func testSidePauseFanoutSurvivesACrashBeforeItsCallbacks() async throws {
        for busyRoot in [true, false] { for trigger in ["limit", "member", "rebind", "renewed"] {
            let root = try temporaryDirectory(), crash = root.appendingPathComponent("crash")
            defer { try? FileManager.default.removeItem(at:root) }
            let owner = try familyFixture(root:root), gate = OpenGate(), tools = LimitHeldTools()
            let side = try await self.side("side",parent:owner,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
            let nested = try await self.side("nested",parent:side,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
            let idle = try await self.side("idle",parent:owner,root:root)
            for member in [side,nested,idle] { _ = try await member.keep(whenFinished:false) }
            for member in [side,nested] {
                _ = try await member.submit(Submission(commandID:"work",turnID:"work",text:"Use the tool"),steer:false)
            }
            try await eventually { await tools.starts == 2 }
            await owner.fixtureDelaySidePauses(gate); await side.fixtureDelaySidePauses(gate)
            if busyRoot { await owner.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Held input")) }
            if trigger != "member" { await owner.setCostLimit(0) }
            else { await owner.notePausedMember("unkept-side") }
            try await eventually { await gate.waiting }
            let sidePaused = await side.costPaused; XCTAssertFalse(sidePaused,"Callbacks have not run")
            if trigger == "rebind" {
                try await side.bindSideBudget(to:owner)
                let boundPause = await side.costPaused; XCTAssertTrue(boundPause,"Binding takes the pending pause before acknowledging it")
            }
            if trigger == "renewed" { await owner.fixtureRenewPauseBeforeAnOldAcknowledgement() }
            try FileManager.default.createDirectory(at:crash,withIntermediateDirectories:true)
            for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where file.pathExtension == "jsonl" {
                try FileManager.default.copyItem(at:file,to:crash.appendingPathComponent(file.lastPathComponent))
            }
            await gate.open(); await tools.release(); await tools.release()
            for member in [nested,side,idle,owner] { await member.close() }
            let client = AccountedAgentScript([answer("Resumed"),answer("Resumed"),answer("Resumed")])
            func reopen(_ id: String) throws -> AgentSession {
                let file = try XCTUnwrap(SideBudgetRecovery.journalURL(id,directory:crash))
                return try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:crash,directory:crash,readOnly:true,
                    resources:Resources(cwd:crash,home:crash),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:file.path)
            }
            let restored = try reopen("parent")
            await restored.setCostLimit(5)
            let members = await restored.costPausedMembers, paused = await restored.costPaused
            XCTAssertEqual(Set(members),["side","nested"],"\(trigger), busy root: \(busyRoot)")
            XCTAssertTrue(paused,"The family pause survives even when only sides were running")
            // Root Resume can precede opening either side. Its durable list
            // still gives both sides the pause their callbacks never saved.
            let reply = try await restored.continueRun(commandID:"resume-root")
            XCTAssertEqual(Set(reply["pausedMembers"].list.compactMap(\.text)),["side","nested"])
            let restoredSide = try reopen("side"), restoredNested = try reopen("nested"), restoredIdle = try reopen("idle")
            try await restoredSide.bindSideBudget(to:restored)
            try await restoredNested.bindSideBudget(to:restoredSide)
            try await restoredIdle.bindSideBudget(to:restored)
            let flags = await [restoredSide.costPaused,restoredNested.costPaused,restoredIdle.costPaused]
            XCTAssertEqual(flags,[true,true,false],"Idle sides stay unmarked")
            let retained = await restored.costPausedMembers; XCTAssertEqual(Set(retained),["side","nested"])
            _ = try await restoredSide.continueRun(commandID:"resume-side")
            try await eventually { !(await restoredSide.isRunning) }
            _ = try await restoredNested.continueRun(commandID:"resume-nested")
            try await eventually { await restored.costPausedMembers.isEmpty }
            for member in [restoredNested,restoredSide,restored] {
                try await eventually { !(await member.isRunning) }
                let snapshot = await member.snapshot(), code = await member.errorCode
                XCTAssertEqual(snapshot["state"].text,"idle","\(trigger): Resume completes normally for \(snapshot["sessionId"])")
                XCTAssertNotEqual(snapshot["costPaused"].flag,true,"\(trigger): no completed member still offers cost Resume")
                XCTAssertNotEqual(snapshot["cost"]["paused"].flag,true)
                XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
                let pending = await member.membersPendingResume; XCTAssertFalse(pending)
                XCTAssertNil(code)
            }
            let requests = await client.requests.count
            XCTAssertEqual(requests,busyRoot ? 3 : 2,"One continuation per active side, plus the root's queued input")
            for member in [restoredNested,restoredSide,restoredIdle,restored] { await member.close() }
        } }
    }

    func testChildStopDuringResumeInstallationDoesNotPauseTheFamilyAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript(Array(repeating:answer("Finished"),count:6),held:true)
        let coordinator = AgentSteeringCoordinator(), tools = ResumeDefinitionTools(), gate = OpenGate(), stopped = OpenGate()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        await coordinator.fixturePause("parent")
        let child = try await startChild(owner,coordinator,"stopped")
        try await owner.fixtureAcceptedReceipt("stopped")
        let sibling = try await startChild(owner,coordinator,"sibling",newTask:false)
        try await owner.fixtureAcceptedReceipt("sibling")
        try await eventually { await coordinator.jobs.isEmpty }
        await owner.fixtureCostPause()
        await tools.hold(gate)
        let reply = try await owner.continueRun(commandID:"resume")
        XCTAssertEqual(reply["accepted"].flag,true)
        // Environment preparation crosses actors after Resume reads the
        // parked turns. Hold it while a reader Stop reaches the same owner.
        try await eventually { await gate.waiting }
        let stop = Task {
            try await coordinator.stop(parent:owner,target:.init(childID:child,turn:1),human:true)
            await stopped.open()
        }
        // Before the fix Stop finishes here; with the gate shared it waits
        // for installation. Neither ordering may abort the accepted Resume.
        let deadline = ContinuousClock.now.advanced(by:.milliseconds(250))
        while !(await stopped.opened), ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        await gate.open()
        try await stop.value
        await client.release()
        try await eventually(timeout:.seconds(10)) {
            let running = await owner.isRunning, empty = await coordinator.jobs.isEmpty
            return !running && empty
        }
        let snapshot = await owner.snapshot(), listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertEqual(snapshot["state"].text,"idle","Stopping one resumed child must not abort the family's Resume")
        XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        XCTAssertNotEqual(snapshot["cost"]["paused"].flag,true)
        XCTAssertTrue(snapshot["preflightError"].isNull,"\(snapshot["preflightError"])")
        let siblingResult = await owner.agentState().latest(sibling)?.result
        XCTAssertEqual(listed.first { $0["link"]["childSessionID"].text == sibling }?["status"].text,"completed","\(String(describing:siblingResult))")
        let stoppedStatus = listed.first { $0["link"]["childSessionID"].text == child }?["status"].text
        XCTAssertTrue(stoppedStatus == "not_executed" || stoppedStatus == "interrupted","\(String(describing:stoppedStatus))")
        await owner.close()
    }

    func testBindingTransfersRecoveredMembershipFromEveryAncestorToTheRoot() async throws {
        let root = try temporaryDirectory(), crash = root.appendingPathComponent("crash")
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root)
        let side = try await self.side("side",parent:owner,root:root)
        let nested = try await self.side("nested",parent:side,root:root)
        let leaf = try await self.side("leaf",parent:nested,root:root)
        for member in [side,nested,leaf] { _ = try await member.keep(whenFinished:false) }
        await leaf.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Held leaf input"))
        // Journals an earlier recovery could save on any intermediate side.
        // Only the intermediate knows the cold leaf belongs to Resume.
        try await side.fixtureSavedPauseMembers(["leaf"])
        try await nested.fixtureSavedPauseMembers(["leaf"])
        try await leaf.fixtureSavedPauseMembers([])
        try FileManager.default.createDirectory(at:crash,withIntermediateDirectories:true)
        for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where file.pathExtension == "jsonl" {
            try FileManager.default.copyItem(at:file,to:crash.appendingPathComponent(file.lastPathComponent))
        }
        for member in [leaf,nested,side,owner] { await member.close() }
        let client = AccountedAgentScript([answer("Finished")])
        func reopen(_ id: String) throws -> AgentSession {
            let file = try XCTUnwrap(SideBudgetRecovery.journalURL(id,directory:crash))
            return try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:crash,directory:crash,readOnly:true,
                resources:Resources(cwd:crash,home:crash),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:file.path)
        }
        let restored = try reopen("parent"), restoredSide = try reopen("side"), restoredNested = try reopen("nested")
        await restored.setCostLimit(5)
        let unbound = await restoredSide.snapshot()
        XCTAssertEqual(unbound["cost"]["pausedMembers"].list,["leaf"],"An unbound or orphaned side retains its saved membership")
        try await restoredSide.bindSideBudget(to:restored)
        let rootSnapshot = await restored.snapshot()
        XCTAssertTrue(rootSnapshot["cost"]["pausedMembers"].list.contains("leaf"),"Root Resume must include the still-unopened leaf")
        try await restoredNested.bindSideBudget(to:restoredSide)
        for member in [restoredSide,restoredNested] {
            let snapshot = await member.snapshot()
            XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty,"Only the bound root owns Resume membership")
            let path = await member.path, id = await member.id
            let saved = try SideBudgetRecovery.pauseState(URL(fileURLWithPath:XCTUnwrap(path)),id:id).state
            XCTAssertTrue(saved["costPausedMembers"].list.isEmpty,"Membership transfer is durable")
        }
        let restoredLeaf = try reopen("leaf")
        try await restoredLeaf.bindSideBudget(to:restoredNested)
        let reply = try await restored.continueRun(commandID:"resume-root")
        XCTAssertEqual(Set(reply["pausedMembers"].list.compactMap(\.text)),["side","nested","leaf"])
        for member in [restoredSide,restoredNested,restoredLeaf] { _ = try await member.continueRun(commandID:"resume") }
        try await eventually { await restored.costPausedMembers.isEmpty }
        for member in [restoredLeaf,restoredNested,restoredSide,restored] {
            try await eventually { !(await member.isRunning) }
            let snapshot = await member.snapshot(), pending = await member.membersPendingResume
            XCTAssertEqual(snapshot["state"].text,"idle")
            XCTAssertNotEqual(snapshot["costPaused"].flag,true)
            XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
            XCTAssertFalse(pending)
            await member.close()
        }
    }

    func testStopBeforeAnAcceptedResumeRunsHaltsChildTools() async throws {
        for closing in [false, true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let tools = LimitHeldTools(), coordinator = AgentSteeringCoordinator()
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
                readOnly:true,resources:Resources(cwd:root,home:root),client:ChildToolClient(),tools:tools,traces:TraceStore())
            await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            await owner.setCostLimit(0.5)
            _ = try await startChild(owner,coordinator,"tooling")
            try await eventually { await tools.started }
            let crossing = try await start(owner,"crossing"); try await finish(crossing.0,"crossing",cost:0.6)
            try await eventually { await coordinator.paused.contains("parent") }
            await owner.setCostLimit(5)
            // Both calls run in one actor turn: the new run cannot enter
            // resumeParked before Stop cancels it.
            let pending = try await owner.fixtureResumeThenStop(closing:closing)
            XCTAssertTrue(pending)
            try await eventually { !(await owner.isRunning) }
            do { try await eventually(timeout:.seconds(2)) { await tools.cancelled } }
            catch { XCTFail("Stop left the child's tool running before Resume entered resumeParked") }
            let paused = await owner.costPaused; XCTAssertTrue(paused)
            await tools.release()
            try await eventually { await coordinator.jobs.isEmpty }
            await owner.close()
        }
    }
}

/// Follow-up review round 2: Stop stays prompt through the family gate,
/// and descendant-only recovery does not invent an intermediate's pause.
extension FamilyLimitPauseTests {
    func testReaderStopCancelsLiveWorkWhileDeliveryCompactionHoldsTheGate() async throws {
        for stopSibling in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = DeliveryCompactionClient(), tools = LimitHeldTools(), opened = OpenedChildren()
            let coordinator = AgentSteeringCoordinator(open:{ env, plan in
                let child = try AgentSession(id:plan.origin.link.childSessionID,profile:env.profile,apiKey:env.apiKey,cwd:env.cwd,
                    directory:env.directory,readOnly:true,resources:Resources(frozen:env.resources),client:env.client,
                    tools:env.tools,traces:env.traces,resumePath:env.directory.appendingPathComponent(plan.origin.link.childSessionID + ".jsonl").path,autoCompaction:false)
                await opened.add(child)
                if plan.task == "Worker compacting" { try await child.fixtureCompactionHistory() }
                return child
            })
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
                readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
            await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            let compacting = try await startChild(owner,coordinator,"compacting")
            try await owner.fixtureAcceptedReceipt("compacting")
            try await eventually { await client.turnWaiting }
            var target = compacting
            if stopSibling {
                target = try await startChild(owner,coordinator,"tooling",newTask:false)
                try await owner.fixtureAcceptedReceipt("tooling")
                try await eventually { await tools.started }
            }
            let send = ToolCall(id:"steer",name:"subagent_send",arguments:["child_id":JSON(compacting),"message":JSON(String(repeating:"s",count:240000))])
            let key = try await owner.agentFixtureCall(send)
            _ = try await coordinator.prepare(send,key:key,parent:owner)
            await client.releaseTurn()
            try await eventually { await client.summaryWaiting }
            let children = await opened.children, child = try XCTUnwrap(children.first)
            let before = await child.snapshot()
            XCTAssertEqual(before["compaction"]["reason"].text,"agent-delivery")
            XCTAssertEqual(before["compaction"]["phase"].text,"summarizing")
            let stoppedID = target
            let stop = Task { try await coordinator.stop(parent:owner,target:.init(childID:stoppedID,turn:1),human:true) }
            // Do not release the summary to make Stop pass. The real request
            // (or the sibling's tool) must observe cancellation while held.
            do {
                try await eventually(timeout:.seconds(1)) {
                    if stopSibling { return await tools.cancelled }
                    return await client.summaryCancelled
                }
            } catch { }
            let summaryCancelled = await client.summaryCancelled
            if stopSibling { XCTAssertFalse(summaryCancelled,"Stopping a sibling must leave this compaction alone") }
            await client.releaseSummary(); await tools.release()
            try await stop.value
            try await eventually { await coordinator.jobs.isEmpty }
            let listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
            let status = listed.first { $0["link"]["childSessionID"].text == target }?["status"].text
            XCTAssertEqual(status,"interrupted")
            if !stopSibling {
                let snapshot = await child.snapshot()
                XCTAssertTrue(snapshot["latestSuccessfulCompaction"].isNull,"Stop must not wait for a successful summary")
                XCTAssertEqual(snapshot["compaction"]["phase"].text,"cancelled")
            }
            await owner.close()
        }
    }

    func testRecoveryDoesNotPauseIdleAncestorsOfTheResumedLeaf() async throws {
        for (orphan, depth) in [(false,1),(false,2),(true,2)] { for resumeFirst in [true,false] {
            let root = try temporaryDirectory(), crash = root.appendingPathComponent("crash")
            defer { try? FileManager.default.removeItem(at:root) }
            let original = try familyFixture(root:root), gate = OpenGate(), tools = LimitHeldTools()
            let owner = orphan ? try await side("family",parent:original,root:root) : original
            if orphan { _ = try await owner.keep(whenFinished:false) }
            var ancestors = [owner]
            for index in 0..<depth {
                let intermediate = try await side("idle-\(index)",parent:ancestors.last!,root:root)
                _ = try await intermediate.keep(whenFinished:false); ancestors.append(intermediate)
            }
            let leaf = try await side("leaf",parent:ancestors.last!,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
            _ = try await leaf.keep(whenFinished:false)
            _ = try await leaf.submit(Submission(commandID:"work",turnID:"work",text:"Use the tool"),steer:false)
            try await eventually { await tools.started }
            for ancestor in ancestors { await ancestor.fixtureDelaySidePauses(gate) }
            // This mirrors an idle owner's durable fan-out, without a
            // request or pending input of its own.
            await owner.stopFamilyAtLimit(AgentSession.costHoldError)
            try await eventually { await gate.waiting }
            for index in 1..<ancestors.count { try await ancestors[index].bindSideBudget(to:ancestors[index-1]) }
            try FileManager.default.createDirectory(at:crash,withIntermediateDirectories:true)
            for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where file.pathExtension == "jsonl" {
                if orphan, file.lastPathComponent == "parent.jsonl" { continue }
                try FileManager.default.copyItem(at:file,to:crash.appendingPathComponent(file.lastPathComponent))
            }
            await gate.open(); await tools.release(); await leaf.close()
            for ancestor in ancestors.reversed() { await ancestor.close() }
            if orphan { await original.close() }
            let client = AccountedAgentScript([answer("Leaf completed")])
            func reopen(_ id: String) throws -> AgentSession {
                let file = try XCTUnwrap(SideBudgetRecovery.journalURL(id,directory:crash))
                return try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:crash,directory:crash,readOnly:true,
                    resources:Resources(cwd:crash,home:crash),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:file.path)
            }
            let restored = try reopen(orphan ? "family" : "parent")
            await restored.setCostLimit(5)
            var reply: JSON = .null
            if resumeFirst { reply = try await restored.continueRun(commandID:"resume-root") }
            var restoredAncestors = [restored]
            for index in 0..<depth {
                let intermediate = try reopen("idle-\(index)")
                try await intermediate.bindSideBudget(to:restoredAncestors.last!)
                restoredAncestors.append(intermediate)
                let snapshot = await intermediate.snapshot()
                XCTAssertEqual(snapshot["state"].text,"idle","Descendant-only recovery must not pause an idle side")
                XCTAssertNotEqual(snapshot["costPaused"].flag,true)
                XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
            }
            let restoredLeaf = try reopen("leaf")
            try await restoredLeaf.bindSideBudget(to:restoredAncestors.last!)
            if !resumeFirst { reply = try await restored.continueRun(commandID:"resume-root") }
            XCTAssertEqual(reply["pausedMembers"].list,["leaf"],"Only actual paused work joins family Resume")
            let rootSnapshot = await restored.snapshot()
            XCTAssertEqual(rootSnapshot["queuePaused"].flag,false,"Binding must not undo the accepted root Resume")
            XCTAssertTrue(rootSnapshot["preflightError"].isNull)
            _ = try await restoredLeaf.continueRun(commandID:"resume-leaf")
            try await eventually { !(await restoredLeaf.isRunning) }
            do { try await eventually(timeout:.seconds(1)) { await restored.costPausedMembers.isEmpty } } catch { }
            let requests = await client.requests.count; XCTAssertEqual(requests,1,"The original Resume completes the leaf")
            for member in [restoredLeaf] + restoredAncestors.reversed() {
                let snapshot = await member.snapshot()
                XCTAssertEqual(snapshot["state"].text,"idle")
                XCTAssertNotEqual(snapshot["costPaused"].flag,true)
                XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
                await member.close()
            }
        } }
    }
}

private actor DeliveryCompactionClient: ModelClient {
    var turnWaiting = false, summaryWaiting = false, summaryCancelled = false
    var turnReleased = false, summaryReleased = false
    func releaseTurn() { turnReleased = true }
    func releaseSummary() { summaryReleased = true }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Expected admission")
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,cacheSessionID:String,turnID:String,purpose:String,lifecycle:RequestLifecycle?,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), attempt = UUID().uuidString
        let permit = try await hooks.admitAttempt(attempt); defer { permit.finish() }
        try await hooks.willDispatch(attempt)
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        do {
            var reply = answer("Completed")
            if purpose == "compaction" {
                summaryWaiting = true
                while !summaryReleased { try permit.check(); try await Task.sleep(for:.milliseconds(2)) }
                reply = answer("Earlier work completed; retain the current task.")
            } else if messages.contains(where: { $0.text == "Worker tooling" }) {
                if !messages.contains(where: { $0.role == "toolResult" }) { reply = toolReply(["first"]) }
            } else {
                turnWaiting = true
                while !turnReleased { try permit.check(); try await Task.sleep(for:.milliseconds(2)) }
                reply.usage = [:] // Size the generated history, not answer()'s tiny usage baseline.
            }
            try permit.check()
            try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
            await onObservation(observation); reply.message.requestAttemptIDs = [attempt]; return reply
        } catch {
            if purpose == "compaction" { summaryCancelled = true }
            observation.monitoring["outcome"] = "cancelled"
            try? await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
            throw error
        }
    }
}

private actor ResumeDefinitionTools: ToolExecuting {
    var gate: OpenGate?
    func hold(_ gate: OpenGate) { self.gate = gate }
    func definitions(readOnly: Bool) async -> [ToolDefinition] {
        if let gate { self.gate = nil; await gate.wait() }
        return []
    }
    func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON { throw AgentError("fixture_tool","Unexpected tool") }
}

private extension AgentSession {
    func fixtureCompactionHistory() throws {
        for index in 0..<6 {
            var input = ChatMessage(role:"user",content:[textBlock("Earlier task \(index)")])
            input.taskRootID = input.id
            var reply = ChatMessage(role:"assistant",content:[textBlock(String(repeating:"x",count:30000))])
            reply.taskRootID = input.id
            try append(input); try append(reply)
        }
    }

    func fixtureAcceptedReceipt(_ call: String) throws {
        let operation = try XCTUnwrap(subagents.family?.operations.values.first { $0.key.toolCallID == call })
        var result = ChatMessage(role:"toolResult",content:[textBlock(operation.receipt.encoded())])
        result.toolCallId = call; result.toolName = "subagent_start"
        try append(result)
    }

    func fixtureSavedPauseMembers(_ members: [String]) throws {
        fixtureCostPause(); costPausedMembers = members; try persistState(durable:true)
    }

    func fixtureRenewPauseBeforeAnOldAcknowledgement() {
        notePausedMember("unkept-side")
        let old = costResumeCount
        _ = endCostPause()
        notePausedMember("unkept-side")
        acknowledgeSidePause("side",resumes:old)
    }

    func fixtureDelaySidePauses(_ gate: OpenGate) {
        for (side, notify) in sideBudgetStops {
            sideBudgetStops[side] = { reason, resumes in await gate.wait(); await notify(reason,resumes) }
        }
    }

    func fixtureResumeThenStop(closing: Bool) async throws -> Bool {
        _ = try continueRun(commandID:"resume")
        let pending = costResumePending && !costPaused
        if closing { await close() } else { stop() }
        return pending
    }
}
