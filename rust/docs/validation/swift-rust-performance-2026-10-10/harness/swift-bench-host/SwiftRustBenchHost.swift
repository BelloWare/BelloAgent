import XCTest
import AppKit
@testable import PiApp

/// Opt-in host for the Swift-vs-Rust comparison harness (not part of any gate).
/// It shows the production `WorkspaceRootView` and installs the production
/// `ApplicationMenus`, over an in-memory vault whose only connection points at
/// the loopback bench gateway, then waits for an external `finish` marker while
/// an outside process drives the window with synthetic input.
///
///   PI_APP_BENCH_ROOT     scratch folder (state root, project, markers)
///   PI_APP_BENCH_GATEWAY  http://127.0.0.1:PORT of benchgw.py
///   PI_APP_BENCH_JOURNAL  optional long-chat journal to list (read-only history)
final class SwiftRustBenchHost: XCTestCase {
    @MainActor func testBenchHost() async throws {
        guard let path = testEnvironment("PI_APP_BENCH_ROOT"), let gateway = testEnvironment("PI_APP_BENCH_GATEWAY") else {
            throw XCTSkip("Set PI_APP_BENCH_ROOT and PI_APP_BENCH_GATEWAY to host the benchmark window.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let finish = folder.appendingPathComponent("finish")
        try? FileManager.default.removeItem(at: finish)

        var profile = ProfileRecord(); profile.api = "openai-responses"; profile.baseUrl = gateway; profile.modelId = "bench-model"
        profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        profile.name = "Bench gateway"
        let workspace = WorkspaceRecord(id: "bench-project", path: project.path, trusted: true)
        let seeded = VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")
        let profileID = profile.id
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]
            $0.profiles = [seeded]
            $0.automaticUpdateChecks = false
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        defer { model.shutdown() }
        await model.restore()
        if let journal = testEnvironment("PI_APP_BENCH_JOURNAL"), !model.chats.contains(where: { $0.id == "long" }) {
            let chat = ChatRecord(id: "long", workspaceID: workspace.id, title: "Long chat", path: journal, profileID: profileID)
            model.chats.append(chat)
            try await model.store?.put(chat, kind: "chat", id: chat.id)
        }
        if let first = model.chats.first { await model.select(first.id) }

        for window in NSApp.windows { window.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowPresentationController.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Bello Agent"
        window.isReleasedWhenClosed = false
        window.contentMinSize = WorkspaceRootView.minimumWindowSize
        window.applyPiWindowChrome()
        window.contentView = WorkspaceRootView(model: model)
        window.center()
        let menus = ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { window },
                                     revealWorkspace: { window.makeKeyAndOrderFront(nil) }, showSettings: {})
        menus.install()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try JSONEncoder().encode(["appPID": ProcessInfo.processInfo.processIdentifier])
            .write(to: folder.appendingPathComponent("ready.json"), options: .atomic)
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline, !FileManager.default.fileExists(atPath: finish.path) {
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
