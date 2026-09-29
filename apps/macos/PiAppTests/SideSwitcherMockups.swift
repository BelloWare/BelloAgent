import SwiftUI
import AppKit
@testable import PiApp

// Mockups of switching between a chat's sides beside the side, round two
// (`PI_APP_UI_GALLERY_SIDES_ONLY`, scenes 23*). Round one (22*, 874315c) was
// turned down: tabs that crowd the header and hide sides under More, a heavy
// third column, letter tiles, a plain dropdown. These are pictures, not the
// feature: nothing here switches anything. The design chosen is built in the
// app properly, and this file goes with `SidePaneMockupSlots`.
//
//   A  a pager beside the side's title; its count opens the sides as cards
//   B  a floating capsule of marks under the header; a list on hover
//   C  a slim strip on the seam between the chat and its side; a card on hover
//   D  compact chips above the side's composer
//   E  compact tabs in the window's top strip above the side
//   F  the sides' marks beside the title; an overview of the sides as cards
//
// Every design draws the same marks: the open side a short bar in the
// accent, a working side a turning ring, a new reply the sidebar's orange
// dot, a quiet side a faint dot.

// MARK: - What the designs draw from

enum SideSwitcherStatus: Hashable {
    case idle, running, unread, failed
}

struct SideSwitcherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let status: SideSwitcherStatus
    /// When it last did anything: "2m" while working, else "3m ago".
    let activity: String
    /// The question that started it, and the start of its last reply.
    let question: String
    let snippet: String
    let selected: Bool

    /// What a row says of it, beside its title.
    var shortLabel: String {
        if selected { return "Open" }
        switch status {
        case .running: return "Working · " + activity
        case .unread, .failed, .idle: return activity
        }
    }
    /// What a card says of it, under its title.
    var statusLine: String {
        if selected { return "Open beside the chat" }
        switch status {
        case .running: return "Working for " + activity
        case .unread: return "New reply · " + activity
        case .failed: return "Failed · " + activity
        case .idle: return "Read · " + activity
        }
    }
    /// A label in the accent: the side open, working, or with a new reply.
    var accented: Bool { selected || status == .running || status == .unread }
    var emphasized: Bool { selected || status == .unread }
}

@MainActor enum SideSwitcherMockupData {
    /// The chat's sides in the sidebar's order, the one shown beside it
    /// first if it is not saved yet, each with the status the sidebar gives it.
    static func items(model: WorkspaceModel, parentID: String, state: SideSwitcherMockupState) -> [SideSwitcherItem] {
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
            return SideSwitcherItem(id: chat.id, title: chat.title, status: status, activity: state.activity[chat.id] ?? "",
                                    question: state.questions[chat.id] ?? "", snippet: state.snippets[chat.id] ?? "",
                                    selected: chat.id == shown?.id)
        }
    }
}

// MARK: - Shared parts

/// Where the designs' parts sit in the window, for what floats over it.
struct SideMockupAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Names this view's bounds for what floats over the window, beside the
    /// bounds its own parts named.
    func sideMockupAnchor(_ name: String) -> some View {
        transformAnchorPreference(key: SideMockupAnchors.self, value: .bounds) { anchors, bounds in anchors[name] = bounds }
    }
    /// The hover card's surface, which the app's cards and popovers wear.
    func sideMockupCard(radius: CGFloat = PiRadius.md) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.piSurface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.piHairlineStrong, lineWidth: 1))
            .shadow(color: Color.piShadow, radius: 10, y: 3)
    }
    /// This view with its top-left corner at a point of the space it fills.
    func mockupPlaced(x: CGFloat, y: CGFloat) -> some View {
        fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: x, y: y)
    }
    /// This view centred across a rectangle, its top at `y`.
    func mockupPlaced(centeredIn rect: CGRect, y: CGFloat) -> some View {
        fixedSize()
            .frame(width: rect.width, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: rect.minX, y: y)
    }
}

/// A working side's ring. The app's would turn; a picture holds it still.
struct SideWorkingRing: View {
    var size: CGFloat = 10
    var body: some View {
        Circle().trim(from: 0.1, to: 0.78)
            .stroke(Color.piAccent, style: StrokeStyle(lineWidth: max(1.3, size * 0.15), lineCap: .round))
            .rotationEffect(.degrees(-60))
            .frame(width: size, height: size)
    }
}

