import XCTest
import AppKit
@testable import PiApp
@testable import GitView

final class GitHunkReviewTests: XCTestCase {
    @MainActor func testHunkActivationIsSingleFlightAndReviewKeepsCommitScope() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready()
        let review = try XCTUnwrap(model.review), scope = scene.controller.commitScope
        model.activate(0, reviewID: review.id); model.activate(1, reviewID: review.id)
        try await eventually("one hunk staged", timeout: .seconds(30)) { !model.busy && model.stagedPath != nil }
        XCTAssertEqual(try scene.repo.git(["show", ":review.swift"]), scene.repo.first)
        XCTAssertEqual(try Data(contentsOf: scene.repo.root.appendingPathComponent("review.swift")), scene.repo.both)
        XCTAssertEqual(scene.controller.commitScope, scope)
        model.reviewStaged()
        XCTAssertEqual(scene.controller.selection, GitController.Selection(path: "review.swift", staged: true))
        XCTAssertEqual(scene.controller.commitScope, scope)
    }

    @MainActor func testOldHunkControlCannotActAfterRepositorySwitch() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(), review = try XCTUnwrap(model.review)
        let other = try GitHunkRepo(); defer { other.remove() }
        scene.controller.root = other.root.path
        model.activate(0, reviewID: review.id)
        XCTAssertFalse(model.busy, "The stale control must be rejected before a write task starts")
        XCTAssertEqual(try scene.repo.git(["show", ":review.swift"]), scene.repo.base)
        XCTAssertEqual(try other.git(["show", ":review.swift"]), other.base)
    }

    @MainActor func testF7IsScopedToDiffAndHunkControlsExposeCheckboxState() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(), original = try XCTUnwrap(model.review)
        scene.draw()
        let diff = try XCTUnwrap(scene.find(DiffView.self).first { $0.hunkReview?.review != nil })
        let boxes = scene.find(PiKit.Checkbox.self).filter { $0.accessibilityIdentifier().hasPrefix("git-hunk-") == true }
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes.first?.accessibilityRole(), .checkBox)
        XCTAssertEqual(boxes.first?.accessibilityValue() as? Int, 0)
        XCTAssertTrue(boxes.first?.accessibilityLabel()?.contains("@@ -1,6 +1,6 @@") == true)
        let outside = NSTextView(frame: .zero); scene.panel.addSubview(outside)
        scene.window.makeFirstResponder(outside)
        XCTAssertFalse(diff.performKeyEquivalent(with: scene.key(98)))
        scene.window.makeFirstResponder(diff.table.documentView)
        XCTAssertTrue(diff.performKeyEquivalent(with: scene.key(98)))
        XCTAssertEqual((scene.window.firstResponder as? NSView)?.accessibilityIdentifier(), "git-hunk-0")
        XCTAssertTrue(diff.performKeyEquivalent(with: scene.key(98)))
        XCTAssertEqual((scene.window.firstResponder as? NSView)?.accessibilityIdentifier(), "git-hunk-1")
        scene.controller.presentation.split = true
        scene.draw()
        XCTAssertTrue(diff.performKeyEquivalent(with: scene.key(98, modifiers: .shift)))
        XCTAssertEqual((scene.window.firstResponder as? NSView)?.accessibilityIdentifier(), "git-hunk-0")
        // The diff routes Space only for its focused Pi hunk checkbox.
        XCTAssertTrue(diff.performKeyEquivalent(with: scene.key(49, characters: " ")))
        try await eventually("Space stages the focused hunk", timeout: .seconds(30)) {
            scene.draw()
            return model.enabled && model.review?.id != original.id
        }
        XCTAssertEqual(try scene.repo.git(["show", ":review.swift"]), scene.repo.first)
        scene.window.makeFirstResponder(diff.table.documentView)
        XCTAssertTrue(diff.performKeyEquivalent(with: scene.key(98)))
        XCTAssertEqual((scene.window.firstResponder as? NSView)?.accessibilityIdentifier(), "git-hunk-0", "The remaining hunk gets a fresh navigation position")
    }

    @MainActor func testUnrelatedStatusRefreshPreservesDiffTextSelection() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(), original = try XCTUnwrap(model.review)
        let diff = try XCTUnwrap(scene.find(DiffView.self).first { $0.hunkReview === model })
        let table = try XCTUnwrap(diff.table.documentView as? GitDiffTableView)
        table.selectAll(nil)
        let selected = try XCTUnwrap(table.coordinator).selectedText
        XCTAssertFalse(selected.isEmpty)
        try Data("unrelated staged change\n".utf8).write(to: scene.repo.root.appendingPathComponent("other.txt"))
        try scene.repo.git(["add", "other.txt"])
        await scene.controller.refresh()
        try await eventually("new index review", timeout: .seconds(30)) { scene.draw(); return model.enabled && model.review?.id != original.id }
        XCTAssertEqual(table.coordinator?.selectedText, selected)
    }

    @MainActor func testFinalHunkKeepsExplicitStagedReviewOffer() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(), original = try XCTUnwrap(model.review)
        model.activate(0, reviewID: original.id)
        try await eventually("remaining hunk review", timeout: .seconds(30)) { scene.draw(); return model.enabled && model.review?.id != original.id }
        let remaining = try XCTUnwrap(model.review), scope = scene.controller.commitScope
        model.activate(0, reviewID: remaining.id)
        try await eventually("last hunk staged", timeout: .seconds(30)) { scene.draw(); return !model.busy }
        XCTAssertEqual(try scene.repo.git(["show", ":review.swift"]), scene.repo.both)
        let button = try XCTUnwrap(scene.find(GitHunkToolbar.self).first { !$0.staged.isHidden }?.staged)
        XCTAssertNotNil(button.window)
        button.onPress?()
        XCTAssertEqual(scene.controller.selection, GitController.Selection(path: "review.swift", staged: true))
        XCTAssertEqual(scene.controller.commitScope, scope)
    }

    @MainActor func testNavigationDuringFailedMutationDropsOldReviewAndNotice() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(), original = try XCTUnwrap(model.review)
        let lock = scene.repo.root.appendingPathComponent(".git/index.lock")
        try Data("external owner".utf8).write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        model.activate(0, reviewID: original.id)
        scene.controller.selection = GitController.Selection(path: "other.txt", staged: false)
        model.synchronize()
        XCTAssertNil(model.review, "The busy mutation owns its captured review, not the newly selected file")
        try await eventually("old mutation finished", timeout: .seconds(30)) { !model.busy }
        XCTAssertFalse(model.message.contains("index is locked"), "A failure belongs only to its original selection")
        XCTAssertEqual(try scene.repo.git(["show", ":review.swift"]), scene.repo.base)
    }

    @MainActor func testNavigatingToPartiallyShownHunkCannotLeaveEarlierActionFocused() throws {
        let text = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n@@ -30,1600 +30,1600 @@\n" + (0..<1600).map { "-old \($0)\n+new \($0)\n" }.joined()
        let files = GitDiffParser.parse(text), table = GitDiffTable()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = table; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        table.update(files: files, split: false, wrap: false, showAll: false, identity: "partial", top: TestDiffHeading("Hunks"), topHeightKey: 0, more: nil,
                     hunkControls: GitDiffHunkControls(key: 1) { location in
                         let box = PiKit.Checkbox(isOn: false, label: "Stage hunk")
                         box.isEnabled = location.fullyShown
                         return box
                     })
        table.layoutSubtreeIfNeeded()
        table.moveToChange(forward: true)
        XCTAssertTrue(window.firstResponder is PiKit.Checkbox)
        table.moveToChange(forward: true)
        XCTAssertTrue(window.firstResponder === table.documentView, "A disabled hunk must never leave another action focused")
    }

    @MainActor func testPointerHitAndVoiceOverPressStageOnlyThatHunk() async throws {
        let scene = try GitHunkScene(); defer { scene.close() }
        let model = try await scene.ready(); scene.draw()
        let box = try XCTUnwrap(scene.find(PiKit.Checkbox.self).first { $0.accessibilityIdentifier() == "git-hunk-0" })
        let center = box.convert(NSPoint(x: box.bounds.midX, y: box.bounds.midY), to: scene.panel.superview)
        let hit = scene.panel.hitTest(center)
        XCTAssertTrue(hit === box || hit?.isDescendant(of: box) == true, "The table's text-selection hit testing must expose the hunk control")
        XCTAssertTrue(box.accessibilityPerformPress())
        try await eventually("VoiceOver hunk press finished", timeout: .seconds(30)) { !model.busy }
        XCTAssertEqual(try scene.repo.git(["show", ":review.swift"]), scene.repo.first)
        XCTAssertEqual(try Data(contentsOf: scene.repo.root.appendingPathComponent("review.swift")), scene.repo.both)
    }

    @MainActor func testUnsupportedFileExplainsWholeFileFallback() async throws {
        let scene = try GitHunkScene(binary: true); defer { scene.close() }
        try await eventually("binary fallback", timeout: .seconds(30)) {
            scene.draw()
            return scene.find(DiffView.self).contains { $0.hunkReview?.message.hasPrefix("Hunks unavailable.") == true }
        }
        XCTAssertTrue(scene.find(DiffView.self).contains { $0.hunkReview?.message.contains("binary") == true })
        XCTAssertTrue(scene.find(PiKit.Checkbox.self).filter { $0.accessibilityIdentifier().hasPrefix("git-hunk-") == true }.isEmpty)
    }
}

