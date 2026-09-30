import XCTest
@testable import PiAgentCore

/// Tools that wait until they are let go, so a test can copy a journal while
/// a batch runs, as a crash would leave it.
private actor WaitingTools: ToolExecuting {
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

/// A chat keeps the replay of its journal as written (`durableReplay`), apart
/// from the live state a run keeps: exactly what replaying its journal gives,
/// from the start, or from the metadata file its open resumed from.
final class DurableReplayTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, replies: [ModelReply] = [], tools: any ToolExecuting = RecordingTools(), resume: String? = nil, in directory: URL? = nil) throws -> AgentSession {
            // Everything but the latest turn is summarized when compacted.
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: directory ?? state, readOnly: false, resources: resources,
                                    client: ScriptClient(replies), tools: tools, traces: traces, resumePath: resume, autoCompaction: false, compactionPolicy: policy)
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
    private func compact(_ session: AgentSession, _ id: String) async throws {
        try await session.compact(commandID: id)
        try await eventually { !(await session.isRunning) }
    }

    /// The journal at `path` replayed on a copy (the chat holds the file):
    /// from the start, or resumed from `checkpoint`.
    private func replay(_ chat: Chat, id: String, path: String, from checkpoint: JournalCheckpoint? = nil, spendTracked: Bool = false) throws -> JournalReplay {
        let copyRoot = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: copyRoot) }
        let copy = copyRoot.appendingPathComponent("copy.jsonl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        if let checkpoint { try checkpoint.write(for: copy) }
        let journal = try SessionJournal(url: copy, id: id, cwd: chat.root, binding: chat.profile.binding, create: false, checkpoint: checkpoint)
        if checkpoint != nil { XCTAssertNotNil(journal.resumedFrom, "the copy resumes from the checkpoint") }
        return try AgentSession.replay(journal, url: copy, id: id, binding: chat.profile.binding, spendTracked: spendTracked, resume: checkpoint != nil)
    }
    private func assertSame(_ made: JournalReplay, _ read: JournalReplay, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(made.history, read.history, "\(what): history", file: file, line: line)
        XCTAssertEqual(made.visible, read.visible, "\(what): visible", file: file, line: line)
        XCTAssertEqual(made.context, read.context, "\(what): context", file: file, line: line)
        XCTAssertEqual(made.versions.ledger, read.versions.ledger, "\(what): versions", file: file, line: line)
        XCTAssertEqual(made.spend, read.spend, "\(what): spend", file: file, line: line)
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
        XCTAssertEqual(made.resumed, read.resumed, "\(what): resumed", file: file, line: line)
        XCTAssertEqual(made.coveredBytes, read.coveredBytes, "\(what): bytes", file: file, line: line)
        XCTAssertEqual(made.stateSource?.offset, read.stateSource?.offset, "\(what): state source", file: file, line: line)
        // The checkpoint, but for the copy's own header, marker and session.
        XCTAssertEqual(made.captured?.rows, read.captured?.rows, "\(what): checkpoint rows", file: file, line: line)
        XCTAssertEqual(made.captured?.rowsBefore, read.captured?.rowsBefore, "\(what): checkpoint rows before", file: file, line: line)
        XCTAssertEqual(made.captured?.lineage, read.captured?.lineage, "\(what): checkpoint lineage", file: file, line: line)
        XCTAssertEqual(made.captured?.context, read.captured?.context, "\(what): checkpoint context", file: file, line: line)
        XCTAssertEqual(made.captured?.last, read.captured?.last, "\(what): checkpoint record", file: file, line: line)
        XCTAssertEqual(made.captured?.state, read.captured?.state, "\(what): checkpoint state", file: file, line: line)
        XCTAssertEqual(made.captured?.helper, read.captured?.helper, "\(what): checkpoint helper", file: file, line: line)
        XCTAssertEqual(made.captured?.tasks, read.captured?.tasks, "\(what): checkpoint tasks", file: file, line: line)
        XCTAssertEqual(made.captured?.versions, read.captured?.versions, "\(what): checkpoint versions", file: file, line: line)
    }

    /// A chat with an edit before its compaction: the checkpoint's lineage is
    /// then a marker among the rows it does not name.
    private func source(_ chat: Chat) async throws -> AgentSession {
        let session = try chat.session("source", replies: [
            toolReply(["first", "second"]), answer(String(repeating: "after the tools ", count: 400)),
            answer("the original answer"), answer(String(repeating: "the edited answer ", count: 400)),
            answer("answer three"), answer("Summary of everything so far."),
            answer(String(repeating: "answer four ", count: 400)), answer("Another summary."), answer("answer five"),
        ])
        try await send(session, "u1", "please use the tools")
        try await send(session, "u2", "the original question")
        _ = try await session.edit(fromMessageID: "u2", input: Submission(commandID: "u2b", turnID: "u2b", text: "the edited question"))
        try await eventually { !(await session.isRunning) }
        try await send(session, "u3", "question three")
        try await compact(session, "compact-1")
        return session
    }

    /// Opened from the start, the replay the chat keeps is the journal's, and
    /// stays so as the chat goes on: turns, a compaction, an edit.
    func testTheReplayAChatKeepsIsItsJournals() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let session = try await source(chat)
        try await send(session, "u4", "question four")
        try await compact(session, "compact-2")
        try await send(session, "u5", "question five")
        let sessionPath = await session.path, keptReplay = try await session.durableReplay()
        let path = try XCTUnwrap(sessionPath), kept = try XCTUnwrap(keptReplay)
        let compactions = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n").filter { $0.contains(#""type":"compaction""#) }.count
        XCTAssertEqual(compactions, 2, "the chat compacted twice")
        XCTAssertFalse(kept.r.resumed)
        // A chat the helper made counts its spend from the start.
        assertSame(try kept.finished(), try replay(chat, id: "source", path: path, spendTracked: true), "opened whole")
        await session.close()
    }

    /// Opened from its metadata file, the replay the chat keeps is the one
    /// resumed from that file; the checkpoint it takes at a later compaction
    /// counts the rows it never loaded and names their newest marker, as the
    /// replay of the whole journal does.
    func testAResumedChatKeepsTheResumedReplayAndItsCheckpointsCountEveryRow() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let first = try await source(chat)
        let firstPath = await first.path
        let path = try XCTUnwrap(firstPath)
        await first.close()
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)))
        XCTAssertNotNil(stored.lineage, "the edit's marker")
        XCTAssertFalse(stored.rows.contains { $0.id == stored.lineage }, "among the rows the file does not name")
        let session = try chat.session("source", replies: [answer(String(repeating: "answer four ", count: 400)), answer("Another summary."), answer("answer five")], resume: path)
        let partial = await session.partialHistory
        XCTAssertTrue(partial)
        try await send(session, "u4", "question four")
        try await compact(session, "compact-2")
        try await send(session, "u5", "question five")
        let compactions = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n").filter { $0.contains(#""type":"compaction""#) }.count
        XCTAssertEqual(compactions, 2, "the reopened chat compacted")
        let keptReplay = try await session.durableReplay()
        let kept = try XCTUnwrap(keptReplay)
        XCTAssertTrue(kept.r.resumed)
        let made = try kept.finished()
        assertSame(made, try replay(chat, id: "source", path: path, from: stored), "resumed from the same file")
        let whole = try replay(chat, id: "source", path: path)
        XCTAssertEqual(made.captured?.rowsBefore, whole.captured?.rowsBefore, "every shown row before the context counts")
        XCTAssertEqual(made.captured?.lineage, whole.captured?.lineage, "the newest marker among every shown row")
        XCTAssertEqual(made.captured?.rows, whole.captured?.rows)
        // Loading every row, the chat keeps the whole journal's replay.
        try await session.ensureFullHistory()
        let loadedReplay = try await session.durableReplay()
        let loaded = try XCTUnwrap(loadedReplay)
        XCTAssertFalse(loaded.r.resumed)
        let tracked = await session.spendTracked
        assertSame(try loaded.finished(), try replay(chat, id: "source", path: path, spendTracked: tracked), "after loading every row")
        await session.close()
    }

    /// A chat opened from its metadata file that a fork of the whole chat gave
    /// every row (copied, `adoptCopiedHistory`) keeps a replay of the whole
    /// journal from then on, so an edit of an older message is replayed.
    func testAChatAForkGaveEveryRowKeepsTheWholeReplay() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let first = try await source(chat)
        let firstPath = await first.path
        let path = try XCTUnwrap(firstPath)
        await first.close()
        let session = try chat.session("source", replies: [answer("the first answer, again")], resume: path)
        let partial = await session.partialHistory
        XCTAssertTrue(partial)
        _ = try await session.fork(to: "a-much-longer-fork-identity-than-the-chats-own-one")
        let loaded = await session.partialHistory
        XCTAssertFalse(loaded, "the fork gave the chat every row")
        _ = try await session.edit(fromMessageID: "u1", input: Submission(commandID: "u1b", turnID: "u1b", text: "the first question, edited"))
        try await eventually { !(await session.isRunning) }
        let keptReplay = try await session.durableReplay()
        let kept = try XCTUnwrap(keptReplay)
        XCTAssertFalse(kept.r.resumed)
        let tracked = await session.spendTracked
        assertSame(try kept.finished(), try replay(chat, id: "source", path: path, spendTracked: tracked), "after the fork and an older edit")
        await session.close()
    }

    /// A replay resumed from a checkpoint with nothing after it has read the
    /// journal to its end: taken on later, it reads only what comes next.
    func testAReplayResumedAtTheJournalsEndGoesOnFromThere() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let first = try await source(chat)
        let firstPath = await first.path
        let path = try XCTUnwrap(firstPath)
        await first.close()
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)))
        // The journal as it was right after the checkpoint's record.
        let copyRoot = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: copyRoot) }
        let copy = copyRoot.appendingPathComponent("copy.jsonl")
        try Data(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(Int(stored.start))).write(to: copy)
        let journal = try SessionJournal(url: copy, id: "source", cwd: chat.root, binding: chat.profile.binding, create: false, checkpoint: stored)
        XCTAssertNotNil(journal.resumedFrom)
        var consumer = try AgentSession.replayConsumer(journal, url: copy, id: "source", binding: chat.profile.binding, spendTracked: false, resume: true)
        XCTAssertEqual(consumer.r.coveredBytes, journal.size, "read to the end, with nothing after the checkpoint")
        try journal.append(["type": "message", "message": ["role": "user", "content": "next"]], id: "next")
        let reader = try journal.recordReader(from: consumer.r.coveredBytes)
        while true {
            let start = reader.completeBytes
            guard let line = try reader.nextLine() else { break }
            if !line.isEmpty { try consumer.consume(line, at: start) }
        }
        XCTAssertEqual(consumer.r.history.filter { $0.id == "next" }.count, 1)
        XCTAssertEqual(consumer.r.history.count, Set(consumer.r.history.map(\.id)).count, "no row read twice")
    }

    /// A chat reopened after a crash mid-batch: the open writes an unknown
    /// outcome for the tool that never finished, which the replay the chat
    /// keeps has, and marks the run's task interrupted in memory only, which
    /// it does not have: the journal's replay does not either.
    func testAReopenedChatsReplayHasWhatTheOpenWroteAndNotWhatItOnlyShows() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let tools = WaitingTools()
        let running = try chat.session("source", replies: [toolReply(["first"]), answer("after the tool")], tools: tools)
        _ = try await running.submit(Submission(commandID: "u1", turnID: "u1", text: "use a tool"), steer: false)
        try await eventually { await tools.started > 0 }
        let path = await running.path
        let runningPath = try XCTUnwrap(path)
        // The journal as a crash would leave it, in a directory of its own.
        let crashed = chat.root.appendingPathComponent("crashed"), copy = crashed.appendingPathComponent("source.jsonl")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: runningPath), to: copy)
        await tools.release(); try await eventually { !(await running.isRunning) }
        await running.close()
        let reopened = try chat.session("source", resume: copy.path, in: crashed)
        let live = await reopened.recentTaskPresentations
        let interrupted = live.filter { $0.outcome == "interrupted" }
        let keptReplay = try await reopened.durableReplay()
        let kept = try XCTUnwrap(keptReplay)
        let made = try kept.finished(), read = try replay(chat, id: "source", path: copy.path)
        assertSame(made, read, "reopened after a crash")
        XCTAssertTrue(made.history.contains { $0.role == "toolResult" && $0.text.contains("Outcome unknown") }, "the unknown outcome the open wrote")
        XCTAssertFalse(interrupted.isEmpty, "the open marks the run's task interrupted")
        XCTAssertFalse(made.recentTaskPresentations.contains { $0.outcome == "interrupted" }, "in memory only: not in the journal's replay")
        await reopened.close()
    }
}
