import AppKit
import XCTest
@testable import PiApp

final class OpeningProgressGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testOpeningScenes() async throws {
        guard let path = testEnvironment("PI_APP_OPENING_GALLERY") else { throw XCTSkip("Set PI_APP_OPENING_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = SessionOpeningView()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 840, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; window.contentView = nil; window.close() }
        let progress = HostCommandProgress(completed: 37, total: 100)
        let scenes: [(String, SessionOpeningState)] = [
            ("progress", .opening(progress)), ("legacy", .opening(nil)), ("cancelling", .cancelling(progress)),
            ("cancelled", .cancelled), ("failure", .failed("The project host disconnected while opening this chat. Your message was not sent."))]
        for (name, state) in scenes {
            var presses = 0
            view.update(state, cancel: { presses += 1 }, retry: { presses += 1 })
            if !state.cancelling { view.action.performClick(nil); XCTAssertEqual(presses, 1) }
            for width: CGFloat in [840, 320] {
                window.setContentSize(CGSize(width: width, height: 520))
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance); window.appearance = NSAppearance(named: appearance)
                    view.needsLayout = true; view.needsDisplay = true; view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                    try await Task.sleep(for: .milliseconds(120))
                    XCTAssertTrue(view.bounds.contains(view.action.frame), "The action fits at \(width)")
                    if state.progress != nil { XCTAssertTrue(view.bounds.contains(view.progress.frame)) }
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("opening-\(name)-\(Int(width))-\(theme).png"))
                }
            }
        }
    }
}
