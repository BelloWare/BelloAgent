import XCTest
@testable import PiAgentCore

/// A chat opened from its journal's metadata file reads the rows it did not
/// load from the journal, where they are, instead of loading every row. Every
/// read must answer exactly as the chat holding every row answered, and the
/// chat must go on holding only the rows it loaded.
final class OlderRowsTests: XCTestCase {
    private struct Chat { let root: URL, state: URL, profile: Profile, resources: Resources, path: String }

    private func session(_ chat: Chat, path: String? = nil) throws -> AgentSession {
        try AgentSession(id: "older", profile: chat.profile, apiKey: "test", cwd: chat.root, directory: chat.state, readOnly: true,
                         resources: chat.resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(),
                         resumePath: path ?? chat.path, autoCompaction: false)
    }
    private func send(_ session: AgentSession, _ turn: String, _ text: String) async throws {
        _ = try await session.submit(Submission(commandID: "c-" + turn, turnID: turn, text: text), steer: false)
        try await eventually { !(await session.isRunning) }
    }

    /// Tool calls (reusing call ids from turn to turn), an edit that hides a
    /// question and its answer, then two compactions with turns after each:
    /// the metadata file resumes after the second, so the edit's hidden rows,
    /// the first compaction's rows and most shown rows are before the rows a
    /// reopened chat loads.
    private func chat() async throws -> Chat {
        let root = try temporaryDirectory(); addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root)
        let long = String(repeating: "evidence ", count: 60)
        let replies: [ModelReply] = [
            toolReply(["first"]), answer("Answer 0 " + long),
            answer("Answer 1 " + long),
            toolReply(["first", "second"]), answer("Answer 2 " + long),
            answer("Answer 3 " + long),
            answer("Answer 3, edited " + long),
            toolReply(["second"]), answer("Answer 4 " + long),
            answer("Answer 5 " + long),
            answer("Summary: five questions were answered."),
            toolReply(["first"]), answer("Answer 6 " + long),
            answer("Answer 7 " + long),
            answer("Summary: seven questions were answered."),
            answer("Answer 8"),
        ]
        let writer = try AgentSession(id: "older", profile: profile, apiKey: "test", cwd: root, directory: state, readOnly: true, resources: resources,
                                      client: ScriptClient(replies), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false,
                                      compactionPolicy: { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }())
        for turn in 0..<4 { try await send(writer, "t\(turn)", "Question \(turn)") }
        _ = try await writer.edit(fromMessageID: "t3", input: Submission(commandID: "edit", turnID: "t3-edited", text: "Question 3, edited"))
        try await eventually { !(await writer.isRunning) }
        for turn in 4..<6 { try await send(writer, "t\(turn)", "Question \(turn)") }
        try await writer.compact(commandID: "compact")
        try await eventually { !(await writer.isRunning) }
        for turn in 6..<8 { try await send(writer, "t\(turn)", "Question \(turn)") }
        try await writer.compact(commandID: "compact-again")
        try await eventually { !(await writer.isRunning) }
        try await send(writer, "t8", "Question 8")
        let written = await writer.path
        let path = try XCTUnwrap(written)
        await writer.close()
        return Chat(root: root, state: state, profile: profile, resources: resources, path: path)
    }
    /// The same journal and metadata file under another name.
    private func copy(_ chat: Chat) throws -> String {
        let copy = chat.state.appendingPathComponent("copy-" + UUID().uuidString + ".jsonl")
        try FileManager.default.copyItem(atPath: chat.path, toPath: copy.path)
        try FileManager.default.copyItem(at: JournalCheckpoint.url(for: URL(fileURLWithPath: chat.path)), to: JournalCheckpoint.url(for: copy))
        return copy.path
    }

    /// A read's answer without what names the session that gave it.
    private static func plain(_ value: JSON) -> JSON {
        switch value {
        case .object(let fields): return .object(fields.filter { $0.key != "incarnation" }.mapValues(plain))
        case .array(let items): return .array(items.map(plain))
        default: return value
        }
    }

    /// Every read a reader can make of the chat, in order: each page walking
    /// back from the latest and forward from the first, a page around every
    /// shown row, searches, every row's text, every retained message's body
    /// and every tool call's input.
    private func reads(_ session: AgentSession, ids: [String], calls: [(String, String)]) async throws -> [(String, JSON)] {
        var answers: [(String, JSON)] = []
        func record(_ what: String, _ read: () async throws -> JSON) async {
            do { answers.append((what, Self.plain(try await read()))) }
            catch let error as AgentError { answers.append((what, ["error": JSON(error.code)])) }
            catch { answers.append((what, ["error": JSON("\(error)")])) }
        }
        var page = try await session.historyWindow(["version": 2]), pages = 0
        answers.append(("latest", Self.plain(page)))
        while !page["older"].isNull, pages < 100 {
            page = try await session.historyWindow(["version": 2, "direction": "older", "cursor": page["older"]]); pages += 1
            answers.append(("older \(pages)", Self.plain(page)))
        }
        pages = 0
        while !page["newer"].isNull, pages < 100 {
            page = try await session.historyWindow(["version": 2, "direction": "newer", "cursor": page["newer"]]); pages += 1
            answers.append(("newer \(pages)", Self.plain(page)))
        }
        for id in ids { await record("around \(id)") { try await session.historyWindow(["version": 2, "around": JSON(id)]) } }
        for query in ["", "question", "Answer 2", "done first", "evidence", "nothing like this"] {
            var start = 0, rounds = 0
            while rounds < 20 {
                let found = try await session.contentSearch(["query": JSON(query), "start": JSON(start)]); rounds += 1
                answers.append(("search \(query) from \(start)", Self.plain(found)))
                guard let next = found["next"].int else { break }
                start = next
            }
        }
        let all = try await session.contentSearch(["query": ""])
        let total = all["total"].int ?? 0, revision = all["revision"]
        for index in 1...max(1, total) {
            await record("content \(index)") { try await session.contentPage(["first": 1, "last": JSON(total), "index": JSON(index), "offset": 0, "revision": revision]) }
        }
        for id in ids {
            await record("text \(id)") { try await session.messageRead(id: id, field: "text", offset: 0) }
            await record("thinking \(id)") { try await session.messageRead(id: id, field: "thinking", offset: 0) }
        }
        for (message, call) in calls { await record("input \(message) \(call)") { try await session.toolInput(messageID: message, callID: call) } }
        return answers
    }

    /// Every read of a chat reopened from its metadata file, against the same
    /// reads of the chat holding every row, as it did before.
    @discardableResult
    private func assertReadsMatch(_ chat: Chat, file: StaticString = #filePath, line: UInt = #line) async throws -> OlderRows? {
        let first = try session(chat); await first.close()
        let checkpoint = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: chat.path)), file: file, line: line)
        XCTAssertGreaterThan(checkpoint.rowsBefore, 0, "The file resumes after the compaction", file: file, line: line)

        // The chat as it read before: every row loaded when a read reached them.
        let full = try session(chat, path: try copy(chat))
        let olderBefore = await full.olderRows
        XCTAssertGreaterThan(olderBefore, 0, file: file, line: line)
        try await full.ensureFullHistory()
        let history = await full.history, shownIDs = await full.visible.map(\.id)
        XCTAssertTrue(history.contains { $0.id == "t3" } && !shownIDs.contains("t3"), "The edit hid the original question", file: file, line: line)
        let ids = history.map(\.id) + ["no-such-row"]
        let calls = history.flatMap { message in message.content.filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text }.map { (message.id, $0) } }
        XCTAssertGreaterThan(calls.count, Set(calls.map(\.1)).count, "Call ids repeat across turns", file: file, line: line)
        let expected = try await reads(full, ids: ids, calls: calls)
        await full.close()

        let reader = try session(chat)
        let loaded = await reader.visible.count, loadedHistory = await reader.history.count
        try await reader.loadOlderRows()
        let actual = try await reads(reader, ids: ids, calls: calls)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (got, want) in zip(actual, expected) {
            XCTAssertEqual(got.0, want.0, file: file, line: line)
            XCTAssertEqual(got.1, want.1, "\(want.0) reads as it did with every row loaded", file: file, line: line)
        }
        let partial = await reader.partialHistory, rows = await reader.visible.count, held = await reader.history.count
        let index = await reader.olderIndex
        XCTAssertTrue(partial, "The chat still holds only the rows it loaded", file: file, line: line)
        XCTAssertEqual(rows, loaded, file: file, line: line); XCTAssertEqual(held, loadedHistory, file: file, line: line)
        XCTAssertEqual(index?.shown, olderBefore, file: file, line: line)
        XCTAssertGreaterThan(index?.rows.count ?? 0, olderBefore, "The rows the edit hid are read back too", file: file, line: line)
        XCTAssertFalse(index?.results.isEmpty ?? true, "Older replies' tool calls are paired", file: file, line: line)
        await reader.close()
        return index
    }

    func testRowsReadWhereTheyAreAnswerAsEveryRowLoaded() async throws {
        let index = try await assertReadsMatch(try await chat())
        XCTAssertEqual(index?.kept.count, 0, "Every row is read back, none held")
    }

    /// The first compaction's progress row with no final update after it, as
    /// a crash between the two leaves it: the replay marks it adopted, which
    /// its record alone does not say. That row is held as the replay left it.
    func testAnAdoptedProgressRowIsHeldAsTheReplayLeftIt() async throws {
        let chat = try await chat()
        let url = URL(fileURLWithPath: chat.path)
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let records = try lines.map { try JSON.parse(Data($0.utf8)) }
        let compaction = try XCTUnwrap(records.firstIndex { $0["type"].text == "compaction" })
        let operation = try XCTUnwrap(records[compaction]["nativeCompaction"]["operationId"].text)
        let progress = try XCTUnwrap(records.first { $0["type"].text == "message" && $0["message"]["nativeOperationID"].text == operation }?["id"].text)
        let updates = records.indices.filter { $0 > compaction && records[$0]["customType"].text == "pi-app.presentation.update.v1" && records[$0]["data"]["id"].text == progress }
        XCTAssertFalse(updates.isEmpty, "The progress row's final update follows the compaction")
        for at in updates.reversed() {
            // The record after it names the one before it, so the journal stays one chain.
            if at + 1 < lines.count {
                var next = try JSON.parse(Data(lines[at + 1].utf8)); next["parentId"] = records[at]["parentId"]
                lines[at + 1] = String(decoding: try next.data(), as: UTF8.self)
            }
            lines.remove(at: at)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        JournalCheckpoint.remove(for: url)
        let index = try await assertReadsMatch(chat)
        XCTAssertEqual(index.flatMap { $0.kept[progress] }?.detail, "Compaction · Checkpoint durably adopted")
    }

    /// Paging back from the latest page: the first page past the loaded rows
    /// reads where the older rows are, and every shown row comes once, in
    /// order, as a chat holding every row pages them.
    func testPagingBackReachesEveryRowOnce() async throws {
        let chat = try await chat()
        let first = try session(chat); await first.close()
        let full = try session(chat, path: try copy(chat))
        try await full.ensureFullHistory()
        let all = await full.visible.map(\.id)
        await full.close()

        let reader = try session(chat)
        var page = try await reader.historyWindow(["version": 2]), seen = page["messages"].list.compactMap { $0["id"].text }
        var pages = 0
        while !page["older"].isNull, pages < 100 {
            page = try await reader.historyWindow(["version": 2, "direction": "older", "cursor": page["older"]]); pages += 1
            seen = page["messages"].list.compactMap { $0["id"].text } + seen
            XCTAssertEqual(page["total"].int, all.count)
        }
        XCTAssertEqual(seen, all, "Every shown row once, in order")
        let partial = await reader.partialHistory, index = await reader.olderIndex
        XCTAssertTrue(partial); XCTAssertNotNil(index, "The page past the loaded rows read where the older rows are")
        await reader.close()
    }

    /// A journal no longer holding a row where the replay found it: the read
    /// loads every row instead, as before, and answers from them.
    func testARowNotWhereItWasLoadsEveryRow() async throws {
        let chat = try await chat()
        let first = try session(chat); await first.close()
        let reader = try session(chat)
        try await reader.loadOlderRows()
        let built = await reader.olderIndex
        let index = try XCTUnwrap(built)
        let entry = try XCTUnwrap(index.rows.first { $0.span.id == "t1" })
        // Move the question's record one byte along: its place no longer holds it.
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: chat.path))
        try handle.seek(toOffset: entry.span.offset)
        let bytes = try XCTUnwrap(try handle.read(upToCount: entry.span.length))
        try handle.seek(toOffset: entry.span.offset)
        try handle.write(contentsOf: Data(" ".utf8) + bytes.dropLast())
        try handle.close()
        let read = try await reader.messageRead(id: "t0", field: "text", offset: 0)
        XCTAssertEqual(read["text"].text, "Question 0", "A row still where it was reads as before")
        // Every row loaded from the journal as it is now fails as a full open
        // of it fails; so does the read.
        let copy = chat.state.appendingPathComponent("damaged.jsonl")
        try FileManager.default.copyItem(atPath: chat.path, toPath: copy.path)
        var expected: String?
        do { let opened = try session(chat, path: copy.path); await opened.close() } catch let error as AgentError { expected = error.code }
        XCTAssertNotNil(expected, "The moved record breaks a full open")
        do {
            _ = try await reader.messageRead(id: "t1", field: "text", offset: 0)
            XCTFail("The read answered from a record that is not there")
        } catch let error as AgentError { XCTAssertEqual(error.code, expected) }
        let index2 = await reader.olderIndex
        XCTAssertNil(index2, "Where the rows are is read again, not trusted")
        await reader.close()
    }
}
