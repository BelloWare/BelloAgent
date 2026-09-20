import XCTest
@testable import PiApp

private final class AccountingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 2000
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ value: Double) { lock.lock(); defer { lock.unlock() }; seconds += value }
}

final class GatewayAccountingTests: XCTestCase {
    func testCacheHeaderContractCannotReadAuthenticationOrReuseModelHeader() throws {
        try RoutingConfiguration.validate(.object(["reference": .string("Gateway release acceptance contract"), "cacheHeader": .string("x-app-cache-status")]))
        let cases: [[String: WireValue]] = [
            ["cacheHeader": .string("x-app-cache-status")],
            ["reference": .string("test"), "cacheHeader": .string("authorization")],
            ["reference": .string("test"), "cacheHeader": .string("x-api-key")],
            ["reference": .string("test"), "cacheHeader": .string("x-status"), "modelHeader": .string("X-Status")]
        ]
        for fields in cases { XCTAssertThrowsError(try RoutingConfiguration.validate(.object(fields))) }
    }
    private func folder() throws -> URL {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("accounting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func value(session: String = "session", turn: String = "user-1", output: [String] = ["assistant-1"], cost: Double? = nil, cache: String = "unreported", outcome: String = "completed", wall: Double = 1995, purpose: String = "turn") -> [String: WireValue] {
        ["attemptId": .string(UUID().uuidString), "sessionId": .string(session), "turnId": .string(turn), "purpose": .string(purpose), "api": .string("openai-responses"), "requestedModel": .string("router"), "mode": .string("off"), "outcome": .string(outcome), "wallTimestamp": .number(wall), "dispatchWallTimestamp": .number(wall), "timingVersion": .number(2), "timings": .object(["dispatch": .number(100), "firstContent": .number(110), "modelComplete": .number(120), "httpEnd": .number(130)]), "messageIds": .array([.string("user-1"), .string("assistant-1")]), "outputMessageIds": .array(output.map(WireValue.string)), "gateway": .object(["version": .number(1), "cost": .object(["status": .string(cost == nil ? "unreported" : "reported"), "usd": cost.map(WireValue.number) ?? .null, "source": .string("header:x-litellm-response-cost")]), "cache": .object(["status": .string(cache), "source": .string("header:x-litellm-cache-hit")])]), "usage": .object(["cacheRead": .number(20)])]
    }
    @discardableResult private func save(_ archive: PayloadArchive, _ value: [String: WireValue], workspace: String = "workspace") async throws -> String {
        try await archive.begin(value, workspace: workspace)
        if value["outcome"]?.string != "running" { try await archive.finish(value) }
        return value["attemptId"]!.string!
    }
    private func filter(status: String = "all") -> DashboardFilter {
        DashboardFilter(from: Date(timeIntervalSince1970: 1900), until: Date(timeIntervalSince1970: 2001), status: status, bucketCount: 2)
    }

    func testMessageAttributionAndSessionTotalsDoNotDoubleCountContextToolOrSideLinks() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: Data(repeating: 1, count: 32), quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await save(archive, value(output: ["assistant-1", "tool-1"], cost: 0.01, cache: "miss"))
        try await save(archive, value(output: ["assistant-2"], cost: 0.02, cache: "hit"))
        try await save(archive, value(turn: "user-2", output: ["assistant-3"], cache: "unreported"))
        try await save(archive, value(session: "side", turn: "side-user", output: ["side-answer"], cost: 0.04, cache: "miss"))
        try await save(archive, value(cost: 99), workspace: "other-workspace")
        let messages = [TranscriptMessage(id: "user-1", role: "user", text: ""), .init(id: "assistant-1", role: "assistant", text: ""), .init(id: "tool-1", role: "tool", text: ""), .init(id: "assistant-2", role: "assistant", text: ""), .init(id: "user-2", role: "user", text: "")]
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: messages)
        XCTAssertEqual(result.session.requests, 3); XCTAssertEqual(result.session.costSamples, 2)
        XCTAssertEqual(try XCTUnwrap(result.session.costUSD), 0.03, accuracy: 0.000000001)
        XCTAssertNil(result.messages["user-1"], "Completed requests move to their assistant rows")
        XCTAssertEqual(result.messages["assistant-1"]?.costUSD, 0.01)
        XCTAssertNil(result.messages["tool-1"], "Tools retain Details links without duplicating inline usage")
        XCTAssertEqual(result.messages["assistant-2"]?.costUSD, 0.02)
        XCTAssertNil(result.messages["user-2"]?.costUSD)
        let side = try await archive.gatewayAccounting(sessionID: "side", workspaceID: "workspace", messages: [messages[1]])
        XCTAssertEqual(side.session.costUSD, 0.04); XCTAssertEqual(side.messages["assistant-1"]?.costUSD, 0.01)
        XCTAssertEqual(result.session.cacheHits, 1); XCTAssertEqual(result.session.cacheMisses, 1); XCTAssertEqual(result.session.cacheUnreported, 1)
        XCTAssertEqual(result.session.cacheReadTokens, 60); XCTAssertNil(result.session.cacheWriteTokens)
    }

    func testDashboardCostCoverageZeroCacheStatesAndStatusBucketsAreExplicit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: Data(repeating: 2, count: 32), quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let zero = try await save(archive, value(cost: 0, cache: "hit", wall: 1920))
        try await save(archive, value(cost: 0.005, cache: "miss", outcome: "cancelled", wall: 1980))
        try await save(archive, value(cache: "conflict", outcome: "failed", wall: 1980))
        try await save(archive, value(cache: "unreported", outcome: "running"))
        let all = try await archive.dashboard(filter())
        XCTAssertEqual(all.gateway.requests, 4); XCTAssertEqual(all.gateway.costSamples, 2); XCTAssertEqual(all.gateway.costUSD, 0.005)
        XCTAssertEqual(all.gateway.cacheHits, 1); XCTAssertEqual(all.gateway.cacheMisses, 1); XCTAssertEqual(all.gateway.cacheConflicts, 1); XCTAssertEqual(all.gateway.cacheUnreported, 1)
        XCTAssertEqual(all.buckets[0].gateway.costUSD, 0); XCTAssertEqual(all.buckets[1].gateway.costUSD, 0.005)
        XCTAssertEqual(all.requests.first { $0.id == zero }?.gateway.costUSD, 0)
        let complete = try await archive.dashboard(filter(status: "completed"))
        XCTAssertEqual(complete.gateway.requests, 1); XCTAssertEqual(complete.gateway.costUSD, 0); XCTAssertEqual(complete.gateway.costSamples, 1)
        let failed = try await archive.dashboard(filter(status: "failed"))
        XCTAssertNil(failed.gateway.costUSD); XCTAssertEqual(failed.gateway.costSamples, 0)
        XCTAssertEqual(gatewayUSD(0), "$0 USD"); XCTAssertEqual(gatewayUSD(nil), "Cost unavailable")
        XCTAssertNotEqual(gatewayUSD(0.000000001), "$0 USD")
    }

    func testInlineUsageMovesFromUserToStreamingAnswerAndPreservesRequestDetails() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        var metadata = value(output: [], outcome: "running")
        let id = try await save(archive, metadata)
        let user = TranscriptMessage(id: "user-1", role: "user", text: "Question")
        var streaming = TranscriptMessage(id: "answer", role: "assistant", text: "Partial")
        streaming.state = "streaming"
        let pending = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [user])
        XCTAssertEqual(pending.messages[user.id]?.requests, 1)
        XCTAssertEqual(pending.messages[user.id]?.models?.unreportedRequests, 1)
        let during = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [user, streaming])
        XCTAssertNil(during.messages[user.id]); XCTAssertEqual(during.messages[streaming.id]?.requests, 1)
        metadata["outputMessageIds"] = .array([.string("answer"), .string("tool"), .string("duplicate-link")])
        metadata["outcome"] = .string("completed")
        metadata["usage"] = .object(["inputIncludingCache": .number(38), "output": .number(423), "reasoning": .number(326), "total": .number(461), "cacheRead": .number(0), "cacheWrite": .number(0)])
        metadata["identity"] = .object(["status": .string("reported"), "effectiveModel": .string("gpt-5.4-mini")])
        try await archive.finish(metadata)
        streaming.state = nil
        let complete = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [user, streaming, .init(id: "tool", role: "tool", text: "result"), .init(id: "duplicate-link", role: "assistant", text: "Repeated origin")])
        XCTAssertEqual(complete.messages.keys.sorted(), ["answer"])
        XCTAssertEqual(complete.messages["answer"]?.models?.names, ["gpt-5.4-mini"])
        XCTAssertEqual(complete.messages["answer"]?.models?.reportedRequests, 1)
        XCTAssertNil(complete.session.models, "Message identity must not change session accounting totals")
        XCTAssertEqual(complete.session.tokens?.input, 38); XCTAssertEqual(complete.session.tokens?.output, 423)
        XCTAssertEqual(complete.session.tokens?.total, 461, "Reasoning is already included in output")
        XCTAssertNil(complete.session.costUSD); XCTAssertEqual(complete.session.costSamples, 0)
        XCTAssertEqual(complete.session.cacheWriteTokens, 0); XCTAssertEqual(complete.session.cacheWriteSamples, 1)
        let details = try await archive.list(sessionID: "session", messageID: user.id, workspaceID: "workspace")
        XCTAssertEqual(details.first?["attemptId"]?.string, id, "User Details remains available after inline ownership moves")
        let report = try await archive.dashboard(filter())
        XCTAssertEqual(report.gateway.tokens?.total, 461); XCTAssertNil(report.gateway.costUSD)
        XCTAssertEqual(report.requests.first?.effectiveModel, "gpt-5.4-mini")
        let grouped = try await archive.sessionSummaries(filter())
        XCTAssertEqual(grouped.sessions.first?.gateway.tokens?.total, 461)
        XCTAssertNil(grouped.sessions.first?.gateway.costUSD)
        try await archive.close()
    }

    func testAccountingSurvivesReopenBodyPurgeAndSchemaBackfillButExpiresWithMetrics() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = AccountingClock(), key = Data(repeating: 3, count: 32)
        let archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let id = try await save(archive, value(cost: 0.125, cache: "hit"))
        try await archive.purge(attemptID: id); try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("ALTER TABLE attempts DROP COLUMN cost_usd")
        }
        let reopened = PayloadArchive(root: root, now: { clock.now() })
        try await reopened.configure(key: key, quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let before = try await reopened.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        XCTAssertEqual(before.session.costUSD, 0.125); XCTAssertEqual(before.session.cacheHits, 1)
        clock.advance(101)
        let after = try await reopened.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        XCTAssertNil(after.session.costUSD); XCTAssertEqual(after.session.requests, 0); XCTAssertEqual(after.session.expiredRecords, 1)
    }

    func testReportedReasoningSubsetSurvivesProjectionMigrationWithoutIncreasingTotalCostOrTokens() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = AccountingClock()
        let archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        var metadata = value(cost: 0.0013875)
        metadata["usage"] = .object(["inputIncludingCache": .number(38), "output": .number(302), "reasoning": .number(253), "cacheRead": .number(0), "cacheWrite": .number(0)])
        var gateway = metadata["gateway"]!.object!
        gateway["costBreakdown"] = .object(["reasoning": .object(["status": .string("reported"), "usd": .number(0.0011385), "source": .string("header:x-litellm-response-cost-reasoning")])])
        metadata["gateway"] = .object(gateway)
        let id = try await save(archive, metadata)
        try await archive.purge(attemptID: id); try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("ALTER TABLE attempts DROP COLUMN reasoning_cost_usd")
            try db.execute("ALTER TABLE attempts DROP COLUMN reasoning_tokens")
        }
        let reopened = PayloadArchive(root: root, now: { clock.now() })
        try await reopened.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let report = try await reopened.dashboard(filter())
        XCTAssertEqual(report.gateway.costUSD, 0.0013875); XCTAssertEqual(report.gateway.tokens?.total, 340)
        XCTAssertEqual(report.gateway.reasoningCostUSD, 0.0011385); XCTAssertEqual(report.gateway.reasoningCostSamples, 1)
        XCTAssertEqual(report.gateway.tokens?.reasoning, 253); XCTAssertEqual(report.gateway.tokens?.reasoningSamples, 1)
        XCTAssertEqual(report.requests.first?.gateway.reasoningCostUSD, 0.0011385)
        XCTAssertEqual(report.requests.first?.gateway.reasoningCostStatus, "reported")
        let grouped = try await reopened.sessionSummaries(filter())
        XCTAssertEqual(grouped.sessions.first?.gateway, report.gateway)
        let accounting = try await reopened.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [.init(id: "assistant-1", role: "assistant", text: "Answer")])
        XCTAssertEqual(accounting.session, report.gateway)
        var messageTotals = accounting.messages["assistant-1"]
        XCTAssertEqual(messageTotals?.models?.unreportedRequests, 1)
        messageTotals?.models = nil
        XCTAssertEqual(messageTotals, report.gateway)
        clock.advance(101)
        let expired = try await reopened.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        XCTAssertNil(expired.session.reasoningCostUSD); XCTAssertEqual(expired.session.reasoningCostSamples, 0); XCTAssertNil(expired.session.tokens)
        try await reopened.close()
    }

    func testCompactionSummaryKeepsItsOwnAccountingWithoutDuplicatingTurnUsage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await save(archive, value(turn: "user-1", output: ["summary"], cost: 0.01, purpose: "compaction"))
        try await save(archive, value(turn: "user-1", output: ["answer"], cost: 0.02))
        var summary = TranscriptMessage(id: "summary", role: "system", text: "Compacted")
        summary.kind = "compaction"
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [.init(id: "user-1", role: "user", text: "Question"), summary, .init(id: "answer", role: "assistant", text: "Answer")])
        XCTAssertNil(result.messages["user-1"])
        XCTAssertEqual(result.messages["summary"]?.costUSD, 0.01); XCTAssertEqual(result.messages["answer"]?.costUSD, 0.02)
        XCTAssertEqual(result.session.costUSD ?? 0, 0.03, accuracy: 1e-10)
        try await archive.close()
    }

    func testInterruptedBackfillResumesEvenAfterEveryColumnAlreadyExists() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for index in 1...65 {
            var metadata = value(cost: 0.01, cache: "hit")
            metadata["attemptId"] = .string(String(format: "00000000-0000-0000-0000-%012d", index))
            try await save(archive, metadata)
        }
        try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("DELETE FROM archive_info WHERE name='dashboard-projection'")
            try db.execute("UPDATE attempts SET cost_usd=NULL,cost_status='unreported',cache_status='unreported'")
            try db.execute("CREATE TRIGGER interrupt_projection BEFORE UPDATE OF cost_usd ON attempts WHEN NEW.id='00000000-0000-0000-0000-000000000040' BEGIN SELECT RAISE(ABORT,'synthetic interrupted backfill'); END")
        }
        let interrupted = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        do { try await interrupted.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000); XCTFail("Injected interruption must abort opening") } catch { }
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            XCTAssertEqual(try db.rows("SELECT COUNT(cost_usd) AS n FROM attempts").first?["n"]?.number, 32)
            XCTAssertTrue(try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").isEmpty)
            try db.execute("DROP TRIGGER interrupt_projection")
        }
        let recovered = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await recovered.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let totals = try await recovered.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        XCTAssertEqual(totals.session.costSamples, 65); XCTAssertEqual(totals.session.cacheHits, 65)
        XCTAssertEqual(try XCTUnwrap(totals.session.costUSD), 0.65, accuracy: 0.000000001)
    }

    @MainActor func testRetentionPreferenceRefreshesUnloadedChatAndMessageAccounting() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        model.chats = [.init(id: "session", workspaceID: "workspace", title: "Saved chat", path: nil, profileID: "profile")]
        let view = SessionDisplay(id: "session")
        view.messages = [.init(id: "assistant-1", role: "assistant", text: "Saved answer")]
        model.displays[view.id] = view; model.selected = view; model.selectedID = view.id
        let metadata = value(cost: 0.25, cache: "hit", wall: Date().timeIntervalSince1970 - 10 * 86400)
        try await model.traces.begin(metadata, workspace: "workspace"); try await model.traces.finish(metadata)
        await model.refreshRetainedAccounting()
        XCTAssertEqual(view.footer.gateway.costUSD, 0.25); XCTAssertEqual(view.messages.first?.accounting?.costUSD, 0.25)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        try await model.updateConfiguration { $0.dashboard.metricRetentionDays = 1 }
        XCTAssertNil(view.footer.gateway.costUSD); XCTAssertEqual(view.footer.gateway.expiredRecords, 1)
        XCTAssertNil(view.messages.first?.accounting); XCTAssertTrue(view.messageAccounting.isEmpty)
        XCTAssertTrue(model.hosts.isEmpty, "Refreshing retained accounting must not start a model host")
        try await model.traces.close(); await model.store?.close()
    }

    func testMalformedNegativeUnknownVersionAndProviderPromptCacheNeverInventGatewayCostOrHit() throws {
        var metadata = value(cache: "unreported")
        let absent = GatewayObservation(metadata: metadata)
        XCTAssertNil(absent.costUSD); XCTAssertEqual(absent.cacheStatus, "unreported"); XCTAssertEqual(absent.cacheReadTokens, 20)
        for invalid in [-1.0, Double.infinity, Double.nan, 1e20] {
            metadata["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(invalid)])])
            let result = GatewayObservation(metadata: metadata)
            XCTAssertNil(result.costUSD); XCTAssertEqual(result.costStatus, "invalid")
        }
        metadata["gateway"] = .object(["version": .number(2), "cost": .object(["status": .string("reported"), "usd": .number(2)]), "cache": .object(["status": .string("hit")])])
        XCTAssertNil(GatewayObservation(metadata: metadata).costUSD); XCTAssertEqual(GatewayObservation(metadata: metadata).cacheStatus, "unreported")
        metadata["usage"] = .object(["cacheRead": .number(1.5), "cacheWrite": .number(-1)])
        XCTAssertNil(GatewayObservation(metadata: metadata).cacheReadTokens); XCTAssertNil(GatewayObservation(metadata: metadata).cacheWriteTokens)
    }

    func testUncachedInputRequiresKnownCountersForTheSameRequests() {
        var totals = GatewayTotals(requests: 2, cacheReadTokens: 10, cacheReadSamples: 1)
        totals.tokens = GatewayTokenTotals(input: 38, inputSamples: 1)
        XCTAssertNil(totals.uncachedInputTokens, "Equal partial counts might represent different attempts")
        totals.cacheReadSamples = 2; totals.tokens?.inputSamples = 2
        XCTAssertEqual(totals.uncachedInputTokens, 28)
        totals.cacheReadTokens = nil; XCTAssertNil(totals.uncachedInputTokens)
        totals.cacheReadTokens = 39; XCTAssertNil(totals.uncachedInputTokens)
        var observation = GatewayObservation(metadata: ["usage": .object(["inputIncludingCache": .number(38)])])
        XCTAssertNil(observation.uncachedInputTokens)
        observation.cacheReadTokens = 0; XCTAssertEqual(observation.uncachedInputTokens, 38)
        observation.cacheReadTokens = 39; XCTAssertNil(observation.uncachedInputTokens)
    }

    func testPartialPromptCacheTotalsUsePairedRequestsAcrossSessionAndReport() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let usages: [[String: WireValue]] = [
            ["inputIncludingCache": .number(100), "cacheRead": .number(80)],
            ["inputIncludingCache": .number(200)],
            ["cacheRead": .number(300)],
            ["inputIncludingCache": .number(50), "cacheRead": .number(10)],
            ["inputIncludingCache": .number(5), "cacheRead": .number(8)]
        ]
        for usage in usages {
            var entry = value(); entry["usage"] = .object(usage)
            try await save(archive, entry)
        }
        let session = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        let dashboard = try await archive.dashboard(filter())
        for totals in [session.session, dashboard.gateway] {
            XCTAssertEqual(totals.uncachedInputTokens, 60, "Only 100−80 and 50−10 are valid paired observations")
            XCTAssertEqual(totals.uncachedInputSampleCount, 2)
            XCTAssertEqual(totals.cacheReadSamples, 4)
            XCTAssertEqual(totals.tokens?.inputSamples, 4)
            XCTAssertTrue(totals.promptCacheCoverageLabel.contains("2/5"))
        }
        try await archive.close()
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let restored = try await archive.dashboard(filter())
        XCTAssertEqual(restored.gateway.uncachedInputTokens, 60)
        XCTAssertEqual(restored.gateway.uncachedInputSampleCount, 2)
        try await archive.close()
    }

    func testReasoningFieldsKeepOlderSnapshotsReadableAndRejectImpossibleSubsets() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayTotals(requests: 1))) as! [String: Any]
        old.removeValue(forKey: "reasoningCostSamples"); old.removeValue(forKey: "reasoningCostUSD")
        old["tokens"] = ["input": 38, "output": 302, "total": 340, "inputSamples": 1, "outputSamples": 1, "samples": 1]
        let decoded = try JSONDecoder().decode(GatewayTotals.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.tokens?.total, 340); XCTAssertNil(decoded.tokens?.reasoning); XCTAssertNil(decoded.reasoningCostUSD)
        let invalid = GatewayObservation(metadata: ["usage": .object(["output": .number(302), "reasoning": .number(303)]),
            "gateway": .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.001)]),
                "costBreakdown": .object(["reasoning": .object(["status": .string("reported"), "usd": .number(0.002)])])])])
        XCTAssertNil(invalid.reasoningTokens); XCTAssertNil(invalid.reasoningCostUSD); XCTAssertEqual(invalid.reasoningCostStatus, "conflict")
        XCTAssertEqual(invalid.costUSD, 0.001)
    }

    func testMessageAccountingQueriesBoundInputAndNoSensitiveEvidenceReachesTranscript() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: Data(repeating: 4, count: 32), quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await save(archive, value(cost: 0.1))
        let message = TranscriptMessage(id: "assistant-1", role: "assistant", text: "Answer")
        do { _ = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [message, message]); XCTFail("Duplicate targets multiply rows") } catch { }
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [message])
        var projected = message; projected.accounting = result.messages[message.id]
        let text = String(decoding: try JSONEncoder().encode(projected), as: UTF8.self)
        XCTAssertTrue(text.contains("costUSD")); XCTAssertFalse(text.contains("header:")); XCTAssertFalse(text.contains("requestHeaders")); XCTAssertFalse(text.contains("gateway"))
    }

    func testRequestNavigationPrioritizesOutputEvenWithLargeContextAndUsesItsTurnFallback() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        var metadata = value(turn: "current-user", output: ["answer"])
        metadata["messageIds"] = .array((0..<300).map { .string("context-\($0)") })
        let id = try await save(archive, metadata)
        let links = try await archive.linkedMessages(attemptID: id)
        XCTAssertEqual(links.output, ["answer"])
        XCTAssertEqual(links.turn, "current-user", "Fallback is the triggering turn, not a sorted UUID")
        try await archive.close()
    }

    func testInlineModelNamesComeFromResolvedGatewayIdentityAndPreserveCoverage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let identities: [(String, String?)] = [
            ("reported", "gpt-5.4-mini"), ("reported", "gpt-5.4-mini"), ("reported", "claude-sonnet-4.5"),
            ("unreported", nil), ("reported", "router"), ("conflict", nil), ("incomplete", nil)
        ]
        for (status, name) in identities {
            var metadata = value(cost: 0.001)
            metadata["identity"] = .object(["status": .string(status), "effectiveModel": name.map(WireValue.string) ?? .null,
                                            "evidence": .array([.object(["source": .string("header:x-litellm-model-name"), "value": .string("private-evidence"), "kind": .string("model")])])])
            try await save(archive, metadata)
        }
        // Same linked output in another project must not enter this summary.
        var other = value()
        other["identity"] = .object(["status": .string("reported"), "effectiveModel": .string("other-project-model")])
        try await save(archive, other, workspace: "other")
        let user = TranscriptMessage(id: "user-1", role: "user", text: "Question")
        let answer = TranscriptMessage(id: "assistant-1", role: "assistant", text: "Answer")
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [user, answer])
        XCTAssertNil(result.messages[user.id])
        let summary = try XCTUnwrap(result.messages[answer.id]?.models)
        XCTAssertEqual(summary.names, ["gpt-5.4-mini", "claude-sonnet-4.5"])
        XCTAssertEqual(summary.nameCount, 2); XCTAssertEqual(summary.reportedRequests, 3)
        XCTAssertEqual(summary.unreportedRequests, 2, "An echoed requested alias is not a resolved model")
        XCTAssertEqual(summary.conflictingRequests, 1); XCTAssertEqual(summary.incompleteRequests, 1)
        let encoded = String(decoding: try JSONEncoder().encode(result.messages[answer.id]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-evidence")); XCTAssertFalse(encoded.contains("header:"))
        XCTAssertFalse(encoded.contains("other-project-model")); XCTAssertFalse(encoded.contains("\"router\""))
        try await archive.close()
    }

    func testInlineModelNamesAreBoundedWithoutLosingModelOrRequestCounts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for index in 0..<18 {
            var metadata = value()
            metadata["identity"] = .object(["status": .string("reported"), "effectiveModel": .string(String(format: "model-%02d", index))])
            try await save(archive, metadata)
        }
        try await save(archive, value())
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [.init(id: "assistant-1", role: "assistant", text: "Answer")])
        let summary = try XCTUnwrap(result.messages["assistant-1"]?.models)
        XCTAssertEqual(summary.names, (0..<8).map { String(format: "model-%02d", $0) })
        XCTAssertEqual(summary.nameCount, 18); XCTAssertEqual(summary.reportedRequests, 18)
        XCTAssertEqual(summary.unreportedRequests, 1, "Coverage includes groups outside the visible names")
        XCTAssertEqual(result.messages["assistant-1"]?.requests, 19)
        try await archive.close()
    }

    func testInlineBodyModelWinsHeaderDifferenceWithoutChangingIdentityOrCost() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        func report(_ source: String, _ name: String) -> WireValue { .object(["source": .string(source), "value": .string(name), "kind": .string("model")]) }
        var metadata = value(cost: 0.0013875)
        metadata["requestedModel"] = .string("auto-router")
        metadata["identity"] = .object(["status": .string("conflict"), "effectiveModel": .null,
            "reportedModels": .array([.string("tiny-header-name"), .string("gpt-5.4-mini-2026-09-16")]),
            "evidence": .array([report("header:x-litellm-model-name", "tiny-header-name"),
                                 report("response.completed.response.model", "auto-router"),
                                 report("response.completed.response.router_model_name", "gpt-5.4-mini-2026-09-16")])])
        let id = try await save(archive, metadata)
        let rows: [TranscriptMessage] = [.init(id: "user-1", role: "user", text: "Question"), .init(id: "assistant-1", role: "assistant", text: "Answer")]
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: rows)
        let summary = try XCTUnwrap(result.messages["assistant-1"]?.models)
        XCTAssertEqual(summary.names, ["gpt-5.4-mini-2026-09-16"], "Choose response router_model_name, not the shorter header or body alias")
        XCTAssertEqual(summary.displayRequests, 1); XCTAssertEqual(summary.reportedRequests, 0); XCTAssertEqual(summary.conflictingRequests, 1)
        XCTAssertNil(result.messages["user-1"]); XCTAssertEqual(result.session.costUSD, 0.0013875)
        let retained = try await archive.metadata(attempt: id)
        XCTAssertEqual(retained["identity"], metadata["identity"], "Display preference must not rewrite evidence or route verification")
        let detail = GatewayModelIdentity(metadata: retained)
        XCTAssertEqual(detail.response?.name, summary.names.first)
        XCTAssertEqual(detail.headerReports.map(\.name), ["tiny-header-name"], "Click-through retains the other model with its source")
        let bridge = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(bridge.contains("tiny-header-name")); XCTAssertFalse(bridge.contains("header:"))
        try await archive.close()
    }

    func testLatestOwnedResponseBodyNameIsPrimaryAndAliasEchoIsNotAResolvedIdentity() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for (wall, name, status) in [(1991.0, "first-model", "reported"), (1992.0, "final-model", "conflict"), (1993.0, "auto-router", "unreported")] {
            var metadata = value(wall: wall)
            metadata["requestedModel"] = .string("auto-router")
            metadata["identity"] = .object(["status": .string(status), "effectiveModel": status == "reported" ? .string(name) : .null,
                "evidence": .array([.object(["source": .string("body.model"), "value": .string(name), "kind": .string("model")])])])
            try await save(archive, metadata)
        }
        let result = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [.init(id: "assistant-1", role: "assistant", text: "Answer")])
        let models = try XCTUnwrap(result.messages["assistant-1"]?.models)
        XCTAssertEqual(models.names, ["auto-router", "final-model", "first-model"])
        XCTAssertEqual(models.displayRequests, 3); XCTAssertEqual(models.nameCount, 3)
        XCTAssertEqual(models.reportedRequests, 1); XCTAssertEqual(models.conflictingRequests, 1); XCTAssertEqual(models.unreportedRequests, 1)
        try await archive.close()
    }

    func testBodyModelProjectionBackfillsExistingMetadataAndExpiresWithMetrics() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = AccountingClock(), archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        var metadata = value(cost: 0.02)
        metadata["identity"] = .object(["status": .string("conflict"), "effectiveModel": .null,
            "evidence": .array([.object(["source": .string("body.router_model_name"), "value": .string("retained-body-model"), "kind": .string("model")])])])
        let id = try await save(archive, metadata)
        try await archive.purge(attemptID: id); try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("ALTER TABLE attempts DROP COLUMN response_model")
            try db.execute("UPDATE archive_info SET value=? WHERE name='dashboard-projection'", [.blob(Data([5]))])
        }
        let reopened = PayloadArchive(root: root, now: { clock.now() })
        try await reopened.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let messages = [TranscriptMessage(id: "assistant-1", role: "assistant", text: "Answer")]
        clock.advance(11)
        let result = try await reopened.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: messages)
        XCTAssertEqual(result.messages["assistant-1"]?.models?.names, ["retained-body-model"])
        XCTAssertEqual(result.session.costUSD, 0.02)
        clock.advance(101)
        let expired = try await reopened.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: messages)
        XCTAssertTrue(expired.messages.isEmpty); XCTAssertEqual(expired.session.expiredRecords, 1)
        try await reopened.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        XCTAssertNil(try db.rows("SELECT response_model FROM attempts WHERE id=?", [.text(id)]).first?["response_model"]?.string)
        XCTAssertEqual(try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").first?["value"]?.data, Data([7]))
    }
}
