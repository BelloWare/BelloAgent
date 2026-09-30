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
        func session(_ id: String, replies: [ModelReply] = [], resume: String? = nil, prepared: JournalReplayConsumer? = nil) throws -> AgentSession {
            // Everything but the latest turn is summarized when compacted.
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                                    client: ScriptClient(replies), tools: RecordingTools(), traces: traces, resumePath: resume, prepared: prepared,
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

    /// A chat with a little of everything a long one has.
    private func source(_ chat: Chat) async throws -> AgentSession {
        let session = try chat.session("source", replies: [
            toolReply(["first", "second"]), answer(String(repeating: "after the tools ", count: 400)),
            answer(String(repeating: "answer two ", count: 400)),
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
        let kinds = await session.history.filter { $0.role == "assistant" }.map(\.text)
        XCTAssertEqual(kinds.last, "the last answer", "every reply was used")
        let sessionPath = await session.path
        let reader = try JournalRecordReader(URL(fileURLWithPath: try XCTUnwrap(sessionPath))); _ = try reader.next()
        var shaping: [String] = []
        while let record = try reader.next() { if let type = record["type"].text, ["compaction", "branch"].contains(type) { shaping.append(type) } }
        XCTAssertEqual(shaping, ["compaction", "branch"], "the chat compacted, then edited")
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

    /// What a chat holds of its history, and how much of it.
    private struct Whole: Equatable {
        var history: [ChatMessage], visible: [ChatMessage], ledger: MessageVersionLedger, timelines: [[Int]]
        var links: [String: [String]], spans: [String: JournalCheckpoint.Row], tasks: [TaskPresentationRecord]
        var partial: Bool, older: Int, scanned: UInt64
    }
    private func whole(_ session: AgentSession) async -> Whole {
        Whole(history: await session.history, visible: await session.visible, ledger: await session.versions.ledger, timelines: await session.versions.timelines,
              links: await session.pendingRequestLinks, spans: await session.rowSpans, tasks: await session.recentTaskPresentations,
              partial: await session.partialHistory, older: await session.olderRows, scanned: await session.spansScannedTo)
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
            let (result, replay) = try await source.forked(to: id, at: point)
            let made = try replay.finished()
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
            let handed = try chat.session(id, resume: path, prepared: replay)
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

    /// A fork of the whole chat, from a chat opened from its metadata file
    /// with only its latest rows, gives the chat its whole history from what
    /// it copied, instead of reading the journal once more first: the same
    /// rows, versions, links, places and tasks the full read gave, and a fork
    /// whose timeline is the one it gave.
    func testAForkOfTheWholeChatGivesTheChatItsWholeHistory() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try await source(chat)
        let snapshot = await source.snapshot()
        let path = try XCTUnwrap(snapshot["path"].text)
        await source.close()
        XCTAssertNotNil(JournalCheckpoint.read(for: URL(fileURLWithPath: path)), "the chat has its metadata file")
        func contextData(_ result: JSON) throws -> JSON {
            let reader = try JournalRecordReader(URL(fileURLWithPath: try XCTUnwrap(result["path"].text))); _ = try reader.next()
            var found: JSON = .null
            while let record = try reader.next() { if record["customType"].text == JournalRecordKind.context { found = record["data"] } }
            return found
        }
        // Read in full first, as every fork did.
        let read = try chat.session("source", resume: path)
        let readPartial = await read.partialHistory
        XCTAssertTrue(readPartial, "opened with its latest rows only")
        try await read.ensureFullHistory()
        let readWhole = await whole(read)
        let readFork = try await read.fork(to: "after-read")
        await read.close()
        // Given its history by the fork of the whole chat.
        let forked = try chat.session("source", resume: path)
        let forkedPartial = await forked.partialHistory
        XCTAssertTrue(forkedPartial, "opened with its latest rows only")
        let forkedResult = try await forked.fork(to: "whole")
        let forkedWhole = await whole(forked)
        await forked.close()
        XCTAssertEqual(forkedWhole.history, readWhole.history, "history")
        XCTAssertEqual(forkedWhole.visible, readWhole.visible, "shown rows")
        XCTAssertEqual(forkedWhole.ledger, readWhole.ledger, "versions")
        XCTAssertEqual(forkedWhole.timelines, readWhole.timelines, "version timelines")
        XCTAssertEqual(forkedWhole.links, readWhole.links, "request links")
        XCTAssertEqual(forkedWhole.spans, readWhole.spans, "the rows' places in the chat's own journal")
        XCTAssertEqual(forkedWhole.tasks, readWhole.tasks, "tasks")
        XCTAssertEqual(forkedWhole, readWhole, "everything the full read gives")
        XCTAssertFalse(forkedWhole.partial)
        XCTAssertEqual(try contextData(forkedResult), try contextData(readFork), "the fork's context and timeline")
    }

    /// A fork of the whole chat that fails leaves the chat with its whole
    /// history, as reading it before the fork did, and leaves no fork behind:
    /// when the fork's name is taken, so it cannot be published, and when it
    /// would have the chat's own.
    func testAForkThatFailsStillGivesTheChatItsWholeHistory() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try await source(chat)
        let snapshot = await source.snapshot()
        let path = try XCTUnwrap(snapshot["path"].text)
        await source.close()
        let read = try chat.session("source", resume: path)
        try await read.ensureFullHistory()
        let readWhole = await whole(read), readSnapshot = await read.snapshot()
        await read.close()
        let taken = chat.state.appendingPathComponent("fork_taken.jsonl")
        try Data("not a fork\n".utf8).write(to: taken)
        for (newID, code) in [("taken", nil), ("source", "session_conflict")] as [(String, String?)] {
            let session = try chat.session("source", resume: path)
            let partial = await session.partialHistory
            XCTAssertTrue(partial, "\(newID): opened with its latest rows only")
            do { _ = try await session.fork(to: newID); XCTFail("\(newID): the fork fails") }
            catch { if let code { XCTAssertEqual((error as? AgentError)?.code, code, newID) } }
            let failedWhole = await whole(session), failedSnapshot = await session.snapshot()
            await session.close()
            XCTAssertEqual(failedWhole, readWhole, "\(newID): the whole history, as the full read gave")
            for key in ["messages", "total"] { XCTAssertEqual(failedSnapshot[key], readSnapshot[key], "\(newID): \(key)") }
            // The revision is the session's own, then how often its rows changed.
            let changes = { (snapshot: JSON) in snapshot["displayRevision"].text?.split(separator: ":").last }
            XCTAssertEqual(changes(failedSnapshot), changes(readSnapshot), "\(newID): the rows changed once, as the full read changed them")
        }
        XCTAssertEqual(try Data(contentsOf: taken), Data("not a fork\n".utf8), "the file where the fork would go is kept")
        let left = try FileManager.default.contentsOfDirectory(atPath: chat.state.path).filter { $0.hasPrefix(".fork-") }
        XCTAssertEqual(left, [], "no fork journal left behind")
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
