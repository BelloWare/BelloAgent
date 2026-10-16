import XCTest
@testable import PiAgentCore

final class ChildCostPublicationTests: XCTestCase {
    func testOriginalReaderProjectionMatchesEveryLegacyChildLedger() async throws {
        for shape in SideBudgetUpgradeFixture.Shape.allCases {
            for usage in SideBudgetUpgradeFixture.Usage.allCases {
                for crash in SideBudgetUpgradeFixture.Crash.allCases {
                    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                    var f = SideBudgetUpgradeFixture(root:root,shape:shape,family:.agents,usage:usage,crash:crash)
                    try f.write(); let host = try await f.host()
                    _ = try await f.open(host,"main"); _ = try await f.open(host,"side")
                    let child = try await f.open(host,"child"), expected = await child.costSnapshot
                    let reader = try JournalRecordReader(f.file("child")); var projection = ChildCostProjection()
                    while let row = try reader.next() {
                        if let kind = row["customType"].text {
                            try projection.consume(kind:kind,data:row["data"].data(),child:"child",owner:"side",delegation:"delegation")
                        }
                    }
                    let label = "\(shape)/\(usage)/\(crash)"
                    XCTAssertEqual(projection.usd,expected["spentUSD"].double,label)
                    XCTAssertEqual(projection.reported,expected["reportedRequests"].int,label)
                    XCTAssertEqual(projection.unreported,expected["unreportedRequests"].int,label)
                    XCTAssertEqual(projection.revision,expected["accountingRevision"].int,label)
                    await host.shutdown()
                }
            }
        }
    }

