// Frozen turn-token drawing from 59ef8e0d, for visual parity only.
import AppKit
import SwiftUI
@testable import PiApp

// The SwiftUI drawing of a turn's token shares, for the Session Inspector's
// turn page and the routing analytics, which are SwiftUI views. The
// transcript draws the same bar natively (`TranscriptNativeTokenBar`).

/// Two non-overlapping shares, or one filled track when only a reported total
/// is available. Zero and unreported counts stay empty. A tiny Canvas avoids a chart
/// engine and never animates the transcript's geometry while streaming.
struct TurnTokenBarReference: View {
    let partition: TurnTokenPartition
    private var primary: Color { partition.title == "Input" ? .piSuccess : .monitorModel(2) }
    private var secondary: Color { .piAccent }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(partition.title).foregroundStyle(TranscriptPalette.faint)
                Text(partition.totalLabel).foregroundStyle(TranscriptPalette.text)
            }.font(.system(size: 11, weight: .medium)).lineLimit(1)
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(Color.piFillStrong))
                switch partition.fill {
                case .empty: break
                case .reported:
                    context.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(secondary.opacity(0.75)))
                case .split(let fraction):
                    context.clip(to: Path(roundedRect: bounds, cornerRadius: 2))
                    context.fill(Path(bounds), with: .color(secondary.opacity(0.75)))
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)), with: .color(primary))
                }
            }.frame(height: 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                legend(partition.label(part: true), primary)
                legend(partition.label(part: false), secondary)
            }.font(.system(size: 9.5)).foregroundStyle(TranscriptPalette.muted).fixedSize(horizontal: true, vertical: false)
        }.monospacedDigit().help(partition.help)
            .accessibilityElement(children: .ignore).accessibilityLabel(partition.help)
    }
    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 4, height: 4); Text(text) }
    }
}
