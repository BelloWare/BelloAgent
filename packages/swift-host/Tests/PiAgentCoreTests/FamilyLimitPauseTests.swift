import XCTest
@testable import PiAgentCore

/// The shared cost limit pauses the whole family at once and resumes only on
/// Resume (owner, 2026-10-16). Replaces 0.1.128's drain-then-block table.
final class FamilyLimitPauseTests: HelperTestCase {
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
            try await coordinator.fixtureResume(owner:owner,count:1)
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
        await coordinator.fixturePause(owner)
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
    func fixtureOrphanedHold(_ owner: String) { paused.insert(owner) }
    func fixturePause(_ owner: AgentSession) async { await owner.fixtureCoordinatorPause(); paused.insert(await owner.id) }
    func fixturePark(_ id: String) async { if let job = jobs[id] { await park(job,child:job.child,generation:job.owner.pauseGeneration) } }
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
        await coordinator.pause(owner:owner,generation:owner.pauseGeneration)
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
        await coordinator.fixturePause(owner)
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
        await owner.fixtureEndPause(); try await child.resumeAgentTurn(resumedTurn,owner:owner,coordinator:coordinator,generation:owner.pauseGeneration)
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
        await coordinator.fixturePause(owner)
        await client.release()
        try await eventually { await coordinator.jobs.isEmpty }
        let target = AgentTurnTarget(childID:child,turn:1)
        let parked = await owner.agentState().turns[target.id]?.status; XCTAssertEqual(parked,.queued)
        await probe.reset(target)
        await owner.beginResumeFixture()
        try await coordinator.fixtureResume(owner:owner,count:1)
        try await eventually { await owner.agentState().turns[target.id]?.status.terminal == true }
        try await eventually { await probe.seen != nil }
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
        await owner.fixtureNotePausedMember("side-a"); await owner.fixtureNotePausedMember("side-b")
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
        await owner.fixtureForgetPausedMember("side-a")
        let left = await owner.costPausedMembers; XCTAssertEqual(left,["side-b"])
        await owner.close()
    }
}

private extension AgentSession {
    func fixtureCostPause() {
        if !costPaused { costPauseCount &+= 1 }; costPaused = true; queuePaused = true; errorCode = AgentSession.costLimitCode; errorMessage = costPausedMessage
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
        await coordinator.fixturePause(owner)
        await gate.open()
        let receipt = try await accepting.value, child = try XCTUnwrap(receipt["child_id"].text)
        try await eventually(timeout:.seconds(2)) { await coordinator.jobs.isEmpty }
        let status = await owner.agentState().latest(child)?.status
        XCTAssertEqual(status,.queued,"Parked at insertion")
        let dispatched = await client.children.count; XCTAssertEqual(dispatched,0)
        await owner.beginResumeFixture(); await client.releaseAll()
        try await coordinator.fixtureResume(owner:owner,count:1)
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
        await coordinator.fixturePause(owner)
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
        try await coordinator.fixtureResume(owner:first,count:1)
        let saved = await first.path; await first.close()
        let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:saved)
        await coordinator.pause(owner:reopened,generation:reopened.pauseGeneration)
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
        await coordinator.fixturePause(owner)
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
        await coordinator.pause(owner:owner,generation:owner.pauseGeneration)
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
        await coordinator.pause(owner:owner,generation:owner.pauseGeneration)
        try await eventually(timeout:.seconds(5)) { await coordinator.jobs.isEmpty }
        await owner.fixtureEndPause(); await owner.beginResumeFixture()
        try await coordinator.fixtureResume(owner:owner,count:1)
        let reinstalled = await coordinator.jobs[stale.turn.id]
        XCTAssertNotNil(reinstalled)
        await coordinator.park(stale,child:nil,generation:owner.pauseGeneration)
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
            try await coordinator.fixtureResume(owner:first!,count:5)
            await first!.close(); first = nil
            let second = try await steeringOwner(root.appendingPathComponent("b\(attempt)"), client:ScriptClient([]), coordinator:coordinator)
            if ObjectIdentifier(second) == address {
                reused = true
                await coordinator.pause(owner:second,generation:second.pauseGeneration)
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
        await coordinator.pause(owner:owner,generation:owner.pauseGeneration)
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
        let generation = owner.pauseGeneration
        let stops = await owner.sideBudgetStops
        let notify = try XCTUnwrap(stops["side"])
        let stale = CostPauseGeneration(clock:generation.clock,pauses:generation.pauses,resumes:generation.resumes - 1,stops:generation.stops,paused:generation.paused)
        await notify(AgentSession.costHoldError,SidePausePublication(side:stale,root:stale))
        var paused = await side.costPaused; XCTAssertFalse(paused, "A pause older than a Resume is retired")
        await notify(AgentSession.costHoldError,SidePausePublication(side:generation,root:generation))
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
        await owner.fixtureNotePausedMember("ghost")
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
        await coordinator.fixturePause(owner)
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
        await coordinator.pause(owner:owner,generation:owner.pauseGeneration)
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
        await coordinator.pause(owner:side,generation:side.pauseGeneration)
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
        await coordinator.fixtureOrphanedHold("parent")
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
            if phase != "running" { await coordinator.fixturePause(owner) }
            let id = try await startChild(owner,coordinator,"stopped")
            if phase == "parking" { try await eventually { await gate.waiting } }
            else if phase == "parked" { try await eventually { await coordinator.jobs.isEmpty } }
            else { try await eventually { await client.children.count == 1 }; await coordinator.fixturePause(owner) }
            let target = AgentTurnTarget(childID:id,turn:1)
            try await coordinator.stop(parent:owner,target:target,human:true)
            await gate.open()
            await client.releaseAll()
            try await eventually { await coordinator.jobs.isEmpty }
            let stopped = await owner.agentState().latest(id)
            XCTAssertTrue(stopped?.status.terminal == true,"Accepted Stop must seal: \(phase)")
            let requests = await client.children.count
            await owner.beginResumeFixture()
            try await coordinator.fixtureResume(owner:owner,count:1)
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
            else { await owner.fixtureNotePausedMember("unkept-side") }
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
        await coordinator.fixturePause(owner)
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

/// Round 3: accepting Stop must both release later turns and acknowledge
/// without waiting for an unrelated provider request.
extension FamilyLimitPauseTests {
    func testAStoppedParkedChildRunsAFollowUpAfterParentResume() async throws {
        for heldTools in [false,true] { for restart in [false,true] { for mode in ["off","memory","persist"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = FollowUpAfterStopClient(heldTools:heldTools), traces = TraceStore(), tools = RecordingTools()
            _ = try await traces.command("debug.mode",session:"parent",params:["mode":JSON(mode)])
            var coordinator = AgentSteeringCoordinator()
            var owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
                readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces)
            await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            if heldTools { await owner.setCostLimit(0.5) } else { await coordinator.fixturePause(owner) }
            let id = try await startChild(owner,coordinator,"stopped")
            try await owner.fixtureAcceptedReceipt("stopped")
            if !heldTools { try await owner.fixtureSavedPauseMembers([]) }
            try await eventually { await coordinator.jobs.isEmpty }
            try await coordinator.stop(parent:owner,target:.init(childID:id,turn:1),human:true)
            let stopped = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
            XCTAssertEqual(stopped.first?["status"].text,heldTools ? "interrupted" : "not_executed")
            if restart {
                let path = await owner.path; await owner.close()
                coordinator = AgentSteeringCoordinator()
                owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
                    readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,resumePath:path)
                await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            }
            await owner.setCostLimit(5)
            _ = try await owner.continueRun(commandID:"resume-parent")
            try await eventually { !(await owner.isRunning) }
            await client.followUp(id)
            _ = try await owner.submit(Submission(commandID:"follow-up",turnID:"follow-up",text:"Follow up with the stopped child"),steer:false)
            try await eventually { !(await owner.isRunning) }
            let children = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
            XCTAssertEqual(children.first?["turn"].int,2)
            XCTAssertEqual(children.first?["status"].text,"completed","restart=\(restart), capture=\(mode)")
            let requests = await client.childRequests; XCTAssertEqual(requests,heldTools ? 2 : 1,"Only the new follow-up executes")
            let invoked = await tools.calls; XCTAssertTrue(invoked.isEmpty,"The stopped turn's held tools never execute")
            let unresolved = await client.unresolvedCalls; XCTAssertTrue(unresolved.isEmpty,"The next request pairs the stopped turn's held calls")
            let retired = await client.retiredCalls; XCTAssertEqual(retired,heldTools ? ["call-0"] : [])
            let snapshot = await owner.snapshot()
            XCTAssertEqual(snapshot["state"].text,"idle")
            XCTAssertNotEqual(snapshot["costPaused"].flag,true)
            XCTAssertTrue(snapshot["preflightError"].isNull)
            await owner.close()
        } } }
    }

    func testBothReaderStopRoutesAcknowledgeWhileSiblingCompactionIsHeld() async throws {
        for route in ["subagent.stop","turn.stop"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let host = NativeHostService(emit:{ _ in }), client = DeliveryCompactionClient(holdSibling:true)
            _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
            _ = try await host.command("session.open",sessionID:"parent",params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only"])
            let loaded = await host.loadedSession("parent"), owner = try XCTUnwrap(loaded)
            let original = await owner.agentCoordinator, hostCoordinator = try XCTUnwrap(original)
            let coordinator = AgentSteeringCoordinator(open:{ env, plan in
                let child = try await hostCoordinator.open(env.fixtureClient(client),plan)
                if plan.task == "Worker compacting" { try await child.fixtureCompactionHistory() }
                return child
            },settled:{ _ in })
            await owner.enableAgentSteering(coordinator)
            let compacting = try await startChild(owner,coordinator,"compacting")
            try await owner.fixtureAcceptedReceipt("compacting")
            try await eventually { await client.turnWaiting }
            let target = try await startChild(owner,coordinator,"tooling",newTask:false)
            try await owner.fixtureAcceptedReceipt("tooling")
            try await eventually { await client.siblingWaiting }
            let send = ToolCall(id:"steer",name:"subagent_send",arguments:["child_id":JSON(compacting),"message":JSON(String(repeating:"s",count:240000))])
            let key = try await owner.agentFixtureCall(send)
            _ = try await coordinator.prepare(send,key:key,parent:owner)
            await client.releaseTurn()
            try await eventually { await client.summaryWaiting }
            let ack = StopReply(), start = ContinuousClock.now
            let stop = Task {
                let reply = try await host.command(route,sessionID:route == "subagent.stop" ? "parent" : target,
                    params:route == "subagent.stop" ? ["childId":JSON(target),"turn":1] : [:])
                await ack.receive(reply,elapsed:start.duration(to:.now))
            }
            do { try await eventually(timeout:.seconds(2)) { await ack.reply != nil } } catch { }
            if let reply = await ack.reply {
                XCTAssertEqual(reply["accepted"].flag,true)
                let elapsed = await ack.elapsed; XCTAssertLessThan(elapsed,.seconds(2),"\(route) must beat the 30 s host deadline")
                print("Stop acknowledgment \(route): \(elapsed), sibling compaction still held")
                let snapshot = try await host.command("session.snapshot",sessionID:compacting,params:[:])
                XCTAssertEqual(snapshot["compaction"]["phase"].text,"summarizing","Acknowledged while the unrelated request is still held")
            }
            let cancelled = await client.summaryCancelled; XCTAssertFalse(cancelled)
            await client.releaseSummary()
            try await stop.value
            try await eventually { await coordinator.jobs.isEmpty }
            let page = try await host.command("subagent.list",sessionID:"parent",params:[:])
            XCTAssertEqual(page["children"].list.first { $0["link"]["childSessionID"].text == target }?["status"].text,"interrupted")
            await host.shutdown()
        }
    }

    func testReaderStopAcknowledgesWhileParentDeliveryCompactsAndDeliveryIsRefreshed() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = DeliveryCompactionClient(holdSibling:true), opened = OpenedChildren()
        let coordinator = AgentSteeringCoordinator(open:{ env, plan in
            let child = try AgentSteeringCoordinator.makeChild(env,plan)
            await opened.add(child); return child
        })
        var profile = try fixtureProfile().raw; profile["maxOutputTokens"] = 24000
        let owner = try AgentSession(id:"parent",profile:Profile(profile),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
        let id = try await startChild(owner,coordinator,"tooling")
        try await owner.fixtureAcceptedReceipt("tooling")
        try await eventually { await client.siblingWaiting }
        let children = await opened.children, child = try XCTUnwrap(children.first)
        let report = ToolCall(id:"report",name:"subagent_report",arguments:["kind":"note","message":JSON(String(repeating:"r",count:4096))])
        let key = try await child.agentFixtureCall(report)
        _ = try await coordinator.report(report,key:key,child:child)
        try await owner.fixtureCompactionHistory(bytes:50000)
        let delivery = Task { try await coordinator.boundary(owner,final:false) }
        do { try await eventually { await client.summaryWaiting } }
        catch {
            print("Parent compaction fixture: \(await owner.snapshot()["compaction"])")
            await client.releaseSummary()
            _ = try await delivery.value
            throw error
        }
        let ack = StopReply(), start = ContinuousClock.now
        let stop = Task {
            try await coordinator.stop(parent:owner,target:.init(childID:id,turn:1),human:true)
            await ack.receive(["accepted":true],elapsed:start.duration(to:.now))
        }
        do { try await eventually(timeout:.seconds(2)) { await ack.reply != nil } } catch { }
        if let reply = await ack.reply {
            XCTAssertEqual(reply["accepted"].flag,true)
            let snapshot = await owner.snapshot()
            XCTAssertEqual(snapshot["compaction"]["phase"].text,"summarizing")
            try await eventually { await coordinator.jobs.isEmpty }
        }
        let cancelled = await client.summaryCancelled; XCTAssertFalse(cancelled)
        await client.releaseSummary()
        try await stop.value
        let delivered = try await delivery.value; XCTAssertTrue(delivered)
        let events = await owner.history.compactMap(\.nativeAgentDelivery).flatMap { $0["events"].list }
        XCTAssertEqual(events.filter { $0["kind"].text == "result" }.count,1,"Delivery is selected again after compaction, including the child's new terminal result")
        await owner.close()
    }
}

private actor StopReply {
    var reply: JSON?, elapsed: Duration = .zero
    func receive(_ reply: JSON, elapsed: Duration) { self.reply = reply; self.elapsed = elapsed }
}

private extension SubagentEnvironment {
    func fixtureClient(_ client: any ModelClient) -> SubagentEnvironment {
        .init(parent:parent,ownerID:ownerID,turnID:turnID,executionID:executionID,parentAttemptID:parentAttemptID,
            generation:generation,runtimeID:runtimeID,profile:profile,apiKey:apiKey,connectionSupportsReasoning:connectionSupportsReasoning,
            models:models,definitions:definitions,capabilities:capabilities,mcpPolicy:mcpPolicy,tools:tools,client:client,
            resources:resources,cwd:cwd,directory:directory,readOnly:readOnly,traces:traces,retry:retry,changed:changed)
    }
}

private actor FollowUpAfterStopClient: ModelClient {
    var childID: String?, childRequests = 0
    let heldTools: Bool
    var unresolvedCalls: [String] = [], retiredCalls: [String] = []
    init(heldTools: Bool) { self.heldTools = heldTools }
    func followUp(_ id: String) { childID = id }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped","Expected admission")
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,cacheSessionID:String,turnID:String,purpose:String,lifecycle:RequestLifecycle?,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), attempt = UUID().uuidString
        let permit = try await hooks.admitAttempt(attempt); defer { permit.finish() }
        try await hooks.willDispatch(attempt); try permit.check()
        var reply = answer("Parent finished")
        if sessionID != "parent" {
            childRequests += 1
            if heldTools, childRequests == 1 { reply = toolReply(["first"]) }
            else {
                reply = answer("Child follow-up completed")
                let results = Set(messages.compactMap { $0.role == "toolResult" ? $0.toolCallId : nil })
                unresolvedCalls = messages.flatMap(\.content).filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text }.filter { !results.contains($0) }
                retiredCalls = messages.filter { $0.role == "toolResult" && $0.toolStats?["outcome"].text == "not_executed" }.compactMap(\.toolCallId)
            }
        }
        else if let childID, !messages.contains(where: { $0.content.contains { $0["type"].text == "toolCall" && $0["name"].text == "subagent_send" } }) {
            reply = agentCallReply("follow-up-child","subagent_send",["child_id":JSON(childID),"message":"Do the new follow-up"])
        }
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":JSON(heldTools && sessionID != "parent" && childRequests == 1 ? 0.6 : 0.01)]]]
        try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
        await onObservation(observation); reply.message.requestAttemptIDs = [attempt]; return reply
    }
}

