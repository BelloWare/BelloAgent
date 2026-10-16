import XCTest
@testable import PiAgentCore

final class FamilyLimitStopTests: XCTestCase {
    enum Phase: String, CaseIterable { case idle, ownRequest, childrenDispatched, queuedChildren, preLedgerRequest, tools }
    enum Crosser: String, CaseIterable { case own, backgroundChild, waitedChild, nestedSide, sideChild }

    func testEveryPhaseAndChargeSourceDrainsBeforeOneBudgetStop() async throws {
        for phase in Phase.allCases { for crosser in Crosser.allCases {
            if phase == .queuedChildren {
                try await assertQueuedChildrenFinalizeWhileOtherRequestsDrain(crosser)
                continue
            }
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
            if phase == .ownRequest { held = try await start(owner,"held") }
            if phase == .childrenDispatched { held = try await start(child,"held") }
            await owner.limitFixturePhase(model:phase == .ownRequest || phase == .preLedgerRequest,
                tools:phase == .tools || crosser == .waitedChild)
            try await finish(crossing.0,"crossing",cost:0.6)
            let pending = phase == .ownRequest || phase == .childrenDispatched || phase == .preLedgerRequest
            let before = await owner.stopCount
            XCTAssertEqual(before,pending ? 0 : 1,label)
            if let held {
                XCTAssertNoThrow(try held.1.check(),label)
                try await finish(held.0,"held",cost:0.1)
            }
            if phase == .ownRequest || phase == .preLedgerRequest {
                let beforeClear = await owner.stopCount
                XCTAssertEqual(beforeClear,0,"\(label): settlement precedes completion of the model callback")
                await owner.limitFixturePhase(model:false,tools:false)
            }
            let stopped = await owner.stopCount
            XCTAssertEqual(stopped,1,"\(label): the last request/model-active clear must stop")
            await owner.stopFamilyAtLimit()
            let again = await owner.stopCount, spend = await owner.spend
            XCTAssertEqual(again,1,"\(label): one stop per exhausted run")
            XCTAssertEqual(spend.usd,held == nil ? 0.6 : 0.7,accuracy:1e-9,label)
            do { _ = try await crossing.0.admitAttempt("denied"); XCTFail("\(label): admitted past the limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit",label) }
            await sideChild.close(); await child.close(); await nested.close(); await side.close(); await owner.close()
        } }
    }

