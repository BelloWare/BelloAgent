import Foundation

/// Edits within one unchanged row order. A consumer may skip presentations:
/// it takes the union since its own stamp, or reconciles whole if it fell
/// behind the bounded log. The log retains indices, never old message text.
struct TranscriptChanges: Equatable, Sendable {
    struct Stamp: Equatable, Sendable {
        var epoch = UUID()
        var revision = 0
    }
    private struct Edit: Equatable, Sendable {
        var revision: Int
        var indices: [Int]
        var tail: Int?
    }
    private(set) var stamp = Stamp()
    private var edits: [Edit] = []
    mutating func record(_ indices: [Int]) {
        // An empty edit proves the plan stayed the same at a new
        // presentation; a copied snapshot alone does not prove that.
        append(indices: indices, tail: nil)
    }
    mutating func recordTail(from index: Int) { append(indices: [], tail: index) }
    private mutating func append(indices: [Int], tail: Int?) {
        stamp.revision += 1
        edits.append(Edit(revision: stamp.revision, indices: indices, tail: tail))
        if edits.count > 64 { edits.removeFirst(edits.count - 64) }
    }
    func indices(since previous: TranscriptChanges?) -> [Int]? {
        guard let edits = intervening(previous), !edits.contains(where: { $0.tail != nil }) else { return nil }
        return Set(edits.flatMap(\.indices)).sorted()
    }
    func tailStart(since previous: TranscriptChanges?) -> Int? {
        guard let edits = intervening(previous), edits.contains(where: { $0.tail != nil }) else { return nil }
        return edits.compactMap { edit in min(edit.tail ?? Int.max, edit.indices.min() ?? Int.max) }.min()
    }
    private func intervening(_ previous: TranscriptChanges?) -> [Edit]? {
        guard let previous, previous.stamp.epoch == stamp.epoch,
              previous.stamp.revision <= stamp.revision else { return nil }
        if previous.stamp.revision == stamp.revision { return [] }
        guard let first = edits.first, first.revision <= previous.stamp.revision + 1 else { return nil }
        return edits.filter { $0.revision > previous.stamp.revision }
    }
}