private actor DeliveryCompactionClient: ModelClient {
    var turnWaiting = false, summaryWaiting = false, summaryCancelled = false
    let holdSibling: Bool
    var siblingWaiting = false
    var turnReleased = false, summaryReleased = false
    init(holdSibling: Bool = false) { self.holdSibling = holdSibling }
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
                if holdSibling {
                    siblingWaiting = true
                    while !summaryReleased { try permit.check(); try await Task.sleep(for:.milliseconds(2)) }
                } else if !messages.contains(where: { $0.role == "toolResult" }) { reply = toolReply(["first"]) }
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
    func fixtureCompactionHistory(bytes: Int = 30000) throws {
        for index in 0..<6 {
            var input = ChatMessage(role:"user",content:[textBlock("Earlier task \(index)")])
            input.taskRootID = input.id
            var reply = ChatMessage(role:"assistant",content:[textBlock(String(repeating:"x",count:bytes))])
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
        fixtureNotePausedMember("unkept-side")
        let old = SidePausePublication(side:pauseGeneration,root:pauseGeneration)
        _ = endCostPause()
        fixtureNotePausedMember("unkept-side")
        acknowledgeSidePause("side",generation:old)
    }

    func fixtureDelaySidePauses(_ gate: OpenGate, finished: CloseFenceProbe? = nil) {
        for (side, notify) in sideBudgetStops {
            sideBudgetStops[side] = { reason, resumes in await gate.wait(); await notify(reason,resumes); finished?.mark(side) }
        }
    }

    func fixtureResumeThenStop(closing: Bool) async throws -> Bool {
        _ = try continueRun(commandID:"resume")
        let pending = costResumePending && costPaused
        if closing { await close() } else { stop() }
        return pending
    }
}

/// Round 4: a pause transfer needs a durable acknowledgment, and a terminal
/// child must have no Resume-only state even when no follow-up ever arrives.
extension FamilyLimitPauseTests {
    func testRecoveredMembershipSurvivesFailedRootAcknowledgments() async throws {
        for failure in ["append","sync","source"] {
            let root = try temporaryDirectory(), crash = root.appendingPathComponent("crash")
            defer { try? FileManager.default.removeItem(at:root) }
            let fault = PauseWriteFault()
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),
                beforeJournalAppend:{ try fault.append($0,writer:"parent") },beforeJournalSynchronize:{ try fault.synchronize(writer:"parent") })
            let side = try await faultSide(parent:owner,root:root,fault:fault)
            let leaf = try await self.side("leaf",parent:side,root:root)
            _ = try await leaf.keep(whenFinished:false)
            await leaf.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Leaf work"))
            try await leaf.fixtureSavedPauseMembers([])
            try await side.fixturePauseLists(members:["leaf"],pending:[])
            let parentPath = try XCTUnwrap(awaitValue: await owner.path)
            let durableParent = try Data(contentsOf:URL(fileURLWithPath:parentPath))
            fault.arm(failure == "source" ? "side" : "parent",sync:failure == "sync",emptyMembers:failure == "source")
            for _ in 0..<2 {
                do { try await side.bindSideBudget(to:owner) } catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_pause_write") }
                let snapshot = await side.snapshot()
                XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["leaf"],"\(failure): source survives every unacknowledged transfer, including known-member retry")
            }
            try FileManager.default.createDirectory(at:crash,withIntermediateDirectories:true)
            for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where file.pathExtension == "jsonl" {
                try FileManager.default.copyItem(at:file,to:crash.appendingPathComponent(file.lastPathComponent))
            }
            // An unsuccessful synchronize provides no promise that its bytes
            // survive. Simulate their loss, not an orderly close's later flush.
            if failure == "sync" { try durableParent.write(to:crash.appendingPathComponent("parent.jsonl")) }
            fault.disarm(); await leaf.close(); await side.close(); await owner.close()
            func reopen(_ id: String) throws -> AgentSession {
                let file = try XCTUnwrap(SideBudgetRecovery.journalURL(id,directory:crash))
                return try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:crash,directory:crash,readOnly:true,
                    resources:Resources(cwd:crash,home:crash),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:file.path)
            }
            let restored = try reopen("parent"), restoredSide = try reopen("side")
            try await restoredSide.bindSideBudget(to:restored)
            var reply: JSON = .null
            do { reply = try await restored.continueRun(commandID:"resume-root") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"nothing_to_continue") }
            XCTAssertTrue(reply["pausedMembers"].list.contains("leaf"),"The app must still receive the unopened descendant after \(failure)")
            await restoredSide.close(); await restored.close()
        }
    }

    func testFailedTransferRetainsMembershipAddedDuringRootAcknowledgment() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let fault = PauseWriteFault(), barrier = PauseWriteBarrier()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),beforeJournalAppend:{ barrier.append($0) })
        let side = try await faultSide(parent:owner,root:root,fault:fault)
        let leaf = try await self.side("leaf",parent:side,root:root)
        _ = try await leaf.keep(whenFinished:false); try await leaf.fixtureSavedPauseMembers([])
        try await owner.fixtureSavedPauseMembers([])
        try await side.fixturePauseLists(members:["leaf"],pending:[])
        barrier.arm()
        let binding = Task { try await side.bindSideBudget(to:owner) }
        do { try await eventually { barrier.waiting } }
        catch { barrier.release(); _ = try? await binding.value; throw error }
        // The root's save is in flight while the side learns another member.
        // The source failure must restore both, not its pre-await snapshot.
        try await side.fixturePauseLists(members:["leaf","later"],pending:[])
        fault.arm("side"); barrier.release()
        do { try await binding.value; XCTFail("Expected source save failure") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_pause_write") }
        let snapshot = await side.snapshot()
        XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["leaf","later"])
        fault.disarm(); await leaf.close(); await side.close(); await owner.close()
    }

    func testSideFanoutKeepsIntentUntilBothPauseAndRootMembershipAreDurable() async throws {
        for failedWriter in ["parent","side"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let fault = PauseWriteFault()
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),
                beforeJournalAppend:{ try fault.append($0,writer:"parent") })
            let intermediate = try await self.side("intermediate",parent:owner,root:root)
            _ = try await intermediate.keep(whenFinished:false)
            let side = try await faultSide(parent:intermediate,root:root,fault:fault)
            await side.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Side work"))
            try await side.fixturePauseLists(members:[],pending:[])
            try await intermediate.fixturePauseLists(members:[],pending:["side"])
            // Fail the new pause/member save, but let an erroneous removal
            // succeed, so this distinguishes ordering from a blocked writer.
            fault.arm(failedWriter,matchingPause:true)
            try await intermediate.fixtureNotifySide("side")
            let path = try XCTUnwrap(awaitValue: await intermediate.path)
            let saved = try SideBudgetRecovery.pauseState(URL(fileURLWithPath:path),id:"intermediate").state
            XCTAssertTrue(saved["costPendingSidePauses"].list.contains("side"),"\(failedWriter): failed replacement must keep the durable intent")
            fault.disarm(); await intermediate.close(); await side.close(); await owner.close()
        }
    }

    func testAutomaticPauseRetirementWaitsForItsDurableSave() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let fault = PauseWriteFault(), owner = try familyFixture(root:root)
        let side = try await faultSide(parent:owner,root:root,fault:fault)
        try await side.fixtureSavedPauseMembers([]); await owner.fixtureNotePausedMember("side")
        fault.arm("side",emptyMembers:true)
        await side.clearCostPauseWithoutWork()
        try await Task.sleep(for:.milliseconds(100))
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"],"A failed local save must not retire the root's Resume obligation")
        fault.disarm(); await side.close(); await owner.close()
    }

    func testFailedPauseRemovalsSurviveALaterStateSaveAndRestart() async throws {
        for removal in ["member","intent"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let fault = PauseWriteFault()
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),
                beforeJournalAppend:{ try fault.append($0,writer:"parent") })
            let side = try await self.side("side",parent:owner,root:root)
            _ = try await side.keep(whenFinished:false)
            await side.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Held work"))
            try await side.fixtureSavePauseState()
            if removal == "member" { try await owner.fixtureSavedPauseMembers(["side"]) }
            else { try await owner.fixturePauseLists(members:[],pending:["side"]) }
            fault.arm("parent",emptyMembers:true)
            if removal == "member" { await owner.fixtureForgetPausedMember("side") }
            else { await owner.fixtureAcknowledgeSidePause("side") }
            fault.disarm(); try await owner.fixtureSavePauseState()
            let path = await owner.path; await side.close(); await owner.close()
            let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path)
            var reply: JSON = .null
            do { reply = try await restored.continueRun(commandID:"resume") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"nothing_to_continue") }
            XCTAssertEqual(reply["pausedMembers"].list,["side"],"\(removal): an unrelated save cannot commit a failed retirement")
            await restored.close()
        }
    }

    private func faultSide(parent: AgentSession, root: URL, fault: PauseWriteFault) async throws -> AgentSession {
        let initial = try await side("side",parent:parent,root:root)
        _ = try await initial.keep(whenFinished:false)
        let path = await initial.path; await initial.close()
        let side = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path,
            beforeJournalAppend:{ try fault.append($0,writer:"side") })
        try await side.bindSideBudget(to:parent); return side
    }

    func testParkedStopClearsRetainedAndReopenedChildSnapshots() async throws {
        for route in ["subagent.stop","turn.stop"] { for mode in ["off","memory","persist"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let host = NativeHostService(emit:{ _ in })
            _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
            _ = try await host.command("session.open",sessionID:"parent",params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","captureMode":JSON(mode)])
            let owner = try XCTUnwrap(awaitValue: await host.loadedSession("parent"))
            let coordinator = try XCTUnwrap(awaitValue: await owner.agentCoordinator)
            await coordinator.fixturePause(owner)
            let id = try await startChild(owner,coordinator,"parked")
            try await owner.fixtureAcceptedReceipt("parked")
            try await owner.fixtureSavedPauseMembers([])
            try await eventually { await coordinator.jobs.isEmpty }
            // Open after the parked runner has been evicted: this retained
            // reader is not the runtime the coordinator previously ran.
            _ = try await host.command("session.open",sessionID:id,params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","path":JSON(root.appendingPathComponent(id + ".jsonl").path)])
            let reader = try XCTUnwrap(awaitValue: await host.loadedSession(id))
            let before = await reader.snapshot(); XCTAssertEqual(before["costPaused"].flag,true)
            let reply = try await host.command(route,sessionID:route == "subagent.stop" ? "parent" : id,params:route == "subagent.stop" ? ["childId":JSON(id),"turn":1] : [:])
            XCTAssertEqual(reply["accepted"].flag,true)
            for snapshot in [await reader.snapshot(),try await host.command("session.snapshot",sessionID:id,params:[:])] {
                XCTAssertNotEqual(snapshot["costPaused"].flag,true,"\(route)/\(mode): stopped reader must not promise parent Resume")
                XCTAssertNotEqual(snapshot["cost"]["paused"].flag,true)
            }
            await host.shutdown()
            let cold = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:root.appendingPathComponent(id + ".jsonl").path)
            let snapshot = await cold.snapshot()
            XCTAssertNotEqual(snapshot["costPaused"].flag,true,"Cold terminal reader cannot offer Resume")
            XCTAssertNotEqual(snapshot["cost"]["paused"].flag,true)
            await cold.close()
        } }
    }

    func testParkedStopAfterChildWriterClosesStillRetiresItsPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate = OpenGate(), coordinator = AgentSteeringCoordinator(settled:{ child in await child.close(); await gate.wait() })
        let owner = try await steeringOwner(root,client:ScriptClient([]),coordinator:coordinator)
        await coordinator.fixturePause(owner)
        let id = try await startChild(owner,coordinator,"closing")
        try await owner.fixtureAcceptedReceipt("closing"); try await owner.fixtureSavedPauseMembers([])
        try await eventually { await gate.waiting }
        do { try await coordinator.stop(parent:owner,target:.init(childID:id,turn:1),human:true) }
        catch { XCTFail("A closing parked writer cannot prevent Stop acknowledgment: \(error)") }
        await gate.open(); try await eventually { await coordinator.jobs.isEmpty }
        let listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertEqual(listed.first?["status"].text,"not_executed")
        let reader = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:root.appendingPathComponent(id + ".jsonl").path)
        let snapshot = await reader.snapshot(); XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        await reader.close(); await owner.close()
    }

    func testColdParkedStopKeepsOtherChatsResponsiveAndRuntimeGated() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = NativeHostService(emit:{ _ in }), profile = try fixtureProfile()
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
        for id in ["parent","other"] {
            _ = try await host.command("session.open",sessionID:id,params:["profile":profile.raw,"apiKey":"fixture","toolMode":"read-only","captureMode":"off"])
        }
        let owner = try XCTUnwrap(awaitValue: await host.loadedSession("parent"))
        let coordinator = try XCTUnwrap(awaitValue: await owner.agentCoordinator)
        await coordinator.fixturePause(owner)
        let id = try await startChild(owner,coordinator,"cold")
        try await owner.fixtureAcceptedReceipt("cold"); try await owner.fixtureSavedPauseMembers([])
        try await eventually { await coordinator.jobs.isEmpty }
        let loaded = await host.loadedSession(id); XCTAssertNil(loaded,"Exercise the evicted writer")
        let path = root.appendingPathComponent(id + ".jsonl")
        try appendLongParkedHistory(path,id:id,root:root)

        let gate = ColdTerminalMirrorGate(), began = expectation(description:"Cold terminal mirror entered")
        defer { gate.open() }
        await host.holdTerminalMirror { began.fulfill(); gate.wait() }
        let ack = StopReply()
        let stopping = Task {
            let start = ContinuousClock.now
            let reply = try await host.command("subagent.stop",sessionID:"parent",params:["childId":JSON(id),"turn":1])
            await ack.receive(reply,elapsed:start.duration(to:.now)); return reply
        }
        await fulfillment(of:[began],timeout:5)
        let snapshotServed = expectation(description:"Other snapshot while cold mirror is held")
        let stopServed = expectation(description:"Other Stop while cold mirror is held")
        let snapshot = Task { let reply = try await host.command("session.snapshot",sessionID:"other",params:["includeMessages":false]); snapshotServed.fulfill(); return reply }
        let stop = Task { let reply = try await host.command("turn.stop",sessionID:"other",params:[:]); stopServed.fulfill(); return reply }
        let opened = StopReply()
        let opening = Task {
            let reply = try await host.command("session.open",sessionID:id,params:["profile":profile.raw,"apiKey":"fixture","path":JSON(path.path)])
            await opened.receive(reply,elapsed:.zero); return reply
        }
        await fulfillment(of:[snapshotServed,stopServed],timeout:1)
        let premature = await opened.reply; XCTAssertNil(premature,"A reader must wait for the cold writer's runtime gate")
        let replayStart = nowMS(); gate.open()
        var worst = 0.0, served = 0
        while await ack.reply == nil {
            let start = nowMS()
            _ = try await host.command("session.snapshot",sessionID:"other",params:["includeMessages":false])
            let reply = try await host.command("turn.stop",sessionID:"other",params:[:])
            XCTAssertEqual(reply["accepted"].flag,true)
            worst = max(worst,nowMS()-start)
            if await ack.reply == nil { served += 1 }
            try await Task.sleep(for:.milliseconds(2))
        }
        let replayMS = nowMS()-replayStart
        let stopped = try await stopping.value, otherSnapshot = try await snapshot.value, otherStop = try await stop.value
        XCTAssertEqual(stopped["accepted"].flag,true); XCTAssertEqual(otherStop["accepted"].flag,true)
        XCTAssertEqual(otherSnapshot["sessionId"].text,"other")
        XCTAssertGreaterThan(served,0,"Other chat commands also complete during the real 12,000-row replay")
        XCTAssertLessThan(worst,max(100,replayMS/3),"Cold journal replay must not monopolize the host actor")
        print("PERF cold-terminal-mirror messages=12000 replayMs=\(Int(replayMS)) otherChatWorstMs=\(Int(worst)) served=\(served)")
        let child = try await opening.value
        XCTAssertEqual(child["total"].int,12_000)
        XCTAssertNotEqual(child["costPaused"].flag,true,"The reader opens only after the terminal mirror is durable")
        await host.shutdown()
    }

    private func appendLongParkedHistory(_ path: URL, id: String, root: URL) throws {
        let journal = try SessionJournal(url:path,id:id,cwd:root,binding:nil,create:false)
        for index in 0..<12_000 {
            let message = ChatMessage(role:index.isMultiple(of:2) ? "user" : "assistant",content:[textBlock("Message \(index) " + String(repeating:"x",count:200))])
            try journal.append(["type":"message","message":message.pi],id:"long-\(index)",flush:false)
        }
        try journal.synchronize()
    }

    func testLateSidePauseCannotResurrectClosedOrDeletedMembership() async throws {
        for kept in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let gate = OpenGate(), owner = try familyFixture(root:root)
            let side = try await self.side("side",parent:owner,root:root)
            if kept { _ = try await side.keep(whenFinished:false) }
            await side.fixtureQueue(Submission(commandID:"held",turnID:"held",text:"Held side input"))
            await owner.fixtureDelaySidePauses(gate)
            await owner.stopFamilyAtLimit(AgentSession.costHoldError)
            try await eventually { await gate.waiting }
            let notify = try XCTUnwrap(awaitValue:await owner.sideBudgetStops["side"])
            let generation = SidePausePublication(side:owner.pauseGeneration,root:owner.pauseGeneration)
            let path = await side.path; await side.close()
            if let path { try FileManager.default.removeItem(atPath:path) }
            await owner.forgetDeletedMembers(["side"])
            await gate.open()
            // Await the same callback directly too: all publications from
            // the first callback either precede this one or see closed.
            await notify(AgentSession.costHoldError,generation)
            try await Task.sleep(for:.milliseconds(50))
            let snapshot = await owner.snapshot()
            XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
            XCTAssertNotEqual(snapshot["costPaused"].flag,true)
            await owner.close()
        }
    }

    func testFailedTerminalPauseCleanupRetriesWithoutReplayingHeldTools() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = FollowUpAfterStopClient(heldTools:true), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
        await owner.setCostLimit(0.5)
        let id = try await startChild(owner,coordinator,"held")
        try await owner.fixtureAcceptedReceipt("held")
        try await eventually { await coordinator.jobs.isEmpty }
        var turn = try XCTUnwrap(awaitValue: await owner.agentState().latest(id))
        let plan = try XCTUnwrap(awaitValue: await owner.subagents.plans.values.first { $0.origin.link.childSessionID == id })
        turn.status = .interrupted
        turn.result = SubagentToolResult(plan:plan,status:.interrupted,error:AgentError("subagent_stopped","Stopped"),began:true)
        turn.normalizeResult()
        let fault = PauseWriteFault(), tools = RecordingTools()
        let reader = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),resumePath:root.appendingPathComponent(id + ".jsonl").path,
            beforeJournalAppend:{ try fault.append($0,writer:"child") })
        fault.arm("child",emptyMembers:true)
        do { try await reader.saveAgentTerminal(turn); XCTFail("Terminal cleanup did not confirm its state save") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_pause_write") }
        fault.disarm(); try await reader.saveAgentTerminal(turn)
        let snapshot = await reader.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        let saved = try SideBudgetRecovery.pauseState(root.appendingPathComponent(id + ".jsonl"),id:id).state
        XCTAssertNotEqual(saved["costPaused"].flag,true)
        XCTAssertTrue(saved["costPendingCalls"].list.isEmpty)
        let history = await reader.history, calls = await tools.calls
        XCTAssertEqual(history.filter { $0.role == "toolResult" && $0.toolCallId == "call-0" }.count,1)
        XCTAssertTrue(calls.isEmpty)
        await reader.close(); await owner.close()
    }

    func testTerminalRecoveryRetiresChildPauseAndHeldToolsBeforeAnyFollowUp() async throws {
        for mode in ["off","memory","persist"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = FollowUpAfterStopClient(heldTools:true), traces = TraceStore(), tools = RecordingTools()
            _ = try await traces.command("debug.mode",session:"parent",params:["mode":JSON(mode)])
            let coordinator = AgentSteeringCoordinator()
            let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces)
            await owner.enableFamilyBudget(); await owner.enableSubagents(SubagentCoordinator()); await owner.enableAgentSteering(coordinator)
            await owner.setCostLimit(0.5)
            let id = try await startChild(owner,coordinator,"held")
            try await owner.fixtureAcceptedReceipt("held")
            try await eventually { await coordinator.jobs.isEmpty }
            // Crash after durable Stop admission, before either terminal or
            // pause cleanup. Parent recovery must retire the child too.
            var run = try XCTUnwrap(awaitValue: await owner.agentState().run)
            run.heldChildren.append(id); try await owner.appendAgentRecord(JournalRecordKind.familyRun,run)
            let parentPath = await owner.path; await owner.close()
            let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,resumePath:parentPath)
            let cold = try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,resumePath:root.appendingPathComponent(id + ".jsonl").path)
            let snapshot = await cold.snapshot(), history = await cold.history
            XCTAssertNotEqual(snapshot["costPaused"].flag,true)
            XCTAssertNotEqual(snapshot["cost"]["paused"].flag,true)
            let results = history.filter { $0.role == "toolResult" && $0.toolCallId == "call-0" }
            XCTAssertEqual(results.count,1,"The terminal transcript pairs the held tool immediately")
            XCTAssertEqual(results.first?.toolStats?["outcome"].text,"not_executed")
            let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
            let saved = try SideBudgetRecovery.pauseState(root.appendingPathComponent(id + ".jsonl"),id:id).state
            XCTAssertNotEqual(saved["costPaused"].flag,true); XCTAssertTrue(saved["costPendingCalls"].list.isEmpty)
            await cold.close(); await restored.close()
        }
    }
}

