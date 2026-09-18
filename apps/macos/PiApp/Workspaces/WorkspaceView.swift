import SwiftUI
import WebKit

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sidebar keeps the width the user last dragged it to.
    @AppStorage("sidebarWidth") private var storedSidebarWidth: Double = Double(WindowChrome.sidebarWidth)
    @State private var draggingSidebarWidth: CGFloat?
    private var sidebarWidth: CGFloat { draggingSidebarWidth ?? WindowChrome.clampSidebarWidth(CGFloat(storedSidebarWidth)) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                WindowChrome(sidebarWidth: sidebarWidth, focusedSessionID: model.focusedSessionID ?? model.selectedID).frame(height: WindowChrome.height)
                WorkspaceSidebar(model: model)
            }.frame(width: sidebarWidth)
            SidebarResizeHandle(width: sidebarWidth, dragging: $draggingSidebarWidth) { storedSidebarWidth = Double($0) }
            GeometryReader { region in
              ZStack {
                Group {
                    if let session = model.selected, let chat = model.chat {
                        // A shown side takes exactly half of the width.
                        let shownSide = model.sides[chat.id].flatMap { side in model.displays[side.id].map { (side, $0) } }
                        HStack(spacing: 0) {
                            ConversationPane(model: model, session: session, chat: chat)
                                .frame(width: shownSide == nil ? region.size.width : (region.size.width / 2).rounded(.down))
                            if let shown = shownSide {
                                SidePane(model: model, session: shown.1, info: shown.0).id(shown.0.id)
                                    .frame(width: region.size.width - (region.size.width / 2).rounded(.down))
                                    .transition(reduceMotion ? .identity : AnyTransition.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86), value: model.sides[chat.id]?.id)
                    } else if OnboardingState.shouldPresent(configurationLoaded: model.configurationLoaded, hasProfiles: !model.requestProfiles.isEmpty, hasChats: !model.chats.isEmpty) {
                        OnboardingView(model: model)
                    } else {
                        WorkspaceWelcome(model: model)
                    }
                }
                // A hidden split pane must not contribute its combined column
                // minima to the report's available width on a small window.
                .frame(width: region.size.width, height: region.size.height)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.selectedID == nil)
                // The chat pane stays mounted (transcript, scroll, drafts and any
                // running generation survive) while the report covers it.
                .opacity(model.page == .chats ? 1 : 0)
                .allowsHitTesting(model.page == .chats)
                .disabled(model.page != .chats)
                .accessibilityHidden(model.page != .chats)
                if model.page == .report {
                    ReportPage(model: model)
                        .transition(reduceMotion ? .identity : AnyTransition.opacity.combined(with: .move(edge: .trailing)))
                        .zIndex(1)
                }
              }
              .frame(width: region.size.width, height: region.size.height)
              .clipped()
            }
            .background(Color.piContent)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.page)
        }
        .ignoresSafeArea(.container, edges: .top)
        .buttonStyle(.piSecondary)
        .toggleStyle(.switch)
        .background(Color.piWindow)
        .focusedSceneValue(\.workspaceCommandModel, model)
        .sheet(isPresented: $model.showProfiles) { ProfileSettings(model: model).frame(width: 760, height: 780) }
        .sheet(isPresented: $model.showInspector) { if let id = model.inspectorSessionID ?? model.selectedID { InspectorView(model: model, sessionID: id, messageID: model.inspectorMessageID) } }
        .sheet(isPresented: $model.showMessageViewer) { RetainedMessageViewer(model: model) }
        .sheet(isPresented: $model.showMessageDetail) { if let id = model.messageDetailSessionID, let messageID = model.messageDetailID { MessageDetailView(model: model, sessionID: id, messageID: messageID) } }
        .sheet(isPresented: $model.showConversationContent) { if let id = model.contentSessionID { ConversationContentView(model: model, sessionID: id) } }
        .sheet(isPresented: $model.showResources) { ResourceInspector(model: model) }
        .sheet(isPresented: $model.showWorkspaceManager) { WorkspaceManagerView(model: model) }
        .sheet(item: $model.renameTarget) { target in RenameChatSheet(model: model, chatID: target.id) }
        .sheet(isPresented: $model.showGit) {
            if let project = model.workspaces.first(where: { $0.id == (model.gitWorkspaceID ?? model.selectedWorkspaceID) }) { GitPanelView(model: model, roots: project.roots) }
        }
        // Errors used to be a modal alert: a background save failure interrupted
        // typing with the same weight as a failed send, and the text vanished on
        // OK. The strip stays until dismissed and never steals focus.
        .overlay(alignment: .top) {
            if let error = model.error {
                ErrorBanner(text: error) { model.error = nil }
                    .padding(.top, 44).padding(.horizontal, PiSpacing.xl)
                    .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.error)
        .frame(minWidth: 920, minHeight: 600)
        .background(WindowActivityGuard(model: model))
        .background(ConversationPageVisibility(reportVisible: model.page == .report, focusIdentity: model.focusedSessionID, closeReport: model.closeReport))
        .disabled(model.installPreparing)
        .overlay {
            if model.installPreparing {
                HStack(spacing: PiSpacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Saving drafts and preparing to close…").font(PiFont.body)
                }.padding(20).piElevated()
            }
        }
    }
}

/// Opacity and SwiftUI hit testing do not resign an NSTextView's first
/// responder. Hide the existing native surfaces without dismantling them, and
/// move keyboard focus onto the report's responder chain. Only page/window
/// transitions walk the native view tree; streaming does not trigger scans.
struct ConversationPageVisibility: NSViewRepresentable {
    let reportVisible: Bool
    let focusIdentity: String?
    let closeReport: () -> Void
    func makeNSView(context: Context) -> ConversationPageVisibilityView { ConversationPageVisibilityView() }
    func updateNSView(_ view: ConversationPageVisibilityView, context: Context) {
        view.closeReport = closeReport
        view.update(reportVisible: reportVisible, focusIdentity: focusIdentity)
    }
    static func dismantleNSView(_ view: ConversationPageVisibilityView, coordinator: ()) { view.restoreNativeViews(restoreFocus: false) }
}

