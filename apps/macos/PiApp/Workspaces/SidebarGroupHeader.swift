import SwiftUI

/// A project's header strip, as values. The strip is two buttons, a menu and a
/// right-click menu; rebuilding twelve of them — three projects and nine
/// topics — is what a sidebar pass spent most of its remaining time on once
/// the rows stopped rebuilding. It is compared instead.
struct ProjectHeaderState: Equatable {
    var projectID = ""
    var name = ""
    var scratch = false
    var trusted = false
    /// A project whose configuration is gone still lists its retained chats.
    var available = true
    var expanded = true
    var archived = false
    /// The filter locks disclosure open, so the header's toggles are disabled.
    var filtering = false
    var chosen = false
    var hasUnread = false
    /// Below `ProjectSidebarGroup.compactHeaderWidth` the strip keeps only its
    /// actions menu; both buttons are in that menu.
    var compact = false
    /// A sibling shares this name's opening, so the tail is what tells them apart.
    var truncatesInTheMiddle = false
    var dropTargeted = false
    var help = ""
}

struct ProjectSidebarHeader: View, Equatable {
    nonisolated static func == (lhs: ProjectSidebarHeader, rhs: ProjectSidebarHeader) -> Bool { lhs.state == rhs.state }
    let model: WorkspaceModel
    let state: ProjectHeaderState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : PiMotion.glide) { model.setProjectExpanded(state.projectID, expanded: !state.expanded) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(state.expanded ? 90 : 0)).frame(width: 10)
                    Image(systemName: state.scratch ? "tray" : "folder").font(.system(size: 12, weight: .medium))
                    Text(state.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .truncationMode(state.truncatesInTheMiddle ? .middle : .tail)
                    if !state.expanded && state.hasUnread { UnreadDot() }
                    Spacer(minLength: 0)
                }.foregroundStyle(state.chosen ? Color.piInk : Color.piInkSecondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).piPointer().disabled(state.filtering)
            .help(state.help)
            .accessibilityLabel((state.expanded ? "Collapse project " : "Expand project ") + state.name)
            .accessibilityIdentifier("projectDisclosure-" + state.projectID)
            if !state.scratch {
                if !state.compact {
                    PiIconButton(symbol: "arrow.triangle.branch", label: "Changes and history of " + state.name, size: 22) { model.showChanges(in: state.projectID) }
                        .disabled(!state.available).accessibilityIdentifier("projectChanges-" + state.projectID)
                    PiIconButton(symbol: "plus", label: "New chat in " + state.name, size: 22) { model.newChat(in: state.projectID, topicID: nil) }
                        .disabled(!state.available || !state.trusted).accessibilityIdentifier("newProjectChat-" + state.projectID)
                }
                Menu { ProjectSidebarActions(model: model, state: state) } label: { Image(systemName: "ellipsis").frame(width: 18, height: 22).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer()
                    .accessibilityLabel("Project actions for " + state.name).accessibilityIdentifier("projectActions-" + state.projectID)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(state.dropTargeted ? Color.piAccentSoft : .clear, in: RoundedRectangle(cornerRadius: PiRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.sm).stroke(state.dropTargeted ? Color.piAccent : .clear, lineWidth: 1))
        .contextMenu { ProjectSidebarActions(model: model, state: state) }
    }
}