private final class ColdTerminalMirrorGate: @unchecked Sendable {
    private let release = DispatchSemaphore(value:0)
    func wait() { _ = release.wait(timeout:.now() + 10) }
    func open() { release.signal() }
}

private extension NativeHostService {
    func holdTerminalMirror(_ action: @escaping @Sendable () -> Void) { beforeChildTerminalMirror = action }
}

/// A synchronous journal hook holds one root write while another actor
/// records a new membership. No provider or shared native lane is involved.
private final class PauseWriteBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false, entered = false, released = false
    var waiting: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func arm() { condition.lock(); armed = true; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func append(_ row: JSON) {
        condition.lock(); defer { condition.unlock() }
        guard armed, row["customType"].text == JournalRecordKind.state, row["data"]["costPausedMembers"].list.contains("leaf") else { return }
        armed = false; entered = true
        while !released { condition.wait() }
    }
}

private final class PauseWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: String?, sync = false, emptyMembers = false, matchingPause = false, hits = 0
    func arm(_ writer: String, sync: Bool = false, emptyMembers: Bool = false, matchingPause: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer; self.sync = sync; self.emptyMembers = emptyMembers; self.matchingPause = matchingPause
    }
    func disarm() { lock.lock(); let count = hits; writer = nil; lock.unlock(); XCTAssertGreaterThan(count,0,"The injected writer failure must actually run") }
    func append(_ record: JSON, writer: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard self.writer == writer, !sync, record["customType"].text == JournalRecordKind.state else { return }
        if emptyMembers, !record["data"]["costPausedMembers"].list.isEmpty { return }
        if matchingPause, record["data"]["costPaused"].flag != true { return }
        hits += 1; throw AgentError("fixture_pause_write","Injected \(writer) pause write failure")
    }
    func synchronize(writer: String) throws {
        lock.lock(); defer { lock.unlock() }
        if self.writer == writer, sync { hits += 1; throw AgentError("fixture_pause_write","Injected \(writer) synchronize failure") }
    }
}

private extension AgentSession {
    func fixtureSavePauseState() throws { try persistState(durable:true) }
    func fixturePauseLists(members: [String], pending: [String]) throws {
        costPausedMembers = members; costPendingSidePauses = pending; try persistState(durable:true)
    }
    func fixtureNotifySide(_ side: String) async throws {
        let notify = try XCTUnwrap(sideBudgetStops[side]); await notify(Self.costHoldError,SidePausePublication(side:pauseGeneration,root:sideBudgetParents.last?.pauseGeneration ?? pauseGeneration))
    }
}

private func XCTUnwrap<T>(awaitValue: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(awaitValue,file:file,line:line)
}

/// Round 6: every durable prefix must be repairable without duplicate reports.
extension FamilyLimitPauseTests {
    func testParkedStopRepairsEveryPartialSealBeforeAcknowledgingRetry() async throws {
        for route in ["subagent.stop","turn.stop"] {
            var recordCount = 0
            // First measure the whole transaction, then fail before each append.
            for cut in [-1] + Array(0..<10) {
                if cut >= 0 && cut >= recordCount { break }
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let fault = SealWriteFault()
                let (host, owner, coordinator, id) = try await partialSealHost(root,fault:fault)
                let session = route == "subagent.stop" ? "parent" : id
                let params: JSON = route == "subagent.stop" ? ["childId":JSON(id),"turn":1] : [:]
                fault.arm(after:cut < 0 ? nil : cut)
                do {
                    let reply = try await host.command(route,sessionID:session,params:params)
                    XCTAssertEqual(reply["accepted"].flag,true)
                    if cut >= 0 { XCTFail("\(route)/\(cut): expected injected append failure") }
                } catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_seal_write","\(route)/\(cut)") }
                let writes = fault.disarm()
                if cut < 0 { recordCount = writes; XCTAssertEqual(writes,9,"Update the boundary matrix if the transaction changes") }
                else { XCTAssertEqual(writes,cut); XCTAssertTrue(fault.failed) }
                for _ in 0..<2 {
                    let reply = try await host.command(route,sessionID:session,params:params)
                    XCTAssertEqual(reply["accepted"].flag,true,"\(route)/\(cut): retry acknowledgment")
                }
                try await assertSealedReports(host,owner:owner,coordinator:coordinator,childID:id,root:root,label:"\(route)/\(cut)")
                await host.shutdown()
            }
        }
    }

