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
    /// Packets emitted but not yet taken by `next()`.
    var unanswered: Int { lock.lock(); defer { lock.unlock() }; return frames.count - cursor }
}

private actor CompletedCaptures {
    var attempts: [Int: String] = [:]
    func add(_ index: Int, _ attempt: String) { attempts[index] = attempt }
    var count: Int { attempts.count }
}

final class CaptureConcurrencyTests: XCTestCase {
    /// An acknowledgment that took longer than 3 s used to switch capture off
    /// for good, for every chat on the helper: the log then missed every later
    /// request. A slow recorder now only delays the pages behind it.
    func testSlowRecorderDelaysPacketsButNeverTurnsCaptureOff() async throws {
        let packets = ConcurrentCapturePackets()
        let delivery = CaptureDelivery(epoch: "fixture", emit: { packets.append($0) })
        await delivery.enable()
        let tasks = (0..<20).map { index in Task { await delivery.send(["type": "fixture", "session": JSON(index)]) } }
        try await eventually { await delivery.pendingCount == 20 }
        try await Task.sleep(for: .milliseconds(3_200))
        XCTAssertEqual(packets.packets.count, 1, "One page in flight; the rest wait their turn")
        try await eventually {
            if let frame = packets.next() { await delivery.acknowledge(frame["transferId"].text!, accepted: true) }
            return packets.packets.count == 20 && packets.unanswered == 0
        }
        for task in tasks { let accepted = await task.value; XCTAssertTrue(accepted) }
        let later = Task { await delivery.send(["type": "finish"]) }
        try await eventually { packets.unanswered == 1 }
        await delivery.acknowledge(packets.next()!["transferId"].text!, accepted: true)
        let accepted = await later.value
        XCTAssertTrue(accepted, "A late acknowledgment leaves capture on for later packets")
        XCTAssertEqual(Set(packets.packets.compactMap { $0["session"].int }), Set(0..<20), "Every held page went out")
        XCTAssertEqual(packets.packets.last?["type"].text, "finish")
        let pending = await delivery.pendingCount; XCTAssertEqual(pending, 0)
    }

