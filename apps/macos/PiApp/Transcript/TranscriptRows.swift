import SwiftUI
import AppKit

// The rows of the conversation, drawn natively: user bubbles, replies with
// their work line, tool cards with diffs, turn lines, and the status rows the
// host and app add. Every figure comes from TranscriptActivity; nothing here
// computes usage or timing itself.

/// What a row can ask the pane to do.
struct TranscriptActions {
    var inspect: (String) -> Void = { _ in }
    var edit: (String) -> Void = { _ in }
    var copyMessage: (String) -> Void = { _ in }
    var stop: () -> Void = {}
    /// Runs the failed turn again from where it stopped.
    var retry: () -> Void = {}
    /// Nil for panes that cannot create a child conversation.
    var quoteReply: ((TranscriptQuote) -> Void)? = nil
    /// The turn report's info button: the Session Inspector at that turn.
    var inspectTurn: ((TurnSummary) -> Void)? = nil
    /// A skill pill in a sent message (the message's id, the skill, the pill)
    /// was pressed; nil where no popover can open.
    var skillPressed: ((String, TranscriptSkillUse, NSView) -> Void)? = nil
    /// The pointer entered or left a sent message's skill pill.
    var skillHovered: ((String, TranscriptSkillUse, NSView, Bool) -> Void)? = nil
    /// The cost-limit notice: raise the limit (the editor opens over the
    /// button it passes), or continue a run stopped there.
    var costLimit: ((CostLimitNoticeAction, NSView?) -> Void)? = nil
    /// "Fork from here" on a reply: a new chat that ends at it. The rows
    /// offer it where the pane's `transcriptForks` says the chat can fork.
    var fork: ((String) -> Void)? = nil
    /// An edited message's switcher: the version this many steps away (‹ −1, › +1).
    var switchVersion: ((String, Int) -> Void)? = nil
    /// The earlier-version banner's Back to latest.
    var latestVersion: (() -> Void)? = nil
}

enum TranscriptMetrics {
    static let proseWidth: CGFloat = 640
    static let pageWidth: CGFloat = 840
}

/// The dots between figures on a work or turn line, as the stylesheet drew them.
private func dotted(_ parts: [Text]) -> Text {
    var result = Text("")
    for (index, part) in parts.enumerated() {
        if index > 0 { result = result + Text(" · ").foregroundColor(TranscriptPalette.faint) }
        result = result + part
    }
    return result
}
private func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

/// One figure of a work or turn line: a text, or a control such as the model
/// link; a dot precedes every figure but the first unless it says otherwise.
struct FigureItem {
    var text: Text? = nil
    var view: AnyView? = nil
    var dotted = true
    static func text(_ text: Text) -> FigureItem { FigureItem(text: text) }
    static func view<V: View>(_ view: V, dotted: Bool = true) -> FigureItem { FigureItem(view: AnyView(view), dotted: dotted) }
}

/// Figures that flow like a sentence: a narrow pane wraps between them, never
/// after a dot, and a control keeps its place in the sentence.
struct FigureFlow: View {
    let items: [FigureItem]
    var font: Font = .system(size: 12.5, weight: .medium)
    var color: Color = TranscriptPalette.faint
    var body: some View {
        PiFlow(spacing: 0, rowSpacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                // The dot trails the figure it follows, so a wrapped line never starts with one.
                HStack(spacing: 0) {
                    if let text = item.text { text.font(font).foregroundStyle(color).monospacedDigit() }
                    if let view = item.view { view }
                    if index + 1 < items.count && items[index + 1].dotted { Text(" · ").font(font).foregroundStyle(TranscriptPalette.faint) }
                }
            }
        }
    }
}

/// The quiet mark under a message the reader has just sent, until the
/// helper's own row for it takes its place. A helper that is up takes a
/// message within a frame or two, so the mark waits before it shows: it is
/// there for a send that is slow, not a flash on every one that is not.
struct TranscriptSendingMark: View {
    static let delay = Duration.milliseconds(400)
    @State private var shown = false
    var body: some View {
        Text("Sending…").font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.faint)
            .opacity(shown ? 1 : 0).piAnimation(PiMotion.quick, value: shown)
            .task { if (try? await Task.sleep(for: Self.delay)) != nil { shown = true } }
            .accessibilityLabel("Sending")
            .accessibilityIdentifier("messageSending")
    }
}

/// A small ring that turns while something is under way.
struct SpinnerView: View {
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
            Circle().trim(from: 0.2, to: 1).stroke(TranscriptPalette.hairStrong, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .overlay(Circle().trim(from: 0, to: 0.22).stroke(TranscriptPalette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)))
                .rotationEffect(.degrees(angle))
                .frame(width: 11, height: 11)
        }
        .accessibilityHidden(true)
    }
}

/// The pill buttons under a row: Edit (user rows), Copy, View raw (finished
/// replies), Details and Fork from here. They show on hover, and they exist
/// only while the row is hovered: a few buttons with their hover tracking for
/// every row of a long chat is a large part of what opening one costs. The
/// band reserves their height either way, so nothing moves, and the same
/// actions stay reachable without a pointer through the row's accessibility
/// actions.
struct RowActionsView: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    let visible: Bool
    /// The reply's switch between rendered and source, where the row offers it.
    var source: ReplySourceToggle? = nil
    @Environment(\.piReduceMotion) private var reduceMotion
    @Environment(\.transcriptForks) private var forks
    /// One pill: its label, whether it wears the accent, and what it does.
    struct Pill: Identifiable {
        let title: String
        var accent = false
        let perform: () -> Void
        var id: String { title }
    }
    /// The pills a hovered row shows, in order.
    static func pills(_ message: TranscriptMessage, actions: TranscriptActions, forks: Bool, source: ReplySourceToggle?) -> [Pill] {
        var pills: [Pill] = []
        if MessageRowView.editable(message) { pills.append(Pill(title: "Edit", accent: true) { actions.edit(message.id) }) }
        pills.append(Pill(title: "Copy") { actions.copyMessage(message.id) })
        if let source { pills.append(Pill(title: ReplySource.title(raw: source.raw), perform: source.toggle)) }
        pills.append(Pill(title: "Details") { actions.inspect(message.id) })
        if ReplyMenu.forks(message, enabled: forks), let fork = actions.fork { pills.append(Pill(title: "Fork from here") { fork(message.id) }) }
        return pills
    }
    var body: some View {
        HStack(spacing: 4) {
            if visible {
                ForEach(Self.pills(message, actions: actions, forks: forks, source: source)) { pill in
                    self.pill(pill.title, accent: pill.accent, action: pill.perform)
                }
            }
        }
        .frame(height: 22)
        .piAnimation(PiMotion.quick, value: visible)
        .accessibilityHidden(true)
    }
    private func pill(_ title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11, weight: .medium)) }
            .buttonStyle(TranscriptPillStyle(accent: accent))
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 2)))
    }
}

