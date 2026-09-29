import SwiftUI
import AppKit
@testable import PiApp

// Mockups of switching between a chat's sides right beside the side, drawn
// in the real window for the owner to choose from
// (`PI_APP_UI_GALLERY_SIDES_ONLY`, scenes 22*). They are pictures, not the
// feature: nothing here switches anything. The design chosen is built in the
// app properly and this file goes, with `SidePaneHeaderSlot` if nothing else
// uses it.
//
//   A  tabs across the top of the side pane
//   B  a rail of the chat's sides at the window's right edge, wide or collapsed
//   C  the side's title as a menu of the chat's sides

/// How a side is doing, as its switcher shows it: the sidebar's own marks.
enum SideSwitcherStatus: Hashable {
    case idle, running, unread, failed
}

struct SideSwitcherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let status: SideSwitcherStatus
    /// When it last did anything, in the sidebar's words: "now", "3m ago".
    let activity: String
    let selected: Bool
}

@MainActor enum SideSwitcherMockupData {
    /// The chat's sides in the sidebar's order, and the one shown beside it
    /// if it is not saved yet, with the status the sidebar would give each.
    static func items(model: WorkspaceModel, parentID: String, activity: [String: String]) -> [SideSwitcherItem] {
        let shown = model.sides[parentID]
        var chats = model.chats.filter { $0.parentSessionID == parentID && !$0.isArchived }.sorted(by: ChatRecord.sidebarPrecedes)
        if let shown, !chats.contains(where: { $0.id == shown.id }) {
            chats.insert(ChatRecord(id: shown.id, workspaceID: shown.workspaceID, title: "Side conversation", path: nil, profileID: shown.profileID), at: 0)
        }
        return chats.map { chat in
            let display = model.displays[chat.id]
            let status: SideSwitcherStatus = display?.busy == true ? .running
                : model.unreadFailure(sessionID: chat.id) || display?.state == "error" ? .failed
                : model.unreadOutputCount(sessionID: chat.id) > 0 ? .unread : .idle
            return SideSwitcherItem(id: chat.id, title: chat.title, status: status, activity: activity[chat.id] ?? "",
                                    selected: chat.id == shown?.id)
        }
    }
}

/// A side's mark: the sidebar's spinner, unread dot, failure mark, or the
/// branch glyph side rows carry when there is nothing to say.
struct SideStatusMark: View {
    let status: SideSwitcherStatus
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            switch status {
            case .running: PiSpinner(size: size - 3)
            case .unread: UnreadDot()
            case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: size - 2)).foregroundStyle(Color.piDanger)
            case .idle: Image(systemName: "arrow.triangle.branch").font(.system(size: size - 3, weight: .medium)).foregroundStyle(Color.piInkTertiary)
            }
        }.frame(width: size, height: size)
    }
}

/// The side header's own parts, which every design keeps: its state badge,
/// what it shares of its chat, and Bring Back, Keep, the chat's actions and
/// Close.
@MainActor struct SideHeaderParts {
    let context: SidePaneHeaderContext
    @ViewBuilder var badge: some View {
        let side = context.side
        if side.pending { PiBadge(text: "Created when you send", icon: "square.and.pencil").fixedSize() }
        else { PiBadge(text: side.kept ? "Saved · Read-only" : "In memory", tone: side.kept ? .success : .warning, icon: "arrow.triangle.branch").fixedSize() }
    }
    var boundary: some View {
        Text(context.boundary).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
            .help(context.boundaryDetail)
    }
    @ViewBuilder var actions: some View {
        let side = context.side
        PiIconButton(symbol: "arrow.uturn.backward", label: "Bring Back to Parent Draft…") { context.actions.bringBack() }
        if !side.pending && !side.kept {
            Button { context.actions.keep() } label: { Label("Keep", systemImage: "pin") }.buttonStyle(.piSecondaryCompact)
        }
        ConversationActionsMenu(model: context.model, session: context.session, chat: context.chat)
        PiIconButton(symbol: "xmark", label: "Close side", size: 26) { context.actions.close() }
    }
    /// Room the actions take on the header's first line.
    var actionsWidth: CGFloat { context.side.pending || context.side.kept ? 92 : 160 }
}

// MARK: - A · Tabs across the top of the side pane

