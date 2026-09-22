import Foundation
import Combine

/// One non-default report filter, shown as a removable chip while the
/// advanced filter panel is collapsed so active narrowing is never hidden.
struct ReportFilterChip: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case workspace, session, status, api, purpose, alias, model, unreported }
    let kind: Kind
    let label: String
    var id: String { kind.rawValue }
}

/// State and queries behind the usage report page. It outlives the page view
/// so navigating back to chats and returning restores filters, the brushed
/// selection and the last snapshot while refreshing newly retained requests.
@MainActor final class ReportController: ObservableObject {
    static let debounceMilliseconds = 300
    /// Row labels for the report's lists, rebuilt only when the chat or project
    /// list actually changes. Building them inside the page's `body` meant a
    /// chart drag rebuilt a dictionary of every chat and project per frame,
    /// because the brush preview publishes on every pointer move.
    private var labelRevisions: (chats: Int, workspaces: Int)?
    private var cachedChatTitles: [String: String] = [:]
    private var cachedWorkspaceNames: [String: String] = [:]
    func labels(for model: WorkspaceModel) -> (titles: [String: String], workspaces: [String: String]) {
        let revisions = (chats: model.chatsRevision, workspaces: model.workspacesRevision)
        if labelRevisions == nil || labelRevisions! != revisions {
            cachedChatTitles = Dictionary(model.chats.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            cachedWorkspaceNames = Dictionary(model.workspaces.map { ($0.id, WorkspaceLabel.name($0)) } + [(WorkspaceRecord.scratchID, "No project")], uniquingKeysWith: { first, _ in first })
            labelRevisions = revisions
        }
        return (cachedChatTitles, cachedWorkspaceNames)
    }
    static let manualSession = "\u{1}enter-id"

    @Published var preferences = DashboardPreferences()
    @Published var unreportedOnly = false
    @Published var sessionEntry = false
    /// Full applied window; the chart always shows this.
    @Published private(set) var snapshot: DashboardSnapshot?
    /// Brushed sub-range; tiles and the table use it when present.
    @Published private(set) var focused: DashboardSnapshot?
    @Published private(set) var brush: DashboardBrush?
    @Published var brushPreview: DashboardBrush?
    @Published private(set) var aliases: [String] = []
    @Published private(set) var models: [String] = []
    @Published private(set) var purposes: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var filtersPending = false
    @Published private(set) var notice = ""
    @Published private(set) var failure: String?
    @Published var advancedOpen = false
    @Published var detailsOpen = false
    @Published var chartMetric = "Output tok/s"
    @Published var latencyMetric = "TTFT"
    /// "requests" lists attempts; "sessions" groups them per chat.
    @Published var grouping = "requests"
    @Published private(set) var sessions: DashboardSessionPage?
    /// The per-route split for the same filter as the session list; nil while it loads.
    @Published private(set) var modelSummaries: [DashboardModelSummary]?
    /// First request page per expanded session, keyed by session id.
    @Published private(set) var sessionRequests: [String: DashboardRequestPage] = [:]
    @Published var expandedSessions: Set<String> = []
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var sessionRevision = 0
    private var sessionPageRevision = 0

    private weak var model: WorkspaceModel?
    private var ready = false
    private var visible = false
    private var applyingDefaults = false
    private var dirty = false
    private var debounce: Task<Void, Never>?
    private var refreshTask: (id: UUID, task: Task<Void, Never>)?
    private var defaultsTask: (id: UUID, task: Task<DashboardPreferences, Error>)?
    private var brushTask: Task<Void, Never>?
    private var filterRevision = 0
    private var brushRevision = 0
    private var appliedPreset = DashboardWindowPreset.day
    private var observers: Set<AnyCancellable> = []
    typealias Query = @Sendable (PayloadArchive, DashboardFilter, Int) async throws -> DashboardSnapshot
    typealias PageQuery = @Sendable (PayloadArchive, DashboardFilter, Int) async throws -> DashboardRequestPage
    typealias SessionQuery = @Sendable (PayloadArchive, DashboardFilter, Int) async throws -> DashboardSessionPage
    typealias ModelQuery = @Sendable (PayloadArchive, DashboardFilter) async throws -> [DashboardModelSummary]
    private let query: Query
    private let pageQuery: PageQuery
    private let sessionQuery: SessionQuery
    private let modelQuery: ModelQuery

    private nonisolated static func queryArchive(_ archive: PayloadArchive, _ filter: DashboardFilter, _ offset: Int) async throws -> DashboardSnapshot {
        try await archive.dashboard(filter, offset: offset)
    }

    private nonisolated static func queryPage(_ archive: PayloadArchive, _ filter: DashboardFilter, _ offset: Int) async throws -> DashboardRequestPage {
        try await archive.requestPage(filter, offset: offset)
    }
    private nonisolated static func querySessions(_ archive: PayloadArchive, _ filter: DashboardFilter, _ offset: Int) async throws -> DashboardSessionPage {
        try await archive.sessionSummaries(filter, offset: offset)
    }
    private nonisolated static func queryModels(_ archive: PayloadArchive, _ filter: DashboardFilter) async throws -> [DashboardModelSummary] {
        try await archive.modelSummaries(filter)
    }
    init(query: @escaping Query = ReportController.queryArchive, pageQuery: @escaping PageQuery = ReportController.queryPage, sessionQuery: @escaping SessionQuery = ReportController.querySessions, modelQuery: @escaping ModelQuery = ReportController.queryModels) {
        self.query = query
        self.pageQuery = pageQuery
        self.sessionQuery = sessionQuery
        self.modelQuery = modelQuery
        $preferences.dropFirst().removeDuplicates().sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        $unreportedOnly.dropFirst().removeDuplicates().sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
    }

    func attach(_ model: WorkspaceModel) { self.model = model }

    /// The snapshot the tiles and table should read: the brushed sub-range when present.
    var active: DashboardSnapshot? { focused ?? snapshot }
    var window: DashboardWindow { DashboardWindow.resolve(preferences) }
    /// Labels above retained results describe the exact window those results used.
    var appliedWindow: DashboardWindow {
        guard let filter = snapshot?.filter else { return window }
        return DashboardWindow(from: filter.from, until: filter.until, preset: appliedPreset)
    }
    var hasResults: Bool { snapshot != nil }

    /// Loads defaults once, coalescing concurrent visits. Later visits preserve
    /// choices and refresh requests that arrived while the report was hidden.
    func prepare() async {
        guard !Task.isCancelled else { return }
        visible = true
        await refresh()
    }

    // MARK: Filters

    func filter() -> DashboardFilter {
        let window = window
        return DashboardFilter(from: window.from, until: window.until, workspaceID: preferences.workspaceID, sessionID: preferences.sessionID, purpose: preferences.purpose, status: preferences.status, api: preferences.api, requestedAlias: preferences.requestedAlias, effectiveModel: unreportedOnly ? nil : preferences.effectiveModel, unreportedModelOnly: unreportedOnly)
    }

    /// Non-default filters other than the time window, in display order.
    func activeFilters(workspaces: [WorkspaceRecord], chats: [ChatRecord]) -> [ReportFilterChip] {
        let applied = snapshot?.filter ?? filter()
        var chips: [ReportFilterChip] = []
        if let id = applied.workspaceID {
            let name = workspaces.first { $0.id == id }.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Retained " + String(id.prefix(8))
            chips.append(ReportFilterChip(kind: .workspace, label: "Project · " + name))
        }
        if let id = applied.sessionID {
            let title = chats.first { $0.id == id }?.title
            chips.append(ReportFilterChip(kind: .session, label: "Session · " + ((title?.isEmpty == false ? title : nil) ?? String(id.prefix(8)))))
        }
        if applied.status != "completed" { chips.append(ReportFilterChip(kind: .status, label: "Status · " + (applied.status == "all" ? "all statuses" : applied.status))) }
        if let api = applied.api { chips.append(ReportFilterChip(kind: .api, label: "API · " + (api == "openai-responses" ? "Responses" : "Messages"))) }
        if let purpose = applied.purpose { chips.append(ReportFilterChip(kind: .purpose, label: "Purpose · " + purpose)) }
        if let alias = applied.requestedAlias { chips.append(ReportFilterChip(kind: .alias, label: "Alias · " + alias)) }
        if applied.unreportedModelOnly { chips.append(ReportFilterChip(kind: .unreported, label: "No resolved model")) }
        else if let model = applied.effectiveModel { chips.append(ReportFilterChip(kind: .model, label: "Model · " + model)) }
        return chips
    }
    var activeFilterCount: Int { activeFilters(workspaces: [], chats: []).count }

    func clear(_ chip: ReportFilterChip) {
        switch chip.kind {
        case .workspace: preferences.workspaceID = nil; preferences.sessionID = nil; sessionEntry = false
        case .session: preferences.sessionID = nil; sessionEntry = false
        case .status: preferences.status = "completed"
        case .api: preferences.api = nil
        case .purpose: preferences.purpose = nil
        case .alias: preferences.requestedAlias = nil
        case .model: preferences.effectiveModel = nil
        case .unreported: unreportedOnly = false
        }
    }

    func setWorkspace(_ id: String?) {
        if preferences.workspaceID != id { preferences.sessionID = nil; sessionEntry = false }
        preferences.workspaceID = id
    }
    func setPreset(_ preset: DashboardWindowPreset) { DashboardWindow.apply(preset, to: &preferences) }
    func setCustomBound(_ chosen: Date, anchorFrom: Bool) {
        let current = window
        let bounds = DashboardWindow.normalizeCustom(from: anchorFrom ? chosen : (preferences.customFrom ?? current.from), until: anchorFrom ? (preferences.customUntil ?? current.until) : chosen, anchorFrom: anchorFrom)
        preferences.customFrom = bounds.from; preferences.customUntil = bounds.until
    }
    func chooseSession(_ chosen: String) {
        if chosen == Self.manualSession { sessionEntry = true }
        else { sessionEntry = false; preferences.sessionID = chosen.isEmpty ? nil : chosen }
    }
    func reset() {
        let retention = preferences.metricRetentionDays
        preferences = DashboardPreferences(); preferences.metricRetentionDays = retention
        unreportedOnly = false; sessionEntry = false; clearBrush()
    }

    // MARK: Queries

    /// Filter edits coalesce before one query; edits made while a query runs
    /// are applied after it finishes.
    func scheduleRefresh() {
        guard !applyingDefaults else { return }
        filterRevision += 1
        dirty = true; filtersPending = true
        failure = nil
        scheduleQuery()
    }
    private func scheduleQuery() {
        debounce?.cancel()
        guard visible, !loading else { return }
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
    func refresh() async {
        guard let model, !Task.isCancelled else { return }
        visible = true
        debounce?.cancel(); debounce = nil
        if let running = refreshTask { await running.task.value; return }
        cancelBrushQuery()
        invalidateSessionQueries()
        let id = UUID()
        loading = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refresh(model, id: id)
        }
        refreshTask = (id, task)
        await task.value
    }
    private func isCurrent(_ id: UUID) -> Bool { visible && refreshTask?.id == id && !Task.isCancelled }

    private func initialize(_ model: WorkspaceModel, id: UUID) async throws {
        guard !ready else { return }
        let pending: (id: UUID, task: Task<DashboardPreferences, Error>)
        if let defaultsTask { pending = defaultsTask }
        else {
            pending = (UUID(), Task {
                try await model.ensureConfiguration()
                return model.configuration.dashboard
            })
            defaultsTask = pending
        }
        defer { if defaultsTask?.id == pending.id { defaultsTask = nil } }
        let saved = try await pending.task.value
        guard isCurrent(id), !ready else { return }
        // Preserve edits made before prepare starts or while the vault loads.
        if filterRevision == 0 {
            applyingDefaults = true
            preferences = saved; unreportedOnly = saved.unreportedModelOnly ?? false
            applyingDefaults = false
        }
        ready = true
    }

    private func refresh(_ model: WorkspaceModel, id: UUID) async {
        defer { finishQuery(id) }
        do { try await initialize(model, id: id) }
        catch {
            if isCurrent(id) { failure = error.localizedDescription; dirty = false }
            return
        }
        guard isCurrent(id) else { return }
        repeat {
            dirty = false
            let applied = filter(), preset = window.preset, revision = filterRevision
            do {
                let result = try await query(model.traces, applied, 0)
                guard isCurrent(id) else { return }
                guard revision == filterRevision else { dirty = true; continue }
                let selection = brush, selectionRevision = brushRevision
                var selected: DashboardSnapshot?
                if let selection, selection.fits(applied) { selected = try await query(model.traces, selection.narrowed(applied), 0) }
                guard isCurrent(id) else { return }
                guard revision == filterRevision, selectionRevision == brushRevision else { dirty = true; continue }
                snapshot = result; appliedPreset = preset; filtersPending = false
                focused = selected
                sessions = nil; modelSummaries = nil
                failure = nil
                async let aliasValues = model.traces.distinctAliases(applied)
                async let modelValues = model.traces.distinctModels(applied)
                async let purposeValues = model.traces.distinctPurposes(applied)
                let values = try await (aliasValues, modelValues, purposeValues)
                guard isCurrent(id) else { return }
                let groupFilter = selection.flatMap { $0.fits(applied) ? $0.narrowed(applied) : nil } ?? applied
                let grouped = try await sessionQuery(model.traces, groupFilter, 0)
                guard isCurrent(id) else { return }
                let byModel = try await modelQuery(model.traces, groupFilter)
                guard isCurrent(id) else { return }
                guard revision == filterRevision, selectionRevision == brushRevision else { dirty = true; continue }
                aliases = values.0; models = values.1; purposes = values.2
                snapshot = result; appliedPreset = preset; filtersPending = false
                sessions = grouped; modelSummaries = byModel
                focused = selectionRevision == brushRevision && brush == selection ? selected : nil
                if let selection, !selection.fits(applied) { clearBrush() }
                refreshExpandedSessions()
                failure = nil
                await model.refreshRetainedAccounting()
                guard isCurrent(id) else { return }
                notice = "At most 128 requests per page and 60 time buckets; 100,000 retained request records. Captures marked off, partial, expired, purged or corrupt remain explicit in Inspector."
            } catch {
                guard isCurrent(id) else { return }
                if revision == filterRevision { failure = error.localizedDescription }
                else { dirty = true }
            }
        } while dirty && isCurrent(id)
    }

    private func finishQuery(_ id: UUID) {
        guard refreshTask?.id == id else { return }
        refreshTask = nil; loading = brushTask != nil
        if dirty { scheduleQuery() }
    }
    /// Pages the table within the brushed sub-range when one is active.
    func page(offset: Int) async {
        guard let model, visible, !loading, !filtersPending, let applied = snapshot?.filter else { return }
        let selection = brush, revision = filterRevision, selectionRevision = brushRevision
        let id = UUID()
        loading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishQuery(id) }
            do {
                let result = try await self.pageQuery(model.traces, selection?.narrowed(applied) ?? applied, offset)
                guard self.isCurrent(id), revision == self.filterRevision, selectionRevision == self.brushRevision, self.snapshot?.filter == applied else { return }
                if selection != nil { self.focused?.replaceRows(result) } else { self.snapshot?.replaceRows(result) }
                self.notice = "Request rows refreshed at \(result.asOf.formatted(date: .omitted, time: .standard)). Charts and totals remain from the last report refresh."
                self.failure = nil
            } catch {
                guard self.isCurrent(id), revision == self.filterRevision, selectionRevision == self.brushRevision else { return }
                self.failure = error.localizedDescription
            }
        }
        refreshTask = (id, task)
        await task.value
    }
    func applyBrush(_ selection: DashboardBrush?) {
        guard visible, !loading, !filtersPending else { return }
        clearBrush()
        guard let model, let selection, let snapshot, selection.fits(snapshot.filter) else { return }
        brushPreview = selection
        let revision = filterRevision, selectionRevision = brushRevision
        loading = true
        brushTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if selectionRevision == self.brushRevision {
                    self.brushTask = nil; self.brushPreview = nil; self.loading = self.refreshTask != nil
                    if self.dirty { self.scheduleQuery() }
                }
            }
            do {
                let result = try await self.query(model.traces, selection.narrowed(snapshot.filter), 0)
                guard self.visible, !Task.isCancelled, revision == self.filterRevision, selectionRevision == self.brushRevision, self.snapshot?.filter == snapshot.filter else { return }
                self.focused = result; self.brush = selection; self.failure = nil
                await self.reloadSessions()
            } catch {
                guard self.visible, !Task.isCancelled, revision == self.filterRevision, selectionRevision == self.brushRevision else { return }
                self.failure = error.localizedDescription
            }
        }
    }
    private func cancelBrushQuery() {
        brushRevision += 1; brushTask?.cancel(); brushTask = nil; brushPreview = nil
        loading = refreshTask != nil
    }
    func clearBrush() {
        let hadBrush = brush != nil
        cancelBrushQuery(); brush = nil; focused = nil
        if dirty { scheduleQuery() } else if hadBrush { Task { [weak self] in await self?.reloadSessions() } }
    }
    func save() async {
        guard let model else { return }
        do {
            try filter().validated()
            var chosen = preferences; chosen.unreportedModelOnly = unreportedOnly
            if unreportedOnly { chosen.effectiveModel = nil }
            let saved = chosen
            try await model.updateConfiguration {
                var filters = saved; filters.metricRetentionDays = $0.dashboard.metricRetentionDays
                $0.dashboard = filters
            }
            failure = nil
            notice = "Default filters saved in the configuration vault."
        } catch { failure = error.localizedDescription }
    }
    /// Cancels pending work when the page leaves the window (state is kept).
    func suspend() {
        visible = false
        debounce?.cancel(); debounce = nil
        refreshTask?.task.cancel(); refreshTask = nil
        cancelBrushQuery()
        invalidateSessionQueries()
        loading = false
    }

    // MARK: Sessions

    /// The filter the session list and its expanded requests currently use.
    private var groupedFilter: DashboardFilter? {
        guard let applied = snapshot?.filter else { return nil }
        return brush.map { $0.narrowed(applied) } ?? applied
    }
    /// Re-reads the session list and the per-model split after the chart selection changed.
    func reloadSessions() async {
        await pageSessions(offset: 0)
        await loadModels()
    }
    /// Re-reads the per-route split for the filter the session list uses.
    func loadModels() async {
        guard let model, visible, !filtersPending, let applied = groupedFilter else { return }
        let revision = filterRevision, selectionRevision = brushRevision
        do {
            let summaries = try await modelQuery(model.traces, applied)
            guard visible, !Task.isCancelled, revision == filterRevision, selectionRevision == brushRevision, applied == groupedFilter else { return }
            modelSummaries = summaries
        } catch { if visible, revision == filterRevision, selectionRevision == brushRevision { failure = error.localizedDescription } }
    }
    func pageSessions(offset: Int) async {
        guard let model, visible, !filtersPending, let applied = groupedFilter else { return }
        invalidateSessionQueries()
        let revision = filterRevision, selectionRevision = brushRevision, pageRevision = sessionPageRevision
        @MainActor func current() -> Bool {
            visible && !Task.isCancelled && revision == filterRevision && selectionRevision == brushRevision && pageRevision == sessionPageRevision && applied == groupedFilter
        }
        do {
            let page = try await sessionQuery(model.traces, applied, offset)
            guard current() else { return }
            sessions = page; failure = nil
            refreshExpandedSessions()
        } catch { if current() { failure = error.localizedDescription } }
    }
    /// Expands or collapses one session; expanding loads its first request page.
    func toggleSession(_ id: String) {
        if expandedSessions.contains(id) { expandedSessions.remove(id); sessionTasks[id]?.cancel(); sessionTasks[id] = nil; return }
        expandedSessions.insert(id)
        loadSession(id)
    }
    private func invalidateSessionQueries() {
        sessionRevision += 1; sessionPageRevision += 1
        sessionTasks.values.forEach { $0.cancel() }; sessionTasks = [:]; sessionRequests = [:]
    }
    private func refreshExpandedSessions() {
        invalidateSessionQueries()
        for row in sessions?.sessions ?? [] where expandedSessions.contains(row.id) { loadSession(row.id) }
    }
    private func loadSession(_ id: String) {
        guard visible, !filtersPending, expandedSessions.contains(id), sessionRequests[id] == nil, sessionTasks[id] == nil,
              let model, var applied = groupedFilter else { return }
        applied.sessionID = id
        let revision = filterRevision, selectionRevision = brushRevision, expandedRevision = sessionRevision
        sessionTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled && expandedRevision == self.sessionRevision { self.sessionTasks[id] = nil } }
            @MainActor func current() -> Bool {
                self.visible && !Task.isCancelled && self.expandedSessions.contains(id) && revision == self.filterRevision && selectionRevision == self.brushRevision && expandedRevision == self.sessionRevision
            }
            do {
                let result = try await self.pageQuery(model.traces, applied, 0)
                guard current() else { return }
                self.sessionRequests[id] = result
            } catch {
                guard current() else { return }
                self.failure = error.localizedDescription
            }
        }
    }
    /// The message a request produced, else its triggering user turn.
    func linkedMessage(attemptID: String) async -> String? {
        guard let model else { return nil }
        guard let links = try? await model.traces.linkedMessages(attemptID: attemptID) else { return nil }
        return links.output.first ?? links.turn ?? links.context.last
    }
}