/// One of a row's actions as assistive technology offers it: a name and
/// what it does.
struct TranscriptRowAction: Identifiable {
    let name: String
    let perform: () -> Void
    var id: String { name }
    /// The row's actions, for readers who never hover: VoiceOver reaches Edit,
    /// Copy, a reply's View raw, Details and Fork from here through the row
    /// itself rather than through pills that only a pointer can reveal. A
    /// message still being sent can only be copied.
    static func all(_ message: TranscriptMessage, _ actions: TranscriptActions, forks: Bool = false,
                    source: ReplySourceToggle? = nil) -> [TranscriptRowAction] {
        let id = message.id
        let copy = TranscriptRowAction(name: "Copy") { actions.copyMessage(id) }
        if message.isSending { return [copy] }
        var all: [TranscriptRowAction] = []
        let editable = MessageRowView.editable(message)
        if editable { all.append(TranscriptRowAction(name: "Edit") { actions.edit(id) }) }
        all.append(copy)
        if let source { all.append(TranscriptRowAction(name: ReplySource.title(raw: source.raw), perform: source.toggle)) }
        all.append(TranscriptRowAction(name: "Details") { actions.inspect(id) })
        if !editable, ReplyMenu.forks(message, enabled: forks), let fork = actions.fork {
            all.append(TranscriptRowAction(name: "Fork from here") { fork(id) })
        }
        return all
    }
}

extension View {
    /// The row's actions (`TranscriptRowAction.all`) as one list on the row.
    /// A list, not a modifier per case: which actions a row offers changes
    /// as a reply settles — Fork from here and View raw arrive — and that must
    /// never give the row's content a new identity, which would rebuild the
    /// reply's selectable text in the middle of the reader's selection.
    func transcriptRowActions(_ message: TranscriptMessage, _ actions: TranscriptActions, forks: Bool = false,
                              source: ReplySourceToggle? = nil) -> some View {
        let named = TranscriptRowAction.all(message, actions, forks: forks, source: source)
        return accessibilityActions {
            ForEach(named) { action in Button(action.name, action: action.perform) }
        }
    }
}

struct TranscriptPillStyle: ButtonStyle {
    var accent = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? (accent ? TranscriptPalette.accent : TranscriptPalette.text) : TranscriptPalette.muted)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.panelStrong : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(hovering && accent ? TranscriptPalette.accent : TranscriptPalette.hairStrong, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .piPointer()
    }
}

// MARK: - Markdown body

/// A rendered markdown body: one selectable text holding every block of
/// the message (`NativeMarkdownSurface`), with the whole message's copy
/// control on hover.
struct MarkdownBodyView: View {
    let source: String
    var style: MarkdownStyle = .prose
    var capsWidth = true
    var streaming = false
    var copyTargets: [MarkdownCopyTarget] = []
    var sourceIdentity = ""
    /// The reader is reading this reply as its source: the body keeps its
    /// place and its text's measurements, but draws nothing and takes no
    /// room until it is shown again.
    var parked = false
    @State private var hovering = false
    var body: some View {
        // The surface reads the message itself, so a token does not run this
        // body at all, and nothing here parses.
        let headings = copyTargets.filter { if case .section = $0.kind { return true }; return false }
        let introduction = copyTargets.first { $0.kind == .introduction || $0.kind == .whole }
        NativeMarkdownSurface(source: source, style: style, capsWidth: capsWidth, streaming: streaming,
                              headings: headings, identity: sourceIdentity, parked: parked)
            .frame(minHeight: source.isEmpty && streaming ? 22 : nil)
            .overlay(alignment: .leading) { if source.isEmpty && streaming { WaitingDots() } }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                // An overlay never changes the row's layout, so the control can
                // wait until the pointer is actually over this message.
                if let introduction, !streaming, !parked, hovering { CopyButton(target: introduction, visible: hovering).offset(y: -3) }
            }
            .onHover { hovering = $0 }
            .piStableLayout()
    }
}

/// Three pulsing dots before the first token arrives.
struct WaitingDots: View {
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { dots(phase: 3) }
            else {
                TimelineView(.periodic(from: .now, by: 0.4)) { context in
                    dots(phase: Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4)
                }
            }
        }
        .frame(height: 22).accessibilityLabel("Waiting for the reply")
    }
    private func dots(phase: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(TranscriptPalette.muted).frame(width: 7, height: 7).opacity(phase == 0 ? 0.25 : index < phase ? 1 : 0.25)
            }
        }
    }
}

/// The transcript's own disclosure line: the same chevron a turn's work header
/// uses, the whole line tappable, and no motion on anything that decides the
/// row's height — the AppKit row owns that and its frame snaps. Whether it is
/// open comes from the conversation, never from this view, so the row can be
/// re-measured in the same pass as the click. A stock `DisclosureGroup` draws
/// its chevron from the window's appearance rather than the row's colour
/// scheme, which is why the transcript does not use one.
struct TranscriptFoldHeader: View {
    let title: String
    let open: Bool
    let toggle: () -> Void
    var help: (open: String, closed: String) = ("Hide", "Show")
    var font: Font = .system(size: 12, weight: .medium)
    var color: Color = TranscriptPalette.faint
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.faint)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .piAnimation(PiMotion.base, value: open)
                    .frame(width: 18, height: 16)
                    .background(hovering ? TranscriptPalette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain).piPointer()
            .accessibilityHidden(true)
            Text(title).font(font).foregroundStyle(hovering ? TranscriptPalette.muted : color)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .help(open ? help.open : help.closed)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(open ? "Hide \(title)" : "Show \(title)")
    }
}

