import XCTest
@testable import PiAgentCore

/// The legacy data payloads come from executing the tagged helper's writers,
/// not from today's encoders. Only physical IDs/ancestry change per topology.
struct SideBudgetUpgradeFixture {
    enum Shape: CaseIterable { case countAttempt127, preCost, preScope, missingReasoning, current }
    enum Family: CaseIterable {
        case side, nested, agents, nestedAgents
        var nested: Bool { self == .nested || self == .nestedAgents }
        var agents: Bool { self == .agents || self == .nestedAgents }
        var owner: String { nested ? "nested" : "side" }
        var sides: [String] { nested ? ["side","nested"] : ["side"] }
        var parents: [String] { nested ? ["side","main"] : ["main"] }
    }
    enum Usage: String, CaseIterable { case priced, unpriced, unknown }
    enum Crash: CaseIterable { case beforeMain, beforeSide, beforeChild, afterAll }
    enum Operation: CaseIterable {
        case openMain, openSide, reconcile, deleteCold, deleteWithHelper
        var deletes: Bool { self == .deleteCold || self == .deleteWithHelper }
    }
    let root: URL, shape: Shape, family: Family, usage: Usage, crash: Crash
    var source: String { family.agents ? "child" : family.owner }
    var evidence: JSON = .null
    var familyUSD: Double { usage == .priced ? 0.9 : 0.2 }

    static func legacy(_ name: String) throws -> [JSON] {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SideBudget127/" + name + ".jsonl")
        return try String(contentsOf:url,encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }
    }
    static func legacyCost(_ name: String) throws -> JSON {
        try XCTUnwrap(legacy(name).last { $0["customType"].text == JournalRecordKind.cost }?["data"])
    }
    func file(_ id: String) -> URL { root.appendingPathComponent((["side","nested"].contains(id) ? "side_" : "") + id + ".jsonl") }
    func row(_ kind: String, _ data: JSON) -> JSON { ["type":"custom","customType":JSON(kind),"data":data] }

