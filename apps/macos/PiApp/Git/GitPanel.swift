import SwiftUI
import AppKit
import GitView

/// The Changes sheet, laid out like IntelliJ's Git tool window: a branch
/// menu with fetch, pull, push and stash controls; a changelist with
/// checkboxes, amend and discard; the history with filters and ref badges;
/// and a unified or side-by-side diff of whatever is selected.
///
/// The panel observes its controller, and every change to it runs this body.
/// Each part below takes only the values it shows and compares on them, so a
/// file chosen, a character typed or a box ticked draws the parts that show
/// it and lets the others pass: the whole panel drawn again for each took a
/// fifth of a frame and more.
struct GitPanelView: View {
    @StateObject private var controller: GitController
    @PiDismiss private var dismiss
    @State private var panelWindow: NSWindow?
    /// The panel's own asker, so a question about discarding is only ever
    /// refused by another question about discarding.
    @StateObject private var questions = PiQuestion()

    init(roots: [String]) {
        _controller = StateObject(wrappedValue: GitController(roots: roots))
    }
    /// A panel over a controller made elsewhere: the tests that time the
    /// sheet drive its controller directly.
    init(controller: @autoclosure @escaping () -> GitController) {
        _controller = StateObject(wrappedValue: controller())
    }

    var body: some View {
        PiSheet("Changes", subtitle: subtitle, symbol: "arrow.triangle.branch", width: 1180, height: 780) {
            VStack(spacing: 0) {
                GitPanelToolbar(controller: controller, inputs: GitPanelToolbar.Inputs(controller)).equatable()
                Rectangle().fill(Color.piHairline).frame(height: 1)
                // The layout the panel keeps is there from its first frame. A
                // sheet whose first frame said "Not a git repository", in the
                // moment before its first read, reported layout cycles on every
                // update after the panel took its place, until it closed.
                if controller.statusRead && controller.repositoryRoot == nil && !controller.loading {
                    notARepository
                } else {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 340)
                        Rectangle().fill(Color.piHairline).frame(width: 1)
                        GitPanelDetail(controller: controller, inputs: GitPanelDetail.Inputs(controller)).equatable()
                    }
                }
            }
        } actions: {
            GitPanelActions(controller: controller, working: controller.loading || controller.busy,
                            close: { [dismiss] in dismiss() }).equatable()
        }
        .background(GitPanelWindowReader(found: { panelWindow = $0 }, closed: { [controller] in controller.letGo() }))
        .task { controller.opened(); await controller.refresh() }
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

    private var notARepository: some View {
        VStack(spacing: PiSpacing.sm) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 28)).foregroundStyle(Color.piInkTertiary)
            Text("Not a git repository").font(PiFont.title(17)).foregroundStyle(Color.piInk)
            Text("\(controller.displayRoot) is not inside a git repository. Run git init there, or choose another folder of this project.")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var sidebar: some View {
        if controller.panel == .changes {
            VStack(spacing: 0) {
                GitChangesList(controller: controller, inputs: GitChangesList.Inputs(controller), discard: discard).equatable()
                Rectangle().fill(Color.piHairline).frame(height: 1)
                GitCommitBox(controller: controller, inputs: GitCommitBox.Inputs(controller), discard: discard).equatable()
            }
        } else {
            GitHistoryList(controller: controller, inputs: GitHistoryList.Inputs(controller)).equatable()
        }
    }

    /// Discard is the one irreversible action here, so it always confirms — on
    /// a sheet over the panel, never by stopping the main thread in a modal
    /// loop while git, the terminal and every other window wait.
    private var discard: @MainActor ([GitStatusEntry]) -> Void {
        { [questions, controller, _panelWindow] entries in
            GitDiscard.ask(questions, discarding: entries, in: _panelWindow.wrappedValue) { entries in
                Task { await controller.discard(entries) }
            }
        }
    }
}

/// A panel part's `==`, on the main actor where its inputs live: the same
/// controller and the same inputs. Its actions go to the controller it was
/// made with, whatever closure was handed with it.
@MainActor private func samePart<Inputs: Equatable>(_ a: (GitController, Inputs), _ b: (GitController, Inputs)) -> Bool {
    a.0 === b.0 && a.1 == b.1
}