/// What the header's menu and the project's right-click menu both offer.
struct ProjectSidebarActions: View {
    let model: WorkspaceModel
    let state: ProjectHeaderState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var body: some View {
        if !state.scratch {
            Button("New Chat", systemImage: "square.and.pencil") { model.newChat(in: state.projectID, topicID: nil) }.disabled(!state.available || !state.trusted)
            Button("New Topic…", systemImage: "folder.badge.plus") { model.presentNewTopic(in: state.projectID) }
                .accessibilityIdentifier("newTopic-" + state.projectID)
            // The header drops its own button for this in a narrow sidebar.
            Button("Changes and History…", systemImage: "arrow.triangle.branch") { model.showChanges(in: state.projectID) }
                .disabled(!state.available).accessibilityIdentifier("projectChangesAction-" + state.projectID)
        }
        Button(state.expanded ? "Collapse Project" : "Expand Project") {
            withAnimation(reduceMotion ? nil : PiMotion.glide) { model.setProjectExpanded(state.projectID, expanded: !state.expanded) }
        }.disabled(state.filtering)
        Button(state.archived ? "Show Active Chats" : "Show Archived Chats", systemImage: "archivebox") {
            withAnimation(reduceMotion ? nil : PiMotion.glide) { model.setProjectArchiveFilter(state.projectID, archived: !state.archived) }
        }
        if !state.scratch {
            Divider()
            Button(state.available ? "Manage Project…" : "Configure Projects…", systemImage: "folder.badge.gearshape") {
                if state.available { model.selectedWorkspaceID = state.projectID }
                model.showWorkspaceManager = true
            }
        }
    }
}

/// A topic's header strip, on the same terms as the project's.
struct TopicHeaderState: Equatable {
    var projectID = ""
    var topicID = ""
    var title = ""
    var trusted = false
    var expanded = true
    var filtering = false
    var hasUnread = false
    var chats = 0
    var dropTargeted = false
}

struct TopicSidebarHeader: View, Equatable {
    nonisolated static func == (lhs: TopicSidebarHeader, rhs: TopicSidebarHeader) -> Bool { lhs.state == rhs.state }
    let model: WorkspaceModel
    let state: TopicHeaderState
    /// Opens the group's own "Remove this topic?" question, which lives with
    /// the rows it is about rather than in a sheet over the window.
    let confirmRemove: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : PiMotion.glide) { model.setTopicExpanded(state.topicID, expanded: !state.expanded) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(state.expanded ? 90 : 0)).frame(width: 10)
                    Image(systemName: state.expanded ? "folder" : "folder.fill").font(.system(size: 11, weight: .medium))
                    Text(state.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !state.expanded && state.hasUnread { UnreadDot() }
                    Spacer(minLength: 0)
                    Text("\(state.chats)").font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary)
                }.foregroundStyle(Color.piInkSecondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).piPointer().disabled(state.filtering)
            .accessibilityLabel((state.expanded ? "Collapse topic " : "Expand topic ") + state.title + ", " + WorkspaceLabel.chats(state.chats))
            .accessibilityIdentifier("topicDisclosure-" + state.topicID)
            PiIconButton(symbol: "plus", label: "New chat in topic " + state.title, size: 22) { model.newChat(in: state.projectID, topicID: state.topicID) }
                .disabled(!state.trusted).accessibilityIdentifier("newTopicChat-" + state.topicID)
            Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 18, height: 22).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer()
                .accessibilityLabel("Topic actions for " + state.title).accessibilityIdentifier("topicActions-" + state.topicID)
        }
        .padding(.leading, 21).padding(.trailing, 7).padding(.vertical, 2)
        .background(state.dropTargeted ? Color.piAccentSoft : .clear, in: RoundedRectangle(cornerRadius: PiRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.sm).stroke(state.dropTargeted ? Color.piAccent : .clear, lineWidth: 1))
        .contextMenu { actions }
        .help("Drop chats here to group them in “" + state.title + "”. Saved side chats move with their parent.")
    }
    @ViewBuilder private var actions: some View {
        Button("New Chat", systemImage: "square.and.pencil") { model.newChat(in: state.projectID, topicID: state.topicID) }.disabled(!state.trusted)
        Button("New Topic…", systemImage: "folder.badge.plus") { model.presentNewTopic(in: state.projectID) }
        Divider()
        Button("Rename Topic…", systemImage: "pencil") { model.presentRenameTopic(state.topicID) }
        Button("Remove Topic…", systemImage: "folder.badge.minus", role: .destructive, action: confirmRemove)
            .help("Keep all chats and move them back to the project")
    }
}
