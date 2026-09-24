import SwiftUI

// One chat on one line: its title, its state, its figures and its unread
// dot, plus the side conversation that hangs under it. Every row here is
// given values its parent already looked up, so it can be compared rather
// than rebuilt.

/// A small accent dot marks a chat with replies the user has not viewed. The
/// sidebar records only whether a chat is unread, never how many replies.
struct UnreadDot: View {
    /// A run that failed while you were away: marked, but never counted in the Dock badge.
    var failure = false
    var body: some View {
        Circle().fill(failure ? Color.piDanger : Color.piBrandOrange).frame(width: 7, height: 7)
            .accessibilityLabel(failure ? "Run failed" : "Unread replies").help(failure ? "The last run failed while you were away" : "New replies you have not viewed")
    }
}

/// Compact live stats for a sidebar row: state, cost and the session's input,
/// cached-input and output tokens. The composer footer owns the separate
/// context-size estimate.
struct ChatRowStats: Equatable {
    var state = "idle"
    /// The last run stopped at the chat's cost limit: a stop, not a failure.
    var costLimited = false
    var busy = false
    var loading = false
    var costUSD: Double?
    var cacheHits = 0
    var cacheMisses = 0
    var requests = 0
    var tokens: Double?
    var tokenSamples = 0
    var inputTokens: Double?
    var cachedTokens: Double?
    var outputTokens: Double?
    var inputSamples = 0
    var cachedSamples = 0
    var outputSamples = 0
    var generating = false
    var timing: SessionTimingHistory?
    /// Seconds since 1970 of the latest request or message, for the "3m ago" stamp.
    private(set) var lastActivity: Double?
    /// "3m ago", "2h ago", "yesterday", or a short date, as of when the row
    /// was built; nil without any activity. Stored rather than worked out on
    /// reading, so a row whose stamp now reads differently compares unequal
    /// and is drawn again: one that held only the time kept "just now".
    private(set) var recencyLabel: String?
    init(totals: GatewayTotals?, timing: SessionTimingHistory? = nil, now: Date = Date()) {
        self.timing = timing
        costUSD = totals?.costUSD; cacheHits = totals?.cacheHits ?? 0; cacheMisses = totals?.cacheMisses ?? 0; requests = totals?.requests ?? 0
        tokens = totals?.tokens?.total; tokenSamples = totals?.tokens?.samples ?? 0
        inputTokens = totals?.tokens?.input; outputTokens = totals?.tokens?.output; cachedTokens = totals?.cacheReadTokens
        inputSamples = totals?.tokens?.inputSamples ?? 0; outputSamples = totals?.tokens?.outputSamples ?? 0; cachedSamples = totals?.cacheReadSamples ?? 0
        noteActivity(totals?.lastActivity, now: now)
    }
    mutating func noteActivity(_ seconds: Double?, now: Date = Date()) {
        lastActivity = seconds
        recencyLabel = seconds.flatMap { $0.isFinite && $0 > 0 ? ChatRowStats.relative(Date(timeIntervalSince1970: $0), now: now) : nil }
    }
    var hasActivity: Bool { requests > 0 || busy || loading || tokens != nil || timing?.latest != nil }
    /// "12k in · 8.1k cached · 2.4k out". Unreported usage reads n/a, never zero.
    var usageLabel: String? {
        guard requests > 0 || inputTokens != nil || outputTokens != nil else { return nil }
        return "\(compactTokens(inputTokens)) in · \(compactTokens(cachedTokens)) cached · \(compactTokens(outputTokens)) out"
    }
    var usageHelp: String {
        "Session tokens · input \(menuBarTokens(inputTokens)) (\(inputSamples)/\(requests) requests reported) · cached input \(menuBarTokens(cachedTokens)) (\(cachedSamples)/\(requests) reported) · output \(menuBarTokens(outputTokens)) (\(outputSamples)/\(requests) reported). "
        + "Input counts cached tokens once; reasoning is included in output. Context size is shown below the composer."
    }
    var costLabel: String? {
        guard let costUSD, costUSD.isFinite, costUSD >= 0 else { return requests > 0 ? "cost n/a" : nil }
        if costUSD == 0 { return "$0" }
        return costUSD < 0.01 ? String(format: "$%.4f", costUSD) : String(format: "$%.2f", costUSD)
    }
    var tokensLabel: String? {
        guard let tokens, tokens.isFinite, tokens >= 0 else { return requests > 0 ? "tok n/a" : nil }
        if tokens >= 1_000_000 { return String(format: "%.1fM tok", tokens / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk tok", tokens / 1000) }
        return String(format: "%.0f tok", tokens)
    }
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        if seconds < 172_800 { return "yesterday" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    var tokensHelp: String {
        "Session tokens consumed: \(menuBarTokens(tokens)). \(tokenSamples)/\(requests) requests reported both input and output. "
        + (tokenSamples < requests ? "Partial total; missing usage is excluded. " : "")
        + "Input includes cached tokens once; reasoning is included in output. Context size is shown below the composer."
    }
    mutating func updateActivity(state: String, loading: Bool, activity: [String: WireValue]) {
        self.state = state; self.loading = loading
        busy = ["queued", "running", "stopping", "compacting"].contains(state)
        let phase = activity["phase"]?.string ?? ""
        generating = busy && !loading && state != "stopping" && [1, 2].contains(activity["version"]?.number ?? 0)
            && activity["modelActive"]?.bool == true && ["model", "compacting"].contains(phase)
        if busy && phase == "tool" { self.state = "tool" }
    }
    var rateLabel: String? { timing.map { SessionRatePresentation(history: $0).label } }
}

/// What a chat row shows, given values its parent has already looked up. It
/// holds the model to act on a press, never to observe it: the row it belongs
/// to is compared on `SidebarChatRowState`, so nothing drawn here may come
/// from state that comparison does not cover.
struct ChatRow: View {
    let model: WorkspaceModel
    let chat: ChatRecord
    let selected: Bool
    var unreadCount = 0
    var unreadFailure = false
    /// Whether this chat has a loaded page. The caller has already looked, and
    /// the answer is part of what its row is compared on.
    var live = false
    /// "Ready", "Archived · Work connection": worked out by the group,
    /// which knows how many connections there are to name.
    var subtitle = ""
    var hasSide = false
    var expanded = true
    /// What this row's metrics line has to itself; see `ChatRowMetrics`.
    var available: CGFloat = .infinity
    var toggle: () -> Void = {}
    private var symbol: String { chat.imported ? "doc.text" : chat.parentSessionID != nil ? "arrow.triangle.branch" : chat.connectionTest == true ? "checkmark.seal" : chat.toolMode == "read-only" ? "eye" : "bubble.left" }
    private var archiveAction: (() -> Void)? { chat.isBackgroundTask || chat.connectionTest == true ? nil : { model.toggleSessionArchive(chat.id) } }
    @Environment(\.sidebarMinute) private var minute
    var body: some View {
        if live, let display = model.displays[chat.id] {
            LiveChatRow(session: display, footer: display.footer, title: chat.title, subtitle: subtitle, symbol: symbol, selected: selected, unreadCount: unreadCount, unreadFailure: unreadFailure, hasSide: hasSide, expanded: expanded, available: available, toggle: toggle, pinned: chat.isPinned, archived: chat.isArchived, archive: archiveAction)
        } else {
            RetainedAccountingRow(accounting: model.chatAccounting.row(for: chat.id)) { totals in
                ChatRowBody(stats: ChatRowStats(totals: totals, now: minute ?? Date()), title: chat.title, subtitle: subtitle, symbol: symbol, selected: selected, unreadCount: unreadCount, unreadFailure: unreadFailure, hasSide: hasSide, expanded: expanded, pinned: chat.isPinned, available: available, archived: chat.isArchived, archive: archiveAction).equatable()
            }
        }
    }
}

struct RetainedAccountingRow<Content: View>: View {
    @ObservedObject var accounting: CachedSessionAccounting
    @ViewBuilder var content: (GatewayTotals?) -> Content
    var body: some View { content(accounting.totals) }
}

/// Observes a loaded session so its row updates while it runs.
private struct LiveChatRow: View {
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let unreadCount: Int
    var unreadFailure = false
    let hasSide: Bool
    let expanded: Bool
    var available: CGFloat = .infinity
    let toggle: () -> Void
    var pinned = false
    var archived = false
    var archive: (() -> Void)? = nil
    @Environment(\.sidebarMinute) private var minute
    private var stats: ChatRowStats {
        let now = minute ?? Date()
        var value = ChatRowStats(totals: footer.gateway, timing: footer.timing, now: now)
        value.updateActivity(state: session.state, loading: session.loading, activity: session.activity)
        value.costLimited = session.failureCode == SessionDisplay.costLimitCode
        // A message that just landed is more recent than the last retained request.
        if let at = session.messages.last(where: { $0.at != nil })?.at { value.noteActivity(max(value.lastActivity ?? 0, at / 1_000), now: now) }
        return value
    }
    var body: some View { row }
    private var row: some View {
        ChatRowBody(stats: stats, title: title, subtitle: subtitle, symbol: symbol, selected: selected, unreadCount: unreadCount, unreadFailure: unreadFailure, hasSide: hasSide, expanded: expanded, toggle: toggle, pinned: pinned, available: available, archived: archived, archive: archive).equatable()
    }
}

/// A row whose inputs have not changed must not re-measure and re-lay out its
/// metrics line. Every workspace change invalidates the whole sidebar, so
/// without this an unread dot or a selection redraws every row of every group.
struct ChatRowBody: View, Equatable {
    nonisolated static func == (lhs: ChatRowBody, rhs: ChatRowBody) -> Bool {
        lhs.stats == rhs.stats && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.symbol == rhs.symbol
            && lhs.selected == rhs.selected && lhs.unreadCount == rhs.unreadCount && lhs.unreadFailure == rhs.unreadFailure
            && lhs.hasSide == rhs.hasSide && lhs.expanded == rhs.expanded && lhs.pinned == rhs.pinned
            && lhs.indent == rhs.indent && lhs.archived == rhs.archived && lhs.available == rhs.available
        // `toggle` and `archive` are fixed by the chat this row is identified
        // by: a background task or a connection test never gains the control.
    }
    let stats: ChatRowStats
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    var unreadCount = 0
    var unreadFailure = false
    var hasSide = false
    var expanded = true
    var toggle: () -> Void = {}
    var pinned = false
    var indent = false
    /// What the metrics line has to itself at the sidebar's current width.
    var available: CGFloat = .infinity
    /// Archive control: one click asks, a second confirms; restore is immediate.
    var archived = false
    var archive: (() -> Void)? = nil
    @State private var confirmingArchive = false
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                // Not a ProgressView: that is an AppKit view resizing itself
                // inside the sidebar's lazy list (PiSpinner).
                if stats.busy || stats.loading { PiSpinner(size: 11) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Color.piAccent : Color.piInkSecondary) }
            }.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: selected || unreadCount > 0 ? .semibold : .regular)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                        .contentTransition(.opacity).piAnimation(PiMotion.base, value: title)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.piInkTertiary).accessibilityLabel("Pinned chat") }
                    Spacer(minLength: 4)
                    // The dot animates itself. Hanging the animation off the
                    // whole row made every row pay for it on every redraw.
                    ZStack {
                        if unreadCount > 0 || unreadFailure { UnreadDot(failure: unreadFailure && unreadCount == 0).transition(.scale.combined(with: .opacity)) }
                    }
                    .piAnimation(PiMotion.spring, value: unreadCount > 0 || unreadFailure)
                    if archive != nil || hasSide {
                        // Published so a draggable row's AppKit press surface can
                        // leave these presses to SwiftUI; see SidebarRowControlBounds.
                        HStack(spacing: 4) {
                            if let archive {
                                if confirmingArchive {
                                    Button("Archive") { confirmingArchive = false; archive() }.buttonStyle(.piPrimaryCompact)
                                        .accessibilityIdentifier("confirmArchive")
                                    PiIconButton(symbol: "xmark", label: "Keep chat", size: 18) { confirmingArchive = false }
                                } else {
                                    PiIconButton(symbol: archived ? "arrow.uturn.backward" : "archivebox", label: archived ? "Restore chat" : "Archive chat", size: 18) {
                                        if archived { archive() } else { confirmingArchive = true }
                                    }
                                    // Quiet at rest, solid under the pointer: a
                                    // control the pointer only strengthens, never
                                    // conjures. Invisible, it could not be found
                                    // and gave keyboard focus nowhere to show.
                                    .opacity(hovering || confirmingArchive ? 1 : 0.28)
                                    .piAnimation(PiMotion.quick, value: hovering)
                                    .accessibilityIdentifier(archived ? "restoreChat" : "archiveChat")
                                }
                            }
                            if hasSide {
                                PiIconButton(symbol: "chevron.down", label: expanded ? "Hide child chats" : "Show child chats", size: 18, action: toggle)
                                    .rotationEffect(.degrees(expanded ? 0 : -90))
                            }
                        }
                        .anchorPreference(key: SidebarRowControlBounds.self, value: .bounds) { [$0] }
                        // Only the confirm/cancel pair swaps; the row does not.
                        .piAnimation(PiMotion.quick, value: confirmingArchive)
                    }
                }
                if stats.hasActivity { ChatRowMetrics(stats: stats, title: title, available: available) } else {
                    Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .help(subtitle + (stats.requests > 0 ? " · \(stats.requests) requests · cache \(stats.cacheHits) hit / \(stats.cacheMisses) miss" : ""))
        // Accounting refreshes are data updates, not whole-row transitions, and
        // neither the dot nor the archive question is a change to the row: both
        // animate where they happen, above.
        .onHover { inside in hovering = inside; if !inside { confirmingArchive = false } }
    }
}

