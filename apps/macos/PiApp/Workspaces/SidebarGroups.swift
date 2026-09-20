import SwiftUI

// What the sidebar is made of above the rows: a project, a topic inside it,
// the chats of one group, and the right-click menus those rows offer. Each
// group compares on a value so a change redraws the part that changed.

struct ProjectSidebarGroup: View {
    /// Below this the header keeps only its actions menu: the changes and
    /// new-chat buttons ate the project's name, and both are in the menu.
    static let compactHeaderWidth: CGFloat = 240
    @ObservedObject var model: WorkspaceModel
    let project: WorkspaceRecord
    let available: Bool
    let name: String
    var filter = ""
    var sidebarWidth: CGFloat = WindowChrome.sidebarWidth
    @Environment(\.piReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var expanded: Bool { !query.isEmpty || model.projectIsExpanded(project.id) }
    private var archived: Bool { model.projectShowsArchive(project.id) }
    private var projectTopics: [TopicRecord] { project.isScratch ? [] : model.topics(in: project.id) }
    private var visibleTopics: [TopicRecord] {
        guard !query.isEmpty else { return projectTopics }
        return projectTopics.filter { topic in
            topic.title.localizedCaseInsensitiveContains(query)
                || model.sidebarEntries(in: project.id, topicID: topic.id, archived: archived, collapsed: []).contains { $0.chat.title.localizedCaseInsensitiveContains(query) }
        }
    }
    private var archivedCount: Int { model.sidebarIndex.archivedCount(in: project.id, chats: model.chats) }
    private var hasUnread: Bool { model.projectHasUnread(project.id) }
    /// Whether the header still has room for its own changes and new-chat
    /// buttons beside the project's name.
    static func showsHeaderButtons(at width: CGFloat) -> Bool { width >= compactHeaderWidth }
    private var compactHeader: Bool { !Self.showsHeaderButtons(at: sidebarWidth) }
    /// A name reads from its start unless a sibling shares its opening.
    private var truncatesInTheMiddle: Bool {
        SidebarProject.truncatesInTheMiddle(name, among: model.sidebarProjects.map(\.name))
    }
    var body: some View {
        // Every group's contents are worked out here, once, so each group can
        // be compared rather than rebuilt. A collapsed project works out
        // nothing at all.
        let names = model.sidebarConnectionCount > 1
        let topics = expanded ? visibleTopics : []
        VStack(alignment: .leading, spacing: 3) {
            ProjectSidebarHeader(model: model, state: headerState).equatable()
            // Unfolding a project used to swap its rows in whole. They come
            // out from under the header now, and go back the same way; the
            // header's own button owns the animation (`PiMotion.glide`).
            if expanded {
                if !available { Text("Project unavailable · History only").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).padding(.leading, 23).padding(.vertical, 3) }
                if archived {
                    Button { withAnimation(reduceMotion ? nil : PiMotion.glide) { model.setProjectArchiveFilter(project.id, archived: false) } } label: { Label("Archive · Back to Chats", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.plain).piPointer().font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.leading, 23).padding(.vertical, 4)
                        .accessibilityIdentifier("sessionArchiveFilter")
                }
                ForEach(topics) { topic in
                    TopicSidebarGroup(model: model, projectID: project.id, topicID: topic.id,
                                      contents: model.topicGroupContents(in: project, topic: topic, archived: archived, filter: query,
                                                                         sidebarWidth: sidebarWidth, namesConnection: names))
                        .equatable()
                }
                SidebarSessionGroup(model: model, projectID: project.id,
                                    contents: model.sidebarGroupContents(in: project, topicID: nil, archived: archived, filter: query,
                                                                         showEmpty: topics.isEmpty, sidebarWidth: sidebarWidth,
                                                                         namesConnection: names))
                    .equatable()
                if !archived && archivedCount > 0 {
                    Button { withAnimation(reduceMotion ? nil : PiMotion.glide) { model.setProjectArchiveFilter(project.id, archived: true) } } label: { Label("Archive · \(archivedCount)", systemImage: "archivebox") }
                        .buttonStyle(.plain).piPointer().font(PiFont.caption).foregroundStyle(Color.piInkTertiary).padding(.leading, 23).padding(.vertical, 4)
                        .accessibilityLabel("Show \(archivedCount) archived chats in " + name)
                        .accessibilityIdentifier("sessionArchiveFilter")
                }
            }
        }
        .transition(PiMotion.reveal)
        // Opening a chat unfolds whatever hides it. One observation for the
        // whole project, not one per group.
        .onAppear { revealOpenChats() }
        .onChange(of: revealKey) { _, _ in revealOpenChats() }
        // Disclosure and the archive switch animate from where they are
        // triggered (`withAnimation`). A `.animation(value:)` here wrapped the
        // whole project — every group, every row — in a transaction that had
        // to be re-evaluated on every unrelated workspace change.
        // The project's whole area takes a drop, not only its header strip: a
        // chat dropped beside the rows it already sits with returns to the
        // project root. Topic groups sit inside this one and answer first, so
        // their own rows still move into that topic. The header keeps the
        // highlight, so the group about to receive the chats is still named.
        .contentShape(Rectangle())
        .onDrop(of: [TopicSessionDrag.type], isTargeted: $dropTargeted) { providers in
            guard !project.isScratch else { return false }
            return TopicSessionDrag.acceptSidebarDrop(providers, model: model, projectID: project.id, topicID: nil)
        }
    }
    private var headerState: ProjectHeaderState {
        ProjectHeaderState(projectID: project.id, name: name, scratch: project.isScratch, trusted: project.trusted,
                           available: available, expanded: expanded, archived: archived, filtering: !query.isEmpty,
                           chosen: model.selectedWorkspaceID == project.id, hasUnread: hasUnread,
                           compact: compactHeader, truncatesInTheMiddle: truncatesInTheMiddle,
                           dropTargeted: dropTargeted, help: help)
    }
    private var help: String {
        if project.isScratch { return "Chats outside any project, such as connection tests. Tools stay disabled here." }
        guard available else { return "Project configuration unavailable. Retained chats are read-only. Project ID: " + project.id }
        return project.roots.joined(separator: "\n") + "\nDrop chats anywhere in this project to move them out of a topic."
    }
    /// What a reveal depends on: which chat is open, and which group it is in.
    private struct RevealKey: Equatable {
        var selected: String?
        var focused: String?
        var selectedTopic: String?
        var focusedTopic: String?
    }
    private var revealKey: RevealKey {
        RevealKey(selected: model.selectedID, focused: model.focusedSessionID,
                  selectedTopic: model.record(model.selectedID ?? "")?.topicID,
                  focusedTopic: model.record(model.focusedSessionID ?? "")?.topicID)
    }
    private func revealOpenChats() {
        revealAncestors(of: model.selectedID)
        revealAncestors(of: model.focusedSessionID)
    }
    private func revealAncestors(of id: String?) {
        guard let id, let selected = model.record(id), selected.workspaceID == project.id else { return }
        var parent = selected.parentSessionID, seen: Set<String> = [], reveal: Set<String> = []
        while let id = parent, seen.insert(id).inserted, let item = model.record(id), item.workspaceID == project.id {
            reveal.insert(id); parent = item.parentSessionID
        }
        model.revealSidebarSides(reveal, in: project.id)
    }
}

