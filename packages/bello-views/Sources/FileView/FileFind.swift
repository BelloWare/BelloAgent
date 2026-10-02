import AppKit

// Finding in a file's text view, as a find bar drives it (`FileFind`): the
// query, as typed, is searched at once, and the first match at or after
// where finding began is shown; Next and Previous go on from the match shown,
// in the order asked, each from where the one before left off. A reader who
// moves the selection meanwhile has the last word: what was asked before is
// dropped, and finding goes on from where they put it. The view draws every
// match on its lines, and the one shown more strongly.

@MainActor public final class FileFind {
    public private(set) weak var view: FileTextView?
    public private(set) var query = ""
    public private(set) var matchCase = false
    /// The search for the query, while there is one to search for.
    public private(set) var search: FileSearch?
    /// The match shown.
    public private(set) var current: FileSearchHit?
    /// Told whenever the match shown, the search or its count changes.
    public var onChange: (() -> Void)?

    /// Where typing searches from: where finding began, or the match last
    /// gone to, or where the reader last put the selection.
    private var anchor: FileTextPosition
    private enum Step { case fromAnchor, next, previous }
    private var steps: [Step] = []
    private var working: Task<Void, Never>?
    /// The view's selection as this last left it: any other is the reader's.
    private var selectionSeen: Int
    private var showing = false

    public init(view: FileTextView) {
        self.view = view
        anchor = view.selectedRange.start
        selectionSeen = view.selectionRevision
        view.find?.close()
        view.find = self
    }

    /// Matches counted so far, and whether counting goes on.
    public var count: Int { search?.count ?? 0 }
    public var isCounting: Bool { search?.isCounting ?? false }
    /// Why the search stopped short: the file changed or failed.
    public var stopped: String? { search?.stopped }
    /// A find is under way.
    public var isFinding: Bool { working != nil }
    /// The query is longer than a query may be.
    public private(set) var isTooLong = false
    /// The match shown's place among all the matches, once counted.
    public var ordinal: Int? { current.flatMap { search?.ordinal(of: $0) } }

    /// What a view's selection gives a find bar to search for: its text, when
    /// it lies on one line and is short enough to be a query. A longer one is
    /// not read to find out.
    public static func query(fromSelectionIn view: FileTextView) -> String? {
        let (start, end) = view.selectedRange
        guard start.line == end.line, start != end, end.column - start.column <= FileMatcher.unitLimit,
              let text = view.selectedText, !FileMatcher(query: text, matchCase: true).matchesNothing else { return nil }
        return text
    }

    /// Searches for a new query, or with case matched or not: at once, the
    /// first match at or after where finding began shown.
    public func set(query: String, matchCase: Bool) {
        guard query != self.query || matchCase != self.matchCase else { return }
        self.query = query; self.matchCase = matchCase
        restart()
    }
    /// The view shows the file as read again: the same query, searched in
    /// the new text, from where the reader is now, and nothing moved. The
    /// match that was shown stays the one shown only if it is still exactly
    /// there — checked by reading that place, not by searching the whole
    /// file — and stays a candidate through further reloads until checked.
    /// Anything the reader does meanwhile (Next, Previous, moving the
    /// selection, a new query) wins over that check.
    public func textChanged() {
        let previous = current ?? keeping
        stop()
        search?.cancel(); search = nil; current = nil
        keeping = previous
        guard let view else { return }
        selectionSeen = view.selectionRevision
        // The selection as the view clamped it to the new text: a line gone
        // with a shorter file is no place to search from.
        anchor = view.selectedRange.start
        let matcher = FileMatcher(query: query, matchCase: matchCase)
        isTooLong = matcher.isTooLong
        search = matcher.matchesNothing ? nil : view.source.search(matcher)
        search?.onChange = { [weak self] in self?.searchChanged() }
        view.needsDisplay = true
        // Where matches fall, for a query that can overlap itself, depends
        // on matching from its line's start: read from there, within a bound.
        if let previous, let search, previous.line < view.source.lineCount,
           case let from = matcher.overlaps ? FileTextPosition(line: previous.line, column: 0) : previous.start,
           previous.columns.upperBound - from.column <= Self.keepingReach {
            let source = view.source
            working = Task { [weak self] in
                let there: String? = await withCheckedContinuation { done in
                    source.fetch(from: from, to: previous.end) { done.resume(returning: $0) }
                }
                guard let self, !Task.isCancelled, self.search === search else { return }
                let at = previous.columns.lowerBound - from.column
                // Answered either way only when the text was read and the
                // search ran its course: a file changed or unreadable again
                // meanwhile leaves the match to check in the next text.
                var answered = there != nil
                if let there, search.matcher.matches(in: there).contains(at..<(at + previous.columns.count)) {
                    // A match starts exactly there: the search's first at or
                    // after it is that one, found at once.
                    let hit = await search.find(from: previous.start, forward: true)
                    guard !Task.isCancelled, self.search === search else { return }
                    if let hit, hit.line == previous.line, hit.columns == previous.columns {
                        self.current = hit; self.anchor = hit.start
                        self.view?.needsDisplay = true
                    } else if hit == nil, search.stopped != nil || search.isStale {
                        answered = false
                    }
                }
                if answered { self.keeping = nil }
                self.working = nil
                self.onChange?()
                self.run()
            }
        } else {
            keeping = nil
        }
        onChange?()
    }
    /// The match shown before a reload, until the new text has been checked
    /// for it; let go of when the reader moves on.
    private var keeping: FileSearchHit?
    /// How far along its line a kept match is checked (UTF-16 units).
    static let keepingReach = 1 << 16
    /// A find bar left open while the file could not be read, now that it
    /// can: its query and case, searched as `textChanged` searches.
    public func resume(query: String, matchCase: Bool) {
        self.query = query; self.matchCase = matchCase
        textChanged()
    }
    public func next() { ask(.next) }
    public func previous() { ask(.previous) }

