import XCTest
@testable import PiAgentCore

/// A journal written before 0.1.111 slimmed once (`JournalSlimming`): without
/// the run-state records a later one supersedes, and opening to exactly the
/// chat it was. Anything that goes wrong leaves the journal as it was.
final class JournalSlimmingTests: XCTestCase {
    private struct Chat { let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore }

    private func chat() throws -> Chat {
        let root = try temporaryDirectory(); addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile(), resources: Resources(cwd: root, home: root), traces: TraceStore())
    }
    private func session(_ chat: Chat, id: String = "slim", replies: [ModelReply] = [], path: String? = nil,
                         seed: [ChatMessage]? = nil, parent: JSON = .null) throws -> AgentSession {
        try AgentSession(id: id, profile: chat.profile, apiKey: "test", cwd: chat.root, directory: chat.state, readOnly: true, resources: chat.resources,
                         client: ScriptClient(replies), tools: RecordingTools(), traces: chat.traces, resumePath: path, seed: seed, parent: parent, autoCompaction: false,
                         compactionPolicy: { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }())
    }
    private func send(_ session: AgentSession, _ turn: Int) async throws {
        _ = try await session.submit(Submission(commandID: "command-\(turn)", turnID: "turn-\(turn)", text: "Question \(turn)"), steer: false)
        try await eventually { !(await session.isRunning) }
    }
    /// A long chat in small: turns, a compaction, an edit of the last
    /// question, and turns after it.
    private func journal(_ chat: Chat, turns: Int = 24) async throws -> String {
        var replies: [ModelReply] = (0..<turns).map { answer("Answer \($0) " + String(repeating: "evidence ", count: 20)) }
        replies.append(answer("Summary: many questions were answered."))
        replies += (turns..<(turns + 8)).map { answer("Answer \($0)") }
        let writer = try session(chat, replies: replies)
        for turn in 0..<turns { try await send(writer, turn) }
        try await writer.compact(commandID: "compact")
        try await eventually { !(await writer.isRunning) }
        for turn in turns..<(turns + 3) { try await send(writer, turn) }
        let rows = await writer.visible
        let last = try XCTUnwrap(rows.last { $0.role == "user" })
        _ = try await writer.edit(fromMessageID: last.id, input: Submission(commandID: "edit", turnID: "turn-edit", text: "Question, edited"))
        try await eventually { !(await writer.isRunning) }
        for turn in (turns + 4)..<(turns + 7) { try await send(writer, turn) }
        let written = await writer.path
        let path = try XCTUnwrap(written)
        await writer.close()
        return path
    }
    /// Every run-state record written whole, as the helper wrote them before
    /// 0.1.111, and no metadata file.
    private func rewriteWhole(_ path: String) throws {
        var lines: [String] = [], list: [JSON] = []
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            var record = try JSON.parse(Data(line.utf8))
            if record["customType"].text == "pi-app.native.state.v1" {
                let data = record["data"]
                list = data[CommandReceipts.deltaKey].flag == true ? CommandReceipts.apply(data["commands"].list, to: list) : data["commands"].list
                var whole = data.removing([CommandReceipts.deltaKey]); whole["commands"] = .array(list); record["data"] = whole
            } else if !record["nativeState"].isNull { list = record["nativeState"]["commands"].list }
            lines.append(String(decoding: try record.data(), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
    }
    private func records(_ path: String) throws -> [JSON] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
    }
    /// The same journal under another name, with no metadata file: opens in full.
    private func copy(_ path: String, in chat: Chat) throws -> String {
        let copy = chat.state.appendingPathComponent("reference-" + UUID().uuidString + ".jsonl").path
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        return copy
    }
    /// Where a test's discarded originals go, instead of the owner's Trash.
    private func bin(_ chat: Chat) throws -> (URL, (URL) throws -> Void) {
        let bin = chat.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return (bin, { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) })
    }
    private func leftovers(_ chat: Chat) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: chat.state.path).filter { $0.hasPrefix(".slim-") || $0.hasPrefix(".pre-slim-") }
    }
    private static func row(_ message: ChatMessage) -> JSON { ["compaction", "branch"].contains(message.kind ?? "") ? message.pi.removing(["timestamp"]) : message.pi }

    /// The chat each session opened to, against each other.
    private func assertSameChat(_ slimmed: AgentSession, _ reference: AgentSession, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await slimmed.ensureFullHistory()
        let rows = await slimmed.visible.map(Self.row), referenceRows = await reference.visible.map(Self.row)
        XCTAssertEqual(rows, referenceRows, "Every row, as it was", file: file, line: line)
        let context = await slimmed.context.map(Self.row), referenceContext = await reference.context.map(Self.row)
        XCTAssertEqual(context, referenceContext, "The model context", file: file, line: line)
        let ledger = await slimmed.versions.ledger, referenceLedger = await reference.versions.ledger
        XCTAssertEqual(ledger, referenceLedger, "Edited messages' versions", file: file, line: line)
        let spend = await slimmed.spend.record, referenceSpend = await reference.spend.record
        XCTAssertEqual(spend, referenceSpend, file: file, line: line)
        let commands = await slimmed.commands, referenceCommands = await reference.commands
        XCTAssertEqual(commands, referenceCommands, "The receipts", file: file, line: line)
        let snapshot = await slimmed.snapshot(), referenceSnapshot = await reference.snapshot()
        for key in ["state", "runStatus", "queue", "queuePaused", "cost", "commands"] {
            XCTAssertEqual(snapshot[key], referenceSnapshot[key], "Snapshot \(key)", file: file, line: line)
        }
    }

    func testAJournalWrittenBeforeReceiptChangesSlimsAndOpensAsBefore() async throws {
        let chat = try chat()
        let path = try await journal(chat)
        try rewriteWhole(path)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let reference = try copy(path, in: chat)
        let standaloneBefore = try records(path).filter { $0["customType"].text == "pi-app.native.state.v1" }.count
        XCTAssertGreaterThan(standaloneBefore, 100)
        let (bin, discard) = try bin(chat)

        let outcome = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim", minimumSaving: 0, discard: discard)
        XCTAssertTrue(outcome.slimmed, "\(outcome)")
        XCTAssertEqual(outcome.recordsRemoved, standaloneBefore - 1)
        XCTAssertLessThan(outcome.bytesAfter, outcome.bytesBefore)
        let after = try records(path)
        let states = after.filter { $0["customType"].text == "pi-app.native.state.v1" }
        XCTAssertEqual(states.count, 1, "One run-state record is left: the one the chat's run state comes from")
        XCTAssertNotEqual(states.first?["data"][CommandReceipts.deltaKey].flag, true, "and its receipts are whole")
        for (earlier, later) in zip(after, after.dropFirst()) {
            XCTAssertEqual(later["parentId"].text, earlier["type"].text == "session" ? nil : earlier["id"].text, "One chain, record after record")
        }
        let discarded = try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
        XCTAssertEqual(discarded.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(discarded.first)), original, "The original went away whole")
        XCTAssertEqual(try leftovers(chat), [])
        XCTAssertNotNil(JournalCheckpoint.read(for: URL(fileURLWithPath: path)), "The metadata file was written for the new journal")

        let slimmed = try session(chat, path: path), full = try session(chat, path: reference)
        let older = await slimmed.olderRows
        XCTAssertGreaterThan(older, 0, "It opens from the new metadata file")
        try await assertSameChat(slimmed, full)
        await slimmed.close(); await full.close()
        let again = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim", minimumSaving: 1, discard: discard)
        XCTAssertEqual(again.reason, "little-to-gain", "Nothing is left to take out")
    }

    func testAJournalWithReceiptChangesKeepsItsReceipts() async throws {
        let chat = try chat()
        let path = try await journal(chat, turns: 30)
        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
        XCTAssertTrue(try records(path).contains { $0["data"][CommandReceipts.deltaKey].flag == true }, "Written with receipt changes")
        let reference = try copy(path, in: chat)
        let (_, discard) = try bin(chat)
        let outcome = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim", minimumSaving: 0, discard: discard)
        XCTAssertTrue(outcome.slimmed, "\(outcome)")
        let states = try records(path).filter { $0["customType"].text == "pi-app.native.state.v1" }
        XCTAssertEqual(states.count, 1)
        XCTAssertNotEqual(states.first?["data"][CommandReceipts.deltaKey].flag, true, "The record kept holds the whole list")
        let slimmed = try session(chat, path: path), full = try session(chat, path: reference)
        try await assertSameChat(slimmed, full)
        let reopened = await slimmed.commands.count
        XCTAssertEqual(reopened, 30 + 3 + 1 + 1 + 3, "Every receipt: the turns, the compaction and the edit")
        await slimmed.close(); await full.close()
    }

    func testAForkAndAKeptSideSlimToo() async throws {
        let chat = try chat()
        let path = try await journal(chat)
        let parent = try session(chat, replies: (0..<6).map { answer("Later \($0)") }, path: path)
        let fork = try await parent.fork(to: "forked")
        let seed = await parent.sideSeed()
        let side = try session(chat, id: "side", replies: (0..<6).map { answer("Side \($0)") }, seed: seed.messages, parent: seed.info)
        for turn in 100..<104 { try await send(side, turn) }
        let kept = try await side.keep(whenFinished: false)
        let sidePath = try XCTUnwrap(kept["path"].text), forkPath = try XCTUnwrap(fork["path"].text)
        for turn in 104..<106 { try await send(side, turn) }
        await side.close(); await parent.close()
        let forkSession = try session(chat, id: "forked", replies: (0..<4).map { answer("Fork \($0)") }, path: forkPath)
        for turn in 200..<203 { try await send(forkSession, turn) }
        await forkSession.close()
        let (_, discard) = try bin(chat)
        for (id, journal) in [("side", sidePath), ("forked", forkPath)] {
            try rewriteWhole(journal)
            let reference = try copy(journal, in: chat)
            let outcome = try JournalSlimming.slim(url: URL(fileURLWithPath: journal), id: id, minimumSaving: 0, discard: discard)
            XCTAssertTrue(outcome.slimmed, "\(id): \(outcome)")
            let slimmed = try session(chat, id: id, path: journal), full = try session(chat, id: id, path: reference)
            try await assertSameChat(slimmed, full)
            let origin = await slimmed.parentInfo, referenceOrigin = await full.parentInfo
            XCTAssertEqual(origin, referenceOrigin, "\(id) keeps where it came from")
            await slimmed.close(); await full.close()
        }
    }

    func testAJournalASessionHasOpenIsLeftAlone() async throws {
        let chat = try chat()
        let path = try await journal(chat)
        try rewriteWhole(path)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let open = try session(chat, path: path)
        let (_, discard) = try bin(chat)
        let outcome = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim", minimumSaving: 0, discard: discard)
        XCTAssertEqual(outcome.reason, "locked")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        await open.close()
    }

    func testACopyThatDoesNotReplayTheSameLeavesTheJournalAlone() async throws {
        let chat = try chat()
        let path = try await journal(chat)
        try rewriteWhole(path)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let (bin, discard) = try bin(chat)
        let outcome = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim", minimumSaving: 0, discard: discard, tamper: { copy in
            let text = try String(contentsOf: copy, encoding: .utf8).replacingOccurrences(of: "Answer 3 ", with: "Answer 9 ")
            try text.write(to: copy, atomically: false, encoding: .utf8)
        })
        XCTAssertEqual(outcome.reason, "mismatch:history")
        XCTAssertFalse(outcome.slimmed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original, "The journal is as it was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [], "and nothing went to the Trash")
        XCTAssertEqual(try leftovers(chat), [])
    }

    func testADiscardThatFailsLeavesTheJournalAlone() async throws {
        let chat = try chat()
        let path = try await journal(chat)
        try rewriteWhole(path)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let outcome = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim", minimumSaving: 0, discard: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(outcome.reason, "discard-failed")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertEqual(try leftovers(chat), [])
    }

    func testSmallAndImportedJournalsAreLeftAlone() async throws {
        let chat = try chat()
        let writer = try session(chat, replies: [answer("One")])
        try await send(writer, 0)
        let written = await writer.path
        let path = try XCTUnwrap(written)
        await writer.close()
        let small = try JournalSlimming.slim(url: URL(fileURLWithPath: path), id: "slim")
        XCTAssertEqual(small.reason, "little-to-gain")
        let imported = chat.state.appendingPathComponent("imported.jsonl")
        let lines: [JSON] = [["type": "session", "version": 3, "id": "imported"],
                             ["type": "message", "id": "u1", "parentId": .null, "message": ["role": "user", "content": "From pi"]]]
        try (lines.map { String(decoding: try $0.data(), as: UTF8.self) }.joined(separator: "\n") + "\n").write(to: imported, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: imported)
        let outcome = try JournalSlimming.slim(url: imported, id: "imported", minimumSaving: 0)
        XCTAssertEqual(outcome.reason, "not-native")
        XCTAssertEqual(try Data(contentsOf: imported), before)
    }

    /// The helper's command: this workspace's own journals, and none a chat
    /// has open.
    func testTheHelperSlimsOnlyItsOwnJournalsThatNoChatHasOpen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in }), sessions = root.appendingPathComponent("state/Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(sessions.path), "mcp": ["servers": [:]]])
        let profile = try fixtureProfile()
        // Forty turns, each followed by three run-state records carrying all
        // 128 receipts: as a long chat looked before 0.1.111.
        let receipts: [JSON] = (0..<128).map { ["commandId": JSON("command-\(String(repeating: "c", count: 30))-\($0)"), "turnId": JSON("turn-\(String(repeating: "t", count: 30))-\($0)"), "status": "completed", "state": "completed"] }
        var records: [JSON] = [["type": "session", "version": 3, "id": "old", "cwd": JSON(root.path), "timestamp": "2026-09-01T00:00:00Z"],
                               ["type": "custom", "customType": "pi-app.native.v1", "data": ["binding": profile.binding, "version": 1], "id": "marker", "parentId": .null]]
        var parent = "marker"
        func add(_ record: JSON, _ id: String) { var record = record; record["id"] = JSON(id); record["parentId"] = JSON(parent); records.append(record); parent = id }
        for turn in 0..<40 {
            add(["type": "message", "message": ["role": "user", "content": JSON("Question \(turn)")]], "u\(turn)")
            add(["type": "message", "message": ["role": "assistant", "content": JSON("Answer \(turn)")]], "a\(turn)")
            for save in 0..<3 {
                add(["type": "custom", "customType": "pi-app.native.state.v1",
                     "data": ["active": false, "queue": [], "steering": [], "commands": .array(receipts), "queuePaused": false,
                              "steeringMode": "one-at-a-time", "followUpMode": "one-at-a-time", "runStatus": "idle"]], "s\(turn)-\(save)")
            }
        }
        let path = sessions.appendingPathComponent("old.jsonl")
        try (records.map { String(decoding: try $0.data(), as: UTF8.self) }.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("elsewhere.jsonl")
        try FileManager.default.copyItem(at: path, to: outside)
        do { _ = try await host.command("journal.slim", sessionID: nil, params: ["sessionId": "old", "path": JSON(outside.path)]); XCTFail("Only this workspace's own journals") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "session_scope") }

        // A chat open here is not slimmed.
        _ = try await host.command("session.open", sessionID: "old", params: ["profile": profile.raw, "apiKey": "synthetic", "path": JSON(path.path)])
        let open = try await host.command("journal.slim", sessionID: nil, params: ["sessionId": "old", "path": JSON(path.path)])
        XCTAssertEqual(open["reason"].text, "session-open"); XCTAssertEqual(open["slimmed"].flag, false)
        _ = try await host.command("session.close", sessionID: "old", params: [:])

        // The owner's Trash is not a test's: the command's own path is the one
        // the core tests cover with a test bin. Here only the refusal paths,
        // and the gain it reports, are checked through the command.
        let plan = try JournalSlimming.Plan(path)
        XCTAssertEqual(plan.removed.count, 119, "Every run-state record but the last goes")
        XCTAssertGreaterThan(plan.removableBytes, JournalSlimming.minimumSaving)
        await host.shutdown()
    }
}
