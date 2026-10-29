import AppKit
import XCTest
@testable import PiApp

final class OpeningProgressGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testOpeningScenes() async throws {
        guard let path = testEnvironment("PI_APP_OPENING_GALLERY") else { throw XCTSkip("Set PI_APP_OPENING_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        let f = try await OpeningPaneFixture()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        let rows = f.session.messages, previous = NSApp.appearance
        f.window.orderFront(nil)
        defer { NSApp.appearance = previous; f.close() }
        let progress = HostCommandProgress(completed:37,total:100)
        for name in ["pending", "progress", "cancelling", "cancelled", "failure", "cover"] {
            f.session.helperOpening = nil; f.draw()
            f.session.messages = name == "cover" ? [] : rows
            f.session.dropAllSending(); f.session.sendFailure = nil
            f.session.draft = ""; f.session.historyState = name == "cover" ? .loading : .ready
            f.session.loading = !["cancelled", "failure"].contains(name)
            f.session.helperOpeningActions = f.session.loading ? 1 : 0
            if f.session.loading, name != "cover" {
                f.session.showSending(.init(id:"pending-send",role:"user",text:OpeningPaneFixture.draft,turn:"pending-send"))
            }
            switch name {
            case "pending": f.session.helperOpening = .opening(nil)
            case "progress", "cover": f.session.helperOpening = .opening(progress)
            case "cancelling": f.session.helperOpening = .cancelling(progress)
            case "cancelled":
                f.session.helperOpening = .cancelled; f.session.draft = OpeningPaneFixture.draft
                f.session.sendFailure = "Opening cancelled. Your message was not sent."
            default:
                f.session.helperOpening = .failed("The project host disconnected while opening this chat.")
                f.session.draft = OpeningPaneFixture.draft
                f.session.sendFailure = "The project host disconnected while opening this chat."
            }
            f.draw(); await f.drawAfterThreshold()
            for width: CGFloat in [840,320] {
                f.window.setContentSize(CGSize(width:width,height:600))
                for (theme, appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                    NSApp.appearance = NSAppearance(named:appearance); f.window.appearance = NSAppearance(named:appearance)
                    f.draw(); f.pane.needsDisplay = true; f.window.displayIfNeeded(); CATransaction.flush()
                    try await Task.sleep(for:.milliseconds(120))
                    for status in f.openingViews where !status.isHidden {
                        status.layoutSubtreeIfNeeded()
                        XCTAssertTrue(status.bounds.contains(status.action.frame))
                        XCTAssertTrue(status.bounds.contains(status.progress.frame))
                        XCTAssertEqual(status.inCover, name == "cover")
                    }
                    XCTAssertNotNil(f.editor, "The gallery includes the actual composer")
                    let image = try XCTUnwrap(f.pane.bitmapImageRepForCachingDisplay(in:f.pane.bounds))
                    f.pane.cacheDisplay(in:f.pane.bounds,to:image)
                    try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("pane-opening-\(name)-\(Int(width))-\(theme).png"))
                }
            }
        }
    }
}
