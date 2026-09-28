import XCTest
@testable import PiAgentCore

/// A chat opens from its journal's metadata file: the rows from its latest
/// compaction (or edit) on, then only the records after that point. What it
/// opens to must be what a full replay of the journal opens to, over those
/// rows, and a file that does not match its journal is ignored and written
/// again from the journal.
final class JournalCheckpointTests: XCTestCase {
    fileprivate struct Chat { let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore, path: String }

    private func session(_ chat: Chat, _ client: ScriptClient = ScriptClient([])) throws -> AgentSession {
        try AgentSession(id: "checkpointed", profile: chat.profile, apiKey: "test", cwd: chat.root, directory: chat.state, readOnly: true,
                         resources: chat.resources, client: client, tools: RecordingTools(), traces: chat.traces, resumePath: chat.path, autoCompaction: false)
    }
    private func send(_ session: AgentSession, _ turn: Int) async throws {
        _ = try await session.submit(Submission(commandID: "c\(turn)", turnID: "t\(turn)", text: "Question \(turn)"), steer: false)
        try await eventually { !(await session.isRunning) }
    }
    /// Six turns, a compaction that keeps the last, then `after` more turns
    /// and, with `edit`, an edit of the last question: a long chat in small.
    private func chat(after: Int = 2, edit: Bool = false) async throws -> Chat {
        let root = try temporaryDirectory(); addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        var replies: [ModelReply] = (0..<6).map { answer("Answer \($0) " + String(repeating: "evidence ", count: 60)) }
        replies.append(answer("Summary: six questions were answered."))
        replies += (6..<(6 + after + (edit ? 1 : 0))).map { answer("Answer \($0)") }
        let writer = try AgentSession(id: "checkpointed", profile: profile, apiKey: "test", cwd: root, directory: state, readOnly: true, resources: resources,
                                      client: ScriptClient(replies), tools: RecordingTools(), traces: traces, autoCompaction: false,
                                      compactionPolicy: { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }())
        for turn in 0..<6 { try await send(writer, turn) }
        try await writer.compact(commandID: "compact")
        try await eventually { !(await writer.isRunning) }
        for turn in 6..<(6 + after) { try await send(writer, turn) }
        if edit {
            let rows = await writer.visible
            let last = try XCTUnwrap(rows.last { $0.role == "user" })
            _ = try await writer.edit(fromMessageID: last.id, input: Submission(commandID: "edit", turnID: "t-edit", text: "Question, edited"))
            try await eventually { !(await writer.isRunning) }
        }
        let written = await writer.path
        let path = try XCTUnwrap(written)
        await writer.close()
        return Chat(root: root, state: state, profile: profile, resources: resources, traces: traces, path: path)
    }
    private func meta(_ chat: Chat) -> JournalCheckpoint? { JournalCheckpoint.read(for: URL(fileURLWithPath: chat.path)) }

    /// A row as a reader sees it. A compaction's summary row and an edit's
    /// marker are made when the journal is replayed and carry that moment, in
    /// either kind of open.
    private static func row(_ message: ChatMessage) -> JSON { ["compaction", "branch"].contains(message.kind ?? "") ? message.pi.removing(["timestamp"]) : message.pi }

