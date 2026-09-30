import XCTest
@testable import PiAgentCore

/// A gate a test opens: what waits on it goes on then.
private actor Gate {
    private var open = false
    func wait() async { while !open { try? await Task.sleep(nanoseconds: 2_000_000) } }
    func release() { open = true }
}

/// A fork that opens with only its latest rows loads the rest of its history
/// in the background (`startHistoryFill`), off the actor, and takes it when
/// idle: then it is the fork an open of its whole journal gives. A send
/// during the load goes as from any chat holding its latest rows; a load
/// cancelled, failed or overtaken leaves such a chat.
final class HistoryFillTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, client: ScriptClient = ScriptClient([]), resume: String? = nil, prepared: JournalReplayConsumer? = nil) throws -> AgentSession {
            // Everything but the latest turn is summarized when compacted.
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                                    client: client, tools: RecordingTools(), traces: traces, resumePath: resume, prepared: prepared,
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
    private let chatID = "chat-0001"

    /// A chat with tools, an edit, a compaction and turns after it, closed.
    private func source(_ chat: Chat) async throws -> String {
        let session = try chat.session(chatID, client: ScriptClient([
            toolReply(["first", "second"]), answer(String(repeating: "after the tools ", count: 400)),
            answer("the original answer"), answer(String(repeating: "the edited answer ", count: 400)),
            answer("answer three"), answer("Summary of everything so far."), answer("answer four"), answer("answer five"),
        ]))
        try await send(session, "u1", "please use the tools")
        try await send(session, "u2", "the original question")
        _ = try await session.edit(fromMessageID: "u2", input: Submission(commandID: "u2b", turnID: "u2b", text: "the edited question"))
        try await eventually { !(await session.isRunning) }
        try await send(session, "u3", "question three")
        try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        try await send(session, "u4", "question four")
        try await send(session, "u5", "question five")
        let sessionPath = await session.path
        await session.close()
        return try XCTUnwrap(sessionPath)
    }

    private struct Held: Equatable {
        var history: [ChatMessage], visible: [String], ledger: MessageVersionLedger, links: [String: [String]]
        var spans: [String: JournalCheckpoint.Row], tasks: [TaskPresentationRecord], partial: Bool, older: Int
        var messages: JSON, total: JSON, lineage: String, pages: [String]
    }
    /// Every field that differs, named.
    private func assertSame(_ made: Held, _ read: Held, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        // Values, compared as values (their descriptions order keys as they please).
        for (label, a, b) in [("history", "\(made.history.map(\.id))", "\(read.history.map(\.id))"), ("history rows", "\(made.history == read.history)", "true"),
                              ("visible", "\(made.visible)", "\(read.visible)"), ("ledger", "\(made.ledger == read.ledger)", "true"),
                              ("links", "\(made.links == read.links)", "true"), ("spans", "\(made.spans == read.spans)", "true"),
                              ("tasks", "\(made.tasks == read.tasks)", "true"), ("partial", "\(made.partial)", "\(read.partial)"), ("older", "\(made.older)", "\(read.older)"),
                              ("messages", "\(made.messages == read.messages)", "true"), ("total", "\(made.total)", "\(read.total)"),
                              ("lineage", made.lineage, read.lineage), ("pages", "\(made.pages)", "\(read.pages)")] where a != b {
            XCTFail("\(what): \(label) differs: \(a.prefix(600)) vs \(b.prefix(600))", file: file, line: line)
        }
        XCTAssertEqual(made, read, what, file: file, line: line)
    }
    /// What a chat holds and shows: its rows, and, with `paging`, every row a
    /// reader paging back from its latest page reaches (the v2 window).
    private func held(_ session: AgentSession, paging: Bool = true) async throws -> Held {
        let snapshot = await session.snapshot()
        var pages: [String] = [], params: JSON = ["version": 2]
        for _ in 0..<(paging ? 64 : 0) {
            let page = try await session.historyWindow(params)
            pages = page["messages"].list.compactMap { $0["id"].text } + pages
            guard !page["older"].isNull else { break }
            params = ["version": 2, "cursor": page["older"]]
        }
        return Held(history: await session.history, visible: await session.visible.map(\.id), ledger: await session.versions.ledger,
                    links: await session.pendingRequestLinks, spans: await session.rowSpans, tasks: await session.recentTaskPresentations,
                    partial: await session.partialHistory, older: await session.olderRows, messages: snapshot["messages"], total: snapshot["total"],
                    lineage: await session.presentationTimeline, pages: pages)
    }
    /// The fork at `path`, opened from its whole journal.
    private func whole(_ chat: Chat, _ id: String, _ path: String) async throws -> Held {
        let meta = JournalCheckpoint.read(for: URL(fileURLWithPath: path))
        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
        defer { try? meta?.write(for: URL(fileURLWithPath: path)) }
        let session = try chat.session(id, resume: path)
        let partial = await session.partialHistory
        XCTAssertFalse(partial)
        let value = try await held(session)
        await session.close()
        return value
    }
    private func loaded(_ session: AgentSession) async throws {
        try await eventually(timeout: .seconds(30)) { !(await session.partialHistory) }
    }

