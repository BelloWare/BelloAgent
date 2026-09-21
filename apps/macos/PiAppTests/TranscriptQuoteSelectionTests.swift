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
        let field = try XCTUnwrap(views(NSTextField.self, in: stage.document).first { $0.isSelectable && $0.stringValue.contains("A precise answer") })
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let range = (editor.string as NSString).range(of: "中文🙂 and repeated answer")
        editor.setSelectedRange(range)
        let before = stage.document.frame.height
        // The production monitor reads selection after native keyboard input;
        // it must not rely on a caller manually opening the popover.
        let key = try XCTUnwrap(NSEvent.keyEvent(with:.keyUp, location:.zero, modifierFlags:.shift, timestamp:0,
            windowNumber:stage.window.windowNumber, context:nil, characters:"", charactersIgnoringModifiers:"", isARepeat:false, keyCode:124))
        NSApp.postEvent(key, atStart:false)
        await stage.settle(turns:12)
        let popup = try XCTUnwrap(stage.document.quoteSelection.popover)
        XCTAssertTrue(popup.isShown)
        XCTAssertEqual(stage.document.quoteSelection.selectedQuote, TranscriptQuote(messageID: "a", text: "中文🙂 and repeated answer"))
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertEqual(stage.document.frame.height, before, accuracy: 0.5)
        let button = try XCTUnwrap(views(NSButton.self, in: try XCTUnwrap(popup.contentViewController?.view)).first { $0.title == "Ask in side chat" })
        button.performClick(nil)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        XCTAssertTrue(side.pending); XCTAssertEqual(view.draft, "> 中文🙂 and repeated answer\n\n")
        XCTAssertEqual(model.focusedSessionID, side.id); XCTAssertGreaterThan(view.composerFocusRequest, 0)
        XCTAssertEqual(side.model, "selected-model"); XCTAssertEqual(side.thinkingLevel, "high")
        XCTAssertEqual(parent.draft, "Unsent parent question"); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertFalse(view.directCommand); XCTAssertTrue(view.queue.isEmpty)
        XCTAssertNil(stage.document.quoteSelection.popover)
    }

    @MainActor func testUserSelectionEmptyRangeAndSessionSwitchNeverQuote() async throws {
        let model = try model(), parent = try XCTUnwrap(model.selected)
        let stage = TranscriptStreamingStressTests.Stage(parent); defer { stage.close() }
        var emitted: [TranscriptQuote] = []
        stage.actions.quoteReply = { emitted.append($0) }; stage.refresh(); await stage.settle()
        let user = try XCTUnwrap(views(NSTextField.self, in: stage.document).first { $0.isSelectable && $0.stringValue == "Question" })
        user.selectText(nil); stage.document.quoteSelection.presentSelection()
        XCTAssertNil(stage.document.quoteSelection.popover)
        let assistant = try XCTUnwrap(views(NSTextField.self, in: stage.document).first { $0.isSelectable && $0.stringValue.contains("A precise answer") })
        assistant.selectText(nil)
        let editor = try XCTUnwrap(assistant.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0)); stage.document.quoteSelection.presentSelection()
        XCTAssertNil(stage.document.quoteSelection.popover)
        editor.setSelectedRange(NSRange(location: 0, length: 8)); stage.document.quoteSelection.presentSelection()
        XCTAssertTrue(stage.document.quoteSelection.popover?.isShown == true)
        let next = SessionDisplay(id: "another"); next.messages = parent.messages
        stage.show(next); await stage.settle()
        XCTAssertNil(stage.document.quoteSelection.popover)
        stage.document.quoteSelection.askInSideChat(); XCTAssertTrue(emitted.isEmpty)
    }

    @MainActor func testNativeStreamingCodeSelectionAndCopySurvivePopover() async throws {
        let session = SessionDisplay(id: "code")
        session.messages = [TranscriptMessage(id: "code-reply", role: "assistant", text: "```swift\nlet result = \"中文🙂\"\n", state: "streaming")]
        let stage = TranscriptStreamingStressTests.Stage(session); defer { stage.close() }
        var emitted: [TranscriptQuote] = []
        stage.actions.quoteReply = { emitted.append($0) }; stage.refresh(); await stage.settle()
        let code = try XCTUnwrap(views(TranscriptCodeTextView.self, in: stage.document).first)
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