    /// The one open from the file, against the full replay it replaces.
    private func assertSameChat(_ partial: AgentSession, _ full: AgentSession, file: StaticString = #filePath, line: UInt = #line) async {
        let partialVisible = await partial.visible, fullVisible = await full.visible, older = await partial.olderRows
        XCTAssertGreaterThan(older, 0, "The open resumed from the file", file: file, line: line)
        XCTAssertEqual(older + partialVisible.count, fullVisible.count, "Every shown row is counted", file: file, line: line)
        XCTAssertEqual(partialVisible.map(Self.row), fullVisible.suffix(partialVisible.count).map(Self.row), "The rows loaded are the latest rows, as they are", file: file, line: line)
        let partialContext = await partial.context.map(Self.row), fullContext = await full.context.map(Self.row)
        XCTAssertEqual(partialContext, fullContext, "The model context is the same", file: file, line: line)
        let counts = (await partial.assistantMessageCount, await partial.latestAssistantMessageID), fullCounts = (await full.assistantMessageCount, await full.latestAssistantMessageID)
        XCTAssertEqual(counts.0, fullCounts.0, file: file, line: line); XCTAssertEqual(counts.1, fullCounts.1, file: file, line: line)
        let ledger = await partial.versions.ledger, fullLedger = await full.versions.ledger
        XCTAssertEqual(ledger, fullLedger, "Edited messages keep their versions list", file: file, line: line)
        let spend = await partial.spend.record, fullSpend = await full.spend.record
        XCTAssertEqual(spend, fullSpend, file: file, line: line)
        let snapshot = await partial.snapshot(), fullSnapshot = await full.snapshot()
        for key in ["state", "runStatus", "queue", "commands", "queuePaused", "cost"] {
            XCTAssertEqual(snapshot[key], fullSnapshot[key], "Snapshot \(key)", file: file, line: line)
        }
        let ordinal = await partial.presentationOrdinal, fullOrdinal = await full.presentationOrdinal
        XCTAssertGreaterThanOrEqual(ordinal, fullOrdinal, "New parts keep counting up", file: file, line: line)
    }

