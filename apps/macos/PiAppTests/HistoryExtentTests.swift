import XCTest
@testable import PiApp

/// The whole chat as one document: a history page says where it stands in
/// the timeline, a page can be read at any row of it, and the transcript
/// knows how many rows lie before and after the window it holds.
final class HistoryExtentTests: XCTestCase {
    @MainActor private func journal(turns: Int) throws -> URL {
        let root = scratchRoot("history-extent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.jsonl")
        try LongChatScroll.journal(turns: turns).write(to: file)
        return file
    }

    /// Each turn of the fixture is five rows: question, reply with two
    /// calls, their two results, and the closing reply.
    @MainActor func testAPageSaysWhereItStandsAndAnyRowCanBeRead() async throws {
        let file = try journal(turns: 40)
        let reader = HistoryReader()
        let newest = try await reader.window(path: file.path)
        XCTAssertEqual(newest.total, 200)
        XCTAssertEqual(newest.start, 200 - newest.messages.count, "the newest page ends at the last row")
        let middle = try await reader.window(path: file.path, position: 101)
        XCTAssertEqual(middle.start, 101)
        XCTAssertEqual(middle.messages.first?.id, "a20a", "row 101 is turn 20's first reply")
        XCTAssertNotNil(middle.older); XCTAssertNotNil(middle.newer)
        let first = try await reader.window(path: file.path, position: 0)
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.messages.first?.id, "u0")
        XCTAssertNil(first.older)
        // Past the end reads the last row's page.
        let past = try await reader.window(path: file.path, position: 10_000)
        XCTAssertEqual(past.messages.last?.id, "a39b")
        XCTAssertNil(past.newer)
    }

    @MainActor func testTheRowsBeforeAndAfterTheWindowAreCounted() throws {
        func row(_ id: String) -> TranscriptMessage { TranscriptMessage(id: id, role: "assistant", text: id) }
        func page(_ ids: [String], start: Int, total: Int) throws -> ConversationHistoryPage {
            let messages: [WireValue] = ids.map { .object(["id": .string($0), "role": .string("assistant"), "text": .string($0)]) }
            return try ConversationHistoryPage(.object(["version": .number(2), "messages": .array(messages), "incarnation": .string("i"), "lineage": .string("l"),
                                                        "older": .null, "newer": .null, "start": .number(Double(start)), "total": .number(Double(total))]))
        }
        let positions = HistoryPositions()
        XCTAssertNil(positions.extent(of: [row("x")], reachesStart: false, reachesEnd: false), "nothing is known before a page says")
        positions.reset(try page(["m10", "m11", "m12"], start: 10, total: 50))
        XCTAssertEqual(positions.extent(of: ["m10", "m11", "m12"].map(row), reachesStart: false, reachesEnd: false),
                       HistoryExtent(before: 10, after: 37, total: 50))
        // A row the window let go of at the front, and a live row at the end
        // no page has named: counted from the rows that are known.
        XCTAssertEqual(positions.extent(of: ["m11", "m12", "live"].map(row), reachesStart: false, reachesEnd: false),
                       HistoryExtent(before: 11, after: 36, total: 50))
        // A page read below joins the window.
        positions.record(try page(["m13", "m14"], start: 13, total: 50))
        XCTAssertEqual(positions.extent(of: ["m10", "m11", "m12", "m13", "m14"].map(row), reachesStart: false, reachesEnd: false)?.after, 35)
        // The window that holds the first and the newest rows has no room around it.
        XCTAssertNil(positions.extent(of: ["m10"].map(row), reachesStart: true, reachesEnd: true))
        XCTAssertEqual(positions.extent(of: ["m10"].map(row), reachesStart: false, reachesEnd: true), HistoryExtent(before: 10, after: 0, total: 50))
        // Live rows a run adds take their places from the window, so it is
        // still placed once every row a page named has left it.
        let live = ["m13", "m14", "live1", "live2"]
        XCTAssertEqual(positions.extent(of: live.map(row), reachesStart: false, reachesEnd: true), HistoryExtent(before: 13, after: 0, total: 50))
        XCTAssertEqual(positions.extent(of: ["live1", "live2", "live3"].map(row), reachesStart: false, reachesEnd: true),
                       HistoryExtent(before: 15, after: 0, total: 50))
        // A chat just made: its one page is the whole timeline, said or not,
        // and the rows a run adds are placed from it.
        let fresh = HistoryPositions()
        fresh.reset(try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]), "incarnation": .string("new:x"), "lineage": .string("root"),
                                                          "older": .null, "newer": .null])))
        XCTAssertNil(fresh.extent(of: ["n0", "n1"].map(row), reachesStart: true, reachesEnd: true))
        XCTAssertEqual(fresh.extent(of: ["n1", "n2"].map(row), reachesStart: false, reachesEnd: true), HistoryExtent(before: 1, after: 0, total: 3))
        // A timeline that changed knows nothing until the next page.
        positions.forget()
        XCTAssertNil(positions.extent(of: ["m10"].map(row), reachesStart: false, reachesEnd: false))
    }

    /// A page read for where the reader dragged to that fails is read again
    /// a moment later, while they are still there: the rows come.
    @MainActor func testAFailedReadForWhereTheReaderDraggedIsTriedAgain() async throws {
        // Longer than the window holds (`TranscriptPaging.residentCaps`).
        let chat = try await LongChatScroll(turns: 200)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        final class Reads: @unchecked Sendable {
            private let lock = NSLock(); private var count = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
            var total: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let reads = Reads(), reader = HistoryReader(), path = try XCTUnwrap(chat.chat.path)
        let marker = HistoryWindowEdge.position(0).dropLast()
        chat.model.historyWindowLoader = { _, cursor, newer, around in
            if let around, around.hasPrefix(marker), let row = Int(around.dropFirst(marker.count)) {
                if reads.next() == 1 { throw HostError.failure("The first read fails") }
                return try ConversationHistoryPage(await reader.window(path: path, position: row))
            }
            if around == HistoryWindowEdge.start { return try ConversationHistoryPage(await reader.window(path: path, start: true)) }
            return try ConversationHistoryPage(await reader.window(path: path, cursor: cursor, newer: newer, around: around))
        }
        _ = await chat.drive(points: 0, seconds: 0.4, input: .drag({ min(0.5, 1 - CGFloat($0) / 0.8) })) { false }
        chat.endGesture()
        try await eventually("The rows never came after the failed read", timeout: .seconds(8)) {
            chat.draw(); return !chat.blankViewport && chat.document?.visibleContentPrepared == true
        }
        let state = "window \(chat.view.messages.first?.id ?? "-")…\(chat.view.messages.last?.id ?? "-"), clip \(chat.clipY), knob \(chat.knobFraction), leading \(chat.document?.leadingSpace ?? -1), reading \(chat.readingRow()?.id ?? "-")"
        XCTAssertGreaterThanOrEqual(reads.total, 2, "The failed read was tried again: \(state)")
        let id = try XCTUnwrap(chat.readingRow()?.id)
        let turn = try XCTUnwrap(Int(id.drop { !$0.isNumber }.prefix { $0.isNumber }))
        XCTAssertEqual(Double(turn) / 199, 0.5, accuracy: 0.2, "The reader is where they dragged to (turn \(turn))")
    }

    /// A page read by position lands on the first row the transcript draws:
    /// an assistant record with nothing to show (an old empty reply) draws no
    /// row, and landing on it left the reader in blank room.
    @MainActor func testAPositionReadLandsOnARowTheTranscriptDraws() {
        let empty = TranscriptMessage(id: "a0", role: "assistant", text: "")
        let question = TranscriptMessage(id: "u1", role: "user", text: "Question 1?")
        let reply = TranscriptMessage(id: "a1", role: "assistant", text: "An answer.")
        let drawn = Set(TranscriptActivity.blocks(of: [empty, question, reply], complete: false).flatMap(\.messageIDs))
        XCTAssertFalse(drawn.contains("a0"), "The fixture's empty reply draws no row")
        XCTAssertEqual(WorkspaceModel.landingMessageID(in: [empty, question, reply]), "u1")
        XCTAssertEqual(WorkspaceModel.landingMessageID(in: [question, reply]), "u1")
    }

    /// A page holding only rows with nothing to draw is not the end of the
    /// read: the pages after it are read until one draws a row, and that one
    /// is landed on.
    @MainActor func testAPositionReadFollowsPastPagesWithNothingToDraw() async throws {
        func cursor(_ entry: String) -> WireValue { .object(["incarnation": .string("i"), "lineage": .string("l"), "entry": .string(entry)]) }
        func page(_ rows: [(String, String, String)], older: String?, newer: String?) throws -> ConversationHistoryPage {
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("i"), "lineage": .string("l"),
                "messages": .array(rows.map { .object(["id": .string($0.0), "role": .string($0.1), "text": .string($0.2)]) }),
                "older": older.map(cursor) ?? .null, "newer": newer.map(cursor) ?? .null]))
        }
        let empty = try page([("a0", "assistant", "")], older: nil, newer: "a0")
        let alsoEmpty = try page([("a1", "assistant", "")], older: "a1", newer: "a1")
        let drawn = try page([("u2", "user", "Question 2?"), ("a2", "assistant", "An answer.")], older: "u2", newer: nil)
        var reads: [String] = []
        let found = try await WorkspaceModel.drawablePage(from: empty) { boundary, newer in
            reads.append(boundary.entry + (newer ? " newer" : " older"))
            return boundary.entry == "a0" ? alsoEmpty : drawn
        }
        XCTAssertEqual(found?.landing, "u2")
        XCTAssertEqual(found?.page.messages.first?.id, "u2")
        XCTAssertEqual(reads, ["a0 newer", "a1 newer"])
        // Nothing after it draws: the pages before it are read.
        let last = try page([("a9", "assistant", "")], older: "a9", newer: nil)
        let before = try await WorkspaceModel.drawablePage(from: last) { _, newer in newer ? last : drawn }
        XCTAssertEqual(before?.landing, "u2")
    }

    /// A window that lets go of its earliest rows as the chat grows (the
    /// window was at the chat's start) keeps room for them: the rows and the
    /// earlier boundary are published together.
    @MainActor func testAWindowThatLetsGoOfItsFirstRowsKeepsRoomForThem() async throws {
        let chat = try await LongChatScroll(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        await chat.model.revealStartOfChat(sessionID: chat.chat.id)
        try await eventually("Home never read the chat's first page") { chat.draw(); return chat.view.olderPage.cursor == nil && chat.view.messages.first?.id == "u0" }
        for _ in 0..<10 { chat.draw(); try await Task.sleep(for: .milliseconds(10)) }
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 4, bytes: caps.bytes)
        defer { TranscriptPaging.residentCaps = caps }
        // Nothing holds the window: the reader's anchor has gone (they moved).
        // (Once no page is being read, which is when a window lets go.)
        try await eventually("The window never let go of its first rows", timeout: .seconds(10)) {
            chat.view.scrollAnchor = nil; chat.view.pinnedHistoryIDs = []
            chat.model.releaseHeldWindow(chat.view); chat.draw()
            return chat.view.messages.first?.id != "u0"
        }
        // As it lets go (the page reads them back as the reader scrolls).
        XCTAssertNotNil(chat.view.olderPage.cursor)
        XCTAssertGreaterThan(chat.page?.snapshot?.extent?.before ?? 0, 0, "The rows let go of keep their room")
    }

    /// A source that says its history changed (the helper rejects the
    /// boundary with `history_changed`) is a changed conversation, offered
    /// Reload, not a read to try again forever.
    func testAHelperThatSaysItsHistoryChangedIsASourceChange() {
        XCTAssertTrue(WorkspaceModel.isSourceChange(HostError.rejected("history_changed", "The history boundary is no longer available. Reload history.")))
        XCTAssertTrue(WorkspaceModel.isSourceChange(HostError.rejected("message_missing", "That message is outside the current branch.")))
        XCTAssertTrue(WorkspaceModel.isSourceChange(HostError.failure("History was replaced or edited. Reload it to reanchor safely.")))
        XCTAssertFalse(WorkspaceModel.isSourceChange(HostError.rejected("timeout", "The helper did not answer.")))
        XCTAssertFalse(WorkspaceModel.isSourceChange(HostError.failure("The helper stopped.")))
    }

    /// Clicking a reply's text gives it the keyboard without selecting
    /// anything: that must not hold its row, or every far scroll and drag
    /// would be refused. A selection, or text being edited, does.
    @MainActor func testOnlyASelectionOrAnEditorHoldsItsRow() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        text.string = "A reply the reader clicked."
        text.isEditable = false; text.isSelectable = true
        text.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(TranscriptNativeDocument.responderHoldsRow(text), "focus alone")
        text.setSelectedRange(NSRange(location: 2, length: 5))
        XCTAssertTrue(TranscriptNativeDocument.responderHoldsRow(text), "a selection")
        text.setSelectedRange(NSRange(location: 0, length: 0)); text.isEditable = true
        XCTAssertTrue(TranscriptNativeDocument.responderHoldsRow(text), "an editor")
        XCTAssertFalse(TranscriptNativeDocument.responderHoldsRow(nil))
        XCTAssertFalse(TranscriptNativeDocument.responderHoldsRow(NSButton()), "a control")
    }

    /// The chat's row height is measured again when the pane's width
    /// changes (every row's height does), and as the window grows near its
    /// cap, not only when it doubles.
    @MainActor func testTheRowHeightIsMeasuredAgainAfterAResizeAndNearTheCap() {
        XCTAssertFalse(TranscriptNativeDocument.remeasuresHistoryRowHeight(count: 20, sample: 15, width: 800, sampleWidth: 800))
        XCTAssertTrue(TranscriptNativeDocument.remeasuresHistoryRowHeight(count: 30, sample: 15, width: 800, sampleWidth: 800))
        XCTAssertTrue(TranscriptNativeDocument.remeasuresHistoryRowHeight(count: 20, sample: 15, width: 500, sampleWidth: 800), "the width changed")
        XCTAssertTrue(TranscriptNativeDocument.remeasuresHistoryRowHeight(count: 480, sample: 300, width: 800, sampleWidth: 800), "near the cap")
        XCTAssertFalse(TranscriptNativeDocument.remeasuresHistoryRowHeight(count: 320, sample: 300, width: 800, sampleWidth: 800))
    }

    /// A far read refused because the reader holds a selection says so at
    /// the earlier edge.
    @MainActor func testAFarReadRefusedForASelectionSaysSo() async throws {
        let chat = try await LongChatScroll(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        chat.view.pinnedHistoryIDs = [chat.view.messages.last!.id]
        chat.model.jumpToHistoryPosition(chat.chat.id, position: 10, offset: 0)
        XCTAssertEqual(chat.view.olderPage.error, WorkspaceModel.selectionHoldsWindow)
        XCTAssertNil(chat.view.jumpRead, "No read was made")
    }

    /// A position read whose window came from the other source (the helper)
    /// checks that window's entry is still in the journal's branch.
    @MainActor func testAPositionReadHandedOverChecksTheWindowsEntry() async throws {
        let chat = try await LongChatScroll(turns: 30)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        let lineage = try XCTUnwrap(chat.view.presentation.identity?.lineage)
        let held = ConversationCursor(incarnation: "helper:x", lineage: lineage, entry: "u3")
        let page = try await chat.model.readConversationWindow(chat.chat, cursor: nil, position: 50, validating: held)
        XCTAssertEqual(page.start, 50)
        do {
            _ = try await chat.model.readConversationWindow(chat.chat, cursor: nil, position: 50,
                                                            validating: ConversationCursor(incarnation: "helper:x", lineage: lineage, entry: "gone"))
            XCTFail("A window whose entry is gone was read by position")
        } catch { XCTAssertTrue(WorkspaceModel.isSourceChange(error), "\(error)") }
        do {
            _ = try await chat.model.readConversationWindow(chat.chat, cursor: nil, position: 50,
                                                            validating: ConversationCursor(incarnation: "helper:x", lineage: "another", entry: "u3"))
            XCTFail("A window of another branch was read by position")
        } catch { XCTAssertTrue(WorkspaceModel.isSourceChange(error), "\(error)") }
    }
}