/// A topic and its chats. Compared on `TopicGroupContents`, which the project
/// works out once per pass; the drop highlight and the remove question are
/// this view's own state and invalidate it on their own.
private struct TopicSidebarGroup: View, Equatable {
    nonisolated static func == (lhs: TopicSidebarGroup, rhs: TopicSidebarGroup) -> Bool {
        lhs.contents == rhs.contents && lhs.projectID == rhs.projectID
    }
    let model: WorkspaceModel
    let projectID: String
    let topicID: String
    let contents: TopicGroupContents
    @State private var dropTargeted = false
    @State private var confirmingRemove = false
    @State private var removing = false
    var body: some View {
        var header = contents.header
        header.dropTargeted = dropTargeted
        return VStack(alignment: .leading, spacing: 3) {
            TopicSidebarHeader(model: model, state: header) { confirmingRemove = true }.equatable()
            if confirmingRemove {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remove this topic? Its chats stay in the project.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    HStack(spacing: 8) {
                        Button(removing ? "Removing…" : "Remove Topic", role: .destructive) { remove() }.buttonStyle(.piSecondaryCompact).disabled(removing)
                        Button("Cancel") { confirmingRemove = false }.buttonStyle(.piGhost).disabled(removing)
                    }
                }.padding(.leading, 35).padding(.trailing, 7).padding(.vertical, 5)
            }
            if contents.expanded {
                SidebarSessionGroup(model: model, projectID: projectID, contents: contents.contents).equatable()
                    .transition(PiMotion.reveal)
            }
        }
        // Header strip and chat rows are one drop zone: aiming at the topic's
        // rows is the obvious way to say “into this topic”, and the header keeps
        // the highlight so the receiving group is still obvious.
        .contentShape(Rectangle())
        .onDrop(of: [TopicSessionDrag.type], isTargeted: $dropTargeted) { providers in
            TopicSessionDrag.acceptSidebarDrop(providers, model: model, projectID: projectID, topicID: topicID)
        }
    }
    private func remove() {
        guard !removing else { return }
        removing = true
        let model = model, topicID = topicID
        Task {
            defer { removing = false }
            do { try await model.removeTopic(topicID) }
            catch { model.error = error.localizedDescription }
        }
    }
}