@MainActor final class ConversationPageVisibilityView: NSView {
    private struct HiddenView { weak var view: NSView?; let wasHidden: Bool }
    private var hiddenViews: [HiddenView] = []
    private weak var previousResponder: NSResponder?
    private weak var appliedWindow: NSWindow?
    private var previousFocusIdentity: String?
    private var focusIdentity: String?
    private var reportVisible = false
    private var appliedReportVisible: Bool?
    private var revision = 0
    var closeReport: (() -> Void)?
    override var acceptsFirstResponder: Bool { reportVisible }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyVisibility() }
    func update(reportVisible: Bool, focusIdentity: String?) {
        self.reportVisible = reportVisible; self.focusIdentity = focusIdentity
        applyVisibility()
    }
    private func applyVisibility() {
        guard appliedReportVisible != reportVisible || appliedWindow !== window else { return }
        revision += 1
        if appliedWindow !== window { restoreNativeViews(restoreFocus: false) }
        appliedWindow = window; appliedReportVisible = reportVisible
        guard let window else { return }
        if reportVisible {
            previousFocusIdentity = focusIdentity
            hideNativeViews(in: window, takeFocus: true)
            let expected = revision
            // The initial SwiftUI mount may attach this background before its
            // native siblings. One deferred pass captures those same instances.
            Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard let self, let window, self.revision == expected, self.reportVisible else { return }
                self.hideNativeViews(in: window, takeFocus: false)
            }
        } else { restoreNativeViews(restoreFocus: true) }
    }
    private func hideNativeViews(in window: NSWindow, takeFocus: Bool) {
        guard let content = window.contentView else { return }
        func nativeViews(_ view: NSView) -> [NSView] {
            if view is ComposerTextView || view is WKWebView { return [view] }
            return view.subviews.flatMap { nativeViews($0) }
        }
        let views = nativeViews(content)
        let responderView = window.firstResponder as? NSView
        let hasConversationFocus = responderView.map { responder in views.contains { responder === $0 || responder.isDescendant(of: $0) } } ?? false
        if hasConversationFocus {
            previousResponder = window.firstResponder
            window.makeFirstResponder(self)
        } else if takeFocus, window.attachedSheet == nil { window.makeFirstResponder(self) }
        for view in views where !hiddenViews.contains(where: { $0.view === view }) {
            hiddenViews.append(HiddenView(view: view, wasHidden: view.isHidden))
            view.isHidden = true
        }
    }
    func restoreNativeViews(restoreFocus: Bool) {
        for hidden in hiddenViews { hidden.view?.isHidden = hidden.wasHidden }
        let restoredTranscript = hiddenViews.contains { $0.view is WKWebView && !$0.wasHidden }
        hiddenViews.removeAll()
        if restoreFocus, previousFocusIdentity == focusIdentity, let responder = previousResponder as? NSView,
           responder.window === window, !responder.isHiddenOrHasHiddenAncestor, window?.attachedSheet == nil {
            window?.makeFirstResponder(responder)
        } else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        previousResponder = nil; previousFocusIdentity = nil
        if restoredTranscript { NotificationCenter.default.post(name: TranscriptReadVisibility.didRestoreNativeView, object: window) }
    }
    override func cancelOperation(_ sender: Any?) {
        if reportVisible { closeReport?() } else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if reportVisible, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}

/// Non-modal error strip at the top of the window.
private struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: PiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piDanger).padding(.top, 2)
            Text(text).font(PiFont.body).foregroundStyle(Color.piInk).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PiSpacing.sm)
            Button("Dismiss", action: dismiss).buttonStyle(.piGhost)
        }
        .padding(.leading, PiSpacing.md).padding(.trailing, 4).padding(.vertical, PiSpacing.sm)
        .frame(maxWidth: 640)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piDanger.opacity(0.35), lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: " + text)
        .accessibilityIdentifier("errorBanner")
    }
}

/// The hairline between sidebar and content doubles as a drag handle.
private struct SidebarResizeHandle: View {
    let width: CGFloat
    @Binding var dragging: CGFloat?
    let commit: (CGFloat) -> Void
    @State private var startWidth: CGFloat?
    var body: some View {
        Rectangle().fill(Color.piHairline).frame(width: 1)
            .overlay {
                Rectangle().fill(Color.clear).frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = startWidth ?? width
                            if startWidth == nil { startWidth = width }
                            dragging = WindowChrome.clampSidebarWidth(base + value.translation.width)
                        }
                        .onEnded { value in
                            let final = WindowChrome.clampSidebarWidth((startWidth ?? width) + value.translation.width)
                            startWidth = nil; dragging = nil; commit(final)
                        })
                    .accessibilityLabel("Resize sidebar")
                    .accessibilityHint("Drag left or right")
            }
            .zIndex(1)
    }
}

private struct WorkspaceSidebar: View {
    @ObservedObject var model: WorkspaceModel
    @State private var filter = ""
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
            PiTextField(placeholder: "Filter chats", text: $filter, icon: "magnifyingglass")
                .onExitCommand { filter = ""; model.focusComposer() }
                .padding(.horizontal, PiSpacing.md).padding(.bottom, 6)
                .accessibilityLabel("Filter chats by title").accessibilityIdentifier("sidebarFilter")
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(model.sidebarProjects) { project in
                        ProjectSidebarGroup(model: model, project: project.record, available: project.available, name: project.name, filter: filter)
                    }
                }.padding(.horizontal, PiSpacing.sm).padding(.bottom, PiSpacing.md)
            }
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
                PiIconButton(symbol: "ladybug", label: "Request Inspector") { if let id = model.selectedID { model.inspect(id) } }.disabled(model.selectedID == nil)
                PiIconButton(symbol: "book.closed", label: "Skills, instructions and MCP") { model.inspectResources(model.selectedID) }.disabled(model.selectedWorkspaceID == nil)
                PiIconButton(symbol: model.showBackgroundSessions ? "eye" : "eye.slash", label: model.showBackgroundSessions ? "Hide background sessions" : "Show background sessions", tone: model.showBackgroundSessions ? .accent : .neutral) {
                    model.showBackgroundSessions.toggle()
                }.accessibilityIdentifier("backgroundSessionsToggle")
                Spacer()
                PiIconButton(symbol: "gearshape", label: "LiteLLM connections and preferences") { model.showProfiles = true }
            }.padding(.horizontal, PiSpacing.sm).padding(.vertical, 6)
        }
        .background(Color.piWindow)
    }
}

