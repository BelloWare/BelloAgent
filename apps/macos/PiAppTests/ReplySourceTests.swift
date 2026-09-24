import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// What the reader typed reads exactly as typed, and a finished reply can be
/// read as its markdown source. Each is one selectable text: nothing in it is
/// read as Markdown, its line breaks and spaces stay, and a selection can run
/// across its lines. Switching a reply re-measures it in the pass that
/// switched it, and nothing above it moves.
///
/// Copying a selection to the pasteboard is `PlainTextCopyTests`, in the
/// serial lane: every test host shares the pasteboard.
final class ReplySourceTests: XCTestCase {
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    /// Everything Markdown would read as something else, on several lines.
    static let typed = "# Not a heading\n**not bold** and `not code`\n- not a list item\n  two  spaces [not a link](https://example.com)\n\nafter a blank line"

    /// A reply long enough to be drawn by the native surface when rendered,
    /// and by the TextKit leaf as its source.
    static let longReply: String = (0..<24).map { index in
        "## Section \(index)\nSome **bold** text with `code` and a [link](https://example.com), long enough to wrap in the pane.\n\n- item one\n- item two"
    }.joined(separator: "\n\n")

    @MainActor private func stage(_ messages: [TranscriptMessage], width: CGFloat = 820, height: CGFloat = 560) async -> TranscriptStreamingStressTests.Stage {
        let session = SessionDisplay(id: "reply-source-" + UUID().uuidString)
        session.messages = messages
        let stage = TranscriptStreamingStressTests.Stage(session, width: width, height: height)
        stage.refresh(); await stage.settle()
        return stage
    }
    private static func user(_ id: String, _ text: String, at: Double = 1_000) -> TranscriptMessage {
        TranscriptMessage(id: id, role: "user", text: text, at: at, turn: id)
    }
    private static func reply(_ id: String, _ text: String, turn: String, at: Double = 2_000) -> TranscriptMessage {
        TranscriptMessage(id: id, role: "assistant", text: text, state: "complete", at: at, turn: turn)
    }
    /// A reply read in order: its words, a call, then more words.
    private static func orderedReply(_ id: String, turn: String) -> TranscriptMessage {
        var timeline = ResponseTimeline()
        func part(_ ordinal: Int, _ kind: String, _ text: String, call: String? = nil, name: String? = nil) {
            timeline.consume(ResponsePartEvent(attemptID: "attempt-" + id, ordinal: ordinal, itemID: "item-\(ordinal)", outputIndex: ordinal, partIndex: 0,
                                               kind: kind, update: "replace", text: text, callID: call, name: name))
        }
        part(0, "text", "First **part** of the answer.")
        part(1, "toolArguments", "{\"path\":\"README.md\"}", call: "c1", name: "read")
        part(2, "text", "Second part, with `code`.")
        timeline.finish("completed")
        var reply = TranscriptMessage(id: id, role: "assistant", text: "First **part** of the answer.Second part, with `code`.",
                                      tools: [ToolView(id: "c1", name: "read", state: "completed", input: "{\"path\":\"README.md\"}",
                                                       output: "Synthetic file.", durationMs: 12, truncated: false, path: "README.md")],
                                      state: "complete", at: 2_000, turn: turn)
        reply.responseTimeline = timeline
        return reply
    }
    /// The rows that draw this reply's text.
    @MainActor private func textRows(_ stage: TranscriptStreamingStressTests.Stage, of reply: String) -> [TranscriptRowContainer] {
        stage.rows.filter { ReplySource.replyID(of: $0.contentItem) == reply }
    }
    /// Waits until a rendered surface has measured every block it is going
    /// to near the viewport: it prepares a few at a time, a pass after another.
    @MainActor private func settled(_ surface: NativeMarkdownContainer, _ stage: TranscriptStreamingStressTests.Stage) async {
        var measured = -1
        for _ in 0..<40 where measured != surface.blockMeasurementCount {
            measured = surface.blockMeasurementCount
            await stage.settle(turns: 3)
        }
    }
    @MainActor private func assertStacked(_ stage: TranscriptStreamingStressTests.Stage, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var expected: CGFloat?
        for row in stage.rows {
            if let expected {
                XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5, "\(what): row \(row.itemID) starts at \(row.frame.minY), the row above ends at \(expected)", file: file, line: line)
            }
            expected = row.frame.maxY
            guard row.superview != nil else { continue }
            XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5,
                                     "\(what): row \(row.itemID) holds \(row.hostedFittingHeight) points in a \(row.frame.height) point row", file: file, line: line)
        }
    }

    // MARK: A message as it was typed

    /// A short message is one selectable SwiftUI text holding exactly the
    /// characters typed: no heading, no bold, no code, no list, no link, and
    /// every line break and double space where it was.
    @MainActor func testAUserMessageShowsExactlyWhatWasTyped() async throws {
        let stage = await stage([Self.user("u1", Self.typed), Self.reply("a1", "Answer.", turn: "u1")])
        defer { stage.close() }
        let row = try XCTUnwrap(stage.row("u1"))
        let texts = views(NSTextField.self, in: row).filter(\.isSelectable)
        XCTAssertEqual(texts.map(\.stringValue), [Self.typed], "one selectable text holds the whole message, character for character")
        XCTAssertTrue(views(NativeMarkdownContainer.self, in: row).isEmpty, "nothing in the bubble is Markdown")
        XCTAssertTrue(views(TranscriptCodeTextView.self, in: row).isEmpty, "no code block in the bubble")
        XCTAssertTrue(views(TranscriptPlainTextView.self, in: row).isEmpty, "a short message is SwiftUI's own text")
        // A selection runs across its lines: from inside the bold markers to
        // inside the link, over three line breaks, in one field.
        let field = try XCTUnwrap(texts.first)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let start = (Self.typed as NSString).range(of: "not bold").location
        let end = NSMaxRange((Self.typed as NSString).range(of: "[not a link"))
        editor.setSelectedRange(NSRange(location: start, length: end - start))
        let selected = (editor.string as NSString).substring(with: editor.selectedRange())
        XCTAssertEqual(selected, "not bold** and `not code`\n- not a list item\n  two  spaces [not a link")
        XCTAssertEqual(stage.session.messages.first?.text, Self.typed, "reading it changes nothing")
    }

    /// A paste as long as the composer takes is one TextKit text: laid out
    /// once for the width it is drawn at, its row as tall as its lines, and
    /// every line of it selectable in one range.
    @MainActor func testALongPasteIsOneTextTheRowFits() async throws {
        var text = "", index = 0
        while text.utf8.count < 262_144 - 128 {
            text += "Line \(index): **not bold** `not code` # not a heading - [not a link](https://example.com)\n"
            index += 1
        }
        let stage = await stage([Self.user("u1", text), Self.reply("a1", "Answer.", turn: "u1")], height: 700)
        defer { stage.close() }
        let row = try XCTUnwrap(stage.row("u1"))
        stage.readerScroll(to: row.frame.minY)
        await stage.settle()
        let leaves = views(TranscriptPlainTextView.self, in: row)
        XCTAssertEqual(leaves.count, 1, "one text holds the whole paste")
        let leaf = try XCTUnwrap(leaves.first)
        XCTAssertTrue(leaf.string == text, "the paste reads exactly as it was typed")
        XCTAssertTrue(views(NSTextField.self, in: row).filter { $0.isSelectable }.isEmpty, "and in no other text")
        XCTAssertLessThanOrEqual(leaf.layoutPasses, 2, "the paste is laid out once per width it was offered, not on every pass")
        let lines = CGFloat(index + 1)
        XCTAssertGreaterThanOrEqual(leaf.frame.height, lines * 17, "every line of the paste has its line box")
        XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5, "the row holds the whole paste")
        let layoutsBefore = leaf.layoutPasses
        stage.readerScroll(to: row.frame.midY)
        await stage.settle()
        XCTAssertEqual(leaf.layoutPasses, layoutsBefore, "scrolling through the paste lays nothing out again")
        // One selection across thousands of its lines.
        let range = NSRange(location: 6, length: (text as NSString).length - 40)
        leaf.setSelectedRange(range)
        XCTAssertEqual(leaf.selectedRange(), range)
        XCTAssertGreaterThan((leaf.string as NSString).substring(with: leaf.selectedRange()).filter { $0 == "\n" }.count, 2_000)
    }

    /// A row stands at an estimate until it is measured, and a message's
    /// estimate counts its lines as typed: blank lines included, no block gaps.
    @MainActor func testUserRowEstimatesStayCloseToTheirMeasuredHeights() async throws {
        let paragraph = String(repeating: "A long line that wraps several times across the bubble. ", count: 12)
        let texts = ["Short.", Self.typed, "one\ntwo\nthree\n\n\nsix", paragraph, paragraph + "\n\n" + paragraph]
        let messages = texts.enumerated().flatMap { index, text in
            [Self.user("u\(index)", text, at: Double(index) * 10), Self.reply("a\(index)", "Answer \(index).", turn: "u\(index)", at: Double(index) * 10 + 5)]
        }
        let stage = await stage(messages, height: 2_400)
        defer { stage.close() }
        for index in texts.indices {
            let row = try XCTUnwrap(stage.row("u\(index)"))
            let estimate = TranscriptRowEstimate.height(of: row.contentItem, width: row.frame.width)
            XCTAssertEqual(estimate, row.frame.height, accuracy: max(14, row.frame.height * 0.15),
                           "message \(index) stands at \(estimate) points before it is measured and measures \(row.frame.height)")
        }
    }

    // MARK: A reply's source

    /// View raw shows the reply's markdown exactly as it arrived, in one
    /// selectable monospaced text, re-measured in the same pass; the rows
    /// above keep their places and the reply keeps its top. View rendered
    /// brings the rendered reply back at the height it had.
    @MainActor func testViewRawShowsTheReplysSourceAndViewRenderedBringsItBack() async throws {
        let stage = await stage([Self.user("u0", "Earlier question."), Self.reply("a0", "Earlier answer.", turn: "u0", at: 1_500),
                                 Self.user("u1", "Write it all out.", at: 1_800), Self.reply("a1", Self.longReply, turn: "u1")], height: 700)
        defer { stage.close() }
        let row = try XCTUnwrap(textRows(stage, of: "a1").first)
        stage.readerScroll(to: max(0, row.frame.minY - 40))
        await stage.settle()
        let surface = try XCTUnwrap(views(NativeMarkdownContainer.self, in: row).first, "the reply starts rendered, by its native surface")
        await settled(surface, stage)
        let above = stage.rows.prefix { $0 !== row }.map(\.frame)
        let top = row.frame.minY - stage.scrollY, rendered = row.frame.height
        let measured = surface.blockMeasurementCount, estimated = surface.provisionalBlockCount

        row.toggleDisclosure(.source("a1"))
        stage.draw()
        XCTAssertTrue(stage.session.disclosure.isOpen(.source("a1")), "the reply's view is the conversation's, not the row's")
        let leaf = try XCTUnwrap(views(TranscriptPlainTextView.self, in: row).first, "the source is one TextKit text")
        XCTAssertEqual(views(TranscriptPlainTextView.self, in: row).count, 1)
        XCTAssertTrue(leaf.string == Self.longReply, "the source is the reply exactly as it arrived")
        XCTAssertTrue(leaf.font?.isFixedPitch == true, "in a monospaced face")
        XCTAssertTrue(surface.isParked && surface.mountedBlockCount == 0 && surface.frame.height == 0,
                      "and nothing of it is rendered: the rendered surface waits, parked, taking no room")
        XCTAssertTrue(views(NSTextField.self, in: row).filter(\.isSelectable).isEmpty, "the source is the only text")
        XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5, "the row was re-measured in the pass that switched it")
        XCTAssertNotEqual(row.frame.height, rendered, "the source is not as tall as the rendered reply")
        XCTAssertEqual(stage.rows.prefix { $0 !== row }.map(\.frame), above, "the rows above do not move")
        XCTAssertEqual(row.frame.minY - stage.scrollY, top, accuracy: 1, "the reply keeps its place on the screen")
        assertStacked(stage, "in its source")
        // Its lines are the source's lines, selectable across them.
        let heading = (Self.longReply as NSString).range(of: "## Section 3")
        leaf.setSelectedRange(NSRange(location: heading.location, length: 80))
        XCTAssertTrue((leaf.string as NSString).substring(with: leaf.selectedRange()).hasPrefix("## Section 3\nSome **bold** text"))
        // A right-click on the selection is the text's own; anywhere else it
        // is the row's, whose reply menu has View Rendered.
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: leaf.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: stage.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNotNil(leaf.menu(for: click), "the selection's own menu")
        leaf.setSelectedRange(NSRange(location: heading.location, length: 0))
        XCTAssertNil(leaf.menu(for: click), "the row's menu")

        row.toggleDisclosure(.source("a1"))
        stage.draw()
        await settled(surface, stage)
        XCTAssertFalse(stage.session.disclosure.isOpen(.source("a1")))
        XCTAssertTrue(views(TranscriptPlainTextView.self, in: row).isEmpty, "View rendered puts the rendered reply back")
        XCTAssertTrue(views(NativeMarkdownContainer.self, in: row).first === surface && !surface.isParked, "the same surface")
        XCTAssertEqual(surface.blockMeasurementCount - measured, estimated - surface.provisionalBlockCount,
                       "with every height it had measured: nothing is measured again, only blocks still at estimates are prepared")
        XCTAssertEqual(stage.rows.prefix { $0 !== row }.map(\.frame), above, "the rows above still have not moved")
        XCTAssertEqual(row.frame.minY - stage.scrollY, top, accuracy: 1, "the reply is where it was")
        assertStacked(stage, "rendered again")
    }

    /// A short reply's source is SwiftUI's own monospaced text, one field.
    @MainActor func testAShortRepliesSourceIsOneSelectableText() async throws {
        let source = "# Title\n\nSome **bold** and `code`:\n\n- one\n- two"
        let stage = await stage([Self.user("u1", "Show me."), Self.reply("a1", source, turn: "u1")])
        defer { stage.close() }
        let row = try XCTUnwrap(textRows(stage, of: "a1").first)
        row.toggleDisclosure(.source("a1"))
        stage.draw(); await stage.settle()
        let texts = views(NSTextField.self, in: row).filter(\.isSelectable)
        XCTAssertEqual(texts.map(\.stringValue), [source], "the whole source, in one text")
        XCTAssertTrue(views(TranscriptPlainTextView.self, in: row).isEmpty)
        assertStacked(stage, "a short source")
    }

    /// The view is kept per reply, in the conversation: every part of a
    /// reply's text switches together, and no other row reads it — not the
    /// reply's header line, its card, its figures, nor another message.
    @MainActor func testEveryTextPartOfAReplySwitchesTogetherAndNothingElseReadsIt() async throws {
        let stage = await stage([Self.user("u1", "Read the file, then answer."), Self.orderedReply("a1", turn: "u1"),
                                 Self.user("u2", "And again?", at: 3_000), Self.orderedReply("a2", turn: "u2")], height: 900)
        defer { stage.close() }
        let parts = textRows(stage, of: "a1")
        XCTAssertEqual(parts.count, 2, "the reply's two text parts each have a row")
        let others = stage.rows.filter { !parts.contains($0) }
        let heights = Dictionary(uniqueKeysWithValues: others.map { ($0.itemID, $0.frame.height) })
        let store = stage.session.disclosure
        try XCTUnwrap(parts.first).toggleDisclosure(.source("a1"))
        stage.draw(); await stage.settle()
        for row in stage.rows {
            let value = TranscriptRowDisclosure.of(row.contentItem, in: store)
            XCTAssertEqual(value.raw, parts.contains(row), "row \(row.itemID) reads the reply's view only if it draws the reply's text")
        }
        for part in parts {
            XCTAssertEqual(views(NSTextField.self, in: part).filter(\.isSelectable).count, 1, "part \(part.itemID) is one selectable text")
            XCTAssertTrue(views(NSTextField.self, in: part).contains { $0.stringValue.contains("**part**") || $0.stringValue.contains("`code`") },
                          "part \(part.itemID) reads as its source")
        }
        for row in others {
            XCTAssertEqual(row.frame.height, heights[row.itemID] ?? -1, accuracy: 0.5, "row \(row.itemID) is not re-measured for another row's view")
        }
        XCTAssertFalse(store.isOpen(.source("a2")), "another reply keeps its own view")
        assertStacked(stage, "a reply in its source")
        // Rows that leave the conversation take the reply's view with them.
        stage.session.messages = Array(stage.session.messages.suffix(2))
        stage.refresh(); await stage.settle()
        XCTAssertFalse(store.isOpen(.source("a1")), "the view goes with the reply's rows")
    }

    /// Offered on a reply's finished text only: never while it streams, on a
    /// message the reader sent, or on a reply that only called tools.
    func testTheSwitchIsOfferedOnFinishedRepliesOnly() {
        let finished = Self.reply("a1", "Done.", turn: "u1")
        XCTAssertTrue(ReplySource.offered(finished))
        var streaming = finished; streaming.state = "streaming"
        XCTAssertFalse(ReplySource.offered(streaming), "text still arriving is always rendered")
        XCTAssertFalse(ReplySource.shows(streaming, raw: true), "even in a reply the reader switched")
        var stopped = finished; stopped.stopReason = "interrupted"
        XCTAssertTrue(ReplySource.offered(stopped), "a stopped reply's words have arrived")
        var earlier = finished; earlier.earlierVersion = true
        XCTAssertTrue(ReplySource.offered(earlier), "an earlier version's reply reads either way too")
        XCTAssertFalse(ReplySource.offered(Self.user("u1", "**typed**")), "a message the reader sent always reads as typed")
        var toolsOnly = Self.reply("a2", "  \n", turn: "u1"); toolsOnly.tools = [ToolView(id: "t", name: "read", state: "completed", input: "{}", output: "", durationMs: 1, truncated: false)]
        XCTAssertFalse(ReplySource.offered(toolsOnly), "a reply with no words has no source to show")
        var status = finished; status.kind = "requestInfo"
        XCTAssertFalse(ReplySource.offered(status))
    }

    /// The hover pills of a finished reply: Copy, View raw, Details, and
    /// Fork from here where the chat forks; View rendered once it is raw.
    @MainActor func testThePillsOfAFinishedReplyOfferTheSwitch() {
        var actions = TranscriptActions()
        var forked: [String] = []
        actions.fork = { forked.append($0) }
        var switched = 0
        let reply = Self.reply("a1", "Done.", turn: "u1")
        let rendered = RowActionsView.pills(reply, actions: actions, forks: true, source: ReplySourceToggle(raw: false) { switched += 1 })
        XCTAssertEqual(rendered.map(\.title), ["Copy", "View raw", "Details", "Fork from here"])
        rendered.first { $0.title == "View raw" }?.perform()
        XCTAssertEqual(switched, 1)
        let raw = RowActionsView.pills(reply, actions: actions, forks: true, source: ReplySourceToggle(raw: true) { switched += 1 })
        XCTAssertEqual(raw.map(\.title), ["Copy", "View rendered", "Details", "Fork from here"])
        raw.first { $0.title == "View rendered" }?.perform()
        XCTAssertEqual(switched, 2)
        XCTAssertEqual(RowActionsView.pills(reply, actions: actions, forks: false, source: nil).map(\.title), ["Copy", "Details"],
                       "a row that offers no switch shows none")
        XCTAssertEqual(RowActionsView.pills(Self.user("u1", "Hi"), actions: actions, forks: true, source: nil).map(\.title), ["Edit", "Copy", "Details"])
        XCTAssertTrue(forked.isEmpty)
    }

    /// The reply's menu, built when it opens: View Raw after Copy Reply, and
    /// View Rendered once the reply reads as its source.
    @MainActor func testTheReplyMenuOffersTheSwitch() {
        var switched = 0
        let reply = Self.reply("a1", "Done.", turn: "u1")
        let menu = PiMenus.menu(ReplyMenu.entries(reply, actions: TranscriptActions(), forks: false, source: ReplySourceToggle(raw: false) { switched += 1 }))
        XCTAssertEqual(menu.items.compactMap { $0.identifier?.rawValue }, ["reply-copy", ReplySource.menuIdentifier, "reply-details"])
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == ReplySource.menuIdentifier }?.title, "View Raw")
        XCTAssertTrue(PiMenus.perform(ReplySource.menuIdentifier, in: menu))
        XCTAssertEqual(switched, 1)
        let raw = PiMenus.menu(ReplyMenu.entries(reply, actions: TranscriptActions(), forks: false, source: ReplySourceToggle(raw: true) { switched += 1 }))
        XCTAssertEqual(raw.items.first { $0.identifier?.rawValue == ReplySource.menuIdentifier }?.title, "View Rendered")
        XCTAssertNil(PiMenus.menu(ReplyMenu.entries(reply, actions: TranscriptActions(), forks: false)).items.first { $0.identifier?.rawValue == ReplySource.menuIdentifier },
                     "no switch, no command")
    }

    /// A reader who never hovers reaches the switch through the row itself:
    /// the row carries one list of named actions, the switch among them after
    /// Copy, and performing it switches the reply in the conversation. The
    /// row builds that list and its pills from the same value.
    @MainActor func testAssistiveTechnologyReachesTheSwitchThroughTheRow() async throws {
        let stage = await stage([Self.user("u1", "Answer me."), Self.reply("a1", "An **answer** with `code`.", turn: "u1")])
        defer { stage.close() }
        let row = try XCTUnwrap(textRows(stage, of: "a1").first)
        guard case .block(let block) = row.contentItem, let message = block.message else { return XCTFail("The reply is a block row") }
        /// The row's message as its container draws it: with the conversation's
        /// disclosure for it and the container's toggle.
        func drawn() -> MessageRowView {
            MessageRowView(message: message, actions: TranscriptActions(),
                           disclosure: TranscriptRowDisclosure.of(row.contentItem, in: stage.session.disclosure),
                           toggle: { [weak row] part in row?.toggleDisclosure(part) }, switchesSource: true)
        }
        let rendered = try XCTUnwrap(drawn().source, "a finished reply offers the switch")
        XCTAssertFalse(rendered.raw)
        let named = TranscriptRowAction.all(message, TranscriptActions(), source: rendered)
        XCTAssertEqual(named.map(\.name), ["Copy", "View raw", "Details"])
        named.first { $0.name == "View raw" }?.perform()
        stage.draw(); await stage.settle()
        XCTAssertTrue(stage.session.disclosure.isOpen(.source("a1")), "performing it switches the reply")
        XCTAssertEqual(views(NSTextField.self, in: row).filter(\.isSelectable).map(\.stringValue), [message.text])
        let raw = try XCTUnwrap(drawn().source)
        XCTAssertTrue(raw.raw)
        XCTAssertEqual(TranscriptRowAction.all(message, TranscriptActions(), source: raw).map(\.name), ["Copy", "View rendered", "Details"],
                       "and then offers the way back")
        TranscriptRowAction.all(message, TranscriptActions(), source: raw).first { $0.name == "View rendered" }?.perform()
        stage.draw(); await stage.settle()
        XCTAssertFalse(stage.session.disclosure.isOpen(.source("a1")))
        XCTAssertTrue(views(NSTextField.self, in: row).filter(\.isSelectable).allSatisfy { $0.stringValue != message.text }, "rendered again")

        // No switch on a message the reader sent, a reply still arriving, or
        // a row that cannot reach the conversation's disclosure.
        XCTAssertNil(MessageRowView(message: Self.user("u2", "**typed**"), actions: TranscriptActions(), switchesSource: true).source)
        var streaming = message; streaming.state = "streaming"
        XCTAssertNil(MessageRowView(message: streaming, actions: TranscriptActions(), switchesSource: true).source)
        XCTAssertNil(MessageRowView(message: message, actions: TranscriptActions()).source)
        // The rest of the list is what it always was.
        var actions = TranscriptActions(); actions.fork = { _ in }
        XCTAssertEqual(TranscriptRowAction.all(Self.user("u2", "Hi"), actions, forks: true).map(\.name), ["Edit", "Copy", "Details"])
        XCTAssertEqual(TranscriptRowAction.all(message, actions, forks: true).map(\.name), ["Copy", "Details", "Fork from here"])
        var sending = Self.user("u3", "Hi"); sending.state = TranscriptMessage.sendingState
        XCTAssertEqual(TranscriptRowAction.all(sending, actions, forks: true).map(\.name), ["Copy"])
    }

    /// A reply that streamed keeps the very surface it streamed into when it
    /// settles, in a chat that can fork as in one that cannot: Fork from here
    /// and View raw arriving in the row's actions must not give the row's
    /// content a new identity, which would rebuild its text from estimates
    /// and drop the reader's selection in it.
    @MainActor func testASettlingReplyKeepsItsSurfaceWhereTheChatCanFork() async throws {
        for forks in [false, true] {
            var reply = Self.reply("a1", String(Self.longReply.prefix(1_600)), turn: "u1")
            reply.state = "streaming"
            let session = SessionDisplay(id: "settle-" + UUID().uuidString)
            session.messages = [Self.user("u1", "Write it all out."), reply]
            session.state = "running"
            let stage = TranscriptStreamingStressTests.Stage(session)
            defer { stage.close() }
            stage.environment.forks = forks
            stage.actions.fork = { _ in }
            stage.page.state = "running"
            stage.refresh(); await stage.settle()
            let row = try XCTUnwrap(textRows(stage, of: "a1").first)
            let surface = try XCTUnwrap(views(NativeMarkdownContainer.self, in: row).first, "a streaming reply is drawn by its native surface")
            reply.text = Self.longReply; reply.state = "complete"
            session.messages = [Self.user("u1", "Write it all out."), reply]
            session.state = "idle"; stage.page.state = "idle"
            stage.refresh(); await stage.settle(turns: 10)
            let settled = try XCTUnwrap(textRows(stage, of: "a1").first)
            XCTAssertTrue(views(NativeMarkdownContainer.self, in: settled).first === surface,
                          "forks \(forks): the settled reply is still the surface it streamed into")
        }
    }

    /// The shared geometry cache never hands a reply the height it measured
    /// in the other view.
    @MainActor func testSharedGeometryIsNeverReusedAcrossRenderedAndSource() {
        let cache = TranscriptGeometryCache()
        let item = TranscriptItem.message(Self.reply("m1", "A **settled** reply.", turn: "u1"))
        var raw = TranscriptRowDisclosure(); raw.raw = true
        cache.store(CGSize(width: 600, height: 120), sessionID: "s", item: item, fresh: false,
                    environment: TranscriptRowEnvironment(), disclosure: .default, backingScale: 2)
        XCTAssertNil(cache.measurement(sessionID: "s", item: item, fresh: false, environment: TranscriptRowEnvironment(),
                                       disclosure: raw, width: 600, backingScale: 2),
                     "a reply read as its source cannot borrow the rendered reply's height")
    }
}
