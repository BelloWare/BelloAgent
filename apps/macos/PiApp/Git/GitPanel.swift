import SwiftUI
import AppKit
import GitView

/// A project's changes and history, laid out like IntelliJ's Git tool
/// window: a branch menu with fetch, pull, push and stash controls; a
/// changelist with checkboxes, amend and discard; the history with filters
/// and ref badges; and a unified or side-by-side diff of whatever is
/// selected. Shown in a tab beside the chats or in a window of its own
/// (`ChangesTab`), over a controller its tab keeps.
///
/// The panel observes its controller, and every change to it runs this body.
/// Each part below takes only the values it shows and compares on them, so a
/// file chosen, a character typed or a box ticked draws the parts that show
/// it and lets the others pass: the whole panel drawn again for each took a
/// fifth of a frame and more.
struct GitPanelView: View {
    @ObservedObject var controller: GitController
    /// Where the panel is, and the discard question it has up, if any: its
    /// tab's, so closing the tab takes the question down.
    @State private var place: GitPanelPlace
    /// The panel's own asker, so a question about discarding is only ever
    /// refused by another question about discarding.
    @StateObject private var questions: PiQuestion
    /// The project the panel shows, named in its header.
    let project: String?
    let openFile: ((String, Int) -> Void)?
    /// Optional layout observation for tests; no row geometry is read in the app.
    let observeFileRow: (@MainActor (String, CGRect) -> Void)?
    /// Wide enough for the list beside the diff; below this the list goes
    /// above it (`GitPanelSplit`). Set only when the panel's width crosses
    /// it, so resizing within one layout draws no part again.
    @State private var wide = true
    nonisolated static let wideWidth: CGFloat = 900

    init(controller: GitController, place: GitPanelPlace = GitPanelPlace(), questions: PiQuestion = PiQuestion(), project: String? = nil,
         openFile: ((String, Int) -> Void)? = nil, observeFileRow: (@MainActor (String, CGRect) -> Void)? = nil) {
        self.controller = controller; self.project = project; self.openFile = openFile; self.observeFileRow = observeFileRow
        _place = State(initialValue: place)
        _questions = StateObject(wrappedValue: questions)
    }

    var body: some View {
        VStack(spacing: 0) {
            GitPanelHeader(controller: controller, inputs: GitPanelHeader.Inputs(controller), project: project).equatable()
            GitPanelToolbar(controller: controller, inputs: GitPanelToolbar.Inputs(controller), wide: wide).equatable()
            Rectangle().fill(Color.piHairline).frame(height: 1)
            // The layout the panel keeps is there from its first frame. A
            // panel whose first frame said "Not a git repository", in the
            // moment before its first read, reported layout cycles on every
            // update after the panel took its place.
            if controller.statusRead && controller.repositoryRoot == nil && !controller.loading {
                notARepository
            } else {
                GitPanelSplit(wide: wide) {
                    sidebar
                    Rectangle().fill(Color.piHairline)
                    GitPanelDetail(controller: controller, inputs: GitPanelDetail.Inputs(controller), openFile: openFile).equatable()
                }
            }
        }
        .background(Color.piContent)
        .onGeometryChange(for: Bool.self, of: { $0.size.width >= Self.wideWidth }) { wide = $0 }
        // On screen or not, as the panel's own view is: the controller reads
        // and watches only while it is, and a discard question the panel has
        // up goes down, unanswered, when the panel goes or moves.
        .background(GitPanelPresence(place: place, shown: { [controller, place] shown in
            controller.setShown(shown)
            if !shown { place.cancelQuestion() }
        }, moved: { [place] in place.cancelQuestion() }))
        .accessibilityIdentifier("git-panel")
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
                GitChangesList(controller: controller, inputs: GitChangesList.Inputs(controller), discard: discard, observeFileRow: observeFileRow).equatable()
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
        { [questions, controller, place] entries in
            place.askToDiscard(entries, questions: questions) { entries in Task { await controller.discard(entries) } }
        }
    }
}

/// A panel part's `==`, on the main actor where its inputs live: the same
/// controller and the same inputs. Its actions go to the controller it was
/// made with, whatever closure was handed with it.
@MainActor private func samePart<Inputs: Equatable>(_ a: (GitController, Inputs), _ b: (GitController, Inputs)) -> Bool {
    a.0 === b.0 && a.1 == b.1
}

