import AppKit

/// The one line every piece of work reads as: a tool call, a reasoning block,
/// a context injection, a folded turn. One height, one icon box, one title,
/// one summary — so a reply's work reads as a list rather than as a stack of
/// differently shaped boxes.
///
/// Status is carried by colour and by one hidden word, never by a second badge
/// on the line: a failure replaces the summary with its first line, a stopped
/// call turns its dot amber, and a running row sweeps slowly. The whole row is
/// the control, for the pointer and for the keyboard, and the icon cross-fades
/// into the chevron under the pointer so the line never grows a second glyph.
enum TranscriptRowChrome {
    /// The line box every work row shares.
    static let height: CGFloat = 24
    /// The leading box the icon and the chevron both sit in.
    static let leading: CGFloat = 16
    /// Between the leading box and the title.
    static let gap: CGFloat = 6
    /// Where content opened under a row starts, so it lines up with the title.
    static let indent: CGFloat = leading + gap
    /// The icon-to-chevron cross-fade, and the chevron's own turn.
    static let chevronSeconds = 0.1
    /// A fold opening or closing. Quicker than `PiMotion.base`: a disclosure
    /// is an answer to a click, not an entrance, and at 220 ms a reader
    /// opening several rows in a row waits on the transcript. The curve is the
    /// same ease-out, so nothing else about the motion changes.
    static let foldSeconds = 0.16
    /// One sweep of the running shimmer.
    static let shimmerSeconds = 2.6
}

/// Where a row stands. Only `running`, `stopped` and `failed` say anything;
/// a settled row is its icon and its summary.
enum TranscriptRowState: String, Sendable, Equatable {
    case ok, running, stopped, failed

    /// The word assistive technology hears, since the dot and the sweep are
    /// both colour.
    var spokenStatus: String? {
        switch self {
        case .ok: return nil
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}
final class TranscriptFocusMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
