import AppKit
import QuartzCore

// The sidebar's list: every project, its topics and the chats of each group,
// as one flat run of entries laid out by frames in a scroll view. Only the
// entries near what is on screen have views; each view is kept by its
// entry's identity and changes only what its entry changes.

/// One line of the sidebar list.
enum SidebarEntry: Equatable {
    case projectHeader(ProjectHeaderState)
    case projectUnavailable(projectID: String)
    case topicHeader(TopicHeaderState)
    case topicRemove(topicID: String, removing: Bool)
    case archiveHeading(groupID: String, count: Int, indent: CGFloat)
    case chat(chat: ChatRecord, state: SidebarChatRowState, projectID: String)
    /// Under a chat the filter listed for its messages: the match (`SidebarSearch.swift`).
    case searchSnippet(SidebarSearchSnippetState)
    case side(SidebarSideRowState)
    case pagination(groupID: String, projectID: String, hiddenRoots: Int, shownRoots: Int, indent: CGFloat)
    case empty(groupID: String, text: String, indent: CGFloat)
    /// A group that shows nothing: no room, but the stack's spacing around it.
    case nothing(groupID: String)

    var id: String {
        switch self {
        case .projectHeader(let state): return "project|" + state.projectID
        case .projectUnavailable(let id): return "unavailable|" + id
        case .topicHeader(let state): return "topic|" + state.topicID
        case .topicRemove(let id, _): return "remove|" + id
        case .archiveHeading(let group, _, _): return "archived|" + group
        case .chat(let chat, _, _): return "chat|" + chat.id
        case .searchSnippet(let state): return "snippet|" + state.chatID
        case .side(let state): return "side|" + state.id
        case .pagination(let group, _, _, _, _): return "pages|" + group
        case .empty(let group, _, _): return "empty|" + group
        case .nothing(let group): return "nothing|" + group
        }
    }
}

/// Where one project's or topic's chats can be dropped: its whole area.
struct SidebarDropZone: Equatable {
    var projectID: String
    var topicID: String?
    var scratch: Bool
    var range: ClosedRange<CGFloat>
}

/// The list's entries for the workspace as it is, worked out once per change.
struct SidebarListContents: Equatable {
    var entries: [SidebarEntry] = []
    /// The gap above each entry: 9 between projects, 3 within one.
    var gaps: [CGFloat] = []
    /// Which project each entry belongs to, and which topic group (if any).
    var owners: [(project: String, topic: String?)] = []
    static func == (lhs: SidebarListContents, rhs: SidebarListContents) -> Bool {
        lhs.entries == rhs.entries && lhs.gaps == rhs.gaps && lhs.owners.map(\.project) == rhs.owners.map(\.project)
            && lhs.owners.map(\.topic) == rhs.owners.map(\.topic)
    }

    static let projectSpacing: CGFloat = 9
    static let rowSpacing: CGFloat = 3

