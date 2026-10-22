import XCTest
import AppKit
@testable import PiApp

/// `revealInTranscript`: a message brought into view in the real pane —
/// loaded or not — a place in it marked and shown, the newest of quick
/// requests winning, and a finished turn that folded the message opening.
final class TranscriptRevealTests: XCTestCase {
    /// Reveals read the page around a message outside the window: these
    /// chats page three five-row turns at a time, as the 0.1.71 plan did
    /// (`usePlanPages`), so most of a chat is outside it.
    @MainActor override func setUp() async throws { installSidebarRevealHook(self); usePlanPages(rows: 15) }

    @MainActor func testFixtureOwnsInheritedHooks() async throws {
        try await checkSidebarRevealSetup(self) { try await self.setUp() }
    }

    @MainActor private func chat(turns: Int = 120, bigOutputTurn: Int? = nil) async throws -> LongChatScroll {
        let chat = try await LongChatScroll(turns: turns, bigOutputTurn: bigOutputTurn)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        return chat
    }
    @MainActor private func state(_ chat: LongChatScroll, _ id: String) -> String {
        let row = chat.document?.row(drawing: id)
        return "row \(row?.itemID ?? "-") mounted \(row?.superview != nil) top \(row.map { $0.frame.minY - chat.clipY } ?? -1) clip \(chat.clipY) highest \(chat.highest) rows \(chat.view.messages.first?.id ?? "-")…\(chat.view.messages.last?.id ?? "-") anchor \(String(describing: chat.view.scrollAnchor)) error \(chat.view.olderPage.error ?? "-")"
    }
    /// Whether row `id` has landed: `TranscriptReveal.landing` below the
    /// viewport's top, or as near it as the rows above allow — a page read
    /// around a message starts with it, so it can stand no lower than the
    /// page's top inset until earlier rows arrive, and the reader's place is
    /// then held, not moved.
    @MainActor private func landed(_ chat: LongChatScroll, _ id: String) -> Bool {
        guard let top = landing(chat, id) else { return false }
        return top >= TranscriptMetrics.pageTopInset - 1 && top <= CGFloat(TranscriptReveal.landing) + 1
    }
    /// Where row `id`'s first row stands below the viewport's top, once on screen.
    @MainActor private func landing(_ chat: LongChatScroll, _ id: String) -> CGFloat? {
        guard let row = chat.document?.row(drawing: id), row.superview != nil else { return nil }
        return row.frame.minY - chat.clipY
    }

