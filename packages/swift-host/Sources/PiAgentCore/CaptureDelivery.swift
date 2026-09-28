import Foundation

/// One outstanding 32 KiB payload page per helper, acknowledged only after the
/// native owner accepts it. There is no deadline: a slow owner (a busy disk, a
/// large log) delays the pages behind it and never turns capture off, because
/// a deadline that switched capture off for good lost every later request of
/// every chat on this helper. The model request never waits on this delivery
/// (`TraceStore` queues its packets). The helper never receives the vault
/// payload key.
public actor CaptureDelivery {
    private let epoch: String, emit: @Sendable (JSON) -> Void
    private var occupied = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var enabled = false, closed = false
    private var pending: (String, CheckedContinuation<Bool, Never>)?
    /// Includes the packet awaiting acknowledgment and producers waiting behind it.
    var pendingCount: Int { waiters.count + (occupied ? 1 : 0) }
    public init(epoch: String, emit: @escaping @Sendable (JSON) -> Void) {
        self.epoch = epoch; self.emit = emit
    }
    public func enable() { enabled = true }
    /// The helper is shutting down: its reader stopped acknowledging, and a
    /// stopped run still has a partial reply and its final state to write.
    /// The packet in flight and every later one are refused at once.
    public func close() {
        closed = true
        let queued = waiters; waiters.removeAll()
        for waiter in queued { waiter.resume(returning: false) }
        if let pending { acknowledge(pending.0, accepted: false) }
    }
    public func send(_ packet: JSON) async -> Bool {
        guard enabled else { return true }
        guard !closed else { return false }
        if occupied {
            // One page in flight at a time, in order.
            guard await withCheckedContinuation({ waiters.append($0) }) else { return false }
        } else { occupied = true }
        let accepted = await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            pending = (id, continuation)
            emit(["v": 1, "kind": "capture", "hostEpoch": JSON(epoch), "transferId": JSON(id), "packet": packet])
        }
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume(returning: true) }
        return accepted
    }
    public func acknowledge(_ id: String, accepted: Bool) {
        guard let pending, pending.0 == id else { return }
        self.pending = nil; pending.1.resume(returning: accepted)
    }
}
