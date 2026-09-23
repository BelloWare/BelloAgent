import Foundation

/// What a request added to the one before it: the longest run of items the two
/// share from the start, what follows it, and whether the earlier request's
/// history was rewritten (a compaction or an edit replaced some of it).
struct RequestDelta: Sendable, Equatable {
    /// Items the two requests share from the start.
    var shared: Int
    /// Items after the shared run: what is new in this request.
    var added: Int
    /// Items of the earlier request past the shared run, which this one no longer has.
    var dropped: Int
    var addedCharacters: Int
    var instructionsChanged: Bool
    var toolsChanged: Bool
    /// No earlier request to compare with.
    var first: Bool
    var rewritten: Bool { dropped > 0 }

    static func between(_ current: RequestDigests, previous: RequestDigests?) -> RequestDelta {
        guard let previous else {
            return RequestDelta(shared: 0, added: current.items.count, dropped: 0, addedCharacters: current.characters.reduce(0, +),
                                instructionsChanged: false, toolsChanged: false, first: true)
        }
        var shared = 0
        let limit = min(current.items.count, previous.items.count)
        while shared < limit, current.items[shared] == previous.items[shared] { shared += 1 }
        let added = current.items.count - shared
        let characters = current.characters.count == current.items.count ? current.characters[shared...].reduce(0, +) : 0
        return RequestDelta(shared: shared, added: added, dropped: previous.items.count - shared, addedCharacters: characters,
                            instructionsChanged: current.instructions != previous.instructions,
                            toolsChanged: current.tools != previous.tools, first: false)
    }

    func isNew(_ index: Int) -> Bool { index >= shared }

    /// `New since request 1: +3 items, 4.2K chars · 83% of input cached`.
    func banner(previous: String?, cachedShare: Double?) -> String {
        let cached = cachedShare.flatMap { share -> String? in
            guard share.isFinite, share >= 0 else { return nil }
            return MetricFormat.cacheHitPercent(read: min(share, 1) * 1_000_000, prompt: 1_000_000).map { $0 + "% of input cached" }
        }
        let items = "\(added) item" + (added == 1 ? "" : "s") + ", " + RequestDocument.charactersLabel(addedCharacters)
        var line: String
        if first || previous == nil { line = "First request: " + items }
        else if rewritten {
            line = "History rewritten since \(previous!): \(dropped) earlier item" + (dropped == 1 ? "" : "s") + " replaced · +" + items
        } else if added == 0 { line = "Same input as \(previous!)" }
        else { line = "New since \(previous!): +" + items }
        if let cached { line += " · " + cached }
        return line
    }

    /// What changed besides the items: rewritten history, instructions, tools.
    var notes: [String] {
        var notes: [String] = []
        if rewritten { notes.append("History rewritten: \(dropped) earlier item" + (dropped == 1 ? " is" : "s are") + " no longer sent; a compaction or an edit replaced them.") }
        if instructionsChanged { notes.append("The system prompt changed.") }
        if toolsChanged { notes.append("The tools changed.") }
        return notes
    }
}
