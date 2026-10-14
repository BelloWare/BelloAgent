import XCTest
import AppKit
@testable import PiApp
import GitView

/// Standalone Git scenes: no UIScreenshotTests gateway or installed app.
final class GitHunkGalleryTests: XCTestCase {
    @MainActor func testHunkReviewScenes() async throws {
        let folder = ProcessInfo.processInfo.environment["PI_APP_HUNK_GALLERY"].map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for (name, width, height, binary, stage) in [
            ("hunks-wide", 1180.0, 760.0, false, 0),
            ("hunks-920", 920.0, 600.0, false, 0),
            ("hunks-staged-offer", 1180.0, 760.0, false, 1),
            ("hunks-binary", 920.0, 600.0, true, 0),
            ("hunks-index", 920.0, 600.0, false, 2),
            ("hunks-final-offer", 920.0, 600.0, false, 3)
        ] {
            let scene = try GitHunkScene(width: width, height: height, binary: binary); defer { scene.close() }
            if binary {
                try await eventually("unavailable reason", timeout: .seconds(30)) {
                    scene.draw()
                    return scene.find(DiffView.self).contains { $0.hunkReview?.message.hasPrefix("Hunks unavailable.") == true }
                }
            } else {
                let model = try await scene.ready()
                if stage > 0, let review = model.review {
                    model.activate(0, reviewID: review.id)
                    try await eventually("staged offer", timeout: .seconds(30)) { scene.draw(); return !model.busy && model.stagedPath != nil && model.review != nil }
                    if stage == 2 {
                        model.reviewStaged()
                        try await eventually("index review", timeout: .seconds(30)) { scene.draw(); return model.enabled && model.review?.staged == true }
                    } else if stage == 3, let remaining = model.review {
                        model.activate(0, reviewID: remaining.id)
                        try await eventually("final hunk offer", timeout: .seconds(30)) { scene.draw(); return !model.busy && model.stagedPath != nil }
                    }
                }
            }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                scene.window.appearance = NSAppearance(named: appearance); scene.draw()
                try await Task.sleep(for: .milliseconds(150)); scene.draw()
                for button in scene.find(GitHunkToolbar.self).flatMap({ [$0.previous, $0.next] }) {
                    XCTAssertTrue(button.frame.width > 0)
                    XCTAssertLessThanOrEqual(button.frame.maxX, button.superview!.bounds.width + 0.5)
                }
                if let folder { try save(scene.panel, to: folder.appendingPathComponent(name + "-" + suffix + ".png")) }
            }
        }
        // A narrow detached diff pane, in both layouts and appearances.
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(), review = try XCTUnwrap(model.review)
        let diff = DiffView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        diff.bindHunkReview(scene.controller)
        let window = NSWindow(contentRect: diff.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = diff; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for split in [false, true] {
            diff.show(files: review.files, title: "review.swift", subtitle: "Working tree versus index", identity: GitController.diffIdentity(path: "review.swift", staged: false), split: split,
                      setSplit: { _ in }, expanded: nil, setExpanded: { _ in })
            try await eventually("narrow hunk review", timeout: .seconds(30)) { diff.layoutSubtreeIfNeeded(); return diff.hunkReview?.enabled == true }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance); diff.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150)); diff.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if let folder { try save(diff, to: folder.appendingPathComponent("hunks-narrow-\(split ? "split" : "unified")-\(suffix).png")) }
            }
        }
    }
    @MainActor private func save(_ view: NSView, to path: URL) throws {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path)
    }
}
