import XCTest
@testable import PiAgentCore

/// A chat moved to another saved connection: the helper never answers an
/// open on the new connection with the session loaded on the old one.
final class ConnectionSwitchTests: XCTestCase {
    func testAnOpenOnAnotherConnectionIsNotAnsweredByTheLoadedSession() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        let original = try fixtureProfile().raw
        _ = try await host.command("session.open", sessionID: "chat", params: ["profile": original, "apiKey": "synthetic", "toolMode": "read-only"])
        var other = original; other["id"] = "other-connection"
        do {
            _ = try await host.command("session.open", sessionID: "chat", params: ["profile": other, "apiKey": "synthetic", "toolMode": "read-only"])
            XCTFail("The session loaded on the first connection must not answer an open on the second")
        } catch let error as AgentError { XCTAssertEqual(error.code, "session_conflict") }
        let again = try await host.command("session.open", sessionID: "chat", params: ["profile": original, "apiKey": "synthetic", "toolMode": "read-only"])
        XCTAssertEqual(again["profileId"].text, original["id"].text)
        await host.shutdown()
    }

    // MARK: The journal moved to another connection (`session.rebind`)

    private struct Chat {
        let root: URL, state: URL, resources: Resources, traces: TraceStore
        func session(_ id: String, _ profile: Profile, replies: [ModelReply] = [], resume: String? = nil, client: ScriptClient? = nil) throws -> AgentSession {
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                                    client: client ?? ScriptClient(replies), tools: RecordingTools(), traces: traces, resumePath: resume,
                                    autoCompaction: false, compactionPolicy: policy)
        }
    }
    private func chat() throws -> Chat {
        let root = try temporaryDirectory()
        return Chat(root: root, state: root.appendingPathComponent("state"), resources: Resources(cwd: root, home: root), traces: TraceStore())
    }
    /// Another saved connection: another endpoint and default model, so a
    /// journal bound to the first is not bound to it.
    private func second() throws -> Profile {
        var raw = try fixtureProfile().raw; raw["id"] = "second"; raw["modelId"] = "second-model"; raw["baseUrl"] = "http://127.0.0.1:23456/v1"
        return try Profile(raw)
    }
    private func send(_ session: AgentSession, _ id: String, _ text: String) async throws {
        _ = try await session.submit(Submission(commandID: id, turnID: id, text: text), steer: false)
        try await eventually { !(await session.isRunning) }
    }
    private let chatID = "chat-0001"
    /// A chat on the first connection: a turn, a compaction, a turn; closed,
    /// with the metadata file its open resumes from.
    private func source(_ chat: Chat) async throws -> String {
        let long = { (n: Int) in answer("answer \(n) " + String(repeating: "evidence ", count: 60)) }
        let session = try chat.session(chatID, try fixtureProfile(), replies: [long(0), long(1), long(2), answer("Summary so far."), answer("answer two")])
        try await send(session, "u0", "question zero")
        try await send(session, "u00", "question zero again")
        try await send(session, "u1", "question one")
        try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        try await send(session, "u2", "question two")
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        await session.close()
        return path
    }
    private func host(_ chat: Chat) async throws -> NativeHostService {
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(chat.root.path), "directory": JSON(chat.state.path), "mcp": ["servers": [:]]])
        return host
    }
    private func rebind(_ host: NativeHostService, _ path: String, to profile: Profile) async throws -> JSON {
        try await host.command("session.rebind", sessionID: chatID, params: ["path": JSON(path), "profile": profile.raw])
    }

    func testAJournalMovedToAnotherConnectionOpensThereWithEverythingItHad() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat), url = URL(fileURLWithPath: path), first = try fixtureProfile(), second = try second()
        let before = try chat.session(chatID, first, resume: path)
        let context = await before.context.map(\.id)
        try await before.ensureFullHistory()
        let history = await before.history.map(\.id), visible = await before.visible.map(\.id)
        await before.close()
        XCTAssertNotNil(JournalCheckpoint.read(for: url), "the chat opens from its metadata file")
        let bytes = try Data(contentsOf: url)

        let host = try await host(chat)
        let moved = try await rebind(host, path, to: second)
        XCTAssertEqual(moved["rebound"].flag, true)
        XCTAssertEqual(try Data(contentsOf: url).prefix(bytes.count), bytes, "every record written on the first connection stays as it was")
        do { _ = try SessionJournal(url: url, id: chatID, cwd: chat.root, binding: first.binding, create: false); XCTFail("bound to the second connection now") }
        catch let error as AgentError { XCTAssertEqual(error.code, "legacy_session") }
        // The metadata file names the move, so the next open still resumes from it.
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: url))
        XCTAssertEqual(stored.rebinds?.count, 1)
        try {
            let resumed = try SessionJournal(url: url, id: chatID, cwd: chat.root, binding: second.binding, create: false, checkpoint: stored)
            XCTAssertNotNil(resumed.resumedFrom); XCTAssertEqual(resumed.binding, second.binding)
        }()

        let client = ScriptClient([answer("answer three")])
        let after = try chat.session(chatID, second, resume: path, client: client)
        let afterContext = await after.context.map(\.id)
        XCTAssertEqual(afterContext, context)
        try await send(after, "u3", "question three")
        let profiles = await client.profiles
        XCTAssertEqual(profiles.map(\.id), ["second"], "the next request goes to the second connection")
        let sent = await client.requests.first?.map(\.id) ?? []
        XCTAssertEqual(Array(sent.prefix(context.count)), context, "with the context the chat had")
        await after.close()

        // Read whole, without the metadata file, the journal says the same.
        JournalCheckpoint.remove(for: url)
        let whole = try chat.session(chatID, second, resume: path)
        let wholeHistory = await whole.history.map(\.id), wholeVisible = await whole.visible.map(\.id)
        XCTAssertEqual(Array(wholeHistory.prefix(history.count)), history)
        XCTAssertEqual(Array(wholeVisible.prefix(visible.count)), visible)
        XCTAssertTrue(wholeHistory.contains("u3"))
        await whole.close()

        // The same connection again changes nothing; back to the first works.
        let again = try await rebind(host, path, to: second)
        XCTAssertEqual(again["rebound"].flag, false)
        let back = try await rebind(host, path, to: first)
        XCTAssertEqual(back["rebound"].flag, true)
        let reopened = try chat.session(chatID, first, resume: path)
        let reopenedHistory = await reopened.history.map(\.id)
        XCTAssertTrue(reopenedHistory.contains("u3"))
        await reopened.close()
        await host.shutdown()
    }

    func testAChatOpenHereIsNotMoved() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let host = try await host(chat)
        _ = try await host.command("session.open", sessionID: chatID, params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "path": JSON(path)])
        do { _ = try await rebind(host, path, to: try second()); XCTFail("a loaded chat is closed before it moves") }
        catch let error as AgentError { XCTAssertEqual(error.code, "session_busy") }
        await host.shutdown()
    }

    /// A fork from a reply written before the chat moved is bound to where
    /// the chat is now, cloned or copied; so is a fork of the whole chat.
    func testForksOfAMovedChatAreBoundToItsConnection() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat), second = try second()
        let host = try await host(chat)
        _ = try await rebind(host, path, to: second)
        await host.shutdown()
        let parent = try chat.session(chatID, second, resume: path)
        try await parent.ensureFullHistory()
        let parentHistory = await parent.history
        let early = try XCTUnwrap(parentHistory.first { $0.role == "assistant" && $0.kind == nil }?.id)
        for (forkID, point) in [("fork-01", Optional(early)), ("fork-02", nil), ("fork-with-an-identity-longer-than-the-chat-01", Optional(early)), ("fork-with-an-identity-longer-than-the-chat-02", nil)] {
            let result = try await parent.fork(to: forkID, at: point)
            let url = URL(fileURLWithPath: try XCTUnwrap(result["path"].text))
            try {
                let opened = try SessionJournal(url: url, id: forkID, cwd: chat.root, binding: second.binding, create: false, checkpoint: JournalCheckpoint.read(for: url))
                XCTAssertEqual(opened.binding, second.binding, forkID)
            }()
            let fork = try chat.session(forkID, second, resume: url.path)
            await fork.close()
        }
        await parent.close()
    }

    func testSlimmingAMovedJournalKeepsWhereItIsBound() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat), second = try second(), url = URL(fileURLWithPath: path)
        let host = try await host(chat)
        _ = try await rebind(host, path, to: second)
        await host.shutdown()
        let outcome = try JournalSlimming.slim(url: url, id: chatID, minimumSaving: 0, discard: { _ in })
        XCTAssertTrue(outcome.slimmed, outcome.reason ?? "")
        let opened = try chat.session(chatID, second, resume: path)
        let openedHistory = await opened.history.map(\.id)
        XCTAssertTrue(openedHistory.contains("u2"))
        await opened.close()
    }

    /// A move to where the journal already is changes nothing, but what the
    /// journal holds is forced to disk before it says so.
    func testAMoveToWhereTheJournalIsForcesItToDisk() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat), url = URL(fileURLWithPath: path), first = try fixtureProfile()
        let journal = try SessionJournal(url: url, id: chatID, cwd: chat.root, binding: nil, create: false)
        let size = journal.size
        try journal.rebind(to: first.binding)
        XCTAssertEqual(journal.size, size, "nothing written")
        XCTAssertEqual(journal.synchronizations, 1)
    }

    func testAMoveThatDoesNotFollowTheBindingBeforeItIsRefused() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat), url = URL(fileURLWithPath: path), first = try fixtureProfile(), second = try second()
        try {
            let journal = try SessionJournal(url: url, id: chatID, cwd: chat.root, binding: first.binding, create: false)
            try journal.append(["type": "custom", "customType": JSON(JournalRecordKind.rebind), "data": ["binding": first.binding, "previous": second.binding]])
        }()
        JournalCheckpoint.remove(for: url)
        do { _ = try SessionJournal(url: url, id: chatID, cwd: chat.root, binding: nil, create: false); XCTFail("a move from a binding the journal was not on") }
        catch let error as AgentError { XCTAssertEqual(error.code, "session_damaged") }
    }
}
