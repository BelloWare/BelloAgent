import XCTest
import SwiftUI
@testable import PiApp

/// A turn that ran sixty tool calls, in the real document inside a real scroll
/// view. Every card is retained and openable; only the cards near the
/// conversation's viewport are laid out, drawn or tracked. What is checked is
/// what the reader would see: which cards are on screen, that each one fits the
/// space it was given, that opening one changes only that card, and that the
/// text inside an open card can still be selected.
final class NativeWorkListViewportTests: XCTestCase {
    @MainActor private final class Fixture {
        let session: SessionDisplay
        let page: TranscriptPage
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow
        var environment = TranscriptRowEnvironment()

        init(tools: Int, width: CGFloat = 820, height: CGFloat = 560) {
            session = SessionDisplay(id: "work-list")
            var reply = TranscriptMessage(id: "a1", role: "assistant",
                                          text: String(repeating: "Here is what changed and why it matters. ", count: 8),
                                          at: 2_000, turn: "u1")
            reply.thinking = "Working out the order of the edits."
            reply.tools = (0..<tools).map { index in
                ToolView(id: "t\(index)", name: index % 3 == 0 ? "bash" : "read", state: "completed",
                         input: "{\"path\":\"apps/macos/PiApp/Sources/File\(index).swift\"}",
                         output: (0..<6).map { "line \($0) of tool \(index) output that wraps across the card." }.joined(separator: "\n"),
                         durationMs: 12 + Double(index), truncated: false,
                         path: "apps/macos/PiApp/Sources/File\(index).swift")
            }
            session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Work through the whole change.", at: 1_000, turn: "u1"), reply]
            // These viewport checks exercise explicitly expanded work.
            for item in TranscriptActivity.blocks(of: session.messages) {
                if case .block(let block) = item { session.disclosure.setOpen(true, .work(block.key)) }
            }
            page = TranscriptPage()
            page.state = "idle"
            page.bind(session)
            scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
            document = TranscriptNativeDocument(page: page, geometryCache: TranscriptGeometryCache())
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            refresh()
        }
        func refresh() {
            document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: environment,
                            disclosure: session.disclosure, toolInputs: session.toolInputs)
            document.layoutRows(width: scroll.contentSize.width)
            draw()
        }
        func draw() { document.finishDisclosureMotion(); scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(turns: Int = 8) async {
            for _ in 0..<turns {
                draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
            }
            draw()
        }
        func readerScroll(to y: CGFloat) {
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            draw()
        }
        var blockRow: TranscriptRowContainer? {
            document.retainedRows.first { if case .block(let block) = $0.item { return !block.tools.isEmpty }; return false }
        }
        var workPart: TranscriptDisclosure.Part? {
            guard case .block(let block)? = blockRow?.item else { return nil }
            return .work(block.key)
        }
        func close() { window.contentView = nil; window.close() }
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    @MainActor private func container(_ fixture: Fixture) throws -> NativeWorkListContainer {
        try XCTUnwrap(descendants(NativeWorkListContainer.self, in: fixture.document).first)
    }
    @MainActor private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
    /// Every card that is actually on screen holds no more than the space the
    /// list gave it. Overlap here is one tool call drawn over the next.
    @MainActor private func assertCardsFit(_ container: NativeWorkListContainer, _ what: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        for host in container.subviews {
            XCTAssertLessThanOrEqual(ceil(host.fittingSize.height), host.frame.height + 0.5,
                                     "\(what): a card holds \(host.fittingSize.height) points in a \(host.frame.height) point row",
                                     file: file, line: line)
        }
    }

    @MainActor func testALongTurnKeepsEveryCardAndMountsOnlyTheOnesNearTheViewport() async throws {
        let cards = 160
        let fixture = Fixture(tools: cards); defer { fixture.close() }
        await fixture.settle()
        let list = try container(fixture)
        XCTAssertEqual(list.retainedRowCount, cards, "every tool call is still there")
        XCTAssertLessThan(list.mountedRowCount, 70, "a \(cards)-call turn must not put every card in the view tree")
        XCTAssertGreaterThan(list.mountedRowCount, 0, "the cards the reader can see are on screen")
        assertCardsFit(list, "the settled turn")

        // Reading down through the turn: the cards come and go, every one of
        // them is seen, and nothing is measured again to show them.
        var seen = Set(list.mountedRowIDs())
        let step = fixture.scroll.contentView.bounds.height / 2
        var y: CGFloat = 0
        while y < fixture.document.frame.height {
            fixture.readerScroll(to: y)
            await fixture.settle(turns: 2)
            seen.formUnion(list.mountedRowIDs())
            XCTAssertLessThan(list.mountedRowCount, 70, "scrolling must keep the card hierarchy bounded")
            assertCardsFit(list, "reading the turn at \(y)")
            y += step
        }
        XCTAssertEqual(seen.count, cards, "only \(seen.count) of the \(cards) cards were ever on screen")
    }

    @MainActor func testOpeningOneCardMeasuresThatCardAndLeavesTheRestAlone() async throws {
        let fixture = Fixture(tools: 60); defer { fixture.close() }
        await fixture.settle()
        let list = try container(fixture)
        let before = list.rowMeasurementCount
        let row = try XCTUnwrap(fixture.blockRow)
        let tall = row.frame.height
        // The click path a card's header takes, not a poke at the store.
        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","t1")))
        fixture.draw()
        await fixture.settle()
        XCTAssertGreaterThan(row.frame.height, tall + 20, "the open card made the turn taller")
        // One card opened: its own measurement, and the list's layout around
        // it. Nothing like sixty.
        XCTAssertLessThan(list.rowMeasurementCount - before, 12,
                          "opening one card measured \(list.rowMeasurementCount - before) cards")
        assertCardsFit(list, "with one card open")

        // What the card shows is selectable native text, not a picture.
        let selectable = textFields(in: list).filter(\.isSelectable).map(\.stringValue)
        XCTAssertTrue(selectable.contains { $0.contains("line 0 of tool 1 output") },
                      "the open card's output must be selectable; found \(selectable.prefix(4))")

        row.toggleDisclosure(.tool(ToolOccurrence.key("a1","t1")))
        fixture.draw()
        await fixture.settle()
        XCTAssertEqual(row.frame.height, tall, accuracy: 1, "closing the card returns the turn to its height")
        assertCardsFit(list, "after the card closed again")
    }

    @MainActor func testFoldingAndUnfoldingASixtyCallTurnDoesNotMeasureEveryCard() async throws {
        let fixture = Fixture(tools: 60); defer { fixture.close() }
        await fixture.settle()
        let list = try container(fixture)
        let row = try XCTUnwrap(fixture.blockRow)
        let part = try XCTUnwrap(fixture.workPart)
        let open = row.frame.height
        let before = list.rowMeasurementCount
        for round in 1...4 {
            row.toggleDisclosure(part)
            fixture.draw()
            XCTAssertLessThan(row.frame.height, open / 2, "round \(round): the turn folds at once")
            row.toggleDisclosure(part)
            fixture.draw()
            XCTAssertEqual(row.frame.height, open, accuracy: 1, "round \(round): the turn comes back to its own height")
        }
        XCTAssertLessThan(list.rowMeasurementCount - before, 8,
                          "folding and unfolding measured \(list.rowMeasurementCount - before) cards again")
        await fixture.settle()
        assertCardsFit(list, "after folding and unfolding")
    }

    @MainActor func testTheWholeTurnIsMeasuredFromOneClosedCard() async throws {
        let fixture = Fixture(tools: 60); defer { fixture.close() }
        await fixture.settle()
        let list = try container(fixture)
        // A closed card is one line high whatever it says, so the list needs
        // one measurement for all of them plus whatever the reader opened.
        // One card measured for the shape every closed card shares, plus the
        // handful checked against it.
        XCTAssertLessThan(list.rowMeasurementCount, 12,
                          "the turn cost \(list.rowMeasurementCount) card measurements to lay out")
        assertCardsFit(list, "the turn as first laid out")
    }

    @MainActor func testANarrowerPaneRelaysTheCardsOutWithoutOverlap() async throws {
        let fixture = Fixture(tools: 60); defer { fixture.close() }
        await fixture.settle()
        let list = try container(fixture)
        for width in [700.0, 560.0, 900.0] as [CGFloat] {
            fixture.window.setContentSize(NSSize(width: width, height: fixture.scroll.frame.height))
            fixture.scroll.frame = CGRect(x: 0, y: 0, width: width, height: fixture.scroll.frame.height)
            fixture.refresh()
            await fixture.settle()
            assertCardsFit(list, "at width \(width)")
            XCTAssertEqual(list.retainedRowCount, 60, "a resize keeps every card")
        }
    }
}
