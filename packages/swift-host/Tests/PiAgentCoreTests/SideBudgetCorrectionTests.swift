import XCTest
@testable import PiAgentCore

final class SideBudgetCorrectionTests: XCTestCase {
    func testDiskMirrorsUseActualOwnershipAndLeaveLoadedForkAndForeignJournalsUntouched() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let side = try fixture(root,id:"side"), foreign = try fixture(root,id:"foreign",parent:"elsewhere")
        let fork = try fixture(root,id:"fork",relationship:"fork")
        let files = [side,foreign,fork], before = try files.map { try Data(contentsOf:$0) }
        let costs = ["side","foreign","fork"].map { cost(owner:$0) }
        try SideBudgetRecovery.mirrorCapturedCosts(costs,owner:"main",directory:root,loaded:["side"])
        XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before)
        try SideBudgetRecovery.mirrorCapturedCosts(costs,owner:"main",directory:root,loaded:[])
        XCTAssertEqual(try spend(side,id:"side").usd,0.7)
        XCTAssertEqual(try Data(contentsOf:foreign),before[1]); XCTAssertEqual(try Data(contentsOf:fork),before[2])
    }

    func testCorrectionCannotChangeTheRecordedSourceIdentity() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = try fixture(root,id:"side"), before = try Data(contentsOf:file)
        var forged = cost(owner:"side"); forged["sourceSessionId"] = "foreign"
        XCTAssertThrowsError(try SideBudgetRecovery.mirrorCapturedCosts([forged],owner:"main",directory:root,loaded:[])) {
            XCTAssertEqual(($0 as? AgentError)?.code,"accounting_damaged")
        }
        XCTAssertEqual(try Data(contentsOf:file),before)
    }

    func testFailedChildMirrorRetriesAfterTheSideCorrectionHasCommitted() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let side = try fixture(root,id:"side",managed:true), childURL = root.appendingPathComponent("child.jsonl")
        let correction = cost(owner:"side",managed:true)
        do {
            let childWriter = try SessionJournal(url:childURL,id:"child",cwd:root,binding:nil,create:false)
            XCTAssertThrowsError(try SideBudgetRecovery.mirrorCapturedCosts([correction],owner:"main",directory:root,loaded:[])) {
                XCTAssertEqual(($0 as? AgentError)?.code,"session_locked")
            }
            XCTAssertEqual(try spend(side,id:"side").usd,0.7,"Owner-first commit survives a failed mirror")
            withExtendedLifetime(childWriter) { }
        }
        for _ in 0..<2 { try SideBudgetRecovery.mirrorCapturedCosts([correction],owner:"main",directory:root,loaded:[]) }
        for (file,id) in [(side,"side"),(childURL,"child")] {
            let total = try spend(file,id:id)
            XCTAssertEqual(total.usd,0.7); XCTAssertEqual(total.reported,1); XCTAssertEqual(total.unreported,0)
        }
    }

    func testDiscardedSidesAreNeverRecreatedAndSymlinksCannotEscapeTheWorkspace() throws {
        let root = try temporaryDirectory(), external = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:external) }
        let discarded = try fixture(root,id:"side"); try FileManager.default.removeItem(at:discarded)
        let outside = try fixture(external,id:"outside"), before = try Data(contentsOf:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("side_outside.jsonl"),withDestinationURL:outside)
        try SideBudgetRecovery.mirrorCapturedCosts([cost(owner:"side"),cost(owner:"outside")],owner:"main",directory:root,loaded:[])
        XCTAssertFalse(FileManager.default.fileExists(atPath:discarded.path))
        XCTAssertEqual(try Data(contentsOf:outside),before)
    }

    private func cost(owner: String, managed: Bool = false) -> JSON {
        var value: JSON = ["attemptId":"attempt","sourceSessionId":JSON(managed ? "child" : owner),"budgetOwnerSessionId":JSON(owner),"sideParents":["main"],"purpose":"turn","outcome":"completed","usd":0.7,"reported":1,"unreported":0,"usage":["input":100,"output":20],"accountingRevision":10]
        if managed { value["delegationId"] = "delegation" }
        return value
    }
    private func fixture(_ root: URL, id: String, parent: String = "main", relationship: String = "side", managed: Bool = false) throws -> URL {
        let file = root.appendingPathComponent("side_" + id + ".jsonl")
        let writer = try SessionJournal(url:file,id:id,cwd:root,binding:fixtureProfile().binding,create:true)
        try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":["parentSessionId":JSON(parent),"relationship":JSON(relationship)]])
        var unknown = cost(owner:id,managed:managed); unknown["reported"] = 0; unknown["unreported"] = 1; unknown["usd"] = 0; unknown["usage"] = [:]; unknown["accountingRevision"] = 1
        var admission = unknown.removing(["usd","reported","unreported","usage","outcome"]); admission["state"] = "dispatched"
        if managed {
            let origin = subagentFixtureOrigin(parent:id), plan = SubagentPlan(origin:origin,task:"Private side content",resultMessageID:"result")
            try writer.append(["type":"custom","customType":JSON(JournalRecordKind.subagentCall),"data":try subagentJSON(plan)])
            let child = try SessionJournal(url:root.appendingPathComponent("child.jsonl"),id:"child",cwd:root,binding:fixtureProfile().binding,create:true,managedChild:true)
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":try subagentJSON(origin)])
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":unknown])
        }
        try writer.append(["type":"custom","customType":JSON(JournalRecordKind.budgetAttempt),"data":admission])
        try writer.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":unknown],flush:true)
        return file
    }
    private func spend(_ file: URL, id: String) throws -> SessionSpend {
        let journal = try SessionJournal(url:file,id:id,cwd:file.deletingLastPathComponent(),binding:nil,create:false)
        return try AgentSession.replay(journal,url:file,id:id,binding:fixtureProfile().binding,spendTracked:false,resume:false).spend
    }
}