    func testHostPublishesCorrectionsForLoadedAndUnloadedSideOwnedChildren() async throws {
        for sideLoaded in [false,true] {
            for childLoaded in [false,true] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                var f = SideBudgetUpgradeFixture(root:root,shape:.current,family:.agents,usage:.unknown,crash:.afterAll)
                try f.write()
                // This case reconciles at main, so retain the actual root
                // admission (the upgrade fixture normally models adoption).
                do {
                    let reader = try JournalRecordReader(f.file("side"))
                    var admission: JSON = .null
                    while let row = try reader.next() { if row["customType"].text == JournalRecordKind.budgetAttempt { admission = row["data"] } }
                    let writer = try SessionJournal(url:f.file("main"),id:"main",cwd:root,binding:nil,create:false)
                    try writer.append(f.row(JournalRecordKind.budgetAttempt,admission),flush:true)
                }
                let frames = ChildCostProbe(), host = NativeHostService(emit:{ frames.add($0) })
                _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
                _ = try await f.open(host,"main"); _ = try await f.open(host,"side")
                if childLoaded { _ = try await f.open(host,"child") }
                if !sideLoaded { _ = try await host.command("session.close",sessionID:"side",params:[:]) }
                var evidence = f.evidence; evidence["gateway"]["cost"] = ["status":"reported","usd":0.7]
                _ = try await host.command("budget.reconcile",sessionID:"main",params:["evidence":.array([evidence])])
                try await eventually { frames.values.contains { $0["type"].text == "session.cost" && $0["sessionId"].text == "child" && $0["payload"]["spentUSD"].double == 0.7 } }
                let reading = try XCTUnwrap(frames.values.last { $0["type"].text == "session.cost" && $0["sessionId"].text == "child" })["payload"]
                XCTAssertEqual(reading["reportedRequests"].int,1); XCTAssertEqual(reading["unreportedRequests"].int,0)
                XCTAssertNotNil(reading["accountingRevision"].int)
                let child = await host.loadedSession("child"); XCTAssertEqual(child != nil,childLoaded)
                let side = await host.loadedSession("side"); XCTAssertEqual(side != nil,sideLoaded)
                await host.shutdown()
            }
        }
    }

    func testColdChildCostsInvalidateOnAppendAndRevalidateAcceptedOrigin() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var f = SideBudgetUpgradeFixture(root:root,shape:.current,family:.agents,usage:.unknown,crash:.afterAll)
        try f.write(); let host = try await f.host()
        _ = try await f.open(host,"main"); let side = try await f.open(host,"side")
        let plans = await side.subagents.plans, plan = try XCTUnwrap(plans.values.first)
        let reader = ChildBudgetReadings()
        let before = try await reader.read(plan:plan,directory:root)
        XCTAssertEqual(before["unreportedRequests"].int,1)
        let repeated = try await reader.read(plan:plan,directory:root); XCTAssertEqual(repeated,before)
        var evidence = f.evidence; evidence["gateway"]["cost"] = ["status":"reported","usd":0.7]
        _ = try await host.command("budget.reconcile",sessionID:"side",params:["evidence":.array([evidence])])
        let corrected = try await reader.read(plan:plan,directory:root)
        XCTAssertEqual(corrected["spentUSD"].double,0.7)
        XCTAssertGreaterThan(corrected["accountingRevision"].int ?? 0,before["accountingRevision"].int ?? 0)
        var foreign = plan; foreign.origin.link.budgetOwnerSessionID = "foreign"
        do { _ = try await reader.read(plan:foreign,directory:root); XCTFail("A cache hit cannot bypass accepted origin validation") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"subagent_recovery") }
        await host.shutdown()
    }

    func testReleasedFollowUpCostsPublishForProgressSettlementLimitCancelAndRestart() async throws {
        for ending in ["completed","limit","cancelled","restart","read-only original"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let readings = ChildCostProbe(), client = ChildCostLifecycleScript()
            let coordinator = AgentSteeringCoordinator(open: { env, plan in
                let child = try AgentSteeringCoordinator.makeChild(env,plan)
                await child.observeChildCosts { readings.add($0) }
                return child
            })
            let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
            await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
            let start = ToolCall(id:"start",name:"subagent_start",arguments:["task":"First","mode":"background"])
            let key = try await parent.agentFixtureCall(start,newTask:true)
            let receipt = try await coordinator.prepare(start,key:key,parent:parent)
            let child = try XCTUnwrap(receipt["child_id"].text)
            try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
            await coordinator.drain()
            let first = try XCTUnwrap(readings.values.last)
            XCTAssertEqual(first["spentUSD"].double,0.01,ending)
            await client.holdCostFollowUp()
            if ending == "limit" { await parent.setCostLimit(0.015) }
            let send = ToolCall(id:"send",name:"subagent_send",arguments:["child_id":JSON(child),"message":"Follow up","expected_turn":1])
            let next = try await parent.agentFixtureCall(send,newTask:true)
            _ = try await coordinator.prepare(send,key:next,parent:parent)
            try await eventually { await client.requests.count == 2 }
            await coordinator.progress(.init(childID:child,turn:2))
            XCTAssertEqual(readings.values.last?["spentUSD"].double,0.01,"Starting/progress does not invent another charge")
            if ending == "cancelled" { try await coordinator.stop(parent:parent,target:.init(childID:child,turn:2),human:true) }
            else { await client.release() }
            try await eventually { await parent.agentState().latest(child)?.status.terminal == true }
            await coordinator.drain()
            let terminal = await coordinator.list(parent:parent,cursor:0,limit:10)
            XCTAssertTrue(terminal["children"].list[0]["progress"].isNull,"Sealing may cancel every progress publication")
            let final = try XCTUnwrap(readings.values.last)
            let plans = await parent.subagents.plans
            let plan = try XCTUnwrap(plans.values.first)
            let saved = try await ChildBudgetReadings().read(plan:plan,directory:root)
            for field in ["spentUSD","reportedRequests","unreportedRequests","accountingRevision"] { XCTAssertEqual(final[field],saved[field],ending + "/" + field) }
            XCTAssertEqual(final["spentUSD"].double,ending == "cancelled" ? 0.01 : 0.02,ending)
            XCTAssertEqual(final["unreportedRequests"].int,ending == "cancelled" ? 1 : 0,ending)
            XCTAssertGreaterThan(final["accountingRevision"].int ?? 0,first["accountingRevision"].int ?? 0,ending)
            if ending == "restart" || ending == "read-only original" {
                let reader = try AgentSession(id:child,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:root.appendingPathComponent(child + ".jsonl").path)
                await reader.observeChildCosts { readings.add($0) }
                XCTAssertEqual(readings.values.last?["accountingRevision"],final["accountingRevision"],"A new runtime retains the durable cost revision")
                XCTAssertEqual(readings.values.last?["spentUSD"],final["spentUSD"])
                await reader.close()
            }
            await parent.close()
        }
    }

    func testTerminalNativeListCarriesAuthoritativeCostsWithoutOpeningChildReaders() async throws {
        for usage in SideBudgetUpgradeFixture.Usage.allCases {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            var f = SideBudgetUpgradeFixture(root:root,shape:.current,family:.agents,usage:usage,crash:.afterAll)
            try f.write(); let host = try await f.host()
            _ = try await f.open(host,"main"); _ = try await f.open(host,"side")
            let page = try await host.command("subagent.list",sessionID:"side",params:["includeCosts":true])
            XCTAssertTrue(page["children"].list.allSatisfy { $0["progress"].isNull })
            let cost = page["costs"]["child"]
            XCTAssertEqual(cost["spentUSD"].double,usage == .priced ? 0.7 : 0)
            XCTAssertEqual(cost["reportedRequests"].int,usage == .priced ? 1 : 0)
            XCTAssertEqual(cost["unreportedRequests"].int,usage == .priced ? 0 : 1)
            XCTAssertNotNil(cost["accountingRevision"].int)
            let child = await host.loadedSession("child"); XCTAssertNil(child)
            let ordinary = try await host.command("subagent.list",sessionID:"side",params:[:])
            XCTAssertTrue(ordinary["costs"].isNull,"Numeric metadata is opt-in native IPC, never a model tool result")
            await host.shutdown()
        }
    }

    func testUnloadedChildMirrorLeavesHostResponsiveAndKeepsRuntimeGate() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var f = SideBudgetUpgradeFixture(root:root,shape:.current,family:.agents,usage:.unknown,crash:.afterAll)
        try f.write(); let host = try await f.host()
        _ = try await f.open(host,"main"); _ = try await f.open(host,"side")
        var evidence = f.evidence; evidence["gateway"]["cost"] = ["status":"reported","usd":0.7]
        let gate = ChildMirrorGate(), began = expectation(description:"Disk mirror entered")
        await host.holdChildMirror { began.fulfill(); gate.wait() }
        let reconcile = Task { try await host.command("budget.reconcile",sessionID:"side",params:["evidence":.array([evidence])]) }
        await fulfillment(of:[began],timeout:5)
        let status = expectation(description:"Unrelated status while disk is held"), stopped = expectation(description:"Stop while disk is held")
        let statusTask = Task { _ = try await host.command("session.status",sessionID:"main",params:["budgetOnly":true]); status.fulfill() }
        let stopTask = Task { _ = try await host.command("turn.stop",sessionID:"main",params:[:]); stopped.fulfill() }
        let opened = ChildOpenProbe()
        let openTask = Task { _ = try await f.open(host,"child"); await opened.set() }
        await fulfillment(of:[status,stopped],timeout:1)
        let premature = await opened.value; XCTAssertFalse(premature,"The runtime gate must prevent a second writer")
        gate.open()
        _ = try await reconcile.value; try await statusTask.value; try await stopTask.value; try await openTask.value
        let cost = try await host.command("session.status",sessionID:"child",params:["budgetOnly":true])
        XCTAssertEqual(cost["cost"]["spentUSD"].double,0.7)
        await host.shutdown()
    }
}

