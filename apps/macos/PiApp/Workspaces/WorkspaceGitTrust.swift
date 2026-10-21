import Foundation
import GitProcessSafety

/// Filesystem calls on a disconnected volume may not return even when their
/// caller is cancelled. Coalesce outstanding calls, cap their number, and let
/// reads use confinement when any root cannot be resolved promptly. Completed
/// paths are not cached: symlinks can change without a workspace revision.
final class WorkspaceGitTrustPaths: @unchecked Sendable {
    private final class Pending: @unchecked Sendable {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var result: String?
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let lock = NSLock()
    private var pending: [Data: Pending] = [:]
    private static let queue = DispatchQueue(label: "Bello.git.trust.paths", qos: .userInitiated, attributes: .concurrent)

    func resolve(_ paths: [String], invocation: GitInvocation,
                 canonicalize: @escaping @Sendable (String) -> String) async throws -> [String]? {
        try Task.checkCancellation(); try invocation.check()
        let id = UUID(), (events, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var jobs: [Pending] = []
        defer {
            completion.finish()
            lock.withLock { for job in jobs { job.waiters.removeValue(forKey: id) } }
        }
        for path in paths {
            try Task.checkCancellation(); try invocation.check()
            let key = Data(path.utf8)
            let job: Pending? = lock.withLock {
                if let current = pending[key] { current.waiters[id] = completion; return current }
                guard pending.count < 64 else { return nil }
                let job = Pending(); job.waiters[id] = completion; pending[key] = job
                Self.queue.async { [self] in
                    // A queued lookup that has already expired cannot help its
                    // read. An executing filesystem call stays off all actors.
                    let wanted = lock.withLock { !job.waiters.isEmpty && ProcessInfo.processInfo.systemUptime < job.deadline }
                    let result = wanted ? canonicalize(path) : nil
                    lock.withLock {
                        job.result = result
                        for waiter in job.waiters.values { waiter.yield(()) }
                        pending.removeValue(forKey: key)
                    }
                }
                return job
            }
            guard let job else { return nil }
            jobs.append(job)
        }
        let deadline = min(invocation.deadline, jobs.map(\.deadline).min() ?? invocation.deadline)
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                completion.finish()
            } catch {}
        }
        defer { timer.cancel() }
        completion.yield(())
        for await _ in events {
            try Task.checkCancellation(); try invocation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let results = lock.withLock { jobs.compactMap(\.result) }
            if results.count == paths.count { return results }
        }
        try Task.checkCancellation(); try invocation.check()
        return nil
    }
}
