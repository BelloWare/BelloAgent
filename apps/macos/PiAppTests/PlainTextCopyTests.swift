import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Copying from a message exactly as it was typed, and from a reply read as
/// its source: a selection across lines reaches the pasteboard as exactly the
/// characters it covers, line breaks and Markdown included. Each is one text,
/// so the selection is one range, which the rendered reply's separate block
/// texts could never be.
///
/// These use the general pasteboard, which every test host shares, so they
/// run in the serial lane (`scripts/test-lanes.py`).
final class PlainTextCopyTests: XCTestCase {
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    @MainActor private func stage(_ messages: [TranscriptMessage]) async -> TranscriptStreamingStressTests.Stage {
        let session = SessionDisplay(id: "plain-copy-" + UUID().uuidString)
        session.messages = messages
        let stage = TranscriptStreamingStressTests.Stage(session, width: 820, height: 700)
        stage.refresh(); await stage.settle()
        return stage
    }
    /// Copies what `text` has selected, as ⌘C does, and reads it back.
    @MainActor private func copied(from text: NSTextView) -> String? {
        NSPasteboard.general.clearContents()
        text.copy(nil)
        return NSPasteboard.general.string(forType: .string)
    }

    /// A short message: SwiftUI's own selectable text, through the field
    /// editor that holds its selection.
    @MainActor func testCopyingAcrossTheLinesOfATypedMessage() async throws {
        let typed = ReplySourceTests.typed
        let stage = await stage([TranscriptMessage(id: "u1", role: "user", text: typed, at: 1_000, turn: "u1"),
                                 TranscriptMessage(id: "a1", role: "assistant", text: "Answer.", state: "complete", at: 2_000, turn: "u1")])
        defer { stage.close() }
        let row = try XCTUnwrap(stage.row("u1"))
        let field = try XCTUnwrap(views(NSTextField.self, in: row).first { $0.isSelectable && $0.stringValue == typed })
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let start = (typed as NSString).range(of: "**not bold**").location
        let end = NSMaxRange((typed as NSString).range(of: "two  spaces"))
        editor.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(copied(from: editor), "**not bold** and `not code`\n- not a list item\n  two  spaces",
                       "the copy is the typed characters across three lines, markers and spaces included")
    }

    /// A long paste: the TextKit text, selected from one line deep into another.
    @MainActor func testCopyingAcrossTheLinesOfALongPaste() async throws {
        let text = (0..<400).map { "Line \($0): **not bold** `not code` # not a heading" }.joined(separator: "\n")
        XCTAssertTrue(TranscriptPlainText.usesTextKit(text))
        let stage = await stage([TranscriptMessage(id: "u1", role: "user", text: text, at: 1_000, turn: "u1"),
                                 TranscriptMessage(id: "a1", role: "assistant", text: "Answer.", state: "complete", at: 2_000, turn: "u1")])
        defer { stage.close() }
        let row = try XCTUnwrap(stage.row("u1"))
        stage.readerScroll(to: row.frame.minY)
        await stage.settle()
        let leaf = try XCTUnwrap(views(TranscriptPlainTextView.self, in: row).first)
        let start = (text as NSString).range(of: "Line 2:").location
        let end = NSMaxRange((text as NSString).range(of: "Line 5: **not bold**"))
        leaf.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(copied(from: leaf), (2...4).map { "Line \($0): **not bold** `not code` # not a heading" }.joined(separator: "\n") + "\nLine 5: **not bold**")
    }

    /// A reply switched to its source: its Markdown, copied across lines as it
    /// arrived, not the rendered words.
    @MainActor func testCopyingAcrossTheLinesOfAReplysSource() async throws {
        let source = ReplySourceTests.longReply
        let stage = await stage([TranscriptMessage(id: "u1", role: "user", text: "Write it all out.", at: 1_000, turn: "u1"),
                                 TranscriptMessage(id: "a1", role: "assistant", text: source, state: "complete", at: 2_000, turn: "u1")])
        defer { stage.close() }
        let row = try XCTUnwrap(stage.row("block:a1"))
        row.toggleDisclosure(.source("a1"))
        stage.draw()
        stage.readerScroll(to: row.frame.minY)
        await stage.settle()
        let leaf = try XCTUnwrap(views(TranscriptPlainTextView.self, in: row).first)
        let start = (source as NSString).range(of: "## Section 1\n").location
        let end = NSMaxRange((source as NSString).range(of: "- item one", range: NSRange(location: start, length: 200)))
        leaf.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(copied(from: leaf), "## Section 1\nSome **bold** text with `code` and a [link](https://example.com), long enough to wrap in the pane.\n\n- item one")
    }
}
