import XCTest
@testable import PiAgentCore

private final class PageReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [JSON]] = [:]
    private var emitted: [String: ContinuousClock.Instant] = [:]
    func emit(_ value: JSON) {
        guard value["kind"].text == "reply", let id = value["commandId"].text else { return }
        let now = ContinuousClock.now
        lock.withLock { values[id, default: []].append(value); emitted[id] = now }
    }
    func replies(_ id: String) -> [JSON] { lock.withLock { values[id] ?? [] } }
    func replyTime(_ id: String) -> ContinuousClock.Instant? { lock.withLock { emitted[id] } }
}

private final class PageStepGate: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var steps = 0
    var count: Int { lock.withLock { steps } }
    func step(_ stage: String) {
        let first = lock.withLock { steps += 1; return steps == 1 }
        if first { _ = release.wait(timeout: .now() + 10) }
    }
    func open() { release.signal() }
}

private final class PageDecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false, reads = 0
    var count: Int { condition.lock(); defer { condition.unlock() }; return reads }
    func step(_ stage: String) {
        guard stage == "stored" else { return }
        condition.lock(); defer { condition.unlock() }
        reads += 1
        let deadline = Date().addingTimeInterval(10)
        while !open { if !condition.wait(until: deadline) { break } }
    }
    func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
}

final class HistoryReadCancellationTests: XCTestCase {
    private struct Fixture {
        let root: URL, host: NativeHostService, session: AgentSession, replies: PageReplies, epoch: String
        func command(_ id: String, method: String = "session.history", params: JSON = ["version": 2, "position": 0], token: String? = nil) async {
            var frame: JSON = ["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": JSON(id), "method": JSON(method), "sessionId": "long", "params": params]
            if let token { frame["readToken"] = JSON(token) }
            await host.receive(frame)
        }
        func cancel(_ id: String, token: String, epoch: String? = nil) async {
            await host.receive(["v": 1, "kind": "read.cancel", "hostEpoch": JSON(epoch ?? self.epoch), "requestId": JSON(id), "readToken": JSON(token)])
        }
        func reply(_ id: String) async throws -> JSON {
            try await eventually { !replies.replies(id).isEmpty }
            return replies.replies(id)[0]
        }
    }
    private func fixture(rows: Int = 180, bodyBytes: Int = 2048) async throws -> Fixture {
        let root = try temporaryDirectory(), directory = root.appendingPathComponent("state"), profile = try fixtureProfile()
        let path = directory.appendingPathComponent("long.jsonl")
        do {
            let journal = try SessionJournal(url: path, id: "long", cwd: root, binding: profile.binding, create: true)
            let body = String(repeating: "Saved fixture content. ", count: bodyBytes / 23)
            for index in 0..<rows {
                try journal.append(["type": "message", "message": ["role": JSON(index.isMultiple(of: 20) ? "user" : "assistant"), "content": JSON("Row \(index) " + body)]], id: "r\(index)")
            }
            try journal.append(["type": "compaction", "summary": "Generated earlier turns", "nativeKeptIDs": .array((rows-20..<rows).map { JSON("r\($0)") }), "tokensBefore": 100000], id: "summary")
        }
        let first = try AgentSession(id: "long", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                     resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path)
        await first.close()
        let replies = PageReplies(), host = NativeHostService(emit: { replies.emit($0) })
        await host.receive(["v": 1, "kind": "hello", "major": 1])
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(directory.path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "long", params: ["path": JSON(path.path), "profile": profile.publicValue, "apiKey": "fixture", "toolMode": "read-only"])
        let loaded = await host.loadedSession("long"), session = try XCTUnwrap(loaded)
        addTeardownBlock { await host.shutdown(); try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, host: host, session: session, replies: replies, epoch: await host.epoch)
    }

    func testCancelStopsPageAtARowBoundaryAndNeverReportsAPartialSuccess() async throws {
        for method in ["session.history", "session.version.page"] {
            let f = try await fixture()
            try await f.session.loadFullHistory()
            await f.session.fixtureVersion()
            let expected = try await f.host.command(method, sessionID: "long", params: method == "session.history" ? ["version": 2, "position": 0] : ["messageId": "r0"])
            let gate = PageStepGate(); defer { gate.open() }
            await f.session.noteHistoryPageSteps { gate.step($0) }
            await f.command("old", method: method, params: method == "session.history" ? ["version": 2, "position": 0] : ["messageId": "r0"], token: "old-token")
            try await eventually { gate.count > 0 }
            await f.cancel("old", token: "old-token")
            XCTAssertTrue(f.replies.replies("old").isEmpty, "A cancel cannot acknowledge the slot while the read still runs")
            gate.open()
            let cancelled = try await f.reply("old")
            XCTAssertEqual(cancelled["ok"].flag, false)
            XCTAssertEqual(cancelled["error"]["code"].text, "command_cancelled")
            XCTAssertEqual(gate.count, 1, "No remaining page rows should be built after cancellation")
            await f.session.noteHistoryPageSteps(nil)
            await f.command("new", method: method, params: method == "session.history" ? ["version": 2, "position": 0] : ["messageId": "r0"])
            let fresh = try await f.reply("new")
            XCTAssertEqual(fresh["result"], expected, "Cancellation cannot change ordering, boundaries, content or identity")
            XCTAssertEqual(f.replies.replies("old").count, 1)
        }
    }

