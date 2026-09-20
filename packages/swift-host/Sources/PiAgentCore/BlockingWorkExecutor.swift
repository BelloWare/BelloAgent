import Foundation

/// Swift task cancellation does not propagate onto a Dispatch worker thread.
/// Blocking jobs carry this token and check it at safe interruption points.
///
/// Concurrency: `@unchecked` because the flag is plain mutable state. The
/// invariant is that `cancelled` is read and written only while `lock` is
/// held, and only ever goes from false to true.
final class BlockingWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Bounds both blocking worker occupancy and retained waiting operations. The
/// helper shares one pool; Swift actors and the cooperative task executor never
/// perform these blocking jobs. Waiting jobs are admitted in FIFO order.
///
/// Concurrency: `@unchecked` because the queue is plain mutable state shared
/// by callers and by Dispatch workers. The invariant is that `active` and
/// `waiting` are read and written only while `lock` is held and never while a
/// continuation is being resumed, that `maximumWorkers`/`maximumWaiting` are
/// immutable, and that each job resumes its continuation exactly once —
/// either by running, by being rejected, or by being removed from `waiting`.
final class BlockingWorkExecutor: @unchecked Sendable {
    static let shared = BlockingWorkExecutor()
    private struct Job: Sendable {
        let id: UUID
        let cancellation: BlockingWorkCancellation
        let execute: @Sendable () -> Void
        let reject: @Sendable (Error) -> Void
    }
    private let lock = NSLock()
    private let workers = DispatchQueue(label: "app.bello.file-workers", qos: .userInitiated, attributes: .concurrent)
    private let maximumWorkers: Int, maximumWaiting: Int
    private var active = 0, waiting: [Job] = []

    init(maximumWorkers: Int = 4, maximumWaiting: Int = 64) {
        precondition(maximumWorkers > 0 && maximumWaiting >= 0)
        self.maximumWorkers = maximumWorkers; self.maximumWaiting = maximumWaiting
    }
    var occupancy: (active: Int, waiting: Int) {
        lock.lock(); defer { lock.unlock() }; return (active, waiting.count)
    }
    func run<Value: Sendable>(_ operation: @escaping @Sendable (BlockingWorkCancellation) throws -> Value) async throws -> Value {
        let id = UUID(), cancellation = BlockingWorkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                enqueue(Job(id: id, cancellation: cancellation, execute: {
                    do {
                        try cancellation.checkCancellation()
                        let value = try operation(cancellation)
                        try cancellation.checkCancellation()
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }, reject: { continuation.resume(throwing: $0) }))
            }
        }, onCancel: {
            cancellation.cancel()
            self.cancelWaiting(id)
        })
    }
    private func enqueue(_ job: Job) {
        lock.lock()
        do { try job.cancellation.checkCancellation() }
        catch { lock.unlock(); job.reject(error); return }
        if active < maximumWorkers {
            active += 1; lock.unlock(); dispatch(job)
        } else if waiting.count < maximumWaiting {
            waiting.append(job); lock.unlock()
        } else {
            lock.unlock()
            job.reject(AgentError("tool_busy", "File workers and their waiting queue are full. Retry after an active read or search finishes."))
        }
    }
    private func cancelWaiting(_ id: UUID) {
        lock.lock()
        let job = waiting.firstIndex(where: { $0.id == id }).map { waiting.remove(at: $0) }
        lock.unlock()
        job?.reject(CancellationError())
    }
    private func dispatch(_ job: Job) {
        workers.async { [self] in
            job.execute()
            lock.lock()
            let next: Job?
            if waiting.isEmpty { active -= 1; next = nil }
            else { next = waiting.removeFirst() }
            lock.unlock()
            if let next { dispatch(next) }
        }
    }
}
