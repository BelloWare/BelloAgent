import SwiftUI
import AppKit

/// The skills a sent message used, as pills at the start of its bubble —
/// ahead of the text, where the model received them. They look like the
/// composer's tokens; resting the pointer on one previews it, a press opens
/// its details.
///
/// Every pill is the same height and the row is a plain flow, so the bubble
/// is measured once and at its final height: nothing here waits on the
/// catalog, the helper or the pointer.
struct TranscriptSkillPills: View {
    let messageID: String
    let skills: [TranscriptSkillUse]
    let actions: TranscriptActions
    nonisolated static let spacing: CGFloat = 6
    var body: some View {
        PiFlow(spacing: Self.spacing, rowSpacing: Self.spacing) {
            ForEach(skills) { use in TranscriptSkillPill(messageID: messageID, use: use, actions: actions) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(skills.count == 1 ? "Skill used by this message" : "Skills used by this message")
        .accessibilityIdentifier("transcript-skill-pills")
    }
}

private struct TranscriptSkillPill: View {
    let messageID: String
    let use: TranscriptSkillUse
    let actions: TranscriptActions
    @State private var hovering = false
    @ObservedObject private var popovers = SkillPopovers.shared
    var body: some View {
        let key = SkillPopovers.sentKey(messageID: messageID, skillID: use.id)
        // What the pill says without the catalog: the row cannot see it, and
        // must not wait for it. The popover compares with the current one.
        let detail = SkillDetail.sent(use, catalog: SkillCatalog())
        SkillPillFace(name: use.name, arguments: use.arguments, hovered: hovering, open: popovers.openKey == key)
            .overlay {
                SkillPillTrigger(label: detail.accessibilityLabel, help: detail.accessibilityHelp + ". Press to show its details.",
                                 copied: SkillPillLabel.copied(use.name), identifier: "skill-pill-" + use.name,
                                 onHover: { anchor, inside in
                                     hovering = inside
                                     actions.skillHovered?(messageID, use, anchor, inside)
                                 },
                                 onPress: { anchor in actions.skillPressed?(messageID, use, anchor) })
            }
    }
}

/// `SkillPillButton` over a pill's SwiftUI face, sized to it.
struct SkillPillTrigger: NSViewRepresentable {
    let label: String
    let help: String
    let copied: String
    var identifier: String?
    let onHover: (NSView, Bool) -> Void
    let onPress: (NSView) -> Void

    func makeNSView(context: Context) -> SkillPillButton {
        let button = SkillPillButton(frame: .zero)
        apply(to: button)
        return button
    }
    func updateNSView(_ button: SkillPillButton, context: Context) { apply(to: button) }
    private func apply(to button: SkillPillButton) {
        let hover = onHover, press = onPress
        button.onHover = { view, inside in hover(view, inside) }
        button.onPress = { view in press(view) }
        button.copiedText = copied
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.accessibilityHelp() != help { button.setAccessibilityHelp(help) }
        if button.accessibilityIdentifier() != (identifier ?? "") { button.setAccessibilityIdentifier(identifier) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SkillPillButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
