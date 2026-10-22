import AppKit
import XCTest
@testable import PiApp

/// PERF-1 (the 0.1.130 soak): opening chats beside the Agents, Diff and
/// Files card. The card narrows the reading column below the page's 840
/// points in most windows, and switching chats costs the card itself.
final class SessionCardSwitchTests: XCTestCase {
    /// Prose that wraps differently at the page's width and in the column.
    private static func prose(_ chat: String, _ reply: Int) -> String {
        (0..<3).map { "\(chat) reply \(reply), paragraph \($0): " + String(repeating: "Words that wrap differently in the narrower column. ", count: 5) }
            .joined(separator: "\n\n")
    }

    /// Three turns, as the synthetic gateway answers: replies with a response
    /// timeline (reasoning, then words: a part row's words) and one without
    /// (the reply's own body row).
    @MainActor private static func messages(_ chat: String) -> [TranscriptMessage] {
        var result: [TranscriptMessage] = []
        for turn in 0..<3 {
            let question = "\(chat)-q\(turn)"
            var user = TranscriptMessage(id: question, role: "user", text: "Question \(turn) about the retry loop?", turn: question)
            user.at = Double(turn) * 10
            var reply = TranscriptMessage(id: "\(chat)-a\(turn)", role: "assistant", text: prose(chat, turn), turn: question)
            reply.at = Double(turn) * 10 + 5
            if turn != 1 {
                reply.responseTimeline = ResponseTimeline.canonical([(kind: "reasoningText", text: "Where does the retry live?", callID: nil, name: nil),
                                                                     (kind: "text", text: reply.text, callID: nil, name: nil)], sourceID: reply.id)
            }
            result += [user, reply]
        }
        return result
    }

