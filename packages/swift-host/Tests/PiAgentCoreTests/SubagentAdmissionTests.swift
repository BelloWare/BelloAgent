import XCTest
@testable import PiAgentCore

final class SubagentAdmissionTests: XCTestCase {
    func testCancelledPermitRetainsScopeButRecordsNoDispatch() async throws {
        let traces = TraceStore(), client = ProviderClient(traces: traces)
        let scope = RequestScope(sourceSessionID: "child", budgetOwnerSessionID: "parent", turnID: "turn", executionID: "execution", purpose: "turn", ownerGeneration: 0, delegation: subagentFixtureOrigin().link)
        let evidence = AdmissionEvidence()
        let lifecycle = RequestLifecycle(scope: scope, admitAttempt: { id in
            let permit = RequestPermit(id); permit.cancel(); return permit
        }, willDispatch: { _ in XCTFail("Cancelled permit dispatched") }, settleAttempt: { value in await evidence.record(value) })
        do {
            _ = try await client.complete(profile: fixtureProfile(), apiKey: "fixture", messages: [], instructions: "fixture", tools: [], sessionID: "child", cacheSessionID: "child", turnID: "turn", purpose: "turn", lifecycle: lifecycle, onObservation: { _ in }, onDelta: { _ in })
            XCTFail("Cancelled permit must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        let settlements = await evidence.values
        XCTAssertEqual(settlements.count, 1); XCTAssertFalse(settlements[0].dispatched)
        let captures = try await traces.command("debug.list", session: "child", params: [:])
        XCTAssertEqual(captures["attempts"].list.first?["requestScope"], try subagentJSON(scope))
        XCTAssertEqual(captures["attempts"].list.first?["attemptId"].text, settlements[0].observation.attemptID)
    }

    func testSharedLimitCancelsPermitsButStillAcceptsLateChildAccounting() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try familyFixture(root: root), profile = try fixtureProfile()
        await owner.enableFamilyBudget(); await owner.beginPresentedTask("turn")
        var origin = subagentFixtureOrigin()
        let execution = await owner.activeTaskPresentation?.executionID
        origin.link.parentExecutionID = try XCTUnwrap(execution)
        try await owner.installAdmissionFixturePlan(SubagentPlan(origin: origin, task: "task", resultMessageID: "result"))
        let child = try AgentSession(id: "child", profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: true,
                                     resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: DisabledTools(), traces: TraceStore(), prepared: nil, subagentOrigin: origin)
        try await child.bindBudgetOwner(owner, generation: 0)
        await owner.setCostLimit(0.5)
        let ownValue = try await owner.requestLifecycle(turnID: "turn", purpose: "turn")
        let delegatedValue = try await child.requestLifecycle(turnID: "turn", purpose: "turn")
        let own = try XCTUnwrap(ownValue), delegated = try XCTUnwrap(delegatedValue)
        let a = try await own.admitAttempt("own"), b = try await delegated.admitAttempt("child-physical")
        try await own.willDispatch("own"); try await delegated.willDispatch("child-physical")
        try await own.settleAttempt(AttemptSettlement(scope: own.scope, observation: billingObservation(profile: profile, session: "parent", attempt: "own", cost: 0.6), dispatched: true))
        XCTAssertThrowsError(try b.check()); XCTAssertThrowsError(try a.check())
        // Cancellation may report a final charge. Both journals retain the same
        // physical attempt, and only the owner total includes both sessions.
        try await delegated.settleAttempt(AttemptSettlement(scope: delegated.scope, observation: billingObservation(profile: profile, session: "child", attempt: "child-physical", cost: 0.2), dispatched: true))
        let total = await owner.spend, local = await child.spend
        XCTAssertEqual(total.usd, 0.8, accuracy: 1e-9); XCTAssertEqual(local.usd, 0.2)
        XCTAssertEqual(total.reported, 2); XCTAssertEqual(local.reported, 1)
        await owner.setCostLimit(2)
        do { _ = try await delegated.admitAttempt("stale"); XCTFail("Raising the limit cannot revive old child work") } catch {}
        await child.close(); await owner.close()
    }

    func testOwnerJournalAndScopePrecedeEveryLoopbackRetry() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gateway, root: root); defer { gateway.stop() }
        var raw = try fixtureProfile().raw; raw["baseUrl"] = JSON(gateway.base + "/v1")
        let traces = TraceStore(), profile = try Profile(raw)
        let owner = try familyFixture(root: root, profile: profile, client: ProviderClient(traces: traces), traces: traces)
        await owner.enableFamilyBudget(); await owner.useRetrySettings(.init(maxRetries: 2, baseDelayMs: 1))
        _ = try await owner.submit(Submission(commandID: "command", turnID: "turn", text: "task"), steer: false)
        try await eventually { !(await owner.isRunning) }
        let state = await owner.snapshot(), accounting = await owner.accounting
        XCTAssertEqual(state["state"].text, "idle", state.encoded())
        XCTAssertEqual(accounting.attempts.count, 3)
        let observations = try JSON.parse(Data(contentsOf: root.appendingPathComponent("observed.json")))
        XCTAssertEqual(observations.list.compactMap(\.int), [1, 2, 3], "Each request found its own durable dispatch admission")
        let spend = await owner.spend
        XCTAssertEqual(spend.reported, 3); XCTAssertEqual(spend.usd, 0.03, accuracy: 1e-9)
        let captures = try await traces.command("debug.list", session: "parent", params: [:])
        XCTAssertEqual(Set(captures["attempts"].list.compactMap { $0["attemptId"].text }), Set(accounting.attempts.keys))
        XCTAssertTrue(captures["attempts"].list.allSatisfy { $0["requestScope"]["budgetOwnerSessionID"].text == "parent" })
        await owner.close()
    }

    func testSummaryRetriesUseTheSameThrowingAdmissionPath() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScopedBillingClient(failures: 1)
        let owner = try familyFixture(root: root, client: client)
        await owner.enableFamilyBudget(); await owner.useRetrySettings(.init(maxRetries: 1, baseDelayMs: 1))
        try await owner.runAdmissionFixtureSummary()
        let entries = await owner.accounting.attempts
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.values.allSatisfy { $0.admission?["purpose"].text == "compaction" && $0.contribution != nil })
        await owner.close()
    }

    func testDeniedAdmissionCreatesNoCaptureAndNeverDispatches() async throws {
        let traces = TraceStore(), client = ProviderClient(traces: traces)
        let scope = RequestScope(sourceSessionID: "parent", budgetOwnerSessionID: "parent", turnID: "turn", executionID: "execution", purpose: "turn", ownerGeneration: 0, delegation: nil)
        let lifecycle = RequestLifecycle(scope: scope, admitAttempt: { _ in throw AgentError("fixture_admission_denied", "No dispatch") }, willDispatch: { _ in XCTFail("Dispatched a denied attempt") }, settleAttempt: { _ in XCTFail("Settled an unregistered attempt") })
        do {
            _ = try await client.complete(profile: fixtureProfile(), apiKey: "fixture", messages: [ChatMessage(role: "user", content: [textBlock("task")])], instructions: "fixture", tools: [], sessionID: "parent", cacheSessionID: "parent", turnID: "turn", purpose: "turn", lifecycle: lifecycle, onObservation: { _ in }, onDelta: { _ in })
            XCTFail("Admission denial must propagate")
        } catch { XCTAssertEqual((error as? AgentError)?.code, "fixture_admission_denied") }
        let captures = try await traces.command("debug.list", session: "parent", params: [:])
        XCTAssertTrue(captures["attempts"].list.isEmpty)
    }

    private static let gateway = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1]); seen = []
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self, *args): pass
 def do_POST(self):
  self.rfile.read(int(self.headers['content-length']))
  rows = [json.loads(line) for line in (root/'parent.jsonl').read_text().splitlines()]
  dispatched = [row for row in rows if row.get('customType') == 'pi-app.budget-attempt.v1' and row['data']['state'] == 'dispatched']
  seen.append(len(dispatched)); (root/'observed.json').write_text(json.dumps(seen))
  failed = len(seen) < 3
  body = {'error': {'message':'server temporarily unavailable'}} if failed else {'id':'r','model':'fixture-model','status':'completed','output':[{'id':'m','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Done'}]}],'usage':{'input_tokens':10,'output_tokens':2,'total_tokens':12}}
  raw = json.dumps(body).encode(); self.send_response(503 if failed else 200)
  self.send_header('Content-Type','application/json'); self.send_header('Content-Length', str(len(raw))); self.send_header('x-litellm-response-cost','0.01'); self.end_headers(); self.wfile.write(raw)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root/'ready.json').write_text(json.dumps({'port':server.server_port})); server.serve_forever()
