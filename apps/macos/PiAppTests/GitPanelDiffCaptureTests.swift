import XCTest
import SwiftUI
import AppKit
@testable import PiApp


extension GitPanelAuditTests {
    /// A picture of the diff pane, unified and side by side, light and dark,
    /// so the card chrome around lazily built rows can be looked at.
    @MainActor func testCaptureTheDiffPaneWhenRequested() throws {
        guard let root = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else {
            throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT to capture the diff pane")
        }
        let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let patch = """
        diff --git a/Sources/Engine/Router.swift b/Sources/Engine/Router.swift
        --- a/Sources/Engine/Router.swift
        +++ b/Sources/Engine/Router.swift
        @@ -18,9 +18,12 @@ struct Router {
             let profile: Profile
        -    var timeout: Duration = .seconds(30)
        -    func route(_ request: Request) throws -> Route {
        +    var timeout: Duration = .seconds(45)
        +    var retries = 2
        +    func route(_ request: Request, attempt: Int = 0) throws -> Route {
                 guard let host = request.host else { throw RouterError.noHost }
        -        return Route(host: host, timeout: timeout)
        +        let budget = timeout / Duration.seconds(max(1, retries - attempt))
        +        return Route(host: host, timeout: budget)
             }
         }
        """
        let files = GitDiffParser.parse(patch + "\n")
        XCTAssertEqual(files.count, 1)
        for split in [false, true] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let holder = DiffHolder()
                let view = DiffView(files: files, title: "Sources/Engine/Router.swift", subtitle: "Working tree versus index", identity: "capture",
                                    split: Binding(get: { split }, set: { _ in }), expanded: Binding(get: { holder.expanded }, set: { holder.expanded = $0 }))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = NSHostingView(rootView: view)
                window.makeKeyAndOrderFront(nil)
                defer { window.contentView = nil; window.close() }
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                let representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: representation)
                let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("13-git-diff-\(split ? "split" : "unified")-\(name).png"), options: .atomic)
            }
        }
    }
}
