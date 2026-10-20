import XCTest
import Darwin
@testable import PiApp

private actor DrainArchiveConsumer {
    let archive: PayloadArchive
    let holdBegin: Bool
    var held = false, released = false, finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ archive: PayloadArchive, holdBegin: Bool = false) { self.archive = archive; self.holdBegin = holdBegin }
    func accept(_ packet: [String: WireValue]) async throws {
        let hold = holdBegin ? packet["type"]?.string == "begin" :
            packet["type"]?.string == "bytes" && packet["body"]?.string == "response" && (packet["offset"]?.number ?? 0) >= 32_768
        if hold, !released {
            held = true
            await withCheckedContinuation { waiter = $0 }
        }
        try await Task.sleep(for: .milliseconds(10))
        try await archive.accept(packet, workspace: "w")
        if packet["type"]?.string == "finish" { finished = true }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

final class CaptureDrainTests: XCTestCase, SerialTestLane {
    @MainActor func testSlowConsumerArchivesEveryQueuedByteBeforeGracefulExit() async throws {
        try await shutdownFixture(pastDeadline: false)
    }
    @MainActor func testLargeMetadataReachesTheArchiveWithoutTruncation() async throws {
        try await shutdownFixture(pastDeadline: false, largeMetadata: true)
    }
    @MainActor func testDeadlineLeavesAnInterruptedPartialBodyBeforeReportingExit() async throws {
        try await shutdownFixture(pastDeadline: true)
    }
    @MainActor func testClearingWhileHelperStopsCannotBeUndoneByAnInFlightBegin() async throws {
        try await shutdownFixture(pastDeadline: false, clearDuringStop: true)
    }
    @MainActor func testKilledHelperStopsAcceptingCommandsBeforeCaptureFinalization() async throws {
        try await shutdownFixture(pastDeadline: false, crashDuringCapture: true)
    }
    @MainActor private func shutdownFixture(pastDeadline: Bool, clearDuringStop: Bool = false, crashDuringCapture: Bool = false, largeMetadata: Bool = false) async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("capture-drain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if !clearDuringStop { try? FileManager.default.removeItem(at: root) } }
        let script = root.appendingPathComponent("gateway.py")
        let source = largeMetadata ? Self.gateway
            .replacingOccurrences(of: "body = b''.join(b'data: ' + json.dumps(f).encode() + b'\\n\\n' for f in frames)",
                                  with: "frames[-1]['response']['usage']['vendor_details'] = 'v' * 5_000_000\n        body = json.dumps(frames[-1]['response']).encode()")
            .replacingOccurrences(of: "'text/event-stream'", with: "'application/json'") : Self.gateway
        try source.write(to: script, atomically: true, encoding: .utf8)
        let gateway = Process()
        gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); gateway.arguments = ["-u", script.path, root.path]
        gateway.standardOutput = FileHandle.nullDevice; gateway.standardError = FileHandle.nullDevice
        try gateway.run()
        defer { if gateway.isRunning { gateway.terminate(); gateway.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: ready))["port"])
        let model = clearDuringStop ? WorkspaceModel(stateRoot: root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage())) : nil
        if let model {
            registerWorkspaceFixtureTeardown(model, root: root)
            try await model.reloadConfiguration()
            model.chats = [ChatRecord(id: "s", workspaceID: "w", title: "Fixture", path: nil, profileID: "test")]
            model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        }
        let archive = model?.traces ?? PayloadArchive(root: root.appendingPathComponent("archive"))
        let consumer = DrainArchiveConsumer(archive, holdBegin: clearDuringStop)
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        let state = root.appendingPathComponent("state"), host = HostSupervisor(acknowledgmentTimeout: crashDuringCapture ? .milliseconds(200) : nil)
        defer { host.shutdown() }
        try await host.connect(cwd: root, state: state, capture: { try await consumer.accept($0) })
        _ = try await host.request("workspace.open", params: ["cwd": .string(root.path), "directory": .string(state.appendingPathComponent("Sessions").path), "captureProtocol": .number(1),
            "resources": .object(["skills": .bool(false), "codexHome": .string(root.appendingPathComponent("empty-codex").path)])])
        let profile: [String: WireValue] = ["id": .string("test"), "revision": .string("1"), "providerId": .string("litellm"), "modelId": .string("fixture-model"), "api": .string("openai-responses"),
            "baseUrl": .string("http://127.0.0.1:\(port)/v1"), "contextWindow": .number(100000), "maxOutputTokens": .number(4096), "reasoning": .bool(true), "thinkingLevel": .string("default")]
        _ = try await host.request("session.open", sessionID: "s", params: ["profile": .object(profile), "apiKey": .string("fixture-secret"), "captureMode": .string("persist")])
        _ = try await host.request("turn.submit", sessionID: "s", params: ["clientTurnId": .string("t"), "text": .string(String(repeating: "Question ", count: 10_000))])
        try await eventually(timeout: largeMetadata ? 60 : 10) {
            let snapshot = try await host.request("session.snapshot", sessionID: "s").object ?? [:]
            return snapshot["state"]?.string == "idle" && snapshot["messages"]?.array?.contains { $0.object?["role"]?.string == "assistant" } == true
        }
        try await eventually { await consumer.held }
        if crashDuringCapture {
            try await checkCrash(host: host, root: root, state: state, consumer: consumer, archive: archive)
            return
        }
        let release = Task {
            try await Task.sleep(for: .milliseconds(pastDeadline ? 4_000 : 50))
            await consumer.release()
        }
        var clearFinished = false
        let clearing: Task<Void, Error>?
        if let model {
            model.hosts["w"] = host; host.shutdown()
            clearing = Task { try await model.clearCaptures(sessionID: "s"); clearFinished = true }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(clearFinished, "A stopping helper still owns an unacknowledged begin")
        } else { clearing = nil }
        let start = ProcessInfo.processInfo.systemUptime
        if largeMetadata { try await eventually(timeout: 60) { await consumer.finished } }
        try await host.shutdownAndWait()
        try await clearing?.value
        if clearDuringStop {
            try await release.value
            let remaining = try await archive.statistics()
            XCTAssertEqual(remaining["chunks"], 0); XCTAssertEqual(remaining["storedBytes"], 0)
            let attempts = try await archive.list(sessionID: "s")
            XCTAssertTrue(attempts.allSatisfy { $0["request"]?.object?["state"]?.string == "purged" })
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let attempts = try await archive.list(sessionID: "s")
        let metadata = try XCTUnwrap(attempts.first)
        let id = try XCTUnwrap(metadata["attemptId"]?.string)
        if pastDeadline {
            XCTAssertEqual(metadata["outcome"]?.string, "interrupted")
            XCTAssertEqual(metadata["response"]?.object?["state"]?.string, "partial")
            let retained = metadata["response"]?.object?["retainedBytes"]?.number ?? 0
            XCTAssertGreaterThan(retained, 0)
            XCTAssertLessThan(retained, Double(try Data(contentsOf: root.appendingPathComponent("response.bin")).count))
            XCTAssertLessThan(elapsed, 6, "The existing shutdown wait remains bounded")
        } else {
            XCTAssertEqual(metadata["outcome"]?.string, "completed")
            if largeMetadata { XCTAssertEqual(metadata["usage"]?.object?["raw"]?.object?["vendor_details"]?.string?.count, 5_000_000) }
            for body in ["request", "response"] {
                XCTAssertEqual(metadata[body]?.object?["state"]?.string, "complete")
                let actual = try await archive.completeBody(attemptID: id, body: body)
                XCTAssertEqual(actual, try Data(contentsOf: root.appendingPathComponent(body + ".bin")))
            }
        }
        print("CAPTURE gracefulShutdown pastDeadline=\(pastDeadline) elapsed=\(elapsed) responseRetained=\(metadata["response"]?.object?["retainedBytes"]?.number ?? 0)")
        try await release.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("Sessions/.capture-outbox").path))
        if largeMetadata {
            try await archive.close()
            let reopened = PayloadArchive(root: root.appendingPathComponent("archive"))
            try await reopened.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
            let saved = try await reopened.metadata(attempt: id)
            XCTAssertEqual(saved["usage"]?.object?["raw"]?.object?["vendor_details"]?.string, String(repeating: "v", count: 5_000_000))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("export"), withIntermediateDirectories: true)
            let exported = try await reopened.exportRetained(sessionID: "s", attemptID: id, destination: root.appendingPathComponent("export"))
            for body in ["request", "response"] {
                let actual = try await reopened.completeBody(attemptID: id, body: body)
                XCTAssertEqual(actual, try Data(contentsOf: root.appendingPathComponent(body + ".bin")))
                XCTAssertEqual(actual, try Data(contentsOf: exported.appendingPathComponent(body + ".bin")))
            }
            let manifest = try JSONDecoder().decode([String: WireValue].self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
            XCTAssertEqual(manifest["usage"], saved["usage"])
            try await reopened.close()
            // Exercise both metadata migrations on the accepted large record.
            let db = try CaptureDatabase(url: root.appendingPathComponent("archive/requests.sqlite"))
            try db.execute("DELETE FROM archive_info WHERE name='dashboard-projection'")
            try PayloadArchive.prepareDashboardSchema(db, migrate: true)
            try PayloadArchive.prepareDashboardSchema(db, migrate: true)
            try CaptureLineage.prepare(db, migrate: true)
            try CaptureLineage.prepare(db, migrate: true)
            let future = Date().addingTimeInterval(8 * 86400)
            let expired = PayloadArchive(root: root.appendingPathComponent("archive"), now: { future })
            try await expired.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
            let statistics = try await expired.statistics()
            XCTAssertEqual(statistics["expiredRequests"], 1); XCTAssertEqual(statistics["chunks"], 0)
            let bytes = Data("Generated capture after expiry".utf8)
            let sibling: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string("sibling"), "turnId": .string("t"),
                "mode": .string("persist"), "outcome": .string("completed"), "timingVersion": .number(2), "timings": .object(["dispatch": .number(1)]),
                "request": .object(["observedBytes": .number(Double(bytes.count))])]
            try await expired.begin(sibling, workspace: "w")
            try await expired.append(attempt: sibling["attemptId"]!.string!, kind: "request", offset: 0, bytes: bytes)
            try await expired.finish(sibling)
            let body = try await expired.completeBody(attemptID: sibling["attemptId"]!.string!, body: "request")
            XCTAssertEqual(body, bytes)
            let report = try await expired.dashboard(DashboardFilter(from: future.addingTimeInterval(-9 * 86400), until: future.addingTimeInterval(1)))
            XCTAssertEqual(report.requests.map(\.id), [sibling["attemptId"]!.string!])
            try await expired.close()
            return
        }
        try await archive.clear(sessionID: "s")
        let remaining = try await archive.statistics()
        XCTAssertEqual(remaining["chunks"], 0); XCTAssertEqual(remaining["storedBytes"], 0)
        try await archive.close()
    }

    @MainActor private func checkCrash(host: HostSupervisor, root: URL, state: URL, consumer: DrainArchiveConsumer, archive: PayloadArchive) async throws {
        let connection = try XCTUnwrap(host.connectionID), pid = try XCTUnwrap(host.helperProcessIdentifier)
        let lost = expectation(description: "Command channel loss precedes the stalled archive")
        var losses = 0
        host.onLoss = { losses += 1; if losses == 1 { lost.fulfill() } }
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        await fulfillment(of: [lost], timeout: 1)
        XCTAssertFalse(host.isReady, "A dead helper must not stay ready behind a capture callback")
        XCTAssertEqual(host.connectionID, connection, "Retain capture ownership until finalization finishes")
        XCTAssertThrowsError(try WorkspaceLock(url: state.appendingPathComponent("writer.lock")))
        for method in ["turn.submit", "turn.edit"] {
            do {
                _ = try await host.request(method, sessionID: "s", params: ["clientTurnId": .string(UUID().uuidString), "text": .string("After the crash"), "messageId": .string("m")])
                XCTFail("A dead command channel must reject this submission")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Host is unavailable"), "Refuse before dispatch, without an uncertain acknowledgment timeout: \(error)")
            }
        }
        var reconnected = false, cleared = false, stopped = false
        let reconnecting = Task {
            try await host.connect(cwd: root, state: state, capture: { try await consumer.accept($0) })
            reconnected = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(reconnected, "connect() must not reuse the dead connection or replace its capture owner")
        reconnecting.cancel()
        let clearing = Task { try await host.settleCaptureIfStopping(); cleared = true }
        let stopping = Task { try await host.shutdownAndWait(); stopped = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(cleared, "Clear must still wait for capture finalization")
        XCTAssertFalse(stopped, "Shutdown must still wait for capture finalization")
        await consumer.release()
        try await clearing.value; try await stopping.value
        _ = await reconnecting.result
        XCTAssertNil(host.connectionID)
        let attempts = try await archive.list(sessionID: "s")
        XCTAssertEqual(attempts.first?["outcome"]?.string, "interrupted")
        XCTAssertEqual(attempts.first?["response"]?.object?["state"]?.string, "partial")
        try await host.connect(cwd: root, state: state, capture: { try await consumer.accept($0) })
        XCTAssertNotEqual(host.connectionID, connection)
        let info = try await host.request("runtime.info")
        XCTAssertEqual(info.object?["engine"]?.string, "swift", "A new connection works after capture settles")
        try await host.shutdownAndWait()
        try await archive.clear(sessionID: "s")
        let remaining = try await archive.statistics()
        XCTAssertEqual(remaining["chunks"], 0); XCTAssertEqual(remaining["storedBytes"], 0)
        try await archive.close()
    }

    @MainActor func testClearingWithStoppedHelperRemovesRetiredSpoolsAndArchivedBodies() async throws {
        try await clearFixture(delete: false)
    }
    @MainActor func testDeletingWithStoppedHelperRemovesRetiredSpoolsAndArchivedBodies() async throws {
        try await clearFixture(delete: true)
    }
    @MainActor private func clearFixture(delete: Bool) async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("clear-capture-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "s", workspaceID: "w", title: "Fixture", path: nil, profileID: "p")
        model.chats = [chat]; model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        let retired = root.appendingPathComponent("Workspaces/w/Sessions/.capture-outbox")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data("private captured body".utf8).write(to: retired.appendingPathComponent("unacknowledged.jsonl"))
        let id = UUID().uuidString
        let metadata: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("s"), "turnId": .string("t"), "mode": .string("persist"), "outcome": .string("completed"),
            "request": .object(["observedBytes": .number(6)]), "response": .object(["observedBytes": .number(0)])]
        try await model.traces.begin(metadata, workspace: "w")
        try await model.traces.append(attempt: id, kind: "request", offset: 0, bytes: Data("secret".utf8))
        try await model.traces.finish(metadata)
        XCTAssertTrue(model.hosts.isEmpty)
        if delete {
            model.questions.answer = { _ in true }
            model.deleteChat(chat.id)
            try await eventually { model.record(chat.id) == nil }
            XCTAssertNil(model.error)
        } else { try await model.clearCaptures(sessionID: "s") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        let remaining = try await model.traces.statistics()
        XCTAssertEqual(remaining["chunks"], 0); XCTAssertEqual(remaining["storedBytes"], 0)
    }

    @MainActor private func eventually(timeout: TimeInterval = 10, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostError.failure("Capture fixture did not reach the expected state")
    }

    private static let gateway = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        (root / 'request.bin').write_bytes(self.rfile.read(int(self.headers['Content-Length'])))
        text = 'Recovered answer. ' * 7000
        message = {'type':'message','id':'m1','role':'assistant','content':[{'type':'output_text','text':text}]}
        frames = [
            {'type':'response.created','response':{'id':'r1','status':'in_progress','output':[]}},
            {'type':'response.output_item.added','output_index':0,'item':{'type':'message','id':'m1','role':'assistant','content':[]}},
            {'type':'response.output_text.delta','output_index':0,'item_id':'m1','content_index':0,'delta':text},
            {'type':'response.completed','response':{'id':'r1','status':'completed','output':[message],'usage':{'input_tokens':100,'output_tokens':10}}}
        ]
        body = b''.join(b'data: ' + json.dumps(f).encode() + b'\n\n' for f in frames)
        (root / 'response.bin').write_bytes(body)
        self.send_response(200); self.send_header('Content-Type','text/event-stream')
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
server = http.server.HTTPServer(('127.0.0.1',0),Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port':server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#
}