/// A side's mark where a row would be too much.
struct SideDot: View {
    let item: SideSwitcherItem
    var vertical = false
    /// The room a mark takes along the line of marks.
    static func length(_ item: SideSwitcherItem) -> CGFloat { item.selected ? 16 : 12 }
    var body: some View {
        ZStack {
            if item.selected {
                Capsule().fill(Color.piAccent).frame(width: vertical ? 5 : 16, height: vertical ? 16 : 5)
            } else {
                switch item.status {
                case .running: SideWorkingRing(size: 10)
                case .unread: Circle().fill(Color.piBrandOrange).frame(width: 7, height: 7)
                case .failed: Circle().fill(Color.piDanger).frame(width: 7, height: 7)
                case .idle: Circle().fill(Color.piInkTertiary.opacity(0.6)).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: vertical ? 12 : Self.length(item), height: vertical ? Self.length(item) : 12)
    }
}

/// A side's mark at the head of a row: the working ring, the new-reply dot,
/// a failure, or the branch every side row carries.
struct SideRowMark: View {
    let item: SideSwitcherItem
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            switch item.status {
            case .running: SideWorkingRing(size: size - 3)
            case .unread: Circle().fill(Color.piBrandOrange).frame(width: 7, height: 7)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: size - 3)).foregroundStyle(Color.piDanger)
            case .idle:
                Image(systemName: "arrow.triangle.branch").font(.system(size: size - 4, weight: .semibold))
                    .foregroundStyle(item.selected ? Color.piAccent : Color.piInkTertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The side's question, set off by the bar a quotation carries.
struct SideQuestion: View {
    let text: String
    var lines = 1
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color.piHairlineStrong).frame(width: 2)
            Text(text).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(lines).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Open Side, as a list of sides offers it.
struct SideOpenButton: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
            Text("Open Side").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.piAccent)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.piAccentSoft, in: Capsule())
    }
}

/// The side header's own parts, which every design keeps: its title, its
/// state badge, what it shares of its chat, and Bring Back, Keep, the chat's
/// actions and Close.
@MainActor struct SideHeaderParts {
    let context: SidePaneHeaderContext
    var title: String { context.side.kept ? context.chat.title : "Side conversation" }
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
}

/// The side's header as the app draws it, with something beside the title
/// and the state badge moved down beside what the side shares.
struct SideHeaderWithAccessory<Accessory: View>: View {
    let context: SidePaneHeaderContext
    @ViewBuilder var accessory: Accessory
    private var parts: SideHeaderParts { SideHeaderParts(context: context) }
    var body: some View {
        HStack(alignment: .center, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(parts.title).font(PiFont.title(15)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                    accessory.fixedSize()
                }
                HStack(spacing: 6) { parts.badge; parts.boundary }
            }
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: PiSpacing.sm) { parts.actions }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 10).padding(.bottom, 8)
        .background(Color.piContent)
    }
}

// MARK: - A · A pager beside the title

/// ‹ 2 of 4 › beside the side's title: the arrows step to the chat's
/// previous and next side, and the count opens them all as cards. A ring or
/// a dot after the count says another side is working or has a new reply.
struct SidePager: View {
    let items: [SideSwitcherItem]
    let isOpen: Bool
    private var position: Int { (items.firstIndex { $0.selected } ?? 0) + 1 }
    private func others(_ status: SideSwitcherStatus) -> Bool { items.contains { !$0.selected && $0.status == status } }
    var body: some View {
        HStack(spacing: 0) {
            step("chevron.left", enabled: position > 1)
            HStack(spacing: 7) {
                Text("\(position) of \(items.count)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(isOpen ? Color.piInk : Color.piInkSecondary)
                if others(.running) || others(.unread) {
                    HStack(spacing: 4) {
                        if others(.running) { SideWorkingRing(size: 9) }
                        if others(.unread) { Circle().fill(Color.piBrandOrange).frame(width: 6, height: 6) }
                    }
                }
            }
            .padding(.horizontal, 8).frame(height: 20)
            .background {
                if isOpen { Capsule().fill(Color.piSurface).shadow(color: Color.piShadow, radius: 2, y: 1) }
            }
            .sideMockupAnchor("pager")
            step("chevron.right", enabled: position < items.count)
        }
        .padding(2)
        .background(Color.piFill, in: Capsule())
    }
    private func step(_ symbol: String, enabled: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.piInkSecondary.opacity(enabled ? 1 : 0.35))
            .frame(width: 20, height: 20)
            .contentShape(Circle())
    }
}

