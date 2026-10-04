import Foundation

// The edges of the conversation: where the rows the page holds end and the
// rest of the chat begins. The page reads what lies beyond an edge as the
// reader reaches it, at either end, so an edge normally shows nothing at all.
// It speaks up only when it has to: a read that is slow shows a small
// spinner, one that failed says so with a way to try again, and earlier rows
// the page will not read on its own (a short page that has filled itself as
// often as it may) wait behind one quiet control. Everything here floats over
// the conversation: nothing that comes or goes at an edge changes the
// transcript's frame, so no row ever moves for it.

/// What one edge of the conversation shows.
enum TranscriptEdge: Equatable {
    /// Nothing: no rows beyond it, or a read that is not slow yet.
    case quiet
    /// A read that has run longer than `quietLoad`: the small spinner.
    case loading
    /// Rows the page will not read on its own: the reader asks for them.
    case waiting
    /// A read that failed: its error, and Retry.
    case failed(String)
    /// The conversation changed under the page: why, and Reload.
    case changed(String)

    /// How long a read runs before its edge shows the spinner. Most pages
    /// land well inside it, and show nothing at all.
    static let quietLoad = Duration.milliseconds(300)

    static func earlier(_ boundary: ConversationPageBoundary, slow: Bool, waitsForReader: Bool) -> TranscriptEdge {
        if let error = boundary.error { return .failed(error) }
        if boundary.loading { return slow ? .loading : .quiet }
        return boundary.cursor != nil && waitsForReader ? .waiting : .quiet
    }
    static func newer(_ boundary: ConversationPageBoundary, slow: Bool) -> TranscriptEdge {
        // An error with no boundary left to read from is not a read that
        // failed: the page lost its place in the conversation, and only
        // reading it again helps.
        if let error = boundary.error { return boundary.cursor == nil ? .changed(error) : .failed(error) }
        if boundary.loading { return slow ? .loading : .quiet }
        // The rows after a window are read as the reader reaches its end, as
        // the rows before it are at its top: nothing to press.
        return .quiet
    }
    /// A short name for the marker checks read.
    var name: String {
        switch self {
        case .quiet: return "quiet"
        case .loading: return "loading"
        case .waiting: return "waiting"
        case .failed: return "failed"
        case .changed: return "changed"
        }
    }
}