    func testRecoveryRepairsEveryPartialSealAndInterruptedNotice() async throws {
        // Copy each durable prefix before retry/close can modify it. Recovery
        // itself then fails after each of its parent writes and is retried.
        for cut in 1..<9 {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let fault = SealWriteFault(), crash = root.appendingPathComponent("crash")
            let (host, _, _, id) = try await partialSealHost(root,fault:fault)
            fault.arm(after:cut)
            do { _ = try await host.command("subagent.stop",sessionID:"parent",params:["childId":JSON(id),"turn":1]); XCTFail("Expected partial seal") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_seal_write") }
            XCTAssertEqual(fault.disarm(),cut); XCTAssertTrue(fault.failed)
            try copySealJournals(root,to:crash)
            await host.shutdown()
            let profile = try fixtureProfile()
            // A full recovery gives the number of writes whose prefixes we
            // must preserve. Each failure run gets a fresh copy of the crash.
            var recoveryWrites = 0
            for recoveryCut in [-1] + Array(0..<10) {
                if recoveryCut >= 0 && recoveryCut >= recoveryWrites { break }
                let attempt = root.appendingPathComponent("repair-\(recoveryCut)")
                try copySealJournals(crash,to:attempt)
                let recoveryFault = SealWriteFault(); recoveryFault.arm(after:recoveryCut < 0 ? nil : recoveryCut)
                do {
                    let session = try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:attempt,directory:attempt,readOnly:true,
                        resources:Resources(cwd:attempt,home:attempt),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:attempt.appendingPathComponent("parent.jsonl").path,
                        beforeJournalAppend:{ try recoveryFault.append($0) })
                    if recoveryCut >= 0 { XCTFail("Expected recovery append failure") }
                    recoveryWrites = recoveryFault.disarm()
                    XCTAssertLessThanOrEqual(recoveryWrites,10,"Extend the recovery boundary matrix if its transaction changes")
                    await session.close()
                } catch {
                    XCTAssertEqual((error as? AgentError)?.code,"fixture_seal_write")
                    XCTAssertEqual(recoveryFault.disarm(),recoveryCut); XCTAssertTrue(recoveryFault.failed)
                }
                let restored = NativeHostService(emit:{ _ in })
                try await openSealWorkspace(restored,root:attempt)
                _ = try await restored.command("session.open",sessionID:"parent",params:["profile":profile.raw,"apiKey":"fixture","path":JSON(attempt.appendingPathComponent("parent.jsonl").path)])
                _ = try await restored.command("session.open",sessionID:id,params:["profile":profile.raw,"apiKey":"fixture","path":JSON(attempt.appendingPathComponent(id + ".jsonl").path)])
                let owner = try XCTUnwrap(awaitValue: await restored.loadedSession("parent"))
                let coordinator = try XCTUnwrap(awaitValue: await owner.agentCoordinator)
                try await assertSealedReports(restored,owner:owner,coordinator:coordinator,childID:id,root:attempt,label:"crash=\(cut)/repair=\(recoveryCut)")
                await restored.shutdown()
            }
        }
    }

    func testSealingRepairsEverySubsetWithoutRedeliveringExistingReports() async throws {
        for recovery in [false,true] { for mask in 0..<16 { for retired in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            var (host, owner, coordinator, id) = try await partialSealHost(root,fault:SealWriteFault())
            var child = try XCTUnwrap(awaitValue: await host.loadedSession(id))
            var turn = try XCTUnwrap(awaitValue: await owner.agentState().latest(id))
            let plan = try XCTUnwrap(awaitValue: await owner.subagents.plans.values.first)
            var run = try XCTUnwrap(awaitValue: await owner.agentState().run)
            run.heldChildren = [id]; try await owner.appendAgentRecord(JournalRecordKind.familyRun,run)
            turn.status = .notExecuted; turn.result = SubagentToolResult(plan:plan,status:.notExecuted); turn.normalizeResult()
            if mask & 1 != 0 { try await owner.appendAgentRecord(JournalRecordKind.agentTerminal,turn) }
            if mask & 2 != 0 {
                let state = await owner.agentState()
                try await owner.appendAgentRecord(JournalRecordKind.agentMessage,AgentFamilyMessage.resultEvent(turn,task:plan.origin.description,sequence:state.sequence + 1))
            }
            for var message in await owner.agentState().pending(author:"parent") {
                if retired { message.disposition = "not_delivered_interrupted"; try await owner.appendAgentRecord(JournalRecordKind.agentMessage,message) }
                if mask & 4 != 0 {
                    let state = await owner.agentState()
                    let notice = AgentFamilyMessage(id:"undelivered:" + message.id,sequence:state.sequence + 1,childID:id,turn:1,author:"subagent",kind:"not_delivered_interrupted",text:"Existing notice",task:message.task,epoch:message.epoch,replyTo:message.id)
                    try await owner.appendAgentRecord(JournalRecordKind.agentMessage,notice)
                }
            }
            if mask & 8 != 0 { try await child.saveAgentTerminal(turn) }
            var directory = root
            if recovery {
                directory = root.appendingPathComponent("crash")
                try copySealJournals(root,to:directory); await host.shutdown()
                host = NativeHostService(emit:{ _ in }); try await openSealWorkspace(host,root:directory)
                let profile = try fixtureProfile()
                _ = try await host.command("session.open",sessionID:"parent",params:["profile":profile.raw,"apiKey":"fixture","path":JSON(directory.appendingPathComponent("parent.jsonl").path)])
                _ = try await host.command("session.open",sessionID:id,params:["profile":profile.raw,"apiKey":"fixture","path":JSON(directory.appendingPathComponent(id + ".jsonl").path)])
                owner = try XCTUnwrap(awaitValue: await host.loadedSession("parent"))
                child = try XCTUnwrap(awaitValue: await host.loadedSession(id))
                coordinator = try XCTUnwrap(awaitValue: await owner.agentCoordinator)
                turn = try XCTUnwrap(awaitValue: await owner.agentState().latest(id))
            }
            let label = "recovery=\(recovery)/subset=\(mask)/retired=\(retired)"
            for _ in 0..<2 {
                do { try await coordinator.fixtureSeal(turn,owner:owner,child:child,task:plan.origin.description) }
                catch { XCTFail(label + ": sealing must repair existing records: \(error)") }
            }
            try await assertSealedReports(host,owner:owner,coordinator:coordinator,childID:id,root:directory,label:label)
            do { try await coordinator.fixtureSeal(turn,owner:owner,child:child,task:plan.origin.description) }
            catch { XCTFail(label + ": delivered reports must remain idempotent: \(error)") }
            let deliveredAgain = try await coordinator.boundary(owner,final:false)
            XCTAssertFalse(deliveredAgain,"A repeated seal must preserve already-delivered reports")
            await host.shutdown()
        } } }
    }

    func testParkingATerminalTurnRepairsItsPartialSeal() async throws {
        for cut in [2,4,6] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let fault = SealWriteFault()
            let (host, owner, coordinator, id) = try await partialSealHost(root,fault:fault)
            let child = try XCTUnwrap(awaitValue: await host.loadedSession(id))
            fault.arm(after:cut)
            do { _ = try await host.command("subagent.stop",sessionID:"parent",params:["childId":JSON(id),"turn":1]); XCTFail("Expected partial seal") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_seal_write") }
            XCTAssertEqual(fault.disarm(),cut)
            await owner.fixtureEndPause()
            try await coordinator.fixtureParkTerminal(owner:owner,child:child)
            try await assertSealedReports(host,owner:owner,coordinator:coordinator,childID:id,root:root,label:"park-after-\(cut)")
            await host.shutdown()
        }
    }

    func testPauseTransferRepairsEveryPartialWriteBeforeSourceRetirement() async throws {
        for cut in 0..<4 {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let fault = SealWriteFault(), owner = try familyFixture(root:root)
            let side = try await self.side("side",parent:owner,root:root)
            _ = try await side.keep(whenFinished:false)
            var leaves: [AgentSession] = []
            for id in ["leaf","later"] {
                let leaf = try await self.side(id,parent:side,root:root)
                _ = try await leaf.keep(whenFinished:false)
                await leaf.fixtureQueue(Submission(commandID:id,turnID:id,text:"Held work"))
                try await leaf.fixtureSavedPauseMembers([]); leaves.append(leaf)
            }
            try await owner.fixtureSavedPauseMembers([])
            try await side.fixturePauseLists(members:["leaf","later"],pending:[])
            try await owner.fixtureSealWriter(fault); try await side.fixtureSealWriter(fault)
            fault.arm(after:cut)
            do { try await side.bindSideBudget(to:owner) }
            catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_seal_write") }
            XCTAssertEqual(fault.disarm(),cut); XCTAssertTrue(fault.failed)
            for _ in 0..<2 { try await side.bindSideBudget(to:owner) }
            let snapshot = await side.snapshot()
            XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty,"Source retires only after both replacements")
            let parentPath = await owner.path
            for leaf in leaves { await leaf.close() }; await side.close(); await owner.close()
            let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:parentPath)
            let reply = try await restored.continueRun(commandID:"resume")
            XCTAssertEqual(Set(reply["pausedMembers"].list.compactMap(\.text)),Set(["leaf","later"]),"\(cut): the app receives every transferred member once")
            XCTAssertEqual(reply["pausedMembers"].list.count,2)
            await restored.close()
        }
    }

    func testSidePauseFanoutRepairsEveryPartialWriteBeforeAcknowledgment() async throws {
        var recordCount = 0
        for cut in [-1] + Array(0..<10) {
            if cut >= 0 && cut >= recordCount { break }
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let fault = SealWriteFault(), owner = try familyFixture(root:root)
            let side = try await self.side("side",parent:owner,root:root)
            _ = try await side.keep(whenFinished:false)
            await side.fixtureQueue(Submission(commandID:"work",turnID:"work",text:"Held side work"))
            try await side.fixtureSavePauseState()
            try await owner.fixtureSavedPauseMembers([])
            try await owner.fixturePauseLists(members:[],pending:["side"])
            try await owner.fixtureSealWriter(fault); try await side.fixtureSealWriter(fault)
            fault.arm(after:cut < 0 ? nil : cut)
            try await owner.fixtureNotifySide("side")
            // Drain the additional publication scheduled by the side's first
            // pause before inspecting the durable fan-out prefix.
            _ = await side.fixturePublishSidePause(repair:true)
            try await Task.sleep(for:.milliseconds(10))
            let writes = fault.disarm()
            if cut < 0 { recordCount = writes; XCTAssertGreaterThan(writes,0); XCTAssertLessThanOrEqual(writes,10) }
            else { XCTAssertEqual(writes,cut); XCTAssertTrue(fault.failed) }
            for _ in 0..<2 { try await owner.fixtureNotifySide("side") }
            let sideSnapshot = await side.snapshot(); XCTAssertEqual(sideSnapshot["costPaused"].flag,true)
            let saved = try SideBudgetRecovery.pauseState(root.appendingPathComponent("parent.jsonl"),id:"parent").state
            XCTAssertTrue(saved["costPendingSidePauses"].list.isEmpty,"Only the repaired fan-out can acknowledge its intent")
            let parentPath = await owner.path; await side.close(); await owner.close()
            let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:parentPath)
            let reply = try await restored.continueRun(commandID:"resume")
            XCTAssertEqual(reply["pausedMembers"].list,["side"],"\(cut): the app receives the paused side exactly once")
            await restored.close()
        }
    }

    func testRecoveryRepairsOldTurnNoticesWhileTheFollowUpStaysParked() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let fault = SealWriteFault(), crash = root.appendingPathComponent("crash")
        let (host, owner, _, id) = try await partialSealHost(root,fault:fault)
        fault.arm(after:4)
        do { _ = try await host.command("subagent.stop",sessionID:"parent",params:["childId":JSON(id),"turn":1]); XCTFail("Expected partial seal") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_seal_write") }
        XCTAssertEqual(fault.disarm(),4)
        let child = try XCTUnwrap(awaitValue: await host.loadedSession(id))
        let first = try XCTUnwrap(awaitValue: await owner.agentState().latest(id))
        try await child.saveAgentTerminal(first)
        let key = SubagentCallKey(parentSessionID:"parent",assistantMessageID:"follow-up",toolCallID:"next")
        let next = AgentChildTurn(childID:id,turn:2,executionID:"second",parentExecutionID:"next-execution",generation:0,runtimeID:"next-runtime",epoch:"next-execution",inputID:"next-input",task:"Follow-up",call:key)
        try await owner.appendAgentRecord(JournalRecordKind.agentOperation,AgentOperation(key:key,digest:"fixture",receipt:["accepted":true],turn:next,epoch:"next-execution"))
        try await child.appendAgentRecord(JournalRecordKind.agentTurn,next); await child.fixtureCoordinatorPause(); try await child.parkAgentTurn(next,generation:child.pauseGeneration)
        let state = await owner.agentState()
        try await owner.appendAgentRecord(JournalRecordKind.agentMessage,AgentFamilyMessage(id:"next-steer",sequence:state.sequence + 1,childID:id,turn:2,author:"parent",kind:"steer",text:"Input for the held follow-up",task:"Follow-up",epoch:"next-execution"))
        try copySealJournals(root,to:crash); await host.shutdown()
        let restored = NativeHostService(emit:{ _ in }), profile = try fixtureProfile()
        try await openSealWorkspace(restored,root:crash)
        _ = try await restored.command("session.open",sessionID:"parent",params:["profile":profile.raw,"apiKey":"fixture","path":JSON(crash.appendingPathComponent("parent.jsonl").path)])
        let reader = try await restored.command("session.open",sessionID:id,params:["profile":profile.raw,"apiKey":"fixture","path":JSON(crash.appendingPathComponent(id + ".jsonl").path)])
        XCTAssertEqual(reader["costPaused"].flag,true,"The new unsealed turn remains paused")
        let parent = try XCTUnwrap(awaitValue: await restored.loadedSession("parent"))
        let coordinator = try XCTUnwrap(awaitValue: await parent.agentCoordinator)
        await parent.fixtureEndPause(); _ = try await coordinator.boundary(parent,final:false)
        let snapshot = try await restored.command("session.snapshot",sessionID:"parent",params:[:])
        let events = snapshot["messages"].list.flatMap { $0["nativeAgentDelivery"]["events"].list }
        XCTAssertEqual(events.filter { $0["kind"].text == "result" }.count,1)
        XCTAssertEqual(Set(events.filter { $0["kind"].text == "not_delivered_interrupted" }.compactMap { $0["reply_to"].text }),Set(["steer-1","steer-2"]))
        let page = try await restored.command("subagent.list",sessionID:"parent",params:[:])
        XCTAssertEqual(page["children"].list.first?["turn"].int,2)
        XCTAssertEqual(page["children"].list.first?["pendingMessages"].int,1,"Only the new turn's steering remains pending")
        await restored.shutdown()
    }

    private func openSealWorkspace(_ host: NativeHostService, root: URL) async throws {
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
    }

    private func partialSealHost(_ root: URL, fault: SealWriteFault) async throws -> (NativeHostService,AgentSession,AgentSteeringCoordinator,String) {
        let host = NativeHostService(emit:{ _ in }), profile = try fixtureProfile()
        try await openSealWorkspace(host,root:root)
        _ = try await host.command("session.open",sessionID:"parent",params:["profile":profile.raw,"apiKey":"fixture","toolMode":"read-only","captureMode":"off"])
        let owner = try XCTUnwrap(awaitValue: await host.loadedSession("parent"))
        let coordinator = try XCTUnwrap(awaitValue: await owner.agentCoordinator)
        await coordinator.fixturePause(owner)
        let id = try await startChild(owner,coordinator,"partial")
        try await owner.fixtureAcceptedReceipt("partial"); try await owner.fixtureSavedPauseMembers([])
        try await eventually { await coordinator.jobs.isEmpty }
        for index in 1...2 {
            let state = await owner.agentState()
            let message = AgentFamilyMessage(id:"steer-\(index)",sequence:state.sequence + 1,childID:id,turn:1,author:"parent",kind:"steer",text:"Pending steering \(index)",task:"Worker partial",epoch:state.run!.epoch)
            try await owner.appendAgentRecord(JournalRecordKind.agentMessage,message)
        }
        _ = try await host.command("session.open",sessionID:id,params:["profile":profile.raw,"apiKey":"fixture","path":JSON(root.appendingPathComponent(id + ".jsonl").path)])
        let child = try XCTUnwrap(awaitValue: await host.loadedSession(id))
        try await owner.fixtureSealWriter(fault); try await child.fixtureSealWriter(fault)
        return (host,owner,coordinator,id)
    }

    private func assertSealedReports(_ host: NativeHostService, owner: AgentSession, coordinator: AgentSteeringCoordinator, childID: String, root: URL, label: String) async throws {
        let child = try await host.command("session.snapshot",sessionID:childID,params:[:])
        XCTAssertNotEqual(child["costPaused"].flag,true,label)
        let listed = try await host.command("subagent.list",sessionID:"parent",params:[:])
        XCTAssertEqual(listed["children"].list.first?["status"].text,"not_executed",label)
        await owner.fixtureEndPause()
        _ = try await coordinator.boundary(owner,final:false)
        let snapshot = try await host.command("session.snapshot",sessionID:"parent",params:[:])
        let events = snapshot["messages"].list.flatMap { $0["nativeAgentDelivery"]["events"].list }
        XCTAssertEqual(events.filter { $0["kind"].text == "result" }.count,1,label + ": one result reaches the parent")
        XCTAssertEqual(Set(events.filter { $0["kind"].text == "not_delivered_interrupted" }.compactMap { $0["reply_to"].text }),Set(["steer-1","steer-2"]),label + ": every undelivered input is reported")
        let fenced = try await owner.closeAgentFamilyFence(); XCTAssertTrue(fenced,label + ": no stranded steering blocks completion")
        for id in ["parent",childID] {
            let rows = try Data(contentsOf:root.appendingPathComponent(id + ".jsonl")).split(separator:10).map { try JSON.parse(Data($0)) }
            XCTAssertEqual(rows.filter { $0["customType"].text == JournalRecordKind.agentTerminal }.count,1,label + "/" + id + ": terminal appended once")
            if id == "parent" {
                for kind in ["result","not_delivered_interrupted"] {
                    let messages = rows.filter { $0["customType"].text == JournalRecordKind.agentMessage && $0["data"]["kind"].text == kind }
                    XCTAssertEqual(messages.count,kind == "result" ? 1 : 2,label + ": no duplicate \(kind) records")
                }
            }
        }
    }

    private func copySealJournals(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        for file in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) where file.pathExtension == "jsonl" {
            try FileManager.default.copyItem(at:file,to:destination.appendingPathComponent(file.lastPathComponent))
        }
    }
}

