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
    /// Close after the graceful outbox drain, or at its shutdown deadline.
    /// The deadline refuses an outstanding packet and releases its producer;
    /// ordinary slow capture has no timeout.
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
        defer {
            if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume(returning: true) }
        }
        guard let bytes = try? packet.data() else { return false }
        if bytes.count <= HostProtocol.frameBytes - 512 { return await sendFrame(["packet": packet]) }
        // Metadata can contain the complete provider usage object. Page the
        // encoded packet, including JSON escaping, without truncating capture.
        let packetID = UUID().uuidString
        for offset in stride(from: 0, to: bytes.count, by: 32 * 1024) {
            let end = min(bytes.count, offset + 32 * 1024)
            guard await sendFrame(["chunk": ["packetId": JSON(packetID), "offset": JSON(offset),
                "bytes": JSON(bytes.subdata(in: offset..<end).base64EncodedString()), "final": JSON(end == bytes.count)]]) else { return false }
        }
        return true
    }
    private func sendFrame(_ payload: JSON) async -> Bool {
        guard !closed else { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            pending = (id, continuation)
            var frame = payload
            frame["v"] = 1; frame["kind"] = "capture"; frame["hostEpoch"] = JSON(epoch); frame["transferId"] = JSON(id)
            emit(frame)
        }
    }
    public func acknowledge(_ id: String, accepted: Bool) {
        guard let pending, pending.0 == id else { return }
        self.pending = nil; pending.1.resume(returning: accepted)
    }
}
