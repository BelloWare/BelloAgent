import AppKit

/// Everything a row's content is drawn from. The row container owns all of
/// it — what the row is, what the reader opened in it, the values it is
/// drawn with and the width it wraps at — and hands it over whole, so a
/// content view never has to ask anyone else.
struct TranscriptRowInputs {
    let item: TranscriptItem
    let fresh: Bool
    let actions: TranscriptActions
    let width: CGFloat
    let environment: TranscriptRowEnvironment
    var disclosure = TranscriptRowDisclosure.default
    var toggle: (TranscriptDisclosure.Part) -> Void = { _ in }
    /// What this turn's work list measured last time it was open.
    var workListHeight: CGFloat? = nil
    var workListMeasured: (CGFloat) -> Void = { _ in }
    /// True while the document is moving this row between two measured heights.
    var foldInMotion = false
}

/// What a row draws through: a view the row container builds once, hands
/// new inputs to, and asks for its height at the width it is laid out at.
/// The container keeps every measurement; the content only answers.
@MainActor protocol TranscriptRowContent: NSView {
    /// The row that holds this content, told when the content's own height
    /// changed without new inputs (text finishing its layout, say).
    var owner: TranscriptRowContainer? { get set }
    /// Whether this content can draw `item`. A row whose item changes into
    /// one its content cannot draw is given new content.
    func accepts(_ item: TranscriptItem) -> Bool
    func apply(_ inputs: TranscriptRowInputs)
    /// Lays the content out at its frame's width and returns the height it
    /// needs there, with how many sizing passes that took.
    func settle() -> (height: CGFloat, passes: Int)
    /// The height the content needs at its frame's width, asked again to
    /// confirm an earlier measurement.
    func confirmHeight() -> CGFloat
}

/// Builds the content for an item: the native row that draws it.
@MainActor enum TranscriptRowRenderer {
    /// A test seam: draws every row through this instead (the parity tests'
    /// SwiftUI rows, which the native ones must read exactly as).
    static var reference: ((TranscriptRowInputs) -> NSView & TranscriptRowContent)?
    static func content(for item: TranscriptItem, inputs: TranscriptRowInputs) -> NSView & TranscriptRowContent {
        if let reference { return reference(inputs) }
        if TranscriptNativeUserRow.draws(item) { return TranscriptNativeUserRow(inputs: inputs) }
        if TranscriptNativeReplyRow.draws(item) { return TranscriptNativeReplyRow(inputs: inputs) }
        if TranscriptNativeFailureRow.draws(item) { return TranscriptNativeFailureRow(inputs: inputs) }
        if TranscriptNativeNoticeRow.draws(item) { return TranscriptNativeNoticeRow(inputs: inputs) }
        if TranscriptNativeBranchRow.draws(item) { return TranscriptNativeBranchRow(inputs: inputs) }
        if TranscriptNativeStatusRow.draws(item) { return TranscriptNativeStatusRow(inputs: inputs) }
        if TranscriptNativeVersionBannerRow.draws(item) { return TranscriptNativeVersionBannerRow(inputs: inputs) }
        if TranscriptNativeCompactionRow.draws(item) { return TranscriptNativeCompactionRow(inputs: inputs) }
        if TranscriptNativeRequestInfoRow.draws(item) { return TranscriptNativeRequestInfoRow(inputs: inputs) }
        if TranscriptNativeToolResultRow.draws(item) { return TranscriptNativeToolResultRow(inputs: inputs) }
        if TranscriptNativeTurnSummaryRow.draws(item) { return TranscriptNativeTurnSummaryRow(inputs: inputs) }
        if TranscriptNativeTurnFoldRow.draws(item) { return TranscriptNativeTurnFoldRow(inputs: inputs) }
        if TranscriptNativeResponseRow.draws(item) { return TranscriptNativeResponseRow(inputs: inputs) }
        if TranscriptNativePartRow.draws(item) { return TranscriptNativePartRow(inputs: inputs) }
        if TranscriptNativeExecutionRow.draws(item) { return TranscriptNativeExecutionRow(inputs: inputs) }
        if TranscriptNativeLegacyRow.draws(item) { return TranscriptNativeLegacyRow(inputs: inputs) }
        // Nothing the planners make reaches here (TranscriptNativeEverywhereTests).
        return TranscriptNativeEmptyRow(inputs: inputs)
    }
}

/// A row that draws nothing and takes no room: what an item no native row
/// draws stands as, should a planner ever make one.
@MainActor final class TranscriptNativeEmptyRow: NSView, TranscriptRowContent {
    weak var owner: TranscriptRowContainer?
    init(inputs: TranscriptRowInputs) { super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    func accepts(_ item: TranscriptItem) -> Bool { false }
    func apply(_ inputs: TranscriptRowInputs) {}
    func settle() -> (height: CGFloat, passes: Int) { (0, 0) }
    func confirmHeight() -> CGFloat { 0 }
}
