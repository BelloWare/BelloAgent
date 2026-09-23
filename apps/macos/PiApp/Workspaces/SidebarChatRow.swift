import AppKit
import SwiftUI

/// How many sidebar rows have built their view tree. A test seam, not
/// diagnostics: a selection change must rebuild the two rows whose selection
/// changed and no others, and that is only checkable by counting.
@MainActor enum SidebarRowRenderCount {
    private(set) static var builds = 0
    static func reset() { builds = 0 }
    static func built() { builds &+= 1 }
}

/// Everything a sidebar chat row draws or branches on that does not come from
/// its `ChatRecord`. Together with the record it is the row's whole input, so
/// the row can be compared instead of rebuilt.
///
/// Every group and every row used to observe the whole `WorkspaceModel`, where
/// one `@Published` property invalidates every view that touches the object:
/// one unread dot rebuilt every row of every project, menus and drag surfaces
/// included. The rows now carry values, so a change redraws what changed.
struct SidebarChatRowState: Equatable {
    var selected = false
    var marked = false
    /// Whether any bulk selection is up at all; it changes what the row's
    /// right-click menu offers.
    var anyMarked = false
    var unreadCount = 0
    var unreadFailure = false
    /// Identity of the loaded page, when the chat has one. A row swaps between
    /// retained billing and a live session only when this changes; the live
    /// session's own figures are observed by the row underneath.
    var liveIdentity: ObjectIdentifier?
    var hasSide = false
    var expanded = true
    var draggable = false
    /// "Ready", "Archived · Work connection" — the connection name is only
    /// shown when more than one connection exists.
    var subtitle = ""
    /// What this row's metrics line has to itself; see `ChatRowMetrics`.
    var available: CGFloat = .infinity
    var indent: CGFloat = 0
    /// A failed run is something to look at too; Mark as Read clears it.
    var offersMarkAsRead: Bool { unreadCount > 0 || unreadFailure }
}

/// The open, unsaved side conversation drawn under its parent row.
struct SidebarSideRowState: Equatable {
    var id = ""
    var title = ""
    var kept = false
    var selected = false
    var unreadCount = 0
    var liveIdentity: ObjectIdentifier?
    var available: CGFloat = .infinity
    var indent: CGFloat = 0
}

/// One chat in the sidebar: its press surface, its highlight, its right-click
/// menu and its drag source. Equatable on the record and the state above, so a
/// workspace change that this row does not show leaves it standing.
struct SidebarChatRow: View, Equatable {
    nonisolated static func == (lhs: SidebarChatRow, rhs: SidebarChatRow) -> Bool {
        // `model` and `projectID` are fixed for the row this identity names.
        lhs.chat == rhs.chat && lhs.state == rhs.state
    }
    let model: WorkspaceModel
    let chat: ChatRecord
    let projectID: String
    let state: SidebarChatRowState
    @Environment(\.piReduceMotion) private var reduceMotion
    @State private var insertionAfter: Bool?

    /// A drag surface owns the pointer on draggable rows, so the press has to
    /// route the same way whether it arrives from AppKit or from the button's
    /// own keyboard activation.
    private var click: @MainActor (NSEvent.ModifierFlags) -> Void {
        let model = model, chat = chat
        return { flags in
            SidebarRowClick(modifiers: flags).apply(to: model, sessionID: chat.id) {
                Task {
                    if model.side(chat.id) != nil { await model.selectSide(chat.id) }
                    else if chat.parentSessionID != nil, model.record(chat.parentSessionID ?? "") != nil, !chat.imported { await model.showSide(chat.id) }
                    else { await model.select(chat.id) }
                }
            }
        }
    }
    private var rename: @MainActor () -> Void {
        let model = model, chat = chat
        return { if !chat.isBackgroundTask { model.presentRename(chat.id) } }
    }