"""#
}

private actor AdmissionEvidence {
    var values: [AttemptSettlement] = []
    func record(_ value: AttemptSettlement) { values.append(value) }
}

func familyFixture(root: URL, profile: Profile? = nil, client: any ModelClient = ScriptClient([]), traces: TraceStore = TraceStore()) throws -> AgentSession {
    try AgentSession(id: "parent", profile: profile ?? fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                     readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: DisabledTools(), traces: traces)
}

extension AgentSession {
    func installAdmissionFixturePlan(_ plan: SubagentPlan) throws {
        let row: JSON = ["type":"custom", "customType":JSON(JournalRecordKind.subagentCall), "data":try subagentJSON(plan)]
        try journal?.append(row); try subagents.consume(row, sessionID: id)
    }
    func runAdmissionFixtureSummary() async throws {
        currentTurnID = "turn"
        var used = 0
        _ = try await summaryReply([], instructions: "fixture", tools: [], profile: profile, originalProfile: profile,
                                   revision: contextMutation, limit: 2, retry: .init(maxRetries: 1, baseDelayMs: 1), used: &used)
    }
}

private actor ScopedBillingClient: ModelClient {
    var failures: Int
    init(failures: Int) { self.failures = failures }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped", "Missing request admission")
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = try XCTUnwrap(lifecycle), id = UUID().uuidString
        let permit = try await hooks.admitAttempt(id); defer { permit.finish() }
        try await hooks.willDispatch(id)
        var observation = RequestObservation(sessionID: sessionID, turnID: turnID, attemptID: id, purpose: purpose, fingerprint: "fixture", profile: profile)
        observation.monitoring = ["outcome":"completed", "gateway":["cost":["status":"reported","usd":0.1]]]
        try await hooks.settleAttempt(AttemptSettlement(scope: hooks.scope, observation: observation, dispatched: true))
        if failures > 0 { failures -= 1; throw AgentError("provider_http", "HTTP 503 server unavailable", attemptID: id) }
        var reply = answer("Summary"); reply.message.requestAttemptIDs = [id]; return reply
    }
}