/// The list and the diff: side by side where the panel is wide, the list
/// 340 points wide; where it is narrow (the pane beside the chat), the list
/// above the diff, both the panel's width. One layout over the same three
/// parts either way, so the diff table, the lists and what they hold (the
/// wrap, where they were scrolled) stay the same views when the panel's
/// width crosses from one to the other.
struct GitPanelSplit: Layout {
    let wide: Bool
    static let listWidth: CGFloat = 340
    /// Narrow: how tall the list side is, of the `available` height (the
    /// panel's less the rule): 45% of it, never less than the side needs
    /// (`least`: its commit box or filters, and a few rows), and leaving the
    /// diff 180 points where that allows; at most all there is.
    static func listHeight(available: CGFloat, least: CGFloat) -> CGFloat {
        min(max((available * 0.45).rounded(), least), max(available - 180, least), available)
    }
    /// Three rows of the list, below the side's fixed parts.
    static let leastRows: CGFloat = 3 * 44
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else {
            for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
            return
        }
        let (list, rule, detail) = (subviews[0], subviews[1], subviews[2])
        if wide {
            let width = min(Self.listWidth, bounds.width)
            list.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
            rule.place(at: CGPoint(x: bounds.minX + width, y: bounds.minY), proposal: ProposedViewSize(width: 1, height: bounds.height))
            detail.place(at: CGPoint(x: bounds.minX + width + 1, y: bounds.minY), proposal: ProposedViewSize(width: max(0, bounds.width - width - 1), height: bounds.height))
        } else {
            // What the side cannot give up, a five-line commit message
            // included: its size when offered no height at all.
            let fixed = list.sizeThatFits(ProposedViewSize(width: bounds.width, height: 0)).height
            let height = Self.listHeight(available: max(0, bounds.height - 1), least: fixed + Self.leastRows)
            list.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: height))
            rule.place(at: CGPoint(x: bounds.minX, y: bounds.minY + height), proposal: ProposedViewSize(width: bounds.width, height: 1))
            detail.place(at: CGPoint(x: bounds.minX, y: bounds.minY + height + 1), proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - height - 1)))
        }
    }
}