    private func assertQueuedChildrenFinalizeWhileOtherRequestsDrain(_ crosser: Crosser) async throws {
        let label = "queuedChildren/\(crosser)", root = try temporaryDirectory()
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
        let queued = Array(accepted.suffix(2)), opened = await runtimes.opened
        XCTAssertEqual(opened.count,18,label)
        for id in queued {
            let prepared = try XCTUnwrap(opened[id]), unloadable = await prepared.canUnload
            XCTAssertFalse(unloadable,"\(label): acceptance pins a prepared runtime until it has a terminal record")
        }
        let crossing = try await start(source,"crossing")
        await owner.limitFixturePhase(model:false,tools:crosser == .waitedChild)
        try await finish(crossing.0,"crossing",cost:0.6)
        let before = await owner.stopCount; XCTAssertEqual(before,0,label)
        // Free one slot while fifteen HTTP requests remain dispatched. Both
        // prepared queued children hit the budget gate, without a family Stop.
        await client.releaseFirst()
        try await eventually { await coordinator.jobs.count == 15 }
        let stopping = await owner.stopCount, inFlight = await owner.inFlightBudgetAttempts.count
        let cancelled = await client.cancelled, settled = await runtimes.settled
        XCTAssertEqual(stopping,0,label); XCTAssertEqual(inFlight,15,label)
        XCTAssertTrue(cancelled.isEmpty,label); XCTAssertEqual(settled.count,3,label)
        let family = await owner.agentState()
        for id in queued {
            let prepared = try XCTUnwrap(opened[id]), target = AgentTurnTarget(childID:id,turn:1)
            let terminal = try XCTUnwrap(family.turns[target.id])
            XCTAssertEqual(terminal.status,.notExecuted,label)
            XCTAssertEqual(terminal.result?.envelope["error"]["code"].text,"cost_limit",label)
            XCTAssertEqual(terminal.result?.metadata["effects"].text,"not_executed",label)
            let state = await prepared.agentState(), closed = await prepared.agentTurnClosed
            let unloadable = await prepared.canUnload, released = await runtimes.released.contains(target.id)
            let spend = await prepared.spend
            XCTAssertEqual(state.latest(id),terminal,"\(label): child and owner must agree before releasing the runtime")
            XCTAssertTrue(closed,label); XCTAssertTrue(unloadable,label); XCTAssertTrue(released,label)
            XCTAssertEqual(settled.filter { $0 == target.id }.count,1,label)
            XCTAssertEqual(spend.reported + spend.unreported,0,label)
            let reader = try JournalRecordReader(root.appendingPathComponent(id + ".jsonl"))
            var records: [JSON] = []
            while let row = try reader.next() {
                if row["customType"].text == JournalRecordKind.agentTerminal { records.append(row["data"]) }
            }
            XCTAssertEqual(records,[try subagentJSON(terminal)],"\(label): the terminal must be durable, exactly once")
        }
        await client.releaseAll()
        try await eventually { await coordinator.jobs.isEmpty }
        let stopped = await owner.stopCount, spend = await owner.spend, allSettled = await runtimes.settled
        let allReleased = await runtimes.released, allCancelled = await client.cancelled
        XCTAssertEqual(stopped,1,label); XCTAssertEqual(spend.usd,4.2,accuracy:1e-9,label)
        XCTAssertEqual(spend.reported,17,label); XCTAssertEqual(spend.unreported,0,label)
        XCTAssertEqual(allSettled.count,18,label); XCTAssertEqual(allReleased.count,18,label)
        XCTAssertTrue(allCancelled.isEmpty,label)
        // Match the host's idle-runtime guard when opening a follow-up. A
        // leaked prepared child would reject this with session_busy.
        await owner.setCostLimit(20)
        let follow = ToolCall(id:"follow",name:"subagent_send",arguments:["child_id":JSON(queued[0]),"message":"Try again","expected_turn":1])
        let key = try await owner.agentFixtureCall(follow,newTask:true)
        let receipt = try await coordinator.prepare(follow,key:key,parent:owner)
        XCTAssertEqual(receipt["route"].text,"follow_up",label)
        try await eventually { await coordinator.jobs.isEmpty }
        let resumed = await owner.agentState(), dispatched = await client.children
        XCTAssertEqual(resumed.latest(queued[0])?.status,.completed,label)
        XCTAssertEqual(dispatched.count,17,label)
        let ownerUnloadable = await owner.canUnload; XCTAssertTrue(ownerUnloadable,label)
        await runtimes.close(); await sideChild.close(); await child.close(); await nested.close(); await side.close(); await owner.close()
    }