/// Ordinary rows keep one line. A narrow sidebar puts the stable rate below
/// state/cost instead of letting a fixed-width metric overflow the chat row.
struct ChatRowMetrics: View {
    let stats: ChatRowStats
    let title: String
    /// What this line has to itself. `ViewThatFits` used to answer the same
    /// question by laying out all four forms for every row on every pass; the
    /// strings are measured once instead and the widest form that fits is the
    /// only one built. The line still truncates as a last resort, so a
    /// rounding difference shows an ellipsis rather than running past the edge.
    var available: CGFloat = .infinity
    @ViewBuilder var body: some View {
        if available.isFinite {
            chosen(SidebarMetricsFigures(stats).form(fitting: available)).piStableLayout()
        } else {
            // Nobody told this line how much room it has, so it works it out
            // the way it always did. The sidebar always tells it.
            ViewThatFits(in: .horizontal) {
                statsRow(tokens: true, recency: true, fitted: false)
                statsRow(tokens: false, recency: true, fitted: false)
                statsRow(tokens: false, recency: false, fitted: false)
                stacked
            }
            .piStableLayout()
        }
    }
    @ViewBuilder private func chosen(_ form: SidebarMetricsForm) -> some View {
        if form == .stacked { stacked } else { statsRow(tokens: form.showsTokens, recency: form.showsRecency, fitted: true) }
    }
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) { stateAndCost }
            if let history = stats.timing { SidebarReportedRate(history: history, sessionTitle: title) }
        }
        .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).lineLimit(1)
    }
    /// `fitted` is a line that was chosen by measurement: it may truncate as a
    /// last resort if the measurement and the layout ever disagree by a pixel.
    /// A candidate offered to `ViewThatFits` must instead report the width it
    /// wants, or every candidate would "fit" by shrinking.
    @ViewBuilder private func statsRow(tokens showTokens: Bool, recency showRecency: Bool, fitted: Bool) -> some View {
        let row = HStack(spacing: 6) {
            stateAndCost
            if let history = stats.timing { SidebarReportedRate(history: history, sessionTitle: title) }
            // Cost and one token figure; the input, cached and output split is a hover away.
            if showTokens, !stats.busy, let tokens = stats.tokensLabel { Text("· " + tokens).help(stats.usageHelp).accessibilityLabel(stats.usageHelp) }
            if showRecency, let recency = stats.recencyLabel { Text("· " + recency).help("Last activity").accessibilityLabel("Last activity " + recency) }
        }
        .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).lineLimit(1)
        if fitted { row.truncationMode(.tail).fixedSize(horizontal: false, vertical: true) }
        else { row.fixedSize(horizontal: true, vertical: false) }
    }
    @ViewBuilder private var stateAndCost: some View {
        if (stats.busy || stats.loading) && !stats.generating {
            Text(PiSessionState.label(stats.state, loading: stats.loading)).foregroundStyle(Color.piWarning).fontWeight(.medium)
        } else if ["error", "interrupted", "paused"].contains(stats.state) {
            Text(PiSessionState.label(stats.state, costLimited: stats.costLimited)).foregroundStyle(stats.state == "paused" ? Color.piInfo : stats.costLimited ? Color.piWarning : Color.piDanger).fontWeight(.medium)
        }
        if let cost = stats.costLabel { Text(cost) }
    }
}