    /// A whole fork of a chat opened from its metadata file, and a fork from
    /// a reply of a chat opened whole, open with their latest rows and load
    /// the rest: then each is the fork an open of its whole journal gives,
    /// its rows and pages, and its lineage and shown rows as before.
    func testAFilledForkIsItsWholeJournalsFork() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        for (name, point) in [("fork-a", nil), ("fork-b", "reply")] as [(String, String?)] {
            let meta = JournalCheckpoint.read(for: URL(fileURLWithPath: path))
            if point != nil { JournalCheckpoint.remove(for: URL(fileURLWithPath: path)) }
            let parent = try chat.session(chatID, resume: path)
            try? meta?.write(for: URL(fileURLWithPath: path))
            let partialParent = await parent.partialHistory
            XCTAssertEqual(partialParent, point == nil, "\(name): the chat was opened from its file, or whole")
            var at: String?
            if point != nil { at = await parent.history.last { $0.role == "assistant" && $0.text == "answer four" }?.id; XCTAssertNotNil(at) }
            let (result, replay) = try await parent.forked(to: name, at: at)
            await parent.close()
            let forkPath = try XCTUnwrap(result["path"].text)
            XCTAssertTrue(replay.r.resumed, "\(name): opens with its latest rows")
            let fork = try chat.session(name, resume: forkPath, prepared: replay)
            let before = try await held(fork)
            XCTAssertTrue(before.partial)
            await fork.startHistoryFill()
            try await loaded(fork)
            let after = try await held(fork)
            let events = await fork.eventPage(since: 0)["events"].list.compactMap { $0["type"].text }
            await fork.close()
            let read = try await whole(chat, name, forkPath)
            assertSame(after, read, "\(name): the fork an open of its whole journal gives")
            XCTAssertEqual(after.lineage, before.lineage, "\(name): the same timeline")
            XCTAssertEqual(Array(after.visible.suffix(before.visible.count)), before.visible, "\(name): the rows it showed, last")
            XCTAssertEqual(after.pages, before.pages, "\(name): the same rows paging back")
            XCTAssertTrue(events.contains("history.loaded"), "\(name): the app is told")
        }
    }

    /// A send during the load goes at once, with the context the fork had,
    /// as from any chat holding its latest rows; the load, done during the
    /// run, is taken when the run ends, and then the fork is its whole
    /// journal's, the new turn included.
    func testASendDuringTheLoadGoesAtOnceAndTheLoadWaitsForTheRun() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let parent = try chat.session(chatID, resume: path)
        let (result, replay) = try await parent.forked(to: "fork-c")
        await parent.close()
        let forkPath = try XCTUnwrap(result["path"].text)
        let client = ScriptClient([answer("the fork's answer")], holdFirst: true), gate = Gate()
        let fork = try chat.session("fork-c", client: client, resume: forkPath, prepared: replay)
        await fork.holdHistoryFill { stage in if stage == "replay" { await gate.wait() } }
        await fork.startHistoryFill()
        let context = await fork.context.map(\.id)
        let started = Date()
        _ = try await fork.submit(Submission(commandID: "f1", turnID: "f1", text: "a question for the fork"), steer: false)
        try await eventually { await client.count == 1 }
        let waited = Date().timeIntervalSince(started)
        let asked = await client.requests.last?.map(\.id)
        XCTAssertEqual(asked, context + ["f1"], "the context the fork had, and the question")
        XCTAssertLessThan(waited, 5, "not held by the load")
        // The load finishes during the run: it waits for the run's end.
        await gate.release()
        try await Task.sleep(nanoseconds: 200_000_000)
        let during = await fork.partialHistory
        XCTAssertTrue(during, "not taken during the run")
        await client.release()
        try await eventually { !(await fork.isRunning) }
        try await loaded(fork)
        let after = try await held(fork)
        await fork.close()
        let read = try await whole(chat, "fork-c", forkPath)
        // The rows of the turn this fork ran are the ones it holds in memory,
        // as any chat that ran a turn holds them (a load of every row keeps
        // them): compared by identity. Every row written before, by value.
        let turn = Set(after.history.suffix(2).map(\.id))
        XCTAssertEqual(turn.count, 2); XCTAssertTrue(turn.contains("f1"))
        var made = after, reread = read
        made.history = after.history.filter { !turn.contains($0.id) }; reread.history = read.history.filter { !turn.contains($0.id) }
        XCTAssertEqual(after.history.map(\.id), read.history.map(\.id))
        assertSame(made, reread, "the whole journal's fork, the new turn included")
    }

    /// A load cancelled (the fork closed, unloaded) or failed (a damaged
    /// record before the rows it holds) leaves a fork holding its latest
    /// rows, which goes on working; one overtaken by a load of every row on
    /// the actor is not taken.
    func testACancelledFailedOrOvertakenLoadLeavesTheForkAsItWas() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let parent = try chat.session(chatID, resume: path)
        var forks: [(String, String, JournalReplayConsumer)] = []
        for name in ["fork-d", "fork-e", "fork-f", "fork-g"] {
            let (result, replay) = try await parent.forked(to: name)
            forks.append((name, try XCTUnwrap(result["path"].text), replay))
        }
        await parent.close()
        // Closed mid-load.
        let gate = Gate()
        do {
            let (name, forkPath, replay) = forks[0]
            let fork = try chat.session(name, resume: forkPath, prepared: replay)
            await fork.holdHistoryFill { stage in if stage == "replay" { await gate.wait() } }
            await fork.startHistoryFill()
            await fork.close()
            let running = await fork.historyFill.map { _ in true }
            XCTAssertNil(running, "closed: the load is let go of at once")
            await gate.release()
            try await Task.sleep(nanoseconds: 100_000_000)
            let partial = await fork.partialHistory
            XCTAssertTrue(partial, "closed: nothing taken")
        }
        // Unloaded mid-load.
        do {
            let (name, forkPath, replay) = forks[1], hold = Gate()
            let fork = try chat.session(name, resume: forkPath, prepared: replay)
            await fork.holdHistoryFill { stage in if stage == "replay" { await hold.wait() } }
            await fork.startHistoryFill()
            let unloaded = await fork.unloadIfIdle()
            XCTAssertTrue(unloaded)
            let running = await fork.historyFill.map { _ in true }
            XCTAssertNil(running, "unloaded: the load is let go of at once")
            await hold.release()
            try await Task.sleep(nanoseconds: 100_000_000)
            let partial = await fork.partialHistory
            XCTAssertTrue(partial, "unloaded: nothing taken")
        }
        // Failed: a record before the rows the fork holds no longer parses.
        do {
            let (name, forkPath, replay) = forks[2]
            var bytes = try Data(contentsOf: URL(fileURLWithPath: forkPath))
            let marker = Data(#""role":"user""#.utf8), range = try XCTUnwrap(bytes.range(of: marker))
            bytes.replaceSubrange(range, with: Data(#""role":"usex""#.utf8))
            try bytes.write(to: URL(fileURLWithPath: forkPath))
            let fork = try chat.session(name, client: ScriptClient([answer("still working")]), resume: forkPath, prepared: replay)
            let before = try await held(fork, paging: false)
            XCTAssertTrue(before.partial)
            await fork.startHistoryFill()
            try await eventually { await fork.historyFill.map { _ in true } == nil }
            let after = try await held(fork, paging: false)
            XCTAssertEqual(after, before, "failed: the fork as it was")
            try await send(fork, "f2", "does it still work")
            let rows = await fork.visible.map(\.id)
            XCTAssertTrue(rows.contains("f2"), "and it goes on working")
            await fork.close()
        }
        // Overtaken: every row loaded on the actor first.
        do {
            let (name, forkPath, replay) = forks[3], hold = Gate()
            let fork = try chat.session(name, resume: forkPath, prepared: replay)
            await fork.holdHistoryFill { stage in if stage == "replay" { await hold.wait() } }
            await fork.startHistoryFill()
            try await fork.ensureFullHistory()
            let loadedFirst = try await held(fork)
            let running = await fork.historyFill.map { _ in true }
            XCTAssertNil(running, "the load is let go of")
            await hold.release()
            try await Task.sleep(nanoseconds: 100_000_000)
            let after = try await held(fork)
            XCTAssertEqual(after, loadedFirst, "overtaken: nothing taken twice")
            await fork.close()
            let read = try await whole(chat, name, forkPath)
            assertSame(after, read, "overtaken")
        }
    }

    /// A load stopped while its history is being made (the replay done, the
    /// rows being made off the actor): the making stops too, and nothing is
    /// taken.
    func testALoadStoppedWhileItsHistoryIsBeingMadeStopsThere() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let parent = try chat.session(chatID, resume: path)
        let (result, replay) = try await parent.forked(to: "fork-p")
        await parent.close()
        let forkPath = try XCTUnwrap(result["path"].text), gate = Gate()
        let fork = try chat.session("fork-p", resume: forkPath, prepared: replay)
        await fork.holdHistoryFill { stage in if stage == "prepare" { await gate.wait() } }
        await fork.startHistoryFill()
        try await eventually { await fork.historyFill?.preparation != nil }
        let making = await fork.historyFill?.preparation
        let preparation = try XCTUnwrap(making)
        await fork.close()
        XCTAssertTrue(preparation.isCancelled, "the making stops with the load")
        await gate.release()
        if case .success = await preparation.value { XCTFail("nothing made once stopped") }
        let partial = await fork.partialHistory
        XCTAssertTrue(partial, "nothing taken")
    }

    /// A chat whose kept replay is far behind its journal (made in this run
    /// and grown since) forks from its metadata file, as its reopen would,
    /// not by replaying all of it: the fork opens with its latest rows and
    /// loads the rest, and is its whole journal's.
    func testAChatFarAheadOfItsKeptReplayForksFromItsMetadataFile() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        // Opened whole, its kept replay is the whole journal's.
        let meta = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)))
        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
        let parent = try chat.session(chatID, resume: path)
        try meta.write(for: URL(fileURLWithPath: path))
        let whole0 = await parent.durable?.r.resumed
        XCTAssertEqual(whole0, false)
        // Written behind the chat's kept replay: more than a fork takes it on by.
        let filler = String(repeating: "x", count: 1 << 20)
        try await parent.appendForTesting((0..<9).map { ["type": "custom", "customType": "test.filler", "data": ["text": JSON(filler), "n": JSON($0)]] })
        let coveredBytes = await parent.durable?.r.coveredBytes, sizeBytes = await parent.journalSizeForTesting
        let covered = try XCTUnwrap(coveredBytes), size = try XCTUnwrap(sizeBytes)
        XCTAssertGreaterThan(size - covered, AgentSession.forkCatchUpLimit)
        let (result, replay) = try await parent.forked(to: "fork-q")
        XCTAssertTrue(replay.r.resumed, "from the chat's metadata file")
        let keptReplay = await parent.durable
        let kept = try XCTUnwrap(keptReplay)
        XCTAssertEqual(kept.r.coveredBytes, size); XCTAssertTrue(kept.r.resumed, "the chat keeps that replay")
        await parent.close()
        let forkPath = try XCTUnwrap(result["path"].text)
        let fork = try chat.session("fork-q", resume: forkPath, prepared: replay)
        await fork.startHistoryFill()
        try await loaded(fork)
        let after = try await held(fork)
        await fork.close()
        let read = try await whole(chat, "fork-q", forkPath)
        assertSame(after, read, "from the metadata file, filled")
    }

    /// Through the host: a fork opened with its latest rows loads the rest,
    /// and a quiesce stops a load under way.
    func testTheHostStartsTheLoadAndAQuiesceStopsIt() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let path = try await source(chat)
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(chat.root.path), "directory": JSON(chat.state.path)])
        _ = try await host.command("session.open", sessionID: chatID, params: ["profile": chat.profile.raw, "apiKey": "fixture", "path": JSON(path)])
        let result = try await host.command("session.fork", sessionID: chatID, params: ["forkSessionId": "fork-h"])
        XCTAssertEqual(result["accepted"].flag, true)
        let loadedFork = await host.loadedSession("fork-h")
        let fork = try XCTUnwrap(loadedFork)
        try await loaded(fork)
        _ = try await host.command("workspace.quiesce", sessionID: nil, params: [:])
        let fill = await fork.historyFill.map { _ in true }
        XCTAssertNil(fill)
        await host.shutdown()
    }
}