/// A code block: monospaced, wrapped, with the language and a copy control on hover.
struct CodeBlockView: View {
    let language: String?
    let code: String
    var size: CGFloat = 12.5
    @State private var hovering = false
    @State private var section = 0
    private let streaming: Bool
    @State private var usesNativeText: Bool
    init(language: String?, code: String, size: CGFloat = 12.5, streaming: Bool = false, nativeChoice: Bool? = nil) {
        self.language = language; self.code = code; self.size = size; self.streaming = streaming
        _usesNativeText = State(initialValue: nativeChoice ?? (NativeCodeText.enabled && (streaming || code.utf8.count >= NativeCodeText.minimumBytes)))
    }
    var body: some View {
        let slices = CodeBlockSections.ranges(code, enabled: !streaming)
        let index = min(section, max(0, slices.count - 1))
        let shown = slices.isEmpty ? code : CodeBlockSections.section(code, slices[index])
        VStack(alignment: .leading, spacing: 0) {
        ZStack(alignment: .topTrailing) {
            // Keep the chosen leaf for this block's mounted lifetime. Crossing
            // the size threshold while selecting/streaming must not replace
            // the native selection owner. Reopened large fences use TextKit.
            Group {
                if usesNativeText { NativeCodeText(source: shown, language: language, size: size) }
                else { Text(SyntaxHighlighter.attributed(shown, language: language, size: size)).lineSpacing(size * 0.4) }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 31).padding(.bottom, 10)
            // The toolbar sits in the block's reserved top padding, so it can
            // wait for the pointer rather than existing in every fence of a
            // long report.
            HStack(spacing: 6) {
                if hovering {
                    if let language { Text(language.lowercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(TranscriptPalette.faint).accessibilityLabel("Language \(language)") }
                    CopyButton(target: MarkdownCopyTarget(kind: .code, label: "Copy code", text: code), visible: hovering)
                }
            }
            .frame(height: 20)
            // Only the code is selectable. Inherited selection on decorative
            // toolbar text creates extra AppKit text fields in every code fence.
            .textSelection(.disabled)
            .padding(.trailing, 8).padding(.top, 5)
        }
        if slices.count > 1 {
            HStack {
                Button("Previous section") { section = max(0, index - 1) }.disabled(index == 0)
                Text("Code section \(index + 1) of \(slices.count) · Copy includes the full code")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Button("Next section") { section = min(slices.count - 1, index + 1) }.disabled(index + 1 == slices.count)
            }.buttonStyle(.plain).padding(10).accessibilityIdentifier("codeSectionNavigation")
        }
        }
        .background(TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
        .onHover { hovering = $0 }
        .piAnimation(PiMotion.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy code") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }
}

/// Copies a markdown target to the clipboard and says so for two seconds.
struct CopyButton: View {
    let target: MarkdownCopyTarget
    let visible: Bool
    @State private var copied = false
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target.text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .medium))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .scaleEffect(copied && !reduceMotion ? 1.1 : 1).animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.6), value: copied)
                Text(copied ? "Copied" : "Copy").font(.system(size: 10.5, weight: .medium)).contentTransition(.opacity)
            }
            .foregroundStyle(copied ? TranscriptPalette.accent : hovering ? TranscriptPalette.text : TranscriptPalette.muted)
            .padding(.horizontal, 6).padding(.vertical, 4)
            // Copy feedback must not rewrap a heading or change its cached
            // Markdown block height when the label changes to “Copied”.
            .frame(width: 64)
            .background(hovering ? TranscriptPalette.panelStrong : TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(copied ? TranscriptPalette.accent.opacity(0.4) : hovering ? TranscriptPalette.hairStrong : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).piPointer()
        .textSelection(.disabled)
        .opacity(visible || copied || hovering ? 1 : 0)
        .piAnimation(PiMotion.quick, value: visible || copied || hovering)
        .onHover { hovering = $0 }
        .help(target.label).accessibilityLabel(target.label)
    }
}

// MARK: - Message rows