/// Local-only fixture: no app launch, gateway, remote, helpers or credentials.
final class GitHunkRepo {
    let root: URL
    let base: Data, first: Data, both: Data
    init(binary: Bool = false) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bello-hunk-ui-" + UUID().uuidString)
        func content(_ edits: [Int: String]) -> Data { Data((1...32).map { (edits[$0] ?? "let item\($0) = \($0)") + "\n" }.joined().utf8) }
        base = content([:]); first = content([3: "let retryLimit = 4"]); both = content([3: "let retryLimit = 4", 30: "let timeoutSeconds = 45"])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Hunk Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.fsmonitor", "false"), ("core.autocrlf", "false"), ("core.attributesFile", "/dev/null"), ("credential.helper", "")] { try git(["config", key, value]) }
        try Data((binary ? "review.swift -diff\n" : "review.swift diff\n").utf8).write(to: root.appendingPathComponent(".git/info/attributes"))
        try base.write(to: root.appendingPathComponent("review.swift")); try Data("other base\n".utf8).write(to: root.appendingPathComponent("other.txt")); try git(["add", "."]); try git(["commit", "-qm", "Fixture"])
        try (binary ? Data([0, 1, 2]) : both).write(to: root.appendingPathComponent("review.swift"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = args; process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "HunkFixture", code: Int(process.terminationStatus)) }
        return data
    }
}

