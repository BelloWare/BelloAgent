import XCTest
@testable import PiAgentCore

final class SubagentAccountingTests: HelperTestCase {
    func testFamilyCostAndTokensSurviveFailedStoppedResumedRequestsAndReload() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        func open(_ path: String? = nil) throws -> AgentSession {
            try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                tools: DisabledTools(), traces: TraceStore(), resumePath: path)
        }
        var owner = try open()
        await owner.setCostLimit(1)
        var records: [JSON] = []
        for (index, outcome) in ["failed", "cancelled", "completed"].enumerated() {
            var cost = costRecord("child-attempt-\(index)", usd: 0.4, revision: index + 1)
            cost["outcome"] = JSON(outcome); cost["sourceSessionId"] = JSON("child-\(index % 2)")
            cost["purpose"] = JSON(index == 2 ? "compaction" : "turn")
            cost["usage"] = ["input":100, "output":20, "cacheRead":40, "reasoning":5, "total":120]
            records.append(cost)
            try await owner.appendAccounting(kind: JournalRecordKind.cost, data: cost)
        }
        do { try await owner.enforceCostLimit(); XCTFail("All child attempts must count against the parent's budget") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "cost_limit") }
        // Raising the budget permits a user resume; settled requests stay charged.
        await owner.setCostLimit(2); try await owner.enforceCostLimit()
        var resumed = costRecord("child-resumed", usd: 0.3, revision: 4)
        resumed["usage"] = ["input":200, "output":30, "cacheRead":50, "reasoning":10, "total":230]
        records.append(resumed)
        try await owner.appendAccounting(kind: JournalRecordKind.cost, data: resumed)
        let path = await owner.path
        for reload in [false, true, true] {
            if reload { await owner.close(); owner = try open(path) }
            for cost in records { try await owner.appendAccounting(kind: JournalRecordKind.cost, data: cost) }
            let snapshot = await owner.costSnapshot
            XCTAssertEqual(try XCTUnwrap(snapshot["spentUSD"].double), 1.5, accuracy: 1e-9)
            XCTAssertEqual(snapshot["reportedRequests"].int, 4)
            XCTAssertEqual(snapshot["familyUsage"]["input"].double, 500)
            XCTAssertEqual(snapshot["familyUsage"]["output"].double, 90)
            XCTAssertEqual(snapshot["familyUsage"]["cacheRead"].double, 170)
            XCTAssertEqual(snapshot["familyUsage"]["reasoning"].double, 25)
            XCTAssertEqual(snapshot["familyUsage"]["total"].double, 590)
            XCTAssertEqual(snapshot["familyUsage"]["unknownRequests"].int, 0)
        }
        await owner.close()
    }

    func testNullUsageFieldsRemainAnUnknownRequest() throws {
        var ledger = AttemptAccounting(), spend = SessionSpend()
        var unknown = costRecord("physical", usd: nil, revision: 1)
        unknown["usage"] = ["input":.null,"output":.null]
        unknown["usageStatus"] = ["input":"invalid","output":"unreported"]
        try ledger.consume(kind: JournalRecordKind.cost, data: unknown, spend: &spend)
        XCTAssertTrue(ledger.usageTotals.isEmpty); XCTAssertEqual(ledger.usageUnknownRequests, 1)
        XCTAssertEqual(spend.unreported, 1)
    }

    func testAdmissionIsUnknownUntilSettledOrProvenNotDispatched() throws {
        var ledger = AttemptAccounting(), spend = SessionSpend()
        var admission = admissionRecord("physical")
        try ledger.consume(kind: JournalRecordKind.budgetAttempt, data: admission, spend: &spend)
        XCTAssertEqual(spend.unreported, 1); XCTAssertEqual(spend.reported, 0)
        XCTAssertEqual(ledger.usageUnknownRequests, 1)
        admission["state"] = "not_dispatched"
        try ledger.consume(kind: JournalRecordKind.budgetAttempt, data: admission, spend: &spend)
        XCTAssertEqual(spend, SessionSpend()); XCTAssertEqual(ledger.usageUnknownRequests, 0)
        XCTAssertThrowsError(try ledger.consume(kind: JournalRecordKind.cost, data: costRecord("physical", usd: 1, revision: 2), spend: &spend))
    }

    func testCorrectionReplacesUnknownAndIsIdempotentWithoutLosingUsage() throws {
        var ledger = AttemptAccounting(), spend = SessionSpend()
        try ledger.consume(kind: JournalRecordKind.budgetAttempt, data: admissionRecord("physical"), spend: &spend)
        var unknown = costRecord("physical", usd: nil, revision: 2)
        unknown["usage"] = ["input":100, "output":5]
        try ledger.consume(kind: JournalRecordKind.cost, data: unknown, spend: &spend)
        var known = costRecord("physical", usd: 0.75, revision: 3); known["usage"] = ["input":100, "output":5]
        XCTAssertTrue(try ledger.consume(kind: JournalRecordKind.costUpdate, data: known, spend: &spend))
        XCTAssertFalse(try ledger.consume(kind: JournalRecordKind.costUpdate, data: known, spend: &spend))
        XCTAssertFalse(try ledger.consume(kind: JournalRecordKind.costUpdate, data: unknown, spend: &spend))
        XCTAssertEqual(spend, SessionSpend(usd: 0.75, reported: 1))
        XCTAssertEqual(ledger.usageTotals["input"], 100); XCTAssertEqual(ledger.usageReported["input"], 1)
        XCTAssertEqual(ledger.usageUnknownRequests, 0)
        known["sourceSessionId"] = "other-child"; known["accountingRevision"] = 4
        XCTAssertThrowsError(try ledger.consume(kind: JournalRecordKind.costUpdate, data: known, spend: &spend))
    }

    func testIndexDoesNotForgetOlderAttemptsAndForkResetClearsAuthority() throws {
        var ledger = AttemptAccounting(), spend = SessionSpend()
        for n in 0..<600 { try ledger.consume(kind: JournalRecordKind.cost, data: costRecord("attempt-\(n)", usd: 1, revision: n + 1), spend: &spend) }
        XCTAssertFalse(try ledger.consume(kind: JournalRecordKind.cost, data: costRecord("attempt-0", usd: 1, revision: 1), spend: &spend))
        XCTAssertEqual(spend.usd, 600); XCTAssertEqual(ledger.attempts.count, 600)
        try ledger.consume(kind: JournalRecordKind.cost, data: ["reset":true,"usd":0,"reported":0,"unreported":0], spend: &spend)
        XCTAssertTrue(ledger.attempts.isEmpty); XCTAssertEqual(spend, SessionSpend())
        XCTAssertThrowsError(try ledger.consume(kind: JournalRecordKind.costUpdate, data: costRecord("attempt-0", usd: 2, revision: 601), spend: &spend))
    }

    func testMalformedReportedCostIsUnknownAndSeedIsKeptOnce() throws {
        var ledger = AttemptAccounting(), spend = SessionSpend()
        try ledger.consume(kind: JournalRecordKind.cost, data: ["source":"app-request-log","usd":3,"reported":2], spend: &spend)
        var invalid = costRecord("attempt", usd: 1, revision: 1); invalid["usd"] = -1
        try ledger.consume(kind: JournalRecordKind.cost, data: invalid, spend: &spend)
        XCTAssertEqual(spend, SessionSpend(usd: 3, reported: 2, unreported: 1))
        let restored = try JSONDecoder().decode(AttemptAccounting.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored, ledger)
    }

    func testFailedAccountingWriteClosesAdmissionAndKeepsUnknownEvidence() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let s = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                                 readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                                 tools: DisabledTools(), traces: TraceStore(), beforeJournalAppend: { record in
            if record["customType"].text == JournalRecordKind.cost { throw AgentError("fixture_io", "No space") }
        })
        try await s.appendAccounting(kind: JournalRecordKind.budgetAttempt, data: admissionRecord("physical"))
        do { try await s.appendAccounting(kind: JournalRecordKind.cost, data: costRecord("physical", usd: 1, revision: 2)); XCTFail("Write must fail") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "accounting_persistence") }
        do { try await s.enforceCostLimit(); XCTFail("Admission must be closed") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "accounting_persistence") }
        let spend = await s.spend
        XCTAssertEqual(spend.unreported, 1); XCTAssertEqual(spend.reported, 0)
        await s.close()
    }

    func testCopyForkDropsAdmissionsCorrectionsAndOwnerAuthority() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try AgentSession(id: "p", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore())
        try await parent.appendAccounting(kind: JournalRecordKind.budgetAttempt, data: admissionRecord("physical"))
        try await parent.appendAccounting(kind: JournalRecordKind.cost, data: costRecord("physical", usd: nil, revision: 2))
        try await parent.correctAccounting(costRecord("physical", usd: 2, revision: 3))
        // The longer identity forces the streaming copy path rather than clone.
        let fork = try await parent.fork(to: "fork-with-longer-identity")
        let child = try AgentSession(id: "fork-with-longer-identity", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: fork["path"].text)
        let spend = await child.spend, accounting = await child.accounting
        XCTAssertEqual(spend, SessionSpend()); XCTAssertTrue(accounting.attempts.isEmpty)
        await child.close(); await parent.close()
    }

    func testPhysicalAttemptIsNotChargedAgainAfterReopen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile()
        func open(_ path: String? = nil) throws -> AgentSession {
            try AgentSession(id: "parent", profile: profile, apiKey: "fixture", cwd: root, directory: root,
                             readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                             tools: DisabledTools(), traces: TraceStore(), resumePath: path)
        }
        let observation = billingObservation(profile: profile, session: "parent", attempt: "physical", cost: 0.75)
        let first = try open(); let contribution = await first.contribution(observation, owner: "parent")
        try await first.appendAccounting(kind: JournalRecordKind.cost, data: contribution)
        var task = ChatMessage(role: "user", content: [textBlock("task")]); task.id = "task"
        try await first.append(task)
        try await first.appendForTesting([["type":"custom", "customType":JSON(JournalRecordKind.context), "data":["ids":["task"]]]])
        let path = await first.path; await first.close()
        let second = try open(path); try await second.appendAccounting(kind: JournalRecordKind.cost, data: contribution)
        let total = await second.spend
        XCTAssertEqual(total.usd, 0.75); XCTAssertEqual(total.reported, 1)
        await second.close()
        XCTAssertNotNil(JournalCheckpoint.read(for: root.appendingPathComponent("parent.jsonl")))
        let checkpoint = try open(path); try await checkpoint.appendAccounting(kind: JournalRecordKind.cost, data: contribution)
        let retained = await checkpoint.spend
        XCTAssertEqual(retained, total)
        await checkpoint.close()
    }
}

func admissionRecord(_ id: String) -> JSON {
    ["attemptId":JSON(id), "sourceSessionId":"child", "budgetOwnerSessionId":"parent", "delegationId":"delegation", "purpose":"turn", "state":"admitted", "accountingRevision":1]
}
func costRecord(_ id: String, usd: Double?, revision: Int) -> JSON {
    ["attemptId":JSON(id), "sourceSessionId":"child", "budgetOwnerSessionId":"parent", "delegationId":"delegation", "purpose":"turn", "outcome":"completed",
     "usd":usd.map { JSON($0) } ?? 0, "reported":JSON(usd == nil ? 0 : 1), "unreported":JSON(usd == nil ? 1 : 0), "accountingRevision":JSON(revision)]
}

func billingObservation(profile: Profile, session: String, attempt: String, cost: Double?) -> RequestObservation {
    var value = RequestObservation(sessionID: session, turnID: "turn", attemptID: attempt, purpose: "turn", fingerprint: "fixture", profile: profile)
    value.monitoring = ["outcome":"completed", "gateway":["cost":["status":cost == nil ? "unreported" : "reported", "usd":cost.map { JSON($0) } ?? .null]]]
    return value
}