/// The spinner, Refresh and Done, at the sheet's top right. Compared as one
/// view, they are one view in the header's row: in a row of their own, spaced
/// as the header spaces its parts. Left loose, the header's row stood them
/// one above the other.
private struct GitPanelActions: View, Equatable {
    let controller: GitController
    let working: Bool
    let close: @MainActor () -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.working), (b.controller, b.working)) } }
    var body: some View {
        let _ = RedrawCounter.note("GitPanelActions")
        HStack(spacing: PiSpacing.md) {
            if working { PiSpinner(controlSize: .small) }
            PiIconButton(symbol: "arrow.clockwise", label: "Refresh changes", size: 28) { Task { await controller.refresh() } }
            Button("Done") { close() }.buttonStyle(.piSecondary)
        }
    }
}

// MARK: - Toolbar

/// The folder, the branch menu, fetch, pull and push, the stash menu, the
/// Changes and History tabs, and what the last action said.
private struct GitPanelToolbar: View, Equatable {
    struct Inputs: Equatable {
        var roots: [String], root: String?, displayRoot: String, repository: Bool
        var branch: String, upstream: String?, behind: Int, ahead: Int
        var stashes: Int, busy: Bool, panel: GitController.Panel, notice: String, lastCommit: String?
        @MainActor init(_ controller: GitController) {
            roots = controller.roots; root = controller.root; displayRoot = controller.displayRoot; repository = controller.repositoryRoot != nil
            branch = controller.status.branch; upstream = controller.status.upstream; behind = controller.status.behind; ahead = controller.status.ahead
            stashes = controller.stashes.count; busy = controller.busy; panel = controller.panel; notice = controller.notice; lastCommit = controller.lastCommit
        }
    }
    let controller: GitController
    let inputs: Inputs
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var stashMessage = ""
    @State private var showStash = false
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    var body: some View {
        let _ = RedrawCounter.note("GitPanelToolbar")
        HStack(spacing: PiSpacing.sm) {
            if inputs.roots.count > 1 {
                PiDropdown(selection: Binding(get: { controller.root ?? "" }, set: { controller.root = $0 }),
                           items: inputs.roots.map { ($0, ($0 as NSString).lastPathComponent) }, icon: "folder", compact: true)
            } else {
                Label(inputs.displayRoot, systemImage: "folder").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            if inputs.repository {
                branchMenu
                remoteControls
                stashMenu
            }
            PiTabs(selection: Binding(get: { controller.panel }, set: { controller.panel = $0 }), items: GitController.Panel.allCases.map { ($0, $0.title) })
            Spacer()
            if !inputs.notice.isEmpty { Text(inputs.notice).font(PiFont.caption).foregroundStyle(Color.piDanger).lineLimit(1).help(inputs.notice) }
            if let last = inputs.lastCommit { PiBadge(text: "Committed \(last)", tone: .success, icon: "checkmark") }
        }.padding(.horizontal, PiSpacing.lg).padding(.vertical, PiSpacing.sm)
    }

    /// IntelliJ's branch popup: the local branches to switch to, and a new branch from HEAD.
    private var branchMenu: some View {
        PiMenuButton(title: inputs.branch.isEmpty ? "detached" : inputs.branch, icon: "arrow.triangle.branch",
                     identifier: "git-branch-menu") { [controller, _newBranchName, _showNewBranch] in
            let current = controller.status.branch
            PiMenuEntry.button("New Branch from \(current.isEmpty ? "HEAD" : current)…") { _newBranchName.wrappedValue = ""; _showNewBranch.wrappedValue = true }
            PiMenuEntry.divider
            for branch in controller.branches {
                PiMenuEntry.button(branch, enabled: branch != current, checked: branch == current) { Task { await controller.checkout(branch) } }
            }
        }
        .disabled(inputs.busy)
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
                remoteButton("Pull", symbol: "arrow.down.circle", count: inputs.behind,
                             help: inputs.behind > 0 ? "Pull \(inputs.behind) new commits (fast-forward only)" : "Pull (fast-forward only)") { await controller.pull() }
                remoteButton("Push", symbol: "arrow.up.circle", count: inputs.ahead,
                             help: inputs.ahead > 0 ? "Push \(inputs.ahead) commits to \(inputs.upstream ?? "the upstream")" : "Push") { await controller.push() }
            }
            // Three 26-point buttons 2 apart: the size `ViewThatFits` measures,
            // with the buttons over it. Measured as buttons, they were built
            // afresh for every layout of the sheet, every frame of an
            // animation anywhere in it.
            Color.clear.frame(width: 3 * 26 + 2 * 2, height: 26).overlay {
                GitRemoteIconButtons(controller: controller, behind: inputs.behind, ahead: inputs.ahead, upstream: inputs.upstream)
            }
        }.disabled(inputs.busy)
    }
    private func remoteButton(_ title: String, symbol: String, count: Int, help: String, run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Label(count > 0 ? "\(title) \(count)" : title, systemImage: symbol)
        }
        .buttonStyle(.piSecondaryCompact).fixedSize().help(help)
        .accessibilityLabel(count > 0 ? "\(title), \(count) commits" : title)
        .accessibilityIdentifier("git-remote-" + title.lowercased())
    }

    private var stashMenu: some View {
        PiMenuButton(title: inputs.stashes == 0 ? "Stash" : "Stash · \(inputs.stashes)", icon: "tray.and.arrow.down",
                     identifier: "git-stash-menu") { [controller, _stashMessage, _showStash] in
            PiMenuEntry.button("Stash Changes…", enabled: !controller.status.entries.isEmpty) { _stashMessage.wrappedValue = ""; _showStash.wrappedValue = true }
            if !controller.stashes.isEmpty {
                PiMenuEntry.divider
                for stash in controller.stashes {
                    PiMenuEntry.button("Pop \(stash.name): \(stash.subject)") { Task { await controller.popStash(stash.name) } }
                }
            }
        }
        .disabled(inputs.busy)
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
}

