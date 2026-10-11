import XCTest
@testable import PiAgentCore

/// A model that streams what it is told to and never finishes: the helper
/// dies while it waits.
private actor StallingClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private(set) var requests = 0
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1; callback = onDelta
        while true { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// A value set from a journal hook, read by the test.
private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock(); private var stored: String?
    var value: String? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

/// A model that streams its pieces quickly, then answers with them.
private actor DeltaThenAnswerClient: ModelClient {
    let pieces: [String]
    init(pieces: [String]) { self.pieces = pieces }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        for piece in pieces { try await onDelta(.text(piece)) }
        return answer(pieces.joined())
    }
}

/// The reply a run is streaming survives a helper that dies mid-reply
/// (`PartialReplyLog`): a reopen shows it as the interrupted reply a stop
/// leaves, and sends nothing again.
final class PartialReplyLogTests: XCTestCase {
    private struct Chat {
        let root: URL, state: URL, profile: Profile
        func session(_ id: String, client: any ModelClient, resume: String? = nil, in directory: URL? = nil,
                     beforeAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }) throws -> AgentSession {
            try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: directory ?? state, readOnly: false, resources: Resources(cwd: root, home: root),
                             client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: resume, autoCompaction: false, beforeJournalAppend: beforeAppend)
        }
    }
    private func chat() throws -> Chat {
        let root = try temporaryDirectory()
        return Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile())
    }
    private func part(_ ordinal: Int, _ kind: String, _ text: String) -> StreamDelta {
        .part(ResponsePartEvent(attemptID: "attempt", ordinal: ordinal, itemID: "item", outputIndex: 0, partIndex: 0, kind: kind, update: "append", text: text, observedAt: Double(ordinal)))
    }
    /// What streamed: thought, then text in many pieces.
    private let pieces = (0..<30).map { "piece \($0) 中文🙂 " }
    private func stream(_ client: StallingClient) async throws {
        try await eventually { await client.ready }
        try await client.emit(part(1, "reasoningSummary", "Thinking it over.")); try await client.emit(.thinking("Thinking it over."))
        for (index, piece) in pieces.enumerated() { try await client.emit(part(index + 2, "text", piece)); try await client.emit(.text(piece)) }
    }
    /// The chat's files as a helper killed now leaves them, copied beside
    /// each other into a directory of their own; the journal's path there.
    private func killedCopy(_ path: String, log: Bool = true) throws -> URL {
        let directory = try temporaryDirectory()
        let journal = URL(fileURLWithPath: path), copy = directory.appendingPathComponent(journal.lastPathComponent)
        try FileManager.default.copyItem(at: journal, to: copy)
        if log { try FileManager.default.copyItem(at: PartialReplyLog.url(for: journal), to: PartialReplyLog.url(for: copy)) }
        return copy
    }
    private func replies(_ session: AgentSession) async -> [ChatMessage] { await session.visible.filter { $0.role == "assistant" } }

    func testAReplyStreamingWhenTheHelperDiesIsReopenedAsAnInterruptedReply() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        try await eventually { FileManager.default.fileExists(atPath: PartialReplyLog.url(for: URL(fileURLWithPath: path)).path) }
        try await Task.sleep(nanoseconds: 3 * PartialReplyLog.flushDelayNanoseconds)
        let copy = try killedCopy(path)
        let streamingID = await session.partialID
        await session.close()

        let reopened = try chat.session("chat", client: StallingClient(), resume: copy.path, in: copy.deletingLastPathComponent())
        let kept = await replies(reopened)
        XCTAssertEqual(kept.count, 1)
        let reply = try XCTUnwrap(kept.first)
        XCTAssertEqual(reply.id, streamingID, "the reply keeps the identity it streamed under")
        XCTAssertEqual(reply.text, pieces.joined()); XCTAssertEqual(reply.thinking, "Thinking it over.")
        XCTAssertEqual(reply.stopReason, "interrupted"); XCTAssertFalse(reply.replayEligible)
        XCTAssertEqual(reply.turn, "t1")
        XCTAssertEqual(reply.responseTimeline?.terminal, "interrupted")
        XCTAssertEqual(reply.responseTimeline?.segments.map(\.text), ["Thinking it over.", pieces.joined()], "the parts read as they streamed")
        XCTAssertEqual(reply.requestAttemptIDs, ["attempt"])
        // The interrupted task ends at the reply and counts it.
        let task = await reopened.recentTaskPresentations.last
        XCTAssertEqual(task?.outcome, "interrupted"); XCTAssertEqual(task?.lastSourceID, reply.id); XCTAssertEqual(task?.replies, 1)
        let state = await reopened.state, running = await reopened.isRunning
        XCTAssertEqual(state, .paused); XCTAssertFalse(running, "nothing is sent again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialReplyLog.url(for: copy).path), "the journal holds it now")
        await reopened.close()

        // Opened again, from the journal alone, it is there once.
        let again = try chat.session("chat", client: StallingClient(), resume: copy.path, in: copy.deletingLastPathComponent())
        let shown = await replies(again)
        XCTAssertEqual(shown.map(\.id), [reply.id]); XCTAssertEqual(shown.first?.text, reply.text)
        await again.close()
    }

    /// A line torn by the crash ends what is read; everything before it stands.
    func testATornLastLineIsLeftOut() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        try await Task.sleep(nanoseconds: 3 * PartialReplyLog.flushDelayNanoseconds)
        let copy = try killedCopy(path)
        await session.close()
        let torn = try FileHandle(forWritingTo: PartialReplyLog.url(for: copy)); try torn.seekToEnd()
        try torn.write(contentsOf: Data(#"{"t":"never finis"#.utf8)); try torn.close()

        let reopened = try chat.session("chat", client: StallingClient(), resume: copy.path, in: copy.deletingLastPathComponent())
        let kept = await replies(reopened)
        XCTAssertEqual(kept.map(\.text), [pieces.joined()])
        await reopened.close()
    }

    /// A run that settles takes its log with it; a stop keeps the reply as
    /// it always did, in the journal.
    func testASettledRunLeavesNoLog() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath), log = PartialReplyLog.url(for: URL(fileURLWithPath: path))
        try await eventually { FileManager.default.fileExists(atPath: log.path) }
        await session.stop()
        try await eventually { !(await session.isRunning) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        await session.close()
        let reopened = try chat.session("chat", client: StallingClient(), resume: path)
        let kept = await replies(reopened)
        XCTAssertEqual(kept.map(\.text), [pieces.joined()], "the stop's own row, once")
        await reopened.close()
    }

    /// A log that does not belong to the journal as it is (its record is
    /// gone), or a damaged one (an id no record may have, a place past any
    /// file), adds nothing, and is removed; the chat opens as it is.
    func testALogTheJournalDoesNotMatchAddsNothing() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        try await Task.sleep(nanoseconds: 3 * PartialReplyLog.flushDelayNanoseconds)
        let killed = try killedCopy(path)
        await session.close()
        // The record after the header: the native marker, never a row.
        let journalIDs = try String(contentsOf: killed, encoding: .utf8).components(separatedBy: "\n").dropFirst().prefix(1)
            .compactMap { try? JSON.parse(Data($0.utf8))["id"].text }
        XCTAssertEqual(journalIDs.count, 1)
        let damages: [(String, (inout PartialReplyLog.Header) -> Void)] = [
            ("another record", { $0.after.id = "someone-else" }), ("an id no record may have", { $0.reply = "not an id/../" }),
            ("an empty id", { $0.reply = "" }), ("the anchor's id", { $0.reply = $0.after.id }), ("a loaded row's id", { $0.reply = "t1" }), ("an earlier record's id", { $0.reply = journalIDs.first ?? "" }), ("a place past any file", { $0.after.offset = UInt64.max }),
        ]
        for (what, damage) in damages {
            let copy = try killedCopy(killed.path), logURL = PartialReplyLog.url(for: copy)
            var lines = try String(contentsOf: logURL, encoding: .utf8).components(separatedBy: "\n")
            var header = try JSONDecoder().decode(PartialReplyLog.Header.self, from: Data(lines[0].utf8))
            damage(&header)
            lines[0] = String(decoding: try JSONEncoder().encode(header), as: UTF8.self)
            try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

            let reopened = try chat.session("chat", client: StallingClient(), resume: copy.path, in: copy.deletingLastPathComponent())
            let kept = await replies(reopened)
            XCTAssertEqual(kept.count, 0, what)
            XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path), what)
            await reopened.close()
            // And it opens again: nothing it wrote is refused.
            let again = try chat.session("chat", client: StallingClient(), resume: copy.path, in: copy.deletingLastPathComponent())
            await again.close()
        }
    }

    /// A cut-off reply the run cannot journal keeps its log, set aside,
    /// when the run settles.
    func testAReplyTheRunCannotJournalKeepsItsLogAside() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient()
        // When the run is saved as settled, the log is already aside: a
        // crash just after must not leave it where a reopen removes it.
        let logAtSettle = LockedFlags(), logPath = LockedFlags()
        let session = try chat.session("chat", client: client, beforeAppend: { record in
            if record["message"]["role"].text == "assistant" { throw AgentError("session_record_limit", "fixture: the record will not write") }
            if record["customType"].text == JournalRecordKind.state, record["data"]["active"].flag == false, let path = logPath.value {
                logAtSettle.value = FileManager.default.fileExists(atPath: path) ? "in place" : "aside"
            }
        })
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath), journal = URL(fileURLWithPath: path)
        logPath.value = PartialReplyLog.url(for: journal).path
        await session.stop()
        try await eventually { !(await session.isRunning) }
        XCTAssertEqual(logAtSettle.value, "aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialReplyLog.url(for: journal).path))
        let directory = journal.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(journal.lastPathComponent + ".stream-unrestored-") }
        XCTAssertEqual(aside.count, 1)
        let kept = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(aside.first)), encoding: .utf8)
        XCTAssertTrue(kept.contains("piece 29"), "everything that streamed, the last moment too")
        await session.close()
    }

    /// A journal torn by the same crash opens only as a recovered copy; the
    /// reply goes with the copy, its place moved with the copy's header.
    func testARecoveredCopyOfATornJournalKeepsTheReply() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path, streamingID = await session.partialID
        let path = try XCTUnwrap(sessionPath)
        try await Task.sleep(nanoseconds: 3 * PartialReplyLog.flushDelayNanoseconds)
        let copy = try killedCopy(path), directory = copy.deletingLastPathComponent()
        await session.close()
        let torn = try FileHandle(forWritingTo: copy); try torn.seekToEnd()
        try torn.write(contentsOf: Data(#"{"type":"custom","id":"unfinish"#.utf8)); try torn.close()
        XCTAssertThrowsError(try chat.session("chat", client: StallingClient(), resume: copy.path, in: directory))

        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(chat.root.path), "directory": JSON(directory.path), "mcp": ["servers": [:]]])
        let recovered = try await host.command("session.recover", sessionID: nil, params: ["path": JSON(copy.path), "newSessionId": "recovered-chat"])
        await host.shutdown()
        let recoveredPath = try XCTUnwrap(recovered["sessionFile"].text)
        let reopened = try chat.session("recovered-chat", client: StallingClient(), resume: recoveredPath, in: directory)
        let kept = await replies(reopened)
        XCTAssertEqual(kept.map(\.id), [try XCTUnwrap(streamingID)]); XCTAssertEqual(kept.first?.text, pieces.joined())
        XCTAssertTrue(FileManager.default.fileExists(atPath: PartialReplyLog.url(for: copy).path), "the original is left as it was")
        await reopened.close()
    }

    /// A reply the journal will not take is kept aside, and the chat says so.
    func testAReplyThatCannotBeWrittenBackIsKeptAsideAndSaid() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        let sessionPath = await session.path
        let path = try XCTUnwrap(sessionPath)
        try await Task.sleep(nanoseconds: 3 * PartialReplyLog.flushDelayNanoseconds)
        let copy = try killedCopy(path), directory = copy.deletingLastPathComponent()
        await session.close()

        let reopened = try chat.session("chat", client: StallingClient(), resume: copy.path, in: directory, beforeAppend: { record in
            if record["message"]["role"].text == "assistant" { throw AgentError("session_record_limit", "fixture: the record will not write") }
        })
        let kept = await replies(reopened), notice = await reopened.errorMessage
        XCTAssertEqual(kept.count, 0)
        XCTAssertTrue(notice?.contains("could not be added back") == true, notice ?? "no notice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialReplyLog.url(for: copy).path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(copy.lastPathComponent + ".stream-unrestored-") }
        XCTAssertEqual(aside.count, 1, "kept beside the chat's file")
        await reopened.close()
    }

    /// A reply that ended but whose row the journal refused keeps its log
    /// too, with its last moment.
    func testAFinishedReplyTheJournalRefusesKeepsItsLogAside() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = DeltaThenAnswerClient(pieces: pieces)
        let session = try chat.session("chat", client: client, beforeAppend: { record in
            if record["message"]["role"].text == "assistant" { throw AgentError("session_record_limit", "fixture: the record will not write") }
        })
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let sessionPath = await session.path
        let journal = URL(fileURLWithPath: try XCTUnwrap(sessionPath)), directory = journal.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialReplyLog.url(for: journal).path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(journal.lastPathComponent + ".stream-unrestored-") }
        XCTAssertEqual(aside.count, 1)
        let kept = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(aside.first)), encoding: .utf8)
        XCTAssertTrue(kept.contains("piece 29"))
        await session.close()
    }

    /// Text arrives token by token; it is written a batch at a time.
    func testDeltasAreWrittenInBatches() async throws {
        let chat = try chat(); defer { try? FileManager.default.removeItem(at: chat.root) }
        let client = StallingClient(), session = try chat.session("chat", client: client)
        _ = try await session.submit(Submission(commandID: "c1", turnID: "t1", text: "a question"), steer: false)
        try await stream(client)
        try await Task.sleep(nanoseconds: 3 * PartialReplyLog.flushDelayNanoseconds)
        let writes = await session.partialReplyLog?.writes ?? 0
        XCTAssertGreaterThan(writes, 0)
        XCTAssertLessThan(writes, 5, "\(pieces.count * 2 + 2) deltas, written together")
        await session.close()
    }
}