    /// Builds the list from `model`, as `ProjectSidebarGroup` built each project.
    @MainActor static func build(model: WorkspaceModel, filter: String, sidebarWidth: CGFloat, confirmingRemove: Set<String>, removing: Set<String>,
                      dropTarget: (project: String, topic: String?)?) -> SidebarListContents {
        var contents = SidebarListContents()
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = model.sidebarConnectionCount > 1
        let archive = model.sidebarShowsArchived
        let projects = model.sidebarProjects
        let siblings = projects.map(\.name)
        for (index, project) in projects.enumerated() {
            let record = project.record
            var gap = index == 0 ? 0 : projectSpacing
            func add(_ entry: SidebarEntry, topic: String? = nil) {
                // A snippet sits right under its row, as part of it.
                if case .searchSnippet = entry { gap = 0 }
                contents.entries.append(entry); contents.gaps.append(gap)
                contents.owners.append((record.id, topic)); gap = rowSpacing
            }
            let expanded = !query.isEmpty || model.projectIsExpanded(record.id)
            let help: String = {
                if record.isScratch { return "Chats outside any project, such as connection tests. Tools stay disabled here." }
                guard project.available else { return "Project configuration unavailable. Retained chats are read-only. Project ID: " + record.id }
                return record.roots.joined(separator: "\n") + "\nDrop chats anywhere in this project to move them out of a topic."
            }()
            add(.projectHeader(ProjectHeaderState(
                projectID: record.id, name: project.name, scratch: record.isScratch, trusted: record.trusted, available: project.available,
                expanded: expanded, filtering: !query.isEmpty, chosen: model.selectedWorkspaceID == record.id,
                hasUnread: model.projectHasUnread(record.id), compact: !ProjectSidebarGroup.showsHeaderButtons(at: sidebarWidth),
                truncatesInTheMiddle: SidebarProject.truncatesInTheMiddle(project.name, among: siblings),
                dropTargeted: dropTarget?.project == record.id && dropTarget?.topic == nil, help: help)))
            guard expanded else { continue }
            if !project.available { add(.projectUnavailable(projectID: record.id)) }
            let topics = visibleTopics(model: model, project: record, query: query, archive: archive)
            for topic in topics {
                let group = model.topicGroupContents(in: record, topic: topic, includesArchive: archive, filter: query,
                                                     sidebarWidth: sidebarWidth, namesConnection: names)
                var header = group.header
                header.dropTargeted = dropTarget?.project == record.id && dropTarget?.topic == topic.id
                add(.topicHeader(header), topic: topic.id)
                if confirmingRemove.contains(topic.id) { add(.topicRemove(topicID: topic.id, removing: removing.contains(topic.id)), topic: topic.id) }
                if group.expanded {
                    addGroup(group.contents, projectID: record.id, topic: topic.id, model: model, filtering: !query.isEmpty, add: add)
                    if let archived = group.archive { addGroup(archived, projectID: record.id, topic: topic.id, model: model, filtering: !query.isEmpty, add: add) }
                }
            }
            let archived = model.sidebarArchiveContents(in: record, topicID: nil, includesArchive: archive, filter: query,
                                                        sidebarWidth: sidebarWidth, namesConnection: names)
            addGroup(model.sidebarGroupContents(in: record, topicID: nil, archived: false, filter: query, showEmpty: topics.isEmpty && archived == nil,
                                                sidebarWidth: sidebarWidth, namesConnection: names), projectID: record.id, topic: nil,
                     model: model, filtering: !query.isEmpty, add: add)
            if let archived { addGroup(archived, projectID: record.id, topic: nil, model: model, filtering: !query.isEmpty, add: add) }
        }
        return contents
    }
    @MainActor private static func addGroup(_ group: SidebarGroupContents, projectID: String, topic: String?, model: WorkspaceModel, filtering: Bool,
                                            add: (SidebarEntry, String?) -> Void) {
        var any = false
        if group.archived { add(.archiveHeading(groupID: group.groupID, count: group.total, indent: group.indent), topic); any = true }
        for row in group.rows {
            add(.chat(chat: row.chat, state: row.state, projectID: projectID), topic); any = true
            if filtering, let hit = model.sidebarSearchHit(row.chat.id) {
                add(.searchSnippet(SidebarSearchSnippetState(chat: row.chat, hit: hit, indent: row.state.indent)), topic)
            }
            if let side = row.side { add(.side(side), topic) }
        }
        if group.paginates {
            add(.pagination(groupID: group.groupID, projectID: projectID, hiddenRoots: group.hiddenRoots, shownRoots: group.shownRoots, indent: group.indent), topic)
            any = true
        }
        if let empty = group.emptyLabel { add(.empty(groupID: group.groupID, text: empty, indent: group.indent), topic); any = true }
        if !any { add(.nothing(groupID: group.groupID), topic) }
    }
    /// The topics a filter leaves: a topic whose title matches, or one with a
    /// chat that does, archived chats included while they are listed.
    @MainActor private static func visibleTopics(model: WorkspaceModel, project: WorkspaceRecord, query: String, archive: Bool) -> [TopicRecord] {
        let topics = project.isScratch ? [] : model.topics(in: project.id)
        guard !query.isEmpty else { return topics }
        return topics.filter { topic in
            topic.title.localizedCaseInsensitiveContains(query) || (archive ? [false, true] : [false]).contains { archived in
                model.sidebarEntries(in: project.id, topicID: topic.id, archived: archived, collapsed: []).contains { model.sidebarMatches($0.chat, query: query) }
            }
        }
    }
}

/// Whether a project header has room for its own buttons, as the SwiftUI
/// group asked.
enum ProjectSidebarGroup {
    /// Below this the header keeps only its actions menu: the changes and
    /// new-chat buttons ate the project's name, and both are in the menu.
    static let compactHeaderWidth: CGFloat = 240
    static func showsHeaderButtons(at width: CGFloat) -> Bool { width >= compactHeaderWidth }
}
