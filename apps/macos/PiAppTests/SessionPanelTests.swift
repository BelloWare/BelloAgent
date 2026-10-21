import AppKit
import XCTest
import FileFinder
@testable import PiApp
@testable import GitView

@MainActor private final class SessionPanelTestWindow: NSWindow {
    // Route the app-wide request without depending on WindowServer activation.
    // First responders and the panel's controls remain real AppKit objects.
    var nominatedKeyWindow: Bool?
    override var isKeyWindow: Bool { nominatedKeyWindow ?? super.isKeyWindow }
}

final class SessionPanelTests: GitPanelTestCase, SerialTestLane {
    @MainActor func testWideMainChatShowsFloatingPanelEvenWithoutAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["main"])
        registerWorkspaceFixtureTeardown(bench.model, root: root)
        let session = SessionDisplay(id: bench.chats[0].id)
        session.historyState = .ready; session.draftReady = true
        session.messages = [.init(id: "reply", role: "assistant", text: "A generated reply.")]
        bench.model.displays[session.id] = session
        let pane = ConversationPaneView(model: bench.model, panelState: SessionPanelState())
        pane.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        pane.show(session: session, chat: bench.chats[0])
        pane.layoutSubtreeIfNeeded()
        let panel = ConversationPaneTests.views(NSView.self, in: pane).first {
            $0.accessibilityIdentifier() == "session-floating-panel" && !$0.isHidden
        }
        XCTAssertNotNil(panel, "Every wide main chat shows the floating panel, including an empty family")
        if let panel {
            XCTAssertLessThanOrEqual(pane.transcript.frame.maxX, panel.frame.minX)
            XCTAssertLessThanOrEqual(panel.frame.maxY, pane.composer.frame.minY)
        }
    }

    @MainActor private func fixture(width: CGFloat = 900, gitRepository: Bool = false) throws -> (WorkspaceModel, ConversationPaneView, NSWindow, URL) {
        let root = try repository("session-panel")
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.tabs.showsWindows = false
        for chat in model.chats {
            let display = SessionDisplay(id: chat.id)
            display.historyState = .ready; display.draftReady = true
            display.messages = [.init(id: "reply-" + chat.id, role: "assistant", text: String(repeating: "Generated transcript text for the reading column. ", count: 25))]
            model.displays[chat.id] = display
        }
        model.selectedID = "chat-parent"; model.selected = model.displays["chat-parent"]; model.focusedSessionID = "chat-parent"
        model.historyWindowLoader = { id, _, _, _ in
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string(id), "lineage": .string("root"),
                "messages": .array([.object(["id": .string("reply-" + id), "role": .string("assistant"), "text": .string("Generated reader content")])]),
                "older": .null, "newer": .null]))
        }
        if gitRepository {
            try start(root)
            try "app-state/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try "one\ntwo\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root); try git(["commit", "-qm", "Generated fixture"], in: root)
            try "one\nchanged\nthree\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        let pane = ConversationPaneView(model: model, panelState: SessionPanelState())
        pane.show(session: model.selected!, chat: model.chats[0])
        let window = SessionPanelTestWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.tabs.tearDown(); window.contentView = nil; window.close() }
        pane.layoutSubtreeIfNeeded()
        return (model, pane, window, root)
    }
    @MainActor private func button(_ id: String, in view: NSView) throws -> PiKit.ButtonBase {
        try XCTUnwrap(ConversationPaneTests.views(PiKit.ButtonBase.self, in: view).first { $0.accessibilityIdentifier() == id })
    }

    @MainActor private func untrustedFileLinked(from root: URL, model: WorkspaceModel, name: String = "secret.swift",
                                                link linkName: String = "linked.swift", project: String = "private") throws -> (link: URL, target: URL) {
        let other = try repository("panel-private")
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        let target = other.appendingPathComponent(name), link = root.appendingPathComponent(linkName)
        try "Generated private content\n".write(to: target, atomically: true, encoding: .utf8)
        model.workspaces.append(WorkspaceRecord(id: project, path: other.path, trusted: false))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return (link, target)
    }

    @MainActor func testThresholdAndNoOverlapAtSeveralWidths() throws {
        let (_, pane, window, _) = try fixture()
        for width in [640.0, 799, 800, 820, 900, 1180, 1700, 799, 800] {
            window.setContentSize(CGSize(width: width, height: 700)); pane.layoutSubtreeIfNeeded()
            let shown = width >= 800
            XCTAssertEqual(!pane.sessionPanel.isHidden, shown, "width \(width)")
            XCTAssertEqual(pane.agentFamilyHeader.isHidden, shown, "width \(width)")
            if shown {
                XCTAssertEqual(pane.sessionPanel.frame.width, 288)
                XCTAssertGreaterThanOrEqual(pane.transcript.frame.width, 480)
                XCTAssertLessThanOrEqual(pane.transcript.frame.maxX + 16, pane.sessionPanel.frame.minX)
                XCTAssertLessThanOrEqual(pane.sessionPanel.frame.maxY + 16, pane.composer.frame.minY)
                XCTAssertTrue(pane.bounds.contains(pane.sessionPanel.frame))
            } else {
                XCTAssertEqual(pane.transcript.frame.width, width)
                XCTAssertGreaterThanOrEqual(pane.transcript.frame.minY, pane.agentFamilyHeader.frame.maxY)
            }
        }
        let area = CGRect(x: 0, y: 0, width: 1700, height: 600)
        XCTAssertEqual(SessionPanelLayout.transcript(in: area).midX, area.midX, "Spare margin preserves the centred reading column")
    }

    @MainActor func testQueueFindAndGrowingComposerNeverIntersectPanel() async throws {
        let (model, pane, _, _) = try fixture()
        let session = try XCTUnwrap(model.selected)
        session.queue = (0..<4).map { ["turnId": .string("q\($0)"), "kind": .string("followup"), "text": .string("Generated follow-up \($0)")] }
        session.draft = (0..<6).map { "Draft line \($0)" }.joined(separator: "\n")
        session.findCommand = TranscriptFindCommand(kind: .show, serial: 1)
        try await eventually("find and queue") {
            pane.refresh(); pane.layoutSubtreeIfNeeded()
            return pane.transcript.findBar != nil && !ConversationPaneTests.views(QueuePanelView.self, in: pane).isEmpty
        }
        XCTAssertFalse(pane.sessionPanel.isHidden)
        let panel = pane.sessionPanel.frame
        for view in [pane.composer, pane.transcript.findBar!, ConversationPaneTests.views(QueuePanelView.self, in: pane)[0]] as [NSView] {
            XCTAssertFalse(panel.intersects(view.convert(view.bounds, to: pane)))
        }
        let before = pane.transcript.frame
        session.draft += " more words"; pane.refresh(); pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.transcript.frame, before, "Typing within the same line never changes the reading column")
    }

    @MainActor func testShortPaneFallsBackAndLongFamilyScrollsInsideCard() throws {
        let (model, pane, window, _) = try fixture()
        for index in 0..<30 {
            var side = model.chats[2]; side.id = "side-\(index)"; model.chats.append(side)
        }
        pane.sessionPanel.agents?.refresh(); pane.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(pane.sessionPanel.agents?.enclosingScrollView)
        XCTAssertGreaterThan(scroll.documentView!.frame.height, scroll.contentSize.height)
        XCTAssertLessThanOrEqual(pane.sessionPanel.frame.maxY, pane.composer.frame.minY)
        window.setContentSize(CGSize(width: 900, height: 260)); pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.sessionPanel.isHidden)
        XCTAssertFalse(pane.agentFamilyHeader.isHidden)
    }

    @MainActor func testCollapseReopenAndTabChoiceAreWindowSessionState() async throws {
        let (model, pane, window, _) = try fixture()
        pane.sessionPanel.select(.files)
        XCTAssertEqual(pane.panelState.selection, .files)
        pane.sessionPanel.collapse.onPress?()
        XCTAssertTrue(pane.sessionPanel.isHidden); XCTAssertTrue(pane.panelState.collapsed)
        window.setContentSize(CGSize(width: 1000, height: 700)); pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.sessionPanel.isHidden)
        pane.agentFamilyHeader.button.onPress?()
        XCTAssertFalse(pane.sessionPanel.isHidden); XCTAssertFalse(pane.panelState.collapsed)
        // Reopening restores the card; the family shortcut explicitly selects Agents.
        XCTAssertEqual(pane.panelState.selection, .files)
        var another = model.chats[0]; another.id = "another-main"; model.chats.append(another)
        let display = SessionDisplay(id: another.id); display.historyState = .ready
        pane.show(session: display, chat: another); pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.sessionPanel.selectedTab, .files)
        XCTAssertEqual(SessionPanelState().selection, .agents)
        XCTAssertFalse(SessionPanelState().collapsed)
    }

    @MainActor func testEmptyCollapsedFamilyStillHasReopenPill() throws {
        let (model, pane, _, _) = try fixture()
        model.chats.removeAll { $0.id != "chat-parent" }
        pane.refresh(); pane.sessionPanel.agents?.refresh(); pane.layoutSubtreeIfNeeded()
        XCTAssertNotNil(try button("new-family-side", in: pane.sessionPanel))
        pane.sessionPanel.collapse.onPress?()
        XCTAssertFalse(pane.agentFamilyHeader.isHidden)
        XCTAssertEqual(pane.agentFamilyHeader.button.title, "Agents")
        XCTAssertTrue(pane.agentFamilyHeader.button.accessibilityLabel()?.hasPrefix("Agents.") == true)
        pane.agentFamilyHeader.open()
        XCTAssertFalse(pane.sessionPanel.isHidden)
    }

    @MainActor func testScratchAndNonRepositoryTabsAndLazyReaders() async throws {
        let (model, pane, _, _) = try fixture()
        XCTAssertNil(pane.sessionPanel.changes); XCTAssertNil(pane.sessionPanel.files)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(pane.sessionPanel.availableTabs, [.agents, .files])
        var scratch = model.chats[0]; scratch.workspaceID = WorkspaceRecord.scratchID
        pane.show(session: model.selected!, chat: scratch)
        XCTAssertEqual(pane.sessionPanel.availableTabs, [.agents])
        XCTAssertNil(pane.sessionPanel.changes); XCTAssertNil(pane.sessionPanel.files)
    }

    @MainActor func testTabAccessibilityFollowsIdentityWhenDiffIsInsertedAfterFiles() async throws {
        let (_, pane, _, _) = try fixture(gitRepository: true)
        let panel = pane.sessionPanel
        XCTAssertEqual(panel.availableTabs, [.agents, .files])
        let files = try XCTUnwrap(panel.tabs.tab(.files))
        XCTAssertEqual(files.accessibilityIdentifier(), "session-panel-tab-files")
        try await eventually("Diff inserted between retained tabs") { panel.availableTabs == [.agents, .diff, .files] }
        XCTAssertTrue(panel.tabs.tab(.files) === files)
        // Retained AppKit subviews need not follow the new visual tab order.
        XCTAssertEqual(PiKit.controls(in: panel.tabs).compactMap { ($0 as? PiKit.ButtonBase)?.title }, ["Agents", "Files", "Diff"])
        for tab in panel.availableTabs {
            let control = try XCTUnwrap(panel.tabs.tab(tab))
            XCTAssertEqual(control.title, tab.rawValue)
            XCTAssertEqual(control.accessibilityLabel(), tab.rawValue)
            XCTAssertEqual(control.accessibilityIdentifier(), "session-panel-tab-" + tab.rawValue.lowercased())
            control.onPress?()
            XCTAssertEqual(panel.selectedTab, tab)
        }
    }

    @MainActor func testNegativeRepositoryDiscoveryRetriesOnReactivation() async throws {
        for transition in ["collapse", "hidden ancestor", "disabled"] {
            let (_, pane, _, root) = try fixture()
            let panel = pane.sessionPanel
            try await eventually("negative discovery", timeout: 5) { panel.repositoryChecked }
            XCTAssertFalse(panel.availableTabs.contains(.diff))
            if transition == "collapse" { panel.collapse.onPress?() }
            else if transition == "hidden ancestor" { pane.isHidden = true }
            else { pane.inheritedEnabled = false }
            XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: root.path), 0)
            try start(root)
            if transition == "collapse" { pane.agentFamilyHeader.button.onPress?() }
            else if transition == "hidden ancestor" { pane.isHidden = false }
            else { pane.inheritedEnabled = true }
            XCTAssertFalse(panel.repositoryChecked, "Reactivation invalidates the negative result before any filesystem event arrives")
            try await eventually("Diff after " + transition, timeout: 5) { panel.availableTabs.contains(.diff) }
            XCTAssertNil(panel.changes, "Reactivation discovers only the repository")
        }
    }

    @MainActor func testNegativeRepositoryDiscoveryRetriesOnSameProjectChatSwitch() async throws {
        let (model, pane, _, root) = try fixture()
        let panel = pane.sessionPanel
        try await eventually("negative discovery", timeout: 5) { panel.repositoryChecked }
        try start(root)
        var chat = model.chats[0]; chat.id = "another-main"; model.chats.append(chat)
        let display = SessionDisplay(id: chat.id); display.historyState = .ready
        pane.show(session: display, chat: chat)
        XCTAssertFalse(panel.repositoryChecked, "Chat switching invalidates the negative result before any filesystem event arrives")
        try await eventually("Diff in the next chat", timeout: 5) { panel.availableTabs.contains(.diff) }
    }

    @MainActor func testNegativeRepositoryDiscoveryObservesGitInitWhilePanelIsOpen() async throws {
        let (_, pane, _, root) = try fixture()
        let panel = pane.sessionPanel
        try await eventually("negative discovery", timeout: 5) { panel.repositoryChecked }
        for _ in 0..<3 {
            panel.refresh()
            XCTAssertTrue(panel.repositoryChecked, "Ordinary refreshes retain the negative snapshot until a real invalidation")
        }
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: root.path), 1)
        XCTAssertNil(panel.files); XCTAssertNil(panel.changes)
        try start(root)
        try await eventually("Diff after git init without a UI transition", timeout: 5) { panel.availableTabs.contains(.diff) }
        XCTAssertEqual(panel.selectedTab, .agents)
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: root.path), 0, "Discovery lets go once Git is found; the Diff reader remains lazy")
        XCTAssertNil(panel.files); XCTAssertNil(panel.changes)
    }

    @MainActor func testNegativeRepositoryDiscoveryRetriesOnFolderBrowserChanges() async throws {
        let (_, pane, _, root) = try fixture()
        let panel = pane.sessionPanel
        panel.select(.files)
        let browser = try XCTUnwrap(panel.files?.browser)
        try await eventually("negative discovery and folder listing", timeout: 5) {
            panel.repositoryChecked && browser.snapshot(root) != nil && !browser.isLoading(root)
        }
        try start(root)
        browser.expand(root)
        XCTAssertFalse(panel.repositoryChecked, "Folder events invalidate the negative result before the Git watch delivers")
        try await eventually("Diff after folder refresh", timeout: 5) { panel.availableTabs.contains(.diff) }
        XCTAssertEqual(panel.selectedTab, .files)
    }

    @MainActor func testPositiveRepositoryDiscoveryRevalidatesOnReactivation() async throws {
        for transition in ["collapse", "hidden ancestor", "disabled"] {
            let (_, pane, _, root) = try fixture(gitRepository: true)
            let panel = pane.sessionPanel
            try await eventually("positive discovery") { panel.availableTabs.contains(.diff) }
            if transition == "collapse" { panel.collapse.onPress?() }
            else if transition == "hidden ancestor" { pane.isHidden = true }
            else { pane.inheritedEnabled = false }
            try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
            if transition == "collapse" { pane.agentFamilyHeader.button.onPress?() }
            else if transition == "hidden ancestor" { pane.isHidden = false }
            else { pane.inheritedEnabled = true }
            XCTAssertFalse(panel.repositoryChecked, "Successful discovery also expires on reactivation")
            try await eventually("removed repository after " + transition, timeout: 5) { panel.availableTabs == [.agents, .files] }
            XCTAssertNil(panel.changes, "Reactivation keeps changes lazy")
            try start(root)
            try await eventually("recreated repository after " + transition, timeout: 5) { panel.availableTabs.contains(.diff) }
        }
    }

    @MainActor func testMissingSummaryRepositoryRearmsDiscoveryAndKeepsFilesUsable() async throws {
        for empty in [false, true] {
            let (_, pane, _, root) = try fixture(gitRepository: true)
            if empty { try git(["restore", "file.txt"], in: root) }
            let panel = pane.sessionPanel
            try await eventually("repository discovery") { panel.availableTabs.contains(.diff) }
            panel.select(.diff)
            let changes = try XCTUnwrap(panel.changes)
            try await eventually("summary read") { changes.controller.statusRead && !changes.controller.loading }
            XCTAssertEqual(changes.controller.status.entries.isEmpty, empty)
            try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
            await changes.controller.refresh()
            try await eventually("missing repository hides Diff", timeout: 5) { panel.availableTabs == [.agents, .files] }
            XCTAssertNil(panel.changes, "Retire the missing summary before a replacement repository arrives")
            panel.select(.files)
            let browser = try XCTUnwrap(panel.files?.browser)
            try await eventually("ordinary project files remain browsable") {
                browser.rows.contains { $0.url.lastPathComponent == "file.txt" && $0.entry != nil }
            }
            try start(root)
            try await eventually("git init is discovered without a chat switch", timeout: 5) { panel.availableTabs.contains(.diff) }
            panel.select(.diff)
            let replacement = try XCTUnwrap(panel.changes)
            XCTAssertFalse(replacement === changes)
            try await eventually("new repository counts") { replacement.controller.changeStats["file.txt"] != nil }
        }
    }

    @MainActor func testUnavailableCountsHaveAnExplicitRowLabel() {
        let entry = GitStatusEntry(path: "missing.txt", originalPath: nil, indexState: ".", worktreeState: ".", untracked: true)
        let row = SessionPanelDiffRow(entry: entry, stat: nil)
        XCTAssertTrue(row.accessibilityLabel()?.contains("Counts unavailable") == true)
        XCTAssertTrue(row.toolTip?.contains("Counts unavailable") == true)
    }

    @MainActor func testDiffCountsAndClickOpenExistingChangesTab() async throws {
        let (model, pane, _, _) = try fixture(gitRepository: true)
        try await eventually("repository discovered") { pane.sessionPanel.availableTabs.contains(.diff) }
        XCTAssertNil(pane.sessionPanel.changes, "Discovery does not read status/history")
        pane.sessionPanel.select(.diff)
        let changes = try XCTUnwrap(pane.sessionPanel.changes)
        try await eventually("counts read") { changes.controller.changeStats["file.txt"] != nil }
        XCTAssertEqual(changes.controller.changeStats["file.txt"]?.added, 2)
        XCTAssertEqual(changes.controller.changeStats["file.txt"]?.removed, 1)
        XCTAssertTrue(changes.controller.diff.isEmpty); XCTAssertTrue(changes.controller.commits.isEmpty)
        pane.layoutSubtreeIfNeeded()
        let row = try button("panel-diff-file.txt", in: changes)
        XCTAssertTrue(row.accessibilityLabel()?.contains("+2 −1") == true)
        row.onPress?()
        let tab = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab)
        XCTAssertEqual(tab.controller.selection?.path, "file.txt")
        XCTAssertFalse(tab.controller.selection?.staged ?? true)
        row.onPress?()
        XCTAssertTrue(model.tabs.pane.activeTab === tab)
        pane.sessionPanel.select(.agents)
        XCTAssertTrue(changes.controller.suspended)
    }

    @MainActor func testConfiguredRenameAndCopyRowsCountTheDiffTheyOpen() async throws {
        for mode in ["false", "copies"] {
            let (model, pane, _, root) = try fixture(gitRepository: true)
            try git(["restore", "file.txt"], in: root)
            try git(["config", "status.renames", mode], in: root)
            if mode == "false" {
                try git(["mv", "file.txt", "moved.txt"], in: root)
            } else {
                try "one\ntwo\ncopy\n".write(to: root.appendingPathComponent("copy.txt"), atomically: true, encoding: .utf8)
                try "one\ntwo\nsource\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
                try git(["add", "."], in: root)
            }
            try await eventually("repository discovered") { pane.sessionPanel.availableTabs.contains(.diff) }
            pane.sessionPanel.select(.diff)
            let changes = try XCTUnwrap(pane.sessionPanel.changes)
            try await eventually("counts read") { changes.controller.statusRead && !changes.controller.loading }
            XCTAssertEqual(changes.controller.status.entries.map(\.badge), mode == "false" ? ["D", "A"] : ["C", "M"])
            pane.layoutSubtreeIfNeeded()
            for entry in changes.controller.status.entries {
                let row = try button("panel-diff-" + entry.path, in: changes)
                row.onPress?()
                let tab = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab)
                tab.controller.setShown(true)
                await tab.controller.refresh()
                try await eventually("selected diff read") { !tab.controller.diffLoading && !tab.controller.diff.isEmpty }
                XCTAssertEqual(tab.controller.selection, .init(path: entry.path, staged: true))
                XCTAssertEqual(tab.controller.diff.map(\.path), [entry.path], "A copy source is context for detection, not another selected row")
                let opened = try XCTUnwrap(tab.controller.diff.first { $0.path == entry.path })
                let stats = try XCTUnwrap(changes.controller.changeStats[entry.path])
                XCTAssertEqual(stats, GitDiffStat(added: opened.added, removed: opened.removed, binary: opened.binary), entry.path)
                XCTAssertTrue(row.accessibilityLabel()?.contains("+\(opened.added) −\(opened.removed)") == true)
            }
        }
    }

    @MainActor func testPanelAndChangesMatchRawStatusWithWorktreeOverrides() async throws {
        for key in ["diff.renames", "diff.renameLimit"] {
            let (model, pane, _, root) = try fixture(gitRepository: true)
            try git(["restore", "file.txt"], in: root)
            for index in 0..<3 {
                let text = (0..<20).map { "file \(index) line \($0)\n" }.joined()
                try text.write(to: root.appendingPathComponent("old-\(index).txt"), atomically: true, encoding: .utf8)
            }
            try git(["add", "."], in: root); try git(["commit", "-qm", "Generated rename baseline"], in: root)
            for index in 0..<3 {
                try FileManager.default.removeItem(at: root.appendingPathComponent("old-\(index).txt"))
                let text = (0..<20).map { $0 < 5 ? "replacement \(index) \($0)\n" : "file \(index) line \($0)\n" }.joined()
                try text.write(to: root.appendingPathComponent("new-\(index).txt"), atomically: true, encoding: .utf8)
            }
            try git(["add", "."], in: root)
            try git(["config", "extensions.worktreeConfig", "true"], in: root)
            try git(["config", "--local", key, key == "diff.renames" ? "true" : "1000"], in: root)
            try git(["config", "--worktree", key, key == "diff.renames" ? "false" : "1"], in: root)
            let effective = try git(["config", "--get", key], in: root).trimmingCharacters(in: .newlines)
            XCTAssertEqual(effective, key == "diff.renames" ? "false" : "1")
            let output = try git(["status", "--porcelain=v2", "--untracked-files=all", "-z"], in: root)
            let expected = GitService.parseStatus(Data(output.utf8)).entries
            try await eventually("repository discovered") { pane.sessionPanel.availableTabs.contains(.diff) }
            pane.sessionPanel.select(.diff)
            let changes = try XCTUnwrap(pane.sessionPanel.changes)
            try await eventually("counts read") { changes.controller.statusRead && !changes.controller.loading }
            XCTAssertEqual(changes.controller.status.entries, expected, "Panel grouping must match git status")
            pane.layoutSubtreeIfNeeded()
            for entry in expected {
                let row = try button("panel-diff-" + entry.path, in: changes)
                row.onPress?()
                let tab = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab)
                tab.controller.setShown(true)
                await tab.controller.refresh()
                try await eventually("selected diff read") { !tab.controller.diffLoading && !tab.controller.diff.isEmpty }
                XCTAssertEqual(tab.controller.status.entries, expected, "Changes grouping must match git status")
                XCTAssertEqual(tab.controller.diff.map(\.path), [entry.path])
                let opened = try XCTUnwrap(tab.controller.diff.first)
                XCTAssertEqual(changes.controller.changeStats[entry.path],
                               GitDiffStat(added: opened.added, removed: opened.removed, binary: opened.binary))
            }
        }
    }

    @MainActor func testFilesAreLazyVirtualizedAndKeepUntrustedContentUnreadable() async throws {
        let (model, pane, _, root) = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
        try "fixture\n".write(to: root.appendingPathComponent("Sources/Nested/a.txt"), atomically: true, encoding: .utf8)
        model.workspaces[0].trusted = false; pane.refresh()
        pane.sessionPanel.select(.files)
        let files = try XCTUnwrap(pane.sessionPanel.files), browser = files.browser
        try await eventually("root entries") { browser.snapshot(root) != nil }
        XCTAssertNil(browser.snapshot(root.appendingPathComponent("Sources")))
        browser.expand(root.appendingPathComponent("Sources"))
        try await eventually("first level") { browser.snapshot(root.appendingPathComponent("Sources")) != nil }
        XCTAssertNil(browser.snapshot(root.appendingPathComponent("Sources/Nested")))
        browser.expand(root.appendingPathComponent("Sources/Nested"))
        try await eventually("second level") { browser.snapshot(root.appendingPathComponent("Sources/Nested")) != nil }
        let url = root.appendingPathComponent("Sources/Nested/a.txt")
        browser.select(url); XCTAssertTrue(files.tree.navigate(keyCode: 36))
        let tab = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab)
        XCTAssertEqual(tab.url.path, url.path)
        XCTAssertFalse(tab.readable); XCTAssertNil(tab.document)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertFalse(model.workspaces[0].trusted)
        pane.sessionPanel.select(.agents)
        XCTAssertFalse(browser.isLoading(root))
        pane.sessionPanel.select(.files)
        XCTAssertTrue(browser.expanded.contains(FileBreadcrumb.normalized(root.appendingPathComponent("Sources/Nested"))))
    }

    @MainActor func testFilesSymlinkUsesTheSameDestinationTrustAsQuickOpen() async throws {
        let (model, pane, window, root) = try fixture()
        let (link, target) = try untrustedFileLinked(from: root, model: model)
        XCTAssertTrue(model.workspaces[0].trusted)
        model.showQuickOpen(in: window)
        model.quickOpen.query = link.lastPathComponent
        try await eventually("Quick Open lists the symlink") {
            model.quickOpen.answered == link.lastPathComponent && !model.quickOpen.rows.isEmpty
        }
        model.openQuickOpenChoice()
        let quickOpen = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab)
        XCTAssertEqual(quickOpen.key, FileTab.key(for: target))
        XCTAssertEqual(quickOpen.projectID, "private")
        XCTAssertFalse(quickOpen.readable); XCTAssertNil(quickOpen.document)
        model.tabs.close(quickOpen)

        pane.sessionPanel.select(.files)
        let files = try XCTUnwrap(pane.sessionPanel.files), browser = files.browser
        try await eventually("Files lists the symlink") { browser.rows.contains { $0.url == link } }
        for route in ["pointer", "keyboard", "accessibility"] {
            pane.layoutSubtreeIfNeeded()
            let table = files.tree.table
            let row = try XCTUnwrap(browser.rows.firstIndex { $0.url == link })
            switch route {
            case "pointer":
                let rect = table.rect(ofRow: row)
                let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                table.mouseDown(with: event)
            case "keyboard":
                browser.select(link); XCTAssertTrue(files.tree.navigate(keyCode: 36))
            default:
                let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                XCTAssertTrue(cell.accessibilityPerformPress())
            }
            let tab = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab)
            XCTAssertFalse(tab === quickOpen, "Each route must create a fresh tab, not reuse Quick Open's trust")
            XCTAssertEqual(tab.url, quickOpen.url, route)
            XCTAssertEqual(tab.projectID, quickOpen.projectID, route)
            XCTAssertEqual(tab.project, quickOpen.project, route)
            XCTAssertEqual(tab.missingReason, quickOpen.missingReason, route)
            XCTAssertFalse(tab.readable, route); XCTAssertNil(tab.document, route)
            model.tabs.close(tab)
        }
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertFalse(try XCTUnwrap(model.workspace(for: "private")).trusted)
    }

    /// A target name that begins with a combining mark or ZWJ joins the "/"
    /// before it into one Character; its untrusted project still holds it,
    /// rather than leaving it outside every project and readable.
    @MainActor func testFilesSymlinkToANameThatBeginsWithACombiningMarkKeepsTheDestinationsTrust() async throws {
        let (model, pane, window, root) = try fixture()
        let links = try ["\u{0301}", "\u{200D}"].enumerated().map { index, mark in
            try untrustedFileLinked(from: root, model: model, name: mark + "secret.swift", link: "linked-\(index).swift", project: "private-\(index)")
        }
        pane.sessionPanel.select(.files)
        let files = try XCTUnwrap(pane.sessionPanel.files), browser = files.browser
        try await eventually("Files lists the symlinks") { links.allSatisfy { link in browser.rows.contains { $0.url == link.link } } }
        for (index, (link, target)) in links.enumerated() {
            for route in ["pointer", "keyboard", "accessibility"] {
                let label = "\(index), \(route)"
                pane.layoutSubtreeIfNeeded()
                let table = files.tree.table
                let row = try XCTUnwrap(browser.rows.firstIndex { $0.url == link })
                switch route {
                case "pointer":
                    let rect = table.rect(ofRow: row)
                    let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 1, clickCount: 1, pressure: 1))
                    table.mouseDown(with: event)
                case "keyboard":
                    browser.select(link); XCTAssertTrue(files.tree.navigate(keyCode: 36))
                default:
                    let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                    XCTAssertTrue(cell.accessibilityPerformPress())
                }
                let tab = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab, label)
                XCTAssertEqual(Array(tab.key.utf8), Array(FileTab.key(for: target).utf8), label)
                XCTAssertEqual(tab.projectID, "private-\(index)", label)
                XCTAssertEqual(tab.project, .untrusted(name: target.deletingLastPathComponent().lastPathComponent), label)
                XCTAssertNotNil(tab.missingReason, label)
                XCTAssertFalse(tab.readable, label); XCTAssertNil(tab.document, label)
                model.tabs.close(tab)
            }
        }
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(model.workspaces.filter { $0.id.hasPrefix("private-") }.allSatisfy { !$0.trusted })
    }

    @MainActor func testDiffFileMenuResolvesSymlinkDestinationTrust() async throws {
        let (model, pane, window, root) = try fixture(gitRepository: true)
        let (link, target) = try untrustedFileLinked(from: root, model: model)
        try await eventually("repository discovered") { pane.sessionPanel.availableTabs.contains(.diff) }
        pane.sessionPanel.select(.diff)
        let changes = try XCTUnwrap(pane.sessionPanel.changes)
        try await eventually("symlink change listed") { changes.controller.status.entries.contains { $0.path == link.lastPathComponent } }
        pane.layoutSubtreeIfNeeded()
        try button("panel-diff-" + link.lastPathComponent, in: changes).onPress?()
        let tab = try XCTUnwrap(model.tabs.pane.activeTab as? ChangesTab)
        XCTAssertEqual(tab.projectID, model.chats[0].workspaceID, "The diff still belongs to its source repository")
        XCTAssertEqual(tab.controller.selection?.path, link.lastPathComponent)
        window.contentView = tab.contentView; window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("Changes repository resolved") { tab.controller.repositoryRoot != nil }
        let menu = try XCTUnwrap(GitDiffPiMenu.builder(openFile: { tab.openFile(path: $0, line: $1) })(
            GitDiffMenuRequest(hasSelection: false, filePath: link.lastPathComponent,
                fileLine: GitDiffFileLine(path: link.lastPathComponent, line: 1), copy: {}, selectAll: {})))
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "git-diff-open-file" })
        menu.performActionForItem(at: menu.index(of: item))
        let file = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab)
        XCTAssertEqual(file.key, FileTab.key(for: target))
        XCTAssertEqual(file.projectID, "private")
        XCTAssertFalse(file.readable); XCTAssertNil(file.document)
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testAgentsUpdateLiveAndOpenSideChildAndNewSide() async throws {
        let (model, pane, _, _) = try fixture()
        let child = try XCTUnwrap(model.record("chat-child"))
        model.subagentSummaries[child.id] = .init(link: child.delegation!, description: child.title, model: "fixture", status: .running, revision: 1)
        try await eventually("running row appears") {
            ConversationPaneTests.views(PiKit.ButtonBase.self, in: pane.sessionPanel).contains { $0.accessibilityIdentifier() == "stop-agent-chat-child" }
        }
        model.subagentSummaries[child.id]?.status = .completed
        try await eventually("running Stop disappears") {
            !ConversationPaneTests.views(PiKit.ButtonBase.self, in: pane.sessionPanel).contains { $0.accessibilityIdentifier() == "stop-agent-chat-child" }
        }
        try button("open-agent-chat-child", in: pane.sessionPanel).onPress?()
        try await eventually("child tab opens") { model.subagentTab(child.id) != nil }
        XCTAssertEqual(model.selectedID, "chat-parent")
        try button("open-side-chat-side", in: pane.sessionPanel).onPress?()
        try await eventually("side opens") { model.sides["chat-parent"]?.id == "chat-side" }
        try button("new-family-side", in: pane.sessionPanel).onPress?()
        try await eventually("new side") { model.sides["chat-parent"]?.pending == true }
    }

    @MainActor func testStopUsesExistingDelegationOwnerAndTurn() async throws {
        let (model, pane, _, root) = try fixture()
        let child = try XCTUnwrap(model.record("chat-child"))
        model.subagentSummaries[child.id] = .init(link: child.delegation!, description: child.title, model: "fixture", status: .running, revision: 1, turn: 3)
        var sent: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { sent.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("generated-host"))
        defer { host.shutdown() }
        model.hosts["pane-project"] = host; model.opened.insert("chat-parent")
        try await eventually("Stop row") {
            ConversationPaneTests.views(PiKit.ButtonBase.self, in: pane.sessionPanel).contains { $0.accessibilityIdentifier() == "stop-agent-chat-child" }
        }
        try button("stop-agent-chat-child", in: pane.sessionPanel).onPress?()
        try await eventually("stop command") { sent.contains { $0["method"]?.string == "subagent.stop" } }
        let stop = try XCTUnwrap(sent.first { $0["method"]?.string == "subagent.stop" })
        XCTAssertEqual(stop["sessionId"]?.string, "chat-parent")
        XCTAssertEqual(stop["params"]?.object?["childId"]?.string, child.id)
        XCTAssertEqual(stop["params"]?.object?["turn"]?.number, 3)
    }

    @MainActor func testFamilyShortcutFocusesAgentsAndMountNeverStealsComposer() async throws {
        let (model, pane, window, _) = try fixture()
        let testWindow = try XCTUnwrap(window as? SessionPanelTestWindow)
        defer { testWindow.nominatedKeyWindow = nil }
        let editor = try XCTUnwrap(ConversationPaneTests.views(ComposerTextView.self, in: pane).first)
        window.makeFirstResponder(editor)
        pane.sessionPanel.select(.files); pane.sessionPanel.select(.agents)
        XCTAssertTrue(window.firstResponder === editor)
        pane.sessionPanel.select(.files)
        testWindow.nominatedKeyWindow = false
        model.agentFamilyRequests.send("chat-parent")
        XCTAssertEqual(pane.sessionPanel.selectedTab, .files, "Inactive windows do not consume another window's shortcut")
        testWindow.nominatedKeyWindow = true
        model.agentFamilyRequests.send("chat-parent")
        XCTAssertEqual(pane.sessionPanel.selectedTab, .agents)
        let focused = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(focused.isDescendant(of: pane.sessionPanel.tabs))
        XCTAssertEqual(pane.sessionPanel.accessibilityLabel(), "Session panel")
        XCTAssertEqual(pane.sessionPanel.tabs.accessibilityLabel(), "Session panel tabs")
        let names = PiKit.controls(in: pane.sessionPanel.tabs).compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(names.contains("Agents")); XCTAssertTrue(names.contains("Files"))
        pane.sessionPanel.select(.files); pane.sessionPanel.collapse.onPress?()
        model.agentFamilyRequests.send("chat-parent")
        XCTAssertTrue(pane.panelState.collapsed, "A shortcut keeps a deliberately collapsed card collapsed")
        XCTAssertTrue(pane.sessionPanel.isHidden)
        XCTAssertNotNil(pane.agentFamilyHeader.popover.popover, "Hidden cards use the existing family popover")
        pane.agentFamilyHeader.popover.close()
        pane.agentFamilyHeader.button.onPress?()
        XCTAssertEqual(pane.sessionPanel.selectedTab, .files, "Only the pill restores the collapsed card's tab")
        pane.inheritedEnabled = false
        XCTAssertTrue(PiKit.controls(in: pane.sessionPanel.agents!).allSatisfy { !$0.isEnabled })
    }

    @MainActor func testSidesAndSubagentReadersNeverShowFloatingCard() throws {
        let (model, pane, _, _) = try fixture()
        let standalone = ConversationPaneView(model: model)
        standalone.frame = pane.frame
        standalone.show(session: model.selected!, chat: model.chats[0])
        standalone.layoutSubtreeIfNeeded()
        XCTAssertTrue(standalone.sessionPanel.isHidden, "Only the owning workspace enables the card")
        pane.show(session: model.displays["chat-child"]!, chat: model.record("chat-child")!)
        pane.showsAgentFamily = false; pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.sessionPanel.isHidden); XCTAssertTrue(pane.agentFamilyHeader.isHidden)
        pane.showsAgentFamily = true
        pane.show(session: model.displays["chat-side"]!, chat: model.record("chat-side")!)
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.sessionPanel.isHidden)
    }

    @MainActor func testEmptyFamilyShortcutIsAvailableOnlyWithAVisibleCardOrCollapsedPill() throws {
        let saved = UserDefaults.standard.object(forKey: "sidebarWidth")
        UserDefaults.standard.set(264.0, forKey: "sidebarWidth")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "sidebarWidth") }
            else { UserDefaults.standard.removeObject(forKey: "sidebarWidth") }
        }
        let (model, _, window, _) = try fixture(width: 1180)
        model.chats.removeAll { $0.id != "chat-parent" }
        let root = WorkspaceRootView(model: model)
        window.contentView = root; model.conversationWindow = { [weak window] in window }
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.canShowAgentFamily)
        let pane = try XCTUnwrap(root.conversation)
        pane.sessionPanel.collapse.onPress?()
        XCTAssertTrue(model.canShowAgentFamily)
        pane.agentFamilyHeader.open()
        window.setContentSize(CGSize(width: 960, height: 700)); root.layoutSubtreeIfNeeded()
        XCTAssertFalse(model.canShowAgentFamily)
        model.page = .report; root.refresh()
        XCTAssertFalse(model.canShowAgentFamily)
    }

    @MainActor func testDeletedAndRecreatedPathUsesOneWorkingTreeRow() throws {
        let status = GitService.parseStatus(Data("1 D. N... 100644 000000 000000 abc 000 same.txt\0? same.txt\0".utf8))
        XCTAssertEqual(status.entries.count, 2)
        let rows = SessionPanelChanges.compactEntries(status.entries)
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].untracked)
        let reversed = SessionPanelChanges.compactEntries(Array(status.entries.reversed()))
        XCTAssertEqual(reversed, rows)
    }

    @MainActor func testLayoutContractWithoutWindows() {
        XCTAssertFalse(SessionPanelLayout.fits(width: 799, height: 500))
        XCTAssertTrue(SessionPanelLayout.fits(width: 800, height: 500))
        XCTAssertFalse(SessionPanelLayout.fits(width: 1000, height: 211))
        XCTAssertTrue(SessionPanelLayout.fits(width: 1000, height: 212))
        for width in [800.0, 900, 1180, 1600] {
            let transcript = SessionPanelLayout.transcript(in: CGRect(x: 0, y: 0, width: width, height: 500))
            let panelLeft = width - 288 - 16
            XCTAssertLessThanOrEqual(transcript.maxX + 16, panelLeft)
            XCTAssertGreaterThanOrEqual(transcript.width, 480)
        }
    }

    @MainActor func testDiffRowKeepsFocusAndRefreshesItsRepositoryContext() async throws {
        let (model, pane, window, root) = try fixture(gitRepository: true)
        try await eventually("repository discovered") { pane.sessionPanel.availableTabs.contains(.diff) }
        pane.sessionPanel.select(.diff)
        let changes = try XCTUnwrap(pane.sessionPanel.changes)
        try await eventually("counts") { changes.controller.changeStats["file.txt"] != nil }
        pane.layoutSubtreeIfNeeded()
        let row = try button("panel-diff-file.txt", in: changes)
        XCTAssertTrue(window.makeFirstResponder(row))
        try "one\nchanged\nthree\nfour\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try git(["branch", "-m", "review"], in: root)
        await changes.controller.refresh()
        try await eventually("new row counts") { row.accessibilityLabel()?.contains("+3 −1") == true }
        XCTAssertTrue(try button("panel-diff-file.txt", in: changes) === row)
        XCTAssertTrue(window.firstResponder === row)
        row.onPress?()
        XCTAssertEqual((model.tabs.pane.activeTab as? ChangesTab)?.controller.selection?.path, "file.txt")
    }
}
