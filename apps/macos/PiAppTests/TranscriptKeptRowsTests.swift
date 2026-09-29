import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A pane going back to a chat it showed a moment ago takes that chat's rows
/// back instead of building every row's tree again (`TranscriptKeptRows`).
/// One page and one document are bound to one chat after another, as the
/// conversation pane is when the reader switches chats.
final class TranscriptKeptRowsTests: XCTestCase {
    @MainActor private final class Pane {
        let page = TranscriptPage()
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow
        private(set) var current: SessionDisplay?

        init(width: CGFloat = 760, height: CGFloat = 440) {
            scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            scroll.borderType = .noBorder
            document = TranscriptNativeDocument(page: page)
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            // Where the reader is goes to the chat on screen, as the pane's does.
            page.onAnchorChanged = { [weak self] anchor in self?.current?.scrollAnchor = anchor }
        }

        /// The reader opens a chat: a new selection, as `select` makes it.
        func show(_ session: SessionDisplay) {
            session.presentationGeneration = UUID()
            current = session
            page.bind(session)
            refresh()
        }
        func refresh() {
            document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment(),
                            disclosure: page.disclosure, toolInputs: page.toolInputs)
            document.layoutRows(width: scroll.contentSize.width)
        }
        var rows: [TranscriptRowContainer] { document.retainedRows }
        var offset: CGFloat { scroll.contentView.bounds.minY }
        var bottom: CGFloat { max(0, document.frame.height - scroll.contentView.bounds.height) }
        func close() { window.contentView = nil; window.close() }

