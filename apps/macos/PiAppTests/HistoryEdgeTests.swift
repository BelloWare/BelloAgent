import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The edges of a conversation: where the rows the page holds end and the
/// rest of the chat begins. The reader should not have to see them. A page
/// that reaches an edge loads what lies beyond it on its own; an edit the
/// reader makes moves the chat onto a new branch, and the page goes there
/// with them. Every check is on what the reader sees, pass after pass.
final class HistoryEdgeTests: XCTestCase {

    // MARK: What one pass shows

    /// One drawn pass of the pane.
    struct Pass {
        /// The transcript's scroll view, in window coordinates.
        var surface: CGRect
        /// The pane's own frame, in window coordinates.
        var pane: CGRect
        /// Every row on screen: its top edge in window coordinates, and its height.
        var rows: [String: (top: CGFloat, height: CGFloat)]
        /// The messages the page holds, in order.
        var messages: [String]
        /// What each row on screen shows, for a failure to name it.
        var names: [String: String] = [:]
    }
    @MainActor static func pass(_ hosted: NSView) -> Pass? {
        guard let scroll = ConversationPaneTests.views(TranscriptNativeScrollView.self, in: hosted).first,
              let document = scroll.documentView as? TranscriptNativeDocument else { return nil }
        let surface = scroll.convert(scroll.bounds, to: nil)
        var rows: [String: (top: CGFloat, height: CGFloat)] = [:], names: [String: String] = [:]
        for row in document.retainedRows where row.superview != nil {
            let frame = row.convert(row.bounds, to: nil)
            guard frame.height > 0, frame.intersects(surface) else { continue }
            rows[row.itemID] = (frame.maxY, frame.height)
            switch row.contentItem {
            case .message(let message): names[row.itemID] = message.role + " “" + message.text.prefix(24) + "”"
            case .block(let block): names[row.itemID] = "reply “" + (block.message?.text.prefix(24) ?? "") + "”"
            }
        }
        let page = ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.page
        return Pass(surface: surface, pane: hosted.convert(hosted.bounds, to: nil), rows: rows,
                    messages: page?.snapshot?.messages.map(\.id) ?? [], names: names)
    }
    /// The rows on screen in both passes moved together: by the one scroll
    /// between them, and down by whatever the rows above them grew by (a
    /// reply streaming in above its own footer). Anything left over is the
    /// page moving a row on its own. Returns the scroll, and what moved on
    /// its own if anything did.
    static func rowsMovedTogether(_ before: Pass, _ after: Pass, tolerance: CGFloat = 3) -> (delta: CGFloat, problem: String?) {
        // Top of the screen first: window coordinates grow upwards.
        let shared = Set(before.rows.keys).intersection(after.rows.keys).sorted { before.rows[$0]!.top > before.rows[$1]!.top }
        guard !shared.isEmpty else { return (0, nil) }
        var grown: CGFloat = 0, implied: [CGFloat] = []
        for id in shared {
            let was = before.rows[id]!, now = after.rows[id]!
            implied.append(now.top - was.top + grown)
            grown += now.height - was.height
        }
        // The scroll is what the rows agree on.
        let scroll = implied.sorted()[implied.count / 2]
        let strays = zip(shared, implied).filter { abs($0.1 - scroll) > tolerance }
        guard !strays.isEmpty else { return (scroll, nil) }
        let moved: [String] = strays.map { stray in (after.names[stray.0] ?? stray.0) + " moved \(Int(stray.1 - scroll)) pt" }
        return (scroll, moved.joined(separator: ", ") + " on its own while the page scrolled \(Int(scroll)) pt")
    }
}

// MARK: - Editing and resending

extension HistoryEdgeTests {
    /// Editing an earlier question and sending it moves the chat onto a new
    /// branch. That is what the reader asked for: the page follows the new
    /// reply as it streams, and no edge ever says the branch changed, that
    /// newer messages are loading, or that anything needs reloading.
    @MainActor func testEditingAnEarlierQuestionFollowsTheNewBranch() async throws {
        try await editAndResend("Second question")
    }
    /// The same for the question the chat ended with.
    @MainActor func testEditingTheLatestQuestionFollowsTheNewBranch() async throws {
        try await editAndResend("Third question")
    }
    /// The way an edit usually starts: the reader has scrolled up to the
    /// question they want to change. Sending it takes them to the new turn
    /// at the end, in one movement of the whole page.
    @MainActor func testEditingAQuestionScrolledUpToGoesToTheNewTurn() async throws {
        try await editAndResend("Second question", questions: 6, scrolledUp: true)
    }

