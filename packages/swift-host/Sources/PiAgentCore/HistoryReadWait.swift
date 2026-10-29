import Foundation

/// A single result with cancellation-safe continuation installation. Completing
/// before the waiter suspends, or racing completion with cancellation, resumes
/// it exactly once. All mutable state is protected by the lock.
private final class HistoryReadResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
}

/// Waiting for session-owned background work does not give a reader ownership
/// of that work. A cancelled waiter leaves immediately; the observer only
/// forwards its eventual result and owns no session or command slot.
enum HistoryReadWait {
    static func value<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) async throws -> Value {
        let result = HistoryReadResult<Value>()
        Task { result.finish(await task.result.mapError { $0 as Error }) }
        return try await withTaskCancellationHandler {
            let value = try await result.value()
            try Task.checkCancellation()
            return value
        } onCancel: { result.finish(.failure(CancellationError())) }
    }
}

/// One shared prerequisite, owned by its readers together. A last departing
/// reader retires it permanently and cancels its worker; another reader must
/// start a new load. Worker completion, not any reader, clears the actor's
/// handle. The lock covers task installation, retirement and all waiters.
final class SharedHistoryLoad: @unchecked Sendable {
    private let progress = JournalWorkProgress.current
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var result: Result<Void, Error>?
    private var waiters: [UUID: HistoryReadResult<Void>] = [:]
    private var retired = false
    func start(_ task: Task<Void, Never>) {
        lock.lock(); self.task = task; let retired = retired; lock.unlock()
        if retired { task.cancel() }
    }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); self.result = result; task = nil
        let waiting = Array(waiters.values); waiters.removeAll(); lock.unlock()
        for waiter in waiting { waiter.finish(result) }
    }
    func cancel() {
        lock.lock(); retired = true; let task = task; lock.unlock()
        task?.cancel()
    }
    /// Registration is synchronous, on the session actor: choosing a load
    /// and joining it cannot race its last reader's departure.
    func reader() -> (@Sendable () async throws -> Void)? {
        let id = UUID(), waiter = HistoryReadResult<Void>()
        lock.lock()
        if retired { lock.unlock(); return nil }
        if let result { lock.unlock(); waiter.finish(result) }
        else { waiters[id] = waiter; lock.unlock() }
        let observer = progress?.forward(to: JournalWorkProgress.current)
        return {
            defer { if let observer { self.progress?.remove(observer) } }
            try await withTaskCancellationHandler {
                try await waiter.value()
                try Task.checkCancellation()
            } onCancel: {
                waiter.finish(.failure(CancellationError()))
                self.cancelReader(id)
            }
        }
    }
    private func cancelReader(_ id: UUID) {
        lock.lock(); waiters.removeValue(forKey: id)
        let last = waiters.isEmpty && result == nil
        if last { retired = true }
        let task = last ? task : nil; lock.unlock()
        task?.cancel()
    }
}
