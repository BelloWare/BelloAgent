import XCTest
@testable import PiAgentCore
#if canImport(Darwin)
import Darwin
#endif

/// A model client the test drives one delta at a time.
private actor CostClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var reply: ModelReply?
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func finish(_ value: ModelReply) { reply = value }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while reply == nil { try await Task.sleep(nanoseconds: 500_000) }
        return reply!
    }
}

/// The reader's side of the row-update contract: the page it holds, and how
/// it applies what the helper sends instead of a whole page.
struct Page {
    private(set) var rows: [JSON]
    init(_ rows: [JSON]) { self.rows = rows }
    /// False when the update cannot be applied and the reader must resync.
    mutating func apply(_ patch: JSON) -> Bool {
        guard !patch.isNull else { return false }
        var byID: [String: JSON] = [:]
        for row in rows { guard let id = row["id"].text else { return false }; byID[id] = row }
        for row in patch["rows"].list { guard let id = row["id"].text else { return false }; byID[id] = row }
        for update in patch["appends"].list {
            guard let id = update["id"].text, var row = byID[id] else { return false }
            row["text"] = JSON((row["text"].text ?? "") + (update["text"].text ?? ""))
            row["thinking"] = JSON((row["thinking"].text ?? "") + (update["thinking"].text ?? ""))
            byID[id] = row
        }
        let order = patch["order"].isNull ? rows.compactMap { $0["id"].text } : patch["order"].list.compactMap(\.text)
        var next: [JSON] = []
        for id in order { guard let row = byID[id] else { return false }; next.append(row) }
        rows = next
        return true
    }
}

/// Bytes and blocks the default malloc zone currently holds. A streaming path
/// that churns the heap shows up as CPU; one that leaks shows up here.
func heapInUse() -> (bytes: Int, blocks: Int) {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return (Int(stats.size_in_use), Int(stats.blocks_in_use))
}

/// Process CPU time in milliseconds, user plus system.
func processCPUMilliseconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
    let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
    return user + system
}

/// What a streamed token costs the helper: the CPU it burns and the bytes it
/// puts on the wire. Both must scale with the delta, not with the page.
final class StreamingCostTests: XCTestCase {
    private func history(count: Int, bytes: Int) -> [ChatMessage] {
        (0..<count).map { index in
            var message = ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", content: [textBlock("Row \(index): " + String(repeating: "x", count: bytes))])
            message.id = "message-\(index)"
            return message
        }
    }
    private func session(root: URL, id: String, seed: [ChatMessage], client: any ModelClient) throws -> AgentSession {
        var profile = try fixtureProfile().raw; profile["contextWindow"] = 1_000_000
        return try AgentSession(id: id, profile: Profile(profile), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), seed: seed, autoCompaction: false)
    }

    /// Streams a long reply into a full 60-row page, polling a snapshot after
    /// every delta the way the app does, and reports what each one cost.
    func testStreamedDeltaCostsLessThanAMillisecondAndSendsOnlyItsRow() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = CostClient()
        let session = try session(root: root, id: "cost", seed: history(count: 60, bytes: 4096), client: client)
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "start", turnID: "start", text: "Question"), steer: false)
        try await eventually { await client.ready }
        let first = await session.snapshot()
        let pageBytes = (try? first.data().count) ?? 0
        var revision = first["displayRevision"]
        var contextRevision=first["contextStateRevision"], observationRevision=first["contextObservationRevision"]
        let rounds = 200
        var frameBytes = 0, maximumFrame = 0
        var page = Page(first["messages"].list)
        let cpuStart = processCPUMilliseconds(), start = ProcessInfo.processInfo.systemUptime
        for index in 0..<rounds {
            try await client.emit(.text("token-\(index) "))
            let next = await session.snapshot(["displayRevision":revision,"messageDelta":true,"includeMetrics":false,
                "contextStateRevision":contextRevision,"contextObservationRevision":observationRevision])
            if !next["contextStateRevision"].isNull { contextRevision=next["contextStateRevision"] }
            if !next["contextObservationRevision"].isNull { observationRevision=next["contextObservationRevision"] }
            let bytes = (try? next.data().count) ?? 0
            frameBytes += bytes; maximumFrame = max(maximumFrame, bytes)
            revision = next["displayRevision"]
            XCTAssertTrue(next["messages"].isNull, "A streamed token must not resend the page")
            XCTAssertTrue(page.apply(next["messageDelta"]))
        }
        let wall = (ProcessInfo.processInfo.systemUptime - start) * 1000, cpu = processCPUMilliseconds() - cpuStart
        print("PERF streamed-delta page=\(pageBytes)B rounds=\(rounds) cpuPerDeltaMs=\(cpu / Double(rounds)) wallPerDeltaMs=\(wall / Double(rounds)) bytesPerDelta=\(frameBytes / rounds) maxFrame=\(maximumFrame)")
        XCTAssertLessThan(cpu / Double(rounds), 1.0, "A streamed token must cost the helper under a millisecond of CPU")
        XCTAssertLessThan(maximumFrame / max(1, pageBytes / 40), 1, "A streamed token's frame must stay far under the page it updates")
        await client.finish(answer("Finished")); try await eventually { !(await session.isRunning) }
        let settled = await session.snapshot(["displayRevision": revision, "messageDelta": true])
        XCTAssertTrue(page.apply(settled["messageDelta"]))
        let whole = await session.snapshot()
        XCTAssertEqual(JSON.array(page.rows), .array(whole["messages"].list), "Applied updates must rebuild exactly the page a full read returns")
    }

    /// The accumulator on its own: no snapshot, no projection, just the cost of
    /// taking a token into the partial row.
    func testDeltaAccumulationIsConstantTimeInTheReplySoFar() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = CostClient()
        let session = try session(root: root, id: "accumulate", seed: [], client: client)
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "start", turnID: "start", text: "Question"), steer: false)
        try await eventually { await client.ready }
        let rounds = 4000
        // Warm until the retained event window is full, so what the measured
        // window shows is steady-state cost, not a ring still filling.
        for index in 0..<(AgentSession.retainedEvents + AgentSession.retainedEventSlack + 1000) { try await client.emit(.text("warm-\(index) ")) }
        let heapStart = heapInUse()
        let cpuStart = processCPUMilliseconds(), start = ProcessInfo.processInfo.systemUptime
        for index in 0..<rounds { try await client.emit(.text("token-\(index) ")) }
        let wall = (ProcessInfo.processInfo.systemUptime - start) * 1000, cpu = processCPUMilliseconds() - cpuStart
        let heapEnd = heapInUse()
        let grown = heapEnd.bytes - heapStart.bytes, blocks = heapEnd.blocks - heapStart.blocks
        print("PERF delta-accumulate rounds=\(rounds) cpuPerDeltaUs=\(cpu * 1000 / Double(rounds)) wallPerDeltaUs=\(wall * 1000 / Double(rounds)) heapGrowthBytes=\(grown) heapGrowthBlocks=\(blocks)")
        XCTAssertLessThan(cpu * 1000 / Double(rounds), 10, "Taking a token into the partial row must not scale with the reply so far")
        XCTAssertLessThan(grown, 64 * 1024, "A streamed token must not leave anything behind on the heap")
        await client.finish(answer("Finished")); try await eventually { !(await session.isRunning) }
    }
}
