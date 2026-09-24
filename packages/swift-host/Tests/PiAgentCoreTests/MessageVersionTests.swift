import XCTest
@testable import PiAgentCore

/// A reply that names the request it came from, as a gateway reply does.
func attempted(_ reply: ModelReply, _ attempt: String) -> ModelReply {
    var reply = reply; reply.message.requestAttemptIDs = [attempt]; return reply
}

/// Every edit leaves the message it replaced, and the replies that followed
/// it, readable as an earlier version. The versions come from the branch
/// records every edit already writes, so a chat edited before versions were
/// shown reads the same way, and nothing is rewritten.
final class MessageVersionTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String = "chat", replies: [ModelReply] = [], resume: String? = nil, keepRecentTokens: Int? = nil) throws -> AgentSession {
            var policy = CompactionPolicy(); if let keepRecentTokens { policy.keepRecentTokens = keepRecentTokens }
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: true, resources: resources,
                                    client: ScriptClient(replies), tools: RecordingTools(), traces: traces, resumePath: resume,
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
    private func edit(_ session: AgentSession, _ target: String, _ id: String, _ text: String) async throws {
        _ = try await session.edit(fromMessageID: target, input: Submission(commandID: id, turnID: id, text: text))
        try await eventually { !(await session.isRunning) }
    }
    private func texts(_ rows: JSON) -> [String] { rows.list.map { $0["text"].text ?? "" } }

    func testOneEditLeavesTheOriginalAndItsRepliesAsVersionOne() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let session = try chat.session(replies: [attempted(answer("first answer"), "attempt-1"), attempted(answer("original answer"), "attempt-2"),
                                                 attempted(answer("edited answer"), "attempt-3")])
        try await send(session, "u1", "first question")
        try await send(session, "u2", "original question")
        try await edit(session, "u2", "u2b", "edited question")

        let listed = try await session.messageVersions(["messageId": "u2b"])
        XCTAssertEqual(listed["count"].int, 2)
        XCTAssertEqual(listed["current"].int, 2, "the version shown now is the edit")
        XCTAssertEqual(listed["versions"].list.map { $0["messageId"].text }, ["u2", "u2b"])
        XCTAssertEqual(listed["versions"].list.map { $0["live"].flag }, [false, true])
        XCTAssertEqual(listed["versions"].list.first?["text"].text, "original question")
        XCTAssertEqual(listed["versions"].list.first?["turns"].list.compactMap(\.text), ["u2"])
        XCTAssertEqual(listed["versions"].list.first?["requests"].int, 1)
        let byOriginal = try await session.messageVersions(["messageId": "u2"])
        XCTAssertEqual(byOriginal["versions"], listed["versions"], "any version names the same list")
        let plain = try await session.messageVersions(["messageId": "u1"])
        XCTAssertEqual(plain["versions"].list.count, 0, "a message never edited has no versions")

        // The edited message's row says which version it is; others say nothing.
        let rows = await session.snapshot()["messages"].list
        let edited = try XCTUnwrap(rows.first { $0["id"].text == "u2b" })
        XCTAssertEqual(edited["versions"]["index"].int, 2); XCTAssertEqual(edited["versions"]["count"].int, 2)
        XCTAssertEqual(edited["versions"]["ids"].list.compactMap(\.text), ["u2", "u2b"])
        XCTAssertTrue(rows.filter { $0["id"].text != "u2b" }.allSatisfy { $0["versions"].isNull })

