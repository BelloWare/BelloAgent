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
    /// is read an item at a time, and drawn in segments of which only the
    /// last — the one holding the item still arriving — is rebuilt and measured.
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
        // The shape: the list is drawn in segments, and a token compares the
        // open list's segments — sixteen items each — not its items.
        XCTAssertGreaterThan(long.blocks, 8, "an 8 KB list is drawn in segments")
        XCTAssertLessThan(long.visitsPerToken, 16, "a token compared \(long.visitsPerToken) blocks")
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

    /// The text a surface draws, where it draws it: every text field in it,
    /// in the surface's own coordinates.
    @MainActor private func drawn(_ surface: NSView) -> [(text: String, frame: CGRect)] {
        descendants(NSTextField.self, in: surface).map { ($0.stringValue, surface.convert($0.bounds, from: $0)) }
            .sorted { $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
    }

    /// A surface holding one block, measured and laid out in a window tall
    /// enough that every block is on screen, as a reply's surface is measured
    /// in the window it is drawn in.
    @MainActor private func surface(_ blocks: [MarkdownBlock], segments: Int) async -> (surface: NativeMarkdownContainer, window: NSWindow) {
        let prior = NativeMarkdownContainer.listSegmentLength
        NativeMarkdownContainer.listSegmentLength = segments
        defer { NativeMarkdownContainer.listSegmentLength = prior }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1_800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: 1_800))
        window.contentView = content
        window.orderFront(nil)
        let surface = NativeMarkdownContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 1))
        content.addSubview(surface)
        surface.update(blocks: blocks, style: .prose, capsWidth: true, streaming: false, headings: [], environment: TranscriptRowEnvironment())
        let height = surface.measure(width: 700).height
        surface.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        for _ in 0..<3 { surface.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield() }
        return (surface, window)
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// Drawn in segments, a long list is the same list: every item's text in
    /// the same place to the fraction of a point, the items as far apart as in
    /// one list, the list as tall, and the same pixels.
    @MainActor func testALongListDrawnInSegmentsIsDrawnExactlyAsOneList() async throws {
        let blocks = TranscriptMarkdown.parse(Self.longList)
        guard blocks.count == 1, case .list(true, 7, let items) = blocks[0] else { return XCTFail("the fixture is one ordered list") }
        XCTAssertEqual(items.count, 50)
        let whole = await surface(blocks, segments: .max)
        defer { whole.window.contentView = nil; whole.window.close() }
        let parts = await surface(blocks, segments: 16)
        defer { parts.window.contentView = nil; parts.window.close() }
        XCTAssertEqual(whole.surface.retainedBlockCount, 1)
        XCTAssertEqual(parts.surface.retainedBlockCount, 4, "fifty items are four segments of at most sixteen")
        XCTAssertEqual(parts.surface.measure(width: 700).height, whole.surface.measure(width: 700).height, "the segmented list is exactly as tall")
        let one = drawn(whole.surface), segmented = drawn(parts.surface)
        XCTAssertEqual(segmented.map(\.text), one.map(\.text), "the same text, in the same order, markers and numbers included")
        XCTAssertGreaterThan(one.count, 50, "every item's text, and the nested items'")
        for (a, b) in zip(one, segmented) {
            XCTAssertEqual(b.frame.minY, a.frame.minY, accuracy: 0.01, "\(a.text.debugDescription) moved")
            XCTAssertEqual(b.frame.minX, a.frame.minX, accuracy: 0.01, "\(a.text.debugDescription) moved")
            XCTAssertEqual(b.frame.height, a.frame.height, accuracy: 0.01, "\(a.text.debugDescription) changed height")
            XCTAssertEqual(b.frame.width, a.frame.width, accuracy: 0.01, "\(a.text.debugDescription) changed width")
        }
        // The pixels, as the window server has them once both are on screen.
        try await Task.sleep(for: .milliseconds(300))
        whole.window.displayIfNeeded(); parts.window.displayIfNeeded()
        let first = try XCTUnwrap(capture(whole.window)), second = try XCTUnwrap(capture(parts.window))
        XCTAssertEqual(first.width, second.width); XCTAssertEqual(first.height, second.height)
        let differing = pixelsDiffering(first, second)
        print("PERF a 50-item list in four segments against one list: \(differing) of \(first.width * first.height) pixels differ")
        XCTAssertEqual(differing, 0, "the segmented list must draw the same pixels as one list")
    }

    /// A window's pixels, from the window server.
    @MainActor private func capture(_ window: NSWindow) -> CGImage? {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: ListImage.self)
        return create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                      CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue()
    }
    private func pixelsDiffering(_ a: CGImage, _ b: CGImage) -> Int {
        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let x = rgba(a), y = rgba(b)
        var count = 0
        for pixel in stride(from: 0, to: min(x.count, y.count), by: 4) where x[pixel] != y[pixel] || x[pixel + 1] != y[pixel + 1] || x[pixel + 2] != y[pixel + 2] {
            count += 1
        }
        return count
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
        XCTAssertGreaterThan(surface.retainedBlockCount, 1, "a 40-item list is drawn in segments")
        let field = try XCTUnwrap(descendants(NSTextField.self, in: surface).first { $0.stringValue.hasPrefix("item 3 with") && $0.isSelectable })
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor())
        let selected = (field.stringValue as NSString).range(of: "code")
        editor.selectedRange = selected
        let owners = surface.blockOwnerIdentities
        for round in 0..<30 {
            source += ["\n- item next", " with", " `code`", " and", " **bold**", " text"][round % 6]
            XCTAssertNotNil(surface.appendStreaming(source, identity: "list"), "token \(round) extends the surface")
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield()
        }
        XCTAssertTrue(field.currentEditor() === editor, "the selection's field keeps its editor")
        XCTAssertEqual(editor.selectedRange, selected, "the selection stays on the same characters")
        XCTAssertTrue(descendants(NSTextField.self, in: surface).contains { $0 === field }, "the field holding the selection is the same field")
        XCTAssertEqual(surface.blockOwnerIdentities.first, owners.first, "the segment holding the selection is the same segment")
        // Copying the reply copies its source, whatever the segments.
        host.rootView = MarkdownBodyView(source: source, streaming: false, sourceIdentity: "list")
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield() }
        let whole = TranscriptCopy.targets(in: source).first { $0.kind == .whole || $0.kind == .introduction }
        XCTAssertEqual(whole?.text.contains("item 39 with `code`"), true, "the reply's copy is its source")
    }
}