    /// Ends finding: the search and every find stopped, the matches no longer
    /// drawn. The selection stays where it is.
    public func close() {
        keeping = nil
        stop()
        search?.cancel(); search = nil
        current = nil
        if view?.find === self { view?.find = nil }
        onChange = nil
    }

    // MARK: Searching

    private func restart() {
        keeping = nil
        stop()
        search?.cancel()
        current = nil
        let matcher = FileMatcher(query: query, matchCase: matchCase)
        isTooLong = matcher.isTooLong
        search = matcher.matchesNothing ? nil : view?.source.search(matcher)
        search?.onChange = { [weak self] in self?.searchChanged() }
        view?.needsDisplay = true
        if search != nil { ask(.fromAnchor) }
        onChange?()
    }
    private func searchChanged() {
        guard let search else { return }
        // Read again (as Latin-1): the same query in the text as it is now.
        if search.isStale { restart(); return }
        // Matches along a long line may be drawn once the count passes them.
        if search.matcher.overlaps { view?.needsDisplay = true }
        onChange?()
    }
    private func stop() {
        working?.cancel(); working = nil
        steps = []
    }

    // MARK: Going to matches

    private func ask(_ step: Step) {
        guard search != nil else { return }
        keeping = nil
        steps.append(step)
        run()
    }
    /// The reader moved the selection: what was asked before is dropped.
    func selectionChanged() {
        guard !showing, let view, view.selectionRevision != selectionSeen else { return }
        readerMoved()
    }
    /// The reader went somewhere of their own accord, whether or not the
    /// selection moved (sent to the file's start where the insertion point
    /// already was): what was asked before is dropped, and finding goes on
    /// from there.
    func readerMoved() {
        guard !showing, let view else { return }
        selectionSeen = view.selectionRevision
        anchor = view.selectedRange.start
        current = nil; keeping = nil
        stop()
        view.needsDisplay = true
        onChange?()
    }
    private func run() {
        guard working == nil, !steps.isEmpty, let search, let view else { return }
        let step = steps.removeFirst()
        let (start, end) = view.selectedRange
        let from: FileTextPosition, forward: Bool
        switch step {
        case .fromAnchor: from = anchor; forward = true
        case .next: from = current?.end ?? end; forward = true
        case .previous: from = current?.start ?? start; forward = false
        }
        working = Task { [weak self] in
            let hit = await search.find(from: from, forward: forward)
            guard let self, !Task.isCancelled, self.search === search else { return }
            self.working = nil
            self.found(hit)
        }
    }
    private func found(_ hit: FileSearchHit?) {
        guard let view else { return }
        current = hit
        if let hit {
            showing = true
            view.show(match: hit)
            showing = false
            selectionSeen = view.selectionRevision
            anchor = hit.start
        } else {
            // None anywhere: nothing more to go to.
            steps = []
        }
        view.needsDisplay = true
        onChange?()
        run()
    }
}
