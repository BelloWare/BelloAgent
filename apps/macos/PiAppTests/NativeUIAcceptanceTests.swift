import XCTest
import SwiftUI
@testable import PiApp

// Opt-in interactive harness, compiled into the test bundle only. Production
// PiApp has no fixture switch, credential fallback, or test-vault implementation.
final class NativeUIAcceptanceTests: XCTestCase {
    @MainActor func testInteractiveSyntheticWorkspace() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PI_APP_UI_ACCEPTANCE_ROOT"] ?? environment["TEST_RUNNER_PI_APP_UI_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set PI_APP_UI_ACCEPTANCE_ROOT to run the interactive CUA acceptance window.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let featureBatch = environment["PI_APP_UI_ACCEPTANCE_FEATURES"] == "1" || environment["TEST_RUNNER_PI_APP_UI_ACCEPTANCE_FEATURES"] == "1"
        let productivityBatch = environment["PI_APP_UI_ACCEPTANCE_PRODUCTIVITY"] == "1" || environment["TEST_RUNNER_PI_APP_UI_ACCEPTANCE_PRODUCTIVITY"] == "1"
        let secondaryFolder = folder.appendingPathComponent("secondary-workspace-folder", isDirectory: true)
        if featureBatch {
            try FileManager.default.createDirectory(at: secondaryFolder, withIntermediateDirectories: true)
            try Data("Synthetic UI fixture file: read-tool round trip verified.\nSECONDARY-WORKSPACE-ROOT-VERIFIED\n".utf8)
                .write(to: secondaryFolder.appendingPathComponent("SECONDARY.md"))
        }
        let finish = folder.appendingPathComponent("finish")
        if FileManager.default.fileExists(atPath: finish.path) { try FileManager.default.removeItem(at: finish) }
        try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8).write(to: folder.appendingPathComponent("README.md"))
        try prepareResources(in: folder)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("fixtures/native/ui-gateway.py").path]
        fixture.currentDirectoryURL = folder; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path, "PI_APP_UI_FIXTURE_MODEL": "auto-router"]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let value = try JSONDecoder().decode([String: Int].self, from: greeting)
        let port = try XCTUnwrap(value["port"]), base = "http://127.0.0.1:\(port)"
        let mcpFixturePath = repository.appendingPathComponent("fixtures/native/mcp-server.py").path
        let workspace = WorkspaceRecord(id: "native-ui-fixture", path: folder.path, trusted: true)
        let referenceFolder = folder.appendingPathComponent("Reference Project", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
        let referenceProject = WorkspaceRecord(id: "native-ui-reference", path: referenceFolder.path, trusted: true)
        let profilePath = folder.appendingPathComponent("synthetic-profiles.json")
        var connections = ["auto-router", "fixture-fast"].map { alias -> VaultProfile in
            var profile = ProfileRecord(); profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = alias
            profile.contextWindow = alias == "fixture-fast" ? 128_000 : 2_000_000; profile.maxOutputTokens = alias == "fixture-fast" ? 16_000 : 300_000
            profile.catalogUrl = base + "/catalog"
            profile.name = alias == "fixture-fast" ? "Responses · Fast model" : "Synthetic Responses"
            let reasoning = alias == "fixture-fast" ? "\"reasoning\":false,\"thinkingLevel\":\"default\"" : "\"reasoning\":true,\"thinkingLevel\":\"high\""
            profile.advancedJSON = "{\(reasoning),\"routing\":{\"replayPolicy\":\"portable\",\"reference\":\"Synthetic UI gateway accounting contract v1\",\"cacheHeader\":\"x-fixture-cache\",\"modelHeader\":\"x-fixture-model\"}}"
            return VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")
        }
        // This synthetic profile seed belongs only to the XCTest harness. It
        // keeps profile identities stable across separately launched app PIDs;
        // production configuration still comes exclusively from Keychain.
        if FileManager.default.fileExists(atPath: profilePath.path) {
            connections = try JSONDecoder().decode([VaultProfile].self, from: Data(contentsOf: profilePath))
            guard connections.allSatisfy({ $0.profile.api == "openai-responses" }), Set(connections.map { $0.profile.modelId }) == ["auto-router", "fixture-fast"] else {
                throw HostError.failure("Use a fresh UI acceptance folder for the Responses-only fixture; legacy synthetic profiles are not migrated silently.")
            }
            for index in connections.indices { connections[index].profile.baseUrl = base; connections[index].profile.catalogUrl = base + "/catalog" }
        }
        try JSONEncoder().encode(connections).write(to: profilePath, options: .atomic)
        let seededConnections = connections
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace, referenceProject]; $0.profiles = seededConnections
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
        var priorAttempts = Set<String>()
        for chat in model.chats {
            for metadata in try await model.traces.list(sessionID: chat.id) {
                if let id = metadata["attemptId"]?.string { priorAttempts.insert(id) }
            }
        }
        for connection in connections where !model.chats.contains(where: { $0.profileID == connection.profile.id && !$0.imported }) {
            let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: connection.profile.name, path: nil, profileID: connection.profile.id)
            model.chats.append(chat)
            try await model.store?.put(chat, kind: "chat", id: chat.id)
        }
        if environment["PI_APP_UI_ACCEPTANCE_HISTORY"] == "1" || environment["TEST_RUNNER_PI_APP_UI_ACCEPTANCE_HISTORY"] == "1" {
            try await prepareHistory(in: folder, model: model, workspace: workspace, profileID: connections[0].profile.id)
        }
        let selectedPath = folder.appendingPathComponent("selected-for-relaunch.txt")
        let savedSelection = try? String(contentsOf: selectedPath, encoding: .utf8)
        await model.select(savedSelection ?? model.chats.first(where: { !$0.imported })!.id)
        for window in NSApp.windows { window.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bello Agent — Synthetic UI Acceptance"
        window.isReleasedWhenClosed = false
        // This status item uses the production panel with the isolated fixture
        // archive. Never open the application's production-vault menu in tests.
        let metricsMenu = UIAcceptanceStatusItem(model: model, window: window)
        window.contentView = NSHostingView(rootView: UIAcceptanceWindow(model: model,
            showMetrics: { metricsMenu.pressButton() },
            closeAndShowMetrics: { window.close(); metricsMenu.pressButton() }))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        defer { metricsMenu.remove() }
        try Data("\(base)\n".utf8).write(to: folder.appendingPathComponent("ready.txt"))
        try JSONEncoder().encode(["appPID": ProcessInfo.processInfo.processIdentifier, "gatewayPID": fixture.processIdentifier]).write(to: folder.appendingPathComponent("processes.json"))
        // The operator writes finish after observing the actual GUI workflows.
        // This keeps CUA evidence separate from assertions about model state.
        var previousCostSamples: [String: Int] = [:]
        var backgroundBilling = Set<String>()
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish").path) {
            for view in model.displays.values {
                let samples = view.footer.gateway.costSamples
                if samples > (previousCostSamples[view.id] ?? 0), model.selectedID != view.id { backgroundBilling.insert(view.id) }
                previousCostSamples[view.id] = samples
            }
            let state: WireValue = .object([
                "page": .string(model.page.rawValue),
                "reportLoaded": .bool(model.report.snapshot != nil),
                "selectedID": .string(model.selectedID ?? ""), "focusedID": .string(model.focusedSessionID ?? ""),
                "chats": .array(model.chats.prefix(4).map { .object(["id": .string($0.id), "title": .string($0.title), "pinned": .bool($0.isPinned), "archived": .bool($0.isArchived)]) }),
                "sessions": .array(model.displays.values.map { .object([
                    "id": .string($0.id), "state": .string($0.state), "draft": .string($0.draft),
                    "costSamples": .number(Double($0.footer.gateway.costSamples)), "costUSD": $0.footer.gateway.costUSD.map(WireValue.number) ?? .null,
                    "messages": .number(Double($0.messages.count)), "projectedTextBytes": .number(Double($0.messages.reduce(0) { $0 + $1.text.utf8.count }))
                ]) })
            ])
            try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("ui-state.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish").path), "UI acceptance timed out without an explicit operator finish marker")
        if productivityBatch {
            XCTAssertFalse(backgroundBilling.isEmpty, "A new cost sample must arrive while another chat is selected")
            XCTAssertTrue(model.chats.contains { $0.isPinned }, "Pin a session through the native UI")
            XCTAssertTrue(model.chats.contains { $0.isArchived }, "Leave a session archived after verifying restore")
            XCTAssertTrue(model.chats.contains { $0.titleWasEdited == true }, "Rename a session through the native UI")
            let persisted = try await model.store?.loadChats() ?? []
            for chat in model.chats {
                let saved = try XCTUnwrap(persisted.first { $0.id == chat.id })
                XCTAssertEqual(saved.title, chat.title); XCTAssertEqual(saved.isPinned, chat.isPinned); XCTAssertEqual(saved.isArchived, chat.isArchived)
            }
        }
        try Data((model.selectedID ?? "").utf8).write(to: selectedPath)
        for host in model.hosts.values { try await host.shutdownAndWait() }
        let (captured, _) = try await URLSession.shared.data(from: URL(string: base + "/captures")!)
        try captured.write(to: folder.appendingPathComponent("captures.json"))
        let observed = try JSONDecoder().decode([[String: WireValue]].self, from: captured)
        XCTAssertEqual(Set(observed.compactMap { $0["path"]?.string }), ["/v1/responses"], "Active requests must use only Responses")
        XCTAssertEqual(Set(observed.compactMap { $0["model"]?.string }), ["auto-router", "fixture-fast"], "Exercise the router and the second Responses model before finishing")
        if featureBatch {
            let fast = observed.filter { $0["model"]?.string == "fixture-fast" }
            XCTAssertEqual(Set(fast.compactMap { $0["path"]?.string }), ["/v1/responses"], "Send with the smaller catalog model through Responses")
            for record in fast {
                let body = try XCTUnwrap(Data(base64Encoded: record["request"]?.string ?? ""))
                let json = try JSONDecoder().decode(WireValue.self, from: body).object ?? [:]
                XCTAssertEqual(json["max_output_tokens"]?.number, 16_000, "The selected model's output limit must reach the wire")
                XCTAssertNil(json["reasoning"]); XCTAssertNil(json["thinking"]); XCTAssertNil(json["output_config"])
                XCTAssertTrue(record["contractValidated"]?.bool == true)
            }
            let replacement = observed.compactMap { record -> String? in
                guard let data = Data(base64Encoded: record["request"]?.string ?? ""),
                      let text = String(data: data, encoding: .utf8), text.contains("BRANCH-REPLACEMENT-FIXTURE") else { return nil }
                return text
            }
            XCTAssertFalse(replacement.isEmpty, "Edit BRANCH-ORIGINAL-FIXTURE to BRANCH-REPLACEMENT-FIXTURE after an ABANDONED-REPLY-FIXTURE turn")
            for body in replacement {
                XCTAssertFalse(body.contains("BRANCH-ORIGINAL-FIXTURE")); XCTAssertFalse(body.contains("ABANDONED-REPLY-FIXTURE"))
            }
            XCTAssertTrue(model.displays.values.contains { $0.messages.contains { $0.kind == "branch" } }, "The edit branch must remain visible")
            XCTAssertTrue(model.workspaces.contains { $0.id == workspace.id && $0.paths.contains(secondaryFolder.resolvingSymlinksInPath().path) }, "Add and trust the secondary fixture folder through Workspaces")
            XCTAssertTrue(observed.contains { $0["secondaryRootVerified"]?.bool == true }, "Read SECONDARY.md through the helper from the added workspace folder")
        }
        var verifiedBodies = 0, currentRunVerifiedBodies = 0
        var priorUnverifiedAttempts: [String] = []
        var currentRunPaths = Set<String>()
        var currentRunModels = Set<String>()
        for sessionID in model.chats.map(\.id) {
            for metadata in try await model.traces.list(sessionID: sessionID) where metadata["request"]?.object?["state"]?.string == "complete" {
                let attemptID = try XCTUnwrap(metadata["attemptId"]?.string)
                if productivityBatch {
                    let auth = try XCTUnwrap(metadata["requestHeaders"]?.object?["authorization"]?.string)
                    XCTAssertTrue(auth.hasPrefix("Bearer ")); XCTAssertTrue(auth.hasSuffix("-key"))
                    XCTAssertFalse(auth.contains("synthetic-loopback-only-key"))
                    XCTAssertNotNil(metadata["responseHeaders"]?.object?["content-type"]?.string)
                    XCTAssertNotNil(metadata["responseHeaders"]?.object?["date"]?.string)
                }
                var bodies: [String: Data] = [:]
                for kind in ["request", "response"] {
                    let retained = Int(metadata[kind]?.object?["retainedBytes"]?.number ?? 0)
                    var data = Data()
                    while data.count < retained {
                        let page = try await model.traces.body(attemptID: attemptID, body: kind, offset: data.count)
                        XCTAssertFalse(page.isEmpty); if page.isEmpty { break }; data.append(page)
                    }
                    bodies[kind] = data
                }
                guard let serverRecord = observed.first(where: { Data(base64Encoded: $0["request"]?.string ?? "") == bodies["request"] }) else {
                    if priorAttempts.contains(attemptID) {
                        // A prior failed harness run may have lost its separate
                        // fixture log. Report this evidence gap explicitly;
                        // never manufacture expected wire bytes from storage.
                        priorUnverifiedAttempts.append(attemptID)
                    } else {
                        XCTFail("Current-run capture has no independent gateway bytes: \(attemptID)")
                    }
                    continue
                }
                let response = try XCTUnwrap(Data(base64Encoded: serverRecord["response"]?.string ?? ""))
                if metadata["response"]?.object?["state"]?.string == "complete" { XCTAssertEqual(response, bodies["response"]) }
                else { XCTAssertTrue(response.starts(with: try XCTUnwrap(bodies["response"])), "An interrupted body must remain an original byte prefix") }
                verifiedBodies += 2
                if !priorAttempts.contains(attemptID) {
                    currentRunVerifiedBodies += 2
                    if let path = serverRecord["path"]?.string { currentRunPaths.insert(path) }
                    if let model = serverRecord["model"]?.string { currentRunModels.insert(model) }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(verifiedBodies, 4)
        XCTAssertEqual(currentRunPaths, ["/v1/responses"], "Send fresh Responses requests during this process run")
        XCTAssertEqual(currentRunModels, ["auto-router", "fixture-fast"], "Independently verify fresh exact captures for both requested models")
        XCTAssertGreaterThanOrEqual(metricsMenu.opens, 2, "Open and reopen the fixture status panel")
        XCTAssertTrue(metricsMenu.openedWithoutMainWindow, "Verify the status item after closing the fixture main window")
        XCTAssertGreaterThan(metricsMenu.reportOpens, 0, "Open the report from the status panel")
        XCTAssertGreaterThanOrEqual(metricsMenu.scopes.count, 2, "Change the menu's time scope")
        let menuSnapshot = try await model.traces.menuBarMetrics(period: .retained)
        XCTAssertGreaterThan(menuSnapshot.gateway.tokens?.total ?? 0, 0)
        XCTAssertGreaterThan(menuSnapshot.gateway.costUSD ?? 0, 0)
        XCTAssertEqual(Set(menuSnapshot.models.map(\.requestedAlias)), ["auto-router", "fixture-fast"])
        XCTAssertEqual(Set(menuSnapshot.models.compactMap(\.resolvedModel)), Set(observed.compactMap { $0["resolvedModel"]?.string }), "Distribution must match the independently recorded gateway routes, including the owner billing sample when exercised")
        let result: WireValue = .object([
            "productivityChecks": .bool(productivityBatch), "backgroundBillingSessions": .number(Double(backgroundBilling.count)),
            "requests": .number(Double(observed.count)), "verifiedRetainedBodies": .number(Double(verifiedBodies)),
            "currentRunVerifiedBodies": .number(Double(currentRunVerifiedBodies)),
            "priorUnverifiedAttemptIDs": .array(priorUnverifiedAttempts.sorted().map(WireValue.string)),
            "catalogModelEditAndMultiRootChecks": .bool(featureBatch),
            "menuOpens": .number(Double(metricsMenu.opens)), "menuReportOpens": .number(Double(metricsMenu.reportOpens)),
            "menuScopes": .array(metricsMenu.scopes.sorted().map(WireValue.string)),
            "menuRequests": .number(Double(menuSnapshot.gateway.requests)),
            "menuTokens": .number(Double(menuSnapshot.gateway.tokens?.total ?? 0)),
            "menuCostUSD": .number(menuSnapshot.gateway.costUSD ?? 0)
        ])
        try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("verification.json"))
        try await model.traces.close()
    }

    private func prepareResources(in folder: URL) throws {
        let skill = folder.appendingPathComponent(".agents/skills/fixture-explicit")
        try FileManager.default.createDirectory(at: skill.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try Data("---\nname: fixture-explicit\ndescription: Synthetic explicit-only acceptance skill\n---\nInclude the marker EXPLICIT-FIXTURE-SELECTED in your response.\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: skill.appendingPathComponent("agents/openai.yaml"))
        try Data("Synthetic native acceptance instructions: fixture data only.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        let script = "import sys,time\nchunk=(b'SYNTHETIC-TOOL-OUTPUT\\n'*50000)[:1048576]\nassert len(chunk)==1048576\nfor _ in range(50):\n sys.stdout.buffer.write(chunk);sys.stdout.buffer.flush();time.sleep(.15)\n"
        try Data(script.utf8).write(to: folder.appendingPathComponent("stress-output.py"))
    }

    @MainActor private func prepareHistory(in folder: URL, model: WorkspaceModel, workspace: WorkspaceRecord, profileID: String) async throws {
        let history = folder.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        var body = Data()
        for index in 0..<10_000 {
            let message: WireValue = .object(["type": .string("message"), "id": .string("history-\(index)"),
                "parentId": index == 0 ? .null : .string("history-\(index - 1)"),
                "message": .object(["role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                    "content": .array([.object(["type": .string("text"), "text": .string("Message \(index) · 🌍\n\n" + String(repeating: "Synthetic retained paragraph. ", count: 4))])])])])
            body.append(try JSONEncoder().encode(message)); body.append(10)
        }
        for index in 0..<100 {
            let id = "history-fixture-\(index)", path = history.appendingPathComponent("\(id).jsonl")
            if model.chats.contains(where: { $0.id == id }) { continue }
            var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\"}\n".utf8); bytes.append(body)
            try bytes.write(to: path)
            let chat = ChatRecord(id: id, workspaceID: workspace.id, title: String(format: "History %03d · 10000 messages", index), path: path.path, profileID: profileID, toolMode: "read-only", imported: true)
            model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: id)
        }
    }
}

@MainActor private final class UIAcceptanceStatusItem: NSObject {
    private let controller = MenuBarController()
    private let window: NSWindow
    private(set) var opens = 0
    private(set) var reportOpens = 0
    private(set) var openedWithoutMainWindow = false
    private(set) var scopes = Set<String>()

    init(model: WorkspaceModel, window: NSWindow) {
        self.window = window
        super.init()
        controller.onOpen = { [weak self] in
            guard let self else { return }
            self.opens += 1
            self.openedWithoutMainWindow = self.openedWithoutMainWindow || !self.window.isVisible
        }
        controller.install(title: "B·Test", accessibilityLabel: "Bello Agent fixture activity and usage") {
            MenuBarMetricsView(load: { [weak self] period, until, offset in
                self?.scopes.insert(period.rawValue)
                return try await model.traces.menuBarMetrics(period: period, until: until, offset: offset)
            }, activity: { model.menuBarActivity() }, openApp: { [weak self] in
                self?.reveal()
            }, openReport: { [weak self] in
                self?.reportOpens += 1; self?.reveal(); model.openReport()
            }, openSession: { [weak self] id in
                self?.reveal()
                Task { if model.side(id) != nil { await model.selectSide(id) } else { await model.select(id) } }
            })
        }
    }
    // CUA excludes physical status-bar buttons. The test toolbar invokes the
    // production controller's actual NSStatusBarButton target/action; CUA then
    // operates its production panel, including after the main window closes.
    func pressButton() { controller.pressButton() }
    private func reveal() {
        controller.close(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func remove() { controller.remove() }
}

private struct UIAcceptanceWindow: View {
    @ObservedObject var model: WorkspaceModel
    let showMetrics: () -> Void
    let closeAndShowMetrics: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SYNTHETIC LOOPBACK FIXTURE · Test vault only · No real model calls").font(.caption.bold())
                Spacer()
                Button("Fixture Usage", action: showMetrics)
                Button("Close Window & Show Usage", action: closeAndShowMetrics)
                Button("Stop Fixture Helper") { model.shutdown() }
                    .help("Test-only process interruption. The next native action must reopen saved state without replaying work.")
            }.padding(8).background(Color.orange.opacity(0.25))
            WorkspaceView(model: model)
        }
    }
}
