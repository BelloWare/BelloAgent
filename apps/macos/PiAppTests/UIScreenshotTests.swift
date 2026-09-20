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
        await model.select(main.id); try await settle(0.8)
        session.draft = "Now add a unit test for the jitter bounds and show me the diff."

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
            try await sheet(window, name: "04-inspector-\(name)", into: gallery, open: { model.inspect(main.id) }, close: { model.showInspector = false })
            try await sheet(window, name: "05-profiles-\(name)", into: gallery, open: { model.showProfiles = true }, close: { model.showProfiles = false })
            try await sheet(window, name: "06-resources-\(name)", into: gallery, open: { model.inspectResources(main.id) }, close: { model.showResources = false })
            try await sheet(window, name: "07-search-\(name)", into: gallery, open: { model.inspectConversation(main.id) }, close: { model.showConversationContent = false })
            try await sheet(window, name: "08-workspaces-\(name)", into: gallery, open: { model.showWorkspaceManager = true }, close: { model.showWorkspaceManager = false })
            if let assistant = session.messages.last(where: { $0.role == "assistant" && !$0.id.hasPrefix("stream:") }) {
                try await sheet(window, name: "09-message-\(name)", into: gallery, open: { model.showMessageDetail(main.id, messageID: assistant.id) }, close: { model.showMessageDetail = false })
            }
            // The Changes sheet against a small repository inside the project folder.
            try await sheet(window, name: "10-changes-\(name)", into: gallery, open: { model.showChanges(in: workspace.id) }, close: { model.showGit = false })
            // Session info for the main chat, in its own window, with both routes it used.
            let chat = try XCTUnwrap(model.record(main.id))
            let usage = SessionUsageWindows.shared.show(model: model, chat: chat, footer: session.footer, initialBreakdown: .models)
            try await settle(2.5)
            let panel = try XCTUnwrap(usage.window); panel.setContentSize(NSSize(width: 1000, height: 940)); panel.center(); try await settle(0.8)
            try capture(panel, to: gallery.appendingPathComponent("11-session-info-\(name).png"))
            usage.close(); try await settle(0.6)
        }
        try await renderReviewScenes(model: model, window: window, gallery: gallery, appearances: appearances,
                                     mainID: main.id, secondID: second.id, workspaceID: workspace.id)
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

        // 13 · A running turn: the live bar, and a follow-up waiting behind it.
        session.draft = "slow: walk through the retry budget one step at a time."
        model.send(sessionID: mainID)
        try await settle(2.0)
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

    @MainActor private func sheet(_ window: NSWindow, name: String, into gallery: URL, open: () -> Void, close: () -> Void) async throws {
        open(); try await settle(2.2)
        try capture(window, to: gallery.appendingPathComponent(name + ".png"))
        close(); try await settle(0.8)
    }

    @MainActor private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
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
    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        var frame = window.frame
        if let sheet = window.attachedSheet { frame = frame.union(sheet.frame) }
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        guard let image = create(bounds, CGWindowListOption.optionOnScreenOnly.rawValue, 0, options)?.takeRetainedValue() else { throw XCTSkip("Window capture returned no image") }
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
