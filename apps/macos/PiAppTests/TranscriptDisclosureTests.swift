import XCTest
import SwiftUI
@testable import PiApp

/// Collapsing and expanding a turn that ran many tool calls. A click reaches the
/// row through `toggleDisclosure`, exactly as the chevron and the header tap do,
/// so these checks cover the real path: the row resizes in the same pass, rows
/// stay stacked with nothing drawn outside its own row, and what the reader
/// closed stays closed through streaming and scrolling.
final class TranscriptDisclosureTests: XCTestCase {
    @MainActor private final class Fixture {
        let session: SessionDisplay
        let page: TranscriptPage
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow

        init(messages: [TranscriptMessage], width: CGFloat = 780, height: CGFloat = 560, openWork: Bool = true) {
            session = SessionDisplay(id: "disclosure")
            session.messages = messages
            // Geometry/motion cases explicitly open the work being exercised.
            if openWork {
                for item in TranscriptActivity.blocks(of: messages) {
                    if case .block(let block) = item { session.disclosure.setOpen(true, .work(block.key)) }
                }
            }
            page = TranscriptPage()
            page.state = "idle"
            page.bind(session)
            scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
            document = TranscriptNativeDocument(page: page)
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            refresh()
        }
        var rows: [TranscriptRowContainer] { document.retainedRows }
        var blockRow: TranscriptRowContainer? {
            rows.first { if case .block(let block) = $0.item { return !block.tools.isEmpty }; return false }
        }
        /// The part a click on the work header toggles, taken from the row itself.
        var workPart: TranscriptDisclosure.Part? {
            guard case .block(let block)? = blockRow?.item else { return nil }
            return .work(block.key)
        }
        func refresh() {
            document.update(snapshot: page.snapshot, actions: TranscriptActions(),
                            environment: TranscriptRowEnvironment(), disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width)
            draw()
        }
        /// What the reader is left looking at: a disclosure's motion has
        /// landed on the geometry the click measured. The tests that watch
        /// the motion itself drive its ticks instead.
        func draw() {
            document.finishDisclosureMotion()
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func settle(turns: Int = 8) async {
            for _ in 0..<turns {
                draw()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            draw()
        }
        func close() { window.contentView = nil; window.close() }
    }

    /// A turn with a long reply and many tool calls: the shape the owner sees
    /// when one request works through a task.
    private func workingTurn(tools: Int, tail: Int = 0) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        messages.append(TranscriptMessage(id: "u1", role: "user", text: "Work through the whole change.", at: 1_000, turn: "u1"))
        var reply = TranscriptMessage(id: "a1", role: "assistant",
                                      text: String(repeating: "Here is what changed and why it matters for the next step. ", count: 12),
                                      at: 2_000, turn: "u1")
        reply.thinking = String(repeating: "Considering the order of the edits. ", count: 6)
        reply.tools = (0..<tools).map { index in
            ToolView(id: "t\(index)", name: index % 3 == 0 ? "bash" : "read", state: "completed",
                     input: "{\"path\":\"apps/macos/PiApp/Sources/File\(index).swift\"}",
                     output: String(repeating: "line \(index) of output that wraps across the row. ", count: 6),
                     durationMs: 12, truncated: false, path: "apps/macos/PiApp/Sources/File\(index).swift")
        }
        messages.append(reply)
        messages += (0..<tail).map { index in
            TranscriptMessage(id: "tail\(index)", role: index % 2 == 0 ? "user" : "assistant",
                              text: String(repeating: "Tail row \(index) with enough text to wrap. ", count: 6),
                              at: 3_000 + Double(index), turn: "tail\(index - index % 2)")
        }
        return messages
    }

