import XCTest
@testable import PiAgentCore

/// Tools that wait until they are let go, so a test can copy a journal while
/// a batch runs, as a crash would leave it.
private actor HeldBatch: ToolExecuting {
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

/// A fork of the whole chat is a clone of its journal (`clonedFork`): the
/// chat's records as written, then the fork's origin, a spend that starts
/// again, its run state and its context. The fork opens with what its
/// journal replays to, and comes with the metadata file a replay of its
/// journal would write; the chat is left as it was. When that cannot be
/// known, the fork is copied as before.
final class ForkCloneTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, replies: [ModelReply] = [], tools: any ToolExecuting = RecordingTools(), resume: String? = nil,
                     prepared: JournalReplayConsumer? = nil, in directory: URL? = nil) throws -> AgentSession {
            // Everything but the latest turn is summarized when compacted.
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: directory ?? state, readOnly: false, resources: resources,
                                    client: ScriptClient(replies), tools: tools, traces: traces, resumePath: resume, prepared: prepared,
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
    private let chatID = "chat-0001", forkID = "fork-001"

    /// A chat with tools, an edit, a compaction and a turn after it, closed;
    /// then, written into its journal, what three attempts cost.
    private func source(_ chat: Chat) async throws -> String {
        let session = try chat.session(chatID, replies: [
            toolReply(["first", "second"]), answer(String(repeating: "after the tools ", count: 400)),
            answer("the original answer"), answer(String(repeating: "the edited answer ", count: 400)),
            answer("answer three"), answer("Summary of everything so far."), answer("answer four"),
        ])
        try await send(session, "u1", "please use the tools")
        try await send(session, "u2", "the original question")
        _ = try await session.edit(fromMessageID: "u2", input: Submission(commandID: "u2b", turnID: "u2b", text: "the edited question"))
        try await eventually { !(await session.isRunning) }
        try await send(session, "u3", "question three")
        try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        try await send(session, "u4", "question four")
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        await session.close()
        let journal = try SessionJournal(url: URL(fileURLWithPath: path), id: chatID, cwd: chat.root, binding: chat.profile.binding, create: false)
        for usd in [0.25, 0.5] { try journal.append(["type": "custom", "customType": JSON(SessionSpend.recordType), "data": ["usd": JSON(usd), "reported": 1, "unreported": 0]]) }
        try journal.append(["type": "custom", "customType": JSON(SessionSpend.recordType), "data": ["usd": 0, "reported": 0, "unreported": 1]])
        return path
    }

    /// The journal at `path` replayed from its start, on a copy.
    private func fullReplay(_ chat: Chat, id: String, path: String) throws -> JournalReplay {
        let copyRoot = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: copyRoot) }
        let copy = copyRoot.appendingPathComponent("copy.jsonl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let journal = try SessionJournal(url: copy, id: id, cwd: chat.root, binding: chat.profile.binding, create: false)
        return try AgentSession.replay(journal, url: copy, id: id, binding: chat.profile.binding, spendTracked: false, resume: false)
    }
    private func lines(_ path: String) throws -> [Data] { try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map { Data($0) } }
    /// Whether the fork at `path` is a clone of the journal at `source`.
    private func cloned(_ path: String, from source: String) throws -> Bool {
        let fork = try lines(path), chat = try lines(source)
        return fork.count > chat.count && Array(fork[1..<chat.count]) == Array(chat.dropFirst())
    }

    /// A fork of a chat opened from its metadata file starts from that file,
    /// as the chat's own reopen does: the task receipts it carries are the
    /// file's (written while the chat ran, without those of rows an edit hid),
    /// where a replay of the whole journal keeps every receipt until an open
    /// filters out those of hidden rows. Every other part is the replay's, and
    /// the receipts the fork shows once opened are the ones a full open shows.
    private func assertAsItsReplay(_ stored: JournalCheckpoint, _ read: JournalReplay, carried: [TaskPresentationRecord], _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        var expected = read.captured
        expected?.tasks = stored.tasks
        XCTAssertEqual(stored, expected, "\(what): the checkpoint a replay of the fork takes, but for the receipts", file: file, line: line)
        XCTAssertEqual(stored.tasks, carried, "\(what): the receipts its chat's file carried", file: file, line: line)
    }
    private struct Held: Equatable {
        var history: [String], visible: [String], partial: Bool, older: Int, spans: [String: JournalCheckpoint.Row], spend: SessionSpend, messages: JSON, total: JSON
    }
    private func held(_ session: AgentSession) async -> Held {
        let snapshot = await session.snapshot()
        return Held(history: await session.history.map(\.id), visible: await session.visible.map(\.id), partial: await session.partialHistory,
                    older: await session.olderRows, spans: await session.rowSpans, spend: await session.spend, messages: snapshot["messages"], total: snapshot["total"])
    }

    /// Opened whole, the chat's fork is a clone opened whole: what a replay of
    /// its journal gives, its metadata file the one that replay would write,
    /// and a spend that starts again. The chat is left as it was.
    func testAForkOfAChatOpenedWholeIsItsJournalsReplay() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
        let parent = try chat.session(chatID, resume: path)
        let before = await held(parent)
        XCTAssertFalse(before.partial); XCTAssertEqual(before.spend.usd, 0.75)
        let (result, replay) = try await parent.forked(to: forkID)
        let forkPath = try XCTUnwrap(result["path"].text)
        XCTAssertTrue(try cloned(forkPath, from: path), "cloned")
        let after = await held(parent)
        XCTAssertEqual(after, before, "the chat is left as it was")
        let read = try fullReplay(chat, id: forkID, path: forkPath), made = try replay.finished()
        XCTAssertEqual(JournalCheckpoint.read(for: URL(fileURLWithPath: forkPath)), read.captured, "the metadata file a replay writes")
        XCTAssertEqual(made.captured, read.captured)
        XCTAssertEqual(made.history, read.history); XCTAssertEqual(made.visible, read.visible); XCTAssertEqual(made.context, read.context)
        XCTAssertEqual(made.versions.ledger, read.versions.ledger); XCTAssertEqual(made.rowSpans, read.rowSpans)
        XCTAssertEqual(made.recentTaskPresentations, read.recentTaskPresentations); XCTAssertEqual(made.stateRecord, read.stateRecord)
        XCTAssertEqual(made.parentInfo, read.parentInfo); XCTAssertEqual(made.coveredBytes, read.coveredBytes)
        XCTAssertEqual(read.spend, SessionSpend(), "the fork's spend starts again"); XCTAssertTrue(read.spendTracked)
        XCTAssertEqual(read.parentInfo["relationship"].text, "fork"); XCTAssertEqual(read.parentInfo["parentSessionId"].text, chatID)
        // Opened as the host opens it, whole, and the chat an open of its file is.
        let fork = try chat.session(forkID, resume: forkPath, prepared: replay)
        let handed = await held(fork)
        XCTAssertFalse(handed.partial)
        await fork.close()
        JournalCheckpoint.remove(for: URL(fileURLWithPath: forkPath))
        let opened = try chat.session(forkID, resume: forkPath)
        let read2 = await held(opened)
        XCTAssertEqual(handed, read2, "as an open of the file alone")
        let state = await opened.snapshot()
        XCTAssertEqual(state["state"].text, "idle"); XCTAssertEqual(state["queueCount"].int, 0)
        await opened.close(); await parent.close()
    }

    /// Opened from its metadata file, the chat's fork is a clone that opens
    /// from its own, which is the one a replay of its journal writes. The
    /// chat keeps just the rows it had.
    func testAForkOfAChatOpenedFromItsMetadataFileOpensFromItsOwn() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let parent = try chat.session(chatID, resume: path)
        let before = await held(parent)
        XCTAssertTrue(before.partial)
        let (result, replay) = try await parent.forked(to: forkID)
        let forkPath = try XCTUnwrap(result["path"].text)
        XCTAssertTrue(try cloned(forkPath, from: path))
        let after = await held(parent)
        XCTAssertEqual(after, before, "the chat is left as it was")
        let read = try fullReplay(chat, id: forkID, path: forkPath)
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: forkPath)))
        let parentReplay = try await parent.durableReplay()
        assertAsItsReplay(stored, read, carried: try XCTUnwrap(parentReplay).r.recentTaskPresentations, "from the chat's metadata file")
        XCTAssertTrue(replay.r.resumed)
        let fork = try chat.session(forkID, resume: forkPath, prepared: replay)
        let handed = await held(fork)
        XCTAssertTrue(handed.partial, "opened from its metadata file, as its chat was")
        XCTAssertEqual(handed.older, stored.rowsBefore)
        let spend = await fork.spend
        XCTAssertEqual(spend, SessionSpend())
        let receipts = await fork.recentTaskPresentations
        await fork.close()
        // The rows it holds are the last of those an open of the whole file holds.
        JournalCheckpoint.remove(for: URL(fileURLWithPath: forkPath))
        let whole = try chat.session(forkID, resume: forkPath)
        let all = await held(whole)
        XCTAssertEqual(Array(all.visible.suffix(handed.visible.count)), handed.visible)
        XCTAssertEqual(all.visible.count, handed.visible.count + handed.older)
        // A chat opened from its file shows the receipts of the rows it holds.
        let wholeReceipts = await whole.recentTaskPresentations, held = Set(handed.visible)
        XCTAssertEqual(receipts, wholeReceipts.filter { $0.lastSourceID.map(held.contains) ?? false }, "for its rows, the receipts a full open shows")
        XCTAssertFalse(receipts.isEmpty)
        await whole.close(); await parent.close()
    }

    /// Reopened after a crash mid-batch, the chat shows its run's task as
    /// interrupted, in memory only: its fork does not have it, as a replay of
    /// the fork's journal does not.
    func testAReopenedChatsInterruptedTaskIsNotItsForks() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let tools = HeldBatch()
        let running = try chat.session(chatID, replies: [toolReply(["first"]), answer("after the tool")], tools: tools)
        _ = try await running.submit(Submission(commandID: "u1", turnID: "u1", text: "use a tool"), steer: false)
        try await eventually { await tools.started > 0 }
        let runningPath = await running.path
        let crashed = chat.root.appendingPathComponent("crashed"), copy = crashed.appendingPathComponent(chatID + ".jsonl")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: try XCTUnwrap(runningPath)), to: copy)
        await tools.release(); try await eventually { !(await running.isRunning) }
        await running.close()
        let parent = try chat.session(chatID, resume: copy.path, in: crashed)
        let tasks = await parent.recentTaskPresentations
        XCTAssertTrue(tasks.contains { $0.outcome == "interrupted" }, "the chat shows it")
        let (result, replay) = try await parent.forked(to: forkID)
        let forkPath = try XCTUnwrap(result["path"].text)
        XCTAssertTrue(try cloned(forkPath, from: copy.path))
        let read = try fullReplay(chat, id: forkID, path: forkPath)
        XCTAssertEqual(JournalCheckpoint.read(for: URL(fileURLWithPath: forkPath)), read.captured)
        let fork = try chat.session(forkID, resume: forkPath, prepared: replay, in: crashed)
        let forkTasks = await fork.recentTaskPresentations
        XCTAssertFalse(forkTasks.contains { $0.outcome == "interrupted" }, "the fork does not")
        XCTAssertEqual(forkTasks, read.recentTaskPresentations)
        await fork.close(); await parent.close()
    }

    /// Right after an edit, before its replacement is delivered, the edit's
    /// marker comes after the chat's last complete row: a fork leaves it out.
    /// Opened from its metadata file, the chat does not know the marker the
    /// fork's rows name then, so the fork is copied; opened whole, it is
    /// cloned, and its lineage is the replay's.
    func testRightAfterAnEditAForkOfAChatOpenedFromItsFileIsCopied() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let session = try chat.session(chatID, replies: [answer("answer one"), answer("the original answer"), answer("the edited answer")])
        try await send(session, "u1", "question one")
        try await send(session, "u2", "the original question")
        _ = try await session.edit(fromMessageID: "u2", input: Submission(commandID: "u2b", turnID: "u2b", text: "the edited question"))
        try await eventually { !(await session.isRunning) }
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        await session.close()
        // The journal as it stood right after the edit's record, and the
        // metadata file written there.
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)))
        let edited = chat.root.appendingPathComponent("edited"), copy = edited.appendingPathComponent(chatID + ".jsonl")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        try Data(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(Int(stored.start))).write(to: copy)
        XCTAssertEqual(try JSON.parse(try XCTUnwrap(try lines(copy.path).last))["type"].text, "branch")
        XCTAssertTrue(stored.rows.contains { $0.id == stored.lineage }, "the marker is among the file's rows")
        for (whole, name) in [(false, "fork-002"), (true, "fork-003")] {
            if whole { JournalCheckpoint.remove(for: copy) } else { try stored.write(for: copy) }
            let parent = try chat.session(chatID, resume: copy.path, in: edited)
            let partial = await parent.partialHistory
            XCTAssertEqual(partial, !whole)
            let (result, replay) = try await parent.forked(to: name)
            let forkPath = try XCTUnwrap(result["path"].text)
            let read = try fullReplay(chat, id: name, path: forkPath)
            XCTAssertEqual(try cloned(forkPath, from: copy.path), whole, whole ? "cloned" : "copied")
            if whole { XCTAssertEqual(JournalCheckpoint.read(for: URL(fileURLWithPath: forkPath)), read.captured) }
            XCTAssertFalse(read.visible.contains { $0.kind == "branch" && $0.id == stored.lineage }, "the fork leaves the marker out")
            let fork = try chat.session(name, resume: forkPath, prepared: replay, in: edited)
            let rows = await fork.visible.map(\.id)
            XCTAssertEqual(rows, read.visible.map(\.id))
            await fork.close(); await parent.close()
        }
    }

    /// A request ledger row with no eligibility flag counts as eligible to
    /// one replay and not to the other; a fork of the whole chat takes the
    /// chat's context as it is, and its metadata file is its replay's.
    func testALedgerRowWithNoEligibilityFlagForksAsItsJournalReplays() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = chat.state.appendingPathComponent(chatID + ".jsonl")
        do {
            let journal = try SessionJournal(url: path, id: chatID, cwd: chat.root, binding: chat.profile.binding, create: true)
            try journal.append(["type": "message", "message": ["role": "user", "content": "a question"]], id: "q1")
            try journal.append(["type": "message", "message": ["role": "system", "content": "Request", "nativeKind": "requestLedger"]], id: "ledger")
            try journal.append(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "an answer"]]]], id: "a1")
            try journal.append(["type": "message", "message": ["role": "user", "content": "another"]], id: "q2")
            try journal.append(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "another answer"]]]], id: "a2")
        }
        let parent = try chat.session(chatID, resume: path.path)
        let boundary = await parent.sideSeed().messages.map(\.id)
        let (result, replay) = try await parent.forked(to: forkID)
        let forkPath = try XCTUnwrap(result["path"].text)
        XCTAssertTrue(try cloned(forkPath, from: path.path))
        let read = try fullReplay(chat, id: forkID, path: forkPath)
        XCTAssertEqual(JournalCheckpoint.read(for: URL(fileURLWithPath: forkPath)), read.captured)
        XCTAssertEqual(read.context.map(\.id), boundary, "the chat's context")
        XCTAssertEqual(try replay.finished().context.map(\.id), boundary)
        await parent.close()
    }

    /// A fork of a fork starts its spend again too, and spend after a start
    /// adds up from there.
    func testAForkOfAForkStartsItsSpendAgain() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let parent = try chat.session(chatID, resume: path)
        let first = try await parent.fork(to: forkID)
        await parent.close()
        let firstPath = try XCTUnwrap(first["path"].text)
        do {
            let journal = try SessionJournal(url: URL(fileURLWithPath: firstPath), id: forkID, cwd: chat.root, binding: chat.profile.binding, create: false)
            try journal.append(["type": "custom", "customType": JSON(SessionSpend.recordType), "data": ["usd": 0.125, "reported": 1, "unreported": 0]])
        }
        let fork = try chat.session(forkID, resume: firstPath)
        let resumed = await fork.partialHistory
        XCTAssertTrue(resumed, "opened from its metadata file")
        let spend = await fork.spend
        XCTAssertEqual(spend, SessionSpend(usd: 0.125, reported: 1, unreported: 0), "its own, from its start")
        let (second, replay) = try await fork.forked(to: "fork-002")
        let secondPath = try XCTUnwrap(second["path"].text)
        XCTAssertTrue(try cloned(secondPath, from: firstPath))
        let read = try fullReplay(chat, id: "fork-002", path: secondPath)
        XCTAssertEqual(read.spend, SessionSpend(), "the fork of the fork starts again")
        XCTAssertEqual(try replay.finished().spend, SessionSpend())
        let forkReplay = try await fork.durableReplay()
        assertAsItsReplay(try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: secondPath))), read,
                          carried: try XCTUnwrap(forkReplay).r.recentTaskPresentations, "a fork of a fork")
        XCTAssertEqual(read.parentInfo["parentSessionId"].text, forkID)
        await fork.close()
    }

    /// The shared fixture both readers are checked on (the app's in
    /// ForkCloneReaderTests): a cloned fork of a chat opened from its
    /// metadata file, with its own. Written when PI_WRITE_FORK_FIXTURE names
    /// the fixtures directory; the header's working directory is then made
    /// neutral, keeping its length.
    func testWriteTheSharedForkFixture() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PI_WRITE_FORK_FIXTURE"] else { throw XCTSkip("Set PI_WRITE_FORK_FIXTURE to the fixtures directory to write the fixture.") }
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let parent = try chat.session(chatID, resume: path)
        let result = try await parent.fork(to: forkID)
        await parent.close()
        let forkPath = try XCTUnwrap(result["path"].text)
        var lines = try self.lines(forkPath)
        var header = try JSON.parse(lines[0]); header["cwd"] = "/workspace"
        var line = try header.data()
        XCTAssertLessThanOrEqual(line.count, lines[0].count)
        line.append(contentsOf: repeatElement(0x20, count: lines[0].count - line.count)); lines[0] = line
        var checkpoint = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: forkPath)))
        checkpoint.header = .init(offset: 0, length: line.count, sha256: JournalCheckpoint.digest(line))
        let target = URL(fileURLWithPath: directory).appendingPathComponent("fork-clone.jsonl")
        try Data(lines.map { $0 + Data([10]) }.joined()).write(to: target)
        try checkpoint.write(for: target)
    }

    /// The shared fixture replays as a fork: the chat's rows up to the fork,
    /// the edit's version shown, a spend that starts again, the fork's
    /// origin; and its metadata file is the one a replay of it writes.
    func testTheSharedForkFixtureReplaysAsAFork() throws {
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        let fixture = repo.appendingPathComponent("fixtures/native/fork-clone.jsonl")
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("fork-clone.jsonl")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let profile = try fixtureProfile()
        let journal = try SessionJournal(url: copy, id: forkID, cwd: root, binding: profile.binding, create: false)
        let read = try AgentSession.replay(journal, url: copy, id: forkID, binding: profile.binding, spendTracked: false, resume: false)
        XCTAssertEqual(read.spend, SessionSpend()); XCTAssertTrue(read.spendTracked)
        XCTAssertEqual(read.parentInfo["relationship"].text, "fork"); XCTAssertEqual(read.parentInfo["parentSessionId"].text, chatID)
        let texts = read.visible.map(\.text)
        XCTAssertTrue(texts.contains { $0.hasPrefix("the edited answer") }); XCTAssertFalse(texts.contains("the original answer"))
        XCTAssertEqual(texts.last, "answer four")
        // Made from a chat opened from its metadata file: its receipts are
        // that file's (`assertAsItsReplay`); every other part is its replay's.
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: fixture))
        var expected = read.captured; expected?.tasks = stored.tasks
        XCTAssertEqual(stored, expected, "its metadata file is its replay's, but for the receipts")
        let shown = Set(read.visible.map(\.id))
        XCTAssertEqual(stored.tasks.filter { $0.lastSourceID.map(shown.contains) ?? false }, read.recentTaskPresentations.filter { $0.lastSourceID.map(shown.contains) ?? false },
                       "the receipts of the rows it shows are its replay's")
        XCTAssertGreaterThan(stored.rowsBefore, 0, "opened from it, rows before the context are not loaded")
    }

    func testAForkInThePublished116CopiedFormatOpensAndReloadsAsBefore() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        let fixture = repo.appendingPathComponent("fixtures/native/fork-clone.jsonl")
        let expected = try fullReplay(chat, id: forkID, path: fixture.path)
        let path = chat.state.appendingPathComponent("legacy-fork.jsonl")
        // The published 0.1.116 copier retained conversation records,
        // stripped queued branch state, omitted parent cost and run state,
        // then wrote context, origin, zero cost (without reset), and an idle
        // state. Use the shared tool/edit/compaction fixture in that format.
        do {
            let journal = try SessionJournal(url: path, id: forkID, cwd: chat.root, binding: chat.profile.binding, create: true)
            let omitted: Set<String> = [JournalRecordKind.marker, JournalRecordKind.state, JournalRecordKind.sideOrigin,
                JournalRecordKind.forkOrigin, JournalRecordKind.contextRecovery, SessionSpend.recordType]
            for line in try lines(fixture.path).dropFirst() {
                let record = try JSON.parse(line)
                guard !omitted.contains(record["customType"].text ?? "") else { continue }
                try journal.append(record.removing(["id", "parentId", "timestamp", "nativeState"]), id: try identity(record["id"]))
            }
            let ids = expected.context.map(\.id)
            let timeline = EditReplayPlan.forkTimeline(visible: expected.visible.map(\.id), boundary: ids)
            try journal.append(["type": "custom", "customType": JSON(JournalRecordKind.context),
                                "data": ["ids": .array(ids.map { JSON($0) }), "visibleIDs": .array(timeline.map { JSON($0) })]])
            try journal.append(["type": "custom", "customType": JSON(JournalRecordKind.forkOrigin), "data": expected.parentInfo])
            var spend = SessionSpend().record; spend["source"] = "fork"
            XCTAssertTrue(spend[SessionSpend.resetKey].isNull)
            try journal.append(["type": "custom", "customType": JSON(SessionSpend.recordType), "data": spend])
            try journal.append(["type": "custom", "customType": JSON(JournalRecordKind.state),
                                "data": ["active": false, "queue": [], "steering": [], "commands": [], "queuePaused": false]])
        }
        for pass in 0..<2 {
            let session = try chat.session(forkID, resume: path.path)
            try await session.loadFullHistory()
            let history = await session.history, visible = await session.visible, context = await session.context
            let versions = await session.versions.ledger, origin = await session.parentInfo, spend = await session.spend
            XCTAssertEqual(history, expected.history, "open \(pass): retained and hidden rows")
            XCTAssertEqual(visible, expected.visible, "open \(pass): displayed timeline")
            XCTAssertEqual(context, expected.context, "open \(pass): model context")
            XCTAssertEqual(versions, expected.versions.ledger)
            XCTAssertEqual(origin, expected.parentInfo)
            XCTAssertEqual(spend, SessionSpend(), "old copied forks still start with their own zero spend")
            await session.close()
        }
    }

    /// The replay of a fork's journal, and what a fork from the same reply
    /// that was copied replays to, compared: every row, the rows shown, the
    /// context, versions, counts, spend and origin (but for when it was made).
    private func assertLikeTheCopy(_ chat: Chat, clone: (id: String, path: String), copy: (id: String, path: String), _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let cloned = try fullReplay(chat, id: clone.id, path: clone.path), copied = try fullReplay(chat, id: copy.id, path: copy.path)
        XCTAssertTrue(try lines(clone.path).contains { $0.range(of: Data(#""reset":true"#.utf8)) != nil }, "\(what): cloned", file: file, line: line)
        XCTAssertEqual(cloned.history.map(\.id), copied.history.map(\.id), "\(what): rows", file: file, line: line)
        XCTAssertEqual(cloned.visible.map(\.id), copied.visible.map(\.id), "\(what): rows shown", file: file, line: line)
        XCTAssertEqual(cloned.context.map(\.id), copied.context.map(\.id), "\(what): context", file: file, line: line)
        XCTAssertEqual(cloned.versions.ledger, copied.versions.ledger, "\(what): versions", file: file, line: line)
        XCTAssertEqual(cloned.assistantMessageCount, copied.assistantMessageCount, "\(what): replies", file: file, line: line)
        XCTAssertEqual(cloned.latestAssistantMessageID, copied.latestAssistantMessageID, "\(what): latest reply", file: file, line: line)
        XCTAssertEqual(cloned.spend, copied.spend, "\(what): spend", file: file, line: line)
        XCTAssertEqual(cloned.parentInfo.removing(["capturedAt"]), copied.parentInfo.removing(["capturedAt"]), "\(what): origin", file: file, line: line)
    }

    /// From a chat opened from its metadata file: a reply after the file's
    /// checkpoint forks from it; one before it (loaded, or reached by paging
    /// back) from the start; one whose place the chat does not know is
    /// copied. Each clone is what a copied fork from that reply
    /// is, and the chat stays as it was. Each fork is made from a chat opened
    /// afresh: a copied fork loads every row of the chat it is made from.
    func testForksFromRepliesOfAChatOpenedFromItsFileAreWhatCopiesAre() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let whole = try fullReplay(chat, id: chatID, path: path)
        func reply(_ text: String) throws -> String { try XCTUnwrap(whole.history.first { $0.role == "assistant" && $0.text.hasPrefix(text) }?.id) }
        var rebuilt: [String: Bool] = [:]
        func fork(_ name: String, at reply: String, paging: Bool = false) async throws -> String {
            let parent = try chat.session(chatID, resume: path)
            if paging { try await parent.loadOlderRows() }
            let before = await held(parent)
            XCTAssertTrue(before.partial)
            let (result, replay) = try await parent.forked(to: name, at: reply)
            rebuilt[name] = replay.r.resumed
            let forkPath = try XCTUnwrap(result["path"].text)
            // A clone leaves the chat as it was; a copy loads its every row, as before.
            if try isClone(forkPath) { let after = await held(parent); XCTAssertEqual(after, before, "\(name): the chat is left as it was") }
            await parent.close()
            return forkPath
        }
        func isClone(_ path: String) throws -> Bool { try lines(path).contains { $0.range(of: Data(#""reset":true"#.utf8)) != nil } }
        // The chat's metadata file follows its compaction's finished progress,
        // written after the compaction record, as a live chat's does.
        let stored = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)))
        let follows = try JSON.parse(Data(try Data(contentsOf: URL(fileURLWithPath: path))[Int(stored.last.offset)..<Int(stored.last.offset) + stored.last.length]))
        XCTAssertNotEqual(follows["type"].text, "compaction", "the file follows a record after the compaction")
        for (text, label) in [("answer four", "after the checkpoint"), ("answer three", "loaded, before the checkpoint")] {
            let id = try reply(text), copyID = "a-copied-fork-" + String(label.count) + "-with-a-longer-identity"
            let clonePath = try await fork("fork-\(label.count)", at: id), copyPath = try await fork(copyID, at: id)
            try assertLikeTheCopy(chat, clone: ("fork-\(label.count)", clonePath), copy: (copyID, copyPath), label)
        }
        XCTAssertEqual(rebuilt["fork-20"], true, "after the checkpoint: rebuilt from it, not from the start")
        XCTAssertEqual(rebuilt["fork-29"], false, "before the checkpoint: rebuilt from the start")
        // A reply the chat never loaded, in an edited timeline: copied until
        // paging back learns where it is.
        let early = try reply("the edited answer")
        let unknownPath = try await fork("fork-x", at: early)
        XCTAssertFalse(try isClone(unknownPath), "copied: its place is not known")
        let clonePath = try await fork("fork-y", at: early, paging: true), copyPath = try await fork("a-copied-fork-from-an-unloaded-reply", at: early)
        try assertLikeTheCopy(chat, clone: ("fork-y", clonePath), copy: ("a-copied-fork-from-an-unloaded-reply", copyPath), "never loaded, then indexed")
    }

    /// A request ledger row with no eligibility flag after the checkpoint is
    /// in a fork's context, as the replay a copy uses has it; and a reply
    /// whose tool batch lost a result forks at the result it has.
    func testALedgerRowAfterTheCheckpointAndABatchMissingAResultForkAsCopiesDo() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        do {
            let journal = try SessionJournal(url: URL(fileURLWithPath: path), id: chatID, cwd: chat.root, binding: chat.profile.binding, create: false)
            try journal.append(["type": "message", "message": ["role": "user", "content": "one more"]], id: "q9")
            try journal.append(["type": "message", "message": ["role": "system", "content": "Request", "nativeKind": "requestLedger"]], id: "ledger-9")
            try journal.append(["type": "message", "message": ["role": "system", "content": "Request", "nativeKind": "requestLedger", "nativeReplayEligible": false]], id: "ledger-10")
            try journal.append(["type": "message", "message": ["role": "assistant", "content": [["type": "toolCall", "id": "c1", "name": "first", "arguments": [:]], ["type": "toolCall", "id": "c2", "name": "second", "arguments": [:]]]]], id: "calls-9")
            try journal.append(["type": "message", "message": ["role": "toolResult", "toolCallId": "c1", "toolName": "first", "content": [["type": "text", "text": "done"]]]], id: "result-9")
            try journal.append(["type": "message", "message": ["role": "user", "content": "and after"]], id: "q10")
            try journal.append(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "the answer after"]]]], id: "a10")
        }
        for (label, opened) in [("whole", false), ("from its file", true)] {
            if !opened { JournalCheckpoint.remove(for: URL(fileURLWithPath: path)) }
            let parent = try chat.session(chatID, resume: path)
            for (reply, name) in [("calls-9", "b"), ("a10", "c")] {
                let clone = try await parent.fork(to: "fork-\(name)\(opened ? 1 : 0)", at: reply)
                let copyID = "a-copied-fork-\(name)-\(opened)-with-a-longer-identity"
                let copy = try await parent.fork(to: copyID, at: reply)
                try assertLikeTheCopy(chat, clone: ("fork-\(name)\(opened ? 1 : 0)", try XCTUnwrap(clone["path"].text)), copy: (copyID, try XCTUnwrap(copy["path"].text)), "\(label), \(reply)")
                let forked = try fullReplay(chat, id: "fork-\(name)\(opened ? 1 : 0)", path: try XCTUnwrap(clone["path"].text))
                if reply == "calls-9" { XCTAssertEqual(forked.history.last?.id, "result-9", "\(label): at the result it has") }
                else {
                    XCTAssertTrue(forked.context.map(\.id).contains("ledger-9"), "\(label): the ledger row with no flag, as the copy's replay has it")
                    XCTAssertFalse(forked.context.map(\.id).contains("ledger-10"), "\(label): not one no request sends")
                }
            }
            await parent.close()
        }
    }

    /// A message that carries a fork's context kind is a message to one replay
    /// and a context record to the other, which takes a checkpoint there: a
    /// fork from a reply after it is rebuilt from the start, and has the
    /// copy's context. And a chat opened whole gives, from a reply, a fork
    /// the host opens whole, as a copy's.
    func testForksFromRepliesAfterAMessageCarryingTheContextKindAndOfAWholeChat() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = chat.state.appendingPathComponent(chatID + ".jsonl")
        do {
            let journal = try SessionJournal(url: path, id: chatID, cwd: chat.root, binding: chat.profile.binding, create: true)
            try journal.append(["type": "message", "message": ["role": "user", "content": "a question"]], id: "u")
            try journal.append(["type": "message", "customType": JSON(JournalRecordKind.context),
                                "message": ["role": "assistant", "content": [["type": "text", "text": "cut off"]], "nativeReplayEligible": false]], id: "p")
            try journal.append(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "the answer"]]]], id: "a")
        }
        for opened in [false, true] {
            if opened {
                // Opened whole once, it has the checkpoint its open took at "p".
                let first = try chat.session(chatID, resume: path.path); await first.close()
                XCTAssertEqual(JournalCheckpoint.read(for: path)?.lastID, "p")
            }
            let parent = try chat.session(chatID, resume: path.path)
            let partial = await parent.partialHistory
            XCTAssertEqual(partial, opened)
            let (clone, replay) = try await parent.forked(to: "fork-\(opened ? 1 : 0)", at: "a")
            await parent.close()
            let copyParent = try chat.session(chatID, resume: path.path)
            let copy = try await copyParent.fork(to: "a-copied-fork-\(opened)-with-a-longer-identity", at: "a")
            await copyParent.close()
            try assertLikeTheCopy(chat, clone: ("fork-\(opened ? 1 : 0)", try XCTUnwrap(clone["path"].text)),
                                  copy: ("a-copied-fork-\(opened)-with-a-longer-identity", try XCTUnwrap(copy["path"].text)), opened ? "opened from its file" : "opened whole")
            XCTAssertEqual(try fullReplay(chat, id: "fork-\(opened ? 1 : 0)", path: try XCTUnwrap(clone["path"].text)).context.map(\.id), ["u", "a"])
            // The host opens the fork with its replay: whole, as its chat was opened whole.
            let fork = try chat.session("fork-\(opened ? 1 : 0)", resume: try XCTUnwrap(clone["path"].text), prepared: replay)
            let forkPartial = await fork.partialHistory
            XCTAssertFalse(forkPartial, "rebuilt from the start, the fork is whole")
            await fork.close()
        }
    }

    /// A chat opened whole, with a compaction before the reply: the fork from
    /// the reply is rebuilt from that checkpoint, as copies of it are, and
    /// opens with its latest rows, fast; then it loads the rest in the
    /// background (`startHistoryFill`) and is the fork its whole journal is.
    func testAForkFromAReplyOfAChatOpenedWholeOpensFastThenLoadsTheRest() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
        let parent = try chat.session(chatID, resume: path)
        let partial = await parent.partialHistory
        XCTAssertFalse(partial)
        let found = await parent.history.first { $0.role == "assistant" && $0.text.hasPrefix("answer four") }?.id
        let latest = try XCTUnwrap(found)
        let (clone, replay) = try await parent.forked(to: "fork-w", at: latest)
        let copy = try await parent.fork(to: "a-copied-fork-of-a-whole-chat", at: latest)
        await parent.close()
        let clonePath = try XCTUnwrap(clone["path"].text)
        try assertLikeTheCopy(chat, clone: ("fork-w", clonePath), copy: ("a-copied-fork-of-a-whole-chat", try XCTUnwrap(copy["path"].text)), "opened whole")
        XCTAssertTrue(replay.r.resumed, "rebuilt from the checkpoint")
        let read = try fullReplay(chat, id: "fork-w", path: clonePath)
        XCTAssertEqual(JournalCheckpoint.read(for: URL(fileURLWithPath: clonePath)), read.captured, "its metadata file is its replay's")
        let fork = try chat.session("fork-w", resume: clonePath, prepared: replay)
        let forkPartial = await fork.partialHistory
        XCTAssertTrue(forkPartial, "opens with its latest rows")
        await fork.startHistoryFill()
        try await eventually(timeout: .seconds(30)) { !(await fork.partialHistory) }
        let rows = await fork.visible.map(\.id)
        XCTAssertEqual(rows, read.visible.map(\.id), "then every row")
        await fork.close()
    }

    /// A chat whose run is going is copied, as before: its boundary is not
    /// its journal's end.
    func testARunningChatsForkIsCopied() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let tools = HeldBatch()
        let parent = try chat.session(chatID, replies: [answer("answer one"), toolReply(["first"]), answer("after the tool")], tools: tools)
        try await send(parent, "u1", "question one")
        _ = try await parent.submit(Submission(commandID: "u2", turnID: "u2", text: "use a tool"), steer: false)
        try await eventually { await tools.started > 0 }
        let result = try await parent.fork(to: forkID)
        let sessionPath = await parent.path
        XCTAssertFalse(try cloned(try XCTUnwrap(result["path"].text), from: try XCTUnwrap(sessionPath)), "copied")
        await tools.release(); try await eventually { !(await parent.isRunning) }
        await parent.close()
    }
}
