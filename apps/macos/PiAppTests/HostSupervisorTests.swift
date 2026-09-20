import XCTest
import Darwin
@testable import PiApp

final class HostSupervisorTests: XCTestCase {
    @MainActor func testQueuedCancellationWinsOverSameTurnReplyAndStopBypassesFullQueue() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var sent: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { sent.append($0) }); defer { host.shutdown() }
        try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
        let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
        let active = (0..<32).map { index in Task { try await host.request("runtime.info", commandID: "active-\(index)") } }
        for _ in 0..<1000 where sent.count < 32 { await Task.yield() }
        XCTAssertEqual(sent.count, 32)
        let cancelled = Task { try await host.request("runtime.info", commandID: "cancelled") }
        for _ in 0..<1000 where host.queuedCommandCount == 0 { await Task.yield() }
        XCTAssertEqual(host.queuedCommandCount, 1)
        let following = Task { try await host.request("runtime.info", commandID: "following") }
        for _ in 0..<1000 where host.queuedCommandCount < 2 { await Task.yield() }
        XCTAssertEqual(host.queuedCommandCount, 2)
        let stop = Task { try await host.request("turn.stop", commandID: "stop") }
        for _ in 0..<1000 where sent.count < 33 { await Task.yield() }
        XCTAssertEqual(sent.last?["commandId"]?.string, "stop")
        host.receive(reply("stop", epoch: epoch), connectionID: connection)
        _ = try await stop.value
        // Do not yield between cancel and freeing the slot: asynchronous
        // cleanup alone could dispatch the cancelled request in this window.
        cancelled.cancel()
        host.receive(reply("active-0", epoch: epoch), connectionID: connection)
        XCTAssertFalse(sent.contains { $0["commandId"]?.string == "cancelled" })
        XCTAssertTrue(sent.contains { $0["commandId"]?.string == "following" })
        do { _ = try await cancelled.value; XCTFail("A cancelled queued command must remain undispatched") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await host.shutdownAndWait()
        for task in active { _ = await task.result }
        _ = await following.result
    }

    @MainActor func testTimedOutCommandsHoldHelperCapacityUntilTheirLateReply() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var sent: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { sent.append($0) }, acknowledgmentTimeout: .milliseconds(50))
        defer { host.shutdown() }
        try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
        let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
        let active = (0..<32).map { index in Task { try await host.request("runtime.info", commandID: "active-\(index)") } }
        for _ in 0..<1000 where sent.count < 32 { await Task.yield() }
        let queued = Task { try await host.request("runtime.info", commandID: "queued") }
        for _ in 0..<1000 where host.queuedCommandCount == 0 { await Task.yield() }
        for task in active {
            do { _ = try await task.value; XCTFail("The held acknowledgment must time out") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Outcome uncertain")) }
        }
        XCTAssertEqual(sent.count, 32, "A timed-out helper task still owns its original slot")
        XCTAssertEqual(host.queuedCommandCount, 1)
        host.receive(reply("active-0", epoch: epoch), connectionID: connection)
        XCTAssertEqual(sent.last?["commandId"]?.string, "queued")
        host.receive(reply("queued", epoch: epoch), connectionID: connection)
        _ = try await queued.value
        try await host.shutdownAndWait()
    }

    /// The app stops idle helpers itself. Sending the next message inside that
    /// window used to fail with "Project host is stopping" instead of starting
    /// a fresh helper, and a supervisor stopped before it ever had a transport
    /// refused every later connection for the rest of the session.
    @MainActor func testStoppingAnIdleHelperDoesNotRejectTheNextConnection() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let host = HostSupervisor(); defer { host.shutdown() }
        try await host.connect(cwd: root, state: state)
        _ = try await host.request("runtime.info")
        host.shutdown()
        try await host.connect(cwd: root, state: state)
        XCTAssertTrue(host.isReady)
        let restarted = try await host.request("runtime.info")
        XCTAssertEqual(restarted.object?["engine"]?.string, "swift")
        try await host.shutdownAndWait()

        let neverStarted = HostSupervisor()
        neverStarted.shutdown()
        try await neverStarted.connect(cwd: root, state: state)
        XCTAssertTrue(neverStarted.isReady, "a stop with nothing to stop must not wedge the supervisor shut")
        try await neverStarted.shutdownAndWait()
    }

    /// A helper killed mid-turn: the command fails with an explicit uncertain
    /// outcome, the loss is reported once, and repeated kill/restart rounds
    /// leave no descriptors and no orphaned helper processes behind.
    @MainActor func testKilledHelperRecoversWithoutLeakingDescriptorsOrProcesses() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let host = HostSupervisor(); defer { host.shutdown() }
        var losses = 0; host.onLoss = { losses += 1 }
        try await host.connect(cwd: root, state: state)
        _ = try await host.request("runtime.info")

        let inFlight = Task { try await host.request("runtime.info", commandID: "mid-turn") }
        for pid in Self.helperProcesses() { kill(pid, SIGKILL) }
        do { _ = try await inFlight.value; XCTFail("A killed helper cannot answer") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No request was replayed"), error.localizedDescription) }
        for _ in 0..<600 where host.connectionID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(host.isReady); XCTAssertNil(host.connectionID); XCTAssertEqual(losses, 1)

        let baseline = Self.openDescriptorCount()
        for _ in 0..<5 {
            try await host.connect(cwd: root, state: state)
            _ = try? await host.request("runtime.info")
            for pid in Self.helperProcesses() { kill(pid, SIGKILL) }
            for _ in 0..<600 where host.connectionID != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(host.connectionID, "every killed connection must be released before the next attempt")
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(Self.openDescriptorCount() - baseline, 4, "restart storms must not leak file descriptors")
        XCTAssertTrue(Self.helperProcesses().isEmpty, "no helper may outlive its supervisor")

        try await host.connect(cwd: root, state: state)
        let recovered = try await host.request("runtime.info")
        XCTAssertEqual(recovered.object?["engine"]?.string, "swift")
        try await host.shutdownAndWait()
    }

    private static func helperProcesses() -> [pid_t] {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe(); task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [] }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
    private static func openDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0..<Int32(getdtablesize()) where fcntl(descriptor, F_GETFD) != -1 { count += 1 }
        return count
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("host-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func reply(_ id: String, epoch: String) -> TransportEvent {
        .frame(["v": .number(1), "kind": .string("reply"), "commandId": .string(id), "hostEpoch": .string(epoch), "ok": .bool(true), "result": .object([:])])
    }

    @MainActor func testTwentySessionsCanBurstRefreshAndSendCommandsWithoutQueueRejection() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("host-twenty-sessions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostSupervisor(); defer { host.shutdown() }
        try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
        // Four simultaneous reads per chat reproduce refresh/status/context
        // overlap without a gateway. The helper still admits only 32 at once.
        let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
            for session in 0..<20 {
                for _ in 0..<4 {
                    group.addTask {
                        let result = try await host.request("runtime.info", sessionID: "session-\(session)")
                        return result.object?["engine"]?.string == "swift"
                    }
                }
            }
            var count = 0
            for try await valid in group { XCTAssertTrue(valid); count += 1 }
            return count
        }
        XCTAssertEqual(completed, 80); XCTAssertTrue(host.isReady)
        try await host.shutdownAndWait()
    }

    @MainActor func testRetiredConnectionCannotBecomeReadyOrStopItsReplacement() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("host-generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostSupervisor(); defer { host.shutdown() }
        let state = root.appendingPathComponent("state")
        try await host.connect(cwd: root, state: state)
        let retired = try XCTUnwrap(host.connectionID)
        let ready: [String: WireValue] = ["v": .number(1), "kind": .string("ready"), "major": .number(1),
            "engine": .string("swift"), "engineVersion": .string("1.0.0"), "hostEpoch": .string("late-epoch"),
            "capabilities": .array(["responses", "mcp", "steering", "transport-capture"].map(WireValue.string))]
        try await host.shutdownAndWait()
        host.receive(.frame(ready), connectionID: retired)
        host.receive(.failed("Late failure"), connectionID: retired)
        XCTAssertFalse(host.isReady); XCTAssertNil(host.connectionID)
        try await host.connect(cwd: root, state: state)
        let replacement = try XCTUnwrap(host.connectionID), epoch = host.epoch
        XCTAssertNotEqual(replacement, retired)
        var losses = 0; host.onLoss = { losses += 1 }
        host.receive(.frame(ready), connectionID: retired)
        host.receive(.failed("Late failure"), connectionID: retired)
        host.receive(.exited(1), connectionID: retired)
        XCTAssertTrue(host.isReady); XCTAssertEqual(host.connectionID, replacement)
        XCTAssertEqual(host.epoch, epoch); XCTAssertEqual(losses, 0)
        let reply = try await host.request("clock.sync")
        XCTAssertNotNil(reply.object?["monotonic"]?.number, "The replacement still answers commands")
        try await host.shutdownAndWait()
    }
}