    @MainActor private func editAndResend(_ target: String, questions: Int = 3, scrolledUp: Bool = false) async throws {
        let live = try await ConversationPaneTests.LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        let names = ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]
        for question in names.prefix(questions).map({ $0 + " question" }) {
            await live.send(question)
            await live.waitUntil("“\(question)” was never answered") {
                !live.session.hasWork && !live.session.loading
                    && live.session.messages.contains { $0.role == "assistant" && $0.text.contains(question) }
            }
        }
        await live.settle(10)
        let page = try XCTUnwrap(live.transcript)
        let rows = live.session.messages
        let original = try XCTUnwrap(rows.first { $0.role == "user" && $0.text == target })
        let abandoned = Set(rows.drop(while: { $0.id != original.id }).map(\.id))
        if scrolledUp {
            // The reader scrolls up until the question is at the top of the page.
            let scroll = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeScrollView.self, in: live.hosted).first)
            let top = try XCTUnwrap(page.rowFrame(of: original.id), "The question is not on the page").minY - 12
            page.readerWillNavigate(upward: true)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: top)); scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            await live.settle(10)
            XCTAssertFalse(page.atBottom, "The chat is long enough that the question is away from the end")
        }
        live.model.editMessage(original.id, sessionID: live.chat.id)
        await live.waitUntil("The original never loaded for editing") {
            !live.session.editPreparing && live.session.editingMessageID == original.id
        }
        let edited = target + ", edited"
        live.session.draft = edited
        let start = try XCTUnwrap(Self.pass(live.hosted), "No transcript on screen")
        var previous = start, problems: [String] = [], left = false, passes = 0
        live.model.sendEdit(sessionID: live.chat.id)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            await live.settle(1)
            passes += 1
            let session = live.session
            guard let now = Self.pass(live.hosted) else { problems.append("pass \(passes): no transcript on screen"); continue }
            // Measured from the pane's own top: the test window resizes itself
            // to the pane's minimum height as the composer changes.
            let above = now.pane.maxY - now.surface.maxY, before = start.pane.maxY - start.surface.maxY
            if abs(above - before) > 0.5 {
                problems.append("pass \(passes): something above the transcript moved its top edge by \(Int(before - above)) pt (transcript \(now.surface) in \(now.pane))")
            }
            let edges = Self.edges(live.hosted).filter { $0.kind != "latest" }
            if !edges.isEmpty { problems.append("pass \(passes): an edge shows: \(Self.describe(edges))") }
            if session.newerPage.available {
                problems.append("pass \(passes): the page shows a newer edge: “\(session.newerPage.error ?? "Load newer")”")
            }
            if let error = session.olderPage.error { problems.append("pass \(passes): the earlier edge failed: \(error)") }
            if session.browsingHistory { problems.append("pass \(passes): the page stopped following the live rows") }
            if session.historyState.loading { problems.append("pass \(passes): the conversation was reloaded behind the loading cover") }
            if now.messages.isEmpty { problems.append("pass \(passes): the page was blank") }
            if let moved = Self.rowsMovedTogether(previous, now).problem { problems.append("pass \(passes): \(moved)") }
            // The rows the edit abandoned leave once, and never come back.
            let showing = now.messages.contains { abandoned.contains($0) }
            if left && showing { problems.append("pass \(passes): an abandoned row came back") }
            if !showing { left = true }
            previous = now
            if !session.hasWork, !session.loading, !session.editSubmitting,
               page.snapshot?.messages.contains(where: { $0.role == "assistant" && $0.text.contains(edited) }) == true { break }
        }
        await live.settle(10)
        XCTAssertTrue(problems.isEmpty, "\(problems.count) of \(passes) passes went wrong:\n" + problems.prefix(12).joined(separator: "\n"))
        let shown = page.snapshot?.messages ?? []
        XCTAssertTrue(shown.contains { $0.role == "user" && $0.text == edited }, "The edited question shows")
        XCTAssertTrue(shown.contains { $0.role == "assistant" && $0.text.contains(edited) }, "Its new reply shows")
        XCTAssertTrue(shown.contains { $0.kind == "branch" }, "The branch marker shows where the edit began")
        XCTAssertFalse(shown.contains { abandoned.contains($0.id) }, "Nothing the edit abandoned is left on the page")
        XCTAssertTrue(page.atBottom, "The page follows the new reply to its end")
        XCTAssertFalse(live.session.browsingHistory)
        XCTAssertFalse(live.session.newerPage.available)
        XCTAssertNil(live.session.newerPage.error)

        // The page is still the live conversation: the next message arrives
        // in it, with its reply, without anything being reloaded.
        await live.send("After the edit")
        await live.waitUntil("The next message never reached the page") {
            !live.session.hasWork && !live.session.loading
                && page.snapshot?.messages.contains { $0.role == "assistant" && $0.text.contains("After the edit") } == true
        }
        XCTAssertFalse(live.session.browsingHistory)
        closed = true
        await live.close()
    }
}

// MARK: - Reaching the top of a long chat

extension HistoryEdgeTests {
    /// A long chat read from its journal, with no helper: every earlier page
    /// comes from the file, as it does for a chat the helper has let go of.
    @MainActor final class PagedChat {
        let model: WorkspaceModel
        let chat: ChatRecord
        let view: SessionDisplay
        let window: NSWindow
        let hosted: NSHostingView<ConversationPane>
        let path: String
        let root: URL