/// Fetch, pull and push as three symbols, where the toolbar has no room for
/// their names: each keeps its count and its help.
private struct GitRemoteIconButtons: View {
    let controller: GitController
    let behind: Int, ahead: Int, upstream: String?
    var body: some View {
        let _ = RedrawCounter.note("GitRemoteIconButtons")
        HStack(spacing: 2) {
            PiIconButton(symbol: "arrow.down.to.line", label: "Fetch", size: 26) { Task { await controller.fetch() } }.help("Fetch from every remote and prune")
            PiIconButton(symbol: "arrow.down.circle", label: "Pull", size: 26) { Task { await controller.pull() } }
                .help(behind > 0 ? "Pull \(behind) new commits (fast-forward only)" : "Pull (fast-forward only)")
                .overlay(alignment: .topTrailing) { counter(behind) }
            PiIconButton(symbol: "arrow.up.circle", label: "Push", size: 26) { Task { await controller.push() } }
                .help(ahead > 0 ? "Push \(ahead) commits to \(upstream ?? "the upstream")" : "Push")
                .overlay(alignment: .topTrailing) { counter(ahead) }
        }
    }
    @ViewBuilder private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.piOnAccent)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.piAccent, in: Capsule()).offset(x: 4, y: -4)
        }
    }
}

// MARK: - Changes

/// A square that ticks, unticks, or shows some of a section ticked.
@MainActor private func gitCheckbox(on: Bool, mixed: Bool = false, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: on ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(on || mixed ? Color.piAccent : Color.piInkTertiary)
            .frame(width: 18, height: 18).contentShape(Rectangle())
    }.buttonStyle(.plain).piPointer().accessibilityLabel(label)
}

