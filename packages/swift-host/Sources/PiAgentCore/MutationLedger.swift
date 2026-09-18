import Foundation

/// Recent command IDs retain their exact content binding. Older IDs become
/// bounded Bloom-filter tombstones for the rest of the host epoch: eviction
/// must never make a mutating command executable again. A rare false positive
/// refuses the command and requires reconciliation; it never retries effects.
struct MutationLedger {
    private let recentLimit: Int
    private var recent: [String: String] = [:], order: [String] = []
    private var tombstones: [UInt64]
    private var hasTombstones = false

    init(recentLimit: Int = 4096, tombstoneWords: Int = 131_072) {
        precondition(recentLimit > 0 && tombstoneWords > 0)
        self.recentLimit = recentLimit
        // 1 MiB in production, approximately 2e-8 false-positive probability
        // after 100,000 expired mutations with seven hash positions.
        tombstones = Array(repeating: 0, count: tombstoneWords)
    }

    func fingerprint(for id: String) -> String? { recent[id] }
    func mayHaveExpired(_ id: String) -> Bool {
        hasTombstones && positions(id).allSatisfy { tombstones[$0 / 64] & (UInt64(1) << ($0 % 64)) != 0 }
    }
    mutating func record(_ id: String, fingerprint: String) {
        if recent[id] == nil { order.append(id) }
        recent[id] = fingerprint
        if order.count > recentLimit {
            let expired = order.removeFirst(); recent.removeValue(forKey: expired)
            for position in positions(expired) { tombstones[position / 64] |= UInt64(1) << (position % 64) }
            hasTombstones = true
        }
    }

    private func positions(_ id: String) -> [Int] {
        let digest = Array(sha256(Data(id.utf8)).utf8)
        func word(_ offset: Int) -> UInt64 {
            digest[offset..<offset + 16].reduce(0) { ($0 << 4) | UInt64($1 <= 57 ? $1 - 48 : $1 - 87) }
        }
        let first = word(0), step = word(16) | 1, bits = UInt64(tombstones.count * 64)
        return (0..<7).map { Int((first &+ UInt64($0) &* step) % bits) }
    }
}
