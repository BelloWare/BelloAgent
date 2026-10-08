import XCTest
import AppKit
@testable import PiApp

/// ⌘F in an open chat: the find bar over the real pane counts matches in the
/// whole chat, loaded or not, steps to each — reading in the page of one the
/// window does not hold — marks them, and closes with Escape.
final class TranscriptFindTests: XCTestCase {
    @MainActor private func chat(turns: Int = 60) async throws -> LongChatScroll {
        let chat = try await LongChatScroll(turns: turns)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        return chat
    }
    @MainActor private func pane(_ chat: LongChatScroll) throws -> NativeTranscriptPane {
        try XCTUnwrap(LongChatScroll.views(NativeTranscriptPane.self, in: chat.pane).first)
    }
    /// The focused match is marked in the focus colour and stands on screen.
    @MainActor private func focusShown(_ chat: LongChatScroll, query: String) -> Bool {
        guard let document = chat.document, let text = document.focusText, !document.focusPending,
              let manager = text.layoutManager, let container = text.textContainer, let clip = chat.scroll?.contentView,
              document.focusRange.location != NSNotFound, NSMaxRange(document.focusRange) <= (text.textStorage?.length ?? 0) else { return false }
        let found = ((text.textStorage?.string ?? "") as NSString).substring(with: document.focusRange)
        let rect = text.convert(manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil), in: container), to: clip)
        let colour = manager.temporaryAttributes(atCharacterIndex: document.focusRange.location, effectiveRange: nil)[.backgroundColor] as? NSColor
        return found.lowercased() == query.lowercased() && clip.bounds.contains(CGPoint(x: clip.bounds.midX, y: rect.midY)) && colour == TranscriptHighlights.focusColor
    }

    @MainActor func testFindStepsThroughMatchesAcrossTheWholeChat() async throws {
        let chat = try await chat()
        let pane = try pane(chat)
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let bar = try XCTUnwrap(pane.findBar)
        XCTAssertTrue((chat.window.firstResponder as? NSView)?.isDescendant(of: bar) == true, "The field takes the keyboard")
        // "everything for question 1" closes the replies of questions 1 and 10–19: eleven
        // messages, nearly all far above the newest page the chat opened on.
        let query = "everything for question 1"
        XCTAssertFalse(chat.view.messages.contains { $0.id == "a1b" }, "The first match starts outside the window")
        bar.field.text = query; bar.field.onChange?(query)
        try await eventually("The search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching && pane.find.matches.count == 11 }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["a1b"] + (10...19).map { "a\($0)b" })
        try await eventually("The first match was never shown", timeout: .seconds(20)) { chat.draw(); return focusShown(chat, query: query) }
        XCTAssertEqual(bar.count.line.text, "1 of 11")
        // Next, then back past the first to the last.
        pane.find.step(1)
        try await eventually("Next never showed question 10's reply", timeout: .seconds(20)) {
            chat.draw(); return chat.document?.highlights.focus?.messageID == "a10b" && focusShown(chat, query: query)
        }
        XCTAssertEqual(bar.count.line.text, "2 of 11")
        pane.find.step(-1); pane.find.step(-1)
        try await eventually("Previous never wrapped to the last match", timeout: .seconds(20)) {
            chat.draw(); return chat.document?.highlights.focus?.messageID == "a19b" && focusShown(chat, query: query)
        }
        XCTAssertEqual(bar.count.line.text, "11 of 11")
        // Every match on screen is marked, not only the current one.
        bar.field.text = "parser"; bar.field.onChange?("parser")
        try await eventually("The second search never showed its match", timeout: .seconds(20)) {
            chat.draw(); return !pane.find.searching && focusShown(chat, query: "parser")
        }
        let document = try XCTUnwrap(chat.document)
        var marked = 0
        for row in document.retainedRows where row.superview != nil {
            for text in TranscriptNativeDocument.textViews(in: row) {
                for range in TranscriptNativeDocument.ranges(of: "parser", in: (text.textStorage?.string ?? "") as NSString)
                where !(text === document.focusText && range == document.focusRange) {
                    if text.layoutManager?.temporaryAttributes(atCharacterIndex: range.location, effectiveRange: nil)[.backgroundColor] as? NSColor == TranscriptHighlights.matchColor { marked += 1 }
                }
            }
        }
        XCTAssertGreaterThan(marked, 0, "The other matches on screen are marked too")
    }

    /// A match in a tool's output: the search names the result's record, the
    /// page draws it inside its call's card. The card opens and the match in
    /// it is marked and shown.
    @MainActor func testAMatchInAToolsOutputOpensItsCard() async throws {
        let chat = try await chat(turns: 20)
        let pane = try pane(chat)
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let bar = try XCTUnwrap(pane.findBar)
        // Only the grep outputs of turns 8 and 17 reach line 57.
        let query = "parse(input, at: 57)"
        bar.field.text = query; bar.field.onChange?(query)
        try await eventually("The search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching && !pane.find.matches.isEmpty }
        XCTAssertEqual(Set(pane.find.matches.map(\.messageID)), ["r8a", "r17a"])
        try await eventually("The match in the tool's output was never shown", timeout: .seconds(20)) { chat.draw(); return focusShown(chat, query: query) }
        // Marked where the page draws the output: the result's own row, or
        // the card of the reply that made the call.
        let marked = try XCTUnwrap(chat.document?.highlights.focus?.messageID)
        let record = pane.find.matches[pane.find.current ?? 0].messageID
        XCTAssertTrue(marked == record || marked == "a" + record.dropFirst(), "\(marked) does not draw \(record)")
    }

    /// A match in the middle of a long file a read returned, which its card
    /// keeps folded between the first and last lines: the card shows it.
    @MainActor func testAMatchInAReadCardsFoldedMiddleIsShown() async throws {
        let chat = try await chat(turns: 20)
        let pane = try pane(chat)
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let bar = try XCTUnwrap(pane.findBar)
        // Line 11 of the 124-line file turn 8 read; nothing else says it.
        let query = "value10 = compute(8, 10)"
        bar.field.text = query; bar.field.onChange?(query)
        try await eventually("The search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching && !pane.find.matches.isEmpty }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["r8b"])
        try await eventually("The match in the read card's middle was never shown", timeout: .seconds(20)) { chat.draw(); return focusShown(chat, query: query) }
    }

    /// ⇧⌘G is both Changes and History's and Find Previous's: with the
    /// focused chat's find bar closed it opens Changes and History, and while
    /// the bar is open it steps back through the matches. Offered as AppKit
    /// offers a key equivalent: the key window's views, then the real menus.
    @MainActor func testShiftCommandGIsFindPreviousOnlyWhileTheBarIsOpen() async throws {
        let chat = try await chat(turns: 20)
        let pane = try pane(chat)
        let previous = NSApp.mainMenu; defer { NSApp.mainMenu = previous }
        let window = chat.window
        let menus = ApplicationMenus(model: chat.model, updates: UpdateController(), workspaceWindow: { window }, revealWorkspace: {}, showSettings: {})
        menus.install()
        // The keys are offered to this window directly, as AppKit offers them
        // to the key one; it need not win the keyboard from other apps.
        window.makeKeyAndOrderFront(nil)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "G",
                                                 charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        func press() -> Bool { window.performKeyEquivalent(with: key) || (NSApp.mainMenu?.performKeyEquivalent(with: key) ?? false) }
        func changes() -> HostedTab? { chat.model.tabs.tab(kind: ChangesTab.kind, key: "project") }

        // No project to show changes of: ⇧⌘G does nothing, and never opens a
        // find bar that is not there.
        XCTAssertFalse(press(), "Changes and History is unavailable, and Find Previous with no find bar")
        XCTAssertNil(pane.findBar)

        // No find bar: Changes and History.
        chat.model.workspaces = [WorkspaceRecord(id: "project", path: chat.root.path, trusted: true)]
        XCTAssertTrue(press(), "Something takes ⇧⌘G")
        let tab = try XCTUnwrap(changes(), "⇧⌘G opens Changes and History while no find bar is open")
        XCTAssertNil(pane.findBar, "and does not open the find bar")
        chat.model.tabs.close(tab)
        XCTAssertNil(changes())

        // The bar open, on the first of eleven matches: back to the last.
        chat.model.findInFocusedConversation(.show, in: window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let bar = try XCTUnwrap(pane.findBar)
        let query = "everything for question 1"
        bar.field.text = query; bar.field.onChange?(query)
        try await eventually("The search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching && pane.find.matches.count == 11 }
        try await eventually("The first match was never shown", timeout: .seconds(20)) { chat.draw(); return focusShown(chat, query: query) }
        XCTAssertEqual(bar.count.line.text, "1 of 11")
        XCTAssertTrue(press())
        try await eventually("⇧⌘G never stepped back to the last match", timeout: .seconds(20)) {
            chat.draw(); return pane.find.current == 10 && chat.document?.highlights.focus?.messageID == "a19b" && focusShown(chat, query: query)
        }
        XCTAssertEqual(bar.count.line.text, "11 of 11")
        XCTAssertNil(changes(), "⇧⌘G with the find bar open does not open Changes and History")
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: bar) == true, "The keyboard stays in the find field")

        // The report over the chats, the bar still open beneath it: the keys
        // are Changes and History's, and the hidden matches stay where they were.
        chat.model.page = .report
        XCTAssertTrue(press())
        XCTAssertNotNil(changes(), "⇧⌘G over the report opens Changes and History")
        XCTAssertEqual(pane.find.current, 10, "and does not step through a find bar nobody sees")
        chat.model.tabs.close(try XCTUnwrap(changes()))
        chat.model.page = .chats

        // Closed again: Changes and History once more.
        try XCTUnwrap(bar.field.onCancel)()
        XCTAssertNil(pane.findBar)
        XCTAssertTrue(press())
        XCTAssertNotNil(changes(), "⇧⌘G opens Changes and History again once the bar is closed")
        XCTAssertNil(pane.findBar)
        withExtendedLifetime(menus) {}
    }

    @MainActor func testEscapeClosesTheBarAndClearsTheMarks() async throws {
        let chat = try await chat(turns: 20)
        let pane = try pane(chat)
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let bar = try XCTUnwrap(pane.findBar)
        bar.field.text = "parser"; bar.field.onChange?("parser")
        try await eventually("The search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching && !pane.find.matches.isEmpty }
        XCTAssertFalse(chat.document?.highlights.isEmpty ?? true)
        try XCTUnwrap(bar.field.onCancel)()
        XCTAssertNil(pane.findBar, "Escape closes the bar")
        XCTAssertTrue(chat.document?.highlights.isEmpty ?? false, "and the marks go with it")
        chat.draw()
        for row in chat.document?.retainedRows ?? [] where row.superview != nil {
            for text in TranscriptNativeDocument.textViews(in: row) where (text.textStorage?.length ?? 0) > 0 {
                var range = NSRange()
                let colour = text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, longestEffectiveRange: &range,
                                                                     in: NSRange(location: 0, length: text.textStorage!.length)) as? NSColor
                XCTAssertTrue(colour == nil && range.length == text.textStorage!.length, "No mark is left in the text")
            }
        }
    }

    @MainActor func testAQueryWithNoMatchesSaysSo() async throws {
        let chat = try await chat(turns: 10)
        let pane = try pane(chat)
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let bar = try XCTUnwrap(pane.findBar)
        bar.field.text = "zebra crossing"; bar.field.onChange?("zebra crossing")
        try await eventually("The search never finished", timeout: .seconds(20)) { chat.draw(); return !pane.find.searching }
        XCTAssertEqual(bar.count.line.text, "No matches")
        XCTAssertFalse(bar.next.isEnabled)
    }
}
