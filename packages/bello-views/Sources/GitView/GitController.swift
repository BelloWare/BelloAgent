import Combine
import Foundation
import AppKit

/// The diff's layout and its whole-diff gate. Only the diff observes them.
@MainActor public final class GitDiffPresentation: ObservableObject {
    @Published public var split = false
    /// Which diff the reader asked to see in full. It names the diff, so the
    /// row gate comes back for the next file or commit.
    @Published public var whole: String?
    public init() {}
}

/// State for the Changes panel: which folder, its status, the selected file's
/// diff, the commit history and the selected commit. Reads run on GitService;
/// stage, unstage and commit are the only writes.
@MainActor public final class GitController: ObservableObject {
    public enum Panel: String, CaseIterable, Hashable { case changes, history
        public var title: String { self == .changes ? "Changes" : "History" }
    }
    public struct Selection: Equatable {
        public let path: String; public let staged: Bool
        public init(path: String, staged: Bool) { self.path = path; self.staged = staged }
    }

    /// A row's repository and reading. Kept by actions and confirmations so
    /// a same-named file in a later repository can never inherit the action.
    public struct RepositoryContext: Equatable, Sendable {
        public let root: String
        fileprivate let generation: Int
    }
    /// Repository-wide forms outlive status snapshots, but never a switch
    /// away and back. Rows keep their stricter RepositoryContext instead.
    public struct RepositoryIdentity: Equatable, Sendable {
        public let root: String
        fileprivate let lifetime = UUID()
    }
    @Published public private(set) var repositoryIdentity: RepositoryIdentity?
    private var identifiedFolder: String?
    private func identifyRepository(_ top: String?, folder: String?) {
        identifiedFolder = folder
        if repositoryIdentity?.root != top { repositoryIdentity = top.map { RepositoryIdentity(root: $0) } }
    }
    public func acceptsRepository(_ identity: RepositoryIdentity?) -> Bool { !suspended && sameRepositoryIdentity(identity) }
    private func sameRepositoryIdentity(_ identity: RepositoryIdentity?) -> Bool {
        guard let identity else { return false }
        return !closed && root == identifiedFolder && identity == repositoryIdentity
    }
    private func formRoot(_ identity: RepositoryIdentity?) -> String? {
        guard sameRepositoryIdentity(identity) else { notice = "The repository changed. Open the form again."; return nil }
        return identity?.root
    }
    public struct RepositorySnapshot: Equatable {
        public let context: RepositoryContext?
        public let status: GitRepositoryStatus
        public let read: Bool
        fileprivate let staged: [GitStatusEntry], unstaged: [GitStatusEntry]
        fileprivate let conflictCount: Int
        fileprivate let stagedPaths: Set<String>, unstagedPaths: Set<String>, paths: Set<String>
        fileprivate init(context: RepositoryContext? = nil, status: GitRepositoryStatus = GitRepositoryStatus(), read: Bool = false) {
            self.context = context; self.status = status; self.read = read
            staged = status.entries.filter(\.staged); unstaged = status.entries.filter(\.unstaged)
            conflictCount = status.entries.filter(\.conflicted).count
            stagedPaths = Set(staged.map(\.path)); unstagedPaths = Set(unstaged.map(\.path)); paths = Set(status.entries.map(\.path))
        }
    }
    @Published public private(set) var repository = RepositorySnapshot()
    public var repositoryContext: RepositoryContext? { repository.context }
    private var repositoryGeneration = 0

    /// Synchronous even when a refresh has not started yet. Returning to a
    /// folder does not revive a menu or question from its earlier reading.
    /// UI callbacks check before queuing a write; its entry checks again.
    public func accepts(_ context: RepositoryContext?) -> Bool { !suspended && sameRepository(context) }
    private func sameRepository(_ context: RepositoryContext?) -> Bool {
        guard let context else { return false }
        return !closed && context == repository.context && context.generation == repositoryGeneration
    }
    private func actionRoot(_ context: RepositoryContext?) -> String? {
        // A queued write may enter just after the panel hides. Hiding stops
        // reads; the write still belongs to this repository and generation.
        guard sameRepository(context) else { notice = "The repository changed. Choose the action again."; return nil }
        return context?.root
    }

