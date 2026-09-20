import Foundation

// One scheduled main-actor delivery, with bounded decoded control frames and
// conflated presentation invalidations. A blocked native run loop cannot retain
// one Task per token/event indefinitely.
final class HostInbox: @unchecked Sendable {
    // The supervisor admits up to 32 normal requests, each with a legal
    // 1 MiB reply. A busy main actor must not turn a healthy multi-chat burst
    // into host loss. The decoder already refuses any frame over
    // HostFrameDecoder.maximum, so this count is the byte budget: 64 frames
    // can hold at most 64 MiB. Weighing each frame as well meant encoding
    // every reply a second time — 2.8 ms for a full transcript page — to
    // reach a limit the count reaches first.
    private static let maximumControlFrames = 64
    private let lock = NSLock()
    private var pending: [TransportEvent] = []
    private var displays: [String: TransportEvent] = [:]
    private var scheduled = false
    private let deliver: @MainActor @Sendable ([TransportEvent]) -> Void
    init(deliver: @escaping @MainActor @Sendable ([TransportEvent]) -> Void) { self.deliver = deliver }
    func enqueue(_ event: TransportEvent) {
        lock.lock()
        if case .frame(let frame) = event, frame["type"]?.string == "session.changed", let id = frame["sessionId"]?.string, displays.count < 32 || displays[id] != nil { displays[id] = event }
        else if pending.count >= Self.maximumControlFrames {
            pending = [.failed("The host control channel overflowed. Outcome uncertain; no command was replayed.")]; displays.removeAll()
        } else { pending.append(event) }
        let schedule = !scheduled; scheduled = true; lock.unlock()
        if schedule { Task { @MainActor in self.deliver(self.drain()) } }
    }
    private func drain() -> [TransportEvent] {
        lock.lock(); defer { lock.unlock() }
        let values = pending + displays.values
        pending.removeAll(keepingCapacity: true); displays.removeAll(keepingCapacity: true); scheduled = false
        return values
    }
}