    @MainActor private final class Bench {
        let model: WorkspaceModel
        let chats: [ChatRecord]
        let pane: ConversationPaneView
        let window: NSWindow
        init(_ test: XCTestCase, width: CGFloat) throws {
            let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("session-card-" + UUID().uuidString)
            // Chats of their own: the page's shared heights outlive a test.
            let run = UUID().uuidString.prefix(8)
            let bench = try ConversationPaneTests.workbench(root: root, chats: ["first", "second", "third"].map { "\($0)-\(run)" })
            test.registerWorkspaceFixtureTeardown(bench.model, root: root)
            model = bench.model; chats = bench.chats
            for chat in chats {
                let display = SessionDisplay(id: chat.id)
                display.historyState = .ready; display.draftReady = true
                display.messages = SessionCardSwitchTests.messages(chat.title)
                model.displays[chat.id] = display
            }
            pane = ConversationPaneView(model: model, panelState: SessionPanelState())
            // Never shown: the pane lays out and draws without taking focus.
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = pane
            test.addTeardownBlock { @MainActor [window] in window.contentView = nil; window.close() }
            // The column keeps its width while a page fills: a legacy
            // scroller appearing partway would narrow it, and every row would
            // rightly be laid out again at the new width.
            let transcript = ConversationPaneTests.views(NSScrollView.self, in: pane).filter { $0.documentView is TranscriptNativeDocument }
            XCTAssertEqual(transcript.count, 1, "the pane has its transcript")
            for scroll in transcript { scroll.scrollerStyle = .overlay }
        }
        func show(_ index: Int) async {
            let chat = chats[index]
            model.selectedID = chat.id; model.selected = model.displays[chat.id]; model.focusedSessionID = chat.id
            pane.show(session: model.displays[chat.id]!, chat: chat)
            await settle()
        }
        /// What the run loop still owes the pane: the transcript's scheduled
        /// layout, deferred validation, the card's layers drawn.
        func settle() async {
            for _ in 0..<12 {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        }
        var document: TranscriptNativeDocument? {
            ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: pane).first?.enclosingScrollView?.documentView as? TranscriptNativeDocument
        }
        /// The replies' text surfaces on the page, with the row each is drawn in.
        var surfaces: [(surface: NativeMarkdownContainer, row: TranscriptRowContainer)] {
            guard let document else { return [] }
            return document.subviews.compactMap { $0 as? TranscriptRowContainer }.flatMap { row in
                ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).filter { $0.textLength > 0 }.map { ($0, row) }
            }
        }
    }

    /// Each reply shown beside the card is laid out once, at the column's
    /// width: opening a chat, another, each again with its rows built anew
    /// (standing at the heights the page kept for them), and rows that let
    /// go of their trees — the reader scrolled far past them — building them
    /// again as they come back into view. Before, a reply's words were laid
    /// out at 840 points as their view joined the page, then again at the
    /// column's width when the row measured them.
    @MainActor func testRepliesBesideTheCardAreLaidOutOnceAtTheColumnWidth() async throws {
        let limit = TranscriptKeptRows.chatLimit
        TranscriptKeptRows.chatLimit = 0
        defer { TranscriptKeptRows.chatLimit = limit }
        // A pane about as wide as the soak's (a 1,280-point window less its
        // sidebar): the card leaves the column about 620 points.
        let bench = try Bench(self, width: 1_000)
        func check(_ step: String) {
            XCTAssertFalse(bench.pane.sessionPanel.isHidden, "\(step): the card is beside the chat")
            let words = bench.surfaces.filter { $0.surface.superview is TranscriptNativeReplyRow }
            XCTAssertGreaterThanOrEqual(words.count, 2, "\(step): replies' words are on the page")
            XCTAssertTrue(words.contains { $0.surface.superview?.superview is TranscriptNativePartView }, "\(step): a part row's words are covered")
            XCTAssertTrue(words.contains { !($0.surface.superview?.superview is TranscriptNativePartView) }, "\(step): a reply's own row is covered")
            for (surface, row) in words {
                XCTAssertLessThan(surface.bounds.width, TranscriptMetrics.pageWidth - 100, "\(step): the column is narrower than the page")
                XCTAssertEqual(surface.textLayouts, 1, "\(step), row \(row.itemID): its words were laid out \(surface.textLayouts) times")
                XCTAssertEqual(surface.textLayoutWidth, surface.bounds.width, "\(step), row \(row.itemID): laid out at its own width")
            }
        }
        var borrowed = 0
        for (step, index) in [0, 1, 0, 1].enumerated() {
            await bench.show(index)
            check("show \(step)")
            if step >= 2 { borrowed += bench.document?.retainedRows.reduce(0) { $0 + $1.sharedMeasurementHits } ?? 0 }
        }
        XCTAssertGreaterThan(borrowed, 0, "coming back, rows stood at the heights the page kept, laid out as they mounted")
        let document = try XCTUnwrap(bench.document)
        let mounted = document.retainedRows.filter { $0.superview != nil }
        for row in mounted { row.removeFromSuperview(); row.releaseHost() }
        XCTAssertTrue(mounted.allSatisfy { !$0.isHosted }, "the rows let go of their trees")
        document.layoutRows(width: document.frame.width)
        await bench.settle()
        XCTAssertTrue(mounted.contains { $0.superview != nil && $0.isHosted }, "the rows came back into view")
        check("trees built again")
    }

    /// Switching between chats whose card reads the same — no sides or
    /// agents yet, which is most chats — keeps the card's Agents rows, and
    /// redraws none of its pills: the folder menu, hidden on the Agents tab,
    /// was drawn again on every switch, making its symbols anew. New Side
    /// still opens a side of the chat now shown.
    @MainActor func testSwitchingChatsKeepsTheCardsRowsAndPills() async throws {
        let bench = try Bench(self, width: 1_000)
        await bench.show(0)
        let panel = bench.pane.sessionPanel
        XCTAssertFalse(panel.isHidden)
        let folder = try XCTUnwrap(ConversationPaneTests.views(PiKit.MenuButton.self, in: panel).first)
        var folderDraws = 0
        let draw = folder.content.drawer
        folder.content.drawer = { rect in folderDraws += 1; draw?(rect) }
        func newSide() -> FamilyPickerRow? {
            panel.agents.flatMap { ConversationPaneTests.views(FamilyPickerRow.self, in: $0).first { $0.accessibilityIdentifier() == "new-family-side" } }
        }
        let list = try XCTUnwrap(panel.agents), row = try XCTUnwrap(newSide())
        var rowDraws = 0
        let rowDraw = row.content.drawer
        row.content.drawer = { rect in rowDraws += 1; rowDraw?(rect) }
        for index in [1, 2, 0, 1] {
            await bench.show(index)
            XCTAssertTrue(panel.agents === list, "chat \(index): the Agents list follows the chat")
            XCTAssertTrue(newSide() === row, "chat \(index): rows that read the same are kept")
        }
        XCTAssertEqual(folderDraws, 0, "the hidden folder menu was drawn again")
        XCTAssertEqual(rowDraws, 0, "a kept row was drawn again")
        // The kept New Side acts for the chat shown now, not the one it was built for.
        let shown = bench.chats[1].id
        XCTAssertEqual(bench.model.selectedID, shown)
        row.onPress?()
        try await eventually("a side of the chat shown") { bench.model.sides[shown]?.pending == true }
        XCTAssertNil(bench.model.sides[bench.chats[0].id], "not a side of the chat the row was built for")
    }

    /// A list out of sight is not built: with Files shown, opening a chat
    /// with a side builds none of its Agents rows until Agents is chosen
    /// again, as when each chat had a list of its own. Kept across the
    /// switch, the list was rebuilt for the new family behind the Files tab.
    @MainActor func testAChatOpenedBesideAnotherTabBuildsItsAgentsOnlyWhenShown() async throws {
        let bench = try Bench(self, width: 1_000)
        let parent = bench.chats[1]
        var side = ChatRecord(id: "side-" + UUID().uuidString, workspaceID: parent.workspaceID, title: "Release checklist", path: nil,
                              profileID: parent.profileID)
        side.parentSessionID = parent.id
        bench.model.chats.append(side)
        await bench.show(0)
        let panel = bench.pane.sessionPanel
        XCTAssertNotNil(panel.agents, "the card opens on Agents")
        panel.select(.files); await bench.settle()
        XCTAssertEqual(panel.selectedTab, .files)
        func rows() -> [FamilyPickerRow] { ConversationPaneTests.views(FamilyPickerRow.self, in: panel) }
        await bench.show(1)
        XCTAssertEqual(panel.selectedTab, .files, "the card stays on Files")
        XCTAssertTrue(rows().isEmpty, "Agents rows were built behind the Files tab: \(rows().compactMap { $0.accessibilityIdentifier() })")
        panel.select(.agents); await bench.settle()
        XCTAssertTrue(rows().contains { $0.accessibilityIdentifier() == "open-side-" + side.id }, "choosing Agents builds the chat's list, with its side")
    }
}
