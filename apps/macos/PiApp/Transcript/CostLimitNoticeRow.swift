import SwiftUI
import AppKit

/// Where a chat stopped at its cost limit, or refused a message because it
/// was there: the helper's own words, what happens to what was waiting, and
/// the one thing to do next. While the spend is at the limit that is Raise
/// limit…, which opens the chat's limit editor over the button; once the limit
/// is above the spend, a stopped run offers Continue.
///
/// Amber rather than red: the run did what the owner asked it to.
struct CostLimitNoticeRow: View {
    let message: TranscriptMessage
    var actions = TranscriptActions()
    /// The limit is above the spend again.
    private var raised: Bool { message.failureCode == SessionDisplay.costLimitRaised }
    /// A stopped run, rather than a refused message.
    private var run: Bool { message.id.hasPrefix("failure:run:") }
    @State private var raiseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: raised ? "checkmark.circle.fill" : "dollarsign.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(raised ? TranscriptPalette.accent : TranscriptPalette.warning)
                    .accessibilityHidden(true)
                Text(raised ? "Cost limit raised" : run ? "Stopped at this chat's cost limit" : "This chat is at its cost limit")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(raised ? TranscriptPalette.accent : TranscriptPalette.warning)
                Spacer(minLength: 0)
                if raised {
                    if run {
                        Button { actions.costLimit?(.continueRun, nil) } label: {
                            Label("Continue", systemImage: "play.fill").font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(TranscriptPillStyle(accent: true))
                        .help("Send the stopped request again from where the run stopped, with this chat's current model and effort; queued follow-ups go on after it")
                        .accessibilityIdentifier("cost-limit-continue")
                    }
                } else {
                    raiseButton
                }
            }
            Text(message.text).font(.system(size: 13)).foregroundStyle(TranscriptPalette.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let detail = message.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((raised ? TranscriptPalette.accentSoft : TranscriptPalette.warning.opacity(0.09)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke((raised ? TranscriptPalette.accent : TranscriptPalette.warning).opacity(0.35), lineWidth: 1))
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel((raised ? "Cost limit raised: " : "Cost limit reached: ") + message.text)
        .accessibilityIdentifier("cost-limit-notice")
    }

    /// The pill's face, with an AppKit press target over it: the editor is a
    /// popover anchored to this button.
    private var raiseButton: some View {
        Label("Raise limit…", systemImage: "arrow.up.circle").font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(raiseHovered ? TranscriptPalette.accent : TranscriptPalette.text)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(raiseHovered ? TranscriptPalette.panelStrong : TranscriptPalette.surface, in: Capsule())
            .overlay(Capsule().stroke(raiseHovered ? TranscriptPalette.accent : TranscriptPalette.hairStrong, lineWidth: 1))
            .fixedSize()
            .overlay {
                PiPopoverTrigger(label: "Raise limit…", identifier: "cost-limit-raise",
                                 help: "Choose a higher limit for this chat, or no limit",
                                 onHover: { raiseHovered = $0 },
                                 onPress: { anchor in actions.costLimit?(.raise, anchor) })
            }
    }
}
