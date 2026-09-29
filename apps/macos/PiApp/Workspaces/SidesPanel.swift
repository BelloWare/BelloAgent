import SwiftUI
import AppKit
import Combine

// The sides panel: the open chat's sides at the window's right edge, beside
// the side pane where a side is shown, so switching between them does not
// take the pointer across the window to the sidebar. The sidebar still lists
// every side.
//
// It hides until the pointer rests at the window's right edge, then slides
// in over the conversation as an overlay, so nothing under it moves; it
// slides away once the pointer has left it for the middle of the window.
// Pinned, it stands as a column of its own, docked at the right as the
// sidebar is at the left. docs/Sides-Panel.md.

enum SidesPanelMetrics {
    static let width: CGFloat = 248
    /// The strip of the window's right edge the pointer rests on to bring the
    /// panel. Narrow, so a pointer on the side pane's scroll bar is not on it.
    static let edgeWidth: CGFloat = 3
    /// How long the pointer rests at the edge before the panel comes.
    static let dwell: Duration = .milliseconds(200)
    /// How long the panel stays once the pointer has left it, so crossing
    /// the edge on the way somewhere else does not flicker it.
    static let grace: Duration = .milliseconds(400)
}

/// One row of the panel: a side of the open chat.
struct SidesPanelEntry: Identifiable, Equatable {
    let id: String
    let title: String
    /// Shown in the side pane now.
    let open: Bool
    /// Saved as a chat of its own, with a record and accounting.
    let saved: Bool
}

/// What the handle carries while the panel is hidden: whether a side other
/// than the one on screen is working, has a new reply, or failed.
struct SidesPanelActivity: Equatable {
    var sides = 0
    var working = false
    var unread = false
    var failed = false
}

// MARK: - Coming and going

/// Whether the panel is out, while it is not pinned. The pointer resting at
/// the window's right edge for `dwell` brings it, never while a mouse button
/// is down. While it is out, where the pointer is gets checked every tenth
/// of a second, not left to enter and exit events, which AppKit does not
/// send for a panel that appears under a pointer already there: once the
/// pointer has been off the panel and off the edge for `grace`, it goes.
@MainActor final class SidesPanelReveal: ObservableObject {
    @Published private(set) var shown = false
    var dwell = SidesPanelMetrics.dwell
    var grace = SidesPanelMetrics.grace
    /// How often the pointer is looked for while the panel is out.
    var poll: Duration = .milliseconds(100)
    /// Whether the pointer is on the window's right edge, and on the panel.
    var pointerAtEdge: () -> Bool = { false }
    var pointerOnPanel: () -> Bool = { false }
    /// Whether a mouse button is down: dragging the side pane's scroll bar
    /// to the edge must not bring the panel.
    var buttonsDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    private var arriving: Task<Void, Never>?
    private var watching: Task<Void, Never>?

    /// The pointer came to the window's right edge or the handle, or left
    /// one. Leaving one for the other, where they meet, keeps its rest.
    func edge(_ inside: Bool) {
        guard !shown else { return }
        guard inside || pointerAtEdge() else { arriving?.cancel(); arriving = nil; return }
        guard arriving == nil, !buttonsDown() else { return }
        let dwell = dwell
        arriving = Task { [weak self] in
            try? await Task.sleep(for: dwell)
            guard let self, !Task.isCancelled else { return }
            self.arriving = nil
            if self.pointerAtEdge() && !self.buttonsDown() { self.show() }
        }
    }

    /// Out at once, as when the panel is unpinned under the pointer; it goes
    /// once the pointer has left it, or, `untilHidden`, when `hide` says.
    func show(untilHidden: Bool = false) {
        arriving?.cancel(); arriving = nil
        watching?.cancel(); watching = nil
        if !shown { shown = true }
        if !untilHidden { watch() }
    }
    /// Away at once, as when the panel is pinned.
    func hide() {
        arriving?.cancel(); arriving = nil
        watching?.cancel(); watching = nil
        if shown { shown = false }
    }

    private func watch() {
        watching?.cancel()
        let poll = poll, grace = grace
        watching = Task { [weak self] in
            var away: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard let self, !Task.isCancelled, self.shown else { return }
                if self.pointerOnPanel() || self.pointerAtEdge() { away = nil; continue }
                let now = ContinuousClock.now
                guard let since = away else { away = now; continue }
                if now - since >= grace {
                    self.watching = nil
                    self.shown = false
                    return
                }
            }
        }
    }
}