    func testCancelStopsParallelJournalDecodesAndQueuedReadsBeforeTheyStart() async throws {
        let f = try await fixture()
        _ = try await f.session.historyWindow(["version": 2, "position": 0])
        let gate = PageDecodeGate(); defer { gate.release() }
        await f.session.noteHistoryPageSteps { gate.step($0) }
        await f.command("active", token: "active")
        try await eventually { gate.count > 0 }
        for index in 0..<24 {
            let id = "queued-\(index)"
            await f.command(id, token: id)
            await f.cancel(id, token: id)
        }
        await f.cancel("active", token: "active")
        gate.release()
        let result = try await f.reply("active")
        XCTAssertEqual(result["error"]["code"].text, "command_cancelled")
        for index in 0..<24 {
            let reply = try await f.reply("queued-\(index)")
            XCTAssertEqual(reply["error"]["code"].text, "command_cancelled")
        }
        XCTAssertLessThanOrEqual(gate.count, ProcessInfo.processInfo.activeProcessorCount, "Only already-entered decode units may run; all later rows and queued reads are obsolete")
        let indexed = await f.session.olderIndex != nil, partial = await f.session.partialHistory
        XCTAssertTrue(indexed); XCTAssertTrue(partial, "Cancellation must not trigger unreadable-row full-history fallback")
        await f.session.noteHistoryPageSteps(nil)
        await f.command("newest", params: ["version": 2, "position": 60])
        let newest = try await f.reply("newest")
        XCTAssertEqual(newest["ok"].flag, true)
        XCTAssertEqual(newest["result"]["messages"].list.first?["id"].text, "r60")
    }

    func testStaleEpochTokenAndNonReadCancelsAreIgnored() async throws {
        let f = try await fixture(), gate = PageStepGate(); defer { gate.open() }
        await f.session.noteHistoryPageSteps { gate.step($0) }
        await f.command("read", token: "current")
        try await eventually { gate.count > 0 }
        await f.cancel("read", token: "current", epoch: "retired")
        await f.cancel("read", token: "retired")
        gate.open()
        let result = try await f.reply("read")
        XCTAssertEqual(result["ok"].flag, true)
        XCTAssertGreaterThan(result["result"]["messages"].list.count, 1)
        // A late cancel for an earlier use of this command ID cannot stop
        // its replacement; the dispatch token is part of the identity.
        let replacementGate = PageStepGate(); defer { replacementGate.open() }
        await f.session.noteHistoryPageSteps { replacementGate.step($0) }
        await f.command("read", token: "replacement")
        try await eventually { replacementGate.count > 0 }
        await f.cancel("read", token: "current")
        replacementGate.open()
        try await eventually { f.replies.replies("read").count == 2 }
        XCTAssertEqual(f.replies.replies("read").last?["ok"].flag, true)
        await f.command("mutation", method: "queue.configure", params: ["mode": "one-at-a-time"], token: "mutation-token")
        await f.cancel("mutation", token: "mutation-token")
        let mutation = try await f.reply("mutation")
        XCTAssertNotEqual(mutation["error"]["code"].text, "command_cancelled")
    }

    /// No injected page delays: generated journal, warm index,
    /// 24 page requests immediately superseded and then the final destination.
    func testRapidSupersessionMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["PI_SCROLL14_PERF"] == "1" else { throw XCTSkip("Set PI_SCROLL14_PERF=1 for generated long-chat measurements") }
        let f = try await fixture(rows: 4000, bodyBytes: 16384)
        _ = try await f.session.historyWindow(["version": 2, "position": 0])
        let indexed = await f.session.olderIndex != nil
        let bytes = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("state/long.jsonl").path)[.size] as? NSNumber
        print("SCROLL14_FIXTURE rows=4000 turns=200 bytes=\(bytes?.intValue ?? 0) indexed=\(indexed)")
        XCTAssertTrue(indexed, "Measure real journal paging through the older-row index")
        for run in 0..<5 {
            let started = ContinuousClock.now
            for request in 0..<24 {
                let id = "\(run)-\(request)"
                await f.command(id, params: ["version": 2, "position": JSON(request * 120)], token: id)
                await f.cancel(id, token: id)
            }
            let final = "final-\(run)", requested = ContinuousClock.now
            await f.command(final, params: ["version": 2, "position": 3200], token: final)
            let result = try await f.reply(final), emitted = try XCTUnwrap(f.replies.replyTime(final))
            let elapsed = emitted - requested, total = emitted - started
            XCTAssertEqual(result["ok"].flag, true)
            XCTAssertEqual(result["result"]["messages"].list.first?["id"].text, "r3200")
            for request in 0..<24 { _ = try await f.reply("\(run)-\(request)") }
            let cancelled = (0..<24).filter { f.replies.replies("\(run)-\($0)").first?["error"]["code"].text == "command_cancelled" }.count
            func ms(_ value: Duration) -> Double { Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15 }
            print(String(format: "SCROLL14_PERF run=%d superseded=24 cancelled=%d final_ms=%.2f burst_ms=%.2f", run, cancelled, ms(elapsed), ms(total)))
        }
    }
}

private extension AgentSession {
    func fixtureVersion() {
        versions.ledger.branched(from: "r0")
        versions.ledger.recorded(userMessage: "replacement")
    }
}
