import XCTest
@testable import PiAgentCore

/// BUG-011 (review 2026-10-16): media types are case-insensitive (RFC 9110
/// 8.3.1), so a complete JSON response under `Application/JSON` is JSON, not
/// an SSE stream that never ends. A loopback gateway sends identical bytes
/// under each spelling; the request's user text names the header to send.
final class ProviderMediaTypeTests: HelperTestCase {
    static let gatewayScript = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        media = json.dumps(request['input'])
        media = media[media.index('MEDIA[') + 6:]; media = media[:media.index(']')]
        response = {'id':'r1','object':'response','status':'completed','model':request['model'],
            'output':[{'id':'m1','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'OK'}]}],
            'usage':{'input_tokens':3,'output_tokens':1,'total_tokens':4}}
        if 'event-stream' in media.lower():
            body = b''.join(b'data: ' + json.dumps(f).encode() + b'\n\n' for f in [
                {'type':'response.output_text.delta','output_index':0,'item_id':'m1','content_index':0,'delta':'OK'},
                {'type':'response.completed','response':response}]) + b'data: [DONE]\n\n'
        else:
            body = json.dumps(response).encode()
        self.send_response(200); self.send_header('Content-Type', media)
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body); self.wfile.flush()
server = http.server.HTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    func testCompleteJSONDecodesTheSameUnderEveryValidMediaTypeSpelling() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON(gateway.base + "/v1")
        let client = ProviderClient(traces: TraceStore())
        for media in ["application/json", "Application/JSON", "Application/JSON; charset=utf-8", " APPLICATION/json ;charset=UTF-8", "text/event-stream", "Text/Event-Stream; charset=utf-8"] {
            let reply: ModelReply
            do {
                reply = try await client.complete(profile: Profile(raw), apiKey: "fixture", messages: [ChatMessage(role: "user", content: [textBlock("MEDIA[\(media)]")])],
                                                  instructions: "fixture", tools: [], sessionID: "s", turnID: "t", purpose: "turn", onDelta: { _ in })
            } catch { XCTFail("\(media): \(error)"); continue }
            XCTAssertEqual(reply.message.text, "OK", media)
            XCTAssertEqual(reply.terminal?.status, "completed", media)
        }
    }

    func testOnlyTheExactJSONTypeIsJSON() {
        for value in ["application/json", "Application/JSON", "application/json; charset=utf-8", "  APPLICATION/JSON  ;q=1"] {
            XCTAssertTrue(ProviderClient.isJSONMediaType(value), value)
        }
        for value in [nil, "", "text/event-stream", "application/json-seq", "application/jsonx", "text/plain; note=application/json", "application/problem+json"] {
            XCTAssertFalse(ProviderClient.isJSONMediaType(value), value ?? "nil")
        }
    }
}