        // Version one reads as it did: the original question and its reply,
        // in the transcript's row format, with the requests they came from.
        let page = try await session.versionPage(["messageId": "u2"])
        XCTAssertEqual(texts(page["messages"]), ["original question", "original answer"])
        XCTAssertEqual(page["messages"].list.map { $0["role"].text }, ["user", "assistant"])
        XCTAssertEqual(page["messages"].list.last?["requestAttemptIDs"].list.compactMap(\.text), ["attempt-2"])
        XCTAssertEqual(page["messages"].list.last?["reply"]["attempt"].text, "attempt-2")
        XCTAssertEqual(page["version"].int, 1); XCTAssertEqual(page["count"].int, 2); XCTAssertEqual(page["live"].flag, false)
        XCTAssertTrue(page["next"].isNull)
        // The latest version pages the timeline shown now.
        let latest = try await session.versionPage(["messageId": "u2b"])
        XCTAssertEqual(texts(latest["messages"]), ["edited question", "edited answer"])
        // Reading versions changes nothing the model sees.
        let context = await session.context.map(\.id)
        XCTAssertFalse(context.contains("u2"))
        await session.close()
    }

    func testRepeatedEditsExtendOneListAndReopenAlike() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let session = try chat.session(replies: [answer("answer one"), answer("answer two"), answer("answer three")])
        try await send(session, "q1", "question one")
        try await edit(session, "q1", "q2", "question two")
        try await edit(session, "q2", "q3", "question three")
        let listed = try await session.messageVersions(["messageId": "q3"])
        XCTAssertEqual(listed["versions"].list.map { $0["messageId"].text }, ["q1", "q2", "q3"])
        XCTAssertEqual(listed["current"].int, 3)
        for (id, expected) in [("q1", ["question one", "answer one"]), ("q2", ["question two", "answer two"]), ("q3", ["question three", "answer three"])] {
            let page = try await session.versionPage(["messageId": JSON(id)])
            XCTAssertEqual(texts(page["messages"]), expected, id)
        }
        let rows = await session.snapshot()["messages"].list
        XCTAssertEqual(rows.first { $0["id"].text == "q3" }?["versions"]["index"].int, 3)
        let saved = await session.path
        let path = try XCTUnwrap(saved), bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        await session.close()

        // Reopened from its journal, the chat numbers the same versions.
        let reopened = try chat.session(resume: path)
        let again = try await reopened.messageVersions(["messageId": "q2"])
        XCTAssertEqual(again["versions"].list.map { $0["messageId"].text }, ["q1", "q2", "q3"])
        let first = try await reopened.versionPage(["messageId": "q1"])
        XCTAssertEqual(texts(first["messages"]), ["question one", "answer one"])
        let all = try await reopened.messageVersions([:])
        XCTAssertEqual(all["groups"].list.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, "reading versions never writes the journal")
        await reopened.close()
    }

    func testAnEditAfterACompactionKeepsTheSummaryInTheEarlierVersion() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let session = try chat.session(replies: [answer(String(repeating: "first evidence ", count: 400)), answer(String(repeating: "second evidence ", count: 400)),
                                                 answer("the summary\n\n---\n\n**Turn Context (split turn):**\n\nthe split turn's prefix"), answer("third answer"), answer("edited second answer"),
                                                 answer("edited again answer")], keepRecentTokens: 1)
        try await send(session, "u1", "first question")
        try await send(session, "u2", "second question")
        try await session.compact(); try await eventually { !(await session.isRunning) }
        try await send(session, "u3", "third question")
        // The second question sits before the summary; edit it now.
        try await edit(session, "u2", "u2b", "edited second question")
        let listed = try await session.messageVersions(["messageId": "u2b"])
        XCTAssertEqual(listed["versions"].list.map { $0["messageId"].text }, ["u2", "u2b"])
        XCTAssertEqual(listed["versions"].list.first?["turns"].list.compactMap(\.text), ["u2", "u3"], "version one ran to the end of the chat")
        let page = try await session.versionPage(["messageId": "u2"])
        let kinds = page["messages"].list.map { $0["kind"].text ?? $0["role"].text ?? "" }
        XCTAssertEqual(kinds.first, "user"); XCTAssertTrue(kinds.contains("compaction"), "the summary written after it is part of version one: \(kinds)")
        XCTAssertEqual(texts(page["messages"]).last, "third answer")
        XCTAssertFalse(page["messages"].list.contains { $0["kind"].text == "branch" }, "markers are left out")
        // An edit made after the compaction, of the latest question, extends its own list.
        try await edit(session, "u2b", "u2c", "edited again")
        let again = try await session.messageVersions(["messageId": "u2c"])
        XCTAssertEqual(again["versions"].list.map { $0["messageId"].text }, ["u2", "u2b", "u2c"])
        let second = try await session.versionPage(["messageId": "u2b"])
        XCTAssertEqual(texts(second["messages"]), ["edited second question", "edited second answer"])
        await session.close()
    }

    func testAChatEditedBeforeVersionsReadsItsBranchesWithoutARewrite() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = chat.state.appendingPathComponent("legacy.jsonl")
        do {
            let journal = try SessionJournal(url: path, id: "legacy", cwd: chat.root, binding: chat.profile.binding, create: true)
            try journal.append(["type":"message","message":["role":"user","content":"kept question"]], id: "kept")
            try journal.append(["type":"message","message":["role":"assistant","content":"kept answer"]], id: "kept-answer")
            try journal.append(["type":"message","message":["role":"user","content":"old question"]], id: "old")
            try journal.append(["type":"message","message":["role":"assistant","content":"old answer","nativeRequestAttemptIds":["old-attempt"]]], id: "old-answer")
            try journal.append(["type":"branch","fromMessageId":"old","keptIds":["kept","kept-answer"]], id: "branch")
            try journal.append(["type":"message","message":["role":"user","content":"new question"]], id: "new")
            try journal.append(["type":"message","message":["role":"assistant","content":"new answer"]], id: "new-answer")
        }
        let bytes = try Data(contentsOf: path)
        let session = try chat.session("legacy", resume: path.path)
        let listed = try await session.messageVersions(["messageId": "new"])
        XCTAssertEqual(listed["versions"].list.map { $0["messageId"].text }, ["old", "new"])
        let page = try await session.versionPage(["messageId": "old"])
        XCTAssertEqual(texts(page["messages"]), ["old question", "old answer"])
        XCTAssertEqual(page["messages"].list.last?["requestAttemptIDs"].list.compactMap(\.text), ["old-attempt"])
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        await session.close()
    }

    func testTheLedgerNumbersOnlyBranchesThatNameAMessage() {
        var ledger = MessageVersionLedger()
        ledger.branched(from: ""); ledger.recorded(userMessage: "after-nameless")
        XCTAssertNil(ledger.versions(of: "after-nameless"), "A branch that names no message starts no list")
        ledger.branched(from: "a"); ledger.recorded(userMessage: "b")
        ledger.recorded(userMessage: "c")
        XCTAssertEqual(ledger.versions(of: "c"), nil, "Only the first user message after a branch replaces it")
        ledger.branched(from: "b"); ledger.recorded(userMessage: "d")
        XCTAssertEqual(ledger.versions(of: "a"), ["a", "b", "d"])
        XCTAssertEqual(ledger.position(of: "d")?.index, 3)
        XCTAssertEqual(ledger.edited, [["a", "b", "d"]])
    }

    func testAnOldVersionPagesInBoundedPages() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let long = { (tag: String) in answer(tag + String(repeating: " filler", count: 12_000)) }
        let session = try chat.session(replies: [long("one"), long("two"), long("three"), answer("replacement answer")])
        try await send(session, "a", "first")
        try await send(session, "b", "second")
        try await send(session, "c", "third")
        try await edit(session, "a", "a2", "first, edited")
        var offset = 0, pages = 0, seen: [String] = []
        while true {
            let page = try await session.versionPage(["messageId": "a", "offset": JSON(offset)])
            XCTAssertLessThanOrEqual(try page["messages"].data().count, HistoryWindowPolicy.envelopeBytes)
            XCTAssertEqual(page["start"].int, offset); XCTAssertEqual(page["total"].int, 6)
            seen += texts(page["messages"]).map { String($0.prefix(5)) }; pages += 1
            guard let next = page["next"].int else { break }
            offset = next
        }
        XCTAssertGreaterThan(pages, 1, "three long replies do not fit one page")
        XCTAssertEqual(seen, ["first", "one f", "secon", "two f", "third", "three"])
        do { _ = try await session.versionPage(["messageId": "a", "offset": 7]); XCTFail("past the end") }
        catch let error as AgentError { XCTAssertEqual(error.code, "invalid_range") }
        do { _ = try await session.versionPage(["messageId": "b"]); XCTFail("b was never edited") }
        catch let error as AgentError { XCTAssertEqual(error.code, "version_missing") }
        await session.close()
    }
}
