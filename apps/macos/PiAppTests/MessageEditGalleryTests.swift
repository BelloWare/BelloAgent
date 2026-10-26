import XCTest
import AppKit
@testable import PiApp

/// The composer the moment Edit is pressed on a question on screen, while
/// its complete original is still being read (EDIT-1), and once it is: at
/// the 920 pt minimum window and narrow, light and dark. While it loads, the
/// banner says so beside its spinner, in the banner's own colour rather than
/// as a refusal; the question is already in the field. Each scene checks the
/// banner stays inside the composer and off the field; with
/// `PI_APP_EDIT_GALLERY` set to a folder, each is also written there as a PNG.
final class MessageEditGalleryTests: XCTestCase {
    @MainActor func testEditBannerWhileTheOriginalLoads() async throws {
        let folder = testEnvironment("PI_APP_EDIT_GALLERY").map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let question = "Why does the parser read the stream twice when a nested block closes early? Look at module 4."
        let messages = [
            TranscriptMessage(id: "u1", role: "user", text: "What changed in the parser?", at: 1_000),
            TranscriptMessage(id: "a1", role: "assistant", text: "The parser now keeps its offsets across nested blocks.", at: 2_000),
            TranscriptMessage(id: "u2", role: "user", text: question, at: 3_000),
            TranscriptMessage(id: "a2", role: "assistant", text: "It reads the token stream again after a nested block closes early.", at: 4_000),
        ]
        for width in [920, 420] as [CGFloat] {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let pane = try ConversationPaneTests.Pane(messages: messages, width: width, height: 600)
                defer { pane.close() }
                pane.window.appearance = NSAppearance(named: appearance)
                pane.session.selectionMetadataLoaded = true
                var pending: CheckedContinuation<[String: WireValue], Error>?
                pane.model.editTargetRead = { _, id in
                    try await withCheckedThrowingContinuation { pending = $0 }
                }
                await pane.settle(16)
                pane.model.editMessage("u2", sessionID: pane.session.id)
                await pane.settle(16)
                let name = "edit-\(Int(width))"
                let banner = try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: pane.hosted).first { !$0.isHidden }, name)
                let spinner = ConversationPaneTests.views(PiSpinnerView.self, in: banner).first
                XCTAssertEqual(spinner?.isHidden, false, "\(name): the banner's spinner turns while the original loads")
                XCTAssertEqual(pane.editor?.string, question, name)
                try check(banner, in: pane, name: name)
                try write(pane, to: folder, name: "\(name)-loading-\(suffix)")
                pending?.resume(returning: ["messageId": .string("u2"), "text": .string(question), "sourceTimeline": .string("timeline"),
                                            "sourceTextDigest": .string("digest"), "legacyInputs": .bool(false)])
                try await eventually("\(name): the original is read") { !pane.session.editPreparing }
                await pane.settle(16)
                XCTAssertEqual(spinner?.isHidden, true, "\(name): the spinner stops once the original is read")
                try check(banner, in: pane, name: name)
                try write(pane, to: folder, name: "\(name)-loaded-\(suffix)")
                pane.model.cancelEdit(sessionID: pane.session.id)
            }
        }
    }

    @MainActor private func check(_ banner: ComposerEditBanner, in pane: ConversationPaneTests.Pane, name: String) throws {
        let field = try XCTUnwrap(pane.editor?.enclosingScrollView, name)
        let composer = try XCTUnwrap(ConversationPaneTests.views(ComposerInputView.self, in: pane.hosted).first, name)
        let bannerFrame = banner.convert(banner.bounds, to: nil), fieldFrame = field.convert(field.bounds, to: nil)
        XCTAssertGreaterThan(bannerFrame.height, 20, name)
        XCTAssertTrue(composer.convert(composer.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5).contains(bannerFrame), "\(name): the banner stays inside the composer")
        XCTAssertFalse(bannerFrame.intersects(fieldFrame), "\(name): the banner stays off the field")
    }

    @MainActor private func write(_ pane: ConversationPaneTests.Pane, to folder: URL?, name: String) throws {
        guard let folder else { return }
        let view = try XCTUnwrap(pane.window.contentView)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