/// A strip that says when the pointer enters and leaves it, and where the
/// pointer is, without ever taking a click: presses go to whatever is under
/// it, the side pane's scroll bar included.
struct SidesPanelPointerArea: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void
    /// Handed the question "is the pointer on this strip now?".
    let asks: @MainActor (@escaping @MainActor () -> Bool) -> Void
    func makeNSView(context: Context) -> SidesPanelPointerView {
        let view = SidesPanelPointerView()
        view.changed = changed
        asks { [weak view] in view?.containsPointer ?? false }
        return view
    }
    func updateNSView(_ view: SidesPanelPointerView, context: Context) { view.changed = changed }
}

final class SidesPanelPointerView: NSView {
    var changed: @MainActor (Bool) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
    var containsPointer: Bool {
        guard let window, window.isVisible else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

// MARK: - At the edge, while not pinned

/// Where the pointer is, as the edge view's strips answer it.
@MainActor final class SidesPanelProbes {
    var edge: (() -> Bool)?
    var handle: (() -> Bool)?
    var panel: (() -> Bool)?
}

/// The panel while it is not pinned: a faint handle at the window's right
/// edge, the strip that brings the panel, and the panel itself when it is
/// out, laid over the conversation.
struct SidesPanelEdge: View {
    let model: WorkspaceModel
    let parentID: String
    @ObservedObject var reveal: SidesPanelReveal
    @State private var probes = SidesPanelProbes()
    /// Worked out when a side's activity changes, not on every change to the
    /// workspace: the handle is all that shows most of the time.
    @State private var activity = SidesPanelActivity()
    @State private var handleHovered = false
    var body: some View {
        ZStack(alignment: .trailing) {
            if reveal.shown {
                SidesPanel(model: model, parentID: parentID, pinned: false)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.piHairlineStrong).frame(width: 1) }
                    // A close shadow to lift the panel's edge and a wide one
                    // to set it above the conversation: one alone read flat
                    // in the light appearance.
                    .shadow(color: Color.piShadow, radius: 2, x: -1)
                    .shadow(color: Color.piShadow, radius: 24, x: -8)
                    .background(SidesPanelPointerArea(changed: { _ in }, asks: { [probes] in probes.panel = $0 }))
                    .transition(.move(edge: .trailing))
            } else if activity.sides > 0 {
                SidesPanelHandle(activity: activity, hovered: handleHovered)
                    .background(SidesPanelPointerArea(changed: { [reveal] inside in handleHovered = inside; reveal.edge(inside) },
                                                      asks: { [probes] in probes.handle = $0 }).padding(-4))
                    .padding(.trailing, SidesPanelHandle.inset)
                    .transition(.opacity)
            }
            SidesPanelPointerArea(changed: { [reveal] in reveal.edge($0) }, asks: { [probes] in probes.edge = $0 })
                .frame(width: SidesPanelMetrics.edgeWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .piAnimation(PiMotion.glide, value: reveal.shown)
        .onAppear {
            reveal.pointerAtEdge = { [probes] in probes.edge?() == true || probes.handle?() == true }
            reveal.pointerOnPanel = { [probes] in probes.panel?() == true }
            activity = model.sidesPanelActivity(of: parentID)
        }
        .onChange(of: parentID) { _, id in activity = model.sidesPanelActivity(of: id) }
        .onReceive(model.activityChanged.receive(on: DispatchQueue.main)) { _ in
            let next = model.sidesPanelActivity(of: parentID)
            if next != activity { activity = next }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A thin grip at the window's right edge while the panel is hidden,
/// carrying the ring of a side that is working or the dot of a new reply.
/// Resting the pointer on it brings the panel, as resting it on the edge
/// does; it takes no clicks, so nothing under it stops working.
struct SidesPanelHandle: View {
    let activity: SidesPanelActivity
    var hovered = false
    /// Clear of the side pane's scroll bar when the system shows scroll bars
    /// all the time; against the edge when they only show while scrolling.
    static var inset: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 3 : 3
    }
    var body: some View {
        VStack(spacing: 6) {
            if activity.working { PiSpinner(size: 9) }
            else if activity.failed { UnreadDot(failure: true) }
            else if activity.unread { UnreadDot() }
            Capsule(style: .continuous).fill(Color.piInkTertiary.opacity(hovered ? 0.8 : 0.45)).frame(width: 4, height: 34)
                .piAnimation(PiMotion.quick, value: hovered)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityIdentifier("sidesPanelHandle")
    }
    private var label: String {
        let count = "\(activity.sides) side\(activity.sides == 1 ? "" : "s")"
        if activity.working { return count + ", one working. Rest the pointer on the window's right edge to show them." }
        if activity.unread { return count + ", one with a new reply. Rest the pointer on the window's right edge to show them." }
        return count + ". Rest the pointer on the window's right edge to show them."
    }
}

// MARK: - The panel

/// The open chat's sides: New side first, then each side with its mark, its
/// title and what it last did, the one in the side pane highlighted. Pinned,
/// it is a column of the window; otherwise it lies over the conversation.
struct SidesPanel: View {
    @ObservedObject var model: WorkspaceModel
    let parentID: String?
    let pinned: Bool
    /// The highlight glides to the side chosen, as the sidebar's does.
    @Namespace private var selectionGlide
    var body: some View {
        let entries = parentID.map { model.sidesPanelEntries(of: $0) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Sides").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.5)
                if !entries.isEmpty {
                    Text("\(entries.count)").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).monospacedDigit()
                }
                Spacer()
                PiIconButton(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin the sides panel" : "Pin the sides panel open",
                             tone: pinned ? .accent : .neutral, size: 24, filled: pinned) { [model] in model.setSidesPanelPinned(!pinned) }
                    .accessibilityIdentifier("sidesPanelPin")
            }
            .padding(.leading, PiSpacing.lg).padding(.trailing, PiSpacing.sm).padding(.top, 10)
            if let title = parentID.flatMap({ model.record($0)?.title }) {
                Text("of “\(title)”").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, PiSpacing.lg).padding(.top, 1).padding(.bottom, PiSpacing.sm)
                    .help(title)
            }
            ScrollView {
                VStack(spacing: 2) {
                    if let parentID {
                        newSide(parentID)
                        ForEach(entries) { entry in SidesPanelRowSlot(model: model, entry: entry) }
                    } else {
                        Text("Open a chat to see its sides.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, PiSpacing.sm).padding(.bottom, PiSpacing.md)
            }
            .environment(\.piSelectionNamespace, selectionGlide)
            .modifier(SidebarMinuteClock())
        }
        .frame(width: SidesPanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.piWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sides")
        .accessibilityIdentifier("sidesPanel")
    }

    private func newSide(_ parentID: String) -> some View {
        PiSelectableRow(selected: false, action: { [model] in model.openSideFromSidesPanel(parentID: parentID) }) {
            HStack(spacing: 9) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piAccent)
                    .frame(width: 16, height: 16)
                Text("New side").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.piAccent)
                Spacer(minLength: 0)
            }
        }
        .disabled(!model.canOpenSide(parentID) || model.installPreparing)
        .help("Open a new side conversation beside this chat")
        .accessibilityIdentifier("sidesPanelNewSide")
    }
}

/// A side's row, from its loaded page while it has one (so a run shows as it
/// goes), else from the accounting the sidebar reads.
private struct SidesPanelRowSlot: View {
    let model: WorkspaceModel
    let entry: SidesPanelEntry
    var body: some View {
        let unread = model.unreadOutputCount(sessionID: entry.id) > 0, failed = model.unreadFailure(sessionID: entry.id)
        if let display = model.displays[entry.id] {
            SidesPanelLiveRow(model: model, entry: entry, session: display, footer: display.footer, unread: unread, failed: failed)
        } else {
            SidesPanelRetainedRow(model: model, entry: entry, accounting: model.chatAccounting.row(for: entry.id), unread: unread, failed: failed)
        }
    }
}

private struct SidesPanelLiveRow: View {
    let model: WorkspaceModel
    let entry: SidesPanelEntry
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics
    let unread: Bool
    let failed: Bool
    @Environment(\.sidebarMinute) private var minute
    private var stats: ChatRowStats {
        let now = minute ?? Date()
        var value = ChatRowStats(totals: footer.gateway, timing: footer.timing, now: now)
        value.updateActivity(state: session.state, loading: session.loading, activity: session.activity)
        if let at = session.messages.last(where: { $0.at != nil })?.at { value.noteActivity(max(value.lastActivity ?? 0, at / 1_000), now: now) }
        return value
    }
    var body: some View { SidesPanelRow(model: model, entry: entry, stats: stats, unread: unread, failed: failed) }
}

private struct SidesPanelRetainedRow: View {
    let model: WorkspaceModel
    let entry: SidesPanelEntry
    @ObservedObject var accounting: CachedSessionAccounting
    let unread: Bool
    let failed: Bool
    @Environment(\.sidebarMinute) private var minute
    var body: some View {
        SidesPanelRow(model: model, entry: entry, stats: ChatRowStats(totals: accounting.totals, now: minute ?? Date()), unread: unread, failed: failed)
    }
}

/// One side: its mark (a ring while it works, the orange dot of a new reply,
/// the red one of a failure, else a quiet dot), its title, and what it is
/// doing or when it last did anything.
struct SidesPanelRow: View {
    let model: WorkspaceModel
    let entry: SidesPanelEntry
    let stats: ChatRowStats
    let unread: Bool
    let failed: Bool
    private var working: Bool { stats.busy || stats.loading }
    var body: some View {
        PiSelectableRow(selected: entry.open, action: { [model, id = entry.id] in Task { await model.openFromSidesPanel(id) } }) {
            HStack(alignment: .top, spacing: 9) {
                mark.frame(width: 16, height: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 13, weight: entry.open || unread ? .semibold : .regular)).foregroundStyle(Color.piInk)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    detail
                }
                Spacer(minLength: 0)
            }
        }
        .help(entry.title)
        .accessibilityIdentifier("sidesPanelRow")
    }
    @ViewBuilder private var mark: some View {
        if working { PiSpinner(size: 11) }
        else if failed { UnreadDot(failure: true) }
        else if unread { UnreadDot() }
        else { Circle().fill(Color.piInkTertiary.opacity(0.5)).frame(width: 6, height: 6).accessibilityHidden(true) }
    }
    /// What the side is doing, in the sidebar's words, then how long ago it
    /// last did anything.
    private var lead: (text: String, color: Color)? {
        if working { return (PiSessionState.label(stats.state, loading: stats.loading), Color.piWarning) }
        if RunState(rawValue: stats.state).isStopped {
            return (PiSessionState.label(stats.state, costLimited: stats.costLimited),
                    RunState(rawValue: stats.state) == .paused ? Color.piInfo : stats.costLimited ? Color.piWarning : Color.piDanger)
        }
        if failed { return ("Failed", Color.piDanger) }
        if unread { return ("New reply", Color.piAccent) }
        return nil
    }
    private var detail: some View {
        let lead = lead
        let recency = stats.recencyLabel
        return HStack(spacing: 0) {
            if let lead { Text(lead.text).foregroundStyle(lead.color).fontWeight(.medium) }
            if let recency { Text((lead == nil ? "" : " · ") + recency) }
            else if lead == nil { Text(entry.saved ? "Saved" : "Not saved yet") }
        }
        .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).lineLimit(1)
    }
}

