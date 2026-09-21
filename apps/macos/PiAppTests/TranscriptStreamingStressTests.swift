import XCTest
import SwiftUI
import Combine
@testable import PiApp

/// The conversation page driven the way the owner drives it: a long turn
/// arriving one tool call at a time while the reader sits higher up, cards
/// opened and closed, the pane resized, the appearance switched, and two long
/// chats swapped back and forth. Every check is on what the reader sees — row
/// frames, the content each row actually holds, and where the page is parked.
final class TranscriptStreamingStressTests: XCTestCase {

    // MARK: The page in a real window

    @MainActor final class Stage {
        private(set) var session: SessionDisplay
        let page = TranscriptPage()
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow
        let cache: TranscriptGeometryCache
        var environment = TranscriptRowEnvironment()
        var actions = TranscriptActions()
        /// The pane repaints whenever the page publishes; so does this.
        private var pageChanges: AnyCancellable?

        init(_ session: SessionDisplay, width: CGFloat = 820, height: CGFloat = 560,
             cache: TranscriptGeometryCache = TranscriptGeometryCache()) {
            self.session = session
            self.cache = cache
            scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
            document = TranscriptNativeDocument(page: page, geometryCache: cache)
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            page.state = "idle"
            page.bind(session)
            pageChanges = page.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            refresh()
        }
        var rows: [TranscriptRowContainer] { document.retainedRows }
        func row(_ id: String) -> TranscriptRowContainer? { rows.first { $0.itemID == id } }
        /// The row holding the turn's tool calls.
        var workRow: TranscriptRowContainer? {
            rows.first { if case .block(let block) = $0.item { return !block.tools.isEmpty }; return false }
        }
        /// The first reply row, whether or not the turn called any tool.
        var blockRow: TranscriptRowContainer? {
            rows.first { if case .block = $0.item { return true }; return false }
        }
        func workPart(_ row: TranscriptRowContainer) -> TranscriptDisclosure.Part? {
            guard case .block(let block) = row.item else { return nil }
            return .work(block.key)
        }
        /// One pass of exactly what the pane does when the session publishes.
        func refresh() {
            document.update(snapshot: page.snapshot, actions: actions, environment: environment,
                            disclosure: session.disclosure, toolInputs: session.toolInputs)
            document.layoutRows(width: scroll.contentSize.width)
            draw()
        }
        /// What the reader is left looking at: a disclosure's motion has
        /// landed on the geometry the click measured.
        func draw() {
            document.finishDisclosureMotion()
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        /// Another chat in the same pane.
        func show(_ next: SessionDisplay) {
            session = next
            page.bind(next)
            refresh()
        }
        /// The sidebar or the side pane taking or giving back width.
        func resize(width: CGFloat, height: CGFloat? = nil) {
            let size = NSSize(width: width, height: height ?? scroll.frame.height)
            window.setContentSize(size)
            scroll.frame = CGRect(origin: .zero, size: size)
            draw()
        }
        /// The reader dragging a pane's edge: AppKit tells the hierarchy the
        /// drag has begun, delivers a layout per frame, then says it has ended.
        func beginDrag() { scroll.viewWillStartLiveResize(); document.beginLiveResize() }
        func endDrag() { scroll.viewDidEndLiveResize(); document.endLiveResize(); draw() }
        /// A reader's own scroll: the clip moves and AppKit says so.
        func readerScroll(to y: CGFloat) {
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            draw()
        }
        var scrollY: CGFloat { scroll.contentView.bounds.origin.y }
        func settle(turns: Int = 6) async {
            for _ in 0..<turns {
                draw()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            draw()
        }
        /// A long chat comes up with its viewport exact and measures the rest
        /// in idle slices. This waits for the last of them, as a reader who
        /// leaves the chat open does.
        func settleUntilExact(seconds: Double = 60) async {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while document.approximateRowCount > 0, ProcessInfo.processInfo.systemUptime < deadline {
                await settle(turns: 1)
            }
            await settle()
        }
        func close() { window.contentView = nil; window.close() }
    }

    // MARK: Fixtures

    /// Settled turns before the one that is arriving, so there is something to
    /// scroll up into.
    @MainActor static func history(turns: Int) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        for index in 0..<turns {
            messages.append(TranscriptMessage(id: "hu\(index)", role: "user",
                                              text: "Question \(index) about the change we are making.",
                                              at: Double(1_000 + index * 10), turn: "hu\(index)"))
            var reply = TranscriptMessage(id: "ha\(index)", role: "assistant",
                                          text: String(repeating: "Answer \(index) with enough prose to wrap over a few lines in a narrow pane. ", count: 4),
                                          at: Double(1_005 + index * 10), turn: "hu\(index)")
            reply.accounting = GatewayTotals()
            messages.append(reply)
        }
        return messages
    }

    static func toolCall(_ index: Int, state: String = "completed") -> ToolView {
        ToolView(id: "t\(index)", name: index % 3 == 0 ? "bash" : index % 3 == 1 ? "read" : "edit", state: state,
                 input: index % 3 == 0 ? "{\"command\":\"swift build --package-path packages/host\"}" : "{\"path\":\"apps/macos/PiApp/Sources/File\(index).swift\"}",
                 output: String(repeating: "line \(index) of tool output that wraps across the width of the card. ", count: 8),
                 durationMs: 12 + Double(index), truncated: false,
                 path: index % 3 == 0 ? nil : "apps/macos/PiApp/Sources/File\(index).swift")
    }

    // MARK: Shared checks