/// The changed files, staged first, each with its tick and its badge.
private struct GitChangesList: View, Equatable {
    struct Inputs: Equatable {
        var read: Bool, staged: [GitStatusEntry], unstaged: [GitStatusEntry], empty: Bool
        var checked: Set<String>, selection: GitController.Selection?
        @MainActor init(_ controller: GitController) {
            read = controller.statusRead; staged = controller.staged; unstaged = controller.unstaged; empty = controller.status.entries.isEmpty
            checked = controller.checked; selection = controller.selection
        }
    }
    let controller: GitController
    let inputs: Inputs
    let discard: @MainActor ([GitStatusEntry]) -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    var body: some View {
        let _ = RedrawCounter.note("GitChangesList")
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if inputs.read && inputs.empty {
                    Text("No changes. The working tree matches HEAD.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(PiSpacing.lg)
                }
                if !inputs.staged.isEmpty {
                    section("Staged · \(inputs.staged.count)", paths: controller.stagedPaths, action: ("Unstage all", { Task { await controller.unstage(controller.staged.map(\.path)) } }))
                    ForEach(inputs.staged) { entry in row(entry, staged: true) }
                }
                if !inputs.unstaged.isEmpty {
                    section("Changes · \(inputs.unstaged.count)", paths: controller.unstagedPaths, action: ("Stage all", { Task { await controller.stage(controller.unstaged.map(\.path)) } }))
                    ForEach(inputs.unstaged) { entry in row(entry, staged: false) }
                }
            }.padding(PiSpacing.sm)
        }
    }

    private func row(_ entry: GitStatusEntry, staged: Bool) -> some View {
        GitFileRow(controller: controller, entry: entry, staged: staged,
                   selected: inputs.selection == GitController.Selection(path: entry.path, staged: staged),
                   checked: inputs.checked.contains(entry.path), discard: discard).equatable()
    }

    private func section(_ title: String, paths: Set<String>, action: (String, () -> Void)) -> some View {
        let all = paths.isSubset(of: inputs.checked)
        return HStack(spacing: PiSpacing.sm) {
            gitCheckbox(on: all, mixed: !all && !paths.isDisjoint(with: inputs.checked), label: all ? "Uncheck \(title)" : "Check \(title)") {
                if all { controller.checked.subtract(paths) } else { controller.checked.formUnion(paths) }
            }
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            Spacer()
            Button(action.0, action: action.1).buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piAccent).piPointer()
        }.padding(.horizontal, PiSpacing.sm).padding(.top, PiSpacing.sm).padding(.bottom, 2)
    }
}

