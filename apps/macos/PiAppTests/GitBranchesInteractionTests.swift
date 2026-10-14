import XCTest
import AppKit
@testable import PiApp
@testable import GitView

final class GitBranchesInteractionTests: XCTestCase {
    @MainActor func testTrackingRowsStayAlignedAndUseTheCatalogWhileFiltering() async throws {
        let scene = try GitBranchesScene(width: 420); defer { scene.close() }
        _ = try await scene.repo.divergedBranch(); try scene.repo.origin(branch: "topic")
        try scene.repo.git(["branch", "--set-upstream-to=origin/topic", "main"])
        try scene.repo.write("one.txt", "one\n"); try scene.repo.commit("Local one")
        try scene.repo.write("two.txt", "two\n"); try scene.repo.commit("Local two")
        try await scene.ready()
        let view = try await scene.openBranches()
        view.frame.size.width = 280; view.layoutSubtreeIfNeeded()
        let sections = scene.find(PiKit.TextLine.self, in: view).filter { $0.accessibilityIdentifier() == "git-branches-section" }
        XCTAssertEqual(Set(sections.map(\.line.text)), ["Recent", "Local", "Remote · origin"])
        for section in sections {
            XCTAssertTrue(section.line.uppercased); XCTAssertEqual(section.line.tracking, 0.4)
            XCTAssertGreaterThanOrEqual(section.frame.minY, 8)
            if section.line.text != "Recent" { XCTAssertEqual(section.frame.minY, 14) }
        }
        let rows = scene.find(PiKit.SelectableRow.self, in: view)
        for row in rows {
            let current = row.accessibilityIdentifier() == "git-branch-refs/heads/main"
            let mark = try XCTUnwrap(scene.find(PiKit.SymbolView.self, in: row).first { $0.accessibilityIdentifier() == "git-branch-current" })
            let name = try XCTUnwrap(scene.find(LabelView.self, in: row).first)
            XCTAssertEqual(mark.isHidden, !current); XCTAssertEqual(mark.frame.minX, 0)
            XCTAssertEqual(name.frame.minX, 20, "Every row reserves the same leading check column")
            let value = row.accessibilityValue() as? String ?? ""
            XCTAssertEqual(value.contains("Current"), current)
            if current {
                XCTAssertTrue(value.contains("2 ahead, 1 behind"))
                let count = try XCTUnwrap(scene.find(PiKit.TextLine.self, in: row).first { $0.accessibilityIdentifier() == "git-branch-tracking-counts" })
                XCTAssertEqual(count.line.text, "↑2 ↓1")
                XCTAssertGreaterThanOrEqual(count.frame.width, count.intrinsicContentSize.width)
                XCTAssertLessThanOrEqual(count.frame.maxX, try XCTUnwrap(count.superview).bounds.width)
                XCTAssertLessThanOrEqual(name.frame.maxX, count.frame.minX)
            }
        }
        // Retire the upstream in the fixture after opening. Keyboard, search
        // and layout retain the already-read catalog until the next opening.
        try scene.repo.git(["update-ref", "-d", "refs/remotes/origin/topic"])
        view.filter("main"); view.move(1); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.catalog?.branches.first { $0.name == "main" }?.tracking?.ahead, 2)
        XCTAssertEqual(view.catalog?.branches.first { $0.name == "main" }?.tracking?.gone, false)
        let reopened = try await scene.openBranches()
        XCTAssertEqual(reopened.catalog?.branches.first { $0.name == "main" }?.tracking?.gone, true)
    }

    @MainActor func testSearchRemoteSectionsKeyboardAndAccessibleCurrentBranch() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        _ = try await scene.repo.divergedBranch(); try scene.repo.origin(branch: "topic")
        try await scene.ready()
        let view = try await scene.openBranches()
        view.search.text = "origin/"; view.filter("origin/")
        XCTAssertEqual(view.visibleBranches.map(\.name), ["origin/topic"])
        XCTAssertEqual(view.selectedRef, "refs/remotes/origin/topic")
        view.search.text = ""; view.filter(""); view.move(1)
        XCTAssertNotNil(view.selectedRef)
        for _ in 0..<20 { view.move(1) }
        XCTAssertEqual(view.selectedRef, "refs/remotes/origin/topic", "Recent duplicates cannot trap arrow navigation")
        view.layoutSubtreeIfNeeded()
        let current = try XCTUnwrap(scene.find(PiKit.SelectableRow.self, in: view).first { $0.accessibilityIdentifier() == "git-branch-refs/heads/main" })
        XCTAssertEqual(current.accessibilityLabel(), "main, local branch")
        XCTAssertTrue((current.accessibilityValue() as? String)?.lowercased().contains("current") == true)
        XCTAssertEqual(scene.find(LabelView.self, in: current).first?.line.text, "main", "The current mark is separate from the branch name")
        let remote = try XCTUnwrap(scene.find(PiKit.SelectableRow.self, in: view).first { $0.accessibilityIdentifier() == "git-branch-refs/remotes/origin/topic" })
        XCTAssertEqual(scene.find(LabelView.self, in: remote).first?.symbolName, "cloud")
        XCTAssertEqual(view.search.field.accessibilityLabel(), "Search local and remote branches")
        let editor = NSTextView()
        XCTAssertTrue(view.control(view.search.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(scene.tools.identity)
    }
    @MainActor func testBranchPillOpensTheNewPopup() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        try await scene.ready()
        let panel = GitPanelView(controller: scene.controller)
        panel.frame = scene.host.bounds; scene.host.addSubview(panel); panel.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(scene.find(PiKit.MenuButton.self, in: panel).first { $0.accessibilityIdentifier() == "git-branch-menu" })
        pill.performClick(nil)
        try await eventually("branch popup", timeout: .seconds(30)) {
            NSApp.windows.contains { window in window.contentView.map { !scene.find(GitBranchesPopover.self, in: $0).isEmpty } == true }
        }
        let popup = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView }.flatMap { scene.find(GitBranchesPopover.self, in: $0) }.first)
        popup.cancel?()
    }
    @MainActor func testUnmergedDeleteAsksTwiceNamesCommitsAndReturnCancels() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        let branch = try await scene.repo.divergedBranch(); try await scene.ready(); _ = try await scene.openBranches()
        var asked: [NSAlert] = []
        scene.tools.questions.answerAlert = { alert in
            asked.append(alert)
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
            return asked.count == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn
        }
        await scene.tools.delete(branch)
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(asked[1].informativeText.contains("Topic only"))
        XCTAssertTrue(asked[1].informativeText.contains(String(branch.oid.prefix(7))))
        XCTAssertTrue(asked[1].informativeText.contains("not in main"))
        XCTAssertEqual(try scene.repo.git(["rev-parse", branch.ref]).trimmingCharacters(in: .newlines), branch.oid)
    }
    @MainActor func testConfirmedDeleteUsesReviewedRefAndPreservesWorktree() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        let branch = try await scene.repo.divergedBranch(); try await scene.ready(); _ = try await scene.openBranches()
        scene.tools.questions.answerAlert = { _ in .alertFirstButtonReturn }
        let before = try scene.repo.snapshot()
        await scene.tools.delete(branch)
        XCTAssertEqual(try scene.repo.git(["branch", "--list", "topic"]), "")
        XCTAssertEqual(try scene.repo.snapshot(), before)
    }
    @MainActor func testRepositorySwitchDuringQuestionRetiresConsent() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        let other = try GitBranchesFixture(); defer { other.close() }
        let branch = try await scene.repo.divergedBranch(); try await scene.ready(); _ = try await scene.openBranches()
        var count = 0
        scene.tools.questions.answerAlert = { _ in count += 1; scene.controller.root = other.path; return .alertFirstButtonReturn }
        await scene.tools.delete(branch)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try scene.repo.git(["rev-parse", branch.ref]).trimmingCharacters(in: .newlines), branch.oid)
        XCTAssertEqual(try other.read("f.txt"), "base\n")
    }
    @MainActor func testBranchHistoryCallbackCarriesRepositoryAndLegacyFallbackFilters() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        let branch = try await scene.repo.divergedBranch(); try await scene.ready(); _ = try await scene.openBranches()
        let identity = try XCTUnwrap(scene.controller.repositoryIdentity)
        var refs: [String] = []
        scene.controller.onShowBranchHistory = { ref, repository in XCTAssertEqual(repository, identity); refs.append(ref) }
        scene.tools.branchAction(.history, branch: branch)
        XCTAssertEqual(refs, [branch.ref])
        scene.controller.onShowBranchHistory = nil
        scene.controller.showBranchHistory(branch.ref, repository: identity)
        try await eventually("branch history", timeout: .seconds(30)) { scene.controller.commits.contains { $0.subject == "Topic only" } }
        XCTAssertEqual(scene.controller.panel, .history)
        XCTAssertEqual(scene.controller.logFilter.reference, branch.ref)
    }
    @MainActor func testStashPreviewIncludesUntrackedAndDropQuestionCancels() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }
        try scene.repo.write("saved.txt", "saved untracked\n")
        _ = try await scene.repo.service.createStash(message: "Notes", includeUntracked: true, keepIndex: false, in: scene.repo.path)
        try await scene.ready()
        scene.tools.showStashes(from: scene.anchor)
        let view = try XCTUnwrap(scene.tools.stashes)
        try await eventually("stash preview", timeout: .seconds(30)) { !view.preview.isEmpty }
        XCTAssertEqual(view.files.map(\.path), ["saved.txt"])
        XCTAssertTrue(view.files.first?.untracked == true)
        XCTAssertNil(view.diff.hunkReview)
        let stash = try XCTUnwrap(view.selected)
        scene.tools.questions.answerAlert = { alert in
            XCTAssertTrue(alert.informativeText.contains("Notes")); XCTAssertEqual(alert.buttons[0].keyEquivalent, ""); XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
            return .alertSecondButtonReturn
        }
        await scene.tools.stashAction(.drop, stash: stash)
        let after = try await scene.repo.service.stashRecords(in: scene.repo.path)
        XCTAssertEqual(after.map(\.oid), [stash.oid])
    }
    @MainActor func testSharedWriteAdmissionRefusesConcurrentWriter() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }; try await scene.ready()
        let identity = try XCTUnwrap(scene.controller.repositoryIdentity), gate = GitBranchWriteGate()
        let first = Task { try await scene.controller.performRepositoryWrite(repository: identity) { _ in await gate.wait(); return true } }
        try await eventually("writer admitted", timeout: .seconds(30)) { scene.controller.busy }
        do {
            _ = try await scene.controller.performRepositoryWrite(repository: identity) { [service = scene.repo.service] root in
                try await service.createStash(message: "Should not run", includeUntracked: true, keepIndex: false, in: root)
            }
            XCTFail("second writer must be refused")
        } catch {}
        await gate.release(); _ = try await first.value
        let stashes = try await scene.repo.service.stashRecords(in: scene.repo.path)
        XCTAssertTrue(stashes.isEmpty)
    }
    @MainActor func testOldSheetCompletionCannotCloseReopenedPresentation() async throws {
        let scene = try GitBranchesScene(); defer { scene.close() }; try await scene.ready()
        scene.tools.showStashes(from: scene.anchor)
        let completion = try XCTUnwrap(scene.tools.sheet?.onEnded)
        scene.tools.close()
        let popup = try await scene.openBranches()
        completion(true)
        XCTAssertTrue(scene.tools.branches === popup)
        XCTAssertEqual(scene.tools.identity, scene.controller.repositoryIdentity)
        XCTAssertNotNil(popup.catalog)
    }
}