private struct ProjectSidebarGroup: View {
    @ObservedObject var model: WorkspaceModel
    let project: WorkspaceRecord
    let available: Bool
    let name: String
    var filter = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedSides: Set<String> = []
    /// Top-level chats shown before "Show more"; a filter shows every match.
    @State private var shownRoots = ProjectSidebarGroup.pageSize
    static let pageSize = 5
    private var expanded: Bool { model.projectIsExpanded(project.id) }
    private var archived: Bool { model.projectShowsArchive(project.id) }
    private var allChats: [SidebarChatEntry] {
        let entries = model.sidebarEntries(in: project.id, archived: archived, collapsed: filter.isEmpty ? collapsedSides : [])
        return filter.isEmpty ? entries : entries.filter { $0.chat.title.localizedCaseInsensitiveContains(filter) }
    }
    /// The first `shownRoots` top-level chats with their children; the selected
    /// or focused chat is always within the shown page.
    private var visibleChats: [SidebarChatEntry] {
        guard filter.isEmpty else { return allChats }
        let entries = allChats
        var limit = shownRoots
        if let current = model.focusedSessionID ?? model.selectedID, let position = entries.firstIndex(where: { $0.id == current }) {
            let root = entries[...position].filter { $0.depth == 0 }.count
            limit = max(limit, root)
        }
        var shown: [SidebarChatEntry] = [], roots = 0
        for entry in entries {
            if entry.depth == 0 { roots += 1; if roots > limit { break } }
            shown.append(entry)
        }
        return shown
    }
    private var hiddenRoots: Int { filter.isEmpty ? max(0, allChats.filter { $0.depth == 0 }.count - visibleChats.filter { $0.depth == 0 }.count) : 0 }
    private var archivedCount: Int { model.chats.filter { $0.workspaceID == project.id && $0.isArchived }.count }
    private var hasUnread: Bool { model.chats.contains { $0.workspaceID == project.id && model.unreadOutputCount(sessionID: $0.id) > 0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.setProjectExpanded(project.id, expanded: !expanded) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 10)
                        Image(systemName: project.isScratch ? "tray" : "folder").font(.system(size: 12, weight: .medium))
                        Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        if !expanded && hasUnread { UnreadDot() }
                        Spacer(minLength: 0)
                    }.foregroundStyle(model.selectedWorkspaceID == project.id ? Color.piInk : Color.piInkSecondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).piPointer().help(project.isScratch ? "Chats outside any project, such as connection tests. Tools stay disabled here." : available ? project.roots.joined(separator: "\n") : "Project configuration unavailable. Retained chats are read-only. Project ID: " + project.id)
                .accessibilityLabel((expanded ? "Collapse project " : "Expand project ") + name)
                .accessibilityIdentifier("projectDisclosure-" + project.id)
                if !project.isScratch {
                    PiIconButton(symbol: "arrow.triangle.branch", label: "Changes and history of " + name, size: 22) { model.showChanges(in: project.id) }
                        .disabled(!available).accessibilityIdentifier("projectChanges-" + project.id)
                    PiIconButton(symbol: "plus", label: "New chat in " + name, size: 22) { model.newChat(in: project.id) }
                        .disabled(!project.trusted).accessibilityIdentifier("newProjectChat-" + project.id)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .contextMenu {
                if !project.isScratch { Button("New Chat", systemImage: "square.and.pencil") { model.newChat(in: project.id) }.disabled(!project.trusted) }
                Button(expanded ? "Collapse Project" : "Expand Project") { model.setProjectExpanded(project.id, expanded: !expanded) }
                Button(archived ? "Show Active Chats" : "Show Archived Chats", systemImage: "archivebox") { model.setProjectArchiveFilter(project.id, archived: !archived) }
                if !project.isScratch {
                    Divider()
                    Button(available ? "Manage Project…" : "Configure Projects…", systemImage: "folder.badge.gearshape") { if available { model.selectedWorkspaceID = project.id }; model.showWorkspaceManager = true }
                }
            }
            if expanded {
                if !available { Text("Project unavailable · History only").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).padding(.leading, 23).padding(.vertical, 3) }
                if archived {
                    Button { model.setProjectArchiveFilter(project.id, archived: false) } label: { Label("Archive · Back to Chats", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.plain).piPointer().font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.leading, 23).padding(.vertical, 4)
                        .accessibilityIdentifier("sessionArchiveFilter")
                }
                ForEach(visibleChats) { entry in
                    chatRows(entry).transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
                if hiddenRoots > 0 {
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { shownRoots += ProjectSidebarGroup.pageSize * 2 } } label: {
                        Label("Show \(min(hiddenRoots, ProjectSidebarGroup.pageSize * 2)) more · \(hiddenRoots) hidden", systemImage: "chevron.down")
                    }
                    .buttonStyle(.plain).piPointer().font(PiFont.caption).foregroundStyle(Color.piAccent).padding(.leading, 23).padding(.vertical, 4)
                    .accessibilityIdentifier("sessionShowMore-" + project.id)
                }
                if visibleChats.isEmpty {
                    Text(archived ? "No archived chats" : filter.isEmpty ? "No chats yet" : "No matching chats").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).padding(.leading, 48).padding(.vertical, 6)
                }
                if !archived && archivedCount > 0 {
                    Button { model.setProjectArchiveFilter(project.id, archived: true) } label: { Label("Archive · \(archivedCount)", systemImage: "archivebox") }
                        .buttonStyle(.plain).piPointer().font(PiFont.caption).foregroundStyle(Color.piInkTertiary).padding(.leading, 23).padding(.vertical, 4)
                        .accessibilityLabel("Show \(archivedCount) archived chats in " + name)
                        .accessibilityIdentifier("sessionArchiveFilter")
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: archived)
        // Chats that appear (a first message, a restore) or leave (archive, delete) fade and slide rather than jump.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visibleChats.map(\.id))
        .onChange(of: model.focusedSessionID) { _, id in revealAncestors(of: id) }
        .onChange(of: model.selectedID) { _, id in revealAncestors(of: id) }
        .onChange(of: archived) { _, _ in shownRoots = ProjectSidebarGroup.pageSize }
    }
    private func revealAncestors(of id: String?) {
        guard let id, let selected = model.record(id), selected.workspaceID == project.id else { return }
        var parent = selected.parentSessionID, seen: Set<String> = []
        while let id = parent, seen.insert(id).inserted, let item = model.record(id), item.workspaceID == project.id {
            collapsedSides.remove(id); parent = item.parentSessionID
        }
    }
    @ViewBuilder private func chatRows(_ entry: SidebarChatEntry) -> some View {
        let chat = entry.chat
        let side = model.sides[chat.id]
        let selected = model.focusedSessionID == chat.id || model.selectedID == chat.id && model.focusedSessionID == nil
        PiSelectableRow(selected: selected, action: {
            Task {
                if model.side(chat.id) != nil { await model.selectSide(chat.id) }
                else if chat.parentSessionID != nil, model.record(chat.parentSessionID ?? "") != nil, !chat.imported { await model.showSide(chat.id) }
                else { await model.select(chat.id) }
            }
        }, doubleClick: { if !chat.isBackgroundTask { model.presentRename(chat.id) } }) {
            ChatRow(model: model, chat: chat, selected: selected,
                    hasSide: entry.hasChildren || side?.kept == false, expanded: !collapsedSides.contains(chat.id)) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    if collapsedSides.contains(chat.id) { collapsedSides.remove(chat.id) } else { collapsedSides.insert(chat.id) }
                }
            }
        }
        .contextMenu {
            if chat.parentSessionID != nil { Button("Open on Its Own", systemImage: "rectangle.expand.vertical") { Task { await model.select(chat.id) } }; Divider() }
            SessionOrganizationActions(model: model, chat: chat)
            if model.unreadOutputCount(sessionID: chat.id) > 0 { Divider(); Button("Mark as Read") { model.markSessionRead(chat.id) } }
        }
        .padding(.leading, CGFloat(14 + min(entry.depth, 3) * 14))
        if let side, !side.kept, !collapsedSides.contains(chat.id) {
            PiSelectableRow(selected: model.focusedSessionID == side.id, action: { Task { await model.selectSide(side.id) } }) { SideRow(model: model, info: side, selected: model.focusedSessionID == side.id) }
                .contextMenu {
                    if side.kept, let record = model.record(side.id) { SessionOrganizationActions(model: model, chat: record) }
                    if model.unreadOutputCount(sessionID: side.id) > 0 { Button("Mark as Read") { model.markSessionRead(side.id) } }
                }
                .padding(.leading, CGFloat(28 + min(entry.depth, 3) * 14))
        }
    }
}

private struct SessionOrganizationActions: View {
    @ObservedObject var model: WorkspaceModel
    let chat: ChatRecord
    var body: some View {
        if !chat.isBackgroundTask { Button("Rename…") { model.renameSession(chat.id) } }
        Button(chat.isPinned ? "Unpin Chat" : "Pin Chat", systemImage: chat.isPinned ? "pin.slash" : "pin") { model.toggleSessionPin(chat.id) }
        Button(chat.isArchived ? "Restore Chat" : "Archive Chat", systemImage: chat.isArchived ? "arrow.uturn.backward" : "archivebox") { model.toggleSessionArchive(chat.id) }
        if chat.isArchived {
            Divider()
            Button("Delete Chat…", systemImage: "trash", role: .destructive) { model.deleteChat(chat.id) }
        }
    }
}

/// A small accent dot marks a chat with replies the user has not viewed. The
/// sidebar records only whether a chat is unread, never how many replies.
struct UnreadDot: View {
    var body: some View {
        Circle().fill(Color.piBrandOrange).frame(width: 7, height: 7)
            .accessibilityLabel("Unread replies").help("New replies you have not viewed")
    }
}

