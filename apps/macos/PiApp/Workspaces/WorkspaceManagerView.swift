import SwiftUI
import AppKit

enum WorkspaceLabel {
    static func name(_ workspace: WorkspaceRecord) -> String { URL(fileURLWithPath: workspace.path).lastPathComponent }
    static func folders(_ count: Int) -> String { count == 1 ? "1 folder" : "\(count) folders" }
    static func chats(_ count: Int) -> String { count == 1 ? "1 chat" : "\(count) chats" }
}

/// One folder line: path, primary marker and an optional remove action.
struct WorkspaceFolderRow: View {
    let path: String
    var primary = false
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: primary ? "house" : "folder").font(.system(size: 11, weight: .medium)).foregroundStyle(primary ? Color.piAccent : Color.piInkSecondary).frame(width: 14)
            Text(path).font(PiFont.mono).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
            Spacer(minLength: 4)
            if primary { PiBadge(text: "Primary", tone: .accent) }
            if let remove { PiIconButton(symbol: "xmark", label: "Remove folder", size: 22, action: remove) }
        }
        .padding(.horizontal, PiSpacing.md).padding(.vertical, 6)
    }
}

/// Primary and extra folders of a saved workspace with add/remove actions.
/// Shared by the manager sheet and onboarding.
struct WorkspaceFolderList: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: WorkspaceRecord
    var onError: (String) -> Void = { _ in }
    @State private var busy = false
    private var active: Bool { model.workspaceHasActiveWork(workspace.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            VStack(spacing: 0) {
                WorkspaceFolderRow(path: workspace.path, primary: true)
                ForEach(workspace.paths, id: \.self) { folder in
                    Rectangle().fill(Color.piHairline).frame(height: 1).padding(.leading, PiSpacing.md)
                    WorkspaceFolderRow(path: folder) { perform { try await model.removeFolder(folder, from: workspace.id) } }
                        .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                }
            }
            .piInset()
            .animation(.easeInOut(duration: 0.2), value: workspace.paths)
            HStack(spacing: PiSpacing.sm) {
                Button { perform { try await model.addFoldersInteractively(to: workspace.id) } } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.piSecondaryCompact).disabled(busy || active || workspace.roots.count >= WorkspaceModel.maximumRoots)
                if busy { ProgressView().controlSize(.mini) }
                Text(active ? "Stop this project's work before changing folders." : "\(WorkspaceLabel.folders(workspace.roots.count)) · Changes reopen the host on the next message")
                    .font(PiFont.caption).foregroundStyle(active ? Color.piWarning : Color.piInkTertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.18), value: active)
        }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; do { try await work() } catch { onError(error.localizedDescription) } }
    }
}