private final class SealWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false, limit: Int?, writes = 0, hit = false
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return hit }
    func arm(after: Int?) { lock.lock(); active = true; limit = after; writes = 0; hit = false; lock.unlock() }
    @discardableResult func disarm() -> Int { lock.lock(); defer { lock.unlock() }; active = false; return writes }
    func append(_ row: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        if writes == limit { hit = true; throw AgentError("fixture_seal_write","Injected failure after \(writes) records") }
        writes += 1
    }
}

private extension AgentSession {
    func fixtureSealWriter(_ fault: SealWriteFault) throws {
        let url = try XCTUnwrap(journal?.url)
        try journal?.synchronize(); journal = nil
        journal = try SessionJournal(url:url,id:id,cwd:cwd,binding:nil,create:false,beforeAppend:{ try fault.append($0) })
    }
}

private extension AgentSteeringCoordinator {
    func fixtureSeal(_ turn: AgentChildTurn, owner: AgentSession, child: AgentSession, task: String) async throws {
        let ownerID = await owner.id, lock = gate(ownerID); try await lock.acquire()
        do { try await seal(turn:turn,parent:owner,task:task,child:child); await lock.release() }
        catch { await lock.release(); throw error }
    }
    func fixtureParkTerminal(owner: AgentSession, child: AgentSession) async throws {
        let env = try await owner.delegationEnvironment()
        let plan = try XCTUnwrap(awaitValue: await owner.subagents.plans.values.first)
        var turn = try XCTUnwrap(awaitValue: await owner.agentState().latest(child.id))
        turn.status = .queued; turn.result = nil
        let job = Job(owner:owner,environment:env,plan:plan,turn:turn)
        await owner.fixtureCoordinatorPause(); jobs[turn.id] = job; await park(job,child:child,generation:owner.pauseGeneration)
    }
}

/// Round 7: every asynchronous pause message belongs to one generation.
extension FamilyLimitPauseTests {
    func testStopDuringContinuationInstallationKeepsTheFamilyResumable() async throws {
        for phase in ["before-first","before-second","after-install"] {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate = OpenGate(), client = AccountedAgentScript(Array(repeating:answer("Finished"),count:6))
        let coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
        await coordinator.fixturePause(owner)
        for name in ["one","two"] {
            _ = try await startChild(owner,coordinator,name,newTask:name == "one")
            try await owner.fixtureAcceptedReceipt(name)
        }
        try await eventually { await coordinator.jobs.isEmpty }
        await owner.fixtureCostPause()
        await coordinator.fixtureHoldResumePhase(gate,phase:phase)
        _ = try await owner.continueRun(commandID:"first")
        try await eventually { await gate.waiting }
        await owner.stop()
        await gate.open()
        try await eventually { !(await owner.isRunning) }
        let stopped = await owner.snapshot(), requests = await client.requests.count
        XCTAssertEqual(stopped["costPaused"].flag,true,"Stop before install commits must preserve the pause")
        XCTAssertEqual(requests,0,"No child starts before the Resume commit")
        let listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertTrue(listed.allSatisfy { $0["costPaused"].flag == true },"Every unsealed child remains held")
        await coordinator.fixtureHoldResumePhase(nil,phase:phase)
        _ = try await owner.continueRun(commandID:"second")
        do { try await eventually(timeout:.seconds(2)) { await owner.agentState().turns.values.allSatisfy { $0.status.terminal } } }
        catch { XCTFail("A second Resume must release every child after the interrupted install") }
        let final = await owner.snapshot()
        XCTAssertNotEqual(final["costPaused"].flag,true)
        await owner.close()
        }
    }

    func testDuplicateSidePublicationCannotUndoTheRootsAcceptedResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), gate = OpenGate()
        let side = try await self.side("side",parent:owner,root:root)
        _ = try await side.keep(whenFinished:false)
        try await side.fixtureSavedPauseMembers([])
        await side.fixtureHoldPausePublication(gate)
        let original = Task { await side.fixturePublishSidePause() }
        try await eventually { await gate.waiting }
        let repaired = await side.fixturePublishSidePause(repair:true); XCTAssertTrue(repaired)
        let reply = try await owner.continueRun(commandID:"resume-root")
        XCTAssertEqual(reply["pausedMembers"].list,["side"])
        let accepted = await owner.snapshot()
        await gate.open(); _ = await original.value
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["costPaused"],accepted["costPaused"],"The app keeps showing the sides still awaiting Resume")
        XCTAssertEqual(snapshot["queuePaused"].flag,false)
        XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"],"Membership remains covered by the accepted Resume")
        await side.fixtureHoldPausePublication(nil)
        _ = try await side.continueRun(commandID:"resume-side")
        try await eventually { await owner.costPausedMembers.isEmpty }
        let completed = await owner.snapshot(); XCTAssertNotEqual(completed["costPaused"].flag,true)
        await side.close(); await owner.close()
    }
}

private extension AgentSession {
    func fixtureHoldPausePublication(_ gate: OpenGate?) {
        if let gate { beforeSidePausePublication = { await gate.wait() } } else { beforeSidePausePublication = nil }
    }
}

private extension AgentSession {
    // A coordinator-only hold used by older boundary fixtures also needs the
    // owner's pause identity. Leave admission open to seed accepted work.
    func fixtureCoordinatorPause() { if !costPaused { costPaused = true; costPauseCount += 1 } }
    func fixturePrepareResume(count: Int) -> CostPauseGeneration {
        costPaused = true; costPauseCount = count; queuePaused = false
        _ = beginCostResume(); return pauseGeneration
    }
    func fixtureNotePausedMember(_ side: String) {
        _ = notePausedMember(side,publication:SidePausePublication(side:pauseGeneration,root:pauseGeneration))
    }
    func fixtureForgetPausedMember(_ side: String) { forgetPausedMember(side,generation:pauseGeneration,destination:pauseGeneration) }
    func fixtureAcknowledgeSidePause(_ side: String) { acknowledgeSidePause(side,generation:SidePausePublication(side:pauseGeneration,root:pauseGeneration)) }
    func fixturePublishSidePause(repair: Bool = false) async -> Bool {
        guard let publication = sidePausePublication() else { return false }
        return await publishSidePause(publication,repair:repair)
    }
}
private extension AgentSteeringCoordinator {
    func fixtureResume(owner: AgentSession, count: Int) async throws {
        let generation = await owner.fixturePrepareResume(count:count)
        try await resumeParked(owner:owner,generation:generation)
        try await owner.commitCostResume(generation,active:false)
        activateResume(owner:owner,generation:generation)
    }
}

