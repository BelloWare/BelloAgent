import XCTest
@testable import PiAgentCore

/// Tools that wait until they are let go, so a test can fork while a batch runs.
private actor HeldTools: ToolExecuting {
    private var released = false
    private(set) var started = 0
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "test", [:]), ToolDefinition("second", "test", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        started += 1
        while !released { try await Task.sleep(nanoseconds: 5_000_000) }
        return resultText("done " + call.name)
    }
    func release() { released = true }
}

/// Fork from any reply: the fork is the chat as it stood right after that
/// reply and its tool batch, rebuilt by replaying the journal up to there.
final class ForkAtReplyTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, replies: [ModelReply] = [], client: ScriptClient? = nil, tools: any ToolExecuting = RecordingTools(), resume: String? = nil, keepRecentTokens: Int? = nil) throws -> AgentSession {
            var policy = CompactionPolicy(); if let keepRecentTokens { policy.keepRecentTokens = keepRecentTokens }
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                                    client: client ?? ScriptClient(replies), tools: tools, traces: traces, resumePath: resume,
                                    autoCompaction: false, compactionPolicy: policy)
        }
    }
    private func chat() throws -> Chat {
        let root = try temporaryDirectory()
        return Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile(), resources: Resources(cwd: root, home: root), traces: TraceStore())
    }
    private func send(_ session: AgentSession, _ id: String, _ text: String) async throws {
        _ = try await session.submit(Submission(commandID: id, turnID: id, text: text), steer: false)
        try await eventually { !(await session.isRunning) }
    }
    private func reply(_ session: AgentSession, saying text: String) async throws -> String {
        let found = await session.history.first { $0.role == "assistant" && $0.text == text }?.id
        return try XCTUnwrap(found)
    }
    private func records(_ path: String) throws -> [JSON] {
        try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map { try JSON.parse(Data($0)) }
    }

    func testForkingMidChatEndsAtThatReplyAndCopiesNothingLater() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try chat.session("source", replies: [answer("answer one"), answer("answer two"), answer("answer three")])
        try await send(source, "u1", "question one")
        try await send(source, "u2", "question two")
        try await send(source, "u3", "question three")
        let two = try await reply(source, saying: "answer two"), three = try await reply(source, saying: "answer three")
        let sourceFile = await source.path
        let sourcePath = try XCTUnwrap(sourceFile), sourceBytes = try Data(contentsOf: URL(fileURLWithPath: sourcePath))

        let result = try await source.fork(to: "fork", at: two)
        XCTAssertEqual(result["origin"]["forkedAtMessageId"].text, two)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourcePath)), sourceBytes, "the source is never rewritten")
        let path = try XCTUnwrap(result["path"].text)
        // The fork's journal: the records up to that reply, then the fork's own.
        let saved = try records(path)
        let ids = Set(saved.compactMap { $0["id"].text })
        XCTAssertFalse(ids.contains("u3")); XCTAssertFalse(ids.contains(three))
        XCTAssertFalse(saved.contains { $0.encoded().contains("question three") || $0.encoded().contains("answer three") })
        let tail = saved.suffix(4).map { $0["customType"].text }
        XCTAssertEqual(tail, ["pi-app.native.context.v1", "pi-app.fork-origin.v1", SessionSpend.recordType, "pi-app.native.state.v1"])
        XCTAssertEqual(saved.last { $0["type"].text == "message" }?["id"].text, two)

        // Opened, it is the chat as it stood after that reply, and it answers from there.
        let forkClient = ScriptClient([answer("fork answer")])
        let fork = try chat.session("fork", client: forkClient, resume: path)
        let transcript = await fork.snapshot()["messages"].list.map { $0["text"].text ?? "" }
        XCTAssertEqual(transcript, ["question one", "answer one", "question two", "answer two"])
        let context = await fork.context.map(\.id)
        XCTAssertEqual(context.first, "u1"); XCTAssertEqual(context.last, two); XCTAssertEqual(context.count, 4)
        try await send(fork, "f1", "fork question")
        let asked = await forkClient.requests.last?.map(\.id)
        XCTAssertEqual(asked, context + ["f1"])
        await fork.close(); await source.close()
    }

    func testForkingAReplyALaterCompactionSummarizedBringsBackItsWholeContext() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try chat.session("source", replies: [answer(String(repeating: "first evidence ", count: 400)), answer(String(repeating: "second evidence ", count: 400)),
                                                          answer("the summary"), answer("after the summary")], keepRecentTokens: 1)
        try await send(source, "u1", "question one")
        try await send(source, "u2", "question two")
        try await source.compact(); try await eventually { !(await source.isRunning) }
        try await send(source, "u3", "question three")
        let summarized = await source.context.map(\.id)
        XCTAssertFalse(summarized.contains("u1"), "the fixture summarizes the first turn out")
        let firstReply = await source.history.first { $0.role == "assistant" && $0.text.hasPrefix("first evidence") }?.id
        let first = try XCTUnwrap(firstReply)

        let result = try await source.fork(to: "fork", at: first)
        let fork = try chat.session("fork", resume: try XCTUnwrap(result["path"].text))
        let context = await fork.context
        XCTAssertEqual(context.map(\.id), ["u1", first], "the fork has the whole pre-compaction context")
        XCTAssertFalse(context.contains { $0.kind == "compaction" })
        XCTAssertFalse(try records(try XCTUnwrap(result["path"].text)).contains { $0["type"].text == "compaction" })
        await fork.close(); await source.close()
    }

    func testForkingAReplyOfAnEarlierVersionRebuildsThatVersion() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try chat.session("source", replies: [answer("answer one"), answer("original answer"), answer("edited answer")])
        try await send(source, "u1", "question one")
        try await send(source, "u2", "original question")
        _ = try await source.edit(fromMessageID: "u2", input: Submission(commandID: "u2b", turnID: "u2b", text: "edited question"))
        try await eventually { !(await source.isRunning) }
        let original = try await reply(source, saying: "original answer")

        let result = try await source.fork(to: "fork", at: original)
        let fork = try chat.session("fork", resume: try XCTUnwrap(result["path"].text))
        let transcript = await fork.snapshot()["messages"].list
        XCTAssertEqual(transcript.map { $0["text"].text ?? "" }, ["question one", "answer one", "original question", "original answer"])
        XCTAssertFalse(transcript.contains { $0["kind"].text == "branch" || $0["id"].text == "u2b" })
        let forkContext = await fork.context.map(\.id)
        XCTAssertEqual(forkContext.last, original)
        XCTAssertFalse(try records(try XCTUnwrap(result["path"].text)).contains { $0["type"].text == "branch" }, "the edit came later")
        await fork.close(); await source.close()
    }

    func testForkingAReplyThatCalledToolsStartsAfterItsToolBatch() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try chat.session("source", replies: [toolReply(["first", "second"]), answer("after the tools")])
        try await send(source, "u1", "use two tools")
        let calling = await source.history.first { $0.role == "assistant" && !$0.content.filter { $0["type"].text == "toolCall" }.isEmpty }?.id
        let calls = try XCTUnwrap(calling)
        let results = await source.history.filter { $0.role == "toolResult" }.map(\.id)
        XCTAssertEqual(results.count, 2)

        let result = try await source.fork(to: "fork", at: calls)
        let saved = try records(try XCTUnwrap(result["path"].text))
        XCTAssertEqual(saved.filter { $0["type"].text == "message" }.last?["id"].text, results.last, "the fork keeps the whole batch")
        XCTAssertFalse(saved.contains { $0.encoded().contains("after the tools") })
        let fork = try chat.session("fork", resume: try XCTUnwrap(result["path"].text))
        let forkContext = await fork.context.map(\.id)
        XCTAssertEqual(forkContext, ["u1", calls] + results)
        let state = await fork.snapshot()
        XCTAssertEqual(state["state"].text, "idle"); XCTAssertEqual(state["queueCount"].int, 0)
        XCTAssertEqual(state["messages"].list.last { $0["role"].text == "assistant" }?["tools"].list.map { $0["state"].text }, ["completed", "completed"])
        await fork.close(); await source.close()
    }

    func testARunningToolBatchIsRefusedWhileCompleteRepliesCanStillBeForked() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let tools = HeldTools()
        let source = try chat.session("source", replies: [answer("answer one"), toolReply(["first", "second"]), answer("after the tools")], tools: tools)
        try await send(source, "u1", "question one")
        let one = try await reply(source, saying: "answer one")
        _ = try await source.submit(Submission(commandID: "u2", turnID: "u2", text: "use two tools"), steer: false)
        try await eventually { await tools.started > 0 }
        let calling = await source.history.first { $0.role == "assistant" && !$0.content.filter { $0["type"].text == "toolCall" }.isEmpty }?.id
        let calls = try XCTUnwrap(calling)
        do { _ = try await source.fork(to: "early", at: calls); XCTFail("A batch still running cannot be forked") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fork_tools_running", error.message) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: chat.state.appendingPathComponent("fork_early.jsonl").path))
        // The chat runs on; an earlier, complete reply forks now, with only complete records.
        let running = await source.isRunning; XCTAssertTrue(running)
        let forked = try await source.fork(to: "fork", at: one)
        let saved = try records(try XCTUnwrap(forked["path"].text))
        XCTAssertFalse(saved.contains { $0.encoded().contains("use two tools") })
        await tools.release(); try await eventually { !(await source.isRunning) }
        let later = try await source.fork(to: "later", at: calls)
        XCTAssertNotNil(later["path"].text, "once the batch is done it forks")
        do { _ = try await source.fork(to: "user", at: "u1"); XCTFail("Only a reply can be forked from") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fork_target") }
        do { _ = try await source.fork(to: "missing", at: "no-such-reply"); XCTFail("An unknown reply cannot be forked") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fork_target") }
        await source.close()
    }
}