/// Compact live stats for a sidebar row: state, cost and the session's input,
/// cached-input and output tokens. The composer footer owns the separate
/// context-size estimate.
struct ChatRowStats: Equatable {
    var state = "idle"
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
    var estimatedTokensPerSecond: Double?
    /// Seconds since 1970 of the latest request or message, for the "3m ago" stamp.
    var lastActivity: Double?
    init(totals: GatewayTotals?) {
        lastActivity = totals?.lastActivity
        costUSD = totals?.costUSD; cacheHits = totals?.cacheHits ?? 0; cacheMisses = totals?.cacheMisses ?? 0; requests = totals?.requests ?? 0
        tokens = totals?.tokens?.total; tokenSamples = totals?.tokens?.samples ?? 0
        inputTokens = totals?.tokens?.input; outputTokens = totals?.tokens?.output; cachedTokens = totals?.cacheReadTokens
        inputSamples = totals?.tokens?.inputSamples ?? 0; outputSamples = totals?.tokens?.outputSamples ?? 0; cachedSamples = totals?.cacheReadSamples ?? 0
    }
    var hasActivity: Bool { requests > 0 || busy || loading || tokens != nil }
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
    /// "3m ago", "2h ago", "yesterday", or a short date; nil without any activity.
    var recencyLabel: String? {
        guard let lastActivity, lastActivity.isFinite, lastActivity > 0 else { return nil }
        return ChatRowStats.relative(Date(timeIntervalSince1970: lastActivity))
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
    mutating func updateActivity(state: String, loading: Bool, activity: [String: WireValue], observedAt: Double, now: Double) {
        self.state = state; self.loading = loading
        busy = ["queued", "running", "stopping", "compacting"].contains(state)
        let phase = activity["phase"]?.string ?? ""
        generating = busy && !loading && state != "stopping" && activity["version"]?.number == 1
            && activity["modelActive"]?.bool == true && ["model", "compacting"].contains(phase)
        if busy && phase == "tool" { self.state = "tool" }
        let age = now - observedAt
        estimatedTokensPerSecond = activity["estimatedOutputTokensPerSecond"]?.number.flatMap { value in
            guard generating, age >= 0, age <= 2, value.isFinite, value >= 0 else { return nil }
            return value
        }
    }
    var rateLabel: String? {
        guard generating else { return nil }
        return estimatedTokensPerSecond.map { String(format: "~%.1f tok/s", $0) } ?? "— tok/s"
    }
}

private struct ChatRow: View {
    @ObservedObject var model: WorkspaceModel
    let chat: ChatRecord
    let selected: Bool
    var hasSide = false
    var expanded = true
    var toggle: () -> Void = {}
    private var symbol: String { chat.imported ? "doc.text" : chat.parentSessionID != nil ? "arrow.triangle.branch" : chat.connectionTest == true ? "checkmark.seal" : chat.toolMode == "read-only" ? "eye" : "bubble.left" }
    private var archiveAction: (() -> Void)? { chat.isBackgroundTask || chat.connectionTest == true ? nil : { model.toggleSessionArchive(chat.id) } }
    private var subtitle: String {
        let state = chat.isArchived ? "Archived" : chat.imported ? "Imported" : chat.toolMode == "read-only" ? "Read-only" : "Ready"
        guard model.requestProfiles.count > 1, !chat.imported, let connection = model.profiles.first(where: { $0.id == chat.profileID }) else { return state }
        return state + " · " + connection.name
    }
    var body: some View {
        if let display = model.displays[chat.id] {
            LiveChatRow(session: display, footer: display.footer, title: chat.title, subtitle: subtitle, symbol: symbol, selected: selected, unreadCount: model.unreadOutputCount(sessionID: chat.id), hasSide: hasSide, expanded: expanded, toggle: toggle, pinned: chat.isPinned, archived: chat.isArchived, archive: archiveAction)
        } else {
            ChatRowBody(stats: ChatRowStats(totals: model.chatStats[chat.id]), title: chat.title, subtitle: subtitle, symbol: symbol, selected: selected, unreadCount: model.unreadOutputCount(sessionID: chat.id), hasSide: hasSide, expanded: expanded, toggle: toggle, pinned: chat.isPinned, archived: chat.isArchived, archive: archiveAction)
        }
    }
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
    let hasSide: Bool
    let expanded: Bool
    let toggle: () -> Void
    var pinned = false
    var archived = false
    var archive: (() -> Void)? = nil
    private var stats: ChatRowStats {
        var value = ChatRowStats(totals: footer.gateway)
        value.updateActivity(state: session.state, loading: session.loading, activity: session.activity, observedAt: session.activityObservedAt, now: ProcessInfo.processInfo.systemUptime)
        // A message that just landed is more recent than the last retained request.
        if let at = session.messages.last(where: { $0.at != nil })?.at { value.lastActivity = max(value.lastActivity ?? 0, at / 1_000) }
        return value
    }
    var body: some View {
        if session.busy {
            TimelineView(.periodic(from: .now, by: 1)) { _ in row }
        } else { row }
    }
    private var row: some View {
        ChatRowBody(stats: stats, title: title, subtitle: subtitle, symbol: symbol, selected: selected, unreadCount: unreadCount, hasSide: hasSide, expanded: expanded, toggle: toggle, pinned: pinned, archived: archived, archive: archive)
    }
}

private struct ChatRowBody: View {
    let stats: ChatRowStats
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    var unreadCount = 0
    var hasSide = false
    var expanded = true
    var toggle: () -> Void = {}
    var pinned = false
    var indent = false
    /// Archive control: one click asks, a second confirms; restore is immediate.
    var archived = false
    var archive: (() -> Void)? = nil
    @State private var confirmingArchive = false
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                if stats.busy || stats.loading { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Color.piAccent : Color.piInkSecondary) }
            }.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: selected || unreadCount > 0 ? .semibold : .regular)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.piInkTertiary).accessibilityLabel("Pinned chat") }
                    Spacer(minLength: 4)
                    if unreadCount > 0 { UnreadDot().transition(.scale.combined(with: .opacity)) }
                    if let archive {
                        if confirmingArchive {
                            Button("Archive") { confirmingArchive = false; archive() }.buttonStyle(.piPrimaryCompact)
                                .accessibilityIdentifier("confirmArchive")
                            PiIconButton(symbol: "xmark", label: "Keep chat", size: 18) { confirmingArchive = false }
                        } else {
                            PiIconButton(symbol: archived ? "arrow.uturn.backward" : "archivebox", label: archived ? "Restore chat" : "Archive chat", size: 18) {
                                if archived { archive() } else { confirmingArchive = true }
                            }
                            .opacity(hovering ? 1 : 0)
                            .accessibilityIdentifier(archived ? "restoreChat" : "archiveChat")
                        }
                    }
                    if hasSide {
                        PiIconButton(symbol: "chevron.down", label: expanded ? "Hide child chats" : "Show child chats", size: 18, action: toggle)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                if stats.hasActivity { statsLine } else {
                    Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .help(subtitle + (stats.requests > 0 ? " · \(stats.requests) requests · cache \(stats.cacheHits) hit / \(stats.cacheMisses) miss" : ""))
        .onHover { inside in hovering = inside; if !inside { confirmingArchive = false } }
        .animation(.easeInOut(duration: 0.2), value: stats)
        .animation(.easeInOut(duration: 0.2), value: unreadCount)
        .animation(.easeInOut(duration: 0.15), value: confirmingArchive)
    }
    /// Cost, tokens and recency while they fit; a narrow sidebar drops tokens, then recency, rather than cutting words in half.
    private var statsLine: some View {
        ViewThatFits(in: .horizontal) {
            statsRow(tokens: true, recency: true)
            statsRow(tokens: false, recency: true)
            statsRow(tokens: false, recency: false)
        }
    }
    private func statsRow(tokens showTokens: Bool, recency showRecency: Bool) -> some View {
        HStack(spacing: 6) {
            if (stats.busy || stats.loading) && !stats.generating {
                Text(stats.loading ? "preparing" : stats.state).foregroundStyle(Color.piWarning).fontWeight(.medium)
            } else if ["error", "interrupted", "paused"].contains(stats.state) {
                Text(stats.state).foregroundStyle(stats.state == "paused" ? Color.piInfo : Color.piDanger).fontWeight(.medium)
            }
            if let cost = stats.costLabel { Text(cost) }
            if let rate = stats.rateLabel { Text(rate).foregroundStyle(Color.piAccent).help(MenuBarActivitySnapshot.rateExplanation).accessibilityLabel("Estimated current output: " + rate) }
            // Cost and one token figure; the input, cached and output split is a hover away.
            if showTokens, !stats.busy, let tokens = stats.tokensLabel { Text("· " + tokens).help(stats.usageHelp).accessibilityLabel(stats.usageHelp) }
            if showRecency, let recency = stats.recencyLabel { Text("· " + recency).help("Last activity").accessibilityLabel("Last activity " + recency) }
        }
        .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
    /// Narrow rows fall back to arrows: up for input, bolt for cached input, down for output.
    private var usageCompact: some View {
        HStack(spacing: 5) {
            usageFigure("arrow.up", compactTokens(stats.inputTokens))
            usageFigure("bolt.fill", compactTokens(stats.cachedTokens))
            usageFigure("arrow.down", compactTokens(stats.outputTokens))
        }
    }
    private func usageFigure(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 1) { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)); Text(value) }
    }
}

