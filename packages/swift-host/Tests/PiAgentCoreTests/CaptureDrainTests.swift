import XCTest
@testable import PiAgentCore

private final class DrainPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSON] = [], cursor = 0
    func emit(_ frame: JSON) { if frame["kind"].text == "capture" { lock.lock(); frames.append(frame); lock.unlock() } }
    func next() -> JSON? {
        lock.lock(); defer { lock.unlock() }
        guard cursor < frames.count else { return nil }
        defer { cursor += 1 }; return frames[cursor]
    }
    var packets: [JSON] { lock.lock(); defer { lock.unlock() }; return frames.map { $0["packet"] } }
}
private actor DrainFlag {
    var done = false
    func finish() { done = true }
}
private actor HeldDrainConsumer {
    var packets: [JSON] = []
    var held = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func accept(_ packet: JSON) async -> Bool {
        packets.append(packet)
        if packets.count == 1, !released {
            held = true
            await withCheckedContinuation { waiter = $0 }
        }
        return true
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

final class CaptureDrainTests: HelperTestCase {
    func testLargeMetadataPagesAreOrderedAndWaitForFinalRetention() async throws {
        let packets = DrainPackets(), done = DrainFlag()
        let delivery = CaptureDelivery(epoch: "fixture", emit: { packets.emit($0) })
        await delivery.enable()
        let packet: JSON = ["type": "finish", "metadata": ["usage": ["raw": JSON(String(repeating: "\u{01}🙂", count: 150_000))]]]
        let sending = Task { let accepted = await delivery.send(packet); await done.finish(); return accepted }
        var bytes = Data(), final = false, packetID: String?
        while !final {
            var frame: JSON?
            try await eventually { frame = packets.next(); return frame != nil }
            let value = try XCTUnwrap(frame), chunk = value["chunk"]
            XCTAssertLessThanOrEqual(try value.data().count, HostProtocol.frameBytes)
            XCTAssertEqual(chunk["offset"].int, bytes.count)
            if let packetID { XCTAssertEqual(chunk["packetId"].text, packetID) } else { packetID = chunk["packetId"].text }
            let page = try XCTUnwrap(Data(base64Encoded: chunk["bytes"].text ?? ""))
            XCTAssertLessThanOrEqual(page.count, 32 * 1024)
            bytes.append(page); final = chunk["final"].flag == true
            let finished = await done.done
            XCTAssertFalse(finished, "Returning before the last acknowledgement loses capture retention")
            await delivery.acknowledge(try XCTUnwrap(value["transferId"].text), accepted: true)
        }
        let accepted = await sending.value
        XCTAssertTrue(accepted); XCTAssertEqual(try JSON.parse(bytes), packet)
        await delivery.close()
    }

    func testRejectedMetadataChunkReleasesTheNextPacketWithoutSendingItsTail() async throws {
        let packets = DrainPackets(), delivery = CaptureDelivery(epoch: "fixture", emit: { packets.emit($0) })
        await delivery.enable()
        let first = Task { await delivery.send(["type": "finish", "metadata": JSON(String(repeating: "x", count: 1_100_000))]) }
        var frame: JSON?
        try await eventually { frame = packets.next(); return frame != nil }
        let second = Task { await delivery.send(["type": "finish", "metadata": [:]]) }
        await delivery.acknowledge(try XCTUnwrap(frame?["transferId"].text), accepted: false)
        let accepted = await first.value
        XCTAssertFalse(accepted)
        try await eventually { frame = packets.next(); return frame != nil }
        XCTAssertEqual(frame?["packet"]["type"].text, "finish")
        await delivery.acknowledge(try XCTUnwrap(frame?["transferId"].text), accepted: true)
        let nextAccepted = await second.value
        XCTAssertTrue(nextAccepted)
        await delivery.close()
    }

    func testShutdownDrainsQueuedPagesWhileAcceptingAcknowledgments() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gateway, root: root); defer { gateway.stop() }
        let packets = DrainPackets(), service = NativeHostService(emit: { packets.emit($0) })
        await service.receive(["v": 1, "kind": "hello", "major": 1])
        let directory = root.appendingPathComponent("state")
        _ = try await service.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(directory.path), "captureProtocol": 1])
        var profile = try fixtureProfile().raw; profile["baseUrl"] = JSON(gateway.base + "/v1")
        _ = try await service.command("session.open", sessionID: "s", params: ["profile": profile, "apiKey": "fixture-secret", "captureMode": "persist"])
        _ = try await service.command("turn.submit", sessionID: "s", params: ["clientTurnId": "t", "text": JSON(String(repeating: "Question ", count: 10_000))])
        try await eventually {
            let state = try? await service.command("session.snapshot", sessionID: "s", params: [:])
            return state?["state"].text == "idle" && state?["messages"].list.contains { $0["role"].text == "assistant" } == true
        }
        XCTAssertEqual(packets.packets.count, 1)
        let done = DrainFlag(), epoch = await service.epoch
        let consumer = Task {
            while !(await done.done) {
                try? await Task.sleep(for: .milliseconds(10))
                if let frame = packets.next() {
                    await service.receive(["v": 1, "kind": "capture.ack", "hostEpoch": JSON(epoch), "transferId": frame["transferId"], "accepted": true])
                }
            }
        }
        await service.shutdown()
        await done.finish(); await consumer.value
        for kind in ["request", "response"] {
            var actual = Data()
            for packet in packets.packets where packet["type"].text == "bytes" && packet["body"].text == kind {
                XCTAssertEqual(packet["offset"].int, actual.count)
                actual.append(try XCTUnwrap(Data(base64Encoded: packet["bytes"].text ?? "")))
            }
            XCTAssertEqual(actual, try Data(contentsOf: root.appendingPathComponent(kind + ".bin")))
        }
        XCTAssertEqual(packets.packets.filter { $0["type"].text == "finish" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".capture-outbox").path))
    }

    func testUnacknowledgedShutdownUsesOnlyTheExistingGracePeriod() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gateway, root: root); defer { gateway.stop() }
        let packets = DrainPackets(), service = NativeHostService(emit: { packets.emit($0) })
        await service.receive(["v": 1, "kind": "hello", "major": 1])
        let directory = root.appendingPathComponent("state")
        _ = try await service.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(directory.path), "captureProtocol": 1])
        var profile = try fixtureProfile().raw; profile["baseUrl"] = JSON(gateway.base + "/v1")
        _ = try await service.command("session.open", sessionID: "s", params: ["profile": profile, "apiKey": "fixture-secret", "captureMode": "persist"])
        _ = try await service.command("turn.submit", sessionID: "s", params: ["clientTurnId": "t", "text": JSON(String(repeating: "Question ", count: 10_000))])
        try await eventually {
            let state = try? await service.command("session.snapshot", sessionID: "s", params: [:])
            return state?["state"].text == "idle" && state?["messages"].list.contains { $0["role"].text == "assistant" } == true
        }
        XCTAssertEqual(packets.packets.count, 1)
        let done = DrainFlag(), epoch = await service.epoch
        // A release after the allowed grace makes a missing deadline fail in
        // finite time instead of hanging the test process.
        let lateConsumer = Task {
            try? await Task.sleep(for: .seconds(4))
            while !(await done.done) {
                if let frame = packets.next() {
                    await service.receive(["v": 1, "kind": "capture.ack", "hostEpoch": JSON(epoch), "transferId": frame["transferId"], "accepted": true])
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        await service.shutdown()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        await done.finish(); await lateConsumer.value
        XCTAssertGreaterThan(elapsed, 3, "Give the consumer the graceful drain window")
        XCTAssertLessThan(elapsed, 3.5, "Finish capture draining before the app's unchanged SIGTERM deadline")
        XCTAssertEqual(packets.packets.count, 1, "Never send a terminal completion after an undelivered page")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".capture-outbox").path))
        print("CAPTURE unacknowledgedShutdown elapsed=\(elapsed) emittedPackets=\(packets.packets.count)")
    }

    func testClearWaitsForAlreadyQueuedCaptureBeforeReleasingItsBodies() async throws {
        let sink = HeldDrainConsumer(), traces = TraceStore(sink: { await sink.accept($0) })
        _ = try await traces.command("debug.mode", session: "s", params: ["mode": "persist"])
        let bytes = Data(repeating: 97, count: 65_536)
        let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: bytes, headers: [:])
        await traces.append(id, data: bytes)
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        try await eventually { await sink.held }
        let cleared = DrainFlag()
        let clearing = Task { let result = try await traces.command("debug.clear", session: "s", params: [:]); await cleared.finish(); return result }
        try await Task.sleep(for: .milliseconds(50))
        let early = await cleared.done
        XCTAssertFalse(early, "A clear cannot report success before an in-flight begin/body can reach the archive")
        await sink.release()
        _ = try await clearing.value
        let delivered = await sink.packets
        XCTAssertEqual(delivered.filter { $0["type"].text == "finish" }.count, 1, "The archive writer must be settled before native clear")
        let remaining = try await traces.command("debug.list", session: "s", params: [:])
        XCTAssertEqual(remaining["total"].int, 0)
        XCTAssertEqual(remaining["workspaceRetainedBytes"].int, 0)
    }

    func testWorkspaceOpenDiscardsRetiredSpoolFilesWithoutReplayingThem() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), retired = state.appendingPathComponent(".capture-outbox")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data("{\"type\":\"begin\",\"metadata\":{\"attemptId\":\"\(id)\",\"sessionId\":\"deleted\"}}\n".utf8).write(to: retired.appendingPathComponent(id + ".jsonl"))
        let packets = DrainPackets(), service = NativeHostService(emit: { packets.emit($0) })
        await service.receive(["v": 1, "kind": "hello", "major": 1])
        _ = try await service.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(state.path), "captureProtocol": 1])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        XCTAssertTrue(packets.packets.isEmpty, "An unacknowledged old begin cannot recreate a cleared capture")
        await service.shutdown()
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