        /// `questionsOnly`: every row a one-line question, each its own turn,
        /// so a page of three turns is three short rows.
        init(turns: Int, height: CGFloat = 760, questionsOnly: Bool = false) async throws {
            root = scratchRoot("history-edges")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("history.jsonl"), encoder = JSONEncoder()
            var bytes = try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("a")]); bytes.append(10)
            for index in 0..<(questionsOnly ? turns : turns * 2) {
                let user = questionsOnly || index % 2 == 0
                let text = questionsOnly ? "Question \(index)?" : user ? "Question \(index / 2)?"
                    : "## Answer \(index / 2)\n\n" + String(repeating: "A paragraph long enough to wrap across the page, with **bold** and `code`. ", count: 5)
                        + "\n\n- one point\n- another point\n\nAnd a closing line for answer \(index / 2)."
                bytes.append(try encoder.encode(["type": WireValue.string("message"), "id": .string("m\(index)"),
                    "parentId": index == 0 ? .null : .string("m\(index - 1)"),
                    "message": .object(["role": .string(user ? "user" : "assistant"), "content": .string(text)])]))
                bytes.append(10)
            }
            try bytes.write(to: file)
            path = file.path
            model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
            try await model.reloadConfiguration()
            chat = ChatRecord(id: "a", workspaceID: "project", title: "A", path: file.path, profileID: "profile")
            model.chats = [chat]
            await model.select("a")
            view = try XCTUnwrap(model.selected)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosted = NSHostingView(rootView: ConversationPane(model: model, session: view, chat: chat, paneWidth: 900))
            window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        }
        var page: TranscriptPage? { ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.page }
        var scroll: TranscriptNativeScrollView? { ConversationPaneTests.views(TranscriptNativeScrollView.self, in: hosted).first }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 8) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }; draw() }
        func ready() async throws {
            for _ in 0..<400 where view.historyState != .ready { await settle(1) }
            XCTAssertEqual(view.historyState, .ready, "The chat never finished opening")
            await settle(10)
        }
        /// The reader scrolls to the top of what the page holds.
        func readerScrollsToTop() throws {
            let page = try XCTUnwrap(page), scroll = try XCTUnwrap(scroll)
            page.readerWillNavigate(upward: true)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        func close() { window.contentView = nil; window.close() }
    }

    /// Checks one pass of a chat whose rows are only ever added in front:
    /// the transcript's frame never moves (nothing is shown above or below
    /// it), and the rows on screen stay exactly where the reader left them.
    @MainActor private func watch(_ chat: PagedChat, from start: Pass, previous: inout Pass, pass index: Int, into problems: inout [String],
                                  spinnerAllowed: Bool = false) {
        guard let now = Self.pass(chat.hosted) else { problems.append("pass \(index): no transcript on screen"); return }
        // The way back to the latest message is the reader's, not an edge's:
        // it shows whenever they are away from the bottom.
        let edges = Self.edges(chat.hosted).filter { $0.kind != "latest" && !(spinnerAllowed && $0.kind == "loading") }
        if !edges.isEmpty { problems.append("pass \(index): an edge shows: \(Self.describe(edges))") }
        if abs(now.surface.maxY - now.pane.maxY) > 0.5 {
            problems.append("pass \(index): the transcript starts \(Int(now.pane.maxY - now.surface.maxY)) pt below the pane's top: something is drawn above it")
        }
        if abs(now.surface.minY - start.surface.minY) > 0.5 || abs(now.surface.height - start.surface.height) > 0.5 {
            problems.append("pass \(index): the transcript's frame changed from \(start.surface) to \(now.surface)")
        }
        let moved = Self.rowsMovedTogether(previous, now)
        if let problem = moved.problem { problems.append("pass \(index): \(problem)") }
        else if abs(moved.delta) > 3 { problems.append("pass \(index): the rows on screen moved \(Int(moved.delta)) pt with nobody scrolling") }
        previous = now
    }

    /// Scrolling to the top of a long chat reads the page before it, and
    /// the next, and the next. Each lands in front of what the reader is
    /// looking at without moving it, and nothing announces it: no bar above
    /// the conversation, no text, no change to the transcript's frame.
    @MainActor func testReachingTheTopReadsEarlierPagesWithoutAStripOrAJump() async throws {
        let chat = try await PagedChat(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        defer { chat.close() }
        try await chat.ready()
        XCTAssertNotNil(chat.view.olderPage.cursor, "The chat opens on its newest page")
        let start = try XCTUnwrap(Self.pass(chat.hosted))
        var previous = start, problems: [String] = [], passes = 0
        for round in 0..<3 {
            let first = chat.view.messages.first?.id
            try chat.readerScrollsToTop()
            chat.draw(); previous = try XCTUnwrap(Self.pass(chat.hosted))
            let began = Date()
            var landed = false
            while Date().timeIntervalSince(began) < 10 {
                await chat.settle(1); passes += 1
                // A read that has been slow may show the spinner, nothing else.
                watch(chat, from: start, previous: &previous, pass: passes, into: &problems,
                      spinnerAllowed: Date().timeIntervalSince(began) >= 0.3)
                if chat.view.messages.first?.id != first, !chat.view.olderPage.loading { landed = true; break }
            }
            XCTAssertTrue(landed, "Round \(round): reaching the top never read the page before it")
            for _ in 0..<12 { await chat.settle(1); passes += 1; watch(chat, from: start, previous: &previous, pass: passes, into: &problems, spinnerAllowed: true) }
            XCTAssertNil(chat.view.olderPage.error, "Round \(round): \(chat.view.olderPage.error ?? "")")
        }
        XCTAssertTrue(problems.isEmpty, "\(problems.count) of \(passes) passes went wrong:\n" + problems.prefix(12).joined(separator: "\n"))
    }

    /// A page that is slow to arrive shows no more than it needs to: for the
    /// first moments nothing at all, and then only the small spinner at the
    /// edge. The transcript's frame never moves, and when the page lands the
    /// reader's row is where it was.
    @MainActor func testASlowEarlierPageShowsNothingThenOnlyTheSpinner() async throws {
        let chat = try await PagedChat(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        defer { chat.close() }
        try await chat.ready()
        let gate = AsyncGate(), reader = chat.model.history, path = chat.path
        chat.model.historyWindowLoader = { _, cursor, newer, around in
            await gate.wait()
            return try ConversationHistoryPage(try await reader.window(path: path, cursor: cursor, newer: newer, around: around))
        }
        let start = try XCTUnwrap(Self.pass(chat.hosted))
        var previous = start, problems: [String] = [], passes = 0
        let first = chat.view.messages.first?.id
        try chat.readerScrollsToTop()
        chat.draw(); previous = try XCTUnwrap(Self.pass(chat.hosted))
        let began = Date()
        var spinner = false
        while Date().timeIntervalSince(began) < 0.9 {
            await chat.settle(1); passes += 1
            let elapsed = Date().timeIntervalSince(began)
            // Nothing at all for the first moments; the spinner after them.
            watch(chat, from: start, previous: &previous, pass: passes, into: &problems, spinnerAllowed: elapsed >= 0.28)
            if elapsed >= 0.5 {
                let shown = Self.edges(chat.hosted)
                if shown.contains(where: { $0.edge == "earlier" && $0.kind == "loading" }) { spinner = true }
                else { problems.append("pass \(passes): \(Int(elapsed * 1000)) ms into a slow read and no spinner: \(Self.describe(shown))") }
            }
        }
        XCTAssertTrue(spinner, "A slow read shows the spinner at the top")
        XCTAssertTrue(chat.view.olderPage.loading, "The earlier page is still on its way")
        await gate.open()
        while chat.view.olderPage.loading || chat.view.messages.first?.id == first {
            await chat.settle(1); passes += 1
            watch(chat, from: start, previous: &previous, pass: passes, into: &problems, spinnerAllowed: true)
            if Date().timeIntervalSince(began) > 10 { XCTFail("The earlier page never landed"); break }
        }
        // The spinner leaves with the read (it fades); then nothing is left.
        for _ in 0..<30 { await chat.settle(1); passes += 1; watch(chat, from: start, previous: &previous, pass: passes, into: &problems, spinnerAllowed: true) }
        for _ in 0..<10 { await chat.settle(1); passes += 1; watch(chat, from: start, previous: &previous, pass: passes, into: &problems) }
        XCTAssertTrue(problems.isEmpty, "\(problems.count) of \(passes) passes went wrong:\n" + problems.prefix(12).joined(separator: "\n"))
    }
}

// MARK: - Reads that end, and end only themselves

/// Holds every history read until the test lets it go, and counts them.
private actor HeldReads {
    private(set) var started = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func read() async {
        started += 1
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { open = true; waiting.forEach { $0.resume() }; waiting = [] }
}

extension HistoryEdgeTests {
    /// A chat on screen with a page of rows and an earlier boundary, and no helper.
    @MainActor private func heldChat() async throws -> (model: WorkspaceModel, view: SessionDisplay) {
        let root = scratchRoot("history-edge-reads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "profile")
        let view = SessionDisplay(id: chat.id)
        view.messages = (4..<10).map { TranscriptMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0)") }
        view.presentation.identity = ("runtime", "root")
        view.olderPage = .init(cursor: .init(incarnation: "runtime", lineage: "root", entry: "m4"))
        view.historyState = .ready; view.presentation.readyAt = PerformanceProbe.now
        model.chats = [chat]; model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view
        return (model, view)
    }
    private func earlierPage(_ ids: [String], older: String? = nil) throws -> ConversationHistoryPage {
        try ConversationHistoryPage(.object([
            "version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array(ids.map { .object(["id": .string($0), "role": .string("user"), "text": .string("Earlier \($0)")]) }),
            "older": older.map { .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string($0)]) } ?? .null,
            "newer": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string(ids.last ?? "")])]))
    }

    /// A read whose page was replaced under it (a search result opened in
    /// the same chat) finishes after the reader has asked again. It must not
    /// end the read that is under way now: that read's spinner would go, and
    /// the page would start a second read of the same rows.
    @MainActor func testAReadThatWasReplacedDoesNotEndTheReadUnderWayNow() async throws {
        let (model, view) = try await heldChat()
        let first = HeldReads()
        let stale = try earlierPage(["m2", "m3"], older: "m2")
        model.historyWindowLoader = { _, _, _, _ in await first.read(); return stale }
        let superseded = Task { await model.loadHistoryPage(view.id, newer: false) }
        for _ in 0..<500 { if await first.started == 1 { break }; await Task.yield() }
        XCTAssertTrue(view.olderPage.loading)
        // The page is replaced under that read, and the reader asks again.
        let replaced = try ConversationHistoryPage(.object([
            "version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array((20..<24).map { .object(["id": .string("m\($0)"), "role": .string("user"), "text": .string("Message \($0)")]) }),
            "older": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("m20")]), "newer": .null]))
        model.adoptInitialHistory(replaced, into: view)
        view.historyState = .ready
        let second = HeldReads()
        let earlier = try earlierPage(["m18", "m19"], older: "m18")
        model.historyWindowLoader = { _, _, _, _ in await second.read(); return earlier }
        let current = Task { await model.loadHistoryPage(view.id, newer: false) }
        for _ in 0..<500 { if await second.started == 1 { break }; await Task.yield() }
        XCTAssertTrue(view.olderPage.loading)
        await first.release()
        let droppedStale = await superseded.value
        XCTAssertFalse(droppedStale, "The replaced read's page is not joined to the new window")
        XCTAssertTrue(view.olderPage.loading, "The read under way now is still loading when the replaced one finishes")
        await second.release()
        let loaded = await current.value
        XCTAssertTrue(loaded)
        XCTAssertFalse(view.olderPage.loading)
        XCTAssertEqual(view.messages.first?.id, "m18")
    }

    /// Sending while an earlier page is on its way follows the new turn in
    /// place. The earlier read is let go of; the conversation is not read
    /// again behind the loading cover, which blanked the whole page.
    @MainActor func testSendingWhileAnEarlierPageLoadsFollowsWithoutReloading() async throws {
        let (model, view) = try await heldChat()
        let reads = HeldReads()
        let earlier = try earlierPage(["m2", "m3"], older: "m2")
        model.historyWindowLoader = { _, _, _, _ in await reads.read(); return earlier }
        let reading = Task { await model.loadHistoryPage(view.id, newer: false) }
        for _ in 0..<500 { if await reads.started == 1 { break }; await Task.yield() }
        XCTAssertTrue(view.olderPage.loading)
        let generation = view.presentationGeneration
        model.followSubmittedTurn(view.id)
        XCTAssertNotEqual(view.historyState, .loading, "Sending must not read the whole conversation again behind the loading cover")
        XCTAssertEqual(view.presentationGeneration, generation, "The page the reader is on stays the page")
        XCTAssertEqual(view.scrollAnchor?.followsBottom, true, "The page follows the new turn")
        await reads.release()
        let joined = await reading.value
        XCTAssertFalse(joined, "The earlier page no longer joins a page that is following its newest rows")
        XCTAssertFalse(view.olderPage.loading)
        XCTAssertNil(view.olderPage.error)
        XCTAssertEqual(view.messages.first?.id, "m4")
    }
}