/// A message row: user bubble, reply prose, status pill, or one of the marker rows.
struct MessageRowView: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    var inlineAccounting = true
    var disclosure = TranscriptRowDisclosure.default
    var toggle: (TranscriptDisclosure.Part) -> Void = { _ in }
    /// Whether `toggle` reaches the conversation's disclosure, so this row
    /// can offer to switch its reply between rendered and source.
    var switchesSource = false
    @State private var hovering = false
    @Environment(\.transcriptForks) private var forks
    /// Between a user bubble's skill pills and its text.
    nonisolated static let skillGap: CGFloat = 8
    /// Whether a row offers Edit: a message the reader sent, in the latest
    /// version. An earlier version on screen is read-only.
    nonisolated static func editable(_ message: TranscriptMessage) -> Bool {
        message.role == "user" && message.kind == nil && message.earlierVersion != true
    }
    /// The line under a reply that ended before its natural end: at the output
    /// limit it says what to do next; otherwise it names the provider's reason.
    nonisolated static func earlyEnd(_ stopReason: String?) -> String? {
        stopReason == "length" ? "The reply reached the output limit. Ask the model to continue." : TranscriptActivity.earlyEnd(stopReason)
    }
    @ViewBuilder var body: some View {
        if disclosure.foldedAway {
            // This row's turn has ended and its work is behind one line. The
            // row keeps its place and its identity and draws nothing.
            EmptyView()
        } else { row }
    }
    @ViewBuilder private var row: some View {
        switch message.kind {
        case "execution": ExecutionTimelineRow(message:message, actions:actions, open:disclosure.compaction, toggle:{ toggle(.compaction(message.id)) })
        case "toolResult": ToolResultTimelineRow(message:message, open:disclosure.compaction, toggle:{ toggle(.compaction(message.id)) })
        // A folded response says what it cost on its own header line.
        case "requestInfo": if !disclosure.responseFolded { RequestTimelineInfo(message:message, actions:actions) }
        case "compaction": CompactionRowView(message: message, actions: actions, open: disclosure.compaction, toggle: { toggle(.compaction(message.id)) })
        case "branch": BranchRowView(message: message)
        case "versionBanner": VersionBannerRow(message: message, actions: actions)
        case "failure":
            if message.failureCode?.hasPrefix(SessionDisplay.costLimitCode) == true { CostLimitNoticeRow(message: message, actions: actions) }
            else { FailureRowView(message: message, actions: actions) }
        case "notice": NoticeRowView(message: message)
        default: plain
        }
    }
    private var failed: Bool { ["error", "aborted"].contains(message.state ?? "") }
    /// The switch between this reply rendered and its source, where the row
    /// offers one: on a finished reply's text, in a row that reaches the
    /// conversation's disclosure. The pills and the row's accessibility
    /// actions both take this one value.
    var source: ReplySourceToggle? {
        guard switchesSource, ReplySource.offered(message) else { return nil }
        let id = message.id, toggle = toggle
        return ReplySourceToggle(raw: disclosure.raw) { toggle(.source(id)) }
    }
    @ViewBuilder private var plain: some View {
        let raw = ReplySource.shows(message, raw: disclosure.raw)
        // A parked body keeps the copy targets it was drawn with, so parking
        // and showing it again change nothing it measured.
        let copyTargets = message.role == "assistant" && !message.isStreaming ? TranscriptCopy.targets(in: message.text) : []
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
            if message.role == "system" || failed {
                HStack(spacing: 8) {
                    if message.role == "system" { Text("Status").font(.system(size: 12, weight: .semibold)).foregroundStyle(TranscriptPalette.muted) }
                    if failed { Text(message.state ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.danger) }
                }.frame(maxWidth: .infinity, alignment: message.role == "system" ? .center : .leading)
            }
            if message.role == "user" {
                HStack(spacing: 0) {
                    Spacer(minLength: 40)
                    // The skills lead the bubble: the model received them
                    // ahead of the text.
                    VStack(alignment: .leading, spacing: MessageRowView.skillGap) {
                        if let skills = message.skills, !skills.isEmpty {
                            TranscriptSkillPills(messageID: message.id, skills: skills, actions: actions)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // What the reader typed, exactly as typed: nothing in
                        // it is read as Markdown, and it is one selectable text.
                        if message.skills?.isEmpty != false || !message.text.isEmpty {
                            TranscriptPlainText(text: message.text, face: .user)
                                .equatable()
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(TranscriptPalette.userBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: TranscriptMetrics.proseWidth, alignment: .trailing)
                }
            } else if message.role == "system" {
                Text(message.text).font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 6).background(TranscriptPalette.statusBackground, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if !(message.role == "assistant" && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(message.tools ?? []).isEmpty) {
                // A reply that only called tools keeps its row for anchors and receipts, but shows no body.
                // A reply the reader switched to its source reads as that
                // source, exactly as it arrived, until they switch it back.
                // The rendered body stays where it is, parked, so switching
                // back puts the reader where they were rather than on a
                // surface re-measured from estimates.
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownBodyView(source: message.text, streaming: message.isStreaming, copyTargets: copyTargets,
                                     sourceIdentity: message.id, parked: raw).equatable()
                    if raw { ReplySourceView(source: message.text).equatable() }
                }
                .background { if message.role == "assistant" { TranscriptQuoteRegion(messageID: message.id) } }
            }
            if message.truncated == true {
                Text("This older saved fragment is incomplete; the original text was not retained.").font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted)
            }
            if message.role == "assistant", let notice = Self.earlyEnd(message.stopReason) {
                // The reply reached the output limit the request carried (the model's own
                // ceiling, or the room a nearly full window left), or the provider ended
                // it early for a reason of its own: a warning on the row, not a failed
                // run. The output budget is never that limit.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .medium))
                    Text(notice).font(.system(size: 12))
                }
                .foregroundStyle(TranscriptPalette.warning).padding(.top, 2)
                .accessibilityIdentifier(message.stopReason == "length" ? "reply-output-limit" : "reply-ended-early")
            }
            // Stopping keeps what had arrived. The row says so with one amber
            // chip beside the partial answer rather than a sentence under it:
            // the words above it are still the reply, and they are what the
            // reader came back to read.
            if message.stopReason == "interrupted" { TranscriptStoppedChip() }
            // One quiet band under the row for its time, usage and actions; the
            // actions appear on hover without moving anything.
            HStack(alignment: .center, spacing: 10) {
                if inlineAccounting, let accounting = message.accounting, accounting.requests > 0, message.role != "user" { MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(message.id) }) }
                if message.role != "user" { Spacer(minLength: 0) }
                // An edited message's versions, where the edit's marker row used to be.
                if message.role == "user", let mark = message.versions, mark.usable, let step = actions.switchVersion {
                    VersionSwitcher(messageID: message.id, mark: mark) { step(message.id, $0) }
                }
                if message.isSending {
                    // Where the time will be, in the same band: the row keeps
                    // its height when the helper's row takes its place.
                    TranscriptSendingMark()
                } else if message.role == "user", let at = message.at {
                    Text(TranscriptActivity.formatClock(at)).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.faint).monospacedDigit()
                        .opacity(hovering ? 1 : 0).piAnimation(PiMotion.quick, value: hovering)
                        .accessibilityLabel("Sent at \(TranscriptActivity.formatClock(at))")
                }
                // Edit and Details act on the helper's copy of a message; a
                // message still being sent has none yet.
                RowActionsView(message: message, actions: actions, visible: hovering && !message.isSending, source: source)
                if message.role == "user", inlineAccounting, let accounting = message.accounting, accounting.requests > 0 { MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(message.id) }, trailing: true) }
            }
            .frame(height: 22)
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.role) message")
        .transcriptRowActions(message, actions, forks: forks, source: source)
    }
}

private struct CompactionRowView: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(TranscriptPalette.hairStrong).frame(width: 24, height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("⇣").font(.system(size: 12, weight: .semibold)).foregroundStyle(TranscriptPalette.accent).frame(width: 20, height: 20).background(TranscriptPalette.accentSoft, in: Circle())
                    Text("Context compacted").font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(TranscriptPalette.text)
                    if let detail = message.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted).lineLimit(1).monospacedDigit() }
                    Spacer(minLength: 0)
                    RowActionsView(message: message, actions: actions, visible: hovering)
                }
                if !message.text.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        TranscriptFoldHeader(title: "Summary kept in context", open: open, toggle: toggle,
                                             help: ("Hide the summary this compaction kept in context",
                                                    "Show the summary this compaction kept in context"),
                                             font: .system(size: 11.5, weight: .medium))
                        if open {
                            MarkdownBodyView(source: message.text, style: .summary, capsWidth: false).equatable()
                                .padding(.top, 6).padding(.leading, 22)
                        }
                    }
                    .padding(.top, 6).overlay(alignment: .top) { Rectangle().fill(TranscriptPalette.hair).frame(height: 1) }
                }
                if let accounting = message.accounting, accounting.requests > 0 { MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(message.id) }) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 620)
            .background(TranscriptPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TranscriptPalette.hairStrong, lineWidth: 1))
            Rectangle().fill(TranscriptPalette.hairStrong).frame(width: 24, height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
        .onHover { hovering = $0 }
        .accessibilityLabel("Context compacted")
        .transcriptRowActions(message, actions)
    }
}

private struct DashedLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in path.move(to: CGPoint(x: 0, y: 0.5)); path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5)) }
                .stroke(TranscriptPalette.hairStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }.frame(height: 1)
    }
}

private struct BranchRowView: View {
    let message: TranscriptMessage
    var body: some View {
        HStack(spacing: 8) {
            DashedLine()
            Text("Edited from here").font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).fixedSize()
            if let detail = message.detail ?? (message.text.isEmpty ? nil : message.text) { Text(detail).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.faint).lineLimit(2) }
            DashedLine()
        }
        .padding(.vertical, 8)
        .accessibilityLabel("Edited from here")
    }
}

