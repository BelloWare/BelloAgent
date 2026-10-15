import XCTest
@testable import PiAgentCore

final class SideBudgetReplayTests: XCTestCase {
    // Exhaustive, deterministic products of the historical ledger shapes.
    // Compare the public recovery paths, not a second copy of their reducer.
    func testLegacyShapesHaveIdenticalReplayAndRecoveryTotalsBeforeAndAfterOrphaning() throws {
        var cases = 0
        for keyed in [false, true] {
            for position in ["before", "after", "both"] {
                for adoption in ["no-delegation", "none", "cost", "subagentCall", "agentOperation"] {
                    for seed in ["none", "app-request-log", "side-history"] {
                        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                        let file = try writeLegacySide(root, keyed:keyed, position:position, adoption:adoption, seed:seed)
                        let parent = root.appendingPathComponent("main.jsonl")
                        do { _ = try SessionJournal(url:parent,id:"main",cwd:root,binding:fixtureProfile().binding,create:true) }
                        for orphan in [false, true] {
                            if orphan { try FileManager.default.removeItem(at:parent) }
                            let label = "keyed=\(keyed) position=\(position) adoption=\(adoption) seed=\(seed) orphan=\(orphan)"
                            let replay = try replay(file, id:"side")
                            var recovered = AttemptAccounting(), spend = SessionSpend()
                            let charges = try SideBudgetRecovery.charges(owner:"main",directory:root)
                            // Scan twice and then bind the normal replay: all
                            // three representations must count the same work once.
                            for _ in 0..<2 {
                                for charge in charges where recovered.attempts[charge["attemptId"].text ?? ""] == nil {
                                    try recovered.consume(kind:JournalRecordKind.cost,data:charge,spend:&spend)
                                }
                            }
                            assertTotals(replay, accounting:recovered, spend:spend, label:label)
                            for entry in replay.accounting.attempts.values {
                                if let cost = entry.contribution, recovered.attempts[cost["attemptId"].text ?? ""] == nil {
                                    try recovered.consume(kind:JournalRecordKind.cost,data:SideBudgetRecovery.charge(cost,side:"side",parents:["main"]),spend:&spend)
                                }
                            }
                            if let seed = SideBudgetRecovery.unkeyedCharge(spend:replay.spend,accounting:replay.accounting,side:"side",parents:["main"]), recovered.attempts[seed["attemptId"].text ?? ""] == nil {
                                try recovered.consume(kind:JournalRecordKind.cost,data:seed,spend:&spend)
                            }
                            assertTotals(replay, accounting:recovered, spend:spend, label:label + " after binding")
                            let expected = (adoption == "no-delegation" ? 0 : 0.3) + (position == "after" ? 0 : 0.2) + (position == "before" ? 0 : 0.1) + (seed == "none" ? 0 : 0.07)
                            XCTAssertEqual(spend.usd,expected,accuracy:1e-10,label)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases,180)
    }

    func testAdoptionBeforeFirstDelegationCountsOnceThroughRealBindAndColdReload() async throws {
        for adoption in ["subagentCall", "agentOperation"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let file = try writeLegacySide(root,keyed:true,position:"before",adoption:adoption,seed:"none")
            let origin = subagentFixtureOrigin(parent:"side")
            do {
                let child = try SessionJournal(url:root.appendingPathComponent("child.jsonl"),id:"child",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
                try child.append(row(JournalRecordKind.subagentOrigin,try subagentJSON(origin)))
                try child.append(row(JournalRecordKind.cost,charge("delegated",source:"child",usd:0.3,delegation:"delegation")))
            }
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
            for charge in try SideBudgetRecovery.charges(owner:"main",directory:root) { try accounting.consume(kind:JournalRecordKind.cost,data:charge,spend:&spend) }
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
    }

    private func row(_ kind: String, _ data: JSON) -> JSON { ["type":"custom","customType":JSON(kind),"data":data] }
    private func charge(_ attempt: String, source: String = "side", usd: Double, delegation: String? = nil) -> JSON {
        var value: JSON = ["attemptId":JSON(attempt),"sourceSessionId":JSON(source),"budgetOwnerSessionId":"side","purpose":"turn","outcome":"completed","usd":JSON(usd),"reported":1,"unreported":0,"usage":["input":100,"output":20,"total":120]]
        if let delegation { value["delegationId"] = JSON(delegation) }
        return value
    }
    private func writeLegacySide(_ root: URL, keyed: Bool, position: String, adoption: String, seed: String) throws -> URL {
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
        }
        if position != "before" {
            let value = charge("after",usd:0.1)
            try writer.append(row(JournalRecordKind.cost,keyed ? value : value.removing(["attemptId"])))
        }
        try writer.synchronize()
        return file
    }
    private func replay(_ file: URL, id: String) throws -> JournalReplay {
        let writer = try SessionJournal(url:file,id:id,cwd:file.deletingLastPathComponent(),binding:nil,create:false)
        return try AgentSession.replay(writer,url:file,id:id,binding:fixtureProfile().binding,spendTracked:false,resume:false)
    }
    private func session(_ id: String, root: URL, path: URL) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:path.path)
    }
}
