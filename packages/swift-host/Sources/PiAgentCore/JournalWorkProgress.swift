import Foundation

/// Actual journal work, shared by a worker and any readers waiting for it.
/// Nothing ticks while the worker is waiting on a gate or a lock. A command
/// has one fixed byte bound: validation plus replay for an open, or one
/// replay for a history read. Repeated passes cannot manufacture progress.
final class JournalWorkProgress: @unchecked Sendable {
    @TaskLocal static var current: JournalWorkProgress?
    struct Value: Sendable, Equatable { let completed: UInt64, total: UInt64 }
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private var total: UInt64?, validationBytes: UInt64 = 0
    private var latest: Value?
    private var checked: UInt64 = 0, reported: UInt64 = 0
    private var reportedAt = -Double.infinity
    private var observers: [UUID: @Sendable (Value) -> Void] = [:]

    init(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// The first pass fixes the denominator. A checkpoint can skip a verified
    /// prefix; a fallback or a growing suffix never resets the same command.
    func update(_ completed: UInt64, of bytes: UInt64, validating: Bool = false) {
        guard bytes > 0, bytes <= UInt64.max / 2 else { return }
        lock.lock()
        if total == nil { validationBytes = validating ? bytes : 0; total = bytes + validationBytes }
        let bound = total!, done = min(bound, completed + (validating ? 0 : validationBytes))
        guard done > checked, done - checked >= 65_536 || done == bound || latest == nil else { lock.unlock(); return }
        checked = done
        let now = clock()
        guard done > reported, now - reportedAt >= 0.25 else { lock.unlock(); return }
        let value = Value(completed: done, total: bound)
        reported = done; reportedAt = now; latest = value
        let callbacks = Array(observers.values); lock.unlock()
        for callback in callbacks { callback(value) }
    }
    func observe(_ callback: @escaping @Sendable (Value) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = callback; let latest = latest; lock.unlock()
        if let latest { callback(latest) }
        return id
    }
    func remove(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
    /// A reader forwards only this worker's advancing observations. Joining
    /// a shared load does not create a heartbeat or own its cancellation.
    func forward(to reader: JournalWorkProgress?) -> UUID? {
        guard let reader, reader !== self else { return nil }
        return observe { [weak reader] in reader?.accept($0) }
    }
    private func accept(_ value: Value) {
        lock.lock()
        guard value.completed > reported, total == nil || total == value.total else { lock.unlock(); return }
        total = value.total; reported = value.completed; latest = value
        let callbacks = Array(observers.values); lock.unlock()
        for callback in callbacks { callback(value) }
    }
}
