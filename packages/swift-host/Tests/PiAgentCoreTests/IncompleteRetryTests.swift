import XCTest
@testable import PiAgentCore

private struct CancelAtIncompleteTerminal: ModelClient {
    let provider: ProviderClient
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile: profile, apiKey: apiKey, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, cacheSessionID: sessionID, turnID: turnID, purpose: purpose, lifecycle: nil, onObservation: { _ in }, onDelta: onDelta)
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await provider.complete(profile: profile, apiKey: apiKey, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, cacheSessionID: cacheSessionID, turnID: turnID, purpose: purpose, lifecycle: lifecycle, onObservation: { observation in
            await onObservation(observation)
            if observation.sourceEvent == "response.incomplete" { withUnsafeCurrentTask { $0?.cancel() } }
        }, onDelta: onDelta)
    }
}

private final class IncompleteLedgerWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var refusing = false
    func check(_ record: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        if record["message"]["nativeDetail"].text == "Request failed" { refusing = true }
        if refusing { throw AgentError("session_write", "Fixture journal write failure") }
    }
}

/// The LiteLLM failure reported on 2026-10-15: HTTP 200, a reasoning
/// item, response.incomplete with no reason and zero usage, then [DONE].
/// Every request uses a loopback gateway and synthetic credentials.
final class IncompleteRetryTests: XCTestCase {
    private static let gatewayScript = #"""
import http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
config = json.loads((root / 'config.json').read_text())
count = 0
def frame(value): return 'data: ' + json.dumps(value) + '\n\n'
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        global count
        count += 1
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        failed = count <= config.get('failures', 1)
        response = {'id':'response-' + str(count), 'status':'incomplete' if failed else 'completed'}
        output = []
        frames = []
        if failed:
            item = {'id':'reasoning-' + str(count), 'type':'reasoning', 'summary':[]}
            frames.append({'type':'response.output_item.added', 'output_index':0, 'item':item.copy()})
            if config.get('content'):
                frames.append({'type':'response.reasoning_summary_text.delta', 'output_index':0, 'delta':'DISCARDED REASONING'})
                item['summary'] = [{'type':'summary_text', 'text':'DISCARDED REASONING'}]
            frames.append({'type':'response.output_item.done', 'output_index':0, 'item':item})
            output.append(item)
            if config.get('content'):
                item = {'id':'discarded-message', 'type':'message', 'role':'assistant', 'status':'completed',
                        'content':[{'type':'output_text', 'text':'DISCARDED TEXT'}]}
                frames.append({'type':'response.output_text.delta', 'output_index':1, 'delta':'DISCARDED TEXT'})
                frames.append({'type':'response.output_item.done', 'output_index':1, 'item':item})
                output.append(item)
            if config.get('tool'):
                item = {'id':'discarded-tool', 'type':'function_call', 'call_id':'discarded-call', 'name':'first', 'arguments':'{}', 'status':'completed'}
                frames.append({'type':'response.output_item.added', 'output_index':len(output), 'item':item})
                frames.append({'type':'response.output_item.done', 'output_index':len(output), 'item':item})
                output.append(item)
            if 'details' in config: response['incomplete_details'] = config['details']
            n = config.get('usage', 0)
            response['usage'] = {'input_tokens':n, 'output_tokens':n, 'total_tokens':2*n,
                                 'input_tokens_details':{'cached_tokens':0}, 'output_tokens_details':{'reasoning_tokens':0}}
        else:
            output = [{'id':'accepted-message', 'type':'message', 'role':'assistant', 'status':'completed',
                       'content':[{'type':'output_text', 'text':'ACCEPTED REPLY'}]}]
            if config.get('successful_tool') and count == config.get('failures', 1) + 1:
                output = [{'id':'accepted-tool', 'type':'function_call', 'call_id':'accepted-call', 'name':'second', 'arguments':'{}', 'status':'completed'}]
            else:
                frames.append({'type':'response.output_text.delta', 'output_index':0, 'delta':'ACCEPTED REPLY'})
            response['usage'] = {'input_tokens':20, 'output_tokens':5, 'total_tokens':25}
        if config.get('cost'): response['usage']['cost'] = 0.01 if failed else 0.02
        if not (failed and config.get('omit_output')): response['output'] = output
        prefix = ''.join(frame(f) for f in frames).encode()
        terminal = frame({'type':config.get('terminal', 'response.incomplete') if failed else 'response.completed', 'response':response}).encode() + b'data: [DONE]\n\n'
        with (root / 'requests.jsonl').open('a') as f:
            f.write(json.dumps({'request':request, 'at':time.monotonic(), 'response':(prefix + terminal).decode()}) + '\n')
        if config.get('json'): prefix, terminal = b'', json.dumps(response).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json' if config.get('json') else 'text/event-stream')
        self.send_header('x-litellm-response-cost', '0.01' if failed else '0.02')
        self.send_header('Content-Length', str(len(prefix) + len(terminal) + (64 if failed and config.get('cut_after_terminal') else 0))); self.end_headers()
        self.wfile.write(prefix); self.wfile.flush()
        if failed and config.get('hold'):
            while not (root / 'release').exists(): time.sleep(0.01)
        self.wfile.write(terminal); self.wfile.flush()
server = http.server.HTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port':server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    private struct Fixture {
        let root: URL, session: AgentSession, traces: TraceStore, tools: RecordingTools
        func records() throws -> [JSON] {
            try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
        }
        func attempts() async throws -> [JSON] {
            try await traces.command("debug.list", session: "incomplete", params: [:])["attempts"].list
        }
        func send() async throws {
            _ = try await session.submit(Submission(commandID: "send", turnID: "turn", text: "Fixture request"), steer: false)
        }
        func settle() async throws -> JSON {
            try await eventually { !(await session.isRunning) }
            return await session.snapshot()
        }
    }

    private func fixture(_ config: JSON = [:], retry: PiProviderRules.RetrySettings = .init(maxRetries: 1, baseDelayMs: 1),
                         utility: String? = nil, summary: Bool = false, autoCompaction: Bool = false, cancelAtTerminal: Bool = false,
                         beforeAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }) async throws -> Fixture {
        let root = try temporaryDirectory()
        try config.data().write(to: root.appendingPathComponent("config.json"))
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root)
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON(gateway.base + "/v1"); raw["maxOutputTokens"] = 256
        var seed: [ChatMessage]? = nil
        if summary {
            raw["contextWindow"] = JSON(autoCompaction ? 100_000 : 6_000)
            var user = ChatMessage(role: "user", content: [textBlock("ORIGINAL OBJECTIVE")]); user.id = "root"; user.taskRootID = "root"
            seed = [user] + (0..<4).map { index in
                var reply = ChatMessage(role: "assistant", content: [textBlock("Evidence \(index) " + String(repeating: "x", count: 2000))])
                reply.taskRootID = "root"; return reply
            }
        }
        let traces = TraceStore(), tools = RecordingTools()
        let provider = ProviderClient(traces: traces)
        let client: any ModelClient = cancelAtTerminal ? CancelAtIncompleteTerminal(provider: provider) : provider
        let s = try AgentSession(id: "incomplete", profile: Profile(raw), apiKey: "synthetic-incomplete-key", cwd: root,
                                 directory: root.appendingPathComponent("state"), readOnly: false,
                                 resources: Resources(cwd: root, home: root, titleTask: utility != nil, utility: utility ?? "title"),
                                 client: client, tools: tools, traces: traces, seed: seed,
                                 autoCompaction: autoCompaction, titleTask: utility != nil, utilityPurpose: utility ?? "title", beforeJournalAppend: beforeAppend)
        await s.useRetrySettings(retry)
        addTeardownBlock { await s.close(); gateway.stop(); try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, session: s, traces: traces, tools: tools)
    }

    private func assertAccepted(_ f: Fixture, purpose: String = "turn", file: StaticString = #filePath, line: UInt = #line) async throws {
        let state = try await f.settle(), attempts = try await f.attempts(), records = try f.records()
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded(), file: file, line: line)
        XCTAssertEqual(records.count, 2, file: file, line: line)
        XCTAssertEqual(attempts.count, 2, file: file, line: line)
        XCTAssertEqual(Set(attempts.compactMap { $0["purpose"].text }), [purpose], file: file, line: line)
        XCTAssertEqual(attempts.filter { $0["outcome"].text == "failed" }.count, 1, file: file, line: line)
        if records.count == 2 { XCTAssertEqual(records[0]["request"], records[1]["request"], "Discarded output never enters retry input", file: file, line: line) }
        if purpose != "compaction" {
            let history = await f.session.history.filter { $0.role == "assistant" }
            XCTAssertEqual(history.map(\.text), ["ACCEPTED REPLY"], file: file, line: line)
            XCTAssertEqual(history.first?.thinking, "", file: file, line: line)
            XCTAssertEqual(history.first?.stopReason, nil, file: file, line: line)
        }
        let calls = await f.tools.calls
        XCTAssertTrue(calls.isEmpty, "No call from the incomplete attempt executes", file: file, line: line)
        try await assertDiscardedLedgers(f, file: file, line: line)
    }

    private func assertDiscardedLedgers(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let failed = Set(try await f.attempts().filter { $0["outcome"].text != "completed" }.compactMap { $0["attemptId"].text })
        let ledgers = await f.session.history.filter { $0.kind == "requestLedger" && !(Set($0.requestAttemptIDs ?? []).intersection(failed)).isEmpty }
        for ledger in ledgers {
            XCTAssertTrue(ledger.responseTimeline?.segments.isEmpty == true, "The app projects orphan ledgers as replies", file: file, line: line)
        }
        let operations = await f.session.history.filter { $0.kind == "execution" }
        XCTAssertFalse(operations.contains { $0.responseTimeline?.segments.contains { failed.contains($0.part.attemptID) } == true },
                       "Compaction must discard rejected content while retaining local status and links", file: file, line: line)
    }

    func testReasoningOnlyZeroUsageIncompleteRetriesAndRetainsFailedCapture() async throws {
        let f = try await fixture()
        try await f.send(); try await assertAccepted(f)
        let attempts = try await f.attempts(), failed = try XCTUnwrap(attempts.first { $0["outcome"].text == "failed" })
        let state = await f.session.snapshot(), usage = state["lastRequestObservation"]["usage"]
        XCTAssertEqual(usage["input"].int, 0); XCTAssertEqual(usage["output"].int, 0)
        XCTAssertEqual(failed["usage"]["input"].int, 0); XCTAssertEqual(failed["usage"]["output"].int, 0)
        let captured = try await f.traces.command("debug.body", session: "incomplete", params: ["attemptId":failed["attemptId"], "body":"response"])
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(captured["bytes"].text)))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), try f.records()[0]["response"].text)
        let spend = await f.session.spend
        XCTAssertEqual(spend.unreported, 2); XCTAssertEqual(spend.usd, 0, "Streaming headers alone are not final cost reports")
    }

    func testNullAndEmptyReasonsRetryIncludingACompletedEventWithIncompleteStatus() async throws {
        for details: JSON in [.null, [:], ["reason":.null], ["reason":""]] {
            let f = try await fixture(["details":details, "terminal":"response.completed"])
            try await f.send(); try await assertAccepted(f)
        }
    }

    func testUnexplainedTerminalDoesNotNeedUsableOutputToRetry() async throws {
        let f = try await fixture(["omit_output":true])
        try await f.send(); try await assertAccepted(f)
    }

    func testTransportFailureAfterTheIncompleteTerminalCannotPreserveRejectedContent() async throws {
        let f = try await fixture(["content":true, "tool":true, "cut_after_terminal":true])
        try await f.send(); try await assertAccepted(f)
    }

    func testDisabledOrZeroRetriesKeepTheExistingErrorText() async throws {
        for retry in [PiProviderRules.RetrySettings(enabled: false, maxRetries: 3, baseDelayMs: 1), .init(maxRetries: 0, baseDelayMs: 1)] {
            let f = try await fixture(["content":true, "tool":true], retry: retry)
            try await f.send(); let state = try await f.settle()
            XCTAssertEqual(try f.records().count, 1)
            XCTAssertEqual(state["state"].text, "error")
            XCTAssertEqual(state["preflightError"].text, "Response incomplete without a provider reason")
            let calls = await f.tools.calls, assistants = await f.session.history.filter { $0.role == "assistant" }
            XCTAssertTrue(calls.isEmpty); XCTAssertTrue(assistants.isEmpty)
            try await assertDiscardedLedgers(f)
        }
    }

    func testExhaustedRetriesKeepTheExistingAttemptPrefixAndReason() async throws {
        let f = try await fixture(["failures":3, "content":true, "tool":true], retry: .init(maxRetries: 2, baseDelayMs: 1))
        try await f.send(); let state = try await f.settle()
        XCTAssertEqual(try f.records().count, 3)
        XCTAssertEqual(state["preflightError"].text, "Failed after 3 attempts. Response incomplete without a provider reason")
        let assistants = await f.session.history.filter { $0.role == "assistant" }, calls = await f.tools.calls
        XCTAssertTrue(assistants.isEmpty); XCTAssertTrue(calls.isEmpty)
        try await assertDiscardedLedgers(f)
    }

    func testExplicitReasonsNeverRetryEvenWhenTheirTextLooksTransient() async throws {
        for reason in ["content_filter", "overloaded", "rate_limit"] {
            let f = try await fixture(["details":["reason":JSON(reason)], "tool":true])
            try await f.send(); let state = try await f.settle()
            XCTAssertEqual(try f.records().count, 1)
            XCTAssertEqual(state["preflightError"].text, "Response incomplete: " + reason)
            let calls = await f.tools.calls; XCTAssertTrue(calls.isEmpty)
        }
    }

    func testMaxOutputTokensStillEndsWithALengthStop() async throws {
        let f = try await fixture(["details":["reason":"max_output_tokens"], "content":true])
        try await f.send(); let state = try await f.settle()
        XCTAssertEqual(state["state"].text, "idle")
        XCTAssertEqual(try f.records().count, 1)
        let assistants = await f.session.history.filter { $0.role == "assistant" }
        XCTAssertEqual(assistants.map(\.text), ["DISCARDED TEXT"])
        XCTAssertEqual(assistants.first?.stopReason, "length")
    }

    func testMalformedReasonsAreNotTreatedAsMissing() async throws {
        for reason: JSON in [false, 0, [:], []] {
            let f = try await fixture(["details":["reason":reason]])
            try await f.send(); let state = try await f.settle()
            XCTAssertEqual(try f.records().count, 1); XCTAssertEqual(state["state"].text, "error")
        }
    }

    func testAnExplicitOverflowLikeReasonCannotStartAutomaticCompaction() async throws {
        let f = try await fixture(["details":["reason":"context_length_exceeded"]], summary: true, autoCompaction: true)
        let compactable = await f.session.canCompact(recovering: true); XCTAssertTrue(compactable)
        try await f.send(); let state = try await f.settle(), attempts = try await f.attempts()
        XCTAssertEqual(try f.records().count, 1)
        XCTAssertEqual(attempts.map { $0["purpose"].text }, ["turn"])
        XCTAssertEqual(state["preflightError"].text, "Response incomplete: context_length_exceeded")
    }

    func testJSONIncompleteRetriesAndPreservesFailedUsageMetadata() async throws {
        let f = try await fixture(["json":true, "usage":7, "cost":true, "tool":true])
        try await f.send(); try await assertAccepted(f)
        let attempts = try await f.attempts()
        let failed = try XCTUnwrap(attempts.first { $0["outcome"].text == "failed" })
        XCTAssertEqual(failed["usage"]["input"].int, 7); XCTAssertEqual(failed["usage"]["output"].int, 7)
    }

    func testStopAtTheIncompleteTerminalDiscardsContentAndDoesNotRetry() async throws {
        let f = try await fixture(["content":true, "tool":true], cancelAtTerminal: true)
        try await f.send(); let state = try await f.settle()
        XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(try f.records().count, 1)
        let assistants = await f.session.history.filter { $0.role == "assistant" }, calls = await f.tools.calls
        XCTAssertTrue(assistants.isEmpty); XCTAssertTrue(calls.isEmpty)
        try await assertDiscardedLedgers(f)
    }

    func testOnlyTheSuccessfulAttemptsToolExecutesExactlyOnce() async throws {
        let f = try await fixture(["content":true, "tool":true, "successful_tool":true])
        try await f.send(); let state = try await f.settle(), calls = await f.tools.calls
        XCTAssertEqual(state["state"].text, "idle"); XCTAssertEqual(try f.records().count, 3)
        XCTAssertEqual(calls, ["second"])
        let context = await f.session.context
        XCTAssertEqual(context.filter { $0.role == "toolResult" }.map(\.toolCallId), ["accepted-call"])
        try await assertDiscardedLedgers(f)
    }

    func testStopDuringBackoffDoesNotRestoreTheRejectedReply() async throws {
        let f = try await fixture(["content":true, "tool":true], retry: .init(maxRetries: 1, baseDelayMs: 2_000))
        try await f.send()
        try await eventually { await f.session.retryInfo["attempt"].int == 2 }
        await f.session.stop(); let state = try await f.settle()
        XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(try f.records().count, 1)
        let assistants = await f.session.history.filter { $0.role == "assistant" }
        XCTAssertTrue(assistants.isEmpty); try await assertDiscardedLedgers(f)
    }

    func testARecoveryLogThatCannotBeUnlinkedIsEmptiedBeforeRetry() async throws {
        let f = try await fixture(["content":true, "hold":true], retry: .init(maxRetries: 1, baseDelayMs: 500))
        try await f.send(); try await eventually { await f.session.partialThinking == "DISCARDED REASONING" }
        await f.session.flushStreamed()
        let savedPath = await f.session.path, path = try XCTUnwrap(savedPath)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions:0o500], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory) }
        try Data().write(to: f.root.appendingPathComponent("release"))
        try await eventually { await f.session.retryInfo["attempt"].int == 2 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".stream"), "The directory forbids unlink")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + ".stream")).count, 0)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory)
        try await assertAccepted(f)
    }

    func testFailedLedgerWriteCannotPreventDiscardingTheRecoveryLog() async throws {
        let fault = IncompleteLedgerWriteFailure()
        let f = try await fixture(["content":true, "hold":true], beforeAppend: { try fault.check($0) })
        try await f.send(); try await eventually { await f.session.partialThinking == "DISCARDED REASONING" }
        await f.session.flushStreamed()
        let savedPath = await f.session.path, path = try XCTUnwrap(savedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".stream"))
        try Data().write(to: f.root.appendingPathComponent("release"))
        let state = try await f.settle()
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(try f.records().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".stream"))
        try await assertDiscardedLedgers(f)
        let profile = await f.session.profile
        await f.session.close()
        let reopened = try AgentSession(id: "incomplete", profile: profile, apiKey: "synthetic", cwd: f.root,
                                        directory: f.root.appendingPathComponent("state"), readOnly: false,
                                        resources: Resources(cwd: f.root, home: f.root), client: ScriptClient([]), tools: f.tools,
                                        traces: f.traces, resumePath: path, autoCompaction: false)
        let rows = await reopened.history
        XCTAssertFalse(rows.contains { $0.role == "assistant" })
        XCTAssertFalse(rows.contains { $0.responseTimeline?.segments.contains { $0.text.contains("DISCARDED") } == true })
        await reopened.close()
    }

    func testAccountingFailureRemainsPrimaryButStillDiscardsTheRejectedReply() async throws {
        let f = try await fixture(["content":true, "tool":true], beforeAppend: { record in
            if record["customType"].text == JournalRecordKind.cost { throw AgentError("fixture_write", "Cannot save accounting") }
        })
        await f.session.enableFamilyBudget()
        try await f.send(); let state = try await f.settle()
        XCTAssertEqual(state["errorCode"].text, "accounting_persistence")
        XCTAssertEqual(try f.records().count, 1)
        let assistants = await f.session.history.filter { $0.role == "assistant" }
        XCTAssertTrue(assistants.isEmpty); try await assertDiscardedLedgers(f)
    }

    func testStopAtTheSummaryTerminalDiscardsItsContentAndKeepsTheContext() async throws {
        let f = try await fixture(["content":true, "tool":true], summary: true, cancelAtTerminal: true)
        let before = await f.session.context
        try await f.session.compact(); let state = try await f.settle(), after = await f.session.context
        XCTAssertEqual(state["state"].text, "paused"); XCTAssertEqual(try f.records().count, 1)
        XCTAssertEqual(after.map(\.id), before.map(\.id)); try await assertDiscardedLedgers(f)
    }

    func testDiscardedToolsAndContentNeverBecomeAssistantHistoryOrReappearOnOpen() async throws {
        let f = try await fixture(["content":true, "tool":true, "usage":7, "cost":true])
        // Exercise durable family accounting as well as the ordinary cost path.
        await f.session.enableFamilyBudget()
        try await f.send(); try await assertAccepted(f)
        let usage = await f.session.familyUsage
        XCTAssertEqual(usage["input"].int, 27); XCTAssertEqual(usage["output"].int, 12)
        let spend = await f.session.spend
        XCTAssertEqual(spend.reported, 2); XCTAssertEqual(spend.usd, 0.03, accuracy: 0.000001)
        let savedPath = await f.session.path, profile = await f.session.profile
        let path = try XCTUnwrap(savedPath)
        await f.session.close()
        let reopened = try AgentSession(id: "incomplete", profile: profile, apiKey: "synthetic", cwd: f.root,
                                        directory: f.root.appendingPathComponent("state"), readOnly: false,
                                        resources: Resources(cwd: f.root, home: f.root), client: ScriptClient([]), tools: f.tools,
                                        traces: f.traces, resumePath: path, autoCompaction: false)
        let assistants = await reopened.history.filter { $0.role == "assistant" }
        XCTAssertEqual(assistants.map(\.text), ["ACCEPTED REPLY"])
        let ledgers = await reopened.history.filter { $0.kind == "requestLedger" }
        XCTAssertFalse(ledgers.contains { $0.responseTimeline?.segments.contains { $0.text.contains("DISCARDED") || $0.part.callID == "discarded-call" } == true })
        let context = await reopened.context
        XCTAssertFalse(context.contains { $0.role == "toolResult" || $0.thinking.contains("DISCARDED") || $0.text.contains("DISCARDED") })
        await reopened.close()
    }

    func testReportedFailedAttemptCostCountsInOrdinarySessionsToo() async throws {
        let f = try await fixture(["usage":7, "cost":true])
        try await f.send(); try await assertAccepted(f)
        let spend = await f.session.spend, state = await f.session.snapshot()
        XCTAssertEqual(spend.reported, 2); XCTAssertEqual(spend.usd, 0.03, accuracy: 0.000001)
        XCTAssertEqual(state["lastRequestObservation"]["usage"]["input"].int, 7)
        XCTAssertEqual(state["lastRequestObservation"]["usage"]["output"].int, 7)
    }

    func testRetryNoticeKeepsTheFrozenPolicyAndRemovesTheDiscardedStreamLogBeforeWaiting() async throws {
        let f = try await fixture(["content":true, "tool":true, "hold":true], retry: .init(maxRetries: 1, baseDelayMs: 400))
        try await f.send()
        try await eventually { await f.session.partialThinking == "DISCARDED REASONING" }
        await f.session.flushStreamed()
        let savedPath = await f.session.path
        let path = try XCTUnwrap(savedPath) + ".stream"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "The failed attempt reached the recovery log")
        try Data().write(to: f.root.appendingPathComponent("release"))
        try await eventually { await f.session.snapshot()["runStatus"].text == "retrying" }
        let retry = await f.session.retryInfo
        XCTAssertEqual(retry["attempt"].int, 2); XCTAssertEqual(retry["of"].int, 2)
        XCTAssertEqual(retry["reason"].text, "Response incomplete without a provider reason")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "A crash during backoff must not restore the discarded reply")
        await f.session.useRetrySettings(.init(enabled: false, maxRetries: 0, baseDelayMs: 60_000))
        try await assertAccepted(f)
        let records = try f.records()
        if records.count == 2 { XCTAssertGreaterThanOrEqual((records[1]["at"].double ?? 0) - (records[0]["at"].double ?? 0), 0.4) }
        let cleared = await f.session.retryInfo; XCTAssertTrue(cleared.isNull)
    }

    func testUtilityRequestsUseTheSameRetryPath() async throws {
        for purpose in ["title", "title-suggestions", "webhook"] {
            let f = try await fixture(["content":true, "tool":true], utility: purpose)
            try await f.send(); try await assertAccepted(f, purpose: purpose)
        }
    }

    func testCompactionRetriesUnexplainedIncompleteAndAdoptsOnlyTheCompletedSummary() async throws {
        let f = try await fixture(["content":true, "tool":true], summary: true)
        try await f.session.compact(); try await assertAccepted(f, purpose: "compaction")
        let context = await f.session.context
        XCTAssertEqual(context.first?.kind, "compaction")
        XCTAssertEqual(context.first?.text, CompactionCheckpoint.replayPrefix + "ACCEPTED REPLY")
        XCTAssertTrue(try f.records().allSatisfy { $0["request"]["tool_choice"].text == "none" })
    }

    func testCompactionStillRejectsExplicitReasonsLengthStopsAndDisabledRetries() async throws {
        for (config, retry, code): (JSON, PiProviderRules.RetrySettings, String) in [
            (["details":["reason":"content_filter"]], .init(maxRetries: 1, baseDelayMs: 1), "provider_incomplete"),
            (["details":["reason":"max_output_tokens"]], .init(maxRetries: 1, baseDelayMs: 1), "compaction_output_exhausted"),
            ([:], .init(enabled: false, baseDelayMs: 1), "provider_incomplete_unexplained")
        ] {
            let f = try await fixture(config, retry: retry, summary: true), before = await f.session.context
            try await f.session.compact(); let state = try await f.settle(), after = await f.session.context
            XCTAssertEqual(try f.records().count, 1)
            XCTAssertEqual(state["compaction"]["errorCode"].text, code)
            XCTAssertEqual(after.map(\.id), before.map(\.id))
        }
    }
}
