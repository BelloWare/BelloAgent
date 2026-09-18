import Foundation

private final class KeychainCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
final class KeychainWorker: @unchecked Sendable {
    static let shared = KeychainWorker()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.belloware.PiApp.keychain")
    private var busy = false
    private let timeout: DispatchTimeInterval
    init(timeout: DispatchTimeInterval = .seconds(10)) { self.timeout = timeout }
    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !busy else { lock.unlock(); continuation.resume(throwing: HostError.failure("Keychain is still processing an earlier operation. No request was sent.")); return }
            busy = true; lock.unlock()
            let completion = KeychainCompletion(continuation)
            queue.async {
                let result = Result { try operation() }
                self.lock.lock(); self.busy = false; self.lock.unlock(); completion.finish(result)
            }
            // A synchronous Security IPC cannot safely be killed. Keep at most
            // one worker occupied, but release the UI's wait with a clear error.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(HostError.failure("Keychain did not respond. Review its access prompt or reopen the signed app. No provider request was sent.")))
            }
        }
    }
}
