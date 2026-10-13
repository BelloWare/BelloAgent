import XCTest
@testable import PiApp

final class CaptureReplayTests: XCTestCase {
    func testReplayRestoresTerminalMetadataForMemoryAndDisabledBodyCapture() async throws {
        for mode in ["memory", "off"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = PayloadArchive(root: root), id = UUID().uuidString
            try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
            var begin = metadata(id); begin["mode"] = .string(mode)
            try await archive.begin(begin, workspace: "w")
            var interrupted = begin; interrupted["outcome"] = .string("interrupted")
            try await archive.finish(interrupted)
            try await archive.accept(["type": .string("replay.begin"), "metadata": .object(begin)], workspace: "w")
            var terminal = begin; terminal["outcome"] = .string("completed")
            terminal["usage"] = .object(["input": .number(12), "output": .number(7)])
            try await archive.accept(["type": .string("finish"), "metadata": .object(terminal)], workspace: "w")
            try await archive.accept(["type": .string("replay.end"), "attemptId": .string(id)], workspace: "w")
            let final = try await archive.metadata(attempt: id)
            XCTAssertEqual(final["outcome"]?.string, "completed", mode)
            XCTAssertEqual(final["usage"]?.object?["output"]?.number, 7, mode)
            XCTAssertEqual(final["request"]?.object?["state"]?.string, "not-retained")
        }
    }

    func testRecoveredOutputLinksCanFollowAnAlreadySavedFinishFromAnotherEpoch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root), id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        var saved = metadata(id); saved["hostEpoch"] = .string("old")
        try await archive.begin(saved, workspace: "w")
        saved["outcome"] = .string("completed"); try await archive.finish(saved)
        try await archive.accept(["type": .string("links"), "attemptId": .string(id), "hostEpoch": .string("new"), "replay": .bool(true), "outputMessageIds": .array([.string("reply")])], workspace: "w")
        let links = try await archive.linkedMessages(attemptID: id)
        XCTAssertEqual(links.output, ["reply"])
    }

    func testALateOldHostPacketCannotOverwriteTheRecoveredAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root), id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        var old = metadata(id); old["hostEpoch"] = .string("old")
        try await archive.begin(old, workspace: "w")
        old["outcome"] = .string("interrupted"); try await archive.finish(old)
        var recovered = metadata(id); recovered["hostEpoch"] = .string("new")
        try await archive.accept(["type": .string("replay.begin"), "metadata": .object(recovered)], workspace: "w")
        do {
            try await archive.accept(["type": .string("bytes"), "attemptId": .string(id), "hostEpoch": .string("old"), "body": .string("request"), "offset": .number(0), "bytes": .string(Data("old".utf8).base64EncodedString())], workspace: "w")
            XCTFail("A held consumer from the previous helper cannot write into the recovered attempt")
        } catch { }
        try await archive.accept(["type": .string("bytes"), "attemptId": .string(id), "hostEpoch": .string("new"), "body": .string("request"), "offset": .number(0), "bytes": .string(Data("new".utf8).base64EncodedString())], workspace: "w")
        var final = metadata(id, completed: true, bytes: 3); final["hostEpoch"] = .string("new")
        try await archive.finish(final)
        let body = try await archive.body(attemptID: id, body: "request", offset: 0)
        XCTAssertEqual(body, Data("new".utf8))
    }

    private func metadata(_ id: String, session: String = "s", completed: Bool = false, bytes: Int = 0) -> [String: WireValue] {
        ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string("t"), "mode": .string("persist"),
         "outcome": .string(completed ? "completed" : "running"), "modelOutcome": .string(completed ? "completed" : "pending"),
         "transportOutcome": .string(completed ? "eof" : "pending"), "wallTimestamp": .number(Date().timeIntervalSince1970),
         "request": .object(["observedBytes": .number(Double(bytes)), "captureBytes": .number(Double(bytes))]),
         "response": .object(["observedBytes": .number(0), "captureBytes": .number(0)])]
    }
    func testReplayRebuildsAnInterruptedAttemptWithoutDuplicatingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, archive = PayloadArchive(root: root)
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        let bytes = Data(String(repeating: "recover exact bytes 中文", count: 5000).utf8)
        try await archive.begin(metadata(id), workspace: "w")
        // The old owner acknowledged a prefix and finalized it as interrupted.
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: bytes.prefix(1000))
        var interrupted = metadata(id, bytes: bytes.count); interrupted["outcome"] = .string("interrupted")
        try await archive.finish(interrupted)
        for _ in 0..<2 {
            try await archive.accept(["type": .string("replay.begin"), "metadata": .object(metadata(id))], workspace: "w")
            for offset in stride(from: 0, to: bytes.count, by: 32_768) {
                try await archive.accept(["type": .string("bytes"), "attemptId": .string(id), "body": .string("request"), "offset": .number(Double(offset)), "bytes": .string(bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)).base64EncodedString())], workspace: "w")
            }
            try await archive.accept(["type": .string("events"), "attemptId": .string(id), "offset": .number(0), "events": .array([.object(["type": .string("response.completed"), "start": .number(0), "end": .number(1), "observedAt": .number(1)])])], workspace: "w")
            try await archive.accept(["type": .string("finish"), "metadata": .object(metadata(id, completed: true, bytes: bytes.count))], workspace: "w")
            try await archive.accept(["type": .string("replay.end"), "attemptId": .string(id)], workspace: "w")
        }
        let final = try await archive.metadata(attempt: id)
        XCTAssertEqual(final["outcome"]?.string, "completed")
        XCTAssertEqual(final["request"]?.object?["state"]?.string, "complete")
        var actual = Data()
        while actual.count < bytes.count {
            let page = try await archive.body(attemptID: id, body: "request", offset: actual.count)
            guard !page.isEmpty else { XCTFail("The durable body must include every byte"); break }
            actual.append(page)
        }
        XCTAssertEqual(actual, bytes)
        let attempts = try await archive.list(sessionID: "s"), events = try await archive.eventIndices(attemptID: id, offset: 0)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(events["events"]?.array?.count, 1)
    }

    func testReplayCannotCrossWorkspaceOrRestoreAPurgedBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root), id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        try await archive.begin(metadata(id), workspace: "owner")
        try await archive.finish(metadata(id, completed: true))
        do {
            try await archive.accept(["type": .string("replay.begin"), "metadata": .object(metadata(id))], workspace: "other")
            XCTFail("Recovery must preserve archive ownership")
        } catch { }
        try await archive.purge(attemptID: id)
        try await archive.accept(["type": .string("replay.begin"), "metadata": .object(metadata(id))], workspace: "owner")
        try await archive.accept(["type": .string("bytes"), "attemptId": .string(id), "body": .string("request"), "offset": .number(0), "bytes": .string(Data("discarded".utf8).base64EncodedString())], workspace: "owner")
        try await archive.accept(["type": .string("finish"), "metadata": .object(metadata(id, completed: true, bytes: 9))], workspace: "owner")
        try await archive.accept(["type": .string("replay.end"), "attemptId": .string(id)], workspace: "owner")
        let final = try await archive.metadata(attempt: id)
        XCTAssertEqual(final["request"]?.object?["state"]?.string, "purged")
        XCTAssertEqual(final["request"]?.object?["retainedBytes"]?.number, 0)
    }
}
