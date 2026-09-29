import XCTest
@testable import PiAgentCore

/// A chat's journal is replayed two ways: by `AgentSession.replay` when the
/// chat opens, and by the read-only `ConversationReplay` for a fork at one
/// reply and a portable preview. Both give the same rows, the same rows
/// shown, and the same context a request sends. The one difference is the
/// open's context also keeping rows no request sends (every request, count
/// and compaction leaves them out), until a record resets the context.
final class ReplayParityTests: XCTestCase {
    private struct Replays { var open: JournalReplay; var pure: ConversationReplay }

    /// Both replays of the journal at `path`, read from a copy, so a chat
    /// that has the journal open keeps it.
    private func replays(_ path: URL) throws -> Replays {
        let data = try Data(contentsOf: path)
        let records = try data.split(separator: 10).map { try JSON.parse(Data($0)) }
        let id = try XCTUnwrap(records.first?["id"].text)
        let binding = records.first { $0["customType"].text == "pi-app.native.v1" }?["data"]["binding"] ?? .null
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("copy.jsonl")
        try data.write(to: copy)
        let opened = try SessionJournal(url: copy, id: id, cwd: root, binding: binding, create: false)
        let open = try AgentSession.replay(opened, url: copy, id: id, binding: binding, spendTracked: false, resume: false)
        return Replays(open: open, pure: try ConversationReplay(records))
    }

    private func assertAlike(_ replays: Replays, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let open = replays.open, pure = replays.pure
        XCTAssertEqual(pure.history.map(\.id), open.history.map(\.id), "\(name): the rows", file: file, line: line)
        XCTAssertEqual(pure.visible.map(\.id), open.visible.map(\.id), "\(name): the rows shown", file: file, line: line)
        XCTAssertEqual(pure.context.filter(\.replayEligible).map(\.id), open.context.filter(\.replayEligible).map(\.id), "\(name): the context a request sends", file: file, line: line)
        let kept = Set(open.context.filter { !$0.replayEligible }.map(\.id))
        XCTAssertTrue(pure.context.filter { !$0.replayEligible }.allSatisfy { kept.contains($0.id) }, "\(name): only the open's context keeps rows no request sends", file: file, line: line)
    }

    func testTheSharedGoldenJournalsReplayAlike() throws {
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        for name in ["before", "after"] {
            assertAlike(try replays(repo.appendingPathComponent("fixtures/native/historical-edit-\(name).jsonl")), "historical-edit-\(name)")
        }
    }

    /// Tools, rows no request sends on both sides of a context reset, a
    /// progress row and its update, a compaction, an edit and a fork's
    /// context record.
    func testAJournalOfEveryRecordKindReplaysAlike() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("kinds.jsonl"), profile = try fixtureProfile()
        do {
            let journal = try SessionJournal(url: path, id: "kinds", cwd: root, binding: profile.binding, create: true)
            func message(_ id: String, _ role: String, _ text: String, _ change: (inout ChatMessage) -> Void = { _ in }) throws {
                var message = ChatMessage(role: role, content: [textBlock(text)]); message.id = id; change(&message)
                try journal.append(["type": "message", "message": message.pi], id: id, flush: false)
            }
            let interrupted: (inout ChatMessage) -> Void = { $0.replayEligible = false; $0.stopReason = "interrupted" }
            try message("u1", "user", "First question")
            var calls = toolReply(["first"]).message; calls.id = "a1"
            try journal.append(["type": "message", "message": calls.pi], id: "a1", flush: false)
            try message("r1", "toolResult", "done first") { $0.toolCallId = "call-0"; $0.toolName = "first" }
            try message("a2", "assistant", "First answer")
            try message("ledger-1", "system", "Request") { $0.kind = "requestLedger"; $0.replayEligible = false }
            try message("partial-1", "assistant", "A reply cut off", interrupted)
            try message("u2", "user", "Second question")
            try message("exec-1", "system", "Compacting") { $0.kind = "execution"; $0.replayEligible = false; $0.operationID = "op-1" }
            var finished = ChatMessage(role: "system", content: [textBlock("Compacted")])
            finished.id = "exec-1"; finished.kind = "execution"; finished.replayEligible = false; finished.operationID = "op-1"
            try journal.append(["type": "custom", "customType": "pi-app.presentation.update.v1", "data": ["id": "exec-1"], "message": finished.pi], flush: false)
            try journal.append(["type": "compaction", "summary": "What came before", "nativeKeptIDs": ["u2"], "tokensBefore": 9000], id: "summary-1", flush: false)
            try message("a3", "assistant", "Second answer")
            try journal.append(["type": "branch", "fromMessageId": "u2", "keptIds": ["summary-1"]], id: "branch-1", flush: false)
            try message("u3", "user", "Second question, edited")
            try message("partial-2", "assistant", "Another reply cut off", interrupted)
            try message("a4", "assistant", "Answer to the edit")
            try journal.append(["type": "custom", "customType": "pi-app.native.context.v1", "data": ["ids": ["summary-1", "u3", "partial-2", "a4"]]], flush: false)
            try message("u4", "user", "Third question")
            try message("partial-3", "assistant", "Cut off again", interrupted)
            try journal.synchronize()
        }
        let both = try replays(path)
        assertAlike(both, "every record kind")
        // The difference allowed, as it stands: a context record keeps what it
        // names in both, and after it only the open keeps a cut-off reply.
        XCTAssertEqual(both.open.context.map(\.id), ["summary-1", "u3", "partial-2", "a4", "u4", "partial-3"])
        XCTAssertEqual(both.pure.context.map(\.id), ["summary-1", "u3", "partial-2", "a4", "u4"])
    }

    /// What a chat writes as it runs, and the journals its forks and a side
    /// start from.
    func testALiveChatItsForksAndItsSideReplayAlike() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let client = ScriptClient([toolReply(["first", "second"]), answer("First answer"), answer("Second answer")])
        let chat = try AgentSession(id: "chat", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: client, tools: RecordingTools(), traces: traces, autoCompaction: false)
        for (index, text) in ["First question", "Second question"].enumerated() {
            _ = try await chat.submit(Submission(commandID: "c\(index)", turnID: "t\(index)", text: text), steer: false)
            try await eventually { !(await chat.isRunning) }
        }
        let chatPath = directory.appendingPathComponent("chat.jsonl")
        let parent = try replays(chatPath)
        assertAlike(parent, "the chat")
        let reply = try XCTUnwrap(parent.open.history.first { $0.role == "assistant" && $0.kind == nil }?.id)
        let atEnd = try await chat.fork(to: "fork-end"), atReply = try await chat.fork(to: "fork-reply", at: reply)
        assertAlike(try replays(URL(fileURLWithPath: try XCTUnwrap(atEnd["path"].text))), "a fork at the end")
        assertAlike(try replays(URL(fileURLWithPath: try XCTUnwrap(atReply["path"].text))), "a fork at the first reply")
        let seed = await chat.sideSeed()
        let side = try AgentSession(id: "side", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: traces, seed: seed.messages, parent: seed.info)
        let kept = try await side.preserveSide()
        assertAlike(try replays(URL(fileURLWithPath: try XCTUnwrap(kept["path"].text))), "a side")
        await side.close(); await chat.close()
    }
}
