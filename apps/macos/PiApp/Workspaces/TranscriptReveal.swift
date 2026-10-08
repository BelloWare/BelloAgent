import Foundation

/// A place in a chat's text the transcript is asked to show: a message, and
/// optionally a range of characters inside the text it draws (a find match).
struct TranscriptReveal: Equatable, Sendable {
    var messageID: String
    /// What to mark in the message, if anything.
    var mark: Mark?
    enum Mark: Equatable, Sendable {
        /// A UTF-16 range of the message's text (`TranscriptMessage.text`).
        case range(NSRange)
        /// A search result's excerpt of the message and the match inside it
        /// (UTF-16, within the excerpt): the occurrence whose surroundings
        /// read as the excerpt's is the one marked.
        case excerpt(String, highlight: NSRange)
    }
    /// Bumped by every request, so asking for the same place again lands again.
    var serial: Int
    /// Asked for by the find bar, which marks its own match.
    var fromFind = false
    /// How far below the viewport's top a revealed row lands.
    static let landing: Double = 24
}

extension WorkspaceModel {
    /// Brings message `messageID` of chat `sessionID` into view in its
    /// transcript, `TranscriptReveal.landing` points below the top, opens the
    /// finished turn that folded it away, and marks and shows `mark` when one
    /// is given. A message the transcript's
    /// window holds is scrolled to; one outside it is read in with the page
    /// around it, which replaces the window in place, and the window grows
    /// from there in both directions as the reader scrolls. Returns false when
    /// the chat or the message cannot be shown (the error is the page's to
    /// show). The chat should be the selected one (or a side shown beside
    /// it): nothing is placed in a transcript nobody is showing.
    @discardableResult
    func revealInTranscript(sessionID id: String, messageID: String, mark: TranscriptReveal.Mark? = nil, fromFind: Bool = false) async -> Bool {
        guard !Task.isCancelled, transcriptShows(id), let view = displays[id], let item = record(id) else { return false }
        revealSerial += 1
        view.reveal = TranscriptReveal(messageID: messageID, mark: mark, serial: revealSerial, fromFind: fromFind)
        if view.messages.contains(where: { $0.id == messageID }) {
            land(view, on: messageID)
            return true
        }
        return await readWindow(item, view: view, around: messageID)
    }

    /// Home: the chat's first message, at the top. A window that already
    /// starts there is scrolled; otherwise the chat's first page is read in
    /// place of the window.
    @discardableResult
    func revealStartOfChat(sessionID id: String) async -> Bool {
        guard !Task.isCancelled, transcriptShows(id), let view = displays[id], let item = record(id) else { return false }
        if view.olderPage.cursor == nil, let first = view.messages.first {
            land(view, on: first.id, landing: Double(TranscriptMetrics.pageTopInset))
            return true
        }
        return await readWindow(item, view: view, around: nil)
    }

    /// Whether chat `id`'s transcript is what the reader has in front of them:
    /// the chats page, with the chat selected or open as the side beside it.
    private func transcriptShows(_ id: String) -> Bool {
        page == .chats && (id == selectedID || sides[selectedID ?? ""]?.id == id)
    }
    private func land(_ view: SessionDisplay, on messageID: String, landing: Double = TranscriptReveal.landing) {
        view.revealRead = nil
        view.scrollAnchor = .init(id: messageID, offset: landing, followsBottom: false)
        view.viewportRequestOpens = false; view.viewportRequest += 1
        anchorChanged(view)
    }

    /// Reads the page that starts at `around` (the chat's first page when
    /// nil) and adopts it in place of the window, landing on its first row.
    private func readWindow(_ item: ChatRecord, view: SessionDisplay, around: String?) async -> Bool {
        let generation = view.presentationGeneration
        // The newest request wins: a find bar stepping through matches quickly
        // must not land on an earlier match whose read came back last.
        revealSerial += 1
        let serial = revealSerial, navigation = messageNavigationRevision
        view.revealRead = serial; view.revealFailure = nil
        // Only into a transcript that still shows this chat: a read that
        // lands after the reader went to another chat leaves this one as it was.
        func current() -> Bool {
            !Task.isCancelled && displays[item.id] === view && view.presentationGeneration == generation && view.revealRead == serial
                && transcriptShows(item.id) && messageNavigationRevision == navigation
        }
        // Reads at the old window's edges join rows that are about to go.
        view.presentation.olderTask?.cancel(); view.presentation.newerTask?.cancel()
        do {
            var page = try await readConversationWindow(item, cursor: nil, around: around, start: around == nil)
            guard current() else { return false }
            page.messages = await withAccounting(page.messages, view: view, workspaceID: item.workspaceID)
            guard current(), let first = around ?? page.messages.first?.id else { return false }
            // The chat's start lands at the very top, its inset above the first row.
            adoptInitialHistory(page, into: view, around: first, landing: around == nil ? Double(TranscriptMetrics.pageTopInset) : TranscriptReveal.landing)
            view.browsingHistory = page.newer != nil
            anchorChanged(view)
            return true
        } catch {
            // Said to whoever asked (the find bar shows it), not at the
            // window's earlier edge, whose Retry reads a different page.
            if !(error is CancellationError), current() { view.revealFailure = error.localizedDescription }
            return false
        }
    }
}

