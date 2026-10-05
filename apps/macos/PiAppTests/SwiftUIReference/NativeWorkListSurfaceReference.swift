import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/NativeWorkListSurface.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// A turn's tool calls, drawn natively. A turn that ran sixty of them retains
/// every card and its exact height, while only the cards near the outer
/// conversation viewport participate in native layout, drawing and tracking.
/// This is not another scroll view and it truncates nothing: every card is
/// still there, still openable, still selectable once it is on screen.
///
/// The reason a long turn can be folded and unfolded inside a frame is that a
/// card the reader has not opened is one line high whatever it says — the
/// header truncates to a single line and every badge on it is shorter than
/// that line. So measuring one closed card measures all of them, and only the
/// cards the reader has actually opened are laid out individually. The
/// assumption is not taken on trust: every card that mounts is checked against
/// the height it was placed at, and a card that disagrees keeps its own.
struct NativeWorkListSurface: NSViewRepresentable {
    /// Below this a turn is short enough that the plain SwiftUI stack is both
    /// simpler and cheaper than a hosting view per card.
    static var minimumRowCount: Int { NativeWorkListContainer.minimumRowCount }
    let tools: [ToolView]
    let openTools: Set<String>
    let fetched: [String: ToolInputDocument]
    let toggle: (String) -> Void
    var openFile: ((String, ClosedRange<Int>?) -> Void)? = nil

    func makeNSView(context: Context) -> NativeWorkListContainer {
        let view = NativeWorkListContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeWorkListContainer, context: Context) {
        view.update(tools: tools, openTools: openTools, fetched: fetched, toggle: toggle, openFile: openFile,
                    environment: TranscriptRowEnvironment(context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeWorkListContainer, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}
