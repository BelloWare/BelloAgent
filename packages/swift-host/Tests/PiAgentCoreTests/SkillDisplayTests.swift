import XCTest
@testable import PiAgentCore

/// The skills a user message was sent with reach its display row: the app
/// draws them as pills at the start of the message's bubble. The model still
/// receives each skill's expansion ahead of the text, exactly as before.
final class SkillDisplayTests: XCTestCase {
    func testUserRowsCarryTheSkillsTheyWereSentWithLiveAndAfterReopening() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let skillRoot = root.appendingPathComponent(".codex/skills/review"), agents = skillRoot.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("---\nname: review\ndescription: Review the pending diff\n---\nSKILL-BODY-REVIEW".utf8).write(to: skillRoot.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: agents.appendingPathComponent("openai.yaml"))
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent(".codex").path)], home: root)
        let catalog = try await resources.resolve()
        var selection = try XCTUnwrap(catalog.skills.first)
        selection["intent"] = "picker"; selection["arguments"] = "focus on tests"
        let frozen = try await resources.freeze([selection], text: "Check it", tools: [])
        XCTAssertEqual(frozen.first?.description, "Review the pending diff", "What the catalog said is frozen with the selection")
        XCTAssertEqual(frozen.first?.scope, "user"); XCTAssertEqual(frozen.first?.policy, "explicitOnly")

        let client = ScriptClient([answer("done")]), tools = RecordingTools(), traces = TraceStore()
        let state = root.appendingPathComponent("state")
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: state, readOnly: true,
                                       resources: resources, client: client, tools: tools, traces: traces, autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "c", text: "Check it", skills: frozen), steer: false)
        try await eventually { !(await session.isRunning) }
        let live = await session.snapshot()
        let user = try XCTUnwrap(live["messages"].list.first { $0["role"].text == "user" })
        XCTAssertEqual(user["text"].text, "Check it", "The row shows what was typed")
        let skills = user["skills"].list
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills.first?["id"], selection["id"])
        XCTAssertEqual(skills.first?["name"].text, "review")
        XCTAssertEqual(skills.first?["path"], selection["path"])
        XCTAssertEqual(skills.first?["contentHash"], selection["contentHash"], "The version the reply used")
        XCTAssertEqual(skills.first?["metadataHash"], selection["metadataHash"])
        XCTAssertEqual(skills.first?["arguments"].text, "focus on tests")
        XCTAssertEqual(skills.first?["description"].text, "Review the pending diff")
        XCTAssertEqual(skills.first?["scope"].text, "user")
        XCTAssertEqual(skills.first?["policy"].text, "explicitOnly")
        XCTAssertFalse(live["messages"].encoded().contains("SKILL-BODY-REVIEW"), "The skill's body never reaches the display")
        XCTAssertTrue(live["messages"].list.filter { $0["role"].text != "user" }.allSatisfy { $0["skills"].isNull }, "Only a user row carries skills")
        let requests = await client.requests
        let received = try XCTUnwrap(requests.first?.last { $0.role == "user" }?.text)
        XCTAssertTrue(received.hasPrefix("Explicit user skill selection"), "The model received the skill ahead of the text")
        XCTAssertTrue(received.contains("SKILL-BODY-REVIEW")); XCTAssertTrue(received.hasSuffix("Check it"))
        let journalPath = await session.path
        let path = try XCTUnwrap(journalPath)
        await session.close()

        let journal = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(journal.contains("\"description\":\"Review the pending diff\""), "The journal records what the skill was when it was sent")

        let reopened = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: state, readOnly: true,
                                        resources: resources, client: ScriptClient([]), tools: tools, traces: traces, resumePath: path, autoCompaction: false)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["messages"].list.first { $0["role"].text == "user" }?["skills"], user["skills"], "A reopened chat shows the same pills")
        await reopened.close()
    }

    /// A message recorded before 0.1.86 kept each selection's name and path but
    /// not its description; its row still shows the skill, and an entry
    /// without a name is left out rather than shown blank.
    func testOlderRecordsStillShowTheirSkills() {
        var message = ChatMessage(role: "user", content: [textBlock("Explicit user skill selection …\n\nShip it")])
        message.displayText = "Ship it"
        message.userInput = ["version": 1, "attachments": [], "skills": [
            ["id": "id-review", "contentHash": "h", "metadataHash": "m", "arguments": "", "intent": "picker", "name": "review", "path": "/p/review/SKILL.md"],
            ["id": "id-broken"],
        ]]
        let row = message.view()
        XCTAssertEqual(row["text"].text, "Ship it")
        XCTAssertEqual(row["skills"].list.map { $0["name"].text }, ["review"])
        XCTAssertTrue(row["skills"].list.first?["description"].isNull ?? false)
        XCTAssertTrue(ChatMessage(role: "user", content: [textBlock("Plain")]).view()["skills"].isNull, "No skills, no key")
        var none = ChatMessage(role: "user", content: [textBlock("Plain")]); none.userInput = ["version": 1, "attachments": [], "skills": []]
        XCTAssertTrue(none.view()["skills"].isNull)
    }

    /// A queued submission saved before a frozen skill carried its catalog
    /// fields still decodes, and records what it has.
    func testQueueRecordsFromBeforeStillDecode() throws {
        let saved = #"{"id":"i","name":"review","path":"/p","baseDir":"/","body":"b","contentHash":"h","metadataHash":"m","arguments":"x"}"#
        let skill = try JSONDecoder().decode(FrozenSkill.self, from: Data(saved.utf8))
        XCTAssertNil(skill.description); XCTAssertNil(skill.scope); XCTAssertNil(skill.policy)
        XCTAssertEqual(skill.recorded["name"].text, "review")
        XCTAssertTrue(skill.recorded["description"].isNull)
        XCTAssertEqual(skill.selection, ["id": "i", "contentHash": "h", "metadataHash": "m", "arguments": "x", "intent": "picker"],
                       "The selection itself is unchanged")
    }
}
