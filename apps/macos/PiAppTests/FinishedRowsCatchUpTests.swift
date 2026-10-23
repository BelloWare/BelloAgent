import XCTest
@testable import PiApp

/// A chat whose run finished while another chat was shown holds its finished
/// page before the reader opens it (`catchUpFinishedRows`, OPEN-1), and opens
/// on it at once. The read that brings the page gives way to the chat being
/// opened, or running again, before it lands; a chat on screen is not read
/// this way, since the snapshot loop already brings it its rows.
final class FinishedRowsCatchUpTests: XCTestCase {
    /// The history reads, by chat, each held until released while its chat is `holding`.
    private actor Reads {
        private(set) var calls: [String] = []
        private var holding: Set<String> = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func hold(_ id: String) { holding.insert(id) }
        func release() { holding = []; let gates = waiting; waiting = []; for gate in gates { gate.resume() } }
        /// Which read of this chat it is, from 1.
        func enter(_ id: String) async -> Int {
            calls.append(id)
            let read = count(id)
            if holding.contains(id) { await withCheckedContinuation { waiting.append($0) } }
            return read
        }
        func count(_ id: String) -> Int { calls.filter { $0 == id }.count }
    }

    private static func page(_ rows: [(id: String, role: String, text: String)]) throws -> ConversationHistoryPage {
        try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("live:finished"), "lineage": .string("root"),
            "messages": .array(rows.map { .object(["id": .string($0.id), "role": .string($0.role), "text": .string($0.text)]) }),
            "older": .null, "newer": .null]))
    }
    private static let finishedPage = [(id: "q", role: "user", text: "A large answer, please"), (id: "r", role: "assistant", text: "The whole answer.")]

    /// `firstRead`, `laterReads`: what the chat's first read, and the reads
    /// after it, return when not its finished page.
    /// `journal`, `otherJournal`: the finished chat's and another chat's journals, when they have one.
    @MainActor private func model(_ reads: Reads, firstRead: [(id: String, role: String, text: String)]? = nil,
                                  laterReads: [(id: String, role: String, text: String)]? = nil, journal: URL? = nil,
                                  otherJournal: URL? = nil) async throws -> WorkspaceModel {
        let root = scratchRoot("finished-rows")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root)
        try await model.reloadConfiguration()
        model.chats = [ChatRecord(id: "finished", workspaceID: "project", title: "Finished", path: journal?.path, profileID: "profile"),
                       ChatRecord(id: "shown", workspaceID: "project", title: "Shown", path: nil, profileID: "profile"),
                       ChatRecord(id: "other", workspaceID: "project", title: "Other", path: otherJournal?.path, profileID: "profile")]
        model.historyWindowLoader = { id, _, _, _ in
            let read = await reads.enter(id)
            guard id == "finished" else { return try Self.page([(id: "s", role: "assistant", text: "Shown")]) }
            return try Self.page(read == 1 ? firstRead ?? Self.finishedPage : laterReads ?? Self.finishedPage)
        }
        await model.select("shown")
        return model
    }

    /// A pi journal for `id` of `turns` turns, each reply `replyBytes` long.
    private func journal(_ id: String, turns: Int, replyBytes: Int) throws -> URL {
        let folder = scratchRoot("finished-rows-journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(id + ".jsonl")
        var data = Data(#"{"type":"session","version":3,"id":"\#(id)"}"#.utf8 + [10])
        let reply = String(repeating: "An answer. ", count: max(1, replyBytes / 11))
        for turn in 0..<turns {
            data += Data(#"{"type":"message","id":"u\#(turn)","message":{"role":"user","content":"Question \#(turn)"}}"#.utf8 + [10])
            data += Data(#"{"type":"message","id":"a\#(turn)","message":{"role":"assistant","content":"\#(reply)"}}"#.utf8 + [10])
        }
        try data.write(to: file)
        return file
    }

    /// The finished chat's display as the reader left it, its reply still
    /// arriving, and its run since ended.
    @MainActor private func leftWhileArriving(_ model: WorkspaceModel) -> SessionDisplay {
        let view = SessionDisplay(id: "finished")
        view.messages = [TranscriptMessage(id: "q", role: "user", text: "A large answer, please"),
                         TranscriptMessage(id: "r", role: "assistant", text: "The answer so", state: "streaming")]
        view.presentation.identity = ("live:finished", "root")
        view.historyState = .ready
        model.displays[view.id] = view
        return view
    }

    @MainActor func testAChatThatFinishedOutOfSightHoldsItsFinishedPageAndOpensOnIt() async throws {
        let reads = Reads(), model = try await model(reads)
        let view = leftWhileArriving(model)
        XCTAssertTrue(view.heldRowsOutlived, "the rows held are the run as the reader left it")
        let request = view.viewportRequest
        model.catchUpFinishedRows(view.id)
        let read = try XCTUnwrap(view.finishedRowsRead, "a finished chat out of sight reads its page")
        await read.value
        XCTAssertEqual(view.messages.map(\.text), ["A large answer, please", "The whole answer."], "it holds its finished page")
        XCTAssertFalse(view.heldRowsOutlived)
        XCTAssertNil(view.finishedRowsRead)
        XCTAssertEqual(view.historyState, .ready, "held, not presented: nothing shows the chat")
        XCTAssertEqual(view.viewportRequest, request, "nor is any page asked to place it")
        // Opened, it is on those rows from the start, uncovered, while the
        // page is read behind them.
        let opening = Task { @MainActor in await model.select("finished") }
        while model.selectedID != "finished" { await Task.yield() }
        XCTAssertEqual(view.presentedMessages.map(\.id), ["q", "r"], "the finished rows are on the page at once")
        XCTAssertEqual(view.presentedMessages.last?.isStreaming, false)
        XCTAssertFalse(ConversationPaneView.coversTranscript(view), "nothing covers them while the page is read")
        await opening.value
        XCTAssertEqual(view.historyState, .preparing)
        XCTAssertEqual(view.messages.map(\.text), ["A large answer, please", "The whole answer."])
        let count = await reads.count("finished")
        XCTAssertEqual(count, 2, "one read as the run ended, one as the chat opened")
    }

    /// Without the read, the same opening drops the outlived rows and opens
    /// covered, as a chat never shown does: what the read is for.
    @MainActor func testWithoutItsFinishedPageTheChatOpensCovered() async throws {
        let reads = Reads(), model = try await model(reads)
        let view = leftWhileArriving(model)
        let opening = Task { @MainActor in await model.select("finished") }
        while model.selectedID != "finished" { await Task.yield() }
        XCTAssertEqual(view.presentedMessages.map(\.id), [], "the rows the run outlived are not shown")
        XCTAssertTrue(ConversationPaneView.coversTranscript(view))
        await opening.value
        XCTAssertEqual(view.messages.map(\.text), ["A large answer, please", "The whole answer."])
    }

    /// The reader opens the chat while its finished page is still being read
    /// for it: the opening reads its own, and the earlier read, landing
    /// after, changes nothing.
    @MainActor func testAnOpeningWhileThePageIsReadReadsItsOwn() async throws {
        let reads = Reads(), model = try await model(reads, firstRead: [(id: "q", role: "user", text: "A large answer, please"), (id: "r", role: "assistant", text: "Read too early.")])
        let view = leftWhileArriving(model)
        await reads.hold("finished")
        model.catchUpFinishedRows(view.id)
        let read = try XCTUnwrap(view.finishedRowsRead)
        while await reads.count("finished") < 1 { await Task.yield() }
        let opening = Task { @MainActor in await model.select("finished") }
        while await reads.count("finished") < 2 { await Task.yield() }
        XCTAssertTrue(ConversationPaneView.coversTranscript(view), "opened before its page came, it opens as before")
        await reads.release()
        await read.value; await opening.value
        XCTAssertEqual(view.historyState, .preparing)
        XCTAssertEqual(view.messages.map(\.text), ["A large answer, please", "The whole answer."], "the opening's page is the one shown")
    }

    /// A chat running again before its page comes keeps what it holds: the
    /// page is no longer what it is.
    @MainActor func testAChatRunningAgainKeepsItsRows() async throws {
        let reads = Reads(), model = try await model(reads)
        let view = leftWhileArriving(model)
        await reads.hold("finished")
        model.catchUpFinishedRows(view.id)
        let read = try XCTUnwrap(view.finishedRowsRead)
        while await reads.count("finished") < 1 { await Task.yield() }
        view.state = "running"
        await reads.release(); await read.value
        XCTAssertEqual(view.messages.last?.text, "The answer so", "a page read for a finished run is not put on a running one")
    }

    /// What the opening reads of the journal before its page, a scan of the
    /// whole file once the run has written to it, is read as the run ends:
    /// the opening scans none of it again.
    @MainActor func testTheOpeningFindsItsJournalScannedAlready() async throws {
        let folder = scratchRoot("finished-rows-journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let journal = folder.appendingPathComponent("finished.jsonl")
        var lines = [#"{"type":"session","version":3,"id":"finished"}"#]
        for turn in 0..<200 {
            lines.append(#"{"type":"message","id":"u\#(turn)","message":{"role":"user","content":"Question \#(turn)"}}"#)
            lines.append(#"{"type":"message","id":"a\#(turn)","message":{"role":"assistant","content":"\#(String(repeating: "An answer. ", count: 80))"}}"#)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: journal)
        let reads = Reads(), model = try await model(reads, journal: journal)
        let view = leftWhileArriving(model)
        // Read when the chat was last opened; the run has written since.
        let item = try XCTUnwrap(model.record(view.id))
        await model.readInheritedSubagents(item, current: { true })
        let file = try FileHandle(forWritingTo: journal); try file.seekToEnd()
        try file.write(contentsOf: Data(#"{"type":"message","id":"q","message":{"role":"user","content":"A large answer, please"}}"#.utf8 + [10])); try file.close()
        model.catchUpFinishedRows(view.id)
        await view.finishedRowsRead?.value
        let scanned = await model.history.subagentScannedBytes
        await model.select(view.id)
        let opened = await model.history.subagentScannedBytes
        XCTAssertEqual(opened - scanned, 0, "the opening finds the journal it scans already scanned")
        XCTAssertEqual(view.messages.map(\.text), ["A large answer, please", "The whole answer."])
    }

    /// The reader moves between other chats while the finished chat's page is
    /// read for it: that read is the chat's own, and lands anyway. Before,
    /// it answered to the workspace's navigation, so a switch from one chat
    /// to another dropped it, and the chat kept the rows its run outlived
    /// until it was opened, covered, again (review, round 2).
    @MainActor func testTheFinishedPageLandsThoughTheReaderMovesOn() async throws {
        let reads = Reads(), model = try await model(reads)
        let view = leftWhileArriving(model)
        await reads.hold("finished")
        model.catchUpFinishedRows(view.id)
        let read = try XCTUnwrap(view.finishedRowsRead)
        while await reads.count("finished") < 1 { await Task.yield() }
        await model.select("other")
        XCTAssertEqual(model.selectedID, "other")
        await reads.release(); await read.value
        XCTAssertEqual(view.messages.last?.text, "The whole answer.", "the finished page lands though the reader moved on")
        XCTAssertFalse(view.heldRowsOutlived)
        let opening = Task { @MainActor in await model.select(view.id) }
        while model.selectedID != view.id { await Task.yield() }
        XCTAssertFalse(ConversationPaneView.coversTranscript(view), "and the chat opens on it, uncovered")
        await opening.value
    }

    /// Where a journal's plan scan waits, as it begins, until released: the
    /// scan held open for as long as a test needs it.
    private final class ScanGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false, released = false
        private let path: String
        init(_ path: URL) { self.path = path.path }
        var hasEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
        func enter(_ scanned: URL) {
            guard scanned.path == path else { return }
            condition.lock(); defer { condition.unlock() }
            entered = true
            let deadline = Date().addingTimeInterval(30)
            while !released, condition.wait(until: deadline) {}
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }

    /// The journal scan read for a finished chat out of sight runs off the
    /// reader every chat's reads go through: a chat opened while it is under
    /// way reads at once instead of waiting for it. Before, the scan ran on
    /// that reader, and another chat's opening waited for the whole scan,
    /// hundreds of milliseconds in a long chat, its own reads already cached
    /// (review, round 2). The scan is held open here until the other chat's
    /// read has completed (review, round 3).
    @MainActor func testAChatOpenedWhileTheFinishedJournalIsScannedDoesNotWaitForIt() async throws {
        let journal = try self.journal("finished", turns: 200, replyBytes: 1_000)
        let otherJournal = try self.journal("other", turns: 3, replyBytes: 100)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int)
        let reads = Reads(), model = try await model(reads, journal: journal, otherJournal: otherJournal)
        let other = try XCTUnwrap(model.record("other"))
        await model.readInheritedSubagents(other, current: { true })
        let gate = ScanGate(journal)
        HistoryReader.planScanStarting = { gate.enter($0) }
        addTeardownBlock { HistoryReader.planScanStarting = nil; gate.release() }
        let view = leftWhileArriving(model)
        model.catchUpFinishedRows(view.id)
        let read = try XCTUnwrap(view.finishedRowsRead)
        let start = ProcessInfo.processInfo.systemUptime
        while !gate.hasEntered, ProcessInfo.processInfo.systemUptime - start < 10 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.hasEntered, "the finished chat's journal scan began")
        // The other chat opens while that scan is held; its first read is of
        // its own journal, already cached.
        var readOwnJournal = false
        model.openSteps = { chat, step in if chat == "other", step == "inherited agents read" { readOwnJournal = true } }
        let opening = Task { @MainActor in await model.select("other") }
        let asked = ProcessInfo.processInfo.systemUptime
        while !readOwnJournal, ProcessInfo.processInfo.systemUptime - asked < 10 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(readOwnJournal, "the other chat read while the finished journal's scan was held")
        gate.release()
        await opening.value; await read.value
        model.openSteps = nil
        let scanned = await model.history.subagentScannedBytes
        XCTAssertGreaterThanOrEqual(scanned, size, "the finished chat's journal was scanned whole, off the reader")
        let item = try XCTUnwrap(model.record(view.id))
        await model.readInheritedSubagents(item, current: { true })
        let again = await model.history.subagentScannedBytes
        XCTAssertEqual(again, scanned, "and kept: the opening finds it read")
    }

    /// The commands a host sent, for the test to answer.
    @MainActor private final class Commands { var frames: [[String: WireValue]] = []; var answered = 0 }

    /// A connected helper whose commands the test answers itself, as the
    /// project's host.
    @MainActor private func answeringHost(_ model: WorkspaceModel) async throws -> (host: HostSupervisor, commands: Commands) {
        let commands = Commands()
        let host = HostSupervisor(commandSender: { commands.frames.append($0) })
        let folder = scratchRoot("finished-rows-host")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await host.connect(cwd: folder, state: folder.appendingPathComponent("host"))
        addTeardownBlock { @MainActor in try? await host.shutdownAndWait(); try? FileManager.default.removeItem(at: folder) }
        model.hosts["project"] = host
        return (host, commands)
    }

    /// The snapshot loop asks for the chat's status, as an event in it does,
    /// and every status it asks for is answered with `state` and the helper's
    /// row revision `revision`, until it asks no more.
    @MainActor private func status(_ state: String, seq: Int, revision: String, of view: SessionDisplay, in model: WorkspaceModel,
                                   host: (host: HostSupervisor, commands: Commands)) async throws {
        model.refresh(view.id)
        var quiet = 0
        while quiet < 10 {
            if host.commands.answered < host.commands.frames.count {
                let frame = host.commands.frames[host.commands.answered]; host.commands.answered += 1
                let result: WireValue = frame["method"]?.string == "session.status"
                    ? .object(["sessionId": .string(view.id), "seq": .number(Double(seq)), "state": .string(state), "runStatus": .string(state),
                               "displayRevision": .string(revision), "queue": .array([]), "queueCount": .number(0)])
                    : .object([:])
                host.host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.host.epoch)),
                                          "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": result]),
                                  connectionID: try XCTUnwrap(host.host.connectionID))
                quiet = 0
            } else if view.snapshotInFlight { quiet = 0 } else { quiet += 1 }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// A run that starts and ends while the finished page is still being
    /// read moves the helper's rows past that page: it is read again, and the
    /// chat holds the page as it is after both runs; a run the read missed
    /// sends the chat back for its page too. Before, the older page was put in
    /// place, its rows finished, so nothing read the chat again, and it opened
    /// on the run before and then changed to the newer page (review, round 3).
    @MainActor func testARunThatComesAndGoesDuringTheReadSendsItBackForTheNewerPage() async throws {
        let afterBoth = Self.finishedPage + [(id: "q2", role: "user", text: "And a short one"), (id: "r2", role: "assistant", text: "A short answer.")]
        let reads = Reads(), model = try await model(reads, laterReads: afterBoth)
        let view = leftWhileArriving(model)
        view.state = "running"
        model.opened.insert(view.id)
        let host = try await answeringHost(model)
        await reads.hold("finished")
        // The run ends out of sight, and its page is read.
        try await status("idle", seq: 5, revision: "epoch:5", of: view, in: model, host: host)
        let read = try XCTUnwrap(view.finishedRowsRead, "the end of the run reads the finished page")
        while await reads.count("finished") < 1 { await Task.yield() }
        // A short follow-up runs and ends while that read is under way.
        try await status("running", seq: 6, revision: "epoch:6", of: view, in: model, host: host)
        try await status("idle", seq: 9, revision: "epoch:9", of: view, in: model, host: host)
        await reads.release(); await read.value
        XCTAssertEqual(view.messages.map(\.id), ["q", "r", "q2", "r2"], "the chat holds the page as it is after both runs")
        XCTAssertFalse(view.heldRowsOutlived)
        // A run the snapshot loop only learns of afterwards.
        let before = await reads.count("finished")
        try await status("idle", seq: 12, revision: "epoch:12", of: view, in: model, host: host)
        await view.finishedRowsRead?.value
        let after = await reads.count("finished")
        XCTAssertEqual(after, before + 1, "rows the helper's have moved past are read again")
        XCTAssertFalse(view.heldRowsOutlived)
        let opening = Task { @MainActor in await model.select(view.id) }
        while model.selectedID != view.id { await Task.yield() }
        XCTAssertEqual(view.presentedMessages.map(\.id), ["q", "r", "q2", "r2"], "opened, it is on that page at once")
        XCTAssertFalse(ConversationPaneView.coversTranscript(view))
        await opening.value
    }

    /// The chat on screen gets its rows from the snapshot loop, and a chat
    /// still running, or holding no outlived rows, needs no read.
    @MainActor func testOnlyAFinishedChatOutOfSightIsRead() async throws {
        let reads = Reads(), model = try await model(reads)
        let view = leftWhileArriving(model)
        view.state = "running"
        model.catchUpFinishedRows(view.id)
        XCTAssertNil(view.finishedRowsRead, "still running")
        view.state = "idle"
        view.messages[1].state = nil
        model.catchUpFinishedRows(view.id)
        XCTAssertNil(view.finishedRowsRead, "nothing outlived")
        view.messages[1].state = "streaming"
        let shown = try XCTUnwrap(model.displays["shown"])
        shown.messages = view.messages; shown.presentation.identity = ("live:shown", "root")
        model.catchUpFinishedRows("shown")
        XCTAssertNil(shown.finishedRowsRead, "on screen")
        model.catchesUpFinishedRows = false
        model.catchUpFinishedRows(view.id)
        XCTAssertNil(view.finishedRowsRead, "switched off, as a measurement does to compare")
        let count = await reads.count("finished")
        XCTAssertEqual(count, 0)
    }
}