    @Published public var roots: [String] = []
    @Published public var root: String? {
        didSet {
            guard root != oldValue else { return }
            folderGeneration += 1
            rememberInterruptedCommitRead()
            identifiedFolder = nil
            repositoryGeneration += 1
            stop()
            if root == nil { identifyRepository(nil, folder: nil) }
            // Another folder, perhaps another repository: a commit held for a
            // reveal in the last one, and a reveal still on its way, go.
            pinnedCommit = nil; revealTarget = nil; revealTokens += 1
            if suspended { needsFullRead = true }
            startRefresh()
        }
    }
    public var repositoryRoot: String? { repository.context?.root }
    /// Coming back to Changes brings up to date a diff that a refresh nobody
    /// asked for left unread while it was hidden.
    @Published public var panel = Panel.changes { didSet { if panel == .changes, oldValue != .changes, selectedDiffStale { startSelectedDiffLoad(silently: true) } } }
    public var status: GitRepositoryStatus { repository.status }
    @Published public private(set) var loading = false
    /// A read has said whether the folder is a repository and, when it is,
    /// what changed in it. Until then the panel keeps its own layout, empty,
    /// and says neither "Not a git repository" nor "No changes".
    public var statusRead: Bool { repository.read }
    @Published public private(set) var notice = ""
    @Published public var selection: Selection? { didSet { if selection != oldValue { startSelectedDiffLoad() } } }
    @Published public private(set) var diff: [GitDiffFile] = []
    /// The Changes diff is being read for the reader. A read nobody asked for
    /// never sets it, and the History tab's commit reads have a flag of their
    /// own: one flag for both panes flashed a spinner on the pane not reading.
    @Published public private(set) var diffLoading = false
    @Published public private(set) var commitLoading = false
    /// A refresh nobody asked for skipped the selected diff while History was showing.
    private var selectedDiffStale = false
    @Published public private(set) var commits: [GitCommit] = []
    @Published public private(set) var historyExhausted = false
    @Published public var selectedCommit: GitCommit? {
        didSet {
            guard selectedCommit != oldValue else { return }
            historyChoices += 1
            // Another commit chosen: the one a blame line asked for is no
            // longer held, and its line no longer the one to show.
            if selectedCommit?.hash != pinnedCommit { pinnedCommit = nil }
            if let reveal = revealTarget, selectedCommit?.hash != reveal.target.commit { revealTarget = nil }
            commitReadInterrupted = nil
            let before = historyChoices, hadFile = detailFile != nil
            changingCommit = true; detailFile = nil; changingCommit = false
            // The implicit file clear is part of choosing the commit. A
            // nested observer's file choice must keep its own revision.
            if hadFile, historyChoices == before + 1 { historyChoices = before }
            startCommitLoad()
        }
    }
    @Published public private(set) var detail: GitCommitDetail?
    /// The selected commit's patch, parsed off the main thread and kept per
    /// commit, so moving through history never re-reads or re-parses one twice.
    @Published public private(set) var detailDiff: [GitDiffFile] = []
    /// A big commit keeps its patch off screen until it is asked for.
    @Published public private(set) var detailDiffDeferred = false
    @Published public var commitMessage = "" {
        didSet {
            guard commitMessage != oldValue else { return }
            clearPreflight()
            messageGeneration += 1
            pendingAmendPrefill = nil
            messageOwner = root == identifiedFolder ? .repository(repositoryIdentity?.root) : .folder(root)
        }
    }
    /// Typing belongs to the selected folder, even while its status is on
    /// the way. Resolve that folder before discarding a draft on a switch;
    /// a second selection must not reclassify it as the previous draft.
    private enum DraftOwner { case repository(String?), folder(String?) }
    private var messageOwner: DraftOwner?
    private var messageGeneration = 0
    private var folderGeneration = 0
    @Published public private(set) var lastCommit: String?
    /// Files ticked for the next commit (IntelliJ's changelist checkboxes).
    /// Everything is ticked the first time a repository is read; after that the
    /// set is the reader's, and unticking every file stays unticked across a
    /// refresh rather than silently re-arming the commit.
    @Published public var checked: Set<String> = [] { didSet { if checked != oldValue { clearPreflight() }; if !applyingChecked { checkedByReader = true }; recountChecked() } }
    /// True once the reader has ticked or unticked anything themselves.
    private var checkedByReader = false
    private var applyingChecked = false
    private func applyChecked(_ value: Set<String>) { guard value != checked else { return }; applyingChecked = true; checked = value; applyingChecked = false }
    /// What Commit takes: the checked files, or the index as staged. Chosen by
    /// the reader and never switched by the checked set: unticking every file
    /// is not consent to commit the index.
    /// New/reopened panels start with the index. Explicit choices stay live
    /// across refreshes and actions; this setting has no persisted legacy value.
    public static let defaultCommitScope: GitCommitScope = .stagedChanges
    @Published public var commitScope: GitCommitScope = GitController.defaultCommitScope { didSet { if commitScope != oldValue { clearPreflight() } } }
    @Published public var signOff = false { didSet { if signOff != oldValue { clearPreflight() } } }
    @Published public private(set) var preflight: GitCommitPreflight?
    @Published public private(set) var preflightLoading = false
    private var preflightTask: Task<GitCommitPreflight, Error>?
    private var preflightGeneration = 0
    private func clearPreflight() {
        preflightGeneration += 1
        preflightTask?.cancel(); preflightTask = nil
        publish(\.preflightLoading, false); publish(\.preflight, nil)
    }
    private var pendingAmendPrefill: (folder: Int, edit: Int)?
    @Published public var amend = false {
        didSet {
            if amend != oldValue { clearPreflight() }
            pendingAmendPrefill = nil
            if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingAmendPrefill = (folderGeneration, messageGeneration)
                resumeAmendPrefill()
            }
        }
    }
    @Published public private(set) var branches: [String] = []
    @Published public private(set) var stashes: [GitStashEntry] = []
    public let history: GitHistoryState
    @Published public var historyOptions = GitHistoryOptions() { didSet { if historyOptions != oldValue { startHistoryReload() } } }
    @Published public var logFilter = GitLogFilter() { didSet { if logFilter != oldValue { startHistoryReload() } } }
    @Published public var detailFile: String? {
        didSet {
            if let reveal = revealTarget, !changingCommit, detailFile != reveal.target.path { revealTarget = nil }
            if detailFile != oldValue {
                historyChoices += 1
                if !changingCommit { commitReadInterrupted = nil; startCommitLoad() }
            }
        }
    }
    /// The commit a blame line asked for, held as the selection while it is
    /// read and through history reads that do not list it (a page not read,
    /// a filter that leaves it out), until the reader chooses another.
    private var pinnedCommit: String? { didSet { if pinnedCommit == nil { revealValid = nil } } }
    /// The asker's standing for the pinned commit, asked again before its
    /// reads are shown: lapsed, the reveal is dropped and nothing of it shown.
    private var revealValid: (@MainActor () -> Bool)?
    private func revealStillValid(_ hash: String) -> Bool {
        guard hash == pinnedCommit, let valid = revealValid else { return true }
        if valid() { return true }
        selectedCommit = nil
        return false
    }
    /// The line a blame click asked to see in its commit's diff, and a token
    /// told each time it is asked for, so the same line asked for again is
    /// shown again.
    @Published public private(set) var revealTarget: GitHistoryReveal? {
        didSet {
            if revealTarget?.token != oldValue?.token { revealNote = nil }
            // The reveal over (another file or commit chosen): the asker's
            // standing no longer governs what the reader reads.
            if revealTarget == nil { revealValid = nil }
        }
    }
    /// Why the line asked for is not shown selected in the diff, if it is not.
    @Published public private(set) var revealNote: String?
    /// What became of the line asked for, as the diff table says: shown, or
    /// why not — said, rather than leaving the diff's top on screen as if it
    /// were the line.
    public func revealed(_ reveal: GitDiffReveal, _ outcome: GitDiffRevealOutcome) {
        guard let target = revealTarget, reveal.token == target.token else { return }
        // Shown, or said why not: the reveal is done, and what is on screen
        // is the reader's from here.
        revealValid = nil
        let parents = selectedCommit?.parents.count ?? 1
        switch outcome {
        case .shown: revealNote = nil
        case .pastShownRows:
            revealNote = "Line \(target.target.line) is further down than the diff shows at first. Show the whole diff to reach it."
        case .pastReadLines:
            revealNote = "Line \(target.target.line) is past the part of this diff that can be read here (it is too long). Open the commit in a terminal or editor to see it."
        case .notInDiff:
            revealNote = parents > 1
                ? "Line \(target.target.line) of \(target.target.path) is not in this merge's diff against its first parent: the merge brought it in from another parent."
                : "Line \(target.target.line) of \(target.target.path) is not in this commit's diff."
        }
    }
    private var revealTokens = 0
    @Published public private(set) var detailFileDiff: [GitDiffFile] = []
    /// How the diff is laid out and which diff is shown whole, held apart
    /// from the state the panel observes: switching the layout, or opening
    /// the whole diff, redraws the diff and not the whole panel.
    /// How many of a commit's files are listed at first, and how many more
    /// each time more are asked for.
    public static let commitFilesStep = 200
    public let presentation = GitDiffPresentation()
    public var splitDiff: Bool { get { presentation.split } set { presentation.split = newValue } }
    /// Which diff the reader asked to see in full. It names the diff, so the
    /// row gate comes back for the next file or commit instead of quietly
    /// staying open and laying out a whole 20,000-line patch.
    public var wholeDiffShown: String? { get { presentation.whole } set { presentation.whole = newValue } }
    /// How many of a commit's file chips are on screen. Reset for each commit.
    @Published public var commitFilesShown = GitController.commitFilesStep
    /// Names one diff: the selected file, or a commit and the file chosen in it.
    public static func diffIdentity(path: String, staged: Bool) -> String { "changes\u{1}\(path)\u{1}\(staged)" }
    public static func diffIdentity(commit: String, file: String?) -> String { "commit\u{1}\(commit)\u{1}\(file ?? "")" }
    @Published public private(set) var busy = false
    private let service: GitService
    private var generation = 0
    private var changingCommit = false
    private var historyChoices = 0
    private func clearHistorySelection() {
        guard selectedCommit != nil else { return }
        let before = historyChoices
        selectedCommit = nil
        // Credit only this reset, never a reader choice made by a synchronous
        // observer of it. A pending blame reveal survives the former alone.
        if historyChoices == before + 1 { historyChoices = before }
    }
    /// One commit's reads, cancelled as soon as another commit is chosen.
    private var detailTask: Task<Void, Never>?
    /// The selected file's diff read, cancelled as soon as another file is chosen.
    private var selectedDiffTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    /// The next page of history being read, and which reading of the history
    /// it continues: a page for a history read again since (a refresh, a
    /// filter, the panel hidden) is dropped, not added behind the new one.
    private var pageTask: Task<Void, Never>?
    private var historyReading = 0
    /// Watches the working tree so a file saved in an editor or a commit made
    /// in a terminal appears without the reader pressing Refresh.
    private(set) var watcher: GitWorkingTreeWatcher?
    /// Refreshes the watch started, for tests.
    private(set) var automaticRefreshes = 0
    var isWatching: Bool { watcher?.isWatching == true }
    private var missedChange = GitWatchChanges()
    /// Refreshes the reader asked for that are still running. A refresh nobody
    /// asked for must never supersede one of theirs.
    private var readerRefreshes = 0
    private func drainMissedChange() {
        guard !missedChange.isEmpty, !busy, readerRefreshes == 0, watcher != nil else { return }
        let changes = missedChange; missedChange = GitWatchChanges()
        workingTreeChanged(changes)
    }
    private struct CachedCommit { var detail: GitCommitDetail; var diff: [GitDiffFile]? = nil; var fileDiffs: [String: [GitDiffFile]] = [:] }
    private var commitCache: [String: CachedCommit] = [:]
    private var commitCacheOrder: [String] = []
    private static let commitCacheLimit = 24

    public init(roots: [String], service: GitService = .shared) {
        self.service = service; self.history = GitHistoryState(service: service)
        self.roots = roots; self.root = roots.first
    }
    /// A panel that went away without saying so still leaves nothing running:
    /// the reads are cancelled here, and the watch's stream belongs to a box
    /// of its own that stops it when the last reference goes.
    deinit {
        refreshTask?.cancel(); historyTask?.cancel()
        detailTask?.cancel(); selectedDiffTask?.cancel()
    }

    public var displayRoot: String { (root as NSString?)?.lastPathComponent ?? "" }
    /// Split once when the status is read. A repository with thousands of
    /// changed files must not be filtered again for every pass over the body.
    public var staged: [GitStatusEntry] { repository.staged }
    public var unstaged: [GitStatusEntry] { repository.unstaged }
    public var conflictCount: Int { repository.conflictCount }
    public var stagedPaths: Set<String> { repository.stagedPaths }
    public var unstagedPaths: Set<String> { repository.unstagedPaths }
    /// How many of the changed files are ticked, counted when either side changes.
    @Published public private(set) var checkedCount = 0
    private var allPaths: Set<String> { repository.paths }
    private func recountChecked() {
        var count = 0
        if checked.count <= allPaths.count { for path in checked where allPaths.contains(path) { count += 1 } }
        else { for path in allPaths where checked.contains(path) { count += 1 } }
        publish(\.checkedCount, count)
    }
    /// Every assignment to a published property redraws the whole panel, even
    /// one that assigns what is already there: a refresh publishes what changed.
    private func publish<Value: Equatable>(_ property: ReferenceWritableKeyPath<GitController, Value>, _ value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }

    /// Refreshes without waiting, replacing any refresh already in flight so
    /// its git processes stop instead of racing the new one.
    public func startRefresh() { automaticRefresh = nil; automaticChangePending = GitWatchChanges(); refreshTask?.cancel(); refreshTask = Task { await refresh() } }
    private func startHistoryReload() { history.cancel(); historyTask?.cancel(); historyTask = Task { await reloadHistory() } }
    /// Stops every read this panel started. Hiding the panel stops them
    /// (`setShown`), so no `git show` keeps computing a patch for a panel
    /// nobody can see.
    public func stop() {
        history.cancel()
        clearPreflight()
        generation += 1
        pendingAmendPrefill = nil
        watcher?.stop(); watcher = nil
        refreshTask?.cancel(); refreshTask = nil; automaticRefresh = nil; automaticChangePending = GitWatchChanges()
        historyTask?.cancel(); historyTask = nil
        pageTask?.cancel(); pageTask = nil; historyReading += 1
        detailTask?.cancel(); detailTask = nil
        selectedDiffTask?.cancel(); selectedDiffTask = nil
        loading = false; diffLoading = false; commitLoading = false
    }

    /// The panel has closed for good. Whatever still holds the sheet's views
    /// holds this controller (in a test, XCTest does until the test returns),
    /// and a controller that kept what it had read held its diffs, its history
    /// and up to two dozen commits' patches with it. It goes back to how it
    /// was made: a panel that opens over it again reads everything afresh, as
    /// a first open does.
    public func letGo() {
        identifyRepository(nil, folder: nil)
        selectedCommit = nil
        selection = nil
        repositoryGeneration += 1; repository = RepositorySnapshot()
        diff = []; detail = nil; detailDiff = []; detailFileDiff = []; detailDiffDeferred = false
        commits = []; historyExhausted = false; branches = []; stashes = []
        commitCache = [:]; commitCacheOrder = []
        applyChecked([]); checkedByReader = false
        commitMessage = ""; amend = false; signOff = false; commitScope = Self.defaultCommitScope; lastCommit = nil; notice = ""
        selectedDiffStale = false; panel = .changes
        splitDiff = false; wholeDiffShown = nil; commitFilesShown = GitController.commitFilesStep
        logFilter = GitLogFilter()
        historyOptions = GitHistoryOptions(); history.reset()
        // Last: the resets above may have started reads of their own. A write
        // still running, whose refresh would read everything again, reads
        // nothing until a panel opens over this controller.
        stop()
        closed = true
        needsFullRead = false; commitReadInterrupted = nil
    }
    /// Let go of by a closed panel; see `letGo()`.
    private var closed = false
    /// A panel is on screen over this controller: it reads again.
    public func opened() { closed = false }

    /// Whether a panel over this controller is on screen (`setShown`).
    public private(set) var isShown = false
    /// Hidden after being shown: another tab over the panel, or the report
    /// over the tabs. A hidden panel reads nothing and watches nothing.
    public private(set) var suspended = false
    /// The folder changed while the panel was hidden: shown again, it is read
    /// as a first open reads it.
    private var needsFullRead = false
    /// Which of a commit's reads is running, and which one hiding or changing
    /// folders stopped: finished after a refresh, and kept until it has
    /// restarted, whatever comes and goes in between.
    private enum CommitRead { case commit, wholePatch }
    private var commitRead: CommitRead?
    /// Another folder can be in the same repository. Keep its interrupted
    /// read by repository, commit and file, not by the invalidated row token.
    private var commitReadInterrupted: (read: CommitRead, root: String, commit: String, file: String?)?
    private func rememberInterruptedCommitRead() {
        guard commitLoading, let commitRead, let repositoryRoot, let hash = selectedCommit?.hash else { return }
        commitReadInterrupted = (commitRead, repositoryRoot, hash, detailFile)
    }
    /// How many times the panel has come or gone, for tests.
    private(set) var shownChanges = 0
    /// Reads of the working tree that finished current, for tests.
    private(set) var refreshesFinished = 0

    /// Whether a panel over this controller is on screen, as the panel says
    /// when it comes and goes.
    ///
    /// Shown for the first time, or again after `letGo()`, it reads with a
    /// spinner, and the first file
    /// chosen. Shown again after being hidden, it reads what changed
    /// meanwhile quietly: the selection, the ticks, the history paged in and
    /// the commit being read stay as they were, and a commit's read that
    /// hiding stopped is finished. Hidden, every read and the watch stop; a
    /// write already running finishes, and what it changed is read when the
    /// panel is shown. A panel hidden from the start (made under the report)
    /// is hidden too: nothing reads, not even a folder chosen meanwhile.
    public func setShown(_ shown: Bool) {
        guard shown != isShown || (shown && closed) || (!shown && !suspended) else { return }
        isShown = shown
        shownChanges += 1
        if shown {
            let reopened = closed
            closed = false; suspended = false
            if !statusRead || needsFullRead || reopened { needsFullRead = false; startRefresh() } else { startQuietRefresh() }
        } else {
            rememberInterruptedCommitRead()
            // Hidden after being shown: the reader left, and a reveal still on
            // its way is dropped rather than landing when they come back.
            revealTokens += 1
            suspended = true
            stop()
        }
    }
    /// What changed while the panel was hidden, read without moving the
    /// reader; then the commit's read that hiding stopped, if there was one.
    private func startQuietRefresh() {
        automaticRefresh = nil; automaticChangePending = GitWatchChanges()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh(automatic: true) }
    }
    /// After a read of the working tree that finished while the panel shows,
    /// whichever read it was (the one showing started, or one the watch
    /// started in its place): the interrupted read, if it is still for the
    /// repository, commit and file chosen.
    private func resumeInterruptedCommitRead() {
        guard let interrupted = commitReadInterrupted, !suspended, !closed else { return }
        commitReadInterrupted = nil
        guard repositoryRoot == interrupted.root, selectedCommit?.hash == interrupted.commit, detailFile == interrupted.file else { return }
        switch interrupted.read {
        case .commit: startCommitLoad()
        case .wholePatch: loadDeferredCommitDiff()
        }
    }
    /// Test seam: commits whose reads are kept for moving back to them.
    var cachedCommits: Int { commitCache.count }

    /// The working tree changed under the panel. The reader is not moved: the
    /// selection, the ticks, the scroll position and the whole-diff gate stay
    /// where they are, and a spinner does not appear for a read nobody asked
    /// for. Only a file that has actually gone stops being selected.
    private func workingTreeChanged(_ changes: GitWatchChanges) {
        guard changes.isInteresting(ignoring: watcher?.ignored) else { return }
        // While the reader's own action is running, its refresh will see the
        // change; if it somehow does not, the change is picked up after it.
        guard !busy, readerRefreshes == 0 else { missedChange.formUnion(changes); return }
        missedChange = GitWatchChanges()
        // A refresh already under way is let finish, and whatever changed
        // during it is rechecked against the ignored paths it learned.
        // Cancelling it on every change meant a repository whose refresh
        // outlasts the watcher's one-second interval never finished one.
        if automaticRefresh != nil { automaticChangePending.formUnion(changes); return }
        automaticRefreshes += 1
        let token = UUID(); automaticRefresh = token; automaticChangePending = GitWatchChanges()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh(automatic: true)
            guard let self, self.automaticRefresh == token else { return }
            self.automaticRefresh = nil
            let pending = self.automaticChangePending; self.automaticChangePending = GitWatchChanges()
            if !Task.isCancelled { self.workingTreeChanged(pending) }
        }
    }
    /// A test seam: how long each status read takes on top of git's own time.
    nonisolated(unsafe) static var statusReadDelay: Duration = .zero
    /// Holds a completed status snapshot in tests while the working tree changes.
    var statusDidRead: (@MainActor () async throws -> Void)?
    var headMessageDidRead: (@MainActor () async -> Void)?
    /// The automatic refresh under way, and the events queued during it.
    private var automaticRefresh: UUID?
    private var automaticChangePending = GitWatchChanges()
    /// Pending reads and deliveries, so fixtures can hold the exact race.
    var isAutomaticallyRefreshing: Bool { automaticRefresh != nil }
    var hasPendingAutomaticChange: Bool { !automaticChangePending.isEmpty }
    var hasMissedChange: Bool { !missedChange.isEmpty }
    private func updateWatch(on root: String?) {
        guard let root else { watcher?.stop(); watcher = nil; return }
        let resolved = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().path
        guard watcher?.root != resolved || watcher?.isWatching != true else { return }
        watcher?.stop()
        let watcher = GitWorkingTreeWatcher(root: root) { [weak self] changes in self?.workingTreeChanged(changes) }
        if repositoryRoot == root { watcher.ignored.preserve(root: watcher.root, entries: status.entries) }
        watcher.start()
        self.watcher = watcher
    }

    public func refresh(automatic: Bool = false) async {
        // Hidden or let go of: nothing is read, and the watch stays off. A
        // hidden panel is read again when it is shown (`setShown`).
        guard let root, !closed, !suspended else { return }
        // Checked again here and not only where the task was made: the reader
        // may have started a refresh of their own in between, and theirs must
        // not be left half done with a spinner that never stops.
        if automatic, busy || readerRefreshes > 0 { missedChange.formUnion(.unknown); return }
        generation += 1; let generation = generation
        if !automatic { readerRefreshes += 1; loading = true; notice = "" }
        defer {
            if !automatic {
                readerRefreshes -= 1
                if readerRefreshes == 0 { loading = false; drainMissedChange() }
            }
        }
        let top = await service.repositoryRoot(of: root)
        // A stopped read of the top level reads as "no repository": only a
        // refresh still current may say so.
        guard current(generation) else { return }
        identifyRepository(top, folder: root)
        guard current(generation), !closed, !suspended else { return }
        guard let top else {
            guard await resolveDraftOwner(top: nil, folder: root, generation: generation) else { return }
            guard publishRepository(nil, status: GitRepositoryStatus(), generation: generation) else { return }
            updateWatch(on: nil)
            publish(\.diff, []); publish(\.commits, [])
            publish(\.selection, nil); publish(\.selectedCommit, nil); publish(\.detail, nil); return
        }
        // SinceNow cannot recover a save made before the stream starts. Arm
        // it before Git reads; events during this refresh are drained after it.
        guard current(generation), !closed, !suspended else { return }
        updateWatch(on: top)
        do {
            // A refresh publishes only what changed: the watch refreshes on
            // every save, and reassigning the same status, history and diff
            // redrew the whole panel each time.
            // A test seam, zero in the app: a repository slow to read.
            if Self.statusReadDelay > .zero { try? await Task.sleep(for: Self.statusReadDelay); guard !Task.isCancelled else { return } }
            let status = try await service.status(in: top)
            try await statusDidRead?()
            guard current(generation) else { return }
            guard await resolveDraftOwner(top: top, folder: root, generation: generation) else { return }
            let previousSelection = selection
            guard publishRepository(top, status: status, generation: generation) else { return }
            let paths = Set(status.entries.map(\.path))
            // Files arrive ticked until the reader says otherwise; once they
            // have, a refresh never ticks anything back on. Unticking every
            // file used to re-tick them all and re-arm the commit button.
            applyChecked(checkedByReader ? checked.intersection(paths) : paths)
            // A repository reset clears the old diff before publishing its
            // rows. Keep a matching choice, but a missing choice stays empty:
            // clearing it is not consent to select the new first row.
            if let chosen = selection ?? previousSelection {
                if !status.entries.contains(where: { $0.path == chosen.path && ($0.staged == chosen.staged || $0.unstaged == !chosen.staged) }) { selection = nil }
                else if selection == nil { selection = chosen }
                // A read nobody asked for shows no spinner, and a diff nobody
                // can see waits until Changes is showing again.
                else if !automatic || panel == .changes { await loadSelectedDiff(silently: automatic) }
                else { selectedDiffStale = true }
            } else if !automatic, let first = status.entries.first { selection = Selection(path: first.path, staged: !first.unstaged && first.staged) }
            async let branchList = service.branches(in: top)
            async let stashList = service.stashes(in: top)
            async let ignoredList = service.ignoredPaths(in: top)
            // Reads cancelled because this refresh was replaced are not empty
            // lists: taking them for that blanked the branch menu and the
            // stash count until the next refresh landed, several times a
            // minute while the agent edits files with Changes open.
            var branches: [String] = [], stashes: [GitStashEntry] = []
            do { branches = try await branchList } catch is CancellationError { return } catch {}
            do { stashes = try await stashList } catch is CancellationError { return } catch {}
            let ignored = try? await ignoredList
            guard current(generation) else { return }
            if let ignored, let watcher, watcher.root == URL(fileURLWithPath: top, isDirectory: true).resolvingSymlinksInPath().path {
                watcher.ignored.update(root: watcher.root, relative: ignored)
            }
            publish(\.branches, branches); publish(\.stashes, stashes)
            await reloadHistory(generation: generation, automatic: automatic)
            if current(generation) { refreshesFinished += 1; resumeInterruptedCommitRead() }
        } catch is CancellationError {
        } catch { if current(generation) { notice = error.localizedDescription } }
    }

    /// Whether the refresh or read that took `generation` is still the one the
    /// panel wants: not replaced by a newer one and not cancelled. Whatever it
    /// read, or failed to read because it was stopped, it keeps to itself.
    private func current(_ generation: Int) -> Bool { !Task.isCancelled && self.generation == generation }

    private func resolveDraftOwner(top: String?, folder: String, generation: Int) async -> Bool {
        while case .folder(let owner) = messageOwner {
            let edit = messageGeneration
            let resolved: String?
            if owner == folder { resolved = top }
            else if let owner { resolved = await service.repositoryRoot(of: owner) }
            else { resolved = nil }
            guard current(generation), !closed, !suspended else { return false }
            // The reader may have typed while the earlier folder resolved.
            guard edit == messageGeneration else { continue }
            messageOwner = .repository(resolved)
        }
        return current(generation) && !closed && !suspended
    }

    private func publishRepository(_ root: String?, status: GitRepositoryStatus, generation: Int) -> Bool {
        guard current(generation), !closed, !suspended else { return false }
        guard !repository.read || repositoryRoot != root || self.status != status || (root != nil && repository.context?.generation != repositoryGeneration) else { return true }
        if repository.read, case .repository(let owner) = messageOwner, owner != root { commitMessage = "" }
        guard current(generation), !closed, !suspended else { return false }
        let changedRepository = repositoryRoot != root
        if changedRepository {
            commitReadInterrupted = nil
            selection = nil; clearHistorySelection()
            diff = []; commits = []; branches = []; stashes = []
            commitCache = [:]; commitCacheOrder = []; historyExhausted = false
            checkedByReader = false; applyChecked([])
            if repository.read {
                amend = false; signOff = false; lastCommit = nil
            }
        }
        // Published resets notify synchronously: an observer may select yet
        // another repository or hide the panel before this assignment.
        guard current(generation), !closed, !suspended else { return false }
        clearPreflight()
        repositoryGeneration += 1
        if let root, let watcher, watcher.root == URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().path {
            watcher.ignored.preserve(root: watcher.root, entries: status.entries)
        }
        repository = RepositorySnapshot(context: root.map { RepositoryContext(root: $0, generation: repositoryGeneration) }, status: status, read: true)
        recountChecked()
        // The snapshot's observers can stop us too. Nothing may restart the
        // watcher or a diff read after that stop.
        guard current(generation), !closed, !suspended else { return false }
        // A branch belongs to the confirmed repository, unlike text/author/
        // path filters. Publish the new snapshot before changing the filter
        // because its observer schedules a history read against that snapshot.
        if changedRepository, historyOptions.reference != nil { historyOptions.reference = nil }
        guard current(generation), !closed, !suspended else { return false }
        resumeAmendPrefill()
        return true
    }

    private func reloadHistory(generation: Int? = nil, automatic: Bool = false) async {
        guard let repositoryRoot, !closed, !suspended else { return }
        let generation = generation ?? self.generation
        let query = GitHistoryQuery(filter: logFilter, options: historyOptions)
        guard await history.reload(in: repositoryRoot, query: query, preservingCount: automatic),
              current(generation), !closed, !suspended, self.repositoryRoot == repositoryRoot,
              query == GitHistoryQuery(filter: logFilter, options: historyOptions) else { return }
        let reading = history.reading
        historyReading += 1; pageTask?.cancel(); pageTask = nil
        publish(\.commits, reading.commits); publish(\.historyExhausted, reading.next == nil)
        if !automatic, let selectedCommit, selectedCommit.hash != pinnedCommit,
           !reading.commits.contains(where: { $0.hash == selectedCommit.hash }) { clearHistorySelection() }
    }

    public func loadMoreHistory() async {
        guard let repositoryRoot, !closed, !suspended,
              history.reading.snapshot?.root == repositoryRoot else { return }
        guard await history.loadMore(), !closed, !suspended, self.repositoryRoot == repositoryRoot else { return }
        publish(\.commits, history.reading.commits)
        publish(\.historyExhausted, history.reading.next == nil)
    }

    /// Every explicit row choice retires pending blame navigation, even when
    /// the same commit is already selected. List choices remain filter-bound.
    public func chooseHistoryCommit(_ commit: GitCommit) {
        guard !closed, !suspended, acceptsRepository(repositoryIdentity) else { return }
        historyChoices += 1; revealTokens += 1
        pinnedCommit = nil; revealTarget = nil
        selectedCommit = commit
    }

    /// Exact hash navigation is a pin, never a row inserted into a query.
    public func openHistoryCommit(_ commit: GitCommit) {
        guard !closed, !suspended, acceptsRepository(repositoryIdentity) else { return }
        // A same-hash choice is still newer than an in-flight blame reveal.
        historyChoices += 1; revealTokens += 1
        panel = .history; revealTarget = nil; pinnedCommit = commit.hash
        selectedCommit = commit; detailFile = nil
    }

    private func resumeAmendPrefill() {
        guard let request = pendingAmendPrefill else { return }
        guard amend, request.folder == folderGeneration, request.edit == messageGeneration,
              !closed, !suspended,
              commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingAmendPrefill = nil; return
        }
        // A folder switch invalidates the row context before its repository
        // is known. Keep this request until publication: the same repository
        // retains Amend, while publishing another repository resets it.
        guard root == identifiedFolder, sameRepository(repositoryContext) else { return }
        pendingAmendPrefill = nil
        Task { await prefillHeadMessage(folder: request.folder, edit: request.edit) }
    }

    private func prefillHeadMessage(folder: Int, edit: Int) async {
        guard amend, !closed, !suspended, folder == folderGeneration, edit == messageGeneration,
              root == identifiedFolder, sameRepository(repositoryContext),
              let root = repositoryRoot, repositoryIdentity?.root == root,
              let message = try? await service.headMessage(in: root) else { return }
        await headMessageDidRead?()
        // A return to the same path, or typing then erasing, still retires
        // this prefill. An ordinary status refresh does not.
        if amend, folder == folderGeneration, edit == messageGeneration,
           repositoryRoot == root, !closed, !suspended,
           commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commitMessage = message }
    }

    /// Runs one write. A second write asked for while one runs is refused, not
    /// queued: a double click commits once.
    private func perform(_ what: String, _ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; notice = ""
        defer { busy = false; drainMissedChange() }
        var failure: String?
        do { try await work() } catch is CancellationError { } catch { failure = "\(what): \(error.localizedDescription)" }
        await refresh(reporting: failure)
    }
    /// The reader's refresh after a write, then what failed. The refresh
    /// begins by clearing the notice, so a failure said before it was gone in
    /// the same turn, before it was ever drawn.
    private func refresh(reporting failure: String?) async {
        await refresh()
        if let failure { notice = failure }
    }
    /// Shared admission for additive repository tools. A writer stays alive
    /// through navigation, but its result is only published to its repository.
    public func performRepositoryWrite<T: Sendable>(repository identity: RepositoryIdentity,
        operation: @Sendable (String) async throws -> T) async throws -> T {
        guard acceptsRepository(identity), !busy else { throw GitFailure(message: "The repository changed or another Git operation is running. Try again.") }
        busy = true
        defer { busy = false; drainMissedChange() }
        do {
            let result = try await operation(identity.root)
            if sameRepositoryIdentity(identity) { await refresh() }
            return result
        } catch {
            if sameRepositoryIdentity(identity) { await refresh(reporting: error.localizedDescription) }
            throw error
        }
    }
    /// Retarget a matching History filter before the write's normal refresh.
    public func renameBranch(_ branch: GitBranchReference, to name: String, repository identity: RepositoryIdentity) async throws {
        try await performRepositoryWrite(repository: identity) { [service, weak self] root in
            let reference = try await service.renameBranch(branch, to: name, in: root)
            await self?.retargetBranchHistory(branch.ref, to: reference, repository: identity)
        }
    }
    public func deleteBranch(_ review: GitBranchDeletion, allowUnmerged: Bool = false, repository identity: RepositoryIdentity) async throws -> String {
        try await performRepositoryWrite(repository: identity) { [service, weak self] root in
            let result = try await service.deleteBranch(review, allowUnmerged: allowUnmerged, in: root)
            await self?.retargetBranchHistory(review.branch.ref, to: nil, repository: identity)
            return result
        }
    }
    private func retargetBranchHistory(_ old: String, to reference: String?, repository identity: RepositoryIdentity) {
        // A hidden panel may be resolving another folder in this repository.
        // Retarget its retained snapshot; a different repository retires it.
        guard !closed, repositoryIdentity == identity, repositoryRoot == identity.root, historyOptions.reference == old else { return }
        historyOptions.reference = reference
    }
    public func reportRepositoryResult(_ message: String, repository identity: RepositoryIdentity) {
        guard acceptsRepository(identity) else { return }
        notice = message
    }
    /// An explicit branch navigation starts the live browser with a removable
    /// ref filter and retires older blame navigation, even with no selection.
    public func showBranchHistory(_ reference: String, repository identity: RepositoryIdentity) {
        guard acceptsRepository(identity) else { return }
        guard repositoryRoot == identity.root else {
            notice = "The repository was still loading. Choose Show in History again."; return
        }
        notice = ""
        historyChoices += 1; revealTokens += 1
        pinnedCommit = nil; revealTarget = nil; selectedCommit = nil
        logFilter = GitLogFilter(); historyOptions = GitHistoryOptions(reference: reference); panel = .history
    }

    public func checkout(_ branch: String) async { await checkout(branch, context: repositoryContext) }
    public func checkout(_ branch: String, context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("Switch") { try await service.checkout(branch, in: root) } }
    public func createBranch(_ name: String) async { await createBranch(name, context: repositoryContext) }
    public func createBranch(_ name: String, context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("New branch") { try await service.createBranch(name, in: root) } }
    public func createBranch(_ name: String, repository: RepositoryIdentity?) async { guard let root = formRoot(repository) else { return }; await perform("New branch") { try await service.createBranch(name, in: root) } }
    public func stash(message: String) async { await stash(message: message, context: repositoryContext) }
    public func stash(message: String, context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("Stash") { try await service.stashPush(message: message, in: root) } }
    public func stash(message: String, repository: RepositoryIdentity?) async { guard let root = formRoot(repository) else { return }; await perform("Stash") { try await service.stashPush(message: message, in: root) } }
    public func popStash(_ name: String? = nil) async { await popStash(name, context: repositoryContext) }
    public func popStash(_ name: String?, context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("Pop stash") { try await service.stashPop(name, in: root) } }
    public func fetch() async { await fetch(context: repositoryContext) }
    public func fetch(context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("Fetch") { try await service.fetch(in: root) } }
    public func pull() async { await pull(context: repositoryContext) }
    public func pull(context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("Pull") { try await service.pull(in: root) } }
    public func push() async { await push(context: repositoryContext) }
    public func push(context: RepositoryContext?) async { guard let root = actionRoot(context) else { return }; await perform("Push") { try await service.push(in: root) } }
    /// Discards these rows. A rename goes back under its old name, unless a
    /// row left out of this discard is at that name now.
    public func discard(_ entries: [GitStatusEntry]) async { await discard(entries, context: repositoryContext) }
    public func discard(_ entries: [GitStatusEntry], context: RepositoryContext?) async {
        guard let root = actionRoot(context) else { return }
        let held = allPaths.subtracting(entries.map(\.path))
        await perform("Discard") { try await service.discard(entries, in: root, held: held) }
    }
    /// Freeze exactly what the user is about to commit. A question keeps this
    /// value; it never reads a newer HEAD, scope or draft as consent to that one.
    /// Check may inspect an empty scope to report conflicts; commit actions
    /// still require content, and submission repeats the service's guards.
    public func commitRequest(context: RepositoryContext?, reword: Bool = false, scope: GitCommitScope? = nil, forPreflight: Bool = false) -> GitCommitRequest? {
        guard let root = actionRoot(context), let context, !busy else { return nil }
        let scope = scope ?? commitScope
        let kind: GitCommitRequest.Kind = reword ? .reword : amend ? .amend : .commit
        let target: GitCommitTarget?
        if kind != .commit {
            guard let head = status.head else { notice = "There is no commit to rewrite yet."; return nil }
            target = GitCommitTarget(head: head, branch: status.branch)
        } else { target = nil }
        let content: GitCommitContent?
        if reword { content = nil }
        else if scope == .stagedChanges {
            guard forPreflight || !staged.isEmpty else { notice = "Nothing to commit: nothing is staged."; return nil }
            content = .staged
        } else {
            let rows = status.entries.filter { checked.contains($0.path) }
            let paths = GitService.paths(rows.map(\.path), renames: rows, for: .commit, held: allPaths.subtracting(checked))
            guard forPreflight || !paths.isEmpty else { notice = "Tick the files to commit."; return nil }
            content = .files(paths: paths, staging: rows.filter(\.untracked).map(\.path))
        }
        return GitCommitRequest(context: context, root: root, kind: kind, target: target, content: content,
                                message: commitMessage, signOff: signOff, scope: scope, checked: checked,
                                checkedCount: checkedCount, stagedCount: staged.count, chosenScope: commitScope)
    }

    public func accepts(_ request: GitCommitRequest) -> Bool {
        !suspended && sameCommitRequest(request)
    }

    /// A dispatched write keeps its authorization if the panel merely hides.
    /// Pending preparation/questions still require the visible accepts check.
    private func sameCommitRequest(_ request: GitCommitRequest) -> Bool {
        sameRepository(request.context) && request.message == commitMessage && request.signOff == signOff && request.chosenScope == commitScope
            && (request.kind == .reword || (request.kind == .amend) == amend)
            && (request.content == .staged || request.kind == .reword || request.checked == checked)
    }

    /// Explicit Check and the question preparation share one cancellable read.
    /// Typing, another check, a status change or leaving the panel invalidates it.
    public func checkCommit(_ request: GitCommitRequest) async -> GitCommitPreflight? {
        guard accepts(request), !busy else { return nil }
        clearPreflight()
        let generation = preflightGeneration
        preflightLoading = true; notice = ""
        let task = Task { [service] in try await service.preflight(in: request.root, content: request.content) }
        preflightTask = task
        defer { if generation == preflightGeneration { preflightTask = nil; preflightLoading = false } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, generation == preflightGeneration, accepts(request) else { return nil }
            preflight = result
            return result
        } catch is CancellationError { return nil }
        catch {
            if generation == preflightGeneration, accepts(request) { notice = "Check: " + error.localizedDescription }
            return nil
        }
    }

    /// UI callers confirm rewrites (and whitespace warnings) before handing
    /// back the frozen request. Every write rechecks repository and preflight;
    /// the service rechecks the reviewed HEAD/branch immediately before amend.
    public func submitCommit(_ request: GitCommitRequest, allowingWhitespace: Bool = false) async {
        guard !busy else { return }
        guard sameCommitRequest(request) else { notice = "The repository or commit choices changed. Review and try again."; return }
        await perform(request.kind.title) {
            let result = try await service.preflight(in: request.root, content: request.content)
            guard sameCommitRequest(request) else { throw GitFailure(message: "The repository or commit choices changed. Review and try again.") }
            preflight = result
            guard result.canCommit else { throw GitFailure(message: result.summary) }
            guard !result.hasWarnings || allowingWhitespace else { throw GitFailure(message: "Review the Git check warnings before committing.") }
            if request.kind == .reword {
                lastCommit = try await service.reword(message: request.message, in: request.root, expectedHead: request.target?.head,
                                                     expectedTarget: request.target, signOff: request.signOff)
            } else if let content = request.content {
                lastCommit = try await service.commit(message: request.message, in: request.root, content: content,
                                                     amend: request.kind == .amend, expectedTarget: request.target, signOff: request.signOff)
            }
            clearDraft(request.message, in: request.root)
        }
    }
    public func commitInScope() async { await commitInScope(context: repositoryContext) }
    public func commitInScope(context: RepositoryContext?) async {
        if let request = commitRequest(context: context) { await submitCommit(request) }
    }
    public func commitChecked() async { await commitChecked(context: repositoryContext) }
    public func commitChecked(context: RepositoryContext?) async {
        if let request = commitRequest(context: context, scope: .checkedFiles) { await submitCommit(request) }
    }
    public func commitStaged() async { await commitStaged(context: repositoryContext) }
    public func commitStaged(context: RepositoryContext?) async {
        if let request = commitRequest(context: context, scope: .stagedChanges) { await submitCommit(request) }
    }
    public func rewordLastCommit() async { await rewordLastCommit(context: repositoryContext) }
    public func rewordLastCommit(context: RepositoryContext?) async {
        if let request = commitRequest(context: context, reword: true) { await submitCommit(request) }
    }
    /// After a write, clears the message it used, unless the reader has typed
    /// another since or the panel moved to another repository.
    private func clearDraft(_ message: String, in root: String) {
        guard repositoryRoot == root, commitMessage == message else { return }
        commitMessage = ""; amend = false
    }

    /// Reads the selected file's diff, stopping the read the previous selection
    /// started. Clicking down a long list of changed files used to leave one
    /// `git diff` running per file, all of them computing patches nobody reads.
    /// A silent read keeps the diff on screen, with no spinner, until the new
    /// one is ready, and replaces it only if it changed.
    public func startSelectedDiffLoad(silently: Bool = false) {
        selectedDiffTask?.cancel()
        selectedDiffStale = false
        guard let repositoryRoot, let selection else { publish(\.diff, []); publish(\.diffLoading, false); return }
        // A path can have two rows: a staged deletion and an untracked file
        // saved there since. The row asked for is the one in its own section.
        let entry = status.entries.first { $0.path == selection.path && (selection.staged ? $0.staged : $0.unstaged) }
            ?? status.entries.first { $0.path == selection.path }
        // A rename is asked for under both names, or git sees a new file and
        // shows every one of its lines as added.
        let paths = [entry?.originalPath, selection.path].compactMap { $0 }
        if !silently { publish(\.diffLoading, true) }
        selectedDiffTask = Task { [service] in
            do {
                let files = try await service.diffFiles(in: repositoryRoot, paths: paths, staged: selection.staged, untracked: entry?.untracked == true)
                try Task.checkCancellation()
                guard self.selection == selection else { return }
                publish(\.diff, files); publish(\.diffLoading, false)
            } catch is CancellationError {
            } catch {
                guard self.selection == selection else { return }
                notice = error.localizedDescription; publish(\.diff, []); publish(\.diffLoading, false)
            }
        }
    }
    /// Waits for the selected file's diff; the panel itself never waits.
    private func loadSelectedDiff(silently: Bool = false) async {
        startSelectedDiffLoad(silently: silently)
        await selectedDiffTask?.value
    }

    /// Shows whatever of this commit is already read, then fetches only what is
    /// missing. Choosing another commit cancels the reads of the last one, so a
    /// superseded `git show` is terminated instead of finishing into nothing.
    public func startCommitLoad() {
        detailTask?.cancel()
        guard let repositoryRoot, let commit = selectedCommit else {
            detail = nil; detailDiff = []; detailFileDiff = []; detailDiffDeferred = false; commitLoading = false; return
        }
        if detail?.commit.hash != commit.hash { commitFilesShown = GitController.commitFilesStep }
        let file = detailFile, cached = commitCache[commit.hash]
        if let cached { detail = cached.detail } else if detail?.commit.hash != commit.hash { detail = nil }
        detailDiff = cached?.diff ?? []
        detailFileDiff = file.flatMap { cached?.fileDiffs[$0] } ?? []
        detailDiffDeferred = file == nil && cached?.diff == nil && (cached?.detail.isLarge ?? false)
        let needsDetail = cached == nil
        let needsDiff = file == nil ? (cached?.diff == nil && !(cached?.detail.isLarge ?? false)) : cached?.fileDiffs[file ?? ""] == nil
        guard needsDetail || needsDiff else { commitLoading = false; return }
        commitLoading = true; commitRead = .commit
        detailTask = Task { [service] in
            do {
                var summary = cached?.detail
                if needsDetail {
                    let value = try await service.commitDetail(in: repositoryRoot, commit: commit)
                    try Task.checkCancellation()
                    guard selectedCommit?.hash == commit.hash, revealStillValid(commit.hash) else { return }
                    // The file list and message appear before any patch is read.
                    detail = value; summary = value
                    remember(CachedCommit(detail: value), for: commit.hash)
                    detailDiffDeferred = file == nil && value.isLarge
                }
                if file != nil || !(summary?.isLarge ?? false) {
                    let renamedFrom = file.flatMap { name in summary?.files.first { $0.path == name }?.originalPath }
                    let files = try await service.commitDiffFiles(in: repositoryRoot, commit: commit, path: file, renamedFrom: renamedFrom)
                    try Task.checkCancellation()
                    guard selectedCommit?.hash == commit.hash, detailFile == file, revealStillValid(commit.hash) else { return }
                    if let file { detailFileDiff = files; commitCache[commit.hash]?.fileDiffs[file] = files }
                    else { detailDiff = files; commitCache[commit.hash]?.diff = files }
                }
                commitLoading = false
            } catch is CancellationError {
            } catch {
                guard selectedCommit?.hash == commit.hash, revealStillValid(commit.hash) else { return }
                notice = error.localizedDescription; commitLoading = false
            }
        }
    }

    /// "Show the whole diff" for a commit whose patch was held back.
    public func loadDeferredCommitDiff() {
        guard let commit = selectedCommit, detailFile == nil else { return }
        detailDiffDeferred = false
        detailTask?.cancel()
        guard let repositoryRoot else { return }
        commitLoading = true; commitRead = .wholePatch
        detailTask = Task { [service] in
            do {
                let files = try await service.commitDiffFiles(in: repositoryRoot, commit: commit, path: nil)
                try Task.checkCancellation()
                guard selectedCommit?.hash == commit.hash, detailFile == nil else { return }
                detailDiff = files; commitCache[commit.hash]?.diff = files; commitLoading = false
            } catch is CancellationError {
            } catch { notice = error.localizedDescription; commitLoading = false }
        }
    }

    /// Shows the change a blamed line came from: History, its commit (read by
    /// its id, wherever it is in the history and whatever the filter shows),
    /// its file under the name it had there, and the line there brought into
    /// view. A newer ask replaces one still being read. False when the commit
    /// is not in this repository.
    /// `repository` is the top of the repository the blame read: the panel
    /// reads it first if it shows another (its `root` set to the folder
    /// holding it), and does nothing if it still does not.
    /// `valid` is asked again after every wait — the asker's own standing
    /// (the file still readable, its project still trusted) — and a reader
    /// who chose a commit meanwhile, a hidden or closed panel, a newer ask or
    /// a cancelled task each end this one with nothing shown.
    @discardableResult
    public func revealHistory(_ target: GitHistoryTarget, in repository: String, while valid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        revealTokens += 1
        let token = revealTokens
        // The reader's choice as it was when asked: one made while this waits
        // wins over it.
        let choice = historyChoices
        // A tab brought forward says it is shown a turn later: waited for,
        // briefly, before a hidden panel counts as one the reader left.
        let until = ProcessInfo.processInfo.systemUptime + 3
        while suspended, !closed, token == revealTokens, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < until {
            try? await Task.sleep(for: .milliseconds(20))
        }
        func stillWanted() -> Bool { token == revealTokens && !closed && !suspended && !Task.isCancelled && valid() && historyChoices == choice }
        // A panel just made, or just pointed at another folder, is still
        // reading which repository it shows: that read is waited for first.
        if repositoryRoot != repository, !closed { await refreshTask?.value }
        if repositoryRoot != repository, !closed { await refresh() }
        guard stillWanted() else { return false }
        guard let repositoryRoot, repositoryRoot == repository else {
            notice = "This file's repository is not the one Changes shows."
            return false
        }
        panel = .history
        let found = try? await service.commit(target.commit, in: repositoryRoot)
        guard let commit = found, stillWanted(), self.repositoryRoot == repositoryRoot else {
            if found == nil, stillWanted() { notice = "That commit is not in this repository's history." }
            return false
        }
        pinnedCommit = commit.hash
        // Chosen first: choosing it lets go of any earlier reveal and its
        // standing; this one's is set after, so it is not let go of with them.
        if selectedCommit?.hash != commit.hash { selectedCommit = commit }
        revealTarget = GitHistoryReveal(target: target, token: token)
        revealValid = valid
        if detailFile != target.path { detailFile = target.path }
        return true
    }

    /// History of one path, from a file in the changes list or in a commit.
    public func showFileHistory(_ path: String) {
        panel = .history
        selectedCommit = nil
        logFilter.path = path
    }
    public func clearFileHistory() { logFilter.path = nil }

    private func remember(_ entry: CachedCommit, for hash: String) {
        commitCache[hash] = entry
        commitCacheOrder.removeAll { $0 == hash }
        commitCacheOrder.append(hash)
        while commitCacheOrder.count > Self.commitCacheLimit, let oldest = commitCacheOrder.first {
            commitCacheOrder.removeFirst(); commitCache.removeValue(forKey: oldest)
        }
    }

    /// Stages the rows at these paths; a rename is staged under both names.
    public func stage(_ paths: [String]) async { await stage(paths, context: repositoryContext) }
    public func stage(_ paths: [String], context: RepositoryContext?) async {
        guard let root = actionRoot(context) else { return }
        let paths = GitService.paths(paths, renames: status.entries, for: .stage)
        await perform("Stage") { try await service.stage(paths, in: root) }
    }
    /// Unstages the rows at these paths; a rename is unstaged whole, not by half.
    public func unstage(_ paths: [String]) async { await unstage(paths, context: repositoryContext) }
    public func unstage(_ paths: [String], context: RepositoryContext?) async {
        guard let root = actionRoot(context) else { return }
        let paths = GitService.paths(paths, renames: status.entries, for: .unstage)
        await perform("Unstage") { try await service.unstage(paths, in: root) }
    }
}

