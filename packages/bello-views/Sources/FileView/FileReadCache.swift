import Foundation

/// What is kept of a file's text once read, and what keeps it (`FileDocument`):
/// its runs of lines (pages) and its long lines' windows, each costing its
/// text and a little more, within a budget.
///
/// Two things keep an entry whatever the budget, each by name: the screen
/// shown (its pins, replaced by the next screen's), and holds (a read waiting
/// to be answered, kept until it is let go). Everything else goes, the one
/// used longest ago first, while more is kept than the budget; an entry just
/// put is not let go of by its own coming, so whoever asked for it can read it.
struct FileReadCache {
    enum Key: Hashable, Sendable {
        case page(Int)
        case window(line: Int, mark: Int)
    }
    enum Payload {
        /// A run of lines from its first.
        case page(firstLine: Int, lines: [String])
        /// A long line's text from one mark to the next.
        case window(NSString)
    }
    private struct Entry { let payload: Payload; let cost: Int; var used: Int }
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    private(set) var cost = 0
    let budget: Int
    private var screen: Set<Key> = []
    private var holds: [Int: Set<Key>] = [:]
    private var lastHold = 0

    init(budget: Int) { self.budget = budget }

    /// A tick of the clock: when something was used or asked for.
    mutating func tick() -> Int { clock += 1; return clock }
    func contains(_ key: Key) -> Bool { entries[key] != nil }
    /// A kept entry, marked used unless it is only looked at.
    mutating func payload(_ key: Key, use: Bool) -> Payload? {
        guard var entry = entries[key] else { return nil }
        if use { entry.used = tick(); entries[key] = entry }
        return entry.payload
    }
    /// Keeps an entry, as used when it was last asked for, and lets go of
    /// others while more is kept than the budget.
    mutating func put(_ key: Key, _ payload: Payload, cost: Int, asked: Int) {
        remove(key)
        entries[key] = Entry(payload: payload, cost: cost, used: asked)
        self.cost += cost
        evict(sparing: key)
    }
    mutating func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { cost -= entry.cost }
    }
    /// Lets go of everything, holds and pins included: another reading of
    /// the file. Holds taken before are let go of as they are released.
    mutating func removeAll() { entries = [:]; cost = 0; screen = []; holds = [:] }

    /// The screen shown now: what it needs is kept, until another is shown.
    mutating func pin(screen keys: Set<Key>) {
        screen = keys
        evict()
    }
    /// A read waiting to be answered: what it needs is kept until let go of.
    mutating func hold(_ keys: Set<Key>) -> Int {
        lastHold += 1
        holds[lastHold] = keys
        return lastHold
    }
    /// Lets go of a hold; again, or after everything went, is nothing.
    mutating func release(_ hold: Int) {
        if holds.removeValue(forKey: hold) != nil { evict() }
    }
    /// What the screen and the holds keep.
    var kept: Set<Key> { holds.values.reduce(into: screen) { $0.formUnion($1) } }

    private mutating func evict(sparing just: Key? = nil) {
        guard cost > budget else { return }
        let kept = kept
        for (key, _) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            guard cost > budget else { return }
            guard !kept.contains(key), key != just else { continue }
            remove(key)
        }
    }

    /// Test seams: how many pages are kept, and how many holds.
    var pageCount: Int { entries.keys.reduce(0) { if case .page = $1 { return $0 + 1 }; return $0 } }
    var holdCount: Int { holds.count }
}
