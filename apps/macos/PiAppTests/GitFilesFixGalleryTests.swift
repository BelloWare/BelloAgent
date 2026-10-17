import AppKit
import XCTest
@testable import PiApp

@MainActor final class GitFilesFixGalleryTests: XCTestCase, SerialTestLane {
    func testPreviewInverseTextAndCoveredTerminalGallery() async throws {
        guard let path = testEnvironment("PI_GITFILES_FIX_GALLERY") else { throw XCTSkip("Set PI_GITFILES_FIX_GALLERY to capture") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await TerminalPageFixture()
        defer { fixture.close() }
        let imageURL = fixture.root.appendingPathComponent("Updated image.bmp")
        try FilePreviewRefreshTests.bitmap(red: false).write(to: imageURL)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for width: CGFloat in [1240, 920] {
                fixture.window.appearance = NSAppearance(named: appearance)
                fixture.window.setContentSize(NSSize(width: width, height: 800))
                fixture.model.page = .chats
                fixture.model.terminalVisible = false
                try await eventually("terminal finished closing in gallery") {
                    fixture.window.contentView?.layoutSubtreeIfNeeded()
                    return fixture.session.view.window == nil
                }
                let preview = fixture.model.openFile(imageURL)
                fixture.model.tabs.activate(preview)
                await fixture.settle()
                try await eventually("preview visible in gallery") { preview.preview.image != nil }
                try capture(fixture.window, to: folder.appendingPathComponent("preview-\(name)-\(Int(width)).png"))

                fixture.model.terminalVisible = true
                fixture.model.tabs.close(preview)
                await fixture.settle()
                fixture.session.emulator.feed("\u{1b}[2J\u{1b}[H\u{1b}[?25lNormal then inverse:\r\n\u{1b}[0mA\u{1b}[7mA\u{1b}[1m \u{1b}[0m\r\nInverse then normal:\r\n\u{1b}[7mA\u{1b}[0mA\u{1b}[1m \u{1b}[0m\r\n")
                fixture.session.view.refresh()
                await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent("terminal-\(name)-\(Int(width)).png"))
                fixture.model.openReport()
                await fixture.settle()
                XCTAssertFalse(fixture.window.firstResponder === fixture.session.view)
                try capture(fixture.window, to: folder.appendingPathComponent("report-\(name)-\(Int(width)).png"))
            }
        }
    }
    private func capture(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
