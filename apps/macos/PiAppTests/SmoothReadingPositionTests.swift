import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp

final class SmoothReadingPositionTests: SmoothShellTestCase {
    // MARK: 2. The reading position holds through every change around the transcript

    /// Everything that changes the pane's size around the conversation, with
    /// the reader parked away from the newest row: the row they are on must
    /// stay on the same line of the pane, and the page must not scroll itself.
    /// Page Up and Page Down, Home and End move the reader through the
    /// conversation. They are delivered to the window the way a keyboard
    /// delivers them, which means they land on the composer — where the
    /// reader's focus lives — and the composer hands them on.
    @MainActor func testTheKeysThatPageThroughAChatReachItFromTheComposer() async throws {
        let shell = try shell(["Reading"], rows: 60)
        defer { shell.close() }
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        let editor = try XCTUnwrap(shell.editor)
        XCTAssertTrue(shell.window.makeFirstResponder(editor))
        shell.page?.jumpToLatest()
        await shell.settle(0.8)
        let bottom = shell.offset
        XCTAssertGreaterThan(bottom, 300, "the fixture must have a conversation to page back through")
        let draft = editor.string

        @MainActor func press(_ keyCode: UInt16, _ character: String, _ what: String) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: shell.window.windowNumber, context: nil,
                                                       characters: character, charactersIgnoringModifiers: character,
                                                       isARepeat: false, keyCode: keyCode), what)
            shell.window.sendEvent(event)
            await shell.settle(0.4)
        }

        try await press(116, "\u{F72C}", "Page Up")
        XCTAssertLessThan(shell.offset, bottom - 200, "Page Up must move the conversation back")
        XCTAssertTrue(shell.window.firstResponder === editor, "the reader keeps typing where they were")
        XCTAssertFalse(shell.page?.followsBottom ?? true, "paging back detaches the page, as a wheel does")
        let paged = shell.offset

        try await press(121, "\u{F72D}", "Page Down")
        XCTAssertGreaterThan(shell.offset, paged + 200, "Page Down must move it forward again")

        try await press(115, "\u{F729}", "Home")
        XCTAssertEqual(shell.offset, -(shell.scroll?.contentInsets.top ?? 0), accuracy: 2,
                       "Home goes to the start of the conversation")

        try await press(119, "\u{F72B}", "End")
        XCTAssertGreaterThan(shell.offset, bottom - 60, "End goes back to the newest row")
        XCTAssertEqual(editor.string, draft, "paging through a chat must not type into the draft")
        XCTAssertTrue(shell.window.firstResponder === editor)
    }

    /// A draft long enough to scroll keeps these keys: they belong to
    /// whatever the reader is moving through, and that is the field.
    @MainActor func testALongDraftKeepsThePageKeysForItself() async throws {
        let shell = try shell(["Reading"], rows: 60)
        defer { shell.close() }
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        let session = try XCTUnwrap(shell.model.displays[shell.chats[0].id])
        session.draft = (1...40).map { "Line \($0) of a draft far taller than the field it is typed into." }.joined(separator: "\n")
        await shell.settle(0.8)
        let editor = try XCTUnwrap(shell.editor)
        XCTAssertTrue(shell.window.makeFirstResponder(editor))
        XCTAssertFalse(editor.draftFitsInTheField, "the fixture must have a draft that scrolls")
        shell.page?.jumpToLatest()
        await shell.settle(0.8)
        let bottom = shell.offset
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: shell.window.windowNumber, context: nil,
                                                   characters: "\u{F72C}", charactersIgnoringModifiers: "\u{F72C}",
                                                   isARepeat: false, keyCode: 116))
        shell.window.sendEvent(event)
        await shell.settle(0.4)
        XCTAssertEqual(shell.offset, bottom, accuracy: 2, "the conversation must not move while the draft is what scrolls")
    }

    /// The strip used to be an overlay on the whole window: it floated over
    /// the sidebar and painted over the first line of the conversation. It
    /// must take its room from the content column instead.
    @MainActor func testTheErrorStripPushesTheConversationAndLeavesTheSidebarAlone() async throws {
        let shell = try shell(["Pushed"], rows: 30)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        let before = shell.transcriptFrame
        XCTAssertGreaterThan(before.height, 200, "the conversation must be on screen")
        // While the conversation reaches the top of the window, AppKit keeps
        // the titlebar's own inset on its scroll view so the rows can pass
        // under the drag region. Pushing the column down takes that inset
        // away, which is what makes the reader's row shift by its height;
        // recorded here so the figure in the reading-position test is named.
        let titlebarInset = shell.scroll?.contentInsets.top ?? 0
        XCTAssertGreaterThan(titlebarInset, 0, "the conversation reaches the window's top edge")

        shell.model.error = "The gateway refused the request: 400 invalid_request_error — the model \"smooth-model\" does not accept a 300000-token output limit on this route. Reduce the output budget in Settings, or choose a model whose catalog ceiling covers it, then send again."
        // Frame by frame: the room the strip takes must arrive whole. An
        // animated inset would walk the conversation down the pane over a
        // fifth of a second, dragging the line the reader is on with it.
        var heights: Set<Int> = []
        for _ in 0..<24 {
            shell.draw()
            heights.insert(Int(shell.transcriptFrame.maxY.rounded()))
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(12))
        }
        XCTAssertLessThanOrEqual(heights.count, 2,
                                 "the strip interpolated the conversation's top edge through \(heights.sorted()) instead of moving it once")
        let pushed = shell.transcriptFrame
        let taken = before.maxY - pushed.maxY
        print(String(format: "PERF smooth error strip: the conversation's top edge moved down %.0f points and its height fell by %.0f",
                     taken, before.height - pushed.height))
        XCTAssertGreaterThan(taken, 30, "the strip covered the conversation instead of pushing it")
        XCTAssertEqual(shell.scroll?.contentInsets.top ?? -1, 0, accuracy: 0.5,
                       "a pushed conversation no longer reaches the titlebar, so AppKit drops its automatic inset")
        XCTAssertEqual(before.height - pushed.height, taken, accuracy: 2, "the strip must take its room from the top, not from the composer")

        // Nothing the strip draws may reach over the sidebar.
        let sidebarEdge = WindowChrome.storedSidebarWidth
        let strip = Self.tree(shell.hosted).filter { $0.name.contains("SelectionTextField") && $0.frame.minY >= pushed.maxY - 1 }
        XCTAssertFalse(strip.isEmpty, "the strip's message must be on screen above the conversation")
        for entry in strip {
            XCTAssertGreaterThanOrEqual(entry.frame.minX, sidebarEdge,
                                        "the error strip reached over the sidebar (at x \(Int(entry.frame.minX)), sidebar ends at \(Int(sidebarEdge)))")
        }
        shell.model.error = nil
        await shell.settle(0.8)
        XCTAssertEqual(shell.transcriptFrame.maxY, before.maxY, accuracy: 2, "dismissing the strip must give the room back")
        XCTAssertEqual(shell.transcriptFrame.height, before.height, accuracy: 2)
    }

    /// Wheel, page keys and the end of the conversation all leave the reader
    /// exactly where they put them — including while a reply streams below.
    /// The one scroll the app makes for itself is the one that follows the
    /// newest row, and only while the reader is already on it.
    ///
    /// Where they are is the line of text on the pane, not the clip's offset:
    /// the history above them is still being measured a row at a time while
    /// this runs, and each row that lands at its exact height moves the clip by
    /// that row's difference precisely so that nothing on screen moves.
    @MainActor func testScrollingNeverFightsTheReader() async throws {
        let shell = try shell(["Scrolled"], rows: 60)
        let session = try XCTUnwrap(shell.model.displays[shell.chats[0].id])
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        let scroll = try XCTUnwrap(shell.scroll)
        let document = try XCTUnwrap(scroll.documentView)
        let settled = Shell.conversation(rows: 60, prefix: shell.chats[0].id)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 3, "the fixture must be several screens long")

        // The wheel: where the reader stops is where they stay, whatever
        // arrives below them.
        await shell.scrollAwayFromTheBottom(by: 700)
        let afterWheel = shell.offset
        XCTAssertLessThan(afterWheel, max(0, document.frame.height - scroll.contentView.bounds.height) - 400,
                          "the wheel did not move the reader off the newest row")
        XCTAssertGreaterThan(afterWheel, TranscriptPage.earlierThreshold,
                             "the fixture must stay clear of the earlier-page threshold for this to mean anything")
        let line = try XCTUnwrap(shell.readingRow(), "the reader must be looking at a row")
        /// The row the reader was on is still the one they are on, on the
        /// same line of the pane, and the page has not taken them back.
        func assertHeld(_ held: (id: String, contentY: CGFloat, screenY: CGFloat), _ what: String) {
            let now = shell.readingRow()
            XCTAssertEqual(now?.id, held.id, "\(what) moved the reader to another row")
            XCTAssertEqual(now?.screenY ?? .infinity, held.screenY, accuracy: 1, "\(what) moved the line the reader is on")
            XCTAssertFalse(shell.page?.followsBottom ?? true, "\(what) pinned the page to the newest row under the reader")
        }
        session.state = "running"
        session.messages = settled + [TranscriptMessage(id: "stream:tail", role: "assistant", text: "streamed words arrive ",
                                                        state: "streaming", turn: shell.chats[0].id + "-m58")]
        for step in 1...4 {
            session.messages[60] = TranscriptMessage(id: "stream:tail", role: "assistant",
                                                     text: String(repeating: "streamed words arrive here ", count: step * 8),
                                                     state: "streaming", turn: shell.chats[0].id + "-m58")
            await shell.settle(0.35)
            assertHeld(line, "a streamed delta at step \(step)")
        }
        // A second wheel move while the reply is still arriving.
        await shell.scrollAwayFromTheBottom(by: 300)
        let afterSecond = shell.offset
        XCTAssertLessThan(afterSecond, afterWheel - 100, "the second wheel move did not reach the page")
        let secondLine = try XCTUnwrap(shell.readingRow())
        session.messages[60] = TranscriptMessage(id: "stream:tail", role: "assistant",
                                                 text: String(repeating: "streamed words arrive here ", count: 64),
                                                 state: "streaming", turn: shell.chats[0].id + "-m58")
        await shell.settle(0.5)
        assertHeld(secondLine, "a streamed delta after the reader's second move")

        // Back at the newest row — and only there — the page follows.
        shell.page?.jumpToLatest()
        await shell.settle(1.0)
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        XCTAssertEqual(shell.offset, bottom, accuracy: 4, "jumping to the latest reply must land at the end")
        session.messages[60] = TranscriptMessage(id: "stream:tail", role: "assistant",
                                                 text: String(repeating: "streamed words arrive here ", count: 96),
                                                 state: "streaming", turn: shell.chats[0].id + "-m58")
        await shell.settle(0.6)
        XCTAssertEqual(shell.offset, max(0, document.frame.height - scroll.contentView.bounds.height), accuracy: 4,
                       "a reader at the newest row must be carried with it")
        session.state = "idle"
        session.messages = settled
        await shell.settle(0.4)
    }

    /// The mouse wheel itself, the event a real one sends. AppKit lands a
    /// wheel without gesture phases a frame or more after `scrollWheel(with:)`
    /// has returned, and whatever lays the page out in that gap — in the app a
    /// slice measuring history or a streamed token, here a pass forced at once
    /// — takes the reading anchor where the reader still is. Frame by frame
    /// from the event: the reader leaves the end once, by the wheel, and is
    /// never carried back toward it.
    @MainActor func testAWheelIsNotUndoneByAPassThatRunsBeforeItLands() async throws {
        let shell = try shell(["Late wheel"], rows: 60)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        let scroll = try XCTUnwrap(shell.scroll)
        let document = try XCTUnwrap(shell.document)
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        XCTAssertEqual(shell.offset, bottom, accuracy: TranscriptPage.followThreshold, "the chat must open at its newest row")
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 700, wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:)))
        scroll.scrollWheel(with: wheel)
        let landedAtOnce = shell.offset < bottom - 400
        document.layoutNow()
        var offsets: [CGFloat] = []
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            shell.draw()
            offsets.append(shell.offset)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(8))
        }
        let landed = shell.offset
        print(String(format: "PERF smooth late wheel: AppKit %@ the wheel; the reader stands %.0f pt above the end after %d frames",
                     landedAtOnce ? "applied" : "deferred", bottom - landed, offsets.count))
        XCTAssertLessThan(landed, bottom - 400, "the wheel did not move the reader, or an anchor taken before it landed put them back")
        XCTAssertFalse(shell.page?.followsBottom ?? true, "the end of the wheel pinned the page again")
        // Once the wheel has taken them off the end, no frame carries them
        // back toward it: holding their line while rows above re-measure moves
        // the clip by a few points, never by the wheel's own distance.
        if let left = offsets.firstIndex(where: { $0 < bottom - 400 }) {
            for index in offsets.indices.dropFirst(left + 1) {
                XCTAssertLessThan(offsets[index] - offsets[index - 1], 40,
                                  "frame \(index) carried the reader \(Int(offsets[index] - offsets[index - 1])) pt back toward the end")
            }
        }
    }

    // MARK: 2b. What the transitions cost, frame by frame

}
