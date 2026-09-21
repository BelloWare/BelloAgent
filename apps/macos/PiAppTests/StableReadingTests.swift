import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class StableReadingTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    @MainActor func testProductionStreamingAppendDuringParentAdoptionKeepsMiddleSource() async throws {
        for selected in [false, true] {
            let session = SessionDisplay(id: "reading-middle-\(selected)")
            let source = (0..<75).map { "Paragraph \($0). " + String(repeating: "Settled source stays still. ", count: 3) }.joined(separator: "\n\n")
            XCTAssertLessThan(source.utf8.count, 16384)
            session.messages = [.init(id: "u", role: "user", text: "Read"), .init(id: "a", role: "assistant", text: source, state: "streaming")]
            let stage = TranscriptStreamingStressTests.Stage(session, height: 480)
            defer { stage.close() }
            stage.page.presentationInterval = 0; stage.page.state = "running"
            await stage.settle(turns: 2)
            let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, stage.document).first)
            var held: NativeMarkdownContainer.LogicalAnchor?
            var drawCount = 0
            body.didPrepareVisibleBlocks = {
                guard let prepared = body.preparedLogicalAnchor else { return }
                body.didPrepareVisibleBlocks = nil
                held = stage.scroll.transcriptReading.readingAnchor ?? prepared
                // This is the real SessionDisplay -> TranscriptPage -> native
                // document path while the child's parent correction is pending.
                session.messages[1].text += "\n\nNew tail during measurement."
                stage.refresh()
            }
            stage.readerScroll(to: stage.document.frame.height * 0.4)
            for _ in 0..<8 where held == nil {
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                stage.window.displayIfNeeded()
            }
            let anchor = try XCTUnwrap(held)
            body.didDrawPreparedContent = {
                drawCount += 1
                XCTAssertEqual(body.displacement(of: anchor) ?? .infinity, 0, accuracy: 1 / stage.window.backingScaleFactor)
            }
            var editor: NSText?
            if selected, let field = descendants(NSTextField.self, body).first(where: { $0.isSelectable && $0.stringValue.hasPrefix("Paragraph") }) {
                field.selectText(nil); editor = field.currentEditor(); editor?.selectedRange = NSRange(location: 0, length: 5)
            }
            for i in 0..<12 {
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                session.messages[1].text += "\n\nTail \(i)."
                stage.refresh(); stage.window.displayIfNeeded()
                if let editor { XCTAssertTrue(stage.window.firstResponder === editor); XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 5)) }
            }
            XCTAssertGreaterThan(drawCount, 0)
            print("READING_MIDDLE selected=\(selected) drawOpportunities=\(drawCount) sourceBytes=\(source.utf8.count)")
        }
    }
    @MainActor func testLongUnicodeParagraphAndCodeRetainCharacterAnchorOnReflow() async throws {
        for code in [false, true] {
            var text = (0..<110).map { "Line \($0) 中文🙂 café שלום visible source stays at this character. " }.joined()
            if code { text = "```swift\n" + text + "\n```" }
            let session = SessionDisplay(id: "long-anchor-\(code)")
            session.messages = [.init(id: "u", role: "user", text: "Read"), .init(id: "a", role: "assistant", text: text, state: "streaming")]
            let stage = TranscriptStreamingStressTests.Stage(session, width: 640, height: 440)
            defer { stage.close() }
            stage.page.presentationInterval = 0
            await stage.settle(turns: 2)
            stage.readerScroll(to: stage.document.frame.height * 0.45)
            let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, stage.document).first)
            stage.scroll.transcriptReading.capture(body)
            let anchor = try XCTUnwrap(stage.scroll.transcriptReading.readingAnchor)
            XCTAssertGreaterThan(try XCTUnwrap(anchor.sourceUTF16Range).location, 100, "The actual middle source character must be retained, code=\(code)")
            var draws = 0
            body.didDrawPreparedContent = {
                draws += 1
                XCTAssertEqual(body.displacement(of: anchor) ?? .infinity, 0, accuracy: 1 / stage.window.backingScaleFactor)
            }
            stage.resize(width: 470)
            for _ in 0..<3 {
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                stage.window.displayIfNeeded()
            }
            XCTAssertEqual(body.displacement(of: anchor) ?? .infinity, 0, accuracy: 1 / stage.window.backingScaleFactor)
            XCTAssertGreaterThan(draws, 0)
        }
    }

    @MainActor func testCanonicalInlineMarkupKeepsTheSameMiddleCharacter() async throws {
        let text = (0..<90).map { "Part \($0) **bold** and [linked text](https://example.com) 中文🙂. " }.joined()
        let session = SessionDisplay(id: "canonical-middle")
        session.messages = [.init(id: "u", role: "user", text: "Read"), .init(id: "a", role: "assistant", text: text, state: "streaming")]
        let stage = TranscriptStreamingStressTests.Stage(session, width: 640, height: 440)
        defer { stage.close() }
        stage.page.presentationInterval = 0
        await stage.settle(turns: 2)
        stage.readerScroll(to: stage.document.frame.height * 0.4)
        let body = try XCTUnwrap(descendants(NativeMarkdownContainer.self, stage.document).first)
        stage.scroll.transcriptReading.capture(body)
        let anchor = try XCTUnwrap(stage.scroll.transcriptReading.readingAnchor)
        XCTAssertGreaterThan(try XCTUnwrap(anchor.sourceUTF16Range).location, 100)
        session.messages[1].state = "complete"
        stage.refresh()
        for _ in 0..<3 {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            stage.window.displayIfNeeded()
        }
        XCTAssertEqual(body.displacement(of: anchor) ?? .infinity, 0, accuracy: 1 / stage.window.backingScaleFactor)
    }

    @MainActor func testCompletionCopyMetadataDoesNotDemotePreparedBlocks() throws {
        let source = "## Heading\n\n" + (0..<80).map { "Paragraph \($0) stays put." }.joined(separator: "\n\n")
        let blocks = TranscriptMarkdown.blocks(source, style: .prose)
        let body = NativeMarkdownContainer()
        body.update(blocks: blocks, style: .prose, capsWidth: true, streaming: true, headings: [], environment: .init())
        body.frame = CGRect(origin: .zero, size: body.measure(width: 620))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 620, height: 540))
        scroll.documentView = body
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: body.frame.height * 0.4))
        for _ in 0..<8 { body.needsLayout = true; body.layoutSubtreeIfNeeded() }
        let provisional = body.provisionalBlockCount, measured = body.blockMeasurementCount
        let mounted = body.subviews.filter { !($0 is NSProgressIndicator) }.map(ObjectIdentifier.init)
        body.update(blocks: blocks, style: .prose, capsWidth: true, streaming: false,
                    headings: TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false }, environment: .init())
        _ = body.measure(width: 620)
        XCTAssertLessThanOrEqual(body.provisionalBlockCount, provisional, "Copy and caret cannot make exact blocks provisional")
        XCTAssertEqual(body.blockMeasurementCount, measured, "Metadata does not measure settled text")
        XCTAssertEqual(body.subviews.filter { !($0 is NSProgressIndicator) }.map(ObjectIdentifier.init), mounted)
    }

    @MainActor func testUpwardGestureWithinOldFollowThresholdDetaches() async {
        let session = SessionDisplay(id: "reading-threshold")
        session.messages = TranscriptStreamingStressTests.history(turns: 6)
        let stage = TranscriptStreamingStressTests.Stage(session)
        defer { stage.close() }
        await stage.settle()
        stage.page.jumpToLatest()
        try? await Task.sleep(for: .milliseconds(450))
        stage.readerScroll(to: max(0, stage.document.frame.height - stage.scroll.contentView.bounds.height - 25))
        XCTAssertFalse(stage.page.followsBottom, "An upward gesture is reading intent even 25 points from the end")
        let y = stage.scrollY
        session.messages.append(TranscriptMessage(id: "tail", role: "assistant", text: "New content", state: "streaming"))
        stage.refresh(); await stage.settle(turns: 1)
        XCTAssertEqual(stage.scrollY, y, accuracy: 1 / (stage.window.backingScaleFactor))
    }

}
