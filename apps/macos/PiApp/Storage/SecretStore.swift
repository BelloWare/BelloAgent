import Foundation

/// Hands one continuation to whichever finishes first: the Security call on
/// the keychain queue, or the timeout on another. The lock makes the handover
/// exactly once, so the continuation is never resumed twice or dropped.
private final class KeychainCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
/// Bookkeeping for one dispatched operation, guarded by the worker's lock.
private final class KeychainSlot: @unchecked Sendable {
    var completed = false
    var timedOut = false
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
            let completion = KeychainCompletion(continuation), slot = KeychainSlot()
            queue.async {
                let result = Result { try operation() }
                self.lock.lock()
                slot.completed = true; self.inFlight -= 1
                if slot.timedOut { self.stalled -= 1 }
                self.lock.unlock()
                completion.finish(result)
            }
            // Release the UI's wait with a clear error, and let a bounded number
            // of later operations queue behind the one that never answered.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lock.lock()
                let stalling = !slot.completed
                if stalling { slot.timedOut = true; self.stalled += 1 }
                self.lock.unlock()
                guard stalling else { return }
                completion.finish(.failure(HostError.failure("Keychain did not respond. Review its access prompt or reopen the signed app. No provider request was sent.")))
            }
        }
    }
}
