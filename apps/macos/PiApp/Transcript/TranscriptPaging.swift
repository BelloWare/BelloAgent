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
        var result: [TranscriptMessage] = [], bytes = 0
        let caps = residentCaps
        for row in (keepingEarlier ? messages : Array(messages.reversed())) {
            let size = size(row)
            guard result.count < caps.rows,
                  result.isEmpty || bytes + size <= caps.bytes else { break }
            result.append(row); bytes += size
        }
        return keepingEarlier ? result : result.reversed()
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

/// A test seam, off in the app. When a fixture turns it on, the native
/// transcript adds up what its own reconciliation, measurement and layout
/// passes cost inside a frame, so the frame can be split into the model
/// update, SwiftUI's update, the document's work and the display pass.
@MainActor enum TranscriptLayoutClock {
    static var recording = false
    static var updateSeconds = 0.0
    static var layoutSeconds = 0.0
    static var measureSeconds = 0.0
    static var measuredRows = 0
    static var mountedRows = 0
    static var markdownUpdateSeconds = 0.0
    static var markdownLayoutSeconds = 0.0
    static var markdownBlocksMeasured = 0
    static var workListCardsMeasured = 0
    /// How many times SwiftUI has been asked to size or lay a row's tree out,
    /// and what those passes cost. A row whose content changed should cost
    /// exactly one.
    static var rowSizingPasses = 0
    static var rowSizingSeconds = 0.0
    // Inclusive phase timings and explicit call counts, not a count of
    // SwiftUI's internal sizing/placement passes.
    static var rootUpdateSeconds = 0.0
    static var rootUpdates = 0
    static var hostBuildSeconds = 0.0
    static var hostBuilds = 0
    static var hostReleaseSeconds = 0.0
    static var viewportLayoutSeconds = 0.0
    static var rowAttachmentSeconds = 0.0
    static var rowDetachmentSeconds = 0.0
    static var placementSeconds = 0.0
    static var validationSeconds = 0.0
    static var intrinsicInvalidations = 0
    static var mountSeconds = 0.0
    static var rowLoopSeconds = 0.0
    /// Tokens the page took by extending the reply's own native surface,
    /// without rebuilding or re-sizing the row's SwiftUI tree.
    static var streamingAppends = 0
    /// Tokens the page took for a reply nobody can see, by standing its row at
    /// an estimate of its own growth instead of measuring it.
    static var streamingEstimates = 0
    /// Tokens the page had to answer by rebuilding the row, because something
    /// other than the arriving text changed with them.
    static var streamingRebuilds = 0
    /// How many rows read what the reader has opened in them again, and how
    /// many times the page walked every row to forget what left it.
    static var disclosureReads = 0
    static var disclosurePrunes = 0
    /// What a reply's native surface spent taking tokens, and the part of it
    /// that was the markdown reading of the text, so a fixture can tell the
    /// surface's own share from the parser's.
    static var markdownAppendSeconds = 0.0
    static var markdownReadingSeconds = 0.0
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func reset() {
        updateSeconds = 0; layoutSeconds = 0; measureSeconds = 0; measuredRows = 0; mountedRows = 0
        markdownUpdateSeconds = 0; markdownLayoutSeconds = 0; markdownBlocksMeasured = 0; workListCardsMeasured = 0
        mountSeconds = 0; rowLoopSeconds = 0; rowSizingPasses = 0; rowSizingSeconds = 0
        rootUpdateSeconds = 0; rootUpdates = 0; hostBuildSeconds = 0; hostBuilds = 0
        hostReleaseSeconds = 0; viewportLayoutSeconds = 0
        rowAttachmentSeconds = 0; rowDetachmentSeconds = 0
        placementSeconds = 0; validationSeconds = 0; intrinsicInvalidations = 0
        streamingAppends = 0; streamingEstimates = 0; streamingRebuilds = 0
        disclosureReads = 0; disclosurePrunes = 0
        markdownAppendSeconds = 0; markdownReadingSeconds = 0
    }
}
