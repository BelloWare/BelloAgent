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
    private func metadata(id: String = UUID().uuidString, session: String = "session", wall: Double = 999_995,
                          outcome: String = "completed", ttft: Double? = 200, duration: Double? = 1_000, output: Double? = 100) -> [String: WireValue] {
        var timings: [String: WireValue] = ["dispatch": .number(100)]
        if let ttft { timings["firstContent"] = .number(100 + ttft) }
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

    func testLatestAndWeightedSessionAverageRemainScopedAndDistinct() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        var first = metadata(wall: 999_990, ttft: 900, duration: 1_000, output: 100)
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
        XCTAssertEqual(history.latest?.outputTokensPerSecond, 20)
        XCTAssertEqual(history.points(for: .rate).map(\.value), [100, 20])
        XCTAssertEqual(history.historicalRate, HistoricalOutputRate(outputTokens: 160, generationMilliseconds: 4_000, samples: 2))
        XCTAssertEqual(history.historicalRate.tokensPerSecond, 40, "Use total output / total duration, without counting reasoning or repeated updates again")
        XCTAssertEqual(history.completedRequests, 2)
        let sessionUsage = try await archive.sessionMetrics(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(sessionUsage.historicalRate, history.historicalRate, "Footer and usage window must use the same retained-session weighted rate")
        try await archive.close()
        let restored = try await configured(root)
        let persisted = try await restored.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(persisted, history, "Helper eviction/restart cannot erase the latest completed request")
        try await restored.close()
    }

    func testMissingMetricsNeverBecomeZeroOrReuseAnOlderRequestsRate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        try await Self.save(archive, metadata(wall: 999_990, ttft: 0, duration: 1_000, output: 0))
        try await Self.save(archive, metadata(wall: 999_991, ttft: nil, duration: nil, output: nil))
        try await Self.save(archive, metadata(wall: 999_992, ttft: 100, duration: 1_000, output: 40))
        let missing = try await Self.save(archive, metadata(wall: 999_993, ttft: 200, duration: 1_000, output: nil))
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.latest?.id, missing); XCTAssertEqual(history.latest?.ttftMilliseconds, 200)
        XCTAssertNil(history.latest?.outputTokensPerSecond)
        XCTAssertEqual(history.historicalRate.tokensPerSecond, 20)
        XCTAssertEqual(history.historicalRate.samples, 2)
        XCTAssertEqual(history.completedRequests, 4, "Missing usage/timing stays visible in average coverage")
        XCTAssertEqual(history.points(for: .ttft).map(\.value), [0, 100, 200])
        XCTAssertEqual(history.points(for: .rate).map(\.value), [0, 40])
        XCTAssertEqual(history.points(for: .rate).map(\.index), [1, 3])
        XCTAssertEqual(history.points(for: .rate).map(\.segment), [0, 1], "Missing observations are chart gaps, not synthetic connecting lines")
        XCTAssertEqual(SessionTimingMetric.rate.label(0), "0 tok/s")
        XCTAssertEqual(SessionTimingMetric.ttft.label(nil), "Unavailable")
        try await archive.close()
    }

    func testRequestDurationMigrationCountsHiddenReasoningWithoutFirstContentAndExpiresCleanly() async throws {
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
        XCTAssertEqual(try XCTUnwrap(silent.outputTokensPerSecond), 302.0 / 2.403, accuracy: 1e-9, "Reasoning is already inside gateway output; no visible text estimate participates")
        XCTAssertEqual(history.samples.first { $0.id == zeroID }?.outputTokensPerSecond, 0)
        XCTAssertNil(history.samples.first { $0.id == zeroDurationID }?.outputTokensPerSecond)
        XCTAssertNil(history.samples.first { $0.id == missingEndID }?.requestMilliseconds)
        XCTAssertEqual(history.latest?.id, missingUsageID)
        XCTAssertEqual(SessionRatePresentation(history: history).label, "Usage unavailable")
        let expected = HistoricalOutputRate(outputTokens: 302, generationMilliseconds: 3_403, samples: 2)
        XCTAssertEqual(history.historicalRate, expected)
        let menu = try await migrated.menuBarMetrics(period: .retained, until: until)
        let session = try await migrated.sessionMetrics(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(menu.historicalRate, expected); XCTAssertEqual(session.historicalRate, expected)
        let info = SessionInfoTiming(history: SessionTimingHistory(samples: [silent]), work: [:])
        XCTAssertEqual(info.latestDurationMs, 2_403); XCTAssertEqual(info.latestRate, silent.outputTokensPerSecond)
        try await migrated.update(expired)
        try await migrated.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let retired = try db.rows("SELECT request_ms,metrics_retained FROM attempts WHERE id=?", [.text(expiredID)]).first
        XCTAssertNil(retired?["request_ms"]?.double, "Neither expiry nor a late metadata update may retain or resurrect duration")
        XCTAssertEqual(retired?["metrics_retained"]?.number, 0)
        XCTAssertEqual(try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").first?["value"]?.data, Data([7]))
    }

    func testHistoryIsBoundedChronologicalAndUsesTheSessionIndex() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await configured(root)
        for index in 0..<132 { try await Self.save(archive, metadata(wall: 999_000 + Double(index), output: Double(index))) }
        let history = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: "project", until: until)
        XCTAssertEqual(history.samples.count, 128); XCTAssertTrue(history.hasOlderRequests)
        XCTAssertEqual(history.samples.first?.outputTokens, 4); XCTAssertEqual(history.samples.last?.outputTokens, 131)
        XCTAssertEqual(history.historicalRate.tokensPerSecond, 65.5, "The average includes retained requests older than the chart's 128-sample limit")
        XCTAssertEqual(history.historicalRate.samples, 132)
        XCTAssertEqual(history.completedRequests, 132)
        for identity in ["", String(repeating: "x", count: 129), "invalid\nidentity"] {
            do { _ = try await archive.sessionTimingHistory(sessionID: identity, workspaceID: "project", until: until); XCTFail("Invalid session scope accepted") } catch { }
            do { _ = try await archive.sessionTimingHistory(sessionID: "session", workspaceID: identity, until: until); XCTFail("Invalid project scope accepted") } catch { }
        }
        let injected = try await archive.sessionTimingHistory(sessionID: "session' OR 1=1 --", workspaceID: "project", until: until)
        XCTAssertTrue(injected.samples.isEmpty)
        XCTAssertNil(injected.historicalRate.tokensPerSecond)
        XCTAssertEqual(injected.completedRequests, 0)
        try await archive.close()
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let plan = try db.rows("EXPLAIN QUERY PLAN SELECT id,wall,ttft_ms,stream_ms,output_tokens FROM attempts WHERE session=? AND workspace=? AND metrics_retained=1 AND wall<? AND dispatch IS NOT NULL AND outcome='completed' ORDER BY wall DESC,id DESC LIMIT 129",
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
        XCTAssertEqual(history.historicalRate, HistoricalOutputRate(outputTokens: 25, generationMilliseconds: 1_000, samples: 1))
        XCTAssertEqual(history.completedRequests, 1)
        try await archive.close()
    }

    func testInvalidAndBufferedTimingValuesRemainHonest() {
        XCTAssertEqual(sample("buffered", ttft: 2_000, duration: 2_000, output: 100).outputTokensPerSecond, 50)
        XCTAssertNil(sample("zero-duration", ttft: 0, duration: 0).outputTokensPerSecond)
        XCTAssertEqual(sample("negative-stream", ttft: 2_000, duration: 1_000).outputTokensPerSecond, 100, "Invalid first-content observations do not erase a separately valid request duration")
        XCTAssertNil(sample("negative-tokens", output: -1).outputTokensPerSecond)
        XCTAssertEqual(sample("missing-ttft", ttft: nil).outputTokensPerSecond, 100)
        XCTAssertNil(sample("missing-duration", duration: nil).outputTokensPerSecond)
        XCTAssertNil(sample("negative-duration", duration: -1).outputTokensPerSecond)
        XCTAssertNil(sample("nan", output: .nan).outputTokensPerSecond)
        XCTAssertNil(sample("infinite", duration: .infinity).outputTokensPerSecond)
        let overflow = SessionTimingSample(id: "overflow", wall: until, ttftMilliseconds: .greatestFiniteMagnitude,
                                           streamingMilliseconds: .greatestFiniteMagnitude, outputTokens: 1)
        XCTAssertNil(overflow.outputTokensPerSecond)
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
        XCTAssertEqual(display.footer.timing.latest?.outputTokensPerSecond, 80)
        XCTAssertEqual(display.footer.timing.historicalRate.tokensPerSecond, 80)
        let id = UUID().uuidString
        let pending = metadata(id: id, wall: now - 1, outcome: "running", ttft: nil, duration: nil, output: nil)
        try await Self.save(model.traces, pending)
        await model.refreshAccounting(display, workspaceID: "project")
        XCTAssertEqual(display.footer.timing.latest?.id, previous["attemptId"]?.string)
        XCTAssertEqual(display.footer.timing.historicalRate.samples, 1, "Pending work must not change the completed average")
        let completed = metadata(id: id, wall: now - 1, ttft: 300, duration: 2_000, output: 50)
        try await model.traces.finish(completed)
        await model.captureDidPersist(["type": .string("finish"), "metadata": .object(completed)], workspaceID: "project")
        for _ in 0..<200 where !model.accountingTasks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.accountingTasks.isEmpty)
        XCTAssertEqual(display.footer.timing.latest?.id, id)
        XCTAssertEqual(display.footer.timing.latest?.ttftMilliseconds, 300)
        XCTAssertEqual(display.footer.timing.latest?.outputTokensPerSecond, 25)
        XCTAssertEqual(try XCTUnwrap(display.footer.timing.historicalRate.tokensPerSecond), 130.0 / 3, accuracy: 1e-10)
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

    @MainActor func testHoverPreviewAllowsCrossingIntoChartAndClickPinsIt() async throws {
        let hover = SessionTimingHover(openDelay: .milliseconds(10), closeDelay: .milliseconds(30))
        defer { hover.stop() }
        hover.triggerHover(true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(hover.presented); XCTAssertFalse(hover.pinned)
        hover.triggerHover(false)
        hover.panelHover(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hover.presented, "The preview must not vanish when the pointer enters the chart")
        hover.togglePinned(); hover.panelHover(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hover.presented); XCTAssertTrue(hover.pinned)
        hover.togglePinned()
        XCTAssertFalse(hover.presented); XCTAssertFalse(hover.pinned)
    }

    @MainActor func testBriefHoverAndDisappearingSessionDoNotLeaveAPopup() async throws {
        let hover = SessionTimingHover(openDelay: .milliseconds(30), closeDelay: .milliseconds(10))
        hover.triggerHover(true); hover.triggerHover(false)
        try await Task.sleep(for: .milliseconds(50)); XCTAssertFalse(hover.presented)
        hover.togglePinned(); XCTAssertTrue(hover.presented)
        hover.stop(); XCTAssertFalse(hover.presented)
        hover.triggerHover(true); hover.stop()
        try await Task.sleep(for: .milliseconds(50)); XCTAssertFalse(hover.presented)
    }

    @MainActor func testLatestAndAverageRatesStayVisibleInWideAndNarrowFooters() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let session = SessionDisplay(id: "timing-preview")
        session.state = "running"
        session.footer.timing = SessionTimingHistory(samples: [sample("earlier"), sample("latest", ttft: 2_000, duration: 3_000, output: 60)],
                                                    historicalRate: HistoricalOutputRate(outputTokens: 160, generationMilliseconds: 4_000, samples: 2), completedRequests: 2)
        let hosted = NSHostingView(rootView: MetricsFooter(model: model, session: session, inspect: {}).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color.piSurface))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1_000, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for width in [1_000, 420] {
            window.setContentSize(NSSize(width: CGFloat(width), height: 100))
            let rendered = try await renderedText(window, filename: "session-timing-footer-\(width).jpg")
            XCTAssertEqual(hosted.bounds.width, CGFloat(width), accuracy: 0.5)
            XCTAssertTrue(rendered.contains("latest 20"), "Latest completed rate must remain visible while a request is running. OCR: \(rendered)")
            XCTAssertTrue(rendered.contains("avg 40"), "The same footer must also show the weighted session average at width \(width). OCR: \(rendered)")
        }
        session.footer.timing.samples.append(sample("missing", output: nil))
        session.footer.timing.completedRequests = 3
        let missing = try await renderedText(window, filename: "session-timing-footer-missing.jpg")
        XCTAssertTrue(missing.contains("usage unavailable"), "Missing latest usage must not reuse either the preceding rate or the session average. OCR: \(missing)")
        XCTAssertTrue(missing.contains("avg 40"), missing)
    }

    @MainActor func testSidebarRateSlotKeepsItsGeometryForAwaitingReportedAndUnavailableUsage() {
        let variants = [SessionTimingHistory(),
                        SessionTimingHistory(samples: [sample("reported", output: 8_000)]),
                        SessionTimingHistory(samples: [sample("zero", output: 0)]),
                        SessionTimingHistory(samples: [sample("missing", output: nil)])]
        for reduced in [false, true] {
            let hosted = NSHostingView(rootView: AnyView(SidebarReportedRate(history: variants[0], sessionTitle: "Fixture").piStableLayout(reduceMotion: reduced)))
            var sizes: [NSSize] = []
            for history in variants {
                hosted.rootView = AnyView(SidebarReportedRate(history: history, sessionTitle: "Fixture").piStableLayout(reduceMotion: reduced))
                hosted.layoutSubtreeIfNeeded()
                sizes.append(hosted.fittingSize)
            }
            XCTAssertGreaterThan(sizes[0].width, 0); XCTAssertGreaterThan(sizes[0].height, 0)
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
        let hosted = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 250, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var wideHeights: [String: CGFloat] = [:]
        // The sidebar tells the line its width, so the shipped path chooses its
        // form by measuring the figures; a line told nothing still lays the
        // forms out to find one that fits. Both must keep everything readable.
        for told in [false, true] {
        for width in [CGFloat(226), CGFloat(126), CGFloat(112)] {
            for item in cases {
                let id = item.state + (item.output == nil ? "-missing" : "") + (told ? "-told" : "")
                var stats = ChatRowStats(totals: nil, timing: SessionTimingHistory(samples: [sample(id, output: item.output)]))
                stats.requests = 1; stats.costUSD = 12.34
                stats.updateActivity(state: item.state, loading: false, activity: [:])
                hosted.rootView = AnyView(ChatRowMetrics(stats: stats, title: "Fixture", available: told ? width : .infinity)
                    .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12))
                window.setContentSize(NSSize(width: width + 24, height: 80))
                let rendered = try await renderedText(window, filename: "sidebar-metrics-\(Int(width))-\(id).jpg")
                XCTAssertEqual(hosted.bounds.width, width + 24, accuracy: 0.5)
                XCTAssertTrue(rendered.contains("12.34"), "Cost must remain visible at \(width)pt: \(rendered)")
                XCTAssertTrue(rendered.contains(item.output == nil ? "usage unavailable" : "latest 100"), "The complete rate label must remain visible at \(width)pt: \(rendered)")
                if item.state != "idle" { XCTAssertTrue(rendered.contains(item.state), rendered) }
                let height = hosted.fittingSize.height
                if width == 226 { wideHeights[id] = height }
                else {
                    XCTAssertGreaterThan(height, try XCTUnwrap(wideHeights[id]) + 8,
                                         "The narrow row must wrap the rate below state/cost; a fixed outer width alone can conceal overflowing children")
                }
            }
        }
        }
    }

    @MainActor private func renderedText(_ window: NSWindow, filename: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                        CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        if let path = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") {
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

    @MainActor func testOptionalNativeTimingChartPreview() async throws {
        guard let directory = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") else { return }
        let output = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let samples = (0..<16).map { index in
            SessionTimingSample(id: "request-\(index)", wall: Date(timeIntervalSince1970: 1_789_535_000 + Double(index * 60)),
                                ttftMilliseconds: index == 7 ? nil : Double(250 + (index * 113) % 1300), streamingMilliseconds: 1_200,
                                outputTokens: index == 9 ? nil : Double(60 + (index * 11) % 70), requestMilliseconds: Double(1450 + (index * 113) % 1300))
        }
        let observed = samples.filter { $0.outputTokensPerSecond != nil }
        let average = HistoricalOutputRate(outputTokens: observed.compactMap(\.outputTokens).reduce(0, +),
                                           generationMilliseconds: observed.reduce(0) { $0 + ($1.requestMilliseconds ?? 0) }, samples: observed.count)
        let history = SessionTimingHistory(samples: samples, historicalRate: average, completedRequests: samples.count)
        let hosted = NSHostingView(rootView: SessionTimingHistoryView(history: history, sessionTitle: "Gateway timing review", close: {}))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 430, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<20 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(hosted.fittingSize.height, 300)
        // Capture only this synthetic hosted view, never the user's desktop.
        guard let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else { return XCTFail("Chart preview has no bitmap") }
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        try data.write(to: output.appendingPathComponent("session-timing-history.jpg"))
    }
}
