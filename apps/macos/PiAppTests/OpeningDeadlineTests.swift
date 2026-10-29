import XCTest
@testable import PiApp

final class OpeningDeadlineTests: XCTestCase {
    @MainActor func testAdvancingWorkCanOpenForLongerThanThirtySeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = OpeningTestClock()
        defer { clock.advance(.seconds(1000)) }
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) }, deadlineSleep: { try await clock.sleep($0) })
        defer { host.shutdown() }
        try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
        let epoch = try XCTUnwrap(host.epoch), connection = try XCTUnwrap(host.connectionID)
        host.receive(.frame(["v":.number(1),"kind":.string("ready"),"major":.number(1),"engine":.string("swift"),"engineVersion":.string("1.0.0"),"hostEpoch":.string(epoch),
            "capabilities":.array(["responses","mcp","steering","transport-capture","command-progress-v1","open-cancel-v1"].map(WireValue.string))]), connectionID: connection)
        let opening = Task { try await host.request("session.open", sessionID: "chat", commandID: "open") }
        for _ in 0..<1000 where clock.waits.isEmpty { await Task.yield() }
        for completed in 1...4 {
            clock.advance(.seconds(20))
            for _ in 0..<20 { await Task.yield() }
            host.receive(.frame(["v":.number(1),"kind":.string("command.progress"),"hostEpoch":.string(epoch),"commandId":.string("open"),
                "completed":.number(Double(completed)),"total":.number(10)]), connectionID: connection)
            for _ in 0..<20 { await Task.yield() }
        }
        host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(epoch),"commandId":.string("open"),"ok":.bool(true),"result":.object([:])]), connectionID: connection)
        _ = try await opening.value
        try await host.shutdownAndWait()
    }

    @MainActor func testStalledProgressFailsAtThirtySeconds() async throws { try await assertNoRenewal(.none) }
    @MainActor func testRepeatedProgressDoesNotRenew() async throws { try await assertNoRenewal(.repeated) }
    @MainActor func testRegressingProgressDoesNotRenew() async throws { try await assertNoRenewal(.regressing) }
    @MainActor func testChangedBoundDoesNotRenew() async throws { try await assertNoRenewal(.bound) }
    @MainActor func testStaleEpochDoesNotRenew() async throws { try await assertNoRenewal(.epoch) }
    @MainActor func testForeignCommandDoesNotRenew() async throws { try await assertNoRenewal(.command) }
    @MainActor func testLegacyHelperKeepsItsFixedDeadline() async throws { try await assertNoRenewal(.legacy) }

    private enum InvalidProgress { case none, repeated, regressing, bound, epoch, command, legacy }
    @MainActor private func assertNoRenewal(_ invalid: InvalidProgress) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = OpeningTestClock(); defer { clock.advance(.seconds(1000)) }
        let host = HostSupervisor(commandSender: { _ in }, deadlineSleep: { try await clock.sleep($0) })
        defer { host.shutdown() }
        try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
        let epoch = try XCTUnwrap(host.epoch), connection = try XCTUnwrap(host.connectionID)
        let capabilities = ["responses","mcp","steering","transport-capture"] + (invalid == .legacy ? [] : ["command-progress-v1","open-cancel-v1"])
        host.receive(.frame(["v":.number(1),"kind":.string("ready"),"major":.number(1),"engine":.string("swift"),"engineVersion":.string("1.0.0"),
            "hostEpoch":.string(epoch),"capabilities":.array(capabilities.map(WireValue.string))]), connectionID: connection)
        var outcome: Result<WireValue, Error>?
        let opening = Task { do { outcome = .success(try await host.request("session.open", sessionID: "chat", commandID: "open")) } catch { outcome = .failure(error) } }
        for _ in 0..<1000 where clock.waits.isEmpty { await Task.yield() }
        var progress: [String: WireValue] = ["v":.number(1),"kind":.string("command.progress"),"hostEpoch":.string(epoch),
            "commandId":.string("open"),"completed":.number(10),"total":.number(100)]
        host.receive(.frame(progress), connectionID: connection)
        for _ in 0..<20 { await Task.yield() }
        clock.advance(.seconds(29)); for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(outcome, "No deadline before 30 seconds")
        switch invalid {
        case .none: break
        case .repeated: host.receive(.frame(progress), connectionID: connection)
        default:
            progress["completed"] = .number(invalid == .regressing ? 9 : 20)
            if invalid == .epoch { progress["hostEpoch"] = .string("retired-epoch") }
            if invalid == .command { progress["commandId"] = .string("other-command") }
            if invalid == .bound { progress["total"] = .number(200) }
            host.receive(.frame(progress), connectionID: connection)
        }
        for _ in 0..<20 { await Task.yield() }
        clock.advance(.seconds(1)); for _ in 0..<1000 where outcome == nil { await Task.yield() }
        if case .failure(let error) = outcome { XCTAssertTrue(error.localizedDescription.contains("Acknowledgment timed out")) }
        else { XCTFail("Non-advancing, foreign or unnegotiated progress renewed the 30-second deadline") }
        host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(epoch),"commandId":.string("open"),"ok":.bool(true)]), connectionID: connection)
        await opening.value
        try await host.shutdownAndWait()
    }

    @MainActor func testCancelDiscardsSameTurnAndLateSuccessAndDisconnectSettlesOpen() async throws {
        for disconnect in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var frames: [[String: WireValue]] = []
            let host = HostSupervisor(commandSender: { frames.append($0) }); defer { host.shutdown() }
            try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
            let epoch = try XCTUnwrap(host.epoch), connection = try XCTUnwrap(host.connectionID)
            var outcome: Result<WireValue, Error>?
            let opening = Task { do { outcome = .success(try await host.request("session.open", sessionID: "chat", commandID: "open")) } catch { outcome = .failure(error) } }
            for _ in 0..<1000 where frames.isEmpty { await Task.yield() }
            if disconnect { host.receive(.failed("Generated disconnect"), connectionID: connection) }
            else {
                opening.cancel()
                // The cancellation mark must win even before its queued cleanup.
                host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(epoch),"commandId":.string("open"),"ok":.bool(true)]), connectionID: connection)
            }
            await opening.value
            if case .failure(let error) = outcome {
                if !disconnect { XCTAssertTrue(error is CancellationError) }
            } else { XCTFail("A cancelled or disconnected open was adopted") }
            await host.waitForCommandSettlement("open")
            XCTAssertFalse(host.hasOutstandingCommand("open"))
            try await host.shutdownAndWait()
        }
    }
}

/// Time only advances when a test asks. Cancelled sleeps may wake later, just
/// like a timer whose delivery was already queued; the supervisor must fence it.
@MainActor private final class OpeningTestClock {
    var now = Duration.zero
    var waits: [(Duration, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { waits.append((now + duration, $0)) }
        try Task.checkCancellation()
    }
    func advance(_ duration: Duration) {
        now += duration
        let ready = waits.filter { $0.0 <= now }; waits.removeAll { $0.0 <= now }
        for (_, continuation) in ready { continuation.resume() }
    }
    deinit { for (_, continuation) in waits { continuation.resume(throwing: CancellationError()) } }
}