    func testAChatOpensFromItsMetadataFileAsAFullReplayWould() async throws {
        let chat = try await chat()
        let written = try XCTUnwrap(meta(chat), "The compaction wrote the file while the chat was open")
        XCTAssertEqual(written.sessionID, "checkpointed")
        let reference0 = try session(chat.copyWithoutMeta())
        let fullOlder = await reference0.olderRows
        XCTAssertEqual(fullOlder, 0, "A full open has every row")
        let copyPath = await reference0.path ?? ""
        let copyMeta = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: copyPath)), "A full open writes the file too")
        XCTAssertEqual(copyMeta.rows.map(\.id), written.rows.map(\.id), "Both name the same rows")
        await reference0.close()

        let partial = try session(chat), reference = try session(chat.copyWithoutMeta())
        await assertSameChat(partial, reference)
        await reference.close()

        // It goes on as any chat does: the next request carries the summary
        // and the turns since, not what was summarized.
        let client = ScriptClient([answer("Answer 8")])
        await partial.close()
        let continued = try session(chat, client)
        try await send(continued, 8)
        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.contains { $0.text.contains("Summary: six questions were answered.") })
        XCTAssertTrue(request.contains { $0.text == "Answer 7" })
        XCTAssertFalse(request.contains { $0.text == "Question 0" })
        await continued.close()
        // And the journal it extended still opens in full.
        let check = try session(chat.copyWithoutMeta())
        let rows = await check.visible.count
        XCTAssertEqual(rows, 20, "Nine turns, the compaction's progress row and its summary")
        await check.close()
    }

    func testAnEditMovesTheFileAndOneTheFileMissedIsReplayedInFull() async throws {
        let chat = try await chat(after: 1)
        let before = try XCTUnwrap(meta(chat))
        // Edit the last question from a chat opened from the file: the edit
        // loads every row first, and writes the file again after itself.
        let editor = try session(chat, ScriptClient([answer("Edited answer")]))
        let rows = await editor.visible
        let last = try XCTUnwrap(rows.last { $0.role == "user" })
        _ = try await editor.edit(fromMessageID: last.id, input: Submission(commandID: "edit", turnID: "t-edit", text: "Question, edited"))
        try await eventually { !(await editor.isRunning) }
        await editor.close()
        let after = try XCTUnwrap(meta(chat))
        XCTAssertGreaterThan(after.start, before.start, "The file now resumes after the edit")
        let partial = try session(chat), reference = try session(chat.copyWithoutMeta())
        await assertSameChat(partial, reference)
        await partial.close(); await reference.close()

        // A file from before the edit cannot resume across it: the journal is
        // replayed in full, and the file written again after the edit.
        try before.write(for: URL(fileURLWithPath: chat.path))
        let reopened = try session(chat)
        let older = await reopened.olderRows
        XCTAssertEqual(older, 0, "An edit after the file's checkpoint is replayed in full")
        await reopened.close()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(meta(chat)).start, after.start)
    }

    /// The rows before the loaded ones come from the journal the first time
    /// something reaches for them: a page, a message read, a search.
    func testOlderRowsLoadWhenSomethingReachesForThem() async throws {
        let chat = try await chat()
        let first = try session(chat); await first.close()
        let reference = try session(chat.copyWithoutMeta())
        let allRows = await reference.visible.map(Self.row)

        let paging = try session(chat)
        let latest = try await paging.historyWindow(["version": 2])
        let older = latest["older"]
        XCTAssertFalse(older.isNull, "The first page offers older rows though none are loaded")
        let before = await paging.olderRows
        XCTAssertGreaterThan(before, 0)
        let page = try await paging.historyWindow(["version": 2, "direction": "older", "cursor": older])
        XCTAssertTrue(page["messages"].list.contains { $0["id"].text == "t5" }, "The question before the loaded rows is on the page before them")
        let after = await paging.olderRows, rows = await paging.visible.map(Self.row)
        XCTAssertEqual(after, 0); XCTAssertEqual(rows, allRows, "Every row, as a full open has them")
        await paging.close()

        let reading = try session(chat)
        let read = try await reading.messageRead(id: "t0", field: "text", offset: 0)
        XCTAssertEqual(read["text"].text, "Question 0")
        await reading.close()

        let searching = try session(chat)
        let found = try await searching.contentSearch(["query": "Question 0"])
        XCTAssertFalse(found["hits"].list.isEmpty, "Search covers the whole chat")
        await searching.close(); await reference.close()
    }

    func testAFileThatDoesNotMatchItsJournalIsWrittenAgain() async throws {
        let chat = try await chat()
        // The file a full open writes (the one written during the chat
        // resumes at a later record, equally valid).
        JournalCheckpoint.remove(for: URL(fileURLWithPath: chat.path))
        let first = try session(chat); await first.close()
        let good = try XCTUnwrap(meta(chat))
        let url = JournalCheckpoint.url(for: URL(fileURLWithPath: chat.path))
        var damaged: [(String, (inout JournalCheckpoint) -> Void)] = [
            ("the record it follows", { $0.last.sha256 = String(repeating: "0", count: 64) }),
            ("a row's place", { $0.rows[0].offset += 1 }),
            ("another session", { $0.sessionID = "someone-else" }),
            ("the header", { $0.header.length -= 1 }),
        ]
        damaged.append(("a context row", { $0.context.append("missing") }))
        for (what, damage) in damaged {
            var value = good; damage(&value)
            try value.write(for: URL(fileURLWithPath: chat.path))
            let opened = try session(chat)
            let older = await opened.olderRows
            XCTAssertEqual(older, 0, "\(what): a file that does not match is not used")
            await opened.close()
            XCTAssertEqual(meta(chat), good, "\(what): the file is written again from the journal")
        }
        try Data("not json".utf8).write(to: url)
        let unreadable = try session(chat); await unreadable.close()
        XCTAssertEqual(meta(chat), good, "An unreadable file is written again")
    }
}

private extension JournalCheckpointTests.Chat {
    /// The same journal under another name, with no metadata file: opens in full.
    func copyWithoutMeta() throws -> JournalCheckpointTests.Chat {
        let copy = state.appendingPathComponent("reference-" + UUID().uuidString + ".jsonl")
        try FileManager.default.copyItem(atPath: path, toPath: copy.path)
        return .init(root: root, state: state, profile: profile, resources: resources, traces: traces, path: copy.path)
    }
}
