import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// What a token costs the reply's own surface as the reply grows. A token is
/// text appended to the block still arriving: the surface reads that block
/// again and measures it again, and nothing above it — not the settled blocks
/// before it, not the items of a long list that have already been followed by
/// another — may be walked, rebuilt or measured for it. So a token under a
/// reply ten times longer costs what it costs under a short one.
///
/// Each run streams through the page itself: the session changes, the page
/// publishes, the row takes the token on its fast path and hands it to the
/// reply's surface, and the page lays out and draws.
final class NativeMarkdownSurfaceStreamingTests: XCTestCase {
    private typealias Stage = TranscriptStreamingStressTests.Stage

    struct Run {
        var frames: [Double] = []
        var appends: [Double] = []
        var updates: [Double] = []
        var tokensOnTheFastPath = 0
        var blocks = 0
        /// Blocks the surface compared with what they were, per token.
        var visitsPerToken = 0.0
        /// Characters of the reply's text each token set again.
        var replaced: [Int] = []
        static func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        var frame: Double { Self.median(frames) }
        var append: Double { Self.median(appends) }
        var update: Double { Self.median(updates) }
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// Streams `tokens` into a reply that already holds `text`, the reader
    /// watching it arrive at the bottom of the page.
    @MainActor private func stream(_ text: String, tokens: [String], label: String) async throws -> Run {
        let id = "reply-" + label
        let session = SessionDisplay(id: "surface-" + label)
        var reply = TranscriptMessage(id: id, role: "assistant", text: text, at: 2_000, turn: "u1")
        reply.state = "streaming"
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Write it all out.", at: 1_000, turn: "u1"), reply]
        let stage = Stage(session, width: 820, height: 700)
        defer { stage.close() }
        stage.page.state = "running"
        stage.page.presentationInterval = 0
        await stage.settleUntilExact()
        var text = text
        // One token so the reply is on its fast path before the clock starts.
        text += " first"
        session.messages[1].text = text
        stage.refresh()
        await stage.settle(turns: 3)
        let row = try XCTUnwrap(stage.rows.first { row in
            if case .block(let block) = row.item { return block.message?.id == id }
            if case .message(let message) = row.item { return message.id == id }
            return false
        }, "the reply has a row")
        let surface = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: row).first { $0.readingIdentity == id }, "the reply is drawn by its own surface")
        var run = Run()
        let appendsBefore = row.streamingAppendCount
        let visitsBefore = surface.reconciledBlockVisits
        TranscriptLayoutClock.recording = true
        defer { TranscriptLayoutClock.recording = false }
        for (index, token) in tokens.enumerated() {
            text += token
            TranscriptLayoutClock.reset()
            let start = ProcessInfo.processInfo.systemUptime
            session.messages[1].text = text
            stage.refresh()
            run.frames.append(ProcessInfo.processInfo.systemUptime - start)
            run.appends.append(TranscriptLayoutClock.markdownAppendSeconds)
            run.updates.append(TranscriptLayoutClock.markdownUpdateSeconds)
            run.replaced.append(surface.lastReplacedLength)
            if index % 8 == 7 { await Task.yield() }
        }
        run.tokensOnTheFastPath = row.streamingAppendCount - appendsBefore
        run.blocks = surface.retainedBlockCount
        run.visitsPerToken = Double(surface.reconciledBlockVisits - visitsBefore) / Double(tokens.count)
        XCTAssertEqual(stage.page.snapshot?.messages.last?.text, text, "the page holds every token")
        return run
    }

    /// A reply of `paragraphs` settled blocks — prose, a heading now and then,
    /// a short list — and the paragraph still arriving.
    private static func reply(blocks: Int) -> String {
        (0..<blocks).map { index in
            if index % 20 == 0 { return "## Part \(index / 20)" }
            if index % 30 == 15 { return "- a point about \(index)\n- another point" }
            return "Paragraph \(index) with **bold**, `code` and a [link](https://example.com/\(index))."
        }.joined(separator: "\n\n") + "\n\nThe paragraph still arriving"
    }

    /// A token costs the same under 120 blocks as under 1,150: nothing it
    /// does walks the blocks above the one it changes.
    @MainActor func testATokenCostsTheSameUnderAHundredAndATwelveHundredBlockReply() async throws {
        // Words, and every eighth token a new paragraph: blocks settle as it runs.
        let tokens = (0..<48).map { $0 % 8 == 7 ? "\n\nAnother paragraph" : " word\($0)" }
        var runs: [Int: Run] = [:]
        for blocks in [120, 1_150] {
            let run = try await stream(Self.reply(blocks: blocks), tokens: tokens, label: "\(blocks)")
            XCTAssertEqual(run.tokensOnTheFastPath, tokens.count, "\(blocks) blocks: every token must extend the reply's surface")
            XCTAssertGreaterThan(run.blocks, blocks, "the fixture must hold \(blocks) blocks")
            runs[blocks] = run
            print(String(format: "PERF a token under a %d-block reply: the frame %.3f ms, the surface's append %.3f ms, of which reconciling its blocks %.3f ms, comparing %.1f blocks (medians of %d)",
                         run.blocks, run.frame * 1000, run.append * 1000, run.update * 1000, run.visitsPerToken, tokens.count))
        }
        let short = try XCTUnwrap(runs[120]), long = try XCTUnwrap(runs[1_150])
        // The shape, whatever the machine: a token compares the blocks it
        // changed and the one before them, not the reply.
        XCTAssertLessThan(long.visitsPerToken, 4, "a token compared \(long.visitsPerToken) of \(long.blocks) blocks")
        XCTAssertLessThan(long.update, short.update * 2 + 0.000_1,
                          String(format: "reconciling a token's blocks cost %.3f ms under 1,150 blocks against %.3f ms under 120", long.update * 1000, short.update * 1000))
        XCTAssertLessThan(long.append, short.append * 2 + 0.000_3,
                          String(format: "a token's append cost %.3f ms under 1,150 blocks against %.3f ms under 120", long.append * 1000, short.append * 1000))
        XCTAssertLessThan(long.frame, short.frame * 2 + 0.000_5,
                          String(format: "a token's frame cost %.3f ms under 1,150 blocks against %.3f ms under 120", long.frame * 1000, short.frame * 1000))
        XCTAssertLessThan(long.frame, releaseBudget(0.004), String(format: "a token's frame cost %.3f ms under 1,150 blocks", long.frame * 1000))
    }

    /// A token on an open list of 8 KB costs what one on 1 KB costs: the list
    /// is read an item at a time, set as text an item at a time, and a token
    /// sets again only the item still arriving.
    @MainActor func testATokenOnAnOpenListCostsTheSameAtOneAndEightKilobytes() async throws {
        func list(_ bytes: Int) -> String {
            var lines: [String] = [], size = 0
            while size < bytes { let line = "- item \(lines.count) with `code` and **bold** text in it"; lines.append(line); size += line.utf8.count + 1 }
            return lines.joined(separator: "\n")
        }
        let tokens = (0..<48).map { ["\n- item next", " with", " `code`", " and", " **bold**", " text"][$0 % 6] }
        var runs: [Int: Run] = [:]
        for bytes in [1_024, 7_600] {
            let run = try await stream(list(bytes), tokens: tokens, label: "list-\(bytes)")
            XCTAssertEqual(run.tokensOnTheFastPath, tokens.count, "a \(bytes)-byte list: every token must extend the reply's surface")
            runs[bytes] = run
            print(String(format: "PERF a token on an open %d-byte list (%d blocks drawn): the frame %.3f ms, the surface's append %.3f ms (medians of %d)",
                         bytes, run.blocks, run.frame * 1000, run.append * 1000, tokens.count))
        }
        let short = try XCTUnwrap(runs[1_024]), long = try XCTUnwrap(runs[7_600])
        // The shape: the list is set as text an item at a time, and a token
        // sets again only the item it changes.
        XCTAssertGreaterThan(long.blocks, 100, "an 8 KB list is set an item at a time")
        XCTAssertLessThan(Run.median(long.replaced.map(Double.init)), 120, "a token set \(Run.median(long.replaced.map(Double.init))) characters again")
        XCTAssertLessThan(long.append, short.append * 2 + 0.000_3,
                          String(format: "a token on an 8 KB list cost %.3f ms in the surface against %.3f ms on 1 KB", long.append * 1000, short.append * 1000))
        XCTAssertLessThan(long.frame, short.frame * 2 + 0.000_5,
                          String(format: "a token's frame on an 8 KB list cost %.3f ms against %.3f ms on 1 KB", long.frame * 1000, short.frame * 1000))
        XCTAssertLessThan(long.frame, releaseBudget(0.004), String(format: "a token's frame on an 8 KB list cost %.3f ms", long.frame * 1000))
    }

    // MARK: A long list drawn in segments

    /// A list with wrapping items, nested items, inline marks and numbers that
    /// start at 7 and grow to two digits.
    private static let longList: String = (0..<50).map { index -> String in
        let number = "\(index + 7)."
        var item = number + " Step \(index + 7): " + (index % 5 == 0 ? String(repeating: "a long line that wraps across the column ", count: 3) : "**do** the `thing`")
        // Nested under the item's text, however wide its number is.
        let indent = String(repeating: " ", count: number.count + 1)
        if index % 9 == 4 { item += "\n\(indent)- a nested point\n\(indent)- and another" }
        return item
    }.joined(separator: "\n")

    /// A list the reply streams an item at a time reads, and is dressed,
    /// exactly as the same list drawn whole: the same markers and numbers, the
    /// same indents, the same space between items, the same copy.
    @MainActor func testAListStreamedItemByItemIsTheSameListAsOneDrawnWhole() async throws {
        let final = Self.longList
        let whole = MarkdownTextSurfaceTests.surface(final)
        let bytes = Array(final.utf8)
        var index = min(bytes.count, 40)
        let streamed = MarkdownTextSurfaceTests.surface(String(decoding: bytes[..<index], as: UTF8.self), streaming: true)
        while index < bytes.count {
            index = min(bytes.count, index + 17)
            _ = streamed.0.appendStreaming(String(decoding: bytes[..<index], as: UTF8.self), identity: "reply")
        }
        streamed.0.read(source: final, style: .prose, capsWidth: true, streaming: false, headings: [], environment: TranscriptRowEnvironment(), identity: "reply")
        XCTAssertEqual(streamed.0.textView.string, whole.0.textView.string)
        XCTAssertEqual(MarkdownTextSurfaceTests.dress(streamed.0), MarkdownTextSurfaceTests.dress(whole.0))
        XCTAssertEqual(streamed.0.measure(width: 760).height, whole.0.measure(width: 760).height)
        let all = { (surface: NativeMarkdownContainer) in surface.textView.copyText([NSRange(location: 0, length: surface.textLength)]) }
        XCTAssertEqual(all(streamed.0), all(whole.0))
        XCTAssertTrue(all(whole.0).hasPrefix("7. Step 7:"), String(all(whole.0).prefix(40)))
        withExtendedLifetime((whole.1, streamed.1)) {}
    }

    /// Selecting in an item the reply has already moved past, then streaming
    /// into the list's last item: the selection stays in the same text field,
    /// on the same characters, and the segment holding it is never rebuilt.
    @MainActor func testASelectionInAFinishedPartOfAListSurvivesTheItemsArrivingAfterIt() async throws {
        var source = (0..<40).map { "- item \($0) with `code` and **bold** text in it" }.joined(separator: "\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MarkdownBodyView(source: source, streaming: true, sourceIdentity: "list"))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield() }
        let surface = try XCTUnwrap(descendants(NativeMarkdownContainer.self, in: host).first)
        XCTAssertGreaterThan(surface.retainedBlockCount, 1, "a 40-item list is set an item at a time")
        let text = surface.textView
        window.makeFirstResponder(text)
        let item = (text.string as NSString).range(of: "item 3 with")
        let selected = (text.string as NSString).range(of: "code", range: NSRange(location: item.location, length: 40))
        text.setSelectedRange(selected)
        for round in 0..<30 {
            source += ["\n- item next", " with", " `code`", " and", " **bold**", " text"][round % 6]
            XCTAssertNotNil(surface.appendStreaming(source, identity: "list"), "token \(round) extends the surface")
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield()
        }
        XCTAssertTrue(window.firstResponder === text, "the text holding the selection keeps it")
        XCTAssertEqual(text.selectedRange(), selected, "the selection stays on the same characters")
        XCTAssertTrue(descendants(MarkdownTextView.self, in: surface).first === text, "the same text")
        // Copying the reply from its menu copies its source.
        host.rootView = MarkdownBodyView(source: source, streaming: false, sourceIdentity: "list")
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield() }
        let whole = TranscriptCopy.targets(in: source).first { $0.kind == .whole || $0.kind == .introduction }
        XCTAssertEqual(whole?.text.contains("item 39 with `code`"), true, "the reply's copy is its source")
    }
}
