import SwiftUI

// The sidebar column: the edge the reader drags to resize it, the list
// itself, and the bar that appears while rows are marked.

/// The hairline between sidebar and content doubles as a drag handle, and
/// wears the shared grip so it looks like one.
struct SidebarResizeHandle: View {
    let width: CGFloat
    @Binding var dragging: CGFloat?
    let commit: (CGFloat) -> Void
    @State private var startWidth: CGFloat?
    var body: some View {
        PiResizeHandle(orientation: .vertical, label: "Resize sidebar",
                       hint: "Drag left or right, or press Control-Command-Left and Control-Command-Right",
                       dragging: dragging != nil,
                       changed: { translation in
                           let base = startWidth ?? width
                           if startWidth == nil { startWidth = width }
                           dragging = WindowChrome.clampSidebarWidth(base + translation)
                       },
                       ended: { translation in
                           let landed = WindowChrome.clampSidebarWidth((startWidth ?? width) + translation)
                           startWidth = nil; dragging = nil; commit(landed)
                       })
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject var model: WorkspaceModel
    /// A project header drops its buttons when the reader has pulled the
    /// sidebar in far enough that they would eat the project's name.
    var width: CGFloat = WindowChrome.sidebarWidth
    @State private var filter = ""
    /// One highlight for the whole list: it slides to the chat that was chosen.
    @Namespace private var selectionGlide
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No app name or icon up here; the Dock and the empty-chat card carry the mark.
            HStack(spacing: 4) {
                Text("Projects").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.5)
                Spacer()
                PiIconButton(symbol: "square.and.pencil", label: model.selectedWorkspaceID == nil ? "Create or choose a project before starting a chat" : "New Chat (⌘N)", tone: .accent, size: 24, filled: true, action: model.newChat)
                    .disabled(!model.workspaces.contains { $0.id == model.selectedWorkspaceID && $0.trusted }).accessibilityIdentifier("newChat")
                PiIconButton(symbol: "folder.badge.plus", label: "Add or manage projects", size: 24) { model.showWorkspaceManager = true }
                    .accessibilityIdentifier("manageProjects")
            }.padding(.horizontal, PiSpacing.lg).padding(.top, 10).padding(.bottom, 4)
            PiTextField(placeholder: "Filter chats and topics", text: $filter, icon: "magnifyingglass")
                .onExitCommand { if model.hasMarkedSessions { model.clearSessionMarks() } else { filter = ""; model.focusComposer() } }
                .padding(.horizontal, PiSpacing.md).padding(.bottom, 6)
                .accessibilityLabel("Filter chats and topics by title").accessibilityIdentifier("sidebarFilter")
            if model.hasMarkedSessions {
                SidebarSelectionBar(model: model).padding(.horizontal, PiSpacing.md).padding(.bottom, 6)
                    .transition(PiMotion.reveal)
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(model.sidebarProjects) { project in
                        ProjectSidebarGroup(model: model, project: project.record, available: project.available, name: project.name,
                                            filter: filter, sidebarWidth: width)
                    }
                }.padding(.horizontal, PiSpacing.sm).padding(.bottom, PiSpacing.md)
            }
            // Marking a range and stepping with the keyboard follow what the
            // filter left listed, so the model is told what it says.
            .onAppear { model.sidebarFilter = filter }
            .onChange(of: filter) { _, value in model.sidebarFilter = value }
            // Marking rows takes a strip above the list; the list moves down
            // to make room rather than jumping.
            .piAnimation(PiMotion.base, value: model.hasMarkedSessions)
            .environment(\.piSelectionNamespace, selectionGlide)
            .overlay {
                if model.sidebarProjects.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 24)).foregroundStyle(Color.piInkTertiary)
                        Text("Add a project to start chatting.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center)
                        Button("Add Project") { model.showWorkspaceManager = true }.buttonStyle(.piSecondaryCompact)
                    }.padding(PiSpacing.lg)
                }
            }
            Rectangle().fill(Color.piHairline).frame(height: 1)
            HStack(spacing: 2) {
                PiIconButton(symbol: "chart.xyaxis.line", label: model.page == .report ? "Back to Chats" : "Usage Report (⇧⌘R)", tone: model.page == .report ? .accent : .neutral, filled: model.page == .report) { model.toggleReport() }
                    .accessibilityIdentifier("requestDashboard")
                PiIconButton(symbol: "ladybug", label: "Request Inspector · what this chat sent and received") { if let id = model.selectedID { model.inspect(id) } }.disabled(model.selectedID == nil)
                    .accessibilityIdentifier("requestInspector")
                PiIconButton(symbol: "book.closed", label: "Skills, instructions and MCP servers for this project") { model.inspectResources(model.selectedID) }.disabled(model.selectedWorkspaceID == nil)
                    .accessibilityIdentifier("projectResources")
                PiIconButton(symbol: model.showBackgroundSessions ? "eye" : "eye.slash", label: model.showBackgroundSessions ? "Hide background tasks in the list" : "Show background tasks in the list", tone: model.showBackgroundSessions ? .accent : .neutral) {
                    model.showBackgroundSessions.toggle()
                }.accessibilityIdentifier("backgroundSessionsToggle")
                Spacer()
                PiIconButton(symbol: "gearshape", label: "Settings · connections, keys and preferences") { model.showProfiles = true }
                    .accessibilityIdentifier("openSettings")
            }.padding(.horizontal, PiSpacing.sm).padding(.vertical, 6)
        }
        .background(Color.piWindow)
    }
}

