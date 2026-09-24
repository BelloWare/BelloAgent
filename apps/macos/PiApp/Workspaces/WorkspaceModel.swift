import Foundation
import Combine

enum WorkspacePage: String, Sendable { case chats, report }

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var workspaces: [WorkspaceRecord] = [] { didSet { sidebarIndex.invalidate(); workspacesRevision &+= 1; noteActivityChanged() } }
    /// Bumped by any change to the list, so views can cache derived labels
    /// instead of rebuilding them on every redraw.
    private(set) var workspacesRevision = 0
    private(set) var chatsRevision = 0
    /// Every sidebar row, unread badge and menu-bar row looks a chat up by id.
    /// A linear scan made those lookups O(chats) each and the sidebar O(chats²).
    /// The sidebar index rebuilds its id table at most once per mutation, lazily.
    @Published var chats: [ChatRecord] = [] { didSet { sidebarIndex.invalidate(); chatsRevision &+= 1; readBadgeCache = nil; noteActivityChanged() } }
    /// A duplicate id keeps the first entry, matching `chats.first`.
    func chatRecord(_ id: String) -> ChatRecord? { sidebarIndex.chat(id, in: chats) }
    @Published var unreadStates: [String: SessionReadState] = [:] { didSet { readBadgeCache = nil; noteActivityChanged() } }
    var readBadgeCache: SidebarReadCounts?
    /// Owned by `WorkspaceReadState.swift`: replies that finished in the chat
    /// the reader is looking at, waiting for the page's own read check.
    var heldUnread: [String: HeldUnread] = [:]
    /// Test seam: whether the app is in front. Nil in the app, which asks NSApp.
    var applicationIsActiveOverride: Bool?
    var dirtyReadStates: Set<String> = []
    var readStateWrites: [String: Task<Void, Never>] = [:]
    @Published var profiles: [ProfileRecord] = [] { didSet { noteActivityChanged() } }
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { messageNavigationRevision += 1; organizationNavigationRevision &+= 1; cancelAutomaticContext(); noteSelectionChanged() } }
    }
    /// Invalidates delayed report-to-message navigation when another target wins.
    var messageNavigationRevision = 0
    var sessionReferenceCopyRevision = 0
    /// Owned by `WorkspaceSelection.swift`: which `select` call is current, so
    /// a slower one cannot finish over a newer selection.
    var selectionRevision = 0
    var navigationTask: Task<Void, Never>?
    /// Deterministic source delay/failure seam. Production uses the live helper
    /// or the shared read-only history actor below, without launching a runtime.
    var historyWindowLoader: (@Sendable (String, ConversationCursor?, Bool, String?) async throws -> ConversationHistoryPage)?
    /// Test seam: an earlier version's rows (`readVersionPage`) without a helper.
    var versionPageLoader: (@Sendable (String, String) async throws -> (rows: [TranscriptMessage], tasks: [TaskPresentationRecord]))?
    /// Chats a "Fork from here" is being made from, so a second press waits for the first.
    var forkingReplies: Set<String> = []
    var organizationNavigationRevision = 0
    var organizationPresentationRevision = 0
    let organizationScheduler = SessionOrganizationScheduler()
    var archiveStopQueue: [(String, Int, SessionDisplay, HostSupervisor)] = []
    var archiveStopRevisions: [String: Int] = [:]
    var archiveStopWorkers = 0
    /// Optional delayed writer used by race/failure fixtures, never by production.
    var organizationWrite: (([String], ChatOrganizationChange) async throws -> ChatOrganizationBatch)?
    @Published var focusedSessionID: String? { didSet { if focusedSessionID != oldValue { organizationNavigationRevision &+= 1; cancelAutomaticContext(); noteSelectionChanged() } } }
    @Published var selected: SessionDisplay?
    @Published var error: String?
    /// Projects whose folder was not found when a helper was to start in it,
    /// by project id: the folder named. The pane offers Locate Folder….
    @Published var missingProjectFolders: [String: String] = [:]
    /// New chats that exist only on screen until their first message is sent.
    /// Nothing is written for them: no chat record, draft, journal or helper session.
    /// One that gains a record is a chat a relaunch can reopen.
    var pendingChatIDs: Set<String> = [] { didSet { noteSelectionChanged() } }
    @Published var showProfiles = false
    @Published var profileChoice = ""
    @Published var selectedWorkspaceID: String? { didSet { if selectedWorkspaceID != oldValue { noteSelectionChanged() } } }
    /// Owned by `WorkspaceLaunchSelection.swift`: what the next launch should
    /// reopen, the newest revision of it known to be on disk, the one write
    /// that carries a change there, and whether changes are written at all —
    /// from the end of `restore()`, which applies the saved one, to `shutdown()`.
    var rememberedSelection: RememberedSelection?
    var savedSelectionRevision: Int64 = 0
    var selectionWrite: Task<Void, Never>?
    var remembersSelection = false
    /// Owned by `WorkspaceLaunchSelection.swift`: the saved side each chat
    /// last showed beside it, by chat id, which `select` reopens after a
    /// relaunch. `sides` is the same thing for this launch, in memory.
    var rememberedSides: [String: String] = [:]
    /// Owned by `WorkspaceLaunchSelection.swift`: sidebar groups a relaunch
    /// opened, for that launch only, to show the row of the chat it reopened.
    @Published var launchReveal = SidebarLaunchReveal() { didSet { sidebarIndex.invalidate() } }
    @Published var showArchivedSessions = false
    @Published var showBackgroundSessions = false { didSet { sidebarIndex.invalidate(); if showBackgroundSessions != oldValue { noteSelectionChanged() } } }
    /// Answers the sidebar's own queries once per change: chat lookups, per
    /// group entry lists, the project groups and the keyboard order.
    let sidebarIndex = SidebarIndex()
    /// What the sidebar's filter field holds. A Shift range and the keyboard
    /// step through the rows that are actually listed, so the model has to know
    /// what the filter left on screen. Not published: the sidebar owns the
    /// field, and typing must not redraw the conversation pane behind it.
    var sidebarFilter = "" { didSet { if sidebarFilter != oldValue { sidebarIndex.invalidate() } } }
    /// Chats whose side chats are folded away. Owned here rather than by the
    /// group's own `@State`, which forgot the fold whenever the project was
    /// collapsed, the archive filter flipped or the sidebar was rebuilt. Both
    /// of these are written into the project's sidebar record, so they come
    /// back with the disclosure they belong to on the next launch.
    @Published var collapsedSidebarSides: Set<String> = []
    /// How many root chats each sidebar group shows, keyed by topic id or, for
    /// the chats outside every topic, by the project's id.
    @Published var sidebarPageSizes: [String: Int] = [:]
    /// Sidebar rows marked with Shift or Command for one bulk action. Empty
    /// means the ordinary single selection applies; marks never open, close,
    /// stop or start a chat by themselves.
    @Published var markedSessionIDs: Set<String> = []
    /// The row a Shift range extends from, kept until the marks are cleared.
    var sessionMarkAnchorID: String?
    var titleGenerationTasks: [String: Task<Void, Never>] = [:]
    /// Connections already told, this launch, that titles need a mini model.
    var titleMiniModelNotified: Set<String> = []
    @Published var showGit = false
    /// The integrated terminal panel under the transcript (⌃` toggles it).
    @Published var terminalVisible = false
    /// The chat whose rename sheet is open.
    @Published var renameTarget: RenameTarget?
    /// The project whose repositories the Changes sheet shows.
    var gitWorkspaceID: String?
    @Published var projectSidebarStates: [String: ProjectSidebarState] = [:] { didSet { sidebarIndex.invalidate() } }
    @Published var topics: [TopicRecord] = [] { didSet { sidebarIndex.invalidate() } }
    @Published var topicEditor: TopicEditorTarget?
    var topicExpansionRequests: [String: Bool] = [:]
    var topicExpansionWrites: [String: Task<Void, Never>] = [:]
    var topicOperationsInFlight = 0
    var projectSidebarWrites: [String: Task<Void, Never>] = [:]
    var dirtyProjectSidebarStates: Set<String> = []
    @Published var workspaceChangesInFlight: Set<String> = []
    @Published var installPreparing = false
    @Published var showConversationContent = false
    var contentSessionID: String?
    /// Test seam: where the Session Inspector was last asked to open.
    var lastInspectorFocus: InspectorFocus?
    /// Which page the main window shows; the chat pane stays mounted underneath the report.
    @Published var page: WorkspacePage = .chats {
        didSet {
            if page != oldValue { organizationNavigationRevision &+= 1; noteSelectionChanged() }
            if page == .report && page != oldValue { messageNavigationRevision += 1 }
        }
    }
    /// Report page state survives navigation so filters, selection and results come back intact.
    let report = ReportController()
    /// Legacy entry point kept for callers and tests: the report is a page, not a sheet.
    var showDashboard: Bool {
        get { page == .report }
        set { page = newValue ? .report : .chats }
    }
    func openReport() { page = .report }
    func closeReport() { page = .chats }
    func toggleReport() { page = page == .report ? .chats : .report }
    var conversationCommandsEnabled: Bool { page == .chats && !presentsSheet && (focusedSessionID ?? selectedID).flatMap(record) != nil }
    /// A sheet of the workspace window is up. Its fields own the keyboard:
    /// the conversation's shortcuts (⌘↩, ⌘., ⌘F) must not act on the chat
    /// behind it, nor present a second sheet over it.
    var presentsSheet: Bool {
        showProfiles || showConversationContent || showResources || showWorkspaceManager || showGit || renameTarget != nil || topicEditor != nil
    }
    @Published var showResources = false
    @Published var showWorkspaceManager = false
    @Published var resourceCatalog: [SkillDescriptor] = []
    @Published var resourceCatalogWorkspaceID: String?
    @Published var resourceCatalogSessionID: String?
    @Published var resourceTargetSessionID: String?
    @Published var sides: [String: SideRecord] = [:] { didSet { sidebarIndex.invalidate(); readBadgeCache = nil; noteActivityChanged(); sidesChanged(from: oldValue) } }
    @Published var resourceLoading = false
    @Published var resourceNotice = ""
    var editTargetRead: (@MainActor (String, String) async throws -> [String: WireValue])?
    var skillCatalogLoads: [String: (token: UUID, scope: String, task: Task<Void, Never>)] = [:]
    /// Retained gateway totals for chats without a loaded display, keyed by chat id.
    let chatAccounting = SessionAccountingCache()
    var chatStats: [String: GatewayTotals] { chatAccounting.values }
    var accountingTasks: [String: Task<Void, Never>] = [:]
    var dirtyAccounting: Set<String> = []
    var chatStatsRevision = 0
    var chatStatsVersions: [String: Int] = [:]
    var accountingStopped = false
    let root: URL
    let vault: ConfigurationVault
    @Published var configuration = VaultConfiguration()
    @Published var configurationLoaded = false
    /// Set while the vault could not be read at launch: each activation of
    /// the app tries again (`retryConfigurationWhenActive`).
    var configurationRetry: NSObjectProtocol?
    var configurationRetrying = false
    /// Cleared when the desktop database cannot be opened, which `restore()`
    /// finds out without opening SQLite on the main actor at launch.
    private(set) var store: MetadataStore?
    let history = HistoryReader()
    let modelCatalog = ModelCatalog()
    let traces: PayloadArchive
    /// Owned by `WorkspaceChatLifecycle.swift`: the throwaway archive a
    /// portable handoff writes into.
    let liveExporter: TraceArchive
    /// The panel observes only committed activity/usage changes, never text or
    /// unrelated workspace presentation. Dirty IDs are projected once per window.
    let activityChanged = PassthroughSubject<Void, Never>()
    let liveActivity = LiveActivityStore()
    private var monitoredDisplays: [String: String] = [:]
    var activityRows: [String: MenuBarActivityRow] = [:]
    var activityDirtyIDs: Set<String> = []
    var activitySnapshot = MenuBarActivitySnapshot()
    var activityProjectionCount = 0
    var menuBarActivityChanges: AnyPublisher<Void, Never> { activityChanged.eraseToAnyPublisher() }
    func noteActivityChanged(_ id: String? = nil) {
        if let id { activityDirtyIDs.insert(id) }
        else { activityDirtyIDs.formUnion(displays.keys); activityDirtyIDs.formUnion(unreadStates.keys); activityDirtyIDs.formUnion(activityRows.keys) }
        activityChanged.send()
        // Read only the affected committed phase, never text or the chat array.
        if let id, let view = displays[id], let item = record(id) {
            let phase = view.uncertain ? "interrupted" : view.state == "error" ? "error" : view.state == "paused" ? "paused" : view.loading ? "starting" : view.busy ? (view.activity["phase"]?.string ?? (view.state == "queued" ? "queued" : "starting")) : "idle"
            liveActivity.phase(phase, workspace: item.workspaceID, session: id)
        }
    }
    private var activityObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private func syncActivityObservers() {
        let live = Set(displays.values.map(ObjectIdentifier.init))
        guard live != Set(activityObservers.keys) else { return }
        for (id, workspace) in monitoredDisplays where displays[id] == nil { liveActivity.forget(workspace: workspace, session: id); monitoredDisplays[id] = nil }
        activityObservers = activityObservers.filter { live.contains($0.key) }
        for view in displays.values where activityObservers[ObjectIdentifier(view)] == nil {
            let id = view.id
            if let item = record(id) { monitoredDisplays[id] = item.workspaceID }
            activityObservers[ObjectIdentifier(view)] = view.activityChanges.merge(with: view.footer.activityChanges)
                .sink { [weak self] _ in self?.noteActivityChanged(id) }
            noteActivityChanged(id)
            // A new display reads the chat's cost limit before its helper says anything.
            view.applyCostReading(costReading(for: id))
        }
        noteActivityChanged()
    }
    var displays: [String: SessionDisplay] = [:] {
        didSet { syncActivityObservers(); SessionInspectorWindows.shared.displaysChanged() }
        willSet {
            // Rows switch between retained accounting and a live display only
            // when display identity changes. Stream/status refreshes keep that
            // identity and must not invalidate the surrounding workspace.
            if displays.count != newValue.count || displays.contains(where: { newValue[$0.key] !== $0.value }) {
                objectWillChange.send()
            }
        }
    }
    var hosts: [String: HostSupervisor] = [:]
    /// Owned by `WorkspaceHosts.swift` (and cancelled by `WorkspaceShutdown`):
    /// one in-flight helper start per project, so two chats opening at once
    /// share it instead of starting two helpers.
    var hostStarts: [String: (token: UUID, task: Task<HostSupervisor, Error>)] = [:]
    /// Owned by `WorkspaceHosts.swift`: which connection each live helper was
    /// started for, so a connection change restarts it.
    var boundHostConnections: [String: UUID] = [:]
    /// Owned by `WorkspaceHosts.swift`: one in-flight `session.open` per chat.
    var sessionOpenings: [String: (token: UUID, task: Task<Void, Error>)] = [:]
    /// Owned by `WorkspaceHosts.swift`: how many callers are waiting on that
    /// open, so the last one out cleans up.
    var sessionOpenCallers: [String: Int] = [:]
    var opened: Set<String> = []
    var deletingProfiles: Set<String> = []
    var profileDeletionGenerations: [String: UInt64] = [:]
    var automaticContextTask: AutomaticContextTask?
    let preparedContextRequests = PreparedContextRequests()
    /// Test injection runs behind the same selection, input and safety guards.
    var automaticContextOperation: AutomaticContextOperation?
    /// Questions this chat asks before it acts, as sheets on its own window.
    let questions = PiQuestion()
    /// Test injection for the helper's `queue.read`; production leaves it nil.
    var queueReadOperation: ((String, String) async throws -> [String: WireValue])?
    /// Test seam: each step of a send as it happens (`WorkspaceRun.swift`),
    /// so a fixture can time where Return's milliseconds go. Nil in the app.
    var sendSteps: ((String) -> Void)?
    /// Owned by `WorkspaceHosts.swift`: chats whose helper `prewarm` is starting.
    var prewarming: Set<String> = []
    /// Test seam: whether typing starts a stopped helper (`prewarm`). Fixtures
    /// that answer for the helper themselves turn it off.
    var prewarmsHelpers = true
    /// Picker saves are ordered per connection; new chats await its pending choice.
    var overrideWrites: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Owned by `WorkspaceRefresh.swift`: the delayed shutdown of an idle
    /// project's helper, cancelled the moment it is used again.
    var idleTasks: [String: Task<Void, Never>] = [:]
    /// Owned by `WorkspaceHosts.swift`: helpers stopped on purpose for being
    /// idle, whose exit therefore is not a lost host.
    var retiringHosts: Set<ObjectIdentifier> = []
    /// Owned by `WorkspaceDrafts.swift`: the debounced write of each chat's
    /// draft, and the token saying which write owns the entry.
    var draftTasks: [String: Task<Void, Never>] = [:]
    /// Which write owns each entry above; see `draftChanged`.
    var draftTaskTokens: [String: UUID] = [:]
    /// Test seam: draft writes still in flight or not yet cleaned up.
    var pendingDraftWrites: Int { draftTasks.count }
    /// True while `restore()` is reading the store, so a second call is a
    /// no-op rather than a second pass over the same rows. Owned by
    /// `WorkspaceRestore.swift`; a chat's own `loading` is a different thing.
    var restoring = false
    /// Owned by `WorkspaceRestore.swift`: launch has not yet opened the chat
    /// it reopens, or found there is none. Until then the window shows
    /// neither the welcome nor onboarding in place of a chat about to appear.
    /// The app's model starts out launching, before its window's first frame.
    @Published var launching: Bool
    /// Owned by `WorkspaceDrafts.swift`: a draft write has already failed, so
    /// the next failure does not repeat the same banner.
    var draftSaveFailed = false
    /// Owned by `WorkspaceChatLifecycle.swift`: onboarding creates exactly one
    /// first chat however many times its button is pressed.
    var creatingOnboardingChat = false
    var hasActiveWork: Bool { !workspaceChangesInFlight.isEmpty || !titleGenerationTasks.isEmpty || displays.values.contains { $0.hasWork || $0.loading } || sides.values.contains { !$0.kept && !$0.pending } }
    var chat: ChatRecord? { selectedID.flatMap(chatRecord) }
    var requestProfiles: [ProfileRecord] { profiles.filter { $0.api == LiteLLMConfiguration.supportedAPI } }

    let completionSound: CompletionSound

    init(stateRoot: URL? = nil, vault: ConfigurationVault = .shared, completionSound: CompletionSound? = nil, launching: Bool = false) {
        self.launching = launching
        self.vault = vault
        self.completionSound = completionSound ?? CompletionSound()
        let benchmarkRoot = PerformanceProbe.shared.enabled ? ProcessInfo.processInfo.environment["PI_APP_BENCHMARK_STATE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
        root = stateRoot ?? benchmarkRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.belloware.PiApp", isDirectory: true)
        traces = PayloadArchive(root: root.appendingPathComponent("Requests-v1", isDirectory: true))
        liveExporter = TraceArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("BelloAgent-Export-" + UUID().uuidString))
        store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        report.attach(self)
    }
    /// Opens the desktop database off the main actor and reports the one state
    /// the rest of the app checks synchronously: there is no storage at all.
    @discardableResult func prepareStore() async -> Bool {
        guard let store else { return false }
        do { try await store.open(); return true }
        catch {
            self.store = nil
            self.error = "Cannot open desktop metadata. Sending is disabled to preserve command intent."
            return false
        }
    }
}
