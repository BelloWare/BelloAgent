import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class MarkdownSourceReconciliationTests: XCTestCase {
    func testDocumentReferenceMapsTheSecondRepeatedLabelUsingUTF16SourcePositions() throws {
        let prefix = "日本🙂 First paragraph.\n\n"
        let fragment = "Another **bold** [same][ref] and [same][ref], e\u{301}.\n\n"
        let document = prefix + fragment + "[ref]: https://example.com/target\n"
        let source = try XCTUnwrap(MarkdownSelection.Source(document, bytes: prefix.utf8.count..<(prefix + fragment).utf8.count))
        let previous = "Another bold [same][ref] and [same][ref], e\u{301}."
        let rendered = "Another bold same and same, e\u{301}."
        let map = MarkdownSelection.Reconciliation(previous: previous, source: source, rendered: rendered, keepsSoftBreaks: false)
        for text in ["same", "e\u{301}"] {
            XCTAssertEqual(map.range((previous as NSString).range(of: text, options: .backwards)),
                           (rendered as NSString).range(of: text, options: .backwards))
        }
        XCTAssertNil(map.range(NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(map.range(NSRange(location: Int.max - 1, length: 100)))
        XCTAssertNil(MarkdownSelection.Source("🙂", bytes: 1..<4), "Reject a range inside a UTF-8 scalar")
    }

    func testTerminalReplacementDoesNotBorrowAnUnrelatedOldSourceIdentity() {
        let state = StreamingMarkdownState()
        let original = state.update("Removed paragraph.\n\nRepeated paragraph.\n\nOld tail.", style: .prose, streaming: true, identity: "reply")
        let generation = state.generation
        let replacement = state.update("Repeated paragraph.\n\nNew terminal source.", style: .prose, streaming: false, identity: "reply")
        XCTAssertGreaterThan(state.generation, generation)
        XCTAssertTrue(replacement.allSatisfy { $0.id.generation == state.generation }, "Different terminal source must use its own generation")
        XCTAssertTrue(Set(original.map(\.id)).isDisjoint(with: replacement.map(\.id)), "Equal text or an equal offset cannot make a replaced source the original block")
    }

    @MainActor func testLateReferenceDefinitionKeepsSelectionAndUnchangedNativeOwner() async throws {
        let original = "First **strong** with [label][ref] here.\n\nUnchanged paragraph."
        let completed = original + "\n\n[ref]: https://example.com/target\n"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MarkdownBodyView(source: original, streaming: true, sourceIdentity: "reply"))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields($0) }
        }
        _ = host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let first = try XCTUnwrap(fields(host).first { $0.stringValue.contains("[label][ref]") })
        let unchanged = try XCTUnwrap(fields(host).first { $0.stringValue == "Unchanged paragraph." })
        first.selectText(nil)
        let editor = try XCTUnwrap(first.currentEditor())
        editor.selectedRange = (first.stringValue as NSString).range(of: "label")
        host.rootView = MarkdownBodyView(source: completed, streaming: false, sourceIdentity: "reply")
        _ = host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        XCTAssertTrue(first.currentEditor() === editor)
        XCTAssertEqual(first.stringValue, "First strong with label here.")
        XCTAssertEqual(editor.selectedRange, (first.stringValue as NSString).range(of: "label"), "Resolve document-scoped references without moving the selected source text")
        XCTAssertTrue(fields(host).contains { $0 === unchanged }, "A dependent paragraph cannot replace an unaffected paragraph's owner")
    }

    @MainActor func testLateReferenceDefinitionKeepsUnselectedMiddleCharacterAtDrawTime() async throws {
        let paragraph = (0..<60).map { "Part \($0) **bold** and [linked text][ref] 中文🙂. " }.joined()
        let session = SessionDisplay(id: "document-reference-reading")
        session.messages = [.init(id: "u", role: "user", text: "Read"),
                            .init(id: "a", role: "assistant", text: paragraph + "\n\nUnchanged tail.", state: "streaming")]
        let stage = TranscriptStreamingStressTests.Stage(session, width: 640, height: 440)
        defer { stage.close() }
        stage.page.presentationInterval = 0
        await stage.settle(turns: 2)
        stage.readerScroll(to: stage.document.frame.height * 0.4)
        func body(_ view: NSView) -> NativeMarkdownContainer? {
            (view as? NativeMarkdownContainer) ?? view.subviews.lazy.compactMap { body($0) }.first
        }
        let surface = try XCTUnwrap(body(stage.document))
        stage.scroll.transcriptReading.capture(surface)
        let anchor = try XCTUnwrap(stage.scroll.transcriptReading.readingAnchor)
        XCTAssertGreaterThan(try XCTUnwrap(anchor.sourceUTF16Range).location, 100)
        var draws = 0
        surface.didDrawPreparedContent = {
            draws += 1
            XCTAssertEqual(surface.displacement(of: anchor) ?? .infinity, 0, accuracy: 1 / stage.window.backingScaleFactor)
        }
        session.messages[1].text += "\n\n[ref]: https://example.com/target\n"
        session.messages[1].state = "complete"
        stage.refresh()
        for _ in 0..<3 {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            stage.window.displayIfNeeded()
        }
        XCTAssertGreaterThan(draws, 0)
        XCTAssertEqual(surface.displacement(of: anchor) ?? .infinity, 0, accuracy: 1 / stage.window.backingScaleFactor)
    }
}