    mutating func write() throws {
        var origin = try JSONDecoder().decode(SubagentOrigin.self,from:Self.legacy("v3-origin").first { $0["customType"].text == JournalRecordKind.subagentOrigin }!["data"].data())
        origin.link.budgetOwnerSessionID = family.owner; origin.link.call.parentSessionID = family.owner
        if shape == .missingReasoning || shape == .current { origin.model.reasoning = ["low","high"] }
        let plan = SubagentPlan(origin:origin,task:"Private fixture task",resultMessageID:"result")
        var scope = RequestScope(sourceSessionID:source,budgetOwnerSessionID:family.owner,turnID:"turn",executionID:"child-execution",purpose:"turn",ownerGeneration:0,delegation:family.agents ? origin.link : nil)
        if shape == .current { scope.sideParents = family.parents }
        if family.agents, shape == .missingReasoning || shape == .current { scope.childTurn = 1; scope.parentExecutionID = "execution" }
        let scopeJSON = try subagentJSON(scope)
        var cost = try Self.legacyCost("pre-scope-" + usage.rawValue)
        cost["sourceSessionId"] = JSON(source); cost["budgetOwnerSessionId"] = JSON(family.owner)
        if !family.agents { cost = cost.removing(["delegationId"]) }
        if shape == .current { cost["scope"] = scopeJSON; cost["sideParents"] = .array(family.parents.map { JSON($0) }) }
        var admission: JSON = ["attemptId":"charged","sourceSessionId":JSON(source),"budgetOwnerSessionId":JSON(family.owner),"purpose":"turn","state":"dispatched","scope":scopeJSON,"accountingRevision":1]
        if family.agents { admission["delegationId"] = "delegation" }
        var own = try Self.legacyCost(shape == .preCost ? "pre-cost" : "count-attempt-priced")
        if shape == .current { own["sourceSessionId"] = JSON(family.owner); own["budgetOwnerSessionId"] = JSON(family.owner) }
        var mainCost = cost; mainCost["sideParents"] = .array(family.parents.map { JSON($0) }); mainCost["accountingRevision"] = 8
        do {
            let main = try SessionJournal(url:file("main"),id:"main",cwd:root,binding:fixtureProfile().binding,create:true)
            if crash != .beforeMain { try main.append(row(JournalRecordKind.cost,mainCost),flush:true) }
            for id in family.sides {
                let side = try SessionJournal(url:file(id),id:id,cwd:root,binding:fixtureProfile().binding,create:true)
                try side.append(row(JournalRecordKind.sideOrigin,["parentSessionId":JSON(id == "side" ? "main" : "side"),"relationship":"side"]))
                if id == family.owner {
                    try side.append(row(JournalRecordKind.cost,own))
                    if family.agents {
                        if shape == .missingReasoning || shape == .current {
                            try side.promoteToSteering(managedChild:false)
                            var message = ChatMessage(role:"assistant",content:[["type":"toolCall","id":"call","name":"subagent_start","arguments":["task":"Private task","mode":"background"]]])
                            message.id = "reply"; try side.append(["type":"message","message":message.pi],id:"reply")
                            let turn = AgentChildTurn(childID:"child",turn:1,executionID:"child-execution",parentExecutionID:"execution",generation:0,runtimeID:"runtime",epoch:"epoch",inputID:"input",task:plan.task,call:origin.link.call)
                            let operation = AgentOperation(key:origin.link.call,digest:"fixture",receipt:["accepted":true],plan:plan,turn:turn,epoch:"epoch")
                            var accepted = row(JournalRecordKind.agentOperation,try subagentJSON(operation)); accepted["ownerID"] = JSON(id)
                            try side.append(accepted)
                        } else { try side.append(row(JournalRecordKind.subagentCall,try subagentJSON(plan))) }
                    }
                    try side.append(row(JournalRecordKind.budgetAttempt,admission))
                    if crash == .beforeChild || crash == .afterAll || crash == .beforeMain && !family.agents {
                        try side.append(row(JournalRecordKind.cost,cost),flush:true)
                    }
                }
            }
            if family.agents {
                let child = try SessionJournal(url:file("child"),id:"child",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
                if shape == .missingReasoning { origin.model.reasoning = nil }
                try child.append(row(JournalRecordKind.subagentOrigin,try subagentJSON(origin)))
                // beforeMain: failed owner append left local fallback evidence.
                // beforeSide: root is the only terminal writer.
                if crash == .beforeMain || crash == .afterAll { try child.append(row(JournalRecordKind.cost,cost),flush:true) }
            }
        }
        evidence = ["attemptId":"charged","sessionId":JSON(source),"turnId":"turn","purpose":"turn","outcome":"completed","requestScope":scopeJSON,"gateway":["cost":["status":usage == .priced ? "reported" : "unreported","usd":usage == .priced ? 0.7 : .null]],"usage":usage == .unknown ? [:] : ["inputIncludingCache":100,"output":20]]
    }
    func host() async throws -> NativeHostService {
        let host = NativeHostService(emit:{ _ in })
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
        return host
    }
    func open(_ host: NativeHostService, _ id: String) async throws -> AgentSession {
        _ = try await host.command("session.open",sessionID:id,params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","path":JSON(file(id).path),"costLimit":["usd":0.5]])
        let session = await host.loadedSession(id); return try XCTUnwrap(session)
    }
    func assertTotals(_ value: JSON, _ label: String, child: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value["spentUSD"].double ?? -1,child ? (usage == .priced ? 0.7 : 0) : familyUSD,accuracy:1e-10,label,file:file,line:line)
        XCTAssertEqual(value["reportedRequests"].int,(child ? 0 : 1) + (usage == .priced ? 1 : 0),label,file:file,line:line)
        XCTAssertEqual(value["unreportedRequests"].int,usage == .priced ? 0 : 1,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["input"].int ?? 0,usage == .unknown ? 0 : 100,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["output"].int ?? 0,usage == .unknown ? 0 : 20,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["reportedFields"]["output"].int ?? 0,usage == .unknown ? 0 : 1,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["reportedFields"]["input"].int ?? 0,usage == .unknown ? 0 : 1,label,file:file,line:line)
        XCTAssertEqual(value["familyUsage"]["unknownRequests"].int,(child ? 0 : 1) + (usage == .unknown ? 1 : 0),label,file:file,line:line)
    }
}
