import XCTest
import AppKit
@testable import PiApp

// The queue panel beside a terminal and in a narrow split pane, reordering
// across its scroll, its detail view open while the message leaves, and
// image-only messages on the paths that take them.

extension ConversationPaneTests {
    @MainActor private func transcriptHeight(_ pane: Pane) throws -> CGFloat {
        try XCTUnwrap(Self.views(TranscriptSurfaceMarker.self, in: pane.hosted).first?.enclosingScrollView).frame.height
    }
    @MainActor private func queueList(_ pane: Pane) -> NSScrollView? {
        Self.views(NSScrollView.self, in: pane.hosted).first { $0 is QueueListScrollView }
    }
    @MainActor private func withTerminalHeight(_ height: Double, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "terminalHeight")
        defaults.set(height, forKey: "terminalHeight")
        defer { if let previous { defaults.set(previous, forKey: "terminalHeight") } else { defaults.removeObject(forKey: "terminalHeight") }; TerminalRegistry.shared.shutdown() }
        try await body()
    }

    /// At the 920×600 minimum window, with a tall draft, a terminal open
    /// (at its default height and dragged tall) and twenty messages waiting
    /// (paused: no run card), the composer's field and the terminal give way
    /// so the transcript keeps about 150 points; the queue keeps a reachable
    /// row and the window keeps its size. While a turn runs, its card takes
    /// about 100 points more (docs/Swift-Test-Handoff.md, "Minimum window").
    @MainActor func testATallDraftATerminalAndAQueueLeaveTheTranscriptItsReadingSpace() async throws {
        for stored in [240.0, 520.0] {
            try await withTerminalHeight(stored) {
                let pane = try Pane(width: 920, height: 600); defer { pane.close() }
                pane.model.terminalVisible = true
                pane.session.state = "paused"; pane.session.queuePaused = true
                pane.session.queue = (0..<20).map { ["turnId": .string("q\($0)"), "kind": .string("follow-up"), "text": .string("Message \($0)")] }
                pane.session.draft = (0..<20).map { "Line \($0) of a long draft" }.joined(separator: "\n")
                for _ in 0..<4 { await pane.settle(20); try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertEqual(pane.window.contentLayoutRect.height, 600, accuracy: 1, "the window keeps its size (terminal \(stored))")
                XCTAssertGreaterThanOrEqual(try transcriptHeight(pane), 145, "the transcript keeps its reading space (terminal \(stored))")
                let list = try XCTUnwrap(queueList(pane))
                XCTAssertGreaterThanOrEqual(list.frame.height, QueuePanel.rowHeight + QueuePanel.sectionHeaderHeight - 1, "a queued row stays reachable")
                let field = try XCTUnwrap(pane.editor?.enclosingScrollView)
                XCTAssertLessThanOrEqual(field.frame.height, ComposerScrollView.besideTerminalHeight + 1, "the field gives way beside a terminal")
                XCTAssertEqual(UserDefaults.standard.double(forKey: "terminalHeight"), stored, "the height the terminal was dragged to is kept")
            }
        }
        // Without a terminal the field keeps its full height.
        let pane = try Pane(width: 920, height: 600); defer { pane.close() }
        pane.session.draft = (0..<20).map { "Line \($0)" }.joined(separator: "\n")
        await pane.settle(30)
        XCTAssertGreaterThan(try XCTUnwrap(pane.editor?.enclosingScrollView).frame.height, ComposerScrollView.besideTerminalHeight + 20)
    }

    /// In a narrow split pane with a terminal open, the queue keeps every
    /// message reachable inside its panel, off the composer.
    @MainActor func testTheQueueInANarrowSplitPaneWithATerminal() async throws {
        try await withTerminalHeight(240) {
            let pane = try Pane(width: 460, height: 700); defer { pane.close() }
            pane.model.terminalVisible = true
            pane.session.state = "running"
            pane.session.queue = (0..<5).map { ["turnId": .string("q\($0)"), "kind": .string($0 == 0 ? "steering" : "follow-up"), "text": .string("Message \($0): " + String(repeating: "words ", count: 20))] }
            for _ in 0..<3 { await pane.settle(20); try await Task.sleep(for: .milliseconds(100)) }
            let list = try XCTUnwrap(queueList(pane))
            XCTAssertGreaterThanOrEqual(list.frame.height, QueuePanel.rowHeight + QueuePanel.sectionHeaderHeight - 1)
            let field = try XCTUnwrap(pane.editor?.enclosingScrollView)
            XCTAssertFalse(list.convert(list.bounds, to: nil).intersects(field.convert(field.bounds, to: nil)), "the queue never covers the composer")
            XCTAssertEqual(pane.window.contentLayoutRect.height, 700, accuracy: 1)
            list.documentView?.scroll(NSPoint(x: 0, y: list.documentView?.bounds.maxY ?? 0))
            await pane.settle(8)
            let table = try XCTUnwrap(Self.views(NSTableView.self, in: list).first)
            XCTAssertTrue(list.contentView.documentVisibleRect.intersects(table.rect(ofRow: table.numberOfRows - 1)), "the last message can be scrolled to")
        }
    }

    /// The first of twenty follow-ups dragged past the end of the scrolled
    /// list goes last. A message removed or delivered during the drag: the
    /// helper refuses the stale order, nothing moves, and the chat says so.
    @MainActor func testReorderingAcrossTheScrollAndAQueueThatChangesDuringTheDrag() async throws {
        let pane = try Pane(width: 920, height: 600); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = (0..<20).map { ["turnId": .string("q\($0)"), "kind": .string("follow-up"), "text": .string("Message \($0)")] }
        await pane.settle(16)
        let ids = QueuedMessage.from(pane.session.queue).map(\.id)
        let order = QueuePanel.reordered(ids, moving: IndexSet(integer: 0), to: ids.count)
        XCTAssertEqual(order.first, "q1"); XCTAssertEqual(order.last, "q0")
        pane.model.reorderQueued(order, sessionID: pane.session.id)
        try await waitFor("The reorder never landed") { QueuedMessage.from(pane.session.queue).map(\.id) == order }

        // The drag began with the order on screen; a message left meanwhile.
        let dragged = QueuePanel.reordered(QueuedMessage.from(pane.session.queue).map(\.id), moving: IndexSet(integer: 0), to: 20)
        pane.session.queue.removeAll { $0["turnId"]?.string == "q7" }
        let before = QueuedMessage.from(pane.session.queue).map(\.id)
        pane.model.reorderQueued(dragged, sessionID: pane.session.id)
        try await waitFor("The stale reorder was never refused") { pane.session.notice.contains("changed while you were dragging") }
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).map(\.id), before, "nothing moved")
    }

    /// Follow-ups are reordered by dragging their rows in the panel's own
    /// table: a row dropped below the last goes last; steering rows and the
    /// headings never move, and nothing is dragged while a message is edited.
    @MainActor func testDraggingAFollowUpRowReordersTheQueue() async throws {
        let pane = try Pane(width: 920, height: 700); defer { pane.close() }
        pane.session.state = "running"
        var queue: [[String: WireValue]] = [["turnId": .string("s"), "kind": .string("steering"), "text": .string("Steer")]]
        for index in 0..<3 { queue.append(["turnId": .string("q\(index)"), "kind": .string("follow-up"), "text": .string("Message \(index)")]) }
        pane.session.queue = queue
        await pane.settle(12)
        let table = try XCTUnwrap(Self.views(QueueTableView.self, in: pane.hosted).first)
        // The headings are headings to VoiceOver (`.isHeader`).
        XCTAssertEqual(table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityRole(), QueueHeadingView.headingRole)
        XCTAssertEqual(table.view(atColumn: 0, row: 2, makeIfNecessary: true)?.accessibilityLabel(), "Follow-ups · when this run finishes")
        try dropFirstFollowUpLast(table)
        try await waitFor("The drag never reordered the queue") { QueuedMessage.from(pane.session.queue).map(\.id) == ["s", "q1", "q2", "q0"] }
        NSPasteboard(name: .drag).clearContents()
        // While a message is edited the follow-ups stay where they are.
        pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("e"), "turnId": .string("q1")]), revision: 10)
        await pane.settle(6)
        noDragDuringAnEdit(table)
        // A message that leaves during the drag: the order the drag began
        // with goes to the helper, which refuses it; nothing moves.
        pane.session.adoptQueueEditHold(nil, revision: 11)
        await pane.settle(6)
        let item = try XCTUnwrap(table.tableView(table, pasteboardWriterForRow: 3) as? NSPasteboardItem)
        pane.session.queue.removeAll { $0["turnId"]?.string == "q2" }
        await pane.settle(6)
        let before = QueuedMessage.from(pane.session.queue).map(\.id)
        dropBelowTheLast(item, in: table)
        try await waitFor("The stale drop was never refused") { pane.session.notice.contains("changed while you were dragging") }
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).map(\.id), before, "nothing moved")
        NSPasteboard(name: .drag).clearContents()
    }
    @MainActor private func dropBelowTheLast(_ item: NSPasteboardItem, in table: QueueTableView) {
        let drag = DragInFlight(item); drag.source = table
        XCTAssertTrue(table.tableView(table, acceptDrop: drag, row: table.numberOfRows, dropOperation: .above))
    }
    /// The drag itself, outside the async test (AppKit's drop calls are synchronous).
    @MainActor private func dropFirstFollowUpLast(_ table: QueueTableView) throws {
        // Lines: steering heading, s, follow-ups heading, q0, q1, q2.
        XCTAssertEqual(table.numberOfRows, 6)
        XCTAssertNil(table.tableView(table, pasteboardWriterForRow: 1), "a steering row does not move")
        XCTAssertNil(table.tableView(table, pasteboardWriterForRow: 2), "nor a heading")
        let written = try XCTUnwrap(table.tableView(table, pasteboardWriterForRow: 3) as? NSPasteboardItem)
        let drag = DragInFlight(written); drag.source = table
        XCTAssertEqual(table.tableView(table, validateDrop: drag, proposedRow: 6, proposedDropOperation: .above), .move)
        // The same row's words, from a drag that began somewhere else.
        let copy = NSPasteboardItem(); copy.setString("q0", forType: QueueTableView.dragType)
        let foreign = DragInFlight(copy)
        XCTAssertEqual(table.tableView(table, validateDrop: foreign, proposedRow: 6, proposedDropOperation: .above), [], "only the panel's own rows")
        XCTAssertTrue(table.tableView(table, acceptDrop: drag, row: 6, dropOperation: .above))
    }
    @MainActor private func noDragDuringAnEdit(_ table: QueueTableView) {
        XCTAssertNil(table.tableView(table, pasteboardWriterForRow: 4), "nothing is dragged during an edit")
        let item = NSPasteboardItem(); item.setString("q0", forType: QueueTableView.dragType)
        let drag = DragInFlight(item); drag.source = table
        XCTAssertEqual(table.tableView(table, validateDrop: drag, proposedRow: 6, proposedDropOperation: .above), [])
    }

    /// In a narrow split pane the header's status never runs under Resume;
    /// it wraps only when its words do not fit before Resume (the gap there
    /// keeps just its minimum), and the panel grows to hold it. A short
    /// "Paused · 1" stays on one line where an equal share for the gap once
    /// broke it mid-word.
    @MainActor func testTheQueueHeaderWrapsOnlyWhenItsWordsDoNotFit() async throws {
        for (width, state, paused) in [(460.0, "error", false), (300.0, "error", false), (300.0, "paused", true)] {
            let pane = try Pane(width: width, height: 700); defer { pane.close() }
            pane.session.state = state; pane.session.queuePaused = paused
            // One follow-up: no "Drag to reorder" hint shares the room.
            pane.session.queue = [["turnId": .string("q0"), "kind": .string("follow-up"), "text": .string("Message 0")]]
            await pane.settle(12)
            let panel = try XCTUnwrap(Self.views(QueuePanelView.self, in: pane.hosted).first)
            let status = panel.status, resume = panel.resume, label = "\(state) at \(width)"
            XCTAssertFalse(resume.isHidden, label)
            XCTAssertLessThanOrEqual(status.frame.maxX, resume.frame.minX, "the status never runs under Resume (\(label))")
            XCTAssertGreaterThanOrEqual(status.frame.height, status.height(forWidth: status.frame.width) - 0.5, "it has the room its lines need (\(label))")
            // Between the status and Resume: two spacings and the gap's minimum.
            let room = resume.frame.minX - status.frame.minX - PiSpacing.sm * 2 - 8
            let wide = status.height(forWidth: status.naturalWidth)
            if status.naturalWidth <= room {
                XCTAssertEqual(status.frame.height, wide, accuracy: 0.5, "it fits, so it keeps one line (\(label): \(status.naturalWidth) in \(room))")
            } else {
                XCTAssertGreaterThan(status.frame.height, wide + 4, "it does not fit, so it wraps (\(label))")
            }
            if paused { XCTAssertLessThanOrEqual(status.naturalWidth, room, "\"Paused · 1\" fits beside Resume at \(width)") }
        }
    }

    /// The detail opened from its row: it shows the whole message; when the
    /// message leaves the queue while it is open, it says so, and nothing is
    /// edited or sent.
    @MainActor func testTheDetailOpenWhileItsMessageLeaves() async throws {
        let pane = try Pane(width: 1000, height: 700); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = [["turnId": .string("a"), "kind": .string("follow-up"), "text": .string("The whole message"), "thinkingLevel": .string("high")],
                              ["turnId": .string("b"), "kind": .string("follow-up"), "text": .string("Another")]]
        await pane.settle(12)
        pane.session.queueDetailID = "a"
        try await waitFor("The detail never opened") { NSApp.windows.contains { String(describing: Swift.type(of: $0)).contains("Popover") && $0.isVisible } }
        try await waitFor("The detail never showed its message") { pane.session.queueDetailShowing == "The whole message" }
        pane.session.queue.removeAll { $0["turnId"]?.string == "a" }
        try await waitFor("The detail never said the message left") { pane.session.queueDetailShowing == QueuedMessageDetailView.goneText }
        XCTAssertTrue(pane.edits.calls.isEmpty, "nothing was edited or held")
        XCTAssertEqual(pane.session.draft, "")
        // The last message leaving while its detail is open: still says so.
        pane.session.queueDetailID = "b"
        try await waitFor("The second detail never showed its message") { pane.session.queueDetailShowing == "Another" }
        pane.session.queue = []
        try await waitFor("The detail of the last message never said it left") { pane.session.queueDetailShowing == QueuedMessageDetailView.goneText }
        XCTAssertTrue(NSApp.windows.contains { String(describing: Swift.type(of: $0)).contains("Popover") && $0.isVisible }, "the detail stays open")
        pane.session.queueDetailID = nil
        try await waitFor("The detail never closed") { !NSApp.windows.contains { String(describing: Swift.type(of: $0)).contains("Popover") && $0.isVisible } }
        XCTAssertNil(pane.session.queueDetailShowing)
    }

    /// An image still being read when the reader moves to another chat goes
    /// to the chat it was chosen in, not the one now shown.
    @MainActor func testALateImageGoesToTheChatItWasChosenIn() async throws {
        let pane = try Pane(width: 900, height: 700, imageModel: true); defer { pane.close() }
        let other = SessionDisplay(id: "other"); pane.model.displays[other.id] = other
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: file)
        pane.model.attachImageFiles([file], sessionID: pane.session.id)
        // The reader moves on before the image is read.
        pane.model.selectedID = other.id; pane.model.selected = other; pane.model.focusedSessionID = other.id
        try await waitFor("The image never arrived") { pane.session.attachments.count == 1 }
        XCTAssertTrue(other.attachments.isEmpty, "the chat now shown does not get it")
        XCTAssertNil(pane.model.error)
    }
}

