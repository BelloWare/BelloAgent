import Foundation

/// One ordering boundary for each chat's desktop input. Capture a ticket when
/// a snapshot is taken, before any Task, debounce or predecessor wait. A newer
/// ticket cancels the older pending snapshot of that payload. Text and reading
/// position are independent payloads: scrolling must not discard typing.
///
/// MetadataStore alone begins tickets. Beginning rejects superseded tickets
/// before revision reservation, conflict detection or recovery side effects.
/// Reservation, CAS and commit then run without suspension on the store actor;
/// an already-begun write finishes before the next write can begin. Compound
/// transactions and their conflict preservation reuse that same boundary.
/// Conditional operations prepare a candidate until they know they will write;
/// a read-only replay does not supersede typing. Captured submissions are
/// durable records, never replaceable snapshots.
final class OrderedDraftWriter: @unchecked Sendable {
    enum Payload: Hashable { case draft, anchor, conflict, submission }
    struct Key: Hashable { let id: String; let payload: Payload }
    final class Ticket: @unchecked Sendable {
        fileprivate let key: Key
        fileprivate var cancellation: (@Sendable () -> Void)?
        fileprivate var superseded = false
        fileprivate init(_ key: Key) { self.key = key }
    }
    private let lock = NSLock()
    private var pending: [Key: Ticket] = [:]
    private var preparations: [Key: [Ticket]] = [:]

    // Conditional operations retain their capture order without cancelling
    // typing for a receipt replay that ultimately performs no write. Their
    // first actual write begins after eligibility checks, before reservation.
    func prepare(_ id: String) -> Ticket {
        let ticket = Ticket(Key(id: id, payload: .draft))
        lock.withLock { preparations[ticket.key, default: []].append(ticket) }
        return ticket
    }
    private func supersede(_ tickets: [Ticket]) -> [@Sendable () -> Void] {
        tickets.compactMap {
            $0.superseded = true
            let cancel = $0.cancellation; $0.cancellation = nil
            return cancel
        }
    }

    func capture(_ id: String, payload: Payload = .draft) -> Ticket {
        let ticket = Ticket(Key(id: id, payload: payload))
        let cancel = lock.withLock {
            let previous = pending.updateValue(ticket, forKey: ticket.key)
            return supersede((previous.map { [$0] } ?? []) + (preparations.removeValue(forKey: ticket.key) ?? []))
        }
        for cancel in cancel { cancel() }
        return ticket
    }
    func cancelOnSupersession(_ ticket: Ticket, task: Task<Void, Never>) {
        let cancelled = lock.withLock {
            if pending[ticket.key] === ticket || preparations[ticket.key]?.contains(where: { $0 === ticket }) == true { ticket.cancellation = { task.cancel() } }
            return ticket.superseded
        }
        if cancelled { task.cancel() }
    }
    fileprivate func begin(_ ticket: Ticket, key: Key) throws {
        let cancellations: [@Sendable () -> Void] = try lock.withLock {
            guard ticket.key == key else { throw StoreError.staleRevision }
            if pending[key] === ticket {
                pending.removeValue(forKey: key); ticket.cancellation = nil
                return []
            }
            guard let waiting = preparations[key], let index = waiting.firstIndex(where: { $0 === ticket }) else { throw StoreError.staleRevision }
            let newer = Array(waiting.suffix(from: index + 1))
            preparations[key] = newer.isEmpty ? nil : newer
            ticket.cancellation = nil
            // A later real capture would already have retired this preparation.
            // A later conditional preparation may still become a read-only
            // replay, so it remains eligible after this synchronous commit.
            let previous = pending.removeValue(forKey: key)
            return supersede(Array(waiting.prefix(index)) + (previous.map { [$0] } ?? []))
        }
        for cancel in cancellations { cancel() }
    }
    func finish(_ ticket: Ticket) {
        lock.withLock {
            if pending[ticket.key] === ticket { pending.removeValue(forKey: ticket.key) }
            if let waiting = preparations[ticket.key] {
                let remaining = waiting.filter { $0 !== ticket }
                preparations[ticket.key] = remaining.isEmpty ? nil : remaining
            }
            ticket.cancellation = nil
        }
    }
}

extension MetadataStore {
    // This function is synchronous and actor-isolated, including nested
    // transactions. No writer can yield between reserving and committing.
    func orderedDraftWrite<T>(_ id: String, payload: OrderedDraftWriter.Payload = .draft,
                              ticket: OrderedDraftWriter.Ticket? = nil, _ operation: () throws -> T) throws -> T {
        let key = OrderedDraftWriter.Key(id: id, payload: payload)
        if ticket == nil, activeDraftWrites.contains(key) { return try operation() }
        let ticket = ticket ?? draftWriter.capture(id, payload: payload)
        defer { draftWriter.finish(ticket) }
        try draftWriter.begin(ticket, key: key)
        activeDraftWrites.insert(key)
        defer { activeDraftWrites.remove(key) }
        return try operation()
    }
}
