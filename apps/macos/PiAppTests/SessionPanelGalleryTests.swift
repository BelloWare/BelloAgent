import AppKit
import XCTest
@testable import PiApp

final class SessionPanelGalleryTests: GitPanelTestCase, SerialTestLane {
    @MainActor func testFloatingSessionPanelGallery() async throws {
        guard let path = testEnvironment("PI_SESSION_PANEL_GALLERY") else { throw XCTSkip("Set PI_SESSION_PANEL_GALLERY") }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (key, value) in [("sidebarWidth", 264.0), ("sidePaneFraction", 0.65)] {
            let previous = UserDefaults.standard.object(forKey: key)
            addTeardownBlock { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            UserDefaults.standard.set(value, forKey: key)
        }
        let fixture = try SubagentGalleryFixture(root: output.appendingPathComponent("fixture-" + UUID().uuidString))
        registerWorkspaceFixtureTeardown(fixture.model, root: fixture.root)
        defer { fixture.close() }
        PiKit.Motion.reducedOverride = true
        let model = fixture.model, window = fixture.window
        let project = fixture.root.appendingPathComponent("Orchard")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try seedRepository(project)
        model.workspaces[0].path = project.path
        let projects = model.workspaces, configuration = try await model.vault.load()
        model.configuration = try await model.vault.update(expectedRevision: configuration.revision) { $0.workspaces = projects }
        model.chats.removeAll { $0.id == "child-3" }
        model.subagentSummaries.removeValue(forKey: "child-3")
        model.chats[0].title = "Polish the release experience"
        fixture.parent.runState = .idle; fixture.parent.runStatus = "idle"
        fixture.parent.messages = [
            .init(id: "request", role: "user", text: "Review the release experience. Keep the changes focused and make the workspace feel calm and easy to navigate."),
            .init(id: "response", role: "assistant", text: """
                The review is underway. I’ve split the work into a few focused checks so we can compare findings before making changes.

                ## What we’re checking

                - **Navigation:** keep the main conversation in view while opening files and review notes.
                - **Clarity:** use consistent spacing, readable labels, and quiet status indicators.
                - **Reliability:** preserve drafts and reading position as the workspace changes.

                The notes and delegated checks are available beside this conversation. I’ll bring their findings together here when they’re ready.
                """)
        ]
        fixture.parent.draft = ""
        for (index, status) in [SubagentStatus.running, .completed, .failed].enumerated() {
            let id = "child-\(index)"
            model.subagentSummaries[id]?.status = status
        }
        for (index, title) in ["Review notes", "Release checklist"].enumerated() {
            let id = "saved-side-\(index)"
            let chat = ChatRecord(id: id, workspaceID: "pane-project", title: title, profileID: fixture.records[0].profileID, parentSessionID: fixture.parent.id)
            model.chats.append(chat)
            let display = SessionDisplay(id: id); display.historyState = .ready; display.draftReady = true
            display.runState = index == 0 ? .running : .idle; display.runStateKnown = true
            display.messages = [.init(id: "side-reply", role: "assistant", text: "The navigation and spacing checks are ready. Keep these notes beside the main review while comparing the changes.")]
            var totals = GatewayTotals(); totals.costSamples = 1; totals.costUSD = index == 0 ? 0.025 : 0.012
            display.footer.gateway = totals; model.displays[id] = display
        }
        model.historyWindowLoader = { id, cursor, _, _ in
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string(id), "lineage": .string("root"),
                "messages": .array(cursor == nil ? [.object(["id": .string("side-reply"), "role": .string("assistant"), "text": .string("The navigation checks are complete. Preserve the main draft and keep file previews in the existing pane.\n\nI’m checking the remaining spacing and keyboard details.")])] : []),
                "older": .null, "newer": .null]))
        }
        let root = WorkspaceRootView(model: model); window.contentView = root
        let records = model.chats, summaries = model.subagentSummaries
        var manifest: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            model.chats = records; model.subagentSummaries = summaries; model.sides = [:]
            model.selectedID = fixture.parent.id; model.selected = fixture.parent; model.focusedSessionID = fixture.parent.id
            seedSideCosts(model)
            for tab in model.tabs.allTabs { model.tabs.close(tab) }
            for (width, height, name) in [(1440.0, 900.0, "agents"), (1180, 800, "agents"), (960, 700, "pill")] {
                window.setContentSize(CGSize(width: width, height: height))
                root.refresh(); await settle(window)
                let pane = try XCTUnwrap(root.conversation)
                pane.sessionPanel.select(.agents); await settle(window)
                XCTAssertEqual(!pane.sessionPanel.isHidden, width != 960)
                try capture(root, name: "\(name)-\(Int(width))x\(Int(height))-\(theme)", output: output, manifest: &manifest)
            }
            window.setContentSize(CGSize(width: 1440, height: 900)); root.refresh(); await settle(window)
            let pane = try XCTUnwrap(root.conversation)
            try await eventually("repository discovery") { pane.sessionPanel.availableTabs.contains(.diff) }
            pane.sessionPanel.select(.diff)
            try await eventually("six changes and their counts") {
                pane.sessionPanel.changes?.controller.status.entries.count == 6 && pane.sessionPanel.changes?.controller.changeStats.count == 6
            }
            await settle(window)
            try capture(root, name: "diff-1440x900-\(theme)", output: output, manifest: &manifest)
            let changes = try XCTUnwrap(pane.sessionPanel.changes)
            try git(["config", "status.renames", "false"], in: project)
            await changes.controller.refresh()
            XCTAssertEqual(changes.controller.status.entries.count, 7)
            XCTAssertEqual(changes.controller.changeStats["docs/guide.md"]?.added, 3)
            XCTAssertEqual(changes.controller.changeStats["docs/old-guide.md"]?.removed, 3)
            await settle(window)
            try capture(root, name: "diff-no-renames-1440x900-\(theme)", output: output, manifest: &manifest)
            try git(["config", "--unset", "status.renames"], in: project)
            let samples = project.appendingPathComponent("samples")
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: false)
            try Data((String(repeating: "a\n", count: 4_500) + "\0\n").utf8).write(to: samples.appendingPathComponent("late-nul.txt"))
            try Data([0, 10, 1, 10]).write(to: samples.appendingPathComponent("binary.dat"))
            await changes.controller.refresh()
            XCTAssertEqual(changes.controller.changeStats["samples/late-nul.txt"]?.added, 4_501)
            XCTAssertEqual(changes.controller.changeStats["samples/binary.dat"]?.binary, true)
            await settle(window)
            try capture(root, name: "diff-classification-1440x900-\(theme)", output: output, manifest: &manifest)
            try FileManager.default.removeItem(at: samples)
            await changes.controller.refresh()
            pane.sessionPanel.select(.files)
            let browser = try XCTUnwrap(pane.sessionPanel.files?.browser)
            try await eventually("root listing") { browser.snapshot(project) != nil }
            for relative in ["Sources", "Sources/App", "Sources/UI"] {
                let url = project.appendingPathComponent(relative)
                browser.expand(url)
                try await eventually("expanded " + relative) { browser.snapshot(url) != nil }
            }
            await settle(window)
            try capture(root, name: "files-1440x900-\(theme)", output: output, manifest: &manifest)
            pane.sessionPanel.select(.agents)
            model.chats.removeAll { $0.id != fixture.parent.id }; model.subagentSummaries = [:]
            root.refresh(); await settle(window)
            try capture(root, name: "empty-1440x900-\(theme)", output: output, manifest: &manifest)
            model.chats = records; model.subagentSummaries = summaries
            window.setContentSize(CGSize(width: 1600, height: 900))
            await model.openFamilySide("saved-side-1")
            root.refresh(); await settle(window)
            seedSideCosts(model)
            root.refresh(); await settle(window)
            XCTAssertEqual(model.workspaces.first?.path, project.path)
            XCTAssertTrue(pane.sessionPanel.availableTabs.contains(.diff))
            XCTAssertNotNil(root.rightPane)
            XCTAssertFalse(pane.sessionPanel.isHidden, "The 65% main split fits the card beside a side conversation")
            let side = try XCTUnwrap(ConversationPaneTests.views(SidePaneView.self, in: root).first)
            XCTAssertTrue(ConversationPaneTests.views(SessionFloatingPanel.self, in: side).allSatisfy(\.isHidden))
            XCTAssertNil(model.displays["saved-side-1"]?.newerPage.error)
            XCTAssertNil(model.displays["saved-side-1"]?.olderPage.error)
            try capture(root, name: "side-open-1600x900-\(theme)", output: output, manifest: &manifest)
        }
        try (manifest.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor private func seedSideCosts(_ model: WorkspaceModel) {
        for (index, cost) in [0.025, 0.012].enumerated() {
            guard let display = model.displays["saved-side-\(index)"] else { continue }
            model.observeCost(["cost": .object(["spentUSD": .number(cost), "reportedRequests": .number(1), "limitUSD": .null])], view: display)
        }
    }

    private func seedRepository(_ root: URL) throws {
        try start(root)
        let files = [
            ".gitignore": ".build/\n", "README.md": "# Orchard\n\nA generated workspace fixture.\n",
            "Sources/App/Session.swift": "struct Session {\n    var title = \"Review\"\n}\n",
            "Sources/UI/Theme.swift": "let spacing = 12\nlet radius = 10\n",
            "Tests/SessionTests.swift": "func testSession() {\n    checkTitle()\n}\n",
            "docs/old-guide.md": "# Workspace guide\n\nOpen files beside your conversation.\n",
            "docs/obsolete.md": "An old release note.\n"
        ]
        for (path, content) in files { try write(content, path: path, root: root) }
        try git(["add", "."], in: root); try git(["commit", "-qm", "Generated gallery fixture"], in: root)
        try write("struct Session {\n    var title = \"Review\"\n    var isPinned = true\n}\n", path: "Sources/App/Session.swift", root: root)
        try write("let spacing = 16\nlet radius = 14\nlet shadow = 12\n", path: "Sources/UI/Theme.swift", root: root)
        try write("func testSession() {\n    checkTitle()\n    checkNavigation()\n    checkKeyboardFocus()\n}\n", path: "Tests/SessionTests.swift", root: root)
        try write("struct Panel {\n    let tabs = [\"Agents\", \"Diff\", \"Files\"]\n}\n", path: "Sources/UI/Panel.swift", root: root)
        try git(["add", "Sources/UI/Panel.swift"], in: root)
        try git(["mv", "docs/old-guide.md", "docs/guide.md"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("docs/obsolete.md"))
    }
    private func write(_ text: String, path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    @MainActor private func settle(_ window: NSWindow) async {
        for _ in 0..<18 {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield(); try? await Task.sleep(for: .milliseconds(15))
        }
    }
    @MainActor private func capture(_ view: NSView, name: String, output: URL, manifest: inout [String]) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let filename = name + ".png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
        manifest.append(filename)
        print("PANEL SCREENSHOT \(filename)")
    }
}
