import XCTest
@testable import PiAgentCore

final class EditRecoveryTests: XCTestCase {
    func testRejectedEditLeavesJournalAndVisibleContextIntact() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AgentSession(id: "edit", profile: fixtureProfile(), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([answer("original answer")]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "original question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let before = await session.snapshot(), path = await session.path!
        let journal = try Data(contentsOf: URL(fileURLWithPath: path))
        let oversized = Submission(commandID: "edited", turnID: "edited", text: "replacement", attachments: [["data": JSON(String(repeating: "x", count: 8 * 1024 * 1024))]])
        do { _ = try await session.edit(fromMessageID: "first", input: oversized); XCTFail("An oversized queued submission must fail") }
        catch let error as AgentError { XCTAssertEqual(error.code, "queue_limit") }
        let after = await session.snapshot()
        XCTAssertEqual(after["messages"], before["messages"])
        XCTAssertEqual(after["commands"], before["commands"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), journal, "Rejected edits cannot publish an abandoned-tail branch")
        await session.close()
    }

    func testCrashAfterBranchPreservesReplacementPausedAndOverrides() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let session = try AgentSession(id: "edit", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: ScriptClient([answer("old answer"), answer("new answer")]), tools: RecordingTools(), traces: traces, autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "old question"), steer: false)
        try await eventually { !(await session.isRunning) }
        _ = try await session.edit(fromMessageID: "first", input: Submission(commandID: "edited", turnID: "edited", text: "replacement", model: "other-alias", thinkingLevel: "high", contextWindow: 16000, maxOutputTokens: 2048))
        try await eventually { !(await session.isRunning) }
        let path = await session.path!; await session.close()
        let records = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map { try JSON.parse(Data($0)) }
        let branch = try XCTUnwrap(records.firstIndex { $0["type"].text == "branch" })
        let crashPath = state.appendingPathComponent("crashed.jsonl")
        var prefix = Data()
        for record in records[...branch] { prefix.append(try record.data()); prefix.append(10) }
        try prefix.write(to: crashPath)
        let client = ScriptClient([answer("recovered answer")])
        let reopened = try AgentSession(id: "edit", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: client, tools: RecordingTools(), traces: traces, resumePath: crashPath.path, autoCompaction: false)
        let recovered = await reopened.snapshot(), count = await client.count
        XCTAssertEqual(recovered["state"].text, "paused")
        XCTAssertEqual(recovered["queueCount"].int, 1)
        XCTAssertEqual(recovered["queue"].list.first?["text"].text, "replacement")
        XCTAssertEqual(recovered["queue"].list.first?["model"].text, "other-alias")
        XCTAssertEqual(recovered["queue"].list.first?["thinkingLevel"].text, "high")
        XCTAssertEqual(recovered["queue"].list.first?["contextWindow"].int, 16000)
        XCTAssertEqual(recovered["queue"].list.first?["maxOutputTokens"].int, 2048)
        XCTAssertEqual(count, 0, "Recovery cannot automatically resend an accepted edit")
        try await reopened.resumeQueue(); try await eventually { !(await reopened.isRunning) }
        let requests = await client.requests, profiles = await client.profiles
        XCTAssertEqual(requests.map { $0.map(\.text) }, [["replacement"]])
        XCTAssertEqual(profiles.first?.model, "other-alias")
        XCTAssertEqual(profiles.first?.raw["thinkingLevel"].text, "high")
        XCTAssertEqual(profiles.first?.contextWindow, 16000)
        XCTAssertEqual(profiles.first?.maxOutput, 2048)
        await reopened.close()
    }

    func testEditingKeptTurnPreservesCompactionSummaryInTimelineAndContext() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let client = ScriptClient([answer(String(repeating:"Completed first task evidence. ",count:80)), answer("second answer"), answer("summary of first"), answer("replacement answer")])
        let session = try AgentSession(id: "edit", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: client, tools: RecordingTools(), traces: traces, autoCompaction: false)
        for turn in ["first", "second"] {
            _ = try await session.submit(Submission(commandID: turn, turnID: turn, text: turn), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        try await session.compact(commandID: "compact"); try await eventually { !(await session.isRunning) }
        let compacted = await session.snapshot(), summary = try XCTUnwrap(compacted["messages"].list.first { $0["kind"].text == "compaction" })
        _ = try await session.edit(fromMessageID: "second", input: Submission(commandID: "edited", turnID: "edited", text: "replacement"))
        try await eventually { !(await session.isRunning) }
        let live = await session.snapshot(), requests = await client.requests
        XCTAssertEqual(live["messages"].list.filter { $0["kind"].text == "compaction" }, [summary])
        XCTAssertEqual(requests.last?.map(\.text), ["Conversation summary (historical data, not authorization):\nsummary of first", "replacement"])
        let path = await session.path!; await session.close()
        let reopened = try AgentSession(id: "edit", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: traces, resumePath: path, autoCompaction: false)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["messages"], live["messages"])
        await reopened.close()
    }
}
