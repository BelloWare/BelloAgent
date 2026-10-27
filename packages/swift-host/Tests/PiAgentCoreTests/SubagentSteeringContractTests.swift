import XCTest
@testable import PiAgentCore

final class SubagentSteeringContractTests: HelperTestCase {
    func testV3SwitchAndRoleContracts() throws {
        XCTAssertTrue(SubagentPolicy.steeringEnabled)
        XCTAssertTrue(SubagentPolicy.capabilities.contains("subagents-steering-v3"))
        XCTAssertEqual(SubagentSteeringContract.parentNames.count, 5)
        XCTAssertThrowsError(try SubagentSteeringContract.validate("subagent_start", ["task":"x","mode":"background","timeout_ms":1]))
        XCTAssertThrowsError(try SubagentSteeringContract.validate("subagent_wait", ["mode":"one"]))
        XCTAssertThrowsError(try SubagentSteeringContract.validate("subagent_report", ["kind":"question","message":JSON(String(repeating:"😀",count:1025))]))
        XCTAssertThrowsError(try SubagentSteeringContract.validate("subagent_send", ["child_id":"c","message":"x","expected_turn":1.5]))
        XCTAssertNoThrow(try SubagentSteeringContract.validate("subagent_start", ["task":"x","mode":"background","tools":[]]))
        XCTAssertNoThrow(try SubagentSteeringContract.validate("subagent_report", ["kind":"question","message":"Which file?"]))
    }
    func testProductionInstallationOffersV4WithoutFixtureEnablement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                                      readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore())
        let before = await parent.sessionDefinitions()
        XCTAssertTrue(Set(before.map(\.name)).isDisjoint(with: SubagentSteeringContract.parentNames))
        await parent.enableSubagents(SubagentCoordinator())
        let after = await parent.sessionDefinitions()
        XCTAssertTrue(SubagentCodexContract.names.isSubset(of: Set(after.map(\.name))))
        XCTAssertFalse(after.contains { $0.name == "subagent" })
        await parent.close()
    }
    func testPromotionReplacesOnlyMarkerAndPreservesWriterLock() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let profile = try fixtureProfile(), url = root.appendingPathComponent("parent.jsonl")
        var journal: SessionJournal? = try SessionJournal(url:url,id:"parent",cwd:root,binding:profile.binding,create:true)
        try journal!.append(["type":"custom","customType":"fixture","data":["text":"kept"]],id:"original")
        let before = try journal!.recordReader().allRecords()
        try journal!.promoteToSteering(managedChild:false)
        XCTAssertEqual(journal!.markerKind, JournalRecordKind.steeringMarker)
        let after = try journal!.recordReader().allRecords()
        XCTAssertEqual(before.dropFirst(), after.dropFirst())
        XCTAssertEqual(before.first?["id"], after.first?["id"])
        XCTAssertFalse(try String(contentsOf:url).contains("pi-app.native.v1"))
        XCTAssertThrowsError(try SessionJournal(url:url,id:"parent",cwd:root,binding:profile.binding,create:false))
        try journal!.append(["type":"custom","customType":"fixture","data":[:]],id:"later")
        journal = nil
        journal = try SessionJournal(url:url,id:"parent",cwd:root,binding:profile.binding,create:false)
        XCTAssertEqual(journal!.head,"later")
        try journal!.promoteToSteering(managedChild:false)
        XCTAssertEqual(journal!.head,"later")
    }
    func testAgentAuthorSurvivesJournalAndViewWithoutUserAuthority() throws {
        var row = ChatMessage(role:"user",content:[textBlock("discovery")])
        row.nativeAgentDelivery = ["version":1,"author":"subagent","childId":"child","turn":2,"eventIds":["e"]]
        let copy = try ChatMessage(id:row.id,pi:row.pi)
        XCTAssertEqual(copy.nativeAgentDelivery,row.nativeAgentDelivery)
        XCTAssertEqual(copy.view()["nativeAgentDelivery"],row.nativeAgentDelivery)
        XCTAssertNil(copy.userInput)
    }
}
private extension JournalRecordReader {
    func allRecords() throws -> [JSON] { var rows:[JSON]=[]; while let row=try next() { rows.append(row) }; return rows }
}