/// The chat's sides as tabs across the header's first line, in the pill
/// track of the app's other tabs. The title is the selected tab; the second
/// line keeps the badge, what the side shares and the actions. Tabs that do
/// not fit go under More, and + opens another side.
struct SideTabsHeader: View {
    let context: SidePaneHeaderContext
    let items: [SideSwitcherItem]
    private var parts: SideHeaderParts { SideHeaderParts(context: context) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: items.count, through: 1, by: -1)), id: \.self) { shown in
                    strip(showing: shown)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 6) {
                parts.badge
                parts.boundary
                Spacer(minLength: PiSpacing.sm)
                HStack(spacing: PiSpacing.xs) { parts.actions }
            }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 8).padding(.bottom, 6)
        .background(Color.piContent)
    }

    /// The first `shown` sides as tabs, the rest under More, the selected side
    /// always among the tabs.
    private func strip(showing shown: Int) -> some View {
        let selected = items.first { $0.selected }
        var visible = Array(items.prefix(shown))
        if let selected, !visible.contains(selected), !visible.isEmpty { visible[visible.count - 1] = selected }
        let hidden = items.filter { !visible.contains($0) }
        return HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(visible) { tab($0) }
                if !hidden.isEmpty { more(hidden) }
            }
            .padding(3)
            .background(Color.piFillStrong, in: Capsule())
            PiIconButton(symbol: "plus", label: "Open Side", size: 24) {}
        }
        .fixedSize()
    }

    private func tab(_ item: SideSwitcherItem) -> some View {
        HStack(spacing: 6) {
            SideStatusMark(status: item.status, size: 13)
            Text(item.title).font(.system(size: 12, weight: item.selected ? .semibold : .medium))
                .foregroundStyle(item.selected ? Color.piInk : Color.piInkSecondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: item.selected ? 170 : 104, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background {
            if item.selected { Capsule().fill(Color.piSurface).shadow(color: Color.piShadow, radius: 3, y: 1) }
        }
        .help(item.title + (item.activity.isEmpty ? "" : " · " + item.activity))
    }

    /// The sides under More, counted, with the mark of any that is working,
    /// has a new reply or failed, so none of that is hidden with them.
    private func more(_ hidden: [SideSwitcherItem]) -> some View {
        let marks = [SideSwitcherStatus.running, .unread, .failed].filter { status in hidden.contains { $0.status == status } }
        return HStack(spacing: 4) {
            ForEach(marks, id: \.self) { SideStatusMark(status: $0, size: 12) }
            Text("More").font(.system(size: 12, weight: .medium))
            Text("\(hidden.count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1).background(Color.piFill, in: Capsule())
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
        }
        .foregroundStyle(Color.piInkSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

// MARK: - B · A rail at the window's right edge

/// The chat's sides down the window's right edge, beside the side pane, as
/// the sidebar lists chats on the left: each with its mark, its title and
/// when it last did anything; + to open another side at the top. Collapsed, it
/// keeps one mark per side and the title in the help.
struct SideRail: View {
    let parentTitle: String
    let items: [SideSwitcherItem]
    let collapsed: Bool
    static let width: CGFloat = 224
    static let collapsedWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if collapsed { collapsedBody } else { wideBody }
            Spacer(minLength: 0)
        }
        .frame(width: collapsed ? Self.collapsedWidth : Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.piWindow)
        .overlay(alignment: .leading) { Rectangle().fill(Color.piHairline).frame(width: 1) }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Sides").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.5)
                Text("\(items.count)").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).monospacedDigit()
                Spacer()
                PiIconButton(symbol: "plus", label: "Open Side", tone: .accent, size: 24, filled: true) {}
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 2)
            Text("of “\(parentTitle)”").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                .lineLimit(1).truncationMode(.tail).padding(.horizontal, 18).padding(.bottom, 10)
            VStack(spacing: 2) {
                ForEach(items) { item in row(item) }
            }
            .padding(.horizontal, 8)
        }
    }

    private func row(_ item: SideSwitcherItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SideStatusMark(status: item.status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: item.selected ? .semibold : .regular))
                    .foregroundStyle(Color.piInk).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(subtitle(item)).font(PiFont.caption).foregroundStyle(item.status == .failed ? Color.piDanger : Color.piInkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(item.selected ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
    }

    private func subtitle(_ item: SideSwitcherItem) -> String {
        let state: String
        switch item.status {
        case .running: state = "Working for"
        case .unread: state = "New reply"
        case .failed: state = "Failed"
        case .idle: state = item.selected ? "Open" : "Saved"
        }
        if item.status == .running { return item.activity.isEmpty ? "Working" : state + " " + item.activity }
        return item.activity.isEmpty ? state : state + " · " + item.activity
    }

    private var collapsedBody: some View {
        VStack(spacing: 8) {
            PiIconButton(symbol: "plus", label: "Open Side", tone: .accent, size: 28, filled: true) {}
                .padding(.top, 12)
            Rectangle().fill(Color.piHairline).frame(width: 24, height: 1)
            ForEach(items) { item in
                ZStack(alignment: .topTrailing) {
                    Text(String(item.title.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.selected ? Color.piAccent : Color.piInkSecondary)
                        .frame(width: 32, height: 32)
                        .background(item.selected ? Color.piAccentSoft : Color.piFill, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                    if item.status != .idle {
                        SideStatusMark(status: item.status, size: 12)
                            .padding(2).background(Color.piWindow, in: Circle())
                            .offset(x: 5, y: -5)
                    }
                }
                .help(item.title + (item.activity.isEmpty ? "" : " · " + item.activity))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - C · The title as a menu

/// Today's header with the side's title as a menu: pressing it lists the
/// chat's sides with their marks and when each last did anything, the open
/// one ticked, and Open Side at the end.
struct SideTitleMenuHeader: View {
    let context: SidePaneHeaderContext
    let items: [SideSwitcherItem]
    let open: Bool
    private var parts: SideHeaderParts { SideHeaderParts(context: context) }
    var body: some View {
        HStack(alignment: .center, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Text(context.chat.title).font(PiFont.title(15)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.piInkSecondary)
                        if items.count > 1 {
                            Text("\(items.count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(Color.piInkSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Color.piFill, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(open ? Color.piFillStrong : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.leading, -6)
                    parts.badge
                }
                parts.boundary
            }
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: PiSpacing.sm) { parts.actions }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 10).padding(.bottom, 8)
        .background(Color.piContent)
        .overlay(alignment: .topLeading) {
            if open { menu.offset(x: PiSpacing.lg - 6, y: 36) }
        }
        .zIndex(1)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sides of this chat").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.selected ? Color.piAccent : Color.clear).frame(width: 14)
                    SideStatusMark(status: item.status)
                    Text(item.title).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(item.status == .running ? "working" : item.activity).font(PiFont.caption)
                        .foregroundStyle(item.status == .running ? Color.piAccent : Color.piInkTertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(item.selected ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
            }
            Rectangle().fill(Color.piHairline).frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 10) {
                Color.clear.frame(width: 14, height: 1)
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piAccent).frame(width: 14)
                Text("Open Side").font(PiFont.body).foregroundStyle(Color.piAccent)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .padding(6)
        .frame(width: 340)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairlineStrong, lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 12, y: 4)
    }
}

// MARK: - The window the gallery draws them in

@MainActor final class SideSwitcherMockupState: ObservableObject {
    enum Variant: Equatable { case today, tabs, rail, railCollapsed, menu }
    @Published var variant: Variant = .today
    /// When each side last did anything, as the fixture says.
    var activity: [String: String] = [:]
}

/// The real workspace window, with the side pane's header or a rail beside
/// it replaced by the design being shown.
struct SideSwitcherMockupWindow: View {
    let model: WorkspaceModel
    @ObservedObject var state: SideSwitcherMockupState
    private var parentID: String { model.selectedID ?? "" }
    private var items: [SideSwitcherItem] { SideSwitcherMockupData.items(model: model, parentID: parentID, activity: state.activity) }
    var body: some View {
        HStack(spacing: 0) {
            WorkspaceView(model: model).environment(\.sidePaneHeader, slot)
            if state.variant == .rail || state.variant == .railCollapsed {
                SideRail(parentTitle: model.record(parentID)?.title ?? "", items: items, collapsed: state.variant == .railCollapsed)
            }
        }
    }
    private var slot: SidePaneHeaderSlot? {
        let variant = state.variant, activity = state.activity, model = model
        switch variant {
        case .tabs:
            return SidePaneHeaderSlot { context in
                AnyView(SideTabsHeader(context: context, items: SideSwitcherMockupData.items(model: model, parentID: context.side.parentID, activity: activity)))
            }
        case .menu:
            return SidePaneHeaderSlot { context in
                AnyView(SideTitleMenuHeader(context: context, items: SideSwitcherMockupData.items(model: model, parentID: context.side.parentID, activity: activity), open: true))
            }
        case .today, .rail, .railCollapsed:
            return nil
        }
    }
}
