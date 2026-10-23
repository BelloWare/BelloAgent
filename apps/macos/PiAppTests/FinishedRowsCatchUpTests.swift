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

    /// `firstRead`: what the chat's first read returns, when not its finished page.
    /// `journal`, `otherJournal`: the finished chat's and another chat's journals, when they have one.
    @MainActor private func model(_ reads: Reads, firstRead: [(id: String, role: String, text: String)]? = nil, journal: URL? = nil,
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
            return try Self.page(read == 1 ? firstRead ?? Self.finishedPage : Self.finishedPage)
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

    /// The journal scan read for a finished chat out of sight runs off the
    /// reader every chat's reads go through: a chat opened meanwhile reads at
    /// once instead of waiting for it. Before, the scan ran on that reader, so
    /// another chat's opening waited for the whole scan, hundreds of
    /// milliseconds in a long chat, its own reads already cached (review,
    /// round 2).
    @MainActor func testAChatOpenedWhileTheFinishedJournalIsScannedDoesNotWaitForIt() async throws {
        // About 16 MB, long enough to scan that an opening overlaps it.
        let journal = try self.journal("finished", turns: 2_000, replyBytes: 8_192)
        let otherJournal = try self.journal("other", turns: 3, replyBytes: 100)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int)
        let reads = Reads(), model = try await model(reads, journal: journal, otherJournal: otherJournal)
        let other = try XCTUnwrap(model.record("other"))
        await model.readInheritedSubagents(other, current: { true })
        let view = leftWhileArriving(model)
        model.catchUpFinishedRows(view.id)
        let read = try XCTUnwrap(view.finishedRowsRead)
        // The page is held; the scan follows it.
        while view.heldRowsOutlived { await Task.yield() }
        var scanningAtFirstRead: Bool?
        model.openSteps = { chat, step in
            if chat == "other", step == "inherited agents read", scanningAtFirstRead == nil { scanningAtFirstRead = view.finishedRowsRead != nil }
        }
        await model.select("other")
        model.openSteps = nil
        XCTAssertEqual(scanningAtFirstRead, true, "the other chat read its journal while the finished one's was still being scanned")
        await read.value
        let scanned = await model.history.subagentScannedBytes
        XCTAssertGreaterThanOrEqual(scanned, size, "the finished chat's journal was scanned whole, off the reader")
        let item = try XCTUnwrap(model.record(view.id))
        await model.readInheritedSubagents(item, current: { true })
        let again = await model.history.subagentScannedBytes
        XCTAssertEqual(again, scanned, "and kept: the opening finds it read")
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
