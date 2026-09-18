import Foundation

/// One outstanding 32 KiB payload page per helper, acknowledged only after the
/// native owner accepts it. A broken recorder has a finite deadline and never
/// causes an agent/tool replay. The helper never receives the vault payload key.
public actor CaptureDelivery {
    private let epoch: String, emit: @Sendable (JSON) -> Void
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enabled = false
    private var pending: (String, CheckedContinuation<Bool, Never>)?
    private var deadline: Task<Void, Never>?
    public init(epoch: String, emit: @escaping @Sendable (JSON) -> Void) { self.epoch = epoch; self.emit = emit }
    public func enable() { enabled = true }
    public func send(_ packet: JSON) async -> Bool {
        guard enabled else { return true }
        if occupied {
            guard waiters.count < 16 else { return false }
            await withCheckedContinuation { waiters.append($0) }
        } else { occupied = true }
        let accepted = await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            pending = (id, continuation)
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                await self?.acknowledge(id, accepted: false)
            }
            emit(["v": 1, "kind": "capture", "hostEpoch": JSON(epoch), "transferId": JSON(id), "packet": packet])
        }
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
        return accepted
    }
    public func acknowledge(_ id: String, accepted: Bool) {
        guard let pending, pending.0 == id else { return }
        self.pending = nil; deadline?.cancel(); deadline = nil; pending.1.resume(returning: accepted)
    }
}
