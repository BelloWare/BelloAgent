import AppKit

/// What the menu asks of the find bar in a chat (`SessionDisplay.findCommand`).
struct TranscriptFindCommand: Equatable {
    enum Kind: Equatable { case show, next, previous }
    var kind: Kind
    var serial: Int
}

/// The pane whose find bar a chat's find commands go to.
@MainActor protocol TranscriptFindHost: AnyObject {
    /// Whether the find bar is open, in a window.
    var findIsOpen: Bool { get }
    func retireFindNavigation()
    func resumeFindNavigation()
}

/// ⌘F in an open chat: a field over the top right of the transcript, the
/// number of matches and where the reader is among them, the way to the
/// previous and next match, and a way to close it. Return goes to the next
/// match, Shift-Return to the previous one, Escape closes.
@MainActor final class TranscriptFindBar: NSView {
    let field = PiKit.TextField(placeholder: "Find in conversation", icon: "magnifyingglass")
    let count = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    let previous: PiKit.IconButton
    let next: PiKit.IconButton
    let close: PiKit.IconButton
    private let box: PiKit.Box
    private let row = NSView()
    static let size = CGSize(width: 380, height: 44)

    init(query: @escaping (String) -> Void, step: @escaping (Int) -> Void, dismiss: @escaping () -> Void) {
        previous = PiKit.IconButton(symbol: "chevron.up", label: "Previous match", size: 24) { step(-1) }
        next = PiKit.IconButton(symbol: "chevron.down", label: "Next match", size: 24) { step(1) }
        close = PiKit.IconButton(symbol: "xmark", label: "Close find", size: 24) { dismiss() }
        box = PiKit.elevated(row, radius: 14)
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        field.onChange = query
        field.onSubmit = { step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1) }
        field.onCancel = dismiss
        for view in [field, count, previous, next, close] as [NSView] { row.addSubview(view) }
        addSubview(box)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Find in conversation")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    /// "3 of 41", "No matches", or nothing for an empty field; a count that
    /// is still growing as the rest of the chat is searched ends in "+".
    /// The match could not be read in (its page failed to load).
    func showUnreachable() {
        count.line = PiKit.Line("Couldn’t open match", font: PiKit.Font.caption, color: .piInkSecondary)
        needsLayout = true
    }
    func show(current: Int?, total: Int, searching: Bool, failed: Bool = false, query: String) {
        let text: String
        if query.isEmpty { text = "" }
        else if failed { text = "Search failed" }
        else if total == 0 { text = searching ? "Searching…" : "No matches" }
        else if let current { text = "\(current + 1) of \(total)\(searching ? "+" : "")" }
        else { text = "\(total)\(searching ? "+" : "") matches" }
        count.line = PiKit.Line(text, font: PiKit.Font.caption, color: .piInkSecondary)
        previous.isEnabled = total > 0; next.isEnabled = total > 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        box.frame = bounds.insetBy(dx: 4, dy: 4)
        let height = box.bounds.height, inner: CGFloat = 6
        var right = box.bounds.width - inner
        for button in [close, next, previous] {
            right -= 24
            button.frame = CGRect(x: right, y: (height - 24) / 2, width: 24, height: 24)
            right -= 2
        }
        let countWidth = min(90, ceil(count.intrinsicContentSize.width))
        right -= 6
        count.frame = CGRect(x: right - countWidth, y: (height - count.intrinsicContentSize.height) / 2, width: countWidth, height: count.intrinsicContentSize.height)
        right -= countWidth + (countWidth > 0 ? 6 : 0)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = CGRect(x: inner, y: (height - fieldHeight) / 2, width: max(60, right - inner), height: fieldHeight)
    }
}

/// The find bar's work: the matches across the whole chat — loaded or not,
/// from the conversation's own search — where the reader is among them, and
/// marking them in the transcript (`TranscriptHighlights`). Stepping to a
/// match the page does not hold reads it in and lands on it
/// (`revealInTranscript`).
///
/// A match is an occurrence in the text the transcript shows. The search
/// counts occurrences in each message's source (rendered assistant prose,
/// reasoning and agent tasks, results and deliveries); once a message's rows have
/// been on screen, its count is what its text shows (`reconcile`), so a
/// link's address or a heading the source has and the page does not draw
/// is never stepped to.
@MainActor final class TranscriptFindController {
    struct Match: Equatable {
        var messageID: String; var occurrence: Int
        var drawing: ContentHit.Drawing? = nil
        var omittedOutputs: Set<String> = []
        // A page can change where a receipt is drawn without changing the hit.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.messageID == rhs.messageID && lhs.occurrence == rhs.occurrence }
    }
    weak var pane: NativeTranscriptPane?
    private(set) var query = ""
    private(set) var matches: [Match] = []
    private(set) var current: Int?
    private(set) var searching = false
    private(set) var failed = false
    private var task: Task<Void, Never>?
    private var navigation: Task<Void, Never>?
    private var serial = 0
    private var needsResume = false
    /// When the conversation last changed under this query, while its
    /// results still wait to be counted again (`contentChanged`).
    private var contentChangedAt: TimeInterval?
    private var contentRefresh: Task<Void, Never>?
    /// How long the last whole search took, from its first read to its last.
    private var lastScan: TimeInterval = 0
    /// How long a changed conversation stays quiet before it is searched
    /// again. While the chat runs it also waits four times as long as the
    /// last search took, so a long chat changing in bursts spends at most
    /// about a fifth of its run searching again; once it stops, just this.
    static let contentSettle: TimeInterval = 0.5
    /// The conversation's search: hits after `start`, with their counts.
    var search: ((String, String, Int) async throws -> ContentSearch)?
    /// Brings a message into view in the transcript.
    var reveal: ((String, String) async -> Bool)?