    var body: some View {
        let _ = SidebarRowRenderCount.built()
        PiSelectableRow(selected: state.selected, marked: state.marked, providesCursor: !state.draggable,
                        action: { click(NSEvent.modifierFlags) }, doubleClick: rename) {
            ChatRow(model: model, chat: chat, selected: state.selected, unreadCount: state.unreadCount,
                    unreadFailure: state.unreadFailure, live: state.liveIdentity != nil, subtitle: state.subtitle,
                    hasSide: state.hasSide, expanded: state.expanded, available: state.available) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    model.setSidebarSideFolded(chat.id, folded: !model.collapsedSidebarSides.contains(chat.id))
                }
            }
        }
        .contextMenu { menu }
        .overlay {
            if state.draggable {
                GeometryReader { geometry in
                    Color.clear.onDrop(of: [TopicSessionDrag.type], delegate: SessionOrderDrop(model: model, projectID: projectID, targetID: chat.id, height: geometry.size.height, insertionAfter: $insertionAfter))
                }
            }
        }
        .overlay(alignment: insertionAfter == true ? .bottom : .top) {
            if insertionAfter != nil { Rectangle().fill(Color.piAccent).frame(height: 2).allowsHitTesting(false) }
        }
        .modifier(TopicSessionDragSource(model: model, sessionID: chat.id, projectID: projectID, enabled: state.draggable,
                                         click: click, doubleClick: rename))
        .padding(.leading, state.indent)
    }

    @ViewBuilder private var menu: some View {
        if state.anyMarked && state.marked {
            MarkedSessionActions(model: model)
        } else {
            if chat.parentSessionID != nil { Button("Open on Its Own", systemImage: "rectangle.expand.vertical") { Task { await model.select(chat.id) } }; Divider() }
            SessionOrganizationActions(model: model, chat: chat)
            Divider()
            SessionReferenceActions(model: model, sessionID: chat.id)
            if state.offersMarkAsRead { Divider(); Button("Mark as Read") { model.markSessionRead(chat.id) } }
        }
    }
}

/// The open side conversation under its parent. Same bargain as the row above.
struct SidebarSideRow: View, Equatable {
    nonisolated static func == (lhs: SidebarSideRow, rhs: SidebarSideRow) -> Bool { lhs.state == rhs.state }
    let model: WorkspaceModel
    let state: SidebarSideRowState

    var body: some View {
        let _ = SidebarRowRenderCount.built()
        PiSelectableRow(selected: state.selected, action: { [model, state] in Task { await model.selectSide(state.id) } }) {
            SideRow(title: state.title, kept: state.kept, selected: state.selected, unreadCount: state.unreadCount,
                    display: state.liveIdentity == nil ? nil : model.displays[state.id], available: state.available)
        }
        .contextMenu {
            if state.kept, let record = model.record(state.id) { SessionOrganizationActions(model: model, chat: record) }
            SessionReferenceActions(model: model, sessionID: state.id)
            if state.unreadCount > 0 { Button("Mark as Read") { model.markSessionRead(state.id) } }
        }
        .padding(.leading, state.indent)
    }
}

/// One listed chat and, when it is open, the side conversation under it.
struct SidebarGroupRow: Equatable, Identifiable {
    var chat: ChatRecord
    var state: SidebarChatRowState
    var side: SidebarSideRowState?
    var id: String { chat.id }
}

/// Everything one sidebar group draws, worked out once by the project that
/// owns it. The group is compared on this, so a workspace change that does not
/// alter what the group shows leaves its whole subtree — every row, press
/// surface, menu and drag source — standing instead of rebuilt.
///
/// A signature that leaves something out shows the sidebar it drew last.
/// `SidebarAppearanceTests.testEveryRowRedrawsWhenSomethingItShowsChanges`
/// is where that is caught; extend it before adding anything here.
struct SidebarGroupContents: Equatable {
    var groupID = ""
    var indent: CGFloat = 0
    var rows: [SidebarGroupRow] = []
    var hiddenRoots = 0
    var shownRoots = 0
    /// Whether the "Show N more / Show less" line is drawn at all.
    var paginates = false
    /// "No chats yet" and its siblings; nil when the group draws no such line.
    var emptyLabel: String?
}

/// A topic's whole group: its header, the question it can ask about removing
/// itself, and the chats under it.
struct TopicGroupContents: Equatable {
    var header = TopicHeaderState()
    var expanded = true
    var contents = SidebarGroupContents()
}

extension WorkspaceModel {
    /// How many connections there are to name in a row's second line. Asking
    /// `requestProfiles` built an array of every saved connection, and a row
    /// asked once per row per pass.
    var sidebarConnectionCount: Int {
        profiles.reduce(0) { $0 + ($1.api == LiteLLMConfiguration.supportedAPI ? 1 : 0) }
    }
    /// A row's second line while it has no figures to show: its state, and the
    /// connection it runs on when there is more than one to tell apart.
    func sidebarRowSubtitle(_ chat: ChatRecord, namesConnection: Bool) -> String {
        let state = chat.isArchived ? "Archived" : chat.imported ? "Imported" : chat.toolMode == "read-only" ? "Read-only" : "Ready"
        guard namesConnection, !chat.imported, let connection = profiles.first(where: { $0.id == chat.profileID }) else { return state }
        return state + " \u{b7} " + connection.name
    }

