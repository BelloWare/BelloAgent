import AppKit
import FileView
import XCTest
@testable import PiApp

/// Standalone: generated files and a local Git repository, no UI screenshot
/// superclass, helper launch, gateway, real preferences or credentials.
final class FileReviewGalleryTests: XCTestCase {
    @MainActor func testRestoredReaderRecentsHistoryAndBackGallery() async throws {
        guard let path = testEnvironment("PI_FILE_REVIEW_GALLERY") else { throw XCTSkip("Set PI_FILE_REVIEW_GALLERY to capture") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, tab = model.openFile(fixture.url)
        fixture.mount()
        try await eventually("file ready") { tab.status == .ready }
        let view = try XCTUnwrap(tab.scroll?.textView)
        view.restoreReadingPosition(.init(topLine: 48, anchor: .init(line: 51, column: 4), focus: .init(line: 53, column: 29)))
        let saved = try XCTUnwrap(tab.savedState())
        model.tabs.close(tab)
        let restored = try XCTUnwrap(model.tabs.open(kind: FileTab.kind, key: tab.key) {
            FileTab.restore(key: tab.key, state: saved)!
        } as? FileTab)
        fixture.mount()
        try await eventually("restored file ready") { restored.status == .ready }
        XCTAssertEqual(restored.scroll?.textView.focus, .init(line: 53, column: 29))

        let suite = "FileReviewGallery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = QuickOpen(defaults: defaults)
        recent.noteOpened(fixture.url.resolvingSymlinksInPath(), projectID: "review")
        recent.noteOpened(fixture.repo.appendingPathComponent("README.md").resolvingSymlinksInPath(), projectID: "review")
        let reopenedRecents = QuickOpen(defaults: defaults)
        defer { reopenedRecents.close(restoringFocus: false) }

        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600), NSSize(width: 420, height: 600)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size)
                model.tabs.activate(restored); fixture.mount(); await fixture.settle()
                let prefix = "\(name)-\(Int(size.width))x\(Int(size.height))"
                try fixture.capture(to: folder.appendingPathComponent("restored-\(prefix).png"))
                XCTAssertEqual(restored.scroll?.textView.accessibilityRole(), .textArea)
                XCTAssertEqual(restored.scroll?.textView.accessibilityLabel(), "Contents of Review.swift")
                XCTAssertTrue(fixture.window.makeFirstResponder(restored.scroll?.textView))
                XCTAssertEqual(restored.menuEntries().compactMap { entry -> String? in
                    if case .item(let item) = entry { return item.identifier }; return nil
                }, ["file-find", "file-go-to-line", "file-show-history"])

                reopenedRecents.show(.init(id: "review", name: "Review fixture", roots: [fixture.repo.path], trusted: true), in: fixture.window)
                try await eventually("durable recent rows") { reopenedRecents.answered == "" && reopenedRecents.rows.count == 2 }
                let overlay = QuickOpenOverlay(quickOpen: reopenedRecents, open: { _ in })
                let root = try XCTUnwrap(fixture.window.contentView)
                overlay.frame = root.bounds; overlay.autoresizingMask = [.width, .height]; root.addSubview(overlay)
                await fixture.settle()
                try fixture.capture(to: folder.appendingPathComponent("recents-\(prefix).png"))
                reopenedRecents.close(restoringFocus: false); overlay.removeFromSuperview()

                model.showFileHistory(from: restored)
                await restored.historyTask?.value
                let changes = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab)
                fixture.mount()
                try await eventually("file history ready") { changes.controller.repositoryRoot != nil && !changes.controller.commits.isEmpty }
                await fixture.settle()
                XCTAssertEqual(changes.controller.logFilter.path, "Sources/Review.swift")
                try fixture.capture(to: folder.appendingPathComponent("history-\(prefix).png"))
                changes.goBack(); fixture.mount(); await fixture.settle()
                XCTAssertTrue(model.tabs.pane.activeTab === restored)
                XCTAssertEqual(restored.scroll?.textView.focus, .init(line: 53, column: 29))
                try fixture.capture(to: folder.appendingPathComponent("back-\(prefix).png"))
            }
        }
    }
}

@MainActor final class FileReviewProjectFixture {
    let root: URL
    let repo: URL
    let url: URL
    let model: WorkspaceModel
    let window: NSWindow
    init() throws {
        root = scratchRoot("file-review-project")
        repo = root.appendingPathComponent("Review fixture")
        url = repo.appendingPathComponent("Sources/Review.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (["// A generated review fixture", "struct ReviewRules {"] + (0..<120).map {
            "    let rule\($0) = \"Keep the reader's place during review\""
        } + ["}"]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try "# Review fixture\nGenerated files for local validation.\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.tabs.showsWindows = false
        model.workspaces = [WorkspaceRecord(id: "review", path: repo.path, trusted: true)]
        model.selectedWorkspaceID = "review"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "File Review Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "credential.helper", ""])
        try git(["add", "."]); try git(["commit", "-m", "Add review rules"])
    }
    @discardableResult func git(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = repo
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.arguments = ["-c", "commit.gpgsign=false", "-c", "credential.helper=", "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "FileReviewFixtureGit", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func mount() {
        if window.contentView as? TabWindowRootView == nil {
            window.contentView = TabWindowRootView(host: model.tabs, container: model.tabs.pane)
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func settle() async {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func capture(to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    func close() {
        model.shutdown(); window.contentView = nil; window.close()
        let model = model, root = root
        Task { try? await model.traces.close(); await model.store?.close(); try? FileManager.default.removeItem(at: root) }
    }
}