/// The panel's head, as a file tab's is: the project, and what the
/// repository is at (its branch, what it tracks, how many files changed, what
/// is stashed); the spinner while the reader's read runs, and Refresh.
private struct GitPanelHeader: View, Equatable {
    struct Inputs: Equatable {
        var repository: Bool, branch: String, upstream: String?, changed: Int, stashes: Int, working: Bool
        @MainActor init(_ controller: GitController) {
            repository = controller.repositoryRoot != nil; branch = controller.status.branch; upstream = controller.status.upstream
            changed = controller.status.entries.count; stashes = controller.stashes.count; working = controller.loading || controller.busy
        }
    }
    let controller: GitController
    let inputs: Inputs
    let project: String?
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) && a.project == b.project }
    }
    var body: some View {
        let _ = RedrawCounter.note("GitPanelHeader")
        HStack(spacing: PiSpacing.sm) {
            HStack(spacing: 4) {
                if let project {
                    Text(project).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
                }
                Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
            }
            .help(subtitle)
            .accessibilityElement(children: .combine)
            Spacer(minLength: PiSpacing.sm)
            if inputs.working { PiSpinner(controlSize: .small) }
            PiIconButton(symbol: "arrow.clockwise", label: "Refresh changes", size: 26) { Task { await controller.refresh() } }
        }
        .padding(.horizontal, PiSpacing.md).frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
    }
    private var subtitle: String {
        guard inputs.repository else { return "Working-tree changes and history of the project's folders." }
        var parts = [inputs.branch.isEmpty ? "detached HEAD" : inputs.branch]
        if let upstream = inputs.upstream { parts.append("tracks \(upstream)") }
        parts.append("\(inputs.changed) changed")
        if inputs.stashes > 0 { parts.append("\(inputs.stashes) stashed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Toolbar

/// The folder, the branch menu, fetch, pull and push, the stash menu, the
/// Changes and History tabs, and what the last action said: one row where
/// the panel is wide; where it is narrow, the tabs and what the last action
/// said on a second row.
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
    let wide: Bool
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var stashMessage = ""
    @State private var showStash = false
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) && a.wide == b.wide } }

    var body: some View {
        let _ = RedrawCounter.note("GitPanelToolbar")
        // The folder, branch, remote and stash controls stay first in the
        // same row either way: their menus and popovers keep their places.
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.sm) {
                if inputs.roots.count > 1 {
                    PiDropdown(selection: Binding(get: { controller.root ?? "" }, set: { controller.root = $0 }),
                               items: inputs.roots.map { ($0, ($0 as NSString).lastPathComponent) }, icon: "folder", compact: true,
                               maxLabelWidth: wide ? nil : Self.narrowLabelWidth)
                    .help(wide ? "" : inputs.displayRoot)
                } else {
                    Label(inputs.displayRoot, systemImage: "folder").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .lineLimit(1).truncationMode(.middle).help(wide ? "" : inputs.displayRoot)
                }
                if inputs.repository {
                    branchMenu
                    remoteControls
                    stashMenu
                }
                if wide { panelTabs; Spacer(); outcome } else { Spacer(minLength: 0) }
            }
            if !wide {
                HStack(spacing: PiSpacing.sm) { panelTabs; Spacer(); outcome }
            }
        }.padding(.horizontal, PiSpacing.lg).padding(.vertical, PiSpacing.sm)
    }

    /// Where the panel is narrow, the longest a folder's or a branch's name
    /// is shown; the whole name is its help.
    static let narrowLabelWidth: CGFloat = 150

    private var panelTabs: some View {
        PiTabs(selection: Binding(get: { controller.panel }, set: { controller.panel = $0 }), items: GitController.Panel.allCases.map { ($0, $0.title) })
    }
    /// What the last action said: a failure, or the commit it made.
    @ViewBuilder private var outcome: some View {
        if !inputs.notice.isEmpty { Text(inputs.notice).font(PiFont.caption).foregroundStyle(Color.piDanger).lineLimit(1).help(inputs.notice) }
        if let last = inputs.lastCommit { PiBadge(text: "Committed \(last)", tone: .success, icon: "checkmark") }
    }

    /// IntelliJ's branch popup: the local branches to switch to, and a new branch from HEAD.
    private var branchMenu: some View {
        PiMenuButton(title: inputs.branch.isEmpty ? "detached" : inputs.branch, icon: "arrow.triangle.branch",
                     identifier: "git-branch-menu", maxLabelWidth: wide ? nil : Self.narrowLabelWidth) { [controller, _newBranchName, _showNewBranch] in
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
    var observeFileRow: (@MainActor (String, CGRect) -> Void)? = nil
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
                   checked: inputs.checked.contains(entry.path), discard: discard, observeFileRow: observeFileRow).equatable()
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
    var observeFileRow: (@MainActor (String, CGRect) -> Void)? = nil
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
        .background {
            if let observeFileRow {
                Color.clear.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    observeFileRow(entry.path, $0)
                }
            }
        }
    }

    static func badgeColor(_ badge: String) -> Color {
        switch badge { case "A", "U": .piSuccess; case "D": .piDanger; case "R", "C": .piInfo; default: .piBrandOrange }
    }
}

/// The commit message, what the commit takes (the checked files or the staged
/// index, always said, never inferred), amend, discard all, Reword Last
/// Commit and the commit itself.
struct GitCommitBox: View, Equatable {
    struct Inputs: Equatable {
        var message: String, amend: Bool, scope: GitCommitScope, checkedCount: Int, stagedCount: Int, entries: Int, hasHead: Bool, loading: Bool, busy: Bool
        @MainActor init(_ controller: GitController) {
            message = controller.commitMessage; amend = controller.amend; scope = controller.commitScope; checkedCount = controller.checkedCount
            stagedCount = controller.staged.count; entries = controller.status.entries.count; hasHead = controller.status.head != nil
            loading = controller.loading; busy = controller.busy
        }
    }
    let controller: GitController
    let inputs: Inputs
    let discard: @MainActor ([GitStatusEntry]) -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    /// What the box shows and allows for these inputs: the action's name,
    /// whether it and Reword are armed, and the line saying what the active
    /// scope takes. Kept apart from the drawing so it can be checked whole.
    struct Presentation: Equatable {
        var title: String, commitEnabled: Bool, rewordEnabled: Bool, hint: String
    }
    static func presentation(_ inputs: Inputs) -> Presentation {
        let message = inputs.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = inputs.scope == .checkedFiles ? inputs.checkedCount > 0 : inputs.stagedCount > 0
        let idle = !inputs.loading && !inputs.busy
        let title = switch (inputs.scope, inputs.amend) {
        case (.checkedFiles, false): "Commit Checked Files"
        case (.checkedFiles, true): "Amend with Checked Files"
        case (.stagedChanges, false): "Commit Staged Changes"
        case (.stagedChanges, true): "Amend with Staged Changes"
        }
        let hint: String
        switch inputs.scope {
        case .checkedFiles where !content:
            hint = "Tick the files to commit. Their whole working-tree state is committed, not only staged hunks."
        case .stagedChanges where !content:
            hint = "Nothing is staged. Stage changes, or commit checked files instead."
        case _ where inputs.amend && !inputs.hasHead:
            hint = "There is no commit to amend yet."
        default:
            let what = inputs.scope == .checkedFiles
                ? "\(inputs.checkedCount) of \(inputs.entries) files · their whole working-tree state"
                : "\(inputs.stagedCount) staged \(inputs.stagedCount == 1 ? "file" : "files") · exactly as staged; unstaged edits stay"
            hint = message.isEmpty ? what + " · write a message to commit" : what
        }
        return Presentation(title: title, commitEnabled: content && !message.isEmpty && idle && (!inputs.amend || inputs.hasHead),
                            rewordEnabled: inputs.hasHead && !message.isEmpty && idle, hint: hint)
    }

