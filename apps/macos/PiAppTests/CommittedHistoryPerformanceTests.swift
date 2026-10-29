import XCTest
import CryptoKit
import Darwin
import Darwin.libproc
@testable import PiApp

/// Release-only measurements of helper-owned history pages on a generated
/// PERF-1 fixture. `PI_HIST_ROUTE=helper` makes this test host omit the
/// committed-history capability from its hello, so the same build measures
/// the helper's `session.history` path against the file path.
final class CommittedHistoryPerformanceTests: XCTestCase, SerialTestLane {
    @MainActor func testHelperOwnedOlderPages() async throws {
        try XCTSkipUnless(testEnvironment("PI_PERF_JOURNAL") != nil, "Requires a generated PERF-1 fixture")
        #if PI_RELEASE_TESTS
        let (root, path) = try trialClone()
        let helperRoute = testEnvironment("PI_HIST_ROUTE") == "helper"
        HostSupervisor.omitsCommittedHistoryHello = helperRoute
        addTeardownBlock { @MainActor in HostSupervisor.omitsCommittedHistoryHello = false }
        // Appends come from real turns against a generated loopback gateway.
        let gatewayRoot = root.appendingPathComponent("gateway")
        try FileManager.default.createDirectory(at: gatewayRoot, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repository.deleteLastPathComponent() }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [repository.appendingPathComponent("fixtures/native/history_append.py").path, gatewayRoot.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = gatewayRoot.appendingPathComponent("ready.json")
        try await eventually("Generated append gateway did not start", timeout: .seconds(30)) { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int])?["port"])
        let host = HostSupervisor(acknowledgmentTimeout: .seconds(180))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        XCTAssertEqual(host.supportsCommittedHistory, !helperRoute)
        _ = try await host.request("workspace.open", params: ["cwd": .string(root.path), "directory": .string(root.path), "mcp": .object(["servers": .object([:])])])
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "fixture"; profile.baseUrl = "http://127.0.0.1:\(port)/v1"
        // Generated appends must not start an automatic compaction.
        profile.contextWindow = 10_000_000; profile.advancedJSON = #"{"routing":{"replayPolicy":"portable"}}"#
        // The fixture is bound to an unused endpoint: move it to the gateway
        // first, as the app does for a chat moved to another connection.
        _ = try await host.request("session.rebind", sessionID: "long", params: ["path": .string(path.path), "profile": profile.wire])
        _ = try await host.request("session.open", sessionID: "long", params: ["profile": profile.wire, "apiKey": .string("synthetic-only"), "connectionTest": .bool(true), "path": .string(path.path)])
        let item = ChatRecord(id: "long", workspaceID: "history-perf", title: "Fixture", path: path.path, profileID: profile.id)
        model.chats = [item]; model.hosts[item.workspaceID] = host; model.opened.insert(item.id)
        let pid = try XCTUnwrap(host.helperProcessIdentifier)
        if let file = testEnvironment("PI_PERF_PID_FILE") { try JSONSerialization.data(withJSONObject: ["host": getpid(), "helper": pid]).write(to: URL(fileURLWithPath: file)) }
        let profiled = testEnvironment("PI_PERF_PROFILE_PAUSE") == "1" ? (testEnvironment("PI_HIST_PROFILE_PHASE") ?? "firstOlder") : nil
        var appended = 0
        func append(turns: Int) async throws {
            let before = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int ?? 0
            for turn in 0..<turns {
                _ = try await host.request("turn.submit", sessionID: "long", params: ["clientTurnId": .string("append-\(appended)-\(turn)"), "text": .string("Append generated history")])
                try await eventually("The generated append turn did not finish", timeout: .seconds(300), poll: .milliseconds(50)) {
                    let snapshot = try await host.request("session.snapshot", sessionID: "long")
                    return snapshot.object?["state"]?.string == "idle" && snapshot.object?["busy"]?.bool != true
                }
            }
            appended += (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int ?? 0) - before
        }
        let phases: [(name: String, turns: Int, start: Bool, position: Int?)] = [
            ("opening", 0, false, nil), ("firstOlder", 0, true, nil), ("nextOlder", 0, false, 2500),
            ("after1MB", 1, false, 2500), ("after10MB", 10, false, 2500)]
        for phase in phases {
            appended = 0
            if phase.turns > 0 { try await append(turns: phase.turns) }
            if phase.name == profiled {
                print("HIST136-PROFILE " + phase.name); fflush(nil)
                try await Task.sleep(for: .seconds(3))
            }
            let builds = await model.history.indexBuilds
            let beforeApp = usage(getpid()), beforeHelper = usage(pid), traffic = host.measuredWireBytes, started = ProcessInfo.processInfo.systemUptime
            let page = try await model.readConversationWindow(item, cursor: nil, start: phase.start, position: phase.position, followsNavigation: false, opening: phase.name == "opening")
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000, afterApp = usage(getpid()), afterHelper = usage(pid), endTraffic = host.measuredWireBytes
            let rebuilt = await model.history.indexBuilds - builds
            let result: [String: Any] = ["phase": phase.name, "route": helperRoute ? "helper" : "file", "ms": elapsed, "rows": page.messages.count, "start": page.start ?? -1, "total": page.total ?? -1,
                "first": page.messages.first?.id ?? "", "last": page.messages.last?.id ?? "", "incarnation": page.incarnation,
                "appCPU": afterApp.cpu - beforeApp.cpu, "helperCPU": afterHelper.cpu - beforeHelper.cpu,
                "appPeakMiB": afterApp.peak, "helperPeakMiB": afterHelper.peak, "appCurrentMiB": afterApp.current, "helperCurrentMiB": afterHelper.current,
                "ipcSent": endTraffic.sent - traffic.sent, "ipcReceived": endTraffic.received - traffic.received,
                "indexBuilds": rebuilt, "appendedBytes": appended]
            print("HIST136 " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); fflush(nil)
            XCTAssertFalse(page.messages.isEmpty)
        }
        try await host.shutdownAndWait()
        #else
        throw XCTSkip("H1 measurements require Release")
        #endif
    }

    /// The standalone journal reader's cold whole-journal index, without a
    /// helper: the first page of a fresh reader on a fresh clone.
    @MainActor func testStandaloneColdIndex() async throws {
        try XCTSkipUnless(testEnvironment("PI_PERF_JOURNAL") != nil, "Requires a generated PERF-1 fixture")
        #if PI_RELEASE_TESTS
        let (root, path) = try trialClone()
        let index = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        if let file = testEnvironment("PI_PERF_PID_FILE") { try JSONSerialization.data(withJSONObject: ["host": getpid()]).write(to: URL(fileURLWithPath: file)) }
        if testEnvironment("PI_PERF_PROFILE_PAUSE") == "1" {
            print("HIST136-PROFILE standaloneCold"); fflush(nil)
            try await Task.sleep(for: .seconds(3))
        }
        let reader = HistoryReader(indexDirectory: index)
        let before = usage(getpid()), started = ProcessInfo.processInfo.systemUptime
        let page = try await reader.window(path: path.path, start: true)
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000, after = usage(getpid())
        let result: [String: Any] = ["phase": "standaloneCold", "ms": elapsed, "rows": page.messages.count, "start": page.start ?? -1, "total": page.total,
            "first": page.messages.first?.id ?? "", "last": page.messages.last?.id ?? "", "appCPU": after.cpu - before.cpu,
            "appPeakMiB": after.peak, "appCurrentMiB": after.current, "indexBuilds": await reader.indexBuilds]
        print("HIST136 " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); fflush(nil)
        XCTAssertNil(page.notice); XCTAssertFalse(page.messages.isEmpty)
        await reader.releaseIndexes()
        #else
        throw XCTSkip("H1 measurements require Release")
        #endif
    }

    /// Every page of a generated fixture, read forward from its first row
    /// with a fresh reader, and pages at fixed positions: one digest of the
    /// rows, ranges, cursors and task records an index serves. Equal digests
    /// before and after an indexing change mean equal pages.
    @MainActor func testIndexedPagesDigest() async throws {
        try XCTSkipUnless(testEnvironment("PI_PERF_JOURNAL") != nil && testEnvironment("PI_HIST_DIGEST") == "1", "Requires a generated PERF-1 fixture")
        let (root, path) = try trialClone()
        let index = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let reader = HistoryReader(indexDirectory: index), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256(), pages = 0, rows = 0
        func add(_ page: HistoryPage) throws {
            pages += 1; rows += page.messages.count
            for message in page.messages {
                var row = message; row.imageReference = nil
                hash.update(data: try encoder.encode(row))
            }
            hash.update(data: Data("|\(page.start ?? -1)|\(page.total)|\(page.endsTurn)|\(page.partialTurnInput ?? "")|\(page.older?.entry ?? "")|\(page.newer?.entry ?? "")|\(page.lineage ?? "")|\(page.notice ?? "")\n".utf8))
            hash.update(data: try encoder.encode(page.taskRecords))
        }
        let started = ProcessInfo.processInfo.systemUptime
        var page = try await reader.window(path: path.path, start: true)
        try add(page)
        while let next = page.newer {
            page = try await reader.window(path: path.path, cursor: next, newer: true)
            try add(page)
        }
        let total = page.total
        for position in stride(from: 0, to: total, by: max(1, total / 64)) {
            try add(try await reader.window(path: path.path, position: position))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        print("HISTDIGEST " + String(decoding: try JSONSerialization.data(withJSONObject: ["digest": digest, "pages": pages, "rows": rows, "total": total,
            "seconds": ProcessInfo.processInfo.systemUptime - started], options: [.sortedKeys]), as: UTF8.self)); fflush(nil)
        await reader.releaseIndexes()
    }

    /// An APFS clone of the generated fixture (and its metadata file) in a
    /// trial directory of this build root, removed at teardown.
    @MainActor private func trialClone() throws -> (root: URL, path: URL) {
        let build = URL(fileURLWithPath: try XCTUnwrap(testEnvironment("PI_PERF_ROOT"))).resolvingSymlinksInPath()
        let source = URL(fileURLWithPath: try XCTUnwrap(testEnvironment("PI_PERF_JOURNAL"))).resolvingSymlinksInPath()
        guard source.path.hasPrefix(build.path + "/") else { throw XCTSkip("Fixture must be in this build root") }
        let root = build.appendingPathComponent("history-trial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat.jsonl")
        for suffix in ["", ".meta"] where FileManager.default.fileExists(atPath: source.path + suffix) {
            let clone = Process(); clone.executableURL = URL(fileURLWithPath: "/bin/cp")
            clone.arguments = ["-c", source.path + suffix, path.path + suffix]
            try clone.run(); clone.waitUntilExit(); XCTAssertEqual(clone.terminationStatus, 0)
        }
        return (root, path)
    }
    private func usage(_ pid: Int32) -> (cpu: Double, peak: Double, current: Double) {
        var value = rusage_info_v4(), timebase = mach_timebase_info_data_t()
        let status = withUnsafeMutablePointer(to: &value) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        guard status == 0 else { return (0, 0, 0) }
        mach_timebase_info(&timebase)
        return (Double(value.ri_user_time + value.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9,
                Double(value.ri_lifetime_max_phys_footprint) / 1_048_576, Double(value.ri_phys_footprint) / 1_048_576)
    }
}