/// A popover's outline: the hover card's rounded surface with an arrow on
/// its top edge, pointing at what opened it.
struct SidePopoverShape: Shape {
    var arrowX: CGFloat
    var radius: CGFloat = PiRadius.md
    static let arrowWidth: CGFloat = 18
    static let arrowHeight: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        let top = rect.minY + Self.arrowHeight
        let r = min(radius, (rect.height - Self.arrowHeight) / 2, rect.width / 2)
        let half = Self.arrowWidth / 2
        let x = min(max(arrowX, rect.minX + r + half), rect.maxX - r - half)
        // The arrow's tip is rounded a little, as AppKit's is.
        let side = (half * half + Self.arrowHeight * Self.arrowHeight).squareRoot()
        let round: CGFloat = 2.5
        let tip = CGPoint(x: x, y: rect.minY)
        let before = CGPoint(x: x - half * round / side, y: rect.minY + Self.arrowHeight * round / side)
        let after = CGPoint(x: x + half * round / side, y: rect.minY + Self.arrowHeight * round / side)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: top))
        path.addLine(to: CGPoint(x: x - half, y: top))
        path.addLine(to: before)
        path.addQuadCurve(to: after, control: tip)
        path.addLine(to: CGPoint(x: x + half, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: top + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}

/// The chat's sides as cards: each with its mark, its title, the question
/// that started it and the start of its last reply. Its arrow points at the
/// count that opened it.
struct SideCardsPopover: View {
    let parentTitle: String
    let items: [SideSwitcherItem]
    /// Where the arrow sits, from the popover's leading edge.
    var arrowX: CGFloat = 40
    static let width: CGFloat = 388
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: PiSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sides").font(PiFont.heading).foregroundStyle(Color.piInk)
                    Text("of “\(parentTitle)”").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: PiSpacing.sm)
                SideOpenButton()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            VStack(spacing: 2) { ForEach(items) { SideCardRow(item: $0) } }
                .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .padding(.top, SidePopoverShape.arrowHeight)
        .frame(width: Self.width)
        .background(SidePopoverShape(arrowX: arrowX).fill(Color.piSurface))
        .overlay(SidePopoverShape(arrowX: arrowX).stroke(Color.piHairlineStrong, lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 10, y: 3)
    }
}