/// Pure sidebar presentation shared by topic and project-root groups. A title
/// match keeps its ancestors visible, so filtering cannot strand a side chat.
enum SidebarSessionPresentation {
    static let pageSize = 5
    static func filtered(_ entries: [SidebarChatEntry], by query: String) -> [SidebarChatEntry] {
        guard !query.isEmpty else { return entries }
        var kept: Set<Int> = [], ancestors: [Int] = []
        for (index, entry) in entries.enumerated() {
            while let last = ancestors.last, entries[last].depth >= entry.depth { ancestors.removeLast() }
            if entry.chat.title.localizedCaseInsensitiveContains(query) { kept.formUnion(ancestors); kept.insert(index) }
            ancestors.append(index)
        }
        return entries.enumerated().compactMap { kept.contains($0.offset) ? $0.element : nil }
    }
    static func page(_ entries: [SidebarChatEntry], roots requested: Int, selected: Set<String>, filtering: Bool) -> [SidebarChatEntry] {
        guard !filtering else { return entries }
        var limit = max(1, requested), rootCounts = 0
        for entry in entries {
            if entry.depth == 0 { rootCounts += 1 }
            if selected.contains(entry.id) { limit = max(limit, rootCounts) }
        }
        var result: [SidebarChatEntry] = [], roots = 0
        for entry in entries {
            if entry.depth == 0 { roots += 1; if roots > limit { break } }
            result.append(entry)
        }
        return result
    }
}

/// The chats of one sidebar group. Compared on `SidebarGroupContents`: with
/// 540 chats a selection change used to rebuild every group of every project,
/// menus and drag surfaces included, because each group observed the whole
/// workspace.
private struct SidebarSessionGroup: View, Equatable {
    nonisolated static func == (lhs: SidebarSessionGroup, rhs: SidebarSessionGroup) -> Bool {
        lhs.contents == rhs.contents && lhs.projectID == rhs.projectID
    }
    let model: WorkspaceModel
    let projectID: String
    let contents: SidebarGroupContents
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(contents.rows) { row in
                SidebarChatRow(model: model, chat: row.chat, projectID: projectID, state: row.state).equatable()
                    .transition(PiMotion.reveal)
                if let side = row.side {
                    SidebarSideRow(model: model, state: side).equatable().transition(PiMotion.reveal)
                }
            }
            if contents.paginates { pagination }
            if let empty = contents.emptyLabel {
                Text(empty).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                    .padding(.leading, contents.indent + 20).padding(.vertical, 6)
            }
        }
        // A chat that moves up the list because something happened in it
        // slides past its neighbours instead of swapping places with one.
        // Keyed on the order alone: nothing else about a row moves it.
        .piAnimation(PiMotion.glide, value: contents.rows.map(\.id))
    }
    private var pagination: some View {
        HStack(spacing: PiSpacing.md) {
            if contents.hiddenRoots > 0 {
                Button {
                    withAnimation(PiMotion.honouring(PiMotion.glide, reduceMotion: reduceMotion)) {
                        model.setSidebarShownRoots(contents.groupID, to: contents.shownRoots + SidebarSessionPresentation.pageSize * 2, in: projectID)
                    }
                } label: {
                    Label("Show \(min(contents.hiddenRoots, SidebarSessionPresentation.pageSize * 2)) more \u{b7} \(contents.hiddenRoots) hidden", systemImage: "chevron.down")
                }
                .buttonStyle(.plain).piPointer().foregroundStyle(Color.piAccent).accessibilityIdentifier("sessionShowMore-" + contents.groupID)
            }
            if contents.shownRoots > SidebarSessionPresentation.pageSize {
                Button {
                    withAnimation(PiMotion.honouring(PiMotion.glide, reduceMotion: reduceMotion)) {
                        model.setSidebarShownRoots(contents.groupID, to: SidebarSessionPresentation.pageSize, in: projectID)
                    }
                } label: { Label("Show less", systemImage: "chevron.up") }
                    .buttonStyle(.plain).piPointer().foregroundStyle(Color.piInkSecondary).accessibilityIdentifier("sessionShowLess-" + contents.groupID)
            }
        }.font(PiFont.caption).padding(.leading, contents.indent + 9).padding(.vertical, 4)
    }
}

