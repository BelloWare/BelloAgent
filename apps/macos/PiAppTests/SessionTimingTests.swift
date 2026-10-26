import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PiApp

final class SessionTimingTests: XCTestCase {
    private let until = Date(timeIntervalSince1970: 1_000_000)
    private func folder() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-timing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func configured(_ root: URL) async throws -> PayloadArchive {
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 1_000_000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10_000_000)
        return archive
    }
    /// `last` is when the last output token arrived, after dispatch; a record
    /// written before the helper recorded it has none.
    private func metadata(id: String = UUID().uuidString, session: String = "session", wall: Double = 999_995,
                          outcome: String = "completed", ttft: Double? = 200, duration: Double? = 1_000, output: Double? = 100,
                          last: Double? = nil) -> [String: WireValue] {
        var timings: [String: WireValue] = ["dispatch": .number(100)]
        if let ttft { timings["firstContent"] = .number(100 + ttft) }
        if let last { timings["lastContent"] = .number(100 + last) }
        if let duration { timings["modelComplete"] = .number(100 + duration); timings["httpEnd"] = .number(110 + duration) }
        return ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string("user"), "purpose": .string("turn"),
                "api": .string("openai-responses"), "requestedModel": .string("auto-router"), "mode": .string("off"),
                "outcome": .string(outcome), "wallTimestamp": .number(wall - 10), "dispatchWallTimestamp": .number(wall),
                "timingVersion": .number(2), "timings": .object(timings),
                "messageIds": .array([.string("shared-user")]), "outputMessageIds": .array([.string("shared-output")]),
                "usage": .object(["output": output.map(WireValue.number) ?? .null])]
    }
    @discardableResult private static func save(_ archive: PayloadArchive, _ value: [String: WireValue], workspace: String = "project") async throws -> String {
        try await archive.begin(value, workspace: workspace)
        if value["outcome"]?.string == "running" { try await archive.update(value) }
        else { try await archive.finish(value) }
        return value["attemptId"]!.string!
    }
    private func sample(_ id: String, ttft: Double? = 200, duration: Double? = 1_000, output: Double? = 100) -> SessionTimingSample {
        SessionTimingSample(id: id, wall: until, ttftMilliseconds: ttft,
                            streamingMilliseconds: duration.flatMap { value in ttft.map { value - $0 } }, outputTokens: output, requestMilliseconds: duration)
    }

    func testLedgerKeepsFailuresWithoutChangingTheCompletedRate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        let good = try await Self.save(archive, metadata(wall: 999_991, output: 100))
        let failed = try await Self.save(archive, metadata(wall: 999_992, outcome: "failed", output: 999))
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.samples.map(\.id), [good])
        let ledger = SessionRequestLedger(history: history)
        XCTAssertEqual(ledger.rows.map(\.id), [good, failed])
        XCTAssertEqual(ledger.rows.last?.status, "failed")
        XCTAssertEqual(ledger.rows.last?.throughput, "—")
        XCTAssertEqual(ledger.throughput.samples, 1)
        XCTAssertEqual(ledger.throughput.tokensPerSecond, 100, "100 output tokens over the one-second total; the failure adds nothing")
        try await archive.close()
    }

    func testLatestAndWeightedSessionAverageRemainScopedAndDistinct() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        var first = metadata(wall: 999_990, ttft: 500, duration: 1_000, output: 100)
        first["usage"] = .object(["output": .number(100), "reasoning": .number(80)])
        try await Self.save(archive, first)
        for _ in 0..<3 { try await archive.update(first) }
        let latest = try await Self.save(archive, metadata(wall: 999_992, ttft: 2_000, duration: 3_000, output: 60))
        try await Self.save(archive, metadata(wall: 999_993, output: 9_999), workspace: "other-project")
        try await Self.save(archive, metadata(session: "other-session", wall: 999_994, output: 9_999))
        try await Self.save(archive, metadata(wall: 999_995, outcome: "running", duration: nil, output: nil))
        try await Self.save(archive, metadata(wall: 999_996, outcome: "failed", output: 9_999))
        try await Self.save(archive, metadata(wall: until.timeIntervalSince1970, output: 9_999))
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertEqual(history.latest?.id, latest)
        XCTAssertEqual(history.latest?.ttftMilliseconds, 2_000)
        // The latest request's own figures, from its own record: its output
        // (not another session's or project's, reasoning not added again) and
        // its whole three-second round trip, which stays on it as latency.
        XCTAssertEqual(history.latest?.outputTokens, 60)
        XCTAssertEqual(history.latest?.requestMilliseconds, 3_000)
        XCTAssertEqual(history.latest?.streamingMilliseconds, 1_000)
        // All output tokens over TTFT + span. These legacy records have no
        // last-output stamp, so their only end remains the terminal event.
        XCTAssertEqual(history.latest?.settledTokensPerSecond, 20)
        XCTAssertEqual(history.points(for: .rate).map(\.value), [100, 20])
        XCTAssertEqual(history.settledThroughput, SettledThroughput(decodeMilliseconds: 4_000, outputTokens: 160, samples: 2, requests: 2))
        XCTAssertEqual(try XCTUnwrap(history.settledThroughput.tokensPerSecond), 160 / 4.0, accuracy: 1e-9)
        XCTAssertEqual(history.historicalSettledThroughput, SettledThroughput(decodeMilliseconds: 4_000, outputTokens: 160, samples: 2, requests: 2))
        XCTAssertEqual(try XCTUnwrap(history.historicalSettledThroughput?.tokensPerSecond), 160 / 4.0, accuracy: 1e-9,
                       "Use all output tokens / total duration including TTFT, without counting reasoning or repeated updates again")
        XCTAssertEqual(history.completedRequests, 2)
        let sessionUsage = try await archive.sessionMetrics(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(sessionUsage.gateway.settledThroughput.tokensPerSecond, history.historicalSettledThroughput?.tokensPerSecond,
                       "Footer and usage window must use the same retained-session weighted rate")
        XCTAssertEqual(sessionUsage.gateway.settledThroughput.samples, history.historicalSettledThroughput?.samples)
        try await archive.close()
        let restored = try await configured(root)
        let persisted = try await restored.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(persisted.samples, history.samples, "Helper eviction/restart cannot erase completed requests")
        XCTAssertEqual(persisted.completedRequests, history.completedRequests)
        XCTAssertEqual(persisted.historicalSettledThroughput, history.historicalSettledThroughput)
        XCTAssertEqual(persisted.ledgerSamples?.map(\.id), history.ledgerSamples?.map(\.id))
        XCTAssertEqual(persisted.ledgerSamples?.map(\.outcome), ["completed", "completed", "interrupted", "failed"],
                       "The ledger must show unfinished requests as interrupted after restart")
        try await restored.close()
    }

    func testMissingMetricsNeverBecomeZeroOrReuseAnOlderRequestsRate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await Self.save(archive, metadata(wall: 999_989, ttft: 0, duration: 1_000, output: 11))
        let zero = try await Self.save(archive, metadata(wall: 999_990, ttft: 0, duration: 1_000, output: 0))
        try await Self.save(archive, metadata(wall: 999_991, ttft: nil, duration: nil, output: nil))
        try await Self.save(archive, metadata(wall: 999_992, ttft: 100, duration: 1_000, output: 40))
        let missing = try await Self.save(archive, metadata(wall: 999_993, ttft: 200, duration: 1_000, output: nil))
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.latest?.id, missing); XCTAssertEqual(history.latest?.ttftMilliseconds, 200)
        XCTAssertNil(history.latest?.outputTokens, "Missing usage stays missing: never a zero, never the previous request's figure")
        XCTAssertEqual(history.latest?.streamingMilliseconds, 800, "Its timing alone was valid; the rate still needs its tokens")
        XCTAssertNil(history.latest?.settledTokensPerSecond, "A request that reported no output tokens contributes nothing to the settled rate")
        // Zero output stays a reported count but contributes no rate sample.
        let reportedZero = try XCTUnwrap(history.samples.first { $0.id == zero })
        XCTAssertEqual(reportedZero.outputTokens, 0); XCTAssertNil(reportedZero.settledTokensPerSecond)
        // 11 + 40 output tokens over two total seconds; missing observations
        // and zero output contribute nothing.
        XCTAssertEqual(try XCTUnwrap(history.historicalSettledThroughput?.tokensPerSecond), 51 / 2.0, accuracy: 1e-9)
        XCTAssertEqual(history.historicalSettledThroughput?.samples, 2)
        XCTAssertEqual(history.completedRequests, 5, "Missing usage/timing stays visible in average coverage")
        XCTAssertEqual(history.points(for: .ttft).map(\.value), [0, 0, 100, 200])
        XCTAssertEqual(history.points(for: .rate).map(\.value).count, 2)
        XCTAssertEqual(history.points(for: .rate).map(\.value).first, 11)
        XCTAssertEqual(history.points(for: .rate).map(\.value).last ?? 0, 40, accuracy: 1e-9, "Includes the 100 ms wait for first content")
        XCTAssertEqual(history.settledThroughput.samples, 2, "Two of the five requests have a output speed")
        XCTAssertEqual(history.settledThroughput.requests, 5)
        XCTAssertEqual(history.points(for: .rate).map(\.index), [1, 4])
        XCTAssertEqual(history.points(for: .rate).map(\.segment), [0, 2], "Missing observations are chart gaps, not synthetic connecting lines")
        XCTAssertEqual(SessionTimingMetric.rate.label(0), "0 tok/s")
        XCTAssertEqual(SessionTimingMetric.ttft.label(nil), "Unavailable")
        try await archive.close()
    }

    func testRequestDurationMigrationKeepsSilentCompletionsDurationsAndExpiresCleanly() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        var hidden = metadata(wall: 999_993, ttft: nil, duration: 2_403, output: 302)
        hidden["usage"] = .object(["output": .number(302), "reasoning": .number(253)])
        let hiddenID = try await Self.save(archive, hidden)
        let zeroID = try await Self.save(archive, metadata(wall: 999_994, ttft: nil, duration: 1_000, output: 0))
        let zeroDurationID = try await Self.save(archive, metadata(wall: 999_995, ttft: nil, duration: 0, output: 500))
        let missingEndID = try await Self.save(archive, metadata(wall: 999_996, ttft: nil, duration: nil, output: 500))
        let missingUsageID = try await Self.save(archive, metadata(wall: 999_997, ttft: nil, duration: 1_000, output: nil))
        var noDispatch = metadata(wall: 999_998, ttft: nil, duration: 1_000, output: 500)
        noDispatch["timings"] = .object(["modelComplete": .number(1_100)])
        try await Self.save(archive, noDispatch)
        var expired = metadata(wall: 999_800, ttft: nil, duration: 1_000, output: 99_999)
        expired["attemptId"] = .string(UUID().uuidString)
        let expiredID = try await Self.save(archive, expired)
        try await archive.close()
        // Recreate the previous projection: the source metadata has the real
        // endpoints, but old columns could not express a silent completion.
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("ALTER TABLE attempts DROP COLUMN request_ms")
            try db.execute("UPDATE archive_info SET value=? WHERE name='dashboard-projection'", [.blob(Data([6]))])
        }
        let migrated = try await configured(root)
        try await migrated.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 100)
        let history = try await migrated.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        let silent = try XCTUnwrap(history.samples.first { $0.id == hiddenID })
        XCTAssertNil(silent.ttftMilliseconds); XCTAssertNil(silent.streamingMilliseconds)
        XCTAssertEqual(silent.requestMilliseconds, 2_403)
        XCTAssertEqual(silent.outputTokens, 302, "Reasoning is already inside gateway output; no visible text estimate participates")
        let zero = try XCTUnwrap(history.samples.first { $0.id == zeroID })
        XCTAssertEqual(zero.outputTokens, 0, "A reported zero stays a zero, distinct from missing usage")
        XCTAssertEqual(zero.requestMilliseconds, 1_000)
        let zeroDuration = try XCTUnwrap(history.samples.first { $0.id == zeroDurationID })
        XCTAssertEqual(zeroDuration.requestMilliseconds, 0, "A zero-length request keeps its observation")
        XCTAssertNil(zeroDuration.settledTokensPerSecond, "and divides by nothing: no rate, never an infinite one")
        XCTAssertNil(history.samples.first { $0.id == missingEndID }?.requestMilliseconds)
        XCTAssertEqual(history.latest?.id, missingUsageID)
        XCTAssertNil(SessionRatePresentation(history: history).label, "No measured rate: the sidebar slot stays empty")
        // The migration re-projected every retained request's duration from
        // its metadata; the expired one and the one never dispatched are gone.
        XCTAssertEqual(history.samples.map(\.id), [hiddenID, zeroID, zeroDurationID, missingEndID, missingUsageID])
        XCTAssertEqual(history.samples.map(\.requestMilliseconds), [2_403, 1_000, 0, nil, 1_000])
        XCTAssertEqual(history.completedRequests, 5)
        // None of them stamped a first token, so none has a decode span: the
        // footer, the menu and the session window all quote no rate for them.
        let menu = try await migrated.menuBarMetrics(period: .retained, until: until)
        let session = try await migrated.sessionMetrics(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.historicalSettledThroughput?.samples, 0)
        XCTAssertEqual(menu.gateway.settledThroughput.samples, 0); XCTAssertEqual(session.gateway.settledThroughput.samples, 0)
        XCTAssertEqual(menu.gateway.requests, 5); XCTAssertEqual(session.gateway.requests, 5, "The menu and the session window count the same retained requests")
        let info = SessionInfoTiming(history: SessionTimingHistory(samples: [silent]), work: [:])
        // A silent completion has no first-content stamp and therefore no
        // decode span: Session info keeps its duration and reports no settled
        // rate rather than dividing by the whole round trip.
        XCTAssertEqual(info.latestDurationMs, 2_403)
        XCTAssertNil(info.latestRate); XCTAssertNil(silent.settledTokensPerSecond)
        try await migrated.update(expired)
        try await migrated.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let retired = try db.rows("SELECT request_ms,metrics_retained FROM attempts WHERE id=?", [.text(expiredID)]).first
        XCTAssertNil(retired?["request_ms"]?.double, "Neither expiry nor a late metadata update may retain or resurrect duration")
        XCTAssertEqual(retired?["metrics_retained"]?.number, 0)
        XCTAssertEqual(try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").first?["value"]?.data, Data([7]))
    }

    /// The decode span ends when the last output token arrived, not at the
    /// terminal event: this request generated its 101 tokens between 300 and
    /// 1,300 ms, and its gateway completed it at 3,300 ms. A record written
    /// before the helper recorded the last output keeps the terminal event,
    /// the only end it has; both rates now include TTFT and all tokens.
    func testTheDecodeSpanEndsAtTheLastOutputAndOlderRecordsKeepTheirTerminal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        let held = try await Self.save(archive, metadata(wall: 999_990, ttft: 200, duration: 3_200, output: 101, last: 1_200))
        let older = try await Self.save(archive, metadata(wall: 999_991, ttft: 200, duration: 3_200, output: 101))
        // A stream cut before its terminal event: output arrived, no terminal.
        let cut = try await Self.save(archive, metadata(wall: 999_992, outcome: "cancelled", ttft: 200, duration: nil, output: nil, last: 700))
        func check(_ history: SessionTimingHistory, _ when: String) throws {
            let measured = try XCTUnwrap(history.samples.first { $0.id == held }, when)
            XCTAssertEqual(measured.streamingMilliseconds, 1_000, "\(when): first output → last output")
            XCTAssertEqual(measured.ttftMilliseconds, 200, "\(when): time to first token is unchanged")
            XCTAssertEqual(measured.requestMilliseconds, 3_200, "\(when): the request still runs to its terminal event")
            XCTAssertEqual(measured.settledTokensPerSecond, 101 / 1.2, "\(when): all output over TTFT + span")
            let fallback = try XCTUnwrap(history.samples.first { $0.id == older }, when)
            XCTAssertEqual(fallback.streamingMilliseconds, 3_000, "\(when): a record with no last output keeps the terminal event as its end")
            XCTAssertEqual(try XCTUnwrap(fallback.settledTokensPerSecond, when), 101 / 3.2, accuracy: 1e-9, "\(when): all output and TTFT included")
            XCTAssertEqual(history.historicalSettledThroughput, SettledThroughput(decodeMilliseconds: 4_400, outputTokens: 202, samples: 2, requests: 2), when)
            let interrupted = try XCTUnwrap(history.ledgerSamples?.first { $0.id == cut }, when)
            XCTAssertNil(interrupted.streamingMilliseconds, "\(when): no terminal event, no span — as the helper's stream duration has none")
            XCTAssertEqual(interrupted.ttftMilliseconds, 200, "\(when): its first token is still observed")
        }
        try check(try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until), "as recorded")
        try await archive.close()
        // A projection migration re-projects every retained row from its
        // stored metadata, by the same rule.
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("UPDATE attempts SET stream_ms=NULL")
            try db.execute("DELETE FROM archive_info WHERE name='dashboard-projection'")
        }
        let migrated = try await configured(root)
        try check(try await migrated.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until), "after a projection migration")
        try await migrated.close()
    }

    func testHistoryIsBoundedChronologicalAndUsesTheSessionIndex() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        for index in 0..<132 { try await Self.save(archive, metadata(wall: 999_000 + Double(index), output: Double(index))) }
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.samples.count, 128); XCTAssertTrue(history.hasOlderRequests)
        XCTAssertEqual(history.samples.first?.outputTokens, 4); XCTAssertEqual(history.samples.last?.outputTokens, 131)
        // Outputs 1...131 contribute all tokens over one second each.
        // Only the zero-output request is unmeasured.
        XCTAssertEqual(try XCTUnwrap(history.historicalSettledThroughput?.tokensPerSecond), 66, accuracy: 1e-9,
                       "The average includes retained requests older than the chart's 128-sample limit")
        XCTAssertEqual(history.settledThroughput.samples, 128, "while the listed requests stop at it")
        XCTAssertEqual(history.completedRequests, 132)
        XCTAssertEqual(history.historicalSettledThroughput?.samples, 131, "every retained request with at least one output token")
        XCTAssertEqual(SessionRatePresentation(history: history).average, 66)
        for identity in ["", String(repeating: "x", count: 129), "invalid\nidentity"] {
            do { _ = try await archive.sessionTimingHistory(sessionID: identity, workspaceID: "project", until: until); XCTFail("Invalid session scope accepted") } catch { }
            do { _ = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: identity, until: until); XCTFail("Invalid project scope accepted") } catch { }
        }
        let injected = try await archive.sessionTimingHistory(sessionID: "session' OR 1=1 --", workspaceID: "project", until: until)
        XCTAssertTrue(injected.samples.isEmpty)
        XCTAssertEqual(injected.historicalSettledThroughput?.samples, 0); XCTAssertNil(injected.historicalSettledThroughput?.tokensPerSecond)
        XCTAssertEqual(injected.completedRequests, 0)
        try await archive.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let plan = try db.rows("EXPLAIN QUERY PLAN SELECT id,wall,ttft_ms,stream_ms,request_ms,output_tokens,cost_usd,outcome,api,alias,model,response_model,input_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens FROM attempts WHERE session=? AND workspace=? AND metrics_retained=1 AND wall<? AND dispatch IS NOT NULL AND outcome='completed' ORDER BY wall DESC,id DESC LIMIT 129",
                               [.text("session"), .text("project"), .real(until.timeIntervalSince1970)])
        let detail = plan.compactMap { $0["detail"]?.string }.joined(separator: "\n")
        XCTAssertTrue(detail.contains("SEARCH attempts USING INDEX usage_session"), detail)
        XCTAssertTrue(detail.contains("session=? AND workspace=? AND metrics_retained=? AND wall<?"), detail)
    }

    func testSessionAverageExcludesExpiredMetricsAndSurvivesBodyPurge() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await Self.save(archive, metadata(wall: 999_800, output: 9_999))
        let retained = try await Self.save(archive, metadata(wall: 999_995, output: 25))
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        try await archive.purge(attemptID: retained)
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.samples.map(\.id), [retained])
        XCTAssertEqual(history.historicalSettledThroughput, SettledThroughput(decodeMilliseconds: 1_000, outputTokens: 25, samples: 1, requests: 1),
                       "the retained request's 25 tokens; the expired one adds nothing")
        XCTAssertEqual(history.completedRequests, 1)
        try await archive.close()
    }

    /// Each sample keeps only valid observations, and its one rate — the
    /// settled output speed — exists only when both of its ends are valid.
    func testInvalidAndBufferedTimingValuesRemainHonest() {
        // The control: all 100 tokens over 200 ms TTFT + 800 ms span.
        XCTAssertEqual(sample("valid").settledTokensPerSecond, 100)
        // Zero output stays unmeasured; a single token counts.
        XCTAssertEqual(sample("zero-output", output: 0).outputTokens, 0, "A reported zero is kept, not a missing count")
        XCTAssertNil(sample("zero-output", output: 0).settledTokensPerSecond, "No output has no output speed, never a rate of zero")
        XCTAssertEqual(sample("one-token", output: 1).settledTokensPerSecond, 1)
        XCTAssertEqual(sample("two-tokens", output: 2).settledTokensPerSecond, 2, "Both tokens over one total second")
        // A buffered response has a zero decode span; its TTFT supplies
        // the measured duration, so it has a finite output speed.
        let buffered = sample("buffered", ttft: 2_000, duration: 2_000, output: 100)
        XCTAssertEqual(buffered.streamingMilliseconds, 0); XCTAssertEqual(buffered.requestMilliseconds, 2_000)
        XCTAssertEqual(buffered.settledTokensPerSecond, 50)
        let zeroDuration = sample("zero-duration", ttft: 0, duration: 0)
        XCTAssertEqual(zeroDuration.requestMilliseconds, 0); XCTAssertEqual(zeroDuration.streamingMilliseconds, 0)
        XCTAssertNil(zeroDuration.settledTokensPerSecond)
        // First content stamped after completion is invalid and dropped.
        let negativeStream = sample("negative-stream", ttft: 2_000, duration: 1_000)
        XCTAssertNil(negativeStream.streamingMilliseconds); XCTAssertNil(negativeStream.settledTokensPerSecond)
        XCTAssertEqual(negativeStream.requestMilliseconds, 1_000, "Invalid first-content observations do not erase a separately valid request duration")
        let negativeTokens = sample("negative-tokens", output: -1)
        XCTAssertNil(negativeTokens.outputTokens); XCTAssertNil(negativeTokens.settledTokensPerSecond)
        XCTAssertEqual(negativeTokens.streamingMilliseconds, 800, "Invalid usage does not erase valid timing")
        let missingTTFT = sample("missing-ttft", ttft: nil)
        XCTAssertEqual(missingTTFT.requestMilliseconds, 1_000); XCTAssertEqual(missingTTFT.outputTokens, 100)
        XCTAssertNil(missingTTFT.settledTokensPerSecond, "Missing TTFT and span cannot be replaced by terminal latency")
        let missingDuration = sample("missing-duration", duration: nil)
        XCTAssertNil(missingDuration.requestMilliseconds); XCTAssertNil(missingDuration.streamingMilliseconds)
        XCTAssertNil(missingDuration.settledTokensPerSecond)
        let negativeDuration = sample("negative-duration", duration: -1)
        XCTAssertNil(negativeDuration.requestMilliseconds); XCTAssertNil(negativeDuration.streamingMilliseconds)
        XCTAssertNil(negativeDuration.settledTokensPerSecond)
        let nan = sample("nan", output: .nan)
        XCTAssertNil(nan.outputTokens); XCTAssertNil(nan.settledTokensPerSecond)
        let infinite = sample("infinite", duration: .infinity)
        XCTAssertNil(infinite.requestMilliseconds); XCTAssertNil(infinite.streamingMilliseconds)
        XCTAssertNil(infinite.settledTokensPerSecond)
        // A span too long to be a duration, and a finite division that
        // overflows, both leave no rate rather than an infinity.
        let overflow = SessionTimingSample(id: "overflow", wall: until, ttftMilliseconds: .greatestFiniteMagnitude,
                                           streamingMilliseconds: .greatestFiniteMagnitude, outputTokens: 1)
        XCTAssertNil(overflow.settledTokensPerSecond)
        let overflowingRate = SessionTimingSample(id: "overflowing-rate", wall: until, ttftMilliseconds: 1,
                                                  streamingMilliseconds: 500, outputTokens: .greatestFiniteMagnitude)
        XCTAssertEqual(overflowingRate.streamingMilliseconds, 500); XCTAssertEqual(overflowingRate.outputTokens, Double.greatestFiniteMagnitude)
        XCTAssertNil(overflowingRate.settledTokensPerSecond)
        // A reply delivered in one burst: 100 tokens over 5 ms is not 20,000
        // tok/s, it is no measurement. The request keeps its figures.
        let burst = sample("one-burst", ttft: 200, duration: 205, output: 100)
        XCTAssertEqual(burst.streamingMilliseconds, 5); XCTAssertEqual(burst.outputTokens, 100)
        XCTAssertNil(burst.settledTokensPerSecond)
        let floor = SettledThroughput.minimumDecodeMilliseconds
        XCTAssertEqual(try XCTUnwrap(sample("at-the-floor", ttft: 200, duration: floor, output: 100).settledTokensPerSecond), 100 / (floor / 1_000),
                       accuracy: 1e-9, "A total duration exactly at the floor is measured")
    }

    @MainActor func testLoadedSessionTimingRefreshesAfterCompletionWithoutFocusingIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "session", workspaceID: "project", title: "Background", path: nil, profileID: "p")]
        model.selectedID = "other-chat"
        let display = SessionDisplay(id: "session"); model.displays[display.id] = display
        let now = Date().timeIntervalSince1970
        let previous = metadata(wall: now - 3, ttft: 100, duration: 1_000, output: 80)
        try await Self.save(model.traces, previous)
        await model.refreshAccounting(display, workspaceID: "project")
        // All 80 output tokens over one total second.
        XCTAssertEqual(try XCTUnwrap(display.footer.timing.latest?.settledTokensPerSecond), 80, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(display.footer.timing.historicalSettledThroughput?.tokensPerSecond), 80, accuracy: 1e-9)
        let id = UUID().uuidString
        let pending = metadata(id: id, wall: now - 1, outcome: "running", ttft: nil, duration: nil, output: nil)
        try await Self.save(model.traces, pending)
        await model.refreshAccounting(display, workspaceID: "project")
        XCTAssertEqual(display.footer.timing.latest?.id, previous["attemptId"]?.string)
        XCTAssertEqual(display.footer.timing.historicalSettledThroughput?.samples, 1, "Pending work must not change the completed average")
        let completed = metadata(id: id, wall: now - 1, ttft: 300, duration: 2_000, output: 50)
        try await model.traces.finish(completed)
        await model.captureDidPersist(["type": .string("finish"), "metadata": .object(completed)], workspaceID: "project")
        for _ in 0..<200 where !model.accountingTasks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.accountingTasks.isEmpty)
        XCTAssertEqual(display.footer.timing.latest?.id, id)
        XCTAssertEqual(display.footer.timing.latest?.ttftMilliseconds, 300)
        // All 50 output tokens over two total seconds.
        XCTAssertEqual(try XCTUnwrap(display.footer.timing.latest?.settledTokensPerSecond), 25, accuracy: 1e-9)
        // 80 + 50 output tokens over three total seconds.
        XCTAssertEqual(try XCTUnwrap(display.footer.timing.historicalSettledThroughput?.tokensPerSecond), 130 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(display.footer.timing.completedRequests, 2)
        XCTAssertEqual(model.selectedID, "other-chat")
        let reloaded = SessionDisplay(id: "session")
        await model.refreshAccounting(reloaded, workspaceID: "project")
        XCTAssertEqual(reloaded.footer.timing, display.footer.timing)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testSlowAccountingCannotReplaceANewerTimingSnapshot() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let display = SessionDisplay(id: "session")
        var resume: CheckedContinuation<Void, Never>?
        let older = SessionTimingHistory(samples: [sample("old")])
        let newer = SessionTimingHistory(samples: [sample("new", output: 20)])
        let oldRead = Task {
            await model.refreshAccounting(display, workspaceID: "project") {
                await withCheckedContinuation { resume = $0 }
                return SessionGatewayAccounting(timing: older)
            }
        }
        while resume == nil { await Task.yield() }
        await model.refreshAccounting(display, workspaceID: "project") { SessionGatewayAccounting(timing: newer) }
        resume?.resume(); await oldRead.value
        XCTAssertEqual(display.footer.timing, newer)
    }

    /// The footer no longer carries a rate that moves while a request streams.
    /// While a run is going it shows two things: how long the turn has been
    /// running, and what it is doing.
    @MainActor func testRunningFooterKeepsOnlyTheClockAndTheCurrentAction() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = SessionDisplay(id: "timing-preview")
        session.state = "running"
        session.activity = ["phase": .string("tools"), "toolNames": .array([.string("bash")])]
        session.footer.turnTiming = ["startedAt": .number(ProcessInfo.processInfo.systemUptime * 1_000 - 19_000)]
        session.footer.gateway = GatewayTotals(requests: 2, costSamples: 2, costUSD: 0.0025, cacheReadTokens: 6_000, cacheReadSamples: 2)
        session.footer.gateway.turnCount = 1
        session.footer.gateway.tokens = GatewayTokenTotals(input: 12_000, output: 3_800, total: 15_800, inputSamples: 2, outputSamples: 2, samples: 2)
        session.footer.gateway.decodeMilliseconds = 1_000; session.footer.gateway.decodeOutputTokens = 34; session.footer.gateway.decodeSamples = 2
        let hosted = NSHostingView(rootView: HostedMetricsFooter(model: model, session: session).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color.piSurface))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1_000, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for width in [1_000, 420] {
            window.setContentSize(NSSize(width: CGFloat(width), height: 100))
            let rendered = try await renderedText(window, filename: "session-footer-running-\(width).jpg")
            XCTAssertEqual(hosted.bounds.width, CGFloat(width), accuracy: 0.5)
            // The clock started 19 s before the first capture and keeps
            // running: a loaded machine can capture much later, even in minutes.
            // What matters is a visible reading of at least 19 seconds.
            XCTAssertNotNil(rendered.range(of: #"\b(?:(?:19|[2-5][0-9])\s*s|[1-9][0-9]*\s*m\s*[0-5]?[0-9]\s*s|[1-9][0-9]*\s*h\s*[0-5]?[0-9]\s*m\s*[0-5]?[0-9]\s*s)\b"#, options: .regularExpression),
                            "The elapsed clock must stay visible at \(width)pt. OCR: \(rendered)")
            XCTAssertTrue(rendered.contains("bash"), "The current action must stay visible at \(width)pt. OCR: \(rendered)")
            XCTAssertTrue(rendered.contains("15.8k tok") && rendered.contains("cache hit 50.00%") && rendered.contains("$0.0025"),
                          "The usage pill keeps tokens, cache hit and cost at \(width)pt. OCR: \(rendered)")
            // The token split shows where the pane has room for it; a narrow
            // pane drops the split, never the cost.
            XCTAssertEqual(rendered.contains("6k uncached") && rendered.contains("6k cached") && rendered.contains("3.8k out"), width == 1_000,
                           "The token split shows at 1000pt only. OCR: \(rendered)")
            XCTAssertTrue(rendered.contains("34 tok/s"), "The settled session rate stays on the gauge pill at \(width)pt. OCR: \(rendered)")
            XCTAssertFalse(rendered.contains("latest"), "The live latest/average rates left the footer. OCR: \(rendered)")
            XCTAssertFalse(rendered.contains("avg "), "The live latest/average rates left the footer. OCR: \(rendered)")
        }
    }

    /// The footer keeps one form through a run. Its run line sits in one
    /// fixed slot, so neither a phase ("Generating response…" / "Running
    /// read, grep, bash, edit…") nor a clock step (5s → 12m 34s) switches it
    /// between one row and two at any pane width. Sized by its text, it did.
    @MainActor func testTheFooterKeepsItsFormThroughARunsPhasesAndClockSteps() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = SessionDisplay(id: "footer-form")
        session.state = "running"
        session.footer.gateway = GatewayTotals(requests: 2, costSamples: 2, costUSD: 0.0025, cacheReadTokens: 6_000, cacheReadSamples: 2)
        session.footer.gateway.turnCount = 1
        session.footer.gateway.tokens = GatewayTokenTotals(input: 12_000, output: 3_800, total: 15_800, inputSamples: 2, outputSamples: 2, samples: 2)
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        func height(_ width: CGFloat, phase: String, tools: [String], seconds: Double) -> CGFloat {
            session.activity = ["phase": .string(phase), "toolNames": .array(tools.map { .string($0) })]
            session.footer.turnTiming = ["startedAt": .number(ProcessInfo.processInfo.systemUptime * 1_000 - seconds * 1_000)]
            return footerHeight(hosted, model: model, session: session, width: width, compact: false)
        }
        var heights: Set<CGFloat> = []
        for width in stride(from: CGFloat(600), through: 1_600, by: 20) {
            let short = height(width, phase: "model", tools: [], seconds: 5)
            let long = height(width, phase: "working", tools: ["read", "grep", "bash", "edit"], seconds: 754)
            XCTAssertEqual(short, long, "at \(width) pt the footer changed form between two moments of one run")
            heights.insert(short)
        }
        XCTAssertGreaterThan(heights.count, 1, "the sweep crosses the width where the run line drops to its own row")
    }

    /// The context pill's words never change the footer's rows. On showing a
    /// chat, the pill reads "Calculating context…" until the helper has
    /// counted; in a run, "Preparing request input…". Where the pill's figure
    /// fit at the end of a row, those words pushed it onto a row of its own.
    /// The footer grew a row and the conversation above it jumped, then
    /// jumped back when the figure came. The words now take the room the
    /// pill keeps for the showing, in the chat's footer and in a side's
    /// compact one, for a figure of one digit, two, or a nearly full
    /// window's "99.96%".
    @MainActor func testTheContextPillsWordsNeverChangeTheFootersRows() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("context-words")
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        func height(_ width: CGFloat, compact: Bool, tokens: Double, words: String?) -> CGFloat {
            session.context = ["tokens": .number(tokens), "contextWindow": .number(200_000)]
            session.footer.preparingContext = words == "calculating"
            session.footer.pendingContextSubmission = words == "preparing" ? "turn" : nil
            return footerHeight(hosted, model: model, session: session, width: width, compact: compact)
        }
        for compact in [false, true] {
            var heights: Set<CGFloat> = []
            for tokens in [9_000.0, 45_000, 199_920] {
                for width in stride(from: CGFloat(compact ? 240 : 500), through: compact ? 800 : 1_400, by: 4) {
                    session.presentationGeneration = UUID()
                    let counted = height(width, compact: compact, tokens: tokens, words: nil)
                    for words in ["calculating", "preparing"] {
                        XCTAssertEqual(height(width, compact: compact, tokens: tokens, words: words), counted,
                                       "\(compact ? "compact" : "full") footer at \(width) pt, \(tokens) tokens: “\(words)” changed its rows")
                    }
                    heights.insert(counted)
                }
            }
            XCTAssertGreaterThan(heights.count, 1, "the sweep crosses the widths where the pills wrap")
        }
    }

    /// The hour-long soak's case. A chat whose helper has gone and whose
    /// saved reading no longer stands has no figure when it is shown: the
    /// pill reads "Inspect context", then "Calculating context…" while it is
    /// counted, then the figure. None of the three changes the footer's rows
    /// in that showing, nor does the figure shrinking afterwards.
    @MainActor func testAShowingWithoutAFigureKeepsItsRowsUntilTheFigureComes() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("context-unknown")
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        func height(_ width: CGFloat, compact: Bool, tokens: Double?, calculating: Bool) -> CGFloat {
            session.context = tokens.map { ["tokens": .number($0), "contextWindow": .number(200_000)] } ?? [:]
            session.footer.preparingContext = calculating
            return footerHeight(hosted, model: model, session: session, width: width, compact: compact)
        }
        for compact in [false, true] {
            var heights: Set<CGFloat> = []
            for width in stride(from: CGFloat(compact ? 240 : 500), through: compact ? 800 : 1_400, by: 4) {
                session.presentationGeneration = UUID()
                let first = height(width, compact: compact, tokens: nil, calculating: false)
                let where_ = "\(compact ? "compact" : "full") footer at \(width) pt"
                XCTAssertEqual(height(width, compact: compact, tokens: nil, calculating: true), first, "\(where_): “Calculating context…” changed its rows")
                XCTAssertEqual(height(width, compact: compact, tokens: 199_920, calculating: false), first, "\(where_): the figure changed its rows")
                XCTAssertEqual(height(width, compact: compact, tokens: 9_000, calculating: false), first, "\(where_): a shorter figure changed its rows")
                heights.insert(first)
            }
            XCTAssertGreaterThan(heights.count, 1, "the sweep crosses the widths where the pills wrap")
        }
    }

    /// The room lasts one showing. Shown again, the chat lays out from what
    /// its pill shows first, as a chat shown for the first time does. And the
    /// room lies after the pill: its press target is the size of what it says.
    @MainActor func testTheContextPillsRoomLastsOneShowingAndLiesOutsideThePill() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let figure: [String: WireValue] = ["tokens": .number(45_000), "contextWindow": .number(200_000)]
        let fresh = longChat("context-fresh"), shown = longChat("context-shown-before")
        fresh.context = figure
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: fresh, width: 600))
        func target() throws -> CGFloat {
            func find(_ view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == "session-stats-context" { return view }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            return try XCTUnwrap(find(hosted), "the context pill's press target").frame.width
        }
        var kept = 0
        for width in stride(from: CGFloat(500), through: 1_400, by: 4) {
            let first = footerHeight(hosted, model: model, session: fresh, width: width, compact: false)
            let firstTarget = try target()
            // A showing that began without a figure keeps that room once the
            // figure has come; its press target does not.
            shown.presentationGeneration = UUID()
            shown.context = [:]
            let unknown = footerHeight(hosted, model: model, session: shown, width: width, compact: false)
            shown.context = figure
            XCTAssertEqual(footerHeight(hosted, model: model, session: shown, width: width, compact: false), unknown, "at \(width) pt the figure changed the rows")
            XCTAssertEqual(try target(), firstTarget, "at \(width) pt the press target grew with the room kept")
            if unknown != first { kept += 1 }
            // Shown again, it lays out from its figure, as a first showing does.
            shown.presentationGeneration = UUID()
            XCTAssertEqual(footerHeight(hosted, model: model, session: shown, width: width, compact: false), first, "at \(width) pt a new showing kept an old room")
        }
        XCTAssertGreaterThan(kept, 0, "the sweep crosses widths where the room kept a row")
    }

    /// In a run, the chat's saved reading can be far behind the figure on
    /// screen. Words that replace the figure there ("Compacting context…")
    /// take the room of the figure shown, never of the saved one; and a chat
    /// that showed a smaller figure in an earlier showing keeps nothing of it.
    @MainActor func testTheContextPillsWordsTakeTheRoomOfTheFigureShown() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("context-shown")
        let chat = ChatRecord(id: session.id, workspaceID: "project", title: "Long", path: nil, profileID: "profile")
        session.footer.retainedContext = ContextReading(chatID: chat.id, context: ["tokens": .number(46_000), "contextWindow": .number(200_000)],
                                                        binding: ContextPreviewBinding(chat), configurationRevision: 0, journal: nil)
        session.context = ["tokens": .number(199_920), "contextWindow": .number(200_000)]
        let other = longChat("context-shown-other")
        other.context = session.context
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        var heights: Set<CGFloat> = []
        for width in stride(from: CGFloat(500), through: 1_400, by: 2) {
            session.runStatus = "idle"
            let shown = footerHeight(hosted, model: model, session: session, width: width, compact: false)
            session.runStatus = "compacting"
            XCTAssertEqual(footerHeight(hosted, model: model, session: session, width: width, compact: false), shown,
                           "at \(width) pt “Compacting context…” changed the footer's rows")
            heights.insert(shown)
            // The footer is kept across chats. Another chat whose earlier
            // showing held a smaller figure's room, shown again with the same
            // figure as this one, keeps this figure's room.
            other.footer.contextSlot = ContextPillSlot.of(nil, showing: other.presentationGeneration).adding("23%", figure: true)
            other.presentationGeneration = UUID(); other.runStatus = "idle"
            XCTAssertEqual(footerHeight(hosted, model: model, session: other, width: width, compact: false), shown)
            other.runStatus = "compacting"
            XCTAssertEqual(footerHeight(hosted, model: model, session: other, width: width, compact: false), shown,
                           "at \(width) pt, after a chat switch, “Compacting context…” changed the footer's rows")
        }
        XCTAssertGreaterThan(heights.count, 1, "the sweep crosses the widths where the pills wrap")
    }

    @MainActor private func footerHeight(_ hosted: NSHostingView<FooterWidthProbe>, model: WorkspaceModel, session: SessionDisplay,
                                         width: CGFloat, compact: Bool) -> CGFloat {
        hosted.rootView = FooterWidthProbe(model: model, session: session, width: width, compact: compact)
        hosted.layoutSubtreeIfNeeded()
        ConversationPaneTests.views(MetricsFooter.self, in: hosted).first?.refresh()
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.height
    }

    /// The capture badge keeps its room while the chat is on screen: "Next: "
    /// coming (an idle helper leaving) or going (the helper opening) never
    /// changes the footer's rows or form. A new showing lays out from what
    /// the badge says first. Its press target hugs what it says.
    @MainActor func testTheCaptureBadgeKeepsItsRoomThroughAShowing() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("capture-room")
        session.context = ["tokens": .number(45_000), "contextWindow": .number(200_000)]
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        func target() throws -> CGFloat {
            func find(_ view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == "capture-badge" { return view }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            return try XCTUnwrap(find(hosted), "the capture badge's press target").frame.width
        }
        var heights: Set<CGFloat> = [], hugged = 0
        for width in stride(from: CGFloat(500), through: 1_400, by: 4) {
            for first in [true, false] {
                session.presentationGeneration = UUID()
                session.captureAvailable = first
                let shown = footerHeight(hosted, model: model, session: session, width: width, compact: false)
                let firstTarget = try target()
                session.captureAvailable = !first
                XCTAssertEqual(footerHeight(hosted, model: model, session: session, width: width, compact: false), shown,
                               "at \(width) pt the badge \(first ? "gaining" : "losing") “Next: ” changed the footer")
                // In the full form, where the badge has words, the press target
                // hugs the shorter badge, not its room; icon-only, it is the same.
                if !first {
                    let now = try target()
                    if firstTarget > 30 { XCTAssertLessThan(now, firstTarget, "at \(width) pt the press target hugs the shorter badge, not its room"); hugged += 1 }
                    else { XCTAssertEqual(now, firstTarget) }
                }
                heights.insert(shown)
            }
        }
        XCTAssertGreaterThan(heights.count, 1, "the sweep crosses the widths where the footer changes form")
        XCTAssertGreaterThan(hugged, 0, "the sweep reaches widths where the badge has words")
    }

    /// A notice coming or going never moves the footer: it takes only what
    /// the pills leave free (an idle helper's "Saved history · Host runtime
    /// unloaded" moved the conversation while it was read), in a run too,
    /// and in a side's compact footer.
    @MainActor func testANoticeNeverMovesTheFooter() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("notice-room")
        session.context = ["tokens": .number(45_000), "contextWindow": .number(200_000)]
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        for compact in [false, true] {
            for running in compact ? [false] : [false, true] {
                session.state = running ? "running" : "idle"
                var heights: Set<CGFloat> = []
                for width in stride(from: CGFloat(compact ? 240 : 500), through: compact ? 800 : 1_400, by: 4) {
                    session.presentationGeneration = UUID()
                    session.notice = ""
                    let quiet = footerHeight(hosted, model: model, session: session, width: width, compact: compact)
                    for notice in ["Saved history · Host runtime unloaded", "Run cancelled. Pending messages are paused; resume below", ""] {
                        session.notice = notice
                        XCTAssertEqual(footerHeight(hosted, model: model, session: session, width: width, compact: compact), quiet,
                                       "\(compact ? "compact" : "full")\(running ? ", running" : "") footer at \(width) pt: “\(notice)” changed it")
                    }
                    heights.insert(quiet)
                }
                XCTAssertGreaterThan(heights.count, 1, "the sweep crosses the widths where the footer changes form")
            }
        }
        session.state = "idle"
    }

    /// Nothing in the footer's row moves for a notice: the clock and the
    /// badge keep their places whatever notice comes, changes or goes; the
    /// notice sits in what the pills leave free, right against the clock,
    /// and is not shown where that is too little.
    @MainActor func testTheFootersRowPlacesANoticeWithoutMovingAnything() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("footer-row")
        session.state = "running"
        session.activity = ["phase": .string("model")]
        let footer = MetricsFooter(model: model, session: session, inspect: {})
        func parts() -> [String: CGRect] {
            func frame(_ id: String) -> CGRect? {
                func find(_ view: NSView) -> NSView? { view.accessibilityIdentifier() == id ? view : view.subviews.lazy.compactMap(find).first }
                return find(footer).map { $0.convert($0.bounds, to: footer) }
            }
            var parts: [String: CGRect] = [:]
            parts["pills"] = frame("sessionStatsPills"); parts["run"] = frame("session-run-line"); parts["badge"] = frame("capture-badge")
            if let notice = footer.subviews.first(where: { $0 is FooterNotice }), !notice.isHidden { parts["notice"] = notice.frame }
            return parts
        }
        func place(_ width: CGFloat, notice: String) -> [String: CGRect] {
            session.notice = notice
            footer.refresh()
            footer.frame = CGRect(x: 0, y: 0, width: width, height: footer.height(forWidth: width))
            footer.layoutSubtreeIfNeeded()
            return parts()
        }
        let badge = try XCTUnwrap(footer.subviews.compactMap { $0 as? CaptureBadge }.first)
        let minimum = footer.pills.oneRowWidth + MetricsFooter.runSlot + badge.slotWidth(full: true)
            + PiSpacing.md * 2 + MetricsFooter.padding.left + MetricsFooter.padding.right
        for width in [minimum + 10, minimum + 72, minimum + 300] {
            let quiet = place(width, notice: "")
            XCTAssertTrue(footer.fullForm, "The notice check exercises the full footer at \(width) pt")
            for notice in ["Saved history · Host runtime unloaded", "Run cancelled. Pending messages are paused; resume below"] {
                let placed = place(width, notice: notice)
                XCTAssertEqual(placed["run"], quiet["run"], "the clock stays put for “\(notice)” at \(width) pt")
                XCTAssertEqual(placed["badge"], quiet["badge"], "the badge stays put")
                XCTAssertEqual(placed["pills"], quiet["pills"], "the pills stay put")
                let run = try XCTUnwrap(quiet["run"]), pills = try XCTUnwrap(quiet["pills"])
                let room = run.minX - 12 - (pills.maxX + 12)
                if let shown = placed["notice"], room >= MetricsFooter.noticeLeast, shown.width > 0 {
                    XCTAssertEqual(shown.maxX, run.minX - 12, accuracy: 0.5, "the notice sits right against the clock")
                    XCTAssertGreaterThanOrEqual(shown.minX, pills.maxX + 12 - 0.5, "and never over the pills")
                } else {
                    XCTAssertEqual(placed["notice"]?.width ?? 0, 0, accuracy: 0.5, "too little room: the notice is not shown")
                }
            }
        }
        session.state = "idle"
    }

    /// A figure is never cut to make room: the pill that shortens its words
    /// keeps every digit of a nearly full window's reading, read off the
    /// screen at the widths where it ends a row.
    @MainActor func testTheContextFigureIsNeverCut() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = longChat("context-figure")
        session.context = ["tokens": .number(199_920), "contextWindow": .number(200_000)]
        let hosted = NSHostingView(rootView: FooterWidthProbe(model: model, session: session, width: 600))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 600, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // Where the pill only just fits at the end of the first row, and a
        // few points narrower, where it starts the next.
        var checked = 0
        var previous: CGFloat?
        for width in stride(from: CGFloat(1_100), through: 640, by: -2) {
            hosted.rootView = FooterWidthProbe(model: model, session: session, width: width)
            hosted.layoutSubtreeIfNeeded()
            let height = hosted.fittingSize.height
            defer { previous = height }
            guard let previous, previous != height else { continue }
            for probe in [width + 2, width] {
                hosted.rootView = FooterWidthProbe(model: model, session: session, width: probe)
                window.setContentSize(NSSize(width: probe, height: 90))
                let rendered = try await renderedText(window, filename: "context-figure-\(Int(probe)).jpg")
                XCTAssertTrue(rendered.contains("99.96%"), "The whole figure shows at \(probe) pt: \(rendered)")
            }
            checked += 1
            if checked == 3 { break }
        }
        XCTAssertGreaterThan(checked, 0, "the sweep found where the footer wraps")
    }

    /// A long chat's figures: every pill wide.
    @MainActor private func longChat(_ id: String) -> SessionDisplay {
        let session = SessionDisplay(id: id)
        session.footer.gateway = GatewayTotals(requests: 412, costSamples: 412, costUSD: 12.3456, cacheReadTokens: 450_000, cacheReadSamples: 412)
        session.footer.gateway.turnCount = 153
        session.footer.gateway.tokens = GatewayTokenTotals(input: 1_180_000, output: 124_000, total: 1_304_000, inputSamples: 412, outputSamples: 412, samples: 412,
                                                           reasoning: 31_000, reasoningSamples: 412)
        session.footer.gateway.decodeMilliseconds = 1_000; session.footer.gateway.decodeOutputTokens = 34; session.footer.gateway.decodeSamples = 412
        return session
    }

    @MainActor func testRunLineNamesTheActionUnderWayAndTheTurnClock() {
        let session = SessionDisplay(id: "run-line")
        struct Line { let action: String }
        func line() -> Line { Line(action: SessionRunLine.action(session)) }
        session.state = "running"
        XCTAssertEqual(line().action, "Working…")
        session.activity = ["phase": .string("model")]
        XCTAssertEqual(line().action, "Generating response…")
        session.activity = ["phase": .string("tools"), "toolNames": .array([.string("bash"), .string("read")])]
        XCTAssertEqual(line().action, "Running bash…")
        session.state = "stopping"
        XCTAssertEqual(line().action, "Stopping…", "Stopping wins over whatever the last snapshot said was running")
        // `startedAt` is a machine-uptime stamp, never a calendar instant.
        let now = 2_000_000.0
        XCTAssertNil(SessionRunLine.elapsed([:], atUptimeMs: now))
        XCTAssertEqual(SessionRunLine.elapsed(["startedAt": .number(1_981_000)], atUptimeMs: now), "19s")
        XCTAssertEqual(SessionRunLine.elapsed(["startedAt": .number(1_935_000)], atUptimeMs: now), "1m 05s")
        XCTAssertEqual(SessionRunLine.elapsed(["elapsedMs": .number(3_903_000)], atUptimeMs: now), "1h 05m 03s",
                       "A turn with no start stamp still reports the helper's own elapsed figure")
        XCTAssertEqual(SessionRunLine.elapsed(["startedAt": .number(1_981_000), "elapsedMs": .number(25_000)], atUptimeMs: now), "25s",
                       "A stale snapshot is a floor, never a clock running backwards")
    }

    /// One request has one speed. This one waited two seconds for its first
    /// token then generated for one second: all 101 tokens over three seconds.
    /// The sidebar slot, the Session Inspector's request header and the menu
    /// bar all quote that request — so all of them must quote the same figure.
    @MainActor func testEveryCaptionOfOneRequestQuotesTheSameSettledRate() async throws {
        let request = SessionTimingSample(id: "r1", wall: Date(timeIntervalSince1970: 1_790_000_000), ttftMilliseconds: 2_000,
                                          streamingMilliseconds: 1_000, outputTokens: 101, requestMilliseconds: 3_000)
        let history = SessionTimingHistory(samples: [request])
        XCTAssertEqual(SessionTimingMetric.rate.value(in: request), 101 / 3.0)
        XCTAssertEqual(history.points(for: .rate).map(\.value), [101 / 3.0])
        XCTAssertEqual(SessionRatePresentation(history: history).label, "Latest 34 tok/s")

        // The Session Inspector's request header quotes the same request's rate.
        let row = InspectorRequestRow(id: "r1", wall: 1_790_000_000, turn: "t", purpose: "turn", api: "openai-responses", alias: "m", model: "m",
                                      outcome: "completed", output: 101, ttft: 2_000, decode: 1_000, duration: 3_000)
        XCTAssertEqual(row.figures.first { $0.label == "Speed" }?.value, "34 tok/s",
                       "All tokens over the total duration including TTFT")
        XCTAssertFalse(row.figures.contains { $0.value.contains("100 tok/s") })

        // The menu bar's row for the chat that ran it.
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "p", path: root.path, trusted: true)]
        model.chats = [ChatRecord(id: "rates", workspaceID: "p", title: "Rates", path: nil, profileID: "profile")]
        let view = SessionDisplay(id: "rates"); view.state = "running"; view.runStatus = "running"
        view.activity = ["phase": .string("model"), "modelActive": .bool(true)]
        view.footer.timing = history
        model.displays[view.id] = view
        XCTAssertEqual(try XCTUnwrap(model.menuBarActivity().runningRows.first).latestRate, 101 / 3.0,
                       "The menu bar quotes the same settled rate as the sidebar and Session info")
    }

    /// Every menu bar caption and chart includes TTFT in the output speed.
    @MainActor func testTheUsagePanelQuotesTheOutputSpeedOfTheSameRequest() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 1_000_000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10_000_000)
        try await Self.save(archive, metadata(wall: 999_990, ttft: 2_000, duration: 3_000, output: 101))
        let usage = try await archive.menuBarMetrics(period: .day, until: until)
        try await archive.close()
        XCTAssertEqual(usage.gateway.settledThroughput, SettledThroughput(decodeMilliseconds: 3_000, outputTokens: 101, samples: 1, requests: 1),
                       "All 101 output tokens over TTFT + span = three seconds")
        let slice = try XCTUnwrap(usage.buckets.first { $0.requests > 0 })
        let route = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(try XCTUnwrap(MenuBarRateText.rate(slice)), 101 / 3.0, accuracy: 1e-9, "The rate chart includes TTFT")
        let rate = menuBarRate(101.0 / 3), oldRate = menuBarRate(100)
        XCTAssertEqual(MenuBarRateText.caption(usage), "\(rate) tok/s over 1 completed requests · output tokens ÷ time from sending the request to the last output token")
        XCTAssertEqual(MenuBarRateText.slice(slice), "\(rate) output tok/s")
        XCTAssertEqual(MenuBarRateText.point(slice), "\(rate) output tokens per second over 1 requests")
        XCTAssertEqual(MenuBarRateText.model(route), "\(rate) output tok/s · 1 completed requests timed")
        for text in [MenuBarRateText.caption(usage), MenuBarRateText.slice(slice), MenuBarRateText.point(slice), MenuBarRateText.model(route), MenuBarRateText.scope] {
            XCTAssertFalse(text.contains(oldRate) || text.contains("after the first"), text)
        }

        // On screen: the panel showing its rate chart, read off its pixels.
        let panel = MenuBarMetricsController(load: { _, _, _ in usage }, interval: .seconds(60))
        panel.setVisible(true); defer { panel.setVisible(false) }
        for _ in 0..<500 where panel.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(panel.snapshot, usage)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: MenuBarPanelLayout.width, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let surface = FillView(.piSurface)
        let usageView = MenuBarUsageView(controller: panel, chartMetric: .rate)
        surface.addSubview(usageView)
        usageView.frame = CGRect(x: 18, y: 18, width: MenuBarPanelLayout.width - 36, height: usageView.height(forWidth: MenuBarPanelLayout.width - 36))
        window.contentView = surface
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let rendered = try await Self.recognizedText(in: window, filename: "menu-usage-rate.jpg")
        XCTAssertNotNil(rendered.range(of: #"33[.,]667 tok/s"#, options: .regularExpression), "The rate caption includes TTFT. OCR: \(rendered)")
        XCTAssertNil(rendered.range(of: #"100[.,]000"#, options: .regularExpression), "No figure uses the old decode-only rate. OCR: \(rendered)")
    }


    @MainActor func testSidebarRateSlotKeepsItsGeometryForAwaitingReportedAndUnavailableUsage() {
        let variants = [SessionTimingHistory(),
                        SessionTimingHistory(samples: [sample("reported", output: 8_000)]),
                        SessionTimingHistory(samples: [sample("zero", output: 0)]),
                        SessionTimingHistory(samples: [sample("missing", output: nil)])]
        for reduced in [false, true] {
            PiKit.Motion.reducedOverride = reduced
            defer { PiKit.Motion.reducedOverride = nil }
            let slot = SidebarRateView()
            var sizes: [NSSize] = []
            for history in variants {
                slot.presentation = SessionRatePresentation(history: history)
                slot.layoutSubtreeIfNeeded()
                sizes.append(slot.intrinsicContentSize)
            }
            XCTAssertEqual(sizes[0].width, 108); XCTAssertGreaterThan(sizes[0].height, 0)
            for size in sizes.dropFirst() {
                XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5, "A completed or missing usage sample must not move neighboring metrics")
                XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5)
            }
        }
    }

    @MainActor func testNarrowSidebarKeepsStateCostAndRateVisibleWithoutOverflow() async throws {
        // At sidebar widths 300/200, list padding (16), root indentation
        // (14), row padding (20), and icon/spacing (24) leave 226/126pt.
        // A first-level child leaves another 14pt less: 112pt.
        let cases: [(state: String, output: Double?)] = [("idle", 100), ("paused", 100), ("stopping", 100), ("stopping", nil)]
        let hosted = NSView()
        hosted.wantsLayer = true
        let metrics = ChatRowMetricsView()
        hosted.addSubview(metrics)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 250, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var wideHeights: [String: CGFloat] = [:]
        // The sidebar tells the line its width, so it chooses its form by
        // measuring the figures, and must keep everything readable.
        for told in [true] {
        for width in [CGFloat(226), CGFloat(126), CGFloat(112)] {
            for item in cases {
                let id = item.state + (item.output == nil ? "-missing" : "") + (told ? "-told" : "")
                var stats = ChatRowStats(totals: nil, timing: SessionTimingHistory(samples: [sample(id, output: item.output)]))
                stats.requests = 1; stats.costUSD = 12.34
                stats.updateActivity(state: item.state, loading: false, activity: [:])
                metrics.update(stats: stats, available: width)
                metrics.frame = CGRect(x: 12, y: 12, width: width, height: metrics.height(forWidth: width))
                hosted.layer?.backgroundColor = hosted.piCGColor(.piWindow)
                window.setContentSize(NSSize(width: width + 24, height: 80))
                // The rate label fades from the previous fixture value. A
                // sleep before drawing can end before that transaction even
                // starts under parallel load; capture only its settled face.
                try await eventually("The sidebar rate label never finished its transition") {
                    hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                    return ConversationPaneTests.views(PiKit.TextLine.self, in: metrics).allSatisfy { $0.layer?.animation(forKey: "label") == nil }
                }
                let rendered = try await renderedText(window, filename: "sidebar-metrics-\(Int(width))-\(id).jpg")
                XCTAssertEqual(hosted.bounds.width, width + 24, accuracy: 0.5)
                XCTAssertTrue(rendered.contains("12.34"), "Cost must remain visible at \(width)pt: \(rendered)")
                // All 100 tokens over TTFT + span = one second.
                if item.output == nil {
                    XCTAssertFalse(rendered.contains("unavailable") || rendered.contains("latest"), "No measured rate leaves the slot empty at \(width)pt: \(rendered) " +
                                   "(the app draws: \(metrics.shownRate ?? "nothing"); occluded: \(!window.occlusionState.contains(.visible)); on screen: \(window.isOnActiveSpace && window.isVisible))")
                } else {
                    XCTAssertTrue(rendered.contains("latest 100"), "The complete rate label must remain visible at \(width)pt: \(rendered)")
                }
                if item.state != "idle" { XCTAssertTrue(rendered.contains(item.state), rendered) }
                let height = metrics.height(forWidth: width) + 24
                if width == 226 { wideHeights[id] = height }
                else {
                    XCTAssertGreaterThan(height, try XCTUnwrap(wideHeights[id]) + 8,
                                         "The narrow row must wrap the rate below state/cost; a fixed outer width alone can conceal overflowing children")
                }
            }
        }
        }
    }

    /// What the window server shows once it has settled: two readings in a
    /// row that agree. Its image can lag the app's committed frame under the
    /// parallel lane's load; one reading there still showed the previous
    /// fixture's "latest 100 tok/s" after the app had cleared it.
    @MainActor private func renderedText(_ window: NSWindow, filename: String) async throws -> String {
        var previous = try await Self.recognizedText(in: window, filename: filename)
        for _ in 0..<10 {
            let next = try await Self.recognizedText(in: window, filename: filename)
            if next == previous { return next }
            print("Sidebar metrics capture still settling: \(previous) -> \(next)")
            previous = next
        }
        return previous
    }
    /// The words a window shows, read off its pixels: what the reader sees,
    /// lowercased. `PI_APP_USAGE_CAPTURE_ROOT` keeps the capture as evidence.
    @MainActor static func recognizedText(in window: NSWindow, filename: String? = nil) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                        CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        if let path = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT"), let filename {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
            try jpeg.write(to: folder.appendingPathComponent(filename), options: .atomic)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    }
}

