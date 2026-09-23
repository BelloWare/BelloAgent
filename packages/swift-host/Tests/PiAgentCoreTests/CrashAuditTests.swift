import XCTest
@testable import PiAgentCore

final class CrashAuditTests: XCTestCase {
    func testOutOfRangeRetainedTimingReopensAsUnavailableAndPreservesHistory() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), path = root.appendingPathComponent("timing.jsonl")
        var journal: SessionJournal? = try SessionJournal(url: path, id: "timing", cwd: root, binding: profile.binding, create: true)
        try journal?.append(["type": "custom", "customType": "pi-app.native.state.v1", "data": ["queue": [], "steering": [], "commands": [], "timing": ["modelMs": 1e30, "toolMs": -1]]])
        journal = nil
        let original = try Data(contentsOf: path)
        let session = try AgentSession(id: "timing", profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([answer("still works")]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path, autoCompaction: false)
        addTeardownBlock { await session.close() }
        let before = await session.turnMetrics()
        XCTAssertTrue(before["sessionModelMs"].isNull); XCTAssertTrue(before["sessionToolMs"].isNull)
        _ = try await session.submit(Submission(commandID: "go", turnID: "go", text: "continue"), steer: false)
        try await eventually { !(await session.isRunning) }
        let after = await session.turnMetrics()
        XCTAssertTrue(after["sessionModelMs"].isNull)
        XCTAssertTrue(try Data(contentsOf: path).starts(with: original), "Bad metadata is preserved in the append-only journal")
    }

    func testInvalidUsageComponentsAndOverflowRemainExplicit() throws {
        for bad: JSON in [-1, 1.5, 1e30, "NaN", true, .number(.infinity)] {
            let raw: JSON = ["input_tokens": bad, "output_tokens": bad, "output_tokens_details": ["reasoning_tokens": bad]]
            let usage = UsageObservation.normalized(raw, api: "openai-responses")
            XCTAssertTrue(usage["input"].isNull); XCTAssertTrue(usage["output"].isNull)
            XCTAssertEqual(usage["status"]["reasoning"].text, "invalid")
            var totals = CumulativeUsage(); totals.observe(usage)
            XCTAssertTrue(totals.json["input"].isNull); XCTAssertEqual(totals.json["inputStatus"].text, "invalid")
        }
        let large: JSON = ["input_tokens": 8e18, "output_tokens": 8e18]
        let usage = UsageObservation.normalized(large, api: "openai-responses")
        var totals = CumulativeUsage(); totals.observe(usage); totals.observe(usage)
        XCTAssertEqual(totals.json["inputStatus"].text, "overflow")
        XCTAssertEqual(totals.json["outputStatus"].text, "overflow")
        XCTAssertTrue(totals.json["input"].isNull)
        XCTAssertEqual(usage["raw"], large)
        var missing = CumulativeUsage(); missing.observe([:]); missing.observe(usage)
        XCTAssertEqual(missing.json["inputStatus"].text, "unreported")
        XCTAssertTrue(missing.json["input"].isNull)
        let anthropic = UsageObservation.normalized(["input_tokens": 8e18, "cache_read_input_tokens": 8e18, "output_tokens": 2], api: "anthropic-messages")
        XCTAssertTrue(anthropic["inputIncludingCache"].isNull)
        XCTAssertEqual(anthropic["status"]["inputIncludingCache"].text, "overflow")
        XCTAssertNil(ObservedDuration.valid(1e30))
        XCTAssertNil(ObservedDuration.adding(nil, 12))
        XCTAssertEqual(ObservedDuration.adding(10, 20), 30)
    }

    func testHugeUsageThroughRealGatewayKeepsAnswersToolsCompactionAndSiblingAlive() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("gateway.py")
        try Data(Self.gateway.utf8).write(to: script)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, root.path]; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { stopFixtureProcess(server) }
        let ready = root.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap(JSON.parse(Data(contentsOf: ready))["port"].int)
        var raw = try fixtureProfile().raw; raw["baseUrl"] = JSON("http://127.0.0.1:\(port)")
        let traces = TraceStore(), tools = RecordingTools()
        let session = try AgentSession(id: "huge-usage", profile: Profile(raw), apiKey: "synthetic-audit-key", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ProviderClient(traces: traces), tools: tools, traces: traces, autoCompaction: false, compactionPolicy: { var policy = CompactionPolicy(); policy.keepRecentTokens = 1; return policy }())
        raw["modelId"] = "sibling"
        let sibling = try AgentSession(id: "sibling", profile: Profile(raw), apiKey: "synthetic-audit-key", cwd: root, directory: root.appendingPathComponent("sibling"), readOnly: true, resources: Resources(cwd: root, home: root), client: ProviderClient(traces: traces), tools: RecordingTools(), traces: traces, autoCompaction: false)
        addTeardownBlock { await session.close(); await sibling.close() }
        _ = try await session.submit(Submission(commandID: "one", turnID: "one", text: "audit turn 1"), steer: false)
        _ = try await sibling.submit(Submission(commandID: "sib", turnID: "sib", text: "sibling request"), steer: false)
        try await eventually { let first = await session.isRunning, second = await sibling.isRunning; return !first && !second }
        _ = try await session.submit(Submission(commandID: "two", turnID: "two", text: "audit turn 2"), steer: false)
        try await eventually { !(await session.isRunning) }
        try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        let snapshot = await session.snapshot(), other = await sibling.snapshot()
        XCTAssertEqual(snapshot["state"].text, "idle"); XCTAssertEqual(other["state"].text, "idle")
        XCTAssertTrue(snapshot["messages"].list.contains { $0["text"].text == "answer survived" })
        XCTAssertTrue(snapshot["messages"].list.contains { $0["kind"].text == "compaction" })
        let calls = await tools.calls; XCTAssertEqual(calls, ["first"], "Bad accounting cannot replay a tool")
        let totals = await session.inspectContext()["cumulative"]
        XCTAssertEqual(totals["inputStatus"].text, "overflow"); XCTAssertTrue(totals["output"].isNull)
        let records = try String(contentsOf: root.appendingPathComponent("records.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(records.count, 6, "Two turn requests, one tool follow-up, pi's history and turn-prefix summaries and one sibling; no retries")
        let attempts = try await traces.command("debug.list", session: "huge-usage", params: [:])["attempts"].list
        XCTAssertEqual(attempts.count, 5)
        for attempt in attempts {
            let capture = try await traces.command("debug.body", session: "huge-usage", params: ["attemptId": attempt["attemptId"], "body": "response"])
            XCTAssertTrue(records.contains { $0["response"] == capture["bytes"] }, "Exact bytes survive invalid normalized accounting")
        }
    }

    func testMCPServerRequestFloodFailsOnlyItsConnectionWithoutHanging() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("mcp.py")
        try Data("import os,time\nfor n in range(1000):\n os.write(1, ('{\"jsonrpc\":\"2.0\",\"id\":'+str(n)+',\"method\":\"ping\"}\\n').encode())\ntime.sleep(10)\n".utf8).write(to: server)
        let peer = try StdioMCP(command: "/usr/bin/python3", args: [server.path], cwd: root, environment: toolEnvironment(), timeoutSeconds: 2)
        let start = Date()
        do { _ = try await peer.request("tools/call", params: ["name": "unknown", "arguments": [:]]); XCTFail("Flood must fail") }
        catch let error as AgentError { XCTAssertTrue(["mcp_server_flood", "mcp_backpressure", "mcp_unavailable"].contains(error.code), error.message) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        await peer.close(); await peer.close()
        let pipe = Pipe(), writer = MCPWriteQueue(handle: pipe.fileHandleForWriting, failed: {})
        let data = Data(repeating: 0x61, count: 512 * 1024)
        var rejected = 0
        for _ in 0..<100 { if !writer.append(data) { rejected += 1 } }
        XCTAssertGreaterThan(rejected, 0); XCTAssertLessThanOrEqual(writer.retainedBytes, MCPWriteQueue.byteLimit)
        writer.close()
        try await eventually { writer.retainedBytes == 0 }
        try pipe.fileHandleForReading.close()
    }

    private static let gateway = #"""
import base64,http.server,json,os,sys,threading,uuid
root=sys.argv[1]; lock=threading.Lock()
class Gateway(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  try:
   data=self.rfile.read(int(self.headers['Content-Length'])); body=json.loads(data)
   assert self.path.endswith('/responses') and body['stream'] is True
   assert self.headers['Authorization']=='Bearer synthetic-audit-key'
   assert isinstance(body['input'],list) and body['input']
   tool=bool(body.get('tools')) and 'audit turn 1' in data.decode() and not any(x.get('type')=='function_call_output' for x in body['input'])
   output=[{'type':'function_call','id':'item-audit','call_id':'audit-call','name':'first','arguments':'{"value":0}'}] if tool else [{'type':'message','id':'msg-'+uuid.uuid4().hex,'role':'assistant','content':[{'type':'output_text','text':'answer survived'}]}]
   count=10 if body['model']=='sibling' else 8000000000000000000
   response={'id':'resp-'+uuid.uuid4().hex,'model':body['model'],'status':'completed','output':output,'usage':{'input_tokens':count,'output_tokens':count}}
   result=('event: response.completed\ndata: '+json.dumps({'type':'response.completed','response':response})+'\n\n').encode()
   with lock:
    with open(os.path.join(root,'records.jsonl'),'a') as f: f.write(json.dumps({'request':base64.b64encode(data).decode(),'response':base64.b64encode(result).decode()})+'\n')
   self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(result))); self.end_headers(); self.wfile.write(result)
  except Exception as e:
   self.send_error(400,str(e))
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Gateway)
with open(os.path.join(root,'ready.tmp'),'w') as f: json.dump({'port':server.server_port},f)
os.replace(os.path.join(root,'ready.tmp'),os.path.join(root,'ready.json'))
server.serve_forever()
"""#
}
