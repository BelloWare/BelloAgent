import Foundation

/// One bounded checkpoint in flight during a long opening. This owns no
/// journal claim or writer lock. Stopping fences publication before the
/// opening can release those locks or adopt its EOF replay.
final class ReplayCheckpointPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true, busy = false
    private var publishedThrough: UInt64 = 0
    private let url: URL, policy: CheckpointRefreshPolicy
    private let enqueue: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let beforeCapture: @Sendable () -> Void

    init(url: URL, policy: CheckpointRefreshPolicy,
         enqueue: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         beforeCapture: @escaping @Sendable () -> Void = {}) {
        self.url = url; self.policy = policy; self.enqueue = enqueue; self.beforeCapture = beforeCapture
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    func schedule(_ replay: JournalReplayConsumer) {
        lock.lock()
        guard active, !busy else { lock.unlock(); return }
        busy = true; lock.unlock()
        guard let snapshot = replay.settledCheckpointSnapshot(policy: policy) else { finished(); return }
        enqueue { [self] in
            defer { finished() }
            guard isActive else { return }
            beforeCapture()
            guard isActive else { return }
            do {
                var replay = snapshot
                guard let checkpoint = try replay.captureSettledCheckpoint(policy: policy), isActive else { return }
                let temporary = try checkpoint.stage(for: url, maximumBytes: policy.metadataBytes)
                defer { try? FileManager.default.removeItem(at: temporary) }
                // Stop and the atomic rename share a fence. A worker that
                // finishes after EOF/cancel cannot replace a newer cache.
                lock.lock(); defer { lock.unlock() }
                guard active else { return }
                try JournalCheckpoint.publish(staged: temporary, for: url)
                publishedThrough = checkpoint.start
            } catch { /* A failed shortcut keeps the previous checkpoint. */ }
        }
    }

    /// Never wait for capture/encoding. Only an already-entered atomic rename
    /// can precede this fence; no later publication or journal access follows.
    @discardableResult func stop() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        active = false
        return publishedThrough
    }

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    private func finished() { lock.lock(); busy = false; lock.unlock() }
}
