import Foundation

/// Cancellation can race admission and transport installation. Installing an
/// action after invalidation cancels immediately; neither path holds the lock
/// while cancelling a transport.
public final class RequestPermit: @unchecked Sendable {
    public let attemptID: String
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (@Sendable () -> Void)?
    init(_ attemptID: String) { self.attemptID = attemptID }
    public func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        try Task.checkCancellation()
    }
    public func installCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); let stopped = cancelled; cancellation = action; lock.unlock()
        if stopped { action() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let action = cancellation; lock.unlock()
        action?()
    }
    func finish() { lock.lock(); cancellation = nil; lock.unlock() }
}

public struct AttemptSettlement: Sendable {
    public let scope: RequestScope
    public let observation: RequestObservation
    public let dispatched: Bool
}

public struct RequestLifecycle: Sendable {
    public let scope: RequestScope
    public var prepareMailboxCut: (@Sendable (ModelReply) async throws -> ModelReply?)? = nil
    public let admitAttempt: @Sendable (String) async throws -> RequestPermit
    public let willDispatch: @Sendable (String) async throws -> Void
    public let settleAttempt: @Sendable (AttemptSettlement) async throws -> Void
}