private actor GitBranchWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if released { return }; await withCheckedContinuation { continuation = $0 } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor final class GitBranchesScene {
    let repo: GitBranchesFixture
    let controller: GitController
    let tools: GitRepositoryTools
    let window: NSWindow
    let host = FillView(.piContent)
    let anchor = PiKit.Button("main", symbol: "arrow.triangle.branch", style: .secondary)
    init(width: CGFloat = 920, height: CGFloat = 600) throws {
        repo = try GitBranchesFixture(); controller = GitController(roots: [repo.path]); tools = GitRepositoryTools(controller: controller, service: repo.service)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.addSubview(anchor); anchor.frame = CGRect(x: 20, y: 20, width: 120, height: 32)
        window.orderFront(nil)
    }
    func close() { tools.close(); controller.letGo(); window.contentView = nil; window.close(); repo.close() }
    func ready() async throws { await controller.refresh(); try await eventually("repository ready", timeout: .seconds(30)) { self.controller.statusRead && !self.controller.loading } }
    func openBranches() async throws -> GitBranchesPopover {
        tools.showBranches(from: anchor)
        try await eventually("branch catalog", timeout: .seconds(30)) { self.tools.branches?.catalog != nil }
        return try XCTUnwrap(tools.branches)
    }
    func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { find(type, in: $0) } }
}
