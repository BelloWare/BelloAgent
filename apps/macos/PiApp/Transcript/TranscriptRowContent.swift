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

/// Builds the content for an item: native rows where they exist, the
/// SwiftUI row for everything not yet ported.
@MainActor enum TranscriptRowRenderer {
    /// Off draws every row through SwiftUI, for checks that a native row
    /// reads exactly as the SwiftUI one it replaces.
    static var native = true
    static func content(for item: TranscriptItem, inputs: TranscriptRowInputs) -> NSView & TranscriptRowContent {
        if native, TranscriptNativeUserRow.draws(item) { return TranscriptNativeUserRow(inputs: inputs) }
        if native, TranscriptNativeReplyRow.draws(item) { return TranscriptNativeReplyRow(inputs: inputs) }
        if native, TranscriptNativeFailureRow.draws(item) { return TranscriptNativeFailureRow(inputs: inputs) }
        if native, TranscriptNativeNoticeRow.draws(item) { return TranscriptNativeNoticeRow(inputs: inputs) }
        if native, TranscriptNativeBranchRow.draws(item) { return TranscriptNativeBranchRow(inputs: inputs) }
        if native, TranscriptNativeStatusRow.draws(item) { return TranscriptNativeStatusRow(inputs: inputs) }
        if native, TranscriptNativeVersionBannerRow.draws(item) { return TranscriptNativeVersionBannerRow(inputs: inputs) }
        if native, TranscriptNativeCompactionRow.draws(item) { return TranscriptNativeCompactionRow(inputs: inputs) }
        if native, TranscriptNativeRequestInfoRow.draws(item) { return TranscriptNativeRequestInfoRow(inputs: inputs) }
        if native, TranscriptNativeToolResultRow.draws(item) { return TranscriptNativeToolResultRow(inputs: inputs) }
        if native, TranscriptNativeTurnSummaryRow.draws(item) { return TranscriptNativeTurnSummaryRow(inputs: inputs) }
        if native, TranscriptNativeTurnFoldRow.draws(item) { return TranscriptNativeTurnFoldRow(inputs: inputs) }
        if native, TranscriptNativeResponseRow.draws(item) { return TranscriptNativeResponseRow(inputs: inputs) }
        if native, TranscriptNativePartRow.draws(item) { return TranscriptNativePartRow(inputs: inputs) }
        if native, TranscriptNativeExecutionRow.draws(item) { return TranscriptNativeExecutionRow(inputs: inputs) }
        if native, TranscriptNativeLegacyRow.draws(item) { return TranscriptNativeLegacyRow(inputs: inputs) }
        return TranscriptHostedRowContent(inputs: inputs)
    }
}
