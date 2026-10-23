import AppKit
import XCTest
@testable import PiApp

final class NativeMarkdownDrawingTests: XCTestCase, SerialTestLane {
    /// Row heights and stored characters do not prove that AppKit drew the
    /// words. Inspect the window's pixels inside each prose view, including
    /// a reused reader whose appearance and width have changed.
    @MainActor func testPausedSubagentTextIsDrawnAtEveryWidthAndAppearance() async throws {
        let previous = TranscriptDisplay.mode
        TranscriptDisplay.use(.normal)
        defer { TranscriptDisplay.use(previous) }
        let output = testEnvironment("PI_MARKDOWN_DRAWING_GALLERY").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("markdown-drawing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if testEnvironment("PI_MARKDOWN_DRAWING_GALLERY") == nil {
            addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        }
        let fixture = try SubagentGalleryFixture(root: output.appendingPathComponent("fixture-" + UUID().uuidString))
        registerWorkspaceFixtureTeardown(fixture.model, root: fixture.root)
        defer { fixture.close() }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (width, height) in [(700.0, 600.0), (920, 600), (1240, 800)] {
                fixture.window.appearance = NSAppearance(named: appearance)
                fixture.window.setContentSize(NSSize(width: width, height: height))
                for scene in ["family-cost-limit", "family-cost-limit-raised", "child-cost-paused"] {
                    fixture.show(scene); await fixture.settle()
                    let session = scene == "child-cost-paused" ? fixture.child : fixture.parent
                    let notice = try XCTUnwrap(session.presentedMessages.last)
                    let revealed = await fixture.model.revealInTranscript(sessionID: session.id, messageID: notice.id)
                    XCTAssertTrue(revealed); await fixture.settle()
                    guard scene == "child-cost-paused" else { continue }
                    let file = output.appendingPathComponent("\(scene)-\(name)-\(Int(width)).png")
                    try SessionStatsPopoverTests.capture(fixture.window, to: file)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
                    let texts = ConversationPaneTests.views(MarkdownTextView.self, in: fixture.content).filter {
                        !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && !$0.string.isEmpty
                    }
                    XCTAssertEqual(texts.count, 2, "\(name) \(width): the delegated task and reply are visible")
                    for text in texts {
                        let rect = text.convert(text.visibleRect, to: nil)
                        let scale = CGFloat(bitmap.pixelsWide) / fixture.window.frame.width
                        let pixels = CGRect(x: rect.minX * scale, y: (fixture.window.frame.height - rect.maxY) * scale,
                                            width: rect.width * scale, height: rect.height * scale).integral
                        var ink = 0
                        for y in max(0, Int(pixels.minY))..<min(bitmap.pixelsHigh, Int(pixels.maxY)) {
                            for x in max(0, Int(pixels.minX))..<min(bitmap.pixelsWide, Int(pixels.maxX)) {
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                                if name == "dark" ? min(color.redComponent, color.greenComponent, color.blueComponent) > 0.6
                                    : max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 { ink += 1 }
                            }
                        }
                        print("DRAW \(name) \(Int(width)) \(text.string.prefix(30)): frame=\(text.frame) container=\(text.textContainer?.containerSize ?? .zero) unlaid=\(text.layoutManager?.firstUnlaidGlyphIndex() ?? -1) ink=\(ink)")
                        XCTAssertGreaterThan(ink, 100, "\(name) \(width): no text drawn for \(text.string.prefix(50)); \(file.path)")
                    }
                }
            }
        }
    }
}