struct SideCardRow: View {
    let item: SideSwitcherItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SideRowMark(item: item).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.system(size: 13, weight: item.emphasized ? .semibold : .medium))
                        .foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(item.shortLabel).font(item.selected ? .system(size: 10.5, weight: .semibold) : PiFont.caption)
                        .foregroundStyle(item.selected || item.status == .running ? Color.piAccent : Color.piInkTertiary)
                }
                SideQuestion(text: item.question)
                Text(item.snippet).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(item.selected ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - B · A floating capsule

/// The chat's sides as marks in a small capsule at the top of the side,
/// in the window's title band where a window's title would be.
struct SideCapsule: View {
    let items: [SideSwitcherItem]
    var body: some View {
        HStack(spacing: 8) { ForEach(items) { SideDot(item: $0) } }
            .padding(.horizontal, 11).frame(height: 24)
            .background(Color.piSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
            .shadow(color: Color.piShadow, radius: 6, y: 2)
    }
}

/// The capsule under the pointer, grown in place into the sides' list.
struct SideCapsulePanel: View {
    let items: [SideSwitcherItem]
    static let width: CGFloat = 336
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { ForEach(items) { SideDot(item: $0) } }.frame(height: 30)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            VStack(spacing: 1) { ForEach(items) { row($0) } }.padding(6)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            HStack(spacing: 9) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 14)
                Text("Open Side").font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.piAccent)
            .padding(.horizontal, 14).frame(height: 34)
        }
        .frame(width: Self.width)
        .sideMockupCard(radius: 14)
    }
    private func row(_ item: SideSwitcherItem) -> some View {
        HStack(spacing: 9) {
            SideRowMark(item: item)
            Text(item.title).font(.system(size: 12.5, weight: item.emphasized ? .semibold : .regular))
                .foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(item.shortLabel).font(PiFont.caption)
                .foregroundStyle(item.selected || item.status == .running ? Color.piAccent : Color.piInkTertiary)
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(item.selected ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - C · A strip on the seam

/// The chat's sides as marks down a slim strip on the seam between the chat
/// and its side, where the reader's eye crosses from one to the other.
struct SideSeamStrip: View {
    let items: [SideSwitcherItem]
    var hovered: String? = nil
    static let width: CGFloat = 22
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 10
    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(items) { item in
                SideDot(item: item, vertical: true)
                    .background {
                        if item.id == hovered { Circle().fill(Color.piFillStrong).frame(width: 20, height: 20) }
                    }
            }
            Rectangle().fill(Color.piHairlineStrong).frame(width: 10, height: 1)
            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.piInkTertiary)
                .frame(width: 12, height: 12)
        }
        .padding(.vertical, Self.inset)
        .frame(width: Self.width)
        .background(Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 6, y: 2)
    }
    /// Where the middle of a side's mark sits, from the strip's top.
    static func markCenter(_ index: Int, in items: [SideSwitcherItem]) -> CGFloat {
        var y = inset
        for (offset, item) in items.enumerated() {
            let length = SideDot.length(item)
            if offset == index { return y + length / 2 }
            y += length + spacing
        }
        return y
    }
}

/// What the pointer on a mark of the seam shows: the side, as a card.
struct SideSeamCard: View {
    let item: SideSwitcherItem
    static let width: CGFloat = 276
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SideRowMark(item: item)
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            Text(item.statusLine).font(PiFont.micro).foregroundStyle(item.accented ? Color.piAccent : Color.piInkSecondary)
            SideQuestion(text: item.question, lines: 2)
            Text(item.snippet).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(3).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .sideMockupCard()
    }
}

// MARK: - D · Chips above the composer

/// The chat's sides as chips just above the side's composer, where the
/// reader is about to type: the open side in the accent, the others quiet.
struct SideChipsRow: View {
    let items: [SideSwitcherItem]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { chip($0) }
            Image(systemName: "plus").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.piInkSecondary)
                .frame(width: 24, height: 24)
                .background(Color.piSurface, in: Circle())
                .overlay(Circle().stroke(Color.piHairline, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.sm).padding(.bottom, 2)
    }
    private func chip(_ item: SideSwitcherItem) -> some View {
        HStack(spacing: 6) {
            if item.selected {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.piAccent)
                    .frame(width: 12, height: 12)
            } else {
                SideDot(item: item)
            }
            if item.selected {
                Text(item.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.piAccent)
                    .lineLimit(1).fixedSize()
            } else {
                Text(item.title).font(.system(size: 11.5, weight: item.emphasized ? .semibold : .medium))
                    .foregroundStyle(item.status == .unread ? Color.piInk : Color.piInkSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 88, alignment: .leading)
            }
        }
        .padding(.leading, 8).padding(.trailing, 10).frame(height: 24)
        .background(item.selected ? Color.piAccentSoft : Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(item.selected ? Color.piAccent.opacity(0.28) : Color.piHairline, lineWidth: 1))
    }
}

// MARK: - E · Tabs in the window's top strip

