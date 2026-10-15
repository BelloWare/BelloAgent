import XCTest
@testable import PiAgentCore

final class SideBudgetTests: XCTestCase {
    private func session(_ id: String, root: URL, parent: AgentSession? = nil, path: String? = nil) async throws -> AgentSession {
        let seed = await parent?.sideSeed()
        let value = try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: DisabledTools(), traces: TraceStore(),
            resumePath: path, seed: path == nil ? seed?.messages : nil, parent: seed?.info ?? .null)
        if let parent { try await value.bindSideBudget(to: parent) }
        return value
    }
    private func start(_ side: AgentSession, attempt: String) async throws -> RequestLifecycle {
        let pending = try await side.requestLifecycle(turnID: "turn", purpose: "turn")
        let lifecycle = try XCTUnwrap(pending)
        _ = try await lifecycle.admitAttempt(attempt); try await lifecycle.willDispatch(attempt)
        return lifecycle
    }
    private func finish(_ lifecycle: RequestLifecycle, attempt: String, cost: Double, outcome: String = "completed") async throws {
        var observation = billingObservation(profile: try fixtureProfile(), session: lifecycle.scope.sourceSessionID, attempt: attempt, cost: cost)
        observation.monitoring["outcome"] = JSON(outcome)
        observation.fields = ["input":100,"output":20,"total":120]
        try await lifecycle.settleAttempt(AttemptSettlement(scope: lifecycle.scope, observation: observation, dispatched: true))
    }

    func testEphemeralSpendSurvivesDiscardAndBlocksTheWholeFamilyWithoutSideContent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await session("main", root: root)
        await parent.setCostLimit(1)
        let side = try await session("side", root: root, parent: parent)
        try await side.append(ChatMessage(role:"user",content:[textBlock("EPHEMERAL SECRET SIDE CONTENT")]))
        let first = try await start(side, attempt:"first"), running = try await start(parent, attempt:"running-main")
        let permit = await parent.requestPermits["running-main"]
        try await finish(first, attempt:"first",cost:1.2,outcome:"failed")
        XCTAssertNoThrow(try permit?.check(), "A request already dispatched must finish")
        do { _ = try await start(side,attempt:"blocked"); XCTFail("Side must use main budget") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        do { _ = try await start(parent,attempt:"also-blocked"); XCTFail("Main must include side spend") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        // Admission preceded the limit crossing. Settlement must still succeed.
        try await finish(running,attempt:"running-main",cost:0.3)
        await side.close(); let path = await parent.path; await parent.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("side_side.jsonl").path))
        let bytes = try String(contentsOfFile:try XCTUnwrap(path),encoding:.utf8)
        XCTAssertFalse(bytes.contains("EPHEMERAL SECRET SIDE CONTENT"))
        let reopened = try await session("main",root:root,path:path)
        let cost = await reopened.costSnapshot
        XCTAssertEqual(cost["spentUSD"].double ?? 0,1.5,accuracy:1e-9)
        XCTAssertEqual(cost["familyUsage"]["input"].int,200)
        XCTAssertEqual(cost["familyUsage"]["output"].int,40)
        await reopened.close()
    }

    func testKeepAndReloadRetainAttemptIdentityTokensAndDoNotChargeAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var parent = try await session("main",root:root)
        var side = try await session("side",root:root,parent:parent)
        let lifecycle = try await start(side,attempt:"physical")
        try await finish(lifecycle,attempt:"physical",cost:0.4,outcome:"cancelled")
        let kept = try await side.keep(whenFinished:false), parentPath = await parent.path
        await side.close(); await parent.close()
        for _ in 0..<2 {
            parent = try await session("main",root:root,path:parentPath)
            side = try await session("side",root:root,parent:parent,path:kept["path"].text)
            let own = await side.costSnapshot, total = await parent.costSnapshot
            XCTAssertEqual(own["spentUSD"].double,0.4)
            XCTAssertEqual(total["spentUSD"].double,0.4)
            XCTAssertEqual(own["familyUsage"]["input"].int,100)
            XCTAssertEqual(total["familyUsage"]["output"].int,20)
            let ids = await side.accounting.attempts.keys.sorted()
            XCTAssertEqual(ids,["physical"])
            await side.close(); await parent.close()
        }
    }

    func testOpeningMainAdoptsLegacySavedSidesWithoutReopeningTheirContent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), seed = await main.sideSeed()
        let old = try AgentSession(id:"legacy", profile:fixtureProfile(), apiKey:"fixture", cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
        try await old.append(ChatMessage(role:"user",content:[textBlock("LEGACY SIDE PRIVATE CONTENT")]))
        await old.countAttempt(billingObservation(profile:try fixtureProfile(),session:"legacy",attempt:"old-attempt",cost:0.7))
        _ = try await old.keep(whenFinished:false)
        let path = await main.path; await old.close(); await main.close()
        for _ in 0..<2 {
            let reopened = try await session("main",root:root,path:path)
            let total = await reopened.spend
            XCTAssertEqual(total.usd,0.7); XCTAssertEqual(total.reported,1)
            let bytes = try String(contentsOfFile:try XCTUnwrap(path),encoding:.utf8)
            XCTAssertFalse(bytes.contains("LEGACY SIDE PRIVATE CONTENT"))
            await reopened.close()
        }
    }

    func testSideOwnedSubagentUsesTheMainBudgetWithoutChangingDelegationIdentity() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), side = try await session("parent",root:root,parent:main)
        _ = try await side.preserveSide()
        await side.beginPresentedTask("turn")
        var origin = subagentFixtureOrigin()
        let execution = await side.activeTaskPresentation?.executionID
        origin.link.parentExecutionID = try XCTUnwrap(execution)
        try await side.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Task",resultMessageID:"result"))
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
        try await child.bindBudgetOwner(side,generation:0)
        await main.setCostLimit(0.5)
        let lifecycle = try await start(child,attempt:"delegated-side-request")
        XCTAssertEqual(lifecycle.scope.budgetOwnerSessionID,"parent")
        XCTAssertEqual(lifecycle.scope.chargeOwnerSessionID,"main")
        XCTAssertEqual(lifecycle.scope.delegation,origin.link)
        try await finish(lifecycle,attempt:"delegated-side-request",cost:0.6)
        for value in [main,side,child] { let spend = await value.spend; XCTAssertEqual(spend.usd,0.6) }
        do { _ = try await start(child,attempt:"blocked-child"); XCTFail("Side subagent must share root limit") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        await child.close(); await side.close(); await main.close()
    }

    func testUnrelatedDamagedSideCannotPreventOpeningMainButRelatedDamageIsNotIgnored() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), unrelated = try await session("unrelated",root:root)
        let side = try await session("side",root:root,parent:unrelated)
        let kept = try await side.keep(whenFinished:false)
        let mainPath = await main.path, unrelatedPath = await unrelated.path
        await side.close(); await unrelated.close(); await main.close()
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath:try XCTUnwrap(kept["path"].text)))
        try file.seekToEnd(); try file.write(contentsOf:Data("{damaged-side-record}\n".utf8)); try file.close()
        let reopened = try await session("main",root:root,path:mainPath)
        let spend = await reopened.spend; XCTAssertEqual(spend.usd,0)
        await reopened.close()
        do {
            let damaged = try await session("unrelated",root:root,path:unrelatedPath)
            await damaged.close(); XCTFail("Related accounting damage must not silently reset a shared budget")
        } catch { }
    }

    func testLegacyMainSeedAndSavedSideHistoryAreAdoptedOnceThroughSessionOpen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), seed = await main.sideSeed()
        let side = try AgentSession(id:"legacy",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
        await side.countAttempt(billingObservation(profile:try fixtureProfile(),session:"legacy",attempt:"old-side",cost:0.7))
        _ = try await side.keep(whenFinished:false)
        let held = await main.path, path = try XCTUnwrap(held)
        await side.close(); await main.close()
        for _ in 0..<2 {
            let host = NativeHostService(emit: { _ in })
            _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
            _ = try await host.command("session.open",sessionID:"main",params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","path":JSON(path),"costSeed":["usd":0.5,"reported":1,"unreported":0]])
            let snapshot = try await host.command("session.status",sessionID:"main",params:[:])
            XCTAssertEqual(snapshot["cost"]["spentUSD"].double ?? 0,1.2,accuracy:1e-9)
            XCTAssertEqual(snapshot["cost"]["reportedRequests"].int,2)
            await host.shutdown()
        }
    }

    func testLateCaptureCorrectionRepairsRootAndSideWithoutDoubleCounting() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), side = try await session("side",root:root,parent:main)
        let lifecycle = try await start(side,attempt:"unknown")
        let observation = billingObservation(profile:try fixtureProfile(),session:"side",attempt:"unknown",cost:nil)
        try await lifecycle.settleAttempt(AttemptSettlement(scope:lifecycle.scope,observation:observation,dispatched:true))
        let evidence: JSON = ["attemptId":"unknown","sessionId":"side","turnId":"turn","purpose":"turn","outcome":"failed",
            "requestScope":try subagentJSON(lifecycle.scope),"usage":["inputIncludingCache":100,"output":20],"gateway":["cost":["status":"reported","usd":0.7]]]
        for _ in 0..<2 { _ = try await main.reconcileCapturedAccounting([evidence]); try await side.refreshSideCharges() }
        for value in [main,side] {
            let cost = await value.costSnapshot
            XCTAssertEqual(cost["spentUSD"].double,0.7); XCTAssertEqual(cost["reportedRequests"].int,1)
            XCTAssertEqual(cost["unreportedRequests"].int,0); XCTAssertEqual(cost["familyUsage"]["output"].int,20)
        }
        await side.close(); await main.close()
    }

    func testOpeningASideDuringTheParentsRequestNeitherLosesItsChargeNorCancelsIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = SideBudgetHeldClient()
        let main = try AgentSession(id:"main",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:DisabledTools(),traces:TraceStore(),autoCompaction:false)
        await main.setCostLimit(1)
        _ = try await main.submit(Submission(commandID:"main-command",turnID:"main-turn",text:"Main request"),steer:false)
        try await eventually { await client.started }
        let side = try await session("side",root:root,parent:main)
        let lifecycle = try await start(side,attempt:"side-crosses-limit")
        try await finish(lifecycle,attempt:"side-crosses-limit",cost:1.2)
        let state = await main.snapshot()
        XCTAssertEqual(state["state"].text,"running","A side must not cancel the main request already on the wire")
        await client.release()
        try await eventually { !(await main.isRunning) }
        let cost = await main.costSnapshot
        XCTAssertEqual(cost["spentUSD"].double ?? 0,1.5,accuracy:1e-9)
        XCTAssertEqual(cost["reportedRequests"].int,2)
        let replies = await main.history.filter { $0.role == "assistant" }.map(\.text)
        XCTAssertTrue(replies.contains("The admitted main request finished"))
        await side.close(); await main.close()
    }

    func testNestedSideSharesRootAndItsImmediateParentsTotals() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root)
        let side = try await session("side",root:root,parent:main)
        let nested = try await session("nested",root:root,parent:side)
        await main.setCostLimit(0.5)
        let lifecycle = try await start(nested,attempt:"nested-attempt")
        XCTAssertEqual(lifecycle.scope.sideParents,["side","main"])
        XCTAssertTrue(lifecycle.scope.valid)
        try await finish(lifecycle,attempt:"nested-attempt",cost:0.6)
        for value in [main,side,nested] {
            let spend = await value.spend
            XCTAssertEqual(spend.usd,0.6)
            do { _ = try await start(value,attempt:UUID().uuidString); XCTFail("Every member uses the root limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        }
        await nested.close(); await side.close(); await main.close()
    }
}

private actor SideBudgetHeldClient: ModelClient {
    var started = false, released = false
    func release() { released = true }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,turnID:turnID,purpose:purpose,onObservation:{ _ in },onDelta:onDelta)
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        started = true
        while !released { try await Task.sleep(for:.milliseconds(2)) }
        try Task.checkCancellation()
        var observation = billingObservation(profile:profile,session:sessionID,attempt:"main-before-side",cost:0.3)
        observation.fields = ["input":100,"output":20]
        await onObservation(observation)
        return answer("The admitted main request finished")
    }
}
