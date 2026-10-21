import XCTest
@testable import PiAgentCore

final class SideBudgetReplayTests: HelperTestCase {
    // Exhaustive, deterministic products of the historical ledger shapes.
    // Compare the public recovery paths, not a second copy of their reducer.
    func testLegacyShapesHaveIdenticalReplayAndRecoveryTotalsBeforeAndAfterOrphaning() throws {
        var cases = 0
        for keyed in [false, true] {
            for position in ["before", "after", "both"] {
                for adoption in ["no-delegation", "none", "cost", "subagentCall", "agentOperation"] {
                    for seed in ["none", "app-request-log", "side-history"] {
                        for state in AttemptState.allCases {
                            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                            let file = try writeLegacySide(root, keyed:keyed, position:position, adoption:adoption, seed:seed, attemptState:state)
                            let parent = root.appendingPathComponent("main.jsonl")
                            do { _ = try SessionJournal(url:parent,id:"main",cwd:root,binding:fixtureProfile().binding,create:true) }
                            for orphan in [false, true] {
                                if orphan { try FileManager.default.removeItem(at:parent) }
                                let label = "keyed=\(keyed) position=\(position) adoption=\(adoption) seed=\(seed) attempt=\(state) orphan=\(orphan)"
                                let replay = try replay(file, id:"side")
                                var recovered = AttemptAccounting(), spend = SessionSpend()
                                let charges = try SideBudgetRecovery.charges(owner:"main",directory:root)
                                // Scan twice and then bind the normal replay: all
                                // three representations must count the same work once.
                                for _ in 0..<2 {
                                    for charge in charges where recovered.attempts[charge.data["attemptId"].text ?? ""] == nil {
                                        try recovered.consume(kind:charge.kind,data:charge.data,spend:&spend)
                                    }
                                }
                                assertTotals(replay, accounting:recovered, spend:spend, label:label)
                                for entry in replay.accounting.attempts.values {
                                    if let record = SideBudgetRecovery.record(entry,side:"side",parents:["main"]), recovered.attempts[record.data["attemptId"].text ?? ""] == nil {
                                        try recovered.consume(kind:record.kind,data:record.data,spend:&spend)
                                    }
                                }
                                if let seed = SideBudgetRecovery.unkeyedCharge(spend:replay.spend,accounting:replay.accounting,side:"side",parents:["main"]), recovered.attempts[seed["attemptId"].text ?? ""] == nil {
                                    try recovered.consume(kind:JournalRecordKind.cost,data:seed,spend:&spend)
                                }
                                assertTotals(replay, accounting:recovered, spend:spend, label:label + " after binding")
                                let expected = (adoption == "no-delegation" ? 0 : 0.3) + (position == "after" ? 0 : 0.2) + (position == "before" ? 0 : 0.1) + (seed == "none" ? 0 : 0.07)
                                XCTAssertEqual(spend.usd,expected + state.spend,accuracy:1e-10,label)
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases,180 * AttemptState.allCases.count)
    }

    func testAdoptionBeforeFirstDelegationCountsOnceThroughRealBindAndColdReload() async throws {
        for adoption in ["subagentCall", "agentOperation"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let file = try writeLegacySide(root,keyed:true,position:"before",adoption:adoption,seed:"none")
            do { _ = try SessionJournal(url:root.appendingPathComponent("main.jsonl"),id:"main",cwd:root,binding:fixtureProfile().binding,create:true) }
            for _ in 0..<2 {
                let main = try session("main",root:root,path:root.appendingPathComponent("main.jsonl"))
                let side = try session("side",root:root,path:file)
                try await side.bindSideBudget(to:main)
                try await side.bindSideBudget(to:main)
                let total = await main.costSnapshot, local = await side.costSnapshot
                XCTAssertEqual(total["spentUSD"].double,0.5,adoption)
                XCTAssertEqual(total["reportedRequests"].int,2,adoption)
                XCTAssertEqual(total["familyUsage"]["output"].int,20,adoption)
                XCTAssertEqual(local["spentUSD"].double,0.5,adoption)
                await side.close(); await main.close()
            }
            try FileManager.default.removeItem(at:root.appendingPathComponent("main.jsonl"))
            let orphan = try session("side",root:root,path:file)
            let total = await orphan.spend
            XCTAssertEqual(total.usd,0.5,adoption); XCTAssertEqual(total.reported,2,adoption)
            await orphan.setCostLimit(0.4)
            do { try await orphan.enforceSharedCostLimit(); XCTFail("An adopted orphan keeps and enforces exactly its own family spend") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
            await orphan.close()
        }
    }

    func testEveryAttemptStateSurvivesColdAdoptionLiveBindingAndReload() async throws {
        for state in AttemptState.allCases {
            // Ordinary startup proves admission-only attempts were never sent.
            // The raw replay/recovery matrix above compares them before this
            // existing recovery transition; dispatched attempts stay unknown.
            let expected = state == .admitted ? AttemptState.notDispatched : state
            for cold in [false,true] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let parent = root.appendingPathComponent("main.jsonl")
                let initial = try session("main",root:root,path:nil)
                if cold { await initial.close() }
                let file = try writeAttemptSide(root,state:state)
                var main = cold ? try session("main",root:root,path:parent) : initial
                for reload in [false,true] {
                    if reload { main = try session("main",root:root,path:parent) }
                    let side = try session("side",root:root,path:file)
                    for _ in 0..<2 { try await side.bindSideBudget(to:main) }
                    let reading = await main.costSnapshot, local = await side.costSnapshot
                    for value in [reading,local] {
                        XCTAssertEqual(value["spentUSD"].double,expected.spend,"\(state), cold=\(cold)")
                        XCTAssertEqual(value["reportedRequests"].int,expected.reported,"\(state)")
                        XCTAssertEqual(value["unreportedRequests"].int,expected.unreported,"\(state)")
                        XCTAssertEqual(value["familyUsage"]["unknownRequests"].int,expected.unknownUsage,"\(state)")
                        XCTAssertEqual(value["familyUsage"],local["familyUsage"],"\(state)")
                    }
                    await side.close(); await main.close()
                }
                try FileManager.default.removeItem(at:parent)
                let orphan = try session("side",root:root,path:file)
                let reading = await orphan.costSnapshot
                XCTAssertEqual(reading["unreportedRequests"].int,expected.unreported)
                XCTAssertEqual(reading["familyUsage"]["unknownRequests"].int,expected.unknownUsage)
                await orphan.close()
            }
        }
    }

    func testRecoveredAdmissionsCanSettleOrBecomeNotDispatchedWithoutCountingTwice() async throws {
        for starting in [AttemptState.admitted,.dispatched] {
            for terminal in [AttemptState.reported,.dispatchedCancelled] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let main = try session("main",root:root,path:nil)
                let file = try writeAttemptSide(root,state:.empty), side = try session("side",root:root,path:file)
                for record in attemptRows(starting) {
                    try await side.appendAccounting(kind:try XCTUnwrap(record["customType"].text),data:record["data"])
                }
                try await side.bindSideBudget(to:main)
                let before = await main.costSnapshot
                XCTAssertEqual(before["unreportedRequests"].int,1)
                // Rebinding a loaded reader cannot turn an admission into a
                // settlement. Its later real terminal evidence must still work.
                let rows = attemptRows(terminal)
                if starting == .admitted && terminal == .reported {
                    try await side.appendAccounting(kind:JournalRecordKind.budgetAttempt,data:rows[1]["data"])
                }
                let final = try XCTUnwrap(rows.last)
                try await side.appendAccounting(kind:try XCTUnwrap(final["customType"].text),data:final["data"])
                for _ in 0..<2 { try await side.bindSideBudget(to:main) }
                let after = await main.costSnapshot
                XCTAssertEqual(after["spentUSD"].double,terminal.spend)
                XCTAssertEqual(after["reportedRequests"].int,terminal.reported)
                XCTAssertEqual(after["unreportedRequests"].int,0)
                XCTAssertEqual(after["familyUsage"]["unknownRequests"].int,0)
                await side.close(); await main.close()
                let reopened = try session("main",root:root,path:root.appendingPathComponent("main.jsonl"))
                let saved = await reopened.costSnapshot
                XCTAssertEqual(saved["spentUSD"],after["spentUSD"])
                XCTAssertEqual(saved["familyUsage"],after["familyUsage"])
                await reopened.close()
            }
        }
    }

    func testRecoveredAdmissionsKeepTheOriginalCaptureReconciliationAuthority() async throws {
        for sharedScope in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let first = try session("main",root:root,path:nil); await first.close()
            let file = try writeAttemptSide(root,state:.empty)
            var records = attemptRows(.dispatched)
            if sharedScope {
                for index in records.indices { records[index]["data"]["scope"]["sideParents"] = ["main"] }
            }
            do {
                let writer = try SessionJournal(url:file,id:"side",cwd:root,binding:nil,create:false)
                for record in records { try writer.append(record) }
            }
            let main = try session("main",root:root,path:root.appendingPathComponent("main.jsonl"))
            let side = try session("side",root:root,path:file)
            let parentPage = try await main.budgetAttempts(after:nil), sidePage = try await side.budgetAttempts(after:nil)
            XCTAssertEqual(parentPage["attemptIds"].list,sharedScope ? ["state-attempt"] : [],"Adoption must not widen the immutable capture scope")
            XCTAssertEqual(sidePage["attemptIds"].list,["state-attempt"])
            let admission = try XCTUnwrap(records.last)["data"]
            let evidence: JSON = ["attemptId":"state-attempt","sessionId":"side","turnId":"turn","purpose":"turn","outcome":"completed",
                "requestScope":admission["scope"],"gateway":["cost":["status":"reported","usd":0.4]],"usage":["inputIncludingCache":100,"output":20,"total":120]]
            _ = try await (sharedScope ? main : side).reconcileCapturedAccounting([evidence],mirrorChildren:false)
            try await side.bindSideBudget(to:main)
            for value in [await main.costSnapshot,await side.costSnapshot] {
                XCTAssertEqual(value["spentUSD"].double,0.4)
                XCTAssertEqual(value["reportedRequests"].int,1); XCTAssertEqual(value["unreportedRequests"].int,0)
                XCTAssertEqual(value["familyUsage"]["output"].int,20)
                XCTAssertEqual(value["familyUsage"]["unknownRequests"].int,0)
            }
            await side.close(); await main.close()
        }
    }

    func testJoiningALiveOwnersBudgetRetainsItsEarlierUnknownUsageCoverage() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try session("main",root:root,path:nil)
        await main.countAttempt(billingObservation(profile:try fixtureProfile(),session:"main",attempt:"before-side",cost:0.2))
        let side = try session("side",root:root,path:writeAttemptSide(root,state:.dispatched))
        try await side.bindSideBudget(to:main)
        let reading = await main.costSnapshot
        XCTAssertEqual(reading["spentUSD"].double,0.2)
        XCTAssertEqual(reading["reportedRequests"].int,1); XCTAssertEqual(reading["unreportedRequests"].int,1)
        XCTAssertEqual(reading["familyUsage"]["unknownRequests"].int,2,"Both pre-ledger own spend and the unresolved side lack token coverage")
        await side.close(); await main.close()
        let reopened = try session("main",root:root,path:root.appendingPathComponent("main.jsonl"))
        let reloaded = await reopened.costSnapshot
        XCTAssertEqual(reloaded["familyUsage"],reading["familyUsage"])
        await reopened.close()
    }

    func testOlderCheckpointRestoresTheSameUnknownUsageCoverageAsFullReplay() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = try writeLegacySide(root,keyed:false,position:"before",adoption:"none",seed:"app-request-log",attemptState:.dispatched)
        do {
            let writer = try SessionJournal(url:file,id:"side",cwd:root,binding:nil,create:false)
            try writer.append(["type":"message","message":["role":"user","content":"Private checkpoint fixture"]],id:"kept")
            try writer.append(row(JournalRecordKind.context,["ids":["kept"]]))
        }
        let full = try replay(file,id:"side")
        var checkpoint = try XCTUnwrap(full.captured)
        var helper = try JSON.parse(Data(checkpoint.helper.utf8))
        // Older checkpoints counted the unresolved attempt, but omitted the
        // three requests in the legacy unkeyed history from token coverage.
        helper["accounting"]["usageUnknownRequests"] = 1
        checkpoint.helper = helper.encoded(); try checkpoint.write(for:file)
        let partial = try replay(file,id:"side",resume:true)
        XCTAssertTrue(partial.resumed)
        assertTotals(full,accounting:partial.accounting,spend:partial.spend,label:"old checkpoint")
        XCTAssertEqual(partial.accounting.usageUnknownRequests,4)
    }

    private func writeAttemptSide(_ root: URL, state: AttemptState) throws -> URL {
        let file = root.appendingPathComponent("side_side.jsonl")
        let writer = try SessionJournal(url:file,id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
        try writer.append(row(JournalRecordKind.sideOrigin,["parentSessionId":"main","relationship":"side"]))
        for value in attemptRows(state) { try writer.append(value) }
        try writer.synchronize()
        return file
    }

    func testCopiedAdoptionRecordsNeverResetAnotherOwnersLedger() throws {
        for kind in [JournalRecordKind.subagentCall, JournalRecordKind.agentOperation] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let file = try writeLegacySide(root,keyed:true,position:"both",adoption:"none",seed:"none")
            do {
                let writer = try SessionJournal(url:file,id:"side",cwd:root,binding:nil,create:false)
                let plan = SubagentPlan(origin:subagentFixtureOrigin(parent:"foreign"),task:"Foreign history",resultMessageID:"foreign-result",adoptionSeed:["reset":true,"source":"family-adoption","usd":99,"reported":1])
                if kind == JournalRecordKind.subagentCall { try writer.append(row(kind,try subagentJSON(plan))) }
                else {
                    var value = row(kind,try subagentJSON(AgentOperation(key:plan.origin.link.call,digest:"foreign",receipt:[:],plan:plan,epoch:"foreign-epoch")))
                    value["ownerID"] = "foreign"; try writer.append(value)
                }
            }
            let replay = try replay(file,id:"side")
            var accounting = AttemptAccounting(), spend = SessionSpend()
            for charge in try SideBudgetRecovery.charges(owner:"main",directory:root) { try accounting.consume(kind:charge.kind,data:charge.data,spend:&spend) }
            assertTotals(replay,accounting:accounting,spend:spend,label:kind)
            XCTAssertEqual(spend.usd,0.6,accuracy:1e-10)
        }
    }

    private func assertTotals(_ replay: JournalReplay, accounting: AttemptAccounting, spend: SessionSpend, label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(spend.usd,replay.spend.usd,accuracy:1e-10,label,file:file,line:line)
        XCTAssertEqual(spend.reported,replay.spend.reported,label,file:file,line:line)
        XCTAssertEqual(spend.unreported,replay.spend.unreported,label,file:file,line:line)
        XCTAssertEqual(accounting.usageTotals,replay.accounting.usageTotals,label,file:file,line:line)
        XCTAssertEqual(accounting.usageReported,replay.accounting.usageReported,label,file:file,line:line)
        XCTAssertEqual(accounting.usageUnknownRequests,replay.accounting.usageUnknownRequests,label,file:file,line:line)
    }

    private func row(_ kind: String, _ data: JSON) -> JSON { ["type":"custom","customType":JSON(kind),"data":data] }
    private func charge(_ attempt: String, source: String = "side", usd: Double, delegation: String? = nil) -> JSON {
        var value: JSON = ["attemptId":JSON(attempt),"sourceSessionId":JSON(source),"budgetOwnerSessionId":"side","purpose":"turn","outcome":"completed","usd":JSON(usd),"reported":1,"unreported":0,"usage":["input":100,"output":20,"total":120]]
        if let delegation { value["delegationId"] = JSON(delegation) }
        return value
    }
    private func writeLegacySide(_ root: URL, keyed: Bool, position: String, adoption: String, seed: String, attemptState: AttemptState = .empty) throws -> URL {
        let file = root.appendingPathComponent("side_side.jsonl")
        let writer = try SessionJournal(url:file,id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
        if adoption == "agentOperation" { try writer.promoteToSteering(managedChild:false) }
        try writer.append(row(JournalRecordKind.sideOrigin,["parentSessionId":"main","relationship":"side"]))
        var prior = SessionSpend()
        if seed != "none" {
            var value: JSON = ["source":JSON(seed),"usd":0.07,"reported":1,"unreported":1]
            if seed == "side-history" { value["sourceSessionId"] = "earlier"; value["budgetOwnerSessionId"] = "earlier" }
            try writer.append(row(JournalRecordKind.cost,value)); prior.add(record:value)
        }
        if position != "after" {
            let value = charge("before",usd:0.2)
            try writer.append(row(JournalRecordKind.cost,keyed ? value : value.removing(["attemptId"]))); prior.add(record:value)
        }
        var adoptionSeed = prior.record; adoptionSeed["reset"] = true; adoptionSeed["source"] = "family-adoption"
        var plan = SubagentPlan(origin:subagentFixtureOrigin(parent:"side"),task:"Side content must stay here",resultMessageID:"result")
        if ["subagentCall","agentOperation"].contains(adoption) { plan.adoptionSeed = adoptionSeed }
        if adoption == "cost" { try writer.append(row(JournalRecordKind.cost,adoptionSeed)) }
        if adoption == "agentOperation" {
            let op = AgentOperation(key:plan.origin.link.call,digest:"fixture",receipt:["accepted":true],plan:plan,epoch:"execution")
            var value = row(JournalRecordKind.agentOperation,try subagentJSON(op)); value["ownerID"] = "side"
            try writer.append(value)
        } else if adoption != "no-delegation" { try writer.append(row(JournalRecordKind.subagentCall,try subagentJSON(plan))) }
        if adoption != "no-delegation" {
            let delegated = charge("delegated",source:"child",usd:0.3,delegation:"delegation")
            var admission = delegated.removing(["usd","reported","unreported","usage","outcome"]); admission["state"] = "dispatched"
            try writer.append(row(JournalRecordKind.budgetAttempt,admission))
            try writer.append(row(JournalRecordKind.cost,delegated))
            // Cold adoption validates the reciprocal child evidence too.
            let child = try SessionJournal(url:root.appendingPathComponent("child.jsonl"),id:"child",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
            try child.append(row(JournalRecordKind.subagentOrigin,try subagentJSON(plan.origin)))
            try child.append(row(JournalRecordKind.cost,delegated),flush:true)
        }
        if position != "before" {
            let value = charge("after",usd:0.1)
            try writer.append(row(JournalRecordKind.cost,keyed ? value : value.removing(["attemptId"])))
        }
        let source = adoption == "no-delegation" ? "side" : "child"
        for value in attemptRows(attemptState,source:source) { try writer.append(value) }
        try writer.synchronize()
        return file
    }
    private enum AttemptState: String, CaseIterable {
        case empty, admitted, dispatched, notDispatched, admittedCancelled, dispatchedCancelled
        case reported, zero, unknown, unknownUsage, reportedNoUsage, reportedInvalidUsage, invalidCost
        case corrected, staleCorrection, reportedMirror, unknownMirror
        var reported: Int {
            switch self {
            case .reported,.zero,.reportedNoUsage,.reportedInvalidUsage,.corrected,.staleCorrection,.reportedMirror: return 1
            default: return 0
            }
        }
        var unreported: Int {
            switch self {
            case .admitted,.dispatched,.unknown,.unknownUsage,.invalidCost,.unknownMirror: return 1
            default: return 0
            }
        }
        var unknownUsage: Int {
            switch self {
            case .admitted,.dispatched,.unknown,.reportedNoUsage,.reportedInvalidUsage,.unknownMirror: return 1
            default: return 0
            }
        }
        var spend: Double {
            switch self {
            case .reported, .reportedNoUsage, .reportedInvalidUsage, .corrected, .staleCorrection, .reportedMirror: return 0.4
            default: return 0
            }
        }
    }
    private func attemptRows(_ state: AttemptState, source: String = "side") -> [JSON] {
        guard state != .empty else { return [] }
        var cost = charge("state-attempt",source:source,usd:0.4,delegation:source == "child" ? "delegation" : nil)
        cost["accountingRevision"] = 10
        var admission = cost.removing(["usd","reported","unreported","usage","outcome"])
        admission["state"] = "admitted"
        if source == "side" {
            admission["scope"] = ["sourceSessionID":"side","budgetOwnerSessionID":"side","turnID":"turn", "executionID":"execution","purpose":"turn","ownerGeneration":0]
        }
        var rows: [JSON] = []
        if ![.reportedMirror,.unknownMirror].contains(state) { rows.append(row(JournalRecordKind.budgetAttempt,admission)) }
        if state == .admitted { return rows }
        if state != .admittedCancelled && ![.reportedMirror,.unknownMirror,.notDispatched].contains(state) {
            admission["state"] = "dispatched"; rows.append(row(JournalRecordKind.budgetAttempt,admission))
        }
        if state == .dispatched { return rows }
        if [.notDispatched,.admittedCancelled,.dispatchedCancelled].contains(state) {
            admission["state"] = "not_dispatched"
            if state == .notDispatched { rows = [] }
            rows.append(row(JournalRecordKind.budgetAttempt,admission)); return rows
        }
        if state == .zero { cost["usd"] = 0 }
        if [.unknown,.unknownUsage,.unknownMirror,.corrected,.staleCorrection].contains(state) {
            cost["usd"] = 0; cost["reported"] = 0; cost["unreported"] = 1
        }
        if [.unknown,.unknownMirror,.reportedNoUsage].contains(state) { cost = cost.removing(["usage"]) }
        if state == .reportedInvalidUsage { cost["usage"] = ["input":.null,"output":-1,"unsupported":999] }
        if state == .invalidCost { cost["usd"] = -1 }
        rows.append(row(JournalRecordKind.cost,cost))
        if [.corrected,.staleCorrection].contains(state) {
            var corrected = cost; corrected["usd"] = 0.4; corrected["reported"] = 1; corrected["unreported"] = 0; corrected["accountingRevision"] = 11
            rows.append(row(JournalRecordKind.costUpdate,corrected))
            if state == .staleCorrection { rows.append(row(JournalRecordKind.costUpdate,cost)) }
        }
        return rows
    }

    private func replay(_ file: URL, id: String, resume: Bool = false) throws -> JournalReplay {
        let writer = try SessionJournal(url:file,id:id,cwd:file.deletingLastPathComponent(),binding:nil,create:false,checkpoint:resume ? JournalCheckpoint.read(for:file) : nil)
        return try AgentSession.replay(writer,url:file,id:id,binding:fixtureProfile().binding,spendTracked:false,resume:resume)
    }
    private func session(_ id: String, root: URL, path: URL?) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path?.path)
    }
}