/// A line in a commit: the commit's full id, the file's path in that commit
/// and the line's number there (from 1), as a blame names it.
public struct GitHistoryTarget: Equatable, Sendable {
    public let commit: String
    public let path: String
    public let line: Int
    public init(commit: String, path: String, line: Int) { self.commit = commit; self.path = path; self.line = line }
}
/// A target asked for, and which asking it was.
public struct GitHistoryReveal: Equatable, Sendable {
    public let target: GitHistoryTarget
    public let token: Int
}

/// Which content a commit takes; see `GitController.commitScope`.
public enum GitCommitScope: Sendable, Hashable { case checkedFiles, stagedChanges }

/// A value retained by a confirmation, with no live view or mutable target.
public struct GitCommitRequest: Equatable, Sendable {
    public enum Kind: Sendable { case commit, amend, reword
        public var title: String { switch self { case .commit: "Commit"; case .amend: "Amend"; case .reword: "Reword" } }
    }
    public let context: GitController.RepositoryContext
    public let root: String
    public let kind: Kind
    public let target: GitCommitTarget?
    public let content: GitCommitContent?
    public let message: String
    public let signOff: Bool
    public let scope: GitCommitScope
    fileprivate let checked: Set<String>
    fileprivate let checkedCount: Int, stagedCount: Int
    fileprivate let chosenScope: GitCommitScope
    public var scopeDescription: String {
        if kind == .reword { return "Message only · the commit tree, index and working files stay as they are" }
        return scope == .checkedFiles ? "Checked files · \(checkedCount) \(checkedCount == 1 ? "file" : "files") · whole working-tree content"
            : "Staged changes · \(stagedCount) \(stagedCount == 1 ? "file" : "files") · index content; unstaged edits stay"
    }
}