/// A run failure, shown where the conversation stopped rather than in a fixed strip above it.
private struct FailureRowView: View {
    let message: TranscriptMessage
    var actions = TranscriptActions()
    /// A run failure can be retried from where it stopped; a refused send is retyped.
    private var retryable: Bool { message.id.hasPrefix("failure:run:") }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(TranscriptPalette.danger, in: Circle())
                Text("Something went wrong").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(TranscriptPalette.danger)
                Spacer(minLength: 0)
                if retryable {
                    Button(action: actions.retry) { Label("Retry request", systemImage: "arrow.clockwise").font(.system(size: 11.5, weight: .medium)) }
                        .buttonStyle(TranscriptPillStyle(accent: true)).accessibilityIdentifier("retry-run")
                        .help("Send the failed request again from where the turn stopped, with this chat's current model and effort; queued follow-ups continue after it")
                }
            }
            Text(message.text).font(.system(size: 13)).foregroundStyle(TranscriptPalette.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let detail = message.detail { Text(detail).font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TranscriptPalette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(TranscriptPalette.danger.opacity(0.35), lineWidth: 1))
        .padding(.vertical, 8)
        .accessibilityLabel("Error: \(message.text)")
    }
}

/// A transient status line inside the conversation, such as a retry in progress; it turns while it waits.
private struct NoticeRowView: View {
    let message: TranscriptMessage
    var body: some View {
        HStack(spacing: 8) {
            DashedLine()
            SpinnerView()
            Text(message.text).font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.muted).fixedSize()
            DashedLine()
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Status: \(message.text)")
    }
}

// MARK: - Work: action rows, diffs, reasoning

private func actionSymbol(_ kind: ActionKind) -> String {
    switch kind {
    case .command: return "terminal"
    case .write: return "pencil"
    case .read: return "doc.text"
    case .list: return "folder"
    case .search: return "magnifyingglass"
    case .mcp: return "point.3.connected.trianglepath.dotted"
    case .other: return "circle"
    }
}

/// One tool call, on the line every piece of work shares: the verb, the dot,
/// the one-line argument summary, and — for a change — the `+N −M` the card
/// will repeat at its foot. What it opens is a card rather than a column of
/// labelled paragraphs: a diff for a change, a numbered window for a read, a
/// terminal for a command, the IN/OUT card for everything else.
///
/// Its outcome is colour and one hidden word. A failure replaces the summary
/// with the failure's first line; a call the reader stopped turns its dot
/// amber and says "Stopped"; a running call shimmers slowly.
struct ActionRowView: View {
    let tool: ToolView
    var open = false
    /// The call's full arguments, once the host has answered for them. Until
    /// then the card draws the inline document, which always parses.
    var fetched: ToolInputDocument? = nil
    var toggle: () -> Void = {}
    /// Where the call stands, as a row state: a call the reader stopped is
    /// amber, not red — it did not fail, it was interrupted — whether it was
    /// skipped before it began or stopped while it ran.
    nonisolated static func state(of tool: ToolView) -> TranscriptRowState {
        switch TranscriptActivity.outcome(of: tool) {
        case .running: return .running
        case .cancelled, .unknown: return .stopped
        case .failed: return .failed
        case .done: return .ok
        }
    }
    /// What the row is called. The verb is not conjugated for the outcome —
    /// "Ran", never "Failed running" — because the dot in the leading box and
    /// the colour of the summary already say how the call went, and a line
    /// that says it twice reads as an apology.
    ///
    /// Except where "Ran" would claim work that did not happen: a call that
    /// was skipped never ran, so it is "Skipped running"; a call stopped while
    /// it ran is "Stopped running", and its suffix says the outcome is unknown.
    nonisolated static func title(of tool: ToolView) -> String {
        title(TranscriptActivity.actionParts(tool), outcome: TranscriptActivity.outcome(of: tool))
    }
    nonisolated private static func title(_ parts: TranscriptActivity.ActionParts, outcome: ActionOutcome) -> String {
        outcome == .unknown || outcome == .cancelled ? TranscriptActivity.describe(parts, outcome: outcome).verb : parts.done
    }
    /// The collapsed line's summary: a failure's first line replaces the
    /// argument summary outright, because a row cannot say both.
    nonisolated static func summary(of tool: ToolView) -> String { summary(of: tool, object: TranscriptActivity.actionParts(tool).object) }
    nonisolated private static func summary(of tool: ToolView, object: String) -> String {
        guard state(of: tool) == .failed, !tool.output.isEmpty else { return object }
        return TranscriptActivity.firstLine(tool.output)
    }
    /// The quiet trailing clock. A call that took less than a twentieth of a
    /// second says nothing rather than "0.0s": the figure exists to tell the
    /// reader what was slow.
    nonisolated static func elapsed(of tool: ToolView) -> String? {
        guard TranscriptActivity.outcome(of: tool) != .running, let ms = tool.durationMs, ms >= 50 else { return nil }
        return TranscriptActivity.formatDuration(ms)
    }
    /// The change size, already on the collapsed row, and — for a call stopped
    /// while it ran — that its outcome is unknown. It sits outside the
    /// ellipsized summary, so a long command never clips it.
    nonisolated static func suffix(of tool: ToolView) -> String? {
        let change = tool.added != nil || tool.removed != nil ? "+\(tool.added ?? 0) −\(tool.removed ?? 0)" : nil
        guard TranscriptActivity.outcome(of: tool) == .unknown else { return change }
        return [change, "· outcome unknown"].compactMap { $0 }.joined(separator: " ")
    }
    var body: some View {
        // The call's arguments are read once per drawing: while a write
        // streams they are the whole file so far, and the title, the summary
        // and the help each reading them again was three reads per delta.
        let parts = TranscriptActivity.actionParts(tool)
        let outcome = TranscriptActivity.outcome(of: tool)
        let description = TranscriptActivity.describe(parts, outcome: outcome)
        let rowState = Self.state(of: tool)
        TranscriptWorkRow(icon: actionSymbol(description.kind), title: Self.title(parts, outcome: outcome),
                          summary: Self.summary(of: tool, object: description.object), suffix: Self.suffix(of: tool),
                          state: rowState, open: open, toggle: toggle,
                          trailing: Self.elapsed(of: tool),
                          help: description.path ?? description.object) {
            card(description: description, outcome: outcome)
        }
    }
    /// What the row opens. The fetched document when the host has answered for
    /// the call, the inline one until then: both parse, so a card is never a
    /// fragment of JSON.
    @ViewBuilder private func card(description: ActionDescription, outcome: ActionOutcome) -> some View {
        let shown = requested
        let notes = [truncationNote, tool.truncated ? "Preview truncated. The full result is retained in context." : nil]
            .compactMap { $0 }.joined(separator: " · ")
        if let edit = TranscriptActivity.editRequest(shown) {
            TranscriptDiffCard(request: edit, path: description.path, outcome: outcome,
                               added: tool.added, removed: tool.removed)
        } else if description.kind == .command {
            TranscriptTerminalCard(command: TranscriptActivity.parseCommand(shown.input) ?? description.object,
                                   output: tool.output, failed: outcome == .failed)
        } else if description.kind == .read, !tool.output.isEmpty {
            TranscriptReadCard(text: tool.output, firstLine: TranscriptReadCard.firstLine(of: shown.input),
                               path: description.path, failed: outcome == .failed)
        } else {
            let arguments = TranscriptActivity.argumentsText(shown)
            TranscriptIOCard(input: arguments.text.isEmpty
                                ? "The host bounded this call's arguments and none of them could be read."
                                : arguments.text,
                             output: tool.output.isEmpty ? nil : tool.output,
                             failed: outcome == .failed,
                             note: [notes.isEmpty ? nil : notes,
                                    arguments.complete ? nil : "The host bounded this call's arguments. This is the part that arrived, not the whole request."]
                                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        }
    }
    /// The call as the card should read it: the fetched document when one has
    /// arrived, otherwise the inline one.
    private var requested: ToolView {
        guard let fetched else { return tool }
        var copy = tool
        copy.input = fetched.input
        copy.inputTruncated = fetched.truncated ? true : nil
        copy.inputBytes = fetched.bytes
        return copy
    }
    /// What the card says when even what it is showing is short of the request.
    private var truncationNote: String? {
        let current = requested
        guard current.inputTruncated == true else { return nil }
        guard let bytes = current.inputBytes, bytes > 0 else { return "Preview truncated" }
        return "Preview truncated · \(ToolInputDisplay.shortSize(bytes))"
    }
}

/// The expanded list of one run of tool calls; each row opens its own card.
/// A long run is drawn through `NativeWorkListSurface`, which keeps every card
/// but lays out only the ones near the conversation's viewport. A short run
/// keeps the simpler SwiftUI stack.
struct ActivityGroupView: View {
    let tools: [ToolView]
    var openTools: Set<String> = []
    /// Full argument documents the conversation has fetched, by call.
    var fetched: [String: ToolInputDocument] = [:]
    var toggle: (String) -> Void = { _ in }
    var body: some View {
        Group {
            if tools.count >= NativeWorkListSurface.minimumRowCount {
                NativeWorkListSurface(tools: tools, openTools: openTools, fetched: fetched, toggle: toggle)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tools) { tool in
                        ActionRowView(tool: tool, open: openTools.contains(tool.id), fetched: fetched[tool.id], toggle: { toggle(tool.id) }).equatable()
                    }
                }
            }
        }
            .padding(.leading, 4).padding(.vertical, 2)
            .accessibilityLabel("Tool activity")
    }
}

