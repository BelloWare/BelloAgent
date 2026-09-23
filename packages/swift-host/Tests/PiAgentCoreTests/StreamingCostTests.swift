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
        // Timeline parts, as the app applies them: whole segments that are
        // new or changed, text appended to the ones it holds, and the order
        // when it moved.
        for part in patch["parts"].list {
            guard part["version"].int == 1, let id = part["id"].text, var row = byID[id] else { return false }
            let empty: JSON = ["version": 1, "segments": [], "coverage": "observed", "omittedEvents": 0]
            var timeline = row["responseTimeline"].isNull ? empty : row["responseTimeline"]
            var segments: [String: JSON] = [:]
            for segment in timeline["segments"].list { guard let key = segment["id"].text else { return false }; segments[key] = segment }
            for segment in part["segments"].list { guard let key = segment["id"].text else { return false }; segments[key] = segment }
            for append in part["appends"].list {
                guard let key = append["id"].text, var segment = segments[key], segment["revision"] == append["baseRevision"] else { return false }
                segment["text"] = JSON((segment["text"].text ?? "") + (append["text"].text ?? "")); segment["state"] = append["state"]; segment["revision"] = append["revision"]
                segments[key] = segment
            }
            let order = part["order"].isNull ? timeline["segments"].list.compactMap { $0["id"].text } : part["order"].list.compactMap(\.text)
            var ordered: [JSON] = []
            for key in order { guard let segment = segments[key] else { return false }; ordered.append(segment) }
            timeline["segments"] = .array(ordered); timeline["coverage"] = part["coverage"]; timeline["omittedEvents"] = part["omittedEvents"]
            timeline = part["terminal"].isNull ? timeline.removing(["terminal"]) : { var value = timeline; value["terminal"] = part["terminal"]; return value }()
            row["responseTimeline"] = timeline; byID[id] = row
        }
        // Streamed tool arguments, for a reader that asked for them as appends.
        for input in patch["toolInputs"].list {
            guard let id = input["id"].text, let call = input["callID"].text, var row = byID[id] else { return false }
            var tools = row["tools"].list
            guard let index = tools.firstIndex(where: { $0["id"].text == call }) else { return false }
            tools[index]["input"] = JSON((tools[index]["input"].text ?? "") + (input["text"].text ?? "")); tools[index]["inputBytes"] = input["inputBytes"]
            row["tools"] = .array(tools); byID[id] = row
        }
        let order = patch["order"].isNull ? rows.compactMap { $0["id"].text } : patch["order"].list.compactMap(\.text)
        var next: [JSON] = []
        for id in order { guard let row = byID[id] else { return false }; next.append(row) }
        rows = next
        return true
    }
}

