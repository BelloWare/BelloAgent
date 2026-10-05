import SwiftUI

/// The transcript's colours for the SwiftUI views outside the transcript
/// that still draw with them (the shimmer and Back to bottom of
/// Design/PiFlowIndicators.swift, the turn token bar, file syntax). The
/// transcript itself draws with `TranscriptNSPalette`, which these wrap.
enum TranscriptPalette {
    static let text = Color(nsColor: TranscriptNSPalette.text)
    static let muted = Color(nsColor: TranscriptNSPalette.muted)
    static let faint = Color(nsColor: TranscriptNSPalette.faint)
    static let hair = Color(nsColor: TranscriptNSPalette.hair)
    static let hairStrong = Color(nsColor: TranscriptNSPalette.hairStrong)
    static let panel = Color(nsColor: TranscriptNSPalette.panel)
    static let panelStrong = Color(nsColor: TranscriptNSPalette.panelStrong)
    static let surface = Color(nsColor: TranscriptNSPalette.surface)
    static let canvas = Color(nsColor: TranscriptNSPalette.canvas)
    static let accent = Color(nsColor: TranscriptNSPalette.accent)
    static let accentSoft = Color(nsColor: TranscriptNSPalette.accentSoft)
    static let userBackground = Color(nsColor: TranscriptNSPalette.userBackground)
    static let toolBackground = Color(nsColor: TranscriptNSPalette.toolBackground)
    static let codeBackground = Color(nsColor: TranscriptNSPalette.codeBackground)
    static let statusBackground = Color(nsColor: TranscriptNSPalette.statusBackground)
    static let danger = Color(nsColor: TranscriptNSPalette.danger)
    static let success = Color(nsColor: TranscriptNSPalette.success)
    static let warning = Color(nsColor: TranscriptNSPalette.warning)
    static let keyword = Color(nsColor: TranscriptNSPalette.keyword)
    static let string = Color(nsColor: TranscriptNSPalette.string)
    static let number = Color(nsColor: TranscriptNSPalette.number)
    static let comment = Color(nsColor: TranscriptNSPalette.comment)
    static let diffAdded = Color(nsColor: TranscriptNSPalette.diffAdded)
    static let diffAddedMark = Color(nsColor: TranscriptNSPalette.diffAddedMark)
}
