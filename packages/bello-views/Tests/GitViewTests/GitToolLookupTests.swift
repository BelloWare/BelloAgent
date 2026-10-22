import XCTest
@testable import GitView
@testable import GitProcessSafety

final class GitToolLookupTests: ViewsTestCase {
    private final class Gate: @unchecked Sendable {
        private let condition = NSCondition()
        private var count = 0, released = false
        var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
        func enter() {
            condition.lock(); count += 1
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }

    func testFailedLookupCoolsDownThenRetries() async throws {
        let binary = try GitToolLookup.current.get(invocation: GitInvocation())
        let gate = Gate(); gate.release()
        let lookup = GitToolLookup { _ in
            gate.enter()
            if gate.calls == 1 { throw GitToolLookupError.unavailable }
            return binary
        }
        for _ in 0..<2 {
            XCTAssertThrowsError(try lookup.get(invocation: GitInvocation())) {
                XCTAssertTrue($0 is GitToolLookupError)
            }
        }
        XCTAssertEqual(gate.calls, 1, "A failure must not start a tight retry loop")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(try lookup.get(invocation: GitInvocation()), binary)
        XCTAssertEqual(try lookup.get(invocation: GitInvocation()), binary)
        XCTAssertEqual(gate.calls, 2)
    }

    @MainActor func testSharedToolLookupHonorsEachReadDeadlineAndCancellation() async throws {
        let previous = GitToolLookup.current, gate = Gate()
        let binary = try previous.get(invocation: GitInvocation())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-tool-lookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { gate.release(); GitToolLookup.current = previous; try? FileManager.default.removeItem(at: root) }
        GitToolLookup.current = GitToolLookup { _ in gate.enter(); return binary }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.release() }
        let service = GitService(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        var timedOut = false, cancelled = false, secondDone = false
        let first = Task {
            defer { timedOut = true }
            return try await service.run(["--version"], in: root.path, timeout: 0.08)
        }
        let readyBy = ProcessInfo.processInfo.systemUptime + 1
        while gate.calls == 0, ProcessInfo.processInfo.systemUptime < readyBy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.calls, 1, "The fixture entered tool discovery")
        let second = Task {
            defer { secondDone = true }
            return try await service.run(["--version"], in: root.path, timeout: 0.08)
        }
        let third = Task {
            defer { cancelled = true }
            return try await service.run(["--version"], in: root.path, timeout: 1)
        }
        try await Task.sleep(for: .milliseconds(20)); third.cancel()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(timedOut, "The read deadline includes initial tool discovery")
        XCTAssertTrue(secondDone, "Each waiter has its own deadline")
        XCTAssertTrue(cancelled, "Cancellation must not wait for tool discovery")
        XCTAssertEqual(gate.calls, 1, "A stalled lookup is shared, not restarted per read")
        gate.release()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Expired discovery succeeded") }
            catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(error)") }
        }
        do { _ = try await third.value; XCTFail("Cancelled discovery succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let output = try await service.run(["--version"], in: root.path)
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.text.contains("git version"))
        XCTAssertEqual(gate.calls, 1, "A completed lookup is cached")
    }
}
