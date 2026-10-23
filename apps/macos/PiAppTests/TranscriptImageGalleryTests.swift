import XCTest
import AppKit
@testable import PiApp

final class TranscriptImageGalleryTests: XCTestCase {
    @MainActor func testSentImagesAndOwnViewerInMainAndSide() async throws {
        guard let path = testEnvironment("PI_APP_IMAGE_GALLERY") else { throw XCTSkip("Set PI_APP_IMAGE_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for kind in ["main", "side"] {
            for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(1000)), ("dark", .darkAqua, 1000), ("narrow", .aqua, 420)] {
                let fixture = try ComposerPasteRoutingTests.Fixture(kind: kind, width: width)
                defer { fixture.close() }
                fixture.window.setContentSize(CGSize(width: width, height: 900))
                let journal = try TranscriptImageLoadingTests.Journal(root: fixture.root.appendingPathComponent("images"), sessionID: fixture.session.id)
                if var side = fixture.model.side(fixture.session.id) {
                    side.pending = false; side.kept = true
                    fixture.model.sides[side.parentID] = side
                    var saved = side.chat; saved.path = journal.path.path
                    fixture.model.chats.append(saved)
                }
                fixture.session.messages = try await fixture.model.history.read(path: journal.path.path).messages
                fixture.session.draft = "The images stay visible after sending."
                fixture.window.appearance = NSAppearance(named: appearance)
                fixture.pane.show(session: fixture.session, chat: try XCTUnwrap(fixture.model.record(fixture.session.id)), side: fixture.model.side(fixture.session.id))
                fixture.window.orderFront(nil)
                for _ in 0..<8 {
                    fixture.pane.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let buttons = TranscriptImageRowTests.views(TranscriptImageButton.self, in: fixture.pane)
                XCTAssertEqual(buttons.count, 4, "The captioned and image-only messages each show two thumbnails")
                try await eventually("gallery thumbnails decoded") { buttons.allSatisfy { $0.bitmap != nil } }
                for button in buttons {
                    let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: fixture.pane.superview)
                    XCTAssertTrue(fixture.pane.hitTest(point) === button, "The visible thumbnail receives the pointer")
                }
                try capture(fixture.pane, to: folder.appendingPathComponent("sent-images-\(kind)-\(name).png"))
                if kind == "main" {
                    if name == "light" { XCTAssertTrue(try XCTUnwrap(buttons.first).accessibilityPerformPress()) }
                    else { try XCTUnwrap(buttons.first).performClick(nil) }
                    try await eventually("the app's image viewer opens") { fixture.window.attachedSheet != nil }
                    let window = try XCTUnwrap(fixture.window.attachedSheet)
                    let viewer = try XCTUnwrap(TranscriptImageRowTests.views(TranscriptImageViewer.self, in: try XCTUnwrap(window.contentView)).first)
                    try await eventually("the viewer's image arrives") { viewer.preview.image != nil }
                    XCTAssertEqual(TranscriptImageRowTests.views(FilePreviewView.self, in: viewer).count, 1)
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try capture(try XCTUnwrap(window.contentView), to: folder.appendingPathComponent("sent-image-viewer-\(name).png"))
                    let close = try XCTUnwrap(TranscriptImageRowTests.views(PiKit.Button.self, in: viewer).first { $0.title == "Close" })
                    close.performClick(nil)
                    try await eventually("viewer closes") { fixture.window.attachedSheet == nil }
                }
            }
        }
    }
    @MainActor private func capture(_ view: NSView, to path: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