/// "Projects" sheet: every workspace with its folders and chat count, plus creation and removal.
struct WorkspaceManagerView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var draft: NewWorkspaceDraft?
    @State private var message = ""
    @State private var tone: PiTone = .neutral
    @State private var busy = false
    /// Remove Project asked once; the section shows the question until Remove or Keep.
    @State private var confirmingRemove: String?
    private var selected: WorkspaceRecord? { model.workspaces.first { $0.id == selection } }

    struct NewWorkspaceDraft: Equatable {
        var primary: String?
        var extras: [String] = []

        static func editing(_ source: Binding<Self?>) -> Binding<Self>? {
            guard let initial = source.wrappedValue else { return nil }
            return Binding(
                // Read live state on every edit, rather than the value captured by body.
                get: { source.wrappedValue ?? initial },
                // An outgoing animated pane must not reopen a cancelled draft.
                set: { if source.wrappedValue != nil { source.wrappedValue = $0 } }
            )
        }

        mutating func selectPrimary(_ folder: String) {
            primary = folder
            extras.removeAll { $0 == folder }
        }
    }

    var body: some View {
        PiSheet("Projects", subtitle: "Every chat belongs to one project. The primary folder is the working directory; extra folders are read, searched and edited by the same tools.", symbol: "folder.badge.gearshape", width: 780, height: 540) {
            HStack(spacing: 0) {
                list.frame(width: 250)
                Rectangle().fill(Color.piHairline).frame(width: 1)
                Group {
                    if let draft = NewWorkspaceDraft.editing($draft) { NewWorkspacePane(model: model, draft: draft, busy: $busy, cancel: { withAnimation { self.draft = nil } }, created: { id in withAnimation { self.draft = nil; selection = id }; report("Project created.", .success) }, failed: { report($0, .danger) })
                            .transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
                    } else if let selected { detail(selected).id(selected.id).transition(.opacity) }
                    else { placeholder.transition(.opacity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: selection)
                .animation(.easeInOut(duration: 0.2), value: draft == nil)
            }
        } actions: {
            Button { withAnimation(.easeInOut(duration: 0.2)) { draft = NewWorkspaceDraft() }; message = "" } label: { Label("New Project…", systemImage: "plus") }
                .buttonStyle(.piPrimaryCompact).disabled(draft != nil || busy)
        } footer: {
            HStack(spacing: PiSpacing.md) {
                PiStatusLine(text: message, tone: tone).animation(.easeInOut(duration: 0.18), value: message)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { selection = model.selectedWorkspaceID ?? model.workspaces.first?.id; if model.workspaces.isEmpty { draft = NewWorkspaceDraft() } }
        .onChange(of: model.workspaces.map(\.id)) { _, ids in if let selection, !ids.contains(selection) { self.selection = ids.first } }
        .onChange(of: selection) { _, _ in confirmingRemove = nil }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.workspaces.isEmpty ? "Projects" : "Projects · \(model.workspaces.count)").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.5)
                .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.md).padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.workspaces) { workspace in
                        let chats = model.chatCount(workspaceID: workspace.id)
                        PiSelectableRow(selected: selection == workspace.id && draft == nil, action: { withAnimation(.easeInOut(duration: 0.2)) { draft = nil; selection = workspace.id } }) {
                            HStack(spacing: 8) {
                                Image(systemName: workspace.trusted ? "folder.fill" : "folder.badge.questionmark").font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(selection == workspace.id ? Color.piAccent : Color.piInkSecondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(WorkspaceLabel.name(workspace)).font(.system(size: 13, weight: selection == workspace.id ? .semibold : .regular)).foregroundStyle(Color.piInk).lineLimit(1)
                                        if !workspace.paths.isEmpty { Text("+\(workspace.paths.count)").font(PiFont.micro).foregroundStyle(Color.piAccent) }
                                    }
                                    Text(WorkspaceLabel.chats(chats) + " · " + WorkspaceLabel.folders(workspace.roots.count)).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.hosts[workspace.id]?.isReady == true { Circle().fill(model.workspaceHasActiveWork(workspace.id) ? Color.piWarning : Color.piSuccess).frame(width: 6, height: 6).help("Host running") }
                            }
                        }
                    }
                }.padding(.horizontal, PiSpacing.sm)
            }
            .overlay {
                if model.workspaces.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 22)).foregroundStyle(Color.piInkTertiary)
                        Text("No projects yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }.padding(PiSpacing.lg)
                }
            }
        }
        .background(Color.piWindow)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(Color.piInkTertiary)
            Text("Select a project or create one.").font(PiFont.body).foregroundStyle(Color.piInkSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ workspace: WorkspaceRecord) -> some View {
        let chats = model.chatCount(workspaceID: workspace.id)
        let hasTopics = !model.topics(in: workspace.id).isEmpty
        let removalHint = chats > 0 ? "Delete its \(WorkspaceLabel.chats(chats)) first; a project with chats cannot be removed."
            : hasTopics ? "Remove this project's topics first. Removing a topic keeps its chats."
            : "Forget this project. Its folders on disk stay untouched."
        return ScrollView {
            VStack(alignment: .leading, spacing: PiSpacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: PiSpacing.sm) {
                    Text(WorkspaceLabel.name(workspace)).font(PiFont.title(17)).foregroundStyle(Color.piInk).lineLimit(1)
                    PiBadge(text: WorkspaceLabel.chats(chats), icon: "bubble.left")
                    if model.workspaceHasActiveWork(workspace.id) { PiBadge(text: "Working", tone: .warning, dot: true) }
                    Spacer()
                    if model.selectedWorkspaceID != workspace.id { Button("Switch to It") { model.selectedWorkspaceID = workspace.id }.buttonStyle(.piGhost) }
                    else { PiBadge(text: "Current", tone: .accent) }
                }
                .animation(.easeInOut(duration: 0.18), value: model.selectedWorkspaceID)
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Folders", subtitle: "Tools resolve relative paths against the primary folder; skills and instructions are discovered in every folder.")
                    WorkspaceFolderList(model: model, workspace: workspace) { report($0, .danger) }
                }
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Remove", subtitle: removalHint)
                    if confirmingRemove == workspace.id {
                        HStack(spacing: PiSpacing.sm) {
                            Text("Remove “\(WorkspaceLabel.name(workspace))”? Bello Agent forgets this project and its folder trust. Nothing on disk is deleted.")
                                .font(PiFont.caption).foregroundStyle(Color.piDanger).fixedSize(horizontal: false, vertical: true)
                            Button("Keep") { withAnimation(PiMotion.quick) { confirmingRemove = nil } }.buttonStyle(.piSecondaryCompact).fixedSize()
                            Button { remove(workspace) } label: { Label("Remove Project", systemImage: "trash") }.buttonStyle(.piDanger).fixedSize().disabled(busy)
                                .accessibilityIdentifier("workspace-confirm-remove")
                        }
                    } else {
                        Button { withAnimation(PiMotion.base) { confirmingRemove = workspace.id } } label: { Label("Remove Project…", systemImage: "trash") }.buttonStyle(.piDanger).disabled(chats > 0 || hasTopics || busy)
                            .accessibilityIdentifier("workspace-remove")
                    }
                }
                .piAnimation(PiMotion.base, value: confirmingRemove)
            }
            .padding(PiSpacing.xl)
        }
    }

    private func remove(_ workspace: WorkspaceRecord) {
        confirmingRemove = nil
        busy = true
        Task { defer { busy = false }
            do { try await model.removeWorkspace(workspace.id); report("Project removed.", .success) }
            catch { report(error.localizedDescription, .danger) } }
    }

    private func report(_ text: String, _ tone: PiTone) { message = text; self.tone = tone }
}

