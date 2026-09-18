import XCTest
@testable import PiApp

private final class MenuMetricsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 1_000_000
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ value: Double) { lock.lock(); defer { lock.unlock() }; seconds += value }
}

@MainActor private final class MenuMetricsActivity { var count = 2 }

final class MenuBarMetricsTests: XCTestCase {
    func testSidebarUsesConsumedSessionTokensAcrossToolRoundsWithPartialCoverage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await save(archive, value(usage: ["inputIncludingCache": .number(30), "output": .number(12)]))
        try await save(archive, value(usage: ["inputIncludingCache": .number(38), "output": .number(12)]))
        var snapshot = try await archive.menuBarMetrics(period: .retained, until: until)
        var row = ChatRowStats(totals: snapshot.gateway)
        XCTAssertEqual(row.tokensLabel, "92 tok", "Use both HTTP rounds, never just the last context checkpoint of 50 tokens")
        XCTAssertTrue(row.tokensHelp.contains("2/2 requests")); XCTAssertFalse(row.tokensHelp.contains("Partial total"))
        try await save(archive, value())
        snapshot = try await archive.menuBarMetrics(period: .retained, until: until)
        row = ChatRowStats(totals: snapshot.gateway)
        XCTAssertEqual(row.tokensLabel, "92 tok")
        XCTAssertTrue(row.tokensHelp.contains("2/3 requests")); XCTAssertTrue(row.tokensHelp.contains("Partial total; missing usage is excluded"))
        XCTAssertEqual(ChatRowStats(totals: GatewayTotals(requests: 1)).tokensLabel, "tok n/a")
        var zero = GatewayTotals(requests: 1); zero.tokens = GatewayTokenTotals(input: 0, output: 0, total: 0, inputSamples: 1, outputSamples: 1, samples: 1)
        XCTAssertEqual(ChatRowStats(totals: zero).tokensLabel, "0 tok")
        XCTAssertNil(ChatRowStats(totals: nil).tokensLabel)
        try await archive.close()
    }

    func testSidebarUsageBreaksDownInputCachedAndOutputWithoutInventingZeros() {
        var totals = GatewayTotals(requests: 3)
        totals.tokens = GatewayTokenTotals(input: 12_480, output: 2_400, total: 14_880, inputSamples: 3, outputSamples: 3, samples: 3)
        totals.cacheReadTokens = 8_100; totals.cacheReadSamples = 2
        let row = ChatRowStats(totals: totals)
        XCTAssertEqual(row.usageLabel, "12k in · 8.1k cached · 2.4k out")
        XCTAssertTrue(row.usageHelp.contains("input 12,480 (3/3 requests reported)") && row.usageHelp.contains("cached input 8,100 (2/3 reported)") && row.usageHelp.contains("output 2,400 (3/3 reported)"), row.usageHelp)
        XCTAssertEqual(ChatRowStats(totals: GatewayTotals(requests: 1)).usageLabel, "n/a in · n/a cached · n/a out", "Unreported usage never reads as zero")
        XCTAssertNil(ChatRowStats(totals: nil).usageLabel)
        XCTAssertEqual(compactTokens(812), "812"); XCTAssertEqual(compactTokens(1_000), "1k"); XCTAssertEqual(compactTokens(1_260_000), "1.3M")
    }

    func testFooterSplitsSessionAndTurnTimeBetweenModelAndTools() {
        XCTAssertNil(WorkSplit(timing: [:]))
        XCTAssertNil(WorkSplit(timing: ["sessionModelMs": .number(0), "sessionToolMs": .number(0)]), "No work yet means no split")
        let split = WorkSplit(timing: ["sessionModelMs": .number(72_000), "sessionToolMs": .number(14_300), "modelMs": .number(4_200), "toolMs": .number(300), "elapsedMs": .number(4_500)])
        XCTAssertEqual(split?.label, "model 1m 12s · tools 14.3s")
        XCTAssertEqual(split?.turn, "model 4.2s · tools 0.3s")
        XCTAssertEqual(workDuration(400), "0.4s"); XCTAssertEqual(workDuration(3_753_000), "1h 2m"); XCTAssertEqual(workDuration(-1), "n/a")
    }

    @MainActor func testStatusControllerSupportsBothMouseButtons() {
        XCTAssertEqual(MenuBarController.clickEvents, [.leftMouseUp, .rightMouseUp])
        XCTAssertEqual(MenuBarChartMetric.allCases.map(\.title), ["Requests", "Cost", "Output tok/s"])
    }

    func testMenuBarBucketsSliceThePeriodAndCarryCostAndOutputRate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        // The day window is 913,600...1,000,000 in hourly slices.
        try await save(archive, value(wall: 915_000, cost: 0.01, usage: ["inputIncludingCache": .number(30), "output": .number(40)], generationMilliseconds: 2_000))
        try await save(archive, value(wall: 950_000, cost: 0.02, usage: ["inputIncludingCache": .number(30), "output": .number(10)], generationMilliseconds: 1_000))
        try await save(archive, value(wall: 999_999, outcome: "failed"))
        let snapshot = try await archive.menuBarMetrics(period: .day, until: until)
        XCTAssertEqual(snapshot.buckets.count, 24)
        XCTAssertEqual(snapshot.buckets.first?.start, until.addingTimeInterval(-86_400)); XCTAssertEqual(snapshot.buckets.last?.end, until)
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.requests }, 3, "Every dispatched attempt lands in exactly one slice")
        let first = try XCTUnwrap(snapshot.buckets.first { $0.requests > 0 })
        XCTAssertEqual(first.id, 0); XCTAssertEqual(first.gateway.costUSD ?? 0, 0.01, accuracy: 1e-9); XCTAssertEqual(first.historicalRate.tokensPerSecond ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(snapshot.buckets[10].requests, 1); XCTAssertEqual(snapshot.buckets[10].gateway.costUSD ?? 0, 0.02, accuracy: 1e-9)
        let last = try XCTUnwrap(snapshot.buckets.last)
        XCTAssertEqual(last.requests, 1); XCTAssertNil(last.gateway.costUSD); XCTAssertNil(last.historicalRate.tokensPerSecond, "A failed attempt has no completed output rate")
        let week = try await archive.menuBarMetrics(period: .week, until: until)
        XCTAssertEqual(week.buckets.count, 28)
        try await archive.close()
    }

    @MainActor func testActivitySeparatesRunningPendingAndStaleSpeedAndKeepsUnopenedUnreadChats() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let workspace = WorkspaceRecord(id: "workspace", path: root.path, trusted: true)
        model.workspaces = [workspace]
        for id in ["live", "tool", "queued", "unopened"] {
            model.chats.append(ChatRecord(id: id, workspaceID: workspace.id, title: id, path: nil, profileID: "profile"))
        }
        let live = SessionDisplay(id: "live"); live.state = "running"; live.activityObservedAt = 100
        live.activity = ["version": .number(1), "phase": .string("model"), "model": .string("auto-router"), "modelActive": .bool(true), "pendingFollowUps": .number(2), "pendingSteering": .number(1), "estimatedOutputTokensPerSecond": .number(12.5)]
        live.metrics = ["requestedModel": .string("auto-router"), "identity": .object(["status": .string("reported"), "effectiveModel": .string("openai/gpt-5.4-mini")])]
        let tool = SessionDisplay(id: "tool"); tool.state = "running"; tool.activityObservedAt = 100
        tool.activity = ["version": .number(1), "phase": .string("tool"), "modelActive": .bool(false), "toolNames": .array([.string("read")]), "estimatedOutputTokensPerSecond": .number(999)]
        let queued = SessionDisplay(id: "queued"); queued.state = "queued"; queued.queueCount = 1
        model.displays = [live.id: live, tool.id: tool, queued.id: queued]
        model.unreadStates["unopened"] = SessionReadState(id: "unopened", observedAssistantCount: 3, latestAssistantID: "answer", unreadOutputs: 2, unreadTargetID: "answer")
        let current = model.menuBarActivity(now: 101)
        XCTAssertEqual(current.running, 2); XCTAssertEqual(current.queuedChats, 1)
        XCTAssertEqual(current.pending, 4)
        XCTAssertEqual(current.runningRows.map(\.id), ["live", "tool"]); XCTAssertEqual(current.attentionRows.map(\.id), ["queued"]); XCTAssertEqual(current.unreadRows.map(\.id), ["unopened"])
        XCTAssertEqual(current.rows.first { $0.id == "live" }?.resolvedModel, "openai/gpt-5.4-mini")
        XCTAssertEqual(current.rows.first { $0.id == "tool" }?.tools, ["read"])
        XCTAssertEqual(current.rows.first { $0.id == "unopened" }?.unread, 2)
        XCTAssertEqual(current.unreadChats, 1); XCTAssertNil(model.displays["unopened"])
        XCTAssertTrue(model.hosts.isEmpty, "Inspecting the status item never opens helpers")
    }

    func testReasoningSummaryPreservesMissingZeroAndPartialCoverageWithoutAddingToOutput() {
        var totals = GatewayTotals(requests: 3)
        XCTAssertEqual(reasoningUsageSummary(totals), "Reasoning Unavailable tokens (0/3 reported) · Cost unavailable (0/3 reported) · included in output")
        totals.tokens = GatewayTokenTotals(input: 38, output: 302, total: 340, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 253, reasoningSamples: 1)
        totals.costUSD = 0.0013875; totals.costSamples = 1
        totals.reasoningCostUSD = 0.0011385; totals.reasoningCostSamples = 1
        XCTAssertEqual(reasoningUsageSummary(totals), "Reasoning 253 tokens (1/3 reported) · $0.0011385 USD (1/3 reported) · included in output")
        XCTAssertEqual(totals.tokens?.total, 340); XCTAssertEqual(totals.costUSD, 0.0013875)
        totals.tokens?.reasoning = 0; totals.reasoningCostUSD = 0
        XCTAssertTrue(reasoningUsageSummary(totals).contains("Reasoning 0 tokens (1/3 reported) · $0 USD (1/3 reported)"))
    }

    private let until = Date(timeIntervalSince1970: 1_000_000)
    private func folder() throws -> URL {
        let base = ProcessInfo.processInfo.environment["PI_BUILD_ROOT"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("menu-metrics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func value(alias: String = "auto-router", model: String? = "provider/model-a", identity: String = "reported", api: String = "openai-responses", wall: Double = 999_995, outcome: String = "completed", cost: Double? = nil, cache: String = "unreported", usage: [String: WireValue] = [:], purpose: String = "turn", session: String = "session", generationMilliseconds: Double? = 20, ttftMilliseconds: Double? = 10) -> [String: WireValue] {
        var timings: [String: WireValue] = ["dispatch": .number(100)]
        if let ttftMilliseconds { timings["firstContent"] = .number(100 + ttftMilliseconds) }
        if let generationMilliseconds { timings["modelComplete"] = .number(100 + generationMilliseconds); timings["httpEnd"] = .number(110 + generationMilliseconds) }
        return ["attemptId": .string(UUID().uuidString), "sessionId": .string(session), "turnId": .string("user-1"), "purpose": .string(purpose), "api": .string(api), "requestedModel": .string(alias), "mode": .string("off"), "outcome": .string(outcome), "wallTimestamp": .number(wall - 10), "dispatchWallTimestamp": .number(wall), "timingVersion": .number(2), "timings": .object(timings), "messageIds": .array([.string("user-1"), .string("assistant-1")]), "outputMessageIds": .array([.string("assistant-2"), .string("tool-1")]),
         "identity": .object(["status": .string(identity), "effectiveModel": model.map(WireValue.string) ?? .null]),
         "gateway": .object(["version": .number(1), "cost": .object(["status": .string(cost == nil ? "unreported" : "reported"), "usd": cost.map(WireValue.number) ?? .null]), "cache": .object(["status": .string(cache)])]), "usage": .object(usage)]
    }
    @discardableResult private func save(_ archive: PayloadArchive, _ metadata: [String: WireValue], workspace: String = "workspace") async throws -> String {
        try await archive.begin(metadata, workspace: workspace)
        if metadata["outcome"]?.string == "running" { try await archive.update(metadata) }
        else { try await archive.finish(metadata) }
        return metadata["attemptId"]!.string!
    }
    private func configured(_ root: URL) async throws -> PayloadArchive {
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 1_000_000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10_000_000)
        return archive
    }

    func testHistoricalOutputRateWeightsDurationsAndCountsToolCompactionAttemptsOnce() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        var first = value(usage: ["output": .number(100), "reasoning": .number(80)], generationMilliseconds: 1_000, ttftMilliseconds: 900)
        try await save(archive, first)
        first["outputMessageIds"] = .array([.string("assistant-2"), .string("tool-1"), .string("tool-2")])
        for _ in 0..<3 { try await archive.update(first) }
        try await save(archive, value(usage: ["output": .number(100)], generationMilliseconds: 3_000, ttftMilliseconds: 2_000))
        try await save(archive, value(model: "provider/model-b", usage: ["output": .number(0)], purpose: "compaction", generationMilliseconds: 1_000, ttftMilliseconds: 1_000))

        let snapshot = try await archive.menuBarMetrics(period: .retained, until: until)
        XCTAssertEqual(snapshot.historicalRate, HistoricalOutputRate(outputTokens: 200, generationMilliseconds: 5_000, samples: 3))
        XCTAssertEqual(snapshot.historicalRate.tokensPerSecond, 40, "Reasoning is already included in output; repeated links/updates never add samples")
        let modelA = try XCTUnwrap(snapshot.models.first { $0.resolvedModel == "provider/model-a" })
        XCTAssertEqual(modelA.historicalRate.tokensPerSecond, 50, "Use 200 / 4 dispatch-to-completion seconds, including 2.9 seconds before first content; never average individual rates")
        XCTAssertEqual(modelA.historicalRate.samples, 2)
        let zero = try XCTUnwrap(snapshot.models.first { $0.resolvedModel == "provider/model-b" })
        XCTAssertEqual(zero.historicalRate.tokensPerSecond, 0); XCTAssertEqual(zero.historicalRate.samples, 1)
        XCTAssertEqual(snapshot.gateway.requests, 3); XCTAssertEqual(snapshot.compactionRequests, 1)
        try await archive.close()
    }

    func testBufferedResponsesUseTimeToFirstContentWhenStreamIntervalIsZero() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await save(archive, value(usage: ["output": .number(120), "reasoning": .number(100)], generationMilliseconds: 2_000, ttftMilliseconds: 2_000))
        try await save(archive, value(usage: ["output": .number(0)], generationMilliseconds: 1_000, ttftMilliseconds: 1_000))
        let snapshot = try await archive.menuBarMetrics(period: .retained, until: until)
        XCTAssertEqual(snapshot.historicalRate, HistoricalOutputRate(outputTokens: 120, generationMilliseconds: 3_000, samples: 2))
        XCTAssertEqual(snapshot.historicalRate.tokensPerSecond, 40, "Buffered JSON and opaque reasoning cannot produce an infinite or exaggerated historical rate")
        XCTAssertEqual(snapshot.models.first?.historicalRate, snapshot.historicalRate)
        try await archive.close()
    }

    func testHistoricalOutputRateExcludesUnavailableInvalidAndUnfinishedSamples() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await save(archive, value(usage: ["output": .number(100)], generationMilliseconds: 1_000))
        let unavailableDurations: [Double?] = [nil, 0, -1]
        for duration in unavailableDurations {
            try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: duration))
        }
        // Both components must exist and be nonnegative. In particular, a
        // missing/negative TTFT cannot be hidden by a positive stream interval.
        let unavailableTTFTs: [Double?] = [nil, -1, 2_000]
        for ttft in unavailableTTFTs {
            try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: 1_000, ttftMilliseconds: ttft))
        }
        try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: 0, ttftMilliseconds: 0))
        try await save(archive, value(generationMilliseconds: 1_000))
        try await save(archive, value(usage: ["output": .number(-1)], generationMilliseconds: 1_000))
        for outcome in ["running", "failed", "cancelled", "truncated", "interrupted"] {
            try await save(archive, value(outcome: outcome, usage: ["output": .number(500)], generationMilliseconds: 1_000))
        }
        var prepared = value(usage: ["output": .number(500)], generationMilliseconds: 1_000)
        prepared["timings"] = .object(["firstContent": .number(110), "modelComplete": .number(1_110)])
        try await save(archive, prepared)
        let badDuration = try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: 1_000))
        let badOutput = try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: 1_000))
        let badTTFT = try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: 1_000))
        let overflowingDuration = try await save(archive, value(usage: ["output": .number(500)], generationMilliseconds: 1_000))
        try await archive.close()
        // JSON metadata rejects nonfinite values, but historical typed columns
        // must remain safe if an older/corrupted projection contains one.
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("UPDATE attempts SET stream_ms=? WHERE id=?", [.real(.infinity), .text(badDuration)])
            try db.execute("UPDATE attempts SET output_tokens=? WHERE id=?", [.real(.infinity), .text(badOutput)])
            try db.execute("UPDATE attempts SET ttft_ms=? WHERE id=?", [.real(.infinity), .text(badTTFT)])
            try db.execute("UPDATE attempts SET ttft_ms=?,stream_ms=? WHERE id=?", [.real(.greatestFiniteMagnitude), .real(.greatestFiniteMagnitude), .text(overflowingDuration)])
        }
        let reopened = try await configured(root)
        let snapshot = try await reopened.menuBarMetrics(period: .retained, until: until)
        XCTAssertEqual(snapshot.historicalRate, HistoricalOutputRate(outputTokens: 100, generationMilliseconds: 1_000, samples: 1))
        XCTAssertEqual(snapshot.historicalRate.tokensPerSecond, 100)
        XCTAssertEqual(snapshot.counts.unobservedDispatch, 1)
        XCTAssertNil(HistoricalOutputRate().tokensPerSecond)
        XCTAssertNil(HistoricalOutputRate(outputTokens: 1, generationMilliseconds: 0, samples: 1).tokensPerSecond)
        XCTAssertNil(HistoricalOutputRate(outputTokens: .nan, generationMilliseconds: 1, samples: 1).tokensPerSecond)
        XCTAssertNil(HistoricalOutputRate(outputTokens: 1, generationMilliseconds: .infinity, samples: 1).tokensPerSecond)
        try await reopened.close()
    }

    func testSessionMetricsIsolatesWorkspaceAndSessionWithIndexedBindings() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        let session = "same-session' OR 1=1 --", workspace = "workspace' OR 1=1 --"
        try await save(archive, value(cost: 0.1, usage: ["output": .number(100)], session: session, generationMilliseconds: 1_000), workspace: workspace)
        try await save(archive, value(cost: 0.2, usage: ["output": .number(50)], purpose: "compaction", session: session, generationMilliseconds: 1_000), workspace: workspace)
        try await save(archive, value(cost: 0.9, usage: ["output": .number(10_000)], session: session, generationMilliseconds: 1_000), workspace: "other-workspace")
        try await save(archive, value(cost: 0.8, usage: ["output": .number(10_000)], session: "other-session", generationMilliseconds: 1_000), workspace: workspace)

        let snapshot = try await archive.sessionMetrics(sessionID: session, workspaceID: workspace, until: until)
        XCTAssertEqual(snapshot.period, .retained); XCTAssertEqual(snapshot.gateway.requests, 2)
        XCTAssertEqual(snapshot.sessions, 1); XCTAssertEqual(snapshot.workspaces, 1); XCTAssertEqual(snapshot.compactionRequests, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.gateway.costUSD), 0.3, accuracy: 1e-10)
        XCTAssertEqual(snapshot.historicalRate.tokensPerSecond, 75)
        XCTAssertEqual(snapshot.models.first?.costShare, 1)
        let empty = try await archive.sessionMetrics(sessionID: "missing", workspaceID: workspace, until: until)
        XCTAssertEqual(empty.gateway.requests, 0); XCTAssertTrue(empty.models.isEmpty); XCTAssertNil(empty.historicalRate.tokensPerSecond)
        for invalid in ["", String(repeating: "x", count: 129), "line\nbreak"] {
            do { _ = try await archive.sessionMetrics(sessionID: invalid, workspaceID: workspace, until: until); XCTFail("Reject invalid session identity") } catch { }
            do { _ = try await archive.sessionMetrics(sessionID: session, workspaceID: invalid, until: until); XCTFail("Reject invalid workspace identity") } catch { }
        }
        try await archive.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let plan = try db.rows("EXPLAIN QUERY PLAN SELECT COUNT(*) FROM attempts WHERE metrics_retained=1 AND wall<? AND session=? AND workspace=? AND dispatch IS NOT NULL", [.real(until.timeIntervalSince1970), .text(session), .text(workspace)])
        let details = plan.compactMap { $0["detail"]?.string }.joined(separator: "\n")
        XCTAssertTrue(details.contains("SEARCH attempts") && details.contains("session=? AND workspace=? AND metrics_retained=? AND wall<?"), details)
    }

    func testSessionModelGroupsCarryTheirOwnSpeedAndFirstTokenTime() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await save(archive, value(model: "provider/model-a", usage: ["output": .number(100)], generationMilliseconds: 1_000, ttftMilliseconds: 10))
        try await save(archive, value(model: "provider/model-a", usage: ["output": .number(100)], generationMilliseconds: 1_000, ttftMilliseconds: 30))
        try await save(archive, value(alias: "fast", model: "provider/model-b", usage: ["output": .number(300)], generationMilliseconds: 1_000, ttftMilliseconds: 50))
        let snapshot = try await archive.sessionMetrics(sessionID: "session", workspaceID: "workspace", until: until)
        XCTAssertEqual(snapshot.models.count, 2)
        let a = try XCTUnwrap(snapshot.models.first { $0.resolvedModel == "provider/model-a" }), b = try XCTUnwrap(snapshot.models.first { $0.resolvedModel == "provider/model-b" })
        XCTAssertEqual(a.historicalRate.tokensPerSecond, 100); XCTAssertEqual(b.historicalRate.tokensPerSecond, 300)
        XCTAssertEqual(a.ttftP50, 10, "nearest-rank median of 10 and 30"); XCTAssertEqual(a.ttftSamples, 2)
        XCTAssertEqual(b.ttftP50, 50); XCTAssertEqual(b.ttftSamples, 1); XCTAssertEqual(b.httpP50, 1_010)
        XCTAssertEqual(try XCTUnwrap(snapshot.historicalRate.tokensPerSecond), 500 / 3, accuracy: 1e-9, "the session figure blends routes; the rows keep them apart")
    }

    func testCostSharesUseAllPagesAndPreserveUnknownAndReportedZero() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        for index in 0..<25 { try await save(archive, value(model: String(format: "model-%03d", index), cost: 1)) }
        try await save(archive, value(model: "zero-cost", cost: 0))
        try await save(archive, value(model: "unknown-cost"))
        let first = try await archive.sessionMetrics(sessionID: "session", workspaceID: "workspace", until: until)
        let second = try await archive.sessionMetrics(sessionID: "session", workspaceID: "workspace", until: until, offset: 24)
        XCTAssertEqual(first.gateway.costUSD, 25); XCTAssertEqual(second.gateway.costUSD, 25)
        XCTAssertEqual(first.models.count, 24); XCTAssertTrue(first.hasNext); XCTAssertFalse(second.hasNext)
        let allModels = first.models + second.models
        for model in allModels where model.resolvedModel?.hasPrefix("model-") == true { XCTAssertEqual(try XCTUnwrap(model.costShare), 1 / 25.0, accuracy: 1e-10) }
        XCTAssertEqual(allModels.first { $0.resolvedModel == "zero-cost" }?.costShare, 0)
        XCTAssertNil(allModels.first { $0.resolvedModel == "unknown-cost" }?.costShare)
        XCTAssertEqual(allModels.compactMap(\.costShare).reduce(0, +), 1, accuracy: 1e-10)
        try await save(archive, value(cost: 0, session: "all-zero"))
        let allZero = try await archive.sessionMetrics(sessionID: "all-zero", workspaceID: "workspace", until: until)
        XCTAssertEqual(allZero.gateway.costUSD, 0); XCTAssertNil(allZero.models.first?.costShare)
        try await archive.close()
    }

    func testSessionRatesSurviveBodyPurgeButExcludeExpiredMetricsInOtherWorkspaces() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = MenuMetricsClock(), archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let own = try await save(archive, value(cost: 0.1, usage: ["output": .number(50)], generationMilliseconds: 1_000))
        try await save(archive, value(cost: 0.9, usage: ["output": .number(1_000)], generationMilliseconds: 1_000), workspace: "other-workspace")
        try await save(archive, value(cost: 0.9, usage: ["output": .number(1_000)], session: "other-session", generationMilliseconds: 1_000))
        try await archive.purge(attemptID: own)
        clock.advance(11)
        let retained = try await archive.sessionMetrics(sessionID: "session", workspaceID: "workspace", until: clock.now())
        XCTAssertEqual(retained.historicalRate.tokensPerSecond, 50); XCTAssertEqual(retained.historicalRate.samples, 1)
        XCTAssertEqual(retained.gateway.costUSD, 0.1)
        clock.advance(101)
        let expired = try await archive.sessionMetrics(sessionID: "session", workspaceID: "workspace", until: clock.now())
        XCTAssertEqual(expired.gateway.requests, 0); XCTAssertEqual(expired.gateway.expiredRecords, 1)
        XCTAssertEqual(expired.historicalRate.samples, 0); XCTAssertNil(expired.historicalRate.tokensPerSecond)
        XCTAssertNil(expired.gateway.costUSD); XCTAssertTrue(expired.models.isEmpty)
        try await archive.close()
    }

    func testRequestedRoutersResolvedModelsAndUnknownStatesFormIndependentDistributions() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await save(archive, value(cost: 0.01))
        try await save(archive, value(cost: 0.02, purpose: "compaction"))
        try await save(archive, value(model: "provider/model-b", api: "anthropic-messages", cost: 0, session: "other-session"), workspace: "other-workspace")
        try await save(archive, value(model: nil, identity: "unreported"))
        try await save(archive, value(model: "auto-router", identity: "reported"))
        try await save(archive, value(model: "provider/model-a", identity: "conflict"))
        try await save(archive, value(model: nil, identity: "incomplete"))
        try await save(archive, value(alias: "fast-direct", model: "provider/model-c"))
        let result = try await archive.menuBarMetrics(period: .day, until: until)
        XCTAssertEqual(result.gateway.requests, 8); XCTAssertEqual(result.modelGroups, 6)
        XCTAssertEqual(result.sessions, 2); XCTAssertEqual(result.workspaces, 2); XCTAssertEqual(result.compactionRequests, 1)
        XCTAssertEqual(result.gateway.costSamples, 3); XCTAssertEqual(result.costUnreported, 5)
        XCTAssertEqual(try XCTUnwrap(result.gateway.costUSD), 0.03, accuracy: 1e-10)
        let modelA = try XCTUnwrap(result.models.first { $0.resolvedModel == "provider/model-a" })
        XCTAssertEqual(modelA.requestedAlias, "auto-router"); XCTAssertEqual(modelA.gateway.requests, 2)
        XCTAssertEqual(modelA.requestShare, 0.25)
        XCTAssertEqual(modelA.costShare, 1)
        let modelB = try XCTUnwrap(result.models.first { $0.resolvedModel == "provider/model-b" })
        XCTAssertEqual(modelB.api, "anthropic-messages"); XCTAssertEqual(modelB.gateway.costUSD, 0)
        XCTAssertEqual(modelB.costShare, 0)
        let unknown = try XCTUnwrap(result.models.first { $0.identityStatus == "unreported" })
        XCTAssertEqual(unknown.gateway.requests, 2); XCTAssertNil(unknown.resolvedModel)
        XCTAssertNil(unknown.costShare)
        XCTAssertEqual(Set(result.models.filter { $0.resolvedModel == nil }.map(\.identityStatus)), ["unreported", "conflict", "incomplete"])
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.requestShare }, 1, accuracy: 1e-10)
        XCTAssertFalse(result.models.contains { $0.resolvedModel == "auto-router" })
        try await archive.close()
    }

    func testNativeInputTotalsIncludeCacheOnceAndPartialUsageHasSeparateCoverage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await save(archive, value(cost: 0.01, cache: "hit", usage: ["input": .number(100), "inputIncludingCache": .number(100), "output": .number(10), "cacheRead": .number(40)]))
        try await save(archive, value(api: "anthropic-messages", cost: 0.02, cache: "miss", usage: ["input": .number(50), "inputIncludingCache": .number(110), "output": .number(10), "cacheRead": .number(40), "cacheWrite": .number(20)]))
        try await save(archive, value(cost: 0, usage: ["inputIncludingCache": .number(0), "output": .number(0), "cacheRead": .number(0)]))
        try await save(archive, value(cache: "conflict", usage: ["inputIncludingCache": .number(30)]))
        try await save(archive, value())
        let result = try await archive.menuBarMetrics(period: .retained, until: until)
        let tokens = try XCTUnwrap(result.gateway.tokens)
        XCTAssertEqual(tokens.total, 230, "Provider cache is already included, while partial usage is excluded from the complete total")
        XCTAssertEqual(tokens.input, 240); XCTAssertEqual(tokens.output, 20)
        XCTAssertEqual(tokens.samples, 3); XCTAssertEqual(tokens.inputSamples, 4); XCTAssertEqual(tokens.outputSamples, 3)
        XCTAssertEqual(result.gateway.cacheReadTokens, 80); XCTAssertEqual(result.gateway.cacheReadSamples, 3)
        XCTAssertEqual(result.gateway.cacheWriteTokens, 20); XCTAssertEqual(result.gateway.cacheWriteSamples, 1)
        XCTAssertEqual(result.gateway.cacheHits, 1); XCTAssertEqual(result.gateway.cacheMisses, 1)
        XCTAssertEqual(result.gateway.cacheUnreported, 2); XCTAssertEqual(result.gateway.cacheConflicts, 1)
        XCTAssertEqual(result.gateway.costSamples, 3); XCTAssertEqual(result.gateway.requests, 5)
        try await archive.close()
    }

    func testMissingInvalidAndReportedZeroUsageNeverConflate() throws {
        let missing = GatewayObservation(metadata: ["usage": .object(["input": .number(100), "cacheRead": .number(20)])])
        XCTAssertNil(missing.inputTokens); XCTAssertNil(missing.outputTokens)
        for invalid in [-1.0, 1.5, Double.infinity, Double.nan, 1e13] {
            let observation = GatewayObservation(metadata: ["usage": .object(["inputIncludingCache": .number(invalid), "output": .number(invalid)])])
            XCTAssertNil(observation.inputTokens); XCTAssertNil(observation.outputTokens)
        }
        let zero = GatewayObservation(metadata: ["usage": .object(["inputIncludingCache": .number(0), "output": .number(0)])])
        XCTAssertEqual(zero.inputTokens, 0); XCTAssertEqual(zero.outputTokens, 0)
        XCTAssertEqual(menuBarTokens(0), "0"); XCTAssertEqual(menuBarTokens(nil), "Unavailable")
        var legacy = GatewayTotals(requests: 1)
        legacy.costUSD = 0
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("tokens"))
        XCTAssertNil(try JSONDecoder().decode(GatewayTotals.self, from: data).tokens)
    }

    func testDispatchAndHalfOpenDateWindowsExcludePreparedFutureAndOldRecords() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root), end = until.timeIntervalSince1970
        let dayStart = end - 86_400.0, weekStart = end - 604_800.0
        let walls: [TimeInterval] = [dayStart - 0.001, dayStart, end - 1.0, end, end + 1.0, weekStart, weekStart - 0.001]
        for wall in walls {
            try await save(archive, value(wall: wall))
        }
        var prepared = value(outcome: "running")
        prepared["timings"] = .object([:]); try await save(archive, prepared)
        let day = try await archive.menuBarMetrics(period: .day, until: until)
        XCTAssertEqual(day.gateway.requests, 2); XCTAssertEqual(day.counts.unobservedDispatch, 1)
        XCTAssertEqual(day.from, until.addingTimeInterval(-86400))
        let week = try await archive.menuBarMetrics(period: .week, until: until)
        XCTAssertEqual(week.gateway.requests, 4)
        let retained = try await archive.menuBarMetrics(period: .retained, until: until)
        XCTAssertEqual(retained.gateway.requests, 5)
        XCTAssertEqual(retained.from, Date(timeIntervalSince1970: end - 7 * 86400 - 0.001))
        XCTAssertEqual(retained.counts.running, 0)
        for invalid in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -1)] {
            do { _ = try await archive.menuBarMetrics(period: .day, until: invalid); XCTFail("Reject invalid wall clock") } catch { }
        }
        try await archive.close()
    }

    func testUpdatesToolsCompactionAndMessageLinksDoNotMultiplyLocalAttempts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        var first = value(cost: 0.01, usage: ["inputIncludingCache": .number(100), "output": .number(10)])
        try await save(archive, first)
        first["outputMessageIds"] = .array([.string("assistant-2"), .string("tool-1"), .string("tool-2")])
        for _ in 0..<3 { try await archive.update(first) }
        try await save(archive, value(cost: 0.02, usage: ["inputIncludingCache": .number(100), "output": .number(10)], purpose: "compaction"))
        try await save(archive, value(outcome: "failed"))
        try await save(archive, value(outcome: "cancelled"))
        try await save(archive, value(outcome: "running"))
        let result = try await archive.menuBarMetrics(period: .day, until: until)
        XCTAssertEqual(result.gateway.requests, 5); XCTAssertEqual(result.gateway.tokens?.total, 220)
        XCTAssertEqual(result.gateway.costSamples, 2); XCTAssertEqual(result.compactionRequests, 1)
        XCTAssertEqual(result.counts.completed, 2); XCTAssertEqual(result.counts.failed, 1)
        XCTAssertEqual(result.counts.cancelled, 1); XCTAssertEqual(result.counts.running, 1)
        do { try await archive.begin(first, workspace: "workspace"); XCTFail("Duplicate attempt identity must not be charged twice") } catch { }
        try await archive.close()
        let reopened = try await configured(root)
        let recovered = try await reopened.menuBarMetrics(period: .day, until: until)
        XCTAssertEqual(recovered.gateway.requests, 5); XCTAssertEqual(recovered.counts.running, 0); XCTAssertEqual(recovered.counts.interrupted, 1)
        try await reopened.close()
    }

    func testInvalidAndConflictingCostDoesNotBecomeZeroWhenTokensAreReported() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        for status in ["invalid", "conflict", "unreported"] {
            var metadata = value(usage: ["inputIncludingCache": .number(0), "output": .number(0)])
            metadata["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string(status), "usd": .number(0)])])
            try await save(archive, metadata)
        }
        let result = try await archive.menuBarMetrics(period: .day, until: until)
        XCTAssertEqual(result.gateway.tokens?.total, 0); XCTAssertEqual(result.gateway.tokens?.samples, 3)
        XCTAssertNil(result.gateway.costUSD); XCTAssertEqual(result.gateway.costSamples, 0)
        XCTAssertEqual(result.costUnreported, 1); XCTAssertEqual(result.costInvalid, 1); XCTAssertEqual(result.costConflicts, 1)
        try await archive.close()
    }

    func testAllModelGroupsAreReachableThroughStableBoundedPages() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        for index in 0..<49 { try await save(archive, value(model: String(format: "model-%03d", index))) }
        let first = try await archive.menuBarMetrics(period: .retained, until: until)
        let second = try await archive.menuBarMetrics(period: .retained, until: until, offset: 24)
        let last = try await archive.menuBarMetrics(period: .retained, until: until, offset: 48)
        XCTAssertEqual(first.modelGroups, 49); XCTAssertEqual(first.models.count, 24); XCTAssertTrue(first.hasNext)
        XCTAssertEqual(second.models.count, 24); XCTAssertTrue(second.hasNext)
        XCTAssertEqual(last.models.count, 1); XCTAssertFalse(last.hasNext)
        XCTAssertEqual(Set((first.models + second.models + last.models).map(\.id)).count, 49)
        XCTAssertEqual(first.gateway.requests, 49); XCTAssertEqual(last.gateway.requests, 49)
        for offset in [-1, 1, 100_001] {
            do { _ = try await archive.menuBarMetrics(period: .retained, until: until, offset: offset); XCTFail("Bound and align group pages") } catch { }
        }
        try await archive.close()
    }

    func testTokenProjectionBackfillsOldSchemaAndSurvivesBodyExpiryButNotMetricExpiry() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = MenuMetricsClock(), archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let id = try await save(archive, value(cost: 0.1, usage: ["inputIncludingCache": .number(120), "output": .number(30)]))
        try await archive.purge(attemptID: id); try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("ALTER TABLE attempts DROP COLUMN input_tokens")
            try db.execute("ALTER TABLE attempts DROP COLUMN output_tokens")
            try db.execute("UPDATE archive_info SET value=? WHERE name='dashboard-projection'", [.blob(Data([2]))])
        }
        let reopened = PayloadArchive(root: root, now: { clock.now() })
        try await reopened.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        clock.advance(11)
        let backfilled = try await reopened.menuBarMetrics(period: .retained, until: clock.now())
        XCTAssertEqual(backfilled.gateway.tokens?.total, 150); XCTAssertEqual(backfilled.gateway.costUSD, 0.1)
        clock.advance(101)
        let expired = try await reopened.menuBarMetrics(period: .retained, until: clock.now())
        XCTAssertEqual(expired.gateway.requests, 0); XCTAssertEqual(expired.gateway.expiredRecords, 1)
        XCTAssertNil(expired.gateway.tokens?.total); XCTAssertTrue(expired.models.isEmpty)
        try await reopened.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let row = try XCTUnwrap(db.rows("SELECT input_tokens,output_tokens FROM attempts WHERE id=?", [.text(id)]).first)
        XCTAssertNil(row["input_tokens"]?.double); XCTAssertNil(row["output_tokens"]?.double)
        XCTAssertEqual(try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").first?["value"]?.data, Data([6]))
    }

    func testInterruptedTokenBackfillResumesAcrossBatchBoundary() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        for index in 1...65 {
            var metadata = value(usage: ["inputIncludingCache": .number(10), "output": .number(2)])
            metadata["attemptId"] = .string(String(format: "00000000-0000-0000-0000-%012d", index))
            try await save(archive, metadata)
        }
        try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("DELETE FROM archive_info WHERE name='dashboard-projection'")
            try db.execute("UPDATE attempts SET input_tokens=NULL,output_tokens=NULL")
            try db.execute("CREATE TRIGGER interrupt_tokens BEFORE UPDATE OF input_tokens ON attempts WHEN NEW.id='00000000-0000-0000-0000-000000000040' BEGIN SELECT RAISE(ABORT,'synthetic token migration interruption'); END")
        }
        do { _ = try await configured(root); XCTFail("Injected interruption must fail opening") } catch { }
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            XCTAssertEqual(try db.rows("SELECT COUNT(input_tokens) AS n FROM attempts").first?["n"]?.number, 32)
            XCTAssertTrue(try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").isEmpty)
            try db.execute("DROP TRIGGER interrupt_tokens")
        }
        let recovered = try await configured(root)
        let result = try await recovered.menuBarMetrics(period: .retained, until: until)
        XCTAssertEqual(result.gateway.tokens?.samples, 65); XCTAssertEqual(result.gateway.tokens?.total, 780)
        try await recovered.close()
    }

    @MainActor func testHiddenPanelCancelsPollingAndIgnoresUncancellableStaleRead() async throws {
        var continuations: [CheckedContinuation<MenuBarSnapshot, Error>] = []
        let activeChats = MenuMetricsActivity()
        let controller = MenuBarMetricsController(load: { _, _, _ in
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }, activeSessions: { activeChats.count }, interval: .seconds(60))
        controller.setVisible(true)
        for _ in 0..<100 where continuations.isEmpty { await Task.yield() }
        XCTAssertEqual(continuations.count, 1)
        XCTAssertEqual(controller.activeSessions, 2)
        controller.setVisible(false)
        let snapshot = emptySnapshot(period: .day)
        continuations.removeFirst().resume(returning: snapshot)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(controller.snapshot); XCTAssertFalse(controller.loading)
        activeChats.count = 0
        controller.setVisible(true)
        for _ in 0..<100 where continuations.isEmpty { await Task.yield() }
        XCTAssertEqual(continuations.count, 1)
        XCTAssertEqual(controller.activeSessions, 0)
        continuations.removeFirst().resume(returning: snapshot)
        for _ in 0..<100 where controller.snapshot == nil { await Task.yield() }
        XCTAssertNotNil(controller.snapshot)
        controller.setVisible(false)
    }

    @MainActor func testChangingScopeCannotShowLateResultsFromPreviousPeriod() async throws {
        var continuations: [MenuBarPeriod: CheckedContinuation<MenuBarSnapshot, Error>] = [:]
        let controller = MenuBarMetricsController(load: { period, _, _ in
            try await withCheckedThrowingContinuation { continuations[period] = $0 }
        }, interval: .seconds(60))
        controller.setVisible(true)
        for _ in 0..<100 where continuations[.day] == nil { await Task.yield() }
        controller.period = .week
        for _ in 0..<100 where continuations[.week] == nil { await Task.yield() }
        try XCTUnwrap(continuations.removeValue(forKey: .week)).resume(returning: emptySnapshot(period: .week))
        for _ in 0..<100 where controller.snapshot == nil { await Task.yield() }
        XCTAssertEqual(controller.snapshot?.period, .week)
        try XCTUnwrap(continuations.removeValue(forKey: .day)).resume(returning: emptySnapshot(period: .day))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.snapshot?.period, .week)
        controller.setVisible(false)
    }

    private func emptySnapshot(period: MenuBarPeriod) -> MenuBarSnapshot {
        MenuBarSnapshot(period: period, from: period.start(until: until), until: until, counts: DashboardCounts(), gateway: GatewayTotals(), workspaces: 0, sessions: 0, compactionRequests: 0, costUnreported: 0, costInvalid: 0, costConflicts: 0, models: [], modelGroups: 0, offset: 0)
    }
}
