import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// A rendered reply is one text: a selection runs across its blocks, a copy
/// is the text it covers, and a token changes only what it adds.
final class MarkdownTextSurfaceTests: XCTestCase {
    static let sample = """
    ## Retry budget

    The **retry budget** caps how often a failed request is sent again, and the *jitter* spreads those retries out. See [the docs](https://example.com/retries) and `RetryPolicy`.

    - Count every attempt, including the first
    - Back off between attempts:
      1. start at 200 ms
      2. double each time
    - Stop at the budget

    > A quoted note about retries,
    > spanning two lines.

    ```swift
    func send(_ request: Request) async throws -> Response {
        // retry with jitter
        return try await client.send(request, attempt: 1)
    }
    ```

    | Attempt | Delay | Result |
    |:--|--:|:-:|
    | 1 | 0 ms | failed |
    | 2 | 200 ms | ok |

    That is the whole policy.
    """

    @MainActor static func surface(_ source: String, width: CGFloat = 760, streaming: Bool = false, scheme: ColorScheme = .light,
                                   headings: [MarkdownCopyTarget] = []) -> (NativeMarkdownContainer, NSWindow) {
        let surface = NativeMarkdownContainer(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        var values = EnvironmentValues(); values.colorScheme = scheme
        surface.read(source: source, style: .prose, capsWidth: true, streaming: streaming, headings: headings,
                     environment: TranscriptRowEnvironment(values), identity: "reply")
        let height = surface.measure(width: width).height
        surface.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 40, height: height + 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 40, height: height + 40))
        content.wantsLayer = true
        content.layer?.backgroundColor = (scheme == .dark ? NSColor(srgbRed: 0.18, green: 0.16, blue: 0.145, alpha: 1) : NSColor.white).cgColor
        window.contentView = content
        surface.frame.origin = NSPoint(x: 20, y: 20)
        content.addSubview(surface)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        content.layoutSubtreeIfNeeded()
        return (surface, window)
    }

    /// Renders the sample for a person to look at, when asked to.
    @MainActor func testRenderSampleForReview() throws {
        guard let directory = testEnvironment("PI_MARKDOWN_SNAPSHOT_DIR") else { throw XCTSkip("Set PI_MARKDOWN_SNAPSHOT_DIR to render") }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let (surface, window) = Self.surface(Self.sample, scheme: scheme)
            let view = window.contentView!
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown-\(name).png"))
            withExtendedLifetime(surface) {}
        }
    }

    /// One selection runs from the heading to the last paragraph, and its
    /// copy is the reply as it reads.
    @MainActor func testASelectionRunsAcrossEveryBlockAndCopiesAsItReads() throws {
        let (surface, window) = Self.surface(Self.sample)
        let text = surface.textView
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        let copied = text.copyText(text.selectedRanges.map(\.rangeValue))
        XCTAssertTrue(copied.hasPrefix("Retry budget\n\nThe retry budget caps"), copied)
        XCTAssertTrue(copied.contains("- Count every attempt, including the first\n- Back off between attempts:\n  1. start at 200 ms\n  2. double each time\n- Stop at the budget"), copied)
        XCTAssertTrue(copied.contains("func send(_ request: Request) async throws -> Response {\n    // retry with jitter"), copied)
        XCTAssertTrue(copied.contains("Attempt\tDelay\tResult\n1\t0 ms\tfailed\n2\t200 ms\tok"), copied)
        XCTAssertTrue(copied.hasSuffix("That is the whole policy."), copied)
        withExtendedLifetime(window) {}
    }

    /// The controls on the text come with the pointer: over a fence, its
    /// toolbar with its language and a copy of its whole code; over a heading,
    /// its section's copy button; and they go when the pointer leaves.
    @MainActor func testTheFencesToolbarAndAHeadingsCopyButtonComeWithThePointer() throws {
        let headings = TranscriptCopy.targets(in: Self.sample).filter { if case .section = $0.kind { return true }; return false }
        XCTAssertFalse(headings.isEmpty)
        let (surface, window) = Self.surface(Self.sample, headings: headings)
        let text = surface.textView
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        func point(over phrase: String) -> NSPoint {
            let range = (text.string as NSString).range(of: phrase)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX, y: rect.midY + text.topInset)
        }
        func move(to point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            surface.mouseMoved(with: event)
        }
        func toolbar() -> NSHostingView<MarkdownCodeToolbar>? { surface.subviews.compactMap { $0 as? NSHostingView<MarkdownCodeToolbar> }.first }
        func headingButton() -> NSHostingView<MarkdownHeadingAction>? { surface.subviews.compactMap { $0 as? NSHostingView<MarkdownHeadingAction> }.first }
        XCTAssertNil(toolbar()); XCTAssertNil(headingButton())
        try move(to: point(over: "func send"))
        let bar = try XCTUnwrap(toolbar(), "the fence's toolbar")
        XCTAssertEqual(bar.rootView.language, "swift")
        XCTAssertTrue(bar.rootView.code.hasPrefix("func send(_ request: Request)") && bar.rootView.code.hasSuffix("}"), "it copies the whole code")
        XCTAssertLessThan(bar.frame.minY, surface.convert(point(over: "func send"), to: surface).y, "above the code, in the fence's padding")
        XCTAssertNil(headingButton())
        try move(to: point(over: "Retry budget"))
        XCTAssertNil(toolbar())
        let copy = try XCTUnwrap(headingButton(), "the heading's copy button")
        XCTAssertEqual(copy.rootView.target, headings[0])
        try move(to: point(over: "That is the whole policy"))
        XCTAssertNil(toolbar()); XCTAssertNil(headingButton())
        withExtendedLifetime(window) {}
    }

    /// The text as drawn: each run's characters, face, colour and paragraph
    /// style, without the marks that name objects.
    @MainActor static func dress(_ surface: NativeMarkdownContainer) -> [String] {
        guard let storage = surface.textView.textStorage else { return [] }
        var runs: [String] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let font = (attributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" } ?? "-"
            let color = (attributes[.foregroundColor] as? NSColor).map { "\(ObjectIdentifier($0))" } ?? "-"
            let style = (attributes[.paragraphStyle] as? NSParagraphStyle).map { "\($0.firstLineHeadIndent)/\($0.headIndent)/\($0.paragraphSpacingBefore)/\($0.lineSpacing)" } ?? "-"
            runs.append("\((storage.string as NSString).substring(with: range))|\(font)|\(color)|\(style)")
        }
        return runs
    }

    /// A fence streamed a token at a time — keywords completed across
    /// tokens, a comment opened and closed — reads, and is coloured, exactly
    /// as the same fence drawn whole.
    @MainActor func testAFenceStreamedTokenByTokenReadsAsTheFenceDrawnWhole() throws {
        let final = "Before the code.\n\n```swift\nfunc send(_ request: Request) async throws -> Response {\n    /* a block\n       comment */ let value = 42 // done\n    return try await client.send(request)\n}"
        var source = "Before the code.\n\n```swift\nfu"
        let (streamed, window) = Self.surface(source, streaming: true)
        var index = source.utf8.count
        let bytes = Array(final.utf8)
        while index < bytes.count {
            let next = min(bytes.count, index + 3)
            source = String(decoding: bytes[..<next], as: UTF8.self)
            _ = streamed.appendStreaming(source, identity: "reply")
            index = next
        }
        let (whole, other) = Self.surface(final, streaming: true)
        XCTAssertEqual(streamed.textView.string, whole.textView.string)
        XCTAssertEqual(Self.dress(streamed), Self.dress(whole))
        XCTAssertLessThan(streamed.lastReplacedLength, 100, "a token set only its own line again, not the fence")
        withExtendedLifetime((window, other)) {}
    }

    /// A reply that settles with a reference defined at its end reads its
    /// first paragraph anew; a selection in the paragraph after it stays on
    /// the same words though the characters before them changed.
    @MainActor func testASelectionAfterABlockThatReadsAnewStaysOnItsWords() throws {
        let streaming = "First [label][ref] here.\n\nSecond paragraph with the chosen words.\n\n"
        let (surface, window) = Self.surface(streaming, streaming: true)
        let text = surface.textView
        let chosen = (text.string as NSString).range(of: "chosen words")
        text.setSelectedRange(chosen)
        surface.read(source: streaming + "[ref]: https://example.com/target\n", style: .prose, capsWidth: true, streaming: false,
                     headings: [], environment: TranscriptRowEnvironment(), identity: "reply")
        XCTAssertTrue(text.string.hasPrefix("First label here."), text.string)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "chosen words")
        XCTAssertLessThan(surface.lastReplacedLength, 20, "only the paragraph that reads anew was set again")
        withExtendedLifetime(window) {}
    }

    /// SwiftUI's and TextKit's line pitch for each face the rows used, to set
    /// the text at the rows' measure.
    @MainActor func testMeasureLinePitches() throws {
        guard testEnvironment("PI_MARKDOWN_SNAPSHOT_DIR") != nil else { throw XCTSkip("A measurement, run on request") }
        let faces: [(String, Font, NSFont, CGFloat)] = [
            ("prose 14.5", .system(size: 14.5), MarkdownTextFonts.font(size: 14.5), 14.5 * 0.35),
            ("bold 14.5", .system(size: 14.5, weight: .semibold), MarkdownTextFonts.font(size: 14.5, weight: .semibold), 14.5 * 0.35),
            ("heading 18.85 serif", .system(size: 18.85, weight: .semibold, design: .serif), MarkdownTextFonts.font(size: 18.85, weight: .semibold, serif: true), 14.5 * 0.35),
            ("code 12.47 mono", .system(size: 12.47, design: .monospaced), MarkdownTextFonts.font(size: 12.47, monospaced: true), 12.47 * 0.4),
            ("cell 13.05", .system(size: 13.05), MarkdownTextFonts.font(size: 13.05), 0),
            ("reasoning 13", .system(size: 13), MarkdownTextFonts.font(size: 13), 13 * 0.35),
        ]
        for (name, font, nsFont, spacing) in faces {
            func swiftUI(_ lines: Int) -> CGFloat {
                let text = Array(repeating: "Word", count: lines).joined(separator: "\n")
                let host = NSHostingView(rootView: Text(text).font(font).lineSpacing(spacing).fixedSize())
                return host.fittingSize.height
            }
            func textKit(_ lines: Int) -> CGFloat {
                let style = NSMutableParagraphStyle(); style.lineSpacing = spacing
                let storage = NSTextStorage(string: Array(repeating: "Word", count: lines).joined(separator: "\n"), attributes: [.font: nsFont, .paragraphStyle: style])
                let manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 400, height: 10_000)); container.lineFragmentPadding = 0
                storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
                return manager.usedRect(for: container).height
            }
            let s1 = swiftUI(1), s10 = swiftUI(10), t1 = textKit(1), t10 = textKit(10)
            print(String(format: "MEASURE %@: SwiftUI line %.3f pitch %.3f | TextKit line %.3f pitch %.3f", name, s1, (s10 - s1) / 9, t1, (t10 - t1) / 9))
        }
    }

    /// What a token costs on an open list, by the list's length.
    @MainActor func testMeasureTokenCostOnOpenLists() throws {
        guard testEnvironment("PI_MARKDOWN_SNAPSHOT_DIR") != nil else { throw XCTSkip("A measurement, run on request") }
        for items in [20, 400] {
            var source = "A list:\n\n" + (1...items).map { "- Item \($0) explains one more step of the plan in a sentence." }.joined(separator: "\n") + "\n- Last"
            let (surface, window) = Self.surface(source, streaming: true)
            let started = ProcessInfo.processInfo.systemUptime
            for word in 0..<100 {
                source += " word\(word)"
                _ = surface.appendStreaming(source, identity: "reply")
            }
            let perToken = (ProcessInfo.processInfo.systemUptime - started) * 1000 / 100
            print(String(format: "MEASURE open list of %d items: %.3f ms per token, %d characters replaced last", items, perToken, surface.lastReplacedLength))
            withExtendedLifetime(window) {}
        }
        func measure(_ name: String, _ start: String, _ token: (Int) -> String) {
            var source = start
            let (surface, window) = Self.surface(source, streaming: true)
            TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
            defer { TranscriptLayoutClock.recording = false }
            let began = ProcessInfo.processInfo.systemUptime
            for index in 0..<100 { source += token(index); _ = surface.appendStreaming(source, identity: "reply") }
            print(String(format: "MEASURE %@: %.3f ms per token over %d characters (reading %.3f, update %.3f, layout %.3f)", name,
                         (ProcessInfo.processInfo.systemUptime - began) * 10, surface.textLength,
                         TranscriptLayoutClock.markdownReadingSeconds * 10, TranscriptLayoutClock.markdownUpdateSeconds * 10, TranscriptLayoutClock.markdownLayoutSeconds * 10))
            withExtendedLifetime(window) {}
        }
        for count in [120, 1_150] {
            let blocks = (1...count).map { "Paragraph \($0) of a long reply, with **bold** and `code` in it." }.joined(separator: "\n\n")
            measure("paragraph after \(count) blocks", blocks + "\n\nThe last", { " word\($0)" })
        }
        let code = "```swift\n" + (1...400).map { "let value\($0) = try await client.send(request, attempt: \($0)) // retry" }.joined(separator: "\n")
        measure("open 30 KB swift fence", code, { $0 % 5 == 0 ? "\nlet more\($0) = 1" : " + \($0)" })
        let table = "| Attempt | Delay | Result |\n|--|--|--|\n" + (1...100).map { "| \($0) | \($0 * 10) ms | ok |" }.joined(separator: "\n")
        measure("open 100-row table", table, { $0 % 4 == 0 ? "\n| \($0) | x" : " y" })
    }

    /// A token adds its own characters: the text before it is not replaced,
    /// and a selection there stays on the same characters.
    @MainActor func testATokenReplacesOnlyWhatItAddsAndKeepsASelectionAboveIt() throws {
        let start = Self.sample + " More"
        let (surface, window) = Self.surface(start, streaming: true)
        let text = surface.textView
        let selected = NSRange(location: 5, length: 40)
        text.setSelectedRange(selected)
        let before = text.string.utf16.count
        let grown = try XCTUnwrap(surface.appendStreaming(start + " words arrive", identity: "reply"))
        XCTAssertGreaterThanOrEqual(grown, 0)
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertGreaterThanOrEqual(surface.lastReplacedLocation, before - 5, "Only the end of the reply was set again")
        XCTAssertTrue(text.string.hasSuffix("More words arrive"))
        withExtendedLifetime(window) {}
    }
}