    /// Rows are stacked: each begins where the previous ended, every row that
    /// is actually mounted holds no more content than its own height, and the
    /// document is as tall as all of them. A row that is not mounted draws
    /// nothing; `assertFitsWhileScrollingThrough` checks those as they arrive.
    @MainActor func assertStacked(_ stage: Stage, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var expected: CGFloat?
        for row in stage.rows {
            if let expected {
                XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5,
                               "\(what): row \(row.itemID) starts at \(row.frame.minY) but the row above ends at \(expected)", file: file, line: line)
            }
            expected = row.frame.maxY
            guard row.superview != nil else { continue }
            XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                     "\(what): row \(row.itemID) holds \(row.hostedFittingHeight) points of content in a \(row.frame.height) point row",
                                     file: file, line: line)
        }
        let bottom = (stage.rows.last?.frame.maxY ?? 0) + 13
        XCTAssertEqual(stage.document.frame.height, bottom, accuracy: 1, "\(what): the document is not as tall as its rows", file: file, line: line)
    }

    /// Reads the whole conversation from top to bottom the way the reader
    /// would, and checks every row as it comes into view: a row that was
    /// measured at one width and mounted at another draws over its neighbour.
    @MainActor func assertFitsWhileScrollingThrough(_ stage: Stage, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let step = max(120, stage.scroll.contentView.bounds.height / 2)
        var y: CGFloat = 0
        var seen: Set<String> = []
        while y <= max(0, stage.document.frame.height - stage.scroll.contentView.bounds.height) + step {
            stage.readerScroll(to: y)
            await stage.settle(turns: 2)
            for row in stage.rows where row.superview != nil {
                seen.insert(row.itemID)
                XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                         "\(what): row \(row.itemID) holds \(row.hostedFittingHeight) points of content in a \(row.frame.height) point row",
                                         file: file, line: line)
            }
            y += step
        }
        XCTAssertEqual(seen.count, stage.rows.count, "\(what): only \(seen.count) of \(stage.rows.count) rows were ever mounted", file: file, line: line)
    }

    /// Every row was measured at the width it is drawn at, not at a probe width.
    @MainActor func assertMeasuredAtDrawnWidth(_ stage: Stage, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = max(1, min(TranscriptMetrics.pageWidth, stage.scroll.contentSize.width - 48))
        for row in stage.rows {
            XCTAssertEqual(row.frame.width, expected, accuracy: 0.5, "\(what): row \(row.itemID) is \(row.frame.width) points wide, not \(expected)", file: file, line: line)
            XCTAssertTrue(row.hasMeasurement(width: expected), "\(what): row \(row.itemID) has no measurement at \(expected)", file: file, line: line)
        }
    }

    // MARK: 1 — A long turn arriving while the reader is higher up

    @MainActor func testALongTurnStreamsWithoutMovingTheReaderOrOverlappingRows() async throws {
        let session = SessionDisplay(id: "stream")
        session.messages = Self.history(turns: 14)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settle()
        assertStacked(stage, "the settled history")

        // The reader scrolls up into the history and stays there.
        stage.readerScroll(to: 120)
        await stage.settle()
        XCTAssertTrue(stage.page.detached, "a reader parked 120 points from the top is not following the bottom")
        let anchor = try XCTUnwrap(stage.row("hu3"))
        let anchorScreenY = anchor.frame.minY - stage.scrollY
        let parkedAt = stage.scrollY

        // The turn begins: the user's row, then a reply that grows.
        var live = TranscriptMessage(id: "stream:a", role: "assistant", text: "", at: 3_000, turn: "u-live")
        live.state = "streaming"
        live.thinking = "Starting on the change. "
        session.messages.append(TranscriptMessage(id: "u-live", role: "user", text: "Work through the whole change.", at: 2_900, turn: "u-live"))
        session.messages.append(live)
        stage.refresh()

        var deltas = 0.0, worst = 0.0, count = 0
        func delta(_ mutate: (inout TranscriptMessage) -> Void) {
            mutate(&live)
            session.messages = session.messages.map { $0.id == live.id ? live : $0 }
            let started = ProcessInfo.processInfo.systemUptime
            stage.refresh()
            let cost = ProcessInfo.processInfo.systemUptime - started
            deltas += cost; worst = max(worst, cost); count += 1
        }

        // Twenty tool calls, one at a time, with reasoning growing alongside.
        for index in 0..<20 {
            delta { reply in
                reply.tools = (reply.tools ?? []) + [Self.toolCall(index, state: "running")]
                reply.thinking = (reply.thinking ?? "") + "Step \(index): read the file and decide what changes. "
            }
            delta { reply in reply.tools?[index].state = "completed" }
            assertStacked(stage, "after tool \(index)")
            XCTAssertEqual(stage.scrollY, parkedAt, accuracy: 1.5, "tool \(index) moved the reader")
            XCTAssertEqual(try XCTUnwrap(stage.row("hu3")).frame.minY - stage.scrollY, anchorScreenY, accuracy: 1.5,
                           "tool \(index) moved the row the reader was looking at")
        }

        // Then the prose, in deltas.
        for index in 0..<24 {
            delta { reply in reply.text += "Sentence \(index) of the answer, long enough to wrap in this pane. " }
            assertStacked(stage, "after prose delta \(index)")
            XCTAssertEqual(stage.scrollY, parkedAt, accuracy: 1.5, "prose delta \(index) moved the reader")
        }

        // The turn finishes: the row settles and the turn line appears.
        live.state = nil
        live.accounting = GatewayTotals()
        session.messages = session.messages.map { $0.id == live.id ? live : $0 }
        stage.page.state = "idle"
        stage.refresh()
        await stage.settle()
        assertStacked(stage, "after the turn line")
        XCTAssertEqual(stage.scrollY, parkedAt, accuracy: 1.5, "the turn line moved the reader")
        XCTAssertEqual(try XCTUnwrap(stage.row("hu3")).frame.minY - stage.scrollY, anchorScreenY, accuracy: 1.5,
                       "the turn line moved the row the reader was looking at")

        print(String(format: "PERF streaming delta among %d rows: %.1f ms mean, %.1f ms worst (snapshot to relaid-out rows)",
                     stage.rows.count, deltas * 1000 / Double(count), worst * 1000))
        XCTAssertLessThan(deltas / Double(count), releaseBudget(0.016), "a streamed delta must cost less than one frame on the main thread")
    }

    /// Folding and unfolding the turn while it is still arriving.
    @MainActor func testFoldingAndUnfoldingWhileTheTurnIsStillArriving() async throws {
        let session = SessionDisplay(id: "fold-live")
        session.messages = Self.history(turns: 4)
        var live = TranscriptMessage(id: "stream:a", role: "assistant", text: "Working on it. ", at: 3_000, turn: "u-live")
        live.state = "streaming"
        live.thinking = "Thinking about the order of the edits. "
        live.tools = (0..<8).map { Self.toolCall($0) }
        session.messages.append(TranscriptMessage(id: "u-live", role: "user", text: "Do the whole change.", at: 2_900, turn: "u-live"))
        session.messages.append(live)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settle()

        let row = try XCTUnwrap(stage.workRow)
        let part = try XCTUnwrap(stage.workPart(row))
        let open = row.frame.height
        row.toggleDisclosure(part)
        stage.draw()
        let folded = row.frame.height
        XCTAssertLessThan(folded, open / 2, "folding a live turn shortens its row at once")
        assertStacked(stage, "folded while live")

        // Keep streaming into the folded turn.
        for index in 8..<20 {
            live.tools = (live.tools ?? []) + [Self.toolCall(index)]
            live.text += "More of the answer. "
            session.messages = session.messages.map { $0.id == live.id ? live : $0 }
            stage.refresh()
            let current = try XCTUnwrap(stage.workRow)
            XCTAssertLessThan(current.frame.height, open, "tool \(index) reopened a turn the reader folded")
            assertStacked(stage, "folded, tool \(index)")
        }
        await stage.settle()
        assertStacked(stage, "folded after settling")

        // Unfold mid-stream: the row grows and everything below still stacks.
        let current = try XCTUnwrap(stage.workRow)
        current.toggleDisclosure(try XCTUnwrap(stage.workPart(current)))
        stage.draw()
        XCTAssertGreaterThan(current.frame.height, folded * 2, "unfolding restores the work rows at once")
        assertStacked(stage, "unfolded while live")
        await stage.settle()
        assertStacked(stage, "unfolded after settling")
    }

    // MARK: 2 — Tool cards through width, appearance, scrolling and chat switches

    @MainActor func testOpenToolCardsSurviveWidthAppearanceScrollingAndChatSwitches() async throws {
        let first = SessionDisplay(id: "cards-a")
        var reply = TranscriptMessage(id: "a1", role: "assistant",
                                      text: String(repeating: "The change is in place. ", count: 8), at: 2_000, turn: "u1")
        reply.thinking = String(repeating: "Weighing the two approaches. ", count: 8)
        reply.tools = (0..<14).map { index in
            var tool = Self.toolCall(index)
            // One card with far more output than the 320-point scroll cap holds.
            if index == 5 { tool.output = (0..<400).map { "output line \($0) of a very long result" }.joined(separator: "\n") }
            return tool
        }
        first.messages = [TranscriptMessage(id: "u1", role: "user", text: "Make the change.", at: 1_000, turn: "u1"), reply]
        let second = SessionDisplay(id: "cards-b")
        second.messages = Self.history(turns: 6)

        let stage = Stage(first); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        row.toggleDisclosure(try XCTUnwrap(stage.workPart(row))); stage.draw()
        let base = row.frame.height

        // The long card opens and is capped, not unbounded.
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","t5")))
        stage.draw()
        let withLong = row.frame.height
        XCTAssertGreaterThan(withLong, base, "opening a card makes its row taller")
        XCTAssertLessThan(withLong - base, 900, "a long result is capped by its own scroll, not laid out in full")
        assertStacked(stage, "one long card open")

        // Several more, and the reasoning.
        for id in ["t1", "t2", "t9"] { row.toggleDisclosure(.tool(ToolOccurrence.key("a1",id))) }
        row.toggleDisclosure(.reasoning("a1"))
        stage.draw()
        let withAll = row.frame.height
        XCTAssertGreaterThan(withAll, withLong, "more open cards make the row taller again")
        assertStacked(stage, "five cards open")

        func assertStillOpen(_ what: String) throws {
            for id in ["t5", "t1", "t2", "t9"] {
                XCTAssertTrue(first.disclosure.isOpen(.tool(ToolOccurrence.key("a1",id))), "\(what): card \(id) closed itself")
            }
            XCTAssertTrue(first.disclosure.isOpen(.reasoning("a1")), "\(what): the reasoning closed itself")
            for id in ["t0", "t3"] { XCTAssertFalse(first.disclosure.isOpen(.tool(ToolOccurrence.key("a1",id))), "\(what): card \(id) opened itself") }
            let current = try XCTUnwrap(stage.workRow)
            XCTAssertEqual(current.frame.height, withAll, accuracy: 1, "\(what): the row is no longer the height its open cards need")
            assertStacked(stage, what)
        }

        // Narrower, then wider, then back.
        stage.resize(width: 560)
        await stage.settle()
        assertStacked(stage, "narrow with cards open")
        assertMeasuredAtDrawnWidth(stage, "narrow with cards open")
        let narrow = try XCTUnwrap(stage.workRow).frame.height
        XCTAssertGreaterThan(narrow, withAll, "the same open cards are taller in a narrower pane")
        stage.resize(width: 820)
        await stage.settle()
        try assertStillOpen("after narrowing and widening")

        // Dark mode.
        stage.environment.colorScheme = .dark
        stage.refresh()
        await stage.settle()
        try assertStillOpen("in dark mode")
        stage.environment.colorScheme = .light
        stage.refresh()
        await stage.settle()
        try assertStillOpen("back in light mode")

        // Out of the viewport and back.
        stage.readerScroll(to: max(0, stage.document.frame.height - 100))
        await stage.settle()
        stage.readerScroll(to: 0)
        await stage.settle()
        try assertStillOpen("after scrolling away and back")

        // Another chat and back.
        stage.show(second)
        await stage.settle()
        assertStacked(stage, "the other chat")
        stage.show(first)
        await stage.settle()
        try assertStillOpen("after switching chats and back")
    }

    // MARK: 3 — Width changes

    @MainActor func testEveryRowRemeasuresAtTheNewWidthInOnePass() async throws {
        let session = SessionDisplay(id: "width")
        var messages = Self.history(turns: 10)
        var reply = TranscriptMessage(id: "wide", role: "assistant", text: "", at: 9_000, turn: "hu9")
        reply.text = """
        A paragraph with a very long unbroken token: \(String(repeating: "abcdefghij", count: 24)) and text after it.

        | Column one | Column two | Column three | Column four |
        | --- | ---: | :---: | --- |
        | \(String(repeating: "wide ", count: 12)) | 1 | yes | note |
        | b | 2 | no | another note |

        - A list item with `inline code` and a [link](https://example.com/page)
          - A nested item that also wraps because it carries a good deal of text
        1. One
        2. Two

        ```swift
        func measure(width: CGFloat) -> CGSize { CGSize(width: width, height: 10) }
        ```
        """
        messages.append(TranscriptMessage(id: "hu10", role: "user", text: "Show me everything.", at: 8_900, turn: "hu10"))
        reply.turn = "hu10"
        messages.append(reply)
        session.messages = messages

        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        assertStacked(stage, "at the opening width")
        assertMeasuredAtDrawnWidth(stage, "at the opening width")

        // The sidebar takes width, the side pane opens, the window shrinks to
        // its minimum, then everything is given back.
        for width in [700.0, 620.0, 520.0, 460.0, 900.0, 820.0] as [CGFloat] {
            let traversalsBefore = stage.document.rowLayoutTraversalCount
            stage.resize(width: width)
            assertStacked(stage, "immediately at width \(width)")
            assertMeasuredAtDrawnWidth(stage, "immediately at width \(width)")
            let traversals = stage.document.rowLayoutTraversalCount - traversalsBefore
            XCTAssertLessThanOrEqual(traversals, stage.rows.count * 2,
                                     "width \(width) laid the row trees out \(traversals) times for \(stage.rows.count) rows")
            await stage.settle()
            assertStacked(stage, "after settling at width \(width)")
            assertMeasuredAtDrawnWidth(stage, "after settling at width \(width)")
            await assertFitsWhileScrollingThrough(stage, "reading the chat at width \(width)")
        }
    }

    @MainActor func testResizingALongHistoryStaysWithinAFrameOfWork() async throws {
        let session = SessionDisplay(id: "width-cost")
        session.messages = Self.history(turns: 60)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        var worst = 0.0, total = 0.0
        let widths: [CGFloat] = [800, 780, 760, 740, 720, 700, 680, 660, 640, 620]
        for width in widths {
            let started = ProcessInfo.processInfo.systemUptime
            stage.resize(width: width)
            let cost = ProcessInfo.processInfo.systemUptime - started
            worst = max(worst, cost); total += cost
        }
        print(String(format: "PERF one resize step over %d rows: %.1f ms mean, %.1f ms worst",
                     stage.rows.count, total * 1000 / Double(widths.count), worst * 1000))
        assertStacked(stage, "after the resize sweep")
    }

    /// Dragging a pane's edge over a long history. Nothing the reader can see
    /// may move, every row must be exact once the drag ends, and a reader who
    /// scrolls down mid-drag must find exact rows there too.
    @MainActor func testDraggingThePanesEdgeOverALongHistory() async throws {
        let session = SessionDisplay(id: "drag")
        session.messages = Self.history(turns: 120)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        // The reader is reading somewhere in the middle, not at the bottom.
        stage.readerScroll(to: stage.document.frame.height / 3)
        await stage.settle()
        XCTAssertTrue(stage.page.detached, "the fixture must have the reader away from the newest row")
        let read = try XCTUnwrap(stage.rows.first { $0.frame.maxY > stage.scrollY })
        let readID = read.itemID
        let screenY = read.frame.minY - stage.scrollY

        stage.beginDrag()
        for width in [800.0, 780.0, 760.0, 740.0, 720.0, 700.0] as [CGFloat] {
            stage.resize(width: width)
            await stage.settle(turns: 3)
            let current = try XCTUnwrap(stage.row(readID))
            XCTAssertEqual(current.frame.minY - stage.scrollY, screenY, accuracy: 1.5,
                           "the row the reader is on moved at width \(width)")
            assertStacked(stage, "mid-drag at \(width)")
            // Whatever is drawn is exact: a row standing at an earlier width is
            // never mounted.
            for row in stage.rows where row.superview != nil {
                XCTAssertFalse(stage.document.isApproximate(row.itemID),
                               "mid-drag at \(width): mounted row \(row.itemID) is still at an earlier width")
            }
        }
        XCTAssertGreaterThan(stage.document.approximateRowCount, 100,
                             "the drag must leave the rows below the reader standing rather than measuring all of them")

        // The reader scrolls down while still dragging: the rows they arrive at
        // are measured before they are drawn.
        stage.readerScroll(to: stage.document.frame.height * 0.8)
        await stage.settle(turns: 3)
        for row in stage.rows where row.superview != nil {
            XCTAssertFalse(stage.document.isApproximate(row.itemID),
                           "scrolling mid-drag mounted row \(row.itemID) at an earlier width")
            XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                     "scrolling mid-drag left row \(row.itemID) holding \(row.hostedFittingHeight) points in \(row.frame.height)")
        }

        // The drag ends: the viewport is exact and idle reconciliation
        // finishes the unseen history without monopolizing mouse-up.
        stage.endDrag()
        await stage.settleUntilExact()
        XCTAssertEqual(stage.document.approximateRowCount, 0, "the page is exact once the drag stops")
        assertStacked(stage, "after the drag")
        assertMeasuredAtDrawnWidth(stage, "after the drag")
        await assertFitsWhileScrollingThrough(stage, "reading the chat after the drag")
    }

    @MainActor func testResizeReleaseDoesNotSynchronouslyMeasureTheRemainingHistory() async throws {
        let session = SessionDisplay(id: "resize-release-budget")
        session.messages = Self.history(turns: 150)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        stage.readerScroll(to: stage.document.frame.height * 0.5)
        await stage.settle()
        let anchor = try XCTUnwrap(stage.rows.first { $0.frame.maxY > stage.scrollY })
        let offset = anchor.frame.minY - stage.scrollY
        stage.beginDrag()
        let before = stage.rows.reduce(0) { $0 + $1.measurementCount }
        let dragStarted = ProcessInfo.processInfo.systemUptime
        stage.resize(width: 640)
        let dragMS = (ProcessInfo.processInfo.systemUptime - dragStarted) * 1000
        let afterDrag = stage.rows.reduce(0) { $0 + $1.measurementCount }
        let releaseStarted = ProcessInfo.processInfo.systemUptime
        stage.endDrag()
        let releaseMS = (ProcessInfo.processInfo.systemUptime - releaseStarted) * 1000
        let afterRelease = stage.rows.reduce(0) { $0 + $1.measurementCount }
        print("REVIEW resize 300 rows at middle: drag \(dragMS) ms / \(afterDrag - before) measurements; release \(releaseMS) ms / \(afterRelease - afterDrag) measurements")
        XCTAssertLessThan(afterDrag - before, 40, "A deep anchor must not synchronously remeasure the prefix")
        XCTAssertLessThan(afterRelease - afterDrag, 20, "Mouse-up must not synchronously finish every offscreen row")
        XCTAssertGreaterThan(stage.document.approximateRowCount, 100, "Offscreen reconciliation remains scheduled")
        XCTAssertEqual(anchor.frame.minY - stage.scrollY, offset, accuracy: 2)
        await stage.settleUntilExact()
        XCTAssertEqual(stage.document.approximateRowCount, 0)
        assertMeasuredAtDrawnWidth(stage, "after bounded reconciliation")
        assertStacked(stage, "after bounded reconciliation")
    }

    @MainActor func testRapidResizeAtTopMiddleAndBottomUsesOnlyTheLatestWidth() async throws {
        let session = SessionDisplay(id: "resize-interrupted")
        session.messages = Self.history(turns: 150)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        for (fraction, width): (Double, CGFloat) in [(0, 640), (0.5, 710), (0.95, 610)] {
            stage.readerScroll(to: stage.document.frame.height * fraction)
            await stage.settle(turns: 1)
            let anchor = try XCTUnwrap(stage.rows.first { $0.frame.maxY > stage.scrollY })
            let offset = anchor.frame.minY - stage.scrollY
            stage.beginDrag(); stage.resize(width: width); stage.endDrag()
            XCTAssertEqual(anchor.frame.minY - stage.scrollY, offset, accuracy: 2)
            let expected = max(1, min(TranscriptMetrics.pageWidth, stage.scroll.contentSize.width - 48))
            for row in stage.rows where row.superview != nil {
                XCTAssertTrue(row.hasMeasurement(width: expected))
                XCTAssertFalse(stage.document.isApproximate(row.itemID))
            }
            assertStacked(stage, "during successive widths")
            // Start some old-width reconciliation, then change width before
            // the hundreds of unseen rows can all settle.
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertGreaterThan(stage.document.approximateRowCount, 0)
        }
        await stage.settleUntilExact()
        XCTAssertEqual(stage.document.approximateRowCount, 0)
        assertMeasuredAtDrawnWidth(stage, "latest width wins")
        assertStacked(stage, "after interrupted reconciliation")
    }

    /// A side pane opening changes the width of every row of the page. What
    /// the reader can see is exact in the pass that does it; the rest stand
    /// at the height they had until the slices reach them, nothing standing
    /// is ever drawn, and the row the reader is on stays on its line of the
    /// screen throughout.
    @MainActor func testAOneShotWidthChangeMeasuresWhatTheReaderCanSeeAtOnce() async throws {
        let session = SessionDisplay(id: "one-shot")
        session.messages = Self.history(turns: 60)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        stage.readerScroll(to: 400)
        await stage.settle()
        let read = try XCTUnwrap(stage.rows.first { $0.frame.maxY > stage.scrollY })
        let readID = read.itemID
        let screenY = read.frame.minY - stage.scrollY

        let started = ProcessInfo.processInfo.systemUptime
        stage.resize(width: 600)
        let cost = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PERF a side pane opening over %d rows: %.1f ms for the pass, %d rows left standing",
                     stage.rows.count, cost * 1000, stage.document.approximateRowCount))
        let expected = max(1, min(TranscriptMetrics.pageWidth, stage.scroll.contentSize.width - 48))
        for row in stage.rows where row.superview != nil {
            XCTAssertTrue(row.hasMeasurement(width: expected), "mounted row \(row.itemID) is not exact at the new width")
            XCTAssertFalse(stage.document.isApproximate(row.itemID), "mounted row \(row.itemID) is standing at an older width")
        }
        let after = try XCTUnwrap(stage.row(readID))
        XCTAssertEqual(after.frame.minY - stage.scrollY, screenY, accuracy: 2,
                       "the row the reader was on moved by \(after.frame.minY - stage.scrollY - screenY) points")
        assertStacked(stage, "just after the side pane opened")
        // 13 ms alone on this machine; the ceiling leaves room for the other
        // builds it shares the cores with.
        XCTAssertLessThan(cost, releaseBudget(0.025), String(format: "the pass took %.1f ms", cost * 1000))

        await stage.settleUntilExact()
        assertMeasuredAtDrawnWidth(stage, "once the slices finished")
        assertStacked(stage, "once the slices finished")
        await assertFitsWhileScrollingThrough(stage, "reading the chat after the side pane opened")
    }

    /// A drag whose end AppKit never reports must not leave the page standing
    /// at an earlier width for good.
    @MainActor func testAnUnfinishedDragStillEndsUpExact() async throws {
        let session = SessionDisplay(id: "unfinished")
        session.messages = Self.history(turns: 60)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        stage.readerScroll(to: 150)
        await stage.settle()
        stage.beginDrag()
        stage.resize(width: 700)
        XCTAssertGreaterThan(stage.document.approximateRowCount, 0, "the drag leaves rows below the reader standing")
        // No end-of-drag ever arrives; the page catches up on its own.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            stage.draw()
            if stage.document.approximateRowCount == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(stage.document.approximateRowCount, 0, "the page measures itself when the drag stops moving")
        assertMeasuredAtDrawnWidth(stage, "after the unfinished drag settled")
        assertStacked(stage, "after the unfinished drag settled")
    }

    @MainActor func testDragStepCostOverFiveHundredRows() async throws {
        let session = SessionDisplay(id: "drag-cost")
        session.messages = Self.history(turns: 250)
        let stage = Stage(session); defer { stage.close() }
        await stage.settleUntilExact()
        stage.readerScroll(to: 400)
        await stage.settle()
        stage.beginDrag()
        var worst = 0.0, total = 0.0
        let widths: [CGFloat] = [800, 780, 760, 740, 720, 700, 680, 660, 640, 620]
        for width in widths {
            let started = ProcessInfo.processInfo.systemUptime
            stage.resize(width: width)
            let cost = ProcessInfo.processInfo.systemUptime - started
            worst = max(worst, cost); total += cost
        }
        print(String(format: "PERF one drag step over %d rows: %.1f ms mean, %.1f ms worst",
                     stage.rows.count, total * 1000 / Double(widths.count), worst * 1000))
        // What a drag step must not do is work proportional to the page: it
        // measures the rows above and inside the reader's viewport and leaves
        // the rest standing. That shape is what a Debug run can hold the page
        // to; the frame budget is a claim about the shipped build, and an
        // absolute number in Debug on a machine running five builds measures
        // the machine.
        let perStep = total / Double(widths.count)
        let oneRow = stage.rows.first.map { row -> Double in
            let started = ProcessInfo.processInfo.systemUptime
            _ = row.measure(width: 601)
            return ProcessInfo.processInfo.systemUptime - started
        } ?? 0.001
        // The shape, in every configuration: a step measures the rows above
        // and inside the reader's viewport and leaves the rest standing, so
        // it costs a small multiple of one row's own layout rather than the
        // five hundred of them a full pass would. No absolute floor here —
        // that is what `releaseBudget` below is for.
        XCTAssertLessThan(perStep, oneRow * 120,
                          String(format: "a drag step over %d rows cost %.1f ms, against %.2f ms for one row's own layout",
                                 stage.rows.count, perStep * 1000, oneRow * 1000))
        XCTAssertLessThan(perStep, releaseBudget(0.016), "a frame of a drag must cost less than a frame")
        stage.endDrag()
        await stage.settle()
        assertStacked(stage, "after the drag sweep")
    }

    // MARK: 4 — Chat switching, earlier pages, the row cap

    /// What opening a long chat costs. The page comes up with the rows the
    /// reader can see measured and the rest standing at an estimate; those are
    /// measured in idle slices. Neither part may measure a row twice, and the
    /// opening pass may not touch the whole page — that is the hang this
    /// guards against.
    @MainActor func testOpeningALongChatMeasuresItsRowsOnce() async throws {
        let turns = ProcessInfo.processInfo.environment["PI_PERF_TURNS"].flatMap(Int.init) ?? 150
        let session = SessionDisplay(id: "open-cost")
        session.messages = Self.history(turns: turns)
        let started = ProcessInfo.processInfo.systemUptime
        let stage = Stage(session); defer { stage.close() }
        let opened = ProcessInfo.processInfo.systemUptime - started
        let measuredToOpen = stage.rows.reduce(0) { $0 + $1.measurementCount }
        XCTAssertEqual(stage.rows.count, turns * 2)
        XCTAssertLessThan(measuredToOpen, 40, "opening the chat measured \(measuredToOpen) of \(stage.rows.count) rows before the reader saw anything")
        XCTAssertGreaterThan(stage.document.approximateRowCount, stage.rows.count / 2, "the rest of the page must stand at an estimate")
        XCTAssertGreaterThan(stage.document.frame.height, stage.scroll.contentView.bounds.height * 4, "an estimated page still has a height to scroll")
        await stage.settleUntilExact()
        let exact = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PERF open a chat of %d rows: %.0f ms to the viewport (%d rows measured), %.0f ms to exact geometry",
                     stage.rows.count, opened * 1000, measuredToOpen, exact * 1000))
        for row in stage.rows { XCTAssertEqual(row.measurementCount, 1, "row \(row.itemID) was measured \(row.measurementCount) times to open the chat") }
        assertStacked(stage, "the opened chat")
    }

    @MainActor func testSwitchingBetweenTwoLongChatsKeepsEachOnesGeometry() async throws {
        let cache = TranscriptGeometryCache()
        let first = SessionDisplay(id: "chat-one")
        first.messages = Self.history(turns: 40)
        let second = SessionDisplay(id: "chat-two")
        second.messages = Self.history(turns: 40).map { message in
            var copy = message
            // The same row ids in both chats: a cache that ignored the session
            // would hand one chat the other's height.
            copy.text = message.role == "assistant" ? String(repeating: "The other chat answers at much greater length, over several lines of prose. ", count: 10) : message.text
            return copy
        }
        let stage = Stage(first, cache: cache); defer { stage.close() }
        // Both chats are longer than the page measures in one pass, so each
        // comparison waits for the last slice: the question here is whose
        // heights the rows end up with, not when they get them.
        await stage.settleUntilExact()
        let firstHeights = stage.rows.map(\.frame.height)
        stage.show(second)
        await stage.settleUntilExact()
        let secondHeights = stage.rows.map(\.frame.height)
        XCTAssertNotEqual(firstHeights, secondHeights, "the two chats must not measure the same")
        assertStacked(stage, "the second chat")

        for round in 1...4 {
            stage.show(first)
            await stage.settleUntilExact()
            XCTAssertEqual(stage.rows.map(\.frame.height), firstHeights, "round \(round): the first chat took another chat's heights")
            assertStacked(stage, "first chat, round \(round)")
            stage.show(second)
            await stage.settleUntilExact()
            XCTAssertEqual(stage.rows.map(\.frame.height), secondHeights, "round \(round): the second chat took another chat's heights")
            assertStacked(stage, "second chat, round \(round)")
        }
    }

    @MainActor func testEarlierPagesPrependWithoutMovingTheReadersRow() async throws {
        let session = SessionDisplay(id: "earlier")
        session.messages = Self.history(turns: 12)
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        stage.readerScroll(to: 40)
        await stage.settle()
        let anchor = try XCTUnwrap(stage.row("hu1"))
        let screenY = anchor.frame.minY - stage.scrollY

        // An earlier page arrives in front of what is shown.
        var earlier: [TranscriptMessage] = []
        for index in 0..<10 {
            earlier.append(TranscriptMessage(id: "eu\(index)", role: "user", text: "Earlier question \(index).", at: Double(index * 2), turn: "eu\(index)"))
            earlier.append(TranscriptMessage(id: "ea\(index)", role: "assistant",
                                             text: String(repeating: "An earlier answer that takes several lines of the pane. ", count: 6),
                                             at: Double(index * 2 + 1), turn: "eu\(index)"))
        }
        session.messages = TranscriptPaging.prefix(earlier: earlier, shown: session.messages) + session.messages
        stage.refresh()
        await stage.settle()
        assertStacked(stage, "after the earlier page")
        let moved = try XCTUnwrap(stage.row("hu1"))
        XCTAssertEqual(moved.frame.minY - stage.scrollY, screenY, accuracy: 3,
                       "the earlier page moved the row the reader was reading")
    }

    @MainActor func testTheRowCapDropsOldestRowsAndTheirDisclosure() async throws {
        let session = SessionDisplay(id: "cap")
        var messages: [TranscriptMessage] = []
        var reply = TranscriptMessage(id: "a0", role: "assistant", text: "First answer.", at: 2, turn: "u0")
        reply.tools = [Self.toolCall(0)]
        messages.append(TranscriptMessage(id: "u0", role: "user", text: "First question.", at: 1, turn: "u0"))
        messages.append(reply)
        for index in 1..<80 {
            messages.append(TranscriptMessage(id: "u\(index)", role: "user", text: "Question \(index).", at: Double(index * 10), turn: "u\(index)"))
            messages.append(TranscriptMessage(id: "a\(index)", role: "assistant", text: "Answer \(index).", at: Double(index * 10 + 1), turn: "u\(index)"))
        }
        session.messages = messages
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let work = try XCTUnwrap(stage.workRow)
        work.toggleDisclosure(.tool("t0"))
        stage.draw()
        XCTAssertTrue(session.disclosure.isOpen(.tool("t0")))
        XCTAssertEqual(session.disclosure.changedCount, 1)

        // Enough new rows to push the first turn past the cap.
        var grown = messages
        for index in 80..<(80 + TranscriptPage.rowLimit) {
            grown.append(TranscriptMessage(id: "u\(index)", role: "user", text: "Question \(index).", at: Double(index * 10), turn: "u\(index)"))
            grown.append(TranscriptMessage(id: "a\(index)", role: "assistant", text: "Answer \(index).", at: Double(index * 10 + 1), turn: "u\(index)"))
        }
        session.messages = grown
        stage.refresh()
        await stage.settle()
        XCTAssertLessThanOrEqual(stage.rows.count, TranscriptPage.rowLimit, "the page keeps at most its row limit")
        XCTAssertNil(stage.row("block:a0"), "the oldest turn left the page")
        XCTAssertEqual(session.disclosure.changedCount, 0, "a row that left the page must take its disclosure with it")
        assertStacked(stage, "after the cap dropped the oldest rows")
    }

    /// The same streaming, but into a page that already holds a long history:
    /// this is where work proportional to the whole page shows up.
    @MainActor func testStreamingIntoALongPageStaysWithinAFrame() async throws {
        let turns = ProcessInfo.processInfo.environment["PI_PERF_TURNS"].flatMap(Int.init) ?? 150
        let session = SessionDisplay(id: "stream-long")
        session.messages = Self.history(turns: turns)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settleUntilExact()

        // The reader has opened a few things, so the disclosure store is not empty.
        if let work = stage.rows.first(where: { if case .block = $0.item { return true }; return false }) {
            work.toggleDisclosure(.reasoning("ha0"))
        }
        var live = TranscriptMessage(id: "stream:long", role: "assistant", text: "", at: 90_000, turn: "u-long")
        live.state = "streaming"
        session.messages.append(TranscriptMessage(id: "u-long", role: "user", text: "One more, please.", at: 89_900, turn: "u-long"))
        session.messages.append(live)
        stage.refresh()

        var total = 0.0, worst = 0.0
        let rounds = 40
        for index in 0..<rounds {
            live.text += "Sentence \(index) of a reply arriving into a long page. "
            session.messages[session.messages.count - 1] = live
            let started = ProcessInfo.processInfo.systemUptime
            stage.refresh()
            let cost = ProcessInfo.processInfo.systemUptime - started
            total += cost; worst = max(worst, cost)
        }
        print(String(format: "PERF streaming delta into %d rows: %.1f ms mean, %.1f ms worst", stage.rows.count, total * 1000 / Double(rounds), worst * 1000))
        assertStacked(stage, "after streaming into a long page")
        XCTAssertLessThan(total / Double(rounds), releaseBudget(0.016), "a delta into a long page must still cost less than one frame")
    }

    /// A turn folded while it is still running must still be folded once it
    /// settles, even though the settled reply carries a different row id.
    @MainActor func testATurnFoldedWhileItRunsIsStillFoldedWhenItSettles() async throws {
        let session = SessionDisplay(id: "settle-fold")
        session.messages = Self.history(turns: 3)
        session.messages.append(TranscriptMessage(id: "u9", role: "user", text: "Run the whole thing.", at: 8_000, turn: "u9"))
        // Match the helper: provisional and durable rows have one opaque id.
        var live = TranscriptMessage(id: "a9", role: "assistant", text: "Part of the answer so far. ", at: 8_100, turn: "u9")
        live.state = "streaming"
        live.thinking = "Working out the order. "
        live.tools = (0..<10).map { Self.toolCall($0) }
        session.messages.append(live)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settle()

        let row = try XCTUnwrap(stage.workRow)
        let open = row.frame.height
        row.toggleDisclosure(try XCTUnwrap(stage.workPart(row)))
        stage.draw()
        let folded = row.frame.height
        XCTAssertLessThan(folded, open / 2, "the live turn folds")

        // The reply settles: the same content under the persisted row id.
        var settled = live
        settled.id = "a9"
        settled.state = nil
        settled.text += "And the rest of it."
        session.messages[session.messages.count - 1] = settled
        stage.page.state = "idle"
        stage.refresh()
        await stage.settle()

        let after = try XCTUnwrap(stage.workRow)
        XCTAssertLessThan(after.frame.height, open, "the turn reopened its work when the reply settled")
        assertStacked(stage, "after the reply settled")
    }

    /// The compaction marker's summary: a stock disclosure inside a row whose
    /// height AppKit owns. It must resize in the same pass as the click.
    @MainActor func testOpeningACompactionSummaryResizesItsRowInTheSamePass() async throws {
        let session = SessionDisplay(id: "compaction")
        var messages = Self.history(turns: 4)
        var note = TranscriptMessage(id: "c1", role: "system",
                                     text: String(repeating: "The conversation so far, summarised for the next request. ", count: 30),
                                     at: 4_500)
        note.kind = "compaction"
        note.detail = "128k → 18k tokens"
        messages.insert(note, at: 4)
        session.messages = messages
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        assertStacked(stage, "with the compaction marker")
        let row = try XCTUnwrap(stage.row("c1"))
        let others = stage.rows.filter { $0 !== row }.map(\.frame.height)
        let closed = row.frame.height

        row.toggleDisclosure(.compaction("c1"))
        stage.draw()
        XCTAssertGreaterThan(row.frame.height, closed, "the summary opens in the same pass as the click")
        assertStacked(stage, "with the summary open")
        XCTAssertEqual(stage.rows.filter { $0 !== row }.map(\.frame.height), others, "no other row changed height")
        await stage.settle()
        assertStacked(stage, "with the summary open, settled")
        XCTAssertGreaterThan(try XCTUnwrap(stage.row("c1")).frame.height, closed, "the summary stayed open")

        row.toggleDisclosure(.compaction("c1"))
        stage.draw()
        XCTAssertEqual(row.frame.height, closed, accuracy: 1, "closing returns the row to its original height at once")
        assertStacked(stage, "with the summary closed again")
    }

    /// The narrowest the window goes. Every row must still stack and hold its
    /// own content, including a table and a long unbroken token.
    @MainActor func testTheNarrowestPaneStillStacksEveryRow() async throws {
        let session = SessionDisplay(id: "narrow")
        var messages = Self.history(turns: 6)
        var reply = TranscriptMessage(id: "rich", role: "assistant", text: "", at: 7_000, turn: "hu6")
        reply.text = """
        A token that cannot break: \(String(repeating: "z", count: 160))

        | One | Two | Three |
        | --- | --- | --- |
        | \(String(repeating: "cell ", count: 8)) | b | c |

        ```bash
        swift build --package-path packages/swift-host --configuration release
        ```
        """
        reply.thinking = String(repeating: "Considering the narrow case. ", count: 6)
        reply.tools = (0..<6).map { Self.toolCall($0) }
        messages.append(TranscriptMessage(id: "hu6", role: "user", text: "And in a narrow pane?", at: 6_900, turn: "hu6"))
        messages.append(reply)
        session.messages = messages
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        row.toggleDisclosure(.tool("t2"))
        row.toggleDisclosure(.reasoning("rich"))
        stage.draw()

        for width in [420.0, 340.0, 280.0, 820.0] as [CGFloat] {
            stage.resize(width: width)
            await stage.settle()
            assertStacked(stage, "at \(width) points wide")
            assertMeasuredAtDrawnWidth(stage, "at \(width) points wide")
            XCTAssertTrue(session.disclosure.isOpen(.tool("t2")), "the open card closed itself at \(width) points")
            XCTAssertTrue(session.disclosure.isOpen(.reasoning("rich")), "the reasoning closed itself at \(width) points")
            await assertFitsWhileScrollingThrough(stage, "reading the chat at \(width) points wide")
        }
    }

    /// The accent a turn wears for a moment when it settles must not still be
    /// there long after the conversation went quiet.
    @MainActor func testASettledTurnStopsGlowing() async throws {
        let session = SessionDisplay(id: "glow")
        session.messages = Self.history(turns: 3)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settle()
        XCTAssertTrue(stage.page.snapshot?.fresh.isEmpty == true, "a restored page arrives settled")

        session.messages += [TranscriptMessage(id: "u9", role: "user", text: "One more.", at: 8_000, turn: "u9"),
                             TranscriptMessage(id: "a9", role: "assistant", text: "Here it is.", at: 8_100, turn: "u9")]
        stage.page.state = "idle"
        stage.refresh()
        XCTAssertEqual(stage.page.snapshot?.fresh, ["u9", "a9"], "the rows that just arrived carry the settling accent")

        // Nothing else happens: no further message, no state change.
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            stage.draw()
            if stage.page.snapshot?.fresh.isEmpty == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(stage.page.snapshot?.fresh.isEmpty == true,
                      "a turn that settled keeps its accent for good when the conversation goes quiet")
        assertStacked(stage, "after the accent faded")
    }

    // MARK: 5 — Markdown and code

    @MainActor func testMarkdownRendersEverySourceBlockAndAStreamingFenceStaysCode() async throws {
        let source = """
        # A heading

        A paragraph with **bold**, *italic*, `inline code`, a [link](https://example.com), and
        a very long unbroken token \(String(repeating: "x", count: 200)) after it.

        ## Second heading

        | Left | Right | Middle |
        | :--- | ----: | :----: |
        | one | 2 | three |
        | \(String(repeating: "wide cell ", count: 10)) | 4 | five |

        - First bullet
          - Nested bullet with more words than fit on one line in a narrow pane
            - Third level
        1. Numbered one
        2. Numbered two

        > A quote with `code` inside it.

        ```swift
        func greet(_ name: String) -> String {
            return "Hello, \\(name)"   // a comment
        }
        ```
        """
        let blocks = TranscriptMarkdown.blocks(source)
        func count(_ test: (MarkdownBlock) -> Bool) -> Int { blocks.filter(test).count }
        XCTAssertEqual(count { if case .heading = $0 { return true }; return false }, 2, "both headings render")
        XCTAssertEqual(count { if case .table = $0 { return true }; return false }, 1, "the table renders as a table")
        XCTAssertEqual(count { if case .code = $0 { return true }; return false }, 1, "the fence renders as code")
        XCTAssertEqual(count { if case .quote = $0 { return true }; return false }, 1, "the quote renders as a quote")
        XCTAssertEqual(count { if case .list = $0 { return true }; return false }, 2, "both lists render")
        if case .table(let alignments, let header, let rows)? = blocks.first(where: { if case .table = $0 { return true }; return false }) {
            XCTAssertEqual(alignments, [.left, .right, .center], "the table keeps its column alignments")
            XCTAssertEqual(header.count, 3); XCTAssertEqual(rows.count, 2)
        } else { XCTFail("no table") }
        if case .code(let language, let code)? = blocks.first(where: { if case .code = $0 { return true }; return false }) {
            XCTAssertEqual(language, "swift")
            XCTAssertTrue(code.contains("func greet"), "the fence keeps the author's source")
            XCTAssertFalse(code.contains("```"), "the fence markers never reach the code")
        } else { XCTFail("no code block") }

        // A fence that has opened but not closed still reads as code while it streams.
        let partial = "Here is the patch:\n\n```swift\nfunc run() {\n    print(\"one\")\n"
        let streaming = TranscriptMarkdown.streamingBlocks(partial)
        XCTAssertTrue(streaming.contains { if case .code = $0 { return true }; return false },
                      "an unterminated fence renders as code, not as prose")

        // The copy targets follow the source bytes.
        let targets = TranscriptCopy.targets(in: source)
        XCTAssertEqual(targets.filter { if case .section = $0.kind { return true }; return false }.count, 2, "one copy target per heading section")
        let code = try XCTUnwrap(targets.first { $0.kind == .code })
        XCTAssertTrue(code.text.hasPrefix("func greet"), "copying code copies the source, not the rendering")
        XCTAssertFalse(code.text.contains("```"))

        // And the whole thing draws as one row that holds its own content.
        let session = SessionDisplay(id: "markdown")
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Show me.", at: 1, turn: "u1"),
                            TranscriptMessage(id: "a1", role: "assistant", text: source, at: 2, turn: "u1")]
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        assertStacked(stage, "the markdown row")
        for width in [560.0, 420.0, 900.0] as [CGFloat] {
            stage.resize(width: width)
            await stage.settle()
            assertStacked(stage, "the markdown row at \(width)")
            assertMeasuredAtDrawnWidth(stage, "the markdown row at \(width)")
        }
    }

    /// Nothing in the source may be dropped on the way to the screen, however
    /// deeply it is nested.
    @MainActor func testEverythingInTheSourceReachesTheRenderedBlocks() throws {
        let source = """
        Intro paragraph.

        - Outer item
          - Inner item with `code`
            - Deepest item
              ```json
              {"kept": true}
              ```
        - Second outer item

        > Quoted line one
        > - a bullet inside the quote

        | A | B |
        | - | - |
        | cell one | cell two |
        | only one cell |

        1) Parenthesised one
        2) Parenthesised two

        Trailing paragraph with an ![image](https://example.com/i.png) and a <script>alert(1)</script> tag.
        """
        let blocks = TranscriptMarkdown.blocks(source)
        func flatten(_ blocks: [MarkdownBlock]) -> String {
            blocks.map { block -> String in
                switch block {
                case .paragraph(let text): return String(text.characters)
                case .heading(_, let text, _): return String(text.characters)
                case .code(_, let code): return code
                case .list(_, _, let items): return items.map { flatten($0) }.joined(separator: "\n")
                case .quote(let inner): return flatten(inner)
                case .table(_, let header, let rows):
                    return (header + rows.flatMap { $0 }).map { String($0.characters) }.joined(separator: " ")
                }
            }.joined(separator: "\n")
        }
        let rendered = flatten(blocks)
        for expected in ["Intro paragraph.", "Outer item", "Inner item with code", "Deepest item",
                         "{\"kept\": true}", "Second outer item", "Quoted line one", "a bullet inside the quote",
                         "cell one", "cell two", "only one cell", "Parenthesised one", "Parenthesised two",
                         "Trailing paragraph"] {
            XCTAssertTrue(rendered.contains(expected), "the rendering dropped \(expected)")
        }
        XCTAssertTrue(rendered.contains("[Image not loaded"), "an image becomes a note rather than a load")
        // HTML is never interpreted: the tag reaches the reader as the author's
        // own characters, in a paragraph, and nothing in it becomes a link.
        XCTAssertTrue(rendered.contains("<script>alert(1)</script>"), "the source's own characters reach the reader")
        for block in blocks {
            if case .paragraph(let text) = block {
                for run in text.runs { XCTAssertNil(run.link, "no part of a plain paragraph becomes a link") }
            }
        }
        // The ordered list keeps the author's numbering style.
        let ordered = blocks.compactMap { block -> (Bool, Int)? in
            if case .list(let isOrdered, let start, _) = block, isOrdered { return (isOrdered, start) }
            return nil
        }
        XCTAssertEqual(ordered.first?.1, 1, "the ordered list starts where the source starts it")
    }

    @MainActor func testACodeBlockThatIsStillArrivingDoesNotReflowWhatIsAlreadyOnScreen() async throws {
        let session = SessionDisplay(id: "fence")
        session.messages = Self.history(turns: 6)
        var live = TranscriptMessage(id: "stream:code", role: "assistant", text: "Here is the patch:\n\n", at: 9_000, turn: "u-code")
        live.state = "streaming"
        session.messages.append(TranscriptMessage(id: "u-code", role: "user", text: "Write the patch.", at: 8_900, turn: "u-code"))
        session.messages.append(live)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settle()
        stage.readerScroll(to: 80)
        await stage.settle()
        let parked = stage.scrollY
        let anchor = try XCTUnwrap(stage.row("hu1"))
        let screenY = anchor.frame.minY - stage.scrollY

        let lines = ["```swift"] + (0..<40).map { "    let value\($0) = compute(\($0))" } + ["```", "", "That is the whole patch."]
        for line in lines {
            live.text += line + "\n"
            session.messages = session.messages.map { $0.id == live.id ? live : $0 }
            stage.refresh()
            assertStacked(stage, "while the fence streams")
            XCTAssertEqual(stage.scrollY, parked, accuracy: 1.5, "a streaming fence moved the reader")
            XCTAssertEqual(try XCTUnwrap(stage.row("hu1")).frame.minY - stage.scrollY, screenY, accuracy: 1.5,
                           "a streaming fence moved the row the reader was reading")
        }
        live.state = nil
        session.messages = session.messages.map { $0.id == live.id ? live : $0 }
        stage.refresh()
        await stage.settle()
        assertStacked(stage, "after the fence closed")
    }

    /// A long reply crosses from the plain stack into the native markdown
    /// surface while it is still arriving. Nothing may jump at the crossing.
    @MainActor func testAReplyCrossingIntoTheNativeMarkdownSurfaceDoesNotJump() async throws {
        let session = SessionDisplay(id: "surface")
        session.messages = Self.history(turns: 8)
        var live = TranscriptMessage(id: "stream:surface", role: "assistant", text: "", at: 9_000, turn: "u-surface")
        live.state = "streaming"
        session.messages.append(TranscriptMessage(id: "u-surface", role: "user", text: "A long report, please.", at: 8_900, turn: "u-surface"))
        session.messages.append(live)
        let stage = Stage(session); defer { stage.close() }
        stage.page.state = "running"
        await stage.settle()
        stage.readerScroll(to: 60)
        await stage.settle()
        let parked = stage.scrollY
        let screenY = try XCTUnwrap(stage.row("hu1")).frame.minY - stage.scrollY

        var crossed = false
        for index in 0..<(NativeMarkdownSurface.minimumBlockCount + 8) {
            live.text += "Paragraph \(index) of the report, long enough to wrap in this pane.\n\n"
            session.messages[session.messages.count - 1] = live
            stage.refresh()
            let blocks = TranscriptMarkdown.streamingBlocks(live.text).count
            if blocks >= NativeMarkdownSurface.minimumBlockCount { crossed = true }
            assertStacked(stage, "at \(blocks) blocks")
            XCTAssertEqual(stage.scrollY, parked, accuracy: 1.5, "the reply moved the reader at \(blocks) blocks")
            XCTAssertEqual(try XCTUnwrap(stage.row("hu1")).frame.minY - stage.scrollY, screenY, accuracy: 1.5,
                           "the reply moved the row the reader was reading at \(blocks) blocks")
        }
        XCTAssertTrue(crossed, "the fixture must cross the native surface's block threshold")
        live.state = nil
        session.messages[session.messages.count - 1] = live
        stage.refresh()
        await stage.settle()
        assertStacked(stage, "after the long reply settled")
        await assertFitsWhileScrollingThrough(stage, "reading the settled long reply")
    }

    /// Where the cost of folding a long turn actually goes, and how it grows
    /// with the turn: rebuilding the row's content, the one native layout pass
    /// over its hosting view, and the document laying the rest of the page out.
    @MainActor func testWhereFoldingALongTurnSpendsItsTime() async throws {
        func timed(_ work: () -> Void) -> Double {
            let started = ProcessInfo.processInfo.systemUptime; work(); return ProcessInfo.processInfo.systemUptime - started
        }
        var byToolCount: [Int: Double] = [:]
        for tools in [0, 20, 60] {
            let session = SessionDisplay(id: "fold-cost-\(tools)")
            var reply = TranscriptMessage(id: "a1", role: "assistant",
                                          text: String(repeating: "Here is what changed and why it matters for the next step. ", count: 12),
                                          at: 2_000, turn: "u1")
            reply.thinking = String(repeating: "Considering the order of the edits. ", count: 6)
            reply.tools = (0..<tools).map { Self.toolCall($0) }
            session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Work through the whole change.", at: 1_000, turn: "u1"), reply]
            session.messages += (0..<20).map { index in
                TranscriptMessage(id: "tail\(index)", role: index % 2 == 0 ? "user" : "assistant",
                                  text: String(repeating: "Tail row \(index) with enough text to wrap. ", count: 6),
                                  at: 3_000 + Double(index), turn: "tail\(index - index % 2)")
            }
            let stage = Stage(session); defer { stage.close() }
            await stage.settle()
            let row = try XCTUnwrap(stage.blockRow)
            let part = try XCTUnwrap(stage.workPart(row))
            let width = max(1, min(TranscriptMetrics.pageWidth, stage.scroll.contentSize.width - 48))
            var rebuild = 0.0, layout = 0.0, document = 0.0
            let rounds = 6
            for _ in 0..<(rounds * 2) {
                session.disclosure.toggle(part)
                rebuild += timed { row.update(item: row.item, fresh: false, actions: stage.actions, environment: stage.environment) }
                layout += timed { _ = row.measure(width: width) }
                document += timed { stage.document.layoutNow() }
                stage.draw()
            }
            let count = Double(rounds * 2)
            byToolCount[tools] = layout * 1000 / count
            print(String(format: "PERF folding a turn of %3d tool calls: rebuild %.1f ms, one native layout of the row %.1f ms, relaying out the other %d rows %.1f ms",
                         tools, rebuild * 1000 / count, layout * 1000 / count, stage.rows.count - 1, document * 1000 / count))
            assertStacked(stage, "after the fold measurements with \(tools) tool calls")
        }
        // The printed split is the record; this is the ceiling that catches a
        // return to tearing the work list down and rebuilding it, and it is
        // loose enough to survive a machine running five of these at once.
        let small = try XCTUnwrap(byToolCount[0]), large = try XCTUnwrap(byToolCount[60])
        XCTAssertLessThan(large, releaseBudget(0.060) * 1_000, "folding a 60-tool turn took \(large) ms")
        XCTAssertLessThan((large - small) / 60, 1, "folding cost \((large - small) / 60) ms per tool call in the turn")
    }

    // MARK: The live bar when a run starts as the pane opens

    /// A view that hands the transcript whatever the session's run state is at
    /// the moment its body runs, exactly as the pane does.
    private struct PaneUnderTest: View {
        @ObservedObject var session: SessionDisplay
        var body: some View {
            NativeTranscriptView(session: session, state: session.state, actions: TranscriptActions())
        }
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// The run starts in the gap between the pane's body running and its task
    /// running. The page must report the run, not the state the body was built
    /// with: otherwise the bar never appears for the whole turn.
    @MainActor func testARunThatStartsAsThePaneOpensStillReachesTheLiveBar() async throws {
        let session = SessionDisplay(id: "opening-run")
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Start the work.", at: 1_000, turn: "u1")]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: PaneUnderTest(session: session))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        // The first body has run with the chat idle; the run begins before the
        // task that binds the page has had its turn.
        hosted.layoutSubtreeIfNeeded()
        session.state = "running"

        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var page: TranscriptPage?
        while ProcessInfo.processInfo.systemUptime < deadline {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            page = descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page
            if page?.state == "running", page?.liveTurn != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let settled = try XCTUnwrap(page, "the transcript never attached")
        XCTAssertEqual(settled.state, "running", "the page kept the state its body was built with")
        XCTAssertTrue(settled.busy)
        XCTAssertNotNil(settled.liveTurn, "a run that starts as the pane opens must still dock the live bar")

        // And it comes back down when the run ends.
        session.state = "idle"
        let idleBy = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < idleBy {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if settled.liveTurn == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(settled.liveTurn, "the bar leaves with the run")
    }

    /// The reasoning and the compaction summary are the transcript's own
    /// disclosure, not a stock one: they resize their row in the same pass as
    /// the click, in both appearances, and the reader's choice survives.
    @MainActor func testTheReasoningAndSummaryDisclosuresResizeInTheSamePass() async throws {
        let session = SessionDisplay(id: "folds")
        var note = TranscriptMessage(id: "c1", role: "system",
                                     text: String(repeating: "The conversation so far, summarised for the next request. ", count: 20), at: 1_500)
        note.kind = "compaction"; note.detail = "128k → 18k tokens"
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Here is the answer.", at: 2_000, turn: "u1")
        reply.thinking = String(repeating: "Weighing the two approaches before answering. ", count: 12)
        reply.tools = [Self.toolCall(0)]
        session.messages = [TranscriptMessage(id: "u0", role: "user", text: "Start.", at: 900, turn: "u0"), note,
                            TranscriptMessage(id: "u1", role: "user", text: "Now answer.", at: 1_000, turn: "u1"), reply]
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()

        for scheme in [ColorScheme.light, .dark, .light] {
            stage.environment.colorScheme = scheme
            stage.refresh()
            await stage.settle()
            let block = try XCTUnwrap(stage.workRow)
            let compaction = try XCTUnwrap(stage.row("c1"))
            let blockClosed = block.frame.height, compactionClosed = compaction.frame.height

            block.toggleDisclosure(.reasoning("a1"))
            stage.draw()
            XCTAssertGreaterThan(block.frame.height, blockClosed + 20, "\(scheme): reasoning opened in the same pass as the click")
            assertStacked(stage, "\(scheme): reasoning open")

            compaction.toggleDisclosure(.compaction("c1"))
            stage.draw()
            XCTAssertGreaterThan(compaction.frame.height, compactionClosed + 20, "\(scheme): the summary opened in the same pass as the click")
            assertStacked(stage, "\(scheme): summary open")

            // Nothing settles them into a different height a run loop later.
            await stage.settle()
            assertStacked(stage, "\(scheme): both open, settled")
            XCTAssertGreaterThan(try XCTUnwrap(stage.workRow).frame.height, blockClosed + 20)
            XCTAssertGreaterThan(try XCTUnwrap(stage.row("c1")).frame.height, compactionClosed + 20)

            block.toggleDisclosure(.reasoning("a1"))
            compaction.toggleDisclosure(.compaction("c1"))
            stage.draw()
            XCTAssertEqual(block.frame.height, blockClosed, accuracy: 1, "\(scheme): closing returns the row at once")
            XCTAssertEqual(compaction.frame.height, compactionClosed, accuracy: 1, "\(scheme): closing returns the marker at once")
            assertStacked(stage, "\(scheme): both closed again")
        }
    }

    // MARK: Edit cards

    private static func editTool(_ id: String, path: String, before: String, after: String,
                                 state: String = "completed", cutBy: Int = 0) -> ToolView {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        var input = "{\"path\":\"\(escaped(path))\",\"oldText\":\"\(escaped(before))\",\"newText\":\"\(escaped(after))\"}"
        if cutBy > 0 { input = String(input.dropLast(cutBy)) }
        return ToolView(id: id, name: "edit", state: state, input: input, output: "applied",
                        durationMs: 40, truncated: cutBy > 0, path: path, added: 18, removed: 18)
    }

    /// Drawing an open card again — a resize, dark mode, scrolling it away and
    /// back — must never run the line diff a second time, and no `body` may
    /// run it at all.
    @MainActor func testAnOpenEditCardRunsItsDiffOnceHoweverOftenItIsDrawn() async throws {
        let path = "apps/macos/PiApp/Transcript/Once\(UUID().uuidString).swift"
        let before = (0..<120).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let after = (0..<120).map { $0 % 7 == 0 ? "let value\($0) = compute(\($0), retry: true)" : "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let tool = Self.editTool("e1", path: path, before: before, after: after)
        let session = SessionDisplay(id: "edit-card")
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Done.", at: 2_000, turn: "u1")
        reply.tools = [tool]
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Make the edit.", at: 1_000, turn: "u1"), reply]
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()

        let beforeOpening = TranscriptActivity.editComputationCount
        let row = try XCTUnwrap(stage.workRow)
        row.toggleDisclosure(.tool("e1"))
        stage.draw()
        XCTAssertEqual(TranscriptActivity.editComputationCount, beforeOpening + 1, "opening the card works the diff out once")
        assertStacked(stage, "with the edit card open")

        let afterOpening = TranscriptActivity.editComputationCount
        for width in [640.0, 520.0, 820.0] as [CGFloat] {
            stage.resize(width: width)
            await stage.settle()
        }
        stage.environment.colorScheme = .dark
        stage.refresh(); await stage.settle()
        stage.environment.colorScheme = .light
        stage.refresh(); await stage.settle()
        stage.readerScroll(to: max(0, stage.document.frame.height - 60))
        await stage.settle()
        stage.readerScroll(to: 0)
        await stage.settle()
        for _ in 0..<10 { stage.draw() }
        XCTAssertEqual(TranscriptActivity.editComputationCount, afterOpening,
                       "drawing the open card again ran the diff \(TranscriptActivity.editComputationCount - afterOpening) more times")
        assertStacked(stage, "after redrawing the open card")
    }

    /// A call whose arguments the host cut short shows the part that arrived,
    /// and says so. It never shows the raw fragment as if it were the request.
    @MainActor func testACallWhoseArgumentsWereCutShowsWhatArrived() async throws {
        let path = "apps/macos/PiApp/Transcript/Cut.swift"
        let cutInValue = Self.editTool("cut-value", path: path, before: "alpha\nbeta",
                                       after: "alpha\ngamma delta epsilon zeta", cutBy: 14)
        let request = try XCTUnwrap(TranscriptActivity.editRequest(cutInValue), "a cut request must still read as an edit")
        XCTAssertFalse(request.complete, "the card must know the request is not all there")
        XCTAssertTrue(request.rows.contains { $0.text.contains("alpha") }, "what arrived is shown")
        XCTAssertEqual(TranscriptActivity.describe(cutInValue).path, path, "the path still reaches the row's label")
        let shown = TranscriptActivity.argumentsText(cutInValue)
        XCTAssertFalse(shown.complete)
        XCTAssertNotEqual(shown.text, cutInValue.input, "the raw fragment is never what the card shows")

        // Cut inside a key, so the last member cannot be closed at all.
        var cutInKey = cutInValue
        cutInKey = ToolView(id: "cut-key", name: "edit", state: "completed",
                            input: "{\"path\":\"\(path)\",\"oldText\":\"one\\ntwo\",\"newTe",
                            output: "", durationMs: 4, truncated: true, path: path, added: 1, removed: 1)
        let partial = try XCTUnwrap(TranscriptActivity.editRequest(cutInKey))
        XCTAssertFalse(partial.complete)
        XCTAssertTrue(partial.rows.contains { $0.text == "one" }, "the half that arrived is shown")
        XCTAssertFalse(partial.rows.contains { $0.text.contains("newTe") }, "no JSON ever leaks into the rows")

        // A command whose arguments were cut still names its command.
        let bash = ToolView(id: "cut-bash", name: "bash", state: "completed",
                            input: "{\"command\":\"swift build --package-path packages/swift-host\",\"cwd\":\"/Users/some/very/long/pa",
                            output: "", durationMs: 9, truncated: true)
        XCTAssertEqual(TranscriptActivity.describe(bash).object, "swift build --package-path packages/swift-host",
                       "a cut argument list still names the command that ran")

        // And the card draws, with the note, inside a real row.
        let session = SessionDisplay(id: "cut-card")
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Tried the edit.", at: 2_000, turn: "u1")
        reply.tools = [cutInValue, cutInKey, bash]
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Edit it.", at: 1_000, turn: "u1"), reply]
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        for id in ["cut-value", "cut-key", "cut-bash"] { row.toggleDisclosure(.tool(id)) }
        stage.draw()
        assertStacked(stage, "with three cut cards open")
        await stage.settle()
        assertStacked(stage, "with three cut cards open, settled")
    }

    /// A request past the size this preview diffs says so instead of running
    /// the algorithm over it.
    @MainActor func testARequestTooLargeToDiffSaysSoRatherThanRunningIt() async throws {
        let path = "apps/macos/PiApp/Generated/Huge\(UUID().uuidString).swift"
        let before = (0...(TranscriptActivity.diffLineLimit + 100)).map { "line \($0)" }.joined(separator: "\n")
        let after = (0...(TranscriptActivity.diffLineLimit + 100)).map { $0 % 3 == 0 ? "line \($0) changed" : "line \($0)" }.joined(separator: "\n")
        let tool = Self.editTool("huge", path: path, before: before, after: after)
        let computations = TranscriptActivity.editComputationCount
        let request = try XCTUnwrap(TranscriptActivity.editRequest(tool))
        XCTAssertTrue(request.tooLarge, "a request of \(request.lines) lines is past what this preview diffs")
        XCTAssertTrue(request.rows.isEmpty)
        XCTAssertGreaterThan(request.lines, TranscriptActivity.diffLineLimit)
        XCTAssertEqual(TranscriptActivity.editComputationCount, computations, "nothing ran the diff over it")

        let session = SessionDisplay(id: "huge-card")
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Rewrote the file.", at: 2_000, turn: "u1")
        reply.tools = [tool]
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Rewrite it.", at: 1_000, turn: "u1"), reply]
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        let closed = row.frame.height
        row.toggleDisclosure(.tool("huge"))
        stage.draw()
        XCTAssertGreaterThan(row.frame.height, closed, "the card still opens")
        XCTAssertLessThan(row.frame.height - closed, 700, "and stays a preview rather than laying out the whole file")
        assertStacked(stage, "with a too-large diff open")
    }

    /// Everything that can change the height of a turn's work list, changed
    /// while that turn is folded: content, what is open inside it, the
    /// appearance, the text size and the width. A folded list is not laid out,
    /// so each of these has to be picked up the moment it is opened again — a
    /// height kept one moment too long is text drawn over text.
    @MainActor func testTheFoldedWorkListNeverKeepsAHeightItShouldHaveDropped() async throws {
        let session = SessionDisplay(id: "stale")
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Working through it.", at: 2_000, turn: "u1")
        reply.thinking = "Considering the order of the edits."
        reply.tools = (0..<12).map { Self.toolCall($0) }
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Do the work.", at: 1_000, turn: "u1"), reply]
        session.messages.append(TranscriptMessage(id: "u2", role: "user", text: "And then this.", at: 5_000, turn: "u2"))
        session.messages.append(TranscriptMessage(id: "a2", role: "assistant", text: "Done.", at: 5_100, turn: "u2"))
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let part = try XCTUnwrap(stage.workPart(try XCTUnwrap(stage.workRow)))

        /// Folds the turn, changes something while it is folded, opens it
        /// again and checks that what is drawn fits the row it is drawn in.
        func fold(_ what: String, change: () async -> Void) async throws {
            let before = try XCTUnwrap(stage.workRow)
            before.toggleDisclosure(part)
            stage.draw()
            XCTAssertFalse(session.disclosure.isOpen(part), "\(what): the turn folded")
            await change()
            await stage.settle()
            let row = try XCTUnwrap(stage.workRow)
            row.toggleDisclosure(part)
            stage.draw()
            XCTAssertTrue(session.disclosure.isOpen(part), "\(what): the turn unfolded")
            XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                     "\(what): the unfolded turn holds \(row.hostedFittingHeight) points of work in a \(row.frame.height) point row")
            assertStacked(stage, "\(what): unfolded again")
            await stage.settle()
            assertStacked(stage, "\(what): unfolded again, settled")
        }

        // A tool's output grows while the turn is folded.
        try await fold("a tool's output changed while folded") {
            var grown = try! XCTUnwrap(session.messages.first { $0.id == "a1" })
            grown.tools?[3].output = (0..<40).map { "a much longer result, line \($0)" }.joined(separator: "\n")
            session.messages = session.messages.map { $0.id == "a1" ? grown : $0 }
        }
        // A tool's state changes while the turn is folded.
        try await fold("a tool's state changed while folded") {
            var changed = try! XCTUnwrap(session.messages.first { $0.id == "a1" })
            changed.tools?[5].state = "failed"
            session.messages = session.messages.map { $0.id == "a1" ? changed : $0 }
        }
        // More tool calls arrive while the turn is folded.
        try await fold("more tool calls arrived while folded") {
            var grown = try! XCTUnwrap(session.messages.first { $0.id == "a1" })
            grown.tools = (grown.tools ?? []) + (12..<20).map { Self.toolCall($0) }
            session.messages = session.messages.map { $0.id == "a1" ? grown : $0 }
        }
        // A card inside the folded list is opened while it is folded.
        try await fold("a card inside was opened while folded") {
            session.disclosure.toggle(.tool("t2"))
            stage.refresh()
        }
        // The reasoning inside the folded list is opened while it is folded.
        try await fold("the reasoning inside was opened while folded") {
            session.disclosure.toggle(.reasoning("a1"))
            stage.refresh()
        }
        // The appearance changes while the turn is folded.
        try await fold("dark mode while folded") {
            stage.environment.colorScheme = .dark
            stage.refresh()
        }
        // The reader's text size changes while the turn is folded.
        try await fold("a larger text size while folded") {
            stage.environment.dynamicTypeSize = .xxLarge
            stage.refresh()
        }
        // The pane is narrowed while the turn is folded.
        try await fold("a narrower pane while folded") {
            stage.resize(width: 560)
        }
        // And widened again.
        try await fold("a wider pane while folded") {
            stage.resize(width: 900)
        }
        await assertFitsWhileScrollingThrough(stage, "reading the chat after all of it")
    }

    // MARK: Arguments the host had to cut

    /// The inline document a bounded call carries, built the way the helper
    /// and the journal reader build it.
    @MainActor private static func boundedEdit(_ id: String, path: String, before: String, after: String,
                                               limit: Int = ToolInputDisplay.inlineBytes) -> ToolView {
        let arguments = WireValue.object(["path": .string(path), "oldText": .string(before), "newText": .string(after)])
        let inline = ToolInputDisplay.bounded(arguments, limit: limit)
        return ToolView(id: id, name: "edit", state: "completed", input: inline.text, output: "applied",
                        durationMs: 30, truncated: inline.truncated, path: path, added: 40, removed: 12,
                        inputTruncated: inline.truncated ? true : nil, inputBytes: inline.truncated ? inline.bytes : nil)
    }

    /// Opening a card whose arguments the host had to cut asks for the rest,
    /// once, draws what it already has meanwhile, and grows into the answer.
    @MainActor func testOpeningACutCardFetchesTheRestAndGrowsIntoIt() async throws {
        let path = "apps/macos/PiApp/Transcript/Fetched.swift"
        let before = (0..<400).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let after = (0..<400).map { $0 % 4 == 0 ? "let value\($0) = compute(\($0), retry: true)" : "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let inline = Self.boundedEdit("cut1", path: path, before: before, after: after)
        XCTAssertEqual(inline.inputTruncated, true, "the fixture must be a call the host had to cut")
        XCTAssertLessThanOrEqual(inline.input.utf8.count, ToolInputDisplay.inlineBytes)
        XCTAssertNotNil(TranscriptActivity.editRequest(inline), "the inline document parses, so a partial diff is drawable")

        let session = SessionDisplay(id: "fetch")
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Rewrote it.", at: 2_000, turn: "u1")
        reply.tools = [inline]
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Rewrite it.", at: 1_000, turn: "u1"), reply]

        // The host answers with the larger per-tool bound.
        let whole = ToolInputDisplay.bounded(WireValue.object(["path": .string(path), "oldText": .string(before), "newText": .string(after)]),
                                             limit: ToolInputDisplay.contentBytes)
        var asked: [String] = []
        session.toolInputs.load = { messageID, callID in
            asked.append("\(messageID)/\(callID)")
            return ToolInputDocument(input: whole.text, truncated: whole.truncated, bytes: whole.bytes, streaming: false)
        }

        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        row.toggleDisclosure(try XCTUnwrap(stage.workPart(row))); stage.draw()
        let closed = row.frame.height
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","cut1")))
        stage.draw()
        let partial = row.frame.height
        XCTAssertGreaterThan(partial, closed, "the card opens on what the inline document already has")
        assertStacked(stage, "with the cut card open, before the answer")
        XCTAssertEqual(session.toolInputs.requestCount, 1, "the card asks the host for the rest, once")
        let measurements = row.measurementCount
        let inlineRows = try XCTUnwrap(TranscriptActivity.editRequest(inline)).rows.count

        // The answer lands; the page republishes and the row is measured again.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            await stage.settle(turns: 2)
            if session.toolInputs.document("cut1") != nil { break }
        }
        XCTAssertNotNil(session.toolInputs.document("cut1"), "the host's answer reached the conversation")
        XCTAssertEqual(asked, ["a1/cut1"], "the fetch named the reply that made the call")
        await stage.settle()
        let filled = try XCTUnwrap(stage.workRow)
        XCTAssertGreaterThan(filled.measurementCount, measurements,
                             "the row was measured again for what the host sent, rather than keeping its old height")
        // The card's own scroll bounds its height, so what grew is what it can
        // show: the whole request rather than the slice that rode along.
        var fetchedTool = inline
        let document = try XCTUnwrap(session.toolInputs.document("cut1"))
        fetchedTool.input = document.input
        fetchedTool.inputTruncated = document.truncated ? true : nil
        let fetchedRequest = try XCTUnwrap(TranscriptActivity.editRequest(fetchedTool))
        XCTAssertGreaterThan(fetchedRequest.rows.count, inlineRows, "the card now has the whole change to show")
        XCTAssertTrue(fetchedRequest.complete, "and knows it is the whole request")
        XCTAssertTrue(fetchedRequest.rows.contains { $0.text.contains("value399") }, "including the end of it")
        assertStacked(stage, "with the cut card open, after the answer")

        // Asking again is not how it works: closing and reopening reuses it.
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","cut1")))
        stage.draw()
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","cut1")))
        stage.draw()
        await stage.settle()
        XCTAssertEqual(asked, ["a1/cut1"], "the conversation keeps the document it fetched")
        XCTAssertEqual(session.toolInputs.requestCount, 1)
        assertStacked(stage, "after closing and reopening the cut card")
    }

    /// A fetch the host cannot answer leaves the card on what it already has,
    /// and is not retried on every pass.
    @MainActor func testACardWhoseFetchFailsKeepsWhatItHasAndAsksOnce() async throws {
        let path = "apps/macos/PiApp/Transcript/Refused.swift"
        let text = (0..<400).map { "line \($0) of the requested content" }.joined(separator: "\n")
        let inline = Self.boundedEdit("refused", path: path, before: "old", after: text)
        let session = SessionDisplay(id: "refused")
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Wrote it.", at: 2_000, turn: "u1")
        reply.tools = [inline]
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Write it.", at: 1_000, turn: "u1"), reply]
        var attempts = 0
        session.toolInputs.load = { _, _ in
            attempts += 1
            throw HostError.failure("no live host")
        }
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        row.toggleDisclosure(try XCTUnwrap(stage.workPart(row))); stage.draw()
        for _ in 0..<3 {
            row.toggleDisclosure(.tool(ToolOccurrence.key("a1","refused")))
            stage.draw()
            await stage.settle()
            row.toggleDisclosure(.tool(ToolOccurrence.key("a1","refused")))
            stage.draw()
            await stage.settle()
        }
        XCTAssertEqual(attempts, 1, "a host that cannot answer is asked once, not on every open")
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","refused")))
        stage.draw()
        assertStacked(stage, "with a card whose fetch failed")
        XCTAssertNil(session.toolInputs.document("refused"))
    }

    /// A chat read from a journal shows the same card as a live one: the
    /// arguments parse, the values carry their own markers, and the card knows
    /// it is not looking at the whole request.
    @MainActor func testATwentyKilobyteEditReadFromAJournalShowsAPartialDiff() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("journal-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.jsonl")
        let path = "apps/macos/PiApp/Transcript/FromJournal.swift"
        let before = (0..<500).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let after = (0..<500).map { $0 % 5 == 0 ? "let value\($0) = compute(\($0), retry: true)" : "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        XCTAssertGreaterThan(before.utf8.count + after.utf8.count, 20_000, "the fixture must be a large edit")

        var data = Data()
        let encoder = JSONEncoder()
        func append(_ value: [String: WireValue]) throws { data.append(try encoder.encode(value)); data.append(10) }
        try append(["type": .string("session"), "version": .number(3), "id": .string("a")])
        try append(["type": .string("message"), "id": .string("u1"), "parentId": .null,
                    "message": .object(["role": .string("user"), "content": .string("Rewrite the file.")])])
        try append(["type": .string("message"), "id": .string("a1"), "parentId": .string("u1"),
                    "message": .object(["role": .string("assistant"),
                                        "content": .array([
                                            .object(["type": .string("text"), "text": .string("Rewriting it now.")]),
                                            .object(["type": .string("toolCall"), "id": .string("call-1"), "name": .string("edit"),
                                                     "arguments": .object(["path": .string(path), "oldText": .string(before), "newText": .string(after)])])
                                        ])])])
        try data.write(to: file, options: .atomic)

        let page = try await HistoryReader().read(path: file.path)
        let reply = try XCTUnwrap(page.messages.first { $0.role == "assistant" })
        let tool = try XCTUnwrap(reply.tools?.first)
        XCTAssertEqual(tool.name, "edit")
        XCTAssertEqual(tool.inputTruncated, true, "a 20 KB edit does not fit the inline bound")
        XCTAssertGreaterThan(tool.inputBytes ?? 0, 20_000, "the card knows how large the request was")
        XCTAssertLessThanOrEqual(tool.input.utf8.count, ToolInputDisplay.inlineBytes)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(tool.input.utf8)),
                        "what a journal hands a card must parse, so the card is never a fragment of JSON")

        let request = try XCTUnwrap(TranscriptActivity.editRequest(tool), "a bounded journal edit still draws as a diff")
        XCTAssertFalse(request.complete, "the card knows it is not showing the whole request")
        XCTAssertTrue(request.rows.contains { $0.text.contains("let value0 ") || $0.text.contains("let value0 =") },
                      "the content that fits is shown")
        XCTAssertTrue(request.rows.contains { $0.text.hasPrefix(ToolInputDisplay.truncationMarker) },
                      "the hunk ends with the marker that says where the content stops")
        XCTAssertFalse(request.rows.contains { $0.text.contains("\"newText\"") }, "no JSON ever leaks into the rows")

        // And it draws, in a row, with the note.
        let session = SessionDisplay(id: "journal-card")
        session.messages = page.messages
        let stage = Stage(session); defer { stage.close() }
        await stage.settle()
        let row = try XCTUnwrap(stage.workRow)
        row.toggleDisclosure(try XCTUnwrap(stage.workPart(row))); stage.draw()
        let closed = row.frame.height
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","call-1")))
        stage.draw()
        XCTAssertGreaterThan(row.frame.height, closed)
        assertStacked(stage, "with a journal edit open")
    }

    // MARK: 6 — Read receipts

    /// A reply counts as read only once its end has actually been on screen.
    /// The rule is checked against the page's own geometry, which any desktop
    /// can answer; the receipt itself only fires in a key, unoccluded window,
    /// so that half is checked when this desktop can provide one.
    @MainActor func testAReplyCountsAsReadOnlyOnceItsEndHasBeenOnScreen() async throws {
        let session = SessionDisplay(id: "receipts")
        var messages = Self.history(turns: 8)
        messages.append(TranscriptMessage(id: "ulast", role: "user", text: "One long answer, please.", at: 9_000, turn: "ulast"))
        messages.append(TranscriptMessage(id: "alast", role: "assistant",
                                          text: (0..<60).map { "Paragraph \($0) of a long final answer that runs well past the bottom of the pane." }.joined(separator: "\n\n"),
                                          at: 9_100, turn: "ulast"))
        session.messages = messages
        let stage = Stage(session); defer { stage.close() }
        var read: [String] = []
        stage.page.onReadReply = { _, id in read.append(id) }
        NSApp.activate(ignoringOtherApps: true)
        stage.window.makeKeyAndOrderFront(nil)
        await stage.settle()

        /// What the page sees of the last reply from where the reader is.
        func endIsVisible() throws -> Bool {
            let frame = try XCTUnwrap(stage.page.rowFrame(of: "block:alast"), "the last reply has no frame")
            let viewport = stage.scroll.contentView.bounds
            let top = frame.minY - stage.scrollY, bottom = frame.maxY - stage.scrollY
            return TranscriptActivity.replyEndIsVisible(top: top, bottom: bottom, height: frame.height, viewportHeight: viewport.height)
        }

        stage.readerScroll(to: 0)
        await stage.settle()
        XCTAssertFalse(try endIsVisible(), "the top of the conversation is not the end of the last reply")
        XCTAssertTrue(read.isEmpty, "seeing the top of the conversation is not reading the last reply")

        stage.readerScroll(to: max(0, stage.document.frame.height - stage.scroll.contentView.bounds.height))
        await stage.settle()
        XCTAssertTrue(try endIsVisible(), "the end of the last reply is on screen at the bottom of the page")

        guard stage.page.readingIsVisible else {
            throw XCTSkip("A receipt needs this app's own key, unoccluded window; this desktop cannot provide one.")
        }
        // The page waits for the reader to stop moving before it counts a
        // reply as read, so the receipt lands a moment after the scroll.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, read.isEmpty {
            await stage.settle(turns: 2)
        }
        XCTAssertEqual(read.last, "alast", "reaching the end of the last reply counts as reading it")
    }
}