/// The open side conversation under its parent row. Values only, for the same
/// reason as `ChatRow`.
struct SideRow: View {
    let title: String
    let kept: Bool
    let selected: Bool
    var unreadCount = 0
    /// The side's loaded page, when it has one; the caller has already looked.
    var display: SessionDisplay?
    var available: CGFloat = .infinity
    private var subtitle: String { kept ? "Saved · Read-only" : "In memory · Read-only" }
    var body: some View {
        if let display {
            LiveChatRow(session: display, footer: display.footer, title: title, subtitle: subtitle, symbol: "arrow.triangle.branch", selected: selected, unreadCount: unreadCount, hasSide: false, expanded: true, available: available, toggle: {})
        } else {
            ChatRowBody(stats: ChatRowStats(totals: nil), title: title, subtitle: subtitle, symbol: "arrow.triangle.branch", selected: selected, unreadCount: unreadCount, available: available).equatable()
        }
    }
}

/// The minute the sidebar's "3m ago" stamps are worked out against, from one
/// clock around the list. Only the rows read it, and a row whose stamp still
/// reads the same compares equal and is not drawn again.
private struct SidebarMinuteKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var sidebarMinute: Date? {
        get { self[SidebarMinuteKey.self] }
        set { self[SidebarMinuteKey.self] = newValue }
    }
}
struct SidebarMinuteClock: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.everyMinute) { context in content.environment(\.sidebarMinute, context.date) }
    }
}
