import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/NativeCodeText.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// A persistent selectable leaf. The fence's chrome and complete-source copy
/// action stay in CodeBlockView; TextKit owns only literal code and wrapping.
struct NativeCodeText: NSViewRepresentable {
    // Internal comparison seam. Small fences keep the cheaper SwiftUI leaf;
    // a large fence uses TextKit's bounded drawing and incremental text storage.
    static var enabled: Bool { get { TranscriptCodeTextView.enabled } set { TranscriptCodeTextView.enabled = newValue } }
    static var minimumBytes: Int { TranscriptCodeTextView.minimumBytes }
    let source: String
    let language: String?
    let size: CGFloat
    func makeNSView(context: Context) -> TranscriptCodeTextView { TranscriptCodeTextView() }
    func updateNSView(_ view: TranscriptCodeTextView, context: Context) {
        view.update(source: source, language: language, size: size, environment: TranscriptRowEnvironment(context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptCodeTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}
