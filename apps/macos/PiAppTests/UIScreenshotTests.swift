import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// Opt-in screenshot gallery for the native shell. It reuses the synthetic
// loopback gateway from the interactive acceptance harness, sends real
// fixture turns through Responses, and captures this process's own windows in
// light and dark appearance. Production PiApp contains none of this.
final class UIScreenshotTests: XCTestCase {
    @MainActor func testRenderRedesignGallery() async throws {
        guard let path = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else {
            throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT to render the synthetic screenshot gallery.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let gallery = folder.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8).write(to: folder.appendingPathComponent("README.md"))
        // A throwaway repository gives the Changes sheet a branch, history and a working-tree change to show.
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = folder; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"]); try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"])
        try Data("func charge(_ order: Order) async throws -> Receipt {\n    for attempt in 1...3 {\n        if let receipt = try? await gateway.charge(order) { return receipt }\n    }\n    throw PaymentError.exhausted\n}\n".utf8).write(to: folder.appendingPathComponent("PaymentClient.swift"))
        try git(["add", "."]); try git(["commit", "-q", "-m", "Add the payment client and fixture notes"])
        try Data("func charge(_ order: Order) async throws -> Receipt {\n    var delay: Duration = .milliseconds(200)\n    for attempt in 1...5 {\n        if let receipt = try? await gateway.charge(order) { return receipt }\n        try await Task.sleep(for: delay); delay *= 2\n    }\n    throw PaymentError.exhausted\n}\n".utf8).write(to: folder.appendingPathComponent("PaymentClient.swift"))
        try git(["commit", "-q", "-am", "Back off between attempts"])
        try Data("func charge(_ order: Order) async throws -> Receipt {\n    var delay: Duration = .milliseconds(200)\n    var lastError: Error?\n    for attempt in 1...5 {\n        do { return try await gateway.charge(order) } catch { lastError = error }\n        try await Task.sleep(for: delay); delay *= 2\n    }\n    throw lastError ?? PaymentError.exhausted\n}\n".utf8).write(to: folder.appendingPathComponent("PaymentClient.swift"))
        try Data("# Retry notes\n".utf8).write(to: folder.appendingPathComponent("NOTES.md"))
        let skill = folder.appendingPathComponent(".agents/skills/release-checklist")
        try FileManager.default.createDirectory(at: skill.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try Data("---\nname: release-checklist\ndescription: Walk through the release preflight before tagging\n---\nCheck signing, notarization and the appcast before publishing.\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: skill.appendingPathComponent("agents/openai.yaml"))
        // A second skill, in Codex's own folder; explicit only, so no other
        // scene's instructions change for it.
        let review = folder.appendingPathComponent("codex/skills/review-diff")
        try FileManager.default.createDirectory(at: review.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("---\nname: review-diff\ndescription: Review the pending diff for correctness, risky changes and missing tests\n---\nRead the diff before answering.\n".utf8).write(to: review.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: review.appendingPathComponent("agents/openai.yaml"))
        try Data("Synthetic native screenshot instructions: fixture data only.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("fixtures/native/ui-gateway.py").path]
        fixture.currentDirectoryURL = folder; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"]), base = "http://127.0.0.1:\(port)"

        let mcpFixturePath = repository.appendingPathComponent("fixtures/native/mcp-server.py").path
        let workspace = WorkspaceRecord(id: "native-ui-gallery", path: folder.path, trusted: true)
        let referenceFolder = folder.appendingPathComponent("Design Reference", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
        let referenceProject = WorkspaceRecord(id: "gallery-reference", path: referenceFolder.path, trusted: true)
        let connections = ["ui-fixture", "fixture-fast"].map { alias -> VaultProfile in
            var profile = ProfileRecord(); profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = alias; profile.catalogUrl = base + "/catalog"
            profile.contextWindow = alias == "fixture-fast" ? 128_000 : 2_000_000; profile.maxOutputTokens = alias == "fixture-fast" ? 16_000 : 300_000
            profile.modelOutputLimit = alias == "fixture-fast" ? 16_000 : 300_000   // the catalog ceiling is what requests carry
            profile.name = alias == "fixture-fast" ? "Team fast · Responses" : "Team router · Responses"
            profile.miniModelId = "fixture-fast"  // titles and suggestions require a mini model
            profile.advancedJSON = "{\"routing\":{\"replayPolicy\":\"portable\",\"reference\":\"Synthetic UI gateway accounting contract v1\",\"cacheHeader\":\"x-fixture-cache\"}}"
            return VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")
        }
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace, referenceProject]; $0.profiles = connections
            $0.resources[workspace.id] = .object(["codexHome": .string(folder.appendingPathComponent("codex").path)])
            $0.mcp[workspace.id] = .object(["servers": .object(["fixture": .object([
                "transport": .string("stdio"), "command": .string("/usr/bin/python3"),
                "args": .array([.string(mcpFixturePath)])
            ])])])
            $0.automaticUpdateChecks = false
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        defer { model.shutdown() }
        await model.restore()
        XCTAssertEqual(model.configuration.capture.defaultMode, "persist")
        XCTAssertEqual(model.configuration.capture.retentionDays, 30)
        model.profileChoice = connections[0].profile.id; model.selectedWorkspaceID = workspace.id
        // Exercise the native onboarding boundary with the packaged helper and
        // strict gateway, before creating any chat or loading workspace content.
        try await model.verifyOnboardingConnection(connections[0].profile)
        XCTAssertTrue(model.chats.isEmpty, "The connection probe must not create a conversation")
        XCTAssertTrue(model.hosts.isEmpty, "The scoped probe helper must finish independently")
        let plan: [(title: String, profile: Int, toolMode: String)] = [
            ("Harden the payment retry loop", 0, "editing"),
            ("Explain cache accounting", 1, "editing"),
            ("Design notes for the queue", 0, "read-only")
        ]
        for entry in plan where !model.chats.contains(where: { $0.title == entry.title }) {
            let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: entry.title, path: nil, profileID: connections[entry.profile].profile.id, toolMode: entry.toolMode)
            model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        }
        let main = try XCTUnwrap(model.chats.first { $0.title == plan[0].title })
        let second = try XCTUnwrap(model.chats.first { $0.title == plan[1].title })
        await model.select(main.id)

        for window in NSApp.windows { window.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bello Agent"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.styleMask.insert(.fullSizeContentView)
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); NSApp.appearance = nil }
        try await settle(1.5)

        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let session = try XCTUnwrap(model.displays[main.id])
        session.draft = "Please read fixture README.md first, then explain what the retry loop in PaymentClient does today."
        model.send(sessionID: main.id)
        try await waitIdle(session, model: model, minimumMessages: 4)
        // Keep the real fixture-backed workspace open for pointer/keyboard
        // acceptance checks. Captures are window-server images of this app,
        // including its real popovers, never re-created screenshot layouts.
        if testEnvironment("PI_APP_UI_INTERACTIVE") == "1" {
            NSApp.appearance = NSAppearance(named: .aqua)
            try Data("ready".utf8).write(to: folder.appendingPathComponent("ready"))
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("done").path) {
                let request = folder.appendingPathComponent("capture.txt")
                if let name = try? String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    try capture(window, to: gallery.appendingPathComponent(name + ".png"), includingOwnedPanels: true)
                    try FileManager.default.removeItem(at: request)
                }
                try await settle(0.25)
            }
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }
        if testEnvironment("PI_APP_UI_GALLERY_SKILLS_ONLY") == "1" {
            try await captureSkillScenes(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }
        // Only the cost-limit scenes, the Session Inspector's Overview of the
        // chat under a limit among them.
        // Only the versions and fork scenes, and the compaction's requests.
        if testEnvironment("PI_APP_UI_GALLERY_VERSIONS_ONLY") == "1" {
            if testEnvironment("PI_APP_UI_GALLERY_COMPACTION_ONLY") != "1" {
                try await captureVersionAndForkScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                                      workspaceID: workspace.id, profileID: connections[0].profile.id)
            }
            try await captureCompactionRequestScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                                     workspaceID: workspace.id, profileID: connections[0].profile.id)
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }
        // Only a message as typed and a reply read as its source.
        if testEnvironment("PI_APP_UI_GALLERY_LITERAL_ONLY") == "1" {
            try await captureLiteralTextScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                               workspaceID: workspace.id, profileID: connections[0].profile.id)
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }
        if testEnvironment("PI_APP_UI_GALLERY_COST_ONLY") == "1" {
            try await captureCostLimitScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                             workspaceID: workspace.id, profileID: connections[0].profile.id)
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }
        // The first turn ran the read tool: capture its grouped activity before more turns scroll it away.
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.2)
            try capture(window, to: gallery.appendingPathComponent("01a-activity-\(name).png"))
        }
        session.draft = """
        Here is the loop I want to harden:

        ```swift
        func charge(_ order: Order) async throws -> Receipt {
            for attempt in 1...3 {
                if let receipt = try? await gateway.charge(order) { return receipt }
            }
            throw PaymentError.exhausted
        }
        ```

        Please:
        1. add **exponential backoff with jitter**
        2. cap attempts at `5` and surface the last error
        3. keep the cancellation path intact
        """
        model.send(sessionID: main.id)
        try await waitIdle(session, model: model, minimumMessages: 6)

        await model.select(second.id); try await settle(0.6)
        let other = try XCTUnwrap(model.displays[second.id])
        other.draft = "owner billing sample: Explain the reported token and reasoning-cost breakdown."
        model.send(sessionID: second.id)
        try await waitIdle(other, model: model, minimumMessages: 2)
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.4)
            try capture(window, to: gallery.appendingPathComponent("01c-token-shares-\(name).png"))
        }
        await model.select(main.id); try await settle(0.8)
        session.draft = "Now add a unit test for the jitter bounds and show me the diff."

        if testEnvironment("PI_APP_UI_GALLERY_REPORT_ONLY") == "1" {
            model.openReport()
            try await settle(1.2)
            await model.report.refresh()
            for (name, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                try await settle(0.4)
                try capture(window, to: gallery.appendingPathComponent("analytics-routing-\(name).png"))
            }
            XCTAssertNil(model.error, model.error ?? "")
            XCTAssertNil(model.report.failure)
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }

        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.5)
            try capture(window, to: gallery.appendingPathComponent("01-main-\(name).png"))
        }
        // The terminal panel: a live login shell in the app's own emulator under the conversation.
        model.toggleTerminal(); try await settle(2.0)
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("01b-terminal-\(name).png"))
        }
        model.toggleTerminal(); try await settle(0.5)
        // A second route in the same chat, so Session info and the report split speed and latency per model.
        await model.setModel("fixture-fast", for: main.id); try await settle(0.5)
        session.draft = "Summarize the plan in one line."
        model.send(sessionID: main.id)
        try await waitIdle(session, model: model, minimumMessages: 8)
        await model.setModel(nil, for: main.id); try await settle(0.5)
        session.draft = "Now add a unit test for the jitter bounds and show me the diff."

        // A quick gallery for transcript/metrics changes; the full shell
        // gallery remains available for changes to the other pages.
        if testEnvironment("PI_APP_UI_GALLERY_CORE_ONLY") == "1" {
            try await captureInspectorScenes(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
            try await captureSkillScenes(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
            session.draft = "slow: walk through the retry budget one step at a time."
            model.send(sessionID: main.id)
            try await settle(2.0)
            for (name, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance); try await settle(0.4)
                try capture(window, to: gallery.appendingPathComponent("01d-ongoing-\(name).png"))
            }
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }
        // The Session Inspector's scenes, and the chat scenes whose turn
        // cards and live bar open it (12, 13).
        if testEnvironment("PI_APP_UI_GALLERY_INSPECTOR_ONLY") == "1" {
            try await captureInspectorScenes(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
            try await renderReviewScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                         mainID: main.id, secondID: second.id, workspaceID: workspace.id)
            XCTAssertNil(model.error, model.error ?? "")
            for host in model.hosts.values { try await host.shutdownAndWait() }
            try await model.traces.close()
            return
        }

        model.openSide(parentID: main.id, question: "Is the retry budget shared with queued follow-ups, or per turn?")
        try await settle(1.0)
        let sideID = try XCTUnwrap(model.sides[main.id]?.id, "side did not open: \(String(describing: model.error)) / \(String(describing: model.displays[main.id]?.notice))")
        let side = try XCTUnwrap(model.displays[sideID])
        try await waitIdle(side, model: model, minimumMessages: 2)
        try await settle(0.8)

        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.5)
            try capture(window, to: gallery.appendingPathComponent("02-side-\(name).png"))
            model.openReport(); try await settle(2.2)
            try capture(window, to: gallery.appendingPathComponent("03-report-\(name).png"))
            model.report.advancedOpen = true; model.report.detailsOpen = true; try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("03b-report-expanded-\(name).png"))
            model.report.advancedOpen = false; model.report.detailsOpen = false
            model.report.grouping = "sessions"; try await settle(1.0)
            if let first = model.report.sessions?.sessions.first { model.report.toggleSession(first.sessionID); try await settle(1.2) }
            try capture(window, to: gallery.appendingPathComponent("03c-report-sessions-\(name).png"))
            model.report.grouping = "models"; try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("03e-report-models-\(name).png"))
            model.report.grouping = "requests"; model.report.expandedSessions = []
            window.setContentSize(NSSize(width: 920, height: 740)); window.center(); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("03c-report-compact-\(name).png"))
            window.setContentSize(NSSize(width: 920, height: 1100)); window.center(); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("03c-report-compact-controls-\(name).png"))
            window.setContentSize(NSSize(width: 920, height: 740)); window.center(); try await settle(0.3)
            model.report.advancedOpen = true; model.report.setPreset(.custom); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("03d-report-compact-filters-\(name).png"))
            model.report.advancedOpen = false; model.report.setPreset(.day)
            window.setContentSize(NSSize(width: 1440, height: 900)); window.center(); try await settle(0.8)
            model.closeReport(); try await settle(0.8)
            try await sheet(window, name: "05-profiles-\(name)", into: gallery, open: { model.showProfiles = true }, close: { model.showProfiles = false })
            try await sheet(window, name: "06-resources-\(name)", into: gallery, open: { model.inspectResources(main.id) }, close: { model.showResources = false })
            try await sheet(window, name: "07-search-\(name)", into: gallery, open: { model.inspectConversation(main.id) }, close: { model.showConversationContent = false })
            try await sheet(window, name: "08-workspaces-\(name)", into: gallery, open: { model.showWorkspaceManager = true }, close: { model.showWorkspaceManager = false })
            // The Changes sheet against a small repository inside the project folder.
            try await sheet(window, name: "10-changes-\(name)", into: gallery, open: { model.showChanges(in: workspace.id) }, close: { model.showGit = false })
        }
        // The Session Inspector of the main chat, with both routes it used.
        try await captureInspectorScenes(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
        try await renderReviewScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                     mainID: main.id, secondID: second.id, workspaceID: workspace.id)
        try await captureCostLimitScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                         workspaceID: workspace.id, profileID: connections[0].profile.id)
        try await captureSkillScenes(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
        try await captureVersionAndForkScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                              workspaceID: workspace.id, profileID: connections[0].profile.id)
        try await captureCompactionRequestScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                                 workspaceID: workspace.id, profileID: connections[0].profile.id)
        try await captureLiteralTextScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                           workspaceID: workspace.id, profileID: connections[0].profile.id)
        // First-launch onboarding, rendered from an empty vault in its own window.
        let freshVault = ConfigurationVault(storage: MemoryVaultStorage())
        let fresh = WorkspaceModel(stateRoot: folder.appendingPathComponent("onboarding-state"), vault: freshVault)
        await fresh.restore()
        let onboarding = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        onboarding.titleVisibility = .hidden; onboarding.titlebarAppearsTransparent = true; onboarding.styleMask.insert(.fullSizeContentView)
        onboarding.contentView = NSHostingView(rootView: WorkspaceView(model: fresh))
        onboarding.center(); onboarding.makeKeyAndOrderFront(nil)
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.2)
            try capture(onboarding, to: gallery.appendingPathComponent("00-onboarding-\(name).png"))
        }
        onboarding.orderOut(nil); fresh.shutdown()
        XCTAssertNil(model.error, model.error ?? "")
        for host in model.hosts.values { try await host.shutdownAndWait() }
        try await model.traces.close()
    }

    /// Scenes the gallery above never reached, added for the 0.1.60 UX review:
    /// a long chat with its turns folded and unfolded, a running turn with the
    /// live bar and a queued follow-up, the sidebar with a topic, marked rows
    /// and its narrowest width, the error strip, and the window at its
    /// narrowest and at a wide size. Each is captured in light and dark.
    @MainActor private func renderReviewScenes(model: WorkspaceModel, window: NSWindow, gallery: URL,
                                               appearances: [(String, NSAppearance.Name)],
                                               mainID: String, secondID: String, workspaceID: String) async throws {
        func pair(_ name: String, hold: Double = 1.0) async throws {
            for (appearanceName, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                try await settle(hold)
                try capture(window, to: gallery.appendingPathComponent("\(name)-\(appearanceName).png"))
            }
        }
        // The side pane opened earlier keeps half the window; the chat scenes want all of it.
        if let side = model.sides[mainID] { model.closeSide(side.id); try await settle(1.2) }
        await model.select(mainID); try await settle(0.8)
        let session = try XCTUnwrap(model.displays[mainID])

        // 12 · A long chat: every turn's work open, then every turn folded.
        try await pair("12-turns-open")
        let blocks = TranscriptActivity.blocks(of: session.presentedMessages).compactMap { item -> String? in
            if case .block(let block) = item { return block.key }
            return nil
        }
        for key in blocks { session.disclosure.setOpen(false, .work(key)) }
        session.publishTranscript(); try await settle(0.8)
        try await pair("12b-turns-folded")
        for key in blocks { session.disclosure.setOpen(true, .work(key)) }
        session.publishTranscript(); try await settle(0.5)

        // 12c · Away from the bottom: the Back to bottom pill floating over
        // the end of the conversation, above the composer.
        // The gesture is announced the way AppKit announces one, so the pane
        // lets go of the line it was holding: a clip moved behind its back is
        // put straight back, which is exactly what it is there for.
        if let scroll = descendants(TranscriptNativeScrollView.self, in: window.contentView ?? NSView()).first {
            let clip = scroll.contentView
            func readerScrolls(to y: CGFloat) {
                scroll.readerWillNavigate(upward: y < clip.bounds.minY)
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
                scroll.reflectScrolledClipView(clip)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            }
            readerScrolls(to: max(0, clip.bounds.minY - 400))
            try await settle(1.0)
            try await pair("12c-back-to-bottom")
            readerScrolls(to: max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height))
            try await settle(0.6)
        }

        // 13 · A running turn: the live bar, and a follow-up waiting behind it.
        session.draft = "slow: walk through the retry budget one step at a time."
        model.send(sessionID: mainID)
        try await settle(2.0)
        // 13a · The compact working report at the beginning of a run.
        try await pair("13a-working-indicator", hold: 0.3)
        // 11g · The same run in the Session Inspector: the request still streaming.
        try await captureRunningInspector(model: model, session: session, window: window, gallery: gallery, appearances: appearances)
        // 13b · The same report later in the run. The live clock updates
        // independently of the helper's most recent snapshot.
        func liveElapsed() -> Double {
            guard let turn = page(of: window)?.liveTurn else { return 0 }
            return TurnInfoPresentation.live(turn, at: Date()).elapsedMs ?? 0
        }
        let clockDeadline = Date().addingTimeInterval(60)
        while session.busy, liveElapsed() < 15_400, Date() < clockDeadline {
            try await settle(0.25)
        }
        if session.busy, liveElapsed() >= 15_000 {
            try await pair("13b-working-indicator-clock", hold: 0.3)
        } else {
            XCTFail("The slow fixture turn ended after \(Int(liveElapsed())) ms, before the later-running capture; 13b has nothing to show.")
        }
        session.draft = "Then summarise the change in one line for the commit message."
        model.send(sessionID: mainID)
        try await settle(1.5)
        try await pair("13-running-with-queue", hold: 0.8)
        model.stop(sessionID: mainID)
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, session.hasWork || !session.queue.isEmpty { try await settle(0.3) }
        try await settle(1.0)

        // 14 · The sidebar: a topic holding a chat, two rows marked, and the narrowest width.
        let topic = try? await model.createTopic(in: workspaceID, title: "Payments")
        if let topic { try? await model.moveSessions([secondID], in: workspaceID, toTopic: topic.id) }
        try await settle(0.8)
        model.toggleSessionMark(mainID); model.toggleSessionMark(secondID)
        try await settle(0.6)
        try await pair("14-sidebar-topic-marks")
        UserDefaults.standard.set(Double(WindowChrome.minimumSidebarWidth), forKey: "sidebarWidth")
        try await settle(1.0)
        try await pair("14b-sidebar-narrow")
        model.clearSessionMarks()
        UserDefaults.standard.set(Double(WindowChrome.sidebarWidth), forKey: "sidebarWidth")
        try await settle(0.8)

        // 15 · The error strip over a chat: a gateway failure with a long body.
        model.error = "The gateway refused the request: 400 invalid_request_error — the model \"fixture-fast\" does not accept a 300000-token output limit on this route. Reduce the output budget in Settings, or choose a model whose catalog ceiling covers it, then send again."
        try await pair("15-error-strip")
        model.error = nil; try await settle(0.5)

        // 16 · The window at its smallest, and wide.
        window.setContentSize(NSSize(width: 920, height: 620)); window.center(); try await settle(1.0)
        try await pair("16-window-narrow")
        window.setContentSize(NSSize(width: 1760, height: 1000)); window.center(); try await settle(1.0)
        try await pair("16b-window-wide")
        window.setContentSize(NSSize(width: 1440, height: 900)); window.center(); try await settle(0.8)
        XCTAssertNil(model.error, model.error ?? "")
    }

    /// 17 · Skills rendered inline: two selected skills leading the
    /// composer's text as tokens, the sent message's bubble leading with its
    /// pills, a pill's hover card, and a pill's popover.
    @MainActor private func captureSkillScenes(model: WorkspaceModel, session: SessionDisplay, window: NSWindow, gallery: URL,
                                               appearances: [(String, NSAppearance.Name)]) async throws {
        await model.select(session.id); try await settle(0.6)
        // An earlier scene stops a run with a follow-up queued, which leaves the
        // follow-up paused for the reader to decide on. Remove it as the reader
        // would from the queue panel, so this scene's message is not refused
        // behind it.
        for item in QueuedMessage.from(session.queue) {
            model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: session.id)
        }
        let cleared = Date().addingTimeInterval(20)
        while Date() < cleared, !session.queue.isEmpty || session.hasWork { try await settle(0.3) }
        await model.loadSkillCatalog(refresh: true, sessionID: session.id)
        let catalog = session.skillCatalog.entries.map(\.skill)
        let checklist = try XCTUnwrap(catalog.first { $0.name == "release-checklist" }, "The project skill was discovered: \(session.skillCatalog.notice)")
        let review = try XCTUnwrap(catalog.first { $0.name == "review-diff" }, "The Codex skill was discovered")
        session.draft = ""
        XCTAssertTrue(model.addSkill(checklist, view: session)); XCTAssertTrue(model.addSkill(review, view: session))
        let index = try XCTUnwrap(session.skills.firstIndex { $0.id == checklist.id })
        session.skills[index].arguments = "focus on notarization"
        session.draft = "Tag 0.1.86 once both pass, then write the release notes."
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("17-skills-composer-\(name).png"))
        }
        let sent = session.messages.count
        model.send(sessionID: session.id)
        try await waitIdle(session, model: model, minimumMessages: sent + 2)
        let user = try XCTUnwrap(session.messages.last { $0.role == "user" })
        XCTAssertEqual(user.skills?.map(\.name), ["release-checklist", "review-diff"], "The sent message carries its skills")
        XCTAssertTrue(session.skills.isEmpty, "The send took the tokens with it")
        // The fixture echoes what the model received — the skills' expansions
        // ahead of the text — so the reply is long: bring the sent message's
        // bubble into view, as a reader scrolling up to it would.
        try await settle(0.6)
        try scrollConversation(in: window, toRow: user.id)
        try await settle(0.8)
        func pills() -> [SkillPillButton] {
            descendants(SkillPillButton.self, in: window.contentView ?? NSView()).filter { !($0 is ComposerSkillToken) }
        }
        XCTAssertEqual(pills().count, 2, "The sent message's bubble shows its two pills")
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("17b-skills-message-\(name).png"))
        }
        let popovers = SkillPopovers.shared
        popovers.card.delay = .milliseconds(20)
        defer { popovers.card.delay = PiHoverCardPresenter.delay }
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.5)
            let pill = try XCTUnwrap(pills().first, "The sent message shows its pills")
            pill.setHovering(true)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !popovers.card.isShown { try await settle(0.05) }
            try await settle(0.4)
            XCTAssertTrue(popovers.card.isShown, "The pill's card appeared")
            try captureWithPopovers(window, to: gallery.appendingPathComponent("17c-skills-card-\(name).png"))
            pill.setHovering(false)
            pill.performClick(nil)
            let opened = Date().addingTimeInterval(5)
            while Date() < opened, popovers.popover.popover?.isShown != true { try await settle(0.05) }
            XCTAssertTrue(popovers.popover.isShown, "The pill's popover opened")
            try await settle(1.0)
            try captureWithPopovers(window, to: gallery.appendingPathComponent("17d-skills-popover-\(name).png"))
            popovers.close(); try await settle(0.4)
        }
        // 17e · The slash list, typed as a reader would: "/" at the start of
        // the draft, then "re" narrows the commands and skills it offers.
        let editor = try XCTUnwrap(descendants(ComposerTextView.self, in: window.contentView ?? NSView()).first, "The composer's editor is on screen")
        window.makeFirstResponder(editor)
        session.directCommand = true
        editor.insertText("/re", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        let listed = Date().addingTimeInterval(5)
        while Date() < listed, !session.completionVisible { try await settle(0.05) }
        XCTAssertTrue(session.completionVisible, "The slash list opened")
        XCTAssertFalse(model.completions(session).isEmpty, "The slash list offers the catalog's matches")
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.8)
            try capture(window, to: gallery.appendingPathComponent("17e-skills-slash-\(name).png"))
        }
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        session.directCommand = false; try await settle(0.3)
        XCTAssertFalse(session.completionVisible, "Clearing the draft closed the slash list")
    }

    /// 19 · Versions and forks. A question edited once shows `‹ 1 / 2 ›` on
    /// its earlier version, under the banner, read-only (19a); "Fork from
    /// here" on the latest reply opens "‹title› · fork", nested under the chat
    /// in the sidebar, its transcript ending at that reply (19b).
    @MainActor private func captureVersionAndForkScenes(model: WorkspaceModel, window: NSWindow, gallery: URL,
                                                        appearances: [(String, NSAppearance.Name)], workspaceID: String, profileID: String) async throws {
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "Retry budget", path: nil, profileID: profileID, toolMode: "editing")
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id); try await settle(0.8)
        let session = try XCTUnwrap(model.displays[chat.id])
        session.draft = "How many **retries** should `PaymentClient` allow?"
        model.send(sessionID: chat.id)
        try await waitIdle(session, model: model, minimumMessages: 2)
        let original = try XCTUnwrap(session.messages.last { $0.role == "user" }?.id)
        model.editMessage(original, sessionID: chat.id)
        try await until("the edit to load") { !session.editPreparing && session.editingMessageID == original }
        session.draft = "How many **retries** should `PaymentClient` allow for queued follow-ups?"
        model.sendEdit(sessionID: chat.id)
        try await until("the edited question to settle", seconds: 90) {
            !session.editSubmitting && !session.hasWork && !session.loading && session.editingMessageID == nil
                && session.messages.contains { $0.versions?.index == 2 } && session.messages.last?.role == "assistant"
        }
        let edited = try XCTUnwrap(session.messages.last { $0.versions?.usable == true })
        model.showVersion(sessionID: chat.id, messageID: edited.id, step: -1)
        try await until("version 1 to be read") { session.versionView?.loading == false && !(session.versionView?.rows.isEmpty ?? true) }
        XCTAssertNil(session.versionView?.failure, session.versionView?.failure ?? "")
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("19a-version-earlier-\(name).png"))
        }
        model.latestVersion(sessionID: chat.id); try await settle(0.6)
        let reply = try XCTUnwrap(session.messages.last { $0.role == "assistant" && $0.kind == nil }?.id)
        model.forkFromReply(sessionID: chat.id, messageID: reply)
        try await until("the fork to open", seconds: 60) { model.selectedID != chat.id && model.chats.contains { $0.parentSessionID == chat.id } }
        let fork = try XCTUnwrap(model.chats.first { $0.parentSessionID == chat.id })
        XCTAssertEqual(fork.title, "Retry budget · fork")
        let forked = try XCTUnwrap(model.displays[fork.id])
        try await until("the fork's transcript") { forked.historyState != .loading && forked.messages.last?.id == reply }
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("19b-fork-from-here-\(name).png"))
        }
    }

    /// 21 · A message exactly as it was typed: Markdown's characters, indented
    /// lines and a blank line read literally in the bubble, while the reply
    /// that echoes them renders them. 21b · That reply switched to its source,
    /// one monospaced text in the code panel.
    @MainActor private func captureLiteralTextScenes(model: WorkspaceModel, window: NSWindow, gallery: URL,
                                                     appearances: [(String, NSAppearance.Name)], workspaceID: String, profileID: String) async throws {
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "Keep it literal", path: nil, profileID: profileID, toolMode: "editing")
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id); try await settle(0.8)
        let session = try XCTUnwrap(model.displays[chat.id])
        session.draft = """
        Keep these exactly as I typed them:
        **not bold**, `not code`, _not italic_
        # not a heading
        - not a list item
            indented four spaces
        [not a link](https://example.com)

        after a blank line
        """
        model.send(sessionID: chat.id)
        try await waitIdle(session, model: model, minimumMessages: 2)
        let typed = try XCTUnwrap(session.messages.last { $0.role == "user" })
        XCTAssertTrue(typed.text.contains("**not bold**"), "the message keeps its characters")
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("21-literal-message-\(name).png"))
        }
        // View raw on the reply, as its pill, its menu and its accessibility action do.
        let reply = try XCTUnwrap(session.messages.last { $0.role == "assistant" && $0.kind == nil }?.id)
        session.disclosure.setOpen(true, .source(reply))
        try await settle(0.6)
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("21b-reply-raw-\(name).png"))
        }
        session.disclosure.setOpen(false, .source(reply)); try await settle(0.6)
        // 21c · A long paste and its reply's source: both long enough to be
        // TextKit's rather than SwiftUI's, where the paste ends and the source begins.
        let steps = (1...48).map { "- [ ] **step \($0)** run `swift test --filter Retry\($0)` # then read the log" }
        session.draft = "A long paste, exactly as typed:\n" + steps.joined(separator: "\n")
        model.send(sessionID: chat.id)
        try await waitIdle(session, model: model, minimumMessages: 4)
        let long = try XCTUnwrap(session.messages.last { $0.role == "assistant" && $0.kind == nil }?.id)
        session.disclosure.setOpen(true, .source(long))
        try await settle(0.6)
        let scroll = try XCTUnwrap(descendants(TranscriptNativeScrollView.self, in: window.contentView ?? NSView()).first)
        let row = try XCTUnwrap(descendants(TranscriptRowContainer.self, in: scroll).first { ReplySource.replyID(of: $0.contentItem) == long })
        let clip = scroll.contentView
        let y = max(0, row.frame.minY - clip.bounds.height * 0.45)
        scroll.readerWillNavigate(upward: y < clip.bounds.minY)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.0)
            try capture(window, to: gallery.appendingPathComponent("21c-long-paste-source-\(name).png"))
        }
        session.disclosure.setOpen(false, .source(long)); try await settle(0.6)
    }

    /// 20 · A split-turn compaction in the Session Inspector: one Compaction
    /// row holding its one summary request, named "continuation checkpoint",
    /// and its page with the appended instruction identified on the
    /// Conversation tab.
    @MainActor private func captureCompactionRequestScenes(model: WorkspaceModel, window: NSWindow, gallery: URL,
                                                           appearances: [(String, NSAppearance.Name)], workspaceID: String, profileID: String) async throws {
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "Summarize the retry work", path: nil, profileID: profileID, toolMode: "editing")
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id); try await settle(0.6)
        let session = try XCTUnwrap(model.displays[chat.id])
        session.draft = "Which retries does `PaymentClient` make today?"
        model.send(sessionID: chat.id)
        try await waitIdle(session, model: model, minimumMessages: 2)
        // A turn larger than the recent tail a compaction keeps: compacting
        // splits it, so the compaction's one request asks for the history and
        // the start of the turn.
        session.draft = "bulk 120"
        model.send(sessionID: chat.id)
        try await waitIdle(session, model: model, minimumMessages: 4)
        model.action("context.compact", sessionID: chat.id)
        // The scene is the request log, so the compaction is followed there.
        let controller = try openInspector(model, session, at: .latestRequest)
        defer { controller.close(); window.makeKeyAndOrderFront(nil) }
        let inspector = controller.inspector, panel = try XCTUnwrap(controller.window)
        try await until("the compaction's request, settled", seconds: 90) {
            !session.hasWork && !session.loading && inspector.indexLoaded && inspector.index.turns.contains {
                $0.entries.contains { if case .compaction(let group) = $0 { group.requests.count == 1 && !group.requests.contains(where: \.running) } else { false } }
            }
        }
        let group = try XCTUnwrap(inspector.index.turns.flatMap(\.entries).compactMap { entry -> InspectorCompaction? in
            if case .compaction(let group) = entry, group.requests.count == 1 { return group } else { return nil }
        }.last)
        inspector.select(.request(group.requests[0].id))
        try await until("the summary request named", seconds: 30) {
            inspector.summaryLabel(group.requests[0].id) != nil && inspector.request.conversation.value?.summary != nil
        }
        XCTAssertEqual(inspector.summaryLabel(group.requests[0].id), "continuation checkpoint")
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(1.0)
            try capture(panel, to: gallery.appendingPathComponent("20-compaction-requests-\(name).png"))
        }
    }

    /// 18 · A chat's cost limit: the notice where a run stopped at it, the
    /// editor Raise limit… opens over it, and the notice once the limit is
    /// above the spend. The chat has its own limit of $0.001; the fixture's
    /// read round costs $0.00125, so the request after it never goes.
    @MainActor private func captureCostLimitScenes(model: WorkspaceModel, window: NSWindow, gallery: URL,
                                                   appearances: [(String, NSAppearance.Name)], workspaceID: String, profileID: String) async throws {
        func pair(_ name: String, hold: Double = 0.8, popovers: Bool = false, before: () async throws -> Void = {}) async throws {
            for (appearanceName, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                try await before()
                try await settle(hold)
                let file = gallery.appendingPathComponent("\(name)-\(appearanceName).png")
                if popovers { try captureWithPopovers(window, to: file) } else { try capture(window, to: file) }
            }
        }
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "Watch the retry budget", path: nil, profileID: profileID, toolMode: "editing")
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id); try await settle(0.8)
        let session = try XCTUnwrap(model.displays[chat.id])
        try await model.setCostLimit(.usd(0.001), for: chat.id)
        session.draft = "Please read fixture README.md, then summarise the retry budget it describes."
        model.send(sessionID: chat.id)
        let stopped = Date().addingTimeInterval(90)
        while Date() < stopped, !(session.failureCode == SessionDisplay.costLimitCode && !session.hasWork) { try await settle(0.25) }
        XCTAssertEqual(session.failureCode, SessionDisplay.costLimitCode, "The run stopped at the chat's cost limit: \(session.failureMessage ?? session.notice)")
        XCTAssertEqual(session.failureMessage, "This chat reached its $0.001 cost limit ($0.00125 spent). Raise the limit to continue.")
        try await settle(1.0)
        try await pair("18-cost-limit-notice")
        // 18a · The chat's Session Inspector, which the usage pill opens: its
        // spend against the limit, over it and in warning ink, and the editor.
        do {
            let controller = try openInspector(model, session, at: .overview)
            defer { controller.close(); window.makeKeyAndOrderFront(nil) }
            try await until("the limited chat's Overview") { controller.inspector.indexLoaded && controller.inspector.timeCharts.historyLoaded }
            for (name, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance); try await settle(1.2)
                try capture(try XCTUnwrap(controller.window), to: gallery.appendingPathComponent("18a-cost-limit-overview-\(name).png"))
            }
        }
        try await settle(0.6)
        let content = try XCTUnwrap(window.contentView)
        try await pair("18b-cost-limit-editor", hold: 1.0, popovers: true) {
            CostLimitPopover.shared.close(); try await settle(0.4)
            let raise = try XCTUnwrap(descendants(PiPopoverTriggerButton.self, in: content).first { $0.accessibilityIdentifier() == "cost-limit-raise" },
                                      "The notice offers Raise limit…")
            raise.performClick(nil)
            let opened = Date().addingTimeInterval(5)
            while Date() < opened, CostLimitPopover.shared.presenter.popover?.isShown != true { try await settle(0.05) }
            XCTAssertTrue(CostLimitPopover.shared.presenter.isShown, "Raise limit… opened the chat's limit editor")
        }
        CostLimitPopover.shared.close(); try await settle(0.4)
        try await model.setCostLimit(.usd(10), for: chat.id)
        try await pair("18c-cost-limit-raised", hold: 1.0)
        model.costLimitNotice(.continueRun, sessionID: chat.id, anchor: nil)
        let resumed = Date().addingTimeInterval(90)
        while Date() < resumed, session.failureMessage != nil || session.hasWork || session.loading { try await settle(0.25) }
        XCTAssertNil(session.failureMessage, "Continue took the stopped turn on")
        // 18d · Settings: the default every chat without its own limit runs
        // under. The Spending group sits low on the page, so the page is
        // scrolled to its end first.
        try await pair("18d-cost-limit-settings", hold: 0.8) {
            if window.attachedSheet == nil { model.showProfiles = true; try await settle(2.2) }
            let sheet = try XCTUnwrap(window.attachedSheet, "Settings opened as a sheet")
            let scroll = try XCTUnwrap(descendants(NSScrollView.self, in: sheet.contentView ?? NSView()).max { $0.frame.height < $1.frame.height })
            for _ in 0..<3 {
                let end = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: end)); scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(0.4)
            }
        }
        model.showProfiles = false; try await settle(0.8)
    }

    /// Scrolls the main conversation so a row stands near the top of the
    /// viewport, announced the way AppKit announces a reader's scroll.
    @MainActor private func scrollConversation(in window: NSWindow, toRow id: String) throws {
        let scroll = try XCTUnwrap(descendants(TranscriptNativeScrollView.self, in: window.contentView ?? NSView()).first)
        let row = try XCTUnwrap(descendants(TranscriptRowContainer.self, in: scroll).first { $0.itemID == id }, "The row \(id) is in the page")
        let clip = scroll.contentView
        let y = max(0, row.frame.minY - 24)
        scroll.readerWillNavigate(upward: y < clip.bounds.minY)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    /// The conversation page behind the window, for a scene that has to wait
    /// for the turn it is photographing to reach a certain age.
    @MainActor private func page(of window: NSWindow) -> TranscriptPage? {
        window.contentView.flatMap { descendants(TranscriptSurfaceMarker.self, in: $0).first?.page }
    }

    @MainActor private func sheet(_ window: NSWindow, name: String, into gallery: URL, open: () -> Void, close: () -> Void) async throws {
        open(); try await settle(2.2)
        try capture(window, to: gallery.appendingPathComponent(name + ".png"))
        close(); try await settle(0.8)
    }

    @MainActor private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @MainActor private func until(_ what: String, seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for " + what) }
            try await settle(0.1)
        }
    }

    /// The main chat's Session Inspector, opened as the reader opens it,
    /// sized for the gallery.
    @MainActor private func openInspector(_ model: WorkspaceModel, _ session: SessionDisplay, at focus: InspectorFocus) throws -> SessionInspectorWindowController {
        model.openInspector(session: session.id, focus: focus)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: session.id), "The Session Inspector opened")
        try XCTUnwrap(controller.window).setContentSize(NSSize(width: 1_200, height: 860))
        controller.window?.center()
        return controller
    }

    /// The Session Inspector of the main chat, which by now has several turns,
    /// two routes and a tool round: its Overview (where the pills open it),
    /// the first turn, that turn's tool round in each of the request page's
    /// tabs, a search of its raw bytes, what the next request will send, a
    /// narrow window, and a reply's Details landing on its request.
    @MainActor private func captureInspectorScenes(model: WorkspaceModel, session: SessionDisplay, window: NSWindow, gallery: URL,
                                                  appearances: [(String, NSAppearance.Name)]) async throws {
        let controller = try openInspector(model, session, at: .overview)
        let inspector = controller.inspector, panel = try XCTUnwrap(controller.window)
        defer { controller.close(); window.makeKeyAndOrderFront(nil) }
        func shoot(_ scene: String, hold: Double = 0.8) async throws {
            for (name, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance); try await settle(hold)
                try capture(panel, to: gallery.appendingPathComponent("\(scene)-\(name).png"))
            }
        }
        try await until("the Inspector's Overview") {
            inspector.indexLoaded && inspector.index.requests.count >= 2 && inspector.timeCharts.historyLoaded && inspector.usage.snapshot != nil
        }
        // 11 · The Overview: what the chat cost, used and how fast, its charts and requests.
        try await shoot("11-inspector-overview", hold: 1.2)
        // 11b · The first turn, which ran the read tool: its prompt, usage and requests.
        let first = try XCTUnwrap(inspector.index.turns.first { !$0.isOther })
        inspector.select(.turn(first.id))
        try await until("the first turn's prompt") { inspector.prompts[first.id] != nil }
        try await shoot("11b-inspector-turn")
        // 11c · Its tool round: what was new since the request before.
        let round = try XCTUnwrap(first.requests.first { inspector.index.kind(of: $0.id) == "tool round" } ?? first.requests.last)
        inspector.select(.request(round.id))
        inspector.request.tab = .conversation
        try await until("the tool round's conversation") { inspector.request.conversation.value != nil && inspector.request.delta != nil }
        try await shoot("11c-inspector-conversation", hold: 1.0)
        // 11i · "Show all" opens texts in place: the system prompt, all of it
        // where its preview was, with a few lines selected, and every tool's
        // schema in place of the tools' list; the rows below moved down.
        // 11j · The end of the schema: "Show less", then the rows after it.
        do {
            let outline = try XCTUnwrap(descendants(InspectorOutlineView.self, in: panel.contentView ?? NSView()).first, "The conversation's outline is on screen")
            let coordinator = try XCTUnwrap(outline.coordinator)
            let clip = try XCTUnwrap(outline.enclosingScrollView?.contentView)
            coordinator.showWhole(.section(.system))
            coordinator.showWhole(.section(.tools))
            try await until("the whole system prompt and every tool's schema in place") {
                [RequestDocument.Section.Kind.system, .tools].allSatisfy { coordinator.expansion(for: .section($0))?.textView?.window != nil }
            }
            try await settle(0.4)
            let system = try XCTUnwrap(coordinator.expansion(for: .section(.system))?.textView)
            XCTAssertEqual(system.string, coordinator.expansion(for: .section(.system))?.text, "The whole system prompt is in place")
            let text = system.string as NSString
            let first = text.range(of: "\n").location
            system.setSelectedRange(NSRange(location: 0, length: first == NSNotFound ? min(140, text.length) : first))
            panel.makeFirstResponder(system)
            clip.scroll(to: .zero); outline.enclosingScrollView?.reflectScrolledClipView(clip)
            try await shoot("11i-inspector-expanded", hold: 1.0)
            let less = (0..<outline.numberOfRows).last { row in
                guard let node = outline.item(atRow: row) as? InspectorItemsOutline.Node, case .less = node.kind else { return false }
                return true
            }
            let end = try XCTUnwrap(less, "The schema ends with Show less")
            clip.scroll(to: NSPoint(x: 0, y: max(0, outline.rect(ofRow: end).minY - clip.bounds.height * 0.55)))
            outline.enclosingScrollView?.reflectScrolledClipView(clip)
            try await shoot("11j-inspector-expanded-end", hold: 0.8)
            coordinator.showLess(.section(.tools)); coordinator.showLess(.section(.system))
            clip.scroll(to: .zero); outline.enclosingScrollView?.reflectScrolledClipView(clip)
            try await settle(0.3)
        }
        // 11d · What came back.
        inspector.request.tab = .response
        try await until("the tool round's response") { inspector.request.response.value != nil }
        try await shoot("11d-inspector-response", hold: 1.0)
        // 11e · The raw request, searched.
        inspector.request.tab = .raw
        inspector.request.raw = .request
        inspector.request.query = "README"
        try await shoot("11e-inspector-raw-search", hold: 1.4)
        inspector.request.query = ""
        // 11f · What the next request will send, against the last one.
        inspector.select(.nextRequest)
        try await until("the next request") { inspector.next.document.value != nil }
        try await shoot("11f-inspector-next-request", hold: 1.0)
        // 11h · A narrow window: the navigator narrows and the figures wrap.
        inspector.select(.request(round.id)); inspector.request.tab = .conversation
        panel.setContentSize(NSSize(width: 760, height: 700)); panel.center()
        try await shoot("11h-inspector-narrow", hold: 1.2)
        // 09 · A reply's Details open the Inspector at the request that produced it.
        panel.setContentSize(NSSize(width: 1_200, height: 860)); panel.center()
        if let assistant = session.messages.last(where: { $0.role == "assistant" && !$0.id.hasPrefix("stream:") }) {
            model.showMessageDetail(session.id, messageID: assistant.id)
            try await until("the reply's request") {
                if case .request(let id) = inspector.page { return id != round.id && inspector.request.row?.id == id }
                return false
            }
            try await shoot("09-message-details", hold: 1.2)
        }
        XCTAssertNil(inspector.failure, inspector.failure ?? "")
        XCTAssertNil(inspector.focusNotice, inspector.focusNotice ?? "")
    }

    /// 11g · The Inspector on the request a running turn is still streaming.
    @MainActor private func captureRunningInspector(model: WorkspaceModel, session: SessionDisplay, window: NSWindow, gallery: URL,
                                                   appearances: [(String, NSAppearance.Name)]) async throws {
        let controller = try openInspector(model, session, at: .latestRequest)
        let inspector = controller.inspector, panel = try XCTUnwrap(controller.window)
        defer { controller.close(); window.makeKeyAndOrderFront(nil) }
        try await until("the running request", seconds: 10) {
            if case .request(let id) = inspector.page { return inspector.index.request(id)?.running == true }
            return false
        }
        inspector.request.tab = .response
        try await until("the response so far", seconds: 10) { inspector.request.response.value != nil }
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance); try await settle(0.8)
            try capture(panel, to: gallery.appendingPathComponent("11g-inspector-running-\(name).png"))
        }
    }

    /// The window and this app's popovers over it, by window id: no other
    /// application's window can enter the image.
    @MainActor private func captureWithPopovers(_ window: NSWindow, to url: URL) throws {
        typealias ArrayImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ArrayImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        // A skill pill's hover card is a panel of its own, captured the same way.
        let popovers = NSApp.windows.filter { $0.isVisible && $0 != window && (String(describing: type(of: $0)).contains("Popover") || $0 is PiHoverCardPanel) }
        var frame = window.frame
        for popover in popovers { frame = frame.union(popover.frame) }
        var ids = (popovers + [window]).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        guard let image = create(bounds, array, options)?.takeRetainedValue() else { throw XCTSkip("Window capture returned no image") }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }

    @MainActor private func waitIdle(_ session: SessionDisplay, model: WorkspaceModel, minimumMessages: Int, timeout: Double = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = model.error { XCTFail("Workspace error while waiting: \(error)"); return }
            if !session.hasWork && !session.loading && session.messages.count >= minimumMessages && !session.messages.contains(where: { $0.id.hasPrefix("stream:") }) { return }
            try await settle(0.25)
        }
        XCTFail("Session \(session.id) did not settle: state \(session.state), \(session.messages.count) messages, notice: \(session.notice)")
    }

    // Captures this process's windows in the given frame through the window
    // server. The symbol is resolved dynamically so the SDK deprecation note
    // does not fail the warnings-as-errors build; ScreenCaptureKit would need
    // TCC consent.
    @MainActor private func capture(_ window: NSWindow, to url: URL, includingOwnedPanels: Bool = false) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        var frame = window.frame
        if let sheet = window.attachedSheet { frame = frame.union(sheet.frame) }
        if includingOwnedPanels {
            for panel in NSApp.windows where panel.isVisible && panel != window { frame = frame.union(panel.frame) }
        }
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        // Capture the app window itself so an incidental tooltip or another
        // application's window cannot obscure the scene being reviewed.
        let isolated = window.attachedSheet == nil
        let list = isolated ? CGWindowListOption.optionIncludingWindow : .optionOnScreenOnly
        let number = isolated ? UInt32(window.windowNumber) : 0
        let captured: CGImage?
        if includingOwnedPanels {
            captured = create(bounds, CGWindowListOption.optionIncludingWindow.union(.optionOnScreenAboveWindow).rawValue,
                              UInt32(window.windowNumber), options)?.takeRetainedValue()
        } else { captured = create(bounds, list.rawValue, number, options)?.takeRetainedValue() }
        guard let image = captured else { throw XCTSkip("Window capture returned no image") }
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
