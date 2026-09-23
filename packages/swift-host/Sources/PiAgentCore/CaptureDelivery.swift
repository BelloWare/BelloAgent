import Foundation

/// One outstanding 32 KiB payload page per helper, acknowledged only after the
/// native owner accepts it. A broken recorder has a finite deadline and never
/// causes an agent/tool replay. The helper never receives the vault payload key.
public actor CaptureDelivery {
    private let epoch: String, emit: @Sendable (JSON) -> Void
    private let acknowledgmentTimeoutNanoseconds: UInt64
    private var occupied = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var enabled = false, failed = false, closed = false
    private var pending: (String, CheckedContinuation<Bool, Never>)?
    private var deadline: Task<Void, Never>?
    /// Includes the packet awaiting acknowledgment and producers under backpressure.
    var pendingCount: Int { waiters.count + (occupied ? 1 : 0) }
    public init(epoch: String, acknowledgmentTimeoutNanoseconds: UInt64 = 3_000_000_000, emit: @escaping @Sendable (JSON) -> Void) {
        self.epoch = epoch; self.emit = emit; self.acknowledgmentTimeoutNanoseconds = acknowledgmentTimeoutNanoseconds
    }
    public func enable() { enabled = true }
    /// The helper is shutting down: its reader stopped acknowledging, and a
    /// stopped run still has a partial reply and its final state to write.
    /// The packet in flight and every later one are refused at once instead of
    /// holding that cleanup for the acknowledgment deadline.
    public func close() {
        closed = true
        let queued = waiters; waiters.removeAll()
        for waiter in queued { waiter.resume(returning: false) }
        if let pending { acknowledge(pending.0, accepted: false) }
    }
    public func send(_ packet: JSON) async -> Bool {
        guard enabled else { return true }
        guard !failed, !closed else { return false }
        if occupied {
            // Each producer already awaits its current packet. A busy healthy
            // recorder applies FIFO backpressure; session concurrency must not
            // make a begin/body packet look like a failed durable write.
            guard await withCheckedContinuation({ waiters.append($0) }) else { return false }
        } else { occupied = true }
        let accepted = await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            pending = (id, continuation)
            let timeout = acknowledgmentTimeoutNanoseconds
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                await self?.timedOut(id)
            }
            emit(["v": 1, "kind": "capture", "hostEpoch": JSON(epoch), "transferId": JSON(id), "packet": packet])
        }
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume(returning: true) }
        return accepted
    }
    public func acknowledge(_ id: String, accepted: Bool) {
        guard let pending, pending.0 == id else { return }
        self.pending = nil; deadline?.cancel(); deadline = nil; pending.1.resume(returning: accepted)
    }
    private func timedOut(_ id: String) {
        guard pending?.0 == id else { return }
        // A missing owner is a failed connection, not twenty independent slow
        // writes. Release every producer under the same deadline so Stop and
        // shutdown cannot wait one timeout per session. A rejected ACK remains
        // local to its packet and does not trip this circuit breaker.
        failed = true
        let queued = waiters; waiters.removeAll()
        for waiter in queued { waiter.resume(returning: false) }
        acknowledge(id, accepted: false)
    }
}
