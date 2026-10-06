// Frozen composer Inspector button at 59ef8e0d.
import AppKit
import SwiftUI
@testable import PiApp

/// The composer bar's pie button: the chat's Session Inspector, at its Overview.
struct SessionUsageButtonReference: View {
    let model: WorkspaceModel
    let chat: ChatRecord
    @ObservedObject var footer: SessionMetrics
    var costLabel: String? = nil

    @State private var hovering = false

    private func showWindow() { model.openInspector(session: chat.id, focus: .overview) }

    /// The face is SwiftUI; an AppKit press target over it takes the press,
    /// as over the pills under the composer.
    var body: some View {
        face
            .accessibilityElement(children: .ignore).accessibilityHidden(true)
            .overlay {
                PiPopoverTrigger(label: "Session Inspector: cost, tokens, time and every request",
                                 identifier: costLabel == nil ? "sessionUsageButton" : "sessionUsageCostButton",
                                 help: "Open the Session Inspector: what this chat cost and used, how fast it ran, and every request it made",
                                 onHover: { inside in if hovering != inside { hovering = inside } }, onPress: { _ in showWindow() })
            }
    }

    @ViewBuilder private var face: some View {
        if let costLabel {
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle").font(.system(size: 10))
                Text(costLabel).lineLimit(1).monospacedDigit().fixedSize()
            }
            .foregroundStyle(hovering ? Color.piInk : Color.piInkSecondary)
        } else {
            Image(systemName: "chart.pie")
                .font(.system(size: 28 * 0.46, weight: .medium)).foregroundStyle(Color.piInkSecondary)
                .frame(width: 28, height: 28)
                .background(hovering ? Color.piFillStrong : Color.clear, in: Circle())
                .piAnimation(PiMotion.quick, value: hovering)
        }
    }
}