/// What a right-click offers while several rows are marked. Every item runs the
/// same path as its single-chat counterpart. Copying preserves the marks.
struct MarkedSessionActions: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        let marked = model.markedChats
        let archived = marked.filter(\.isArchived).count
        let unread = marked.filter { model.unreadOutputCount(sessionID: $0.id) > 0 }.count
        Text("\(marked.count) chats selected")
        Divider()
        Button("Copy Session References", systemImage: "doc.on.doc") { Task { await model.copyMarkedSessionReferences() } }
            .help("Copy selected session IDs, conversation file paths, token usage and reported cost")
            .accessibilityIdentifier("copyMarkedSessionReferences")
        Divider()
        if archived < marked.count {
            Button("Archive \(marked.count - archived) Chats", systemImage: "archivebox") { model.archiveMarkedSessions(true) }
                .accessibilityIdentifier("archiveMarkedSessions")
        }
        if archived > 0 {
            Button("Restore \(archived) Chats", systemImage: "arrow.uturn.backward") { model.archiveMarkedSessions(false) }
                .accessibilityIdentifier("restoreMarkedSessions")
        }
        Button("Pin All", systemImage: "pin") { model.pinMarkedSessions(true) }
        Button("Unpin All", systemImage: "pin.slash") { model.pinMarkedSessions(false) }
        if let projectID = model.markedProjectID, projectID != WorkspaceRecord.scratchID {
            Menu {
                Text("Includes saved side chats")
                Button("Project root", systemImage: "tray") { model.moveMarkedSessions(toTopic: nil) }
                ForEach(model.topics(in: projectID)) { topic in
                    Button(topic.title, systemImage: "folder") { model.moveMarkedSessions(toTopic: topic.id) }
                }
            } label: { Label("Move \(marked.count) to Topic", systemImage: "folder") }
            .accessibilityIdentifier("moveMarkedSessionsToTopic")
        }
        if unread > 0 { Divider(); Button("Mark \(unread) as Read") { model.markMarkedSessionsRead() } }
        Divider()
        Button("Clear Selection", systemImage: "xmark.circle") { model.clearSessionMarks() }
    }
}

struct SessionOrganizationActions: View {
    @ObservedObject var model: WorkspaceModel
    let chat: ChatRecord
    var body: some View {
        if !chat.isBackgroundTask { Button("Rename…") { model.renameSession(chat.id) } }
        Button(chat.isPinned ? "Unpin Chat" : "Pin Chat", systemImage: chat.isPinned ? "pin.slash" : "pin") { model.toggleSessionPin(chat.id) }
        Button(chat.isArchived ? "Restore Chat" : "Archive Chat", systemImage: chat.isArchived ? "arrow.uturn.backward" : "archivebox") { model.toggleSessionArchive(chat.id) }
        if chat.workspaceID != WorkspaceRecord.scratchID, !chat.isBackgroundTask, chat.connectionTest != true {
            Menu {
                Text("Includes saved side chats")
                Button("Project root", systemImage: model.effectiveTopicID(for: chat) == nil ? "checkmark" : "tray") { move(to: nil) }
                ForEach(model.topics(in: chat.workspaceID)) { topic in
                    Button(topic.title, systemImage: model.effectiveTopicID(for: chat) == topic.id ? "checkmark" : "folder") { move(to: topic.id) }
                }
            } label: { Label("Move to Topic", systemImage: "folder") }
            .help("Move this chat and its saved side chats within this project")
            .accessibilityIdentifier("moveSessionToTopic-" + chat.id)
        }
        if chat.isArchived {
            Divider()
            Button("Delete Chat…", systemImage: "trash", role: .destructive) { model.deleteChat(chat.id) }
        }
    }
    private func move(to topicID: String?) {
        Task {
            do { try await model.moveSessions([chat.id], in: chat.workspaceID, toTopic: topicID) }
            catch { model.error = error.localizedDescription }
        }
    }
}

/// Shared by sidebar right-click menus and the main/side conversation menu.
struct SessionReferenceActions: View {
    let model: WorkspaceModel
    let sessionID: String
    var body: some View {
        Button("Copy Session ID", systemImage: "number") { model.copySessionID(sessionID) }
            .accessibilityIdentifier("copySessionID-" + sessionID)
        Button("Copy Session Reference", systemImage: "doc.on.doc") { Task { await model.copySessionReference(sessionID) } }
            .help("Copy the session ID, conversation file path, token usage and reported cost")
            .accessibilityIdentifier("copySessionReference-" + sessionID)
    }
}