extension TranscriptReveal.Mark {
    /// An excerpt's words just before and after its match, flattened and
    /// lowercased, up to 24 characters each.
    var context: (lead: String, trail: String) {
        guard case .excerpt(let excerpt, let highlight) = self else { return ("", "") }
        let line = excerpt as NSString
        guard highlight.location >= 0, NSMaxRange(highlight) <= line.length else { return ("", "") }
        func flat(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
        let ellipsis = CharacterSet(charactersIn: "…")
        return (String(flat(line.substring(to: highlight.location).trimmingCharacters(in: ellipsis)).suffix(24)),
                String(flat(line.substring(from: NSMaxRange(highlight)).trimmingCharacters(in: ellipsis)).prefix(24)))
    }
    var isExcerpt: Bool { if case .excerpt = self { return true }; return false }
    /// The place in `message` as the transcript draws it: in its text, or —
    /// for an excerpt of a tool's output the message's card shows — in that
    /// card alone (`scopeCall`).
    func place(in message: TranscriptMessage) -> (needle: String, occurrence: Int, scopeCall: String?, input: Bool)? {
        if case .excerpt = self {
            if let found = needle(in: message.text, requireContext: true) { return (found.needle, found.occurrence, nil, false) }
            for tool in message.tools ?? [] {
                if let found = needle(in: tool.output, requireContext: true) { return (found.needle, found.occurrence, tool.id, false) }
                // The index reads a call as its name and its input.
                for source in [tool.input, tool.name + " " + tool.input] {
                    if let found = needle(in: source, requireContext: true) {
                        let shift = source == tool.input ? 0 : Self.ranges(of: found.needle, in: tool.name as NSString, flexible: true).count
                        return (found.needle, max(0, found.occurrence - shift), tool.id, true)
                    }
                }
            }
        }
        return needle(in: message.text).map { ($0.needle, $0.occurrence, nil, false) }
    }
    /// The text to find in the message's rows and which occurrence of it (in
    /// reading order) is the place, for `TranscriptHighlights.Focus`.
    /// `requireContext`: nil unless an excerpt's surrounding words are found.
    func needle(in text: String, requireContext: Bool = false) -> (needle: String, occurrence: Int)? {
        let source = text as NSString
        switch self {
        case .range(let range):
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length else { return nil }
            let needle = source.substring(with: range)
            let before = Self.ranges(of: needle, in: source).filter { $0.location < range.location }.count
            return (needle, before)
        case .excerpt(let excerpt, let highlight):
            let line = excerpt as NSString
            guard highlight.location >= 0, highlight.length > 0, NSMaxRange(highlight) <= line.length else { return nil }
            let needle = line.substring(with: highlight)
            let found = Self.ranges(of: needle, in: source, flexible: true)
            guard !found.isEmpty else { return requireContext ? nil : (needle, 0) }
            // The words just before and just after the match in the excerpt,
            // each as one line: the occurrence whose surroundings read the same.
            func flat(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
            let ellipsis = CharacterSet(charactersIn: "…")
            let lead = String(flat(line.substring(to: highlight.location).trimmingCharacters(in: ellipsis)).suffix(24))
            let trail = String(flat(line.substring(from: NSMaxRange(highlight)).trimmingCharacters(in: ellipsis)).prefix(24))
            // An excerpt that is the match alone says nothing more: one
            // occurrence is that one.
            guard !lead.isEmpty || !trail.isEmpty else { return requireContext && found.count != 1 ? nil : (needle, 0) }
            let index = found.firstIndex { range in
                let before = max(0, range.location - lead.count * 3), after = min(source.length, NSMaxRange(range) + trail.count * 3)
                let leads = lead.isEmpty || flat(source.substring(with: NSRange(location: before, length: range.location - before))).hasSuffix(lead)
                let trails = trail.isEmpty || flat(source.substring(with: NSRange(location: NSMaxRange(range), length: after - NSMaxRange(range)))).hasPrefix(trail)
                return leads && trails
            }
            if requireContext, index == nil { return nil }
            return (needle, index ?? 0)
        }
    }
    static func ranges(of needle: String, in text: NSString, flexible: Bool = false) -> [NSRange] {
        if flexible { return transcriptRanges(of: needle, in: text, flexible: true) }
        guard !needle.isEmpty, text.length > 0 else { return [] }
        var found: [NSRange] = [], from = 0
        while from < text.length {
            let range = text.range(of: needle, options: [.caseInsensitive], range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound, range.length > 0 else { break }
            found.append(range); from = NSMaxRange(range)
        }
        return found
    }
}
