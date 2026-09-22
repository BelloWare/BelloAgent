import SwiftUI

/// The one line every piece of work reads as: a tool call, a reasoning block,
/// a context injection, a folded turn. One height, one icon box, one title,
/// one summary — so a reply's work reads as a list rather than as a stack of
/// differently shaped boxes.
///
/// Status is carried by colour and by one hidden word, never by a second badge
/// on the line: a failure replaces the summary with its first line, a stopped
/// call turns its dot amber, and a running row sweeps slowly. The whole row is
/// the control, for the pointer and for the keyboard, and the icon cross-fades
/// into the chevron under the pointer so the line never grows a second glyph.
enum TranscriptRowChrome {
    /// The line box every work row shares.
    static let height: CGFloat = 24
    /// The leading box the icon and the chevron both sit in.
    static let leading: CGFloat = 16
    /// Between the leading box and the title.
    static let gap: CGFloat = 6
    /// Where content opened under a row starts, so it lines up with the title.
    static let indent: CGFloat = leading + gap
    /// The icon-to-chevron cross-fade, and the chevron's own turn.
    static let chevronSeconds = 0.1
    /// A fold opening or closing. Quicker than `PiMotion.base`: a disclosure
    /// is an answer to a click, not an entrance, and at 220 ms a reader
    /// opening several rows in a row waits on the transcript. The curve is the
    /// same ease-out, so nothing else about the motion changes.
    static let foldSeconds = 0.16
    /// One sweep of the running shimmer.
    static let shimmerSeconds = 2.6

    /// Keys that activate a focused row. Space and Return only: a row is a
    /// button, and everything else belongs to the conversation around it.
    static func activates(_ key: KeyEquivalent) -> Bool { key == .return || key == .space }
}

/// Where a row stands. Only `running`, `stopped` and `failed` say anything;
/// a settled row is its icon and its summary.
enum TranscriptRowState: String, Sendable, Equatable {
    case ok, running, stopped, failed

    /// The word assistive technology hears, since the dot and the sweep are
    /// both colour.
    var spokenStatus: String? {
        switch self {
        case .ok: return nil
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
    var tint: Color {
        switch self {
        case .ok: return TranscriptPalette.faint
        case .running: return TranscriptPalette.accent
        case .stopped: return TranscriptPalette.warning
        case .failed: return TranscriptPalette.danger
        }
    }
}

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

/// What Stop leaves behind: the partial answer stays, and this says why it
/// ends where it does. Amber, because nothing failed — the reader stopped it.
struct TranscriptStoppedChip: View {
    var detail: String = "Its partial answer is retained separately from the retry."
    var body: some View {
        HStack(spacing: 5) {
            TranscriptStateDot(state: .stopped).frame(width: 7)
            Text("Stopped").font(.system(size: 11, weight: .medium)).foregroundStyle(TranscriptPalette.warning)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(TranscriptPalette.warning.opacity(0.14), in: Capsule())
        .fixedSize()
        .help(detail)
        .accessibilityLabel("Stopped. " + detail)
        .accessibilityIdentifier("reply-stopped")
    }
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
    @Environment(\.piReduceMotion) private var reduceMotion

    init(icon: String, title: String, summary: String = "", suffix: String? = nil,
         state: TranscriptRowState = .ok, expandable: Bool = true, open: Bool = false,
         toggle: @escaping () -> Void = {}, trailing: String? = nil, follow: Bool = false,
         help: String? = nil, @ViewBuilder content: @escaping () -> Content = { EmptyView() }) {
        self.icon = icon; self.title = title; self.summary = summary; self.suffix = suffix
        self.state = state; self.expandable = expandable; self.open = open
        self.toggle = toggle; self.trailing = trailing; self.follow = follow; self.help = help
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
                Text(summary).font(.system(size: 12.5))
                    .foregroundStyle(state == .failed ? TranscriptPalette.danger : TranscriptPalette.faint)
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
        .background(alignment: .leading) { if state == .running { TranscriptRowShimmer() } }
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
