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
    static var mountSeconds = 0.0
    static var rowLoopSeconds = 0.0
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func reset() {
        updateSeconds = 0; layoutSeconds = 0; measureSeconds = 0; measuredRows = 0; mountedRows = 0
        markdownUpdateSeconds = 0; markdownLayoutSeconds = 0; markdownBlocksMeasured = 0; workListCardsMeasured = 0
        mountSeconds = 0; rowLoopSeconds = 0; rowSizingPasses = 0; rowSizingSeconds = 0
    }
}