extension FamilyLimitPauseTests {
    func testStaleInheritedSidePauseIsIgnoredAfterRootResume() async throws {
        for intermediate in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try familyFixture(root:root)
            let middle = try await side("middle",parent:owner,root:root)
            let leaf = try await side("leaf",parent:intermediate ? middle : owner,root:root)
            let issuer = intermediate ? middle : owner
            let publication = SidePausePublication(side:issuer.pauseGeneration,root:owner.pauseGeneration)
            await owner.fixtureCostPause(); _ = try await owner.continueRun(commandID:"resume")
            // Work accepted after Resume must not inherit an earlier callback.
            await leaf.fixtureQueue(Submission(commandID:"new",turnID:"new",text:"New work"))
            for _ in 0..<2 { await leaf.receiveSidePause(AgentSession.costHoldError,generation:publication) }
            let snapshot = await leaf.snapshot()
            XCTAssertNotEqual(snapshot["costPaused"].flag,true)
            XCTAssertEqual(snapshot["queuePaused"].flag,false)
            await leaf.close(); await middle.close(); await owner.close()
        }
    }

    func testDuplicateMembershipNoteIsIdempotentAndAnOldNoteCannotRejoin() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root)
        try await side.fixtureSavedPauseMembers([])
        let publication = try XCTUnwrap(awaitValue:await side.sidePausePublication())
        for _ in 0..<2 { let accepted = await owner.notePausedMember("side",publication:publication); XCTAssertTrue(accepted) }
        let reply = try await owner.continueRun(commandID:"root")
        XCTAssertEqual(reply["pausedMembers"].list,["side"])
        _ = try await side.continueRun(commandID:"side")
        try await eventually { await owner.costPausedMembers.isEmpty }
        for _ in 0..<2 { let accepted = await owner.notePausedMember("side",publication:publication); XCTAssertFalse(accepted) }
        let snapshot = await owner.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true); XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
        await side.close(); await owner.close()
    }

    func testStaleMembershipForgetCannotEraseTheNextPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root)
        try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause(repair:true)
        _ = try await owner.continueRun(commandID:"root-1")
        _ = try await side.continueRun(commandID:"side-1")
        try await eventually { await owner.costPausedMembers.isEmpty }
        let oldSide = side.pauseGeneration, oldRoot = owner.pauseGeneration
        try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause(repair:true)
        for _ in 0..<2 { await owner.forgetPausedMember("side",generation:oldSide,destination:oldRoot) }
        let snapshot = await owner.snapshot(); XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"])
        let reply = try await owner.continueRun(commandID:"root-2"); XCTAssertEqual(reply["pausedMembers"].list,["side"])
        _ = try await side.continueRun(commandID:"side-2")
        try await eventually { await owner.costPausedMembers.isEmpty }
        for _ in 0..<2 { await owner.forgetPausedMember("side",generation:side.pauseGeneration,destination:owner.pauseGeneration) }
        let done = await owner.snapshot(); XCTAssertNotEqual(done["costPaused"].flag,true)
        await side.close(); await owner.close()
    }

    func testStaleSideAcknowledgmentCannotEraseTheNextDurableFanOut() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root)
        _ = try await side.keep(whenFinished:false)
        await side.fixtureQueue(Submission(commandID:"work",turnID:"work",text:"Pending work")); try await side.fixtureSavePauseState()
        await owner.fixtureCostPause(); try await owner.fixturePauseLists(members:[],pending:["side"])
        let old = SidePausePublication(side:owner.pauseGeneration,root:owner.pauseGeneration)
        _ = try await owner.continueRun(commandID:"first")
        await owner.fixtureCostPause(); try await owner.fixturePauseLists(members:[],pending:["side"])
        for _ in 0..<2 { await owner.acknowledgeSidePause("side",generation:old) }
        let path = await owner.path; await side.close(); await owner.close()
        let reopened = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path)
        let snapshot = await reopened.snapshot(); XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"])
        let reply = try await reopened.continueRun(commandID:"second"); XCTAssertEqual(reply["pausedMembers"].list,["side"])
        await reopened.close()
    }

    private func checkStaleChildMessage(_ message: String) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), runtimes = GenerationChildRuntime()
        let coordinator = AgentSteeringCoordinator(open:{ try await runtimes.open($0,$1) },settled:{ _ in })
        let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
        let id = try await startChild(owner,coordinator,"held")
        try await eventually { await client.children.count == 1 }
        let oldJob = try XCTUnwrap(awaitValue:await coordinator.jobs.values.first)
        await owner.fixtureCostPause(); let old = owner.pauseGeneration
        await coordinator.pause(owner:owner,generation:old)
        try await eventually { await coordinator.jobs.isEmpty }
        let parked = try XCTUnwrap(awaitValue:await owner.agentState().latest(id))
        await owner.beginResumeFixture(); try await coordinator.fixtureResume(owner:owner,count:old.pauses)
        try await eventually { await client.children.count == 2 }
        let child = try XCTUnwrap(awaitValue:await runtimes.child), current = owner.pauseGeneration
        let before = await owner.snapshot()
        for _ in 0..<2 {
            switch message {
            case "pause", "halt": await coordinator.pause(owner:owner,generation:old,halt:message == "halt")
            case "child-pause", "child-halt": await child.receiveChildPause(generation:old,halt:message == "child-halt")
            case "park": await coordinator.park(oldJob,child:child,generation:old)
            case "owner-park": try await owner.parkOwnedTurn(parked,generation:old)
            case "child-park": try await child.parkAgentTurn(parked,generation:old)
            case "publication": await coordinator.publishParked(oldJob,generation:old)
            case "install":
                try await coordinator.resumeParked(owner:owner,generation:old)
                try await coordinator.resumeParked(owner:owner,generation:current)
                await coordinator.activateResume(owner:owner,generation:current)
            case "child-install":
                do { try await child.resumeAgentTurn(parked,owner:owner,coordinator:coordinator,generation:old); XCTFail("Stale install was admitted") }
                catch { XCTAssertTrue(error is CancellationError) }
                let installed = try XCTUnwrap(awaitValue:await owner.agentState().latest(id))
                try await child.resumeAgentTurn(installed,owner:owner,coordinator:coordinator,generation:current)
            default: XCTFail("Unknown message")
            }
        }
        let snapshot = await child.snapshot(), listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertEqual(snapshot["queuePaused"].flag,false,message); XCTAssertNotEqual(snapshot["costPaused"].flag,true,message)
        XCTAssertEqual(listed.first?["status"].text,"running",message)
        let turn = await owner.agentState().latest(id); XCTAssertEqual(turn?.continuations?.count,1,message)
        let requests = await client.children.count; XCTAssertEqual(requests,2,message)
        if message == "publication" { let after = await owner.snapshot(); XCTAssertEqual(before["subagentsRevision"],after["subagentsRevision"]) }
        if message == "install" || message == "child-install" {
            await owner.fixtureCostPause(); let next = owner.pauseGeneration
            await coordinator.pause(owner:owner,generation:next)
            try await eventually { await coordinator.jobs.isEmpty }
            for _ in 0..<2 {
                await coordinator.activateResume(owner:owner,generation:current)
                if message == "child-install", let turn {
                    do { try await child.resumeAgentTurn(turn,owner:owner,coordinator:coordinator,generation:current); XCTFail("An old install cleared a newer pause") }
                    catch { XCTAssertTrue(error is CancellationError) }
                }
            }
            let held = await child.snapshot(); XCTAssertEqual(held["costPaused"].flag,true)
            let members = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
            XCTAssertEqual(members.first?["costPaused"].flag,true)
        }
        await client.releaseAll(); await coordinator.activateResume(owner:owner,generation:owner.pauseGeneration)
        await coordinator.drain(); await runtimes.close(); await owner.close()
    }
    func testStaleCoordinatorPauseAfterResume() async throws { try await checkStaleChildMessage("pause") }
    func testStaleCoordinatorHaltAfterResume() async throws { try await checkStaleChildMessage("halt") }
    func testStaleChildPauseAfterResume() async throws { try await checkStaleChildMessage("child-pause") }
    func testStaleChildHaltAfterResume() async throws { try await checkStaleChildMessage("child-halt") }
    func testStaleParkJobAfterResume() async throws { try await checkStaleChildMessage("park") }
    func testStaleOwnerParkRecordAfterResume() async throws { try await checkStaleChildMessage("owner-park") }
    func testStaleChildParkMirrorAfterResume() async throws { try await checkStaleChildMessage("child-park") }
    func testStaleParkedPublicationAfterResume() async throws { try await checkStaleChildMessage("publication") }
    func testStaleAndDuplicateResumeInstallAndActivation() async throws { try await checkStaleChildMessage("install") }
    func testStaleAndDuplicateChildResumeInstall() async throws { try await checkStaleChildMessage("child-install") }
}

private actor GenerationChildRuntime {
    var child: AgentSession?
    func open(_ env: SubagentEnvironment, _ plan: SubagentPlan) throws -> AgentSession {
        if let child { return child }
        let opened = try AgentSteeringCoordinator.makeChild(env,plan); child = opened; return opened
    }
    func close() async { await child?.close() }
}

private actor ResumeInstallSteps {
    var count = 0
    let gate: OpenGate
    init(_ gate: OpenGate) { self.gate = gate }
    func waitBeforeSecond() async { count += 1; if count == 2 { await gate.wait() } }
}
private extension AgentSteeringCoordinator {
    func fixtureHoldResumePhase(_ gate: OpenGate?, phase: String) {
        beforeResumeInstall = nil; afterResumeInstall = nil
        guard let gate else { return }
        if phase == "after-install" { afterResumeInstall = { await gate.wait() } }
        else if phase == "before-second" { let steps = ResumeInstallSteps(gate); beforeResumeInstall = { await steps.waitBeforeSecond() } }
        else { beforeResumeInstall = { await gate.wait() } }
    }
}

extension FamilyLimitPauseTests {
    func testRootResumeIncludesAnAppliedSideBeforeItsPublication() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate = OpenGate(), owner = try familyFixture(root:root)
        let side = try await side("side",parent:owner,root:root,client:ScriptClient([answer("Done")]))
        _ = try await side.keep(whenFinished:false)
        await side.fixtureQueue(Submission(commandID:"pending",turnID:"pending",text:"Work"))
        await side.fixtureHoldPausePublication(gate)
        await owner.fixtureCostPause(); try await owner.fixturePauseLists(members:[],pending:["side"])
        let publication = SidePausePublication(side:owner.pauseGeneration,root:owner.pauseGeneration)
        await side.receiveSidePause(AgentSession.costHoldError,generation:publication)
        try await eventually { await gate.waiting }
        let reply = try await owner.continueRun(commandID:"root")
        XCTAssertEqual(reply["pausedMembers"].list,["side"],"Applied fan-out is covered even before its publication arrives")
        await gate.open(); await side.fixtureHoldPausePublication(nil)
        _ = try await side.continueRun(commandID:"side")
        try await eventually { !(await side.isRunning) && owner.costPauseClock.isPaused == false }
        try await eventually { await owner.costPausedMembers.isEmpty }
        let snapshot = await owner.snapshot(); XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        await side.close(); await owner.close()
    }

    func testPublicationIssuedDuringPrepareCannotOutliveTheCommit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root)
        try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause(repair:true)
        _ = try await owner.continueRun(commandID:"root")
        let resume = await side.fixturePrepareResume(count:side.pauseGeneration.pauses)
        let publication = try XCTUnwrap(awaitValue:await side.sidePausePublication())
        try await side.commitCostResume(resume,active:false)
        await owner.forgetPausedMember("side",generation:side.pauseGeneration,destination:owner.pauseGeneration)
        for _ in 0..<2 {
            let accepted = await owner.notePausedMember("side",publication:publication)
            XCTAssertFalse(accepted,"Prepare and commit share a Resume count; publications also require the issuing pause state")
        }
        let snapshot = await owner.snapshot(); XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
        await side.close(); await owner.close()
    }
}

extension FamilyLimitPauseTests {
    func testClosingSideRetiresMembershipAcrossANewerRootPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate()
        try await side.fixtureSavedPauseMembers([]); try await owner.fixtureSavedPauseMembers(["side"])
        await side.fixtureHoldPauseRetirement(gate)
        let closing = Task { await side.close() }
        try await eventually { await gate.waiting }
        _ = try await owner.continueRun(commandID:"root")
        await owner.fixtureCostPause()
        await gate.open(); await closing.value
        let snapshot = await owner.snapshot()
        XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty,"A closed unkept side has no work left for any Resume")
        XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        await owner.fixtureCostPause(); try await owner.fixtureRememberSidePauses()
        let next = try await owner.continueRun(commandID:"next")
        XCTAssertTrue(next["pausedMembers"].list.isEmpty,"Closed callbacks cannot create a later Resume obligation")
        await owner.close()
    }
}
private extension AgentSession {
    func fixtureHoldPauseRetirement(_ gate: OpenGate) { beforeSidePauseRetirement = { await gate.wait() } }
}

private extension AgentSession {
    func fixtureRememberSidePauses() throws { rememberSidePauses(); try persistState(durable:true) }
}
extension FamilyLimitPauseTests {
    func testStaleClosedSideRetirementCannotEraseAReplacement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), oldSide = try await side("side",parent:owner,root:root)
        try await oldSide.fixtureSavedPauseMembers([]); try await owner.fixtureSavedPauseMembers(["side"])
        await oldSide.close(); let old = oldSide.pauseGeneration
        let replacement = try await side("side",parent:owner,root:root)
        try await replacement.fixtureSavedPauseMembers([]); _ = await replacement.fixturePublishSidePause(repair:true)
        let reply = try await owner.continueRun(commandID:"resume"); XCTAssertEqual(reply["pausedMembers"].list,["side"])
        for _ in 0..<2 { await owner.forgetClosedSide("side",generation:old) }
        let snapshot = await owner.snapshot(); XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"])
        _ = try await replacement.continueRun(commandID:"resume-side")
        try await eventually { await owner.costPausedMembers.isEmpty }
        await replacement.close(); await owner.close()
    }
}

extension FamilyLimitPauseTests {
    func testStaleHoldReleaseCannotOverrideALaterResumeGeneration() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = LimitRunClient(mode:"queued"), coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
        let first = await owner.fixturePrepareResume(count:1); try await owner.commitCostResume(first,active:false)
        await coordinator.activateResume(owner:owner,generation:first)
        let old = owner.pauseGeneration
        let second = await owner.fixturePrepareResume(count:2); try await owner.commitCostResume(second,active:false)
        // Finish the accepted activation before simulating the startup hold
        // that only a current runtime's reconciliation may release.
        await coordinator.activateResume(owner:owner,generation:owner.pauseGeneration)
        await coordinator.fixtureOrphanedHold("parent")
        for _ in 0..<2 { await coordinator.releaseStaleHold(owner:owner,generation:old) }
        let held = await coordinator.paused.contains("parent"); XCTAssertTrue(held)
        let id = try await startChild(owner,coordinator,"held")
        let listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertEqual(listed.first?["status"].text,"queued")
        await client.releaseAll(); await coordinator.activateResume(owner:owner,generation:owner.pauseGeneration)
        try await eventually { await owner.agentState().latest(id)?.status.terminal == true }
        await owner.close()
    }

    func testDuplicateParkMirrorCannotRestoreATerminalChildPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let runtimes = GenerationChildRuntime()
        let coordinator = AgentSteeringCoordinator(open:{ try await runtimes.open($0,$1) },settled:{ _ in },retire:{ _,_,turn in
            if let child = await runtimes.child { try await child.saveAgentTerminal(turn) }
        })
        let owner = try await steeringOwner(root,client:ScriptClient([]),coordinator:coordinator)
        await coordinator.fixturePause(owner)
        let id = try await startChild(owner,coordinator,"held")
        try await eventually { await coordinator.jobs.isEmpty }
        let parked = try XCTUnwrap(awaitValue:await owner.agentState().latest(id)), generation = owner.pauseGeneration
        let child = try XCTUnwrap(awaitValue:await runtimes.child)
        try await coordinator.stop(parent:owner,target:parked.target,human:true)
        for _ in 0..<2 { try await child.parkAgentTurn(parked,generation:generation) }
        let snapshot = await child.snapshot(); XCTAssertNotEqual(snapshot["costPaused"].flag,true)
        let listed = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertEqual(listed.first?["status"].text,"not_executed"); XCTAssertNotEqual(listed.first?["costPaused"].flag,true)
        await runtimes.close(); await owner.close()
    }
}

