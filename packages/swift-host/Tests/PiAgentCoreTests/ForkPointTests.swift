import XCTest
@testable import PiAgentCore

/// A fork from a reply finds where it ends (`forkPoint`), reading every
/// record to the journal's end, then rebuilds the conversation up to there
/// (`ConversationReplay(upTo:in:)`) and copies it, reading nothing past it.
/// Where a fork ends, what it holds, and the error a damaged journal gives,
/// are what reading every record each time gave.
final class ForkPointTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile, resources: Resources, traces: TraceStore
        func session(_ id: String, replies: [ModelReply] = [], resume: String? = nil) throws -> AgentSession {
            // Everything but the latest turn is summarized when compacted.
            var policy = CompactionPolicy(); policy.keepRecentTokens = 1
            return try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: resources,
                                    client: ScriptClient(replies), tools: RecordingTools(), traces: traces, resumePath: resume, autoCompaction: false, compactionPolicy: policy)
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
    private func records(_ path: String) throws -> [JSON] {
        let reader = try JournalRecordReader(URL(fileURLWithPath: path)); _ = try reader.next()
        var all: [JSON] = []
        while let record = try reader.next() { all.append(record) }
        return all
    }

    /// Where a fork at `messageID` ended when every record was built: the
    /// reply, or the last result of its tool batch.
    private func builtPoint(_ messageID: String, _ records: [JSON]) throws -> Int {
        var start: Int?, end = 0, pending = Set<String>(), batchFinished = false
        for (index, record) in records.enumerated() {
            if start == nil {
                guard record["type"].text == "message", record["id"].text == messageID else { continue }
                start = index; end = index
                let reply = try ChatMessage(id: messageID, pi: record["message"])
                guard reply.role == "assistant", reply.kind == nil, reply.replayEligible else { throw AgentError("fork_target", "not a reply") }
                pending = Set(reply.content.filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text })
                continue
            }
            guard !pending.isEmpty, !batchFinished, record["type"].text == "message" else { continue }
            let role = record["message"]["role"].text
            if role == "toolResult", let call = record["message"]["toolCallId"].text, pending.remove(call) != nil { end = index; continue }
            if role == "assistant" || role == "user" { batchFinished = true }
        }
        guard start != nil else { throw AgentError("fork_target", "not found") }
        return end
    }

    /// Every message of a chat with a tool batch, a compaction and an edited
    /// message: a fork at it ends where it did, and holds what it did. That is
    /// the records up to there, and the context and timeline their replay gives.
    func testEveryMessageForksWhereAndAsItDidWithEveryRecordBuilt() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let source = try chat.session("source", replies: [
            toolReply(["first", "second"]), answer(String(repeating: "after the tools ", count: 400)),
            answer(String(repeating: "answer two ", count: 400)),
            answer("Summary of everything so far."),
            answer("the original answer"), answer("the edited answer"),
            toolReply(["first"]), answer("the last answer"),
        ])
        try await send(source, "u1", "please use the tools")
        try await send(source, "u2", "question two")
        try await source.compact(commandID: "compact")
        try await eventually { !(await source.isRunning) }
        try await send(source, "u3", "the original question")
        _ = try await source.edit(fromMessageID: "u3", input: Submission(commandID: "u3b", turnID: "u3b", text: "the edited question"))
        try await eventually { !(await source.isRunning) }
        try await send(source, "u4", "one more with a tool")
        let sourcePath = await source.path
        let path = try XCTUnwrap(sourcePath), all = try records(path)
        let built: Set<String> = ["message", "compaction", "branch"]
        XCTAssertEqual(all.filter { ["compaction", "branch"].contains($0["type"].text ?? "") }.map { $0["type"].text }, ["compaction", "branch"], "the chat compacted, then edited")
        var forked = 0, refused: [String] = []
        for (number, id) in all.filter({ $0["type"].text == "message" }).compactMap({ $0["id"].text }).enumerated() {
            let expected: Int?
            do { expected = try builtPoint(id, all) } catch { expected = nil }
            let found: Int?
            do { found = try await source.forkPointForTesting(id, path: URL(fileURLWithPath: path)) }
            catch let error as AgentError { XCTAssertEqual(error.code, "fork_target", id); found = nil }
            XCTAssertEqual(found, expected, "\(id): where the fork ends")
            guard let end = expected else {
                // Not a reply: refused, whether it would be cloned or copied.
                for name in ["n\(number)", "a-refused-fork-\(number)-with-a-longer-identity"] {
                    do { _ = try await source.fork(to: name, at: id); XCTFail("\(id): not a reply") }
                    catch let error as AgentError { XCTAssertEqual(error.code, "fork_target", id) }
                }
                continue
            }
            // The conversation up to there, replayed from every record built.
            let replay = try ConversationReplay(Array(all[...end]))
            let context = replay.context.map(\.id), timeline = EditReplayPlan.forkTimeline(visible: replay.visible.map(\.id), boundary: context)
            // Cloned (an identity that fits the chat's header) and copied.
            for name in ["c\(number)", "a-copied-fork-\(number)-with-a-longer-identity"] {
                let result: JSON
                do { result = try await source.fork(to: name, at: id) }
                catch let error as AgentError {
                    XCTAssertFalse(context.contains(id) && timeline.contains(id), "\(id): \(error.message)")
                    XCTAssertEqual(error.code, "fork_target", id); refused.append(id + ": " + error.message); continue
                }
                forked += 1
                let path = try XCTUnwrap(result["path"].text), saved = try records(path), cloned = name.count <= "source".count
                XCTAssertEqual(saved.filter { built.contains($0["type"].text ?? "") }.compactMap { $0["id"].text },
                               all[...end].filter { built.contains($0["type"].text ?? "") }.compactMap { $0["id"].text }, "\(id): the records up to there")
                XCTAssertEqual(saved.contains { $0["data"][SessionSpend.resetKey].flag == true }, cloned, "\(name): cloned or copied")
                let data = saved.last { $0["customType"].text == JournalRecordKind.context }?["data"]
                XCTAssertEqual(data?["ids"], .array(context.map { JSON($0) }), "\(id): context")
                // A copy names the shown rows; a clone leaves them to its reader.
                XCTAssertEqual(data?["visibleIDs"], cloned ? .null : .array(timeline.map { JSON($0) }), "\(id): timeline")
                XCTAssertEqual(result["origin"]["cutoffEntryId"].text, context.last, id)
                XCTAssertEqual(result["origin"]["contextRevision"].text, sha256(Data(context.joined(separator: "\n").utf8)), id)
                // Replayed, the fork shows the timeline and holds the context.
                let journal = try SessionJournal(url: URL(fileURLWithPath: path), id: name, cwd: chat.root, binding: chat.profile.binding, create: false)
                let replayed = try AgentSession.replay(journal, url: URL(fileURLWithPath: path), id: name, binding: chat.profile.binding, spendTracked: false, resume: false)
                XCTAssertEqual(replayed.visible.map(\.id), timeline, "\(name): the rows shown")
                XCTAssertEqual(replayed.context.map(\.id), context, "\(name): the context")
                if cloned { XCTAssertEqual(JournalCheckpoint.read(for: URL(fileURLWithPath: path)), replayed.captured, "\(name): its metadata file is its replay's") }
            }
        }
        XCTAssertEqual(forked, 14, "every reply forks, the earlier version's too, cloned and copied: \(refused)")
        await source.close()
    }

    /// Unusual records: one that begins and ends as a run state does, but whose
    /// first `id` and `type` are a reply's (the parser keeps the first of a
    /// repeated key); one whose `type` is written with an escape; empty lines;
    /// a tool batch that lost a result; and a fork's context record. For every
    /// message, the point a fork ends at, and the conversation up to it, are
    /// what building every record gives. A shortcut that reads a record's
    /// kind without building it must keep this so.
    func testUnusualRecordsForkWhereAndAsBuildingEveryRecordDid() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let escapedType = "typ" + "\\" + "u0065"
        let lines = [
            #"{"cwd":"/","id":"crafted","timestamp":"t","type":"session","version":3}"#,
            #"{"id":"q","message":{"content":"a question","role":"user"},"parentId":null,"timestamp":"t","type":"message"}"#,
            "",
            #"{"customType":"pi-app.native.state.v1","data":{"active":false},"id":"y","message":{"content":[{"text":"hidden","type":"text"}],"role":"assistant"},"type":"message","z":{},"id":"s9","parentId":"q","timestamp":"t","type":"custom"}"#,
            #"{"id":"a","message":{"content":[{"arguments":{},"id":"c1","name":"first","type":"toolCall"},{"arguments":{},"id":"c2","name":"second","type":"toolCall"}],"role":"assistant"},"parentId":"s9","timestamp":"t","type":"message"}"#,
            #"{"id":"r1","message":{"content":[{"text":"done","type":"text"}],"role":"toolResult","toolCallId":"c1","toolName":"first"},"parentId":"a","timestamp":"t","type":"message"}"#,
            "",
            #"{"customType":"pi-app.native.state.v1","data":{"active":false},"id":"s1","parentId":"r1","timestamp":"t","type":"custom"}"#,
            #"{"customType":"pi-app.native.context.v1","data":{"ids":["q","y"]},"id":"ctx","parentId":"s1","timestamp":"t","type":"custom"}"#,
            #"{"id":"q2","message":{"content":"next","role":"user"},"parentId":"ctx","timestamp":"t","type":"message"}"#,
            #"{"id":"a2","message":{"content":[{"text":"an answer","type":"text"}],"role":"assistant"},"parentId":"q2","timestamp":"t","type":"message"}"#,
            #"{"id":"a3","message":{"content":[{"text":"escaped","type":"text"}],"role":"assistant"},"parentId":"a2","timestamp":"t",""# + escapedType + #"":"message"}"#,
        ]
        let url = chat.root.appendingPathComponent("crafted.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let all = lines.dropFirst().filter { !$0.isEmpty }.map { try! JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(all[1]["id"].text, "y"); XCTAssertEqual(all[1]["type"].text, "message"); XCTAssertEqual(all.last?["type"].text, "message")
        let probe = try chat.session("probe")
        var ends: [Int] = []
        for id in ["q", "y", "s9", "a", "r1", "q2", "a2", "a3", "missing"] {
            let expected: Int?
            do { expected = try builtPoint(id, all) } catch { expected = nil }
            let found: Int?
            do { found = try await probe.forkPointForTesting(id, path: url) }
            catch let error as AgentError { XCTAssertEqual(error.code, "fork_target", id); found = nil }
            XCTAssertEqual(found, expected, "\(id): where the fork ends")
            guard let end = expected else { continue }
            ends.append(end)
            let reader = try JournalRecordReader(url); _ = try reader.next()
            let read = try ConversationReplay(upTo: end, in: reader), built = try ConversationReplay(Array(all[...end]))
            XCTAssertEqual(read.context.map(\.id), built.context.map(\.id), "\(id): context")
            XCTAssertEqual(read.visible.map(\.id), built.visible.map(\.id), "\(id): shown rows")
            XCTAssertEqual(read.history.map(\.id), built.history.map(\.id), "\(id): history")
        }
        XCTAssertEqual(ends, [1, 3, 7, 8], "y, a with its one result, a2 and a3 fork")
        await probe.close()
    }

    /// A read that stops at the reply still finds a journal that changed after
    /// it was opened, as a read to its end finds it.
    func testAReadThatStopsAtTheReplyStillFindsAChangedJournal() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("changed.jsonl")
        try Data((#"{"cwd":"/","id":"changed","timestamp":"t","type":"session","version":3}"# + "\n" +
                  #"{"id":"a","message":{"content":[{"text":"an answer","type":"text"}],"role":"assistant"},"parentId":null,"timestamp":"t","type":"message"}"# + "\n" +
                  #"{"id":"b","message":{"content":[{"text":"another","type":"text"}],"role":"assistant"},"parentId":"a","timestamp":"t","type":"message"}"# + "\n").utf8).write(to: url)
        let unchanged = try JournalRecordReader(url); _ = try unchanged.next()
        XCTAssertEqual(try ConversationReplay(upTo: 0, in: unchanged).history.map(\.id), ["a"])
        let reader = try JournalRecordReader(url); _ = try reader.next()
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd(); try file.write(contentsOf: Data("{}\n".utf8)); try file.close()
        XCTAssertThrowsError(try ConversationReplay(upTo: 0, in: reader)) { XCTAssertEqual(($0 as? AgentError)?.code, "session_damaged") }
    }

    /// A record the parser refuses before the reply fails a fork from the
    /// reply with the parser's own error, and leaves no fork; one after it
    /// fails a copied fork, which reads the journal to its end, and not a
    /// cloned one, which reads nothing past the reply. It is a superseded run
    /// state, which the chat's open never reads.
    func testARecordTheParserRefusesStillFailsAForkFromAReply() async throws {
        let damaged = #"{"customType":"pi-app.native.state.v1","data":{"active":fals},"id":"s1","parentId":"PARENT","timestamp":"t","type":"custom"}"#
        let refused: String
        do { _ = try JSON.parse(Data(damaged.utf8)); return XCTFail("the record is refused") } catch { refused = error.localizedDescription }
        for place in ["before", "after"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let profile = try fixtureProfile(), state = root.appendingPathComponent("state"), path = state.appendingPathComponent("damaged.jsonl")
            func message(_ journal: SessionJournal, _ id: String, _ role: String, _ text: String) throws {
                try journal.append(["type": "message", "message": ["role": JSON(role), "content": JSON(text)]], id: id)
            }
            func writeDamaged() throws {
                let tail = try XCTUnwrap(try SessionJournal(url: path, id: "damaged", cwd: root, binding: profile.binding, create: false).head)
                let file = try FileHandle(forWritingTo: path); try file.seekToEnd()
                try file.write(contentsOf: Data((damaged.replacingOccurrences(of: "PARENT", with: tail) + "\n").utf8)); try file.close()
            }
            do {
                let journal = try SessionJournal(url: path, id: "damaged", cwd: root, binding: profile.binding, create: true)
                try message(journal, "q", "user", "a question")
            }
            if place == "before" { try writeDamaged() }
            do {
                let journal = try SessionJournal(url: path, id: "damaged", cwd: root, binding: profile.binding, create: false)
                try message(journal, "a", "assistant", "an answer")
            }
            if place == "after" { try writeDamaged() }
            do {
                let journal = try SessionJournal(url: path, id: "damaged", cwd: root, binding: profile.binding, create: false)
                try message(journal, "q2", "user", "a second question")
                try message(journal, "a2", "assistant", "a second answer")
                try journal.append(["type": "custom", "customType": "pi-app.native.state.v1", "data": ["active": false, "queue": [], "steering": [], "commands": [], "queuePaused": false]], id: "s2")
            }
            let chat = try AgentSession(id: "damaged", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: false, resources: Resources(cwd: root, home: root),
                                        client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path, autoCompaction: false)
            let copied = "a-copied-fork-with-a-longer-identity"
            do { _ = try await chat.fork(to: copied, at: "a"); XCTFail("\(place): the damaged record fails the copied fork") }
            catch { XCTAssertEqual(error.localizedDescription, refused, "\(place): the parser's error") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("fork_\(copied).jsonl").path), "\(place): no fork")
            if place == "before" {
                do { _ = try await chat.fork(to: "fork", at: "a"); XCTFail("before: the damaged record fails the fork") }
                catch { XCTAssertEqual(error.localizedDescription, refused, "before: the parser's error") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("fork_fork.jsonl").path), "before: no fork")
            } else {
                let cloned = try await chat.fork(to: "fork", at: "a")
                let text = try String(contentsOfFile: try XCTUnwrap(cloned["path"].text), encoding: .utf8)
                XCTAssertFalse(text.contains("a second question") || text.contains(#""active":fals}"#), "after: nothing past the reply")
            }
            await chat.close()
        }
    }
}