/// The chat's sides as compact tabs in the window's own strip above the
/// side, as a browser keeps its tabs: every side has the same share and none
/// is hidden; the open one is raised. Its title is the open tab's, so the
/// header keeps one line: the badge, what the side shares and the actions.
struct SideTopTabsHeader: View {
    let context: SidePaneHeaderContext
    let items: [SideSwitcherItem]
    private var parts: SideHeaderParts { SideHeaderParts(context: context) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    let next: SideSwitcherItem? = offset + 1 < items.count ? items[offset + 1] : nil
                    tab(item, divided: next.map { !item.selected && !$0.selected } ?? false)
                }
                Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                    .frame(width: 26, height: 26).padding(.leading, 4)
            }
            .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 5)
            .background(Color.piWindow)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            HStack(alignment: .center, spacing: 6) {
                parts.badge
                parts.boundary
                Spacer(minLength: PiSpacing.sm)
                HStack(spacing: PiSpacing.sm) { parts.actions }
            }
            .padding(.horizontal, PiSpacing.lg).padding(.vertical, 6)
            .background(Color.piContent)
        }
    }
    private func tab(_ item: SideSwitcherItem, divided: Bool) -> some View {
        HStack(spacing: 6) {
            SideRowMark(item: item, size: 13)
            if item.selected {
                Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.piInk).lineLimit(1).fixedSize()
            } else {
                Text(item.title).font(.system(size: 12, weight: item.emphasized ? .semibold : .regular))
                    .foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .frame(maxWidth: item.selected ? nil : .infinity)
        .layoutPriority(item.selected ? 1 : 0)
        .background {
            if item.selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.piSurface)
                    .shadow(color: Color.piShadow, radius: 2, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
            }
        }
        .overlay(alignment: .trailing) {
            if divided { Rectangle().fill(Color.piHairlineStrong).frame(width: 1, height: 14).offset(x: 1) }
        }
    }
}

// MARK: - F · Marks beside the title, and an overview

/// The chat's sides as their marks beside the side's title, in one quiet
/// pill; pressing it lays every side out as a card over the side.
struct SideDotsButton: View {
    let items: [SideSwitcherItem]
    let isOpen: Bool
    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) { ForEach(items) { SideDot(item: $0) } }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.piInkTertiary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.horizontal, 9).frame(height: 22)
        .background(isOpen ? Color.piFillStrong : Color.piFill, in: Capsule())
    }
}

/// Every side of the chat as a card, two to a row, laid over the side: the
/// question that started it as the transcript shows a message, and the start
/// of its last reply.
struct SideOverview: View {
    let parentTitle: String
    let items: [SideSwitcherItem]
    let width: CGFloat
    private var rows: [Int] { Array(stride(from: 0, to: items.count, by: 2)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: PiSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(items.count) sides").font(PiFont.heading).foregroundStyle(Color.piInk)
                    Text("of “\(parentTitle)”").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: PiSpacing.sm)
                SideOpenButton()
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(rows, id: \.self) { start in
                    GridRow {
                        SideOverviewCard(item: items[start])
                        if start + 1 < items.count { SideOverviewCard(item: items[start + 1]) } else { Color.clear }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: width)
        .sideMockupCard(radius: 14)
    }
}

struct SideOverviewCard: View {
    let item: SideSwitcherItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                SideRowMark(item: item).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                    Text(item.statusLine).font(PiFont.micro).foregroundStyle(item.accented ? Color.piAccent : Color.piInkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(item.question).font(PiFont.caption).foregroundStyle(TranscriptPalette.text).lineLimit(2).truncationMode(.tail)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TranscriptPalette.userBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(item.snippet).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(3).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.piContent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(item.selected ? Color.piAccent.opacity(0.75) : Color.piHairline, lineWidth: item.selected ? 1.5 : 1))
    }
}

// MARK: - The window the gallery draws them in

@MainActor final class SideSwitcherMockupState: ObservableObject {
    enum Design: Equatable { case today, pager, capsule, seam, chips, topTabs, overview }
    @Published var design: Design = .today
    /// The design's second state: its cards or list open, or the pointer on a mark.
    @Published var isOpen = false
    var parentTitle = ""
    /// When each side last did anything, what started it and how its last
    /// reply begins, as the fixture says.
    var activity: [String: String] = [:]
    var questions: [String: String] = [:]
    var snippets: [String: String] = [:]
    /// The side under the pointer on the seam.
    var hovered: String?
}

