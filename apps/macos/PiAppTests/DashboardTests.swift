import XCTest
@testable import PiApp

private final class DashboardClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 2000
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ amount: TimeInterval) { lock.lock(); defer { lock.unlock() }; seconds += amount }
}

final class DashboardTests: XCTestCase {
    private let key = Data(repeating: 0x29, count: 32)
    private func folder() throws -> URL {
        let result = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dashboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func metadata(id: String, wall: Double = 1995, session: String = "session", api: String = "openai-responses", alias: String = "router", model: String? = "reported-model", purpose: String = "turn", outcome: String = "completed", ttft: Double? = 10, stream: Double? = 20, http: Double? = 100, dispatch: Double? = 1000, timingVersion: Int? = 2) -> [String: WireValue] {
        var timings: [String: WireValue] = [:]
        if let dispatch { timings["dispatch"] = .number(dispatch) }
        if let dispatch, let ttft { timings["firstContent"] = .number(dispatch + ttft) }
        if let dispatch, let ttft, let stream { timings["modelComplete"] = .number(dispatch + ttft + stream) }
        if let dispatch, let http { timings["httpEnd"] = .number(dispatch + http) }
        var value: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string("turn"), "purpose": .string(purpose), "api": .string(api), "requestedModel": .string(alias), "mode": .string("off"), "outcome": .string(outcome), "wallTimestamp": .number(wall - 5), "dispatchWallTimestamp": .number(wall), "timings": .object(timings), "messageIds": .array([.string("input")])]
        if let model { value["identity"] = .object(["effectiveModel": .string(model)]) }
        if let timingVersion { value["timingVersion"] = .number(Double(timingVersion)) }
        return value
    }
    @discardableResult private func save(_ archive: PayloadArchive, workspace: String = "workspace", _ value: [String: WireValue]) async throws -> String {
        try await archive.begin(value, workspace: workspace)
        if value["outcome"]?.string != "running" { try await archive.finish(value) }
        return value["attemptId"]!.string!
    }
    private func filter(status: String = "completed") -> DashboardFilter {
        DashboardFilter(from: Date(timeIntervalSince1970: 1900), until: Date(timeIntervalSince1970: 2001), status: status, bucketCount: 2)
    }

