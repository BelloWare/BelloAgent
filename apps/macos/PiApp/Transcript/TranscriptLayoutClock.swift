import Foundation

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
    /// How many times a reply's text was laid out to find its height at a
    /// width it had no height for (`NativeMarkdownContainer.measure`).
    static var markdownMeasures = 0
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
    /// Whole-page identity walks: the page or the document hashing every
    /// row's id to prove the ids unique, or to find rows that came or went.
    /// A token keeps every row's identity, so it must take none.
    static var identityWalks = 0
    /// What a reply's native surface spent taking tokens, and the part of it
    /// that was the markdown reading of the text, so a fixture can tell the
    /// surface's own share from the parser's.
    static var markdownAppendSeconds = 0.0
    static var markdownReadingSeconds = 0.0
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func reset() {
        updateSeconds = 0; layoutSeconds = 0; measureSeconds = 0; measuredRows = 0; mountedRows = 0
        markdownUpdateSeconds = 0; markdownLayoutSeconds = 0; markdownMeasures = 0; workListCardsMeasured = 0
        mountSeconds = 0; rowLoopSeconds = 0; rowSizingPasses = 0; rowSizingSeconds = 0
        rootUpdateSeconds = 0; rootUpdates = 0; hostBuildSeconds = 0; hostBuilds = 0
        hostReleaseSeconds = 0; viewportLayoutSeconds = 0
        rowAttachmentSeconds = 0; rowDetachmentSeconds = 0
        placementSeconds = 0; validationSeconds = 0; intrinsicInvalidations = 0
        streamingAppends = 0; streamingEstimates = 0; streamingRebuilds = 0
        disclosureReads = 0; disclosurePrunes = 0; identityWalks = 0
        markdownAppendSeconds = 0; markdownReadingSeconds = 0
    }
}
