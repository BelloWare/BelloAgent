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
        if previous.first?.id == firstLive.id { return live }
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
    /// What a row weighs in the resident window (`HistoryWindowPolicy.residentWeight`,
    /// the measure the helper fills its pages within too).
    static func size(_ message: TranscriptMessage) -> Int {
        let tools = (message.tools ?? []).reduce(0) { $0 + $1.input.utf8.count + $1.output.utf8.count }
        let segments = message.responseTimeline?.segments ?? []
        return HistoryWindowPolicy.residentWeight(text: message.text.utf8.count, thinking: message.thinking?.utf8.count ?? 0, toolBytes: tools,
                                                  segmentBytes: segments.reduce(0) { $0 + $1.text.utf8.count }, segments: segments.count)
    }
    /// Whether a row opens a display turn (`HistoryWindowPolicy.startsTurn`),
    /// exactly as the transcript's fold counts turns: where the window may
    /// start or end.
    static func startsTurn(_ message: TranscriptMessage) -> Bool {
        HistoryWindowPolicy.startsTurn(role: message.role, kind: message.kind, agentDelivery: message.nativeAgentDelivery != nil)
    }
    /// Where the turn holding row `index` starts: its own first row, or the
    /// first row of `messages` when the turn began before them.
    static func turnStart(_ index: Int, in messages: [TranscriptMessage]) -> Int {
        var start = index
        while start > 0, !startsTurn(messages[start]) { start -= 1 }
        return start
    }
    /// Where the turn holding row `index` ends: at the next turn's first row,
    /// or the end of `messages`.
    static func turnEnd(_ index: Int, in messages: [TranscriptMessage]) -> Int {
        var end = index + 1
        while end < messages.count, !startsTurn(messages[end]) { end += 1 }
        return end
    }
    /// The newest rows within both caps (the earliest when `keepingEarlier`),
    /// in whole display turns. The window lets go of a turn whole, never of
    /// part of one, so a turn it holds reads as it does whole: its work
    /// folded behind its one line. A turn longer than the caps on its own,
    /// which no window holds whole, is cut where the caps fall.
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
        // Whether the turn the cut falls in would fit the caps on its own.
        func fits(_ turn: Range<Int>) -> Bool {
            turn.count <= caps.rows && (turn.count == 1 || turn.reduce(0) { $0 + size(messages[$1]) } <= caps.bytes)
        }
        if keepingEarlier {
            for row in messages { guard admits(row) else { break } }
            if kept == messages.count { return messages }
            // Up to the start of the turn the cut falls in.
            let start = turnStart(kept, in: messages)
            return Array(messages.prefix(start > 0 && fits(start..<turnEnd(kept, in: messages)) ? start : kept))
        }
        for row in messages.reversed() { guard admits(row) else { break } }
        if kept == messages.count { return messages }
        // From the first turn that starts after the cut.
        let first = messages.count - kept, next = turnEnd(first - 1, in: messages)
        let whole = next < messages.count && fits(turnStart(first - 1, in: messages)..<next)
        return Array(messages[(whole ? next : first)...])
    }
    /// The window that keeps every row of `keeping` (the rows on the
    /// reader's screen) with the rest of their turns, and, within both caps,
    /// as many whole turns as it can toward the requested side — earlier
    /// ones when `keepingEarlier` — letting go of the turns past the kept
    /// ones on the other side and of the farthest ones of the requested
    /// side. Turns too long for the caps keep just the kept rows, and a turn
    /// too long for them toward the requested side gives the rows of it
    /// nearest the kept ones that there is still room for. `firstContinues`,
    /// `lastContinues`: `messages` begin or end inside a turn that goes on
    /// past them. Nil when the kept rows alone pass a cap.
    static func window(_ messages: [TranscriptMessage], keeping: Set<String>, keepingEarlier: Bool,
                       firstContinues: Bool = false, lastContinues: Bool = false) -> [TranscriptMessage]? {
        let indices = messages.indices.filter { keeping.contains(messages[$0].id) }
        guard let low = indices.first, let high = indices.last else { return window(messages, keepingEarlier: keepingEarlier) }
        let caps = residentCaps
        func measure(_ range: Range<Int>) -> (rows: Int, bytes: Int) { (range.count, range.reduce(0) { $0 + size(messages[$1]) }) }
        // Whether the window could hold `turn` whole on its own. A piece of a
        // turn that goes on past these rows — a page or the window held a
        // capped piece of it (`firstContinues`, `lastContinues`) — is not the
        // whole turn, however few its rows: that turn is too long for the
        // window, or the page would have held it whole.
        func fitsAlone(_ turn: Range<Int>) -> Bool {
            if turn.lowerBound == 0, firstContinues, let first = messages.first, !startsTurn(first) { return false }
            if turn.upperBound == messages.count, lastContinues { return false }
            let whole = measure(turn); return whole.rows <= caps.rows && (whole.bytes <= caps.bytes || whole.rows == 1)
        }
        var start = turnStart(low, in: messages), end = turnEnd(high, in: messages)
        var (kept, bytes) = measure(start..<end)
        if kept > caps.rows || (bytes > caps.bytes && kept > 1) {
            start = low; end = high + 1; (kept, bytes) = measure(start..<end)
            guard kept <= caps.rows, bytes <= caps.bytes || kept == 1 else { return nil }
        }
        // A turn the window can never hold whole is cut anyway: it gives the
        // rows nearest the kept ones that there is room for, so a page read
        // toward it always adds rows. Taken whole or not at all, its other
        // rows were always more than the window has, and the read added
        // nothing and was refused, leaving the reader at blank room. A turn
        // that fits on its own waits, whole, for room.
        if keepingEarlier {
            while start > 0 {
                let previous = turnStart(start - 1, in: messages), more = measure(previous..<start)
                if kept + more.rows <= caps.rows, bytes + more.bytes <= caps.bytes { start = previous; kept += more.rows; bytes += more.bytes; continue }
                if !fitsAlone(previous..<turnEnd(start - 1, in: messages)) {
                    while start > previous, kept < caps.rows, bytes + size(messages[start - 1]) <= caps.bytes {
                        start -= 1; kept += 1; bytes += size(messages[start])
                    }
                }
                break
            }
        } else {
            while end < messages.count {
                let next = turnEnd(end, in: messages), more = measure(end..<next)
                if kept + more.rows <= caps.rows, bytes + more.bytes <= caps.bytes { end = next; kept += more.rows; bytes += more.bytes; continue }
                if !fitsAlone(turnStart(end, in: messages)..<next) {
                    while end < next, kept < caps.rows, bytes + size(messages[end]) <= caps.bytes {
                        bytes += size(messages[end]); end += 1; kept += 1
                    }
                }
                break
            }
        }
        return Array(messages[start..<end])
    }
    /// Whether the window can take a whole page of earlier rows (a history
    /// page is at most `pageLimits`' rows and bytes)
    /// without letting go of any row it holds. A page that fills itself with
    /// earlier rows must never push out the rows the reader is at, the live
    /// tail among them.
    static func takesAnotherPage(_ messages: [TranscriptMessage]) -> Bool {
        let caps = residentCaps, page = pageLimits
        guard messages.count + page.rows <= caps.rows else { return false }
        return messages.reduce(0) { $0 + size($1) } + page.bytes <= caps.bytes
    }
    /// Whether `window`, cut from `all`, ends at the end of a display turn:
    /// the row after its last one in `all` opens the next turn.
    static func endsTurn(_ window: [TranscriptMessage], in all: [TranscriptMessage]) -> Bool {
        guard let last = window.last, let at = all.lastIndex(where: { $0.id == last.id }), at + 1 < all.count else { return false }
        return startsTurn(all[at + 1])
    }
    /// The question of the turn `window` starts inside of, as the page's
    /// earlier edge names it (`partialTurnInput`): the nearest question
    /// before its first row in `all`, which it was cut from, or `fallback`
    /// when `all` starts inside that same turn. Nil when the window starts
    /// where a turn does.
    static func partialTurnInput(of window: [TranscriptMessage], in all: [TranscriptMessage], fallback: String?) -> String? {
        guard let first = window.first, !startsTurn(first), let at = all.firstIndex(where: { $0.id == first.id }) else { return nil }
        return all[..<at].last(where: startsTurn)?.id ?? fallback
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
    /// What a page of history the journal reader reads may hold
    /// (`HistoryWindowPolicy.PageLimits`): the helper's own, which the app
    /// never changes. A test seam, as `residentCaps` is: a fixture lowers
    /// them so that a short chat pages as a long one does.
    static var pageLimits: HistoryWindowPolicy.PageLimits {
        get { capsLock.lock(); defer { capsLock.unlock() }; return limits }
        set { capsLock.lock(); limits = newValue; capsLock.unlock() }
    }
    nonisolated(unsafe) private static var limits = HistoryWindowPolicy.PageLimits.standard
    /// Rows of an earlier page that are not already shown, in page order.
    static func prefix(earlier: [TranscriptMessage], shown: [TranscriptMessage]) -> [TranscriptMessage] {
        let known = Set(shown.map(\.id))
        return earlier.filter { !known.contains($0.id) }
    }
}
