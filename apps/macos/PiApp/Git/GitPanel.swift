import SwiftUI
import AppKit

/// State for the Changes sheet: which folder, its status, the selected file's
/// diff, the commit history and the selected commit. Reads run on GitService;
/// stage, unstage and commit are the only writes.
@MainActor final class GitController: ObservableObject {
    enum Panel: String, CaseIterable, Hashable { case changes, history
        var title: String { self == .changes ? "Changes" : "History" }
    }
    struct Selection: Equatable { let path: String; let staged: Bool }

    @Published var roots: [String] = []
    @Published var root: String? { didSet { if root != oldValue { Task { await refresh() } } } }
    @Published var repositoryRoot: String?
    @Published var panel = Panel.changes
    @Published private(set) var status = GitRepositoryStatus()
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published var selection: Selection? { didSet { if selection != oldValue { Task { await loadSelectedDiff() } } } }
    @Published private(set) var diff: [GitDiffFile] = []
    @Published private(set) var diffLoading = false
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var historyExhausted = false
    @Published var selectedCommit: GitCommit? { didSet { if selectedCommit != oldValue { Task { await loadCommitDetail() } } } }
    @Published private(set) var detail: GitCommitDetail?
    @Published var commitMessage = ""
    @Published private(set) var lastCommit: String?
    /// Files ticked for the next commit (IntelliJ's changelist checkboxes).
    @Published var checked: Set<String> = []
    @Published var amend = false { didSet { if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Task { await prefillHeadMessage() } } } }
    @Published private(set) var branches: [String] = []
    @Published private(set) var stashes: [GitStashEntry] = []
    @Published var logFilter = GitLogFilter() { didSet { if logFilter != oldValue { Task { await reloadHistory() } } } }
    @Published var detailFile: String? { didSet { if detailFile != oldValue { Task { await loadCommitDetail() } } } }
    @Published private(set) var detailFileDiff: [GitDiffFile] = []
    @Published var splitDiff = false
    @Published private(set) var busy = false
    private let service: GitService
    private var generation = 0

    init(roots: [String], service: GitService = .shared) {
        self.service = service; self.roots = roots; self.root = roots.first
    }

    var displayRoot: String { (root as NSString?)?.lastPathComponent ?? "" }
    var staged: [GitStatusEntry] { status.entries.filter(\.staged) }
    var unstaged: [GitStatusEntry] { status.entries.filter(\.unstaged) }

    func refresh() async {
        guard let root else { return }
        generation += 1; let generation = generation
        loading = true; notice = ""
        defer { if self.generation == generation { loading = false } }
        let top = await service.repositoryRoot(of: root)
        guard self.generation == generation else { return }
        repositoryRoot = top
        guard let top else { status = GitRepositoryStatus(); diff = []; commits = []; selection = nil; selectedCommit = nil; detail = nil; return }
        do {
            let status = try await service.status(in: top)
            guard self.generation == generation else { return }
            self.status = status
            let paths = Set(status.entries.map(\.path))
            checked = checked.isEmpty && status.entries.isEmpty ? [] : (checked.isEmpty ? paths : checked.intersection(paths))
            if let selection, !status.entries.contains(where: { $0.path == selection.path && ($0.staged == selection.staged || $0.unstaged == !selection.staged) }) { self.selection = nil }
            else if selection == nil, let first = status.entries.first { selection = Selection(path: first.path, staged: !first.unstaged && first.staged) }
            else { await loadSelectedDiff() }
            async let branchList = service.branches(in: top)
            async let stashList = service.stashes(in: top)
            branches = (try? await branchList) ?? []; stashes = (try? await stashList) ?? []
            await reloadHistory(generation: generation)
        } catch { notice = error.localizedDescription }
    }

    private func reloadHistory(generation: Int? = nil) async {
        guard let repositoryRoot else { return }
        let generation = generation ?? self.generation
        do {
            let commits = try await service.log(in: repositoryRoot, limit: 50, filter: logFilter)
            guard self.generation == generation else { return }
            self.commits = commits; historyExhausted = commits.count < 50
            if let selectedCommit, !commits.contains(where: { $0.hash == selectedCommit.hash }) { self.selectedCommit = nil }
        } catch { notice = error.localizedDescription }
    }

    func loadMoreHistory() async {
        guard let repositoryRoot, !historyExhausted else { return }
        do {
            let more = try await service.log(in: repositoryRoot, limit: 50, skip: commits.count, filter: logFilter)
            commits += more.filter { commit in !commits.contains(where: { $0.hash == commit.hash }) }
            historyExhausted = more.count < 50
        } catch { notice = error.localizedDescription }
    }

    private func prefillHeadMessage() async {
        guard let repositoryRoot, let message = try? await service.headMessage(in: repositoryRoot) else { return }
        if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commitMessage = message }
    }

    private func perform(_ what: String, _ work: () async throws -> Void) async {
        busy = true; notice = ""
        defer { busy = false }
        do { try await work() } catch { notice = "\(what): \(error.localizedDescription)" }
        await refresh()
    }
    func checkout(_ branch: String) async { guard let root = repositoryRoot else { return }; await perform("Switch") { try await service.checkout(branch, in: root) } }
    func createBranch(_ name: String) async { guard let root = repositoryRoot else { return }; await perform("New branch") { try await service.createBranch(name, in: root) } }
    func stash(message: String) async { guard let root = repositoryRoot else { return }; await perform("Stash") { try await service.stashPush(message: message, in: root) } }
    func popStash(_ name: String? = nil) async { guard let root = repositoryRoot else { return }; await perform("Pop stash") { try await service.stashPop(name, in: root) } }
    func fetch() async { guard let root = repositoryRoot else { return }; await perform("Fetch") { try await service.fetch(in: root) } }
    func pull() async { guard let root = repositoryRoot else { return }; await perform("Pull") { try await service.pull(in: root) } }
    func push() async { guard let root = repositoryRoot else { return }; await perform("Push") { try await service.push(in: root) } }
    func discard(_ entries: [GitStatusEntry]) async { guard let root = repositoryRoot else { return }; await perform("Discard") { try await service.discard(entries, in: root) } }
    /// Commits the checked files (their working-tree state), or the staged index when nothing is checked.
    func commitChecked() async {
        guard let root = repositoryRoot else { return }
        let paths = status.entries.filter { checked.contains($0.path) }.map(\.path)
        await perform("Commit") {
            lastCommit = try await service.commit(message: commitMessage, in: root, paths: paths, amend: amend)
            commitMessage = ""; amend = false
        }
    }

    private func loadSelectedDiff() async {
        guard let repositoryRoot, let selection else { diff = []; return }
        diffLoading = true; defer { diffLoading = false }
        let entry = status.entries.first { $0.path == selection.path }
        do {
            let text = try await service.diff(in: repositoryRoot, path: selection.path, staged: selection.staged, untracked: entry?.untracked == true)
            guard self.selection == selection else { return }
            diff = GitDiffParser.parse(text)
        } catch { notice = error.localizedDescription; diff = [] }
    }

    private func loadCommitDetail() async {
        guard let repositoryRoot, let selectedCommit else { detail = nil; detailFileDiff = []; return }
        diffLoading = true; defer { diffLoading = false }
        do {
            if detail?.commit.hash != selectedCommit.hash {
                let value = try await service.commitDetail(in: repositoryRoot, commit: selectedCommit)
                guard self.selectedCommit == selectedCommit else { return }
                detail = value; detailFile = nil; detailFileDiff = []
            }
            if let detailFile {
                let text = try await service.commitDiff(in: repositoryRoot, commit: selectedCommit, path: detailFile)
                guard self.detailFile == detailFile else { return }
                detailFileDiff = GitDiffParser.parse(text)
            } else { detailFileDiff = [] }
        } catch { notice = error.localizedDescription; detail = nil }
    }

    func stage(_ paths: [String]) async {
        guard let repositoryRoot else { return }
        do { try await service.stage(paths, in: repositoryRoot) } catch { notice = error.localizedDescription }
        await refresh()
    }
    func unstage(_ paths: [String]) async {
        guard let repositoryRoot else { return }
        do { try await service.unstage(paths, in: repositoryRoot) } catch { notice = error.localizedDescription }
        await refresh()
    }
    func commit() async {
        guard let repositoryRoot else { return }
        do {
            lastCommit = try await service.commit(message: commitMessage, in: repositoryRoot)
            commitMessage = ""
        } catch { notice = error.localizedDescription }
        await refresh()
    }
}

