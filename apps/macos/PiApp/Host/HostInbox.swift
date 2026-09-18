import Foundation

// One scheduled main-actor delivery, with bounded decoded control frames and
// conflated presentation invalidations. A blocked native run loop cannot retain
// one Task per token/event indefinitely.
final class HostInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [TransportEvent] = []
    private var displays: [String: TransportEvent] = [:]
    private var bytes = 0
    private var scheduled = false
    private let deliver: @MainActor @Sendable ([TransportEvent]) -> Void
    init(deliver: @escaping @MainActor @Sendable ([TransportEvent]) -> Void) { self.deliver = deliver }
    func enqueue(_ event: TransportEvent) {
        lock.lock()
        if case .frame(let frame) = event, frame["type"]?.string == "session.changed", let id = frame["sessionId"]?.string, displays.count < 32 || displays[id] != nil { displays[id] = event }
        else {
            let size: Int
            if case .frame(let frame) = event { size = (try? JSONEncoder().encode(frame).count) ?? 1_048_576 } else { size = 128 }
            if pending.count >= 64 || bytes + size > 2_097_152 {
                pending = [.failed("The host control channel overflowed. Outcome uncertain; no command was replayed.")]; bytes = 128; displays.removeAll()
            } else { pending.append(event); bytes += size }
        }
        let schedule = !scheduled; scheduled = true; lock.unlock()
        if schedule { Task { @MainActor in self.deliver(self.drain()) } }
    }
    private func drain() -> [TransportEvent] {
        lock.lock(); defer { lock.unlock() }
        let values = pending + displays.values
        pending.removeAll(keepingCapacity: true); displays.removeAll(keepingCapacity: true); bytes = 0; scheduled = false
        return values
    }
}
