import SwiftUI
import AppKit
import Combine

@MainActor final class SessionMetrics: ObservableObject {
    @Published var context: [String: WireValue] = [:]
    @Published var preparedContext: PreparedContextMetrics?
    @Published var preparingContext = false
    @Published var metrics: [String: WireValue] = [:]
    @Published var turnTiming: [String: WireValue] = [:]
    @Published var timing = SessionTimingHistory()
    @Published var gateway = GatewayTotals()
    @Published var gatewayNotice = ""
}
@MainActor final class ComposerDraft: ObservableObject { @Published var text = "" }

@MainActor final class SessionDisplay: ObservableObject {
    let id: String
    let transcriptChanges = CurrentValueSubject<[TranscriptMessage], Never>([])
    var messages: [TranscriptMessage] = [] { didSet { projectionRevision = nil; publishTranscript() } }
    /// What the conversation page shows: the messages, then a retry notice
    /// while the helper retries a failed request, then the run failure or the
    /// last send failure where the conversation stopped. Errors live in the
    /// flow of the chat, not in a strip pinned above it.
    var presentedMessages: [TranscriptMessage] {
        var rows = messages
        if let retryNotice { rows.append(TranscriptMessage(id: "notice:retry:" + id, role: "system", text: retryNotice, kind: "notice")) }
        if let failureMessage {
            rows.append(TranscriptMessage(id: "failure:run:" + id, role: "system", text: failureMessage, kind: "failure",
                                          detail: queuePaused && !queue.isEmpty ? "Queued follow-ups are paused. Resume when you’re ready." : nil))
        } else if let sendFailure {
            rows.append(TranscriptMessage(id: "failure:send:" + id, role: "system", text: sendFailure, kind: "failure"))
        }
        return rows
    }
    func publishTranscript() { transcriptChanges.send(presentedMessages) }
    /// "Retrying (attempt 2 of 3) after: …" while the helper waits to retry a transient failure.
    @Published var retryNotice: String? { didSet { if retryNotice != oldValue { publishTranscript() } } }
    /// A submission the host or app refused; cleared by the next send.
    @Published var sendFailure: String? { didSet { if sendFailure != oldValue { publishTranscript() } } }
    func observeRetry(_ snapshot: [String: WireValue]) {
        let retry = snapshot["retry"]?.object
        let notice: String? = retry.flatMap { value in
            guard let attempt = value["attempt"]?.number, let of = value["of"]?.number else { return nil }
            let reason = value["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "Retrying (attempt \(Int(attempt)) of \(Int(of)))" + (reason.isEmpty ? "…" : " after: " + reason)
        }
        if retryNotice != notice { retryNotice = notice }
    }
    let composerDraft = ComposerDraft()
    var draft: String { get { composerDraft.text } set { if composerDraft.text != newValue { composerDraft.text = newValue } } }
    @Published var attachments: [AttachmentRecord] = []
    @Published var skills: [SkillChip] = []
    @Published var directCommand = false
    @Published var completionVisible = false
    @Published var completionIndex = 0
    @Published var state = "idle"
    @Published var runStatus = "idle"
    /// Bumped when the pane should move keyboard focus into the composer.
    @Published var composerFocusRequest = 0
    @Published var failureMessage: String? { didSet { if failureMessage != oldValue { publishTranscript() } } }
    @Published var queuePaused = false { didSet { if queuePaused != oldValue { publishTranscript() } } }
    var canResumeQueue: Bool { !busy && (queuePaused || ["paused", "interrupted"].contains(state)) }
    func observeRunState(_ snapshot: [String: WireValue]) {
        let rawState = snapshot["state"]?.string ?? "idle", run = snapshot["runStatus"]?.string ?? rawState
        // Older helpers reported failed runs as paused. Keep the run's outcome
        // separate from whether its remaining follow-ups require Resume.
        let nextState = run == "failed" && !["queued", "running", "stopping", "compacting"].contains(rawState) ? "error" : rawState
        if state != nextState { state = nextState }
        if runStatus != run { runStatus = run }
        let paused = snapshot["queuePaused"]?.bool ?? ["paused", "interrupted"].contains(rawState)
        if queuePaused != paused { queuePaused = paused }
        let detail = snapshot["preflightError"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = nextState == "error" ? (detail?.isEmpty == false ? detail : "Run failed.") : nil
        if failureMessage != failure { failureMessage = failure }
    }
    func observeRetainedFailure(_ message: String?) {
        guard !busy, !loading else { return }
        if let message {
            state = "error"; runStatus = "failed"; failureMessage = message
        } else if state == "error" {
            state = "idle"; runStatus = "idle"; failureMessage = nil
        }
    }
    /// Set when a compaction finishes; shown above the composer until the next send or dismissal.
    @Published var compactionNotice: String?
    private var compactionBaselineLoaded = false
    private var observedCompactionID: String?
    /// Status snapshots carry the successful summary that is still in active
    /// context, independently of the visible transcript page. Opening history
    /// establishes a baseline; only a new committed summary produces a notice.
    func observeCompaction(_ snapshot: [String: WireValue], baseline: Bool = false) {
        let summary = snapshot["latestSuccessfulCompaction"]?.object
        let id = summary?["id"]?.string
        if baseline || !compactionBaselineLoaded {
            compactionBaselineLoaded = true; observedCompactionID = id
            return
        }
        if snapshot["runStatus"]?.string == "compacting" { compactionNotice = nil }
        guard id != observedCompactionID else { return }
        observedCompactionID = id
        compactionNotice = id == nil ? nil : summary?["detail"]?.string
    }
    var activity: [String: WireValue] = [:]
    var activityObservedAt: Double = 0
    @Published var queue: [[String: WireValue]] = []
    var queueCount = 0
    @Published var notice = ""
    @Published var before: String?
    @Published var hostBefore: Double?
    var loadingEarlier = false
    @Published var loading = false
    var scrollAnchor: TranscriptAnchor?
    @Published var viewportRequest = 0
    let footer = SessionMetrics()
    var context: [String: WireValue] { get { footer.context } set { footer.context = newValue } }
    func observeContext(_ snapshot: [String: WireValue], baseline: Bool = false) {
        // A newly opened helper starts a new sequence epoch, even when the
        // desktop still has this session's previous prepared estimate.
        if baseline { footer.preparedContext = nil }
        if let context = snapshot["context"]?.object, context != self.context, acceptsContext(context) { self.context = context }
        if let sequence = snapshot["seq"]?.number, let preview = footer.preparedContext, sequence > preview.sequence {
            footer.preparedContext = nil
        }
    }
    /// The helper's count flickers during a run: each appended message clears
    /// it to "pending" and each prepared request replaces it with an estimate.
    /// Keep the last settled count on screen; mid-run, only a count anchored on
    /// gateway-reported usage may replace it. Compaction still resets the ring.
    func acceptsContext(_ context: [String: WireValue]) -> Bool {
        let hasCount = context["tokens"]?.number != nil
        if !hasCount { return context["state"]?.string == "post-compaction" || self.context["tokens"]?.number == nil }
        return !busy || context["method"]?.string == "usage-baseline"
    }
    var metrics: [String: WireValue] { get { footer.metrics } set { footer.metrics = newValue } }
    var turnTiming: [String: WireValue] { get { footer.turnTiming } set { footer.turnTiming = newValue } }
    @Published var captureMode = "persist"
    @Published var captureAvailable = false
    @Published var recovered: [CommandIntent] = []
    /// Edit-and-resend: the user message whose text is loaded in the composer, and the draft it replaced.
    @Published var editingMessageID: String?
    var draftBeforeEdit: DraftRecord?
    var savedDraft: DraftRecord {
        let edit = editingMessageID.map { MessageEditDraft(messageID: $0, originalText: draftBeforeEdit?.text ?? "", originalAttachments: draftBeforeEdit?.attachments, originalSkills: draftBeforeEdit?.skills) }
        return DraftRecord(id: id, text: draft, attachments: attachments, skills: skills, edit: edit)
    }
    func restoreDraft(_ saved: DraftRecord) {
        draft = saved.text; attachments = saved.attachments ?? []; skills = saved.skills ?? []; directCommand = false
        editingMessageID = saved.edit?.messageID
        draftBeforeEdit = saved.edit.map { DraftRecord(id: id, text: $0.originalText, attachments: $0.originalAttachments, skills: $0.originalSkills) }
    }
    var displayObservedAt: Double?
    var projectionRevision: String?
    var browsingHistory = false
    var footerUpdatedAt = 0.0
    var accountingUpdatedAt = 0.0
    var accountingRevision = 0
    var messageAccounting: [String: GatewayTotals] = [:]
    var lastSequence: Double = -1
    var snapshotInFlight = false
    var dirty = false
    var uncertain = false
    @Published var contextSelectionReady = false
    var used = Date()
    init(id: String) { self.id = id }
    var busy: Bool { ["queued", "running", "stopping", "compacting"].contains(state) }
    var hasWork: Bool { busy || queueCount > 0 }
}

enum WorkspacePage: String, Sendable { case chats, report }

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var workspaces: [WorkspaceRecord] = []
    @Published var chats: [ChatRecord] = []
    @Published var unreadStates: [String: SessionReadState] = [:]
    var dirtyReadStates: Set<String> = []
    var readStateWrites: [String: Task<Void, Never>] = [:]
    @Published var profiles: [ProfileRecord] = []
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { messageNavigationRevision += 1; cancelAutomaticContext() } }
    }
    /// Invalidates delayed report-to-message navigation when another target wins.
    var messageNavigationRevision = 0
    @Published var focusedSessionID: String? { didSet { if focusedSessionID != oldValue { cancelAutomaticContext() } } }
    @Published var selected: SessionDisplay?
    @Published var error: String?
    /// New chats that exist only on screen until their first message is sent.
    /// Nothing is written for them: no chat record, draft, journal or helper session.
    var pendingChatIDs: Set<String> = []
    @Published var showProfiles = false
    @Published var profileChoice = ""
    @Published var selectedWorkspaceID: String?
    @Published var showArchivedSessions = false
    @Published var showBackgroundSessions = false
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
    @Published var projectSidebarStates: [String: ProjectSidebarState] = [:]
    var projectSidebarWrites: [String: Task<Void, Never>] = [:]
    var dirtyProjectSidebarStates: Set<String> = []
    @Published var workspaceChangesInFlight: Set<String> = []
    @Published var installPreparing = false
    @Published var showMessageViewer = false
    @Published var showConversationContent = false
    var contentSessionID: String?
    @Published var showInspector = false
    /// Which page the main window shows; the chat pane stays mounted underneath the report.
    @Published var page: WorkspacePage = .chats {
        didSet { if page == .report && page != oldValue { messageNavigationRevision += 1 } }
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
    var conversationCommandsEnabled: Bool { page == .chats && (focusedSessionID ?? selectedID).flatMap(record) != nil }
    var inspectorMessageID: String?
    @Published var showMessageDetail = false
    var messageDetailID: String?
    var messageDetailSessionID: String?
    @Published var showResources = false
    @Published var showWorkspaceManager = false
    @Published var resourceCatalog: [SkillDescriptor] = []
    @Published var resourceCatalogWorkspaceID: String?
    @Published var resourceCatalogSessionID: String?
    @Published var resourceTargetSessionID: String?
    @Published var inspectorSessionID: String?
    @Published var messageViewerSessionID: String?
    @Published var sides: [String: SideRecord] = [:]
    @Published var resourceLoading = false
    @Published var resourceNotice = ""
    /// Retained gateway totals for chats without a loaded display, keyed by chat id.
    @Published var chatStats: [String: GatewayTotals] = [:]
    var accountingTasks: [String: Task<Void, Never>] = [:]
    var dirtyAccounting: Set<String> = []
    var chatStatsRevision = 0
    var chatStatsVersions: [String: Int] = [:]
    var accountingStopped = false
    let root: URL
    let vault: ConfigurationVault
    @Published var configuration = VaultConfiguration()
    @Published var configurationLoaded = false
    let store: MetadataStore?
    let history = HistoryReader()
    let modelCatalog = ModelCatalog()
    let traces: PayloadArchive
    private let liveExporter: TraceArchive
    var displays: [String: SessionDisplay] = [:]
    var hosts: [String: HostSupervisor] = [:]
    var opened: Set<String> = []
    var automaticContextTask: AutomaticContextTask?
    /// Test injection runs behind the same selection, input and safety guards.
    var automaticContextOperation: AutomaticContextOperation?
    /// Picker saves are ordered per connection; new chats await its pending choice.
    var overrideWrites: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var idleTasks: [String: Task<Void, Never>] = [:]
    private var draftTasks: [String: Task<Void, Never>] = [:]
    private var loading = false
    private var draftSaveFailed = false
    private var creatingOnboardingChat = false
    var hasActiveWork: Bool { !workspaceChangesInFlight.isEmpty || !titleGenerationTasks.isEmpty || displays.values.contains { $0.hasWork || $0.loading } || sides.values.contains { !$0.kept && !$0.pending } }
    var chat: ChatRecord? { chats.first { $0.id == selectedID } }
    var requestProfiles: [ProfileRecord] { profiles.filter { $0.api == LiteLLMConfiguration.supportedAPI } }

    init(stateRoot: URL? = nil, vault: ConfigurationVault = .shared) {
        self.vault = vault
        let benchmarkRoot = PerformanceProbe.shared.enabled ? ProcessInfo.processInfo.environment["PI_APP_BENCHMARK_STATE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
        root = stateRoot ?? benchmarkRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.belloware.PiApp", isDirectory: true)
        traces = PayloadArchive(root: root.appendingPathComponent("Requests-v1", isDirectory: true))
        liveExporter = TraceArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("BelloAgent-Export-" + UUID().uuidString))
        do { store = try MetadataStore(url: root.appendingPathComponent("desktop.sqlite")) }
        catch { store = nil; self.error = "Cannot open desktop metadata. Sending is disabled to preserve command intent." }
        report.attach(self)
    }
    func restore() async {
        guard !loading, let store else { return }; loading = true
        do {
            chats = try await store.loadChats()
            try await restoreReadStates()
            do { try await reloadConfiguration() } catch { self.error = error.localizedDescription }
            await reconcileSideKeeps()
            try await restoreProjectSidebarStates()
            selectedWorkspaceID = workspaces.first?.id; profileChoice = requestProfiles.first?.id ?? ""
            // Restore history without opening every runtime. Only the focused,
            // safe native chat may prepare its context in the background.
            if let first = chats.first(where: { !$0.isArchived && !$0.isBackgroundTask }) { await select(first.id, revealInSidebar: false) }
            try? await traces.reconcile()
            await refreshChatStats()
        } catch { loading = false; self.error = "Chats could not be restored. \(error.localizedDescription)" }
    }
    func pickWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.message = "Choose the working directory for Bello Agent."
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        let existing = workspaces.first(where: { $0.path == url.path })
        if let existing, existing.trusted { selectedWorkspaceID = existing.id; return }
        let workspace = WorkspaceRecord(id: existing?.id ?? UUID().uuidString, path: url.path, trusted: true, paths: existing?.paths ?? [])
        Task { do { try await updateConfiguration {
            if let index = $0.workspaces.firstIndex(where: { $0.id == workspace.id }) { $0.workspaces[index] = workspace }
            else { $0.workspaces.append(workspace) }
        }; selectedWorkspaceID = workspace.id }
            catch { self.error = error.localizedDescription } }
    }
    func newChat() {
        guard !installPreparing else { return }
        page = .chats
        guard let workspaceID = selectedWorkspaceID, profiles.contains(where: { $0.id == profileChoice }) else {
            if workspaces.isEmpty { showWorkspaceManager = true } else { showProfiles = true }; return
        }
        guard workspaces.contains(where: { $0.id == workspaceID && $0.trusted }), !workspaceChangesInFlight.contains(workspaceID) else { error = "Wait for project changes to finish and choose a trusted project."; return }
        guard requestProfiles.contains(where: { $0.id == profileChoice }) else { error = LiteLLMConfiguration.unsupportedAPIMessage; showProfiles = true; return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before creating a chat."; return }
        if let current = selectedID, isPendingEmpty(current), record(current)?.workspaceID == workspaceID, record(current)?.profileID == profileChoice {
            displays[current]?.composerFocusRequest += 1; return
        }
        workspaceChangesInFlight.insert(workspaceID)
        let profileID = profileChoice, pendingChoice = overrideWrites[profileChoice]?.task
        let previousChatID = focusedSessionID ?? selectedID
        Task { defer { workspaceChangesInFlight.remove(workspaceID); if let id = selectedID { scheduleAutomaticContext(id) } }
            do {
                await pendingChoice?.value
                var item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "New chat", path: nil, profileID: profileID)
                let remembered = try await store.get(ChatModelDefaults.self, kind: ChatModelDefaults.recordKind, id: profileID)
                // On upgrade there may be a chosen model in the current chat
                // but no defaults record yet. Never inherit another gateway.
                let previous = previousChatID.flatMap(record).flatMap { $0.profileID == profileID && !$0.isBackgroundTask ? ChatModelDefaults(chat: $0) : nil }
                (remembered ?? previous)?.apply(to: &item, profile: profiles.first { $0.id == profileID })
                if remembered?.outputBudgetVersion == nil, item.outputBudgetVersion == 1, remembered != nil {
                    try await store.put(ChatModelDefaults(chat: item), kind: ChatModelDefaults.recordKind, id: profileID)
                }
                // Created on screen only; the first send writes it (materializeChat).
                pendingChatIDs.insert(item.id); chats.insert(item, at: 0); await select(item.id)
            }
            catch { self.error = error.localizedDescription } }
    }
    /// Writes a pending chat's record before its first message, rename,
    /// archive, connection change or helper session needs it.
    func materializeChat(_ id: String) async throws {
        guard pendingChatIDs.contains(id), let item = chats.first(where: { $0.id == id }) else { return }
        guard let store else { throw StoreError.unavailable }
        try await store.put(item, kind: "chat", id: id)
        pendingChatIDs.remove(id)
        if let draft = displays[id]?.savedDraft, !draft.text.isEmpty || !(draft.attachments ?? []).isEmpty { try await store.put(draft, kind: "draft", id: id) }
    }
    /// Drops a pending chat that never received a message. Nothing was written.
    func discardPendingChat(_ id: String) {
        guard pendingChatIDs.remove(id) != nil else { return }
        chats.removeAll { $0.id == id }; displays.removeValue(forKey: id); opened.remove(id)
        if selectedID == id { selectedID = nil; selected = nil }
        if focusedSessionID == id { focusedSessionID = nil }
    }
    func isPendingEmpty(_ id: String) -> Bool {
        guard pendingChatIDs.contains(id) else { return false }
        guard let view = displays[id] else { return true }
        return view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && view.attachments.isEmpty && view.skills.isEmpty
    }
    func createOnboardingChat() async throws {
        guard !installPreparing, !creatingOnboardingChat else {
            throw HostError.failure("A chat or app update is already being prepared.")
        }
        creatingOnboardingChat = true
        defer { creatingOnboardingChat = false }
        try await ensureConfiguration()
        guard let workspaceID = selectedWorkspaceID,
              workspaces.contains(where: { $0.id == workspaceID && $0.trusted }),
              !workspaceChangesInFlight.contains(workspaceID),
              requestProfiles.contains(where: { $0.id == profileChoice }) else {
            throw HostError.failure("Choose a saved Responses connection and a trusted project first.")
        }
        workspaceChangesInFlight.insert(workspaceID)
        defer { workspaceChangesInFlight.remove(workspaceID); if let id = selectedID { scheduleAutomaticContext(id) } }
        guard let store else { throw HostError.failure("Desktop storage is unavailable. Your setup is saved; try again after resolving the storage error.") }
        let item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "New chat", path: nil, profileID: profileChoice)
        try await store.put(item, kind: "chat", id: item.id)
        chats.insert(item, at: 0)
        await select(item.id)
    }
    func select(_ id: String, revealInSidebar: Bool = true) async {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        if let previous = selectedID, previous != id, isPendingEmpty(previous) { discardPendingChat(previous) }
        if revealInSidebar { revealProjectChat(item) } else { showArchivedSessions = item.isArchived }
        PerformanceProbe.shared.beginSelection(id, hasHistory: item.path != nil)
        selectedID = id; profileChoice = item.profileID
        // A chat outside any project never becomes the target for new chats.
        if item.workspaceID != WorkspaceRecord.scratchID { selectedWorkspaceID = item.workspaceID }
        focusedSessionID = id; page = .chats
        let view = displays[id] ?? SessionDisplay(id: id); view.used = Date(); displays[id] = view; selected = view
        view.contextSelectionReady = false
        var contextReady = false
        defer {
            if selectedID == id, displays[id] === view {
                view.contextSelectionReady = contextReady
                if contextReady { scheduleAutomaticContext(id) }
            }
        }
        if let sideID = sides[id]?.id { refresh(sideID) }
        // Drop hidden, idle display pages. Persistent history and drafts are loaded on demand.
        for other in displays.values.sorted(by: { $0.used < $1.used }) where displays.count > 8 && other.id != id && !other.hasWork && !other.loading && !sides.values.contains(where: { $0.id == other.id || $0.parentID == other.id }) {
            displays.removeValue(forKey: other.id)
        }
        do {
            if !opened.contains(id) { view.captureMode = try await capturePreference(sessionID: id).mode; view.captureAvailable = false }
            if let draft = try await store?.get(DraftRecord.self, kind: "draft", id: id), view.draft.isEmpty && view.skills.isEmpty && view.attachments.isEmpty && view.editingMessageID == nil { view.restoreDraft(draft) }
            if view.scrollAnchor == nil { view.scrollAnchor = try await store?.get(TranscriptAnchor.self, kind: "anchor", id: id) }
            view.recovered = try await store?.list(CommandIntent.self, kind: "pending:\(id)") ?? []
            view.uncertain = !view.recovered.isEmpty
            // An unloaded chat shows its newest page; earlier pages load as the
            // reader scrolls up. A saved reading position is honoured when it is
            // inside that page, otherwise the chat opens at its latest message.
            if let path = item.path, !opened.contains(id) {
                let historySequence = view.lastSequence
                let page = try await history.read(path: path)
                guard selectedID == id else { return }
                if page.notice == nil, let count = page.assistantMessageCount {
                    observeAssistantOutputs(sessionID: id, snapshot: ["assistantMessageCount": .number(Double(count)), "latestAssistantMessageId": page.latestAssistantMessageID.map(WireValue.string) ?? .null])
                }
                view.browsingHistory = false
                if let anchor = view.scrollAnchor, !anchor.followsBottom, !page.messages.contains(where: { $0.id == anchor.id }) { view.scrollAnchor = nil }
                view.messages = page.messages; view.before = page.before; view.notice = page.notice ?? (item.imported ? "Imported original · Read-only. Continue creates a separate managed copy." : "Saved history · Host unloaded")
                if page.notice == nil, !opened.contains(id), view.lastSequence == historySequence { view.observeRetainedFailure(page.failureMessage) }
            }
            await refreshAccounting(view, workspaceID: item.workspaceID)
            if let profile = profiles.first(where: { $0.id == item.profileID }), profile.api != LiteLLMConfiguration.supportedAPI {
                view.notice = LiteLLMConfiguration.unsupportedAPIMessage
            }
            contextReady = true
            view.composerFocusRequest += 1
            if opened.contains(id) { refresh(id); return }
            if !view.recovered.isEmpty {
                view.uncertain = true; view.notice = "Outcome uncertain for a previous command. Review the saved history before sending again."; if view.state != "error" { view.state = "interrupted" }
            }
        } catch { view.notice = "History could not be read. Original files were preserved. \(error.localizedDescription)" }
    }
    /// Puts the cursor in a chat's composer: the given chat, else the focused
    /// side, else the selected chat. Every deliberate move between chats calls
    /// this so typing can start at once; background events never do.
    func focusComposer(_ id: String? = nil) {
        guard let target = id ?? focusedSessionID ?? selectedID else { return }
        displays[target]?.composerFocusRequest += 1
    }
    func selectSide(_ id: String) async {
        guard let info = side(id), displays[id] != nil else {
            // A saved child chat that is not the shown side opens in the pane.
            if chats.contains(where: { $0.id == id && $0.parentSessionID != nil }) { await showSide(id) }
            return
        }
        if selectedID != info.parentID { await select(info.parentID) }
        guard selectedID == info.parentID, side(id) != nil else { return }
        page = .chats; focusedSessionID = id
        if let child = record(id) { revealProjectChat(child) }
        focusComposer(id)
        scheduleAutomaticContext(id)
    }
    func draftChanged(_ view: SessionDisplay) {
        scheduleAutomaticContext(view.id, delay: WorkspaceModel.typingPreviewDelay)
        // Unkept side drafts stay in memory by design; on host loss their text
        // is moved into the parent composer instead (discardLostSides).
        guard !isEphemeral(view.id), !pendingChatIDs.contains(view.id) else { return }
        draftTasks[view.id]?.cancel()
        let draft = view.savedDraft
        draftTasks[view.id] = Task {
            do {
                guard let store else { throw StoreError.unavailable }
                let revision = try await store.reserveRevision(kind: "draft", id: draft.id)
                try await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }
                try await store.put(draft, kind: "draft", id: draft.id, revision: revision); draftSaveFailed = false
            }
            catch is CancellationError { }
            catch StoreError.staleRevision { /* A newer send, flush or edit already saved this draft. */ }
            catch {
                // A full disk fails every debounce tick; report it once, not per keystroke.
                guard !draftSaveFailed else { return }
                draftSaveFailed = true; self.error = "Draft could not be saved. \(error.localizedDescription)"
            }
        }
    }
    /// Writes every pending draft and anchor now. Quit calls this so the
    /// 150 ms debounce cannot lose the last thing typed; the update path does
    /// the same inside prepareForInstall.
    func flushDrafts() async throws {
        for task in draftTasks.values { task.cancel() }; draftTasks.removeAll()
        let retained = displays.values.filter { !isEphemeral($0.id) }
        guard !retained.isEmpty else { return }
        guard let store else { throw StoreError.unavailable }
        for view in retained {
            try await store.put(view.savedDraft, kind: "draft", id: view.id)
            if let anchor = view.scrollAnchor { try await store.put(anchor, kind: "anchor", id: view.id) }
        }
    }
    func anchorChanged(_ view: SessionDisplay) {
        guard !isEphemeral(view.id) else { return }
        let anchor = view.scrollAnchor
        Task { if let anchor { try? await store?.put(anchor, kind: "anchor", id: view.id) }
            else { try? await store?.remove(kind: "anchor", id: view.id) } }
    }
    func host(for workspace: WorkspaceRecord) async throws -> HostSupervisor {
        guard !workspaceChangesInFlight.contains(workspace.id) else { throw HostError.failure("Wait for this project's folder changes to finish before starting work.") }
        idleTasks[workspace.id]?.cancel()
        if let existing = hosts[workspace.id], existing.isReady { return existing }
        try await ensureConfiguration()
        if workspace.isScratch {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: workspace.path, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            guard configuration.workspaces.contains(workspace), workspace.trusted else { throw HostError.failure("Trust this project in the configuration vault before starting tools.") }
        }
        let limit = configuration.runtime.workspaceConcurrency
        if hosts.values.filter({ $0.isReady }).count >= limit {
            if let idle = hosts.first(where: { !$0.value.isBusy && $0.key != workspace.id }) { idle.value.shutdown(); hosts.removeValue(forKey: idle.key); opened.subtract(chats.filter { $0.workspaceID == idle.key }.map(\.id)) }
            else { throw HostError.failure("The configured project concurrency limit is in use. Stop another project or change Settings.") }
        }
        let host = hosts[workspace.id] ?? HostSupervisor(); hosts[workspace.id] = host
        host.onEvent = { [weak self] frame in
            guard let id = frame["sessionId"]?.string else { return }
            if frame["type"]?.string == "session.changed" { self?.refresh(id) }
            if frame["type"]?.string == "session.unloaded" { self?.opened.remove(id); self?.displays[id]?.notice = "Saved history · Host runtime unloaded"; self?.displays[id]?.captureAvailable = false }
        }
        host.onLoss = { [weak self] in
            guard let self else { return }
            self.discardLostSides(workspaceID: workspace.id)
            for chat in self.chats where chat.workspaceID == workspace.id {
                self.opened.remove(chat.id); self.displays[chat.id]?.captureAvailable = false
                self.displays[chat.id]?.lastSequence = -1
                if let view = self.displays[chat.id], view.hasWork, view.state != "error" { view.state = "interrupted"; view.runStatus = "interrupted"; view.queueCount = 0; view.uncertain = true; view.notice = "Host interrupted. Outcome uncertain. No command was replayed." }
            }
        }
        let state = root.appendingPathComponent("Workspaces/\(workspace.id)", isDirectory: true)
        let archive = traces, workspaceID = workspace.id
        try await host.connect(cwd: URL(fileURLWithPath: workspace.path), state: state, runtime: configuration.runtime, capture: { [weak self] packet in
            try await archive.accept(packet, workspace: workspaceID)
            // A final capture can arrive after the last session-status event.
            // Refresh accounting from its committed metadata, without waiting
            // for the user to focus this conversation again.
            await self?.captureDidPersist(packet, workspaceID: workspaceID)
        })
        // "cwd" remains for hosts that predate multi-folder roots; "roots" lists every trusted folder, primary first.
        _ = try await host.request("workspace.open", params: ["cwd": .string(workspace.path), "roots": .array(workspace.roots.map(WireValue.string)), "directory": .string(state.appendingPathComponent("Sessions").path), "captureProtocol": .number(1), "resources": try await resourceSettings(workspaceID: workspace.id), "mcp": configuration.mcp[workspace.id] ?? .object(["servers": .object([:])])])
        if PerformanceProbe.shared.enabled { try await host.calibrateClock() }
        return host
    }
    func open(_ item: ChatRecord, automaticContext: Bool = false) async throws -> HostSupervisor {
        if automaticContext { try requireAutomaticContext(item.id) }
        guard let store else { throw StoreError.unavailable }
        guard !workspaceChangesInFlight.contains(item.workspaceID) else { throw HostError.failure("Wait for this project's folder changes to finish before starting work.") }
        if let profile = profiles.first(where: { $0.id == item.profileID }) { try LiteLLMConfiguration.requireSupportedAPI(profile.api) }
        if opened.contains(item.id), let host = hosts[item.workspaceID], host.isReady { idleTasks[item.workspaceID]?.cancel(); return host }
        if isEphemeral(item.id) { throw HostError.failure("This unkept side lost its host. Open a new side from the parent; nothing was replayed.") }
        try await materializeChat(item.id)
        guard !item.imported, let workspace = workspace(for: item.workspaceID), workspace.trusted, let profile = profiles.first(where: { $0.id == item.profileID }) else { throw HostError.failure("This chat needs its saved profile and trusted project. Imported originals cannot be written.") }
        let credential = try await credentials(for: profile)
        if automaticContext { try requireAutomaticContext(item.id) }
        let key = credential["apiKey"]?.string ?? ""
        do { if key.isEmpty { throw HostError.failure("Save an API key in Keychain for this profile") } }
        catch let error as HostError { throw error }
        catch { throw HostError.failure("The profile key is unavailable or Keychain access is locked. Review this profile in Settings.") }
        let host = try await host(for: workspace)
        defer { if automaticContext { scheduleIdle(workspaceID: item.workspaceID, host: host) } }
        if automaticContext {
            do { try requireAutomaticContext(item.id) }
            catch { scheduleIdle(workspaceID: item.workspaceID, host: host); throw error }
        }
        if !opened.contains(item.id) {
            var wire = profile.wire.object ?? [:]
            if let headers = credential["headers"] { wire["headers"] = headers }
            var params: [String: WireValue] = ["profile": .object(wire), "apiKey": .string(key), "toolMode": .string(item.toolMode)]
            if let handoff = try await store.get(WireValue.self, kind: "handoff", id: item.id) { params["handoff"] = handoff }
            if automaticContext { try requireAutomaticContext(item.id) }
            if item.connectionTest == true || workspace.isScratch { params["connectionTest"] = .bool(true) }
            if item.backgroundTask == "session-title" { params["backgroundTask"] = .string("session-title") }
            if let path = item.path { params["path"] = .string(path) }
            let initial = try await host.request("session.open", sessionID: item.id, params: params)
            // Previewing a fresh chat allocates a native journal too. Persist
            // its path before an idle unload, even when no message is sent.
            if let path = initial.object?["path"]?.string, let index = chats.firstIndex(where: { $0.id == item.id }) {
                chats[index].path = path
                // Always retry this durable write on a later open after a
                // storage failure, even though the in-memory path is known.
                try await store.put(chats[index], kind: "chat", id: item.id)
            }
            observeAssistantOutputs(sessionID: item.id, snapshot: initial.object ?? [:])
            displays[item.id]?.observeCompaction(initial.object ?? [:], baseline: true)
            displays[item.id]?.observeContext(initial.object ?? [:], baseline: true)
            opened.insert(item.id)
            let preference = try await capturePreference(sessionID: item.id)
            _ = try await host.request("debug.mode", sessionID: item.id, params: ["mode": .string(preference.mode)])
            displays[item.id]?.captureMode = preference.mode; displays[item.id]?.captureAvailable = true
            displays[item.id]?.lastSequence = -1
        }
        return host
    }
    func send(steer: Bool = false, sessionID: String? = nil) {
        // Global commands target the visible conversation. Explicit session
        // submissions already accepted by an asynchronous side flow continue.
        guard sessionID != nil || page == .chats else { return }
        if let id = sessionID ?? focusedSessionID ?? selectedID, let view = displays[id], view.editingMessageID != nil {
            if steer { view.notice = "Finish or cancel this edit before steering the current run." }
            else { sendEdit(sessionID: id) }
            return
        }
        guard let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), !item.isBackgroundTask, let view = displays[id], (!view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !view.skills.isEmpty), !view.loading, !installPreparing, side(id)?.keeping != true else { return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before sending."; return }
        if resolveLeadingCommand(view, steer: steer) { return }
        guard view.draft.utf8.count <= 262_144 else { error = "The draft exceeds the 256 KiB submission limit"; return }
        if view.uncertain {
            let alert = NSAlert(); alert.messageText = "Previous command outcome is uncertain"
            alert.informativeText = "Review the transcript and any file or tool effects. Sending again starts a new command and may repeat effects."
            alert.addButton(withTitle: "I Reviewed It — Send New Command"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; view.uncertain = false
        }
        let attachments = view.attachments, skills = view.skills
        let text = view.draft, commandID = UUID().uuidString, turnID = UUID().uuidString, previousState = view.state
        view.loading = true; view.compactionNotice = nil
        view.sendFailure = nil
        Task {
            defer { view.loading = false }
            var dispatched = false
            do {
                try await materializeChat(item.id)
                if let info = side(item.id), info.pending { try await publishPendingSide(info, view: view) }
                if !isEphemeral(item.id) { try await store.put(DraftRecord(id: item.id, text: text, attachments: attachments, skills: skills), kind: "draft", id: item.id) }
                let host = try await open(item)
                let intent = CommandIntent(id: commandID, sessionID: item.id, turnID: turnID, text: text, state: "intent", epoch: host.epoch, attachments: attachments, skills: skills)
                if !isEphemeral(item.id) { try await store.put(intent, kind: "pending:\(item.id)", id: commandID) }
                dispatched = true
                if !view.busy { view.state = "running" }
                _ = try await host.request(steer ? "turn.steer" : "turn.submit", sessionID: item.id,
                                          params: TurnOverrides.params(for: item, base: ["text": .string(text), "clientTurnId": .string(turnID), "attachments": .array(attachments.map(\.wire)), "skills": .array(skills.map(\.wire))]), commandID: commandID)
                if !isEphemeral(item.id) { try await store.acknowledgeCommand(sessionID: item.id, commandID: commandID) }
                if view.draft == text { view.draft = ""; view.attachments.removeAll { attachments.contains($0) }; view.skills.removeAll { skills.contains($0) }; view.directCommand = false; draftChanged(view) }
                if let index = chats.firstIndex(where: { $0.id == item.id }), chats[index].titleWasEdited != true, chats[index].titleWasGenerated != true,
                   chats[index].title == "New chat" || (chats[index].parentSessionID != nil && chats[index].title.hasSuffix(" — side")) {
                    if chats[index].title == "New chat" {
                        chats[index].title = String((text.isEmpty ? skills.map { "/" + $0.name }.joined(separator: " ") : text).prefix(60)).replacingOccurrences(of: "\n", with: " "); try await store.put(chats[index], kind: "chat", id: item.id)
                    }
                    scheduleTitleGeneration(sourceID: item.id, input: text)
                }
                refresh(item.id)
            } catch {
                // The failure sits in the conversation, under the messages, not in a fixed strip.
                view.sendFailure = error.localizedDescription
                if case HostError.rejected = error { try? await store.remove(kind: "pending:\(item.id)", id: commandID); view.state = previousState }
                else { view.uncertain = dispatched; view.state = dispatched ? "interrupted" : previousState }
            }
        }
    }
    func refresh(_ id: String) {
        guard let item = record(id), let host = hosts[item.workspaceID], opened.contains(id) else { return }
        let view = displays[id] ?? SessionDisplay(id: id); displays[id] = view
        view.dirty = true
        guard !view.snapshotInFlight else { return }; view.snapshotInFlight = true
        Task {
            defer { view.snapshotInFlight = false; if view.dirty { refresh(id) } }
            view.dirty = false
            do {
                let visible = id == selectedID || sides[selectedID ?? ""]?.id == id
                var params: [String: WireValue] = ["includeMessages": .bool(!view.browsingHistory)]
                let requestedRevision = view.projectionRevision
                if let requestedRevision { params["displayRevision"] = .string(requestedRevision) }
                let result = try await host.request(visible ? "session.snapshot" : "session.status", sessionID: id, params: params).object ?? [:]
                await applySideStatus(id: id, result: result)
                let sequence = result["seq"]?.number ?? -1
                if sequence >= view.lastSequence {
                    view.lastSequence = sequence
                    observeAssistantOutputs(sessionID: id, snapshot: result)
                    view.observeCompaction(result)
                    view.observeRunState(result)
                    view.observeRetry(result)
                    let queue = result["queue"]?.array?.compactMap(\.object) ?? []; if view.queue != queue { view.queue = queue }
                    view.queueCount = Int(result["queueCount"]?.number ?? 0)
                    // Human-readable footer accounting refreshes at 4 Hz. Raw
                    // attempt timings and full precision remain in the host.
                    let now = ProcessInfo.processInfo.systemUptime
                    // Phase changes cannot wait for the footer throttle: a
                    // quiet tool may have no subsequent event until it ends.
                    view.activity = result["activity"]?.object ?? [:]; view.activityObservedAt = now
                    if now - view.footerUpdatedAt >= 0.25 || !view.busy {
                        view.footerUpdatedAt = now
                        view.observeContext(result)
                        if let timing = result["turnMetrics"]?.object, timing != view.turnTiming { view.turnTiming = timing }
                        if let metrics = result["latestAttempt"]?.object, metrics != view.metrics { view.metrics = metrics }
                    }
                    if let mode = result["captureMode"]?.string, mode != view.captureMode { view.captureMode = mode }
                    view.displayObservedAt = result["displayObservedAt"]?.number.map { $0 + host.clockOffset }
                    if let start = view.displayObservedAt { PerformanceProbe.shared.observe("deltaToNativeSnapshotMs", milliseconds: PerformanceProbe.now - start) }
                    if let value = result["messages"], !view.browsingHistory {
                        var messages = await Task.detached { (try? JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value))) ?? [] }.value
                        if !view.browsingHistory {
                            // Rows the reader scrolled up to stay in front of the helper's window.
                            let merged = TranscriptPaging.merge(previous: view.messages, live: messages)
                            let prepended = merged.count - messages.count
                            messages = merged
                            for index in messages.indices { messages[index].accounting = view.messageAccounting[messages[index].id] }
                            if view.messages != messages { view.messages = messages }
                            view.projectionRevision = result["displayRevision"]?.string
                            if view.before != nil { view.before = nil }
                            // The next earlier page starts before the earliest row shown, not before the window.
                            let before = result["before"]?.number.map { $0 - Double(prepended) }.flatMap { $0 > 0 ? $0 : nil }
                            if view.hostBefore != before { view.hostBefore = before }
                        }
                    } else if !view.browsingHistory && view.projectionRevision != requestedRevision {
                        view.dirty = true // An intervening page change needs a fresh full projection.
                    }
                    let notice = item.isBackgroundTask ? (record(id)?.backgroundTaskNotice ?? "Tools disabled · Title generation") : item.connectionTest == true || item.workspaceID == WorkspaceRecord.scratchID ? "Tools disabled · Connection test" : item.toolMode == "read-only" ? "Read-only tools" : ""
                    // An interruption or preflight explanation stays until the
                    // user has reviewed it; the static tool notice must not replace it.
                    if view.notice != notice, !view.uncertain, view.failureMessage == nil { view.notice = notice }
                    if let preflight = result["preflightError"]?.string { if view.failureMessage == nil { view.notice = preflight }; view.uncertain = true }
                    if let keepError = result["keepError"]?.string { view.notice = keepError }
                    if now - view.accountingUpdatedAt >= 0.25 || !view.busy {
                        view.accountingUpdatedAt = now
                        await refreshAccounting(view, workspaceID: item.workspaceID)
                    }
                }
                if let path = result["path"]?.string, let index = chats.firstIndex(where: { $0.id == id }), chats[index].path != path {
                    chats[index].path = path; try await store?.put(chats[index], kind: "chat", id: id)
                }
                let intents = try await store?.list(CommandIntent.self, kind: "pending:\(id)") ?? []
                for var intent in intents {
                    guard let receipt = result["commands"]?.array?.compactMap(\.object).last(where: { $0["commandId"]?.string == intent.id }), let state = receipt["state"]?.string else { continue }
                    if state != "dispatched" {
                        intent.state = state; intent.text = ""; intent.attachments = nil; intent.skills = nil
                        try await store?.put(intent, kind: "receipt:\(id)", id: intent.id)
                        try await store?.remove(kind: "pending:\(id)", id: intent.id)
                    }
                }
                let recovered = try await store?.list(CommandIntent.self, kind: "pending:\(id)") ?? []
                if recovered != view.recovered { view.recovered = recovered }
                if view.recovered.isEmpty { view.uncertain = false }
                updateHostActivity(workspaceID: item.workspaceID)
                scheduleIdle(workspaceID: item.workspaceID, host: host)
            } catch { view.notice = error.localizedDescription }
        }
    }
    func cancelIdle(workspaceID: String) { idleTasks.removeValue(forKey: workspaceID)?.cancel() }
    func scheduleIdle(workspaceID: String, host: HostSupervisor) {
        idleTasks[workspaceID]?.cancel(); guard !host.isBusy, !sides.values.contains(where: { $0.workspaceID == workspaceID && !$0.kept && !$0.pending }) else { return }
        let grace = configuration.runtime.idleGraceSeconds
        idleTasks[workspaceID] = Task { try? await Task.sleep(for: .seconds(grace)); guard !Task.isCancelled, !host.isBusy else { return }
            host.shutdown(); opened.subtract(chats.filter { $0.workspaceID == workspaceID }.map(\.id))
        }
    }
    func action(_ method: String, params: [String: WireValue] = [:], sessionID: String? = nil) {
        guard !installPreparing, let id = sessionID ?? selectedID, let item = record(id) else { return }
        if method == "context.compact" { displays[id]?.compactionNotice = nil }
        let commandID = UUID().uuidString
        Task { do {
            let host = try await open(item)
            if method == "context.compact" && !isEphemeral(item.id) {
                guard let store else { throw StoreError.unavailable }
                try await store.put(CommandIntent(id: commandID, sessionID: item.id, turnID: "compaction:\(commandID)", text: "[Compact now]", state: "intent", epoch: host.epoch), kind: "pending:\(item.id)", id: commandID)
            }
            _ = try await host.request(method, sessionID: item.id, params: params, commandID: commandID)
            if method == "queue.remove", let turnID = params["turnId"]?.string {
                for intent in try await store?.list(CommandIntent.self, kind: "pending:\(item.id)") ?? [] where intent.turnID == turnID { try await store?.remove(kind: "pending:\(item.id)", id: intent.id) }
            }
            if method == "queue.update", let turnID = params["turnId"]?.string, let text = params["text"]?.string, !isEphemeral(item.id) {
                // A recovered intent shows the text the host will actually deliver.
                for var intent in try await store?.list(CommandIntent.self, kind: "pending:\(item.id)") ?? [] where intent.turnID == turnID { intent.text = text; try await store?.put(intent, kind: "pending:\(item.id)", id: intent.id) }
            }
            refresh(item.id)
        }
            catch {
                // A rejected compaction never ran; a leftover intent would mark
                // the chat "outcome uncertain" on its next visit.
                if method == "context.compact", case HostError.rejected = error { try? await store?.remove(kind: "pending:\(item.id)", id: commandID) }
                self.error = error.localizedDescription
            } }
    }
    func stop(sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, let item = record(id), let host = hosts[item.workspaceID], opened.contains(item.id), let view = displays[id] else { return }
        view.state = "stopping"
        Task { do { _ = try await host.request("turn.stop", sessionID: item.id); refresh(item.id) }
            catch { view.state = "interrupted"; view.uncertain = true; view.notice = error.localizedDescription } }
    }
    /// Prepends the page before the earliest row shown, keeping the reader's
    /// place. The page asks for this as the reader nears the top; the header
    /// button asks explicitly. Live updates keep arriving underneath.
    func loadEarlier(sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, let item = record(id), let view = displays[id], !view.loadingEarlier else { return }
        view.loadingEarlier = true
        Task { defer { view.loadingEarlier = false }; do {
            var earlier: [TranscriptMessage] = []
            if opened.contains(item.id), let host = hosts[item.workspaceID] {
                guard let before = view.hostBefore else { return }
                let value = try await host.request("session.history", sessionID: item.id, params: ["before": .number(before)]).object ?? [:]
                earlier = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value["messages"] ?? .array([])))
                guard displays[id] === view else { return }
                view.hostBefore = value["before"]?.number
            } else if let path = item.path, let before = view.before {
                let page = try await history.read(path: path, before: before)
                guard displays[id] === view else { return }
                earlier = page.messages; view.before = page.before
            } else { return }
            var prefix = TranscriptPaging.prefix(earlier: earlier, shown: view.messages)
            guard !prefix.isEmpty else { return }
            for index in prefix.indices { prefix[index].accounting = view.messageAccounting[prefix[index].id] }
            // Keep the row that was first on screen where it is.
            if let first = view.messages.first {
                let offset = view.scrollAnchor?.id == first.id ? (view.scrollAnchor?.offset ?? 0) : 0
                view.scrollAnchor = .init(id: first.id, offset: offset, followsBottom: false)
            }
            view.messages = prefix + view.messages
            view.viewportRequest += 1; anchorChanged(view)
            await refreshAccounting(view, workspaceID: item.workspaceID)
        } catch { self.error = error.localizedDescription } }
    }
    func latest(sessionID: String? = nil) { if let id = sessionID ?? selectedID {
        if let view = displays[id], let item = record(id) {
            view.browsingHistory = false; view.projectionRevision = nil
            // A nil anchor would be reloaded from SQLite by select() before an
            // asynchronous deletion finished. Persist the explicit bottom intent.
            view.scrollAnchor = .init(id: view.messages.last?.id ?? "", offset: 0, followsBottom: true); view.viewportRequest += 1; anchorChanged(view)
            // Drop the pages scrolled up to; the helper's window or the file tail is the display again.
            if opened.contains(id) { view.messages = Array(view.messages.suffix(60)); view.hostBefore = nil }
            else if let path = item.path {
                Task { if let page = try? await history.read(path: path), displays[id] === view { view.messages = page.messages; view.before = page.before; view.viewportRequest += 1 } }
            }
        }
        if opened.contains(id) { refresh(id) } else { Task { await select(id) } }
    } }
    func rename() {
        if let id = focusedSessionID ?? selectedID { renameSession(id) }
    }
    func importChat() {
        guard let workspaceID = selectedWorkspaceID else { pickWorkspace(); return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before importing."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Open a Pi JSONL session read-only. The original file will remain unchanged."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do {
            let page = try await history.read(path: url.path)
            let item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: url.deletingPathExtension().lastPathComponent, path: url.path, profileID: profileChoice, imported: true)
            try await store.put(item, kind: "chat", id: item.id); chats.insert(item, at: 0); await select(item.id); selected?.notice = page.notice ?? "Imported original · Read-only. No historical HTTP capture is available."
        } catch { self.error = "Import could not be read. The original was preserved." } }
    }
    func continueCopy(recoverTail: Bool = false) {
        guard let item = chat, let source = item.path, let workspace = workspaces.first(where: { $0.id == item.workspaceID }), requestProfiles.contains(where: { $0.id == profileChoice }) else { error = "Choose a Responses connection for the continued copy"; return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        let profileID = profileChoice
        if recoverTail {
            let alert = NSAlert(); alert.messageText = "Create a recovered copy?"
            alert.informativeText = "Preserve the entire original in app storage, then omit only its incomplete final record in a new independent chat. Corruption before the final record will still be rejected. Review any interrupted tool effects before continuing."
            alert.addButton(withTitle: "Preserve and Recover Copy"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { do {
            let host = try await host(for: workspace), id = UUID().uuidString
            let result = try await host.request(recoverTail ? "session.import.recover" : "session.import.continue", params: ["path": .string(source), "newSessionId": .string(id)]).object ?? [:]
            guard let path = result["sessionFile"]?.string else { throw StoreError.invalidRecord }
            let copy = ChatRecord(id: id, workspaceID: item.workspaceID, title: item.title + " — continued", path: path, profileID: profileID, toolMode: item.toolMode)
            try await store.put(copy, kind: "chat", id: copy.id); chats.insert(copy, at: 0); await select(copy.id)
        } catch { self.error = "The source could not be continued safely. Check for an incomplete tail, changed source, or incompatible saved profile. Original preserved." } }
    }
    func portableHandoff() {
        guard let item = chat, let path = item.path, let workspace = workspaces.first(where: { $0.id == item.workspaceID }), requestProfiles.contains(where: { $0.id == profileChoice }) else { error = "Choose a source history and a Responses connection"; return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        let profileID = profileChoice
        Task { do {
            let host = try await host(for: workspace)
            let value = try await host.request("session.portable.preview", params: ["path": .string(path)]).object ?? [:]
            guard let text = value["draft"]?.string else { throw StoreError.invalidRecord }
            let alert = NSAlert(); alert.messageText = "Prepare a portable context draft?"
            alert.informativeText = "Create a new chat with editable text from Pi's compaction-aware context. Thinking, signatures, encrypted data, images, tool arguments and continuation cursors are omitted. A 128 KiB text limit applies. The complete original is preserved. Nothing is sent until you review and press Send."
            alert.addButton(withTitle: "Create Draft"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
            let copy = ChatRecord(id: UUID().uuidString, workspaceID: item.workspaceID, title: item.title + " — portable handoff", path: nil, profileID: profileID, toolMode: item.toolMode)
            try await store.commitPortableHandoff(copy, draft: DraftRecord(id: copy.id, text: text), provenance: value["provenance"])
            chats.insert(copy, at: 0); await select(copy.id)
        } catch { self.error = error.localizedDescription } }
    }
    func deleteChat() { deleteChat(selectedID) }
    /// Deletes any chat by id, so archived chats can go straight from the sidebar.
    func deleteChat(_ id: String?) {
        guard let id, let item = record(id) else { return }
        if pendingChatIDs.contains(id) { discardPendingChat(id); return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        if sides[id] != nil { error = "Close the side panel before deleting its parent."; return }
        if side(id) != nil { error = "Close this side panel before deleting its chat."; return }
        guard displays[id]?.hasWork != true, displays[id]?.loading != true else { error = "Stop work and remove queued submissions before deleting this chat"; return }
        let alert = NSAlert(); alert.messageText = item.isArchived ? "Delete the archived chat “\(item.title)”?" : "Delete this chat?"
        alert.informativeText = item.imported ? "Remove its app index and draft. The imported original stays in place." : "Move its managed conversation file to Trash and remove its draft and current memory traces, and locally retained traces."
        alert.addButton(withTitle: "Delete Chat"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do {
            if let host = hosts[item.workspaceID], host.isReady { _ = try await host.request("session.forget", sessionID: item.id) }
            opened.remove(item.id)
            try await traces.clear(sessionID: item.id)
            if !item.imported, let path = item.path, FileManager.default.fileExists(atPath: path) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                }
            }
            forgetReadState(item.id)
            for kind in ["chat", "draft", "anchor", "capture-preference", "handoff", "side-keep", "session-read"] { try await store.remove(kind: kind, id: item.id) }
            try await store.removeAll(kind: "receipt:\(item.id)")
            for intent in try await store.list(CommandIntent.self, kind: "pending:\(item.id)") { try await store.remove(kind: "pending:\(item.id)", id: intent.id) }
            chats.removeAll { $0.id == item.id }; displays.removeValue(forKey: item.id)
            if selectedID == item.id { selectedID = nil; selected = nil }
            if focusedSessionID == item.id { focusedSessionID = nil }
            do { try await removeDeletedCapturePreference(sessionID: item.id) }
            catch { self.error = "The chat was deleted, but its old capture preference could not be removed. \(error.localizedDescription)" }
        } catch { self.error = "Chat deletion did not complete. \(error.localizedDescription)" } }
    }
    func recoverDraft(_ intent: CommandIntent, insert: Bool) {
        guard let view = selected else { return }
        if insert { view.attachments = Array((view.attachments + (intent.attachments ?? [])).prefix(4)); for chip in intent.skills ?? [] where !view.skills.contains(where: { $0.id == chip.id }) && view.skills.count < 8 { view.skills.append(chip) }; view.draft += (view.draft.isEmpty ? "" : "\n\n") + intent.text; view.directCommand = false; draftChanged(view) }
        Task { do { try await store?.remove(kind: "pending:\(view.id)", id: intent.id); view.recovered.removeAll { $0.id == intent.id }; if view.recovered.isEmpty { view.uncertain = false } }
            catch { self.error = error.localizedDescription } }
    }
    func messagePage(id: String, field: String, offset: Int, sessionID: String? = nil) async throws -> (String, Int) {
        guard let target = sessionID ?? selectedID, let item = record(target) else { throw HostError.failure("Only retained completed messages can be opened") }
        if let host = hosts[item.workspaceID], opened.contains(item.id) {
            let value = try await host.request("session.message.read", sessionID: item.id, params: ["messageId": .string(id), "field": .string(field), "offset": .number(Double(offset))]).object ?? [:]
            return (value["text"]?.string ?? "", Int(value["totalCharacters"]?.number ?? 0))
        }
        guard let path = item.path else { throw HostError.failure("This session has no retained file") }
        return try await history.message(path: path, id: id, field: field, offset: offset)
    }
    func debugRequest(_ method: String, sessionID: String, params: [String: WireValue] = [:]) async throws -> [String: WireValue] {
        guard let item = record(sessionID), let host = hosts[item.workspaceID], host.isReady else { throw HostError.failure("No live capture for this session. Imported and unloaded history has no retroactive HTTP trace.") }
        return try await host.request(method, sessionID: sessionID, params: params).object ?? [:]
    }
    func testConnection(profileID: String) {
        guard requestProfiles.contains(where: { $0.id == profileID }) else { error = LiteLLMConfiguration.unsupportedAPIMessage; return }
        let alert = NSAlert(); alert.messageText = "Test this profile's connection?"
        alert.informativeText = "Send a real API request to the configured LiteLLM gateway. Its upstream provider may charge for it. The test runs in a saved chat with tools disabled, outside any project, so you can inspect it later."
        alert.addButton(withTitle: "Send Test Request"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do {
            let item = try await createConnectionTestChat(profileID: profileID)
            submitConnectionTestChat(item.id)
        } catch { self.error = error.localizedDescription } }
    }
    /// Selection can change while the saved test chat loads. Its submission
    /// always belongs to that chat, never to the newly selected conversation.
    func submitConnectionTestChat(_ id: String) {
        guard let view = displays[id], record(id)?.connectionTest == true else { return }
        view.draft = "Reply with OK to confirm this API connection."
        send(sessionID: id)
    }
    /// Connection tests need no project: the chat is saved under the scratch
    /// workspace so its request and reply stay inspectable in the sidebar and report.
    @discardableResult
    func createConnectionTestChat(profileID: String) async throws -> ChatRecord {
        guard requestProfiles.contains(where: { $0.id == profileID }) else { throw HostError.failure(LiteLLMConfiguration.unsupportedAPIMessage) }
        guard let store else { throw HostError.failure("Desktop storage is unavailable. Resolve the storage error before testing a connection.") }
        let item = ChatRecord(id: UUID().uuidString, workspaceID: WorkspaceRecord.scratchID, title: "Connection test", path: nil, profileID: profileID, toolMode: "read-only", connectionTest: true)
        try await store.put(item, kind: "chat", id: item.id); chats.insert(item, at: 0)
        page = .chats
        await select(item.id)
        return item
    }
    func capturePreference(sessionID: String) async throws -> CapturePreference {
        if isEphemeral(sessionID) { return CapturePreference(mode: displays[sessionID]?.captureMode ?? "memory", since: "") }
        try await ensureConfiguration()
        return CapturePreference(mode: configuration.capture.sessionModes[sessionID] ?? configuration.capture.defaultMode,
                                 since: configuration.capture.sessionSince[sessionID] ?? "")
    }
    func removeDeletedCapturePreference(sessionID: String) async throws {
        // Do not reset a retained chat's explicit opt-out if another part of
        // deletion fails. Its vault entries are removed only after the chat is.
        guard record(sessionID) == nil else { throw StoreError.invalidRecord }
        try await ensureConfiguration()
        guard configuration.capture.sessionModes[sessionID] != nil || configuration.capture.sessionSince[sessionID] != nil else { return }
        try await updateConfiguration {
            $0.capture.sessionModes.removeValue(forKey: sessionID)
            $0.capture.sessionSince.removeValue(forKey: sessionID)
        }
    }
    func setCaptureMode(_ mode: String, sessionID: String) async throws {
        if isEphemeral(sessionID) {
            guard mode != "persist" else { throw HostError.failure("Keep the side as a separate chat before enabling persistent capture.") }
            _ = try await debugRequest("debug.mode", sessionID: sessionID, params: ["mode": .string(mode)]); displays[sessionID]?.captureMode = mode; return
        }
        let preference = CapturePreference(mode: mode, since: { let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format.string(from: Date()) }())
        try await updateConfiguration { $0.capture.sessionModes[sessionID] = preference.mode; $0.capture.sessionSince[sessionID] = preference.since }
        if let item = chats.first(where: { $0.id == sessionID }), hosts[item.workspaceID]?.isReady == true { _ = try await debugRequest("debug.mode", sessionID: sessionID, params: ["mode": .string(mode)]) }
        displays[sessionID]?.captureMode = mode
    }
    func clearCaptures(sessionID: String) async throws {
        guard displays[sessionID]?.hasWork != true else { throw HostError.failure("Stop active work before clearing capture bodies.") }
        if let item = record(sessionID), hosts[item.workspaceID]?.isReady == true { _ = try await debugRequest("debug.clear", sessionID: sessionID) }
        let previous = try await capturePreference(sessionID: sessionID)
        if previous.mode == "persist" { try await setCaptureMode("persist", sessionID: sessionID) }
        try await traces.clear(sessionID: sessionID)
    }
    func persistAttempt(sessionID: String, attemptID: String, destination: URL) async throws -> URL {
        let metadata = try await debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(attemptID)])
        guard metadata["outcome"]?.string != "running" else { throw HostError.failure("Wait for this HTTP attempt to finish, or Stop it before exporting retained bytes") }
        return try await liveExporter.persist(metadata, destination: destination, read: { [weak self] body, offset in
            guard let self else { throw TraceError.invalid }
            return try await self.debugRequest("debug.body", sessionID: sessionID, params: ["attemptId": .string(attemptID), "body": .string(body), "offset": .number(Double(offset))])
        }, verify: { [weak self] in
            guard let self else { throw TraceError.invalid }
            return try await self.debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(attemptID)])
        })
    }
    func acquireUpdateBarrier() -> Bool {
        if installPreparing { return true }
        guard !hasActiveWork else { return false }
        installPreparing = true; return true
    }
    func prepareForInstall() async throws {
        guard installPreparing else { throw HostError.failure("The update idle barrier was not acquired") }
        do {
            // The host also checks authoritative lane state after all accepted
            // preflight commands finish. Native status can lag an acknowledgement.
            for host in hosts.values where host.isReady { _ = try await host.request("workspace.quiesce") }
            try await flushDrafts()
            for host in hosts.values { try await host.shutdownAndWait() }
            guard await flushProjectSidebarState() else { throw HostError.failure("Project preferences could not be saved in time. Retry the update after storage becomes available.") }
            guard await flushReadStates() else { throw HostError.failure("Unread state could not be saved in time. Retry the update after storage becomes available.") }
        } catch {
            for host in hosts.values where host.isReady { _ = try? await host.request("workspace.resume") }
            throw error
        }
    }
    func releaseUpdateBarrier() { installPreparing = false }
    func shutdown() {
        cancelAutomaticContext()
        SessionUsageWindows.shared.closeAll(owner: self)
        for task in titleGenerationTasks.values { task.cancel() }
        titleGenerationTasks.removeAll()
        accountingStopped = true
        for task in accountingTasks.values { task.cancel() }
        accountingTasks.removeAll(); dirtyAccounting.removeAll()
        for host in hosts.values { host.shutdown() }
    }
}
