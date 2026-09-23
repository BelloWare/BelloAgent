import XCTest
@testable import PiAgentCore

private final class ConcurrentCapturePackets: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSON] = [], cursor = 0
    func append(_ frame: JSON) { lock.lock(); frames.append(frame); lock.unlock() }
    func next() -> JSON? {
        lock.lock(); defer { lock.unlock() }
        guard cursor < frames.count else { return nil }
        defer { cursor += 1 }; return frames[cursor]
    }
    var packets: [JSON] { lock.lock(); defer { lock.unlock() }; return frames.map { $0["packet"] } }
}

private actor CompletedCaptures {
    var attempts: [Int: String] = [:]
    func add(_ index: Int, _ attempt: String) { attempts[index] = attempt }
    var count: Int { attempts.count }
}

final class CaptureConcurrencyTests: XCTestCase {
    func testRecorderTimeoutFailsQueuedProducersWithoutMultiplyingDeadlines() async throws {
        let packets = ConcurrentCapturePackets()
        let delivery = CaptureDelivery(epoch: "fixture", acknowledgmentTimeoutNanoseconds: 100_000_000, emit: { packets.append($0) })
        await delivery.enable()
        let tasks = (0..<20).map { index in Task { await delivery.send(["type": "fixture", "session": JSON(index)]) } }
        try await eventually { await delivery.pendingCount == 20 }
        for task in tasks { let accepted = await task.value; XCTAssertFalse(accepted) }
        XCTAssertEqual(packets.packets.count, 1, "A missing recorder must not start a fresh timeout for each queued session")
        let accepted = await delivery.send(["type": "finish"])
        XCTAssertFalse(accepted, "The failed connection must not claim later capture packets were retained")
        XCTAssertEqual(packets.packets.count, 1)
        let pending = await delivery.pendingCount; XCTAssertEqual(pending, 0)
    }

    /// Shutting down drops acknowledgments, so a capture sent while a stopped
    /// run cleans up waited the whole deadline (3 s by default) and the app,
    /// quitting meanwhile, never saw the partial reply or the final state.
    func testClosingAnswersTheWaitingAndLaterPacketsAtOnce() async throws {
        let packets = ConcurrentCapturePackets()
        let delivery = CaptureDelivery(epoch: "fixture", acknowledgmentTimeoutNanoseconds: 60_000_000_000, emit: { packets.append($0) })
        await delivery.enable()
        let tasks = (0..<3).map { index in Task { await delivery.send(["type": "fixture", "session": JSON(index)]) } }
        try await eventually { await delivery.pendingCount == 3 }
        let started = Date()
        await delivery.close()
        for task in tasks { let accepted = await task.value; XCTAssertFalse(accepted) }
        let accepted = await delivery.send(["type": "finish"])
        XCTAssertFalse(accepted, "A packet after close is refused, not queued behind a reader that is gone")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Nothing waits for the acknowledgment deadline")
        XCTAssertEqual(packets.packets.count, 1)
        let pending = await delivery.pendingCount; XCTAssertEqual(pending, 0)
    }

    func testRejectedAcknowledgmentRemainsIsolatedToItsPacket() async throws {
        let packets = ConcurrentCapturePackets(), completed = CompletedCaptures()
        let delivery = CaptureDelivery(epoch: "fixture", emit: { packets.append($0) })
        await delivery.enable()
        let tasks = (0..<20).map { index in Task {
            let accepted = await delivery.send(["type": "fixture", "session": JSON(index)])
            await completed.add(index, accepted ? "accepted" : "rejected")
        } }
        try await eventually { await delivery.pendingCount == 20 }
        try await eventually {
            if let frame = packets.next() { await delivery.acknowledge(frame["transferId"].text!, accepted: frame["packet"]["session"].int != 7) }
            return await completed.count == 20
        }
        for task in tasks { await task.value }
        let outcomes = await completed.attempts
        for index in 0..<20 { XCTAssertEqual(outcomes[index], index == 7 ? "rejected" : "accepted") }
        XCTAssertEqual(packets.packets.count, 20)
    }