/// The real workspace window, with the design being shown put in the side
/// pane, and what it floats drawn over the window, above the seam.
struct SideSwitcherMockupWindow: View {
    let model: WorkspaceModel
    @ObservedObject var state: SideSwitcherMockupState
    var body: some View {
        WorkspaceView(model: model)
            .environment(\.sidePaneMockupSlots, slots)
            .overlayPreferenceValue(SideMockupAnchors.self) { anchors in
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) { floating(anchors, proxy) }
                }
                .allowsHitTesting(false)
            }
    }

    private func items(_ parentID: String) -> [SideSwitcherItem] {
        SideSwitcherMockupData.items(model: model, parentID: parentID, state: state)
    }
    /// How much the header moves down for the capsule above it.
    static let capsuleBand: CGFloat = 22

    private var slots: SidePaneMockupSlots? {
        let fixture = self.state, workspace = self.model, isOpen = self.state.isOpen
        func sides(_ parentID: String) -> [SideSwitcherItem] { SideSwitcherMockupData.items(model: workspace, parentID: parentID, state: fixture) }
        switch fixture.design {
        case .today:
            return nil
        case .pager:
            return SidePaneMockupSlots(header: { context, _ in
                AnyView(SideHeaderWithAccessory(context: context) { SidePager(items: sides(context.side.parentID), isOpen: isOpen) }
                    .sideMockupAnchor("header"))
            })
        case .capsule:
            // The header moves down a little to leave the title band to the capsule.
            return SidePaneMockupSlots(header: { _, header in
                AnyView(header.padding(.top, SideSwitcherMockupWindow.capsuleBand).background(Color.piContent).sideMockupAnchor("header"))
            })
        case .seam:
            return SidePaneMockupSlots(header: { _, header in AnyView(header.sideMockupAnchor("header")) })
        case .chips:
            return SidePaneMockupSlots(aboveComposer: { context in AnyView(SideChipsRow(items: sides(context.side.parentID))) })
        case .topTabs:
            return SidePaneMockupSlots(header: { context, _ in
                AnyView(SideTopTabsHeader(context: context, items: sides(context.side.parentID)))
            })
        case .overview:
            return SidePaneMockupSlots(header: { context, _ in
                AnyView(SideHeaderWithAccessory(context: context) { SideDotsButton(items: sides(context.side.parentID), isOpen: isOpen) }
                    .sideMockupAnchor("header"))
            })
        }
    }

    /// What floats: the pager's cards, the capsule, the seam, the overview.
    /// Drawn here rather than in the pane, whose divider is drawn over it.
    @ViewBuilder private func floating(_ anchors: [String: Anchor<CGRect>], _ proxy: GeometryProxy) -> some View {
        if let header = anchors["header"].map({ proxy[$0] }), let parentID = model.selectedID {
            let list = self.items(parentID)
            switch state.design {
            case .pager:
                if state.isOpen, let pager = anchors["pager"].map({ proxy[$0] }) {
                    let x = min(pager.minX - 24, header.maxX - SideCardsPopover.width - 12)
                    SideCardsPopover(parentTitle: state.parentTitle, items: list, arrowX: pager.midX - x)
                        .mockupPlaced(x: x, y: pager.maxY + 3)
                }
            case .capsule:
                if state.isOpen { SideCapsulePanel(items: list).mockupPlaced(centeredIn: header, y: header.minY + 1) }
                else { SideCapsule(items: list).mockupPlaced(centeredIn: header, y: header.minY + 4) }
            case .seam:
                let top = header.maxY + 16
                let seam = header.minX - 0.5
                SideSeamStrip(items: list, hovered: state.isOpen ? state.hovered : nil)
                    .mockupPlaced(x: seam - SideSeamStrip.width / 2, y: top)
                if state.isOpen, let hovered = state.hovered, let index = list.firstIndex(where: { $0.id == hovered }) {
                    SideSeamCard(item: list[index])
                        .mockupPlaced(x: seam + SideSeamStrip.width / 2 + 8, y: top + SideSeamStrip.markCenter(index, in: list) - 22)
                }
            case .overview:
                if state.isOpen {
                    Rectangle().fill(Color.piContent.opacity(0.88))
                        .frame(width: header.width, height: max(0, proxy.size.height - header.maxY))
                        .mockupPlaced(x: header.minX, y: header.maxY)
                    SideOverview(parentTitle: state.parentTitle, items: list, width: header.width - 24)
                        .mockupPlaced(x: header.minX + 12, y: header.maxY + 10)
                }
            case .today, .chips, .topTabs:
                EmptyView()
            }
        }
    }
}