    func testBackgroundAndWaitedResultsCannotCancelAnotherDispatchedRequest() async throws {
        for mode in ["background","wait","tool-reply","queued"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client = LimitRunClient(mode:mode), coordinator = AgentSteeringCoordinator()
            let tools = RecordingTools()
            let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
            await parent.enableFamilyBudget(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
            await parent.setCostLimit(0.5)
            _ = try await parent.submit(Submission(commandID:"command",turnID:"turn",text:"Two workers"),steer:false)
            let expectedChildren = mode == "queued" ? 16 : 2
            try await eventually { let n = await client.children.count, running = await parent.isRunning; return n == expectedChildren || !running }
            let started = await client.children.count, initial = await parent.snapshot()
            XCTAssertEqual(started,expectedChildren,initial.encoded())
            if started != expectedChildren { await parent.close(); continue }
            if mode == "queued" { try await eventually { await client.parentCount == 2 } }
            await client.releaseFirst()
            try await eventually {
                let state = await parent.state
                return state == .stopping || state == .error
            }
            let cancelledBeforeRelease = await client.cancelled
            XCTAssertTrue(cancelledBeforeRelease.isEmpty,"\(mode): a budget error must wait for dispatched HTTP work")
            await client.releaseAll()
            try await eventually { !(await parent.isRunning) }
            let cancelled = await client.cancelled, spend = await parent.spend, code = await parent.errorCode
            XCTAssertTrue(cancelled.isEmpty,mode)
            XCTAssertEqual(spend.usd,mode == "queued" ? 3.62 : mode == "wait" ? 0.81 : 0.82,accuracy:1e-9,mode)
            XCTAssertEqual(spend.unreported,0,mode); XCTAssertEqual(code,"cost_limit",mode)
            let calls = await tools.calls; XCTAssertTrue(calls.isEmpty,"No new tool may run while other requests drain")
            if mode == "queued" {
                let family = await parent.agentState()
                XCTAssertEqual(family.turns.count,18)
                XCTAssertEqual(family.turns.values.filter { $0.status == .notExecuted }.count,2,"Queued requests never dispatch after crossing")
            }
            await coordinator.drain(); await parent.close()
        }
    }

    func testLastOwnedSettlementKeepsTheReplyButExecutesNoTools() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tools = RecordingTools(), client = LimitRunClient(mode:"own")
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
            readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore())
        await parent.enableFamilyBudget(); await parent.setCostLimit(0.5)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"turn",text:"Work"),steer:false)
        try await eventually { !(await parent.isRunning) }
        let calls = await tools.calls, code = await parent.errorCode, history = await parent.history, spend = await parent.spend
        XCTAssertTrue(calls.isEmpty,"The settled reply must not start a tool after exhausting the family budget")
        XCTAssertEqual(code,"cost_limit"); XCTAssertEqual(spend.usd,0.6)
        XCTAssertTrue(history.contains { $0.role == "assistant" && $0.content.contains { $0["type"].text == "toolCall" } })
        XCTAssertTrue(history.contains { $0.role == "toolResult" && $0.isError == true },"Keep the assistant/tool pairing without invoking it")
        await parent.close()
    }

    func testNestedSideToolStopsOnlyAfterTheRootsDispatchedRequestSettles() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), tools = LimitHeldTools()
        await owner.enableFamilyBudget(); await owner.setCostLimit(0.5)
        let side = try await side("side",parent:owner,root:root)
        let nested = try await self.side("nested",parent:side,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
        _ = try await nested.submit(Submission(commandID:"command",turnID:"turn",text:"Work"),steer:false)
        try await eventually { await tools.started }
        let held = try await start(owner,"held"), crossing = try await start(side,"crossing")
        try await finish(crossing.0,"crossing",cost:0.6)
        let cancelled = await tools.cancelled; XCTAssertFalse(cancelled)
        XCTAssertNoThrow(try held.1.check())
        try await finish(held.0,"held",cost:0.1)
        do { try await eventually(timeout:.seconds(2)) { !(await nested.isRunning) } }
        catch { await nested.close(); await side.close(); await owner.close(); throw error }
        let stopped = await tools.cancelled, code = await nested.errorCode
        XCTAssertTrue(stopped); XCTAssertEqual(code,"cost_limit")
        await nested.close(); await side.close(); await owner.close()
    }

    func testRaisedBudgetStopsResumedSideToolsAgainWithoutLaunchingTheOwner() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try familyFixture(root:root), tools = LimitHeldTools()
        let side = try await side("side",parent:owner,root:root)
        let nested = try await self.side("nested",parent:side,root:root,client:LimitRunClient(mode:"side-tool"),tools:tools)
        for cycle in 1...2 {
            await owner.setCostLimit(cycle == 1 ? 0.5 : 1.5)
            _ = try await nested.submit(Submission(commandID:"command-\(cycle)",turnID:"turn-\(cycle)",text:"Work"),steer:false)
            try await eventually { await tools.starts == cycle }
            let sibling = try await self.side("sibling-\(cycle)",parent:owner,root:root)
            let held = try await start(sibling,"held-\(cycle)"), crossing = try await start(sibling,"crossing-\(cycle)")
            try await finish(crossing.0,"crossing-\(cycle)",cost:0.9)
            let cancellations = await tools.cancellations
            XCTAssertEqual(cancellations,cycle - 1,"The new budget still drains dispatched work before stopping tools")
            XCTAssertNoThrow(try held.1.check())
            try await finish(held.0,"held-\(cycle)",cost:0.1)
            do { try await eventually(timeout:.seconds(2)) { !(await nested.isRunning) } }
            catch { await sibling.close(); await nested.close(); await side.close(); await owner.close(); throw error }
            let stops = await owner.stopCount, cancelled = await tools.cancellations, code = await nested.errorCode
            XCTAssertEqual(stops,cycle,"The owner never launched; raising its limit must rearm the shared stop")
            XCTAssertEqual(cancelled,cycle); XCTAssertEqual(code,"cost_limit")
            await sibling.close()
        }
        await nested.close(); await side.close(); await owner.close()
    }

    func testBudgetChangesRearmOnlyWhenWorkIsPermittedAndNeverReviveOldPermits() async throws {
        for (limit, damaged, permitsWork) in [(0.5,false,false),(0.8,false,false),(1.5,false,true),(nil,false,true),(1.5,true,false)] as [(Double?,Bool,Bool)] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try familyFixture(root:root)
            await owner.enableFamilyBudget(); await owner.setCostLimit(0.5)
            let request = try await start(owner,"paid")
            try await finish(request.0,"paid",cost:0.9)
            if damaged { await owner.failFamilyAccounting(AgentError("accounting_persistence","Fixture failure")) }
            let generation = await owner.stopCount
            await owner.setCostLimit(limit)
            let issued = await owner.budgetStopIssued, reason = await owner.familyStopReason, paused = await owner.queuePaused
            let after = await owner.stopCount
            XCTAssertEqual(issued,!permitsWork); XCTAssertEqual(after,generation); XCTAssertTrue(paused)
            XCTAssertEqual(reason?.code,damaged ? "accounting_persistence" : permitsWork ? nil : "cost_limit")
            do { _ = try await request.0.admitAttempt("stale"); XCTFail("A raised limit must not revive the old run") }
            catch { if permitsWork { XCTAssertTrue(error is CancellationError) } }
            await owner.close()
        }
    }

    func testRetryBackoffIsNotAnInFlightRequest() async throws {
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
        let code = await owner.errorCode; XCTAssertEqual(code,"cost_limit")
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
    private func finish(_ hooks: RequestLifecycle, _ attempt: String, cost: Double) async throws {
        let observation = billingObservation(profile:try fixtureProfile(),session:hooks.scope.sourceSessionID,attempt:attempt,cost:cost)
        try await hooks.settleAttempt(.init(scope:hooks.scope,observation:observation,dispatched:true))
    }
}

