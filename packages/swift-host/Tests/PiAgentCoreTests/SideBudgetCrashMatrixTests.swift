import XCTest
@testable import PiAgentCore

final class SideBudgetCrashMatrixTests: XCTestCase {
    func testFallbackAfterSideAppendFailurePreservesTheAdmittedScope() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try session("main",root:root)
        let sideFile = file("side",root)
        do {
            let writer = try SessionJournal(url:sideFile,id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
            try writer.append(row(JournalRecordKind.sideOrigin,["parentSessionId":"main","relationship":"side"]))
        }
        let side = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:sideFile.path,
            beforeJournalAppend:{ record in
                if record["customType"].text == JournalRecordKind.cost, record["data"]["sourceSessionId"].text == "child" { throw AgentError("fixture_append","Side append failed after the root committed") }
            })
        try await side.bindSideBudget(to:main)
        await side.beginPresentedTask("turn")
        var origin = subagentFixtureOrigin(parent:"side")
        let execution = await side.activeTaskPresentation?.executionID
        origin.link.parentExecutionID = try XCTUnwrap(execution)
        let plan = SubagentPlan(origin:origin,task:"Private fallback task",resultMessageID:"result")
        try await side.installAdmissionFixturePlan(plan)
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
        try await child.bindBudgetOwner(side,generation:0)
        let hooks = try await child.requestLifecycle(turnID:"turn",purpose:"turn")
        let request = try XCTUnwrap(hooks)
        _ = try await request.admitAttempt("charged"); try await request.willDispatch("charged")
        var observation = billingObservation(profile:try fixtureProfile(),session:"child",attempt:"charged",cost:0.7)
        observation.fields = ["input":100,"output":20]; observation.fieldStatus = ["input":"reported","output":"reported"]
        do { try await request.settleAttempt(AttemptSettlement(scope:request.scope,observation:observation,dispatched:true)); XCTFail("Fault injection did not reach the side append") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"accounting_persistence") }
        let ownerCost = await main.accounting.attempts["charged"]?.contribution
        let fallback = await child.accounting.attempts["charged"]?.contribution
        XCTAssertEqual(fallback?["scope"],try subagentJSON(request.scope))
        await child.close(); await side.close(); await main.close()
        let cost = try XCTUnwrap(ownerCost)
        XCTAssertNoThrow(try SubagentRecovery.mirrorCapturedCost(cost,plan:plan,directory:root))
    }

    func testOpeningMainRecoversLegacyChildEvidenceWithoutOpeningTheSide() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        _ = try fixture(root,shape:.preScope,crash:.beforeMain)
        let host = try await host(root)
        do {
            let main = try await open(host,"main",root)
            assertFamily(await main.costSnapshot,"main alone")
            let side = await host.loadedSession("side")
            XCTAssertNil(side,"Accounting recovery must not allocate a side transcript runtime")
            do { try await main.enforceCostLimit(); XCTFail("Durable child cost must close the root's $0.50 budget") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        } catch { XCTFail("Legacy child recovery failed: \(error)") }
        await host.shutdown()
    }

    func testColdDeletionAcceptsTheOlderV3OriginShape() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        _ = try fixture(root,shape:.missingReasoning,crash:.afterAll)
        let host = try await host(root)
        do { _ = try await host.command("session.forget",sessionID:"main",params:[:]) }
        catch { XCTFail("Accepted legacy origin must not block cold deletion: \(error)") }
        await host.shutdown()
    }

    func testLoadedAndUnloadedMirrorsRejectChangedAcceptedOriginsAndImmutableScopes() async throws {
        for loaded in [false,true] {
            for changed in ["origin","scope"] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                _ = try fixture(root,shape:.current,crash:.afterAll)
                let url = file("child",root)
                let rows = try String(contentsOf:url,encoding:.utf8).split(separator:"\n").map { line -> String in
                    var record = try JSON.parse(Data(line.utf8))
                    if changed == "origin", record["customType"].text == JournalRecordKind.subagentOrigin { record["data"]["readOnly"] = false }
                    if changed == "scope", record["customType"].text == JournalRecordKind.cost { record["data"]["scope"]["sideParents"] = ["foreign"] }
                    return record.encoded()
                }
                try Data((rows.joined(separator:"\n") + "\n").utf8).write(to:url)
                let before = try Data(contentsOf:url), host = try await host(root)
                if loaded { _ = try await open(host,"child",root) }
                do {
                    _ = try await host.command("session.forget",sessionID:"main",params:[:])
                    XCTFail("Changed \(changed) must not be accepted (loaded=\(loaded))")
                } catch { XCTAssertTrue(["subagent_recovery","accounting_damaged"].contains((error as? AgentError)?.code ?? "")) }
                await host.shutdown()
                XCTAssertEqual(try Data(contentsOf:url),before,"Conflicting evidence must remain available for repair")
            }
        }
    }

    func testDiscardedSideChargesDoNotRequirePlansForUnrelatedLoadedChats() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        _ = try fixture(root,shape:.current,crash:.afterAll)
        // Only numeric charges survive a discarded, unkept family. There is
        // no saved side/child content to repair or recreate during deletion.
        try FileManager.default.removeItem(at:file("side",root))
        try FileManager.default.removeItem(at:file("child",root))
        let unrelated = try session("unrelated",root:root); await unrelated.close()
        let host = try await host(root)
        _ = try await open(host,"main",root); _ = try await open(host,"unrelated",root)
        do { _ = try await host.command("session.forget",sessionID:"main",params:[:]) }
        catch { XCTFail("An unrelated loaded chat must not demand discarded side authority: \(error)") }
        await host.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file("side",root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file("child",root).path))
    }

    func testDirectCorrectionCannotReplaceKnownAmountsOrImmutableScopes() async throws {
        for field in ["usd","scope"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try session("parent",root:root)
            let scope = try subagentJSON(RequestScope(sourceSessionID:"child",budgetOwnerSessionID:"parent",turnID:"turn",executionID:"execution",purpose:"turn",ownerGeneration:0,delegation:subagentFixtureOrigin().link))
            var admission = admissionRecord("known"); admission["state"] = "dispatched"; admission["scope"] = scope
            var cost = costRecord("known",usd:0.7,revision:2); cost["scope"] = scope
            try await owner.appendAccounting(kind:JournalRecordKind.budgetAttempt,data:admission)
            try await owner.appendAccounting(kind:JournalRecordKind.cost,data:cost)
            var conflict = cost; conflict["accountingRevision"] = 3
            if field == "usd" { conflict["usd"] = 0.8 } else { conflict["scope"]["turnID"] = "foreign" }
            do { try await owner.correctAccounting(conflict); XCTFail("Direct correction bypassed the shared \(field) comparison") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"accounting_damaged") }
            let saved = await owner.accounting.attempts["known"]?.contribution
            XCTAssertEqual(saved,cost)
            await owner.close()
        }
    }

    func testEveryLegacyCrashPlacementAndOperationConvergesOnTheSameAccounting() async throws {
        var cases = 0
        for shape in Shape.allCases {
            for crash in Crash.allCases {
                for sideLoaded in [false,true] {
                    for childLoaded in [false,true] {
                        for operation in Operation.allCases {
                            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                            let evidence = try fixture(root,shape:shape,crash:crash)
                            var host = try await host(root)
                            let label = "\(shape) / \(crash) / side=\(sideLoaded) child=\(childLoaded) / \(operation)"
                            do {
                                // Child readers may precede their owner's open.
                                if childLoaded { _ = try await open(host,"child",root) }
                                if sideLoaded {
                                    _ = try await open(host,"main",root)
                                    _ = try await open(host,"side",root)
                                    if childLoaded { _ = try await open(host,"child",root) }
                                }
                                if operation == .deleteCold {
                                    await host.shutdown(); host = try await self.host(root)
                                }
                                switch operation {
                                case .openMain:
                                    let main = try await open(host,"main",root)
                                    assertFamily(await main.costSnapshot,label)
                                case .openSide:
                                    _ = try await open(host,"main",root)
                                    let side = try await open(host,"side",root)
                                    assertFamily(await side.costSnapshot,label)
                                case .reconcile:
                                    _ = try await open(host,"main",root)
                                    // Legacy captures authorize their direct owner.
                                    _ = try await open(host,"side",root)
                                    if childLoaded { _ = try await open(host,"child",root) }
                                    for _ in 0..<2 { _ = try await host.command("budget.reconcile",sessionID:"side",params:["evidence":.array([evidence])]) }
                                case .deleteCold,.deleteWithHelper:
                                    if operation == .deleteWithHelper { _ = try await open(host,"main",root) }
                                    _ = try await host.command("session.forget",sessionID:"main",params:[:])
                                    try FileManager.default.removeItem(at:file("main",root))
                                }
                                if !operation.deletes {
                                    let main = try await open(host,"main",root)
                                    assertFamily(await main.costSnapshot,label)
                                }
                                let side = try await open(host,"side",root), child = try await open(host,"child",root)
                                assertFamily(await side.costSnapshot,label)
                                let childCost = await child.costSnapshot
                                XCTAssertEqual(childCost["spentUSD"].double,0.7,label)
                                XCTAssertEqual(childCost["reportedRequests"].int,1,label)
                                XCTAssertEqual(childCost["unreportedRequests"].int,0,label)
                                XCTAssertEqual(childCost["familyUsage"]["output"].int,20,label)
                                XCTAssertEqual(childCost["familyUsage"]["unknownRequests"].int,0,label)
                                await host.shutdown()
                                // Check durable totals again, with no capture evidence.
                                let reopened = try session("side",root:root,resume:true)
                                assertFamily(await reopened.costSnapshot,label + " reloaded")
                                await reopened.close()
                            } catch { XCTFail("Valid accounting must succeed: \(label): \(error)") }
                            await host.shutdown()
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases,320)
    }

    private enum Shape: CaseIterable { case preCost, preScope, missingReasoning, current }
    private enum Crash: CaseIterable { case beforeMain, beforeSide, beforeChild, afterAll }
    private enum Operation: CaseIterable {
        case openMain, openSide, reconcile, deleteCold, deleteWithHelper
        var deletes: Bool { self == .deleteCold || self == .deleteWithHelper }
    }
    private func fixture(_ root: URL, shape: Shape, crash: Crash) throws -> JSON {
        var origin = subagentFixtureOrigin(parent:"side")
        if shape == .missingReasoning || shape == .current { origin.model.reasoning = ["low","high"] }
        let plan = SubagentPlan(origin:origin,task:"Private side task never copied to main",resultMessageID:"result")
        var scope = RequestScope(sourceSessionID:"child",budgetOwnerSessionID:"side",turnID:"turn",executionID:"child-execution",purpose:"turn",ownerGeneration:0,delegation:origin.link)
        if shape == .missingReasoning || shape == .current { scope.sideParents = ["main"]; scope.childTurn = 1; scope.parentExecutionID = "execution" }
        let scopeJSON = try subagentJSON(scope)
        let admission: JSON = ["attemptId":"charged","sourceSessionId":"child","budgetOwnerSessionId":"side","delegationId":"delegation","purpose":"turn","state":"dispatched","scope":scopeJSON,"accountingRevision":1]
        var cost: JSON = ["attemptId":"charged","sourceSessionId":"child","budgetOwnerSessionId":"side","delegationId":"delegation","purpose":"turn","outcome":"completed","usd":0.7,"reported":1,"unreported":0,"usage":["input":100,"output":20],"usageStatus":["input":"reported","output":"reported"],"accountingRevision":2]
        if shape != .preCost && shape != .preScope { cost["scope"] = scopeJSON; cost["sideParents"] = ["main"] }
        var mainCost = cost; mainCost["sideParents"] = ["main"]; mainCost["accountingRevision"] = 8
        var own: JSON = ["usd":0.2,"reported":1,"unreported":0,"source":"app-request-log"]
        if shape != .preCost { own["attemptId"] = "own"; own["sourceSessionId"] = "side"; own["budgetOwnerSessionId"] = "side" }
        let unresolvedScope = RequestScope(sourceSessionID:"side",budgetOwnerSessionID:"side",turnID:"unknown",executionID:"unknown",purpose:"turn",ownerGeneration:0,delegation:nil)
        let unresolved: JSON = ["attemptId":"unresolved","sourceSessionId":"side","budgetOwnerSessionId":"side","purpose":"turn","state":"dispatched","scope":try subagentJSON(unresolvedScope),"accountingRevision":3]
        do {
            let main = try SessionJournal(url:file("main",root),id:"main",cwd:root,binding:fixtureProfile().binding,create:true)
            if crash != .beforeMain { try main.append(row(JournalRecordKind.cost,mainCost),flush:true) }
            let side = try SessionJournal(url:file("side",root),id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
            try side.append(row(JournalRecordKind.sideOrigin,["parentSessionId":"main","relationship":"side"]))
            try side.append(row(JournalRecordKind.cost,own))
            if shape == .missingReasoning || shape == .current {
                try side.promoteToSteering(managedChild:false)
                var message = ChatMessage(role:"assistant",content:[["type":"toolCall","id":"call","name":"subagent_start","arguments":["task":"Private task","mode":"background"]]])
                message.id = "reply"; try side.append(["type":"message","message":message.pi],id:"reply")
                let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
                let operation = AgentOperation(key:origin.link.call,digest:"fixture",receipt:["accepted":true],plan:plan,turn:turn,epoch:"epoch")
                var accepted = row(JournalRecordKind.agentOperation,try subagentJSON(operation)); accepted["ownerID"] = "side"
                try side.append(accepted)
            } else { try side.append(row(JournalRecordKind.subagentCall,try subagentJSON(plan))) }
            try side.append(row(JournalRecordKind.budgetAttempt,admission))
            if crash == .beforeChild || crash == .afterAll { try side.append(row(JournalRecordKind.cost,cost)) }
            try side.append(row(JournalRecordKind.budgetAttempt,unresolved),flush:true)
            let child = try SessionJournal(url:file("child",root),id:"child",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
            if shape == .missingReasoning { origin.model.reasoning = nil }
            try child.append(row(JournalRecordKind.subagentOrigin,try subagentJSON(origin)))
            // A failed upstream commit leaves fallback evidence in the child.
            if crash != .beforeChild { try child.append(row(JournalRecordKind.cost,cost),flush:true) }
        }
        return ["attemptId":"charged","sessionId":"child","turnId":"turn","purpose":"turn","outcome":"completed","requestScope":scopeJSON,"gateway":["cost":["status":"reported","usd":0.7]],"usage":["inputIncludingCache":100,"output":20]]
    }
    private func assertFamily(_ value: JSON, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value["spentUSD"].double ?? -1,0.9,accuracy:1e-10,label,file:file,line:line)
        XCTAssertEqual(value["reportedRequests"].int,2,label,file:file,line:line)
        XCTAssertEqual(value["unreportedRequests"].int,1,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["input"].int,100,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["output"].int,20,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["reportedFields"]["output"].int,1,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["unknownRequests"].int,2,label,file:file,line:line)
    }
    private func file(_ id: String, _ root: URL) -> URL { root.appendingPathComponent((id == "side" ? "side_" : "") + id + ".jsonl") }
    private func row(_ kind: String, _ data: JSON) -> JSON { ["type":"custom","customType":JSON(kind),"data":data] }
    private func session(_ id: String, root: URL, resume: Bool = false) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:resume ? file(id,root).path : nil)
    }
    private func host(_ root: URL) async throws -> NativeHostService {
        let host = NativeHostService(emit:{ _ in })
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
        return host
    }
    private func open(_ host: NativeHostService, _ id: String, _ root: URL) async throws -> AgentSession {
        _ = try await host.command("session.open",sessionID:id,params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","path":JSON(file(id,root).path),"costLimit":["usd":0.5]])
        let loaded = await host.loadedSession(id); return try XCTUnwrap(loaded)
    }
}