private final class ChildMirrorGate: @unchecked Sendable {
    private let release = DispatchSemaphore(value:0)
    func wait() { _ = release.wait(timeout:.now() + 10) }
    func open() { release.signal() }
}
private actor ChildOpenProbe {
    var value = false
    func set() { value = true }
}
private final class ChildCostProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [JSON] = []
    var values: [JSON] { lock.withLock { stored } }
    func add(_ value: JSON) { lock.withLock { stored.append(value) } }
}
private actor ChildCostLifecycleScript: ModelClient {
    var requests: [[ChatMessage]] = []
    var held = false
    func holdCostFollowUp() { held = true }
    func release() { held = false }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply { throw AgentError("fixture","Accounting required") }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let lifecycle = try XCTUnwrap(lifecycle), attempt = UUID().uuidString
        let permit = try await lifecycle.admitAttempt(attempt); defer { permit.finish() }
        try await lifecycle.willDispatch(attempt); requests.append(messages)
        var observation = RequestObservation(sessionID:sessionID,turnID:turnID,attemptID:attempt,purpose:purpose,fingerprint:"fixture",profile:profile)
        do { while held { try await Task.sleep(for:.milliseconds(5)) } }
        catch {
            observation.monitoring = ["outcome":"cancelled","gateway":["cost":["status":"unreported"]]]
            try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true))
            throw error
        }
        observation.monitoring = ["outcome":"completed","gateway":["cost":["status":"reported","usd":0.01]]]
        observation.fields = ["input":10,"output":2,"total":12]
        try await lifecycle.settleAttempt(.init(scope:lifecycle.scope,observation:observation,dispatched:true))
        await onObservation(observation)
        return answer("Answer")
    }
}
private extension NativeHostService {
    func holdChildMirror(_ action: @escaping @Sendable () -> Void) { beforeChildCostMirror = action }
}
