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
/// counts occurrences in each message's source; once a message's rows have
/// been on screen, its count is what its text shows (`reconcile`), so a
/// link's address or a heading the source has and the page does not draw
/// is never stepped to.
@MainActor final class TranscriptFindController {
    struct Match: Equatable { var messageID: String; var occurrence: Int }
    weak var pane: NativeTranscriptPane?
    private(set) var query = ""
    private(set) var matches: [Match] = []
    private(set) var current: Int?
    private(set) var searching = false
    private(set) var failed = false
    private var task: Task<Void, Never>?
    private var navigation: Task<Void, Never>?
    private var serial = 0
    /// The conversation's search: hits after `start`, with their counts.
    var search: ((String, String, Int) async throws -> ContentSearch)?
    /// Brings a message into view in the transcript.
    var reveal: ((String, String) async -> Bool)?

    init(pane: NativeTranscriptPane) { self.pane = pane }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        task?.cancel(); stopNavigation(); matches = []; current = nil; failed = false
        guard !text.isEmpty, let session = pane?.session, let search else { searching = false; publish(focus: false); return }
        searching = true; publish(focus: false)
        let id = session.id
        task = Task { [weak self] in
            // Typing settles before the chat is searched.
            try? await Task.sleep(for: .milliseconds(150))
            var start = 0
            while !Task.isCancelled {
                let found: ContentSearch
                do { found = try await search(id, text, start) }
                catch {
                    guard let self, !Task.isCancelled, self.query == text else { return }
                    self.searching = false; self.failed = true; self.publish(focus: false)
                    return
                }
                guard !Task.isCancelled, let self, self.query == text else { return }
                for hit in found.hits {
                    for occurrence in 0..<max(1, hit.count ?? 1) { self.matches.append(Match(messageID: hit.id, occurrence: occurrence)) }
                }
                guard let next = found.next else { break }
                if self.current == nil, !self.matches.isEmpty { self.current = self.firstNearReader(); self.publish(focus: true) }
                else { self.publish(focus: false) }
                start = next
            }
            guard let self, !Task.isCancelled, self.query == text else { return }
            self.searching = false
            if self.current == nil, !self.matches.isEmpty { self.current = self.firstNearReader(); self.publish(focus: true) }
            else { self.publish(focus: false) }
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
        matches.replaceSubrange(first..<end, with: (0..<rendered).map { Match(messageID: id, occurrence: $0) })
        if let index = current, index >= end { current = index - (end - first) + rendered }
        if wasCurrent {
            current = first + min(occurrence, rendered - 1); publish(focus: false)
        } else { publish(focus: false) }
    }
    /// Shows the count and marks the matches; `focus` also brings the current
    /// match into view.
    private func publish(focus: Bool, navigate: Bool = true) {
        guard let pane else { return }
        pane.findBar?.show(current: current, total: matches.count, searching: searching, failed: failed, query: query)
        var highlights = TranscriptHighlights(query: query)
        if let current, matches.indices.contains(current) {
            let match = matches[current]
            if focus { serial += 1 }
            // The search names the record; the page may draw it in another
            // message's row (a tool's result in its call's card).
            let drawing = pane.page.drawingMessageID(for: match.messageID)
            // Drawn in another message's row, the occurrence is the record's
            // own: only the text of its call's card is counted.
            let scope = drawing == match.messageID ? nil : pane.session?.messages.first { $0.id == match.messageID }?.toolCallID
            highlights.focus = .init(messageID: drawing, needle: query, occurrence: match.occurrence,
                                     serial: focus ? serial : (pane.document.highlights.focus?.serial ?? serial), fromFind: true, scopeCall: scope,
                                     record: match.messageID)
            if focus, navigate, let session = pane.session {
                stopNavigation()
                _ = pane.page.revealContent(of: match.messageID, needle: query)
                // A match whose rows are not on screen is landed on first; one
                // the page draws now is brought into view in place.
                if !pane.page.visibleMessageIDs().contains(drawing), let reveal {
                    let id = session.id, wanted = current
                    navigation = Task { [weak self] in
                        let landed = await reveal(id, match.messageID)
                        guard !Task.isCancelled, let self, self.current == wanted else { return }
                        guard landed else {
                            if self.pane?.session?.revealFailure != nil { self.pane?.findBar?.showUnreachable() }
                            return
                        }
                        // Read in: the page can now say which row draws it,
                        // open what hides it, and bring it into view.
                        _ = self.pane?.page.revealContent(of: match.messageID, needle: self.query)
                        self.publish(focus: true, navigate: false)
                    }
                }
            }
        }
        pane.document.highlights = highlights
    }
}