private struct SideRow: View {
    @ObservedObject var model: WorkspaceModel
    let info: SideRecord
    let selected: Bool
    private var title: String { info.kept ? (model.record(info.id)?.title ?? info.title) : "Side conversation" }
    var body: some View {
        if let display = model.displays[info.id] {
            LiveChatRow(session: display, footer: display.footer, title: title, subtitle: info.kept ? "Saved · Read-only" : "In memory · Read-only", symbol: "arrow.triangle.branch", selected: selected, unreadCount: model.unreadOutputCount(sessionID: info.id), hasSide: false, expanded: true, toggle: {})
        } else {
            ChatRowBody(stats: ChatRowStats(totals: nil), title: title, subtitle: info.kept ? "Saved · Read-only" : "In memory · Read-only", symbol: "arrow.triangle.branch", selected: selected, unreadCount: model.unreadOutputCount(sessionID: info.id))
        }
    }
}

private struct WorkspaceWelcome: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        VStack(spacing: PiSpacing.lg) {
            Image("BelloAgentIcon")
                .resizable().interpolation(.high).frame(width: 84, height: 84)
                .accessibilityLabel("Bello Agent")
            VStack(spacing: 8) {
                Text("What are we working on?").font(PiFont.display(30)).foregroundStyle(Color.piInk)
                Text("Create a project from one or more trusted folders and connect a LiteLLM route to start a chat.\nSide conversations, exact HTTP inspection and cost accounting are built in.")
                    .font(PiFont.body).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 460)
            }
            HStack(spacing: PiSpacing.md) {
                Button { model.showWorkspaceManager = true } label: { Label(model.workspaces.isEmpty ? "Create a project" : "Projects…", systemImage: "folder") }.buttonStyle(.piPrimary)
                Button { model.showProfiles = true } label: { Label("Configure Provider…", systemImage: "slider.horizontal.3") }.buttonStyle(.piSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.piContent)
    }
}

struct SideActions {
    var bringBack: () -> Void
    var keep: () -> Void
    var close: () -> Void
}

