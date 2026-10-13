import XCTest
@testable import PiAgentCore

/// Fails turn and summary requests a scripted number of times, and notes when
/// each request arrived, so the waits between them can be measured.
private actor TimedClient: ModelClient {
    var turnFailures: Int, summaryFailures: Int
    var times: [String: [Double]] = [:]
    init(turnFailures: Int = 0, summaryFailures: Int = 0) { self.turnFailures = turnFailures; self.summaryFailures = summaryFailures }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        times[purpose, default: []].append(nowMS())
        let transient = AgentError("provider_failed", "Model overloaded (overloaded_error)")
        if purpose == "compaction" {
            if summaryFailures > 0 { summaryFailures -= 1; throw transient }
            return answer("Completed evidence; no approval granted. Retain original objective.")
        }
        if turnFailures > 0 { turnFailures -= 1; throw transient }
        try await onDelta(.text("done")); return answer("done")
    }
    func gaps(_ purpose: String) -> [Double] { let t = times[purpose] ?? []; return zip(t.dropFirst(), t).map { $0 - $1 } }
    func count(_ purpose: String) -> Int { times[purpose]?.count ?? 0 }
}

/// The retry setting the app sends every helper (Settings ▸ Connections ▸
/// Retries): pi's settings.retry, with exponential back-off for every
/// automatic retry of a provider request.
final class RetrySettingsTests: XCTestCase {
    private func session(_ root: URL, _ client: TimedClient, seed: [ChatMessage]? = nil, window: Int = 100_000) throws -> AgentSession {
        var raw = try fixtureProfile().raw; raw["contextWindow"] = JSON(window); raw["maxOutputTokens"] = 256
        return try AgentSession(id: UUID().uuidString, profile: Profile(raw), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), seed: seed, autoCompaction: false)
    }
    private func evidence(count: Int = 4, bytes: Int = 2000) -> [ChatMessage] {
        var user = ChatMessage(role: "user", content: [textBlock("ORIGINAL OBJECTIVE")]); user.id = "root"; user.taskRootID = "root"
        return [user] + (0..<count).map { index in
            var message = ChatMessage(role: "assistant", content: [textBlock("Evidence \(index): " + String(repeating: "x", count: bytes))]); message.id = "evidence-\(index)"; message.taskRootID = "root"; return message
        }
    }
    /// Each wait is at least base × 2^(n−1), and the doubling shows: a fixed
    /// delay would leave the later waits at the base.
    private func assertDoubling(_ gaps: [Double], base: Double, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(gaps.count, count, "one wait before each retry", file: file, line: line)
        for (index, gap) in gaps.enumerated() {
            let expected = base * pow(2, Double(index))
            XCTAssertGreaterThanOrEqual(gap, expected - 5, "retry \(index + 1) waits base × 2^\(index)", file: file, line: line)
            XCTAssertLessThan(gap, expected * 2, "retry \(index + 1) does not wait as long as the next one", file: file, line: line)
        }
    }

    func testDelaysAreTheBaseDoubledForEachRetry() {
        let settings = PiProviderRules.RetrySettings(enabled: true, maxRetries: 5, baseDelayMs: 3_000)
        XCTAssertEqual((1...5).map(settings.delayMs), [3_000, 6_000, 12_000, 24_000, 48_000])
        XCTAssertEqual(PiProviderRules.RetrySettings(), .init(enabled: true, maxRetries: 3, baseDelayMs: 2_000), "pi's defaults")
    }

    func testTheWireFormIsCheckedAndRoundTrips() throws {
        let settings = try PiProviderRules.RetrySettings(wire: ["enabled": false, "maxRetries": 7, "baseDelayMs": 5_000])
        XCTAssertEqual(settings, .init(enabled: false, maxRetries: 7, baseDelayMs: 5_000))
        XCTAssertEqual(try PiProviderRules.RetrySettings(wire: settings.wire), settings)
        for bad: JSON in [["enabled": true, "maxRetries": 11, "baseDelayMs": 2_000], ["enabled": true, "maxRetries": -1, "baseDelayMs": 2_000],
                          ["enabled": true, "maxRetries": 3, "baseDelayMs": 0], ["enabled": true, "maxRetries": 3, "baseDelayMs": 60_001],
                          ["enabled": "yes", "maxRetries": 3, "baseDelayMs": 2_000], ["maxRetries": 3, "baseDelayMs": 2_000], "retry"] {
            XCTAssertThrowsError(try PiProviderRules.RetrySettings(wire: bad), bad.encoded())
        }
    }

    func testTurnRetriesWaitTheBaseDoubledEachTime() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = TimedClient(turnFailures: 3), s = try session(root, client)
        await s.useRetrySettings(.init(enabled: true, maxRetries: 3, baseDelayMs: 150))
        _ = try await s.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
        try await eventually(timeout: .seconds(10)) { !(await s.isRunning) }
        let state = await s.snapshot(), gaps = await client.gaps("turn")
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        assertDoubling(gaps, base: 150, count: 3)
        await s.close()
    }

    func testSummaryRetriesWaitTheBaseDoubledEachTimeAndTakeTheWholeSetting() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let timed = TimedClient(summaryFailures: 3), s = try session(root, timed, seed: evidence(), window: 6_000)
        await s.useRetrySettings(.init(enabled: true, maxRetries: 3, baseDelayMs: 150))
        try await s.compact(); try await eventually(timeout: .seconds(10)) { !(await s.isRunning) }
        let state = await s.snapshot(), gaps = await timed.gaps("compaction")
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        assertDoubling(gaps, base: 150, count: 3)
        await s.close()

        // The most retries Settings allows reach a summary too.
        let many = TimedClient(summaryFailures: 10), t = try session(root.appendingPathComponent("many"), many, seed: evidence(), window: 6_000)
        await t.useRetrySettings(.init(enabled: true, maxRetries: 10, baseDelayMs: 1))
        try await t.compact(); try await eventually(timeout: .seconds(10)) { !(await t.isRunning) }
        let final = await t.snapshot(), requests = await many.count("compaction")
        XCTAssertEqual(final["state"].text, "idle", final["preflightError"].encoded())
        XCTAssertEqual(requests, 11, "the first summary request and ten retries")
        await t.close()
    }

    /// A setting changed while a request is being retried applies from the
    /// next request: the one under way keeps its count and its back-off.
    func testAChangeDuringARequestAppliesFromTheNextOne() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = TimedClient(turnFailures: 3), s = try session(root, client)
        await s.useRetrySettings(.init(enabled: true, maxRetries: 3, baseDelayMs: 150))
        _ = try await s.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
        try await eventually { await s.snapshot()["runStatus"].text == "retrying" }
        await s.useRetrySettings(.init(enabled: true, maxRetries: 0, baseDelayMs: 60_000))
        try await eventually(timeout: .seconds(10)) { !(await s.isRunning) }
        let state = await s.snapshot(), gaps = await client.gaps("turn")
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        assertDoubling(gaps, base: 150, count: 3)
        await s.close()

        let timed = TimedClient(summaryFailures: 3), t = try session(root.appendingPathComponent("summary"), timed, seed: evidence(), window: 6_000)
        await t.useRetrySettings(.init(enabled: true, maxRetries: 3, baseDelayMs: 150))
        try await t.compact()
        try await eventually { await timed.count("compaction") == 1 }
        await t.useRetrySettings(.init(enabled: true, maxRetries: 0, baseDelayMs: 60_000))
        try await eventually(timeout: .seconds(10)) { !(await t.isRunning) }
        let summary = await t.snapshot(), summaryGaps = await timed.gaps("compaction")
        XCTAssertEqual(summary["state"].text, "idle", summary["preflightError"].encoded())
        assertDoubling(summaryGaps, base: 150, count: 3)
        await t.close()
    }

    func testOffOrNoRetriesSendOneRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for settings in [PiProviderRules.RetrySettings(enabled: false, maxRetries: 3, baseDelayMs: 1), .init(enabled: true, maxRetries: 0, baseDelayMs: 1)] {
            let client = TimedClient(turnFailures: 1), s = try session(root.appendingPathComponent(UUID().uuidString), client)
            await s.useRetrySettings(settings)
            _ = try await s.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
            try await eventually { !(await s.isRunning) }
            let state = await s.snapshot(), requests = await client.count("turn")
            XCTAssertEqual(requests, 1); XCTAssertEqual(state["state"].text, "error")
            await s.close()
        }
    }

    /// The app's setting reaches the helper at startup and whenever it
    /// changes, and every chat of every connection uses it: open chats,
    /// chats opened later, forks and sides.
    func testTheHostAppliesTheSettingToEveryChatNowAndLater() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]],
                                                                           "retry": ["enabled": true, "maxRetries": 5, "baseDelayMs": 4_000]])
        var other = try fixtureProfile().raw; other["id"] = "second-connection"
        _ = try await host.command("session.open", sessionID: "a", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic"])
        _ = try await host.command("session.open", sessionID: "b", params: ["profile": other, "apiKey": "synthetic"])
        func settings(_ id: String) async throws -> PiProviderRules.RetrySettings {
            let loaded = await host.loadedSession(id), session = try XCTUnwrap(loaded)
            return await session.retrySettings
        }
        let started = PiProviderRules.RetrySettings(enabled: true, maxRetries: 5, baseDelayMs: 4_000)
        for id in ["a", "b"] { let s = try await settings(id); XCTAssertEqual(s, started, "from workspace.open") }

        let changed = try await host.command("retry.configure", sessionID: nil, params: ["enabled": false, "maxRetries": 2, "baseDelayMs": 1_000])
        XCTAssertEqual(changed["applied"].flag, true)
        let info = try await host.command("runtime.info", sessionID: nil, params: [:])
        XCTAssertEqual(info["retry"], changed["retry"], "runtime.info reports the helper's setting")
        let now = PiProviderRules.RetrySettings(enabled: false, maxRetries: 2, baseDelayMs: 1_000)
        for id in ["a", "b"] { let s = try await settings(id); XCTAssertEqual(s, now, "an open chat takes the change") }
        _ = try await host.command("session.open", sessionID: "c", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic"])
        let later = try await settings("c"); XCTAssertEqual(later, now, "a chat opened later starts with it")
        _ = try await host.command("side.open", sessionID: "a", params: ["sideSessionId": "side-a"])
        let side = try await settings("side-a"); XCTAssertEqual(side, now, "a side uses it")

        do { _ = try await host.command("retry.configure", sessionID: nil, params: ["enabled": true, "maxRetries": 50, "baseDelayMs": 1_000]); XCTFail("out of range") }
        catch let error as AgentError { XCTAssertEqual(error.code, "invalid_params") }
        let kept = try await settings("a"); XCTAssertEqual(kept, now, "a refused setting changes nothing")
        await host.shutdown()
    }

    func testTheHostDefaultIsPiSettingsRetry() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "a", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic"])
        let loaded = await host.loadedSession("a"), session = try XCTUnwrap(loaded), settings = await session.retrySettings
        XCTAssertEqual(settings, PiProviderRules.RetrySettings())
        do { _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("other").path), "retry": ["enabled": true]]); XCTFail("bad retry") }
        catch let error as AgentError { XCTAssertEqual(error.code, "invalid_params", "a bad setting is refused before anything else") }
        await host.shutdown()
    }
}