/// Answers a number of requests at once, then streams the next one under the
/// test's control: a chat with finished turns behind the reply that arrives.
private actor ReceiptsClient: ModelClient {
    let answered: Int
    private var requests = 0, callback: (@Sendable (StreamDelta) async throws -> Void)?, finished = false
    var streaming: Bool { callback != nil }
    init(answered: Int) { self.answered = answered }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func finish() { finished = true }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1
        if requests <= answered { return answer("Answer \(requests)") }
        callback = onDelta
        while !finished { try await Task.sleep(nanoseconds: 500_000) }
        return answer("Streamed")
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
        // An absolute CPU figure measures the machine as much as the code in a
        // debug build on a loaded machine; it holds only in an optimized build.
        // The byte assertions below hold everywhere.
        #if !DEBUG
        XCTAssertLessThan(cpu / Double(rounds), 1.0, "A streamed token must cost the helper under a millisecond of CPU")
        #endif
        XCTAssertLessThan(maximumFrame, 4096, "A token delta keeps a fixed small envelope even when the three-turn page is small")
        XCTAssertLessThan(Double(maximumFrame), Double(pageBytes) * 0.15, "A token must not resend its page")
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
        // The same window again after the reply has grown five times over:
        // what constant time means, measured against itself rather than a
        // clock, so it holds on a loaded machine and in a debug build.
        for index in 0..<(rounds * 4) { try await client.emit(.text("grow-\(index) ")) }
        let lateStart = processCPUMilliseconds()
        for index in 0..<rounds { try await client.emit(.text("late-\(index) ")) }
        let late = processCPUMilliseconds() - lateStart
        let early = cpu * 1000 / Double(rounds), later = late * 1000 / Double(rounds)
        print("PERF delta-accumulate rounds=\(rounds) cpuPerDeltaUs=\(early) laterCpuPerDeltaUs=\(later) wallPerDeltaUs=\(wall * 1000 / Double(rounds)) heapGrowthBytes=\(grown) heapGrowthBlocks=\(blocks)")
        XCTAssertLessThan(later, early * 3 + 5, "Taking a token into the partial row must not scale with the reply so far")
        #if !DEBUG
        XCTAssertLessThan(early, 10, "Taking a token into the partial row costs a few microseconds")
        #endif
        XCTAssertLessThan(grown, 64 * 1024, "A streamed token must not leave anything behind on the heap")
        await client.finish(answer("Finished")); try await eventually { !(await session.isRunning) }
    }

    // MARK: Parts, tool arguments and task receipts

    /// The row every snapshot below is read against, with the per-read revisions
    /// a reader that takes updates sends back.
    private struct Reader {
        var page: Page, revision: JSON, context: JSON = .null, observation: JSON = .null, tasks: JSON = .null, commands: JSON = .null
        var monitoringEpoch: JSON = .null, monitoringCursor: JSON = .null
        var sendsReceiptRevisions = false, takesToolInputAppends = false
        var params: JSON {
            // What the app sends with every poll (WorkspaceRefresh), plus the opt-ins under test.
            var value: JSON = ["displayRevision": revision, "messageDelta": true, "includeMetrics": false, "contextStateRevision": context, "contextObservationRevision": observation,
                               "monitoringEpoch": monitoringEpoch, "monitoringCursor": monitoringCursor]
            if sendsReceiptRevisions { value["taskPresentationRevision"] = tasks; value["commandsRevision"] = commands }
            if takesToolInputAppends { value["toolInputAppends"] = true }
            return value
        }
        /// Takes one reply; false when it could not be applied.
        mutating func take(_ reply: JSON) -> Bool {
            if !reply["contextStateRevision"].isNull { context = reply["contextStateRevision"] }
            if !reply["contextObservationRevision"].isNull { observation = reply["contextObservationRevision"] }
            if !reply["taskPresentationRevision"].isNull { tasks = reply["taskPresentationRevision"] }
            if !reply["commandsRevision"].isNull { commands = reply["commandsRevision"] }
            monitoringEpoch = reply["monitoring"]["epoch"]; monitoringCursor = reply["monitoring"]["cursor"]
            revision = reply["displayRevision"]
            if !reply["messages"].isNull { page = Page(reply["messages"].list); return true }
            return page.apply(reply["messageDelta"])
        }
    }

    private func opened(_ session: AgentSession, client: CostClient) async throws -> Reader {
        _ = try await session.submit(Submission(commandID: "start", turnID: "start", text: "Question"), steer: false)
        try await eventually { await client.ready }
        let first = await session.snapshot(["messageDelta": true])
        var reader = Reader(page: Page(first["messages"].list), revision: first["displayRevision"])
        _ = reader.take(first)
        return reader
    }

    /// A 200 KB reply streamed as the provider delivers it, display part events
    /// from ProviderDisplayEvents beside the text deltas, with a snapshot after
    /// each: a token late in the reply costs what an early one did.
    func testStreamedPartsCostTheSameLateInALongReply() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = CostClient()
        let session = try session(root: root, id: "parts", seed: history(count: 20, bytes: 512), client: client)
        addTeardownBlock { await session.close() }
        var reader = try await opened(session, client: client)
        var adapter = ProviderDisplayEvents(api: "openai-responses", attempt: "attempt-parts")
        for part in adapter.consume(["type": "response.output_item.added", "output_index": 1, "item": ["type": "reasoning", "id": "r"]], at: nowMS()) { try await client.emit(.part(part)) }
        let reasoning: JSON = ["type": "response.reasoning_summary_text.delta", "output_index": 1, "item_id": "r", "summary_index": 0, "delta": "Weighing the options. "]
        for part in adapter.consume(reasoning, at: nowMS()) { try await client.emit(.part(part)) }
        try await client.emit(.thinking("Weighing the options. "))
        // Quotes, backslashes, newlines and wide characters: escaping must be counted, not guessed.
        let chunk = String(repeating: "A \"quoted\" \\path\\ line\n with 中文 and 🦉; ", count: 8)
        let rounds = 500
        var costs: [Double] = [], maximumFrame = 0, replyBytes = 0
        for index in 0..<rounds {
            let frame: JSON = ["type": "response.output_text.delta", "output_index": 0, "item_id": "m", "content_index": 0, "delta": JSON(chunk)]
            let before = processCPUMilliseconds()
            for part in adapter.consume(frame, at: nowMS()) { try await client.emit(.part(part)) }
            try await client.emit(.text(chunk))
            let next = await session.snapshot(reader.params)
            costs.append(processCPUMilliseconds() - before)
            replyBytes += chunk.utf8.count
            let bytes = (try? next.data().count) ?? 0; maximumFrame = max(maximumFrame, bytes)
            XCTAssertTrue(next["messages"].isNull, "delta \(index): a streamed token must not resend the page")
            XCTAssertTrue(reader.take(next), "delta \(index): the update applies to the page the reader holds")
        }
        let early = costs.prefix(100).reduce(0, +) / 100, late = costs.suffix(100).reduce(0, +) / 100
        print("PERF streamed-parts replyBytes=\(replyBytes) earlyCpuPerDeltaMs=\(early) lateCpuPerDeltaMs=\(late) maxFrame=\(maximumFrame)")
        XCTAssertLessThan(late, early * 3 + 0.1, "a token 200 KB into the reply costs what one 40 KB in did")
        XCTAssertLessThan(maximumFrame, 4096)
        let projected = await session.projectedDisplay()
        let exact = try XCTUnwrap(projected.messages.last).data().count
        XCTAssertEqual(projected.streamingBytes, exact, "the running size is the encoded size")
        let whole = await session.snapshot()
        XCTAssertEqual(JSON.array(reader.page.rows), .array(whole["messages"].list), "the applied updates rebuild exactly the page a full read returns")
        await client.finish(answer("Finished")); try await eventually { !(await session.isRunning) }
    }

    /// A tool call whose arguments stream in 1,000 pieces. A reader that takes
    /// input appends receives each piece as an append, never the row again;
    /// a reader that does not still receives a correct row.
    func testStreamedToolArgumentsTravelAsAppends() async throws {
        for appends in [true, false] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let client = CostClient()
            let session = try session(root: root, id: "tool-\(appends)", seed: history(count: 20, bytes: 512), client: client)
            var reader = try await opened(session, client: client)
            reader.takesToolInputAppends = appends
            var adapter = ProviderDisplayEvents(api: "openai-responses", attempt: "attempt-tool")
            for part in adapter.consume(["type": "response.output_item.added", "output_index": 0, "item": ["type": "function_call", "id": "fc", "call_id": "call-write", "name": "write", "arguments": ""]], at: nowMS()) { try await client.emit(.part(part)) }
            try await client.emit(.tool("call-write", "write", ""))
            let opening = await session.snapshot(reader.params)
            XCTAssertTrue(reader.take(opening))
            let rounds = 1000, piece = "\\\"line of the file being written 中文\\n"
            var costs: [Double] = [], rows = 0, maximumFrame = 0
            for index in 0..<rounds {
                let frame: JSON = ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "fc", "delta": JSON(index == 0 ? "{\"path\":\"a.txt\",\"content\":\"" + piece : piece)]
                let before = processCPUMilliseconds()
                for part in adapter.consume(frame, at: nowMS()) { try await client.emit(.part(part)) }
                try await client.emit(.tool("call-write", "write", frame["delta"].text ?? ""))
                let next = await session.snapshot(reader.params)
                costs.append(processCPUMilliseconds() - before)
                rows += next["messageDelta"]["rows"].list.count
                maximumFrame = max(maximumFrame, (try? next.data().count) ?? 0)
                XCTAssertTrue(reader.take(next), "delta \(index)")
            }
            let early = costs.prefix(100).reduce(0, +) / 100, late = costs.suffix(100).reduce(0, +) / 100
            print("PERF tool-argument-deltas appends=\(appends) rounds=\(rounds) rowsResent=\(rows) maxFrame=\(maximumFrame) earlyCpuPerDeltaMs=\(early) lateCpuPerDeltaMs=\(late)")
            if appends {
                XCTAssertEqual(rows, 0, "argument growth never resends the row")
                XCTAssertLessThan(maximumFrame, 4096)
                XCTAssertLessThan(late, early * 3 + 0.1)
            } else { XCTAssertEqual(rows, rounds, "a reader that cannot take appends keeps receiving the row") }
            let whole = await session.snapshot()
            XCTAssertEqual(JSON.array(reader.page.rows), .array(whole["messages"].list))
            let card = try XCTUnwrap(whole["messages"].list.last?["tools"].list.first)
            XCTAssertEqual(card["inputBytes"].int, card["input"].text?.utf8.count)
            let projected = await session.projectedDisplay()
            let exact = try XCTUnwrap(projected.messages.last).data().count
            XCTAssertEqual(projected.streamingBytes, exact, "the running size is the encoded size")
            await client.finish(answer("Finished")); try await eventually { !(await session.isRunning) }
            await session.close()
        }
    }

    /// Seventy finished turns fill the task receipts; streaming the next one,
    /// a reader that sends back the receipt revisions is sent the receipts
    /// only when they change, while a reader that does not still gets them all.
    func testFinishedTurnsDoNotRideOnEveryStreamedToken() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ReceiptsClient(answered: 70)
        let session = try session(root: root, id: "receipts", seed: [], client: client)
        addTeardownBlock { await session.close() }
        for index in 0..<70 {
            _ = try await session.submit(Submission(commandID: "c\(index)", turnID: "t\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        _ = try await session.submit(Submission(commandID: "live", turnID: "live", text: "Stream this"), steer: false)
        try await eventually { await client.streaming }
        for sends in [true, false] {
            let first = await session.snapshot(["messageDelta": true])
            XCTAssertEqual(first["taskPresentation"]["recent"].list.count, 64); XCTAssertEqual(first["commands"].list.count, 71)
            var reader = Reader(page: Page(first["messages"].list), revision: first["displayRevision"])
            reader.sendsReceiptRevisions = sends; _ = reader.take(first)
            var maximumFrame = 0, withReceipts = 0
            for index in 0..<50 {
                try await client.emit(.text("token-\(index) "))
                let next = await session.snapshot(reader.params)
                maximumFrame = max(maximumFrame, (try? next.data().count) ?? 0)
                if !next["taskPresentation"].isNull || !next["commands"].isNull { withReceipts += 1 }
                XCTAssertTrue(reader.take(next))
            }
            print("PERF streamed-token-with-70-turns sendsRevisions=\(sends) maxFrame=\(maximumFrame) framesWithReceipts=\(withReceipts)")
            if sends {
                XCTAssertLessThan(maximumFrame, 4096, "a token is not followed by 64 task records and 71 receipts")
                XCTAssertEqual(withReceipts, 0)
            } else { XCTAssertEqual(withReceipts, 50, "a reader that does not send revisions gets the receipts every time, as before") }
        }
        // A change is sent: the live task finishing moves both revisions.
        let before = await session.snapshot(["messageDelta": true])
        await client.finish()
        try await eventually { !(await session.isRunning) }
        let after = await session.snapshot(["taskPresentationRevision": before["taskPresentationRevision"], "commandsRevision": before["commandsRevision"]])
        XCTAssertEqual(after["taskPresentation"]["recent"].list.last?["rootID"].text, "live")
        XCTAssertEqual(after["commands"].list.last?["status"].text, "completed")
        XCTAssertNotEqual(after["taskPresentationRevision"], before["taskPresentationRevision"])
        XCTAssertNotEqual(after["commandsRevision"], before["commandsRevision"])
    }
}