extension SendImmediacyTests {
    /// An earlier message edited to images alone is resent as them, with no
    /// text made up.
    @MainActor func testAHistoricalEditWithOnlyImages() async throws {
        let chat = try await ScriptedSendChat(messages: [TranscriptMessage(id: "u0", role: "user", text: "Earlier question", at: 1000, turn: "u0"),
                                                        TranscriptMessage(id: "a0", role: "assistant", text: "Earlier answer", at: 2000, turn: "u0")])
        var closed = false
        defer { if !closed { Task { await chat.close() } } }
        chat.session.editingMessageID = "u0"; chat.session.draftBeforeEdit = DraftRecord(id: chat.chat.id, text: "")
        chat.session.draft = ""
        chat.session.attachments = [AttachmentRecord(id: "img", path: "/tmp/fixture-image.png", sha256: "00", bytes: 10, mimeType: "image/png")]
        await chat.settle(4)
        chat.model.sendEdit(sessionID: chat.chat.id)
        await chat.until("The edit never reached the helper") { chat.frames(WorkspaceModel.editTurnMethod).count == 1 }
        let params = try XCTUnwrap(chat.frames(WorkspaceModel.editTurnMethod).first?["params"]?.object)
        XCTAssertEqual(params["text"]?.string, "", "no text is made up")
        XCTAssertEqual(params["attachments"]?.array?.count, 1)
        closed = true
        await chat.close()
    }

    /// A side's composer sends an image alone, on the same rule as its chat.
    @MainActor func testASideSendsAnImageOnlyMessage() async throws {
        let chat = try await ScriptedSendChat()
        var closed = false
        defer { if !closed { Task { await chat.close() } } }
        chat.model.sides["parent"] = SideRecord(id: chat.chat.id, parentID: "parent", workspaceID: chat.chat.workspaceID, profileID: chat.chat.profileID, title: "Side", kept: true)
        XCTAssertNotNil(chat.model.side(chat.chat.id))
        chat.session.attachments = [AttachmentRecord(id: "img", path: "/tmp/fixture-image.png", sha256: "00", bytes: 10, mimeType: "image/png")]
        await chat.settle(4)
        chat.key("\r", keyCode: 36)
        await chat.until("The side's image never reached the helper") { chat.frames("turn.submit").count == 1 }
        XCTAssertEqual(chat.frames("turn.submit").first?["params"]?.object?["text"]?.string, "")
        XCTAssertEqual(chat.session.sendingRows.first?.text, "Image")
        closed = true
        await chat.close()
    }
}
