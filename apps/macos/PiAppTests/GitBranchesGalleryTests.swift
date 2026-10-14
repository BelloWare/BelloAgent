import XCTest
import AppKit
@testable import PiApp
@testable import GitView

/// Generated local repositories only; no application model, gateway or vault.
final class GitBranchesGalleryTests: XCTestCase {
    @MainActor func testBranchesCompareStashAndConfirmations() async throws {
        let folder = ProcessInfo.processInfo.environment["PI_APP_BRANCHES_GALLERY"].map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for (sizeName, width, height) in [("wide", 1180.0, 760.0), ("920", 920.0, 600.0), ("narrow", 420.0, 600.0)] {
            let scene = try GitBranchesScene(width: width, height: height); defer { scene.close() }
            let branch = try await scene.repo.divergedBranch(); try scene.repo.origin(branch: "topic")
            try scene.repo.git(["branch", "feature/review-stash-and-checkout-behavior"])
            try scene.repo.write("main.txt", "On the current branch\n"); try scene.repo.commit("Keep keyboard selection visible in narrow panes")
            try scene.repo.write("f.txt", "Saved review changes\n"); try scene.repo.write("notes.md", "# Review notes\n\nKeep local work safe.\n")
            _ = try await scene.repo.service.createStash(message: "Review branch tools before switching", includeUntracked: true, keepIndex: false, in: scene.repo.path)
            try await scene.ready()
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                scene.window.appearance = NSAppearance(named: appearance)
                let popup = try await scene.openBranches()
                try await capture(popup, "branches-\(sizeName)-\(suffix)", folder)
                popup.search.text = "origin/"; popup.filter("origin/")
                try await capture(popup, "branches-search-\(sizeName)-\(suffix)", folder)
                scene.tools.close()
                let compare = GitBranchCompare(service: scene.repo.service, root: scene.repo.path, branch: branch, valid: { true })
                let compareSheet = PiKit.Sheet("Compare with Current", subtitle: "main ↔ topic", symbol: "arrow.triangle.branch", content: compare, actions: [PiKit.Button("Close", style: .ghost, compact: true)])
                scene.host.addSubview(compareSheet); compareSheet.frame = scene.host.bounds
                try await eventually("comparison rows", timeout: .seconds(30)) { compare.note.line.text.contains("read only") }
                try await capture(compareSheet, "compare-\(sizeName)-\(suffix)", folder)
                compare.cancel(); compareSheet.removeFromSuperview()
                let stash = GitStashList(service: scene.repo.service, root: scene.repo.path, valid: { true })
                let stashSheet = PiKit.Sheet("Stashes", subtitle: "Saved work in this repository", symbol: "tray.and.arrow.down", content: stash, actions: [PiKit.Button("New Stash…", style: .secondary, compact: true)])
                scene.host.addSubview(stashSheet); stashSheet.frame = scene.host.bounds
                try await eventually("stash diff", timeout: .seconds(30)) { !stash.preview.isEmpty }
                try await capture(stashSheet, "stash-preview-\(sizeName)-\(suffix)", folder)
                stash.cancel(); stashSheet.removeFromSuperview()
                let form = GitRepositoryForm(placeholder: "Message (optional)", value: "Continue review after checkout", detail: "Save local changes so they can be applied later.", action: "Stash", stashOptions: true)
                let formSheet = PiKit.Sheet("New Stash", symbol: "tray.and.arrow.down", content: form)
                formSheet.frame = CGRect(x: 0, y: 0, width: min(width, 460), height: 330); scene.host.addSubview(formSheet)
                try await capture(formSheet, "new-stash-\(sizeName)-\(suffix)", folder)
                formSheet.removeFromSuperview()
                let question = PiQuestion.alert(title: "Delete unmerged branch topic?", detail: "1 commit on topic is not in main. Deleting its branch and reflog may make this commit unreachable.\n\n\(branch.oid.prefix(7))  Topic only", action: "Delete Unmerged Branch", cancel: "Cancel", destructive: true, cancelIsDefault: true)
                question.window.appearance = NSAppearance(named: appearance); question.layout(); question.window.orderFront(nil)
                if let content = question.window.contentView { try await capture(content, "confirm-delete-\(sizeName)-\(suffix)", folder) }
                question.window.orderOut(nil)
                let drop = PiQuestion.alert(title: "Drop stash@{0}?", detail: "Permanently remove “Review branch tools before switching” from main. Saved changes may become unrecoverable.", action: "Drop Stash", cancel: "Cancel", destructive: true, cancelIsDefault: true)
                drop.window.appearance = NSAppearance(named: appearance); drop.layout(); drop.window.orderFront(nil)
                if let content = drop.window.contentView { try await capture(content, "confirm-drop-\(sizeName)-\(suffix)", folder) }
                drop.window.orderOut(nil)
            }
        }
    }
    @MainActor private func capture(_ view: NSView, _ name: String, _ folder: URL?) async throws {
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(120)); view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
        XCTAssertTrue(view.bounds.width > 0 && view.bounds.height > 0)
        guard let folder else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        if view is GitBranchesPopover { XCTAssertEqual(bitmap.colorAt(x: 2, y: 2)?.alphaComponent, 1, "The popup must paint its Pi surface") }
        // cacheDisplay omits the native window backdrop of PiQuestion. Draw
        // that window's actual appearance-resolved color under the captured
        // content so exported evidence has the same readable background.
        let opaque = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: opaque))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); rect.fill()
            let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(opaque.colorAt(x: 2, y: 2)?.alphaComponent, 1, "Gallery evidence includes an opaque backdrop")
        try XCTUnwrap(opaque.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