    /// Everything one group of one project draws. Reading the model happens
    /// here, once per pass; the group views take values.
    func sidebarGroupContents(in project: WorkspaceRecord, topicID: String?, archived: Bool, filter: String,
                              showEmpty: Bool, showAllMatches: Bool = false,
                              sidebarWidth: CGFloat, namesConnection: Bool) -> SidebarGroupContents {
        let groupID = topicID ?? project.id
        let indent: CGFloat = topicID == nil ? 14 : 28
        let filtering = showAllMatches || !filter.isEmpty
        // The fold is ignored while filtering, so a match cannot be stranded
        // under a folded parent; the chevron and the open side still follow it.
        let folded = collapsedSidebarSides
        let all = SidebarSessionPresentation.filtered(
            sidebarEntries(in: project.id, topicID: topicID, archived: archived, collapsed: filtering ? [] : folded), by: filter)
        let shown = sidebarShownRoots(groupID)
        let selection = Set([focusedSessionID, selectedID].compactMap { $0 })
        let visible = SidebarSessionPresentation.page(all, roots: shown, selected: selection, filtering: filtering)
        let hiddenRoots = filtering ? 0
            : max(0, all.reduce(0) { $0 + ($1.depth == 0 ? 1 : 0) } - visible.reduce(0) { $0 + ($1.depth == 0 ? 1 : 0) })
        let anyMarked = hasMarkedSessions, projectDraggable = !project.isScratch
        var rows: [SidebarGroupRow] = []
        rows.reserveCapacity(visible.count)
        for entry in visible {
            let chat = entry.chat, side = sides[chat.id]
            let selected = focusedSessionID == chat.id || selectedID == chat.id && focusedSessionID == nil
            var row = SidebarGroupRow(chat: chat, state: SidebarChatRowState(
                selected: selected,
                marked: isSessionMarked(chat.id),
                anyMarked: anyMarked,
                unreadCount: unreadOutputCount(sessionID: chat.id),
                unreadFailure: unreadFailure(sessionID: chat.id),
                liveIdentity: displays[chat.id].map(ObjectIdentifier.init),
                hasSide: entry.hasChildren || side?.kept == false,
                expanded: !folded.contains(chat.id),
                draggable: projectDraggable && !chat.isBackgroundTask && chat.connectionTest != true,
                subtitle: sidebarRowSubtitle(chat, namesConnection: namesConnection),
                available: ChatRowMetrics.availableWidth(sidebar: sidebarWidth, indent: indent, depth: entry.depth),
                indent: indent + CGFloat(min(entry.depth, 3) * 14)))
            if let side, !side.kept, !folded.contains(chat.id) {
                row.side = SidebarSideRowState(
                    id: side.id,
                    title: side.kept ? (record(side.id)?.title ?? side.title) : "Side conversation",
                    kept: side.kept,
                    selected: focusedSessionID == side.id,
                    unreadCount: unreadOutputCount(sessionID: side.id),
                    liveIdentity: displays[side.id].map(ObjectIdentifier.init),
                    available: ChatRowMetrics.availableWidth(sidebar: sidebarWidth, indent: indent + 14, depth: entry.depth),
                    indent: indent + CGFloat(14 + min(entry.depth, 3) * 14))
            }
            rows.append(row)
        }
        let empty = showEmpty && visible.isEmpty
            ? (archived ? "No archived chats" : filter.isEmpty ? "No chats yet" : "No matching chats") : nil
        return SidebarGroupContents(groupID: groupID, indent: indent, rows: rows, hiddenRoots: hiddenRoots, shownRoots: shown,
                                    paginates: !filtering && (hiddenRoots > 0 || shown > SidebarSessionPresentation.pageSize),
                                    emptyLabel: empty)
    }

    /// A topic's group, header included. The header's drop highlight is the
    /// group view's own state and is filled in there.
    func topicGroupContents(in project: WorkspaceRecord, topic: TopicRecord, archived: Bool, filter: String,
                            sidebarWidth: CGFloat, namesConnection: Bool) -> TopicGroupContents {
        let entries = sidebarEntries(in: project.id, topicID: topic.id, archived: archived, collapsed: [])
        let expanded = topicIsExpanded(topic) || !filter.isEmpty
        // A topic whose own title matches lists all of its chats.
        let inner = topic.title.localizedCaseInsensitiveContains(filter) ? "" : filter
        let header = TopicHeaderState(projectID: project.id, topicID: topic.id, title: topic.title, trusted: project.trusted,
                                      expanded: expanded, filtering: !filter.isEmpty,
                                      hasUnread: entries.contains { unreadOutputCount(sessionID: $0.id) > 0 || unreadFailure(sessionID: $0.id) },
                                      chats: entries.count)
        let contents = expanded
            ? sidebarGroupContents(in: project, topicID: topic.id, archived: archived, filter: inner, showEmpty: true,
                                   showAllMatches: !filter.isEmpty, sidebarWidth: sidebarWidth, namesConnection: namesConnection)
            : SidebarGroupContents()
        return TopicGroupContents(header: header, expanded: expanded, contents: contents)
    }
}
