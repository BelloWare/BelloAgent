import XCTest
@testable import PiAgentCore

final class SessionMonitoringTests: XCTestCase {
    func testCursorPhaseBurstAndBoundedGap() throws {
        var buffer = SessionMonitoringBuffer()
        for phase in ["model", "model", "tool", "idle"] { buffer.activity(phase, at: 1) }
        let first = buffer.page(since: 0, epoch: "e", requestedEpoch: "e")
        XCTAssertEqual(first["events"].list.count, 3)
        XCTAssertTrue(buffer.page(since: first["cursor"].int, epoch: "e", requestedEpoch: "e")["events"].list.isEmpty)
        for i in 0..<200 { buffer.activity(i % 2 == 0 ? "tool" : "model", at: Double(i)) }
        let overflow = buffer.page(since: 3, epoch: "e", requestedEpoch: "e")
        XCTAssertEqual(overflow["events"].list.count, 96); XCTAssertEqual(overflow["gap"].flag, true)
        XCTAssertFalse(buffer.page(since: 9999, epoch: "new", requestedEpoch: "old")["events"].list.isEmpty)
    }
    func testCompactionMonitoringDoesNotMutateConversationContext() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: DisabledTools(), traces: TraceStore(), autoCompaction: false)
        addTeardownBlock { await session.close() }
        let before = await session.snapshot(["includeMessages": false, "includeMetrics": false])
        var observation = RequestObservation(sessionID: "s", turnID: "t", attemptID: "utility", purpose: "compaction", fingerprint: "not-for-popup", profile: try fixtureProfile())
        observation.phase = "interim"
        observation.fields = ["input": 1_000, "output": 20]; observation.fieldStatus = ["input":"reported", "output":"reported"]
        await session.compactionObservation(observation)
        let after = await session.snapshot(["includeMessages": false, "includeMetrics": false])
        XCTAssertEqual(before["contextState"], after["contextState"])
        XCTAssertEqual(before["requestObservation"], after["requestObservation"])
        XCTAssertEqual(before["displayRevision"], after["displayRevision"])
        let records = after["monitoring"]["events"].list.filter { $0["kind"].text == "request" }
        XCTAssertEqual(records.first?["purpose"].text, "compaction")
        XCTAssertTrue(records.first?["requestFingerprint"].isNull ?? false)
        XCTAssertEqual(records.first?["usage"]["output"].int, 20)
    }
}
