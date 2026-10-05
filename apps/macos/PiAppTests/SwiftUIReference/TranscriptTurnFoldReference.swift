import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TranscriptTurnFold.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// The one line a folded turn reads as, and the control that opens it. It is a
/// button in its own right and it is never itself folded, so the keyboard
/// always has somewhere to stand: closing the fold leaves focus on this row
/// rather than on a row that has just stopped drawing.
struct TurnFoldControlRow: View {
    let spec: TurnFoldSpec
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    /// Shown only when focus came from the keyboard; a click leaves none.
    @State private var ringShown = false
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(spec.label).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.muted)
                    .lineLimit(1).truncationMode(.tail).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.faint)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .animation(reduceMotion ? nil : .easeOut(duration: TranscriptRowChrome.chevronSeconds), value: open)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(TranscriptPalette.hair).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .focusable()
        .focused($focused)
        // Its own outline over the whole line, instead of the system's ring.
        .focusEffectDisabled()
        .modifier(TranscriptFocusRing(shown: ringShown))
        .onChange(of: focused) { _, now in ringShown = now && !hovering }
        .onKeyPress { press in
            guard TranscriptRowChrome.activates(press.key) else { return .ignored }
            toggle(); return .handled
        }
        .onHover { hovering = $0 }
        .padding(.bottom, open ? 4 : 8)
        .help(open ? "Hide this turn's work" : "Show this turn's work")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spec.label)
        .accessibilityValue(open ? "Open" : "Closed")
        .accessibilityIdentifier("turn-fold")
    }
}
