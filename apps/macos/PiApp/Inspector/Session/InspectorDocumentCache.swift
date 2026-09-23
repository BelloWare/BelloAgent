import Foundation

/// Parsed request and response documents, least recently used first out.
/// A document is keyed by its attempt, its body and the revision of the bytes
/// it was built from, so a body that grew is parsed again and one that did
/// not is never parsed twice. Digests of earlier requests — all a delta needs —
/// are kept apart, small and many.
actor InspectorDocumentCache {
    static let shared = InspectorDocumentCache()

    struct Key: Hashable, Sendable {
        var attempt: String
        /// "request", "response" or "next".
        var kind: String
        /// The retained length and digest the document was built from.
        var revision: String
    }
    enum Value: Sendable {
        case request(RequestDocument)
        case response(ResponseDocument)
    }

    private let capacity: Int
    private let costLimit: Int
    private let digestCapacity: Int
    private var entries: [Key: (value: Value, cost: Int)] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var digestEntries: [Key: RequestDigests] = [:]
    private var digestOrder: [Key] = []
    private(set) var cost = 0

    init(capacity: Int = 24, costLimit: Int = 192 * 1_048_576, digestCapacity: Int = 512) {
        self.capacity = max(1, capacity); self.costLimit = max(1, costLimit); self.digestCapacity = max(1, digestCapacity)
    }

    func value(_ key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key, in: &order)
        return entry.value
    }
    func store(_ value: Value, for key: Key, cost: Int) {
        let cost = max(0, cost)
        guard cost <= costLimit else { return }
        if let old = entries.removeValue(forKey: key) { self.cost -= old.cost; order.removeAll { $0 == key } }
        while !order.isEmpty, entries.count >= capacity || self.cost + cost > costLimit {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { self.cost -= removed.cost }
        }
        entries[key] = (value, cost); order.append(key); self.cost += cost
    }
    func digests(_ key: Key) -> RequestDigests? {
        guard let value = digestEntries[key] else { return nil }
        touch(key, in: &digestOrder)
        return value
    }
    func storeDigests(_ digests: RequestDigests, for key: Key) {
        if digestEntries[key] != nil { digestOrder.removeAll { $0 == key } }
        while digestEntries.count >= digestCapacity, !digestOrder.isEmpty { digestEntries[digestOrder.removeFirst()] = nil }
        digestEntries[key] = digests; digestOrder.append(key)
    }
    var count: Int { entries.count }
    var digestCount: Int { digestEntries.count }
    func removeAll() {
        entries.removeAll(); order.removeAll(); cost = 0
        digestEntries.removeAll(); digestOrder.removeAll()
    }
    private func touch(_ key: Key, in list: inout [Key]) {
        guard list.last != key else { return }
        list.removeAll { $0 == key }; list.append(key)
    }
}
