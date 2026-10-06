import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/NativeMarkdownSurface.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// A rendered reply: one TextKit text holding every block of it, so a
/// selection runs across paragraphs, list items, headings, code and tables,
/// and a copy is the text it covers (`MarkdownTextDocument.swift`).
///
/// The surface reads the message itself (`StreamingMarkdownState`), so a token
/// extends the reply without SwiftUI rebuilding anything: the text changes
/// only from the first character that reads differently, TextKit lays out
/// again only from there, and a selection above it stays as it was.
struct NativeMarkdownSurface: NSViewRepresentable {
    let source: String
    let style: MarkdownStyle
    let capsWidth: Bool
    let streaming: Bool
    let headings: [MarkdownCopyTarget]
    /// Which reply this is, so a token can be handed to the surface that is
    /// carrying it.
    var identity: String = ""
    /// The reader is reading this reply as its source (`ReplySource`). The
    /// surface keeps its text and every height it measured, but draws
    /// nothing and takes no room, so switching back finds the rendered reply
    /// exactly as the reader left it.
    var parked = false
    var resolveFile: (@MainActor (String) async -> ReplyFileLocation?)? = nil
    var openFile: ((String, ClosedRange<Int>?) -> Void)? = nil

    func makeNSView(context: Context) -> NativeMarkdownContainer {
        let view = NativeMarkdownContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeMarkdownContainer, context: Context) {
        view.read(source: source, style: style, capsWidth: capsWidth, streaming: streaming, headings: headings,
                  environment: TranscriptRowEnvironment(context.environment), identity: identity)
        view.park(parked)
        view.textView.resolveFile = resolveFile
        view.textView.openFile = openFile
        view.textView.fileLinkIdentity = identity
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownContainer, context: Context) -> CGSize? {
        parked ? CGSize(width: proposal.width ?? 0, height: 0) : nsView.measure(width: proposal.width)
    }
}