// MARK: - What the edges show

extension HistoryEdgeTests {
    /// The edge controls on screen right now.
    @MainActor static func edges(_ hosted: NSView) -> [TranscriptEdgeMarkerView] {
        ConversationPaneTests.views(TranscriptEdgeMarkerView.self, in: hosted).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
    }
    @MainActor static func describe(_ edges: [TranscriptEdgeMarkerView]) -> String {
        edges.map { "\($0.edge) \($0.kind)" + ($0.text.isEmpty ? "" : " “\($0.text)”") }.joined(separator: ", ")
    }

    /// An edge says something only when it has to: a read that failed, a
    /// page lost, rows that wait for the reader, or a read that is slow.
    func testEdgesSpeakOnlyWhenTheyHaveTo() {
        let cursor = ConversationCursor(incarnation: "runtime", lineage: "root", entry: "m4")
        var boundary = ConversationPageBoundary()
        XCTAssertEqual(TranscriptEdge.earlier(boundary, slow: false, waitsForReader: true), .quiet, "Nothing before the first row")
        boundary.cursor = cursor
        XCTAssertEqual(TranscriptEdge.earlier(boundary, slow: false, waitsForReader: false), .quiet, "Rows the page reads on its own need no control")
        XCTAssertEqual(TranscriptEdge.earlier(boundary, slow: false, waitsForReader: true), .waiting)
        boundary.loading = true
        XCTAssertEqual(TranscriptEdge.earlier(boundary, slow: false, waitsForReader: true), .quiet, "A read that is not slow yet shows nothing")
        XCTAssertEqual(TranscriptEdge.earlier(boundary, slow: true, waitsForReader: true), .loading)
        boundary.loading = false; boundary.error = "Unavailable"
        XCTAssertEqual(TranscriptEdge.earlier(boundary, slow: false, waitsForReader: false), .failed("Unavailable"))
        XCTAssertEqual(TranscriptEdge.newer(boundary, slow: false), .failed("Unavailable"), "A failed read with a boundary can be retried")
        boundary.cursor = nil
        XCTAssertEqual(TranscriptEdge.newer(boundary, slow: false), .changed("Unavailable"), "With no boundary left, only a reload helps")
        XCTAssertEqual(TranscriptEdge.newer(.init(cursor: cursor), slow: false), .waiting, "An older window offers the rows after it")
        XCTAssertEqual(TranscriptEdge.newer(.init(cursor: cursor, loading: true), slow: false), .quiet)
    }

