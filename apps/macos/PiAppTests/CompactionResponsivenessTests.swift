import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The app froze for good while it compacted a long chat (0.1.89): SwiftUI's
/// update never went back to the run loop (`LazyListAppKitControlTests`).
/// This drives that situation in the real window — a long chat whose history
/// takes several chained summary requests, a sidebar with projects and topics,
/// the Session Inspector open, a side pane — through the packaged helper and the
/// synthetic gateway, compacting by hand and at the threshold, while a
/// watchdog checks that the main thread keeps coming back to its run loop and
/// SwiftUI's own log checks that no update changed state from inside itself.
final class CompactionResponsivenessTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor func testCompactingALongChatKeepsTheWindowResponsive() async throws {
        let start = Date()
        let folder = URL(fileURLWithPath: scratchBase()).appendingPathComponent("compaction-hang-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8).write(to: folder.appendingPathComponent("README.md"))

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("fixtures/native/ui-gateway.py").path]
        fixture.currentDirectoryURL = folder; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path,
                               "PI_APP_UI_FIXTURE_LENIENT_LIMIT": "1", "PI_APP_UI_FIXTURE_REAL_USAGE": "1",
                               "PI_APP_UI_FIXTURE_SUMMARY_DELAY": testEnvironment("PI_APP_HANG_SUMMARY_DELAY") ?? "0.05"]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        // A frozen window fails the run with a sample of the main thread, and
        // takes the gateway with it: nothing after the stall can clean up.
        let gateway = fixture.processIdentifier
        let watchdog = MainThreadWatchdog(limit: Double(testEnvironment("PI_APP_HANG_LIMIT") ?? "") ?? 10,
                                          samplePath: folder.deletingLastPathComponent().appendingPathComponent("compaction-hang-sample.txt").path,
                                          onStall: { _ in kill(gateway, SIGTERM) })
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)"

        let workspace = WorkspaceRecord(id: "hang-main", path: folder.path, trusted: true)
        var projects = [workspace]
        for name in ["Design Reference", "Billing Service"] {
            let path = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            projects.append(WorkspaceRecord(id: "hang-" + name.lowercased().replacingOccurrences(of: " ", with: "-"), path: path.path, trusted: true))
        }
        let connections = ["ui-fixture", "fixture-fast"].map { alias -> VaultProfile in
            var profile = ProfileRecord(); profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = alias
            profile.catalogUrl = base + "/catalog"
            profile.contextWindow = alias == "fixture-fast" ? 128_000 : 2_000_000; profile.maxOutputTokens = alias == "fixture-fast" ? 16_000 : 300_000
            profile.modelOutputLimit = alias == "fixture-fast" ? 16_000 : 300_000
            profile.name = alias == "fixture-fast" ? "Team fast · Responses" : "Team router · Responses"
            profile.miniModelId = "fixture-fast"
            profile.advancedJSON = "{\"routing\":{\"replayPolicy\":\"portable\",\"reference\":\"Synthetic UI gateway accounting contract v1\",\"cacheHeader\":\"x-fixture-cache\"}}"
            return VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")
        }
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), configured = projects
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = configured; $0.profiles = connections
            $0.resources[workspace.id] = .object(["codexHome": .string(folder.appendingPathComponent("codex").path)])
            $0.automaticUpdateChecks = false
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: folder)
        await model.restore()
        model.profileChoice = connections[0].profile.id; model.selectedWorkspaceID = workspace.id

        // A sidebar with some weight: three projects, topics, fifty chats.
        let profileID = connections[0].profile.id
        var filler: [ChatRecord] = []
        for index in 0..<50 {
            let project = projects[index % 5 == 0 ? 1 + index % 2 : 0]
            var chat = ChatRecord(id: "filler-\(index)", workspaceID: project.id, title: "Sidebar chat \(index) about the retry budget",
                                  path: nil, profileID: profileID, toolMode: "editing")
            chat.titleWasEdited = true
            filler.append(chat); model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        }
        for topic in 0..<4 {
            let record = try await model.createTopic(in: workspace.id, title: "Topic \(topic)")
            let members = filler.filter { $0.workspaceID == workspace.id }.dropFirst(topic * 6).prefix(6).map(\.id)
            try await model.moveSessions(Array(members), in: workspace.id, toTopic: record.id)
        }
        let main = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Long chat that compacts",
                              path: nil, profileID: profileID, toolMode: "editing")
        model.chats.append(main); try await model.store?.put(main, kind: "chat", id: main.id)
        await model.select(main.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(1500))
        watchdog.start()
        defer { watchdog.stop() }
        let session = try XCTUnwrap(model.displays[main.id])

        func waitIdle(_ what: String, timeout: Double = 180) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            try await Task.sleep(for: .milliseconds(300))
            while Date() < deadline, session.hasWork || session.loading { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertFalse(session.hasWork, what + " did not finish: state \(session.state), notice \(session.notice)")
            try await Task.sleep(for: .milliseconds(300))
        }
        let turns = Int(testEnvironment("PI_APP_HANG_TURNS") ?? "") ?? 4
        let kilobytes = Int(testEnvironment("PI_APP_HANG_KB") ?? "") ?? 90
        for turn in 0..<turns {
            session.draft = "bulk \(kilobytes) history part \(turn): keep going with the payment retry notes."
            model.send(sessionID: main.id)
            try await waitIdle("bulk turn \(turn)")
            print("COMPACTION turn \(turn): \(session.messages.count) rows, state \(session.state), failure \(session.failureMessage ?? "-"), send failure \(String(describing: session.sendFailure)), notice \(session.notice), error \(model.error ?? "-")")
            XCTAssertNil(session.failureMessage, session.failureMessage ?? "")
        }
        print("COMPACTION built \(session.messages.count) rows; worst main-queue answer so far \(String(format: "%.2f", watchdog.worstStall)) s")

        // The last turn stays open in the Session Inspector beside the chat
        // (its info button replaced the Turn Info popover), reading the
        // session's requests while the chat compacts.
        if let info = descendants(NSButton.self, in: hosted).last(where: { $0.accessibilityIdentifier() == "turn-info-button" }) {
            info.performClick(nil)
            try await Task.sleep(for: .milliseconds(600))
            print("COMPACTION inspector open: \(SessionInspectorWindows.shared.controller(sessionID: main.id)?.window?.isVisible == true)")
        } else { print("COMPACTION no turn info button") }

        // A side pane beside the chat, with its own composer and menu.
        model.openSide(parentID: main.id)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(model.error, model.error ?? "")
        // A smaller window: the history is several summary requests long.
        let index = try XCTUnwrap(model.chats.firstIndex { $0.id == main.id })
        model.chats[index].contextWindow = Int(testEnvironment("PI_APP_HANG_WINDOW") ?? "") ?? 60_000
        model.chats[index].maxOutputTokens = 8_192
        model.chats[index].modelOutputLimit = 16_000
        model.action("context.compact", sessionID: main.id)
        var sawCompacting = false
        let compactDeadline = Date().addingTimeInterval(240)
        try await Task.sleep(for: .milliseconds(200))
        while Date() < compactDeadline {
            if session.runStatus == "compacting" || session.state == "compacting" { sawCompacting = true }
            if sawCompacting, !session.hasWork, !session.loading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sawCompacting, "Compact Now never ran")
        print("COMPACTION manual compaction done: \(session.compactionNotice ?? "no notice"); worst \(String(format: "%.2f", watchdog.worstStall)) s")

        // Threshold compaction during a turn: the history grows past the
        // smaller window, and the next send compacts before it asks.
        for turn in 0..<2 {
            session.draft = "bulk \(kilobytes) more history \(turn) after the compaction."
            model.send(sessionID: main.id)
            try await waitIdle("bulk turn after compaction \(turn)", timeout: 240)
        }
        print("COMPACTION threshold compaction done; worst \(String(format: "%.2f", watchdog.worstStall)) s, \(watchdog.answered) answers")
        let (captured, _) = try await URLSession.shared.data(from: URL(string: base + "/captures")!)
        let records = (try JSONSerialization.jsonObject(with: captured) as? [[String: Any]]) ?? []
        let summaries = records.filter { record in
            guard let encoded = record["request"] as? String, let data = Data(base64Encoded: encoded),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            // Pi's system prompt is the first input item; older requests carried it as instructions.
            let first = (body["input"] as? [[String: Any]])?.first
            let system = body["instructions"] as? String ?? (["system", "developer"].contains(first?["role"] as? String ?? "") ? first?["content"] as? String : nil)
            return system?.hasPrefix("You are a context summarization assistant.") == true
        }
        print("COMPACTION gateway saw \(records.count) requests, \(summaries.count) summary requests")
        XCTAssertGreaterThanOrEqual(summaries.count, 3, "Compact Now and the threshold compaction each ran chained summary requests")
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while the chat streamed and compacted")
        XCTAssertLessThan(watchdog.worstStall, watchdog.limit)
        XCTAssertNil(model.error, model.error ?? "")
    }
}
