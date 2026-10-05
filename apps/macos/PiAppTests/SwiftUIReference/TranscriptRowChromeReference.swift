import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TranscriptRowChrome.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// The status mark that replaces a row's icon when a call failed or was
/// interrupted: a filled dot, the one place the row's outcome is a shape.
struct TranscriptStateDot: View {
    let state: TranscriptRowState
    var body: some View {
        Circle().fill(state.tint).frame(width: 7, height: 7)
            .frame(width: TranscriptRowChrome.leading, height: TranscriptRowChrome.leading)
            .accessibilityHidden(true)
    }
}

/// A slow band of light crossing a row while its work runs. It paints over the
/// row and decides no geometry, so it cannot move anything; under Reduce Motion
/// it does not run at all.
private struct TranscriptRowShimmer: View {
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            if reduceMotion {
                Color.clear
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
                    let width = max(1, geometry.size.width)
                    let band = min(300, width)
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: TranscriptRowChrome.shimmerSeconds) / TranscriptRowChrome.shimmerSeconds
                    LinearGradient(colors: [.clear, TranscriptPalette.panelStrong, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (width + band) * phase)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The app's own sign that a row has keyboard focus: the row's rounded box
/// tinted with the accent and traced with a thin accent line, just inside
/// the row's own bounds. It is the row's shape, never the shape of what the
/// row happens to be drawing, so nothing inside it (a running call's
/// shimmer, a summary still being written) can move or resize it.
struct TranscriptFocusRing: ViewModifier {
    let shown: Bool
    /// Built only while it shows: a turn of sixty calls has sixty rows, and
    /// only one of them can have focus.
    func body(content: Content) -> some View {
        content
            .background {
                if shown { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.piAccentSoft).allowsHitTesting(false) }
            }
            .overlay {
                if shown {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.piAccent.opacity(0.55), lineWidth: 1)
                        .background(TranscriptFocusMarker())
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
/// Marks a focus ring in the view tree, so a check can find where it is
/// and whether it shows. It draws nothing and takes no clicks.
struct TranscriptFocusMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> TranscriptFocusMarkerView { TranscriptFocusMarkerView() }
    func updateNSView(_ view: TranscriptFocusMarkerView, context: Context) {}
}

/// One work row: `[icon] Title · summary        suffix`, 24 pt tall, the whole
/// line a button. `content` is what it opens, already laid out by its owner.
struct TranscriptWorkRow<Content: View>: View {
    let icon: String
    let title: String
    /// The one-line argument summary. A failure replaces it with its first line.
    var summary: String = ""
    /// A fragment kept outside the ellipsized summary, so a narrow row clips
    /// the summary before it: a diff's `+N −M`, a read's line count.
    var suffix: String? = nil
    var state: TranscriptRowState = .ok
    /// Whether this row has anything to open at all.
    var expandable = true
    var open = false
    var toggle: () -> Void = {}
    /// A trailing figure that stays quiet: how long the call took.
    var trailing: String? = nil
    /// The summary is a ticker: it shows its newest characters and elides its
    /// beginning, so a line that is still being written reads from its end.
    var follow = false
    /// Shown in place of the icon when the row is a file the reader can open.
    var help: String? = nil
    /// The row's call has a file: this opens it. VoiceOver has it as the
    /// row's "Open File" whatever the summary says.
    var link: (() -> Void)? = nil
    /// Whether the summary is the file's path, and so the link: a failure's
    /// words in its place are not.
    var linksSummary = true
    /// What the row opens, as a closure rather than a stored view: a closed
    /// card must cost nothing at all. Building it eagerly meant every closed
    /// row assembled its whole card — and a file change ran its line diff — on
    /// every render, sixty times over for a turn of sixty edits.
    ///
    /// Name it — `content:` — unless the call has already passed `toggle:`: an
    /// unlabelled trailing closure binds to the first closure parameter after
    /// the last one named, which is `toggle`, and a row whose body became its
    /// toggle draws nothing and says nothing.
    let content: () -> Content
    @State private var hovering = false
    @FocusState private var focused: Bool
    /// Whether the row shows that it has focus: only when focus came from the
    /// keyboard. A click opens the row, and leaves no outline behind.
    @State private var ringShown = false
    @Environment(\.piReduceMotion) private var reduceMotion

    /// `link` comes before `toggle`: an unlabelled trailing closure after the
    /// last argument named binds to the next closure parameter, which must be
    /// `content`.
    init(icon: String, title: String, summary: String = "", suffix: String? = nil,
         state: TranscriptRowState = .ok, expandable: Bool = true, open: Bool = false,
         link: (() -> Void)? = nil, linksSummary: Bool = true,
         toggle: @escaping () -> Void = {}, trailing: String? = nil, follow: Bool = false,
         help: String? = nil, @ViewBuilder content: @escaping () -> Content = { EmptyView() }) {
        self.icon = icon; self.title = title; self.summary = summary; self.suffix = suffix
        self.state = state; self.expandable = expandable; self.open = open
        self.toggle = toggle; self.trailing = trailing; self.follow = follow; self.help = help
        self.link = link; self.linksSummary = linksSummary
        self.content = content
    }

    private var spoken: String {
        [state.spokenStatus, title, summary, suffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { if expandable { toggle() } }) { line }
                .buttonStyle(.plain)
                .piPointer()
                .focusable(expandable)
                .focused($focused)
                // The system's ring traces whatever the row draws, a running
                // call's shimmer included, so it changed width as the shimmer
                // moved. The row draws its own, over the whole row.
                .focusEffectDisabled()
                .modifier(TranscriptFocusRing(shown: ringShown && expandable))
                .onChange(of: focused) { _, now in ringShown = now && !hovering }
                .onKeyPress { press in
                    guard expandable, TranscriptRowChrome.activates(press.key) else { return .ignored }
                    toggle(); return .handled
                }
                .onHover { hovering = $0 }
                .help(help ?? summary)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(spoken)
                .accessibilityValue(expandable ? (open ? "Open" : "Closed") : "")
                .modifier(TranscriptOpenFileAction(link: link))
            if open, expandable { content() }
        }
    }
    private var line: some View {
        HStack(spacing: 0) {
            leadingBox
            Text(title).font(.system(size: 13))
                .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.muted)
                .fixedSize()
            if !summary.isEmpty {
                separator
                // A line still being written reads from its end: the ticker
                // elides its beginning, so the newest characters are the ones
                // on screen and the row's height never changes.
                TranscriptPathText(text: Text(summary).font(.system(size: 12.5))
                                    .foregroundStyle(state == .failed ? TranscriptPalette.danger : TranscriptPalette.faint),
                                   label: "Open \(summary)", help: help, open: linksSummary ? link : nil)
                    .lineLimit(1).truncationMode(follow ? .head : .tail)
            }
            if let suffix {
                Text(suffix).font(.system(size: 12.5)).monospacedDigit()
                    .foregroundStyle(TranscriptPalette.faint).fixedSize()
                    .padding(.leading, 8)
            }
            Spacer(minLength: 4)
            if let trailing, !trailing.isEmpty {
                Text(trailing).font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(TranscriptPalette.faint).fixedSize()
            }
        }
        .frame(height: TranscriptRowChrome.height)
        .contentShape(Rectangle())
        // The shimmer's band travels across the row and no further.
        .background(alignment: .leading) {
            if state == .running { TranscriptRowShimmer().clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
        }
        .background(hovering ? TranscriptPalette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    /// The icon, and the chevron it cross-fades into under the pointer. An open
    /// row is the chevron outright: what the leading box means is "this opens".
    private var leadingBox: some View {
        ZStack {
            if state == .failed || state == .stopped {
                TranscriptStateDot(state: state)
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state == .running ? TranscriptPalette.accent : TranscriptPalette.faint)
                    .opacity(expandable && (open || hovering) ? 0 : 1)
            }
            if expandable {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.faint)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .opacity(open || hovering ? 1 : 0)
            }
        }
        .frame(width: TranscriptRowChrome.leading, height: TranscriptRowChrome.leading)
        .padding(.trailing, TranscriptRowChrome.gap)
        .animation(reduceMotion ? nil : .easeOut(duration: TranscriptRowChrome.chevronSeconds), value: open)
        .animation(reduceMotion ? nil : .easeOut(duration: TranscriptRowChrome.chevronSeconds), value: hovering)
    }
    /// The 2 pt dot between the title and the summary.
    private var separator: some View {
        RoundedRectangle(cornerRadius: 1).fill(TranscriptPalette.faint)
            .frame(width: 2, height: 2).padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

/// A row whose call has a file says so to VoiceOver, as an action on the row:
/// the summary's press target, when it has one, sits under the row's one
/// accessible element.
private struct TranscriptOpenFileAction: ViewModifier {
    let link: (() -> Void)?
    func body(content: Content) -> some View {
        if let link { content.accessibilityAction(named: "Open File", link) } else { content }
    }
}

extension TranscriptRowChrome {
    /// Keys that activate a focused row. Space and Return only: a row is a
    /// button, and everything else belongs to the conversation around it.
    static func activates(_ key: KeyEquivalent) -> Bool { key == .return || key == .space }
}

extension TranscriptRowState {
    var tint: Color {
        switch self {
        case .ok: return TranscriptPalette.faint
        case .running: return TranscriptPalette.accent
        case .stopped: return TranscriptPalette.warning
        case .failed: return TranscriptPalette.danger
        }
    }
}
