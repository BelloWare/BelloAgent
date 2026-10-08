import Foundation

/// How a live page from the helper joins the rows already on screen. The
/// helper sends only the newest window of a conversation; rows the reader
/// scrolled up to (prepended from an earlier page) stay in front of it as long
/// as the two still touch: they share a row, or the page starts right after
/// the last row shown (`follows`, the helper's `historyFollows`). Missing
/// overlap preserves the reader's range until an explicit source handoff, gap
/// load, or validated branch reload.
enum TranscriptPaging {
    static func merge(previous: [TranscriptMessage], live: [TranscriptMessage], follows: String? = nil) -> [TranscriptMessage] {
        guard !previous.isEmpty else { return live }
        guard let firstLive = live.first else { return previous }
        let liveIDs = Set(live.map(\.id))
        if let cut = previous.firstIndex(where: { $0.id == firstLive.id }) {
            return previous[..<cut].filter { !liveIDs.contains($0.id) } + live
        }
        // Saved and helper projections can fit different leading rows within
        // the same byte budget. A live window extending before the saved
        // window still overlaps it and must publish its updated/new replies.
        if let first = previous.first, liveIDs.contains(first.id) { return live }
        // A page with no room left for the row before it (a reply longer
        // than the page) still touches the rows shown when it starts right
        // after the last of them.
        if Self.joins(previous, follows: follows) { return previous.filter { !liveIDs.contains($0.id) } + live }
        return previous
    }
    /// Whether a live page that starts right after the row `follows` carries
    /// on from the last of `shown`.
    static func joins(_ shown: [TranscriptMessage], follows: String?) -> Bool {
        follows != nil && shown.last?.id == follows
    }
    static func size(_ message: TranscriptMessage) -> Int {
        let tools = (message.tools ?? []).reduce(0) { $0 + $1.input.utf8.count + $1.output.utf8.count }
        let timeline = message.responseTimeline?.segments.reduce(0) { $0 + $1.text.utf8.count + 512 } ?? 0
        return message.text.utf8.count + (message.thinking?.utf8.count ?? 0) + tools + timeline + 512
    }
    static func window(_ messages: [TranscriptMessage], keepingEarlier: Bool) -> [TranscriptMessage] {
        // Counts the rows that fit, then cuts once. A page that fits whole —
        // every token of a reply in most chats — comes back as it came,
        // where copying it row by row retained every field of every row.
        var kept = 0, bytes = 0
        let caps = residentCaps
        func admits(_ row: TranscriptMessage) -> Bool {
            let size = size(row)
            guard kept < caps.rows, kept == 0 || bytes + size <= caps.bytes else { return false }
            kept += 1; bytes += size
            return true
        }
        if keepingEarlier {
            for row in messages { guard admits(row) else { break } }
            return kept == messages.count ? messages : Array(messages.prefix(kept))
        }
        for row in messages.reversed() { guard admits(row) else { break } }
        return kept == messages.count ? messages : Array(messages.suffix(kept))
    }
    /// The window that keeps every row of `keeping` (the rows on the
    /// reader's screen) and, within both caps, as many rows as it can toward
    /// the requested side — earlier rows when `keepingEarlier` — letting go
    /// of the rows past the kept ones on the other side and the farthest
    /// rows of the requested side. Nil when the kept rows alone pass a cap.
    static func window(_ messages: [TranscriptMessage], keeping: Set<String>, keepingEarlier: Bool) -> [TranscriptMessage]? {
        let indices = messages.indices.filter { keeping.contains(messages[$0].id) }
        guard let low = indices.first, let high = indices.last else { return window(messages, keepingEarlier: keepingEarlier) }
        let caps = residentCaps
        var kept = 0, bytes = 0
        for index in low...high { kept += 1; bytes += size(messages[index]) }
        guard kept <= caps.rows, bytes <= caps.bytes || kept == 1 else { return nil }
        var start = low, end = high + 1
        if keepingEarlier {
            while start > 0, kept < caps.rows, bytes + size(messages[start - 1]) <= caps.bytes { start -= 1; kept += 1; bytes += size(messages[start]) }
        } else {
            while end < messages.count, kept < caps.rows, bytes + size(messages[end]) <= caps.bytes { bytes += size(messages[end]); end += 1; kept += 1 }
        }
        return Array(messages[start..<end])
    }
    /// Whether the window can take a whole page of earlier rows (a history
    /// page is at most `HistoryWindowPolicy.rows` rows and one envelope)
    /// without letting go of any row it holds. A page that fills itself with
    /// earlier rows must never push out the rows the reader is at, the live
    /// tail among them.
    static func takesAnotherPage(_ messages: [TranscriptMessage]) -> Bool {
        let caps = residentCaps
        guard messages.count + HistoryWindowPolicy.rows <= caps.rows else { return false }
        return messages.reduce(0) { $0 + size($1) } + HistoryWindowPolicy.envelopeBytes <= caps.bytes
    }
    /// The resident window's two caps: `HistoryWindowPolicy`'s, which the app
    /// never changes. A test seam: a fixture lowers them so that a short chat
    /// passes both, rather than paging through a thousand long rows to do it.
    static var residentCaps: (rows: Int, bytes: Int) {
        get { capsLock.lock(); defer { capsLock.unlock() }; return caps }
        set { capsLock.lock(); caps = newValue; capsLock.unlock() }
    }
    private static let capsLock = NSLock()
    nonisolated(unsafe) private static var caps = (rows: HistoryWindowPolicy.residentRows, bytes: HistoryWindowPolicy.residentBytes)
    /// Rows of an earlier page that are not already shown, in page order.
    static func prefix(earlier: [TranscriptMessage], shown: [TranscriptMessage]) -> [TranscriptMessage] {
        let known = Set(shown.map(\.id))
        return earlier.filter { !known.contains($0.id) }
    }
}
