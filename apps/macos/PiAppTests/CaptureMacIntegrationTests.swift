import XCTest
import Foundation
import CryptoKit
@testable import PiApp

final class CaptureMacIntegrationTests: XCTestCase {
    @MainActor func testTwentyColdNativeSessionsStreamToolsAndPersistEveryExactBody() async throws {
        let folder = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("capture-twenty-sessions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("scripts/test-concurrent-native-host.py").path, "--serve"]
        fixture.currentDirectoryURL = folder; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)", workspace = WorkspaceRecord(id: "concurrent-capture", path: folder.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = base + "/v1"; profile.modelId = "concurrency-fixture"
        profile.modelOutputLimit = 4096
        profile.advancedJSON = WireValue.object(["routing": .object(["replayPolicy": .string("portable")])]).pretty
        let connection = VaultProfile(profile: profile, apiKey: "fixture-secret")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let config = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome": .string(folder.appendingPathComponent("empty-codex").path), "skills": .bool(false)])
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: folder)
        try await model.reloadConfiguration()
        for index in 0..<20 {
            let id = String(format: "native-%02d", index)
            try Data("contents for \(id)".utf8).write(to: folder.appendingPathComponent(id + ".txt"))
            let chat = ChatRecord(id: id, workspaceID: workspace.id, title: id, path: nil, profileID: profile.id, toolMode: "read-only")
            model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: id)
            let view = SessionDisplay(id: id); view.draft = "concurrency " + id; model.displays[id] = view
        }
        model.selectedID = model.chats.first?.id; model.selected = model.selectedID.flatMap { model.displays[$0] }
        var interaction: ReviewConcurrentInteractionLoad?
        if testEnvironment("PI_REVIEW_VISUAL_LOAD") == "1" {
            let json = await Task.detached {
                CapturedJSON(value: ["records": (0..<2048).map { ["index": String($0), "payload": String(repeating: "x", count: 1024)] }],
                             formatted: "Synthetic 2 MiB capture inspector")
            }.value
            interaction = try ReviewConcurrentInteractionLoad(model: model, json: json)
        }
        defer { interaction?.verifyAndClose() }
        XCTAssertTrue(model.hosts.isEmpty, "Every session must take the real cold startup path")
        let started = ProcessInfo.processInfo.systemUptime
        var heartbeatSamples = 0, maximumHeartbeatGap = 0.0, previousHeartbeat = started
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                let now = ProcessInfo.processInfo.systemUptime
                maximumHeartbeatGap = max(maximumHeartbeatGap, now - previousHeartbeat)
                previousHeartbeat = now; heartbeatSamples += 1
            }
        }
        defer { heartbeat.cancel() }
        // No await between sends: all twenty user actions enter WorkspaceModel
        // together. The transport supplies each real session's x-session-id.
        for chat in model.chats { model.send(sessionID: chat.id) }
        let deadline = Date().addingTimeInterval(60)
        var completedSnapshots: [String: [String: WireValue]] = [:]
        while Date() < deadline {
            try interaction?.step()
            if model.displays.values.contains(where: { $0.sendFailure != nil }) {
                XCTFail("Concurrent send failures: " + model.displays.values.compactMap { view in view.sendFailure.map { "\(view.id): \($0)" } }.joined(separator: "; "))
                break
            }
            if model.opened.count == 20, model.displays.values.allSatisfy({ !$0.loading && ($0.draft.isEmpty || interaction?.composingSessionID == $0.id) && $0.state == "idle" }),
               let host = model.hosts[workspace.id] {
                for chat in model.chats where completedSnapshots[chat.id] == nil {
                    let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
                    let answered = snapshot["messages"]?.array?.contains {
                        $0.object?["role"]?.string == "assistant" && $0.object?["text"]?.string?.contains("completed " + chat.id + " 中文🙂") == true
                    } == true
                    if snapshot["state"]?.string == "idle", answered { completedSnapshots[chat.id] = snapshot }
                }
                if completedSnapshots.count == 20 { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        heartbeat.cancel(); await heartbeat.value
        XCTAssertGreaterThan(heartbeatSamples, 0, "The MainActor must make progress during concurrent streaming")
        XCTAssertEqual(model.opened.count, 20); XCTAssertEqual(model.hosts.count, 1)
        XCTAssertEqual(completedSnapshots.count, 20, "Initial idle snapshots must not count as completed turns")
        // Capture notifications must populate hidden sessions' totals without
        // a manual accounting refresh or selecting each conversation.
        let accountingDeadline = Date().addingTimeInterval(5)
        while Date() < accountingDeadline,
              model.displays.values.contains(where: { $0.footer.gateway.requests != 2 || $0.footer.gateway.tokens?.total != 220 || $0.footer.gateway.costUSD == nil }) || !model.accountingTasks.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        for chat in model.chats {
            let view = try XCTUnwrap(model.displays[chat.id])
            XCTAssertNil(view.sendFailure, chat.id); XCTAssertFalse(view.loading, chat.id)
            if interaction?.composingSessionID == chat.id { XCTAssertTrue(view.draft.hasPrefix("输入"), "The concurrent input stays in its draft") }
            else { XCTAssertEqual(view.draft, "", chat.id) }
            XCTAssertEqual(view.state, "idle", chat.id)
            let snapshot = try XCTUnwrap(completedSnapshots[chat.id])
            XCTAssertEqual(snapshot["state"]?.string, "idle", chat.id)
            let messages = snapshot["messages"]?.array ?? []
            XCTAssertTrue(messages.contains { $0.object?["text"]?.string?.contains("contents for " + chat.id) == true }, "Each session must read its own real file")
            XCTAssertTrue(messages.contains { $0.object?["text"]?.string?.contains("completed " + chat.id + " 中文🙂") == true }, chat.id)
            XCTAssertEqual(view.footer.gateway.requests, 2, chat.id)
            XCTAssertEqual(view.footer.gateway.tokens?.total, 220, chat.id)
            XCTAssertEqual(try XCTUnwrap(view.footer.gateway.costUSD), 0.002, accuracy: 0.0000001, chat.id)
            XCTAssertEqual(view.footer.gatewayNotice, "", chat.id)
        }
        let (stateBytes, _) = try await URLSession.shared.data(from: URL(string: base + "/state")!)
        let state = try JSONDecoder().decode([String: WireValue].self, from: stateBytes)
        XCTAssertEqual(state["peakHTTP"]?.number, 20)
        XCTAssertEqual(state["active"]?.number, 0)
        XCTAssertEqual(state["waves"]?.object?["1"]?.number, 20)
        XCTAssertEqual(state["waves"]?.object?["2"]?.number, 20)
        XCTAssertEqual(state["requests"]?.number, 40)
        XCTAssertEqual(state["textDeltas"]?.number, 660)
        XCTAssertEqual(state["errors"]?.array, []); XCTAssertEqual(state["cancelled"]?.array, [])
        let monitoringDeadline = Date().addingTimeInterval(5)
        while model.liveActivity.accumulator.completions.count < 40, Date() < monitoringDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.liveActivity.accumulator.completions.count, 40, "The hidden popup feed observes each real attempt exactly once")
        XCTAssertTrue(model.liveActivity.accumulator.active.isEmpty)
        XCTAssertEqual(model.liveActivity.publications, 0, "Concurrent ingestion must not publish into a hidden popup")
        let (capturedBytes, _) = try await URLSession.shared.data(from: URL(string: base + "/captures")!)
        let captures = try JSONDecoder().decode([[String: WireValue]].self, from: capturedBytes)
        XCTAssertEqual(captures.count, 40)

        // Reopen the native database after helper shutdown, so exact-byte
        // comparisons exercise durable bodies rather than live writer buffers.
        model.shutdown()
        for host in model.hosts.values { try await host.shutdownAndWait() }
        try await model.traces.close()
        try await model.traces.configure(key: config.captureKey, quota: config.capture.quotaBytes,
                                         bodyRetention: 604800, metricRetention: 7776000)
        var matchedAttempts = Set<String>()
        for chat in model.chats {
            let attempts = try await model.traces.list(sessionID: chat.id)
            XCTAssertEqual(attempts.count, 2, chat.id)
            for metadata in attempts {
                let id = try XCTUnwrap(metadata["attemptId"]?.string)
                XCTAssertTrue(matchedAttempts.insert(id).inserted)
                XCTAssertEqual(metadata["outcome"]?.string, "completed")
                XCTAssertNil(metadata["persistenceError"]?.string)
                XCTAssertEqual(metadata["requestHeaders"]?.object?["x-session-id"]?.string, chat.id)
                XCTAssertEqual(metadata["requestHeaders"]?.object?["authorization"]?.string, "Bearer ********cret")
                let request = try await model.traces.completeBody(attemptID: id, body: "request")
                let response = try await model.traces.completeBody(attemptID: id, body: "response")
                let matches = captures.filter { Data(base64Encoded: $0["request"]?.string ?? "") == request }
                XCTAssertEqual(matches.count, 1)
                let observed = try XCTUnwrap(matches.first)
                XCTAssertEqual(observed["session"]?.string, chat.id)
                XCTAssertEqual(response, Data(base64Encoded: try XCTUnwrap(observed["response"]?.string)))
                for kind in ["request", "response"] {
                    XCTAssertEqual(metadata[kind]?.object?["state"]?.string, "complete")
                    XCTAssertEqual(metadata[kind]?.object?["storage"]?.string, "plaintext-v2")
                }
            }
        }
        XCTAssertEqual(matchedAttempts.count, 40)
        let statistics = try await model.traces.statistics(); XCTAssertEqual(statistics["attempts"], 40)
        print(String(format: "CONCURRENCY nativeSend=20 peakHTTP=20 toolRoundTrips=20 streamedTextEvents=660 exactDurableBodies=80 elapsed=%.3fs MainActorHeartbeatSamples=%d maximumGapMs=%.2f", ProcessInfo.processInfo.systemUptime - started, heartbeatSamples, maximumHeartbeatGap * 1000))
    }

    @MainActor func testPackagedSwiftHelperCapturesResponsesPortableAndPinnedToolsIntoNativePlaintextArchive() async throws {
        let folder = URL(fileURLWithPath: testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture file contents".utf8).write(to: folder.appendingPathComponent("README.md"))
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("scripts/test-native-host.py").path, "--serve"]
        fixture.currentDirectoryURL = folder; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let value = try JSONDecoder().decode([String: Int].self, from: greeting)
        let port = try XCTUnwrap(value["port"]), base = "http://127.0.0.1:\(port)"
        let workspace = WorkspaceRecord(id: "capture-fixture", path: folder.path, trusted: true)
        let connections = ["portable", "pinned"].map { policy -> VaultProfile in
            var profile = ProfileRecord(); profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "strict-" + policy
            profile.modelOutputLimit = 4096   // the catalog ceiling: what the request carries, and what the strict fixture expects
            var routing: [String: WireValue] = ["replayPolicy": .string(policy), "reference": .string("strict-v1"), "cacheHeader": .string("x-fixture-cache")]
            if policy == "pinned" { routing["expectedModel"] = .string("fixture-fixed"); routing["replayContract"] = .string("Fixture route fixes exact compatible provider items") }
            profile.advancedJSON = WireValue.object(["routing": .object(routing)]).pretty
            return VaultProfile(profile: profile, apiKey: "fixture-secret", headers: ["X-Fixture-Contract": "strict-v1"])
        }
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let config = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = connections
            $0.resources[workspace.id] = .object(["codexHome": .string(folder.appendingPathComponent("codex").path)])
        }
        XCTAssertEqual(config.capture.defaultMode, "persist", "The packaged helper path must retain bodies without a capture opt-in")
        XCTAssertEqual(config.capture.retentionDays, 30)
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        var sessionIDs: [String] = []
        for connection in connections {
            let id = UUID().uuidString; sessionIDs.append(id)
            let chat = ChatRecord(id: id, workspaceID: workspace.id, title: "Synthetic capture fixture", path: nil, profileID: connection.profile.id)
            model.chats.append(chat); model.displays[id] = SessionDisplay(id: id)
            let host = try await model.open(chat)
            _ = try await host.request("turn.submit", sessionID: id, params: ["clientTurnId": .string(UUID().uuidString), "text": .string("fixture: read README.md")])
            var snapshot: [String: WireValue] = [:]
            for _ in 0..<500 {
                snapshot = try await host.request("session.snapshot", sessionID: id).object ?? [:]
                if ["idle", "paused"].contains(snapshot["state"]?.string ?? "") { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(snapshot["state"]?.string, "idle", WireValue.object(snapshot).pretty)
            let attempts = try await model.traces.list(sessionID: id)
            XCTAssertEqual(attempts.count, 2)
            XCTAssertTrue(attempts.allSatisfy { $0["gateway"]?.object?["cost"]?.object?["status"]?.string == "reported" })
            XCTAssertTrue(attempts.allSatisfy { $0["gateway"]?.object?["cache"]?.object?["status"]?.string == "miss" })
            XCTAssertTrue(snapshot["messages"]?.array?.contains(where: { $0.object?["text"]?.string?.contains("fixture file contents") == true }) == true)
            for message in snapshot["messages"]?.array ?? [] {
                let messageID = try XCTUnwrap(message.object?["id"]?.string)
                let links = try await model.traces.list(sessionID: id, messageID: messageID)
                XCTAssertFalse(links.isEmpty, "Every retained user/assistant/tool message needs a request link")
            }
        }
        for host in model.hosts.values { try await host.shutdownAndWait() }
        let archiveRoot = await model.traces.root
        try await model.traces.close()
        let restored = PayloadArchive(root: archiveRoot)
        try await restored.configure(key: config.captureKey, quota: config.capture.quotaBytes, bodyRetention: 604800, metricRetention: 7776000)
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/captures")!)
        let observed = try JSONDecoder().decode([[String: String]].self, from: data)
        for sessionID in sessionIDs {
            for metadata in try await restored.list(sessionID: sessionID) {
                let id = try XCTUnwrap(metadata["attemptId"]?.string)
                var bodies: [String: Data] = [:]
                for kind in ["request", "response"] {
                    let length = Int(metadata[kind]?.object?["retainedBytes"]?.number ?? 0)
                    var bytes = Data()
                    while bytes.count < length { bytes.append(try await restored.body(attemptID: id, body: kind, offset: bytes.count)) }
                    XCTAssertEqual(metadata[kind]?.object?["state"]?.string, "complete")
                    XCTAssertEqual(metadata[kind]?.object?["storage"]?.string, "plaintext-v2")
                    bodies[kind] = bytes
                }
                let record = try XCTUnwrap(observed.first { Data(base64Encoded: $0["request"] ?? "") == bodies["request"] })
                XCTAssertEqual(Data(base64Encoded: record["response"]!), bodies["response"])
                XCTAssertEqual(metadata["requestHeaders"]?.object?["authorization"]?.string, "Bearer ********cret")
            }
        }
        let statistics = try await restored.statistics(); XCTAssertEqual(statistics["attempts"], 4)
        try await restored.close()
        await model.store?.close()
        // Close SQLite before removing its backing directory. If a thrown
        // assertion aborts earlier, preserve synthetic scratch for inspection.
        try FileManager.default.removeItem(at: folder)
    }
}