/// One changed file: its tick, its badge, its name and folder, and stage or
/// unstage. Drawn again only when one of those, or its selection, changes.
private struct GitFileRow: View, Equatable {
    let controller: GitController
    let entry: GitStatusEntry
    let staged: Bool
    let selected: Bool
    let checked: Bool
    let discard: @MainActor ([GitStatusEntry]) -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.controller === b.controller && a.entry == b.entry && a.staged == b.staged && a.selected == b.selected && a.checked == b.checked }
    }

    var body: some View {
        let _ = RedrawCounter.note("GitFileRow")
        let entry = entry, staged = staged, checked = checked, controller = controller
        PiSelectableRow(selected: selected, action: { controller.selection = GitController.Selection(path: entry.path, staged: staged) }) {
            HStack(spacing: PiSpacing.sm) {
                gitCheckbox(on: checked, label: checked ? "Exclude \(entry.path) from the commit" : "Include \(entry.path) in the commit") {
                    if checked { controller.checked.remove(entry.path) } else { controller.checked.insert(entry.path) }
                }.accessibilityIdentifier("git-check-" + entry.path)
                Text(entry.badge).font(PiFont.micro.weight(.bold)).foregroundStyle(Color.piOnAccent).frame(width: 18, height: 18)
                    .background(Self.badgeColor(entry.badge), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
            Button(entry.untracked ? "Delete Untracked File…" : "Discard Changes…") { discard([entry]) }
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

    static func badgeColor(_ badge: String) -> Color {
        switch badge { case "A", "U": .piSuccess; case "D": .piDanger; case "R", "C": .piInfo; default: .piBrandOrange }
    }
}

/// The commit message, amend, discard all, and Commit.
private struct GitCommitBox: View, Equatable {
    struct Inputs: Equatable {
        var message: String, amend: Bool, checkedCount: Int, stagedEmpty: Bool, entries: Int, loading: Bool, busy: Bool
        @MainActor init(_ controller: GitController) {
            message = controller.commitMessage; amend = controller.amend; checkedCount = controller.checkedCount
            stagedEmpty = controller.staged.isEmpty; entries = controller.status.entries.count; loading = controller.loading; busy = controller.busy
        }
    }
    let controller: GitController
    let inputs: Inputs
    let discard: @MainActor ([GitStatusEntry]) -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    var body: some View {
        let _ = RedrawCounter.note("GitCommitBox")
        let checkedCount = inputs.checkedCount
        let message = inputs.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let nothing = checkedCount == 0 && inputs.stagedEmpty && !inputs.amend
        let controller = controller
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            TextField(inputs.amend ? "Amended commit message" : "Commit message", text: Binding(get: { controller.commitMessage }, set: { controller.commitMessage = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(PiFont.body).lineLimit(2...5)
                .padding(PiSpacing.sm).piInset()
                .accessibilityIdentifier("git-commit-message")
            HStack(spacing: PiSpacing.sm) {
                gitCheckbox(on: inputs.amend, label: "Amend the last commit") { controller.amend.toggle() }.accessibilityIdentifier("git-amend")
                Text("Amend").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .help("Fold the checked files into the last commit and reword it.")
                Spacer()
                if inputs.entries > 0 {
                    Button("Discard All…") { discard(controller.status.entries) }.buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piDanger).piPointer()
                        .accessibilityIdentifier("git-discard-all")
                }
            }
            HStack(spacing: PiSpacing.sm) {
                // A disabled Commit used to say only how many files were
                // ticked; the reader was left to guess that the empty message
                // was what stopped it. The line now names the missing step.
                Text(hint(checkedCount: checkedCount, message: message, nothing: nothing))
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { Task { await controller.commitChecked() } } label: { Label(inputs.amend ? "Amend" : "Commit", systemImage: "checkmark.circle") }
                    .buttonStyle(.piPrimaryCompact).fixedSize()
                    .disabled(nothing || message.isEmpty || inputs.loading || inputs.busy)
                    .accessibilityIdentifier("git-commit")
            }
        }.padding(PiSpacing.md)
    }

    /// What the commit box is waiting for, in the order the reader has to
    /// supply it: something to commit, then a message.
    private func hint(checkedCount: Int, message: String, nothing: Bool) -> String {
        if nothing { return inputs.amend ? "Reword the last commit" : "Tick the files to commit" }
        let what = checkedCount > 0 ? "\(checkedCount) of \(inputs.entries) files"
            : inputs.amend ? "Reword only" : "Staged index"
        return message.isEmpty ? what + " · write a message to commit" : what
    }
}

// MARK: - History

/// The filters and the commits, newest first.
private struct GitHistoryList: View, Equatable {
    struct Inputs: Equatable {
        var filter: GitLogFilter, commits: [GitCommit], selected: GitCommit?, exhausted: Bool, loading: Bool
        @MainActor init(_ controller: GitController) {
            filter = controller.logFilter; commits = controller.commits; selected = controller.selectedCommit
            exhausted = controller.historyExhausted; loading = controller.loading
        }
    }
    let controller: GitController
    let inputs: Inputs
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    var body: some View {
        let _ = RedrawCounter.note("GitHistoryList")
        let controller = controller
        VStack(spacing: 0) {
            VStack(spacing: PiSpacing.xs) {
                PiTextField(placeholder: "Filter by message or hash", text: Binding(get: { controller.logFilter.text }, set: { controller.logFilter.text = $0 }), icon: "magnifyingglass")
                    .accessibilityIdentifier("git-history-filter")
                HStack(spacing: PiSpacing.sm) {
                    PiTextField(placeholder: "Author", text: Binding(get: { controller.logFilter.author }, set: { controller.logFilter.author = $0 }), icon: "person")
                    gitCheckbox(on: inputs.filter.allBranches, label: "Show all branches") { controller.logFilter.allBranches.toggle() }
                    Text("All branches").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize()
                }
                if let path = inputs.filter.path {
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
                    if inputs.commits.isEmpty && !inputs.loading {
                        Text(inputs.filter == GitLogFilter() ? "No commits yet." : "No commits match the filter.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(PiSpacing.lg)
                    }
                    ForEach(inputs.commits) { commit in
                        GitCommitRow(controller: controller, commit: commit, selected: inputs.selected == commit, filtered: inputs.filter.path != nil).equatable()
                    }
                    if !inputs.exhausted && !inputs.commits.isEmpty {
                        Button("Load older commits") { Task { await controller.loadMoreHistory() } }.buttonStyle(.piGhost).padding(PiSpacing.sm)
                    }
                }.padding(PiSpacing.sm)
            }
        }
    }
}

/// One commit: its subject, its refs, its hash, author and age.
private struct GitCommitRow: View, Equatable {
    let controller: GitController
    let commit: GitCommit
    let selected: Bool
    /// The history is one file's: the menu offers all files again.
    let filtered: Bool
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.controller === b.controller && a.commit == b.commit && a.selected == b.selected && a.filtered == b.filtered }
    }

    var body: some View {
        let _ = RedrawCounter.note("GitCommitRow")
        let controller = controller, commit = commit
        PiSelectableRow(selected: selected, action: { controller.selectedCommit = commit }) {
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
            if filtered {
                Divider()
                Button("Show All Files Again", systemImage: "clock.arrow.circlepath") { controller.clearFileHistory() }
            }
        }
        .accessibilityIdentifier("git-commit-" + commit.shortHash)
    }
}

// MARK: - Detail

/// The selected file's diff, or the selected commit: its header, its file
/// chips and its diff.
private struct GitPanelDetail: View, Equatable {
    struct Inputs: Equatable {
        var panel: GitController.Panel, selection: GitController.Selection?, diff: GitDiffArray, diffLoading: Bool
        var commit: String?, detailFiles: Int, detailFile: String?, filesShown: Int
        var detailDiff: GitDiffArray, detailFileDiff: GitDiffArray, commitLoading: Bool, deferred: Bool
        @MainActor init(_ controller: GitController) {
            panel = controller.panel; selection = controller.selection; diff = GitDiffArray(controller.diff); diffLoading = controller.diffLoading
            commit = controller.detail?.commit.hash; detailFiles = controller.detail?.files.count ?? 0
            detailFile = controller.detailFile; filesShown = controller.commitFilesShown
            detailDiff = GitDiffArray(controller.detailDiff); detailFileDiff = GitDiffArray(controller.detailFileDiff)
            commitLoading = controller.commitLoading; deferred = controller.detailDiffDeferred
        }
    }
    let controller: GitController
    let inputs: Inputs
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    /// The diff pane's content is a closure it runs later: everything it
    /// shows is taken now, into the closure. SwiftUI compares the closure by
    /// what it holds, and one that read the controller when it ran held the
    /// same controller and selection whatever the diff: a diff that arrived
    /// after the file was chosen was never drawn.
    var body: some View {
        let _ = RedrawCounter.note("GitPanelDetail")
        let controller = controller
        if inputs.panel == .changes {
            if let selection = inputs.selection {
                let files = inputs.diff.files, loading = inputs.diffLoading
                GitDiffPane(presentation: controller.presentation) { split, expanded in
                    DiffView(files: files, title: selection.path, subtitle: selection.staged ? "Staged · index versus HEAD" : "Working tree versus index",
                             identity: GitController.diffIdentity(path: selection.path, staged: selection.staged), loading: loading, split: split, expanded: expanded)
                }
            } else {
                placeholder("Select a file to see its changes.")
            }
        } else if let detail = controller.detail {
            if inputs.deferred {
                ScrollView {
                    VStack(alignment: .leading, spacing: PiSpacing.md) {
                        commitHeader(detail)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This commit changes \(detail.summary). Its files are listed above; open one to read its diff.")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                            Button("Show the whole diff") { controller.loadDeferredCommitDiff() }
                                .buttonStyle(.piSecondaryCompact).accessibilityIdentifier("git-commit-load-diff")
                        }.padding(.horizontal, PiSpacing.lg)
                    }
                }
            } else {
                // The commit's header scrolls away above its diff, as it did
                // when both were one SwiftUI stack.
                let file = inputs.detailFile, loading = inputs.commitLoading
                let files = file == nil ? inputs.detailDiff.files : inputs.detailFileDiff.files
                let lead = AnyView(commitHeader(detail).foregroundStyle(Color.piInk).buttonStyle(.piSecondary).toggleStyle(.piSwitch))
                let leadKey = CommitHeaderKey(commit: detail.commit.hash, files: detail.files.count, selected: file, shown: inputs.filesShown)
                GitDiffPane(presentation: controller.presentation) { split, expanded in
                    DiffView(files: files, title: file, subtitle: file == nil ? nil : "In \(detail.commit.shortHash)",
                             identity: GitController.diffIdentity(commit: detail.commit.hash, file: file), loading: loading, embedded: true,
                             lead: lead, leadKey: leadKey, split: split, expanded: expanded)
                }
            }
        } else if inputs.commitLoading {
            placeholder("Loading…")
        } else {
            placeholder("Select a commit to see what it changed.")
        }
    }

    /// A commit's subject, author, date and hash, the rest of its message,
    /// what it changed, and its files as chips.
    private func commitHeader(_ detail: GitCommitDetail) -> some View {
        let controller = controller
        return VStack(alignment: .leading, spacing: 4) {
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
                GitCommitFileChips(detail: detail, selected: Binding(get: { controller.detailFile }, set: { controller.detailFile = $0 }),
                                   shown: Binding(get: { controller.commitFilesShown }, set: { controller.commitFilesShown = $0 }),
                                   showHistory: { controller.showFileHistory($0) })
            }
        }.padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.lg)
    }
    /// What the commit header's height depends on, besides the width.
    private struct CommitHeaderKey: Hashable { let commit: String, files: Int, selected: String?, shown: Int }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A diff compared as the controller publishes it: a new array for every
/// read. Comparing the lines would walk them all.
struct GitDiffArray: Equatable {
    let files: [GitDiffFile]
    init(_ files: [GitDiffFile]) { self.files = files }
    static func == (a: Self, b: Self) -> Bool {
        a.files.withUnsafeBufferPointer { x in b.files.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress && x.count == y.count } }
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

/// Hands the panel the window it is in, so a confirmation can be a sheet on it,
/// and says when that sheet has closed for good.
///
/// Told on the next turn of the run loop, and only when the window changes:
/// both `updateNSView` and a view moving into its window run inside SwiftUI's
/// update, and the panel keeps the window in its `@State` — writing that from
/// there, on every update of the panel, was a change made during a view update.
///
/// `closed` runs once the sheet has left the screen, its closing animation
/// over, just before its window lets go of the panel (`PiSheetWindow`): the
/// controller lets go of what it read and stops watching at once, rather than
/// whenever the last task still holding it ends, and the panel is laid out
/// once more, emptied.
struct GitPanelWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    var closed: () -> Void = {}
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.found = found; view.closed = closed; return view }
    func updateNSView(_ view: Reader, context: Context) { view.found = found; view.closed = closed; view.report() }
    @MainActor final class Reader: NSView {
        var found: ((NSWindow?) -> Void)?
        var closed: (() -> Void)?
        private weak var reported: NSWindow?
        private var reportedOnce = false
        private var scheduled = false
        private weak var watched: NSWindow?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report(); watch(window) }
        private func watch(_ window: NSWindow?) {
            guard let window, window !== watched else { return }
            if let watched { NotificationCenter.default.removeObserver(self, name: PiSheetWindow.willRelease, object: watched) }
            watched = window
            NotificationCenter.default.addObserver(self, selector: #selector(sheetReleases(_:)), name: PiSheetWindow.willRelease, object: window)
        }
        @objc private func sheetReleases(_ note: Notification) {
            guard let window = note.object as? NSWindow, window === watched else { return }
            NotificationCenter.default.removeObserver(self, name: PiSheetWindow.willRelease, object: window)
            watched = nil
            closed?()
            // Laid out once more, off screen: SwiftUI drops the views that
            // showed what was read. Its layout pass does not come by itself
            // for a window that has left the screen.
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
        }
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