    /// Shutting down drops acknowledgments, so a stopped run cleaning up must
    /// not wait for them: the packet in flight and every later one are
    /// answered at once.
    func testClosingAnswersTheWaitingAndLaterPacketsAtOnce() async throws {
        let packets = ConcurrentCapturePackets()
        let delivery = CaptureDelivery(epoch: "fixture", emit: { packets.append($0) })
        await delivery.enable()
        let tasks = (0..<3).map { index in Task { await delivery.send(["type": "fixture", "session": JSON(index)]) } }
        try await eventually { await delivery.pendingCount == 3 }
        let started = Date()
        await delivery.close()
        for task in tasks { let accepted = await task.value; XCTAssertFalse(accepted) }
        let accepted = await delivery.send(["type": "finish"])
        XCTAssertFalse(accepted, "A packet after close is refused, not queued behind a reader that is gone")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Nothing waits for an acknowledgment that cannot come")
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

    /// Nothing is cut: twenty active requests keep every byte, the log gets
    /// every page in order, and a persisted chat's copies are let go only once
    /// the log has saved them. A session-memory chat keeps all of it.
    func testTwentyActiveCapturesKeepEveryByteUntilTheLogSavedIt() async throws {
        let profile = try fixtureProfile()
        let requests = (0..<20).map { Data("request-\($0):\(String(repeating: "r", count: 1_500))".utf8) }
        let head = Data("original-prefix:\(String(repeating: "a", count: 1_000))".utf8)
        let tail = Data("later-tail:\(String(repeating: "b", count: 1_000))".utf8)
        for mode in ["persist", "memory"] {
            let packets = ConcurrentCapturePackets()
            let traces = TraceStore(sink: { packets.append(["packet": $0]); return true })
            var attempts: [String] = []
            for index in 0..<20 {
                _ = try await traces.command("debug.mode", session: "session-\(index)", params: ["mode": JSON(mode)])
                let id = await traces.begin(session: "session-\(index)", turn: "turn-\(index)", profile: profile, purpose: "turn", body: requests[index], headers: [:])
                attempts.append(id)
                await traces.append(id, data: head)
            }
            await traces.append(attempts[0], data: tail)
            let everything = requests.reduce(0) { $0 + $1.count } + 20 * head.count + tail.count
            let active = try await traces.command("debug.list", session: "session-0", params: [:])
            XCTAssertEqual(active["workspaceRetainedBytes"].int, everything, "\(mode): every active byte is kept")
            for index in 0..<20 {
                let id = attempts[index], response = index == 0 ? head + tail : head
                for (kind, expected) in [("request", requests[index]), ("response", response)] {
                    let body = try await traces.command("debug.body", session: "session-\(index)", params: ["attemptId": JSON(id), "body": JSON(kind)])
                    XCTAssertEqual(Data(base64Encoded: body["bytes"].text ?? ""), expected, "\(mode) \(index) \(kind)")
                    XCTAssertEqual(body["retainedBytes"].int, expected.count)
                }
                await traces.transport(id, observation: ["transportOutcome": "eof", "httpEnd": 1])
                await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            }
            await traces.delivered()
            for index in 0..<20 {
                let id = attempts[index], response = index == 0 ? head + tail : head
                let metadata = try await traces.command("debug.attempt", session: "session-\(index)", params: ["attemptId": JSON(id)])
                for (kind, expected) in [("request", requests[index]), ("response", response)] {
                    XCTAssertEqual(metadata[kind]["retainedBytes"].int, expected.count)
                    XCTAssertEqual(metadata[kind]["state"].text, "complete")
                    var durable = Data()
                    for packet in packets.packets where packet["type"].text == "bytes" && packet["attemptId"].text == id && packet["body"].text == kind {
                        XCTAssertEqual(packet["offset"].int, durable.count)
                        durable.append(try XCTUnwrap(Data(base64Encoded: packet["bytes"].text ?? "")))
                    }
                    if mode == "persist" {
                        XCTAssertEqual(durable, expected, "The log got every page, in order")
                        XCTAssertEqual(metadata[kind]["savedToLog"].flag, true)
                        do {
                            _ = try await traces.command("debug.body", session: "session-\(index)", params: ["attemptId": JSON(id), "body": JSON(kind)])
                            XCTFail("A saved body is read from the app's log")
                        } catch let error as AgentError { XCTAssertEqual(error.code, "capture_saved") }
                    } else {
                        XCTAssertEqual(durable, Data(), "A session-memory chat sends no body to the log")
                        XCTAssertEqual(metadata[kind]["savedToLog"].flag, false)
                        let body = try await traces.command("debug.body", session: "session-\(index)", params: ["attemptId": JSON(id), "body": JSON(kind)])
                        XCTAssertEqual(Data(base64Encoded: body["bytes"].text ?? ""), expected, "The helper holds its only copy")
                    }
                }
            }
            let settled = try await traces.command("debug.list", session: "session-0", params: [:])
            XCTAssertEqual(settled["workspaceRetainedBytes"].int, mode == "persist" ? 0 : everything)
        }
    }

    /// Twenty chats capture at once behind a recorder that has not answered
    /// its first page: none of them waits for it, and once it answers, every
    /// page arrives exactly, one at a time.
    func testTwentyConcurrentCapturesQueueBehindRecorderAndRetainExactBodies() async throws {
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
        // The first acknowledgment is held until every producer is done.
        try await eventually { await completed.count == 20 && packets.packets.count == 1 }
        XCTAssertEqual(packets.packets.count, 1, "No request waited on the recorder, and one page is in flight")
        let pending = await delivery.pendingCount; XCTAssertEqual(pending, 1)
        let drained = Task { await traces.delivered() }
        try await eventually {
            if let frame = packets.next() { await delivery.acknowledge(frame["transferId"].text!, accepted: true) }
            return packets.packets.filter { $0["type"].text == "finish" }.count == 20 && packets.unanswered == 0
        }
        await drained.value
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
        let remaining = await delivery.pendingCount
        XCTAssertEqual(remaining, 0)
    }
}
