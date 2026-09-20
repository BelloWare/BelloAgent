import Foundation

/// Shared only with a C progress callback. The lock guards the cancellation
/// bit; it never guards SQL, file I/O, or the capture writer.
final class ReportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// One connection confined to a serial GCD worker, not the writer actor or the
/// cooperative executor. Each admitted query opens/closes a short WAL snapshot;
/// no transaction survives a page click. Cancellation can stop SQLite sorting.
final class DashboardReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.belloware.reports", qos: .userInitiated)
    private let url: URL
    private var database: CaptureDatabase?
    private let lifecycle = NSLock()
    private var closed = false
    private var pending: [UUID: ReportCancellation] = [:]
    private func admit(_ id: UUID, token: ReportCancellation) -> Bool {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !closed else { return false }; pending[id] = token; return true
    }
    private func finished(_ id: UUID) { lifecycle.lock(); pending[id] = nil; lifecycle.unlock() }
    private func stopAdmissions() {
        lifecycle.lock(); closed = true; let tokens = Array(pending.values); lifecycle.unlock()
        tokens.forEach { $0.cancel() }
    }
    func close() async {
        stopAdmissions()
        await withCheckedContinuation { continuation in
            queue.async { [self] in database = nil; continuation.resume() }
        }
    }
    init(url: URL) { self.url = url }
    func run<T: Sendable>(consumer: String = "report", _ work: @escaping @Sendable (DashboardQueryEngine) throws -> T) async throws -> T {
        let token = ReportCancellation(), id = UUID()
        let admittedAt = ProcessInfo.processInfo.systemUptime
        let measuring = PerformanceProbe.recordingEnabled
        guard admit(id, token: token) else { throw CaptureFailure.unavailable }
        defer { finished(id) }
        let (value, queued, elapsed, statements, sorts) = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        guard !token.isCancelled else { throw CancellationError() }
                        let db: CaptureDatabase
                        if let database { db = database }
                        else { db = try CaptureDatabase(url: url, readOnly: true); database = db }
                        let beganAt = ProcessInfo.processInfo.systemUptime, previousStatements = db.statements, previousSorts = db.sorts
                        db.cancellation(token)
                        defer { db.cancellation(nil) }
                        let value = try db.readSnapshot { try work(DashboardQueryEngine(db: db)) }
                        guard !token.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: (value, (beganAt - admittedAt) * 1_000, (ProcessInfo.processInfo.systemUptime - beganAt) * 1_000, db.statements - previousStatements, db.sorts - previousSorts))
                    } catch { continuation.resume(throwing: token.isCancelled ? CancellationError() : error) }
                }
            }
        } onCancel: { token.cancel() }
        if measuring {
            await MainActor.run {
                PerformanceProbe.shared.observe(consumer + "QueryQueueMs", milliseconds: queued)
                PerformanceProbe.shared.observe(consumer + "QueryExecutionMs", milliseconds: elapsed)
                PerformanceProbe.shared.count(consumer + "SQLStatements", by: statements)
                PerformanceProbe.shared.count(consumer + "SQLSorts", by: sorts)
            }
        }
        return value
    }
}