struct ConversationPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let chat: ChatRecord
    var side: SideRecord? = nil
    var sideActions: SideActions? = nil
    @State private var bridgeStatus = ""
    private var profile: ProfileRecord? { model.profiles.first { $0.id == chat.profileID } }
    private var projectAvailable: Bool { model.workspace(for: chat.workspaceID) != nil }
    /// A chat with nothing in it yet shows what it is connected to and where to start.
    private var showsStarter: Bool {
        session.messages.isEmpty && !session.busy && !session.loading && session.failureMessage == nil && session.sendFailure == nil
            && !chat.imported && !chat.isBackgroundTask && projectAvailable && (side == nil || side?.pending == true)
    }
    var body: some View {
        VStack(spacing: 0) {
            // No header: the sidebar names the chat, the composer bar holds its
            // actions, and the live turn bar at the bottom shows what is going on.
            if side != nil { sideHeader; Rectangle().fill(Color.piHairline).frame(height: 1) }
            if session.uncertain && !session.busy && !session.recovered.isEmpty { recoveredBanner }
            TranscriptView(messages: session.presentedMessages, bridgeStatus: $bridgeStatus, scrollAnchor: Binding(get: { session.scrollAnchor }, set: { session.scrollAnchor = $0; model.anchorChanged(session) }), sessionID: session.id, displayObservedAt: session.displayObservedAt, liveSession: session, onInspectRequests: { sessionID, messageID in model.showMessageDetail(sessionID, messageID: messageID) },
                           onEditMessage: { sessionID, messageID in model.editMessage(messageID, sessionID: sessionID) },
                           onReadReply: { sessionID, messageID in model.acknowledgeVisibleReply(sessionID: sessionID, messageID: messageID) },
                           onLoadEarlier: { sessionID in model.loadEarlier(sessionID: sessionID) },
                           onStop: { sessionID in model.stop(sessionID: sessionID) })
                .background(Color.piContent)
                .overlay(alignment: .top) { if showsStarter { StarterPanel(model: model, chat: chat, session: session).padding(.top, PiSpacing.xl).transition(.opacity) } }
                .overlay { if session.loading && session.messages.isEmpty { LoadingMark().transition(.opacity) } }
                .animation(.easeInOut(duration: 0.2), value: showsStarter)
                .animation(.easeInOut(duration: 0.2), value: session.loading)
            if !session.queue.isEmpty { queuePanel }
            if model.terminalVisible, side == nil, let workspace = model.workspace(for: chat.workspaceID), !workspace.isScratch {
                TerminalPanel(model: model, workspace: workspace).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !projectAvailable {
                HStack(spacing: PiSpacing.sm) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(Color.piInkSecondary)
                    Text("Project unavailable · Retained history is read-only").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Spacer()
                    Button("Configure Projects…") { model.showWorkspaceManager = true }.buttonStyle(.piSecondaryCompact)
                }.padding(PiSpacing.md)
            } else if chat.isBackgroundTask {
                HStack(spacing: PiSpacing.sm) {
                    Image(systemName: "sparkle").foregroundStyle(Color.piAccent)
                    Text("Background task · Tools disabled").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Spacer()
                    if session.busy {
                        Button { model.stop(sessionID: session.id) } label: { Label("Stop task", systemImage: "stop.fill") }.buttonStyle(.piDanger)
                    }
                    if let source = chat.sourceSessionID, model.record(source) != nil {
                        Button("Open source chat") { Task { await model.select(source) } }.buttonStyle(.piSecondaryCompact)
                    }
                }.padding(PiSpacing.md)
            } else if chat.imported { importedFooter } else { ComposerInput(model: model, session: session) }
            MetricsFooter(model: model, session: session, contextWindow: chat.contextWindow ?? profile?.contextWindow, outputReserve: chat.maxOutputTokens ?? profile?.maxOutputTokens) { model.inspect(session.id) }
        }
        .animation(.easeInOut(duration: 0.22), value: session.queue.count)
        .animation(.easeInOut(duration: 0.22), value: session.recovered.count)
        .animation(.easeInOut(duration: 0.24), value: model.terminalVisible)
        .background(Color.piContent)
        // HSplitView gives each pane its own native hosting surface. Remove
        // that surface's titlebar inset too, not only the outer window inset.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Plain words for what the side shares; the identifiers stay in the tooltip.
    private var boundary: String {
        guard let side else { return "" }
        if side.pending { return "Draft side · takes the parent's context when you send your first message" }
        guard let cutoff = side.boundary["cutoffEntryId"]?.string else { return "Shares the parent's context as of when it opened" }
        let parent = model.displays[side.parentID]?.messages.first { $0.id == cutoff }
        let preview = parent.map { String($0.text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let upTo = preview.map { "up to “\($0.count > 60 ? String($0.prefix(59)) + "…" : $0)”" } ?? "as of when it opened"
        return "Shares the parent's context \(upTo)" + (side.boundary["instructionsRefreshed"]?.bool == true ? " · instructions refreshed" : "")
    }
    private var boundaryDetail: String {
        guard let side else { return "" }
        return "Snapshot through \(side.boundary["cutoffEntryId"]?.string ?? "empty context") · \(Int(side.boundary["omittedIncompleteEntries"]?.number ?? 0)) incomplete entries omitted"
            + (side.boundary["instructionsRefreshed"]?.bool == true ? " · instructions refreshed" : " · initial instruction snapshot")
    }
    /// The side pane keeps a slim header: its name, whether it is saved, what it shares, and its own controls.
    private var sideHeader: some View {
        HStack(alignment: .center, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                if let side {
                    HStack(spacing: 6) {
                        if side.kept { titleButton.font(PiFont.title(15)) }
                        else { Text("Side conversation").font(PiFont.title(15)).foregroundStyle(Color.piInk).fixedSize() }
                        if side.pending { PiBadge(text: "Created when you send", icon: "square.and.pencil").fixedSize() }
                        else { PiBadge(text: side.kept ? "Saved · Read-only" : "In memory", tone: side.kept ? .success : .warning, icon: "arrow.triangle.branch").fixedSize() }
                    }
                    Text(boundary).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail).help(boundaryDetail)
                }
            }
            Spacer(minLength: PiSpacing.sm)
            if let side, let sideActions {
                PiIconButton(symbol: "arrow.uturn.backward", label: "Bring Back to Parent Draft…") { sideActions.bringBack() }
                if !side.pending && !side.kept {
                    Button { sideActions.keep() } label: { Label(side.keeping ? "Keeping…" : side.keepRequested ? "Keep Requested" : "Keep", systemImage: "pin") }
                        .buttonStyle(.piSecondaryCompact).disabled(side.keeping || side.keepRequested || session.loading)
                }
                ConversationActionsMenu(model: model, session: session, chat: chat)
                PiIconButton(symbol: "xmark", label: "Close side", size: 26) { sideActions.close() }.disabled(side.keeping || session.loading)
            }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 10).padding(.bottom, 8)
        .background(Color.piContent)
    }
    @ViewBuilder private var titleButton: some View {
        if chat.isBackgroundTask {
            Text(chat.title).foregroundStyle(Color.piInk).lineLimit(1)
        } else {
          Button { model.renameSession(chat.id) } label: {
            Text(chat.title).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail)
          }
        .buttonStyle(.plain).piPointer().help("Rename chat")
        .accessibilityLabel("Rename chat: " + chat.title).accessibilityIdentifier("renameSessionTitle")
        }
    }


    private var recoveredBanner: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.piWarning)
                Text("Interrupted submissions").font(PiFont.heading)
                Text("· Nothing was resent").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            ForEach(session.recovered, id: \.id) { intent in
                HStack {
                    Text(intent.text).lineLimit(1).font(PiFont.body)
                    Spacer()
                    Button("Insert in Draft") { model.recoverDraft(intent, insert: true) }.buttonStyle(.piSecondaryCompact)
                    Button("Dismiss") { model.recoverDraft(intent, insert: false) }.buttonStyle(.piGhost)
                }
            }
        }
        .padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.piWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piWarning.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.sm)
    }

    private var queuePanel: some View {
        QueuePanel(model: model, session: session)
            .padding(.horizontal, PiSpacing.lg).padding(.bottom, PiSpacing.sm)
    }

    private var importedFooter: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(Color.piInkSecondary)
                Text("Imported original · Read-only").font(PiFont.heading)
            }
            Text("Continue creates a separate managed copy; the imported file stays untouched.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            HStack(spacing: PiSpacing.sm) {
                PiDropdown(selection: $model.profileChoice, items: [("", "Choose Responses connection")] + model.requestProfiles.map { ($0.id, $0.name) }, placeholder: "Choose Responses connection", icon: "antenna.radiowaves.left.and.right")
                Button("Continue as Separate Chat") { model.continueCopy() }.buttonStyle(.piPrimary)
                PiMenuButton(title: "Recovery / Handoff") { Button("Portable Context Draft…", action: model.portableHandoff); Button("Recover Incomplete Tail…") { model.continueCopy(recoverTail: true) } }
                Spacer()
            }
        }
        .padding(PiSpacing.lg).piElevated()
        .padding(.horizontal, PiSpacing.lg).padding(.vertical, PiSpacing.sm)
    }
}

/// Pending messages: drag follow-ups to reorder, rewrite one in place, promote
/// one to steering so it reaches the current run after its tool batch, or remove it.
struct QueuedMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let steering: Bool
    init?(_ item: [String: WireValue]) {
        guard let id = item["turnId"]?.string else { return nil }
        steering = item["kind"]?.string == "steering"
        let raw = item["text"]?.string ?? ""
        text = steering && raw.hasPrefix("[Steering] ") ? String(raw.dropFirst("[Steering] ".count)) : raw
        self.id = id
    }
    static func from(_ queue: [[String: WireValue]]) -> [QueuedMessage] { queue.compactMap(QueuedMessage.init) }
}