    @MainActor func testAFailedMarkedRevealCannotReturnWhenAnOrdinaryPageLoadsItsMessage() async throws {
        let chat = try await chat(turns: 40)
        chat.view.presentation.olderTask?.cancel(); chat.view.presentation.newerTask?.cancel()
        try await eventually("Edge reads stopped") { !chat.view.olderPage.loading && !chat.view.newerPage.loading }
        let target = "a1b", reader = chat.model.history, path = try XCTUnwrap(chat.chat.path)
        let source = try await reader.window(path: path, around: target)
        let message = try XCTUnwrap(try ConversationHistoryPage(source).messages.first { $0.id == target })
        XCTAssertFalse(chat.view.messages.contains { $0.id == target })
        chat.model.historyWindowLoader = { _, cursor, newer, around in
            if around == target { throw HostError.failure("Temporary fixture failure") }
            return try ConversationHistoryPage(await reader.window(path: path, cursor: cursor, newer: newer, around: around))
        }
        let shown = await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: target,
                                                       mark: .range((message.text as NSString).range(of: "parser")))
        XCTAssertFalse(shown)
        XCTAssertNotNil(chat.view.revealFailure)
        XCTAssertNil(chat.view.revealRead)
        XCTAssertNil(chat.view.reveal, "A failed marked request must end with its read")
        // The Back to bottom action abandons a reveal before following the
        // latest row; ordinary paging must never revive the failed mark.
        chat.view.abandonReveal()
        try XCTUnwrap(chat.page).jumpToLatest()
        for _ in 0..<12 where !chat.view.messages.contains(where: { $0.id == target }) {
            guard await chat.model.loadEarlierPage(sessionID: chat.chat.id) else { break }
            chat.draw()
        }
        XCTAssertTrue(chat.view.messages.contains { $0.id == target }, "An ordinary history read loads the old target")
        let document = try XCTUnwrap(chat.document)
        try await eventually("The ordinary page was not presented") { chat.draw(); return document.row(drawing: target) != nil }
        for _ in 0..<10 { chat.draw(); try await Task.sleep(for: .milliseconds(16)) }
        XCTAssertNil(document.highlights.focus, "The failed reveal must not mark or scroll to a message that arrives later")
        XCTAssertEqual(chat.clipY, chat.highest, accuracy: 1, "The reader remains at the bottom they chose")
    }

    @MainActor func testNavigationAfterAMarkedReadFinishesCancelsItsQueuedMark() async throws {
        for end in [false, true] {
            let chat = try await chat(turns: 40)
            let pane = try XCTUnwrap(LongChatScroll.views(NativeTranscriptPane.self, in: chat.pane).first)
            chat.view.presentation.olderTask?.cancel(); chat.view.presentation.newerTask?.cancel()
            try await eventually("Edge reads stopped") { !chat.view.olderPage.loading && !chat.view.newerPage.loading }
            XCTAssertFalse(chat.view.messages.contains { $0.id == "a1b" })
            let shown = await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a1b",
                mark: .excerpt("The parser in module 1", highlight: NSRange(location: 4, length: 6)))
            XCTAssertTrue(shown)
            XCTAssertNil(chat.view.revealRead, "The history read has finished")
            XCTAssertNotNil(chat.view.reveal, "Its mark is still waiting for presentation")
            XCTAssertNil(pane.document.highlights.focus, "The queued pane refresh has not consumed the mark")
            // Do not yield between completing the read and the newer input.
            // Both the gesture path and End must cancel the unpresented mark.
            if end { pane.scrollView.scrollToEndOfDocument(nil) }
            else { chat.gestureStep(80) }
            XCTAssertNil(chat.view.reveal, end ? "End cancels the queued mark" : "Scrolling cancels the queued mark")
            pane.refresh()
            XCTAssertNil(pane.document.highlights.focus, "A queued refresh must not revive the cancelled mark")
            XCTAssertFalse(pane.document.focusPending, "The earlier reveal must not reclaim scrolling")
            if end {
                try await eventually("End never reached the latest page") {
                    chat.draw(); return chat.view.historyState == .ready && !chat.view.browsingHistory && !pane.page.landingPending
                }
                XCTAssertEqual(chat.clipY, chat.highest, accuracy: 1, "The reader stays at the end they chose")
            }
            chat.close()
        }
    }

    @MainActor func testRevealAndHomeOfferReloadWhenTheJournalWasReplaced() async throws {
        for home in [false, true] {
            let chat = try await chat()
            chat.view.presentation.olderTask?.cancel(); chat.view.presentation.newerTask?.cancel()
            try await eventually("Edge reads stopped") { !chat.view.olderPage.loading && !chat.view.newerPage.loading }
            let before = chat.view.messages, source = chat.view.presentation.identity?.incarnation
            XCTAssertFalse(before.contains { $0.id == "a1b" })
            let path = try XCTUnwrap(chat.chat.path)
            // All message IDs survive; the source file's identity does not.
            try LongChatScroll.journal(turns: 120).write(to: URL(fileURLWithPath: path), options: .atomic)
            let shown = home ? await chat.model.revealStartOfChat(sessionID: chat.chat.id)
                : await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a1b")
            XCTAssertFalse(shown, home ? "Home" : "Reveal")
            XCTAssertEqual(chat.view.messages.map(\.id), before.map(\.id), "The held window stays readable until Reload")
            XCTAssertEqual(chat.view.presentation.identity?.incarnation, source)
            XCTAssertEqual(chat.view.newerPage.error, WorkspaceModel.branchChangedElsewhere)
            chat.close()
        }
    }

    @MainActor func testRevealAndHomeValidateTheHelperBoundaryDuringJournalHandoff() async throws {
        let chat = try await chat(turns: 30)
        let lineage = try XCTUnwrap(chat.view.presentation.identity?.lineage)
        for start in [false, true] {
            do {
                _ = try await chat.model.readConversationWindow(chat.chat, cursor: nil, around: start ? nil : "a1b", start: start,
                    validating: ConversationCursor(incarnation: "helper:fixture", lineage: lineage, entry: "missing"))
                XCTFail("A missing handoff boundary must offer Reload")
            } catch { XCTAssertTrue(WorkspaceModel.isSourceChange(error), "\(error)") }
        }
    }

    @MainActor func testRevealingAMessageOutsideTheWindowReadsItInAndLandsOnIt() async throws {
        let chat = try await chat()
        XCTAssertFalse(chat.view.messages.contains { $0.id == "a10b" }, "The message starts outside the window")
        let revealed = await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a10b")
        XCTAssertTrue(revealed)
        do {
            try await eventually("The message never landed", timeout: .seconds(20)) {
                chat.draw(); return landed(chat, "a10b")
            }
        } catch { print("REVEALDBG " + state(chat, "a10b")); throw error }
        // It stays there while earlier pages arrive and the rows around it measure.
        let place = try XCTUnwrap(landing(chat, "a10b"))
        for _ in 0..<40 {
            chat.draw(); try await Task.sleep(for: .milliseconds(16))
            XCTAssertEqual(try XCTUnwrap(landing(chat, "a10b")), place, accuracy: 1, "The revealed message moved")
        }
        XCTAssertNotNil(chat.view.olderPage.cursor, "The window grows from there both ways")
        XCTAssertNotNil(chat.view.newerPage.cursor)
    }

    @MainActor func testRevealingAMessageInTheWindowLandsOnIt() async throws {
        let chat = try await chat()
        // A question in the middle of a window of several pages, with rows
        // above and below it to land it exactly.
        for _ in 0..<3 { _ = await chat.model.loadEarlierPage(sessionID: chat.chat.id) }
        let questions = chat.view.messages.filter { $0.role == "user" }
        let target = questions[questions.count / 2].id
        let revealed = await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: target)
        XCTAssertTrue(revealed)
        do {
            try await eventually("The message never landed") {
                chat.draw(); return landing(chat, target).map { abs($0 - TranscriptReveal.landing) <= 1 } ?? false
            }
        } catch {
            // Where it stood instead, and whether the page still had the row, says which step missed.
            XCTFail("landing=\(String(describing: landing(chat, target))) expected=\(TranscriptReveal.landing) scrollY=\(chat.scroll?.contentView.bounds.minY ?? -1) " +
                    "documentHeight=\(chat.document?.frame.height ?? -1) messages=\(chat.view.messages.count) hasTarget=\(chat.view.messages.contains { $0.id == target })")
            throw error
        }
    }

    /// A search result's excerpt names which of the message's occurrences it
    /// shows; that one is marked and brought into view.
    @MainActor func testAnExcerptMarksItsOwnOccurrence() async throws {
        let chat = try await chat()
        // a30b has three findings; each says "The parser in module 13".
        let excerpt = "…## Finding 30.2 The parser in module 13 reads the token stream"
        let highlight = (excerpt as NSString).range(of: "parser")
        let revealed = await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a30b", mark: .excerpt(excerpt, highlight: highlight))
        XCTAssertTrue(revealed)
        let document = try XCTUnwrap(chat.document)
        try await eventually("The mark never resolved", timeout: .seconds(20)) { chat.draw(); return document.focusText != nil && !document.focusPending }
        XCTAssertEqual(document.highlights.focus?.occurrence, 2, "The third finding's occurrence")
        let text = try XCTUnwrap(document.focusText)
        XCTAssertEqual(((text.textStorage?.string ?? "") as NSString).substring(with: document.focusRange).lowercased(), "parser")
        let clip = try XCTUnwrap(chat.scroll?.contentView)
        let rect = text.convert(try XCTUnwrap(text.layoutManager).boundingRect(forGlyphRange: text.layoutManager!.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil), in: text.textContainer!), to: clip)
        XCTAssertTrue(clip.bounds.insetBy(dx: 0, dy: 20).contains(CGPoint(x: clip.bounds.midX, y: rect.midY)), "The marked place is on screen")
        // It is drawn in the focus colour.
        let attributes = text.layoutManager?.temporaryAttributes(atCharacterIndex: document.focusRange.location, effectiveRange: nil)
        XCTAssertEqual(attributes?[.backgroundColor] as? NSColor, TranscriptHighlights.focusColor)
    }

    @MainActor func testTheNewestOfTwoQuickRevealsWins() async throws {
        let chat = try await chat()
        // The first reveal's read comes back last: an earlier request landing
        // late must not take the reader away from the newer one.
        let reader = chat.model.history, path = try XCTUnwrap(chat.chat.path)
        chat.model.historyWindowLoader = { _, cursor, newer, around in
            if around == "a10b" { try await Task.sleep(for: .milliseconds(400)) }
            let start = around == HistoryWindowEdge.start
            return try ConversationHistoryPage(await reader.window(path: path, cursor: cursor, newer: newer, around: start ? nil : around, start: start))
        }
        let first = Task { await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a10b") }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a60b") }
        let outcomes = await (first.value, second.value)
        XCTAssertFalse(outcomes.0, "The superseded reveal reports it did not land")
        XCTAssertTrue(outcomes.1)
        do {
            try await eventually("The newest reveal never landed", timeout: .seconds(20)) {
                chat.draw(); return landed(chat, "a60b")
            }
        } catch { print("REVEALDBG " + state(chat, "a60b")); throw error }
        for _ in 0..<30 { chat.draw(); try await Task.sleep(for: .milliseconds(16)) }
        XCTAssertTrue(landed(chat, "a60b"), "An earlier reveal landing late must not take the reader away")
        XCTAssertFalse(chat.view.messages.contains { $0.id == "a10b" }, "The superseded read was never adopted")
    }

    /// A sidebar search match in a tool's output, after a result of the same
    /// reply too large to share a page with it: the hit names the result's
    /// own row, so the page read for it holds the match, which is marked and
    /// shown — not the reply, whose page ends before that result.
    @MainActor func testASidebarMatchInAToolOutputPastALargeOneIsShown() async throws {
        let chat = try await chat(turns: 40, bigOutputTurn: 10)
        let folder = chat.root.appendingPathComponent("search")
        let url = folder.appendingPathComponent(ChatSearchDatabase.fileName)
        let index = ChatSearchIndex(url: url, indexDirectory: folder), query = ChatSearchQuery(url: url)
        _ = await index.reconcile([ChatSearchSource(id: chat.chat.id, path: try XCTUnwrap(chat.chat.path))])
        let hits = try await query.search("zephyr checkpoint")
        let hit = try XCTUnwrap(hits[chat.chat.id])
        await index.close()
        XCTAssertEqual(hit.kind, .toolOutput)
        XCTAssertEqual(hit.messageID, "r10b", "The result's own row")
        XCTAssertFalse(chat.view.messages.contains { $0.id == hit.messageID }, "The match starts outside the window")
        await SidebarSearchReveal.reveal(chat.model, chatID: chat.chat.id, messageID: hit.messageID, mark: .excerpt(hit.excerpt, highlight: hit.highlight))
        let document = try XCTUnwrap(chat.document)
        func shown() -> Bool {
            guard let text = document.focusText, !document.focusPending, let manager = text.layoutManager, let container = text.textContainer,
                  let clip = chat.scroll?.contentView, NSMaxRange(document.focusRange) <= (text.textStorage?.length ?? 0), document.focusRange.length > 0 else { return false }
            let found = ((text.textStorage?.string ?? "") as NSString).substring(with: document.focusRange).lowercased()
            let rect = text.convert(manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil), in: container), to: clip)
            return found == "zephyr checkpoint" && clip.bounds.contains(CGPoint(x: clip.bounds.midX, y: rect.midY))
        }
        do {
            try await eventually("The match in the second output was never marked and shown", timeout: .seconds(20)) { chat.draw(); return shown() }
        } catch { print("REVEALDBG " + state(chat, hit.messageID)); throw error }
    }

    /// A sidebar Full chats match opened while ⌘F stays open: the page read
    /// in for it, and a reply landing in the journal past that page, change
    /// what the chat presents, and Find counts its query again once that
    /// settles — keeping the sidebar's mark and the place it brought into view.
    @MainActor func testASidebarMatchKeepsItsMarkThroughFindsRecount() async throws {
        let chat = try await chat(turns: 60)
        let pane = try XCTUnwrap(LongChatScroll.views(NativeTranscriptPane.self, in: chat.pane).first)
        let document = try XCTUnwrap(chat.document), clip = try XCTUnwrap(chat.scroll?.contentView)
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let search = try XCTUnwrap(pane.find.search)
        var searches = 0
        pane.find.search = { id, query, start in searches += 1; return try await search(id, query, start) }
        pane.findBar?.field.text = "quokka"; pane.find.setQuery("quokka")
        try await eventually("The zero-hit search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching }
        XCTAssertEqual(pane.findBar?.count.line.text, "No matches")
        let counted = searches
        // a30b's second finding, far above the window, as the sidebar's results show it.
        let excerpt = "…## Finding 30.2 The parser in module 13 reads the token stream"
        XCTAssertFalse(chat.view.messages.contains { $0.id == "a30b" }, "The match starts outside the window")
        await SidebarSearchReveal.reveal(chat.model, chatID: chat.chat.id, messageID: "a30b",
                                         mark: .excerpt(excerpt, highlight: (excerpt as NSString).range(of: "parser")))
        func marked() -> Bool {
            guard let text = document.focusText, !document.focusPending, document.highlights.focus?.fromFind == false,
                  let manager = text.layoutManager, let container = text.textContainer, document.focusRange.location != NSNotFound,
                  NSMaxRange(document.focusRange) <= (text.textStorage?.length ?? 0) else { return false }
            let found = ((text.textStorage?.string ?? "") as NSString).substring(with: document.focusRange).lowercased()
            let rect = text.convert(manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil), in: container), to: clip)
            let colour = manager.temporaryAttributes(atCharacterIndex: document.focusRange.location, effectiveRange: nil)[.backgroundColor] as? NSColor
            return found == "parser" && clip.bounds.contains(CGPoint(x: clip.bounds.midX, y: rect.midY)) && colour == TranscriptHighlights.focusColor
        }
        /// Where the mark stands below the viewport's top.
        func markTop() -> CGFloat? {
            guard let text = document.focusText, let manager = text.layoutManager, let container = text.textContainer,
                  document.focusRange.location != NSNotFound, NSMaxRange(document.focusRange) <= (text.textStorage?.length ?? 0) else { return nil }
            let glyphs = manager.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil)
            return text.convert(manager.boundingRect(forGlyphRange: glyphs, in: container), to: clip).minY - clip.bounds.minY
        }
        do {
            try await eventually("The sidebar's match was never marked and shown", timeout: .seconds(20)) { chat.draw(); return marked() }
        } catch { print("REVEALDBG " + state(chat, "a30b")); throw error }
        for _ in 0..<20 { chat.draw(); try await Task.sleep(for: .milliseconds(16)) }
        let mark = try XCTUnwrap(document.highlights.focus), place = try XCTUnwrap(markTop())
        // A reply lands in the journal past the page, as a run's rows do while
        // the reader is in earlier history, and the chat's presentation moves.
        let record: [String: WireValue] = ["type": .string("message"), "id": .string("late-quokka"), "parentId": .string(chat.lastID),
                                           "message": .object(["role": .string("assistant"), "content": .string("A quokka arrived.")])]
        let journal = try FileHandle(forWritingTo: URL(fileURLWithPath: try XCTUnwrap(chat.chat.path)))
        try journal.seekToEnd(); try journal.write(contentsOf: try JSONEncoder().encode(record) + Data([10])); try journal.close()
        chat.view.presentationChanges.send(chat.view.presentationChanges.value)
        try await eventually("Find never counted again", timeout: .seconds(20)) {
            chat.draw(); return searches > counted && !pane.find.searching && pane.find.matches.count == 1
        }
        for _ in 0..<10 { chat.draw(); try await Task.sleep(for: .milliseconds(16)) }
        XCTAssertEqual(pane.findBar?.count.line.text, "1 of 1", "The count follows the chat")
        XCTAssertEqual(document.highlights.focus, mark, "The recount keeps the sidebar's mark, requesting nothing")
        XCTAssertTrue(marked(), "The mark stays drawn, on screen")
        XCTAssertEqual(try XCTUnwrap(markTop()), place, accuracy: 1, "The place the sidebar brought into view stays")
    }

    /// A finished turn folds its work behind one line; revealing a message in
    /// that work opens the turn.
    @MainActor func testAMessageInAFoldedTurnOpensIt() async throws {
        let mode = TranscriptDisplay.mode
        TranscriptDisplay.use(.compact)
        addTeardownBlock { @MainActor in TranscriptDisplay.use(mode) }
        let chat = try await chat(turns: 40)
        let page = try XCTUnwrap(chat.page)
        let item = try XCTUnwrap(page.snapshot?.items.first { $0.messageIDs.contains("a38a") }, "The work of a finished turn on the page")
        let group: String? = { switch item { case .message(let m): return m.foldGroup; case .block(let b): return b.foldGroup } }()
        let fold = try XCTUnwrap(group, "The finished turn's work is folded")
        XCTAssertFalse(try XCTUnwrap(page.disclosure).isOpen(.turnFold(fold)))
        let text = "I'll look at the module and its tests first." as NSString
        let revealed = await chat.model.revealInTranscript(sessionID: chat.chat.id, messageID: "a38a", mark: .range(text.range(of: "its tests")))
        XCTAssertTrue(revealed)
        try await eventually("The folded turn never opened") { chat.draw(); return page.disclosure?.isOpen(.turnFold(fold)) == true }
        try await eventually("The mark never resolved", timeout: .seconds(20)) { chat.draw(); return chat.document?.focusText != nil }
    }
}
