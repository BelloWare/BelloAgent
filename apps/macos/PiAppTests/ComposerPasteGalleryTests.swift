import AppKit
import XCTest
@testable import PiApp

final class ComposerPasteGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testPasteRefusalNotice() async throws {
        guard let path = testEnvironment("PI_APP_PASTE_GALLERY") else { throw XCTSkip("Set PI_APP_PASTE_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(1240)), ("dark", .darkAqua, 1240), ("narrow", .aqua, 920)] {
            let fixture = try ComposerPasteRoutingTests.Fixture(kind: "main", width: width)
            defer { fixture.close() }
            let root = WorkspaceRootView(model: fixture.model)
            fixture.model.launching = false
            fixture.window.contentView = root; fixture.window.appearance = NSAppearance(named: appearance)
            fixture.window.orderFront(nil); root.refresh(); root.layoutSubtreeIfNeeded()
            let composer = try XCTUnwrap(ConversationPaneTests.views(ComposerTextView.self, in: root).first)
            let board = NSPasteboard(name: .init("paste-gallery-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            board.setData(Data([1, 2, 3]), forType: .tiff)
            XCTAssertTrue(composer.pasteAttachments(from: board))
            try await eventually("paste refusal appears") { fixture.model.error != nil }
            for _ in 0..<8 {
                root.refresh(); root.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(root.errorStrip.banner)
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("paste-refusal-\(name).png"))
        }
    }

    /// Attach Images… with a file no image decoder reads (0.1.130).
    @MainActor func testImageFileRefusalNotice() async throws {
        guard let path = testEnvironment("PI_APP_PASTE_GALLERY") else { throw XCTSkip("Set PI_APP_PASTE_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(1240)), ("dark", .darkAqua, 1240), ("narrow", .aqua, 920)] {
            let fixture = try ComposerPasteRoutingTests.Fixture(kind: "main", width: width)
            defer { fixture.close() }
            let root = WorkspaceRootView(model: fixture.model)
            fixture.model.launching = false
            fixture.window.contentView = root; fixture.window.appearance = NSAppearance(named: appearance)
            fixture.window.orderFront(nil); root.refresh(); root.layoutSubtreeIfNeeded()
            let file = fixture.root.appendingPathComponent("Quarterly scan.heic")
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try Data("Generated text, not an image".utf8).write(to: file)
            fixture.model.questions.chooseFiles = { [file] }
            fixture.model.attachImages(sessionID: fixture.session.id)
            try await eventually("file refusal appears") { fixture.model.error != nil }
            XCTAssertTrue(fixture.model.error?.contains("could not be read as an image") == true, fixture.model.error ?? "")
            for _ in 0..<8 {
                root.refresh(); root.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(root.errorStrip.banner)
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("image-file-refusal-\(name).png"))
        }
    }
}
