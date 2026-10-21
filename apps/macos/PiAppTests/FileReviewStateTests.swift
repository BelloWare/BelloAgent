import AppKit
import FileView
import GitView
import XCTest
@testable import PiApp

final class FileReviewStateTests: XCTestCase {
    @MainActor func testMarkedPathComponentsKeepBlameAndHistoryInTheirRepository() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, name = "\u{301}file", nested = fixture.repo.appendingPathComponent("\u{301}nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("fixture line\n".utf8).write(to: nested.appendingPathComponent(name))
        try fixture.git(["-C", nested.path, "init", "-q", "--template=", "-b", "main"])
        try fixture.git(["-C", nested.path, "add", "--", name])
        try fixture.git(["-C", nested.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Fixture"])
        let commit = try fixture.git(["-C", nested.path, "rev-parse", "HEAD"])
        let tab = model.openFile(nested.appendingPathComponent(name), project: "review")
        fixture.mount()
        try await eventually("marked file read") { tab.status == .ready }
        tab.blame.show()
        try await eventually("marked blame answered") { tab.blame.state != .reading }
        XCTAssertNotNil(tab.blame.blame, String(describing: tab.blame.state))
        XCTAssertEqual(tab.blame.path, name)
        tab.blame.hide()
        model.showFileHistory(from: tab); await tab.historyTask?.value
        let changes = model.tabs.tab(kind: ChangesTab.kind, key: "review") as? ChangesTab
        XCTAssertNotNil(changes, "The nested repository remains inside its configured project")
        if let changes {
            try await eventually("marked file history") { !changes.controller.loading && !changes.controller.commits.isEmpty }
            XCTAssertEqual(changes.controller.logFilter.path, name)
            changes.goBack(); fixture.mount()
        }
        model.error = nil
        model.showHistoricalChange(from: tab, target: GitHistoryTarget(commit: commit, path: name, line: 1), repository: nested.path)
        XCTAssertNil(model.error)
        await (model.tabs.tab(kind: ChangesTab.kind, key: "review") as? ChangesTab)?.navigation?.value
    }

    @MainActor func testAFileFixtureThatFailsToOpenPreservesItsCallersResolver() throws {
        let root = scratchRoot("file-review-init")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocked)
        let previous = FileTab.resolveProject
        FileTab.resolveProject = { _ in .untrusted(name: "outer fixture") }
        defer { FileTab.resolveProject = previous }
        XCTAssertThrowsError(try FileReviewFixture(root: blocked.appendingPathComponent("child")))
        XCTAssertEqual(FileTab.resolveProject(nil), .untrusted(name: "outer fixture"),
                       "A failed fixture has no close() to restore its caller's resolver")
    }

    @MainActor func testNestedFileHistoryKeepsSingleProjectRepositoryReachable() async throws {
        try await checkNestedHistoryRepositoryChoices(multipleRoots: false)
    }

    @MainActor func testNestedFileHistoryKeepsMultipleProjectRepositoriesAndAccessibleSelection() async throws {
        try await checkNestedHistoryRepositoryChoices(multipleRoots: true)
    }

    @MainActor private func checkNestedHistoryRepositoryChoices(multipleRoots: Bool) async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, nested = fixture.repo.appendingPathComponent("Dependencies/Nested")
        func seed(_ folder: URL, file: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "committed fixture\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try fixture.git(["-C", folder.path, "init", "-b", "main"])
            try fixture.git(["-C", folder.path, "config", "user.name", "File Review Fixture"])
            try fixture.git(["-C", folder.path, "config", "user.email", "fixture@example.invalid"])
            try fixture.git(["-C", folder.path, "add", "."])
            try fixture.git(["-C", folder.path, "commit", "-m", "Seed repository choice"])
            try "working fixture\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try seed(nested, file: "Nested.swift")
        var configured = [(folder: fixture.repo, file: "Sources/Review.swift")]
        if multipleRoots {
            let extra = fixture.root.appendingPathComponent("Extra repository")
            try seed(extra, file: "Extra.swift")
            model.workspaces[0].paths = [extra.path]
            configured.append((extra, "Extra.swift"))
        }
        try "outer working fixture\n".write(to: fixture.url, atomically: true, encoding: .utf8)
        let snapshots = try (configured + [(nested, "Nested.swift")]).map { folder, file in
            (folder: folder, file: file,
             tree: try fixture.git(["-C", folder.path, "rev-parse", "HEAD^{tree}"]),
             index: try fixture.git(["-C", folder.path, "show", ":" + file]),
             bytes: try Data(contentsOf: folder.appendingPathComponent(file)))
        }
        let tab = model.openFile(nested.appendingPathComponent("Nested.swift"))
        let nestedRoot = try fixture.git(["-C", nested.path, "rev-parse", "--show-toplevel"])
        model.showFileHistory(from: tab); await tab.historyTask?.value
        let changes = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab), controller = changes.controller
        fixture.mount()
        try await eventually("nested repository history") {
            fixture.mount()
            return controller.repositoryRoot == nestedRoot && !controller.loading && !controller.commits.isEmpty
        }
        XCTAssertEqual(controller.logFilter.path, "Nested.swift")
        XCTAssertEqual(controller.commits.first?.subject, "Seed repository choice")
        XCTAssertEqual(controller.roots, configured.map { $0.folder.path } + [nestedRoot])

        // The same Changes tab is reused after leaving file history. Its
        // actual toolbar must still offer every configured repository.
        changes.goBack(); fixture.mount()
        XCTAssertTrue(model.showChanges(in: "review") === changes)
        fixture.mount()
        let content = try XCTUnwrap(changes.contentView.content as? ChangesTabContent)
        let picker = try XCTUnwrap(content.panel.subviewsOfType(PiKit.Dropdown<String>.self).first {
            $0.accessibilityLabel() == "Repository"
        }, "a nested target also needs a repository picker in a single-root project")
        XCTAssertFalse(picker.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(picker.items.map(\.0), configured.map { $0.folder.path } + [nestedRoot])
        XCTAssertEqual(picker.label, nested.lastPathComponent)
        XCTAssertEqual(picker.accessibilityValue() as? String, nested.lastPathComponent)
        XCTAssertEqual(picker.selection, nestedRoot)

        for (folder, file) in configured {
            let choice = try XCTUnwrap(picker.items.first { $0.0 == folder.path })
            picker.onSelect?(choice.0)
            let repository = try fixture.git(["-C", folder.path, "rev-parse", "--show-toplevel"])
            try await eventually("selected configured repository") {
                fixture.mount()
                return controller.repositoryRoot == repository && !controller.loading &&
                    controller.status.entries.contains { $0.path == file }
            }
            XCTAssertEqual(picker.accessibilityValue() as? String, folder.lastPathComponent)
            XCTAssertEqual(picker.selection, folder.path)
        }
        for snapshot in snapshots {
            XCTAssertEqual(try fixture.git(["-C", snapshot.folder.path, "rev-parse", "HEAD^{tree}"]), snapshot.tree)
            XCTAssertEqual(try fixture.git(["-C", snapshot.folder.path, "show", ":" + snapshot.file]), snapshot.index)
            XCTAssertEqual(try Data(contentsOf: snapshot.folder.appendingPathComponent(snapshot.file)), snapshot.bytes)
        }
    }

    @MainActor func testSideFallbackAndAncestorVisibilityResumeTheActualMountedFile() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, tab = model.openFile(fixture.url), host = model.tabs
        let pane = RightPaneView(model: model, host: host, pane: host.pane)
        let side = SideRecord(id: "side", parentID: "main", workspaceID: "review", profileID: "fixture", title: "Side")
        let session = SessionDisplay(id: "side")
        fixture.window.contentView = pane
        pane.update(side: (side, session), width: 920)
        try await eventually("mounted reader") { tab.status == .ready }
        tab.scroll?.textView.select(from: .init(line: 40, column: 2), to: .init(line: 42, column: 4))
        host.showSide(); pane.update(side: (side, session), width: 920)
        XCTAssertTrue(try XCTUnwrap(tab.documentIfMade).isSuspended)
        pane.update(side: nil, width: 920)
        XCTAssertTrue(tab.isShownNow)
        XCTAssertFalse(try XCTUnwrap(tab.documentIfMade).isSuspended)
        XCTAssertEqual(tab.scroll?.textView.focus, .init(line: 42, column: 4))
        pane.isHidden = true
        XCTAssertTrue(try XCTUnwrap(tab.documentIfMade).isSuspended)
        pane.isHidden = false
        XCTAssertFalse(try XCTUnwrap(tab.documentIfMade).isSuspended)
    }

