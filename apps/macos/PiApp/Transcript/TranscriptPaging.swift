import Foundation

/// How a live page from the helper joins the rows already on screen. The
/// helper sends only the newest window of a conversation; rows the reader
/// scrolled up to (prepended from an earlier page) stay in front of it as long
/// as the two still touch. A window that no longer overlaps what is shown, as
/// after an edit-and-resend branch, replaces the display.
enum TranscriptPaging {
    static func merge(previous: [TranscriptMessage], live: [TranscriptMessage]) -> [TranscriptMessage] {
        guard let firstLive = live.first, let cut = previous.firstIndex(where: { $0.id == firstLive.id }), cut > 0 else { return live }
        let liveIDs = Set(live.map(\.id))
        return previous[..<cut].filter { !liveIDs.contains($0.id) } + live
    }
    /// Rows of an earlier page that are not already shown, in page order.
    static func prefix(earlier: [TranscriptMessage], shown: [TranscriptMessage]) -> [TranscriptMessage] {
        let known = Set(shown.map(\.id))
        return earlier.filter { !known.contains($0.id) }
    }
}
