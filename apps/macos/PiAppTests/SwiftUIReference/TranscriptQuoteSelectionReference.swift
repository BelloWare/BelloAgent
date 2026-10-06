import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TranscriptQuoteSelection.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// A geometry-only marker behind assistant prose (including its code blocks).
/// User text, reasoning/tool details and accounting labels have no marker.
/// It neither intercepts input nor introduces another text/hosting surface.
struct TranscriptQuoteRegion: NSViewRepresentable {
    let messageID: String
    func makeNSView(context: Context) -> TranscriptQuoteRegionView { TranscriptQuoteRegionView() }
    func updateNSView(_ view: TranscriptQuoteRegionView, context: Context) { view.messageID = messageID }
}
