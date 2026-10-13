import XCTest
@testable import PiApp

/// Only injected closures run here; no Security APIs or real Keychain items.
final class KeychainWorkerTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    func testQueuedTimeoutNeverRunsAfterTheQueueDrains() async throws {
        let worker = KeychainWorker(timeout: .milliseconds(120)), gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "first operation started"), finished = expectation(description: "first operation returned")
        let writes = Counter()
        defer { gate.signal() }
        let first = Task { try await worker.perform { entered.fulfill(); gate.wait(); finished.fulfill(); return 1 } }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await first.value; XCTFail("Expected a timeout") } catch { }
        for _ in 0..<3 {
            do { _ = try await worker.perform { writes.increment(); return 2 }; XCTFail("Expected a queued timeout") }
            catch { XCTAssertTrue(error.localizedDescription.contains("will not run"), error.localizedDescription) }
        }
        gate.signal(); await fulfillment(of: [finished], timeout: 2)
        var recovered = false
        for _ in 0..<100 {
            if (try? await worker.perform { 7 }) == 7 { recovered = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(recovered, "The skipped operations must release their queue slots")
        XCTAssertEqual(writes.value, 0, "An operation whose caller timed out before it started must never mutate storage")
    }

    func testStartedTimeoutReportsUncertaintyAndTheOperationMayFinish() async throws {
        let worker = KeychainWorker(timeout: .milliseconds(120)), gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "operation started"), finished = expectation(description: "late operation returned")
        let writes = Counter()
        defer { gate.signal() }
        let save = Task { try await worker.perform { entered.fulfill(); gate.wait(); writes.increment(); finished.fulfill() } }
        await fulfillment(of: [entered], timeout: 2)
        do { try await save.value; XCTFail("Expected a timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("may still complete"), error.localizedDescription) }
        XCTAssertEqual(writes.value, 0)
        gate.signal(); await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(writes.value, 1)
    }
}