    /// Rows are stacked: each starts exactly where the previous ended, and its
    /// content fits inside it. Overlap is text drawn on top of text.
    @MainActor private func assertStacked(_ fixture: Fixture, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var expected: CGFloat?
        for row in fixture.rows {
            if let expected {
                XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5,
                               "\(what): row \(row.itemID) starts at \(row.frame.minY) but the row above ends at \(expected)", file: file, line: line)
            }
            expected = row.frame.maxY
            XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                     "\(what): row \(row.itemID) holds \(row.hostedFittingHeight) points of content in a \(row.frame.height) point row",
                                     file: file, line: line)
        }
        let bottom = (fixture.rows.last?.frame.maxY ?? 0) + 13
        XCTAssertEqual(fixture.document.frame.height, bottom, accuracy: 1, "\(what): the document is not as tall as its rows", file: file, line: line)
    }

    @MainActor func testWorkStartsCollapsedAndStreamingNeverRevealsDetails() async throws {
        var messages = workingTurn(tools: 4)
        messages[1].state = "streaming"
        let fixture = Fixture(messages: messages, openWork: false); defer { fixture.close() }
        await fixture.settle()
        let row = try XCTUnwrap(fixture.blockRow), part = try XCTUnwrap(fixture.workPart)
        let initialHeight = row.frame.height
        XCTAssertFalse(fixture.session.disclosure.isOpen(part))
        messages[1].tools?.append(ToolView(id: "new-tool", name: "bash", state: "running", input: "{\"command\":\"echo secret-detail\"}", output: "", durationMs: nil, truncated: false))
        fixture.session.messages = messages; fixture.refresh(); await fixture.settle()
        XCTAssertFalse(fixture.session.disclosure.isOpen(part))
        XCTAssertEqual(row.frame.height, initialHeight, accuracy: 3, "New calls must not grow a folded work section")
        row.toggleDisclosure(part); fixture.draw()
        XCTAssertTrue(fixture.session.disclosure.isOpen(part))
        XCTAssertGreaterThan(row.frame.height, initialHeight + 40)
        XCTAssertFalse(fixture.session.disclosure.isOpen(.tool("new-tool")), "Opening work still leaves argument/result bodies folded")
        row.toggleDisclosure(part); fixture.draw()
        XCTAssertFalse(fixture.session.disclosure.isOpen(part))
    }

    // MARK: The motion a click starts

    @MainActor func testUnrelatedPublicationDoesNotFinishADisclosure() async throws {
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let fixture = Fixture(messages: workingTurn(tools: 24, tail: 8)); defer { fixture.close() }
        await fixture.settle()
        let row = try XCTUnwrap(fixture.blockRow)
        row.toggleDisclosure(try XCTUnwrap(fixture.workPart))
        fixture.document.advanceDisclosureMotion(to: 0.25)
        let shown = row.frame.height
        var messages = fixture.session.messages
        messages[messages.count - 1].text += "\nA new result in another row."
        fixture.session.messages = messages
        fixture.document.update(snapshot: fixture.page.snapshot, actions: TranscriptActions(),
                                environment: TranscriptRowEnvironment(), disclosure: fixture.session.disclosure)
        fixture.document.layoutRows(width: fixture.scroll.contentSize.width)
        XCTAssertTrue(fixture.document.isMovingDisclosure, "An unrelated publication must not finish a 220 ms fold")
        XCTAssertEqual(row.frame.height, shown, accuracy: 1, "The moving row must stay at its presented height")
        assertStackedDuringMotion(fixture, "after an unrelated delta", moving: row)
        fixture.document.advanceDisclosureMotion(to: 1)
        assertStacked(fixture, "after completion")
    }

    @MainActor func testChangedMovingRowRetargetsWithoutJumping() async throws {
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let fixture = Fixture(messages: workingTurn(tools: 24, tail: 4)); defer { fixture.close() }
        await fixture.settle()
        let row = try XCTUnwrap(fixture.blockRow)
        row.toggleDisclosure(try XCTUnwrap(fixture.workPart))
        fixture.document.advanceDisclosureMotion(to: 0.35)
        let shown = row.frame.height
        var messages = fixture.session.messages
        messages[1].text += String(repeating: "\nA newly arrived paragraph.", count: 8)
        fixture.session.messages = messages
        fixture.document.update(snapshot: fixture.page.snapshot, actions: TranscriptActions(),
                                environment: TranscriptRowEnvironment(), disclosure: fixture.session.disclosure)
        fixture.document.layoutRows(width: fixture.scroll.contentSize.width)
        XCTAssertTrue(fixture.document.isMovingDisclosure)
        XCTAssertEqual(row.frame.height, shown, accuracy: 1, "New content retargets from the displayed geometry")
        assertStackedDuringMotion(fixture, "retargeted content", moving: row)
        fixture.document.advanceDisclosureMotion(to: 1)
        assertStacked(fixture, "latest content at completion")
    }

    /// Rows are stacked at a point part way through a disclosure's motion.
    /// The row that is moving deliberately holds more than its frame — it is
    /// clipped, which is what makes the fold a reveal — so what is checked of
    /// it is that it is somewhere between the two heights the click measured.
    @MainActor private func assertStackedDuringMotion(_ fixture: Fixture, _ what: String,
                                                      moving: TranscriptRowContainer,
                                                      file: StaticString = #filePath, line: UInt = #line) {
        var expected: CGFloat?
        for row in fixture.rows {
            XCTAssertEqual(fixture.page.rowFrame(of: row.itemID), row.frame,
                           "Scroll anchors must use presented geometry during motion", file: file, line: line)
            if let expected {
                XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5,
                               "\(what): row \(row.itemID) starts at \(row.frame.minY) but the row above ends at \(expected)", file: file, line: line)
            }
            expected = row.frame.maxY
            guard row !== moving else { continue }
            XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                     "\(what): row \(row.itemID) holds \(row.hostedFittingHeight) points in a \(row.frame.height) point row",
                                     file: file, line: line)
        }
        let bottom = (fixture.rows.last?.frame.maxY ?? 0) + 13
        XCTAssertEqual(fixture.document.frame.height, bottom, accuracy: 1,
                       "\(what): the document is not as tall as its rows", file: file, line: line)
    }

    @MainActor func testFoldingMovesTheRowsAndStaysStackedAtEveryPointOfTheMotion() async throws {
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let fixture = Fixture(messages: workingTurn(tools: 40, tail: 12)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let part = try XCTUnwrap(fixture.workPart)
        let open = block.frame.height

        block.toggleDisclosure(part)
        XCTAssertTrue(fixture.document.isMovingDisclosure, "a click starts the motion rather than snapping")
        XCTAssertEqual(block.frame.height, open, accuracy: 1, "the motion starts where the page was")
        var heights: [CGFloat] = []
        for point in [0.0, 0.25, 0.5, 0.75, 1.0] {
            fixture.document.advanceDisclosureMotion(to: point)
            fixture.window.displayIfNeeded()
            heights.append(block.frame.height)
            assertStackedDuringMotion(fixture, "folding at \(point)", moving: block)
        }
        XCTAssertFalse(fixture.document.isMovingDisclosure, "the motion ends on the geometry the click measured")
        for (index, height) in heights.dropFirst().enumerated() {
            XCTAssertLessThan(height, heights[index] + 0.5, "the row must only shrink as the fold runs: \(heights)")
        }
        XCTAssertLessThan(heights.last ?? open, open / 2, "the turn ends folded")
        fixture.draw()
        assertStacked(fixture, "after the fold landed")

        // And back, on the same curve.
        let folded = block.frame.height
        block.toggleDisclosure(part)
        for point in [0.0, 0.25, 0.5, 0.75, 1.0] {
            fixture.document.advanceDisclosureMotion(to: point)
            fixture.window.displayIfNeeded()
            assertStackedDuringMotion(fixture, "unfolding at \(point)", moving: block)
        }
        XCTAssertEqual(block.frame.height, open, accuracy: 1, "the turn comes back to the height it was measured at")
        XCTAssertGreaterThan(block.frame.height, folded)
        fixture.draw()
        assertStacked(fixture, "after the unfold landed")
    }

    /// Every disclosure moves the same way: a tool card's body and a reply's
    /// exposed reasoning open and close over the same curve a turn's work
    /// does, and the page is stacked at every point of it.
    @MainActor func testACardAndReasoningMoveOnTheSameCurve() async throws {
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let fixture = Fixture(messages: workingTurn(tools: 12, tail: 6)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        for (what, part) in [("a tool card", TranscriptDisclosure.Part.tool("t3")),
                             ("exposed reasoning", TranscriptDisclosure.Part.reasoning("a1"))] {
            let closed = block.frame.height
            block.toggleDisclosure(part)
            XCTAssertTrue(fixture.document.isMovingDisclosure, "\(what) must move rather than snap")
            for point in [0.0, 0.25, 0.5, 0.75, 1.0] {
                fixture.document.advanceDisclosureMotion(to: point)
                fixture.window.displayIfNeeded()
                assertStackedDuringMotion(fixture, "opening \(what) at \(point)", moving: block)
            }
            XCTAssertGreaterThan(block.frame.height, closed + 10, "\(what) opened")
            fixture.draw()
            assertStacked(fixture, "after \(what) opened")

            block.toggleDisclosure(part)
            XCTAssertTrue(fixture.document.isMovingDisclosure, "closing \(what) must move too")
            for point in [0.0, 0.5, 1.0] {
                fixture.document.advanceDisclosureMotion(to: point)
                fixture.window.displayIfNeeded()
                assertStackedDuringMotion(fixture, "closing \(what) at \(point)", moving: block)
            }
            XCTAssertEqual(block.frame.height, closed, accuracy: 1, "\(what) closed back to the height it had")
            fixture.draw()
            assertStacked(fixture, "after \(what) closed")
        }
    }

    @MainActor func testASecondClickDuringTheMotionCarriesOnFromWhereItIs() async throws {
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let fixture = Fixture(messages: workingTurn(tools: 40, tail: 8)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let part = try XCTUnwrap(fixture.workPart)
        let open = block.frame.height
        block.toggleDisclosure(part)
        fixture.document.advanceDisclosureMotion(to: 0.4)
        let midway = block.frame.height
        XCTAssertLessThan(midway, open - 10, "the fold is under way")
        XCTAssertGreaterThan(midway, 20)

        // The reader changes their mind part way through.
        block.toggleDisclosure(part)
        XCTAssertEqual(block.frame.height, midway, accuracy: 1, "the second click must carry on from where the first had got to")
        assertStackedDuringMotion(fixture, "retargeted", moving: block)
        for point in [0.5, 1.0] {
            fixture.document.advanceDisclosureMotion(to: point)
            assertStackedDuringMotion(fixture, "returning at \(point)", moving: block)
        }
        XCTAssertEqual(block.frame.height, open, accuracy: 1, "it ends fully open again")
        fixture.draw()
        assertStacked(fixture, "after the reader changed their mind")
    }

    @MainActor func testReduceMotionSnapsTheDisclosureAsItAlwaysDid() async throws {
        TranscriptNativeDocument.reducesMotionOverride = true
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let fixture = Fixture(messages: workingTurn(tools: 40, tail: 6)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let open = block.frame.height
        block.toggleDisclosure(try XCTUnwrap(fixture.workPart))
        XCTAssertFalse(fixture.document.isMovingDisclosure, "Reduce Motion means no motion at all")
        XCTAssertLessThan(block.frame.height, open / 2, "the row is at its new height at once")
        assertStacked(fixture, "with Reduce Motion on")
    }

    @MainActor func testCollapsingATurnOfFortyToolCallsResizesItsRowInTheSamePass() async throws {
        let fixture = Fixture(messages: workingTurn(tools: 40)); defer { fixture.close() }
        await fixture.settle()
        assertStacked(fixture, "before collapsing")
        let block = try XCTUnwrap(fixture.blockRow)
        let expanded = block.frame.height
        XCTAssertGreaterThan(expanded, 400, "forty tool calls make a tall row")

        // The click itself, with no run-loop turn in between.
        block.toggleDisclosure(try XCTUnwrap(fixture.workPart))
        fixture.draw()
        XCTAssertLessThan(block.frame.height, expanded / 2, "collapsing must shorten the row at once, not a run loop later")
        assertStacked(fixture, "immediately after collapsing")

        await fixture.settle()
        assertStacked(fixture, "after collapsing settled")
        XCTAssertLessThan(block.frame.height, expanded / 2, "the row stays collapsed")

        block.toggleDisclosure(try XCTUnwrap(fixture.workPart))
        fixture.draw()
        XCTAssertEqual(block.frame.height, expanded, accuracy: 1, "expanding returns the row to its full height at once")
        assertStacked(fixture, "immediately after expanding")
        await fixture.settle()
        assertStacked(fixture, "after expanding settled")
    }

    @MainActor func testRepeatedCollapsingNeverLeavesAStaleHeight() async throws {
        let fixture = Fixture(messages: workingTurn(tools: 24, tail: 10)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let expanded = block.frame.height
        for round in 1...5 {
            block.toggleDisclosure(try XCTUnwrap(fixture.workPart))
            fixture.draw()
            XCTAssertLessThan(block.frame.height, expanded / 2, "round \(round) did not collapse")
            assertStacked(fixture, "collapsed round \(round)")
            block.toggleDisclosure(try XCTUnwrap(fixture.workPart))
            fixture.draw()
            XCTAssertEqual(block.frame.height, expanded, accuracy: 1, "round \(round) did not expand")
            assertStacked(fixture, "expanded round \(round)")
        }
        await fixture.settle()
        assertStacked(fixture, "after five rounds")
    }

    /// One tool card and the exposed reasoning open on their own, and each
    /// resizes only the row that holds it.
    @MainActor func testOpeningOneToolCardAndReasoningResizesOnlyThatRow() async throws {
        let fixture = Fixture(messages: workingTurn(tools: 8, tail: 4)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let others = fixture.rows.filter { $0 !== block }.map(\.frame.height)
        let base = block.frame.height

        block.toggleDisclosure(.tool("t3"))
        fixture.draw()
        XCTAssertGreaterThan(block.frame.height, base, "a tool card that opens makes its row taller")
        assertStacked(fixture, "after opening a tool card")
        let withTool = block.frame.height

        block.toggleDisclosure(.reasoning("a1"))
        fixture.draw()
        XCTAssertGreaterThan(block.frame.height, withTool, "exposed reasoning adds to the same row")
        assertStacked(fixture, "after opening reasoning")
        XCTAssertEqual(fixture.rows.filter { $0 !== block }.map(\.frame.height), others, "no other row changed height")

        block.toggleDisclosure(.tool("t3"))
        block.toggleDisclosure(.reasoning("a1"))
        fixture.draw()
        XCTAssertEqual(block.frame.height, base, accuracy: 1, "closing both returns the row to its original height")
        assertStacked(fixture, "after closing both")
    }

    /// A collapsed turn stays collapsed while the conversation keeps streaming
    /// and when the row is scrolled away and comes back.
    @MainActor func testACollapsedTurnStaysCollapsedThroughStreamingAndScrolling() async throws {
        let fixture = Fixture(messages: workingTurn(tools: 30, tail: 14)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let expanded = block.frame.height
        block.toggleDisclosure(try XCTUnwrap(fixture.workPart))
        fixture.draw()
        let collapsed = block.frame.height
        XCTAssertLessThan(collapsed, expanded / 2)

        // The turn keeps working: another tool result arrives in the same block.
        var reply = try XCTUnwrap(fixture.session.messages.first { $0.id == "a1" })
        reply.tools?.append(ToolView(id: "t-late", name: "read", state: "completed", input: "{}", output: "late output", durationMs: 4, truncated: false))
        fixture.session.messages = fixture.session.messages.map { $0.id == "a1" ? reply : $0 }
        fixture.refresh()
        await fixture.settle()
        let after = try XCTUnwrap(fixture.blockRow)
        XCTAssertEqual(after.frame.height, collapsed, accuracy: 24, "new tool output must not reopen a turn the reader closed")
        assertStacked(fixture, "after new tool output")

        // Scroll it out of the viewport and back.
        fixture.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: fixture.document.frame.height))
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        await fixture.settle()
        fixture.scroll.contentView.setBoundsOrigin(.zero)
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        await fixture.settle()
        let returned = try XCTUnwrap(fixture.blockRow)
        XCTAssertEqual(returned.frame.height, collapsed, accuracy: 24, "a chat keeps what the reader closed while scrolling")
        assertStacked(fixture, "after scrolling away and back")
    }

    /// Two chats keep their own disclosure, and rows that leave take their
    /// entries with them rather than growing the store forever.
    @MainActor func testDisclosureIsPerConversationAndForgetsRemovedRows() throws {
        let store = TranscriptDisclosure()
        XCTAssertFalse(store.isOpen(.work("block:a1")), "work starts collapsed")
        XCTAssertFalse(store.isOpen(.tool("t1")), "a tool card starts closed")
        store.toggle(.work("block:a1")); store.toggle(.tool("t1"))
        XCTAssertTrue(store.isOpen(.work("block:a1"))); XCTAssertTrue(store.isOpen(.tool("t1")))
        XCTAssertEqual(store.changedCount, 2)
        // Returning to the default drops the entry rather than remembering it.
        store.toggle(.work("block:a1"))
        XCTAssertEqual(store.changedCount, 1)
        store.forget(["t1"])
        XCTAssertEqual(store.changedCount, 0); XCTAssertFalse(store.isOpen(.tool("t1")))

        let first = SessionDisplay(id: "first"), second = SessionDisplay(id: "second")
        first.disclosure.toggle(.work("block:a1"))
        XCTAssertTrue(first.disclosure.isOpen(.work("block:a1")))
        XCTAssertFalse(second.disclosure.isOpen(.work("block:a1")), "another chat stays collapsed")
    }

    /// What a collapse costs, printed for the release record: the click, its
    /// re-measurement and the document's re-layout, all in one pass.
    @MainActor func testMeasureCollapsingALongTurn() async throws {
        let toolCount = testEnvironment("PI_PERF_TOOLS").flatMap(Int.init) ?? 60
        let fixture = Fixture(messages: workingTurn(tools: toolCount, tail: 20)); defer { fixture.close() }
        await fixture.settle()
        let block = try XCTUnwrap(fixture.blockRow)
        let part = try XCTUnwrap(fixture.workPart)
        var collapse = 0.0, expand = 0.0, draws = 0.0
        let rounds = testEnvironment("PI_PERF_REPEAT").flatMap(Int.init) ?? 6
        func timed(_ work: () -> Void) -> Double { let s = ProcessInfo.processInfo.systemUptime; work(); return ProcessInfo.processInfo.systemUptime - s }
        for _ in 0..<rounds {
            collapse += timed { block.toggleDisclosure(part) }
            draws += timed { fixture.draw() }
            expand += timed { block.toggleDisclosure(part) }
            draws += timed { fixture.draw() }
        }
        let count = Double(rounds)
        print(String(format: "PERF collapse a %d-tool turn among %d rows: %.1f ms (click to relaid-out rows)", toolCount, fixture.rows.count, collapse * 1000 / count))
        print(String(format: "PERF expand a %d-tool turn among %d rows: %.1f ms (click to relaid-out rows)", toolCount, fixture.rows.count, expand * 1000 / count))
        print(String(format: "PERF display pass after a click: %.1f ms", draws * 1000 / (count * 2)))
    }

    /// The shared geometry cache must never hand a row a height measured in a
    /// different disclosure state.
    @MainActor func testSharedGeometryIsNeverReusedAcrossDisclosureStates() throws {
        let cache = TranscriptGeometryCache()
        let message = TranscriptMessage(id: "m1", role: "assistant", text: "A settled reply.", at: 1, turn: "u1")
        let item = TranscriptItem.message(message)
        var open = TranscriptRowDisclosure(); open.openReasoning = ["m1"]
        cache.store(CGSize(width: 600, height: 120), sessionID: "s", item: item, fresh: false,
                    environment: TranscriptRowEnvironment(), disclosure: .default, backingScale: 2)
        XCTAssertEqual(cache.measurement(sessionID: "s", item: item, fresh: false, environment: TranscriptRowEnvironment(),
                                         disclosure: .default, width: 600, backingScale: 2)?.height, 120)
        XCTAssertNil(cache.measurement(sessionID: "s", item: item, fresh: false, environment: TranscriptRowEnvironment(),
                                       disclosure: open, width: 600, backingScale: 2),
                     "a row with its reasoning open cannot borrow the closed row's height")
    }
}
