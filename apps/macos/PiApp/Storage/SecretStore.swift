import Foundation

struct KeychainTimeout: LocalizedError, Sendable {
    let started: Bool
    /// Finishes when the operation returns, even if that preceded the catch.
    /// No credentials or result values leave the worker through this signal.
    let completion: AsyncStream<Void>
    var errorDescription: String? {
        started
            ? "Keychain did not respond after starting the operation; it may still complete. Review its access prompt or reopen the signed app. No provider request was sent."
            : "Keychain did not respond before the operation could start. It was cancelled and will not run. Review its access prompt or reopen the signed app. No provider request was sent."
    }
}
/// Bookkeeping for one dispatched operation, guarded by the worker's lock.
private final class KeychainSlot<T: Sendable>: @unchecked Sendable {
    var continuation: CheckedContinuation<T, Error>?
    var started = false
    var completed = false
    var timedOut = false
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
}
/// The one place a synchronous Security call is made from, on its own serial
/// queue. Every mutable field below is read and written only under `lock`;
/// nothing else about the type crosses a thread.
final class KeychainWorker: @unchecked Sendable {
    static let shared = KeychainWorker()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.belloware.PiApp.keychain")
    /// Dispatched and not yet returned.
    private var inFlight = 0
    /// Of those, the ones whose caller has already given up waiting. A
    /// synchronous Security IPC cannot safely be killed, so a stalled call keeps
    /// its place on the serial queue — but it must not refuse every later
    /// operation for the rest of the session, which left Settings permanently
    /// reporting "still processing an earlier operation" with no way forward.
    private var stalled = 0
    private static let maximumStalled = 4
    private let timeout: DispatchTimeInterval
    init(timeout: DispatchTimeInterval = .seconds(10)) { self.timeout = timeout }
    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard inFlight - stalled == 0, stalled < Self.maximumStalled else {
                let waiting = stalled > 0
                lock.unlock()
                continuation.resume(throwing: HostError.failure(waiting
                    ? "Keychain has not answered an earlier request. Answer its access prompt — macOS can show it behind another window — or quit and reopen Bello Agent. No request was sent."
                    : "Keychain is still processing an earlier operation. No request was sent."))
                return
            }
            inFlight += 1; lock.unlock()
            let slot = KeychainSlot(continuation)
            let (resolution, resolved) = AsyncStream<Void>.makeStream()
            queue.async {
                self.lock.lock()
                guard !slot.timedOut else {
                    slot.completed = true; self.inFlight -= 1; self.stalled -= 1
                    self.lock.unlock(); resolved.finish(); return
                }
                // Start and timeout compete under the same lock. A caller
                // whose queued operation timed out can trust it never ran.
                slot.started = true; self.lock.unlock()
                let result = Result { try operation() }
                self.lock.lock()
                slot.completed = true; self.inFlight -= 1
                if slot.timedOut { self.stalled -= 1 }
                let continuation = slot.continuation; slot.continuation = nil
                self.lock.unlock()
                continuation?.resume(with: result)
                resolved.finish()
            }
            // Release the UI's wait with a clear error, and let a bounded number
            // of later operations queue behind the one that never answered.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lock.lock()
                guard !slot.completed else { self.lock.unlock(); return }
                slot.timedOut = true; self.stalled += 1
                let started = slot.started, continuation = slot.continuation; slot.continuation = nil
                self.lock.unlock()
                continuation?.resume(throwing: KeychainTimeout(started: started, completion: resolution))
            }
        }
    }
}
