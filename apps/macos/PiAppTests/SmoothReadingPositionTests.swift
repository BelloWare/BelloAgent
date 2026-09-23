import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp

extension SmoothShellTests {
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

    @MainActor func testTheReadingPositionHoldsThroughEveryChangeAroundTheTranscript() async throws {
        let shell = try shell(["Reading"], rows: 60)
        let session = try XCTUnwrap(shell.model.displays[shell.chats[0].id])
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        await shell.scrollAwayFromTheBottom()
        XCTAssertFalse(shell.page?.followsBottom ?? true, "the reader must be away from the newest row for this to mean anything")

        /// A change that does not alter the pane's width keeps the reader on
        /// the same content: the scroll offset and the row's own place in the
        /// document are untouched. A change that does alter it reflows the
        /// text, so what must hold is the row's place on the screen.
        func holds(_ what: String, reflows: Bool, settle seconds: Double = 0.6, tolerance: CGFloat = 2,
                   _ change: () -> Void) async throws {
            let before = try XCTUnwrap(shell.readingRow(), "no row is in view before " + what)
            let offsetBefore = shell.offset
            change()
            // Five ticks through the change, not only where it lands: an
            // animated pane moves the reader's row on every frame or on none
            // of them, and only the frames can tell which.
            for tick in 1...5 {
                shell.draw()
                if let now = shell.readingRow(), now.id == before.id {
                    XCTAssertEqual(now.screenY, before.screenY, accuracy: tolerance,
                                   "\(what) moved the row the reader was on by \(Int(now.screenY - before.screenY)) points at tick \(tick)")
                }
                try? await Task.sleep(for: .milliseconds(PiMotion.baseMilliseconds / 5))
            }
            await shell.settle(seconds)
            let after = try XCTUnwrap(shell.readingRow(), "no row is in view after " + what)
            XCTAssertEqual(after.id, before.id, "\(what) moved the reader onto another row")
            XCTAssertEqual(after.screenY, before.screenY, accuracy: tolerance,
                           "\(what) moved the row the reader was on by \(Int(after.screenY - before.screenY)) points")
            if !reflows {
                XCTAssertEqual(shell.offset, offsetBefore, accuracy: tolerance,
                               "\(what) scrolled the page by \(Int(shell.offset - offsetBefore)) points")
                XCTAssertEqual(after.contentY, before.contentY, accuracy: 1, "\(what) moved the row inside the document")
            }
            XCTAssertFalse(shell.page?.followsBottom ?? true, "\(what) put the page back on the newest row")
        }

        // The composer grows as a long draft is typed, and shrinks again.
        try await holds("a composer grown to five lines", reflows: false) {
            session.draft = (1...5).map { "Line \($0) of a draft that makes the composer taller." }.joined(separator: "\n")
        }
        try await holds("a composer shrunk back to one line", reflows: false) { session.draft = "One line." }
        // A follow-up waiting behind the run appears under the conversation.
        try await holds("the follow-up panel appearing", reflows: false) {
            session.queue = [["turnId": .string("q1"), "text": .string("Then summarise the change in one line.")]]
        }
        try await holds("the follow-up panel leaving", reflows: false) { session.queue = [] }
        // The error strip takes room from the top of the content column.
        // Pushing the column down takes the conversation out from under the
        // titlebar and AppKit removes the inset it had put there;
        // `TranscriptNativeScrollView` moves the clip view by the difference,
        // so the reader stays on the same line.
        try await holds("the error strip arriving", reflows: false) {
            shell.model.error = "The gateway refused the request: 400 invalid_request_error — the model does not accept that output limit on this route."
        }
        try await holds("the error strip dismissed", reflows: false) { shell.model.error = nil }
        // The terminal opens under the conversation and closes again.
        try await holds("the terminal opening", reflows: false, settle: 1.0) { shell.model.toggleTerminal() }
        try await holds("the terminal closing", reflows: false, settle: 1.0) { shell.model.toggleTerminal() }
        // The window and the sidebar's edge both change the pane's width.
        try await holds("the window narrowed by 200 points", reflows: true, settle: 1.0) {
            shell.window.setContentSize(NSSize(width: 1_080, height: 880))
        }
        try await holds("the sidebar widened", reflows: true, settle: 1.0) {
            WindowChrome.adjustStoredSidebarWidth(by: 3 * WindowChrome.widthStep)
        }
        WindowChrome.adjustStoredSidebarWidth(by: -3 * WindowChrome.widthStep)
        await shell.settle(0.6)
        // A side conversation halves the pane.
        try await holds("a side conversation opening beside the chat", reflows: true, settle: 1.4) {
            shell.model.openSide(parentID: shell.chats[0].id)
        }
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

    /// Every animated change to the shell, driven frame by frame for the
    /// length of the animation: what one tick costs the main thread, and
    /// whether any tick misses a 120 Hz frame.
    ///
    /// What is asserted about the geometry is that it does *not* move more
    /// than once. The panels slide and fade over the room they take, rather
    /// than growing into it: a panel whose height is interpolated drags the
    /// conversation's edge across a fifth of a second, and for the strip
    /// above the conversation that is the line the reader is on. The travel
    /// is the transition's own; the layout lands in one step and stays.
    @MainActor func testEveryTransitionHoldsAFrameOfTheBudget() async throws {
        let shell = try shell(["Moving"], rows: 60)
        let session = try XCTUnwrap(shell.model.displays[shell.chats[0].id])
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)

        /// Drives frames for the length of the animation, returning what each
        /// one cost and how many distinct pane geometries were drawn.
        @MainActor func run(_ what: String, over milliseconds: Int = PiMotion.baseMilliseconds,
                            _ change: () -> Void) async -> (mean: Double, worst: Double, ticks: Int, steps: Int) {
            var costs: [Double] = [], geometries: Set<Int> = []
            change()
            let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
            // The animation runs on the wall clock, so how many frames land
            // inside it is what the machine can give: under load, two or
            // three. The loop goes on past its end until it has driven five.
            // Those frames draw the pane the animation landed on, so they add
            // no height to the count of distinct ones, and their cost is still
            // held to the frame budget.
            var inside = 0
            while Date() < deadline || costs.count <= 4 {
                if Date() < deadline { inside += 1 }
                let started = ProcessInfo.processInfo.systemUptime
                shell.draw()
                costs.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                geometries.insert(Int((shell.transcriptFrame.height * 4).rounded()))
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(4))
            }
            await shell.settle(0.5)
            let mean = costs.reduce(0, +) / Double(max(1, costs.count))
            let worst = costs.max() ?? 0
            print(String(format: "PERF smooth transition %@: %d frames (%d inside the animation), mean %.2f ms, worst %.2f ms, %d distinct heights",
                         what, costs.count, inside, mean, worst, geometries.count))
            return (mean, worst, costs.count, geometries.count)
        }