private struct QueuePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @State private var editingID: String?
    @State private var editText = ""
    private var items: [QueuedMessage] { QueuedMessage.from(session.queue) }
    private var followUps: [QueuedMessage] { items.filter { !$0.steering } }
    private var steering: [QueuedMessage] { items.filter(\.steering) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Queued · \(items.count)", systemImage: "tray.full").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                if followUps.count > 1 { Text("Drag to reorder").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                Spacer()
                if session.canResumeQueue {
                    Button { model.action("queue.resume", sessionID: session.id) } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.piSecondaryCompact)
                }
            }
            if !steering.isEmpty {
                ForEach(steering) { item in row(item, index: nil) }
            }
            List {
                ForEach(Array(followUps.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index + 1)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    var order = followUps.map(\.id)
                    order.move(fromOffsets: source, toOffset: destination)
                    model.action("queue.reorder", params: ["turnIds": .array(order.map(WireValue.string))], sessionID: session.id)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
            .frame(height: CGFloat(followUps.count) * 30)
            .accessibilityIdentifier("queue-follow-ups")
        }
        .padding(PiSpacing.md)
        .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .onChange(of: session.queue.count) { _, _ in if let editingID, !items.contains(where: { $0.id == editingID }) { self.editingID = nil } }
    }
    @ViewBuilder private func row(_ item: QueuedMessage, index: Int?) -> some View {
        HStack(spacing: PiSpacing.sm) {
            if item.steering {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.piAccent).frame(width: 14)
                    .help("Steering: delivered after the current tool batch")
            } else {
                Text(index.map(String.init) ?? "").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 14)
            }
            if editingID == item.id {
                TextField("Message", text: $editText, axis: .vertical).textFieldStyle(.plain).font(PiFont.body).lineLimit(1...4)
                    .onSubmit { commitEdit(item) }
                    .accessibilityIdentifier("queue-edit-field")
                Button("Save") { commitEdit(item) }.buttonStyle(.piPrimaryCompact).disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editingID = nil }.buttonStyle(.piGhost)
            } else {
                Text(item.text).lineLimit(1).font(PiFont.body).foregroundStyle(Color.piInk)
                Spacer()
                if !item.steering && session.busy {
                    PiIconButton(symbol: "arrow.turn.up.right", label: "Steer the current run with this message", size: 22) {
                        model.action("queue.steer", params: ["turnId": .string(item.id)], sessionID: session.id)
                    }.help("Deliver after the current tool batch instead of after the run")
                }
                PiIconButton(symbol: "pencil", label: "Edit queued message", size: 22) { editingID = item.id; editText = item.text }
                PiIconButton(symbol: "xmark", label: "Remove", size: 22) {
                    model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: session.id)
                }
            }
        }
        .frame(minHeight: 26)
        .accessibilityIdentifier("queue-item-" + item.id)
    }
    private func commitEdit(_ item: QueuedMessage) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text != item.text { model.action("queue.update", params: ["turnId": .string(item.id), "text": .string(text)], sessionID: session.id) }
        editingID = nil
    }
}

/// The chat's actions, reachable from the composer bar (and the side header): the
/// conversation itself has no header bar.
struct ConversationActionsMenu: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let chat: ChatRecord
    var body: some View {
        Menu {
            if !chat.isBackgroundTask { Button("Rename Chat…") { model.renameSession(chat.id) } }
            if !model.isEphemeral(session.id) {
                SessionOrganizationActions(model: model, chat: chat)
                Divider()
            }
            if model.side(session.id) == nil && !chat.isBackgroundTask {
                Button("Open Side") { model.openSide(parentID: session.id) }.disabled(!model.canOpenSide(session.id))
                Button("Portable Context Handoff…", action: model.portableHandoff)
                if chat.toolMode == "read-only" && chat.connectionTest != true && chat.workspaceID != WorkspaceRecord.scratchID { Button("Enable Editing Tools…") { model.enableEditing(session.id) }.disabled(session.hasWork) }
                Divider()
            }
            if !chat.isBackgroundTask { Button("Compact Now") { model.action("context.compact", sessionID: session.id) } }
            if session.before != nil || session.hostBefore != nil { Button("Earlier Messages") { model.loadEarlier(sessionID: session.id) } }
            Button("Latest Messages") { model.latest(sessionID: session.id) }
            Divider()
            Button("View Retained Message…") { model.viewMessages(session.id) }
            Button("Search and Copy Conversation…") { model.inspectConversation(session.id) }
            Button("Inspect Requests") { model.inspect(session.id) }
            if model.side(session.id) == nil {
                Divider()
                Button("Delete Chat…") { model.deleteChat(chat.id) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                .frame(width: 28, height: 28).background(Color.piFill, in: Circle()).contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer().help("Chat actions")
        .accessibilityIdentifier("conversationActions")
    }
}

/// The app mark with a soft pulse while a chat is being prepared and has nothing to show yet.
struct LoadingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    var body: some View {
        VStack(spacing: PiSpacing.md) {
            Image("BelloAgentIcon").resizable().interpolation(.high).scaledToFit().frame(width: 56, height: 56)
                .scaleEffect(breathing && !reduceMotion ? 1.06 : 1).opacity(breathing && !reduceMotion ? 1 : 0.82)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
                .accessibilityLabel("Bello Agent")
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
        }
        .onAppear { breathing = true }
        .accessibilityIdentifier("loadingMark")
    }
}

/// What an empty chat is connected to, and where to start. Gone with the first message.
struct StarterPanel: View {
    @ObservedObject var model: WorkspaceModel
    let chat: ChatRecord
    @ObservedObject var session: SessionDisplay
    private var workspace: WorkspaceRecord? { model.workspace(for: chat.workspaceID) }
    private var profile: ProfileRecord? { model.profiles.first { $0.id == chat.profileID } }
    private var modelName: String { chat.model ?? profile?.modelId ?? "catalog default" }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack { Spacer(); Image("BelloAgentIcon").resizable().interpolation(.high).scaledToFit().frame(width: 48, height: 48).accessibilityLabel("Bello Agent"); Spacer() }
            HStack(spacing: PiSpacing.sm) {
                PiIconBadge(symbol: "folder", tone: .accent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? chat.workspaceID).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1)
                    ForEach((workspace?.roots ?? []).prefix(4), id: \.self) { root in
                        Text(root).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            HStack(spacing: PiSpacing.sm) {
                PiBadge(text: profile?.name ?? "No connection", tone: profile == nil ? .danger : .neutral, icon: "antenna.radiowaves.left.and.right")
                PiBadge(text: modelName, icon: "cpu")
                PiBadge(text: chat.toolMode == "read-only" ? "Read-only tools" : "Editing tools", icon: chat.toolMode == "read-only" ? "eye" : "pencil")
            }
            Text("Type below to start. Your first message creates the chat.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            PiFlow(spacing: PiSpacing.sm, rowSpacing: PiSpacing.sm) {
                if model.side(session.id) == nil, chat.workspaceID != WorkspaceRecord.scratchID {
                    Button { model.showChanges(in: chat.workspaceID) } label: { Label("Changes", systemImage: "arrow.triangle.branch") }.buttonStyle(.piSecondaryCompact)
                    Button { model.toggleTerminal() } label: { Label("Terminal", systemImage: "terminal") }.buttonStyle(.piSecondaryCompact)
                }
                Button { model.inspectResources(session.id) } label: { Label("Skills", systemImage: "command") }.buttonStyle(.piSecondaryCompact)
                if model.side(session.id) == nil { Button { model.openSide(parentID: session.id) } label: { Label("Open a side", systemImage: "arrow.triangle.branch") }.buttonStyle(.piSecondaryCompact).disabled(!model.canOpenSide(session.id)) }
            }
        }
        .padding(PiSpacing.lg).frame(maxWidth: 560, alignment: .leading)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .accessibilityIdentifier("starterPanel")
    }
}

