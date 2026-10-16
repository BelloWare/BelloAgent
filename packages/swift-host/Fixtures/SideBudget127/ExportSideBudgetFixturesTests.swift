import XCTest
@testable import PiAgentCore

// Executes the unmodified v0.1.127 production writers with synthetic observations.
final class ExportSideBudgetFixturesTests: XCTestCase {
    func testExport() async throws {
        let output = URL(fileURLWithPath:ProcessInfo.processInfo.environment["SIDE_FIXTURE_OUTPUT"]!)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for usage in ["priced","unpriced","unknown"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let side = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:[],parent:["parentSessionId":"main","relationship":"side"])
            _ = try await side.keepNow()
            var ordinary = billingObservation(profile:try fixtureProfile(),session:"side",attempt:"own",cost:usage == "priced" ? 0.2 : nil)
            if usage != "unknown" { ordinary.fields = ["input":40,"output":10]; ordinary.fieldStatus = ["input":"reported","output":"reported"] }
            await side.countAttempt(ordinary)
            await side.close()
            try FileManager.default.copyItem(at:root.appendingPathComponent("side_side.jsonl"),to:output.appendingPathComponent("count-attempt-\(usage).jsonl"))
            let owner = try AgentSession(id:"owner",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore())
            var observation = billingObservation(profile:try fixtureProfile(),session:"child",attempt:"charged",cost:usage == "priced" ? 0.7 : nil)
            if usage != "unknown" { observation.fields = ["input":100,"output":20]; observation.fieldStatus = ["input":"reported","output":"reported"] }
            let cost = await owner.contribution(observation,owner:"side",delegation:"delegation")
            try await owner.appendAccounting(kind:JournalRecordKind.cost,data:cost)
            await owner.close()
            try FileManager.default.copyItem(at:root.appendingPathComponent("owner.jsonl"),to:output.appendingPathComponent("pre-scope-\(usage).jsonl"))
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try AgentSession(id:"owner",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore())
        let seed = await owner.exportSeed()
        let writer = try SessionJournal(url:output.appendingPathComponent("pre-cost.jsonl"),id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
        try writer.append(seed,flush:true)
        let origin = subagentFixtureOrigin(parent:"side")
        let child = try SessionJournal(url:output.appendingPathComponent("v3-origin.jsonl"),id:"child",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
        try child.promoteToSteering(managedChild:true)
        try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":try subagentJSON(origin)],flush:true)
        await owner.close()
    }
}
extension AgentSession {
    func exportSeed() -> JSON { spend = SessionSpend(usd:0.2,reported:1); return carriedSpendRecord() }
}
