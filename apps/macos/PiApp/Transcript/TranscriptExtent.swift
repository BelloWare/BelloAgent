import AppKit

// The whole chat as one document. The transcript holds a bounded window of a
// long chat's rows (`TranscriptPaging`), and the rows before and after that
// window stand in it as room: as many rows as the history says are there, at
// the height a row of this chat takes on average. The scroller is then the
// whole chat's from the moment it opens — a drag to the middle goes to the
// middle of the conversation — and a page read in at an edge takes the place
// of the room its rows stood in, so nothing on screen moves for it. Where the
// reader lands in room no page has reached yet, the page there is read and
// placed where they are (`TranscriptPage.onJump`).

/// How many rows of the timeline shown come before the transcript's first
/// row and after its last, out of `total`.
struct HistoryExtent: Equatable {
    var before: Int
    var after: Int
    var total: Int
    /// The first row after the window, counting from the chat's first.
    var firstAfter: Int { total - after }
}

/// Where the rows a chat's transcript holds stand in its whole timeline, as
/// the history pages read for it said, and how tall one of its rows is on
/// average. One per chat display; never saved.
@MainActor final class HistoryPositions {
    private var positions: [String: Int] = [:]
    private(set) var total: Int?
    /// The height one row of the timeline takes in this chat, measured from
    /// the rows the transcript has laid out (`TranscriptNativeDocument`).
    var rowHeight: CGFloat?
    /// How many rows that height was measured over.
    var rowHeightSample = 0
    /// The first message of the window that supplied the sample.
    var rowHeightFirstID: String?
    /// The row width it was measured at.
    var rowHeightWidth: CGFloat?

    /// A page that replaces the window: what was known of the old one may
    /// belong to another timeline.
    func reset(_ page: ConversationHistoryPage) {
        positions = [:]; total = nil; rowHeightFirstID = nil
        // A page with nothing before or after it is the whole timeline, said
        // or not (a chat just made is authoritatively empty).
        if page.start == nil, page.older == nil, page.newer == nil {
            total = page.messages.count
            for (offset, message) in page.messages.enumerated() { positions[message.id] = offset }
        }
        record(page)
    }
    /// The timeline changed under the window (an edit's new branch): nothing
    /// known still holds until the next page says.
    func forget() { positions = [:]; total = nil }
    func record(_ page: ConversationHistoryPage) {
        guard let start = page.start, let total = page.total else { return }
        self.total = total
        for (offset, message) in page.messages.enumerated() { positions[message.id] = start + offset }
    }
    /// Keeps what is known of the rows the window holds, so a chat read for
    /// hours does not remember every row it ever showed.
    func prune(keeping rows: [TranscriptMessage]) {
        guard positions.count > max(1_024, rows.count * 4) else { return }
        let ids = Set(rows.map(\.id))
        positions = positions.filter { ids.contains($0.key) }
    }
    /// The rows outside `rows` (the window, in order). `reachesStart` and
    /// `reachesEnd` say the window holds the timeline's first and newest rows.
    /// Nil when the history has not said where the window stands, or when
    /// nothing lies outside it. The rows of the window no page named — the
    /// live rows a run adds — take their places from it, so the window is
    /// still placed once the rows a page named have left it.
    func extent(of rows: [TranscriptMessage], reachesStart: Bool, reachesEnd: Bool) -> HistoryExtent? {
        defer { if let total, let placed = placed(rows, reachesStart: reachesStart) { adopt(rows, from: placed, reachesEnd: reachesEnd, total: total) } }
        guard let total, !rows.isEmpty, !positions.isEmpty else { return nil }
        var before: Int? = reachesStart ? 0 : nil
        if before == nil, let index = rows.firstIndex(where: { positions[$0.id] != nil }), let position = positions[rows[index].id] {
            before = max(0, position - index)
        }
        var after: Int? = reachesEnd ? 0 : nil
        if after == nil, let index = rows.lastIndex(where: { positions[$0.id] != nil }), let position = positions[rows[index].id] {
            after = max(0, total - 1 - position - (rows.count - 1 - index))
        }
        guard let before, let after, before + after > 0 else { return nil }
        return HistoryExtent(before: before, after: after, total: max(total, before + rows.count + after))
    }
    /// Where the window's first row stands, from the first of its rows a
    /// page named.
    private func placed(_ rows: [TranscriptMessage], reachesStart: Bool) -> Int? {
        if reachesStart { return 0 }
        guard let index = rows.firstIndex(where: { positions[$0.id] != nil }), let position = positions[rows[index].id] else { return nil }
        return max(0, position - index)
    }
    private func adopt(_ rows: [TranscriptMessage], from first: Int, reachesEnd: Bool, total: Int) {
        for (offset, row) in rows.enumerated() where positions[row.id] == nil { positions[row.id] = first + offset }
        // A window at the newest row is the timeline's end: rows a run added
        // count in its total.
        if reachesEnd { self.total = max(total, first + rows.count) }
        prune(keeping: rows)
    }
}