@MainActor final class GitHunkScene {
    let repo: GitHunkRepo, controller: GitController, panel: GitPanelView, window: NSWindow
    init(width: CGFloat = 1180, height: CGFloat = 760, binary: Bool = false) throws {
        repo = try GitHunkRepo(binary: binary)
        controller = GitController(roots: [repo.root.path])
        panel = GitPanelView(controller: controller, project: "Hunk Review Fixture")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel; window.orderFront(nil)
        controller.setShown(true)
    }
    func ready() async throws -> GitHunkReview {
        try await eventually("complete raw hunk review", timeout: .seconds(30)) {
            self.draw()
            if let message = self.find(DiffView.self).compactMap({ $0.hunkReview?.message }).first(where: { $0.hasPrefix("Hunks unavailable.") }) {
                throw NSError(domain: "GitHunkReviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return self.find(DiffView.self).contains { $0.hunkReview?.enabled == true }
        }
        return try XCTUnwrap(find(DiffView.self).first { $0.hunkReview?.enabled == true }?.hunkReview)
    }
    func draw() { panel.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func find<T: NSView>(_ type: T.Type) -> [T] {
        func visit(_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { visit($0) } }
        return visit(panel)
    }
    func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func close() { controller.letGo(); window.contentView = nil; window.close(); repo.remove() }
}
