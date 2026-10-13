import XCTest
@testable import PiAgentCore

final class CaptureSpoolTests: XCTestCase {
    func testRefusedRecoveryFinalizesTheArchiveButKeepsItsSpoolForRetry() async throws {
        for refused in ["bytes", "finish"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let spool = try CaptureSpool(in: root), id = UUID().uuidString
            try spool.append(["type": "begin", "metadata": ["attemptId": JSON(id), "outcome": "running"]], attempt: id)
            try spool.append(["type": "bytes", "attemptId": JSON(id), "body": "request", "offset": 0, "bytes": "YWJj"], attempt: id)
            try spool.append(["type": "finish", "metadata": ["attemptId": JSON(id), "outcome": "completed"]], attempt: id)
            let sink = RecoveredSpoolPackets(rejecting: refused), traces = TraceStore(sink: { await sink.accept($0) })
            try await traces.openCaptureSpool(in: root)
            try await eventually { await sink.packets.contains { $0["type"].text == "replay.abort" } }
            XCTAssertEqual(try CaptureSpool(in: root).recovered.count, 1, "Archive refusal cannot retire complete capture bytes")
            let packets = await sink.packets
            XCTAssertEqual(packets.last?["attemptId"].text, id)
            XCTAssertFalse(packets.contains { $0["type"].text == "replay.end" })
            let retry = TraceStore()
            try await retry.openCaptureSpool(in: root)
            try await eventually { (try? CaptureSpool(in: root).recovered.isEmpty) == true }
        }
    }

    func testDamagedRecoveryAlsoAbortsAnAlreadyOpenedArchiveWriter() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CaptureSpool(in: root), id = UUID().uuidString
        try spool.append(["type": "begin", "metadata": ["attemptId": JSON(id), "outcome": "running"]], attempt: id)
        let file = root.appendingPathComponent(".capture-outbox/\(id).jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("not-json\n".utf8)); try handle.close()
        let sink = RecoveredSpoolPackets(), traces = TraceStore(sink: { await sink.accept($0) })
        try await traces.openCaptureSpool(in: root)
        try await eventually { await sink.packets.contains { $0["type"].text == "replay.abort" } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFinishedCapturesWaitingForAcknowledgmentDoNotKeepOpenDescriptors() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CaptureSpool(in: root)
        for _ in 0..<128 {
            let id = UUID().uuidString
            try spool.append(["type": "begin", "metadata": ["attemptId": JSON(id)]], attempt: id)
            try spool.append(["type": "finish", "metadata": ["attemptId": JSON(id)]], attempt: id)
        }
        print("CAPTURE unacknowledged=128 openDescriptors=\(spool.openFileCount)")
        XCTAssertEqual(spool.openFileCount, 0, "An unlimited disk backlog must not exhaust file descriptors")
        XCTAssertEqual(try CaptureSpool(in: root).recovered.count, 128, "Every unacknowledged attempt is still retained")
    }

    func testOutputLinksAfterTheAcknowledgedFinishRemainRecoverable() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore()
        try await traces.openCaptureSpool(in: root)
        let id = try await traces.begin(session: "s", turn: "t", profile: fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        await traces.delivered()
        XCTAssertEqual(try CaptureSpool(in: root).recovered.count, 0)
        await traces.stopCaptureDelivery()
        await traces.outputs(id, messageIDs: ["late-output"])
        let file = root.appendingPathComponent(".capture-outbox/\(id).jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let sink = RecoveredSpoolPackets(), restored = TraceStore(sink: { await sink.accept($0) })
        try await restored.openCaptureSpool(in: root)
        try await eventually { !FileManager.default.fileExists(atPath: file.path) }
        let packets = await sink.packets
        XCTAssertEqual(packets.first?["type"].text, "links")
        XCTAssertEqual(packets.first?["replay"].flag, true)
        XCTAssertEqual(packets.first?["outputMessageIds"].list, ["late-output"])
    }
    func testSpoolUsesOnlySanitizedPacketsAndHonorsBodyCaptureMode() async throws {
        for mode in ["off", "memory", "persist"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let traces = TraceStore(sink: { _ in false })
            try await traces.openCaptureSpool(in: root)
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            let secret = "synthetic-private-credential-z19"
            let id = try await traces.begin(session: "s", turn: "t", profile: fixtureProfile(), purpose: "turn", body: Data("question containing \(secret)".utf8), headers: ["Authorization": "Bearer \(secret)"])
            await traces.append(id, data: Data("response echo \(secret)".utf8))
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            await traces.delivered()
            let file = root.appendingPathComponent(".capture-outbox/\(id).jsonl")
            let packets = try Data(contentsOf: file).split(separator: 10).map { try JSON.parse(Data($0)) }
            XCTAssertEqual(packets.first?["type"].text, "begin")
            XCTAssertEqual(packets.last?["type"].text, "finish")
            XCTAssertFalse(packets.contains { $0.encoded().contains(secret) })
            let bodies = packets.filter { $0["type"].text == "bytes" }.compactMap { Data(base64Encoded: $0["bytes"].text ?? "") }
            XCTAssertEqual(bodies.isEmpty, mode != "persist")
            XCTAssertTrue(bodies.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(secret) })
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            _ = try await traces.command("debug.clear", session: "s", params: [:])
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Clearing capture clears its recovery copy too")
        }
    }

    func testOnlyAcknowledgingTheWholeFinishedAttemptRetiresItsSpool() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CaptureSpool(in: root), id = UUID().uuidString
        let first = try spool.append(["type": "begin", "metadata": ["attemptId": JSON(id)]], attempt: id)
        let final = try spool.append(["type": "finish", "metadata": ["attemptId": JSON(id)]], attempt: id)
        try spool.confirmed(id, through: first, accepted: true)
        XCTAssertEqual(try CaptureSpool(in: root).recovered.count, 1)
        let linked = try spool.append(["type": "links", "attemptId": JSON(id), "outputMessageIds": ["reply"]], attempt: id)
        try spool.confirmed(id, through: final, accepted: true)
        XCTAssertEqual(try CaptureSpool(in: root).recovered.count, 1, "Final message links may follow the terminal request record")
        try spool.confirmed(id, through: linked, accepted: true)
        XCTAssertEqual(try CaptureSpool(in: root).recovered.count, 0)
    }
}

private actor RecoveredSpoolPackets {
    private(set) var packets: [JSON] = []
    let rejecting: String?
    init(rejecting: String? = nil) { self.rejecting = rejecting }
    func accept(_ packet: JSON) -> Bool { packets.append(packet); return packet["type"].text != rejecting }
}
