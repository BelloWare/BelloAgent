import SwiftUI
import AppKit

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
    @State private var panelWindow: NSWindow?
    /// The panel's own asker, so a question about discarding is only ever
    /// refused by another question about discarding.
    @StateObject private var questions = PiQuestion()

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
        .background(GitPanelWindowReader { panelWindow = $0 })
        .task { await controller.refresh() }
        .onDisappear { controller.stop(); questions.cancel() }
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
        PiMenuButton(title: controller.status.branch.isEmpty ? "detached" : controller.status.branch, icon: "arrow.triangle.branch",
                     identifier: "git-branch-menu") { [controller, _newBranchName, _showNewBranch] in
            let current = controller.status.branch
            PiMenuEntry.button("New Branch from \(current.isEmpty ? "HEAD" : current)…") { _newBranchName.wrappedValue = ""; _showNewBranch.wrappedValue = true }
            PiMenuEntry.divider
            for branch in controller.branches {
                PiMenuEntry.button(branch, enabled: branch != current, checked: branch == current) { Task { await controller.checkout(branch) } }
            }
        }
        .disabled(controller.busy)
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

    /// Fetch, pull and push carried no words: three arrows in a row, and the
    /// one that sends your commits to a shared remote looked exactly like the
    /// two that only read. They are named wherever the toolbar has room, and
    /// keep their counts and help when it does not.
    private var remoteControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                remoteButton("Fetch", symbol: "arrow.down.to.line", count: 0, help: "Fetch from every remote and prune") { await controller.fetch() }
                remoteButton("Pull", symbol: "arrow.down.circle", count: controller.status.behind,
                             help: controller.status.behind > 0 ? "Pull \(controller.status.behind) new commits (fast-forward only)" : "Pull (fast-forward only)") { await controller.pull() }
                remoteButton("Push", symbol: "arrow.up.circle", count: controller.status.ahead,
                             help: controller.status.ahead > 0 ? "Push \(controller.status.ahead) commits to \(controller.status.upstream ?? "the upstream")" : "Push") { await controller.push() }
            }
            HStack(spacing: 2) {
                PiIconButton(symbol: "arrow.down.to.line", label: "Fetch", size: 26) { Task { await controller.fetch() } }.help("Fetch from every remote and prune")
                PiIconButton(symbol: "arrow.down.circle", label: "Pull", size: 26) { Task { await controller.pull() } }
                    .help(controller.status.behind > 0 ? "Pull \(controller.status.behind) new commits (fast-forward only)" : "Pull (fast-forward only)")
                    .overlay(alignment: .topTrailing) { counter(controller.status.behind) }
                PiIconButton(symbol: "arrow.up.circle", label: "Push", size: 26) { Task { await controller.push() } }
                    .help(controller.status.ahead > 0 ? "Push \(controller.status.ahead) commits to \(controller.status.upstream ?? "the upstream")" : "Push")
                    .overlay(alignment: .topTrailing) { counter(controller.status.ahead) }
            }
        }.disabled(controller.busy)
    }
    private func remoteButton(_ title: String, symbol: String, count: Int, help: String, run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Label(count > 0 ? "\(title) \(count)" : title, systemImage: symbol)
        }
        .buttonStyle(.piSecondaryCompact).fixedSize().help(help)
        .accessibilityLabel(count > 0 ? "\(title), \(count) commits" : title)
        .accessibilityIdentifier("git-remote-" + title.lowercased())
    }
    @ViewBuilder private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.piOnAccent)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.piAccent, in: Capsule()).offset(x: 4, y: -4)
        }
    }

    private var stashMenu: some View {
        PiMenuButton(title: controller.stashes.isEmpty ? "Stash" : "Stash · \(controller.stashes.count)", icon: "tray.and.arrow.down",
                     identifier: "git-stash-menu") { [controller, _stashMessage, _showStash] in
            PiMenuEntry.button("Stash Changes…", enabled: !controller.status.entries.isEmpty) { _stashMessage.wrappedValue = ""; _showStash.wrappedValue = true }
            if !controller.stashes.isEmpty {
                PiMenuEntry.divider
                for stash in controller.stashes {
                    PiMenuEntry.button("Pop \(stash.name): \(stash.subject)") { Task { await controller.popStash(stash.name) } }
                }
            }
        }
        .disabled(controller.busy)
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
                        section("Staged · \(controller.staged.count)", paths: controller.stagedPaths, action: ("Unstage all", { Task { await controller.unstage(controller.staged.map(\.path)) } }))
                        ForEach(controller.staged) { entry in fileRow(entry, staged: true) }
                    }
                    if !controller.unstaged.isEmpty {
                        section("Changes · \(controller.unstaged.count)", paths: controller.unstagedPaths, action: ("Stage all", { Task { await controller.stage(controller.unstaged.map(\.path)) } }))
                        ForEach(controller.unstaged) { entry in fileRow(entry, staged: false) }
                    }
                }.padding(PiSpacing.sm)
            }
            Rectangle().fill(Color.piHairline).frame(height: 1)
            commitBox
        }
    }

    private func section(_ title: String, paths: Set<String>, action: (String, () -> Void)) -> some View {
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
            if !entry.untracked {
                Button("Show History of This File", systemImage: "clock.arrow.circlepath") { controller.showFileHistory(entry.path) }
                    .accessibilityIdentifier("git-file-history-" + entry.path)
            }
            Button("Reveal in Finder") { if let root = controller.repositoryRoot { NSWorkspace.shared.selectFile((root as NSString).appendingPathComponent(entry.path), inFileViewerRootedAtPath: root) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
        }
        .accessibilityIdentifier("git-file-" + entry.path)
    }

    /// Discard is the one irreversible action here, so it always confirms — on
    /// a sheet over the panel, never by stopping the main thread in a modal
    /// loop while git, the terminal and every other window wait.
    private func confirmDiscard(_ entries: [GitStatusEntry]) {
        GitDiscard.ask(questions, discarding: entries, in: panelWindow) { entries in
            Task { await controller.discard(entries) }
        }
    }

    private func badgeColor(_ badge: String) -> Color {
        switch badge { case "A", "U": .piSuccess; case "D": .piDanger; case "R", "C": .piInfo; default: .piBrandOrange }
    }

    private var commitBox: some View {
        let checkedCount = controller.checkedCount
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
                // A disabled Commit used to say only how many files were
                // ticked; the reader was left to guess that the empty message
                // was what stopped it. The line now names the missing step.
                Text(commitHint(checkedCount: checkedCount, message: message, nothing: nothing))
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { Task { await controller.commitChecked() } } label: { Label(controller.amend ? "Amend" : "Commit", systemImage: "checkmark.circle") }
                    .buttonStyle(.piPrimaryCompact).fixedSize()
                    .disabled(nothing || message.isEmpty || controller.loading || controller.busy)
                    .accessibilityIdentifier("git-commit")
            }
        }.padding(PiSpacing.md)
    }

    /// What the commit box is waiting for, in the order the reader has to
    /// supply it: something to commit, then a message.
    private func commitHint(checkedCount: Int, message: String, nothing: Bool) -> String {
        if nothing { return controller.amend ? "Reword the last commit" : "Tick the files to commit" }
        let what = checkedCount > 0 ? "\(checkedCount) of \(controller.status.entries.count) files"
            : controller.amend ? "Reword only" : "Staged index"
        return message.isEmpty ? what + " · write a message to commit" : what
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
                if let path = controller.logFilter.path {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(Color.piAccent)
                        Text((path as NSString).lastPathComponent).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).help(path)
                        Text("history · follows renames").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                        Spacer(minLength: 2)
                        Button("All files") { controller.clearFileHistory() }.buttonStyle(.piGhost).accessibilityIdentifier("git-history-all-files")
                    }
                    .padding(.horizontal, PiSpacing.sm).padding(.vertical, 4)
                    .background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                    .accessibilityIdentifier("git-history-path")
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
            if controller.logFilter.path != nil {
                Divider()
                Button("Show All Files Again", systemImage: "clock.arrow.circlepath") { controller.clearFileHistory() }
            }
        }
        .accessibilityIdentifier("git-commit-" + commit.shortHash)
    }

    // MARK: Detail

    @ViewBuilder private var detailPane: some View {
        if controller.panel == .changes {
            if let selection = controller.selection {
                DiffView(files: controller.diff, title: selection.path, subtitle: selection.staged ? "Staged · index versus HEAD" : "Working tree versus index",
                         identity: GitController.diffIdentity(path: selection.path, staged: selection.staged), loading: controller.diffLoading, split: $controller.splitDiff, expanded: $controller.wholeDiffShown)
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
                        if !detail.files.isEmpty {
                            HStack(spacing: 8) {
                                Text(detail.summary).font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                                if detail.commit.parents.count > 1 { PiBadge(text: "Merge · first parent", tone: .info, icon: "arrow.triangle.merge") }
                            }.accessibilityIdentifier("git-commit-summary")
                            GitCommitFileChips(detail: detail, selected: $controller.detailFile, shown: $controller.commitFilesShown,
                                               showHistory: { controller.showFileHistory($0) })
                        }
                    }.padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.lg)
                    if controller.detailDiffDeferred {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This commit changes \(detail.summary). Its files are listed above; open one to read its diff.")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                            Button("Show the whole diff") { controller.loadDeferredCommitDiff() }
                                .buttonStyle(.piSecondaryCompact).accessibilityIdentifier("git-commit-load-diff")
                        }.padding(.horizontal, PiSpacing.lg)
                    } else {
                        DiffView(files: controller.detailFile == nil ? controller.detailDiff : controller.detailFileDiff,
                                 title: controller.detailFile, subtitle: controller.detailFile == nil ? nil : "In \(detail.commit.shortHash)",
                                 identity: GitController.diffIdentity(commit: detail.commit.hash, file: controller.detailFile), loading: controller.commitLoading, embedded: true,
                                 split: $controller.splitDiff, expanded: $controller.wholeDiffShown)
                    }
                }
            }
        } else if controller.commitLoading {
            placeholder("Loading…")
        } else {
            placeholder("Select a commit to see what it changed.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The one irreversible action in the panel, and the question it asks first.
/// It goes on a sheet over the panel through the app's single sheet-question
/// mechanism, so a second right-click while it is up is dropped rather than
/// stacked and nothing stops the main thread.
@MainActor enum GitDiscard {
    static func ask(_ questions: PiQuestion, discarding entries: [GitStatusEntry], in window: NSWindow?,
                    then act: @escaping ([GitStatusEntry]) -> Void) {
        guard !entries.isEmpty, let window else { return }
        questions.ask(alert(for: entries), over: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            act(entries)
        }
    }

    static func alert(for entries: [GitStatusEntry]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Discard changes to \((entries[0].path as NSString).lastPathComponent)?" : "Discard changes to \(entries.count) files?"
        alert.informativeText = "Tracked files revert to HEAD and untracked files are deleted. Git keeps no copy of these changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

/// Hands the panel the window it is in, so a confirmation can be a sheet on it.
///
/// Told on the next turn of the run loop, and only when the window changes:
/// both `updateNSView` and a view moving into its window run inside SwiftUI's
/// update, and the panel keeps the window in its `@State` — writing that from
/// there, on every update of the panel, was a change made during a view update.
struct GitPanelWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.found = found; return view }
    func updateNSView(_ view: Reader, context: Context) { view.found = found; view.report() }
    @MainActor final class Reader: NSView {
        var found: ((NSWindow?) -> Void)?
        private weak var reported: NSWindow?
        private var reportedOnce = false
        private var scheduled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func report() {
            guard !scheduled, !reportedOnce || reported !== window else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard !self.reportedOnce || self.reported !== self.window else { return }
                self.reportedOnce = true; self.reported = self.window
                self.found?(self.window)
            }
        }
    }
}