private struct ComposerInput: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject var draft: ComposerDraft
    @State private var contentHeight: CGFloat = 0
    private let minimumHeight: CGFloat = 44
    private let maximumHeight: CGFloat = 240
    init(model: WorkspaceModel, session: SessionDisplay) { self.model = model; self.session = session; self.draft = session.composerDraft }
    private var editing: Bool { session.editingMessageID != nil }
    private var canSend: Bool { !((draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.skills.isEmpty) || session.loading || model.installPreparing || (editing && (session.busy || !session.queue.isEmpty))) }
    private var queues: Bool { !editing && (session.busy || !session.queue.isEmpty) }
    @State private var sendPulse = false
    private func submit() {
        guard model.page == .chats else { return }
        // A short press-in and spring-back confirms the send under the pointer.
        sendPulse = true
        Task { try? await Task.sleep(for: .milliseconds(120)); sendPulse = false }
        if editing { model.sendEdit(sessionID: session.id) } else { model.send(sessionID: session.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            if session.completionVisible { completions.transition(AnyTransition.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity)) }
            VStack(spacing: 0) {
                if editing { EditingBanner(session: session) { model.cancelEdit(sessionID: session.id) }.transition(AnyTransition.move(edge: .top).combined(with: .opacity)) }
                if session.runStatus == "compacting" || session.compactionNotice != nil {
                    CompactionBanner(session: session) { session.compactionNotice = nil }.transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                }
                if !session.attachments.isEmpty || !session.skills.isEmpty { chips.padding(.horizontal, PiSpacing.md).padding(.top, PiSpacing.md).transition(.opacity) }
                NativeComposer(text: $draft.text, send: { submit() }, sessionID: session.id, completion: { _ in model.commandChanged(session) },
                    directSlash: { session.directCommand = true }, pasted: { session.directCommand = false; session.completionVisible = false },
                    completionKey: { model.completionKey($0, view: session) }, focused: { model.focusedSessionID = session.id }, accessibilityLabel: model.side(session.id) == nil ? "Main message composer" : "Side message composer", inputRejected: { session.notice = $0 },
                    attachFiles: { model.attachImageFiles($0, sessionID: session.id) },
                    heightChanged: { height in if abs(contentHeight - height) >= 1 { contentHeight = height } }, focusToken: session.composerFocusRequest)
                    .id(session.id).frame(height: min(maximumHeight, max(minimumHeight, contentHeight)))
                    .onChange(of: draft.text) { _, _ in model.draftChanged(session) }
                    // The keyboard hints are the empty composer's placeholder; they leave once typing starts.
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty && session.skills.isEmpty {
                            Text("Message… ↩ send · ⇧↩ new line · / skills").font(.system(size: 14)).foregroundStyle(Color.piInkTertiary)
                                .padding(.leading, 15).padding(.top, 9).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                HStack(spacing: 4) {
                    PiIconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true) { model.attachImages(sessionID: session.id) }.disabled(!model.supportsImages(session.id))
                    PiIconButton(symbol: "command", label: "Skills…", size: 28, filled: true) { model.inspectResources(session.id) }
                    Spacer()
                    if session.busy && !editing {
                        Button { model.send(steer: true, sessionID: session.id) } label: { Label("Steer run", systemImage: "arrow.turn.up.right") }.buttonStyle(.piGhost).disabled(session.loading)
                    }
                    if queues { Text("Queue follow-up").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                    if editing { Text(session.busy || !session.queue.isEmpty ? "Wait for idle to resend" : "Resend from here").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                    if let chat = model.record(session.id) {
                        if model.side(session.id) == nil, model.workspace(for: chat.workspaceID) != nil, chat.workspaceID != WorkspaceRecord.scratchID {
                            PiIconButton(symbol: "arrow.triangle.branch", label: "Changes and history of this project", size: 28, filled: true) { model.showChanges(in: chat.workspaceID) }
                                .accessibilityIdentifier("sessionChangesButton")
                        }
                        SessionUsageButton(model: model, chat: chat, footer: session.footer)
                        if model.side(session.id) == nil { ConversationActionsMenu(model: model, session: session, chat: chat) }
                    }
                    ModelSwitchPills(model: model, session: session).padding(.trailing, 2)
                    Button { submit() } label: {
                        Image(systemName: queues ? "text.badge.plus" : editing ? "arrow.uturn.up" : "arrow.up").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canSend ? Color.piOnAccent : Color.piInkTertiary)
                            .frame(width: 30, height: 30)
                            .background { if canSend { Circle().fill(Color.piBrandOrange) } else { Circle().fill(Color.piFillStrong) } }
                            .shadow(color: canSend ? Color.piBrandOrange.opacity(0.24) : .clear, radius: 5, y: 2)
                            .contentShape(Circle())
                            .scaleEffect(sendPulse ? 0.82 : 1)
                            .animation(.easeOut(duration: 0.18), value: canSend)
                            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: sendPulse)
                    }.buttonStyle(.plain).piPointer().disabled(!canSend).help(queues ? "Queue Follow-up" : editing ? "Resend Edited Message" : "Send")
                    if session.busy {
                        Button { model.stop(sessionID: session.id) } label: {
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.piOnAccent)
                                .frame(width: 30, height: 30)
                                .background(Color.piDanger, in: Circle()).contentShape(Circle())
                        }
                        .buttonStyle(.plain).piPointer().help("Stop response")
                        .accessibilityLabel("Stop response").accessibilityIdentifier("composerStopResponse")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 0)
            }
            .piElevated(radius: 16)
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.sm).padding(.bottom, 6)
        .animation(.easeOut(duration: 0.16), value: contentHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: session.completionVisible)
        .animation(.easeInOut(duration: 0.2), value: session.skills.count + session.attachments.count)
        .animation(.easeInOut(duration: 0.2), value: session.editingMessageID)
        .animation(.easeInOut(duration: 0.2), value: session.compactionNotice)
        .animation(.easeInOut(duration: 0.2), value: session.runStatus == "compacting")
        .animation(.easeInOut(duration: 0.2), value: session.busy)
        .disabled(editing && session.loading)
    }

    private var chips: some View {
        PiFlow {
            ForEach(session.attachments) { attachment in
                PiChip(text: URL(fileURLWithPath: attachment.path).lastPathComponent, icon: "photo", help: attachment.path,
                       action: { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) },
                       remove: { session.attachments.removeAll { $0.id == attachment.id }; model.draftChanged(session) })
            }
            ForEach(session.skills) { chip in
                PiChip(text: "/\(chip.name)" + (chip.arguments.isEmpty ? "" : " · \(String(chip.arguments.prefix(50)))"), icon: "command",
                       help: "Explicit for this submission · \(chip.path) · \(chip.contentHash)",
                       action: { model.editSkillArguments(chip, view: session) },
                       remove: { session.skills.removeAll { $0.id == chip.id }; model.draftChanged(session) })
            }
        }
    }

    private var completions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.completions(session).enumerated()), id: \.element.id) { index, choice in
                Button { model.chooseCompletion(choice, view: session) } label: {
                    HStack(spacing: PiSpacing.sm) {
                        Image(systemName: choice.skill == nil ? "terminal" : "command").font(.system(size: 11, weight: .semibold)).foregroundStyle(index == session.completionIndex ? Color.piAccent : Color.piInkSecondary).frame(width: 16)
                        Text("/" + choice.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk)
                        Text(choice.detail).lineLimit(1).truncationMode(.middle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        Spacer()
                    }.padding(.horizontal, PiSpacing.sm).padding(.vertical, 6).frame(maxWidth: .infinity)
                        .background(index == session.completionIndex ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).piPointer()
            }
            HStack {
                Text(model.resourceLoading ? "Discovering skills…" : "↑↓ Choose · Tab or Return Select · Esc Dismiss").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                Spacer()
                Button("All Skills…") { model.inspectResources(session.id) }.buttonStyle(.piGhost)
            }.padding(.horizontal, PiSpacing.sm).padding(.top, 4)
        }
        .padding(PiSpacing.sm)
        .piElevated(radius: PiRadius.md)
        .accessibilityElement(children: .contain).accessibilityLabel("Slash command suggestions")
    }
}
