import XCTest
@testable import PiAgentCore

/// A chat's run-state records hold only the receipts that changed, with the
/// whole list now and then (`CommandReceipts`), and every open rebuilds the
/// same 128 receipts the chat had: a full replay, an open from the metadata
/// file, after a failed write, and from records written before this format.
final class CommandReceiptsTests: XCTestCase {
    private struct Chat { let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore }

    private func chat() throws -> Chat {
        let root = try temporaryDirectory(); addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile(), resources: Resources(cwd: root, home: root), traces: TraceStore())
    }
    private func session(_ chat: Chat, replies: [ModelReply] = [], path: String? = nil, failing: StateWriteFailure? = nil) throws -> AgentSession {
        try AgentSession(id: "receipts", profile: chat.profile, apiKey: "test", cwd: chat.root, directory: chat.state, readOnly: true, resources: chat.resources,
                         client: ScriptClient(replies), tools: RecordingTools(), traces: chat.traces, resumePath: path, autoCompaction: false,
                         compactionPolicy: { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }(),
                         beforeJournalAppend: { record in try failing?.check(record) })
    }
    private func send(_ session: AgentSession, _ turn: Int) async throws {
        _ = try await session.submit(Submission(commandID: "command-\(turn)", turnID: "turn-\(turn)", text: "Question \(turn)"), steer: false)
        try await eventually { !(await session.isRunning) }
    }
    /// The journal's run-state records, in order.
    private func states(_ path: String) throws -> [JSON] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
            .filter { $0["customType"].text == "pi-app.native.state.v1" }.map { $0["data"] }
    }
    /// The same journal under another name, with no metadata file: opens in full.
    private func copy(_ path: String, in chat: Chat) throws -> String {
        let copy = chat.state.appendingPathComponent("copy-" + UUID().uuidString + ".jsonl").path
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        return copy
    }

    func testChangesAreWrittenOnlyWhenTheyRebuildTheListExactly() {
        func receipt(_ turn: Int, _ status: String) -> JSON { ["commandId": JSON("c\(turn)"), "turnId": JSON("t\(turn)"), "status": JSON(status), "state": JSON(status)] }
        let base = (0..<3).map { receipt($0, "completed") }
        let target = [receipt(0, "completed"), receipt(1, "failed"), receipt(2, "completed"), receipt(3, "queued")]
        let changes = CommandReceipts.changes(from: base, to: target)
        XCTAssertEqual(changes, [receipt(1, "failed"), receipt(3, "queued")], "Only a changed receipt and a new one")
        XCTAssertEqual(CommandReceipts.apply(changes ?? [], to: base), target)
        XCTAssertNil(CommandReceipts.changes(from: base, to: [receipt(0, "completed"), receipt(2, "completed")]), "A receipt taken back needs the whole list")
        XCTAssertNil(CommandReceipts.changes(from: base, to: [receipt(1, "completed"), receipt(0, "completed"), receipt(2, "completed")]), "So does another order")
        XCTAssertEqual(CommandReceipts.changes(from: base, to: base), [], "Nothing changed, nothing written")
        let full = (0..<128).map { receipt($0, "completed") }, next = Array(full.dropFirst()) + [receipt(128, "queued")]
        XCTAssertEqual(CommandReceipts.changes(from: full, to: next), [receipt(128, "queued")], "The oldest goes past the limit on its own")
    }

    /// 150 turns: the list fills, the oldest receipts go, and each open has
    /// all 128 as the chat had them.
    func testALongChatWritesChangesAndEveryOpenRebuildsTheSameReceipts() async throws {
        let chat = try chat()
        let turns = 150
        let writer = try session(chat, replies: (0..<turns).map { answer("Answer \($0)") } + [answer("Summary: many questions were answered.")] + (turns..<(turns + 3)).map { answer("Answer \($0)") })
        for turn in 0..<turns { try await send(writer, turn) }
        // A compaction writes the metadata file over a record of changes.
        try await writer.compact(commandID: "compact")
        try await eventually { !(await writer.isRunning) }
        for turn in turns..<(turns + 3) { try await send(writer, turn) }
        let expected = await writer.commands
        XCTAssertEqual(expected.count, CommandReceipts.limit)
        XCTAssertEqual(expected.last?["turnId"].text, "turn-\(turns + 2)")
        let journalPath = await writer.path
        let path = try XCTUnwrap(journalPath)
        await writer.close()

        let records = try states(path)
        let whole = records.indices.filter { records[$0][CommandReceipts.deltaKey].flag != true }
        XCTAssertGreaterThan(records.count - whole.count, records.count * 9 / 10, "Most records hold only changes")
        for (earlier, later) in zip(whole, whole.dropFirst()) {
            XCTAssertLessThanOrEqual(later - earlier, CommandReceipts.wholeListEvery + 1, "The whole list comes back every \(CommandReceipts.wholeListEvery) records")
        }
        for record in records where record[CommandReceipts.deltaKey].flag == true {
            XCTAssertLessThanOrEqual(record["commands"].list.count, 2, "A record holds the receipts that changed")
            // What a version reading `commands` as the whole list relies on.
            for key in ["active", "queue", "steering", "queuePaused", "runStatus"] { XCTAssertFalse(record[key].isNull, "\(key) is whole in every record") }
        }
        let meta = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)), "The compaction wrote the metadata file")
        XCTAssertEqual(try JSON.parse(Data(meta.helper.utf8))["commands"].list.count, CommandReceipts.limit, "It carries the whole list")

        let resumed = try session(chat, path: path)
        let resumedOlder = await resumed.olderRows
        XCTAssertGreaterThan(resumedOlder, 0, "Opened from the metadata file")
        let resumedCommands = await resumed.commands
        XCTAssertEqual(resumedCommands, expected, "An open from the metadata file rebuilds the receipts")
        await resumed.close()
        let full = try session(chat, path: try copy(path, in: chat))
        let fullCommands = await full.commands
        XCTAssertEqual(fullCommands, expected, "So does a full replay")
        let snapshot = await full.snapshot()
        XCTAssertEqual(snapshot["commands"].list, expected, "and the app is sent the whole list")
        await full.close()
    }

    /// The first record after an open holds the whole list, and a reopened
    /// chat keeps writing changes that rebuild what it holds.
    func testAReopenedChatStartsWithTheWholeListAndKeepsItsReceipts() async throws {
        let chat = try chat()
        let first = try session(chat, replies: (0..<5).map { answer("Answer \($0)") })
        for turn in 0..<5 { try await send(first, turn) }
        let journalPath = await first.path
        let path = try XCTUnwrap(journalPath)
        await first.close()
        let before = try states(path).count

        let second = try session(chat, replies: (5..<8).map { answer("Answer \($0)") }, path: path)
        for turn in 5..<8 { try await send(second, turn) }
        let expected = await second.commands
        XCTAssertEqual(expected.count, 8)
        await second.close()
        let records = try states(path)
        XCTAssertNotEqual(records[before][CommandReceipts.deltaKey].flag, true, "The first record after an open holds the whole list")
        XCTAssertTrue(records[(before + 1)...].contains { $0[CommandReceipts.deltaKey].flag == true })
        let third = try session(chat, path: path)
        let reopened = await third.commands
        XCTAssertEqual(reopened, expected)
        await third.close()
    }

    /// A run-state write that failed may or may not be in the journal: the
    /// next record holds the whole list, and the chat reopens to what it held.
    func testAFailedWriteIsFollowedByTheWholeList() async throws {
        let chat = try chat(), failure = StateWriteFailure()
        let writer = try session(chat, replies: (0..<6).map { answer("Answer \($0)") }, failing: failure)
        for turn in 0..<4 { try await send(writer, turn) }
        failure.arm()
        do { _ = try await writer.submit(Submission(commandID: "command-lost", turnID: "turn-lost", text: "Lost question"), steer: false); XCTFail("The write was refused") } catch {}
        let journalPath = await writer.path
        let path = try XCTUnwrap(journalPath)
        let before = try states(path).count
        for turn in 4..<6 { try await send(writer, turn) }
        let expected = await writer.commands
        XCTAssertFalse(expected.contains { $0["turnId"].text == "turn-lost" }, "The refused message has no receipt")
        await writer.close()
        let records = try states(path)
        XCTAssertNotEqual(records[before][CommandReceipts.deltaKey].flag, true, "The record after the failure holds the whole list")
        let reopened = try session(chat, path: try copy(path, in: chat))
        let commands = await reopened.commands
        XCTAssertEqual(commands, expected)
        await reopened.close()
    }

    /// Journals and metadata files written before this format open as they did.
    func testRecordsWrittenBeforeThisFormatOpenAsBefore() async throws {
        let chat = try chat()
        let writer = try session(chat, replies: (0..<6).map { answer("Answer \($0)") } + [answer("Summary: six questions were answered.")] + [answer("Answer 6")])
        for turn in 0..<6 { try await send(writer, turn) }
        try await writer.compact(commandID: "compact")
        try await eventually { !(await writer.isRunning) }
        try await send(writer, 6)
        let expected = await writer.commands
        let journalPath = await writer.path
        let path = try XCTUnwrap(journalPath)
        await writer.close()
        // The same chat as an earlier version wrote it: every record whole.
        var lines: [String] = [], list: [JSON] = []
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            var record = try JSON.parse(Data(line.utf8))
            if record["customType"].text == "pi-app.native.state.v1" {
                let data = record["data"]
                list = data[CommandReceipts.deltaKey].flag == true ? CommandReceipts.apply(data["commands"].list, to: list) : data["commands"].list
                var whole = data.removing([CommandReceipts.deltaKey]); whole["commands"] = .array(list); record["data"] = whole
            }
            lines.append(String(decoding: try record.data(), as: UTF8.self))
        }
        let old = chat.state.appendingPathComponent("old-" + UUID().uuidString + ".jsonl").path
        try (lines.joined(separator: "\n") + "\n").write(toFile: old, atomically: true, encoding: .utf8)
        XCTAssertFalse(try states(old).contains { $0[CommandReceipts.deltaKey].flag == true })
        let full = try session(chat, path: old)
        let fullCommands = await full.commands
        XCTAssertEqual(fullCommands, expected, "A journal of whole lists opens to its newest list")
        await full.close()
        // Its metadata file, as an earlier version wrote it: no list of its own.
        var meta = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: old)))
        var helper = try JSON.parse(Data(meta.helper.utf8)); helper = helper.removing(["commands"]); meta.helper = helper.encoded()
        try meta.write(for: URL(fileURLWithPath: old))
        let resumed = try session(chat, path: old)
        let older = await resumed.olderRows, resumedCommands = await resumed.commands
        XCTAssertGreaterThan(older, 0, "A whole record needs no list in the file")
        XCTAssertEqual(resumedCommands, expected)
        await resumed.close()

        // A file with no list over a record of changes is not used.
        var current = try XCTUnwrap(JournalCheckpoint.read(for: URL(fileURLWithPath: path)))
        let stateRecord = try XCTUnwrap(current.state.flatMap { check in
            try? JSON.parse(Data(String(contentsOfFile: path, encoding: .utf8).utf8).subdata(in: Int(check.offset)..<(Int(check.offset) + check.length)))
        })
        XCTAssertEqual(stateRecord["data"][CommandReceipts.deltaKey].flag, true, "The checkpoint follows a record of changes")
        helper = try JSON.parse(Data(current.helper.utf8)).removing(["commands"]); current.helper = helper.encoded()
        try current.write(for: URL(fileURLWithPath: path))
        let fallback = try session(chat, path: path)
        let fallbackOlder = await fallback.olderRows, fallbackCommands = await fallback.commands
        XCTAssertEqual(fallbackOlder, 0, "The journal is replayed in full")
        XCTAssertEqual(fallbackCommands, expected)
        await fallback.close()
    }

    /// What a long chat's run state costs now, against the whole list each time.
    func testRunStateRecordsStaySmallOnceTheListIsFull() async throws {
        let chat = try chat()
        let turns = 160
        let writer = try session(chat, replies: (0..<turns).map { answer("Answer \($0)") })
        for turn in 0..<turns { try await send(writer, turn) }
        let journalPath = await writer.path
        let path = try XCTUnwrap(journalPath)
        await writer.close()
        var written = 0, wholeEveryTime = 0, list: [JSON] = []
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where line.contains(#""customType":"pi-app.native.state.v1""#) {
            let data = try JSON.parse(Data(line.utf8))["data"]
            list = data[CommandReceipts.deltaKey].flag == true ? CommandReceipts.apply(data["commands"].list, to: list) : data["commands"].list
            written += line.utf8.count
            var whole = data.removing([CommandReceipts.deltaKey]); whole["commands"] = .array(list)
            wholeEveryTime += line.utf8.count - (try data.data()).count + (try whole.data()).count
        }
        XCTAssertLessThan(Double(written), Double(wholeEveryTime) * 0.35, "Run state costs a third of what whole lists did, or less (\(written) of \(wholeEveryTime) bytes)")
    }
}

/// Refuses the next run-state record once armed, like a full disk would.
final class StateWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func check(_ record: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        guard armed, record["customType"].text == "pi-app.native.state.v1" else { return }
        armed = false
        throw AgentError("session_limit", "Fixture: the run state could not be written")
    }
}