/// The footer at one pane width, as `ConversationPane` lays it under the composer.
private struct FooterWidthProbe: View {
    let model: WorkspaceModel
    let session: SessionDisplay
    let width: CGFloat
    /// A side's footer, which keeps only its own two figures.
    var compact = false
    var body: some View { HostedMetricsFooter(model: model, session: session, compact: compact).frame(width: width) }
}

/// The AppKit footer where a SwiftUI test lays it out: one footer for as
/// long as its chat and form stay (its rooms with it), made again for another.
struct HostedMetricsFooter: NSViewRepresentable {
    let model: WorkspaceModel
    let session: SessionDisplay
    var compact = false
    var inspect: () -> Void = {}
    final class Holder: NSView {
        var footer: MetricsFooter?
        override var isFlipped: Bool { true }
        override func layout() { super.layout(); footer?.frame = bounds }
    }
    func makeNSView(context: Context) -> Holder { let holder = Holder(); updateNSView(holder, context: context); return holder }
    func updateNSView(_ holder: Holder, context: Context) {
        guard holder.footer?.session !== session || holder.footer?.compact != compact else { return }
        holder.footer?.removeFromSuperview()
        let footer = MetricsFooter(model: model, session: session, compact: compact, inspect: inspect)
        holder.addSubview(footer); holder.footer = footer
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Holder, context: Context) -> CGSize? {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: nsView.footer?.height(forWidth: width) ?? 0)
    }
}

