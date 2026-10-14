import AppKit
import XCTest
@testable import PiApp
@testable import GitView

/// Standalone Git scenes: no UIScreenshotTests setup, app model or gateway.
final class GitSafetyGalleryTests: GitPanelTestCase {
    @MainActor func testGitSafetyScenes() async throws {
        let folder = testEnvironment("PI_APP_GIT_SAFETY_GALLERY").map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for scene in ["conflict", "amend-target", "preflight-failure", "commit-box"] {
            let fixture = try GitSafetyRepository(); defer { fixture.remove() }
            if scene == "conflict" { try fixture.conflict() }
            else {
                try fixture.seed()
                try fixture.write("file.txt", scene == "preflight-failure" ? "review this line  \n" : "reviewed content\n")
            }
            let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
            try await eventually("read gallery repository") { controller.statusRead && !controller.loading }
            controller.commitMessage = "Keep the reviewed changes together"
            controller.amend = scene == "amend-target"
            controller.signOff = scene == "commit-box"
            controller.selection = .init(path: "file.txt", staged: false)
            let place = GitPanelPlace(), questions = PiQuestion()
            let panel = GitPanelView(controller: controller, place: place, questions: questions, project: "Review fixture")
            let window = host(panel)
            defer { place.cancelQuestion(); window.close() }
            try await eventually("show gallery panel") { controller.isShown && !controller.loading && !controller.diffLoading }
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for size in [NSSize(width: 1180, height: 780), NSSize(width: 920, height: 600), NSSize(width: 700, height: 640), NSSize(width: 310, height: 600)] {
                    window.appearance = NSAppearance(named: appearance); window.setContentSize(size)
                    controller.commitMessage = size.width == 700 ? "Keep the reviewed changes together\n\nOne\nTwo\nThree" : "Keep the reviewed changes together"
                    if let request = controller.commitRequest(context: controller.repositoryContext) { _ = await controller.checkCommit(request) }
                    panel.refresh(); panel.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let box = try XCTUnwrap(GitOperationSafetyTests.views(GitCommitBox.self, in: panel).first)
                    box.layoutSubtreeIfNeeded()
                    XCTAssertLessThanOrEqual(box.frame.maxY, panel.bounds.maxY, scene)
                    let changes = try XCTUnwrap(GitOperationSafetyTests.views(GitChangesList.self, in: panel).first)
                    let firstFile = try XCTUnwrap(GitOperationSafetyTests.views(GitFileRowView.self, in: changes).first)
                    let fileFrame = firstFile.convert(firstFile.bounds, to: changes)
                    XCTAssertGreaterThanOrEqual(fileFrame.minY, 0, scene)
                    XCTAssertLessThanOrEqual(fileFrame.maxY, changes.bounds.height + 0.5,
                        "\(scene), \(size): the first file stays fully visible; row \(fileFrame), list \(changes.bounds), commit box \(box.bounds)")
                    for control in GitOperationSafetyTests.views(PiKit.ButtonBase.self, in: box) where !control.isHiddenOrHasHiddenAncestor {
                        let frame = control.convert(control.bounds, to: box)
                        XCTAssertGreaterThanOrEqual(frame.minX, 0, control.accessibilityIdentifier())
                        XCTAssertLessThanOrEqual(frame.maxX, box.bounds.width + 0.5, control.accessibilityIdentifier())
                        XCTAssertLessThanOrEqual(frame.maxY, box.bounds.height + 0.5, scene)
                        XCTAssertFalse((control.accessibilityLabel() ?? control.accessibilityTitle() ?? "").isEmpty, "\(scene): \(control.accessibilityIdentifier()) \(type(of: control))")
                    }
                    let signOff = try XCTUnwrap(GitOperationSafetyTests.views(SymbolButton.self, in: box).first { $0.accessibilityIdentifier() == "git-sign-off" })
                    XCTAssertEqual(signOff.accessibilityRole(), .checkBox)
                    XCTAssertEqual(signOff.accessibilityValue() as? Int, scene == "commit-box" ? 1 : 0)
                    if scene == "conflict" {
                        let row = try XCTUnwrap(GitOperationSafetyTests.views(GitFileRowView.self, in: panel).first)
                        XCTAssertEqual(row.row.accessibilityValue() as? String, "Conflict")
                        XCTAssertEqual(GitFileRowView.badgeColor("!"), .piDanger)
                    }
                    let name = "\(scene)-\(theme)-\(Int(size.width))x\(Int(size.height))"
                    if let folder { try capture(panel, to: folder.appendingPathComponent(name + ".png")) }
                    if scene == "amend-target" {
                        place.requestCommit(controller, context: controller.repositoryContext, reword: false, questions: questions)
                        try await eventually("show target sheet") { window.attachedSheet != nil }
                        let sheet = try XCTUnwrap(window.attachedSheet)
                        sheet.appearance = NSAppearance(named: appearance)
                        XCTAssertEqual(sheet.defaultButtonCell?.title, "Cancel")
                        if let folder, let content = sheet.contentView { try capture(content, to: folder.appendingPathComponent(name + "-sheet.png")) }
                        place.cancelQuestion()
                        try await eventually("close target sheet") { !questions.asking && window.attachedSheet == nil }
                    }
                }
            }
        }
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