/// The Changes sheet, laid out like IntelliJ's Git tool window: a branch
/// menu with fetch, pull, push and stash controls; a changelist with
/// checkboxes, amend and discard; the history with filters and ref badges;
/// and a unified or side-by-side diff of whatever is selected.
struct GitPanelView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var controller: GitController
    @Environment(\.dismiss) private var dismiss
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var stashMessage = ""
    @State private var showStash = false

    init(model: WorkspaceModel, roots: [String]) {
        self.model = model
        _controller = StateObject(wrappedValue: GitController(roots: roots))
    }

    var body: some View {
        PiSheet("Changes", subtitle: subtitle, symbol: "arrow.triangle.branch", width: 1180, height: 780) {
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Color.piHairline).frame(height: 1)
                if controller.repositoryRoot == nil && !controller.loading {
                    notARepository
                } else {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 340)
                        Rectangle().fill(Color.piHairline).frame(width: 1)
                        detailPane
                    }
                }
            }
        } actions: {
            if controller.loading || controller.busy { ProgressView().controlSize(.small) }
            PiIconButton(symbol: "arrow.clockwise", label: "Refresh changes", size: 28) { Task { await controller.refresh() } }
            Button("Done") { dismiss() }.buttonStyle(.piSecondary)
        }
        .task { await controller.refresh() }
        .accessibilityIdentifier("git-panel")
    }

    private var subtitle: String {
        guard controller.repositoryRoot != nil else { return "Working-tree changes and history of the project's folders." }
        var parts = [controller.status.branch.isEmpty ? "detached HEAD" : controller.status.branch]
        if let upstream = controller.status.upstream { parts.append("tracks \(upstream)") }
        parts.append("\(controller.status.entries.count) changed")
        if !controller.stashes.isEmpty { parts.append("\(controller.stashes.count) stashed") }
        return parts.joined(separator: " · ")
    }

    private var toolbar: some View {
        HStack(spacing: PiSpacing.sm) {
            if controller.roots.count > 1 {
                PiDropdown(selection: Binding(get: { controller.root ?? "" }, set: { controller.root = $0 }),
                           items: controller.roots.map { ($0, ($0 as NSString).lastPathComponent) }, icon: "folder", compact: true)
            } else {
                Label(controller.displayRoot, systemImage: "folder").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            if controller.repositoryRoot != nil {
                branchMenu
                remoteControls
                stashMenu
            }
            PiTabs(selection: $controller.panel, items: GitController.Panel.allCases.map { ($0, $0.title) })
            Spacer()
            if !controller.notice.isEmpty { Text(controller.notice).font(PiFont.caption).foregroundStyle(Color.piDanger).lineLimit(1).help(controller.notice) }
            if let last = controller.lastCommit { PiBadge(text: "Committed \(last)", tone: .success, icon: "checkmark") }
        }.padding(.horizontal, PiSpacing.lg).padding(.vertical, PiSpacing.sm)
    }

    /// IntelliJ's branch popup: the local branches to switch to, and a new branch from HEAD.
    private var branchMenu: some View {
        PiMenuButton(title: controller.status.branch.isEmpty ? "detached" : controller.status.branch, icon: "arrow.triangle.branch") {
            Button("New Branch from \(controller.status.branch.isEmpty ? "HEAD" : controller.status.branch)…") { newBranchName = ""; showNewBranch = true }
            Divider()
            ForEach(controller.branches, id: \.self) { branch in
                Button { Task { await controller.checkout(branch) } } label: {
                    if branch == controller.status.branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                }.disabled(branch == controller.status.branch)
            }
        }
        .disabled(controller.busy)
        .accessibilityIdentifier("git-branch-menu")
        .popover(isPresented: $showNewBranch, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                Text("New branch").font(PiFont.heading).foregroundStyle(Color.piInk)
                PiTextField(placeholder: "feature/name", text: $newBranchName, icon: "arrow.triangle.branch", mono: true) { createBranch() }
                Text("Created from the current HEAD and checked out; your changes come along.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                HStack { Spacer()
                    Button("Cancel") { showNewBranch = false }.buttonStyle(.piSecondaryCompact)
                    Button("Create") { createBranch() }.buttonStyle(.piPrimaryCompact).disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(PiSpacing.lg).frame(width: 320)
        }
    }
    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showNewBranch = false
        Task { await controller.createBranch(name) }
    }

    private var remoteControls: some View {
        HStack(spacing: 2) {
            PiIconButton(symbol: "arrow.down.to.line", label: "Fetch", size: 26) { Task { await controller.fetch() } }.help("Fetch from every remote and prune")
            PiIconButton(symbol: "arrow.down.circle", label: "Pull", size: 26) { Task { await controller.pull() } }
                .help(controller.status.behind > 0 ? "Pull \(controller.status.behind) new commits (fast-forward only)" : "Pull (fast-forward only)")
                .overlay(alignment: .topTrailing) { counter(controller.status.behind) }
            PiIconButton(symbol: "arrow.up.circle", label: "Push", size: 26) { Task { await controller.push() } }
                .help(controller.status.ahead > 0 ? "Push \(controller.status.ahead) commits to \(controller.status.upstream ?? "the upstream")" : "Push")
                .overlay(alignment: .topTrailing) { counter(controller.status.ahead) }
        }.disabled(controller.busy)
    }
    @ViewBuilder private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.piOnAccent)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.piAccent, in: Capsule()).offset(x: 4, y: -4)
        }
    }

    private var stashMenu: some View {
        PiMenuButton(title: controller.stashes.isEmpty ? "Stash" : "Stash · \(controller.stashes.count)", icon: "tray.and.arrow.down") {
            Button("Stash Changes…") { stashMessage = ""; showStash = true }.disabled(controller.status.entries.isEmpty)
            if !controller.stashes.isEmpty {
                Divider()
                ForEach(controller.stashes) { stash in
                    Button("Pop \(stash.name): \(stash.subject)") { Task { await controller.popStash(stash.name) } }
                }
            }
        }
        .disabled(controller.busy)
        .accessibilityIdentifier("git-stash-menu")
        .popover(isPresented: $showStash, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                Text("Stash changes").font(PiFont.heading).foregroundStyle(Color.piInk)
                PiTextField(placeholder: "Message (optional)", text: $stashMessage, icon: "text.quote") { pushStash() }
                Text("Sets aside every change, untracked files included, and restores a clean working tree.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                HStack { Spacer()
                    Button("Cancel") { showStash = false }.buttonStyle(.piSecondaryCompact)
                    Button("Stash") { pushStash() }.buttonStyle(.piPrimaryCompact)
                }
            }.padding(PiSpacing.lg).frame(width: 340)
        }
    }
    private func pushStash() { showStash = false; Task { await controller.stash(message: stashMessage) } }

    private var notARepository: some View {
        VStack(spacing: PiSpacing.sm) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 28)).foregroundStyle(Color.piInkTertiary)
            Text("Not a git repository").font(PiFont.title(17)).foregroundStyle(Color.piInk)
            Text("\(controller.displayRoot) is not inside a git repository. Run git init there, or choose another folder of this project.")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var sidebar: some View {
        if controller.panel == .changes { changesList } else { historyList }
    }

    // MARK: Changes

    private var changesList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if controller.status.entries.isEmpty {
                        Text("No changes. The working tree matches HEAD.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(PiSpacing.lg)
                    }
                    if !controller.staged.isEmpty {
                        section("Staged · \(controller.staged.count)", entries: controller.staged, action: ("Unstage all", { Task { await controller.unstage(controller.staged.map(\.path)) } }))
                        ForEach(controller.staged) { entry in fileRow(entry, staged: true) }
                    }
                    if !controller.unstaged.isEmpty {
                        section("Changes · \(controller.unstaged.count)", entries: controller.unstaged, action: ("Stage all", { Task { await controller.stage(controller.unstaged.map(\.path)) } }))
                        ForEach(controller.unstaged) { entry in fileRow(entry, staged: false) }
                    }
                }.padding(PiSpacing.sm)
            }
            Rectangle().fill(Color.piHairline).frame(height: 1)
            commitBox
        }
    }

    private func section(_ title: String, entries: [GitStatusEntry], action: (String, () -> Void)) -> some View {
        let paths = Set(entries.map(\.path))
        let all = paths.isSubset(of: controller.checked)
        return HStack(spacing: PiSpacing.sm) {
            checkbox(on: all, mixed: !all && !paths.isDisjoint(with: controller.checked), label: all ? "Uncheck \(title)" : "Check \(title)") {
                if all { controller.checked.subtract(paths) } else { controller.checked.formUnion(paths) }
            }
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            Spacer()
            Button(action.0, action: action.1).buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piAccent).piPointer()
        }.padding(.horizontal, PiSpacing.sm).padding(.top, PiSpacing.sm).padding(.bottom, 2)
    }

    private func checkbox(on: Bool, mixed: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on || mixed ? Color.piAccent : Color.piInkTertiary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain).piPointer().accessibilityLabel(label)
    }

    private func fileRow(_ entry: GitStatusEntry, staged: Bool) -> some View {
        let selected = controller.selection == GitController.Selection(path: entry.path, staged: staged)
        let checked = controller.checked.contains(entry.path)
        return PiSelectableRow(selected: selected, action: { controller.selection = GitController.Selection(path: entry.path, staged: staged) }) {
            HStack(spacing: PiSpacing.sm) {
                checkbox(on: checked, label: checked ? "Exclude \(entry.path) from the commit" : "Include \(entry.path) in the commit") {
                    if checked { controller.checked.remove(entry.path) } else { controller.checked.insert(entry.path) }
                }.accessibilityIdentifier("git-check-" + entry.path)
                Text(entry.badge).font(PiFont.micro.weight(.bold)).foregroundStyle(Color.piOnAccent).frame(width: 18, height: 18)
                    .background(badgeColor(entry.badge), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help(entry.summary)
                VStack(alignment: .leading, spacing: 1) {
                    Text((entry.path as NSString).lastPathComponent).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(1)
                    Text(entry.renamed ? "\(entry.originalPath ?? "") → \(entry.path)" : (entry.path as NSString).deletingLastPathComponent)
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                PiIconButton(symbol: staged ? "minus" : "plus", label: staged ? "Unstage \(entry.path)" : "Stage \(entry.path)", size: 20) {
                    Task { if staged { await controller.unstage([entry.path]) } else { await controller.stage([entry.path]) } }
                }
            }
        }
        .contextMenu {
            if staged { Button("Unstage") { Task { await controller.unstage([entry.path]) } } } else { Button("Stage") { Task { await controller.stage([entry.path]) } } }
            Button(entry.untracked ? "Delete Untracked File…" : "Discard Changes…") { confirmDiscard([entry]) }
            Divider()
            Button("Reveal in Finder") { if let root = controller.repositoryRoot { NSWorkspace.shared.selectFile((root as NSString).appendingPathComponent(entry.path), inFileViewerRootedAtPath: root) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
        }
        .accessibilityIdentifier("git-file-" + entry.path)
    }

    /// Discard is the one irreversible action here, so it always confirms.
    private func confirmDiscard(_ entries: [GitStatusEntry]) {
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Discard changes to \((entries[0].path as NSString).lastPathComponent)?" : "Discard changes to \(entries.count) files?"
        alert.informativeText = "Tracked files revert to HEAD and untracked files are deleted. Git keeps no copy of these changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await controller.discard(entries) }
    }

    private func badgeColor(_ badge: String) -> Color {
        switch badge { case "A", "U": .piSuccess; case "D": .piDanger; case "R", "C": .piInfo; default: .piBrandOrange }
    }

    private var commitBox: some View {
        let checkedCount = controller.status.entries.filter { controller.checked.contains($0.path) }.count
        let message = controller.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let nothing = checkedCount == 0 && controller.staged.isEmpty && !controller.amend
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            TextField(controller.amend ? "Amended commit message" : "Commit message", text: $controller.commitMessage, axis: .vertical).textFieldStyle(.plain).font(PiFont.body).lineLimit(2...5)
                .padding(PiSpacing.sm).piInset()
                .accessibilityIdentifier("git-commit-message")
            HStack(spacing: PiSpacing.sm) {
                checkbox(on: controller.amend, label: "Amend the last commit") { controller.amend.toggle() }.accessibilityIdentifier("git-amend")
                Text("Amend").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .help("Fold the checked files into the last commit and reword it.")
                Spacer()
                if !controller.status.entries.isEmpty {
                    Button("Discard All…") { confirmDiscard(controller.status.entries) }.buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piDanger).piPointer()
                        .accessibilityIdentifier("git-discard-all")
                }
            }
            HStack(spacing: PiSpacing.sm) {
                Text(checkedCount > 0 ? "\(checkedCount) of \(controller.status.entries.count) files" : controller.staged.isEmpty ? (controller.amend ? "Reword only" : "Check files to commit") : "Staged index")
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                Spacer()
                Button { Task { await controller.commitChecked() } } label: { Label(controller.amend ? "Amend" : "Commit", systemImage: "checkmark.circle") }
                    .buttonStyle(.piPrimaryCompact).fixedSize()
                    .disabled(nothing || message.isEmpty || controller.loading || controller.busy)
                    .accessibilityIdentifier("git-commit")
            }
        }.padding(PiSpacing.md)
    }

    // MARK: History

    private var historyList: some View {
        VStack(spacing: 0) {
            VStack(spacing: PiSpacing.xs) {
                PiTextField(placeholder: "Filter by message or hash", text: Binding(get: { controller.logFilter.text }, set: { controller.logFilter.text = $0 }), icon: "magnifyingglass")
                    .accessibilityIdentifier("git-history-filter")
                HStack(spacing: PiSpacing.sm) {
                    PiTextField(placeholder: "Author", text: Binding(get: { controller.logFilter.author }, set: { controller.logFilter.author = $0 }), icon: "person")
                    checkbox(on: controller.logFilter.allBranches, label: "Show all branches") { controller.logFilter.allBranches.toggle() }
                    Text("All branches").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize()
                }
            }.padding(PiSpacing.sm)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if controller.commits.isEmpty && !controller.loading {
                        Text(controller.logFilter == GitLogFilter() ? "No commits yet." : "No commits match the filter.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(PiSpacing.lg)
                    }
                    ForEach(controller.commits) { commit in commitRow(commit) }
                    if !controller.historyExhausted && !controller.commits.isEmpty {
                        Button("Load older commits") { Task { await controller.loadMoreHistory() } }.buttonStyle(.piGhost).padding(PiSpacing.sm)
                    }
                }.padding(PiSpacing.sm)
            }
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        PiSelectableRow(selected: controller.selectedCommit == commit, action: { controller.selectedCommit = commit }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(2)
                if !commit.refs.isEmpty {
                    PiFlow(spacing: 4, rowSpacing: 4) {
                        ForEach(commit.refs, id: \.self) { ref in
                            PiBadge(text: ref.replacingOccurrences(of: "HEAD -> ", with: ""), tone: ref.hasPrefix("HEAD") ? .accent : ref.hasPrefix("tag: ") ? .warning : .info,
                                    icon: ref.hasPrefix("tag: ") ? "tag" : ref.hasPrefix("HEAD") ? "location" : nil)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(commit.shortHash).font(PiFont.mono).foregroundStyle(Color.piAccent)
                    Text(commit.author).lineLimit(1)
                    Text(commit.date.formatted(.relative(presentation: .named))).lineLimit(1)
                    if commit.parents.count > 1 { Image(systemName: "arrow.triangle.merge").help("Merge commit") }
                }.font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }
        }
        .contextMenu {
            Button("Copy Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) }
            Button("Copy Subject") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.subject, forType: .string) }
        }
        .accessibilityIdentifier("git-commit-" + commit.shortHash)
    }

    // MARK: Detail

    @ViewBuilder private var detailPane: some View {
        if controller.panel == .changes {
            if let selection = controller.selection {
                DiffView(files: controller.diff, title: selection.path, subtitle: selection.staged ? "Staged · index versus HEAD" : "Working tree versus index", loading: controller.diffLoading, split: $controller.splitDiff)
            } else {
                placeholder("Select a file to see its changes.")
            }
        } else if let detail = controller.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.commit.subject).font(PiFont.title(17)).foregroundStyle(Color.piInk)
                        Text("\(detail.commit.author) · \(detail.commit.date.formatted(date: .abbreviated, time: .shortened)) · \(detail.commit.hash)")
                            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textSelection(.enabled)
                        if detail.message.contains("\n") {
                            Text(detail.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(PiFont.body).foregroundStyle(Color.piInkSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if !detail.files.isEmpty { commitFiles(detail) }
                    }.padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.lg)
                    DiffView(files: controller.detailFile == nil ? GitDiffParser.parse(detail.diff) : controller.detailFileDiff,
                             title: controller.detailFile, subtitle: controller.detailFile == nil ? nil : "In \(detail.commit.shortHash)", loading: controller.diffLoading, embedded: true, split: $controller.splitDiff)
                }
            }
        } else if controller.diffLoading {
            placeholder("Loading…")
        } else {
            placeholder("Select a commit to see what it changed.")
        }
    }

    /// The commit's files as chips; one narrows the diff to that file, "All" widens it again.
    private func commitFiles(_ detail: GitCommitDetail) -> some View {
        PiFlow {
            PiChip(text: "All \(detail.files.count) files", icon: controller.detailFile == nil ? "checkmark" : nil) { controller.detailFile = nil }
            ForEach(detail.files) { file in
                Button { controller.detailFile = controller.detailFile == file.path ? nil : file.path } label: {
                    PiBadge(text: "\(file.badge) \((file.path as NSString).lastPathComponent)",
                            tone: controller.detailFile == file.path ? .accent : file.badge == "D" ? .danger : file.badge == "A" ? .success : .neutral)
                }.buttonStyle(.plain).piPointer().help(file.path)
                .accessibilityIdentifier("git-commit-file-" + file.path)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Unified or side-by-side diff rendered as file cards with hunk headers,
/// old/new line numbers and tinted added/removed rows.
struct DiffView: View {
    let files: [GitDiffFile]
    let title: String?
    let subtitle: String?
    var loading = false
    var embedded = false
    @Binding var split: Bool
    @State private var wrap = false
    private static let rowLimit = 1_500
    @State private var showAll = false

    var body: some View {
        Group {
            if embedded { content } else { ScrollView { content } }
        }
        .background(Color.piContent)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    if let subtitle { Text(subtitle).font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                PiTabs(selection: $split, items: [(false, "Unified"), (true, "Split")]).accessibilityIdentifier("git-diff-layout")
                Toggle("Wrap", isOn: $wrap).toggleStyle(.switch).controlSize(.mini).font(PiFont.micro)
            }.padding(.horizontal, PiSpacing.lg).padding(.top, embedded ? 0 : PiSpacing.lg)
            if files.isEmpty && !loading {
                Text("No textual changes.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.horizontal, PiSpacing.lg)
            }
            ForEach(files) { file in fileCard(file) }
            if files.reduce(0, { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count } }) > Self.rowLimit && !showAll {
                Button("Show the whole diff") { showAll = true }.buttonStyle(.piSecondaryCompact).padding(.horizontal, PiSpacing.lg)
            }
        }.padding(.bottom, PiSpacing.lg)
    }

    private func fileCard(_ file: GitDiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PiSpacing.sm) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Color.piInkSecondary)
                Text(file.renamed ? "\(file.oldPath) → \(file.newPath)" : file.path).font(PiFont.mono).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if file.added > 0 { Text("+\(file.added)").font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piSuccess) }
                if file.removed > 0 { Text("−\(file.removed)").font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piDanger) }
            }.padding(.horizontal, PiSpacing.md).padding(.vertical, 7).background(Color.piSurfaceSunken)
            ForEach(file.notes, id: \.self) { note in
                Text(note).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).padding(.horizontal, PiSpacing.md).padding(.vertical, 4)
            }
            let budget = showAll ? Int.max : Self.rowLimit
            var shown = 0
            ForEach(file.hunks) { hunk in
                if shown < budget {
                    Text(hunk.header).font(PiFont.mono).foregroundStyle(Color.piInfo).lineLimit(1)
                        .padding(.horizontal, PiSpacing.md).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).background(Color.piInfo.opacity(0.06))
                    if split {
                        ForEach(hunk.splitRows) { row in
                            let _ = { shown += 1 }()
                            if shown <= budget { splitRow(row) }
                        }
                    } else {
                        ForEach(hunk.lines) { line in
                            let _ = { shown += 1 }()
                            if shown <= budget { diffRow(line) }
                        }
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .padding(.horizontal, PiSpacing.lg)
    }

    private func tint(_ kind: GitDiffLine.Kind) -> Color {
        switch kind { case .added: .piSuccess; case .removed: .piDanger; case .context, .note: .clear }
    }

    private func diffRow(_ line: GitDiffLine) -> some View {
        let tint = tint(line.kind)
        let marker = switch line.kind { case .added: "+"; case .removed: "−"; case .context: " "; case .note: "\\" }
        return HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).padding(.trailing, 8)
            Text(marker).frame(width: 12, alignment: .center).foregroundStyle(line.kind == .context ? Color.piInkTertiary : tint)
            Text(line.text.isEmpty ? " " : line.text).lineLimit(wrap ? nil : 1).truncationMode(.tail).textSelection(.enabled)
                .foregroundStyle(line.kind == .note ? Color.piInkTertiary : Color.piInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(PiFont.mono)
        .foregroundStyle(Color.piInkTertiary)
        .padding(.vertical, 1).padding(.horizontal, PiSpacing.sm)
        .background(line.kind == .context || line.kind == .note ? Color.clear : tint.opacity(0.10))
    }

    /// Old text on the left, new text on the right; a blank half is a line that exists only on the other side.
    private func splitRow(_ row: GitSplitRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            splitHalf(row.left, number: row.left?.oldNumber, blank: row.left == nil)
            Rectangle().fill(Color.piHairline).frame(width: 1)
            splitHalf(row.right, number: row.right?.newNumber, blank: row.right == nil)
        }
        .font(PiFont.mono)
        .padding(.vertical, 1)
    }

    private func splitHalf(_ line: GitDiffLine?, number: Int?, blank: Bool) -> some View {
        let kind = line?.kind ?? .context
        let tint = tint(kind)
        return HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "").frame(width: 40, alignment: .trailing).padding(.trailing, 8).foregroundStyle(Color.piInkTertiary)
            Text(line.map { $0.text.isEmpty ? " " : $0.text } ?? " ").lineLimit(wrap ? nil : 1).truncationMode(.tail).textSelection(.enabled)
                .foregroundStyle(kind == .note ? Color.piInkTertiary : Color.piInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PiSpacing.sm)
        .background(blank ? Color.piFill.opacity(0.5) : kind == .context || kind == .note ? Color.clear : tint.opacity(0.10))
    }
}
