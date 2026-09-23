import SwiftUI

/// The sidebar's rate slot: the latest completed request's output rate, as
/// plain text in one stable slot. No per-second clock or streamed-byte
/// measurement participates; a local fade happens only when completed usage
/// changes. The timing history behind it is in the Session Inspector.
struct SidebarReportedRate: View {
    let history: SessionTimingHistory
    let sessionTitle: String
    private var presentation: SessionRatePresentation { SessionRatePresentation(history: history) }
    var body: some View {
        Text(presentation.label)
            .font(PiFont.caption.monospacedDigit()).lineLimit(1)
            .frame(width: 108, alignment: .leading)
            .foregroundStyle(presentation.latest == nil ? Color.piInkTertiary : Color.piInkSecondary)
            .contentTransition(.opacity).piAnimation(PiMotion.quick, value: presentation.label)
            .help(SessionRatePresentation.explanation)
            .accessibilityLabel("Latest completed output rate")
            .accessibilityValue(presentation.label)
            .accessibilityIdentifier("sidebar-reported-rate")
            .piStableLayout()
    }
}