extension FamilyLimitPauseTests {
    func testIntermediateCloseRetirementTakesTheRootFenceBeforeWriting() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), middle = try await side("middle",parent:owner,root:root)
        _ = try await middle.keep(whenFinished:false)
        let leaf = try await side("leaf",parent:middle,root:root)
        try await middle.fixtureSavedPauseMembers(["leaf"])
        let probe = CloseFenceProbe(), gate = ColdTerminalMirrorGate()
        try await middle.fixtureObserveCloseWrites(probe)
        let generation = await leaf.fixtureClosingGeneration()
        let held = Task.detached {
            owner.costPauseClock.synchronized { probe.mark("held"); gate.wait() }
        }
        try await eventually { probe.saw("held") }
        let retirement = Task { await middle.fixtureRetireClosedSide("leaf",generation:generation,probe:probe) }
        try await eventually { probe.saw("entered") }
        try await Task.sleep(for:.milliseconds(50))
        let reading = Task.detached { _ = middle.pauseGeneration; probe.mark("read-middle") }
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertTrue(probe.saw("read-middle"),"Waiting for the root must leave the intermediate clock available")
        XCTAssertFalse(probe.saw("written"),"An intermediate must not hold its own/leaf fences and then wait for the root")
        gate.open(); await held.value; await retirement.value; await reading.value
        let snapshot = await middle.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true); XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
        await leaf.close(); await middle.close(); await owner.close()
    }
}
private final class CloseFenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events = Set<String>()
    func mark(_ event: String) { lock.lock(); events.insert(event); lock.unlock() }
    func saw(_ event: String) -> Bool { lock.lock(); defer { lock.unlock() }; return events.contains(event) }
}
private extension AgentSession {
    func fixtureObserveCloseWrites(_ probe: CloseFenceProbe) throws {
        let url = try XCTUnwrap(journal?.url); try journal?.synchronize(); journal = nil
        journal = try SessionJournal(url:url,id:id,cwd:cwd,binding:nil,create:false,beforeAppend:{ row in
            if row["customType"].text == JournalRecordKind.state { probe.mark("written") }
        })
    }
    func fixtureClosingGeneration() -> CostPauseGeneration { costResumeCount += 1; costPauseClock.beginClosing(); return pauseGeneration }
    func fixtureRetireClosedSide(_ side: String, generation: CostPauseGeneration, probe: CloseFenceProbe) {
        probe.mark("entered"); forgetClosedSide(side,generation:generation)
    }
}

extension FamilyLimitPauseTests {
    private func checkNewPauseDuringInstall(_ trigger: String) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AccountedAgentScript(Array(repeating:answer("Finished"),count:6)), gate = OpenGate()
        let coordinator = AgentSteeringCoordinator()
        let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
        let side = try await side("charger",parent:owner,root:root)
        await owner.setCostLimit(trigger == "limit" ? 0.5 : 5)
        let crossing = trigger == "limit" ? try await start(side,"late-charge") : nil
        await coordinator.fixturePause(owner)
        for name in ["one","two"] {
            _ = try await startChild(owner,coordinator,name,newTask:name == "one")
            try await owner.fixtureAcceptedReceipt(name)
        }
        try await eventually { await coordinator.jobs.isEmpty }
        await owner.fixtureCostPause(); await coordinator.fixtureHoldResumePhase(gate,phase:"before-first")
        _ = try await owner.continueRun(commandID:"resume")
        try await eventually { await gate.waiting }
        if let crossing { try await finish(crossing.0,"late-charge",cost:0.6) }
        else { try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause() }
        await gate.open()
        try await eventually { !(await owner.costResumePending) }
        let snapshot = await owner.snapshot(), requests = await client.requests.count
        XCTAssertEqual(snapshot["costPaused"].flag,true,trigger)
        XCTAssertEqual(snapshot["queuePaused"].flag,true,"A fresh pause during prepare supersedes that Resume: \(trigger)")
        XCTAssertEqual(requests,0,"No child of the superseded Resume starts: \(trigger)")
        let children = await coordinator.list(parent:owner,cursor:0,limit:10)["children"].list
        XCTAssertTrue(children.allSatisfy { $0["costPaused"].flag == true },trigger)
        // A broken fence can strand allocated jobs before their child opens.
        // Retire the fixture after the observable assertions, without hanging
        // the failing-first/mutation process on that intentional broken state.
        if !(await owner.costPaused) {
            await owner.fixtureCostPause()
            for id in await coordinator.jobs.keys { await coordinator.fixturePark(id) }
        }
        await coordinator.fixtureHoldResumePhase(nil,phase:"before-first")
        await side.close(); await owner.close()
    }
    func testNewLimitDuringResumeInstallKeepsItsPause() async throws { try await checkNewPauseDuringInstall("limit") }
    func testNewMemberDuringResumeInstallKeepsItsPause() async throws { try await checkNewPauseDuringInstall("member") }
}


extension FamilyLimitPauseTests {
    func testResumeInstallCannotRestampAnAcceptanceSupersededBeforeTheRunStarts() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root)
        await owner.fixtureQueue(Submission(commandID:"pending",turnID:"pending",text:"Held work"))
        _ = await owner.fixturePrepareResume(count:1)
        await owner.stopFamilyAtLimit(AgentSession.costHoldError)
        do { try await owner.installCostResume(); XCTFail("Install must use the generation captured at acceptance") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["costPaused"].flag,true); XCTAssertEqual(snapshot["queuePaused"].flag,true)
        await owner.abortCostResume(); await owner.close()
    }

    func testFailedResumeCannotPublishAGenerationReusedByTheNextAcceptance() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let fault = ResumeAcceptanceFault(), probe = CloseFenceProbe()
        defer { fault.gate.open() }
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([answer("Finished")]),tools:DisabledTools(),traces:TraceStore(),
            beforeJournalAppend:{ try fault.append($0) })
        let side = try await side("side",parent:owner,root:root)
        try await owner.append(ChatMessage(role:"user",content:[textBlock("Resume this")]))
        try await side.fixtureSavedPauseMembers([])
        await owner.fixtureCostPause(); try await owner.fixturePauseLists(members:[],pending:["side"])
        fault.arm()
        let rejected = Task { try await owner.continueRun(commandID:"rejected") }
        try await eventually { fault.probe.saw("writing") }
        let capturing = Task { await side.fixturePublicationObserved(probe) }
        try await eventually { probe.saw("capturing") }
        try await Task.sleep(for:.milliseconds(50))
        fault.gate.open()
        do { _ = try await rejected.value; XCTFail("The acceptance write must fail") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"fixture_resume_write") }
        let publication = try XCTUnwrap(awaitValue:await capturing.value)
        let reply = try await owner.continueRun(commandID:"accepted")
        XCTAssertEqual(reply["pausedMembers"].list,["side"])
        try await eventually { !(await owner.isRunning) }
        for _ in 0..<2 { _ = await owner.notePausedMember("side",publication:publication) }
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["queuePaused"].flag,false,"A failed acceptance cannot issue a publication valid after the next Resume")
        XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"])
        _ = try await side.continueRun(commandID:"side")
        try await eventually { await owner.costPausedMembers.isEmpty }
        let completed = await owner.snapshot(); XCTAssertNotEqual(completed["costPaused"].flag,true)
        await side.close(); await owner.close()
    }

    func testFinalReplyKeepsThePauseUntilSideFanoutIsAcknowledged() async throws {
        for activeSide in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = AnsweringChildClient(), coordinator = AgentSteeringCoordinator(), gate = OpenGate(), probe = CloseFenceProbe()
            let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
            let side = try await side("side",parent:owner,root:root)
            if activeSide { await side.fixtureQueue(Submission(commandID:"side-work",turnID:"side-work",text:"Held side work")) }
            await owner.fixtureDelaySidePauses(gate,finished:probe)
            await owner.setCostLimit(0.0005)
            _ = try await owner.submit(Submission(commandID:"answer",turnID:"answer",text:"Answer"),steer:false)
            try await eventually { await client.waiting }; await client.release()
            try await eventually { let waiting = await gate.waiting, running = await owner.isRunning; return waiting && !running }
            let awaitingFanout = await owner.snapshot()
            XCTAssertEqual(awaitingFanout["costPaused"].flag,true,"A final reply cannot retire an unacknowledged side pause")
            await gate.open(); try await eventually { probe.saw("side") }
            let sideSnapshot = await side.snapshot(), parentSnapshot = await owner.snapshot()
            XCTAssertEqual(sideSnapshot["costPaused"].flag == true,activeSide)
            XCTAssertEqual(parentSnapshot["costPaused"].flag == true,activeSide)
            if activeSide {
                await owner.setCostLimit(5)
                let reply = try await owner.continueRun(commandID:"resume")
                XCTAssertEqual(reply["pausedMembers"].list,["side"])
            }
            await side.close(); await owner.close()
        }
    }
}

private final class ResumeAcceptanceFault: @unchecked Sendable {
    let gate = ColdTerminalMirrorGate(), probe = CloseFenceProbe()
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func append(_ row: JSON) throws {
        lock.lock()
        let fail = armed && row["customType"].text == JournalRecordKind.state
        if fail { armed = false }
        lock.unlock()
        if fail { probe.mark("writing"); gate.wait(); throw AgentError("fixture_resume_write","Injected acceptance write failure") }
    }
}
private extension AgentSession {
    func fixturePublicationObserved(_ probe: CloseFenceProbe) -> SidePausePublication? {
        probe.mark("capturing"); return sidePausePublication()
    }
}


extension FamilyLimitPauseTests {
    func testRecoveryRetiresFanoutWhoseOnlyRecipientAlreadyFinished() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root)
        _ = try await side.keep(whenFinished:false)
        try await owner.fixtureSavedPauseMembers([]); try await owner.fixturePauseLists(members:[],pending:["side"])
        let path = await owner.path
        // The side's completed state is durable, but the root has not saved
        // its fan-out acknowledgment when both runtimes disappear.
        try await side.fixtureCrashPauseRuntime(); try await owner.fixtureCrashPauseRuntime()
        let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path)
        let snapshot = await restored.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true,"Recovery must not retain a family pause after its final idle recipient completed")
        XCTAssertEqual(snapshot["state"].text,"idle")
        await restored.close()
    }

    func testQueuedRetirementReissuesItsIntentAfterAnotherRootPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), retirement = OpenGate()
        _ = try await side.keep(whenFinished:false)
        try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause(repair:true)
        _ = try await owner.continueRun(commandID:"root")
        await side.fixtureHoldPauseForget(retirement)
        _ = try await side.continueRun(commandID:"side")
        try await eventually { await retirement.waiting }
        // Another pause starts while this now-idle side's retirement is
        // queued. Its current lack of work acknowledges that newer fan-out.
        await owner.fixtureCostPause(); try await owner.fixtureRememberSidePauses()
        let fanout = try XCTUnwrap(awaitValue:await owner.pendingSidePause("side"))
        let publication = await side.receiveSidePause(AgentSession.costHoldError,generation:fanout)
        let confirmed = await side.publishSidePause(publication,repair:true); XCTAssertTrue(confirmed)
        if confirmed { await owner.acknowledgeSidePause("side",generation:fanout) }
        await retirement.open()
        do { try await eventually(timeout:.seconds(2)) { await owner.snapshot()["costPaused"].flag != true } }
        catch { XCTFail("The legitimate retirement must be reissued under the root's new generation") }
        let snapshot = await owner.snapshot()
        XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty,"An idle side must not remain in the app's Resume members")
        await side.close(); await owner.close()
    }

    func testFanoutAcknowledgesSideCompletionDuringMembershipDelivery() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root)
        let receipt = OpenGate(), retirement = OpenGate()
        try await owner.fixtureSavedPauseMembers([]); try await owner.fixturePauseLists(members:[],pending:["side"])
        let fanout = SidePausePublication(side:owner.pauseGeneration,root:owner.pauseGeneration)
        try await side.fixtureSavedPauseMembers([])
        await side.fixtureHoldPauseAcknowledgment(receipt)
        let publication = Task { await side.fixturePublishSidePause(repair:true) }
        try await eventually { await receipt.waiting }
        await side.fixtureHoldPauseForget(retirement)
        _ = try await side.continueRun(commandID:"completed-side")
        try await eventually { await retirement.waiting }
        await receipt.open()
        let confirmed = await publication.value
        XCTAssertTrue(confirmed,"A recipient completing during the root await must acknowledge the still-current fan-out")
        if confirmed { await owner.acknowledgeSidePause("side",generation:fanout) }
        await retirement.open()
        try await eventually { await owner.costPausedMembers.isEmpty }
        let snapshot = await owner.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true,"A completed side must leave no family Resume in the app")
        await side.close(); await owner.close()
    }

    func testDuplicateMembershipDeliveryAcknowledgesTheSameFanout() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), receipt = OpenGate()
        try await owner.fixtureSavedPauseMembers([]); try await owner.fixturePauseLists(members:[],pending:["side"])
        let fanout = SidePausePublication(side:owner.pauseGeneration,root:owner.pauseGeneration)
        try await side.fixtureSavedPauseMembers([])
        await side.fixtureHoldPauseAcknowledgment(receipt)
        let first = Task { await side.fixturePublishSidePause(repair:true) }
        try await eventually { await receipt.waiting }
        await side.fixtureHoldPauseAcknowledgment(nil)
        let second = await side.fixturePublishSidePause(repair:true); XCTAssertTrue(second)
        await receipt.open()
        let confirmed = await first.value; XCTAssertTrue(confirmed,"The same durably acknowledged source intent is idempotent")
        if confirmed { await owner.acknowledgeSidePause("side",generation:fanout) }
        _ = try await side.continueRun(commandID:"side")
        try await eventually { await owner.costPausedMembers.isEmpty }
        let snapshot = await owner.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true,"Duplicate publication must not leave the app waiting on a lost fan-out acknowledgment")
        await side.close(); await owner.close()
    }

    func testAutomaticRetirementIncludesAnAlreadyAcknowledgedSidesNewPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AnsweringChildClient(), coordinator = AgentSteeringCoordinator(), settling = OpenGate(), publication = OpenGate()
        let owner = try await steeringOwner(root,client:client,coordinator:coordinator)
        let side = try await side("side",parent:owner,root:root,client:ScriptClient([answer("Done")]))
        _ = try await side.keep(whenFinished:false)
        await owner.fixtureFinalLinks { await settling.wait() }
        await owner.setCostLimit(0.0005)
        _ = try await owner.submit(Submission(commandID:"answer",turnID:"answer",text:"Answer"),steer:false)
        try await eventually { await client.waiting }; await client.release()
        try await eventually { await settling.waiting }
        try await eventually { await owner.costPendingSidePauses.isEmpty }
        await owner.setCostLimit(5)
        await side.fixtureHoldPausePublication(publication)
        _ = try await side.submit(Submission(commandID:"late",turnID:"late",text:"New side work"),steer:false)
        try await eventually { await publication.waiting }
        try await eventually { !(await side.isRunning) }
        await settling.open(); try await eventually { !(await owner.isRunning) }
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["costPaused"].flag,true,"Cleanup must retain an applied side pause even after its earlier fan-out acknowledgment")
        var reply: JSON = .null
        do { reply = try await owner.continueRun(commandID:"root-resume") }
        catch { XCTFail("The family must still have a Resume: \(error)") }
        XCTAssertEqual(reply["pausedMembers"].list,["side"],"The app must be told to Resume the unpublished side")
        await publication.open(); await side.fixtureHoldPausePublication(nil)
        _ = try await side.continueRun(commandID:"side-resume")
        try await eventually { !(await side.isRunning) }
        await side.close(); await owner.close()
    }

    func testKeptSideUnloadDrainsItsResumeRetirement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate()
        _ = try await side.keep(whenFinished:false)
        try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause(repair:true)
        let reply = try await owner.continueRun(commandID:"root")
        XCTAssertEqual(reply["pausedMembers"].list,["side"])
        await side.fixtureHoldPauseForget(gate)
        _ = try await side.continueRun(commandID:"side")
        try await eventually { await gate.waiting }
        let unloaded = await side.unloadIfIdle(); XCTAssertTrue(unloaded)
        await gate.open()
        do { try await eventually(timeout:.seconds(2)) { await owner.snapshot()["costPaused"].flag != true } }
        catch { XCTFail("Unload must not strand the app's family pause after the side's Resume completed") }
        let snapshot = await owner.snapshot()
        XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty,"The root must durably acknowledge retirement before the side clock retires")
        await owner.close()
    }
}
private extension AgentSession {
    func fixtureHoldPauseForget(_ gate: OpenGate) { beforeSidePauseForget = { await gate.wait() } }
    func fixtureHoldPauseAcknowledgment(_ gate: OpenGate?) {
        if let gate { beforeSidePauseAcknowledgment = { await gate.wait() } } else { beforeSidePauseAcknowledgment = nil }
    }
}

