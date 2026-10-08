import XCTest
import AppKit
@testable import PiApp

/// `revealInTranscript`: a message brought into view in the real pane —
/// loaded or not — a place in it marked and shown, the newest of quick
/// requests winning, and a finished turn that folded the message opening.
final class TranscriptRevealTests: XCTestCase {
    @MainActor private func chat(turns: Int = 120) async throws -> LongChatScroll {
        let chat = try await LongChatScroll(turns: turns)
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
        try await eventually("The message never landed") {
            chat.draw(); return landing(chat, target).map { abs($0 - TranscriptReveal.landing) <= 1 } ?? false
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