        /// A few consecutive passes that agree: deferred validation and the
        /// page's own placement have both run.
        func settle(file: StaticString = #filePath, line: UInt = #line, until ready: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var consecutive = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                consecutive = ready() ? consecutive + 1 : 0
                if consecutive >= 3 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The pane did not settle", file: file, line: line)
            throw NSError(domain: "TranscriptKeptRowsTests", code: 1)
        }
        /// The rows on screen, where they sit in the viewport.
        func visibleFrames() -> [String: CGRect] {
            let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
            var frames: [String: CGRect] = [:]
            for row in rows where row.superview === document && row.isHosted && row.frame.intersects(visible) {
                frames[row.itemID] = row.frame.offsetBy(dx: 0, dy: -visible.minY)
            }
            return frames
        }
        func showing(_ session: SessionDisplay) -> Bool {
            document.shownSessionID == session.id && rows.count == (page.snapshot?.items.count ?? -1) && !rows.isEmpty
        }
    }

    @MainActor private func chat(_ id: String, count: Int = 30) -> SessionDisplay {
        let session = SessionDisplay(id: id)
        session.messages = (0..<count).map { index in
            TranscriptMessage(id: "\(id)-m\(index)", role: "user",
                              text: "Question \(index). " + String(repeating: "Long enough to wrap when the reader narrows the conversation. ", count: 6))
        }
        return session
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { TranscriptKeptRows.admits = { _ in true } }
    }

    /// Going back to a chat takes back the very rows it had: nothing is built.
    @MainActor func testComingBackToAChatTakesItsRowsBack() async throws {
        let pane = Pane(); defer { pane.close() }
        let a = chat("back-a"), b = chat("back-b")
        pane.show(a)
        try await pane.settle { pane.showing(a) && abs(pane.offset - pane.bottom) < 0.5 }
        let identities = Dictionary(uniqueKeysWithValues: pane.rows.map { ($0.itemID, ObjectIdentifier($0)) })
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        XCTAssertEqual(pane.document.keptRows.sessionIDs, ["back-a"], "The chat the reader left keeps its rows")
        XCTAssertTrue(pane.document.keptRows.entries.allSatisfy { $0.rows.allSatisfy { $0.superview == nil } }, "Kept rows are out of the view tree")
        let built = pane.document.rowsBuiltCount
        pane.show(a)
        try await pane.settle { pane.showing(a) && abs(pane.offset - pane.bottom) < 0.5 }
        XCTAssertEqual(pane.document.rowsBuiltCount, built, "Going back built rows again")
        XCTAssertEqual(pane.document.rowsTakenBackCount, 30)
        for row in pane.rows { XCTAssertEqual(ObjectIdentifier(row), identities[row.itemID], "Row \(row.itemID) was made again") }
        XCTAssertEqual(pane.document.keptRows.sessionIDs, ["back-b"], "The chat on screen is not kept; the one left is")
    }

    /// A revisit lands where the reader left the chat and stays there: the
    /// rows taken back are placed at the heights they had, and neither their
    /// validation nor anything after it moves one.
    @MainActor func testARevisitStaysWhereItLands() async throws {
        let pane = Pane(); defer { pane.close() }
        let a = chat("steady-a", count: 40), b = chat("steady-b", count: 40)
        pane.show(a)
        try await pane.settle { pane.showing(a) && abs(pane.offset - pane.bottom) < 0.5 }
        let row = try XCTUnwrap(pane.page.rowFrame(of: "steady-a-m20"))
        pane.page.readerWillNavigate(upward: true)
        pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: row.minY + 9))
        pane.scroll.reflectScrolledClipView(pane.scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: pane.scroll)
        try await pane.settle { a.scrollAnchor?.followsBottom == false && a.scrollAnchor?.id == "steady-a-m20" }
        let left = pane.visibleFrames()
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        pane.show(a)
        // From the first pass that shows the reader's row where it was left,
        // nothing on screen moves or resizes.
        var landed: [String: CGRect]?
        var moves: [String] = []
        let until = ProcessInfo.processInfo.systemUptime + 1.2
        while ProcessInfo.processInfo.systemUptime < until {
            pane.scroll.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
            let frames = pane.visibleFrames()
            if let was = landed {
                for (id, frame) in frames { if let before = was[id], abs(before.minY - frame.minY) > 0.5 || abs(before.height - frame.height) > 0.5 {
                    moves.append("\(id) from \(before) to \(frame)")
                } }
                landed = frames
            } else if let at = frames["steady-a-m20"], let then = left["steady-a-m20"], abs(at.minY - then.minY) < 0.5 {
                landed = frames
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertNotNil(landed, "The chat never came back to where the reader left it")
        XCTAssertEqual(moves, [], "Rows moved after the revisit landed")
        for (id, frame) in left { if let now = landed?[id] { XCTAssertEqual(now.minY, frame.minY, accuracy: 0.5, "\(id) is not where it was left") } }
        XCTAssertGreaterThan(pane.document.rowsTakenBackCount, 0)
    }

    /// A chat that changed while the reader was away comes back as it is
    /// now: changed rows show their new content, new rows are built, rows
    /// that went are gone, and the unchanged ones are the rows it had.
    @MainActor func testAChatThatChangedWhileAwayShowsWhatItIsNow() async throws {
        let pane = Pane(); defer { pane.close() }
        let a = chat("changed-a", count: 12), b = chat("changed-b")
        pane.show(a)
        try await pane.settle { pane.showing(a) }
        let identities = Dictionary(uniqueKeysWithValues: pane.rows.map { ($0.itemID, ObjectIdentifier($0)) })
        let tall = try XCTUnwrap(pane.rows.first { $0.itemID == "changed-a-m2" }).frame.height
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        a.messages[2].text = "Changed while the reader was in another chat."
        a.messages.remove(at: 5)
        a.messages.append(TranscriptMessage(id: "changed-a-new1", role: "user", text: "Arrived while away."))
        a.messages.append(TranscriptMessage(id: "changed-a-new2", role: "user", text: "And another."))
        let built = pane.document.rowsBuiltCount
        pane.show(a)
        try await pane.settle { pane.showing(a) }
        XCTAssertEqual(pane.rows.map(\.itemID), a.messages.map(\.id), "The rows are the chat's rows as it is now")
        XCTAssertEqual(pane.document.rowsBuiltCount - built, 2, "Only the rows that arrived while away are built")
        XCTAssertFalse(pane.document.subviews.contains { ($0 as? TranscriptRowContainer)?.itemID == "changed-a-m5" }, "A row that went is not drawn")
        for row in pane.rows {
            guard case .message(let message) = row.contentItem else { return XCTFail("Unexpected row \(row.itemID)") }
            XCTAssertEqual(message.text, a.messages.first { $0.id == row.itemID }?.text, "Row \(row.itemID) shows stale content")
            if let was = identities[row.itemID] { XCTAssertEqual(ObjectIdentifier(row), was, "Unchanged row \(row.itemID) was made again") }
        }
        let changed = try XCTUnwrap(pane.rows.first { $0.itemID == "changed-a-m2" })
        try await pane.settle { changed.frame.height > 0 && changed.frame.height < tall - 10 }
    }

    /// Only the last chats the pane showed are kept, and the one left longest
    /// ago goes first; a chat no longer kept is built again.
    @MainActor func testOnlyTheLastChatsAreKept() async throws {
        let pane = Pane(); defer { pane.close() }
        let chats = (0..<5).map { chat("lru-\($0)", count: 8) }
        for session in chats {
            pane.show(session)
            try await pane.settle { pane.showing(session) }
        }
        XCTAssertEqual(TranscriptKeptRows.chatLimit, 3)
        XCTAssertEqual(pane.document.keptRows.sessionIDs, ["lru-1", "lru-2", "lru-3"], "The three chats left most recently are kept")
        let built = pane.document.rowsBuiltCount
        pane.show(chats[0])
        try await pane.settle { pane.showing(chats[0]) }
        XCTAssertEqual(pane.document.rowsBuiltCount - built, 8, "A chat no longer kept is built again")
        XCTAssertEqual(pane.document.keptRows.sessionIDs, ["lru-2", "lru-3", "lru-4"])
    }

    /// Kept rows hold what they draw and the chat's stores, never the chat's
    /// display: the workspace lets go of a display as it always did, and the
    /// rows kept for it go with it.
    @MainActor func testKeptRowsDoNotHoldTheirChat() async throws {
        let pane = Pane(); defer { pane.close() }
        let b = chat("hold-b")
        weak var left: SessionDisplay?
        do {
            let a = chat("hold-a")
            left = a
            pane.show(a)
            try await pane.settle { pane.showing(a) }
        }
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(pane.document.keptRows.sessionIDs, ["hold-a"])
        XCTAssertNil(left, "Kept rows hold the display of the chat they were kept for")
    }

    /// A chat whose reply is still arriving keeps nothing: its rows are live.
    @MainActor func testAChatStillRunningIsNotKept() async throws {
        let pane = Pane(); defer { pane.close() }
        let running = chat("running-a", count: 6), b = chat("running-b")
        running.messages.append(TranscriptMessage(id: "running-a-reply", role: "assistant", text: "Still arriving", state: "streaming"))
        pane.show(running)
        try await pane.settle { pane.showing(running) }
        XCTAssertFalse(TranscriptKeptRows.keeps(try XCTUnwrap(pane.page.snapshot), rows: pane.rows))
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [], "A running chat's rows are let go of, as before")
    }

    /// A chat whose display was let go of and made again has other stores
    /// (what the reader opened, the documents fetched): its old rows are not
    /// taken back, and are no longer kept.
    @MainActor func testAChatMadeAgainTakesNothingBack() async throws {
        let pane = Pane(); defer { pane.close() }
        let a = chat("again-a", count: 6), b = chat("again-b")
        pane.show(a)
        try await pane.settle { pane.showing(a) }
        let old = Set(pane.rows.map(ObjectIdentifier.init))
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        let remade = chat("again-a", count: 6)
        pane.show(remade)
        try await pane.settle { pane.showing(remade) }
        XCTAssertTrue(pane.rows.allSatisfy { !old.contains(ObjectIdentifier($0)) }, "Rows made with another display's stores came back")
        XCTAssertEqual(pane.document.rowsTakenBackCount, 0)
        XCTAssertEqual(pane.document.keptRows.sessionIDs, ["again-b"])
    }

    /// A chat comes back with nothing selected in it, as a revisit always has.
    @MainActor func testKeptRowsHoldNoSelection() async throws {
        let pane = Pane(); defer { pane.close() }
        let a = chat("select-a", count: 2), b = chat("select-b")
        a.messages.append(TranscriptMessage(id: "select-a-reply", role: "assistant", text: "A reply whose words the reader selects before leaving."))
        pane.show(a)
        try await pane.settle { pane.showing(a) }
        func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap { texts($0) } }
        let text = try XCTUnwrap(pane.rows.flatMap { texts($0) }.first { $0.string.contains("reader selects") })
        pane.window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 10))
        XCTAssertEqual(text.selectedRange().length, 10)
        pane.show(b)
        try await pane.settle { pane.showing(b) }
        XCTAssertEqual(text.selectedRange().length, 0, "A kept row still holds a selection")
        pane.show(a)
        try await pane.settle { pane.showing(a) }
        XCTAssertTrue(pane.rows.flatMap { texts($0) }.contains { $0 === text }, "The row's text came back")
        XCTAssertEqual(text.selectedRange().length, 0)
    }

    /// The workspace decides what may be kept: a chat whose display went, or
    /// that is archived, keeps nothing in any pane.
    @MainActor func testTheWorkspaceLetsGoOfAChatsRows() async throws {
        let root = scratchRoot("kept-rows-workspace")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        addTeardownBlock { @MainActor in TranscriptKeptRows.admits = { _ in true } }
        let a = chat("workspace-a", count: 6), b = chat("workspace-b", count: 6)
        model.displays = [a.id: a, b.id: b]
        model.chats = [ChatRecord(id: a.id, workspaceID: "project", title: "A", path: nil, profileID: "profile"),
                       ChatRecord(id: b.id, workspaceID: "project", title: "B", path: nil, profileID: "profile")]
        let pane = Pane(); defer { pane.close() }
        func leaveA() async throws {
            pane.show(a); try await pane.settle { pane.showing(a) }
            pane.show(b); try await pane.settle { pane.showing(b) }
        }
        a.state = "running"
        try await leaveA()
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [], "A chat left while it runs opens fresh when the reader comes back")
        a.state = "idle"
        try await leaveA()
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [a.id])
        model.displays.removeValue(forKey: a.id)
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [], "A chat whose display went keeps no rows")
        model.displays[a.id] = a
        try await leaveA()
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [a.id])
        model.chats[0].archivedAt = Date()
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [], "An archived chat keeps no rows")
        try await leaveA()
        XCTAssertEqual(pane.document.keptRows.sessionIDs, [], "Leaving an archived chat keeps nothing")
        model.chats.removeAll { $0.id == a.id }
        XCTAssertFalse(model.keepsTranscriptRows(a.id), "A deleted chat keeps nothing")
        model.shutdown()
    }
}
