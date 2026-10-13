import XCTest
@testable import PiApp

final class CaptureReplayTests: XCTestCase {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func replay(_ archive: PayloadArchive, _ metadata: [String: WireValue]) async throws {
        try await archive.accept(["type": .string("replay.begin"), "metadata": .object(metadata)], workspace: "w")
    }
    private func packet(_ type: String, _ metadata: [String: WireValue]) -> [String: WireValue] {
        ["type": .string(type), "metadata": .object(metadata)]
    }
    private func bodyPacket(_ id: String, _ bytes: Data) -> [String: WireValue] {
        ["type": .string("bytes"), "attemptId": .string(id), "body": .string("request"), "offset": .number(0), "bytes": .string(bytes.base64EncodedString())]
    }

    @MainActor func testBundledHelperKeepsRefusedReplayAndRetriesAfterArchiveRecovery() async throws {
        let root = try fixtureRoot(), state = root.appendingPathComponent("state"), directory = state.appendingPathComponent("Sessions")
        let outbox = directory.appendingPathComponent(".capture-outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let id = UUID().uuidString, bytes = Data(repeating: 97, count: 32_768)
        let file = outbox.appendingPathComponent(id + ".jsonl")
        var data = Data()
        for value in [packet("begin", metadata(id)), bodyPacket(id, bytes), packet("finish", metadata(id, completed: true, bytes: bytes.count))] {
            data.append(try JSONEncoder().encode(value)); data.append(10)
        }
        try data.write(to: file)
        let disk = ReplayDiskFailure(), archive = PayloadArchive(root: root.appendingPathComponent("archive"), beforeChunkWrite: { try disk.check() })
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        let aborted = expectation(description: "Refused replay releases archive writers"), recovered = expectation(description: "Retry finishes")
        let capture: @Sendable ([String: WireValue]) async throws -> Void = { value in
            try await archive.accept(value, workspace: "w")
            if value["type"]?.string == "replay.abort" { aborted.fulfill() }
            if value["type"]?.string == "replay.end" { recovered.fulfill() }
        }
        let host = HostSupervisor(); defer { host.shutdown() }
        let workspace: [String: WireValue] = ["cwd": .string(root.path), "directory": .string(directory.path), "captureProtocol": .number(1),
                                             "resources": .object(["skills": .bool(false), "codexHome": .string(root.appendingPathComponent("empty-codex").path)])]
        try await host.connect(cwd: root, state: state, capture: capture)
        _ = try await host.request("workspace.open", params: workspace)
        await fulfillment(of: [aborted], timeout: 5)
        let interrupted = try await archive.metadata(attempt: id)
        XCTAssertEqual(interrupted["outcome"]?.string, "interrupted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await host.shutdownAndWait()
        disk.recover()
        try await host.connect(cwd: root, state: state, capture: capture)
        _ = try await host.request("workspace.open", params: workspace)
        await fulfillment(of: [recovered], timeout: 5)
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: file.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Only the successful retry retires the spool")
        let actual = try await archive.completeBody(attemptID: id, body: "request")
        XCTAssertEqual(actual, bytes)
        try await host.shutdownAndWait()
        try await archive.purge(attemptID: id)
    }

    func testJournalRestoredLinksAreOwnedAndIdempotentAcrossEpochs() async throws {
        let archive = PayloadArchive(root: try fixtureRoot()), id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        var saved = metadata(id); saved["hostEpoch"] = .string("old")
        try await archive.begin(saved, workspace: "w")
        saved["outcome"] = .string("completed"); try await archive.finish(saved)
        // SessionReplay -> snapshot -> TraceStore.outputs has no replay flag.
        let links: [String: WireValue] = ["type": .string("links"), "attemptId": .string(id), "hostEpoch": .string("new"), "outputMessageIds": .array([.string("journal-reply")])]
        do { try await archive.accept(links, workspace: "other"); XCTFail("Links must retain workspace ownership") } catch { }
        for _ in 0..<2 { try await archive.accept(links, workspace: "w") }
        let linked = try await archive.linkedMessages(attemptID: id)
        XCTAssertEqual(linked.output, ["journal-reply"])
        let final = try await archive.metadata(attempt: id)
        XCTAssertEqual(final["hostEpoch"]?.string, "old", "Link repair does not replace request metadata")
    }

    func testReplayReclaimsItsDetachedPrefixBeforeReservingTheReplacement() async throws {
        for keepOther in [false, true] {
            let archive = PayloadArchive(root: try fixtureRoot()), id = UUID().uuidString, other = UUID().uuidString
            try await archive.configure(quota: keepOther ? 1400 : 600, bodyRetention: 86400, metricRetention: 604800)
            if keepOther {
                try await archive.begin(metadata(other), workspace: "w")
                try await archive.append(attempt: other, kind: "request", offset: 0, bytes: Data(repeating: 98, count: 800))
                try await archive.finish(metadata(other, completed: true, bytes: 800))
            }
            try await archive.begin(metadata(id), workspace: "w")
            try await archive.append(attempt: id, kind: "request", offset: 0, bytes: Data(repeating: 97, count: 400))
            var interrupted = metadata(id, bytes: 600); interrupted["outcome"] = .string("interrupted")
            try await archive.finish(interrupted)
            try await replay(archive, metadata(id))
            let replacement = Data(repeating: 97, count: 600)
            try await archive.accept(bodyPacket(id, replacement), workspace: "w")
            try await archive.accept(packet("finish", metadata(id, completed: true, bytes: 600)), workspace: "w")
            let retained = try await archive.body(attemptID: id, body: "request", offset: 0)
            XCTAssertEqual(retained, replacement, "Detached partial tails cannot consume replacement quota")
            if keepOther {
                let otherBody = try await archive.body(attemptID: other, body: "request", offset: 0)
                XCTAssertEqual(otherBody, Data(repeating: 98, count: 800), "Replay fits without evicting another request")
            }
        }
    }

    func testRefusedReplayBodyCanBeAbortedAndPurgedWithoutClosingTheArchive() async throws {
        let archive = PayloadArchive(root: try fixtureRoot(), beforeChunkWrite: { throw CocoaError(.fileWriteOutOfSpace) })
        let id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        var begin = metadata(id); begin["hostEpoch"] = .string("new")
        try await replay(archive, begin)
        var body = bodyPacket(id, Data(repeating: 97, count: 32_768)); body["hostEpoch"] = .string("new")
        do { try await archive.accept(body, workspace: "w"); XCTFail("The disk failure must refuse the body") } catch { }
        let abort: [String: WireValue] = ["type": .string("replay.abort"), "attemptId": .string(id), "hostEpoch": .string("new")]
        do { try await archive.accept(abort, workspace: "other"); XCTFail("Another workspace cannot abort recovery") } catch { }
        var stale = abort; stale["hostEpoch"] = .string("old")
        do { try await archive.accept(stale, workspace: "w"); XCTFail("Another epoch cannot abort recovery") } catch { }
        try await archive.accept(abort, workspace: "w")
        let settled = try await archive.metadata(attempt: id)
        XCTAssertEqual(settled["outcome"]?.string, "interrupted")
        XCTAssertEqual(settled["request"]?.object?["state"]?.string, "partial")
        try await archive.purge(attemptID: id)
        try await archive.clear(sessionID: "s")
    }

    func testReplayRefusesAFailedFinalTailInsteadOfAcknowledgingDataLoss() async throws {
        let archive = PayloadArchive(root: try fixtureRoot(), beforeChunkWrite: { throw CocoaError(.fileWriteOutOfSpace) })
        let id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 604800)
        try await replay(archive, metadata(id))
        try await archive.accept(bodyPacket(id, Data(repeating: 97, count: 600)), workspace: "w")
        do {
            try await archive.accept(packet("finish", metadata(id, completed: true, bytes: 600)), workspace: "w")
            XCTFail("A failed tail must retain the helper's complete recovery spool")
        } catch { }
    }

    func testBodyReplaySkipsStillKeepTerminalMetricsDiagnosticsAndLinks() async throws {
        for expired in [false, true] {
            let archive = PayloadArchive(root: try fixtureRoot(), now: { Date(timeIntervalSince1970: 1040) })
            let id = UUID().uuidString
            try await archive.configure(quota: nil, bodyRetention: expired ? 10 : 86400, metricRetention: 1000)
            var begin = metadata(id); begin["wallTimestamp"] = .number(1000)
            try await archive.begin(begin, workspace: "w")
            try await archive.append(attempt: id, kind: "request", offset: 0, bytes: Data("body".utf8))
            var old = begin; old["outcome"] = .string(expired ? "interrupted" : "completed")
            old["request"] = .object(["observedBytes": .number(4)])
            try await archive.finish(old); try await archive.reconcile()
            try await replay(archive, begin)
            try await archive.accept(bodyPacket(id, Data("body".utf8)), workspace: "w")
            var terminal = old; terminal["outcome"] = .string("completed")
            terminal["usage"] = .object(["output": .number(7)]); terminal["cost"] = .number(0.4)
            try await archive.accept(packet("finish", terminal), workspace: "w")
            terminal["operation"] = .object(["validation": .string("rejected-summary")])
            try await archive.accept(packet("metadata", terminal), workspace: "w")
            try await archive.accept(["type": .string("links"), "attemptId": .string(id), "outputMessageIds": .array([.string("reply")])], workspace: "w")
            try await archive.accept(["type": .string("replay.end"), "attemptId": .string(id)], workspace: "w")
            let final = try await archive.metadata(attempt: id), links = try await archive.linkedMessages(attemptID: id)
            XCTAssertEqual(final["outcome"]?.string, "completed")
            XCTAssertEqual(final["usage"]?.object?["output"]?.number, 7)
            XCTAssertEqual(final["cost"]?.number, 0.4)
            XCTAssertEqual(final["operation"]?.object?["validation"]?.string, "rejected-summary")
            XCTAssertEqual(final["request"]?.object?["state"]?.string, expired ? "expired" : "complete")
            XCTAssertEqual(links.output, ["reply"])
        }
    }

    func testMetadataOnlyReplayCannotRestoreExpiredTelemetry() async throws {
        for swept in [false, true] {
            let archive = PayloadArchive(root: try fixtureRoot(), now: { Date(timeIntervalSince1970: 1040) })
            let id = UUID().uuidString
            try await archive.configure(quota: nil, bodyRetention: 1000, metricRetention: 10)
            var old = metadata(id); old["wallTimestamp"] = .number(1000); old["hostEpoch"] = .string("old")
            try await archive.begin(old, workspace: "w")
            old["outcome"] = .string("completed"); try await archive.finish(old)
            if swept { try await archive.reconcile() }
            old["usage"] = .object(["output": .number(7)]); old["headers"] = .object(["x-request-id": .string("old-telemetry")])
            old["operation"] = .object(["validation": .string("old-diagnosis")])
            var replay = packet("metadata", old); replay["replay"] = .bool(true); replay["hostEpoch"] = .string("new")
            try await archive.accept(replay, workspace: "w")
            try await archive.reconcile()
            let final = try await archive.metadata(attempt: id)
            XCTAssertEqual(final["metricsRetained"]?.bool, false)
            XCTAssertEqual(final["metricsExpired"]?.bool, true)
            XCTAssertNil(final["usage"]); XCTAssertNil(final["headers"]); XCTAssertNil(final["operation"])
        }
    }

    func testBodyRecoveryAfterMetricExpiryDoesNotEvictItsOwnWriter() async throws {
        let archive = PayloadArchive(root: try fixtureRoot(), now: { Date(timeIntervalSince1970: 1040) })
        let id = UUID().uuidString, other = UUID().uuidString
        try await archive.configure(quota: 45_000, bodyRetention: 1000, metricRetention: 10)
        var old = metadata(id); old["wallTimestamp"] = .number(1000)
        try await archive.begin(old, workspace: "w")
        old["outcome"] = .string("interrupted"); try await archive.finish(old)
        try await archive.reconcile()
        try await archive.begin(metadata(other), workspace: "w")
        try await archive.append(attempt: other, kind: "request", offset: 0, bytes: Data(repeating: 98, count: 10_000))
        try await archive.finish(metadata(other, completed: true, bytes: 10_000))
        var begin = old; begin["outcome"] = .string("running")
        try await replay(archive, begin)
        let bytes = Data(repeating: 97, count: 40_000)
        try await archive.accept(bodyPacket(id, bytes.prefix(32_768)), workspace: "w")
        var tail = bodyPacket(id, bytes.suffix(7_232)); tail["offset"] = .number(32_768)
        try await archive.accept(tail, workspace: "w")
        var terminal = old; terminal["outcome"] = .string("completed")
        terminal["request"] = .object(["observedBytes": .number(40_000)])
        terminal["usage"] = .object(["output": .number(7)])
        try await archive.accept(packet("finish", terminal), workspace: "w")
        let actual = try await archive.completeBody(attemptID: id, body: "request"), final = try await archive.metadata(attempt: id)
        XCTAssertEqual(actual, bytes)
        XCTAssertEqual(final["metricsExpired"]?.bool, true)
        XCTAssertNil(final["usage"], "A body's longer retention cannot restore expired metrics")
    }

    func testNeverAcknowledgedBeginKeepsOnlyItsUnexpiredMetrics() async throws {
        let archive = PayloadArchive(root: try fixtureRoot(), now: { Date(timeIntervalSince1970: 1040) }), id = UUID().uuidString
        try await archive.configure(quota: nil, bodyRetention: 10, metricRetention: 1000)
        var old = metadata(id); old["wallTimestamp"] = .number(1000)
        try await replay(archive, old)
        try await archive.accept(bodyPacket(id, Data("expired".utf8)), workspace: "w")
        old["outcome"] = .string("completed"); old["usage"] = .object(["output": .number(7)])
        try await archive.accept(packet("finish", old), workspace: "w")
        try await archive.accept(["type": .string("replay.end"), "attemptId": .string(id)], workspace: "w")
        let final = try await archive.metadata(attempt: id)
        XCTAssertEqual(final["request"]?.object?["state"]?.string, "expired")
        XCTAssertEqual(final["request"]?.object?["retainedBytes"]?.number, 0)
        XCTAssertEqual(final["usage"]?.object?["output"]?.number, 7)
    }

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

private final class ReplayDiskFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = true
    func check() throws { lock.lock(); defer { lock.unlock() }; if failed { throw CocoaError(.fileWriteOutOfSpace) } }
    func recover() { lock.lock(); defer { lock.unlock() }; failed = false }
}
