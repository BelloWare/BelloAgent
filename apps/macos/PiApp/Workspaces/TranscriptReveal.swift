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
    func revealInTranscript(sessionID id: String, messageID: String, mark: TranscriptReveal.Mark? = nil) async -> Bool {
        guard let view = displays[id], let item = record(id) else { return false }
        revealSerial += 1
        view.reveal = TranscriptReveal(messageID: messageID, mark: mark, serial: revealSerial)
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
        guard let view = displays[id], let item = record(id) else { return false }
        if view.olderPage.cursor == nil, let first = view.messages.first {
            land(view, on: first.id, landing: Double(TranscriptMetrics.pageTopInset))
            return true
        }
        return await readWindow(item, view: view, around: nil)
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
        let serial = revealSerial
        view.revealRead = serial
        // Only into a transcript that still shows this chat: a read that
        // lands after the reader went to another chat leaves this one as it was.
        func current() -> Bool {
            !Task.isCancelled && displays[item.id] === view && view.presentationGeneration == generation && view.revealRead == serial
                && (item.id == selectedID || sides[selectedID ?? ""]?.id == item.id)
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
            if !(error is CancellationError), current() { view.olderPage.error = error.localizedDescription }
            return false
        }
    }
}

extension TranscriptReveal.Mark {
    /// The text to find in the message's rows and which occurrence of it (in
    /// reading order) is the place, for `TranscriptHighlights.Focus`.
    func needle(in text: String) -> (needle: String, occurrence: Int)? {
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
            let found = Self.ranges(of: needle, in: source)
            guard !found.isEmpty else { return (needle, 0) }
            // The words just before the match in the excerpt, as one line.
            func flat(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
            let lead = flat(line.substring(to: highlight.location).trimmingCharacters(in: CharacterSet(charactersIn: "…")))
            let tail = String(lead.suffix(24))
            guard !tail.isEmpty else { return (needle, 0) }
            let index = found.firstIndex { range in
                let start = max(0, range.location - tail.count * 3)
                return flat(source.substring(with: NSRange(location: start, length: range.location - start))).hasSuffix(tail)
            } ?? 0
            return (needle, index)
        }
    }
    static func ranges(of needle: String, in text: NSString) -> [NSRange] {
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
