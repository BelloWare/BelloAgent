import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TranscriptRowContainer.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

struct TranscriptHostedRow: View {
    init(_ inputs: TranscriptRowInputs) {
        item = inputs.item; fresh = inputs.fresh; actions = inputs.actions; width = inputs.width
        environment = inputs.environment; disclosure = inputs.disclosure; toggle = inputs.toggle
        workListHeight = inputs.workListHeight; workListMeasured = inputs.workListMeasured; foldInMotion = inputs.foldInMotion
    }
    let item: TranscriptItem
    let fresh: Bool
    let actions: TranscriptActions
    let width: CGFloat
    let environment: TranscriptRowEnvironment
    /// Plain values, not observed state: the row host knows what the reader
    /// opened, so it can re-measure this row in the same pass as the click.
    var disclosure = TranscriptRowDisclosure.default
    var toggle: (TranscriptDisclosure.Part) -> Void = { _ in }
    /// What this turn's work list measured last time it was open, kept by the
    /// row container so a fold costs a frame change rather than sixty rows of
    /// native layout.
    var workListHeight: CGFloat? = nil
    var workListMeasured: (CGFloat) -> Void = { _ in }
    /// True while the document is moving this row between two measured
    /// heights, so a folding work list stays on screen and slides away.
    var foldInMotion = false
    /// Whether this message draws nothing at all: its turn has folded behind
    /// one line, or its response has folded and this is the header line's own
    /// figures, which that line already carries.
    private func drawsNothing(_ message: TranscriptMessage) -> Bool {
        disclosure.foldedAway || (message.kind == "requestInfo" && disclosure.responseFolded)
    }
    var body: some View {
        Group {
            switch item {
            case .message(let message):
                // A row a fold has emptied must take up nothing: the paragraph
                // spacing reserved around every message would otherwise leave
                // fourteen points of blank where the fold swallowed the row.
                let blank = drawsNothing(message)
                MessageRowView(message: message, actions: actions, disclosure: disclosure, toggle: toggle, switchesSource: true).equatable()
                    .padding(.top, blank ? 0 : (message.role == "user" ? 14 : 4))
                    .padding(.bottom, blank ? 0 : (message.role == "user" ? 4 : 10))
            case .block(let block):
                BlockRowView(block: block, actions: actions, fresh: fresh, disclosure: disclosure, toggle: toggle,
                             workListHeight: workListHeight, workListMeasured: workListMeasured,
                             foldInMotion: foldInMotion).equatable()
            }
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, environment.swiftUIColorScheme)
        .environment(\.layoutDirection, environment.swiftUILayoutDirection)
        .environment(\.locale, environment.locale)
        .environment(\.transcriptForks, environment.forks)
        .environment(\.transcriptOpensFiles, environment.opensFiles)
        .disabled(!environment.isEnabled)
        // No control in a row draws the system's focus ring; the ones that
        // take focus on purpose draw their own (`TranscriptFocusRing`).
        .focusEffectDisabled()
        .piStableLayout()
    }
}

/// The SwiftUI row, for items whose content has not been ported yet.
final class TranscriptHostedRowContent: NSHostingView<TranscriptHostedRow>, TranscriptRowContent {
    weak var owner: TranscriptRowContainer?
    convenience init(inputs: TranscriptRowInputs) {
        self.init(rootView: TranscriptHostedRow(inputs))
        sizingOptions = [.intrinsicContentSize]
        safeAreaRegions = []
    }
    func accepts(_ item: TranscriptItem) -> Bool { true }
    func apply(_ inputs: TranscriptRowInputs) { rootView = TranscriptHostedRow(inputs) }
    func settle() -> (height: CGFloat, passes: Int) {
        // One native pass. The host is laid out at the width the text wraps
        // at; the height it settles on is read from that same pass through
        // the intrinsic size SwiftUI has just computed, so nothing asks it to
        // size the tree a second time for the same answer.
        layoutSubtreeIfNeeded()
        let intrinsic = intrinsicContentSize.height
        // A host that has not published one yet is asked directly; that is a
        // second pass, and the count is what says how often it happens.
        return intrinsic > 0 ? (max(1, ceil(intrinsic)), 1) : (max(1, ceil(fittingSize.height)), 2)
    }
    func confirmHeight() -> CGFloat { max(1, ceil(fittingSize.height)) }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }
}

extension TranscriptRowRenderer {
    /// Off draws every row through the SwiftUI reference row
    /// (`TranscriptHostedRowContent`), for checks that a native row reads
    /// exactly as the SwiftUI one it replaced.
    static var native: Bool {
        get { reference == nil }
        set { reference = newValue ? nil : { TranscriptHostedRowContent(inputs: $0) } }
    }
}
