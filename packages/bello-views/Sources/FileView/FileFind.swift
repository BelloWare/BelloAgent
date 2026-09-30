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
    public func next() { ask(.next) }
    public func previous() { ask(.previous) }

    /// Ends finding: the search and every find stopped, the matches no longer
    /// drawn. The selection stays where it is.
    public func close() {
        stop()
        search?.cancel(); search = nil
        current = nil
        if view?.find === self { view?.find = nil }
        onChange = nil
    }

    // MARK: Searching

    private func restart() {
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
        current = nil
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