        /// One 120 Hz frame. Nothing a transition does may cost more.
        let frame = 1_000.0 / 120
        /// The target is under 2 ms a frame and that is what Release
        /// measures; what is asserted is a ceiling this machine still clears
        /// with the rest of the suite running beside it.
        let ceiling = 4.0
        var animated: [String] = [], snapped: [String] = []
        // Opening the terminal starts a login shell on its first frame, which
        // can take the whole window on a loaded machine, so that one change
        // is not held to a count of driven frames.
        let changes: [(what: String, driven: Bool, change: () -> Void)] = [
            ("the follow-up panel arriving", true, { session.queue = [["turnId": .string("q1"), "text": .string("Then summarise the change.")]] }),
            ("the follow-up panel leaving", true, { session.queue = [] }),
            ("the error strip arriving", true, { shell.model.error = "The gateway refused the request: 400 invalid_request_error." }),
            ("the error strip leaving", true, { shell.model.error = nil }),
            ("the terminal opening", false, { shell.model.toggleTerminal() }),
            ("the terminal closing", true, { shell.model.toggleTerminal() })
        ]
        for (what, driven, change) in changes {
            let result = await run(what, change)
            XCTAssertLessThan(result.mean, ceiling, "\(what) cost \(result.mean) ms a frame")
            XCTAssertLessThan(result.worst, frame, "\(what) missed a 120 Hz frame: \(result.worst) ms")
            if driven { XCTAssertGreaterThan(result.ticks, 4, "\(what) was not driven for long enough to mean anything") }
            if result.steps > 2 { animated.append(what) } else { snapped.append(what) }
        }
        print("PERF smooth transitions whose layout landed in one step: \(snapped.joined(separator: ", "))"
              + (animated.isEmpty ? "" : " — interpolated their height: \(animated.joined(separator: ", "))"))
        XCTAssertTrue(animated.isEmpty,
                      "these changes interpolate the conversation's own edge, which drags the line the reader is on: "
                      + animated.joined(separator: ", "))
    }
}
