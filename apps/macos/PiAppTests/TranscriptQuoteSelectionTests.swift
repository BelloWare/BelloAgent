import XCTest
import SwiftUI
@testable import PiApp

final class TranscriptQuoteSelectionTests: XCTestCase {
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
    @MainActor private func model() throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("quote-side-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        let chat = ChatRecord(id: "parent", workspaceID: "project", title: "Source", path: nil, profileID: "p",
                              model: "selected-model", thinkingLevel: "high", contextWindow: 64000, maxOutputTokens: 8000)
        let display = SessionDisplay(id: chat.id)
        display.draft = "Unsent parent question"
        display.messages = [TranscriptMessage(id: "u", role: "user", text: "Question"),
                            TranscriptMessage(id: "a", role: "assistant", text: "A precise answer with 中文🙂 and repeated answer.")]
        model.chats = [chat]; model.displays[chat.id] = display; model.selectedID = chat.id; model.selected = display
        return model
    }

    @MainActor func testNativeSelectionPopoverOpensQuotedUnsentSideWithoutChangingParent() async throws {
        let model = try model(), parent = try XCTUnwrap(model.selected)
        let stage = TranscriptStreamingStressTests.Stage(parent)
        defer { stage.close() }
        stage.actions.quoteReply = { model.openQuotedSide(parentID: parent.id, quote: $0) }
        stage.refresh(); await stage.settle()
        let editor = try answer(in: stage)
        let range = (editor.string as NSString).range(of: "中文🙂 and repeated answer")
        editor.setSelectedRange(range)
        let before = stage.document.frame.height
        // The production monitor reads selection after native keyboard input;
        // it must not rely on a caller manually opening the popover.
        let key = try XCTUnwrap(NSEvent.keyEvent(with:.keyUp, location:.zero, modifierFlags:.shift, timestamp:0,
            windowNumber:stage.window.windowNumber, context:nil, characters:"", charactersIgnoringModifiers:"", isARepeat:false, keyCode:124))
        NSApp.postEvent(key, atStart:false)
        await stage.settle(turns:12)
        let bar = try XCTUnwrap(stage.document.quoteSelection.bar)
        XCTAssertTrue(bar.isVisible)
        XCTAssertEqual(stage.document.quoteSelection.selectedQuote, TranscriptQuote(messageID: "a", text: "中文🙂 and repeated answer"))
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertEqual(stage.document.frame.height, before, accuracy: 0.5)
        let button = try XCTUnwrap(views(NSButton.self, in: try XCTUnwrap(bar.contentView)).first { $0.accessibilityIdentifier() == "quoteInSideChat" })
        XCTAssertEqual(button.accessibilityLabel(), "Ask in side chat")
        button.performClick(nil)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        XCTAssertTrue(side.pending); XCTAssertEqual(view.draft, "> 中文🙂 and repeated answer\n\n")
        XCTAssertEqual(model.focusedSessionID, side.id); XCTAssertGreaterThan(view.composerFocusRequest, 0)
        XCTAssertEqual(side.model, "selected-model"); XCTAssertEqual(side.thinkingLevel, "high")
        XCTAssertEqual(parent.draft, "Unsent parent question"); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertFalse(view.directCommand); XCTAssertTrue(view.queue.isEmpty)
        XCTAssertNil(stage.document.quoteSelection.bar)
    }

    @MainActor func testUserSelectionEmptyRangeAndSessionSwitchNeverQuote() async throws {
        let model = try model(), parent = try XCTUnwrap(model.selected)
        let stage = TranscriptStreamingStressTests.Stage(parent); defer { stage.close() }
        var emitted: [TranscriptQuote] = []
        stage.actions.quoteReply = { emitted.append($0) }; stage.refresh(); await stage.settle()
        let user = try XCTUnwrap(views(NSTextField.self, in: stage.document).first { $0.isSelectable && $0.stringValue == "Question" })
        user.selectText(nil); stage.document.quoteSelection.presentSelection()
        XCTAssertNil(stage.document.quoteSelection.bar)
        let editor = try answer(in: stage)
        editor.setSelectedRange(NSRange(location: 0, length: 0)); stage.document.quoteSelection.presentSelection()
        XCTAssertNil(stage.document.quoteSelection.bar)
        editor.setSelectedRange(NSRange(location: 0, length: 8)); stage.document.quoteSelection.presentSelection()
        XCTAssertTrue(stage.document.quoteSelection.bar?.isVisible == true)
        let next = SessionDisplay(id: "another"); next.messages = parent.messages
        stage.show(next); await stage.settle()
        XCTAssertNil(stage.document.quoteSelection.bar)
        stage.document.quoteSelection.askInSideChat(); XCTAssertTrue(emitted.isEmpty)
    }

    /// The answer's text, one selectable text, holding the keyboard.
    @MainActor private func answer(in stage: TranscriptStreamingStressTests.Stage) throws -> MarkdownTextView {
        let text = try XCTUnwrap(views(MarkdownTextView.self, in: stage.document).first { $0.string.contains("A precise answer") })
        stage.window.makeFirstResponder(text)
        return text
    }
    /// A selection in an answer, on screen, and the rectangle it covers.
    @MainActor private func selected(_ phrase: String, in stage: TranscriptStreamingStressTests.Stage) throws -> (editor: NSTextView, selection: NSRect, firstLine: NSRect) {
        let editor = try answer(in: stage)
        let range = (editor.string as NSString).range(of: phrase)
        editor.setSelectedRange(range)
        var actual = NSRange(location: NSNotFound, length: 0)
        let first = editor.firstRect(forCharacterRange: range, actualRange: &actual)
        var all = first, rest = NSRange(location: NSMaxRange(actual), length: NSMaxRange(range) - NSMaxRange(actual))
        while rest.length > 0 {
            let line = editor.firstRect(forCharacterRange: rest, actualRange: &actual)
            guard actual.length > 0 else { break }
            all = all.union(line); rest = NSRange(location: NSMaxRange(actual), length: NSMaxRange(range) - NSMaxRange(actual))
        }
        return (editor, all, first)
    }
    @MainActor private func key(_ code: UInt16, _ characters: String, in stage: TranscriptStreamingStressTests.Stage) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: stage.window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
    }

    /// The bar a selection shows is the app's own: its surface, one action, no
    /// stock button bezel and no system popover material. It stands just
    /// above the selection's first line, centred on the selection, never over
    /// it; Return asks with the quote, and Escape dismisses.
    @MainActor func testTheSelectionBarIsTheAppsOwnAndReturnAsks() async throws {
        let model = try model(), parent = try XCTUnwrap(model.selected)
        let stage = TranscriptStreamingStressTests.Stage(parent)
        defer { stage.close() }
        stage.actions.quoteReply = { model.openQuotedSide(parentID: parent.id, quote: $0) }
        stage.refresh(); await stage.settle()
        let (_, selection, firstLine) = try selected("precise answer", in: stage)
        stage.document.quoteSelection.presentSelection()
        let bar = try XCTUnwrap(stage.document.quoteSelection.bar)
        let content = try XCTUnwrap(bar.contentView)
        XCTAssertTrue(bar.isVisible)
        let buttons = views(NSButton.self, in: content)
        XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() }, ["quoteInSideChat"], "One action")
        XCTAssertTrue(buttons.allSatisfy { !$0.isBordered }, "No stock button bezel")
        XCTAssertTrue(views(NSVisualEffectView.self, in: content).isEmpty, "No system popover material")
        XCTAssertFalse(bar.barFrame.intersects(selection), "The bar \(bar.barFrame) covers the selection \(selection)")
        XCTAssertGreaterThanOrEqual(bar.barFrame.minY, firstLine.maxY, "It stands above the selection's first line")
        // Centred on the selection, unless that would take it out of the conversation on screen.
        let pane = stage.window.convertToScreen(stage.document.convert(stage.document.visibleRect, to: nil))
        XCTAssertTrue(pane.contains(bar.barFrame), "The bar \(bar.barFrame) stays inside the conversation \(pane)")
        let centred = abs(bar.barFrame.midX - selection.midX) <= 1
        let held = abs(bar.barFrame.minX - (pane.minX + 8)) <= 1 || abs(bar.barFrame.maxX - (pane.maxX - 8)) <= 1
        XCTAssertTrue(centred || held, "Centred on the selection (\(selection.midX)), or held inside the pane; it is at \(bar.barFrame)")
        XCTAssertIdentical(bar.parent, stage.window, "It travels with its window")
        XCTAssertEqual(bar.appearance?.name, stage.window.effectiveAppearance.name, "and wears its window's appearance")
        try key(36, "\r", in: stage)
        await stage.settle(turns: 10)
        let side = try XCTUnwrap(model.sides[parent.id], "Return asked in a side chat")
        XCTAssertEqual(model.displays[side.id]?.draft, "> precise answer\n\n")
        XCTAssertNil(stage.document.quoteSelection.bar)
    }

    @MainActor func testEscapeDismissesTheSelectionBar() async throws {
        let model = try model(), parent = try XCTUnwrap(model.selected)
        let stage = TranscriptStreamingStressTests.Stage(parent)
        defer { stage.close() }
        var emitted: [TranscriptQuote] = []
        stage.actions.quoteReply = { emitted.append($0) }
        stage.refresh(); await stage.settle()
        _ = try selected("precise answer", in: stage)
        stage.document.quoteSelection.presentSelection()
        XCTAssertTrue(stage.document.quoteSelection.bar?.isVisible == true)
        try key(53, "\u{1b}", in: stage)
        await stage.settle(turns: 10)
        XCTAssertNil(stage.document.quoteSelection.bar)
        XCTAssertTrue(emitted.isEmpty, "Escape asks nothing")
    }

    @MainActor func testNativeStreamingCodeSelectionAndCopySurvivePopover() async throws {
        let session = SessionDisplay(id: "code")
        session.messages = [TranscriptMessage(id: "code-reply", role: "assistant", text: "```swift\nlet result = \"中文🙂\"\n", state: "streaming")]
        let stage = TranscriptStreamingStressTests.Stage(session); defer { stage.close() }
        var emitted: [TranscriptQuote] = []
        stage.actions.quoteReply = { emitted.append($0) }; stage.refresh(); await stage.settle()
        let code = try XCTUnwrap(views(MarkdownTextView.self, in: stage.document).first, "the fence is in the reply's text")
        stage.window.makeFirstResponder(code)
        let range = (code.string as NSString).range(of: "result")
        code.setSelectedRange(range)
        stage.document.quoteSelection.presentSelection()
        XCTAssertEqual(stage.document.quoteSelection.selectedQuote?.text, "result")
        session.messages[0].text += "print(result)\n"; stage.refresh(); await stage.settle()
        XCTAssertEqual(code.selectedRange(), range)
        let clipboard = NSPasteboard(name: .init("quote-copy-" + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(code.writeSelection(to: clipboard, types: code.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), "result")
        stage.document.quoteSelection.askInSideChat()
        XCTAssertEqual(emitted, [TranscriptQuote(messageID: "code-reply", text: "result")])
    }

    @MainActor func testQuotesAppendToPendingDraftAndPreserveSavedSide() throws {
        let model = try model(), quote = TranscriptQuote(messageID: "a", text: "line one\n\n/side is quoted text")
        model.openQuotedSide(parentID: "parent", quote: quote)
        let pending = try XCTUnwrap(model.sides["parent"]), view = try XCTUnwrap(model.displays[pending.id])
        XCTAssertEqual(view.draft, "> line one\n> \n> /side is quoted text\n\n")
        view.draft = "My existing question"
        model.openQuotedSide(parentID: "parent", quote: TranscriptQuote(messageID: "a", text: "More evidence"))
        XCTAssertEqual(model.sides["parent"]?.id, pending.id)
        XCTAssertEqual(view.draft, "My existing question\n\n> More evidence\n\n")
        XCTAssertFalse(view.directCommand)
        model.sides["parent"]?.pending = false; model.sides["parent"]?.kept = true
        model.chats.append(pending.chat)
        model.openQuotedSide(parentID: "parent", quote: quote)
        XCTAssertNotEqual(model.sides["parent"]?.id, pending.id)
        XCTAssertEqual(model.displays[pending.id]?.draft, "My existing question\n\n> More evidence\n\n")
        XCTAssertNotNil(model.record(pending.id)); XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testQuotedSideRejectsOversizePublishingAndUnsupportedOriginsWithoutLosingDrafts() throws {
        let model = try model(), quote = TranscriptQuote(messageID: "a", text: "Quoted text")
        model.openQuotedSide(parentID: "parent", quote: quote)
        let side = try XCTUnwrap(model.sides["parent"]), view = try XCTUnwrap(model.displays[side.id])
        let original = view.draft
        model.openQuotedSide(parentID: "parent", quote: TranscriptQuote(messageID: "a", text: String(repeating: "x", count: 262145)))
        XCTAssertEqual(view.draft, original); XCTAssertTrue(model.error?.contains("256 KiB") == true)
        view.loading = true
        model.openQuotedSide(parentID: "parent", quote: quote)
        XCTAssertEqual(view.draft, original); XCTAssertEqual(model.sides["parent"]?.id, side.id)
        XCTAssertFalse(model.canQuoteReply(side.id), "Nested side panels are not offered")
        model.chats[0].archivedAt = Date()
        XCTAssertFalse(model.canQuoteReply("parent"))
    }
}
