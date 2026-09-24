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

    func testLastParagraphUsesItsPreviousScopeWhenDefinitionJoinsCanonicalRange() throws {
        let original = "First **strong** with [label][ref] here.\n\n"
        let document = original + "[ref]: https://example.com/target\n"
        let previous = "First strong with [label][ref] here."
        let rendered = "First strong with label here."
        let source = try XCTUnwrap(MarkdownSelection.Source(document, bytes: 0..<document.utf8.count))
        let oldSource = try XCTUnwrap(MarkdownSelection.Source(document, bytes: 0..<original.utf8.count))
        let map = MarkdownSelection.Reconciliation(previous: previous, source: source, previousSource: oldSource,
                                                  rendered: rendered, keepsSoftBreaks: false)
        XCTAssertEqual(map.range((previous as NSString).range(of: "label")), (rendered as NSString).range(of: "label"))
    }

    @MainActor func testLateReferenceDefinitionKeepsSelectionAndUnchangedNativeOwner() async throws {
        try await checkReferenceSelection(hasFollowingParagraph: true)
        try await checkReferenceSelection(hasFollowingParagraph: false)
    }

    @MainActor private func checkReferenceSelection(hasFollowingParagraph: Bool) async throws {
        let text = "First **strong** with [label][ref] here.\n\n"
        let original = text + (hasFollowingParagraph ? "Unchanged paragraph." : "[ref]: https://example.com/target\n")
        let completed = hasFollowingParagraph ? original + "\n\n[ref]: https://example.com/target\n" : original
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MarkdownBodyView(source: original, streaming: true, sourceIdentity: "reply"))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func texts(_ view: NSView) -> [MarkdownTextView] {
            if let text = view as? MarkdownTextView { return [text] }
            return view.subviews.flatMap { texts($0) }
        }
        _ = host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        // The whole reply is one text; the paragraph still says [label][ref].
        let reply = try XCTUnwrap(texts(host).first)
        XCTAssertEqual(texts(host).count, 1)
        // While it streams, each settled part is read alone: the reference
        // is defined in a later part, so the link reads as it was typed.
        XCTAssertTrue(reply.string.contains("[label][ref]"), reply.string)
        window.makeFirstResponder(reply)
        let label = (reply.string as NSString).range(of: "label")
        reply.setSelectedRange(label)
        host.rootView = MarkdownBodyView(source: completed, streaming: false, sourceIdentity: "reply")
        _ = host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        XCTAssertTrue(texts(host).first === reply, "the same text")
        XCTAssertTrue(reply.string.hasPrefix("First strong with label here."), reply.string)
        XCTAssertEqual((reply.string as NSString).substring(with: reply.selectedRange()), "label",
                       "Resolve document-scoped references without moving the selected source text")
        if hasFollowingParagraph { XCTAssertTrue(reply.string.contains("Unchanged paragraph."), "the paragraph after it is kept") }
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
