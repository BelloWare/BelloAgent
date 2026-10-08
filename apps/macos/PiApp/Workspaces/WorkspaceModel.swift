import Foundation
import Combine

enum WorkspacePage: String, Sendable { case chats, report, background }

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var workspaces: [WorkspaceRecord] = [] { didSet { sidebarIndex.invalidate(); workspacesRevision &+= 1; noteActivityChanged(); tabs.projectsChanged() } }
    /// The tabs beside the chats and in windows of their own: the window's,
    /// publishing on their own (`TabHost`). Kept across launches in the app;
    /// in tests, nothing is kept.
    let tabs = TabHost(defaults: ProcessInfo.processInfo.environment["PI_APP_TESTING"] == "1" ? nil : .standard)
    /// ⌘P's list: its own to publish, so the window is not drawn again for it.
    let quickOpen = QuickOpen()
    let replyFileResolver = ReplyFileResolver()
    /// Bumped by any change to the list, so views can cache derived labels
    /// instead of rebuilding them on every redraw.
    private(set) var workspacesRevision = 0
    private(set) var chatsRevision = 0
    /// Every sidebar row, unread badge and menu-bar row looks a chat up by id.
    /// A linear scan made those lookups O(chats) each and the sidebar O(chats²).
    /// The sidebar index rebuilds its id table at most once per mutation, lazily.
    @Published var chats: [ChatRecord] = [] { didSet { sidebarIndex.invalidate(); chatsRevision &+= 1; readBadgeCache = nil; noteActivityChanged(); forgetKeptTranscriptRows() } }
    /// A duplicate id keeps the first entry, matching `chats.first`.
    func chatRecord(_ id: String) -> ChatRecord? { sidebarIndex.chat(id, in: chats) }
    @Published var unreadStates: [String: SessionReadState] = [:] { didSet { readBadgeCache = nil; noteActivityChanged() } }
    var readBadgeCache: SidebarReadCounts?
    /// Owned by `WorkspaceRunHolds.swift`: chats whose run waits for Resume
    /// (or was under way when last seen), kept across relaunches.
    @Published var runHolds: [String: RunHoldRecord] = [:] {
        didSet { menuBarProjection.dirty.formUnion(oldValue.keys); menuBarProjection.dirty.formUnion(runHolds.keys); activityChanged.send() }
    }
    var dirtyRunHolds: Set<String> = []
    var runHoldWrites: [String: Task<Void, Never>] = [:]
    /// Launch's reading of the journals the holds name (tests wait on it).
    var runHoldVerification: Task<Void, Never>?
    /// Test seam: hold writes fail, as a full or locked store would.
    var runHoldWritesFail = false
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
    @Published var focusedSessionID: String? {
        didSet {
            guard focusedSessionID != oldValue else { return }
            organizationNavigationRevision &+= 1; cancelAutomaticContext(); noteSelectionChanged()
            // The reader came to this chat: a Mark as Unread on it is done
            // with. Not the chat a launch reopens by itself.
            if let id = focusedSessionID {
                if launchFocus == id { launchFocus = nil }
                else if readStatesRestored { clearManualUnread(sessionID: id) } else { openedBeforeReadStates.insert(id) }
            }
        }
    }
    /// The chat (or side) launch is about to focus, reopening it as it was at
    /// the last quit (`reopenRememberedSelection`): that one focus is not the
    /// reader opening it. Taken by the focus it is for.
    var launchFocus: String?
    /// Mark as Unread waits for the saved read states (`restoreReadStates`);
    /// chats the reader opens before then have their mark cleared once read.
    var readStatesRestored = false
    var openedBeforeReadStates: Set<String> = []
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
    /// Owned by `WorkspaceLaunchSelection.swift`: what the next launch
    /// reopens, the sides it puts back, and how that gets to disk.
    var selectionMemory = SelectionMemory()
    /// Owned by `ContextReading.swift`: each chat's saved context reading.
    var contextReadings: [String: ContextReading] = [:]
    /// Owned by `WorkspaceLaunchSelection.swift`: sidebar groups a relaunch
    /// opened, for that launch only, to show the row of the chat it reopened.
    @Published var launchReveal = SidebarLaunchReveal() { didSet { sidebarIndex.invalidate() } }
    /// The sidebar's archive switch: while it is on, every project lists its
    /// archived chats after its active ones (`SidebarGroups.swift`). One
    /// switch for the whole sidebar, remembered with the selection.
    @Published var showArchivedSessions = false { didSet { if showArchivedSessions != oldValue { sidebarIndex.invalidate(); noteSelectionChanged() } } }
    /// The sides panel at the window's right edge stands open as a column of
    /// its own, rather than hiding until the pointer rests at the edge
    /// (`SidesPanel.swift`). Remembered with the selection.
    @Published var sidesPanelPinned = false { didSet { if sidesPanelPinned != oldValue { noteSelectionChanged() } } }
    /// Whether the sides panel is out over the window while it is not pinned.
    /// Its own object: the panel coming and going redraws nothing else.
    let sidesPanelReveal = SidesPanelReveal()
    /// Answers the sidebar's own queries once per change: chat lookups, per
    /// group entry lists, the project groups and the keyboard order.
    let sidebarIndex = SidebarIndex()
    /// What the sidebar's filter field holds. A Shift range and the keyboard
    /// step through the rows that are actually listed, so the model has to know
    /// what the filter left on screen. Not published: the sidebar owns the
    /// field, and typing must not redraw the conversation pane behind it.
    var sidebarFilter = "" { didSet { if sidebarFilter != oldValue { sidebarIndex.invalidate() } } }
    /// Owned by `SidebarSearch.swift`: the filter's search inside chats,
    /// made when the sidebar first asks for it.
    var sidebarSearchStorage: SidebarSearch?
    /// Chats whose side chats are folded away. Owned here rather than by the
    /// group's own `@State`, which forgot the fold whenever the project was
    /// collapsed, the archive filter flipped or the sidebar was rebuilt. Both
    /// of these are written into the project's sidebar record, so they come
    /// back with the disclosure they belong to on the next launch.
    @Published var collapsedSidebarSides: Set<String> = []
    /// Chats the reader reached from the sidebar itself, or by putting the
    /// cursor in a pane already on screen, with the chats above them: the
    /// sidebar unfolds and expands nothing for these, since the reader could
    /// already see what they clicked (`openFromSidebar`, `focusPane`). Opening
    /// a chat from anywhere else (the menu bar, the Usage Report, search)
    /// empties it and reveals as before.
    var quietSidebarReveal: Set<String> = []
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
    /// Webhooks on their way: the mini model's request, then the send.
    var webhookTasks: [UUID: Task<Void, Never>] = [:]
    /// How long a finished chat's webhook waits before its one retry.
    var webhookRetryDelay: Duration = .seconds(4)
    /// Connections already told, this launch, that titles need a mini model.
    var titleMiniModelNotified: Set<String> = []
    /// The integrated terminal panel under the transcript (⌃` toggles it).
    @Published var terminalVisible = false
    /// The chat whose rename sheet is open.
    @Published var renameTarget: RenameTarget?
    @Published var projectSidebarStates: [String: ProjectSidebarState] = [:] { didSet { sidebarIndex.invalidate() } }
    @Published var topics: [TopicRecord] = [] { didSet { sidebarIndex.invalidate() } }
    @Published var topicEditor: TopicEditorTarget?
    /// The chat whose webhook the preview sheet shows.
    @Published var webhookPreviewTarget: RenameTarget?
    /// The Settings section open in the sheet and the window, kept while the
    /// app runs so Settings reopens where it was left.
    @Published var settingsSection: SettingsSection = .connections
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
    /// The Background requests page's state (`BackgroundRequests.swift`),
    /// kept the same way.
    let backgroundRequests = BackgroundRequestsController()
    /// Background requests this launch has under way.
    var backgroundRequestsRunning: Set<String> = []
    /// Legacy entry point kept for callers and tests: the report is a page, not a sheet.
    var showDashboard: Bool {
        get { page == .report }
        set { page = newValue ? .report : .chats }
    }
    func openReport() { page = .report }
    func closeReport() { page = .chats }
    func toggleReport() { page = page == .report ? .chats : .report }
    var conversationCommandsEnabled: Bool { page == .chats && !presentsSheet && (focusedSessionID ?? selectedID).flatMap(record) != nil }
    /// First-run setup fills the window: the vault has answered, and there is
    /// no connection or no chat yet. Its steps end with the project, so
    /// nothing else offers one meanwhile.
    var presentsSetup: Bool {
        !launching && OnboardingState.shouldPresent(configurationLoaded: configurationLoaded, hasProfiles: !requestProfiles.isEmpty, hasChats: !chats.isEmpty)
    }
    /// A sheet of the workspace window is up. Its fields own the keyboard:
    /// the conversation's shortcuts (⌘↩, ⌘., ⌘F) must not act on the chat
    /// behind it, nor present a second sheet over it.
    var presentsSheet: Bool {
        showProfiles || showConversationContent || showResources || showWorkspaceManager || renameTarget != nil || topicEditor != nil || webhookPreviewTarget != nil
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
    let modelCatalog: ModelCatalog
    let traces: PayloadArchive
    /// Owned by `WorkspaceChatLifecycle.swift`: the throwaway archive a
    /// portable handoff writes into.
    let liveExporter: TraceArchive
    /// The panel observes only committed activity/usage changes, never text or
    /// unrelated workspace presentation. Dirty IDs are projected once per window.
    let activityChanged = PassthroughSubject<Void, Never>()
    let liveActivity = LiveActivityStore()
    private var monitoredDisplays: [String: String] = [:]
    /// Owned by `MenuBarActivity.swift`: the menu bar's rows, kept between projections.
    var menuBarProjection = MenuBarProjection()
    /// Test seam: how many rows the menu bar has worked out.
    var activityProjectionCount: Int { menuBarProjection.count }
    var menuBarActivityChanges: AnyPublisher<Void, Never> { activityChanged.eraseToAnyPublisher() }
    func noteActivityChanged(_ id: String? = nil) {
        if let id { menuBarProjection.dirty.insert(id) }
        else { menuBarProjection.dirty.formUnion(displays.keys); menuBarProjection.dirty.formUnion(unreadStates.keys); menuBarProjection.dirty.formUnion(menuBarProjection.rows.keys) }
        activityChanged.send()
        // Read only the affected committed phase, never text or the chat array.
        if let id, let view = displays[id], let item = record(id) {
            liveActivity.phase(view.activityPhase, workspace: item.workspaceID, session: id)
            if view.runStateKnown { reconcileRunHold(id) }
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
            let activity = view.activityChanges.merge(with: view.footer.activityChanges)
                .sink { [weak self] _ in self?.noteActivityChanged(id) }
            // A selection let go of in a pass of the transcript's layout: the
            // window it stretched is cut after that pass, not inside it.
            let held = view.heldChanges.receive(on: DispatchQueue.main)
                .sink { [weak self, weak view] _ in if let self, let view { self.releaseHeldWindow(view) } }
            activityObservers[ObjectIdentifier(view)] = AnyCancellable { activity.cancel(); held.cancel() }
            noteActivityChanged(id)
            // A new display reads the chat's cost limit before its helper says anything.
            view.applyCostReading(costReading(for: id))
        }
        noteActivityChanged()
    }
    var displays: [String: SessionDisplay] = [:] {
        didSet { syncActivityObservers(); SessionInspectorWindows.shared.displaysChanged(); forgetKeptTranscriptRows() }
        willSet {
            // Rows switch between retained accounting and a live display only
            // when display identity changes. Stream/status refreshes keep that
            // identity and must not invalidate the surrounding workspace.
            if displays.count != newValue.count || displays.contains(where: { newValue[$0.key] !== $0.value }) {
                objectWillChange.send()
            }
        }
    }
    /// Whether a chat the reader leaves keeps its rows in the pane that
    /// showed it (`TranscriptKeptRows`): only while it has a display that is
    /// not running, loading, sending or holding queued messages, and it is
    /// neither archived nor deleted. A chat left while it runs opens fresh
    /// when the reader comes back, with its rows as the run left them.
    func keepsTranscriptRows(_ id: String) -> Bool {
        guard let view = displays[id], !view.hasWork, !view.loading, view.sendingRows.isEmpty else { return false }
        return record(id).map { !$0.isArchived } ?? false
    }
    /// A chat whose display went or was made again, or that was archived or
    /// deleted, keeps no rows in any pane this workspace let keep them.
    private func forgetKeptTranscriptRows() {
        guard !TranscriptKeptRows.keptSessionIDs.isEmpty else { return }
        TranscriptKeptRows.forgetEverywhere(admittedBy: self) { entry in
            !keepsTranscriptRows(entry.sessionID) || displays[entry.sessionID]?.disclosure !== entry.disclosure
        }
    }
    var hosts: [String: HostSupervisor] = [:]
    /// Every Settings editor alive: the sheet's and the Settings window's. Quit
    /// asks about the unsaved edits of each.
    let settingsEditors = NSHashTable<ConnectionSettingsController>.weakObjects()
    /// The Settings sheet's editor. It outlives one showing of the sheet, so a
    /// sheet closed by anything but Cancel, Save or Discard keeps its edits.
    private(set) var sheetSettingsEditor: ConnectionSettingsController?
    func settingsSheetEditor() -> ConnectionSettingsController {
        if let sheetSettingsEditor { return sheetSettingsEditor }
        let editor = ConnectionSettingsController(model: self); sheetSettingsEditor = editor; return editor
    }
    /// A project's MCP servers are being removed: its question is up or the vault is being written.
    @Published var mcpRemovalInProgress = false
    /// Owned by `WorkspaceHosts.swift` (and cancelled by `WorkspaceShutdown`):
    /// one in-flight helper start per project, so two chats opening at once
    /// share it instead of starting two helpers.
    var hostStarts: [String: (token: UUID, task: Task<HostSupervisor, Error>)] = [:]
    /// Owned by `WorkspaceHosts.swift`: which connection each live helper was
    /// started for, so a connection change restarts it.
    var boundHostConnections: [String: UUID] = [:]
    /// Owned by `WorkspaceHosts.swift`: one in-flight `session.open` per chat.
    var sessionOpenings: [String: (token: UUID, task: Task<Void, Error>)] = [:]
    /// Owned by `WorkspaceHosts.swift`: a `session.close` sent when a chat's
    /// display was let go of, which the chat's next open waits for.
    var sessionClosings: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Owned by `WorkspaceHosts.swift`: how many callers are waiting on that
    /// open, so the last one out cleans up.
    var sessionOpenCallers: [String: Int] = [:]
    var opened: Set<String> = []
    /// Owned by `WorkspaceConnectionSwitch.swift`: a chat's move to another
    /// connection under way, which every open of the chat waits for, and how
    /// many times each chat has moved, so an open begun before is known stale.
    var connectionSwitches: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    var connectionGenerations: [String: UInt64] = [:]
    /// Owned by `WorkspaceSides.swift`: a side's draft on its way to its
    /// parent's saved draft, which every other move of it waits for.
    var sideDraftTransfers: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Test seam: each step of a connection change as it happens, awaited
    /// ("closed", "marked", "rebound", "metadata"), so a fixture can hold the change there.
    var connectionSwitchSteps: ((String) async throws -> Void)?
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
    /// Test injection for the helper's `queue.edit.*` commands (method,
    /// session, params); production leaves it nil.
    var queueEditOperation: ((String, String, [String: WireValue]) async throws -> [String: WireValue])?
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
    /// The once-per-launch pass that slims journals written before 0.1.111 (`WorkspaceJournalSlimming.swift`).
    var journalSlimming: Task<Void, Never>?
    /// Owned by `WorkspaceHosts.swift`: helpers stopped on purpose for being
    /// idle, whose exit therefore is not a lost host.
    var retiringHosts: Set<ObjectIdentifier> = []
    /// Owned by `WorkspaceDrafts.swift`: the debounced draft writes under way.
    var draftWrites = DraftWrites()
    /// Test seam: draft writes still in flight or not yet cleaned up.
    var pendingDraftWrites: Int { draftWrites.tasks.count }
    /// True while `restore()` is reading the store, so a second call is a
    /// no-op rather than a second pass over the same rows. Owned by
    /// `WorkspaceRestore.swift`; a chat's own `loading` is a different thing.
    var restoring = false
    /// Owned by `WorkspaceRestore.swift`: launch has not yet opened the chat
    /// it reopens, or found there is none. Until then the window shows
    /// neither the welcome nor onboarding in place of a chat about to appear.
    /// The app's model starts out launching, before its window's first frame.
    @Published var launching: Bool
    /// Set by `shutdown()`: the model is coming down, and nothing may start
    /// again — no helper, read or write. Every task that resumes after an
    /// await checks it.
    var isShutDown = false
    /// Owned by `WorkspaceChatLifecycle.swift`: onboarding creates exactly one
    /// first chat however many times its button is pressed.
    var creatingOnboardingChat = false
    var hasActiveWork: Bool { !workspaceChangesInFlight.isEmpty || !titleGenerationTasks.isEmpty || displays.values.contains { $0.hasWork || $0.loading } || sides.values.contains { !$0.kept && !$0.pending } }
    var chat: ChatRecord? { selectedID.flatMap(chatRecord) }
    var requestProfiles: [ProfileRecord] { profiles.filter { $0.api == LiteLLMConfiguration.supportedAPI } }

    let completionSound: CompletionSound

    init(stateRoot: URL? = nil, vault: ConfigurationVault = .shared, completionSound: CompletionSound? = nil, launching: Bool = false, modelCatalog: ModelCatalog? = nil) {
        self.launching = launching
        self.modelCatalog = modelCatalog ?? ModelCatalog()
        self.vault = vault
        self.completionSound = completionSound ?? CompletionSound()
        let benchmarkRoot = PerformanceProbe.shared.enabled ? ProcessInfo.processInfo.environment["PI_APP_BENCHMARK_STATE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
        root = stateRoot ?? benchmarkRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.belloware.PiApp", isDirectory: true)
        traces = PayloadArchive(root: root.appendingPathComponent("Requests-v1", isDirectory: true))
        liveExporter = TraceArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("BelloAgent-Export-" + UUID().uuidString))
        store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        report.attach(self)
        TranscriptKeptRows.policy = self
        FileTab.resolveProject = { [weak self] id in self?.fileProjectState(id) ?? .removed }
        ChangesTab.resolveProject = { [weak self] id in self?.changesProject(id) }
        ChangesTab.openLocation = { [weak self] url, line in self?.openChangesFile(url, at: line) }
        FileBlame.openChange = { [weak self] tab, target, repository, still in self?.showHistoricalChange(from: tab, target: target, repository: repository, while: still) }
        ChangesTab.activate = { [weak self] tab in self?.tabs.activate(tab) }
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

extension WorkspaceModel: TranscriptKeptRowsPolicy {}