    func testExactNearestRankAndIndependentBucketSamplesNeverAveragePercentiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for n in 1...100 {
            try await save(archive, metadata(id: UUID().uuidString, wall: n <= 99 ? 1920 : 1980, ttft: Double(n), stream: Double(n * 2), http: Double(n * 3)))
        }
        try await save(archive, metadata(id: UUID().uuidString, wall: 1980, ttft: 10_000, stream: 20_000, http: 30_000))
        let result = try await archive.dashboard(filter())
        XCTAssertEqual(result.scopeCounts.dispatched, 101); XCTAssertEqual(result.selectedRequests, 101)
        XCTAssertEqual(result.ttft, DashboardPercentiles(samples: 101, p50: 51, p99: 100))
        XCTAssertEqual(result.streaming, DashboardPercentiles(samples: 101, p50: 102, p99: 200))
        XCTAssertEqual(result.http, DashboardPercentiles(samples: 101, p50: 153, p99: 300))
        XCTAssertEqual(result.buckets[0].ttft, DashboardPercentiles(samples: 99, p50: 50, p99: 99))
        XCTAssertEqual(result.buckets[1].ttft, DashboardPercentiles(samples: 2, p50: 100, p99: 10_000))
        XCTAssertNotEqual(result.ttft.p99, (result.buckets[0].ttft.p99! + result.buckets[1].ttft.p99!) / 2)
        XCTAssertEqual(result.buckets.map(\.requests), [99, 2])
    }

    func testNullIsNotZeroAndErrorsCancellationInflightAreVisibleButExplicitlySelected() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await save(archive, metadata(id: UUID().uuidString, ttft: 0, stream: 0, http: 0, dispatch: 0))
        try await save(archive, metadata(id: UUID().uuidString, ttft: nil, stream: nil, http: 20))
        try await save(archive, metadata(id: UUID().uuidString, outcome: "failed", ttft: nil, stream: nil, http: 500))
        try await save(archive, metadata(id: UUID().uuidString, outcome: "cancelled", ttft: 40, stream: nil, http: 80))
        try await save(archive, metadata(id: UUID().uuidString, outcome: "running", ttft: 50, stream: nil, http: nil))
        try await save(archive, metadata(id: UUID().uuidString, outcome: "truncated", ttft: 10, stream: 5, http: 25))
        try await save(archive, metadata(id: UUID().uuidString, outcome: "running", dispatch: nil))
        try await save(archive, metadata(id: UUID().uuidString, timingVersion: nil))
        let completed = try await archive.dashboard(filter())
        XCTAssertEqual(completed.scopeCounts, DashboardCounts(dispatched: 6, completed: 2, failed: 1, cancelled: 1, running: 1, truncated: 1, interrupted: 0, unobservedDispatch: 2))
        XCTAssertEqual(completed.selectedRequests, 2)
        XCTAssertEqual(completed.ttft, DashboardPercentiles(samples: 1, p50: 0, p99: 0))
        XCTAssertEqual(completed.streaming.samples, 1); XCTAssertEqual(completed.http.samples, 2)
        let all = try await archive.dashboard(filter(status: "all"))
        XCTAssertEqual(all.selectedRequests, 6); XCTAssertEqual(all.ttft.samples, 4); XCTAssertEqual(all.http.samples, 5)
        let cancelled = try await archive.dashboard(filter(status: "cancelled"))
        XCTAssertEqual(cancelled.selectedRequests, 1); XCTAssertEqual(cancelled.ttft.p50, 40); XCTAssertNil(cancelled.streaming.p50)
        XCTAssertEqual(cancelled.scopeCounts.failed, 1, "Status filtering must not hide scope error counts")
    }

    func testEveryDimensionExactFiltersDispatchWallAndUnknownModelsAreIndependent() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let targetID = UUID().uuidString
        try await save(archive, workspace: "chosen-workspace", metadata(id: targetID, wall: 1998, session: "chosen-session", api: "anthropic-messages", alias: "auto-router", model: "upstream-B", purpose: "compaction"))
        try await save(archive, metadata(id: UUID().uuidString, model: "upstream-A"))
        try await save(archive, metadata(id: UUID().uuidString, model: nil))
        var query = filter()
        for keyPath in [\DashboardFilter.workspaceID, \.sessionID, \.purpose, \.api, \.requestedAlias, \.effectiveModel] {
            let matching: [WritableKeyPath<DashboardFilter, String?>: String] = [\.workspaceID: "chosen-workspace", \.sessionID: "chosen-session", \.purpose: "compaction", \.api: "anthropic-messages", \.requestedAlias: "auto-router", \.effectiveModel: "upstream-B"]
            var individual = query; individual[keyPath: keyPath] = matching[keyPath]
            let result = try await archive.dashboard(individual)
            XCTAssertEqual(result.requests.map(\.id), [targetID])
        }
        query.from = Date(timeIntervalSince1970: 1997); query.until = Date(timeIntervalSince1970: 1999)
        let byTime = try await archive.dashboard(query)
        XCTAssertEqual(byTime.requests.map(\.id), [targetID], "Use actual dispatch wall time, not pre-capture preparation time")
        query = filter(); query.unreportedModelOnly = true
        let unreported = try await archive.dashboard(query); XCTAssertEqual(unreported.selectedRequests, 1)
        query = filter(); query.requestedAlias = "auto-router' OR 1=1 --"
        let injection = try await archive.dashboard(query); XCTAssertEqual(injection.selectedRequests, 0)
    }

    func testDurabilityMigrationBodyPurgeAndMetricExpiryKeepExactRequestLinks() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DashboardClock(), archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let id = try await save(archive, metadata(id: UUID().uuidString))
        try await archive.purge(attemptID: id)
        let afterPurge = try await archive.dashboard(filter()); XCTAssertEqual(afterPurge.ttft.p99, 10)
        try await archive.close()
        // Reproduce schema-v2 upgrade and an interrupted column/backfill
        // migration without loading all historic metadata into memory.
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("PRAGMA user_version=2")
            try db.execute("UPDATE attempts SET dispatch=NULL,ttft_ms=NULL,stream_ms=NULL,http_ms=NULL")
        }
        let reopened = PayloadArchive(root: root, now: { clock.now() })
        try await reopened.configure(key: key, quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let migrated = try await reopened.dashboard(filter()); XCTAssertEqual(migrated.ttft, DashboardPercentiles(samples: 1, p50: 10, p99: 10))
        let active = try await save(reopened, metadata(id: UUID().uuidString, outcome: "running", ttft: nil, stream: nil, http: nil))
        try await reopened.close()
        let recovered = PayloadArchive(root: root, now: { clock.now() })
        try await recovered.configure(key: key, quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let afterCrash = try await recovered.dashboard(filter(status: "all"))
        XCTAssertEqual(afterCrash.scopeCounts.running, 0); XCTAssertEqual(afterCrash.scopeCounts.interrupted, 1)
        XCTAssertNil(afterCrash.requests.first(where: { $0.id == active })?.http)
        clock.advance(101)
        let expired = try await recovered.dashboard(filter(status: "all")); XCTAssertEqual(expired.selectedRequests, 0)
        let linked = try await recovered.list(sessionID: "session", messageID: "input")
        XCTAssertEqual(linked.count, 2); XCTAssertTrue(linked.allSatisfy { $0["metricsExpired"] == .bool(true) })
    }

    func testRequestPaginationAndInvalidFiltersAreBounded() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for n in 0..<129 { try await save(archive, metadata(id: UUID().uuidString, wall: 1950 + Double(n) / 10)) }
        let first = try await archive.dashboard(filter()), second = try await archive.dashboard(filter(), offset: 128)
        XCTAssertEqual(first.requests.count, 128); XCTAssertTrue(first.hasNext)
        XCTAssertEqual(second.requests.count, 1); XCTAssertFalse(second.hasNext)
        XCTAssertTrue(Set(first.requests.map(\.id)).isDisjoint(with: second.requests.map(\.id)))
        var invalid = filter(); invalid.status = "anything"
        do { _ = try await archive.dashboard(invalid); XCTFail("Reject arbitrary status") } catch { }
        invalid = filter(); invalid.bucketCount = 61
        do { _ = try await archive.dashboard(invalid); XCTFail("Bound time series") } catch { }
        invalid = filter(); invalid.from = invalid.until
        do { _ = try await archive.dashboard(invalid); XCTFail("Reject empty window") } catch { }
        do { _ = try await archive.dashboard(filter(), offset: -1); XCTFail("Reject negative page") } catch { }
    }

    func testMetricsMayExpireBeforeBodiesWithoutDestroyingExactPayloads() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DashboardClock(), archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 1000, metricRetention: 10)
        let id = UUID().uuidString, bytes = Data("original request bytes 🧪".utf8)
        var value = metadata(id: id); value["mode"] = .string("persist")
        try await archive.begin(value, workspace: "workspace")
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: bytes)
        value["request"] = .object(["observedBytes": .number(Double(bytes.count))])
        try await archive.finish(value)
        clock.advance(11)
        let result = try await archive.dashboard(filter(status: "all"))
        XCTAssertEqual(result.selectedRequests, 0)
        let retained = try await archive.body(attemptID: id, body: "request", offset: 0)
        XCTAssertEqual(retained, bytes)
        let record = try await archive.metadata(attempt: id)
        XCTAssertEqual(record["metricsExpired"], .bool(true))
        XCTAssertEqual(record["request"]?.object?["state"], .string("complete"))
        let exported = try await archive.exportRetained(sessionID: "session", attemptID: id, destination: root)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("request.bin")), bytes)
    }

    func testConflictingAndIncompleteModelIdentityRemainDistinctAfterSchemaThreeMigration() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for status in ["conflict", "incomplete", "unreported"] {
            var value = metadata(id: UUID().uuidString, model: nil)
            value["identity"] = .object(["status": .string(status), "effectiveModel": .null, "evidence": .array([
                .object(["kind": .string("model"), "source": .string("header:x-fixture-model"), "value": .string("model-A")]),
                .object(["kind": .string("model"), "source": .string("body.model"), "value": .string("model-B")])])])
            try await save(archive, value)
        }
        var query = filter(); query.unreportedModelOnly = true
        let result = try await archive.dashboard(query)
        XCTAssertEqual(result.selectedRequests, 3)
        XCTAssertEqual(Set(result.requests.map(\.identityStatus)), ["conflict", "incomplete", "unreported"])
        XCTAssertTrue(result.requests.allSatisfy { $0.effectiveModel == nil })
        let conflicting = try XCTUnwrap(result.requests.first { $0.identityStatus == "conflict" })
        XCTAssertEqual(conflicting.reportedModels, ["model-A", "model-B"], "Conflicting reports keep every name")
        XCTAssertEqual(conflicting.displayModel, "model-A", "The shortest name is shown by default")
        XCTAssertTrue(result.requests.filter { $0.identityStatus != "conflict" }.allSatisfy { $0.reportedModels.isEmpty && $0.displayModel == nil })
        try await archive.close()
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.execute("ALTER TABLE attempts DROP COLUMN identity_status")
            try db.execute("PRAGMA user_version=3")
        }
        let reopened = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await reopened.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let migrated = try await reopened.dashboard(query)
        XCTAssertEqual(Set(migrated.requests.map(\.identityStatus)), ["conflict", "incomplete", "unreported"])
        let conflictID = try XCTUnwrap(migrated.requests.first { $0.identityStatus == "conflict" }?.id)
        XCTAssertEqual(migrated.requests.first { $0.id == conflictID }?.reportedModels, ["model-A", "model-B"], "Re-projection restores both names for older rows")
        let stored = try await reopened.metadata(attempt: conflictID)
        XCTAssertEqual(stored["identity"]?.object?["evidence"]?.array?.count, 2)
    }

    func testDistinctAliasesModelsAndPurposesIgnoreTheirOwnClauseAndStayInsideTheWindow() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await save(archive, metadata(id: UUID().uuidString, alias: "router-b", model: "upstream-B", purpose: "compaction"))
        try await save(archive, metadata(id: UUID().uuidString, alias: "router-a", model: "upstream-A"))
        try await save(archive, metadata(id: UUID().uuidString, alias: "router-a", model: "upstream-A"))
        try await save(archive, metadata(id: UUID().uuidString, alias: "router-c", model: nil))
        try await save(archive, metadata(id: UUID().uuidString, alias: "failed-only", model: "failed-model", outcome: "failed"))
        try await save(archive, metadata(id: UUID().uuidString, wall: 1850, alias: "outside", model: "outside-model"))
        try await save(archive, metadata(id: UUID().uuidString, alias: "unobserved", model: "unobserved-model", dispatch: nil))
        let observed1 = try await archive.distinctAliases(filter()); XCTAssertEqual(observed1, ["router-a", "router-b", "router-c"], "Sorted, deduplicated, dispatched, in window, selected status only")
        let observed2 = try await archive.distinctModels(filter()); XCTAssertEqual(observed2, ["upstream-A", "upstream-B"], "Unreported models are not a value")
        let observed3 = try await archive.distinctPurposes(filter()); XCTAssertEqual(observed3, ["compaction", "turn"])
        let observed4 = try await archive.distinctAliases(filter(status: "all")); XCTAssertEqual(observed4, ["failed-only", "router-a", "router-b", "router-c"])
        var narrowed = filter(); narrowed.requestedAlias = "router-b"; narrowed.effectiveModel = "upstream-B"; narrowed.purpose = "compaction"
        let observed5 = try await archive.distinctAliases(narrowed); XCTAssertEqual(observed5, ["router-b"], "Other dimensions still apply")
        let observed6 = try await archive.distinctModels(narrowed); XCTAssertEqual(observed6, ["upstream-B"])
        var aliasOnly = filter(); aliasOnly.requestedAlias = "router-b"
        let observed7 = try await archive.distinctAliases(aliasOnly); XCTAssertEqual(observed7, ["router-a", "router-b", "router-c"], "A picker lists alternatives to its own current value")
        var unreported = filter(); unreported.unreportedModelOnly = true
        let observed8 = try await archive.distinctModels(unreported); XCTAssertEqual(observed8, ["upstream-A", "upstream-B"], "The unreported-only clause is ignored for the model picker")
        let observed9 = try await archive.distinctAliases(unreported); XCTAssertEqual(observed9, ["router-c"])
        var injection = filter(); injection.requestedAlias = "x' OR 1=1 --"
        let observed10 = try await archive.distinctModels(injection); XCTAssertEqual(observed10, [])
        var invalid = filter(); invalid.status = "anything"
        do { _ = try await archive.distinctAliases(invalid); XCTFail("Distinct helpers validate the filter") } catch { }
    }

    func testDistinctValuesAreBounded() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for n in 0..<(PayloadArchive.distinctLimit + 3) { try await save(archive, metadata(id: UUID().uuidString, alias: String(format: "alias-%04d", n))) }
        let aliases = try await archive.distinctAliases(filter())
        XCTAssertEqual(aliases.count, PayloadArchive.distinctLimit)
        XCTAssertEqual(aliases.first, "alias-0000"); XCTAssertEqual(aliases, aliases.sorted())
    }

    func testWindowPresetResolutionKeepsLegacyHoursAndCustomBounds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var preferences = DashboardPreferences()
        XCTAssertEqual(DashboardWindow.resolve(preferences, now: now), DashboardWindow(from: now.addingTimeInterval(-86400), until: now, preset: .day), "Legacy records without a preset resolve from windowHours")
        preferences.windowHours = 168
        XCTAssertEqual(DashboardWindow.resolve(preferences, now: now).preset, .week)
        preferences.windowHours = 5
        let odd = DashboardWindow.resolve(preferences, now: now)
        XCTAssertEqual(odd.preset, .custom); XCTAssertEqual(odd.span, 5 * 3600, "Unmatched legacy hours keep their relative window")
        for preset in DashboardWindowPreset.allCases where preset != .custom {
            DashboardWindow.apply(preset, to: &preferences, now: now)
            XCTAssertEqual(preferences.windowPreset, preset.rawValue); XCTAssertEqual(preferences.windowHours, preset.hours ?? 1)
            XCTAssertNil(preferences.customFrom); XCTAssertNil(preferences.customUntil)
            let window = DashboardWindow.resolve(preferences, now: now)
            XCTAssertEqual(window.preset, preset); XCTAssertEqual(window.until, now); XCTAssertEqual(window.span, preset.seconds)
        }
        DashboardWindow.apply(.custom, to: &preferences, now: now)
        XCTAssertEqual(preferences.customFrom, now.addingTimeInterval(-720 * 3600), "Custom seeds from the previously resolved window")
        XCTAssertEqual(preferences.customUntil, now)
        preferences.customFrom = Date(timeIntervalSince1970: 100); preferences.customUntil = Date(timeIntervalSince1970: 400)
        XCTAssertEqual(DashboardWindow.resolve(preferences, now: now), DashboardWindow(from: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 400), preset: .custom))
        preferences.customUntil = Date(timeIntervalSince1970: 50)
        let fallback = DashboardWindow.resolve(preferences, now: now)
        XCTAssertEqual(fallback.preset, .custom); XCTAssertEqual(fallback.until, now); XCTAssertEqual(fallback.span, 720 * 3600, "Inverted custom bounds fall back to the relative window instead of failing")
        preferences.windowPreset = "yesterday"
        XCTAssertEqual(DashboardWindow.resolve(preferences, now: now).preset, .month, "Unknown presets fall back to windowHours")
        let short = DashboardWindow.normalizeCustom(from: now, until: now, anchorFrom: true)
        XCTAssertEqual(short.until.timeIntervalSince(short.from), DashboardWindowPreset.minimumSpan)
        let long = DashboardWindow.normalizeCustom(from: now.addingTimeInterval(-DashboardWindowPreset.maximumSpan * 2), until: now, anchorFrom: false)
        XCTAssertEqual(long.until, now); XCTAssertEqual(long.until.timeIntervalSince(long.from), DashboardWindowPreset.maximumSpan)
    }

    func testPreferencesRemainDecodableAndVaultValidationBoundsCustomWindows() throws {
        let legacy = try JSONDecoder().decode(DashboardPreferences.self, from: Data("{\"windowHours\":6,\"status\":\"completed\",\"metricRetentionDays\":90}".utf8))
        XCTAssertNil(legacy.windowPreset); XCTAssertEqual(DashboardWindow.resolve(legacy).preset, .sixHours)
        var configuration = VaultConfiguration()
        configuration.dashboard.windowPreset = "custom"
        configuration.dashboard.customFrom = Date(timeIntervalSince1970: 100); configuration.dashboard.customUntil = Date(timeIntervalSince1970: 200)
        XCTAssertNoThrow(try configuration.validate())
        let encoded = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(VaultConfiguration.self, from: encoded).dashboard, configuration.dashboard)
        configuration.dashboard.customUntil = nil
        XCTAssertThrowsError(try configuration.validate(), "Custom requires both bounds")
        configuration.dashboard.customUntil = Date(timeIntervalSince1970: 100)
        XCTAssertThrowsError(try configuration.validate(), "Custom requires a nonempty window")
        configuration.dashboard.customUntil = Date(timeIntervalSince1970: 100.5)
        XCTAssertThrowsError(try configuration.validate(), "Saved custom windows obey the same minimum duration as the date pickers")
        configuration.dashboard.customUntil = Date(timeIntervalSince1970: 100 + DashboardWindowPreset.maximumSpan + 1)
        XCTAssertThrowsError(try configuration.validate(), "Custom windows are bounded to ten years")
        configuration.dashboard.customFrom = nil; configuration.dashboard.customUntil = nil
        configuration.dashboard.windowPreset = "7d"
        XCTAssertNoThrow(try configuration.validate())
        configuration.dashboard.windowPreset = "fortnight"
        XCTAssertThrowsError(try configuration.validate(), "Unknown presets are rejected")
    }

    func testBrushClampsToTheAppliedWindowAndNarrowsOnlyTheQuery() async throws {
        let applied = filter()
        let brush = try XCTUnwrap(DashboardBrush(Date(timeIntervalSince1970: 2500), Date(timeIntervalSince1970: 1950), in: applied))
        XCTAssertEqual(brush.from, Date(timeIntervalSince1970: 1950)); XCTAssertEqual(brush.until, applied.until, "Dragged dates are ordered and clamped")
        XCTAssertNil(DashboardBrush(Date(timeIntervalSince1970: 1950), Date(timeIntervalSince1970: 1950.5), in: applied), "Sub-second selections are ignored")
        XCTAssertTrue(brush.fits(applied))
        var moved = applied; moved.from = Date(timeIntervalSince1970: 1960)
        XCTAssertFalse(brush.fits(moved), "A brush outside a changed window is dropped")
        var saved = applied; saved.requestedAlias = "router"
        let narrowed = brush.narrowed(saved)
        XCTAssertEqual(narrowed.from, brush.from); XCTAssertEqual(narrowed.requestedAlias, "router"); XCTAssertEqual(saved.from, applied.from, "The applied filter is not mutated")
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        try await save(archive, metadata(id: UUID().uuidString, wall: 1940))
        try await save(archive, metadata(id: UUID().uuidString, wall: 1960))
        let observed11 = try await archive.dashboard(narrowed).selectedRequests; XCTAssertEqual(observed11, 1)
        let observed12 = try await archive.dashboard(applied).selectedRequests; XCTAssertEqual(observed12, 2)
        var tiny = applied; tiny.until = tiny.from.addingTimeInterval(0.5)
        do { _ = try await archive.dashboard(tiny); XCTFail("Reject sub-second windows") } catch { }
    }

    func testCacheHitRatioExcludesUnreportedAndConflictingRows() async throws {
        var totals = GatewayTotals()
        XCTAssertNil(totals.cacheHitRatio)
        totals.cacheUnreported = 5; totals.cacheConflicts = 2
        XCTAssertNil(totals.cacheHitRatio, "Only hits and misses form the ratio")
        totals.cacheHits = 3; totals.cacheMisses = 1
        XCTAssertEqual(totals.cacheHitRatio, 0.75)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for (wall, status) in [(1920.0, "hit"), (1920.0, "miss"), (1920.0, "unreported"), (1980.0, "hit"), (1980.0, "conflict")] {
            var value = metadata(id: UUID().uuidString, wall: wall)
            value["gateway"] = .object(["version": .number(1), "cache": .object(["status": .string(status)])])
            try await save(archive, value)
        }
        let result = try await archive.dashboard(filter())
        XCTAssertEqual(result.gateway.cacheHitRatio, 2.0 / 3.0)
        XCTAssertEqual(result.buckets.map(\.gateway.cacheHitRatio), [0.5, 1.0])
    }
}

