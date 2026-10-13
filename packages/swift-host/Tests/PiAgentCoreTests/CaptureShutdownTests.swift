import XCTest
@testable import PiAgentCore

private final class ShutdownPackets: @unchecked Sendable {
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

final class CaptureShutdownTests: XCTestCase {
    func testShutdownWithAHeldCaptureAckReplaysEveryByteAndTerminalRecord() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gateway, root: root); defer { gateway.stop() }
        let directory = root.appendingPathComponent("state"), firstPackets = ShutdownPackets()
        let first = NativeHostService(emit: { firstPackets.emit($0) })
        await first.receive(["v": 1, "kind": "hello", "major": 1])
        let workspace: JSON = ["cwd": JSON(root.path), "directory": JSON(directory.path), "captureProtocol": 1]
        _ = try await first.command("workspace.open", sessionID: nil, params: workspace)
        var profile = try fixtureProfile().raw; profile["baseUrl"] = JSON(gateway.base + "/v1")
        _ = try await first.command("session.open", sessionID: "s", params: ["profile": profile, "apiKey": "synthetic-api-secret-z23", "captureMode": "persist"])
        _ = try await first.command("turn.submit", sessionID: "s", params: ["clientTurnId": "t", "text": JSON(String(repeating: "Question ", count: 10_000))])
        try await eventually {
            let state = try? await first.command("session.snapshot", sessionID: "s", params: [:])
            return state?["state"].text == "idle" && state?["messages"].list.contains { $0["role"].text == "assistant" } == true
        }
        XCTAssertEqual(firstPackets.packets.count, 1, "The owner is still holding the first ACK")
        let started = ContinuousClock.now
        await first.shutdown()
        XCTAssertLessThan(started.duration(to: .now), .seconds(3), "Shutdown cannot wait indefinitely for capture ACKs")

        let restoredPackets = ShutdownPackets(), restored = NativeHostService(emit: { restoredPackets.emit($0) })
        await restored.receive(["v": 1, "kind": "hello", "major": 1])
        _ = try await restored.command("workspace.open", sessionID: nil, params: workspace)
        addTeardownBlock { await restored.shutdown() }
        let epoch = await restored.epoch
        try await eventually {
            while let frame = restoredPackets.next() {
                await restored.receive(["v": 1, "kind": "capture.ack", "hostEpoch": JSON(epoch), "transferId": frame["transferId"], "accepted": true])
            }
            let packets = restoredPackets.packets
            let files=(try? FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent(".capture-outbox").path)) ?? ["unavailable"]
            return packets.contains { $0["type"].text == "replay.end" } && files.isEmpty
        }
        let packets = restoredPackets.packets
        for kind in ["request", "response"] {
            let expected = try Data(contentsOf: root.appendingPathComponent(kind + ".bin"))
            var actual = Data()
            for packet in packets where packet["type"].text == "bytes" && packet["body"].text == kind {
                XCTAssertEqual(packet["offset"].int, actual.count)
                actual.append(try XCTUnwrap(Data(base64Encoded: packet["bytes"].text ?? "")))
            }
            XCTAssertEqual(actual, expected, kind)
            XCTAssertGreaterThan(actual.count, 65_536)
        }
        XCTAssertEqual(packets.first?["type"].text, "replay.begin")
        XCTAssertEqual(packets.first { $0["type"].text == "finish" }?["metadata"]["outcome"].text, "completed")
        XCTAssertFalse(packets.filter { $0["type"].text == "events" }.flatMap { $0["events"].list }.isEmpty)
        XCTAssertFalse(packets.flatMap { $0["outputMessageIds"].list }.isEmpty)
        await restored.shutdown()
        let thirdPackets = ShutdownPackets(), third = NativeHostService(emit: { thirdPackets.emit($0) })
        await third.receive(["v": 1, "kind": "hello", "major": 1])
        _ = try await third.command("workspace.open", sessionID: nil, params: workspace)
        await third.shutdown()
        XCTAssertTrue(thirdPackets.packets.isEmpty, "An acknowledged recovery is not replayed again")
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
