import AppKit
import XCTest
@testable import GitView
@testable import PiApp

final class GitIntegratedHistoryTests: GitPanelTestCase {
    @MainActor func testBlameRevealsItsLineInsideANarrowViewport() async throws {
        let fixture = try GitHistoryFixture(count: 3); defer { fixture.close() }
        let tabs = TabHost(defaults: nil); tabs.showsWindows = false
        defer { tabs.tearDown() }
        let url = fixture.root.appendingPathComponent("notes.txt")
        let file = try XCTUnwrap(tabs.open(kind: FileTab.kind, key: FileTab.key(for: url)) {
            FileTab(url: url, projectID: "narrow-blame")
        } as? FileTab)
        let tab = try XCTUnwrap(tabs.open(kind: ChangesTab.kind, key: "narrow-blame") {
            ChangesTab(projectID: "narrow-blame", name: "Fixture", roots: [fixture.root.path])
        } as? ChangesTab)
        let panel = try XCTUnwrap(tab.contentView.content as? ChangesTabContent)
        let controller = tab.controller; controller.panel = .history
        tab.cameFrom(file)
        let window = host(panel, width: 920, height: 600)
        defer { window.close() }
        try await eventually("read narrow history") { controller.commits.count == 3 && !controller.loading }
        let target = try XCTUnwrap(controller.commits.last)
        // Warm the exact target before reopening it at a narrower allocation.
        // A cached detail arrives before the new diff view's first layout.
        controller.selectedCommit = target; controller.detailFile = "notes.txt"
        try await eventually("read previous detail") { !controller.commitLoading && !controller.detailFileDiff.isEmpty }
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        controller.selectedCommit = nil; controller.logFilter.text = "No matching commit"
        try await eventually("filter the narrow list") { controller.commits.isEmpty && !controller.history.reading.loading }
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 310, height: 600))
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let accepted = try await controller.revealHistory(.init(commit: target.hash, path: "notes.txt", line: 1), in: XCTUnwrap(controller.repositoryRoot))
        XCTAssertTrue(accepted)
        try await eventually("read the narrow blamed line") { !controller.commitLoading && !controller.detailFileDiff.isEmpty }
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let diff = try XCTUnwrap(GitOperationSafetyTests.views(DiffView.self, in: panel).first { !$0.isHiddenOrHasHiddenAncestor })
        try await eventually("select the blamed line") { panel.layoutSubtreeIfNeeded(); return diff.table.coordinator.anchor != nil }
        let selected = try XCTUnwrap(diff.table.coordinator.anchor)
        let row = diff.table.table.rect(ofRow: selected.row), clip = diff.table.contentView.bounds
        XCTAssertGreaterThanOrEqual(row.minY, clip.minY)
        XCTAssertLessThanOrEqual(row.maxY, clip.maxY)
        // Once shown, a refresh must leave the reader's own scroll alone.
        diff.table.contentView.scroll(to: .zero)
        diff.table.reflectScrolledClipView(diff.table.contentView)
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(diff.table.contentView.bounds.minY, 0)
    }

    @MainActor func testQuietReshowKeepsTheReadersScrollPosition() async throws {
        let fixture = try GitHistoryFixture(count: 60); defer { fixture.close() }
        let controller = fixture.controller; controller.panel = .history
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: panel).first)
        try await eventually("read first history page") { controller.commits.count == 50 && !controller.loading }
        await controller.loadMoreHistory()
        XCTAssertEqual(controller.commits.count, 60)
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        browser.list.scrollToRow(42)
        let position = browser.list.contentView.bounds.origin
        XCTAssertGreaterThan(position.y, 0)
        panel.isHidden = true
        try await eventually("disable hidden history controls") { controller.suspended && !browser.refs.isEnabled }
        panel.isHidden = false
        try await eventually("restore the paged history") {
            controller.isShown && !controller.history.reading.loading && controller.commits.count == 60 && browser.refs.isEnabled
        }
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.list.contentView.bounds.origin, position)
    }

    @MainActor func testQuietReshowRestoresLiveHistoryRowsAndControls() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed()
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.panel = .history
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: panel).first)
        try await eventually("show history") { controller.commits.count == 1 && !controller.loading && browser.refs.isEnabled }
        panel.isHidden = true
        try await eventually("hide history") { controller.suspended && !browser.refs.isEnabled }
        panel.isHidden = false
        try await eventually("quietly read unchanged history") { controller.isShown && controller.isWatching && !controller.history.reading.loading }
        try await eventually("restore history controls and rows") {
            panel.layoutSubtreeIfNeeded()
            return browser.refs.isEnabled && GitOperationSafetyTests.views(GitHistoryRow.self, in: browser).count == 1
        }
    }

    @MainActor func testFiltersAndRemovableChipsDriveTheLiveHistoryQuery() async throws {
        let fixture = try GitHistoryFixture(count: 3); defer { fixture.close() }
        try fixture.git(["branch", "feature/review"])
        let controller = fixture.controller
        controller.panel = .history
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        try await eventually("read live history") { controller.commits.count == 3 && !controller.loading }
        let before = try fixture.repositoryBytes()
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: panel).first)
        browser.message.onChange?("Change 2"); browser.author.onChange?("History Fixture")
        controller.logFilter.path = "notes.txt"
        browser.showReferences()
        let picker = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryRefPicker.self, in: XCTUnwrap(browser.popover.popover?.contentViewController?.view)).first)
        picker.choose?(.reference("refs/heads/feature/review"))
        browser.showDates()
        let dates = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryDateEditor.self, in: XCTUnwrap(browser.popover.popover?.contentViewController?.view)).first)
        dates.from.text = "2026-10-14"; dates.through.text = "2026-10-14"; dates.submit()
        let query = GitHistoryQuery(filter: controller.logFilter, options: controller.historyOptions)
        try await eventually("apply all live filters") {
            controller.history.reading.query == query && !controller.history.reading.loading && controller.commits.map(\.subject) == ["Change 2"]
        }
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let chips = GitOperationSafetyTests.views(GitHistoryFilterChip.self, in: browser)
        XCTAssertEqual(chips.count, 6)
        for chip in chips { chip.remove.performClick(nil) }
        try await eventually("remove each live filter") {
            controller.history.reading.query == GitHistoryQuery() && !controller.history.reading.loading && controller.commits.count == 3
        }
        XCTAssertEqual(controller.logFilter, GitLogFilter())
        XCTAssertEqual(controller.historyOptions, GitHistoryOptions())
        XCTAssertEqual(try fixture.repositoryBytes(), before)
    }

    @MainActor func testKeyboardPagingAndReturnUseTheLiveController() async throws {
        let fixture = try GitHistoryFixture(count: 52); defer { fixture.close() }
        let controller = fixture.controller; controller.panel = .history
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        try await eventually("read first live page") { controller.commits.count == 50 && !controller.loading }
        let before = try fixture.repositoryBytes()
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: panel).first)
        panel.refresh(); panel.layoutSubtreeIfNeeded(); browser.focusList()
        for _ in 0..<50 { browser.moveDown(nil) }
        try await eventually("read second live page") { controller.commits.count == 52 && controller.historyExhausted }
        let target = controller.commits[50]
        try await eventually("focus next page's first row") {
            (browser.list.madeView(for: target.hash) as? GitHistoryRow)?.button.isAccessibilitySelected() == true
        }
        browser.insertNewline(nil)
        try await eventually("open paged detail") { controller.detail?.commit.hash == target.hash && !controller.commitLoading }
        XCTAssertEqual(controller.detail?.files.map(\.path), ["notes.txt"])
        XCTAssertEqual(Set(controller.commits.map(\.hash)).count, 52)
        XCTAssertEqual(try fixture.repositoryBytes(), before)
    }

    @MainActor func testHashJumpAndBlameStayPinnedOutsideTheLiveFilters() async throws {
        let fixture = try GitHistoryFixture(count: 3); defer { fixture.close() }
        let controller = fixture.controller; controller.panel = .history
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        try await eventually("read live commits") { controller.commits.count == 3 && !controller.loading }
        let before = try fixture.repositoryBytes(), target = try XCTUnwrap(controller.commits.last)
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: panel).first)
        browser.message.onChange?("Change 2")
        try await eventually("filter live commits") { controller.commits.count == 1 && !controller.history.reading.loading }
        browser.showHash()
        let editor = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryHashEditor.self, in: XCTUnwrap(browser.popover.popover?.contentViewController?.view)).first)
        editor.field.text = target.hash; editor.button.performClick(nil)
        try await eventually("open exact hash") { controller.detail?.commit.hash == target.hash && !controller.commitLoading }
        XCTAssertEqual(controller.commits.map(\.subject), ["Change 2"])
        XCTAssertEqual(controller.logFilter.text, "Change 2")
        let reveal = GitHistoryTarget(commit: target.hash, path: "notes.txt", line: 1)
        let accepted = await controller.revealHistory(reveal, in: fixture.historyRoot)
        XCTAssertTrue(accepted)
        browser.author.onChange?("Nobody matches")
        try await eventually("exclude pinned blame from list") { controller.commits.isEmpty && !controller.history.reading.loading }
        XCTAssertEqual(controller.selectedCommit?.hash, target.hash)
        XCTAssertEqual(controller.detailFile, "notes.txt")
        XCTAssertEqual(controller.revealTarget?.target, reveal)
        try await eventually("read pinned historical bytes") {
            controller.detailFileDiff.flatMap(\.hunks).flatMap(\.lines).contains { $0.kind == .added && $0.text == "Change 0" }
        }
        XCTAssertEqual(try fixture.repositoryBytes(), before)
    }

    @MainActor func testTheRealHistoryPanelHostsTheFilterBrowser() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed()
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        controller.panel = .history
        let panel = GitPanelView(controller: controller), window = host(panel)
        defer { window.close() }
        try await eventually("read integrated history") { controller.statusRead && !controller.loading }
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(GitOperationSafetyTests.views(GitHistoryBrowser.self, in: panel).first)
        XCTAssertEqual(browser.message.accessibilityIdentifier(), "git-history-filter")
        XCTAssertFalse(browser.refs.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(browser.dates.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(browser.openHashButton.isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testTheFileHistoryReturnBarNamesItsSourceAndCanChangeBackToBlame() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed()
        let host = TabHost(defaults: nil); host.showsWindows = false
        defer { host.tearDown() }
        let url = fixture.root.appendingPathComponent("file.txt")
        let file = try XCTUnwrap(host.open(kind: FileTab.kind, key: FileTab.key(for: url)) { FileTab(url: url, projectID: "history-label") } as? FileTab)
        let tab = try XCTUnwrap(host.open(kind: ChangesTab.kind, key: "history-label") {
            ChangesTab(projectID: "history-label", name: "Fixture", roots: [fixture.root.path])
        } as? ChangesTab)
        let content = try XCTUnwrap(tab.contentView.content as? ChangesTabContent)
        tab.cameFrom(file, source: .file); content.refresh()
        let note = try XCTUnwrap(GitOperationSafetyTests.views(PiKit.TextLine.self, in: content).first {
            $0.accessibilityIdentifier() == "changes-file-history-source"
        })
        XCTAssertEqual(note.line.text, "Opened from the file")
        XCTAssertTrue(tab.returnTab === file)
        tab.cameFrom(file); content.refresh()
        XCTAssertEqual(note.line.text, "Opened from its blame")
    }
}
