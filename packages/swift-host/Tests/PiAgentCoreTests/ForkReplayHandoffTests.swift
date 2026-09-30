import XCTest
@testable import PiAgentCore

/// A fork opens with what its journal replays to, made as the journal was
/// written (`forked`), instead of reading the journal again. That state, and
/// the metadata file written with it, are exactly what the fork's own first
/// open would have made from the file: for a fork of the whole chat and one
/// from a reply, through tool calls, a compaction, an edit and its versions.
final class ForkReplayHandoffTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, replies: [ModelReply] = [], resume: String? = nil, prepared: JournalReplay? = nil) throws -> AgentSession {
            try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                             client: ScriptClient(replies), tools: RecordingTools(), traces: traces, resumePath: resume, prepared: prepared,
                             autoCompaction: false)
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

    /// A chat with a little of everything a long one has.
    private func source(_ chat: Chat) async throws -> AgentSession {
        let session = try chat.session("source", replies: [
            toolReply(["first", "second"]), answer("after the tools"),
            answer("answer two"),
            answer("Summary of everything so far."),
            answer("answer three"), answer("the original answer"), answer("the edited answer"),
            toolReply(["first"]), answer("the last answer"),
        ])
        try await send(session, "u1", "please use the tools")
        try await send(session, "u2", "question two")
        try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        try await send(session, "u3", "question three")
        try await send(session, "u4", "the original question")
        _ = try await session.edit(fromMessageID: "u4", input: Submission(commandID: "u4b", turnID: "u4b", text: "the edited question"))
        try await eventually { !(await session.isRunning) }
        try await send(session, "u5", "one more with a tool")
        return session
    }

    /// Every part of a replay, compared.
    private func assertSame(_ made: JournalReplay, _ read: JournalReplay, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(made.history, read.history, "\(what): history", file: file, line: line)
        XCTAssertEqual(made.visible, read.visible, "\(what): visible", file: file, line: line)
        XCTAssertEqual(made.context, read.context, "\(what): context", file: file, line: line)
        XCTAssertEqual(made.versions.ledger, read.versions.ledger, "\(what): versions", file: file, line: line)
        XCTAssertEqual(made.versions.timelines, read.versions.timelines, "\(what): version timelines", file: file, line: line)
        XCTAssertEqual(made.versions.starts.mapValues { [$0.timeline, $0.offset] }, read.versions.starts.mapValues { [$0.timeline, $0.offset] }, "\(what): version starts", file: file, line: line)
        XCTAssertEqual(made.spend, read.spend, "\(what): spend", file: file, line: line)
        XCTAssertEqual(made.spendTracked, read.spendTracked, "\(what): spend tracked", file: file, line: line)
        XCTAssertEqual(made.assistantMessageCount, read.assistantMessageCount, "\(what): replies", file: file, line: line)
        XCTAssertEqual(made.latestAssistantMessageID, read.latestAssistantMessageID, "\(what): latest reply", file: file, line: line)
        XCTAssertEqual(made.pendingRequestLinks, read.pendingRequestLinks, "\(what): request links", file: file, line: line)
        XCTAssertEqual(made.recentTaskPresentations, read.recentTaskPresentations, "\(what): tasks", file: file, line: line)
        XCTAssertEqual(made.compactionState, read.compactionState, "\(what): compaction state", file: file, line: line)
        XCTAssertEqual(made.contextRecovery, read.contextRecovery, "\(what): context recovery", file: file, line: line)
        XCTAssertEqual(made.failedCompactionFingerprint, read.failedCompactionFingerprint, "\(what): failed compaction", file: file, line: line)
        XCTAssertEqual(made.parentInfo, read.parentInfo, "\(what): origin", file: file, line: line)
        XCTAssertEqual(made.presentationOrdinal, read.presentationOrdinal, "\(what): ordinal", file: file, line: line)
        XCTAssertEqual(made.rowSpans, read.rowSpans, "\(what): row spans", file: file, line: line)
        XCTAssertEqual(made.olderRows, read.olderRows, "\(what): older rows", file: file, line: line)
        XCTAssertEqual(made.stateRecord, read.stateRecord, "\(what): run state", file: file, line: line)
        XCTAssertEqual(made.captured, read.captured, "\(what): checkpoint", file: file, line: line)
        XCTAssertEqual(made.resumed, read.resumed, "\(what): resumed", file: file, line: line)
        XCTAssertEqual(made.stateSource.map { [JSON($0.line.base64EncodedString()), JSON(Double($0.offset)), JSON($0.key)] },
                       read.stateSource.map { [JSON($0.line.base64EncodedString()), JSON(Double($0.offset)), JSON($0.key)] }, "\(what): state source", file: file, line: line)
        XCTAssertEqual(made.coveredBytes, read.coveredBytes, "\(what): bytes", file: file, line: line)
    }

    /// The fork's journal replayed in full, from the file, as an open without
    /// a metadata file does.
    private func fullReplay(_ chat: Chat, id: String, path: String) throws -> JournalReplay {
        let url = URL(fileURLWithPath: path)
        let journal = try SessionJournal(url: url, id: id, cwd: chat.root, binding: chat.profile.binding, create: false)
        return try AgentSession.replay(journal, url: url, id: id, binding: chat.profile.binding, spendTracked: false, resume: false)
    }

    func testAForkOpensWithWhatItsJournalReplaysTo() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try await source(chat)
        let found = await source.history.first { $0.role == "assistant" && $0.text == "answer three" }?.id
        let reply = try XCTUnwrap(found)
        for (id, point) in [("whole", nil), ("at-reply", reply)] as [(String, String?)] {
            let (result, made) = try await source.forked(to: id, at: point)
            let path = try XCTUnwrap(result["path"].text)
            // Made as it was written: what a replay of the file gives.
            assertSame(made, try fullReplay(chat, id: id, path: path), id)
            XCTAssertNotNil(made.captured, "\(id): a checkpoint at the fork's context")
            // No metadata file yet: the fork's first open writes it, and it
            // holds the checkpoint made with the replay.
            let url = URL(fileURLWithPath: path)
            XCTAssertNil(JournalCheckpoint.read(for: url), "\(id): the first open writes the metadata file")
            let opened = try chat.session(id, resume: path)
            XCTAssertEqual(JournalCheckpoint.read(for: url), made.captured, "\(id): metadata file")
            JournalCheckpoint.remove(for: url)
            let openedSnapshot = await opened.snapshot(), openedContext = await opened.context.map(\.id)
            await opened.close()
            // Opened with it, the fork is the chat an open from the file is.
            let handed = try chat.session(id, resume: path, prepared: made)
            XCTAssertEqual(JournalCheckpoint.read(for: url), made.captured, "\(id): opened with the replay, it writes the same metadata file")
            let handedSnapshot = await handed.snapshot(), handedContext = await handed.context.map(\.id)
            XCTAssertEqual(handedSnapshot["messages"], openedSnapshot["messages"], "\(id): rows")
            XCTAssertEqual(handedSnapshot["total"], openedSnapshot["total"], "\(id): row count")
            XCTAssertEqual(handedContext, openedContext, "\(id): context")
            let partial = await handed.partialHistory
            XCTAssertFalse(partial, "\(id): opened whole, as a first open is")
            await handed.close()
        }
        await source.close()
    }

    /// A replay that is not the whole journal as it is now is not used: the
    /// journal is read as before.
    func testAReplayThatNoLongerMatchesItsJournalIsNotUsed() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try await source(chat)
        let (result, made) = try await source.forked(to: "fork")
        let path = try XCTUnwrap(result["path"].text)
        do {
            let journal = try SessionJournal(url: URL(fileURLWithPath: path), id: "fork", cwd: chat.root, binding: chat.profile.binding, create: false)
            try journal.append(["type": "message", "message": ["role": "user", "content": "written after the fork"]], id: "later")
        }
        let opened = try chat.session("fork", resume: path, prepared: made)
        let rows = await opened.history.map(\.id)
        XCTAssertEqual(rows.last, "later", "The journal as it is now, not the replay made before")
        await opened.close(); await source.close()
    }
}