extension DashboardTests {
    func testModelSummariesSplitThroughputAndFirstTokenPerRoute() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        func usage(_ output: Double) -> WireValue { .object(["inputIncludingCache": .number(100), "cacheRead": .number(0), "output": .number(output)]) }
        // Each measured request decodes for longer than the 250 ms a span
        // needs to be a measurement, and its HTTP exchange ends after that.
        var a1 = metadata(id: UUID().uuidString, wall: 1950, model: "model-a", ttft: 10, stream: 400, http: 500); a1["usage"] = usage(60)
        var a2 = metadata(id: UUID().uuidString, wall: 1960, model: "model-a", ttft: 30, stream: 400, http: 500); a2["usage"] = usage(100)
        var b1 = metadata(id: UUID().uuidString, wall: 1970, alias: "fast", model: "model-b", ttft: 50, stream: 500, http: 600); b1["usage"] = usage(400)
        let c1 = metadata(id: UUID().uuidString, wall: 1980, alias: "fast", model: nil, ttft: 5, stream: 5)
        for record in [a1, a2, b1, c1] { try await save(archive, record) }
        let summaries = try await archive.modelSummaries(filter())
        XCTAssertEqual(summaries.map { $0.alias + "→" + ($0.model ?? "?") }, ["router→model-a", "fast→model-b", "fast→?"], "busiest route first; an unreported route stays its own row")
        let a = summaries[0]
        XCTAssertEqual(a.requests, 2); XCTAssertEqual(a.completed, 2); XCTAssertEqual(a.problems, 0)
        XCTAssertEqual(a.ttftP50, 10, "nearest-rank median of 10 and 30"); XCTAssertEqual(a.ttftSamples, 2)
        XCTAssertEqual(try XCTUnwrap(a.gateway.settledThroughput.tokensPerSecond), 160 / 0.8, accuracy: 1e-9, "160 output tokens over 400 ms plus 400 ms of decoding")
        XCTAssertEqual(a.gateway.tokens?.output, 160)
        let b = summaries[1]
        XCTAssertEqual(b.ttftP50, 50); XCTAssertEqual(try XCTUnwrap(b.gateway.settledThroughput.tokensPerSecond), 400 / 0.5, accuracy: 1e-9); XCTAssertEqual(b.httpP50, 600)
        XCTAssertEqual(summaries[2].status, "unreported"); XCTAssertNil(summaries[2].gateway.settledThroughput.tokensPerSecond, "no reported output usage, no rate")
        let window = try await archive.dashboard(filter())
        XCTAssertEqual(window.gateway.settledThroughput.samples, 3)
        XCTAssertEqual(try XCTUnwrap(window.gateway.settledThroughput.tokensPerSecond), 560 / 1.3, accuracy: 1e-9, "the window blends every measured route")
    }

    /// The report's "Output tok/s" headline divided by dispatch-to-completion
    /// time while each route's "Output tok/s" column (and the rest of the app)
    /// uses the settled decode rate: one request, two different figures.
    func testHeadlineOutputRateIsTheSettledDecodeRateEachRouteShows() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        // Dispatch at 0 ms, first content at 2 s, model completion at 5 s, 300 output tokens.
        var request = metadata(id: UUID().uuidString, ttft: 2_000, stream: 3_000, http: 5_100, dispatch: 0)
        request["usage"] = .object(["inputIncludingCache": .number(100), "output": .number(300)])
        try await save(archive, request)
        let window = try await archive.dashboard(filter())
        let routes = try await archive.modelSummaries(filter())
        let route = try XCTUnwrap(routes.first)
        let headline = try XCTUnwrap(ReportThroughputTile.rate(window).tokensPerSecond)
        XCTAssertEqual(headline, 100, accuracy: 1e-9, "300 tokens over the 3 s decode span")
        XCTAssertEqual(try XCTUnwrap(route.gateway.settledThroughput.tokensPerSecond), headline, accuracy: 1e-9, "The headline and the route's column agree")
        XCTAssertTrue(ReportThroughputTile.caption(window).contains("first token to completion"), ReportThroughputTile.caption(window))
    }

    /// Each snapshot read counted the selected requests with its own scan
    /// although the aggregate read beside it returns the same count, and did
    /// the same once more per bucket.
    func testReportSnapshotReadsEachAggregateOnce() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        for (index, wall) in [1910.0, 1950, 1960, 1990].enumerated() {
            try await save(archive, metadata(id: UUID().uuidString, wall: wall, outcome: index == 3 ? "failed" : "completed"))
        }
        let read = try await archive.dashboardStatements(filter())
        print("PERF a report snapshot read used \(read.statements) statements")
        XCTAssertEqual(read.snapshot.selectedRequests, 3)
        XCTAssertEqual(read.snapshot.buckets.map(\.requests), [2, 1])
        XCTAssertEqual(read.snapshot.buckets.map(\.gateway.requests), [2, 1])
        XCTAssertEqual(read.statements, 11, "The request count and each bucket's count come from the aggregate rows")
    }

    func testSessionSummariesGroupRequestsWithTokensMediansAndLinks() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        func usage(_ input: Double, _ cached: Double, _ output: Double) -> WireValue { .object(["inputIncludingCache": .number(input), "cacheRead": .number(cached), "output": .number(output)]) }
        var a1 = metadata(id: UUID().uuidString, wall: 1950, session: "alpha", ttft: 10, http: 100); a1["usage"] = usage(1000, 400, 50); a1["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.5)]), "cache": .object(["status": .string("hit")])])
        var a2 = metadata(id: UUID().uuidString, wall: 1960, session: "alpha", ttft: 30, http: 300); a2["usage"] = usage(2000, 0, 150); a2["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.25)]), "cache": .object(["status": .string("miss")])])
        var a3 = metadata(id: UUID().uuidString, wall: 1970, session: "alpha", outcome: "failed", ttft: 20, http: 200)
        a3["usage"] = usage(10, 0, 0)
        let b1 = metadata(id: UUID().uuidString, wall: 1940, session: "beta", ttft: 5, http: 50)
        for record in [a1, a2, a3, b1] { try await save(archive, record) }
        try await archive.accept(["type": .string("links"), "attemptId": .string(a1["attemptId"]!.string!), "messageIds": .array([.string("ctx-1")]), "outputMessageIds": .array([.string("out-1")])], workspace: "workspace")

        let page = try await archive.sessionSummaries(filter(status: "all"))
        XCTAssertEqual(page.total, 2); XCTAssertEqual(page.sessions.map(\.sessionID), ["alpha", "beta"], "most recently active first")
        let alpha = page.sessions[0]
        XCTAssertEqual(alpha.requests, 3); XCTAssertEqual(alpha.completed, 2); XCTAssertEqual(alpha.problems, 1)
        XCTAssertEqual(alpha.ttftP50, 20, "nearest-rank median of 10, 20, 30")
        XCTAssertEqual(alpha.httpP50, 200)
        XCTAssertEqual(alpha.gateway.costUSD, 0.75); XCTAssertEqual(alpha.gateway.cacheHits, 1); XCTAssertEqual(alpha.gateway.cacheMisses, 1)
        XCTAssertEqual(alpha.gateway.tokens?.input, 3010); XCTAssertEqual(alpha.gateway.tokens?.output, 200); XCTAssertEqual(alpha.gateway.cacheReadTokens, 400)
        XCTAssertEqual(alpha.gateway.uncachedInputTokens, 2610)
        XCTAssertEqual(alpha.first, Date(timeIntervalSince1970: 1950)); XCTAssertEqual(alpha.last, Date(timeIntervalSince1970: 1970))
        let beta = page.sessions[1]
        XCTAssertNil(beta.gateway.tokens, "no usage reported"); XCTAssertEqual(beta.ttftP50, 5)

        let completedOnly = try await archive.sessionSummaries(filter())
        XCTAssertEqual(completedOnly.sessions.first?.requests, 2, "the status filter applies per session")
        let paged = try await archive.sessionSummaries(filter(status: "all"), offset: 1)
        XCTAssertEqual(paged.sessions.map(\.sessionID), ["beta"]); XCTAssertFalse(paged.hasNext)

        let rows = try await archive.dashboard(filter(status: "all")).requests
        let first = try XCTUnwrap(rows.first { $0.sessionID == "alpha" && $0.gateway.inputTokens == 1000 })
        XCTAssertEqual(first.gateway.outputTokens, 50); XCTAssertEqual(first.gateway.uncachedInputTokens, 600)
        let links = try await archive.linkedMessages(attemptID: first.id)
        XCTAssertEqual(links.output, ["out-1"]); XCTAssertTrue(links.context.contains("ctx-1"))
        let unlinked = try await archive.linkedMessages(attemptID: rows.first { $0.sessionID == "beta" }!.id)
        XCTAssertTrue(unlinked.output.isEmpty, "no produced message was linked"); XCTAssertEqual(unlinked.context, ["input"], "context links recorded at begin")
    }
}
