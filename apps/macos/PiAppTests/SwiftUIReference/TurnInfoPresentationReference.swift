import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TurnInfoPresentation.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

struct TurnInfoButton: NSViewRepresentable {
    let turn: TurnSummary
    let actions: TranscriptActions
    func makeNSView(context: Context) -> TurnInfoNSButton { TurnInfoNSButton() }
    func updateNSView(_ button: TurnInfoNSButton, context: Context) { button.turn = turn; button.actions = actions }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TurnInfoNSButton, context: Context) -> CGSize? { TurnInfoNSButton.size }
}