extension SessionTimingTests {
    func testArchivedOldRateIsIgnoredAndRawTimingsSurviveReopen() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        let rawID = UUID().uuidString, rateOnlyID = UUID().uuidString
        var raw = metadata(id: rawID, ttft: 2_000, duration: 9_000, output: 101, last: 3_000)
        raw["metrics"] = .object(["decodeTokensPerSecond": .number(100)])
        try await Self.save(archive, raw)
        var rateOnly = metadata(id: rateOnlyID, ttft: nil, duration: nil, output: 10_000)
        rateOnly["metrics"] = .object(["decodeTokensPerSecond": .number(99_999)])
        try await Self.save(archive, rateOnly)
        try await archive.close()
        let reopened = try await configured(root)
        let history = try await reopened.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        let rate = try XCTUnwrap(history.historicalSettledThroughput)
        XCTAssertEqual(rate.samples, 1); XCTAssertEqual(rate.requests, 2)
        XCTAssertEqual(try XCTUnwrap(rate.tokensPerSecond), 101 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(history.samples.first { $0.id == rawID }?.ttftMilliseconds, 2_000)
        XCTAssertNil(history.samples.first { $0.id == rateOnlyID }?.settledTokensPerSecond)
        let totals = try await reopened.sessionMetrics(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(totals.gateway.settledThroughput, rate)
        try await reopened.close()
    }
}