// MARK: - What the panel lists, and what it does

extension WorkspaceModel {
    /// The open chat's sides as the panel lists them, in the sidebar's order:
    /// its saved sides, and the one beside it first while it is not saved yet.
    func sidesPanelEntries(of parentID: String) -> [SidesPanelEntry] {
        let shown = sides[parentID]
        var entries = chats
            .filter { $0.parentSessionID == parentID && !$0.isBackgroundTask && (!$0.isArchived || $0.id == shown?.id) }
            .sorted(by: ChatRecord.sidebarPrecedes)
            .map { SidesPanelEntry(id: $0.id, title: $0.title, open: $0.id == shown?.id, saved: true) }
        if let shown, !entries.contains(where: { $0.id == shown.id }) {
            entries.insert(SidesPanelEntry(id: shown.id, title: shown.pending ? "New side" : "Side conversation", open: true, saved: false), at: 0)
        }
        return entries
    }

    /// Whether the panel has anything to offer beside this chat: sides of
    /// its own, or a new one.
    func sidesPanelAvailable(for parentID: String) -> Bool {
        canOpenSide(parentID) || !sidesPanelEntries(of: parentID).isEmpty
    }

    /// What the handle carries: the sides other than the one on screen that
    /// are working, have a new reply, or failed.
    func sidesPanelActivity(of parentID: String) -> SidesPanelActivity {
        let entries = sidesPanelEntries(of: parentID)
        var activity = SidesPanelActivity(sides: entries.count)
        for entry in entries where !entry.open {
            if let display = displays[entry.id], display.busy || display.loading { activity.working = true }
            if unreadOutputCount(sessionID: entry.id) > 0 { activity.unread = true }
            if unreadFailure(sessionID: entry.id) { activity.failed = true }
        }
        return activity
    }

    /// A side chosen in the panel. It opens in the side pane, as one chosen
    /// in the sidebar does, and nothing in the sidebar unfolds for it.
    func openFromSidesPanel(_ id: String) async {
        await openFromSidebar(id)
    }

    /// New side, from the panel. Pinned, the panel stays beside the Usage
    /// Report and Background Requests too; the side opens on the chats page,
    /// as a side chosen in the panel does, not behind the page on screen.
    func openSideFromSidesPanel(parentID: String) {
        if page != .chats { page = .chats }
        openSide(parentID: parentID)
    }

    /// Pinned, the panel is a column of the window; unpinned under the
    /// pointer, it stays out over the conversation until the pointer leaves.
    func setSidesPanelPinned(_ pinned: Bool) {
        guard sidesPanelPinned != pinned else { return }
        sidesPanelPinned = pinned
        if pinned { sidesPanelReveal.hide() } else { sidesPanelReveal.show() }
    }
}
