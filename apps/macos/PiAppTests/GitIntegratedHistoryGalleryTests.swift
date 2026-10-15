import AppKit
import XCTest
@testable import GitView
@testable import PiApp

/// The real Changes tab with the integrated History browser, using only a
/// generated repository and a prefs-free tab host. No application model.
final class GitIntegratedHistoryGalleryTests: GitPanelTestCase {
    @MainActor func testIntegratedHistoryScenes() async throws {
        guard let path = testEnvironment("PI_APP_INTEGRATED_HISTORY_GALLERY") else {
            throw XCTSkip("Set PI_APP_INTEGRATED_HISTORY_GALLERY for the integrated History gallery")
        }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try GitHistoryFixture(count: 8); defer { fixture.close() }
        let ref = "feature/restore-committed-history-filters-with-exact-object-navigation-and-long-reference-names"
        try fixture.git(["branch", ref])
        let tabs = TabHost(defaults: nil); tabs.showsWindows = false
        defer { tabs.tearDown() }
        let url = fixture.root.appendingPathComponent("notes.txt")
        let file = try XCTUnwrap(tabs.open(kind: FileTab.kind, key: FileTab.key(for: url)) {
            FileTab(url: url, projectID: "history-gallery")
        } as? FileTab)
        let tab = try XCTUnwrap(tabs.open(kind: ChangesTab.kind, key: "history-gallery") {
            ChangesTab(projectID: "history-gallery", name: "History Fixture", roots: [fixture.root.path])
        } as? ChangesTab)
        let content = try XCTUnwrap(tab.contentView.content as? ChangesTabContent)
        let controller = tab.controller; controller.panel = .history
        tab.cameFrom(file, source: .file)
        let window = host(content); defer { window.close() }
        try await eventually("read integrated gallery history", timeout: 30) { controller.commits.count == 8 && !controller.loading }
        let target = try XCTUnwrap(controller.commits.last)
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: content).first)
        var files: [String] = []
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600), NSSize(width: 310, height: 600)] {
                // Navigate at the captured allocation: resizing after a reveal
                // would capture a line positioned for the previous viewport.
                window.appearance = NSAppearance(named: appearance); window.setContentSize(size)
                content.refresh(); content.layoutSubtreeIfNeeded()
                for name in ["filtered", "empty", "loading", "long-ref", "pinned-blame", "file-history"] {
                    controller.selectedCommit = nil
                    tab.cameFrom(file, source: name == "pinned-blame" ? .blame : .file)
                    var filter = GitLogFilter(), options = GitHistoryOptions()
                    var release: CheckedContinuation<Void, Never>?
                    if name == "filtered" {
                        filter = .init(text: "Change", author: "History Fixture", path: "notes.txt")
                        options.dates = .init(from: "2026-10-14", through: "2026-10-14")
                    } else if name == "empty" || name == "pinned-blame" {
                        filter.text = "No matching commit"
                    } else if name == "long-ref" { options.reference = "refs/heads/" + ref }
                    else if name == "file-history" { filter.path = "notes.txt" }
                    else if name == "loading" {
                        filter.text = "Reading a new query"
                        controller.history.didRead = { query in
                            if query.message == "Reading a new query", release == nil {
                                await withCheckedContinuation { release = $0 }
                            }
                        }
                    }
                    controller.logFilter = filter; controller.historyOptions = options
                    let query = GitHistoryQuery(filter: filter, options: options)
                    if name == "loading" {
                        try await eventually("hold live query") { release != nil }
                    } else {
                        try await eventually("settle live query") {
                            controller.history.reading.query == query && !controller.history.reading.loading
                                && controller.commits == controller.history.reading.commits
                        }
                        if name == "pinned-blame" {
                            let accepted = try await controller.revealHistory(.init(commit: target.hash, path: "notes.txt", line: 1), in: XCTUnwrap(controller.repositoryRoot))
                            XCTAssertTrue(accepted)
                        } else if let commit = controller.commits.first {
                            controller.selectedCommit = commit; controller.detailFile = "notes.txt"
                        }
                        try await eventually("settle historical detail") { !controller.commitLoading }
                    }
                    content.refresh(); content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    if name == "pinned-blame" {
                        try await eventually("show the blamed line in this viewport") {
                            content.layoutSubtreeIfNeeded()
                            guard let diff = GitOperationSafetyTests.views(DiffView.self, in: content).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
                                  let selected = diff.table.coordinator.anchor else { return false }
                            let row = diff.table.table.rect(ofRow: selected.row), clip = diff.table.contentView.bounds
                            return row.minY >= clip.minY && row.maxY <= clip.maxY
                        }
                        let heading = try XCTUnwrap(GitOperationSafetyTests.views(DiffHeading.self, in: content).first)
                        let shownTable = try XCTUnwrap(heading.enclosingScrollView as? GitDiffTable)
                        // noteHeightOfRows animates the live row view after
                        // reporting its final rect. Capture the finished row.
                        try await eventually("finish the wrapped heading's row resize") {
                            content.layoutSubtreeIfNeeded()
                            let next = heading.convert(heading.hunks.next.bounds, from: heading.hunks.next)
                            return heading.bounds.height == shownTable.table.rect(ofRow: 0).height && next.maxY <= heading.bounds.maxY
                        }
                        let next = heading.convert(heading.hunks.next.bounds, from: heading.hunks.next)
                        XCTAssertLessThanOrEqual(next.maxY, heading.bounds.maxY, "The wrapped heading must retain both hunk navigation buttons")
                    }
                    for control in [browser.message, browser.author, browser.refs, browser.dates, browser.openHashButton] as [NSView] {
                        XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                        XCTAssertLessThanOrEqual(control.frame.maxX, browser.bounds.width + 0.5)
                    }
                    for chip in GitOperationSafetyTests.views(GitHistoryFilterChip.self, in: browser) {
                        XCTAssertLessThanOrEqual(chip.frame.maxX, browser.bounds.width + 0.5)
                        XCTAssertLessThanOrEqual(chip.frame.maxY, browser.list.frame.minY)
                    }
                    let filename = "\(name)-\(theme)-\(Int(size.width))x\(Int(size.height)).png"
                    try capture(content, to: folder.appendingPathComponent(filename)); files.append(filename)
                    release?.resume(); controller.history.didRead = nil
                    if name == "loading" { try await eventually("release live query") { !controller.history.reading.loading } }
                }
            }
        }
        XCTAssertEqual(files.count, 36)
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor private func capture(_ view: NSView, to path: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        // Sheet vibrancy is transparent in cacheDisplay. Composite it over
        // its own appearance's window color, without capturing the desktop.
        let opaque = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.pixelsWide, pixelsHigh: image.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: opaque)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(opaque.representation(using: .png, properties: [:])).write(to: path)
    }
}