    /// An earlier page that cannot be read says so at the top, with its
    /// error and Retry, and nothing moves for it. Retry reads it.
    @MainActor func testAFailedEarlierPageOffersRetryWithItsError() async throws {
        let chat = try await PagedChat(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        defer { chat.close() }
        try await chat.ready()
        chat.model.historyWindowLoader = { _, _, _, _ in throw HostError.failure("The history source is unavailable.") }
        let start = try XCTUnwrap(Self.pass(chat.hosted))
        let first = chat.view.messages.first?.id
        try chat.readerScrollsToTop()
        var failed: TranscriptEdgeMarkerView?
        for _ in 0..<300 where failed == nil {
            await chat.settle(1)
            failed = Self.edges(chat.hosted).first { $0.edge == "earlier" && $0.kind == "failed" }
        }
        let marker = try XCTUnwrap(failed, "The failed read never showed at the top: \(Self.describe(Self.edges(chat.hosted)))")
        XCTAssertTrue(marker.text.contains("The history source is unavailable."), "The edge shows the read's own error: \(marker.text)")
        let now = try XCTUnwrap(Self.pass(chat.hosted))
        XCTAssertEqual(now.surface, start.surface, "The failure floats over the conversation; the transcript's frame is where it was")
        XCTAssertEqual(chat.view.messages.first?.id, first)
        // Retry reads the page again, and this time it arrives.
        chat.model.historyWindowLoader = nil
        marker.action?()
        for _ in 0..<300 where chat.view.messages.first?.id == first || chat.view.olderPage.loading { await chat.settle(1) }
        await chat.settle(20)
        XCTAssertNotEqual(chat.view.messages.first?.id, first, "Retry read the earlier page")
        XCTAssertNil(chat.view.olderPage.error)
        XCTAssertFalse(Self.edges(chat.hosted).contains { $0.edge == "earlier" }, "The failure left with it: \(Self.describe(Self.edges(chat.hosted)))")
    }

    /// A page too short to scroll, that has already filled itself as often as
    /// it may, cannot ask for the rows before it on its own. Only then does
    /// the top offer them, quietly, and pressing it reads them.
    @MainActor func testAShortPageThatHasFilledItselfOffersEarlierRows() async throws {
        let chat = try await PagedChat(turns: 60, questionsOnly: true)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        defer { chat.close() }
        try await chat.ready()
        await chat.settle(30)
        XCTAssertNotNil(chat.view.olderPage.cursor, "Earlier rows remain")
        XCTAssertLessThanOrEqual(chat.view.presentation.automaticFills, HistoryWindowPolicy.automaticFills)
        let waiting = try XCTUnwrap(Self.edges(chat.hosted).first { $0.edge == "earlier" && $0.kind == "waiting" },
                                    "The short page never offered its earlier rows: \(Self.describe(Self.edges(chat.hosted))); fills \(chat.view.presentation.automaticFills), rows \(chat.view.messages.count), waits \(chat.page?.earlierWaitsForReader == true), document \(chat.scroll?.documentView?.frame.height ?? -1) in \(chat.scroll?.contentView.bounds.height ?? -1), state \(chat.view.historyState), loading \(chat.view.olderPage.loading)")
        XCTAssertEqual(waiting.text, "Load earlier messages")
        let first = chat.view.messages.first?.id
        waiting.action?()
        for _ in 0..<300 where chat.view.messages.first?.id == first || chat.view.olderPage.loading { await chat.settle(1) }
        // Long enough for a control that goes to finish fading out.
        await chat.settle(30)
        XCTAssertNotEqual(chat.view.messages.first?.id, first, "Pressing it read the earlier rows")
        // Still too short to scroll, the offer stays for the next page; tall
        // enough, the reader's scrolling asks for it, and the offer goes.
        let document = try XCTUnwrap(chat.scroll?.documentView?.frame.height), viewport = try XCTUnwrap(chat.scroll?.contentView.bounds.height)
        let offered = Self.edges(chat.hosted).contains { $0.edge == "earlier" && $0.kind == "waiting" }
        XCTAssertEqual(offered, document <= viewport + TranscriptPage.earlierThreshold,
                       "A \(Int(document)) pt page in a \(Int(viewport)) pt viewport \(offered ? "still offers" : "no longer offers") the earlier rows")
    }

    /// An older window opened from a search is browsed on purpose: it
    /// offers the rows after it (Load newer) and the way to the latest
    /// message, beside each other at the bottom, over the conversation.
    @MainActor func testAnOlderWindowOpenedFromSearchOffersLatestAndLoadNewer() async throws {
        let chat = try await PagedChat(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        defer { chat.close() }
        try await chat.ready()
        let start = try XCTUnwrap(Self.pass(chat.hosted))
        try await chat.model.revealConversationHit("a", hit: .init(id: "m20", position: 0, preview: "Question 10?"))
        await chat.settle(30)
        XCTAssertTrue(chat.view.browsingHistory); XCTAssertNotNil(chat.view.newerPage.cursor)
        var edges = Self.edges(chat.hosted)
        let newer = try XCTUnwrap(edges.first { $0.edge == "newer" && $0.kind == "waiting" }, "No Load newer: \(Self.describe(edges))")
        XCTAssertEqual(newer.text, "Load newer messages")
        XCTAssertNotNil(edges.first { $0.kind == "latest" }, "No way to the latest message: \(Self.describe(edges))")
        XCTAssertEqual(try XCTUnwrap(Self.pass(chat.hosted)).surface, start.surface, "Both float over the conversation")
        // Load newer adds the rows after the window, and it is still an older window.
        let last = chat.view.messages.last?.id
        newer.action?()
        for _ in 0..<300 where chat.view.messages.last?.id == last || chat.view.newerPage.loading { await chat.settle(1) }
        await chat.settle(10)
        XCTAssertNotEqual(chat.view.messages.last?.id, last, "Load newer read the rows after the window")
        edges = Self.edges(chat.hosted)
        XCTAssertNotNil(edges.first { $0.edge == "newer" && $0.kind == "waiting" }, "Still an older window: \(Self.describe(edges))")
        // Latest goes to the end of the conversation, and the edges have nothing left to say.
        try XCTUnwrap(edges.first { $0.kind == "latest" }).action?()
        for _ in 0..<300 where chat.view.browsingHistory || chat.view.historyState != .ready { await chat.settle(1) }
        await chat.settle(20)
        XCTAssertEqual(chat.view.messages.last?.id, "m119")
        XCTAssertFalse(chat.view.newerPage.available)
        XCTAssertFalse(Self.edges(chat.hosted).contains { $0.edge == "newer" && $0.kind != "latest" }, Self.describe(Self.edges(chat.hosted)))
    }
}

extension HistoryEdgeTests {
    /// A page that lost its place (a branch nobody here asked for) says so
    /// above the way back to the latest message, inside the transcript at
    /// any length of explanation, and Reload reads the conversation again.
    @MainActor func testAPageThatLostItsPlaceSaysSoInsideThePane() async throws {
        let chat = try await PagedChat(turns: 60)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        defer { chat.close() }
        try await chat.ready()
        let start = try XCTUnwrap(Self.pass(chat.hosted))
        chat.view.newerPage = .init(cursor: nil, loading: false, error: WorkspaceModel.branchChangedElsewhere)
        chat.view.browsingHistory = true
        await chat.settle(20)
        let edges = Self.edges(chat.hosted)
        let changed = try XCTUnwrap(edges.first { $0.edge == "newer" && $0.kind == "changed" }, Self.describe(edges))
        let latest = try XCTUnwrap(edges.first { $0.kind == "latest" }, Self.describe(edges))
        let notice = changed.convert(changed.bounds, to: nil), circle = latest.convert(latest.bounds, to: nil)
        XCTAssertTrue(start.surface.insetBy(dx: -0.5, dy: -0.5).contains(notice), "The notice \(notice) is cut off by the transcript \(start.surface)")
        XCTAssertGreaterThanOrEqual(notice.minY, circle.maxY, "The notice stands above the circle, not over it")
        XCTAssertEqual(try XCTUnwrap(Self.pass(chat.hosted)).surface, start.surface, "Nothing about it moves the transcript")
        changed.action?()
        for _ in 0..<300 where chat.view.browsingHistory || chat.view.historyState != .ready { await chat.settle(1) }
        await chat.settle(10)
        XCTAssertNil(chat.view.newerPage.error, "Reload read the conversation again")
        XCTAssertFalse(chat.view.browsingHistory)
        XCTAssertFalse(Self.edges(chat.hosted).contains { $0.edge == "newer" && $0.kind != "latest" }, Self.describe(Self.edges(chat.hosted)))
    }
}

// MARK: - The branch a snapshot carries

@MainActor private final class SentFrames { var frames: [[String: WireValue]] = [] }

extension HistoryEdgeTests {
    /// A chat with three answered questions on screen, served by a helper
    /// whose every answer the test writes.
    @MainActor private func answeredChat() async throws -> (model: WorkspaceModel, view: SessionDisplay, host: HostSupervisor, sent: SentFrames) {
        let root = scratchRoot("history-edge-branch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "profile")
        let view = SessionDisplay(id: chat.id)
        view.messages = ["q1", "a1", "q2", "a2", "q3", "a3"].map { TranscriptMessage(id: $0, role: $0.hasPrefix("q") ? "user" : "assistant", text: $0) }
        view.projectionRevision = "runtime:1"; view.pageStartEnsured = true
        view.presentation.identity = ("runtime", "root"); view.historyState = .ready
        model.chats = [chat]; model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view
        let sent = SentFrames(), host = HostSupervisor(commandSender: { sent.frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID] = host; model.opened.insert(chat.id)
        addTeardownBlock { @MainActor in try? await host.shutdownAndWait() }
        return (model, view, host, sent)
    }
    /// The snapshot of a chat whose third... rows, on branch `lineage`.
    private func snapshot(_ rows: [(String, String, String?)], lineage: String, older: String? = nil) -> [String: WireValue] {
        ["seq": .number(2), "state": .string("running"), "runStatus": .string("running"), "displayRevision": .string("runtime:2"), "commands": .array([]),
         "messages": .array(rows.map { id, role, kind in
             var row: [String: WireValue] = ["id": .string(id), "role": .string(role), "text": .string(id)]
             if let kind { row["kind"] = .string(kind) }
             return .object(row)
         }),
         "historyIncarnation": .string("runtime"), "historyLineage": .string(lineage),
         "historyOlder": older.map { .object(["incarnation": .string("runtime"), "lineage": .string(lineage), "entry": .string($0)]) } ?? .null]
    }
    @MainActor private func exchange(_ model: WorkspaceModel, _ view: SessionDisplay, _ host: HostSupervisor, _ sent: SentFrames, _ result: [String: WireValue]) async throws {
        let count = sent.frames.count
        model.refresh(view.id)
        for _ in 0..<2_000 where sent.frames.count == count { try await Task.sleep(for: .milliseconds(1)) }
        let frame = try XCTUnwrap(sent.frames.last)
        let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
            "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(result)]), connectionID: connection)
        for _ in 0..<2_000 where view.snapshotInFlight { try await Task.sleep(for: .milliseconds(1)) }
    }

    /// The reader's edit of the second question lands: the page takes the
    /// new branch where it is, drops what the edit abandoned, keeps what
    /// came before it, and follows the new turn. Nothing reports it.
    @MainActor func testTheReadersOwnBranchIsAdoptedInPlace() async throws {
        let (model, view, host, sent) = try await answeredChat()
        view.olderPage = .init(cursor: .init(incarnation: "runtime", lineage: "root", entry: "q1"))
        // An earlier read under way on the branch being left.
        let reads = HeldReads(), earlier = try earlierPage(["q0"])
        model.historyWindowLoader = { _, _, _, _ in await reads.read(); return earlier }
        let reading = Task { await model.loadHistoryPage(view.id, newer: false) }
        for _ in 0..<500 { if await reads.started == 1 { break }; await Task.yield() }
        view.pendingBranch = .init(from: "root", messageID: "q2", turnID: "q2x")
        let request = view.viewportRequest
        try await exchange(model, view, host, sent, snapshot([("q1", "user", nil), ("a1", "assistant", nil), ("b1", "system", "branch"),
                                                              ("q2x", "user", nil), ("a2x", "assistant", nil)], lineage: "b1", older: "q1"))
        XCTAssertEqual(view.messages.map(\.id), ["q1", "a1", "b1", "q2x", "a2x"], "The abandoned rows left; the rows before the edit stayed")
        XCTAssertEqual(view.presentation.identity?.lineage, "b1")
        XCTAssertNil(view.pendingBranch)
        XCTAssertFalse(view.browsingHistory); XCTAssertFalse(view.newerPage.available); XCTAssertNil(view.newerPage.error)
        XCTAssertEqual(view.olderPage.cursor?.lineage, "b1", "The earlier rows are read from the new branch")
        XCTAssertEqual(view.scrollAnchor?.followsBottom, true); XCTAssertGreaterThan(view.viewportRequest, request, "The page goes to the new turn")
        await reads.release()
        let joined = await reading.value
        XCTAssertFalse(joined, "A read of the branch left behind is not joined to the new one")
        XCTAssertFalse(view.olderPage.loading); XCTAssertNil(view.olderPage.error)
        // The next token of the new reply arrives as a live update.
        var next = snapshot([("q1", "user", nil), ("a1", "assistant", nil), ("b1", "system", "branch"), ("q2x", "user", nil), ("a2x", "assistant", nil), ("q3x", "user", nil)], lineage: "b1", older: "q1")
        next["seq"] = .number(3); next["displayRevision"] = .string("runtime:3")
        try await exchange(model, view, host, sent, next)
        XCTAssertEqual(view.messages.last?.id, "q3x"); XCTAssertFalse(view.browsingHistory)
    }

    /// A snapshot taken before the edit landed still carries the branch the
    /// edit leaves. It is an ordinary update: the edit is still on its way,
    /// and the snapshot that does carry the new branch is adopted, not
    /// reported.
    @MainActor func testASnapshotFromBeforeTheEditLandsLeavesTheEditExpected() async throws {
        let (model, view, host, sent) = try await answeredChat()
        view.pendingBranch = .init(from: "root", messageID: "q2", turnID: "q2x")
        try await exchange(model, view, host, sent, snapshot([("q1", "user", nil), ("a1", "assistant", nil), ("q2", "user", nil),
                                                              ("a2", "assistant", nil), ("q3", "user", nil), ("a3", "assistant", nil)], lineage: "root"))
        XCTAssertNotNil(view.pendingBranch, "The edit is still expected")
        XCTAssertEqual(view.presentation.identity?.lineage, "root")
        var landed = snapshot([("q1", "user", nil), ("a1", "assistant", nil), ("b1", "system", "branch"), ("q2x", "user", nil)], lineage: "b1")
        landed["seq"] = .number(3); landed["displayRevision"] = .string("runtime:3")
        try await exchange(model, view, host, sent, landed)
        XCTAssertNil(view.newerPage.error, "The reader's own edit is never reported as a change")
        XCTAssertFalse(view.browsingHistory)
        XCTAssertEqual(view.messages.map(\.id), ["q1", "a1", "b1", "q2x"])
        XCTAssertNil(view.pendingBranch)
    }

    /// Editing the first question leaves nothing of the page before it: the
    /// new branch's window is the page.
    @MainActor func testAnEditOfTheFirstQuestionReplacesThePage() async throws {
        let (model, view, host, sent) = try await answeredChat()
        view.pendingBranch = .init(from: "root", messageID: "q1", turnID: "q1x")
        try await exchange(model, view, host, sent, snapshot([("b1", "system", "branch"), ("q1x", "user", nil), ("a1x", "assistant", nil)], lineage: "b1"))
        XCTAssertEqual(view.messages.map(\.id), ["b1", "q1x", "a1x"])
        XCTAssertFalse(view.browsingHistory); XCTAssertFalse(view.newerPage.available)
        XCTAssertNil(view.olderPage.cursor)
    }

    /// A branch nobody here asked for is still said, once, plainly, with
    /// the way back: Reload.
    @MainActor func testABranchNobodyAskedForIsStillReported() async throws {
        let (model, view, host, sent) = try await answeredChat()
        try await exchange(model, view, host, sent, snapshot([("b9", "system", "branch"), ("q9", "user", nil)], lineage: "b9"))
        XCTAssertEqual(view.newerPage.error, WorkspaceModel.branchChangedElsewhere)
        XCTAssertTrue(view.browsingHistory)
        XCTAssertEqual(TranscriptEdge.newer(view.newerPage, slow: false), .changed(WorkspaceModel.branchChangedElsewhere))
        XCTAssertEqual(view.messages.map(\.id), ["q1", "a1", "q2", "a2", "q3", "a3"], "The page the reader was reading stays")
    }
}