    var body: some View {
        let _ = RedrawCounter.note("GitCommitBox")
        let shown = Self.presentation(inputs)
        let controller = controller
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            TextField(inputs.amend ? "Amended commit message" : "Commit message", text: Binding(get: { controller.commitMessage }, set: { controller.commitMessage = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(PiFont.body).lineLimit(2...5)
                .padding(PiSpacing.sm).piInset()
                .accessibilityIdentifier("git-commit-message")
            PiTabs(selection: Binding(get: { controller.commitScope }, set: { controller.commitScope = $0 }),
                   items: [(GitCommitScope.checkedFiles, "Checked files"), (.stagedChanges, "Staged changes")])
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Commit scope")
                .accessibilityValue(inputs.scope == .checkedFiles ? "Checked files" : "Staged changes")
                .accessibilityIdentifier("git-commit-scope")
                // No glide: the switch changes the box's height (its hint and
                // title) while a write may change the list above it in the
                // same turn, and the animated resize of the hosting view never
                // settled — AppKit trapped on endless constraint passes
                // (gallery scene 10e). It looks the same, it only does not move.
                .transaction { $0.disablesAnimations = true; $0.animation = nil }
            HStack(spacing: PiSpacing.sm) {
                gitCheckbox(on: inputs.amend, label: "Amend the last commit") { controller.amend.toggle() }.accessibilityIdentifier("git-amend")
                Text("Amend").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .help("Add this commit's content to the last commit and replace its message.")
                Spacer()
                // Beside Amend, apart from the commit: a message-only change,
                // not one more way to commit content.
                Button("Reword Last Commit") { Task { await controller.rewordLastCommit() } }
                    .buttonStyle(.plain).font(PiFont.micro).foregroundStyle(shown.rewordEnabled ? Color.piAccent : Color.piInkTertiary).piPointer()
                    .lineLimit(1).fixedSize()
                    .disabled(!shown.rewordEnabled)
                    .help("Change the last commit's message only. Its files, and your staged and unstaged changes, stay as they are.")
                    .accessibilityIdentifier("git-reword")
                if inputs.entries > 0 {
                    Button("Discard All…") { discard(controller.status.entries) }.buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piDanger).piPointer()
                        .lineLimit(1).fixedSize()
                        .accessibilityIdentifier("git-discard-all")
                }
            }
            // Says what the active action takes, and what it still needs.
            Text(shown.hint)
                .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("git-commit-hint")
            HStack(spacing: PiSpacing.sm) {
                Spacer()
                Button { Task { await controller.commitInScope() } } label: { Label(shown.title, systemImage: "checkmark.circle") }
                    .buttonStyle(.piPrimaryCompact).fixedSize()
                    .disabled(!shown.commitEnabled)
                    .accessibilityIdentifier("git-commit")
            }
        }.padding(PiSpacing.md)
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
    let openFile: ((String, Int) -> Void)?
    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { samePart((a.controller, a.inputs), (b.controller, b.inputs)) } }

    /// The diff pane's content is a closure it runs later: everything it
    /// shows is taken now, into the closure. SwiftUI compares the closure by
    /// what it holds, and one that read the controller when it ran held the
    /// same controller and selection whatever the diff: a diff that arrived
    /// after the file was chosen was never drawn.
    var body: some View {
        let _ = RedrawCounter.note("GitPanelDetail")
        let controller = controller, openFile = openFile
        if inputs.panel == .changes {
            if let selection = inputs.selection {
                let files = inputs.diff.files, loading = inputs.diffLoading
                GitDiffPane(presentation: controller.presentation) { split, expanded in
                    DiffView(files: files, title: selection.path, subtitle: selection.staged ? "Staged · index versus HEAD" : "Working tree versus index",
                             identity: GitController.diffIdentity(path: selection.path, staged: selection.staged), loading: loading, split: split, expanded: expanded, openFile: openFile)
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
                             lead: lead, leadKey: leadKey, split: split, expanded: expanded, openFile: openFile)
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
    /// The question, up; nil when none was asked (nothing to discard, no
    /// window, or a question of this asker's already up).
    @discardableResult
    static func ask(_ questions: PiQuestion, discarding entries: [GitStatusEntry], in window: NSWindow?,
                    then act: @escaping ([GitStatusEntry]) -> Void) -> GitDiscardQuestion? {
        guard !entries.isEmpty, let window else { return nil }
        let alert = alert(for: entries), question = GitDiscardQuestion(alert: alert)
        let asked = questions.ask(alert, over: window) { [question] response in
            guard response == .alertFirstButtonReturn, !question.cancelled else { return }
            act(entries)
        }
        return asked ? question : nil
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

/// A discard question that is up. Taken down unanswered when the panel it is
/// about is hidden, moves or closes: nothing is discarded, whatever is
/// pressed after.
@MainActor final class GitDiscardQuestion {
    private let alert: NSAlert
    private(set) var cancelled = false
    init(alert: NSAlert) { self.alert = alert }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
    }
}

/// Where a panel is: the view of its that is in a window, read when asked,
/// and the discard question it has up.
@MainActor final class GitPanelPlace {
    /// The panel's view that is in a window (`GitPanelPresence`).
    weak var probe: NSView?
    /// The window the panel is in now.
    var window: NSWindow? { probe?.window }
    private(set) var question: GitDiscardQuestion?
    /// Asks, over the window the panel is in now (not the one it was in when
    /// last told: a tab moves between windows). A request refused because a
    /// question is already up keeps that question as the one to take down.
    func askToDiscard(_ entries: [GitStatusEntry], questions: PiQuestion, then act: @escaping ([GitStatusEntry]) -> Void) {
        if let asked = GitDiscard.ask(questions, discarding: entries, in: window, then: act) { question = asked }
    }
    func cancelQuestion() { question?.cancel(); question = nil }
}

/// Says whether the panel is on screen: in a window and not hidden there,
/// neither itself nor anything it is in (another tab shown over it, the
/// report over the tabs). Told on the next turn of the run loop, once for
/// whatever moved in between, and only when it changes: a view moving into
/// its window, and `updateNSView`, run inside SwiftUI's update, and a tab
/// moving between windows leaves one and joins another in the same turn.
struct GitPanelPresence: NSViewRepresentable {
    let place: GitPanelPlace
    let shown: (Bool) -> Void
    /// On screen before and after, but in another window: a question the
    /// panel had up is on the window it left.
    var moved: () -> Void = {}
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.shown = shown; view.moved = moved
        place.probe = view
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.shown = shown; view.moved = moved
        if place.probe !== view { place.probe = view }
        view.check()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.gone() }
    @MainActor final class Probe: NSView {
        var shown: ((Bool) -> Void)?
        var moved: (() -> Void)?
        private var told: Bool?
        /// The window it was on screen in, when last told.
        private weak var toldWindow: NSWindow?
        private var scheduled = false
        private var dismantled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); check() }
        override func viewDidHide() { super.viewDidHide(); check() }
        override func viewDidUnhide() { super.viewDidUnhide(); check() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// On screen now: in a window, and neither it nor anything it is in hidden.
        var onScreen: Bool { !dismantled && window != nil && !isHiddenOrHasHiddenAncestor }
        func check() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduled = false
                    let now = self.onScreen, window = now ? self.window : nil
                    defer { self.toldWindow = window }
                    if now, self.told == true, let before = self.toldWindow, before !== window { self.moved?() }
                    guard now != self.told else { return }
                    self.told = now
                    self.shown?(now)
                }
            }
        }
        /// The panel's view is gone for good: it is not on screen. Said on
        /// the next turn too: SwiftUI takes views down inside its own update,
        /// and a controller publishing from there broke its exclusive access.
        func gone() {
            dismantled = true
            guard told == true, let shown else { return }
            told = false
            DispatchQueue.main.async { MainActor.assumeIsolated { shown(false) } }
        }
    }
}
