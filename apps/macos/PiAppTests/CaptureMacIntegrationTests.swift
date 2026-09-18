import XCTest
import Foundation
import CryptoKit
@testable import PiApp

final class CaptureMacIntegrationTests: XCTestCase {
    @MainActor func testPackagedSwiftHelperCapturesResponsesPortableAndPinnedToolsIntoNativePlaintextArchive() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_BUILD_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
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
