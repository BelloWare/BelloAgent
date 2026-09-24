import SwiftUI
import AppKit

// The transcript's side of message versions and forks: the switcher under an
// edited message, the quiet banner over an earlier version, and the commands
// a reply's right-click menu offers.

/// `‹ 2 / 2 ›` under an edited message: the chevrons show the version before
/// or after, the figure which one is on screen. It stands where the edit's
/// marker row used to, and ⌥← and ⌥→ do the same from the keyboard.
struct VersionSwitcher: View {
    let messageID: String
    let mark: MessageVersionMark
    let step: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            VersionChevron(symbol: "chevron.left", label: "Earlier version", enabled: mark.index > 1) { step(-1) }
            Text("\(mark.index) / \(mark.count)")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(TranscriptPalette.muted)
                .padding(.horizontal, 2)
                .fixedSize()
            VersionChevron(symbol: "chevron.right", label: "Later version", enabled: mark.index < mark.count) { step(1) }
        }
        .frame(height: 22)
        .background(VersionSwitcherMarker(messageID: messageID, mark: mark))
        .help("Version \(mark.index) of \(mark.count) · ⌥← and ⌥→ switch versions")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version \(mark.index) of \(mark.count)")
        .accessibilityIdentifier("version-switcher")
    }
}

private struct VersionChevron: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(!enabled ? TranscriptPalette.faint.opacity(0.45) : hovering ? TranscriptPalette.text : TranscriptPalette.muted)
                .frame(width: 18, height: 18)
                .background(hovering && enabled ? TranscriptPalette.panelStrong : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .piPointer()
        .accessibilityLabel(label)
    }
}

/// The quiet line over an earlier version: what the reader is looking at,
/// and the way back. Everything under it is read-only.
struct VersionBannerRow: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium)).foregroundStyle(TranscriptPalette.faint)
            Text(message.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(TranscriptPalette.muted).fixedSize()
            separator
            Text(message.detail ?? "").font(.system(size: 12)).foregroundStyle(TranscriptPalette.faint).lineLimit(1)
            separator
            Button { actions.latestVersion?() } label: {
                Text("Back to latest").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TranscriptPalette.accent)
                    .underline(hovering)
            }
            .buttonStyle(.plain).piPointer().fixedSize()
            .onHover { hovering = $0 }
            .accessibilityIdentifier("version-back-to-latest")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(TranscriptPalette.panel, in: Capsule())
        .overlay(Capsule().stroke(TranscriptPalette.hair, lineWidth: 1))
        .background(VersionBannerMarker())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 6).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Earlier version, replies from before your edit")
        .accessibilityIdentifier("version-banner")
    }
    private var separator: some View {
        RoundedRectangle(cornerRadius: 1).fill(TranscriptPalette.faint).frame(width: 2, height: 2).accessibilityHidden(true)
    }
}

/// Marks a version switcher in the view tree, so a check can find which
/// message shows one and which version it says. Draws nothing, takes no
/// clicks and never sizes itself.
struct VersionSwitcherMarker: NSViewRepresentable {
    let messageID: String
    let mark: MessageVersionMark
    func makeNSView(context: Context) -> VersionSwitcherMarkerView { VersionSwitcherMarkerView() }
    func updateNSView(_ view: VersionSwitcherMarkerView, context: Context) {
        if view.messageID != messageID { view.messageID = messageID }
        if view.mark != mark { view.mark = mark }
    }
}
final class VersionSwitcherMarkerView: NSView {
    var messageID = ""
    var mark: MessageVersionMark?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// Marks the earlier-version banner, likewise.
struct VersionBannerMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> VersionBannerMarkerView { VersionBannerMarkerView() }
    func updateNSView(_ view: VersionBannerMarkerView, context: Context) {}
}
final class VersionBannerMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Whether the chat on screen can fork from its replies (a saved chat of the
/// app's own). The pane sets it; the transcript's rows carry it to each row.
private struct TranscriptForksKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var transcriptForks: Bool {
        get { self[TranscriptForksKey.self] }
        set { self[TranscriptForksKey.self] = newValue }
    }
}

/// A reply's right-click commands, built when the menu opens.
enum ReplyMenu {
    /// "Fork from Here" is offered on a finished reply of a chat that can fork.
    static func forks(_ message: TranscriptMessage, enabled: Bool) -> Bool {
        enabled && message.role == "assistant" && message.kind == nil && !message.isStreaming && !message.isSending
            && message.stopReason != "interrupted"
    }
    @MainActor static func entries(_ message: TranscriptMessage, actions: TranscriptActions, forks: Bool, fold: (title: String, perform: () -> Void)? = nil) -> [PiMenuEntry] {
        var entries: [PiMenuEntry] = []
        if let fold { entries.append(.button(fold.title) { fold.perform() }); entries.append(.divider) }
        entries.append(.button("Copy Reply", identifier: "reply-copy") { actions.copyMessage(message.id) })
        entries.append(.button("Request Details", identifier: "reply-details") { actions.inspect(message.id) })
        if Self.forks(message, enabled: forks), let fork = actions.fork {
            entries.append(.divider)
            entries.append(.button("Fork from Here", systemImage: "arrow.triangle.branch", identifier: "reply-fork",
                                   help: "A new chat that ends at this reply") { fork(message.id) })
        }
        return entries
    }
}
