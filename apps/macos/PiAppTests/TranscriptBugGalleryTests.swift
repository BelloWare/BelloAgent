import AppKit
import XCTest
@testable import PiApp

final class TranscriptBugGalleryTests: XCTestCase {
    @MainActor func testHeadingCopyLiteralMarkerDiffAndFormattedFindGallery() async throws {
        guard let path = testEnvironment("PI_TRANSCRIPT_BUG_GALLERY") else { throw XCTSkip("Set PI_TRANSCRIPT_BUG_GALLERY") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(760)), ("dark", .darkAqua, 760), ("narrow", .aqua, 360)] {
            let session = SessionDisplay(id: "transcript-bug-gallery")
            let reply = TranscriptMessage(id: "reply", role: "assistant", text: TranscriptBugRegressionTests.nestedHeading + "\n\n**alpha** beta",
                tools: [try TranscriptBugRegressionTests.editTool()], at: 2, turn: "question")
            session.messages = [.init(id: "question", role: "user", text: "Review the heading, edit and formatted phrase.", at: 1), reply]
            let page = TranscriptPage(); page.state = "idle"; page.bind(session)
            for case .block(let block) in page.snapshot?.items ?? [] where block.presentation == .work {
                session.disclosure.setOpen(true, .work(block.key))
            }
            session.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", "edit")))
            let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            let document = TranscriptNativeDocument(page: page); scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            var environment = TranscriptRowEnvironment(); environment.colorScheme = appearance == .darkAqua ? .dark : .light
            document.update(snapshot: page.snapshot, actions: .init(), environment: environment, disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width); document.finishDisclosureMotion()
            for row in document.retainedRows { row.prepareToDraw(); row.layoutForViewport() }
            XCTAssertEqual(ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: document).count, 1)
            document.highlights = TranscriptHighlights(query: "alpha beta")
            scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: document).first { $0.textView.string.contains("Real") })
            let text = surface.textView, manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            let range = (text.string as NSString).range(of: "Real")
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
            surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            scroll.layoutSubtreeIfNeeded(); scroll.displayIfNeeded()
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("transcript-\(name).png"))
        }
    }
}