/// A legacy reply's exposed reasoning, on the same Think row a chronological
/// response uses: closed by default even while it streams, its summary the
/// newest line while it is being written and its first line afterwards.
private struct ReasoningView: View {
    let thinking: String
    let streaming: Bool
    var open = false
    var toggle: () -> Void = {}
    var body: some View {
        if TranscriptActivity.hasVisibleText(thinking) {
            TranscriptWorkRow(icon: "brain", title: "Think",
                              summary: TimelinePartRow.thinkSummary(thinking, running: streaming),
                              state: streaming ? .running : .ok, open: open, toggle: toggle,
                              follow: streaming) {
                MarkdownBodyView(source: thinking, style: .reasoning, capsWidth: false, streaming: streaming).equatable()
                    .padding(.top, 4).padding(.leading, TranscriptRowChrome.indent).padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Blocks and turns

/// Holds a turn's work list at its own height while the turn is open and at
/// nothing while it is folded. A folded list is never measured and never
/// placed: both send every tool row through native layout again for a click
/// that hides them all.
///
/// A SwiftUI `Layout` cannot keep the measurement itself — SwiftUI drops a
/// layout's cache when the row host's root view is replaced, which is exactly
/// what a click does. So the row container keeps it, keyed as strictly as
/// `TranscriptGeometryCache` keys a whole row, and hands it back in as a plain
/// value: `known`. Unfolding is then a frame change and one placement, not a
/// measurement of sixty tool rows followed by that placement.
private struct FoldedWork: Layout {
    var open: Bool
    /// What this list measured last time it was open, at this width and this
    /// content. Nil means it must be measured.
    var known: CGFloat?
    /// True while the document is moving this row between its open and its
    /// folded height. The list is placed at its own height throughout and the
    /// row clips to the frame the motion is interpolating, so folding is the
    /// list sliding out of sight rather than vanishing before the row moves.
    var placing = false
    /// Reports a fresh measurement to the row container that keeps it.
    var measured: (CGFloat) -> Void = { _ in }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = proposal.width ?? 0
        guard open else { return CGSize(width: width, height: 0) }
        if let known { return CGSize(width: width, height: known) }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        measured(size.height)
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard open || placing, let subview = subviews.first else { return }
        subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// One chronological response part, a local legacy disclosure, or an
/// explicitly terminal task aggregate. Returned work starts folded.
struct BlockRowView: View {
    let block: TranscriptBlock
    let actions: TranscriptActions
    var fresh = false
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    var disclosure = TranscriptRowDisclosure.default
    var toggle: (TranscriptDisclosure.Part) -> Void = { _ in }
    /// What this turn's work list measured last time it was open at this
    /// width and content; the row container keeps it across folds.
    var workListHeight: CGFloat? = nil
    var workListMeasured: (CGFloat) -> Void = { _ in }
    /// True while the document is moving this row between its two heights.
    var foldInMotion = false
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion
    @Environment(\.transcriptForks) private var forks
    private var open: Bool { disclosure.work }
    var body: some View {
        if block.presentation == .turnFold, let spec = block.foldSummary, let group = block.foldControl {
            TurnFoldControlRow(spec: spec, open: disclosure.turnFoldOpen, toggle: { toggle(.turnFold(group)) })
        } else if disclosure.foldedAway {
            // The turn ended and its work is behind its one line. Every row
            // keeps its place, its identity and whatever the reader opened
            // inside it; they simply draw nothing until the fold is opened.
            EmptyView()
        } else if block.presentation == .response, let line = block.responseSummary, let message = block.message, let response = block.responseID {
            ResponseHeaderRow(line:line, message:message, actions:actions, live:block.live,
                              folded:disclosure.responseFolded, collapsed:disclosure.responseLine,
                              toggleCollapsed:{ toggle(.responseLine(response)) })
        } else if disclosure.responseLine {
            // The response reads as its header line alone. Its parts keep
            // their rows, their identities and everything the reader opened
            // inside them; they simply draw nothing until it is opened again.
            EmptyView()
        } else if let part = block.part, let message = block.message, let response = block.responseID,
                  ["text", "refusal"].contains(part.part.kind) {
            // A response's own words carry its fold commands too: the strip
            // above a plain answer is short, so the reader need not aim at it.
            partRow(part: part, message: message)
                .contextMenu {
                    PiMenuContent { [actions, toggle, forks, source = source(message)] in
                        ReplyMenu.entries(message, actions: actions, forks: forks, fold: ("Fold This Response to One Line", { toggle(.responseLine(response)) }),
                                          source: source)
                    }
                }
        } else if let part = block.part, let message = block.message {
            partRow(part: part, message: message)
        } else if block.presentation == .body, let message = block.message {
            MessageRowView(message:message, actions:actions, inlineAccounting:false, disclosure:disclosure, toggle:toggle, switchesSource:true).equatable().padding(.bottom,10)
                .contextMenu { PiMenuContent { [actions, forks, source = source(message)] in ReplyMenu.entries(message, actions: actions, forks: forks, source: source) } }
        } else if block.presentation == .summary, let turn = block.turn {
            StableTurnSummaryView(turn:turn, actions:actions)
        } else {
            reply
        }
    }
    /// One part of a response at its own position.
    @ViewBuilder private func partRow(part: ResponseTimeline.Segment, message: TranscriptMessage) -> some View {
        // A card's fold is keyed by the reply that made the call, so two
        // responses reusing one provider call id stay independent.
        let card = (message.tools ?? []).first
        let key = card.map { ToolOccurrence.key(message.id, $0.id) }
        TimelinePartRow(part:part, message:message, actions:actions,
                        open:disclosure.work && !disclosure.responseFolded, toggle:{ toggle(.work(block.key)) },
                        card:card,
                        cardOpen:key.map { disclosure.openTools.contains($0) && !disclosure.responseFolded } ?? false,
                        fetched:key.flatMap { disclosure.toolInputs[$0] },
                        toggleCard:{ if let key { toggle(.tool(key)) } },
                        raw:disclosure.raw, toggleRow:toggle)
    }
    /// The switch between a reply of this row rendered and its source, for
    /// its menu; nil where the row's text does not offer one.
    private func source(_ message: TranscriptMessage) -> ReplySourceToggle? {
        guard ReplySource.offered(message) else { return nil }
        let id = message.id, toggle = toggle
        return ReplySourceToggle(raw: disclosure.raw) { toggle(.source(id)) }
    }
    /// A reply whose recorded order is unavailable: one local work group, its
    /// prose, its figures and the turn line, as it has always read.
    @ViewBuilder private var reply: some View {
        let reasoned = TranscriptActivity.blockReasoned(block)
        let hasWork = block.presentation == .work || !block.tools.isEmpty || reasoned
        let accounting = block.accounting
        let tokens = TranscriptActivity.tokens(of: accounting)
        let hasUsage = tokens != nil || accounting.costUSD != nil || accounting.model != nil
        let merged = block.turn != nil && block.turn!.replies == 1
        let settled = fresh && !block.live
        VStack(alignment: .leading, spacing: 4) {
            if hasWork {
                VStack(alignment: .leading, spacing: 2) {
                    workHeader(reasoned: reasoned)
                    // Every request of the block in order: reasoning, its tool calls,
                    // its figures. The list stays in the tree while closed, at zero
                    // height and clipped: tearing down and rebuilding sixty tool rows
                    // and their native text is what made a click cost two frames.
                    // The list always keeps its own height, so the proposal its
                    // rows see is the same whether the turn is open, closed or
                    // being measured; while it is folded it is not placed, so a
                    // click that hides it does not lay every tool row out again.
                    if hasWork {
                        FoldedWork(open: open, known: workListHeight, placing: foldInMotion, measured: workListMeasured) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(block.replies) { reply in
                                    VStack(alignment: .leading, spacing: 2) {
                                        ReasoningView(thinking: reply.thinking ?? "", streaming: reply.isStreaming,
                                                      open: disclosure.openReasoning.contains(reply.id), toggle: { toggle(.reasoning(reply.id)) }).equatable()
                                        if let tools = reply.tools, !tools.isEmpty {
                                            let scoped = block.presentation == .work
                                            ActivityGroupView(tools: tools,
                                                openTools: Set(tools.filter { disclosure.openTools.contains(scoped ? ToolOccurrence.key(reply.id,$0.id) : $0.id) }.map(\.id)),
                                                fetched: Dictionary(tools.compactMap { tool in disclosure.toolInputs[scoped ? ToolOccurrence.key(reply.id,tool.id) : tool.id].map { (tool.id,$0) } }, uniquingKeysWith: { _,last in last }),
                                                toggle: { toggle(.tool(scoped ? ToolOccurrence.key(reply.id,$0) : $0)) }).equatable()
                                        }
                                        if let accounting = reply.accounting, accounting.requests > 0, !(reply.tools ?? []).isEmpty || !(reply.thinking ?? "").isEmpty || reply.id != block.message?.id {
                                            MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(reply.id) })
                                        }
                                        if block.presentation == .work {
                                            if reply.truncated == true { Text("Partial preview · Open Request details for retained content").font(.system(size:11)).foregroundStyle(TranscriptPalette.warning) }
                                            if let ms = reply.modelMs { Text("Model request: " + TranscriptActivity.formatDuration(ms)).font(.system(size:11)).foregroundStyle(TranscriptPalette.faint) }
                                            if let notice = TranscriptActivity.earlyEnd(reply.stopReason, toolArguments: true) { Text(notice).font(.system(size:12)).foregroundStyle(TranscriptPalette.warning) }
                                            HStack {
                                                Button("Request details") { actions.inspect(reply.id) }
                                                Button("Copy reply") { actions.copyMessage(reply.id) }
                                            }.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(TranscriptPalette.faint)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(TranscriptPalette.hairStrong).frame(width: 2) }
                            .padding(.top, 2).padding(.leading, 2).padding(.bottom, 4)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .clipped()
                        .allowsHitTesting(open)
                        .accessibilityHidden(!open)
                    }
                }
                .onHover { hovering = $0 }
            }
            if let message = block.message {
                MessageRowView(message: message, actions: actions, inlineAccounting: false, disclosure: disclosure, toggle: toggle, switchesSource: true).equatable()
                    .contextMenu { PiMenuContent { [actions, forks, source = source(message)] in ReplyMenu.entries(message, actions: actions, forks: forks, source: source) } }
            }
            // A reply inside a multi-reply turn keeps its own figures; the turn line closes the turn.
            if block.presentation != .work, !block.live, !merged, hasUsage { replyFigures(tokens: tokens) }
            if let turn = block.turn, !turn.live { TurnLineView(turn: turn, settled: settled, now: now, actions: actions, model: accounting.model, modelMessageID: accounting.modelMessageID) }
        }
        .padding(.bottom, 10)
    }
    /// The header of the work rows: what the reply did, on the same 24 pt line
    /// a tool call and a thought read on. It used to be its own arrangement of
    /// a symbol, a label and a chevron; one shape for every piece of work is
    /// the point of that line, so this is now that line with nothing under it
    /// — the list it opens is placed by `FoldedWork`, not by the row.
    private func workHeader(reasoned: Bool) -> some View {
        let outcome = block.task?.outcome
        let state: TranscriptRowState = block.live ? .running
            : outcome == "failed" ? .failed
            : ["cancelled", "interrupted"].contains(outcome ?? "") ? .stopped : .ok
        return TranscriptWorkRow(icon: "list.bullet",
                                 title: block.key.hasPrefix("legacy:") ? "Work" : block.presentation == .work ? "Task" : "Work",
                                 summary: block.key.hasPrefix("legacy:") ? "Legacy response · part order unavailable"
                                    : block.presentation == .work ? workLabel
                                    : ToolCallSummary(rows: block.replies).label(reasoned: reasoned) ?? "Working",
                                 state: state, open: open, toggle: { toggle(.work(block.key)) },
                                 help: workLabel) { EmptyView() }
    }
    private var workLabel: String {
        let status: String
        switch block.task?.outcome {
        case "completed": status = "Completed"
        case "failed": status = "Failed"
        case "cancelled": status = "Stopped"
        case "interrupted": status = "Interrupted"
        case "output-limited": status = "Output limit reached"
        default: status = block.live ? "Working" : "Work · outcome unavailable"
        }
        let summary = block.taskSummary
        let count = summary?.tools ?? ToolCallSummary(rows:block.replies).total
        return status + (count > 0 ? " · \(summary?.toolCountPartial == true ? "at least " : "")\(count) tool calls" : "") +
            (summary?.partial == true ? " · partial history" : "")
    }
    /// Under a reply of a multi-reply turn: how long it took, its tokens, cost and model.
    private func replyFigures(tokens: Double?) -> some View {
        let accounting = block.accounting
        let elapsed: Double? = { if let s = block.startedAt, let e = block.endedAt, e >= s { return e - s }; return nil }()
        var items: [FigureItem] = []
        if let elapsed { items.append(.text(Text(TranscriptActivity.formatDuration(elapsed)))) }
        if let tokens { items.append(.text(Text("\(TranscriptActivity.formatTokenCount(tokens)) tokens"))) }
        if let cost = accounting.costUSD { items.append(.text(Text(TranscriptActivity.formatTurnCost(cost) + (accounting.costSamples < accounting.requests ? " (\(accounting.costSamples)/\(accounting.requests))" : "")))) }
        if let model = accounting.model {
            items.append(.view(Button { actions.inspect(accounting.modelMessageID ?? block.id) } label: {
                HStack(spacing: 3) { Text(model).font(.system(size: 12, weight: .medium)); Image(systemName: "info.circle").font(.system(size: 11)) }.foregroundStyle(TranscriptPalette.faint)
            }.buttonStyle(.plain).piPointer().help("View response-body and header models").accessibilityLabel("View model reports: \(model)")))
        }
        return FigureFlow(items: items, font: .system(size: 12, weight: .medium), color: TranscriptPalette.faint)
            .help(accounting.requests > 0 ? TranscriptActivity.usageBreakdown(accounting) : "")
    }
}

/// Docked above the composer: current work and reported usage, with a
/// shimmering label and a stable slot for duration and token shares.

struct LiveTurnBar: View {
    let turn: TurnSummary
    var state = "running"
    var actions = TranscriptActions()
    private var label: String {
        TurnInfoPresentation.workingLabel(turn, state: state)
    }
    var body: some View {
        CompactTurnReport(turn: turn, actions: actions, status: label)
            .accessibilityElement(children: .contain)
    }
}

struct TranscriptStopStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(TranscriptPalette.danger)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.danger.opacity(0.1) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(TranscriptPalette.danger.opacity(0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }.piPointer()
    }
}

// Rows skip their body while their inputs are unchanged, so a streaming delta
// re-renders only the row that changed and settled rows never parse twice.
extension MessageRowView: Equatable {
    nonisolated static func == (a: MessageRowView, b: MessageRowView) -> Bool { a.message == b.message && a.inlineAccounting == b.inlineAccounting && a.disclosure == b.disclosure && a.switchesSource == b.switchesSource }
}
extension BlockRowView: Equatable {
    nonisolated static func == (a: BlockRowView, b: BlockRowView) -> Bool { a.block == b.block && a.fresh == b.fresh && a.disclosure == b.disclosure && a.workListHeight == b.workListHeight && a.foldInMotion == b.foldInMotion }
}
extension MarkdownBodyView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.source == b.source && a.style == b.style && a.capsWidth == b.capsWidth && a.streaming == b.streaming && a.copyTargets == b.copyTargets && a.sourceIdentity == b.sourceIdentity
            && a.parked == b.parked
    }
}
extension CodeBlockView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.code == b.code && a.language == b.language && a.size == b.size && a.streaming == b.streaming }
}
extension ActionRowView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.tool == b.tool && a.open == b.open && a.fetched == b.fetched }
}
extension ActivityGroupView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.tools == b.tools && a.openTools == b.openTools && a.fetched == b.fetched }
}
extension ReasoningView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.thinking == b.thinking && a.streaming == b.streaming && a.open == b.open }
}

/// Bounded full-code sections use UTF-8 source offsets, never truncated stored
/// code. Page switches are deliberate; streaming retains its existing leaf.
enum CodeBlockSections {
    static func ranges(_ source: String, enabled: Bool = true) -> [Range<Int>] {
        // A fence still arriving is one continuous leaf, asked about on every
        // token: it has nothing to split, so nothing of it is copied.
        guard enabled, source.utf8.count > 32_768 else { return [] }
        let bytes = Array(source.utf8)
        var ranges: [Range<Int>] = [], start = 0
        while start < bytes.count {
            var end = min(bytes.count, start + 8192)
            if end < bytes.count {
                if let newline = bytes[start..<end].lastIndex(of: 10), newline > start { end = newline + 1 }
                else { while end > start && bytes[end] & 0xC0 == 0x80 { end -= 1 } }
            }
            ranges.append(start..<end); start = end
        }
        return ranges
    }
    /// One section's code, taken from the source's own bytes rather than a
    /// copy of all of them.
    static func section(_ source: String, _ range: Range<Int>) -> String {
        let utf8 = source.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound), upper = utf8.index(lower, offsetBy: range.count)
        return String(decoding: utf8[lower..<upper], as: UTF8.self)
    }
}