private extension AgentSession {
    func limitFixturePhase(model: Bool, tools: Bool) { modelActive = model; runStatus = tools ? .waitingTool : .running }
}

/// Uses the same unload guard as HostService's open/release callbacks rather
/// than closing every child unconditionally, which would hide a missing seal.
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
        if await child.unloadIfIdle() { released.insert(turn.id) }
    }
    func close() async { for child in opened.values { await child.close() } }
}

private actor LimitRunClient: ModelClient {
    let mode: String
    var parentCount = 0, children: [String] = [], cancelled: [String] = []
    var firstReleased = false, allReleased = false, firstSettled = false
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
            if mode == "own" { reply = toolReply(["first"]); cost = 0.6 }
            else if parentCount == 1 {
                reply = ModelReply(message:ChatMessage(role:"assistant",content:[]))
                for n in 0..<(mode == "queued" ? 18 : 2) {
                    let start = agentCallReply("start-\(n)","subagent_start",["task":JSON("Worker \(n)"),"mode":JSON(mode == "wait" && n == 1 ? "wait" : "background")])
                    reply.calls += start.calls; reply.message.content += start.message.content
                }
            }
            else if mode == "tool-reply" {
                while !firstSettled { try await Task.sleep(for:.milliseconds(2)) }
                reply = toolReply(["first"])
            }
        } else {
            children.append(sessionID)
            let first = mode == "wait" ? messages.contains { $0.role == "user" && $0.text == "Worker 1" } : children.count == 1
            do {
                while !(allReleased || (first && firstReleased)) { try await Task.sleep(for:.milliseconds(2)) }
                try permit.check(); try Task.checkCancellation()
            } catch {
                cancelled.append(sessionID)
                let final = observation(profile,sessionID,turnID,attempt,cost:nil)
                try await hooks.settleAttempt(.init(scope:hooks.scope,observation:final,dispatched:true))
                throw error
            }
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