/// Shift/Command marking is only useful when the reader can see what is marked
/// and act on it without the context menu.
struct SidebarSelectionBar: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        let marked = model.markedChats
        let allArchived = !marked.isEmpty && marked.allSatisfy(\.isArchived)
        // A sidebar dragged down to its minimum used to break "Archive" across
        // three lines and "Clear" across two. Written words first; symbols when
        // the words no longer fit beside the count.
        ViewThatFits(in: .horizontal) {
            bar(marked.count, allArchived: allArchived, compact: false)
            bar(marked.count, allArchived: allArchived, compact: true)
        }
        .padding(.horizontal, PiSpacing.sm).padding(.vertical, 4)
        .background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
        .help("Shift-click a row for a range, Command-click to add one. Drag any marked row to move them all.")
    }
    private func bar(_ count: Int, allArchived: Bool, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piAccent)
            Text(compact ? "\(count)" : "\(count) selected").font(PiFont.caption).foregroundStyle(Color.piInk)
                .lineLimit(1).fixedSize()
                .accessibilityLabel("\(count) chats selected")
                .accessibilityIdentifier("sidebarSelectionCount")
            Spacer(minLength: 2)
            PiIconButton(symbol: "doc.on.doc", label: "Copy selected session references, tokens and cost", size: 20) {
                Task { await model.copyMarkedSessionReferences() }
            }.accessibilityIdentifier("sidebarSelectionCopy")
            if compact {
                PiIconButton(symbol: allArchived ? "arrow.uturn.backward" : "archivebox",
                             label: allArchived ? "Restore selected chats" : "Archive selected chats", size: 20) {
                    model.archiveMarkedSessions(!allArchived)
                }.accessibilityIdentifier("sidebarSelectionArchive")
                PiIconButton(symbol: "xmark", label: "Clear selection", size: 20) { model.clearSessionMarks() }
                    .accessibilityIdentifier("sidebarSelectionClear")
            } else {
                Button(allArchived ? "Restore" : "Archive") { model.archiveMarkedSessions(!allArchived) }
                    .buttonStyle(.piGhost).lineLimit(1).fixedSize()
                    .accessibilityIdentifier("sidebarSelectionArchive")
                Button("Clear") { model.clearSessionMarks() }
                    .buttonStyle(.piGhost).lineLimit(1).fixedSize()
                    .accessibilityIdentifier("sidebarSelectionClear")
            }
        }
    }
}