    @MainActor func testSavedSideWithoutAvailableChatResumesWhenItsFallbackFileMounts() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let defaults = try defaults(), first = TabHost(defaults: defaults)
        first.showsWindows = false; first.restore()
        _ = first.open(kind: FileTab.kind, key: FileTab.key(for: fixture.url)) { FileTab(url: fixture.url, projectID: "review") }
        first.showSide(); first.tearDown()
        let restored = TabHost(defaults: defaults)
        defer { restored.tearDown() }
        restored.showsWindows = false; restored.restore()
        let tab = try XCTUnwrap(restored.pane.activeTab as? FileTab)
        XCTAssertFalse(tab.isShownNow)
        let pane = RightPaneView(model: fixture.model, host: restored, pane: restored.pane)
        fixture.window.contentView = pane
        pane.update(side: nil, width: 920)
        try await eventually("fallback indexed") { tab.status == .ready }
        XCTAssertTrue(tab.isShownNow)
        XCTAssertFalse(try XCTUnwrap(tab.documentIfMade).isSuspended)
    }

    @MainActor func testLatestHistoryRequestWinsAcrossWindowsAndCancelsEarlierChangesNavigation() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, a = model.openFile(fixture.url), gate = FileReviewGate(), blameGate = FileReviewGate()
        model.tabs.popOut(a)
        let b = model.openFile(fixture.repo.appendingPathComponent("README.md"))
        let changes = try XCTUnwrap(model.showChanges(in: "review"))
        model.tabs.popOut(changes)
        changes.navigate {
            await blameGate.wait()
            guard !Task.isCancelled else { return false }
            changes.controller.showFileHistory("Sources/Review.swift")
            return true
        }
        let oldBlame = changes.navigation
        await blameGate.entered()
        var first = true
        model.fileReviewNavigation.beforeResolution = { if first { first = false; await gate.wait() } }
        model.showFileHistory(from: a)
        let old = a.historyTask
        await gate.entered()
        model.showFileHistory(from: b)
        await b.historyTask?.value
        XCTAssertEqual(changes.controller.logFilter.path, "README.md")
        await gate.open(); await old?.value
        await blameGate.open(); await oldBlame?.value
        XCTAssertEqual(changes.controller.logFilter.path, "README.md")
        XCTAssertTrue(changes.returnTab === b)
    }

    @MainActor func testNewerBlameNavigationCancelsAnOlderDirectHistoryRequest() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, a = model.openFile(fixture.url), gate = FileReviewGate()
        model.tabs.popOut(a)
        let b = model.openFile(fixture.repo.appendingPathComponent("README.md"))
        let prepared = try XCTUnwrap(model.showChanges(in: "review"))
        fixture.mount()
        try await eventually("Changes initially shown") {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            return prepared.controller.isShown && !prepared.controller.loading && prepared.controller.repositoryRoot != nil
        }
        // Blame supplies Git's repository identity, including the filesystem's
        // path spelling, rather than a separately normalized URL spelling.
        let repository = try XCTUnwrap(prepared.controller.repositoryRoot)
        model.tabs.activate(b); fixture.mount()
        model.fileReviewNavigation.beforeResolution = { await gate.wait() }
        model.showFileHistory(from: a)
        let old = a.historyTask
        await gate.entered()
        let commit = try fixture.git(["rev-parse", "HEAD"])
        model.showHistoricalChange(from: b, target: GitHistoryTarget(commit: commit, path: "README.md", line: 1), repository: repository)
        let changes = try XCTUnwrap(model.tabs.tab(kind: ChangesTab.kind, key: "review") as? ChangesTab)
        fixture.mount()
        let navigation = try XCTUnwrap(changes.navigation)
        var finished = false
        let completion = Task { await navigation.value; finished = true }
        defer { completion.cancel() }
        try await eventually("newer blame navigation finishes") {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            return finished
        }
        XCTAssertEqual(changes.controller.selectedCommit?.hash, commit, changes.controller.notice)
        await gate.open(); await old?.value
        XCTAssertTrue(changes.returnTab === b)
        XCTAssertEqual(changes.controller.selectedCommit?.hash, commit)
    }

    @MainActor func testRemovingExtraRootDuringHistoryResolutionPreventsRepositoryRead() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, gate = FileReviewGate()
        let extra = fixture.root.appendingPathComponent("Extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let file = extra.appendingPathComponent("extra.txt")
        try "extra fixture".write(to: file, atomically: true, encoding: .utf8)
        model.workspaces[0].paths = [extra.path]
        let tab = model.openFile(file)
        var repositoryReads = 0
        model.fileReviewNavigation.beforeResolution = { await gate.wait() }
        model.fileReviewNavigation.repositoryRoot = { _ in repositoryReads += 1; return extra.path }
        model.showFileHistory(from: tab)
        let work = tab.historyTask
        await gate.entered()
        model.workspaces[0].paths = []
        await gate.open(); await work?.value
        XCTAssertEqual(repositoryReads, 0)
        XCTAssertFalse(model.tabs.allTabs.contains { $0 is ChangesTab })
    }

    @MainActor func testHistoryRefusesRedirectedFileBeforeStartingRepositoryRead() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, tab = model.openFile(fixture.url)
        let outside = fixture.root.appendingPathComponent("Outside.swift")
        try "outside fixture".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: outside)
        var repositoryReads = 0
        model.fileReviewNavigation.repositoryRoot = { _ in repositoryReads += 1; return fixture.repo.path }
        model.showFileHistory(from: tab); await tab.historyTask?.value
        XCTAssertEqual(repositoryReads, 0)
        XCTAssertFalse(model.tabs.allTabs.contains { $0 is ChangesTab })
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside fixture")
    }

    @MainActor func testHistoryRechecksWarmedFileMetadataBeforeStartingRepositoryRead() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, tab = model.openFile(fixture.url)
        XCTAssertEqual(try tab.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        var repositoryReads = 0
        model.fileReviewNavigation.repositoryRoot = { _ in repositoryReads += 1; return fixture.repo.path }
        model.showFileHistory(from: tab); await tab.historyTask?.value
        XCTAssertEqual(repositoryReads, 0)
        XCTAssertFalse(model.tabs.allTabs.contains { $0 is ChangesTab })
        XCTAssertTrue(try fixture.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @MainActor func testHistoryRechecksFileTypeAfterRepositoryResolution() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, tab = model.openFile(fixture.url), gate = FileReviewGate()
        var repositoryReads = 0
        model.fileReviewNavigation.repositoryRoot = { _ in
            repositoryReads += 1
            await gate.wait()
            return fixture.repo.path
        }
        model.showFileHistory(from: tab)
        let work = tab.historyTask
        await gate.entered()
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        await gate.open(); await work?.value
        XCTAssertEqual(repositoryReads, 1)
        XCTAssertFalse(model.tabs.allTabs.contains { $0 is ChangesTab })
        XCTAssertTrue(try fixture.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @MainActor func testAnOlderRecentValidationCannotReplaceANewerFileQuery() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let quick = QuickOpen(), gate = FileReviewDeliveryGate()
        quick.noteOpened(fixture.url.resolvingSymlinksInPath(), projectID: "p")
        quick.beforeRecentDelivery = { gate.holdFirst() }
        quick.show(.init(id: "p", name: "Fixture", roots: [fixture.root.path], trusted: true), in: nil)
        defer { gate.release(); quick.close(restoringFocus: false) }
        try await eventually("old validation held") { gate.entered }
        quick.query = "no-such-file"
        try await eventually("new query answered") { quick.answered == "no-such-file" }
        let finished = quick.recentValidationsFinished
        gate.release()
        try await eventually("old validation delivered") { quick.recentValidationsFinished > finished }
        XCTAssertEqual(quick.answered, "no-such-file")
        XCTAssertTrue(quick.rows.isEmpty)
        XCTAssertNil(quick.selection)
    }
    @MainActor func testFileMenuActivatesHiddenReaderAndHistoryKeepsRepositoryBytesAndBackPosition() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let model = fixture.model, tab = model.openFile(fixture.url)
        let beforeHead = try fixture.git(["rev-parse", "HEAD^{tree}"])
        let beforeIndex = try fixture.git(["show", ":Sources/Review.swift"])
        let beforeBytes = try Data(contentsOf: fixture.url)
        _ = model.openFile(fixture.repo.appendingPathComponent("README.md"))
        let find = try XCTUnwrap(tab.menuEntries().compactMap { entry -> PiMenuItem? in
            if case .item(let item) = entry, item.identifier == "file-find" { return item }; return nil
        }.first)
        find.perform()
        XCTAssertTrue(model.tabs.pane.activeTab === tab)
        XCTAssertEqual(tab.bar, .find)
        fixture.mount()
        try await eventually("file indexed") { tab.status == .ready }
        tab.closeBar()
        tab.scroll?.textView.select(from: .init(line: 45, column: 2), to: .init(line: 47, column: 12))
        let history = try XCTUnwrap(tab.menuEntries().compactMap { entry -> PiMenuItem? in
            if case .item(let item) = entry, item.identifier == "file-show-history" { return item }; return nil
        }.first)
        history.perform(); await tab.historyTask?.value
        let changes = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab)
        fixture.mount()
        try await eventually("file history") { changes.controller.commits.count == 1 }
        XCTAssertEqual(changes.controller.panel, .history)
        XCTAssertEqual(changes.controller.logFilter.path, "Sources/Review.swift")
        let content = try XCTUnwrap(changes.contentView.content as? ChangesTabContent)
        content.refresh()
        let source = try XCTUnwrap(content.subviewsOfType(PiKit.TextLine.self).first {
            $0.accessibilityIdentifier() == "changes-file-history-source"
        })
        XCTAssertEqual(source.line.text, "Opened from the file")
        XCTAssertTrue(changes.returnTab === tab)
        changes.goBack()
        XCTAssertTrue(model.tabs.pane.activeTab === tab)
        XCTAssertEqual(tab.scroll?.textView.focus, .init(line: 47, column: 12))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD^{tree}"]), beforeHead)
        XCTAssertEqual(try fixture.git(["show", ":Sources/Review.swift"]), beforeIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.url), beforeBytes)
    }

    @MainActor func testClosingFileDuringHistoryResolutionDoesNotOpenChanges() async throws {
        let fixture = try FileReviewProjectFixture()
        defer { fixture.close() }
        let tab = fixture.model.openFile(fixture.url)
        fixture.model.showFileHistory(from: tab)
        let work = tab.historyTask
        fixture.model.tabs.close(tab)
        await work?.value
        XCTAssertFalse(fixture.model.tabs.allTabs.contains { $0 is ChangesTab })
    }
    @MainActor private func defaults() throws -> UserDefaults {
        let name = "FileReviewFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor func testTabHostRelaunchStartsOnlyActiveReaderAndKeepsHiddenPosition() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let defaults = try defaults(), host = TabHost(defaults: defaults)
        host.showsWindows = false; host.restore()
        let first = try XCTUnwrap(host.open(kind: FileTab.kind, key: fixture.tab.key) { FileTab(url: fixture.url, projectID: nil) } as? FileTab)
        let scroll = try XCTUnwrap(first.scroll)
        fixture.window.contentView = scroll
        try await eventually("first ready") { first.status == .ready }
        scroll.textView.select(from: .init(line: 90, column: 4), to: .init(line: 92, column: 7))
        let secondURL = fixture.root.appendingPathComponent("Second.txt")
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        _ = host.open(kind: FileTab.kind, key: FileTab.key(for: secondURL)) { FileTab(url: secondURL, projectID: nil) }
        host.tearDown()
        let restored = TabHost(defaults: defaults)
        defer { restored.tearDown() }
        restored.showsWindows = false; restored.restore()
        let active = try XCTUnwrap(restored.pane.activeTab as? FileTab)
        XCTAssertTrue(active.isShownNow, "actual restore sends visibility, without a manual didShow")
        let hidden = try XCTUnwrap(restored.allTabs.first { $0.key == first.key } as? FileTab)
        XCTAssertFalse(hidden.hasDocument)
        restored.activate(hidden)
        let reopened = try XCTUnwrap(hidden.scroll)
        fixture.window.contentView = reopened
        try await eventually("hidden ready on selection") { hidden.status == .ready }
        XCTAssertEqual(reopened.textView.anchor, .init(line: 90, column: 4))
        XCTAssertEqual(reopened.textView.focus, .init(line: 92, column: 7))
    }

    @MainActor func testExplicitLinkWinsAndShortenedFileClampsSavedSelection() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let scroll = try XCTUnwrap(fixture.tab.scroll)
        fixture.window.contentView = scroll
        try await eventually("ready") { fixture.tab.status == .ready }
        scroll.textView.select(from: .init(line: 200, column: 15), to: .init(line: 201, column: 8))
        let saved = try XCTUnwrap(fixture.tab.savedState())
        let link = try XCTUnwrap(FileTab.restore(key: fixture.tab.key, state: saved) as? FileTab)
        defer { link.willClose() }
        link.reveal(lines: 40...42); link.didShow()
        fixture.window.contentView = try XCTUnwrap(link.scroll)
        try await eventually("explicit link") { link.scroll?.textView.emphasized == 40...42 }
        XCTAssertEqual(link.scroll?.textView.focus, .init(line: 40, column: 0))
        try "short\nx".write(to: fixture.url, atomically: true, encoding: .utf8)
        let shorter = try XCTUnwrap(FileTab.restore(key: fixture.tab.key, state: saved) as? FileTab)
        defer { shorter.willClose() }
        shorter.didShow(); fixture.window.contentView = try XCTUnwrap(shorter.scroll)
        try await eventually("short file") { shorter.status == .ready }
        XCTAssertEqual(shorter.scroll?.textView.anchor, .init(line: 1, column: 1))
        XCTAssertEqual(shorter.scroll?.textView.focus, .init(line: 1, column: 1))
    }

    @MainActor func testRedirectedSavedReferenceAndMalformedStateAreNotRestored() throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let saved = fixture.tab.savedState(), key = fixture.tab.key
        let other = fixture.root.appendingPathComponent("private.txt")
        try "private".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: other)
        XCTAssertNil(FileTab.restore(key: key, state: saved))
        XCTAssertNil(FileTab.restore(key: key, state: Data("{broken".utf8)))
    }

    @MainActor func testRecentsSurviveRelaunchStayBoundedAndForgetRemovedProjects() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let defaults = try defaults(), first = QuickOpen(defaults: defaults)
        for n in 0..<24 {
            let url = fixture.root.appendingPathComponent("File-\(n).txt")
            try "PRIVATE FIXTURE CONTENT".write(to: url, atomically: true, encoding: .utf8)
            first.noteOpened(url.resolvingSymlinksInPath(), projectID: "project")
        }
        let project = QuickOpen.Project(id: "project", name: "Fixture", roots: [fixture.root.path], trusted: true)
        let reopened = QuickOpen(defaults: defaults)
        reopened.projectsChanged([project]); reopened.show(project, in: nil)
        defer { reopened.close(restoringFocus: false) }
        try await eventually("durable recents") { reopened.answered == "" }
        XCTAssertEqual(reopened.rows.count, QuickOpen.recentLimit)
        XCTAssertEqual(reopened.rows.first?.name, "File-23.txt")
        XCTAssertEqual(reopened.rows.last?.name, "File-4.txt")
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: FileRecentState.key)), as: UTF8.self).contains("PRIVATE FIXTURE CONTENT"))
        reopened.projectsChanged([.init(id: project.id, name: project.name, roots: project.roots, trusted: false)])
        reopened.noteOpened(fixture.url, projectID: project.id)
        XCTAssertTrue(FileRecentState.read(defaults).isEmpty, "denied opens cannot recreate untrusted references")
        reopened.projectsChanged([])
        reopened.noteOpened(fixture.url, projectID: project.id)
        let afterRemoval = QuickOpen(defaults: defaults)
        afterRemoval.show(project, in: nil)
        defer { afterRemoval.close(restoringFocus: false) }
        try await eventually("removed project forgotten") { afterRemoval.answered == "" }
        XCTAssertTrue(afterRemoval.rows.isEmpty)
    }

    @MainActor func testRecentsValidateOffMainAndRejectRedirectsDirectoriesAndMissingFiles() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let quick = QuickOpen(), observed = FileReviewFlag()
        let url = fixture.url.resolvingSymlinksInPath()
        quick.noteOpened(url, projectID: "p")
        quick.noteOpened(fixture.root.resolvingSymlinksInPath(), projectID: "p")
        quick.noteOpened(fixture.root.appendingPathComponent("missing").resolvingSymlinksInPath(), projectID: "p")
        let fifo = fixture.root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        quick.noteOpened(fifo.resolvingSymlinksInPath(), projectID: "p")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        quick.beforeRecentValidation = { observed.set(!Thread.isMainThread) }
        quick.show(.init(id: "p", name: "Fixture", roots: [fixture.root.path], trusted: true), in: nil)
        defer { quick.close(restoringFocus: false) }
        try await eventually("validated") { quick.answered == "" }
        XCTAssertTrue(observed.value)
        XCTAssertTrue(quick.rows.isEmpty)
    }
    @MainActor func testRelaunchRestoresViewportAndSelectionWithoutSavingContents() async throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let tab = fixture.tab
        let scroll = try XCTUnwrap(tab.scroll)
        fixture.window.contentView = scroll
        try await eventually("file indexed") { tab.status == .ready }
        scroll.textView.select(from: .init(line: 126, column: 9), to: .init(line: 123, column: 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1700))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        let data = try XCTUnwrap(tab.savedState())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE FIXTURE CONTENT"))
        let restored = try XCTUnwrap(FileTab.restore(key: tab.key, state: data) as? FileTab)
        defer { restored.willClose() }
        let reopened = try XCTUnwrap(restored.scroll)
        fixture.window.contentView = reopened
        restored.didShow()
        try await eventually("restored file indexed") { restored.status == .ready }
        XCTAssertEqual(reopened.textView.anchor, .init(line: 126, column: 9))
        XCTAssertEqual(reopened.textView.focus, .init(line: 123, column: 2))
        XCTAssertEqual(reopened.contentView.bounds.minY, origin.y, accuracy: 1)
    }

    @MainActor func testOldSavedStateAndRemovedProjectDoNotReadOnRestore() throws {
        let fixture = try FileReviewFixture()
        defer { fixture.close() }
        let old = try XCTUnwrap(FileTab.restore(key: fixture.tab.key, state: Data("{\"project\":\"removed\"}".utf8)) as? FileTab)
        defer { old.willClose() }
        XCTAssertFalse(old.hasDocument)
        XCTAssertNil(old.document)
        XCTAssertEqual(old.projectID, "removed")
    }
}

@MainActor final class FileReviewFixture {
    let root: URL
    let url: URL
    let tab: FileTab
    let window: NSWindow
    private let projectResolver: (String?) -> FileProjectState
    init(root: URL = scratchRoot("file-review")) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("Reader.swift")
        try (0..<500).map { "// PRIVATE FIXTURE CONTENT row \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        projectResolver = FileTab.resolveProject
        FileTab.resolveProject = { $0 == nil ? .none : .removed }
        tab = FileTab(url: url, projectID: nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tab.didShow()
    }
    func close() {
        tab.willClose(); window.contentView = nil; window.close()
        FileTab.resolveProject = projectResolver
        try? FileManager.default.removeItem(at: root)
    }
}

/// Lock protects the one cross-thread fixture observation.
final class FileReviewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}

/// Only the first validation waits; lock protects which worker claimed it.
private final class FileReviewDeliveryGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var claimed = false
    var entered: Bool { lock.withLock { claimed } }
    func holdFirst() {
        let hold = lock.withLock { if claimed { return false }; claimed = true; return true }
        if hold { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}
