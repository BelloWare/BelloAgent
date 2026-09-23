import XCTest
@testable import PiAgentCore

/// The decode span a settled tokens-per-second rate divides by. A reasoning
/// model's reported output includes its hidden reasoning, so the span must
/// start when the model started generating (its first output item), not at
/// the first visible token; and a reply delivered in one burst has no
/// measurable span at all.
final class DecodeSpanTests: XCTestCase {
    /// Hidden reasoning for 0.8 s (the reasoning item opens at once), then a
    /// visible reply and the terminal event 0.06 s later: 860 output tokens,
    /// 800 of them reasoning. Model "burst" sends everything in one write.
    static let gatewayScript = #"""
import http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
def frame(value): return b'data: ' + json.dumps(value).encode() + b'\n\n'
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        burst = body['model'] == 'burst'
        reasoning = {'type':'reasoning','id':'rs1','summary':[],'encrypted_content':'opaque'}
        message = {'type':'message','id':'m1','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Done.'}]}
        usage = {'input_tokens':10,'output_tokens':860,'output_tokens_details':{'reasoning_tokens':800}}
        steps = [
            (frame({'type':'response.created','response':{'id':'r1','status':'in_progress','output':[]}}), 0.1),
            (frame({'type':'response.output_item.added','output_index':0,'item':{'type':'reasoning','id':'rs1','summary':[]}}), 0.8),
            (frame({'type':'response.output_item.done','output_index':0,'item':reasoning})
             + frame({'type':'response.output_item.added','output_index':1,'item':{'type':'message','id':'m1','role':'assistant','content':[]}})
             + frame({'type':'response.output_text.delta','output_index':1,'item_id':'m1','content_index':0,'delta':'Done.'}), 0.06),
            (frame({'type':'response.completed','response':{'id':'r1','status':'completed','output':[reasoning,message],'usage':usage}}), 0),
        ]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        if burst:
            self.wfile.write(b''.join(data for data, _ in steps)); self.wfile.flush(); return
        for data, pause in steps:
            self.wfile.write(data); self.wfile.flush()
            if pause: time.sleep(pause)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.json').write_text(json.dumps({'port': server.server_address[1]}))
server.serve_forever()
"""#

    private func attempt(model: String) async throws -> JSON {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("gateway.py"); try Data(Self.gatewayScript.utf8).write(to: script)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path, root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap(JSON.parse(Data(contentsOf: ready))["port"].int)
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON("http://127.0.0.1:\(port)/v1"); raw["modelId"] = JSON(model)
        let traces = TraceStore(), client = ProviderClient(traces: traces)
        let reply = try await client.complete(profile: Profile(raw), apiKey: "fixture", messages: [ChatMessage(role: "user", content: [textBlock("think")])], instructions: "fixture", tools: [], sessionID: "rate", turnID: "t", purpose: "turn", onDelta: { _ in })
        XCTAssertEqual(reply.usage["output"].int, 860); XCTAssertEqual(reply.usage["reasoning"].int, 800)
        return await traces.latest("rate")
    }

    func testHiddenReasoningIsInsideTheDecodeSpan() async throws {
        let metadata = try await attempt(model: "reasoner")
        let timings = metadata["timings"], metrics = metadata["metrics"]
        let firstContent = try XCTUnwrap(timings["firstContent"].double), complete = try XCTUnwrap(timings["modelComplete"].double)
        let dispatch = try XCTUnwrap(timings["dispatch"].double), firstText = try XCTUnwrap(timings["firstText"].double)
        // The app's settled rate: provider output tokens over first content → model complete.
        let settled = 860 / ((complete - firstContent) / 1000)
        print("PERF decode-span reasoning spanMs=\(Int(complete - firstContent)) settledTokPerSec=\(Int(settled)) ttftMs=\(Int(firstContent - dispatch)) firstTextMs=\(Int(firstText - dispatch))")
        XCTAssertGreaterThan(complete - firstContent, 800, "the span covers the 0.8 s of hidden reasoning the output count includes")
        XCTAssertLessThan(settled, 1_100, "860 tokens over ~0.86 s, not over the 0.06 s visible tail (~14,000 tok/s)")
        XCTAssertEqual(metrics["decodeTokensPerSecond"].double ?? 0, settled, accuracy: 0.5)
        XCTAssertEqual(metrics["streamDurationMs"].double ?? 0, complete - firstContent, accuracy: 0.001)
        XCTAssertLessThan(firstContent - dispatch, firstText - dispatch - 700, "time to first token is the first generated item; the first visible text stays separate")
        XCTAssertEqual(metrics["minimumDecodeSpanMs"].double, 250)
    }

    func testABurstDeliveredReplyReportsNoDecodeRate() async throws {
        let metadata = try await attempt(model: "burst")
        let timings = metadata["timings"], metrics = metadata["metrics"]
        let span = (timings["modelComplete"].double ?? 0) - (timings["firstContent"].double ?? 0)
        print("PERF decode-span burst spanMs=\(span)")
        XCTAssertLessThan(span, 250, "one write delivers the whole reply")
        XCTAssertTrue(metrics["decodeTokensPerSecond"].isNull, "below the minimum span a request contributes no rate, never 100,000 tok/s")
        XCTAssertEqual(metrics["minimumDecodeSpanMs"].double, 250, "the minimum travels with the timings, for readers that fold their own rate")
    }
}