extension FamilyLimitPauseTests {
    func testKeptSideCloseAppliesOutstandingFanoutBeforeRetiringItsClock() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate()
        _ = try await side.keep(whenFinished:false)
        await side.fixtureQueue(Submission(commandID:"pending",turnID:"pending",text:"Held work"))
        try await side.fixtureSavePauseState()
        await owner.fixtureDelaySidePauses(gate)
        await owner.fixtureCostPause(); try await owner.fixtureRememberSidePauses()
        await owner.notifySidesOfPause(AgentSession.costHoldError)
        try await eventually { await gate.waiting }
        await side.close()
        let reply = try await owner.continueRun(commandID:"root")
        XCTAssertEqual(reply["pausedMembers"].list,["side"],"Close must hand over unapplied fan-out before retiring a kept side")
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,["side"])
        await gate.open(); await owner.close()
    }

    func testIdleSideUnloadAcknowledgesOutstandingFanout() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate()
        _ = try await side.keep(whenFinished:false)
        await owner.fixtureDelaySidePauses(gate)
        await owner.fixtureCostPause(); try await owner.fixtureRememberSidePauses()
        await owner.notifySidesOfPause(AgentSession.costHoldError)
        try await eventually { await gate.waiting }
        let unloaded = await side.unloadIfIdle(); XCTAssertTrue(unloaded)
        let snapshot = await owner.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true,"An idle recipient must not leave an unacknowledgeable fan-out holding the root")
        await gate.open(); await owner.close()
    }

    func testMembershipIntentRepairsEachPartialWriteAfterBothRuntimesRestart() async throws {
        for paused in [false,true] { for cut in 0..<2 {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate(), fault = SealWriteFault()
            _ = try await side.keep(whenFinished:false)
            try await side.fixtureSavedPauseMembers([])
            try await owner.fixtureSavedPauseMembers(paused ? [] : ["side"])
            if paused { try await side.fixtureStageMembership() }
            else {
                _ = try await owner.continueRun(commandID:"root")
                await side.fixtureHoldPauseForget(gate)
                _ = try await side.continueRun(commandID:"side")
                try await eventually { await gate.waiting }
            }
            let intent = try XCTUnwrap(awaitValue:await side.costPendingMembership)
            let publication = try XCTUnwrap(awaitValue:await side.sidePausePublication())
            let ownerPath = await owner.path, sidePath = try XCTUnwrap(awaitValue:await side.path)
            try await owner.fixtureSealWriter(fault); try await side.fixtureSealWriter(fault)
            fault.arm(after:cut)
            let delivered = await side.deliverSidePauseIntent(intent,publication:publication,repair:true)
            XCTAssertFalse(delivered)
            XCTAssertEqual(fault.disarm(),cut); XCTAssertTrue(fault.failed)
            try await side.fixtureSavePauseState() // An unrelated later save cannot discard the failed intent.
            let saved = try SideBudgetRecovery.pauseState(URL(fileURLWithPath:sidePath),id:"side").state
            XCTAssertEqual(saved["costPendingMembership"],intent.saved,"The source keeps its intent until both records are durable")
            try await side.fixtureCrashPauseRuntime(); try await owner.fixtureCrashPauseRuntime()
            await gate.open()
            let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:ownerPath)
            let snapshot = await restored.snapshot()
            XCTAssertEqual(snapshot["costPaused"].flag == true,paused,"Root recovery must reconcile unopened senders, cut=\(cut)")
            XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,paused ? ["side"] : [])
            if paused {
                let reply = try await restored.continueRun(commandID:"recovered-root")
                XCTAssertEqual(reply["pausedMembers"].list,["side"])
            }
            let reopened = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:sidePath)
            let restoredIntent = await reopened.costPendingMembership
            XCTAssertEqual(restoredIntent,intent,"The final replay state retains the sender intent before binding reissues it")
            for _ in 0..<2 { try await reopened.bindSideBudget(to:restored) }
            let after = await restored.snapshot()
            XCTAssertEqual(after["queuePaused"].flag,false,"Replaying an acknowledged intent cannot undo the root's Resume")
            let retired = try SideBudgetRecovery.pauseState(URL(fileURLWithPath:sidePath),id:"side").state
            XCTAssertTrue(retired["costPendingMembership"].isNull)
            if paused { _ = try await reopened.continueRun(commandID:"recovered-side") }
            try await eventually { await restored.snapshot()["costPaused"].flag != true }
            await reopened.close(); await restored.close()
        } }
    }
}
private extension AgentSession {
    func fixtureStageMembership() throws { rememberSideMembership(paused:costPaused); try persistState(durable:true) }
    func fixtureCrashPauseRuntime() throws { try journal?.synchronize(); closed = true; costPauseClock.retire(); journal = nil }
}

extension FamilyLimitPauseTests {
    func testRecoveredTransferDoesNotResurrectAnAlreadyResumedDescendant() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), middle = try await side("middle",parent:owner,root:root)
        let leaf = try await side("leaf",parent:middle,root:root)
        _ = try await middle.keep(whenFinished:false); _ = try await leaf.keep(whenFinished:false)
        try await leaf.fixtureSavedPauseMembers([]); _ = await leaf.fixturePublishSidePause(repair:true)
        // The root saved the transfer but the source's acknowledgment save
        // failed. Its old copy must not recreate membership after leaf Resume.
        try await middle.fixturePauseLists(members:["leaf"],pending:[])
        _ = try await owner.continueRun(commandID:"root"); _ = try await leaf.continueRun(commandID:"leaf")
        try await eventually { await owner.snapshot()["costPaused"].flag != true }
        let path = await middle.path
        try await middle.fixtureCrashPauseRuntime()
        let reopened = try AgentSession(id:"middle",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path)
        try await reopened.bindSideBudget(to:owner)
        let snapshot = await owner.snapshot()
        XCTAssertNotEqual(snapshot["costPaused"].flag,true,"An old transfer copy cannot undo the completed family Resume")
        XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty)
        await leaf.close(); await reopened.close(); await owner.close()
    }

    func testColdRootFindsAnUnopenedIntermediatesTransferIntent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), middle = try await side("middle",parent:owner,root:root)
        let leaf = try await side("leaf",parent:middle,root:root)
        _ = try await middle.keep(whenFinished:false); _ = try await leaf.keep(whenFinished:false)
        await leaf.fixtureQueue(Submission(commandID:"pending",turnID:"pending",text:"Held work")); try await leaf.fixtureSavePauseState()
        // The intermediate's durable fan-out is the only pause record so far.
        try await middle.fixturePauseLists(members:[],pending:["leaf"])
        let path = await owner.path
        try await leaf.fixtureCrashPauseRuntime(); try await middle.fixtureCrashPauseRuntime(); try await owner.fixtureCrashPauseRuntime()
        let restored = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot["costPaused"].flag,true)
        var reply: JSON = .null
        do { reply = try await restored.continueRun(commandID:"root") }
        catch { XCTFail("The unopened intermediate must hand its durable intent to the root: \(error)") }
        XCTAssertEqual(reply["pausedMembers"].list,["leaf"])
        await restored.close()
    }
}

extension FamilyLimitPauseTests {
    func testMembershipAcknowledgmentSurvivesTheRootsAutomaticRetirement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate()
        _ = try await side.keep(whenFinished:false)
        try await owner.fixtureSavedPauseMembers([]); try await owner.fixturePauseLists(members:[],pending:["side"])
        let fanout = SidePausePublication(side:owner.pauseGeneration,root:owner.pauseGeneration)
        try await side.fixtureSavedPauseMembers([]); try await side.fixtureStageMembership()
        let publication = try XCTUnwrap(awaitValue:await side.sidePausePublication())
        let noted = await owner.notePausedMember("side",publication:publication,repair:true); XCTAssertTrue(noted)
        await side.fixtureHoldPauseForget(gate)
        _ = try await side.continueRun(commandID:"side")
        try await eventually { await gate.waiting }
        // Resume won after application, before the fan-out's publication.
        let confirmed = await side.publishSidePause(publication,repair:true)
        XCTAssertTrue(confirmed,"Confirm the completed recipient without publishing its old pause")
        if confirmed { await owner.acknowledgeSidePause("side",generation:fanout) }
        await gate.open()
        try await eventually(timeout:.seconds(2)) { await owner.snapshot()["costPaused"].flag != true }
        try await eventually(timeout:.seconds(2)) { await side.costPendingMembership == nil }
        let file = try XCTUnwrap(awaitValue:await side.path)
        XCTAssertTrue(try SideBudgetRecovery.pauseState(URL(fileURLWithPath:file),id:"side").state["costPendingMembership"].isNull)
        await side.close(); await owner.close()
    }

    func testFailedMembershipAcknowledgmentKeepsTheSenderUnloadRetryable() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let fault = PauseWriteFault(), gate = OpenGate()
        let owner = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),
            beforeJournalAppend:{ try fault.append($0,writer:"parent") })
        let side = try await side("side",parent:owner,root:root); _ = try await side.keep(whenFinished:false)
        try await side.fixtureSavedPauseMembers([]); _ = await side.fixturePublishSidePause(repair:true)
        _ = try await owner.continueRun(commandID:"root")
        await side.fixtureHoldPauseForget(gate); _ = try await side.continueRun(commandID:"side")
        try await eventually { await gate.waiting }
        fault.arm("parent",emptyMembers:true)
        let refused = await side.unloadIfIdle(); XCTAssertFalse(refused)
        let held = await owner.snapshot(); XCTAssertEqual(held["cost"]["pausedMembers"].list,["side"])
        XCTAssertTrue(side.costPauseClock.acceptsMessages,"A failed handover must leave its sender retryable")
        fault.disarm()
        let unloaded = await side.unloadIfIdle(); XCTAssertTrue(unloaded)
        let finished = await owner.snapshot(); XCTAssertNotEqual(finished["costPaused"].flag,true)
        await gate.open(); await owner.close()
    }

    func testKeptSideCloseDrainsBothMembershipDirections() async throws {
        for paused in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try familyFixture(root:root), side = try await side("side",parent:owner,root:root), gate = OpenGate()
            _ = try await side.keep(whenFinished:false)
            try await side.fixtureSavedPauseMembers([])
            let pending: Task<Bool,Never>?
            if paused {
                try await side.fixtureStageMembership(); await side.fixtureHoldPausePublication(gate)
                pending = Task { await side.fixturePublishSidePause() }
            } else {
                _ = await side.fixturePublishSidePause(repair:true); _ = try await owner.continueRun(commandID:"root")
                await side.fixtureHoldPauseForget(gate); _ = try await side.continueRun(commandID:"side"); pending = nil
            }
            try await eventually { await gate.waiting }
            await side.close()
            let snapshot = await owner.snapshot()
            XCTAssertEqual(snapshot["costPaused"].flag == true,paused)
            XCTAssertEqual(snapshot["cost"]["pausedMembers"].list,paused ? ["side"] : [])
            await gate.open(); _ = await pending?.value
            let afterLateTask = await owner.snapshot(); XCTAssertEqual(afterLateTask["costPaused"],snapshot["costPaused"])
            await owner.close()
        }
    }
}
