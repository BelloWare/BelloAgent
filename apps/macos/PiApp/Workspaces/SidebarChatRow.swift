import AppKit

/// How many sidebar rows have built their view tree. A test seam, not
/// diagnostics: a selection change must rebuild the two rows whose selection
/// changed and no others, and that is only checkable by counting.
@MainActor enum SidebarRowRenderCount {
    /// Chat and side rows drawn again since the last reset.
    static var builds: Int { SidebarChatRowView.builds }
    static func reset() { SidebarChatRowView.builds = 0 }
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
    /// Only the reader's Mark as Unread makes it unread: the dot says
    /// "Unread", not "Unread replies".
    var markedUnreadOnly = false
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
    /// The group's archived chats, listed after its active ones while the
    /// archive switch is on, under an "Archived" heading.
    var archived = false
    /// How many chats the group lists, across every page: the heading's count.
    var total = 0
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
    /// The topic's archived chats while the archive switch is on; nil when
    /// the switch is off or the topic has none to list.
    var archive: SidebarGroupContents?
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
        let state = chat.isArchived ? "Archived" : chat.imported ? "Imported" : chat.toolMode == ChatRecord.readOnlyTools ? "Read-only" : "Ready"
        guard namesConnection, !chat.imported, let connection = profiles.first(where: { $0.id == chat.profileID }) else { return state }
        return state + " \u{b7} " + connection.name
    }

    /// Everything one group of one project draws: its active chats, or, with
    /// `archived`, the archived ones listed after them while the archive
    /// switch is on. Reading the model happens here, once per pass; the group
    /// views take values.
    func sidebarGroupContents(in project: WorkspaceRecord, topicID: String?, archived: Bool, filter: String,
                              showEmpty: Bool, showAllMatches: Bool = false,
                              sidebarWidth: CGFloat, namesConnection: Bool) -> SidebarGroupContents {
        // The archived chats page on their own: they are a list of their own.
        let groupID = archived ? SidebarSessionPresentation.archiveGroupID(topicID ?? project.id) : topicID ?? project.id
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
                markedUnreadOnly: markedUnreadOnly(sessionID: chat.id),
                liveIdentity: displays[chat.id].map(ObjectIdentifier.init),
                hasSide: entry.hasChildren || side?.kept == false,
                expanded: !folded.contains(chat.id),
                draggable: projectDraggable && !chat.isUtilityChat,
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
        var empty: String?
        if showEmpty && visible.isEmpty {
            // A group whose chats are all archived has chats: they are listed
            // once the archive switch is on.
            empty = archived ? "No archived chats" : !filter.isEmpty ? "No matching chats"
                : sidebarEntries(in: project.id, topicID: topicID, archived: true, collapsed: []).isEmpty ? "No chats yet" : "No active chats"
        }
        return SidebarGroupContents(groupID: groupID, indent: indent, archived: archived, total: all.count, rows: rows,
                                    hiddenRoots: hiddenRoots, shownRoots: shown,
                                    paginates: !filtering && (hiddenRoots > 0 || shown > SidebarSessionPresentation.pageSize),
                                    emptyLabel: empty)
    }

    /// A group's archived chats while the archive switch is on, or nil when
    /// the switch is off or none of them is listed.
    func sidebarArchiveContents(in project: WorkspaceRecord, topicID: String?, includesArchive: Bool, filter: String,
                                showAllMatches: Bool = false, sidebarWidth: CGFloat, namesConnection: Bool) -> SidebarGroupContents? {
        guard includesArchive else { return nil }
        let contents = sidebarGroupContents(in: project, topicID: topicID, archived: true, filter: filter, showEmpty: false,
                                            showAllMatches: showAllMatches, sidebarWidth: sidebarWidth, namesConnection: namesConnection)
        return contents.rows.isEmpty ? nil : contents
    }

    /// A topic's group, header included, with its archived chats after its
    /// active ones while the archive switch is on (`includesArchive`). The
    /// header's drop highlight is the group view's own state and is filled
    /// in there.
    func topicGroupContents(in project: WorkspaceRecord, topic: TopicRecord, includesArchive: Bool, filter: String,
                            sidebarWidth: CGFloat, namesConnection: Bool) -> TopicGroupContents {
        let entries = sidebarEntries(in: project.id, topicID: topic.id, archived: false, collapsed: [])
        let expanded = topicIsExpanded(topic) || !filter.isEmpty
        // A topic whose own title matches lists all of its chats.
        let inner = topic.title.localizedCaseInsensitiveContains(filter) ? "" : filter
        let header = TopicHeaderState(projectID: project.id, topicID: topic.id, title: topic.title, trusted: project.trusted,
                                      expanded: expanded, filtering: !filter.isEmpty,
                                      hasUnread: entries.contains { unreadOutputCount(sessionID: $0.id) > 0 || unreadFailure(sessionID: $0.id) },
                                      chats: entries.count)
        guard expanded else { return TopicGroupContents(header: header, expanded: false, contents: SidebarGroupContents()) }
        let archive = sidebarArchiveContents(in: project, topicID: topic.id, includesArchive: includesArchive, filter: inner,
                                             showAllMatches: !filter.isEmpty, sidebarWidth: sidebarWidth, namesConnection: namesConnection)
        // The topic's archived chats stand where "No chats yet" would.
        let contents = sidebarGroupContents(in: project, topicID: topic.id, archived: false, filter: inner, showEmpty: archive == nil,
                                            showAllMatches: !filter.isEmpty, sidebarWidth: sidebarWidth, namesConnection: namesConnection)
        return TopicGroupContents(header: header, expanded: expanded, contents: contents, archive: archive)
    }
}