    func testTwentyActiveCapturesRespectMemoryBudgetWithoutGapsOrDurableByteLoss() async throws {
        let packets = ConcurrentCapturePackets(), limit = 16_000
        let traces = TraceStore(memoryLimit: limit, sink: { packets.append(["packet": $0]); return true })
        let profile = try fixtureProfile()
        let requests = (0..<20).map { Data("request-\($0):\(String(repeating: "r", count: 1_500))".utf8) }
        let head = Data("original-prefix:\(String(repeating: "a", count: 1_000))".utf8)
        let tail = Data("later-tail:\(String(repeating: "b", count: 1_000))".utf8)
        var attempts: [String] = []
        for index in 0..<20 {
            _ = try await traces.command("debug.mode", session: "session-\(index)", params: ["mode": "persist"])
            let id = await traces.begin(session: "session-\(index)", turn: "turn-\(index)", profile: profile, purpose: "turn", body: requests[index], headers: [:])
            attempts.append(id)
            if index == 0 { await traces.append(id, data: head) }
            let retained = try await traces.command("debug.list", session: "session-\(index)", params: [:])
            XCTAssertLessThanOrEqual(retained["workspaceRetainedBytes"].int ?? Int.max, limit)
        }
        // Session zero's prefix was trimmed while other requests stayed active.
        // A later chunk must not be joined onto that shortened memory prefix.
        await traces.append(attempts[0], data: tail)
        for index in 1..<20 { await traces.append(attempts[index], data: head) }
        let retained = try await traces.command("debug.list", session: "session-0", params: [:])
        XCTAssertLessThanOrEqual(retained["workspaceRetainedBytes"].int ?? Int.max, limit)
        XCTAssertEqual(retained["droppedMetadata"].int, 0, "Active attempts and their ownership must survive memory pressure")
        for index in 0..<20 {
            let id = attempts[index], response = index == 0 ? head + tail : head
            await traces.transport(id, observation: ["transportOutcome": "eof", "httpEnd": 1])
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            for (kind, expected) in [("request", requests[index]), ("response", response)] {
                let body = try await traces.command("debug.body", session: "session-\(index)", params: ["attemptId": JSON(id), "body": JSON(kind)])
                let bytes = try XCTUnwrap(Data(base64Encoded: body["bytes"].text ?? ""))
                XCTAssertEqual(bytes, expected.prefix(bytes.count), "Memory capture must remain a contiguous prefix")
                XCTAssertEqual(body["captureBytes"].int, expected.count)
                if bytes.count < expected.count {
                    XCTAssertEqual(body["state"].text, "truncated")
                    XCTAssertTrue(body["reason"].text?.lowercased().contains("workspace memory") == true)
                }
                var durable = Data()
                for packet in packets.packets where packet["type"].text == "bytes" && packet["attemptId"].text == id && packet["body"].text == kind {
                    XCTAssertEqual(packet["offset"].int, durable.count)
                    durable.append(try XCTUnwrap(Data(base64Encoded: packet["bytes"].text ?? "")))
                }
                XCTAssertEqual(durable, expected, "Memory trimming must not change recorder bytes or offsets")
            }
        }
    }

    func testTwentyConcurrentCapturesWaitForRecorderAndRetainExactBodies() async throws {
        let packets = ConcurrentCapturePackets(), completed = CompletedCaptures()
        let delivery = CaptureDelivery(epoch: "fixture", emit: { packets.append($0) })
        await delivery.enable()
        let traces = TraceStore(sink: { await delivery.send($0) })
        let profile = try fixtureProfile()
        let requests = (0..<20).map { Data("request-\($0):\(String(repeating: "r", count: 40_000))".utf8) }
        let responses = (0..<20).map { Data("response-\($0):\(String(repeating: "s", count: 40_000))".utf8) }
        for index in 0..<20 { _ = try await traces.command("debug.mode", session: "session-\(index)", params: ["mode": "persist"]) }
        let tasks = (0..<20).map { index in
            Task {
                let attempt = await traces.begin(session: "session-\(index)", turn: "turn-\(index)", profile: profile, purpose: "turn", body: requests[index], headers: [:])
                await traces.append(attempt, data: responses[index])
                await traces.transport(attempt, observation: ["transportOutcome": "eof", "httpEnd": 1])
                await traces.finish(attempt, outcome: "completed", modelOutcome: "completed")
                await completed.add(index, attempt)
            }
        }
        // Deliberately hold the first acknowledgement until every producer has
        // arrived. A healthy recorder must apply backpressure, never drop begin.
        try await eventually { await delivery.pendingCount + completed.count == 20 }
        let early = await completed.count
        XCTAssertEqual(early, 0, "A saturated recorder is not an unavailable recorder")
        try await eventually {
            if let frame = packets.next() { await delivery.acknowledge(frame["transferId"].text!, accepted: true) }
            return await completed.count == 20
        }
        for task in tasks { await task.value }
        let captured = packets.packets, attempts = await completed.attempts
        XCTAssertEqual(captured.filter { $0["type"].text == "begin" }.count, 20)
        XCTAssertEqual(captured.filter { $0["type"].text == "finish" }.count, 20)
        for index in 0..<20 {
            let attempt = try XCTUnwrap(attempts[index])
            let metadata = try await traces.command("debug.attempt", session: "session-\(index)", params: ["attemptId": JSON(attempt)])
            XCTAssertTrue(metadata["persistenceError"].isNull, "\(index): \(metadata["persistenceError"])")
            for (kind, expected) in [("request", requests[index]), ("response", responses[index])] {
                var actual = Data()
                for packet in captured where packet["type"].text == "bytes" && packet["attemptId"].text == attempt && packet["body"].text == kind {
                    XCTAssertEqual(packet["offset"].int, actual.count)
                    actual.append(try XCTUnwrap(Data(base64Encoded: packet["bytes"].text ?? "")))
                }
                XCTAssertEqual(actual, expected, "\(kind) belongs only to session-\(index)")
            }
        }
        let pending = await delivery.pendingCount
        XCTAssertEqual(pending, 0)
    }
}
