import XCTest
@testable import PiAgentCore

private actor DeltaClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var pending: [ModelReply] = []
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func finish(_ value: ModelReply) { pending.append(value) }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while pending.isEmpty { try await Task.sleep(nanoseconds: 500_000) }
        callback = nil
        return pending.removeFirst()
    }
}

/// The row-update wire contract: a reader that opts in and stays in step is
/// sent only what changed; everything else still gets a whole page, and what
/// the reader assembles is exactly what a whole page would have said.
final class MessageDeltaTests: XCTestCase {
    private func history(count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            var message = ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", content: [textBlock("Row \(index): " + String(repeating: "y", count: 512))])
            message.id = "message-\(index)"
            return message
        }
    }
    private func session(root: URL, id: String, seed: [ChatMessage], client: any ModelClient = ScriptClient([])) throws -> AgentSession {
        var profile = try fixtureProfile().raw; profile["contextWindow"] = 1_000_000
        return try AgentSession(id: id, profile: Profile(profile), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), seed: seed, autoCompaction: false)
    }

    func testReaderThatDoesNotOptInAlwaysReceivesTheWholePage() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root: root, id: "legacy", seed: history(count: 8), client: ScriptClient([answer("Reply")]))
        addTeardownBlock { await session.close() }
        let first = await session.snapshot()
        XCTAssertFalse(first["messages"].isNull); XCTAssertTrue(first["messageDelta"].isNull)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let second = await session.snapshot(["displayRevision": first["displayRevision"]])
        XCTAssertTrue(second["messageDelta"].isNull, "Row updates are opt-in; nothing must appear unasked")
        XCTAssertEqual(second["messages"].list.count, 6, "Without the opt-in the full current three-turn page is the answer")
        XCTAssertEqual(second["messages"].list.first?["id"].text, "message-4")
        XCTAssertEqual(second["messages"].list.last?["text"].text, "Reply")
    }

    func testFirstReadAndAnyOutOfStepReadAreWholePages() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root: root, id: "resync", seed: history(count: 8), client: ScriptClient([answer("First"), answer("Second")]))
        addTeardownBlock { await session.close() }
        let first = await session.snapshot(["messageDelta": true])
        XCTAssertFalse(first["messages"].isNull, "The first read has nothing to update")
        XCTAssertTrue(first["messageDelta"].isNull)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "Question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let stale = await session.snapshot(["displayRevision": "someone-elses:7", "messageDelta": true])
        XCTAssertFalse(stale["messages"].isNull, "A revision this session never sent must resync the whole page")
        XCTAssertTrue(stale["messageDelta"].isNull)
        _ = try await session.submit(Submission(commandID: "c2", turnID: "t2", text: "Again"), steer: false)
        try await eventually { !(await session.isRunning) }
        let stepped = await session.snapshot(["displayRevision": stale["displayRevision"], "messageDelta": true])
        XCTAssertTrue(stepped["messages"].isNull, "A reader in step is sent updates, not the page")
        XCTAssertEqual(stepped["messageDelta"]["base"].text, stale["displayRevision"].text)
        XCTAssertEqual(stepped["messageDelta"]["rows"].list.count, 2, "Only the new user row and its reply")
        var page = Page(stale["messages"].list)
        XCTAssertTrue(page.apply(stepped["messageDelta"]))
        let whole = await session.snapshot()
        XCTAssertEqual(JSON.array(page.rows), .array(whole["messages"].list))
    }

    func testAppliedUpdatesRebuildExactlyTheWholePageThroughAToolTurn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DeltaClient()
        let session = try session(root: root, id: "tools", seed: history(count: 6), client: client)
        addTeardownBlock { await session.close() }
        let first = await session.snapshot(["messageDelta": true])
        var page = Page(first["messages"].list)
        var revision = first["displayRevision"]
        func step(file: StaticString = #filePath, line: UInt = #line) async {
            let next = await session.snapshot(["displayRevision": revision, "messageDelta": true])
            revision = next["displayRevision"]
            if !next["messageDelta"].isNull { XCTAssertTrue(page.apply(next["messageDelta"]), file: file, line: line) }
            else if !next["messages"].isNull { page = Page(next["messages"].list) }
        }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Question"), steer: false)
        try await eventually { await client.ready }
        await step()
        try await client.emit(.thinking("Considering"))
        await step()
        try await client.emit(.text("Partial "))
        await step()
        try await client.emit(.tool("call-1", "first", "{\"path\":\"a\"}"))
        await step()
        try await client.emit(.text("answer"))
        await step()
        var reply = ChatMessage(role: "assistant", content: [textBlock("Partial answer"), ["type": "toolCall", "id": "call-1", "name": "first", "arguments": ["path": "a"]]])
        reply.id = "settled-reply"
        await client.finish(ModelReply(message: reply, calls: [ToolCall(id: "call-1", name: "first", arguments: ["path": JSON("a")])], usage: ["input": 10, "output": 2]))
        await client.finish(answer("Done"))
        // Keep reading the way the app does while the tool runs and the second
        // request streams: the row that owns the call changes after it was
        // already sent, and the result row arrives beneath it.
        for _ in 0..<200 {
            await step()
            if !(await session.isRunning) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await eventually { !(await session.isRunning) }
        await step()
        let whole = await session.snapshot()
        XCTAssertEqual(JSON.array(page.rows), .array(whole["messages"].list),
                       "Row updates must reconstruct the same page a whole read returns")
    }

    func testARunBatchesItsJournalFlushesAndStillRecoversEveryRecord() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root)
        let client = ScriptClient([toolReply(["first", "second"]), answer("Done")])
        let session = try AgentSession(id: "batched", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        let idleAppends = await session.journalAppendCount, idleSyncs = await session.journalSynchronizationCount
        XCTAssertEqual(idleAppends, idleSyncs, "An idle session forces every record it writes")
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let appends = await session.journalAppendCount, syncs = await session.journalSynchronizationCount
        print("PERF journal-turn appends=\(appends) fsyncs=\(syncs) idleAppends=\(idleAppends)")
        XCTAssertGreaterThan(appends, syncs, "A run's records must share one flush, not one each")
        XCTAssertEqual(syncs, idleSyncs + 3, "Admission, the durable task-terminal receipt, and idle state each flush once; tool presentation records add no flushes")
        let stored = await session.path
        let path = try XCTUnwrap(stored)
        let before = await session.snapshot()
        await session.close()
        let reopened = try AgentSession(id: "batched", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path, autoCompaction: false)
        addTeardownBlock { await reopened.close() }
        let after = await reopened.snapshot()
        XCTAssertEqual(after["messages"], before["messages"], "Batched flushes must still recover the whole turn")
        XCTAssertEqual(after["total"], before["total"])
    }
}
