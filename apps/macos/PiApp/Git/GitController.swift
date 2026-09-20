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
    @Published var root: String? { didSet { if root != oldValue { startRefresh() } } }
    @Published var repositoryRoot: String?
    @Published var panel = Panel.changes
    @Published private(set) var status = GitRepositoryStatus() { didSet { splitStatus() } }
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published var selection: Selection? { didSet { if selection != oldValue { startSelectedDiffLoad() } } }
    @Published private(set) var diff: [GitDiffFile] = []
    @Published private(set) var diffLoading = false
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var historyExhausted = false
    @Published var selectedCommit: GitCommit? {
        didSet {
            guard selectedCommit != oldValue else { return }
            changingCommit = true; detailFile = nil; changingCommit = false
            startCommitLoad()
        }
    }
    @Published private(set) var detail: GitCommitDetail?
    /// The selected commit's patch, parsed off the main thread and kept per
    /// commit, so moving through history never re-reads or re-parses one twice.
    @Published private(set) var detailDiff: [GitDiffFile] = []
    /// A big commit keeps its patch off screen until it is asked for.
    @Published private(set) var detailDiffDeferred = false
    @Published var commitMessage = ""
    @Published private(set) var lastCommit: String?
    /// Files ticked for the next commit (IntelliJ's changelist checkboxes).
    /// Everything is ticked the first time a repository is read; after that the
    /// set is the reader's, and unticking every file stays unticked across a
    /// refresh rather than silently re-arming the commit.
    @Published var checked: Set<String> = [] { didSet { if !applyingChecked { checkedByReader = true }; recountChecked() } }
    /// True once the reader has ticked or unticked anything themselves.
    private var checkedByReader = false
    private var applyingChecked = false
    private func applyChecked(_ value: Set<String>) { applyingChecked = true; checked = value; applyingChecked = false }
    @Published var amend = false { didSet { if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Task { await prefillHeadMessage() } } } }
    @Published private(set) var branches: [String] = []
    @Published private(set) var stashes: [GitStashEntry] = []
    @Published var logFilter = GitLogFilter() { didSet { if logFilter != oldValue { startHistoryReload() } } }
    @Published var detailFile: String? { didSet { if detailFile != oldValue && !changingCommit { startCommitLoad() } } }
    @Published private(set) var detailFileDiff: [GitDiffFile] = []
    @Published var splitDiff = false
    /// Which diff the reader asked to see in full. It names the diff, so the
    /// row gate comes back for the next file or commit instead of quietly
    /// staying open and laying out a whole 20,000-line patch.
    @Published var wholeDiffShown: String?
    /// How many of a commit's file chips are on screen. Reset for each commit.
    @Published var commitFilesShown = GitCommitFileChips.step
    /// Names one diff: the selected file, or a commit and the file chosen in it.
    static func diffIdentity(path: String, staged: Bool) -> String { "changes\u{1}\(path)\u{1}\(staged)" }
    static func diffIdentity(commit: String, file: String?) -> String { "commit\u{1}\(commit)\u{1}\(file ?? "")" }
    @Published private(set) var busy = false
    private let service: GitService
    private var generation = 0
    private var changingCommit = false
    /// One commit's reads, cancelled as soon as another commit is chosen.
    private var detailTask: Task<Void, Never>?
    /// The selected file's diff read, cancelled as soon as another file is chosen.
    private var selectedDiffTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    /// Watches the working tree so a file saved in an editor or a commit made
    /// in a terminal appears without the reader pressing Refresh.
    private var watcher: GitWorkingTreeWatcher?
    /// Refreshes the watch started, for tests.
    private(set) var automaticRefreshes = 0
    var isWatching: Bool { watcher?.isWatching == true }
    private var missedChange = false
    /// Refreshes the reader asked for that are still running. A refresh nobody
    /// asked for must never supersede one of theirs.
    private var readerRefreshes = 0
    private func drainMissedChange() {
        guard missedChange, !busy, readerRefreshes == 0, watcher != nil else { return }
        workingTreeChanged()
    }
    private struct CachedCommit { var detail: GitCommitDetail; var diff: [GitDiffFile]? = nil; var fileDiffs: [String: [GitDiffFile]] = [:] }
    private var commitCache: [String: CachedCommit] = [:]
    private var commitCacheOrder: [String] = []
    private static let commitCacheLimit = 24

    init(roots: [String], service: GitService = .shared) {
        self.service = service; self.roots = roots; self.root = roots.first
    }
    /// A panel that went away without saying so still leaves nothing running:
    /// the reads are cancelled here, and the watch's stream belongs to a box
    /// of its own that stops it when the last reference goes.
    deinit {
        refreshTask?.cancel(); historyTask?.cancel()
        detailTask?.cancel(); selectedDiffTask?.cancel()
    }

    var displayRoot: String { (root as NSString?)?.lastPathComponent ?? "" }
    /// Split once when the status is read. A repository with thousands of
    /// changed files must not be filtered again for every pass over the body.
    @Published private(set) var staged: [GitStatusEntry] = []
    @Published private(set) var unstaged: [GitStatusEntry] = []
    @Published private(set) var stagedPaths: Set<String> = []
    @Published private(set) var unstagedPaths: Set<String> = []
    /// How many of the changed files are ticked, counted when either side changes.
    @Published private(set) var checkedCount = 0
    private var allPaths: Set<String> = []
    private func splitStatus() {
        staged = status.entries.filter(\.staged)
        unstaged = status.entries.filter(\.unstaged)
        stagedPaths = Set(staged.map(\.path))
        unstagedPaths = Set(unstaged.map(\.path))
        allPaths = Set(status.entries.map(\.path))
        recountChecked()
    }
    private func recountChecked() {
        var count = 0
        if checked.count <= allPaths.count { for path in checked where allPaths.contains(path) { count += 1 } }
        else { for path in allPaths where checked.contains(path) { count += 1 } }
        checkedCount = count
    }

    /// Refreshes without waiting, replacing any refresh already in flight so
    /// its git processes stop instead of racing the new one.
    func startRefresh() { refreshTask?.cancel(); refreshTask = Task { await refresh() } }
    private func startHistoryReload() { historyTask?.cancel(); historyTask = Task { await reloadHistory() } }
    /// Stops every read this panel started. The sheet calls it as it closes, so
    /// no `git show` keeps computing a patch for a panel nobody can see.
    func stop() {
        generation += 1
        watcher?.stop(); watcher = nil
        refreshTask?.cancel(); refreshTask = nil
        historyTask?.cancel(); historyTask = nil
        detailTask?.cancel(); detailTask = nil
        selectedDiffTask?.cancel(); selectedDiffTask = nil
        loading = false; diffLoading = false
    }

    /// The working tree changed under the panel. The reader is not moved: the
    /// selection, the ticks, the scroll position and the whole-diff gate stay
    /// where they are, and a spinner does not appear for a read nobody asked
    /// for. Only a file that has actually gone stops being selected.
    private func workingTreeChanged() {
        // While the reader's own action is running, its refresh will see the
        // change; if it somehow does not, the change is picked up after it.
        guard !busy, readerRefreshes == 0 else { missedChange = true; return }
        missedChange = false
        automaticRefreshes += 1
        refreshTask?.cancel()
        refreshTask = Task { await refresh(automatic: true) }
    }
    private func updateWatch(on root: String?) {
        guard let root else { watcher?.stop(); watcher = nil; return }
        let resolved = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().path
        guard watcher?.root != resolved || watcher?.isWatching != true else { return }
        watcher?.stop()
        let watcher = GitWorkingTreeWatcher(root: root) { [weak self] in self?.workingTreeChanged() }
        watcher.start()
        self.watcher = watcher
    }

    func refresh(automatic: Bool = false) async {
        guard let root else { return }
        // Checked again here and not only where the task was made: the reader
        // may have started a refresh of their own in between, and theirs must
        // not be left half done with a spinner that never stops.
        if automatic, busy || readerRefreshes > 0 { missedChange = true; return }
        generation += 1; let generation = generation
        if !automatic { readerRefreshes += 1; loading = true; notice = "" }
        defer {
            if !automatic {
                readerRefreshes -= 1
                if readerRefreshes == 0 { loading = false; drainMissedChange() }
            }
        }
        let top = await service.repositoryRoot(of: root)
        guard self.generation == generation else { return }
        repositoryRoot = top
        updateWatch(on: top)
        guard let top else { status = GitRepositoryStatus(); diff = []; commits = []; selection = nil; selectedCommit = nil; detail = nil; return }
        do {
            let status = try await service.status(in: top)
            guard self.generation == generation else { return }
            self.status = status
            let paths = Set(status.entries.map(\.path))
            // Files arrive ticked until the reader says otherwise; once they
            // have, a refresh never ticks anything back on. Unticking every
            // file used to re-tick them all and re-arm the commit button.
            applyChecked(checkedByReader ? checked.intersection(paths) : paths)
            if let selection, !status.entries.contains(where: { $0.path == selection.path && ($0.staged == selection.staged || $0.unstaged == !selection.staged) }) { self.selection = nil }
            else if selection == nil { if !automatic, let first = status.entries.first { selection = Selection(path: first.path, staged: !first.unstaged && first.staged) } }
            else { await loadSelectedDiff() }
            async let branchList = service.branches(in: top)
            async let stashList = service.stashes(in: top)
            branches = (try? await branchList) ?? []; stashes = (try? await stashList) ?? []
            await reloadHistory(generation: generation, automatic: automatic)
        } catch is CancellationError {
        } catch { notice = error.localizedDescription }
    }

    private func reloadHistory(generation: Int? = nil, automatic: Bool = false) async {
        guard let repositoryRoot else { return }
        let generation = generation ?? self.generation
        do {
            let commits = try await service.log(in: repositoryRoot, limit: 50, path: logFilter.path, filter: logFilter)
            guard self.generation == generation else { return }
            self.commits = commits; historyExhausted = commits.count < 50
            // A commit pushed off the first page by newer ones is still the
            // commit the reader is reading; only a filter change drops it.
            if !automatic, let selectedCommit, !commits.contains(where: { $0.hash == selectedCommit.hash }) { self.selectedCommit = nil }
        // A read replaced by a newer one is not something to tell the reader
        // about: typing in the filter cancels one on every keystroke.
        } catch is CancellationError {
        } catch { notice = error.localizedDescription }
    }

    func loadMoreHistory() async {
        guard let repositoryRoot, !historyExhausted else { return }
        do {
            let more = try await service.log(in: repositoryRoot, limit: 50, skip: commits.count, path: logFilter.path, filter: logFilter)
            // A set, not a scan of every page already loaded: paging through a
            // long history was quadratic in the commits on screen.
            let known = Set(commits.map(\.hash))
            commits += more.filter { !known.contains($0.hash) }
            historyExhausted = more.count < 50
        } catch is CancellationError {
        } catch { notice = error.localizedDescription }
    }

    private func prefillHeadMessage() async {
        guard let repositoryRoot, let message = try? await service.headMessage(in: repositoryRoot) else { return }
        if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commitMessage = message }
    }

    private func perform(_ what: String, _ work: () async throws -> Void) async {
        busy = true; notice = ""
        defer { busy = false; drainMissedChange() }
        do { try await work() } catch is CancellationError { } catch { notice = "\(what): \(error.localizedDescription)" }
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

    /// Reads the selected file's diff, stopping the read the previous selection
    /// started. Clicking down a long list of changed files used to leave one
    /// `git diff` running per file, all of them computing patches nobody reads.
    func startSelectedDiffLoad() {
        selectedDiffTask?.cancel()
        guard let repositoryRoot, let selection else { diff = []; diffLoading = false; return }
        let entry = status.entries.first { $0.path == selection.path }
        // A rename is asked for under both names, or git sees a new file and
        // shows every one of its lines as added.
        let paths = [entry?.originalPath, selection.path].compactMap { $0 }
        diffLoading = true
        selectedDiffTask = Task { [service] in
            do {
                let files = try await service.diffFiles(in: repositoryRoot, paths: paths, staged: selection.staged, untracked: entry?.untracked == true)
                try Task.checkCancellation()
                guard self.selection == selection else { return }
                diff = files; diffLoading = false
            } catch is CancellationError {
            } catch {
                guard self.selection == selection else { return }
                notice = error.localizedDescription; diff = []; diffLoading = false
            }
        }
    }
    /// Waits for the selected file's diff; the panel itself never waits.
    private func loadSelectedDiff() async {
        startSelectedDiffLoad()
        await selectedDiffTask?.value
    }

    /// Shows whatever of this commit is already read, then fetches only what is
    /// missing. Choosing another commit cancels the reads of the last one, so a
    /// superseded `git show` is terminated instead of finishing into nothing.
    func startCommitLoad() {
        detailTask?.cancel()
        guard let repositoryRoot, let commit = selectedCommit else {
            detail = nil; detailDiff = []; detailFileDiff = []; detailDiffDeferred = false; diffLoading = false; return
        }
        if detail?.commit.hash != commit.hash { commitFilesShown = GitCommitFileChips.step }
        let file = detailFile, cached = commitCache[commit.hash]
        if let cached { detail = cached.detail } else if detail?.commit.hash != commit.hash { detail = nil }
        detailDiff = cached?.diff ?? []
        detailFileDiff = file.flatMap { cached?.fileDiffs[$0] } ?? []
        detailDiffDeferred = file == nil && cached?.diff == nil && (cached?.detail.isLarge ?? false)
        let needsDetail = cached == nil
        let needsDiff = file == nil ? (cached?.diff == nil && !(cached?.detail.isLarge ?? false)) : cached?.fileDiffs[file ?? ""] == nil
        guard needsDetail || needsDiff else { diffLoading = false; return }
        diffLoading = true
        detailTask = Task { [service] in
            do {
                var summary = cached?.detail
                if needsDetail {
                    let value = try await service.commitDetail(in: repositoryRoot, commit: commit)
                    try Task.checkCancellation()
                    guard selectedCommit?.hash == commit.hash else { return }
                    // The file list and message appear before any patch is read.
                    detail = value; summary = value
                    remember(CachedCommit(detail: value), for: commit.hash)
                    detailDiffDeferred = file == nil && value.isLarge
                }
                if file != nil || !(summary?.isLarge ?? false) {
                    let files = try await service.commitDiffFiles(in: repositoryRoot, commit: commit, path: file)
                    try Task.checkCancellation()
                    guard selectedCommit?.hash == commit.hash, detailFile == file else { return }
                    if let file { detailFileDiff = files; commitCache[commit.hash]?.fileDiffs[file] = files }
                    else { detailDiff = files; commitCache[commit.hash]?.diff = files }
                }
                diffLoading = false
            } catch is CancellationError {
            } catch {
                guard selectedCommit?.hash == commit.hash else { return }
                notice = error.localizedDescription; diffLoading = false
            }
        }
    }

    /// "Show the whole diff" for a commit whose patch was held back.
    func loadDeferredCommitDiff() {
        guard let commit = selectedCommit, detailFile == nil else { return }
        detailDiffDeferred = false
        detailTask?.cancel()
        guard let repositoryRoot else { return }
        diffLoading = true
        detailTask = Task { [service] in
            do {
                let files = try await service.commitDiffFiles(in: repositoryRoot, commit: commit, path: nil)
                try Task.checkCancellation()
                guard selectedCommit?.hash == commit.hash, detailFile == nil else { return }
                detailDiff = files; commitCache[commit.hash]?.diff = files; diffLoading = false
            } catch is CancellationError {
            } catch { notice = error.localizedDescription; diffLoading = false }
        }
    }

    /// History of one path, from a file in the changes list or in a commit.
    func showFileHistory(_ path: String) {
        panel = .history
        selectedCommit = nil
        logFilter.path = path
    }
    func clearFileHistory() { logFilter.path = nil }

    private func remember(_ entry: CachedCommit, for hash: String) {
        commitCache[hash] = entry
        commitCacheOrder.removeAll { $0 == hash }
        commitCacheOrder.append(hash)
        while commitCacheOrder.count > Self.commitCacheLimit, let oldest = commitCacheOrder.first {
            commitCacheOrder.removeFirst(); commitCache.removeValue(forKey: oldest)
        }
    }

    func stage(_ paths: [String]) async {
        guard let repositoryRoot else { return }
        do { try await service.stage(paths, in: repositoryRoot) } catch is CancellationError { } catch { notice = error.localizedDescription }
        await refresh()
    }
    func unstage(_ paths: [String]) async {
        guard let repositoryRoot else { return }
        do { try await service.unstage(paths, in: repositoryRoot) } catch is CancellationError { } catch { notice = error.localizedDescription }
        await refresh()
    }
    func commit() async {
        guard let repositoryRoot else { return }
        do {
            lastCommit = try await service.commit(message: commitMessage, in: repositoryRoot)
            commitMessage = ""
        } catch is CancellationError { } catch { notice = error.localizedDescription }
        await refresh()
    }
}
