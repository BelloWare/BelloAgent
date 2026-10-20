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
