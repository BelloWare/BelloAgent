import XCTest
@testable import PiAgentCore

/// Queued rewrites carry explicit selections through the same host command as the app.
final class QueueEditSkillTests: HelperTestCase {
    private struct Fixture {
        let root: URL, host: NativeHostService, path: String
        let selections: [JSON]
        func call(_ method: String, _ params: JSON) async throws -> JSON {
            try await host.command(method, sessionID: "queued", params: params)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".codex")
        for name in ["review", "notes"] {
            let folder = home.appendingPathComponent("skills/" + name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: Generated \(name)\n---\nPRIVATE_BODY_\(name)\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }
        let resources = Resources(cwd: root, options: ["codexHome": JSON(home.path)], home: root)
        let snapshot = try await resources.resolve()
        let selections = snapshot.skills.map { value -> JSON in var selected = value; selected["intent"] = "picker"; selected["arguments"] = "original arguments"; return selected }
        let frozen = try await resources.freeze([selections[0]], text: "Question", tools: [])
        let client = ScriptClient([answer("first")], holdFirst: true)
        let session = try AgentSession(id: "queued", profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "First"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "pending", turnID: "pending", text: "Question", skills: frozen, thinkingLevel: "high"), steer: false)
        await session.stop(); await client.release()
        try await eventually { !(await session.isRunning) }
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        await session.close()
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path),
                                                                            "resources": ["codexHome": JSON(home.path)], "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "queued", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "path": JSON(path), "toolMode": "read-only"])
        addTeardownBlock { await host.shutdown() }
        return Fixture(root: root, host: host, path: path, selections: selections)
    }
    private func begin(_ f: Fixture, _ id: String) async throws -> JSON {
        try await f.call("queue.edit.begin", ["turnId": "pending", "editId": JSON(id)])
    }

    func testSaveChangesSkillsAndArgumentsDurablyAndReceiptsCoverTheSelections() async throws {
        let f = try await fixture()
        let opened = try await begin(f, "edit")
        XCTAssertEqual(opened["skills"].list.first?["id"], f.selections[0]["id"])
        XCTAssertFalse(opened["skills"].encoded().contains("PRIVATE_BODY"), "Only selection metadata crosses the wire")
        var selected = f.selections[1]; selected["arguments"] = "中文 dates\u{0}check"
        let saved = try await f.call("queue.edit.save", ["editId": "edit", "text": "Question", "skills": [selected]])
        XCTAssertEqual(saved["outcome"].text, "saved")
        let repeated = try await f.call("queue.edit.save", ["editId": "edit", "text": "Question", "skills": [selected]])
        XCTAssertEqual(repeated["repeated"].flag, true)
        do {
            _ = try await f.call("queue.edit.save", ["editId": "edit", "text": "Question", "skills": [f.selections[0]]])
            XCTFail("Same text with other skills is a different save")
        } catch let error as AgentError { XCTAssertEqual(error.code, "command_conflict") }
        let status = try await f.call("queue.edit.status", ["editId": "edit"])
        XCTAssertNotNil(status["inputDigest"].text)
        XCTAssertEqual(status["textDigest"].text, sha256(Data("Question".utf8)), "Legacy receipt remains text-only")
        await f.host.shutdown()
        let delivery = ScriptClient([answer("changed skills delivered")])
        let reopened = try AgentSession(id: "queued", profile: fixtureProfile(), apiKey: "synthetic", cwd: f.root, directory: f.root.appendingPathComponent("state"), readOnly: true,
                                        resources: Resources(cwd: f.root, options: ["codexHome": JSON(f.root.appendingPathComponent(".codex").path)], home: f.root),
                                        client: delivery, tools: RecordingTools(), traces: TraceStore(), resumePath: f.path, autoCompaction: false)
        let after = try await reopened.beginQueueEdit(turnID: "pending", editID: "check")
        XCTAssertEqual(after["skills"].list.map { $0["id"] }, [selected["id"]])
        XCTAssertEqual(after["skills"].list.first?["arguments"].text, "中文 dates\u{0}check")
        XCTAssertEqual(after["thinkingLevel"].text, "high")
        XCTAssertEqual(after["commandId"].text, "pending"); XCTAssertEqual(after["turnId"].text, "pending")
        let state = await reopened.snapshot()
        XCTAssertEqual(state["queuePaused"].flag, true)
        _ = try await reopened.cancelQueueEdit(editID: "check")
        try await reopened.resumeQueue()
        try await eventually { let count = await delivery.count; let running = await reopened.isRunning; return count > 0 && !running }
        let requests = await delivery.requests
        let sent = requests.flatMap { $0 }.map(\.text).joined(separator: "\n")
        XCTAssertTrue(sent.contains("PRIVATE_BODY_" + (selected["name"].text ?? "")))
        XCTAssertFalse(sent.contains("PRIVATE_BODY_" + (f.selections[0]["name"].text ?? "")))
        XCTAssertTrue(sent.contains("中文 dates\u{0}check"))
        await reopened.close()
    }

    func testInvalidOrStaleSelectionsRefuseWithoutChangingTheMessageOrHold() async throws {
        let f = try await fixture()
        _ = try await begin(f, "edit")
        var stale = f.selections[1]; stale["contentHash"] = "changed"
        var invalidIntent = f.selections[1]; invalidIntent["intent"] = "pasted"
        var largeArguments = f.selections[1]; largeArguments["arguments"] = JSON(String(repeating: "x", count: 16_385))
        for value: JSON in [[stale], [invalidIntent], [largeArguments], [f.selections[1], f.selections[1]], .string("not selections")] {
            let before = try Data(contentsOf: URL(fileURLWithPath: f.path))
            do {
                _ = try await f.call("queue.edit.save", ["editId": "edit", "text": "Unaccepted text", "skills": value])
                XCTFail("Invalid structured skill selection was accepted")
            } catch let error as AgentError { XCTAssertTrue(["skill_changed", "invalid_skills", "invalid_params"].contains(error.code), error.code) }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.path)), before)
            let status = try await f.call("queue.edit.status", ["editId": "edit"])
            XCTAssertEqual(status["state"].text, "active"); XCTAssertEqual(status["text"].text, "Question")
        }
    }

    func testRemovingAllSkillsRequiresOtherInputAndLegacySavesKeepTheirSkills() async throws {
        let f = try await fixture()
        _ = try await begin(f, "edit")
        do {
            _ = try await f.call("queue.edit.save", ["editId": "edit", "text": "", "skills": []])
            XCTFail("Removing the only input must leave the edit open")
        } catch let error as AgentError { XCTAssertEqual(error.code, "empty_message") }
        let legacy = try await f.call("queue.edit.save", ["editId": "edit", "text": "Legacy text save"])
        XCTAssertEqual(legacy["outcome"].text, "saved")
        let check = try await begin(f, "check")
        XCTAssertEqual(check["skills"].list.map { $0["id"] }, [f.selections[0]["id"]])
        _ = try await f.call("queue.edit.save", ["editId": "check", "text": "Without skills", "skills": []])
        let cleared = try await begin(f, "cleared")
        XCTAssertEqual(cleared["skillCount"].int, 0); XCTAssertEqual(cleared["skills"].list.count, 0)
    }
    func testSkillFreezingCannotCrossACancelAndUsesTheCurrentQueuePosition() async throws {
        for cancel in [false, true] {
            let f = try await fixture()
            await f.host.shutdown()
            let tools = HeldSkillSaveTools()
            let session = try AgentSession(id: "queued", profile: fixtureProfile(), apiKey: "synthetic", cwd: f.root, directory: f.root.appendingPathComponent("state"), readOnly: true,
                                           resources: Resources(cwd: f.root, options: ["codexHome": JSON(f.root.appendingPathComponent(".codex").path)], home: f.root),
                                           client: ScriptClient([]), tools: tools, traces: TraceStore(), resumePath: f.path, autoCompaction: false)
            _ = try await session.submit(Submission(commandID: "other", turnID: "other", text: "Other queued input"), steer: false)
            try await session.reorderQueue(["other", "pending"])
            _ = try await session.beginQueueEdit(turnID: "pending", editID: "old")
            let save = Task { try await session.saveQueueEdit(editID: "old", text: "Revised", skills: [f.selections[1]]) }
            try await eventually { await tools.waiting }
            if cancel {
                _ = try await session.cancelQueueEdit(editID: "old")
                _ = try await session.beginQueueEdit(turnID: "pending", editID: "new")
            } else { try await session.removeQueued("other") }
            await tools.release()
            if cancel {
                do { _ = try await save.value; XCTFail("A late freeze cannot replace a cancelled edit") }
                catch let error as AgentError { XCTAssertEqual(error.code, "queue_edit_cancelled") }
                let hold = await session.queueEdit
                XCTAssertEqual(hold?.editID, "new")
                let queue = await session.queue
                XCTAssertEqual(queue.last?.text, "Question")
            } else {
                _ = try await save.value
                let queue = await session.queue
                XCTAssertEqual(queue.map(\.turnID), ["pending"])
                XCTAssertEqual(queue.first?.skills.first?.id, f.selections[1]["id"].text)
            }
            await session.close()
        }
    }

    func testFailedSkillSaveKeepsTheOriginalSkillsAndTheHold() async throws {
        let f = try await fixture()
        await f.host.shutdown()
        let failure = SkillSaveWriteFailure()
        let session = try AgentSession(id: "queued", profile: fixtureProfile(), apiKey: "synthetic", cwd: f.root, directory: f.root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: f.root, options: ["codexHome": JSON(f.root.appendingPathComponent(".codex").path)], home: f.root),
                                       client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: f.path, autoCompaction: false,
                                       beforeJournalAppend: { try failure.check($0) })
        _ = try await session.beginQueueEdit(turnID: "pending", editID: "edit")
        let before = try Data(contentsOf: URL(fileURLWithPath: f.path))
        failure.arm()
        do { _ = try await session.saveQueueEdit(editID: "edit", text: "Revised", skills: [f.selections[1]]); XCTFail("Write refusal must keep input") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fixture_write") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.path)), before)
        let status = try await session.queueEditStatus(editID: "edit")
        XCTAssertEqual(status["state"].text, "active")
        XCTAssertEqual(status["skills"].list.first?["id"], f.selections[0]["id"])
        XCTAssertEqual(status["text"].text, "Question")
        await session.close()
    }

}


private actor HeldSkillSaveTools: ToolExecuting {
    private var held = true
    private(set) var waiting = false
    func release() { held = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [] }
    func capabilityIDs(readOnly: Bool) async -> [String] {
        waiting = true
        while held { try? await Task.sleep(nanoseconds: 1_000_000) }
        return []
    }
    func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON { throw AgentError("fixture", "No tools expected") }
}

private final class SkillSaveWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func check(_ record: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        if armed, record["customType"].text == JournalRecordKind.state { throw AgentError("fixture_write", "Definite write refusal") }
    }
}
