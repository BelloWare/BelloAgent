import XCTest
@testable import PiAgentCore

/// A queued message whose explicitly chosen skill changed (or went away)
/// before it was delivered: it is never sent with the old authorization, and
/// never sent on its own. Its skill is pinned to the current file (or taken
/// off), the queue stays paused on a notice naming it (`skill_updated`), and
/// the reader's Resume sends the updated version. A skill that keeps
/// changing says so instead of looping.
final class QueuedSkillRefreshTests: XCTestCase {
    private struct Fixture {
        let root: URL, skill: URL, resources: Resources, session: AgentSession, client: ScriptClient, frozen: [FrozenSkill], selection: JSON
    }

    private func writeSkill(_ folder: URL, description: String, body: String) throws {
        try Data("---\nname: review\ndescription: \(description)\n---\n\(body)".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    }

    /// A chat running its first turn (held), with "skill" (the review skill,
    /// chosen explicitly) and "later" queued behind it.
    private func fixture(replies: [ModelReply], arguments: String = "", text: String = "review this") async throws -> Fixture {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".codex/skills/review"), agents = skill.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try writeSkill(skill, description: "Fixture review", body: "ORIGINAL_SKILL_BODY")
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: agents.appendingPathComponent("openai.yaml"))
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent(".codex").path)], home: root)
        let snapshot = try await resources.resolve(); var selection = try XCTUnwrap(snapshot.skills.first)
        selection["intent"] = "picker"; selection["arguments"] = JSON(arguments)
        let frozen = try await resources.freeze([selection], text: "", tools: [])
        let client = ScriptClient(replies, holdFirst: true)
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "first"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "skill", turnID: "skill", text: text, skills: frozen), steer: false)
        _ = try await session.submit(Submission(commandID: "later", turnID: "later", text: "still pending"), steer: false)
        return Fixture(root: root, skill: skill, resources: resources, session: session, client: client, frozen: frozen, selection: selection)
    }

    private func sent(_ client: ScriptClient) async -> String {
        JSON.array(await client.requests.flatMap { $0.flatMap(\.content) }).encoded()
    }

    func testAChangedSkillIsPinnedToItsCurrentFileAndWaitsForResume() async throws {
        let f = try await fixture(replies: [answer("initial"), answer("reviewed"), answer("later done")])
        // The description is the skill's metadata: a queued selection is
        // checked against it, so this is the change that refuses it.
        try writeSkill(f.skill, description: "Fixture review, revised", body: "UPDATED_SKILL_BODY")
        await f.client.release(); try await eventually { !(await f.session.isRunning) }
        var state = await f.session.snapshot()
        let count = await f.client.count
        XCTAssertEqual(count, 1, "Nothing more was sent on its own")
        XCTAssertEqual(state["state"].text, "error")
        XCTAssertEqual(state["errorCode"].text, "skill_updated")
        XCTAssertEqual(state["preflightError"].text, "\u{201C}review\u{201D} changed after this message was queued. The message now uses the updated version. Press Resume to send it.")
        XCTAssertTrue(state["queuePaused"].flag == true)
        XCTAssertEqual(state["queue"].list.compactMap { $0["turnId"].text }, ["skill", "later"], "Both messages wait, in order")
        // The pin moved with the file: the queued record carries the new body.
        let saved = try String(contentsOf: f.root.appendingPathComponent("state"), encoding: .utf8, recursive: true)
        XCTAssertTrue(saved.contains("UPDATED_SKILL_BODY"), "The queued message holds the current version")

        try await f.session.resumeQueue()
        try await eventually { let count = await f.client.count; let running = await f.session.isRunning; return count == 3 && !running }
        state = await f.session.snapshot()
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].text ?? "")
        let request = await sent(f.client)
        XCTAssertTrue(request.contains("UPDATED_SKILL_BODY"), "Resume sent the updated version")
        XCTAssertFalse(request.contains("ORIGINAL_SKILL_BODY"), "The old version is never sent")
        await f.session.close()
    }

    func testASkillThatIsGoneIsTakenOffAndTheRestWaitsForResume() async throws {
        let f = try await fixture(replies: [answer("initial"), answer("without skill"), answer("later done")])
        try FileManager.default.removeItem(at: f.skill)
        await f.client.release(); try await eventually { !(await f.session.isRunning) }
        let state = await f.session.snapshot()
        let count = await f.client.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state["errorCode"].text, "skill_updated")
        XCTAssertEqual(state["preflightError"].text, "\u{201C}review\u{201D} is no longer available, so it was taken off this queued message. Press Resume to send it.")
        XCTAssertEqual(state["queue"].list.compactMap { $0["turnId"].text }, ["skill", "later"])
        try await f.session.resumeQueue()
        try await eventually { let count = await f.client.count; let running = await f.session.isRunning; return count == 3 && !running }
        let request = await sent(f.client)
        XCTAssertTrue(request.contains("review this"), "The message's text went")
        XCTAssertFalse(request.contains("ORIGINAL_SKILL_BODY"), "Without the skill that is gone")
        await f.session.close()
    }

    /// What the reader wrote for a skill that is gone is not lost with it:
    /// its arguments join the message's text.
    func testAGoneSkillsArgumentsStayInTheMessage() async throws {
        let f = try await fixture(replies: [answer("initial"), answer("without skill"), answer("later done")], arguments: "check the dates", text: "")
        try FileManager.default.removeItem(at: f.skill)
        await f.client.release(); try await eventually { !(await f.session.isRunning) }
        let state = await f.session.snapshot()
        XCTAssertEqual(state["errorCode"].text, "skill_updated", state["preflightError"].text ?? "")
        XCTAssertEqual(state["preflightError"].text, "\u{201C}review\u{201D} is no longer available, so it was taken off this queued message; what you wrote for it is kept in the message. Press Resume to send it.")
        XCTAssertEqual(state["queue"].list.first?["text"].text, "check the dates")
        try await f.session.resumeQueue()
        try await eventually { let count = await f.client.count; let running = await f.session.isRunning; return count == 3 && !running }
        let request = await sent(f.client)
        XCTAssertTrue(request.contains("check the dates")); XCTAssertFalse(request.contains("ORIGINAL_SKILL_BODY"))
        await f.session.close()
    }

    func testAMessageLeftWithNothingToSendStaysRefused() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".codex/skills/review")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try writeSkill(skill, description: "Fixture review", body: "ORIGINAL_SKILL_BODY")
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent(".codex").path)], home: root)
        let resolved = try await resources.resolve(); var selection = try XCTUnwrap(resolved.skills.first); selection["intent"] = "picker"
        let frozen = try await resources.freeze([selection], text: "", tools: [])
        let client = ScriptClient([answer("initial")], holdFirst: true)
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "first"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "skill", turnID: "skill", text: "", skills: frozen), steer: false)
        try FileManager.default.removeItem(at: skill)
        await client.release(); try await eventually { !(await session.isRunning) }
        let state = await session.snapshot()
        XCTAssertEqual(state["errorCode"].text, "skill_revoked")
        XCTAssertEqual(state["preflightError"].text, "\u{201C}review\u{201D} is no longer available, so this queued message has nothing left to send. Remove it from the queue.")
        XCTAssertEqual(state["queue"].list.compactMap { $0["turnId"].text }, ["skill"], "The message is kept for the reader to remove")
        await session.close()
    }

    func testASkillThatKeepsChangingSaysSoAndNeverSendsOnItsOwn() async throws {
        let f = try await fixture(replies: [answer("initial"), answer("reviewed"), answer("later done")])
        try writeSkill(f.skill, description: "Fixture review, revised", body: "SECOND_BODY")
        await f.client.release(); try await eventually { !(await f.session.isRunning) }
        var state = await f.session.snapshot()
        XCTAssertEqual(state["errorCode"].text, "skill_updated")
        // It changes again before Resume: Resume is refused once more, and
        // the notice says the skill is changing rather than repeating itself.
        try writeSkill(f.skill, description: "Fixture review, revised twice", body: "THIRD_BODY")
        try await f.session.resumeQueue()
        try await eventually { !(await f.session.isRunning) }
        state = await f.session.snapshot()
        let count = await f.client.count
        XCTAssertEqual(count, 1, "Nothing was sent")
        XCTAssertEqual(state["errorCode"].text, "skill_updated")
        XCTAssertEqual(state["preflightError"].text, "\u{201C}review\u{201D} changed again after this queued message was updated, so it seems to be changing right now. The message now uses the latest version; press Resume once the skill has stopped changing.")
        XCTAssertTrue(state["queuePaused"].flag == true)
        // Once it settles, Resume sends the latest version.
        try await f.session.resumeQueue()
        try await eventually { let count = await f.client.count; let running = await f.session.isRunning; return count == 3 && !running }
        let request = await sent(f.client)
        XCTAssertTrue(request.contains("THIRD_BODY")); XCTAssertFalse(request.contains("SECOND_BODY")); XCTAssertFalse(request.contains("ORIGINAL_SKILL_BODY"))
        await f.session.close()
    }

    /// The refusal a reader without the app's refresh sees names the skill
    /// and says how to get the current version.
    func testRefusalsNameTheSkillAndSayWhatToDo() async throws {
        let f = try await fixture(replies: [answer("initial")])
        try writeSkill(f.skill, description: "Fixture review", body: "EDITED_BODY")
        do { _ = try await f.resources.freeze([f.selection], text: "", tools: []); XCTFail("A changed skill must not be frozen") }
        catch let error as AgentError {
            XCTAssertEqual(error.code, "skill_changed")
            XCTAssertEqual(error.message, "\u{201C}review\u{201D} changed after you chose it. Choose it again to use the current version.")
        }
        try FileManager.default.removeItem(at: f.skill)
        do { _ = try await f.resources.freeze([f.selection], text: "", tools: []); XCTFail("A missing skill must not be frozen") }
        catch let error as AgentError {
            XCTAssertEqual(error.code, "skill_changed")
            XCTAssertEqual(error.message, "A selected skill is no longer available. Remove it from the message, or choose another.")
        }
        do { try await f.resources.validate(f.frozen); XCTFail("A missing skill must not validate") }
        catch let error as AgentError {
            XCTAssertEqual(error.code, "skill_revoked")
            XCTAssertEqual(error.message, "\u{201C}review\u{201D} changed or was removed after it was chosen. Choose it again to use the current version.")
        }
        await f.client.release(); try await eventually { !(await f.session.isRunning) }
        await f.session.close()
    }
}

private extension String {
    /// Every file under `folder`, read as text and joined.
    init(contentsOf folder: URL, encoding: String.Encoding, recursive: Bool) throws {
        var all = ""
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        for file in files { if let text = try? String(contentsOf: file, encoding: encoding) { all += text } }
        self = all
    }
}