/// Create flow: choose a primary folder, optional extras, then trust and save.
private struct NewWorkspacePane: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var draft: WorkspaceManagerView.NewWorkspaceDraft
    @Binding var busy: Bool
    let cancel: () -> Void
    let created: (String) -> Void
    let failed: (String) -> Void
    private var roots: [String] { (draft.primary.map { [$0] } ?? []) + draft.extras }
    private var existing: WorkspaceRecord? { draft.primary.flatMap { path in model.workspaces.first { $0.path == path } } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PiSpacing.lg) {
                PiSectionHeader("New project", subtitle: "Pick the primary folder first. Add more folders when a task spans several repositories.")
                VStack(spacing: 0) {
                    if let primary = draft.primary {
                        WorkspaceFolderRow(path: primary, primary: true).transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                    } else {
                        HStack(spacing: PiSpacing.sm) {
                            Image(systemName: "house").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary).frame(width: 14)
                            Text("No primary folder chosen").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                            Spacer()
                        }.padding(.horizontal, PiSpacing.md).padding(.vertical, 8)
                    }
                    ForEach(draft.extras, id: \.self) { folder in
                        Rectangle().fill(Color.piHairline).frame(height: 1).padding(.leading, PiSpacing.md)
                        WorkspaceFolderRow(path: folder) { draft.extras.removeAll { $0 == folder } }
                            .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                    }
                }
                .piInset()
                .animation(.easeInOut(duration: 0.2), value: draft)
                HStack(spacing: PiSpacing.sm) {
                    Button { choosePrimary() } label: { Label(draft.primary == nil ? "Choose Primary Folder…" : "Change Primary…", systemImage: "house") }.buttonStyle(.piSecondaryCompact)
                    Button { addExtras() } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }.buttonStyle(.piSecondaryCompact)
                        .disabled(draft.primary == nil || roots.count >= WorkspaceModel.maximumRoots)
                    Spacer()
                    Text(WorkspaceLabel.folders(roots.count)).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
                if existing != nil {
                    PiNote("This folder is already a project. Creating it again replaces its extra folders.", tone: .warning)
                }
                PiNote("Editing chats can read files, run shell commands and change files in these folders with your account's permissions. Read-only chats expose only local read and search tools.")
                HStack {
                    Button("Cancel", action: cancel).buttonStyle(.piGhost)
                    Spacer()
                    Button { create() } label: { Label(busy ? "Creating…" : "Create Project", systemImage: "checkmark") }.buttonStyle(.piPrimary).disabled(draft.primary == nil || busy)
                }
            }
            .padding(PiSpacing.xl)
        }
        .disabled(busy)
    }
    private func choosePrimary() {
        Task {
            guard let folder = await WorkspaceModel.chooseFolders(message: "Choose the primary working directory for this project.", multiple: false).first else { return }
            withAnimation { draft.selectPrimary(folder) }
        }
    }
    private func addExtras() {
        Task {
            let picked = await WorkspaceModel.chooseFolders(message: "Choose additional folders for this project.", multiple: true).filter { !roots.contains($0) }
            guard !picked.isEmpty else { return }
            withAnimation { draft.extras += picked }
        }
    }
    private func create() {
        guard let primary = draft.primary else { return }
        do { try WorkspaceModel.validateRoots(roots) } catch { failed(error.localizedDescription); return }
        let extras = draft.extras
        busy = true
        Task { defer { busy = false }
            do { let workspace = try await model.createWorkspace(primary: primary, extras: extras); created(workspace.id) }
            catch { failed(error.localizedDescription) } }
    }
}