    init(pane: NativeTranscriptPane) { self.pane = pane }

    func retireReaderNavigation() {
        if searching { task?.cancel(); task = nil; searching = false; needsResume = true }
        // Resuming searches the conversation as it is then.
        if needsResume { cancelContentRefresh() }
        stopNavigation()
    }
    func resumeReaderNavigation() {
        guard needsResume else { return }
        setQuery(query, restarting: true)
    }
    /// What the conversation presents — its rows or its tasks — changed while
    /// the bar is open. Its query is searched again once that has been quiet
    /// for a moment, as a refresh (`setQuery(restarting:)`): a reply
    /// streaming in is one change, not a search per token, and a search
    /// under way finishes before another starts. A search retired for
    /// another reader's navigation is left to resume with it.
    func contentChanged() {
        guard !query.isEmpty, !needsResume else { return }
        contentChangedAt = ProcessInfo.processInfo.systemUptime
        scheduleContentRefresh()
    }
    /// Seconds until the changed conversation has been quiet long enough,
    /// or nil once nothing waits.
    private var contentWait: TimeInterval? {
        guard let changed = contentChangedAt else { return nil }
        let quiet = pane?.session?.busy == true ? max(Self.contentSettle, lastScan * 4) : Self.contentSettle
        return changed + quiet - ProcessInfo.processInfo.systemUptime
    }
    private func scheduleContentRefresh() {
        guard contentRefresh == nil, contentChangedAt != nil, !searching, !needsResume else { return }
        contentRefresh = Task { [weak self] in
            // A run that stops shortens the wait: it is looked at again at
            // least every `contentSettle`.
            while let wait = self?.contentWait, wait > 0 {
                try? await Task.sleep(for: .seconds(min(wait, Self.contentSettle)))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.contentRefresh = nil
            guard self.contentChangedAt != nil, !self.searching, !self.needsResume, !self.query.isEmpty else { return }
            self.setQuery(self.query, restarting: true)
        }
    }
    private func cancelContentRefresh() {
        contentRefresh?.cancel(); contentRefresh = nil; contentChangedAt = nil
    }
    func setQuery(_ text: String, restarting: Bool = false) {
        guard text != query || restarting else { return }
        let refreshing = restarting && text == query
        needsResume = false
        query = text
        // This search reads the conversation as it is now.
        cancelContentRefresh()
        task?.cancel(); failed = false
        if !refreshing { stopNavigation(); matches = []; current = nil }
        guard !text.isEmpty, let session = pane?.session, let search else { searching = false; publish(focus: false); return }
        searching = true; publish(focus: false)
        let id = session.id
        task = Task { [weak self] in
            // Typing settles before the chat is searched.
            try? await Task.sleep(for: .milliseconds(150))
            let began = ProcessInfo.processInfo.systemUptime
            var start = 0
            var refreshed: [Match] = []
            while !Task.isCancelled {
                let found: ContentSearch
                do { found = try await search(id, text, start) }
                catch {
                    guard let self, !Task.isCancelled, self.query == text else { return }
                    self.searching = false; self.failed = true; self.publish(focus: false)
                    self.scheduleContentRefresh()
                    return
                }
                guard !Task.isCancelled, let self, self.query == text else { return }
                for hit in found.hits {
                    for occurrence in 0..<max(1, hit.count ?? 1) {
                        let match = Match(messageID: hit.id, occurrence: occurrence, drawing: hit.drawing, omittedOutputs: hit.omittedOutputs ?? [])
                        if refreshing { refreshed.append(match) } else { self.matches.append(match) }
                    }
                }
                guard let next = found.next else { break }
                if !refreshing, self.current == nil, !self.matches.isEmpty { self.current = self.firstNearReader(); self.publish(focus: true) }
                else { self.publish(focus: false) }
                start = next
            }
            guard let self, !Task.isCancelled, self.query == text else { return }
            self.searching = false
            self.lastScan = ProcessInfo.processInfo.systemUptime - began
            if refreshing {
                let selected = self.current.flatMap { self.matches.indices.contains($0) ? self.matches[$0] : nil }
                self.matches = refreshed
                self.current = selected.flatMap { refreshed.firstIndex(of: $0) } ?? (refreshed.isEmpty ? nil : self.firstNearReader())
                self.publish(focus: false)
            }
            else if self.current == nil, !self.matches.isEmpty { self.current = self.firstNearReader(); self.publish(focus: true) }
            else { self.publish(focus: false) }
            // Rows that changed while it ran are searched again once quiet.
            self.scheduleContentRefresh()
        }
    }
    /// The first match in a message on the reader's screen, else the first.
    private func firstNearReader() -> Int {
        let visible = pane?.session?.visibleMessageIDs?() ?? []
        return matches.firstIndex { visible.contains($0.messageID) } ?? 0
    }
    func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        current = ((current ?? (by > 0 ? -1 : 0)) + by + matches.count) % matches.count
        publish(focus: true)
    }
    func clear() {
        needsResume = false
        cancelContentRefresh()
        task?.cancel(); task = nil; stopNavigation(); query = ""; matches = []; current = nil; searching = false; failed = false
        pane?.document.highlights = TranscriptHighlights()
    }
    /// A read for a match no longer wanted must not land.
    private func stopNavigation() {
        navigation?.cancel(); navigation = nil
        pane?.session?.abandonReveal()
    }
    /// Message `id`'s text, all of it on screen, shows the query `rendered`
    /// times: its matches become exactly those.
    func reconcile(_ id: String, needle: String, rendered: Int) {
        // Only for this search, and never to nothing: a match the page cannot
        // draw (in a card it keeps closed) is still stepped to, at its row.
        guard needle == query, rendered > 0, let first = matches.firstIndex(where: { $0.messageID == id }) else { return }
        let end = matches[first...].firstIndex { $0.messageID != id } ?? matches.count
        guard end - first != rendered else { return }
        let wasCurrent = current.map { $0 >= first && $0 < end } ?? false
        let occurrence = current.map { $0 - first } ?? 0
        let original = matches[first]
        matches.replaceSubrange(first..<end, with: (0..<rendered).map { occurrence in
            var match = original; match.occurrence = occurrence; return match
        })
        if let index = current, index >= end { current = index - (end - first) + rendered }
        if wasCurrent {
            current = first + min(occurrence, rendered - 1); publish(focus: false, adoptingOccurrence: true)
        } else { publish(focus: false) }
    }
    /// Shows the count and marks the matches; `focus` also brings the current
    /// match into view.
    private func publish(focus: Bool, navigate: Bool = true, adoptingOccurrence: Bool = false) {
        guard let pane else { return }
        pane.findBar?.show(current: current, total: matches.count, searching: searching, failed: failed, query: query)
        var highlights = TranscriptHighlights(query: query)
        if let current, matches.indices.contains(current) {
            let match = matches[current]
            if focus { serial += 1 }
            // The search names the record; the page may draw it in another
            // message's row (a tool's result in its call's card).
            let captured = match.drawing.flatMap { owner in
                pane.session?.presentedMessages.contains { $0.id == owner.messageID && $0.tools?.contains { $0.id == owner.toolCallID } == true } == true ? owner : nil
            }
            let drawing = captured?.messageID ?? pane.page.drawingMessageID(for: match.messageID)
            // Drawn in another message's row, the occurrence is the record's
            // own: only the text of its call's card is counted.
            let scope = captured?.toolCallID ?? (drawing == match.messageID ? nil : pane.session?.messages.first { $0.id == match.messageID }?.toolCallID)
            if focus {
                highlights.focus = .init(messageID: drawing, needle: query, occurrence: match.occurrence,
                                         serial: serial, fromFind: true, scopeCall: scope, record: match.messageID, omittedOutputs: match.omittedOutputs)
            } else if var previous = pane.document.highlights.focus, previous.fromFind, previous.needle == query,
                      previous.record == match.messageID, previous.occurrence == match.occurrence || adoptingOccurrence {
                // Results and counts can change without a navigation request.
                // Never install a focus after nil: the document would reveal it.
                previous.occurrence = match.occurrence
                highlights.focus = previous
            }
            if focus, navigate, let session = pane.session {
                stopNavigation()
                let target = captured?.messageID ?? match.messageID
                _ = pane.page.revealContent(of: target, needle: query, call: scope)
                // A match whose rows are not on screen is landed on first; one
                // the page draws now is brought into view in place.
                if !pane.page.visibleMessageIDs().contains(drawing), let reveal {
                    let id = session.id
                    navigation = Task { [weak self] in
                        let landed = await reveal(id, target)
                        guard !Task.isCancelled, let self, let current = self.current,
                              self.matches.indices.contains(current), self.matches[current] == match else { return }
                        guard landed else {
                            if self.pane?.session?.revealFailure != nil { self.pane?.findBar?.showUnreachable() }
                            return
                        }
                        // Read in: the page can now say which row draws it,
                        // open what hides it, and bring it into view.
                        _ = self.pane?.page.revealContent(of: target, needle: self.query, call: scope)
                        self.publish(focus: true, navigate: false)
                    }
                }
            }
        }
        pane.document.highlights = highlights
    }
}

extension NativeTranscriptPane {
    func retireFindNavigation() { find.retireReaderNavigation() }
    func resumeFindNavigation() { if findBar != nil { find.resumeReaderNavigation() } }
}
