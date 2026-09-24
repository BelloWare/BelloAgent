import Foundation
import Combine
import AppKit

/// One Session Inspector window: the session's requests grouped into turns,
/// the page the navigator has open, and the reads behind it.
///
/// Nothing is read while the window is hidden. The navigator reads the
/// request log's typed columns only, on the report reader's connection, and
/// only again when the log's signature for the session changed. Charts and
/// turn summaries are built off the main actor. Bodies belong to
/// `InspectorRequestModel` and `NextRequestModel`, which read only for the
/// page and tab on screen.
@MainActor final class SessionInspectorModel: ObservableObject {
    let scope: SessionUsageScope
    @Published var title: String
    @Published private(set) var index = InspectorIndex()
    @Published private(set) var indexLoaded = false
    @Published private(set) var page: InspectorPage = .overview
    /// Why the request log could not be read.
    @Published private(set) var failure: String?
    /// Why the page asked for could not be opened.
    @Published private(set) var focusNotice: String?
    @Published var expanded: Set<String> = []
    /// Each turn's prompt, as far as the navigator and the Turn page show it.
    @Published private(set) var prompts: [String: String] = [:]
    /// Turns of the loaded conversation, as the transcript summarizes them.
    @Published private(set) var summaries: [String: TurnSummary] = [:]
    @Published private(set) var timeCharts = SessionTimeCharts(inputs: SessionStatsInputs(), history: nil)
    @Published private(set) var tokenCharts = SessionTokenCharts(inputs: SessionStatsInputs(), history: nil)
    @Published private(set) var inputs = SessionStatsInputs()
    /// The chat's footer clocks: model and tool time.
    @Published private(set) var work: [String: WireValue] = [:]
    /// The Overview's ledger of every request, built with the index.
    @Published private(set) var ledger = SessionRequestLedger(history: SessionTimingHistory())
    /// Earlier versions of the chat's edited turns, which the navigator nests
    /// under the turn as it stands.
    @Published private(set) var versions = InspectorVersionMap()
    /// What each summary request asked for, read from its body when a page of
    /// its compaction opens; the navigator names a compaction's requests from
    /// these and never reads a body itself.
    @Published private(set) var summaryKinds: [String: SummaryRequestKind] = [:]

    let usage: SessionUsageController
    let request: InspectorRequestModel
    let next: NextRequestModel
    let archive: PayloadArchive
    weak var workspace: WorkspaceModel?
    /// Each chart's pointer selection, held without being observed.
    let timelineSelection = PiChartSelection()
    let speedSelection = PiChartSelection()
    let tokenSelection = PiChartSelection()
    let costSelection = PiChartSelection()

    private(set) var visible = false
    private var pendingFocus: InspectorFocus?
    private var pendingSince: Date?
    private var poll: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var building: Task<Void, Never>?
    private var summarizing: Task<Void, Never>?
    private var prompting: Task<Void, Never>?
    private var lookups: Task<Void, Never>?
    private var versionReads: Task<Void, Never>?
    private var summaryReads: Task<Void, Never>?
    private var summaryObservation: AnyCancellable?
    private var observations: Set<AnyCancellable> = []
    /// The chat's display the footer sinks follow, held weakly: a display the
    /// workspace let go of is not kept for the Inspector's sake.
    private weak var followed: SessionDisplay?
    private var followsDisplay = false
    /// Which read of the log `reading` is: a read that was stopped, ending
    /// after the next one began, leaves the next one's handle alone.
    private var readGeneration = 0
    private var signature: String?
    private var lastRead: (rows: [InspectorRequestRow], live: [InspectorRequestRow], older: Int) = ([], [], 0)
    /// Test seams: log reads of the whole index, and how often the poll runs.
    private(set) var indexReads = 0
    /// Test seam: awaited as each read of the log starts.
    var beforeRead: (() async -> Void)?
    /// Test seam: a read of the log is under way, and can be stopped.
    var isReading: Bool { reading != nil }
    var pollInterval: Duration = .seconds(8)
    var runningPollInterval: Duration = .seconds(2)

    init(scope: SessionUsageScope, title: String, archive: PayloadArchive, workspace: WorkspaceModel?,
         usageLoader: @escaping SessionUsageLoader, cache: InspectorDocumentCache = .shared) {
        self.scope = scope; self.title = title; self.archive = archive; self.workspace = workspace
        usage = SessionUsageController(scope: scope, load: usageLoader)
        request = InspectorRequestModel(archive: archive, sessionID: scope.sessionID, workspace: workspace, cache: cache)
        next = NextRequestModel(sessionID: scope.sessionID, workspace: workspace, cache: cache)
        usage.$snapshot.dropFirst().sink { [weak self] _ in self?.inputsChanged() }.store(in: &observations)
        // The request on screen names its own part as soon as its body is read.
        summaryObservation = request.$conversation.sink { [weak self] load in
            guard let summary = load.value?.summary, let id = self?.request.row?.id else { return }
            Task { @MainActor [weak self] in self?.learn(summary.kind, for: id) }
        }
    }
    deinit { poll?.cancel(); reading?.cancel(); building?.cancel(); summarizing?.cancel(); prompting?.cancel(); lookups?.cancel(); versionReads?.cancel(); summaryReads?.cancel() }

    /// The chat's loaded conversation, when the app has it open.
    var display: SessionDisplay? { workspace?.displays[scope.sessionID] }

    // MARK: Focus and navigation

    /// Opens a page now, or as soon as the index can say where it is.
    func focus(_ focus: InspectorFocus) {
        focusNotice = nil
        // The Overview and the next request need no index; anything else
        // waits for one, or the latest request of a window just opened would
        // be the Overview an empty index falls back to.
        let standalone = focus == .overview || focus == .nextRequest
        if let page = index.resolve(focus, message: hint(for: focus)), indexLoaded || standalone {
            pendingFocus = nil
            show(page)
            return
        }
        pendingFocus = focus; pendingSince = Date()
        if case .message(let id) = focus, hint(for: focus) == nil { lookUpMessage(id) }
        if indexLoaded { signature = nil; refresh() }
    }

    /// What the navigator opens when the reader picks a row.
    func select(_ page: InspectorPage) {
        pendingFocus = nil; focusNotice = nil
        show(page)
    }

    /// ⌘[ and ⌘]: the request before or after the one open, across turns.
    func step(_ delta: Int) {
        let requests = index.requests
        guard !requests.isEmpty else { return }
        switch page {
        case .request(let id):
            if let target = index.adjacent(to: id, step: delta) { select(.request(target)) }
        case .turn(let id):
            guard let first = index.turn(id)?.requests.first else { return }
            if delta > 0 { select(.request(first.id)) }
            else if let previous = index.adjacent(to: first.id, step: -1) { select(.request(previous)) }
        case .overview, .nextRequest:
            select(.request(delta > 0 ? requests[0].id : requests[requests.count - 1].id))
        }
    }

    func toggle(_ turn: String) {
        if expanded.contains(turn) { expanded.remove(turn) } else { expanded.insert(turn) }
    }

    private func show(_ page: InspectorPage) {
        // An earlier version opens under the turn as it stands.
        if case .turn(let id) = page { expanded.insert(index.turn(id)?.version?.latest ?? id) }
        if case .request(let id) = page, let turn = index.turn(containing: id) {
            expanded.insert(turn.version?.latest ?? turn.id)
            if turn.version != nil { expanded.insert(turn.id) }
            if let group = index.compaction(containing: id) { expanded.insert(group.id) }
        }
        if self.page != page { self.page = page }
        syncPage()
    }

    /// What the transcript knows about a message: its request, its role, its turn.
    private func hint(for focus: InspectorFocus) -> InspectorMessageHint? {
        // The rows on screen, an earlier version's included, then the page.
        guard case .message(let id) = focus,
              let message = display?.presentedMessages.first(where: { $0.id == id }) ?? display?.messages.first(where: { $0.id == id }) else { return nil }
        return InspectorMessageHint(id: id, role: message.role, attempt: message.reply?.attempt, turn: message.turn ?? (message.role == "user" ? id : nil))
    }

    /// A message the loaded page does not hold: the request that produced it,
    /// from the log's message links.
    private func lookUpMessage(_ id: String) {
        lookups?.cancel()
        let archive = archive, workspaceID = scope.workspaceID
        lookups = Task { [weak self] in
            let attempts = (try? await archive.attempts(producing: id, workspaceID: workspaceID)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.lookups = nil
            guard self.pendingFocus == .message(id) else { return }
            if let attempt = attempts.first { self.pendingFocus = .request(attempt) }
            else { self.pendingFocus = .turn(id) }
            self.resolvePending()
        }
    }

    private func resolvePending() {
        guard let pending = pendingFocus, indexLoaded else { return }
        if let page = index.resolve(pending, message: hint(for: pending)) {
            pendingFocus = nil; show(page); return
        }
        // The log is still being asked which request produced the message.
        if case .message = pending, lookups != nil { return }
        // A turn that has just started may not have a request on record yet;
        // the next reads keep looking for a while before saying so.
        if Date().timeIntervalSince(pendingSince ?? .distantPast) > 20 || !(display?.busy ?? false) {
            pendingFocus = nil
            focusNotice = {
                switch pending {
                case .turn: return "That turn has no retained requests."
                case .request: return "That request is not in this session's request log."
                case .message: return "No retained request produced that message."
                default: return nil
                }
            }()
            if page != .overview { show(.overview) } else { syncPage() }
        }
    }

    /// Starts or stops the reads of the page on screen.
    private func syncPage() {
        if case .request(let id) = page, let row = index.request(id) {
            let previous = index.predecessor(of: id)
            request.open(row, predecessor: previous, previousLabel: previous.map { label(of: $0, from: row) })
            request.setActive(visible)
            if visible, let group = index.compaction(containing: id) { readSummaryKinds(group) }
        } else { request.setActive(false) }
        let latest = index.latestRequestID.flatMap(index.request)
        next.setActive(visible && page == .nextRequest, previous: latest, previousLabel: latest.map { label(of: $0, from: nil) })
        if case .turn(let id) = page, visible { loadPrompt(id) }
    }

    /// "request 1" within the same turn; "turn 2" across turns.
    func label(of previous: InspectorRequestRow, from row: InspectorRequestRow?) -> String {
        let turn = index.turn(containing: previous.id)
        if let row, let turn, turn.id == index.turn(containing: row.id)?.id, let position = index.position(of: previous.id) {
            return "request \(position.index)"
        }
        guard let turn, !turn.isOther else { return "the last request" }
        if row == nil, let position = index.position(of: previous.id) { return "turn \(turn.number) request \(position.index)" }
        return "turn \(turn.number)"
    }

    // MARK: Visibility and reads

    /// The window is on screen: read, poll and load the page; or stop all of it.
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        usage.setVisible(visible)
        if visible { startPolling(); refreshSummaries(); refreshVersions() }
        else { poll?.cancel(); poll = nil; reading?.cancel(); reading = nil; summarizing?.cancel(); prompting?.cancel(); versionReads?.cancel() }
        syncPage()
    }

    /// Reads the index again now, whatever its signature says.
    func refresh() {
        signature = nil
        guard visible else { return }
        read(force: true)
        usage.refresh()
        if page == .nextRequest { let latest = index.latestRequestID.flatMap(index.request); next.refresh(previous: latest, previousLabel: latest.map { label(of: $0, from: nil) }) }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.read(force: false)
                let busy = self.display?.busy ?? false || self.index.turns.contains(where: \.running)
                do { try await Task.sleep(for: busy ? self.runningPollInterval : self.pollInterval) } catch { return }
            }
        }
    }

    private func read(force: Bool) {
        guard visible, reading == nil else { return }
        let archive = archive, scope = scope
        readGeneration &+= 1
        let generation = readGeneration
        reading = Task { [weak self] in
            defer { if self?.readGeneration == generation { self?.reading = nil } }
            if let gate = self?.beforeRead { await gate() }
            do {
                let signature = try await archive.inspectorSignature(sessionID: scope.sessionID, workspaceID: scope.workspaceID)
                guard let self, !Task.isCancelled else { return }
                let live = await self.liveRows()
                let key = signature + "|" + live.map { "\($0.id):\($0.outcome):\($0.output ?? -1)" }.joined(separator: ",")
                if !force, self.indexLoaded, key == self.signature { self.resolvePending(); return }
                let read = try await archive.inspectorRows(sessionID: scope.sessionID, workspaceID: scope.workspaceID)
                guard !Task.isCancelled else { return }
                self.indexReads += 1
                self.signature = key
                self.lastRead = (read.rows, live, read.older)
                await self.rebuildIndex()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failure = "This session's request log could not be read: " + error.localizedDescription
                self.indexLoaded = true
                self.resolvePending()
            }
        }
    }

    /// The helper's own records, only while the chat runs: then they can be
    /// ahead of the log. Idle, the log has everything the helper does.
    private func liveRows() async -> [InspectorRequestRow] {
        // While the chat runs, or while its replies name requests the durable
        // log never got (it was closed): the helper's own log may hold them.
        let missing = summaries.values.contains { $0.accounting.recordLines.contains { $0.logMissing == .notCaptured } }
        guard let workspace, display?.busy == true || missing,
              let page = try? await workspace.debugRequest("debug.list", sessionID: scope.sessionID, params: ["offset": .number(0)]) else { return [] }
        return (page["attempts"]?.array ?? []).compactMap { $0.object.flatMap(InspectorRequestRow.live) }
    }

    private func rebuildIndex() async {
        let read = lastRead, records = summaries.mapValues(\.accounting.recordLines), versions = versions
        let (built, ledger) = await Task.detached(priority: .userInitiated) { () -> (InspectorIndex, SessionRequestLedger) in
            let index = InspectorIndex(archived: read.rows, live: read.live, records: records, olderRequests: read.older, versions: versions)
            let samples = index.requests.filter { $0.source != .record }.sorted { ($0.wall, $0.id) < ($1.wall, $1.id) }.map(\.sample)
            let history = SessionTimingHistory(samples: samples.filter { $0.outcome == "completed" }, hasOlderRequests: read.older > 0,
                                               ledgerSamples: samples, hasOlderLedgerRequests: read.older > 0)
            return (index, SessionRequestLedger(history: history))
        }.value
        guard !Task.isCancelled else { return }
        if built != index { index = built }
        if ledger != self.ledger { self.ledger = ledger }
        if !indexLoaded { indexLoaded = true }
        if failure != nil { failure = nil }
        if expanded.isEmpty, let last = index.turns.last(where: { !$0.isOther }) { expanded.insert(last.id) }
        resolvePending()
        syncPage()
        rebuildCharts()
        loadPrompts()
    }

    // MARK: Footer, charts and summaries

    /// Follows the chat's footer: a settled request re-reads the index, and
    /// the clocks and totals feed the Overview.
    func observe(footer: SessionMetrics, display: SessionDisplay?) {
        followed = display; followsDisplay = display != nil
        observations.removeAll()
        usage.$snapshot.dropFirst().sink { [weak self] _ in self?.inputsChanged() }.store(in: &observations)
        footer.$gateway.dropFirst().removeDuplicates().debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.signature = nil; self?.read(force: false); self?.inputsChanged() }.store(in: &observations)
        footer.$turnTiming.removeDuplicates().sink { [weak self] timing in self?.work = timing; self?.inputsChanged() }.store(in: &observations)
        display?.presentationChanges.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSummaries(); self?.refreshVersions() }.store(in: &observations)
    }

    /// The workspace built a new display for the chat, or let its display
    /// go (an idle chat's display is evicted when many are open): the
    /// Inspector follows the one it has now, and reads what that shows.
    func follow(_ display: SessionDisplay?) {
        guard display !== followed || (display == nil && followsDisplay) else { return }
        if let display {
            observe(footer: display.footer, display: display)
            refreshSummaries(); refreshVersions(); inputsChanged()
        } else {
            followed = nil; followsDisplay = false
            observations.removeAll()
            usage.$snapshot.dropFirst().sink { [weak self] _ in self?.inputsChanged() }.store(in: &observations)
        }
    }

    private func inputsChanged() {
        var inputs = SessionStatsInputs()
        if let display {
            inputs = SessionStatsInputs(footer: display.footer, session: display)
        } else if let snapshot = usage.snapshot {
            inputs.gateway = snapshot.gateway
            inputs.work = WorkSplit(timing: work)
        }
        if inputs != self.inputs { self.inputs = inputs; rebuildCharts() }
    }

    private func rebuildCharts() {
        guard visible else { return }
        let inputs = inputs, history = index.history
        building?.cancel()
        building = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                (SessionTimeCharts(inputs: inputs, history: history), SessionTokenCharts(inputs: inputs, history: history))
            }.value
            guard !Task.isCancelled, let self else { return }
            var moved = false
            if built.0 != self.timeCharts { self.timeCharts = built.0; moved = true }
            if built.1 != self.tokenCharts { self.tokenCharts = built.1; moved = true }
            if moved { for selection in [self.timelineSelection, self.speedSelection, self.tokenSelection, self.costSelection] { selection.select(nil) } }
        }
    }

    /// The loaded conversation's turns as the transcript sums them: their
    /// outcome, clocks and the requests only the replies recorded.
    /// The chat's edited turns and their earlier versions: every one the
    /// helper numbers when it has the chat open, else the ones on the page.
    func refreshVersions() {
        guard visible else { return }
        let marks = (display?.messages ?? []).compactMap { row -> (String, MessageVersionMark)? in
            guard row.role == "user", let mark = row.versions, mark.usable else { return nil }
            return (row.id, mark)
        }
        let workspace = workspace, sessionID = scope.sessionID
        versionReads?.cancel()
        versionReads = Task { [weak self] in
            let groups = await workspace?.messageVersionGroups(sessionID: sessionID)
            guard !Task.isCancelled, let self else { return }
            let map = Self.versionMap(marks: marks, groups: groups)
            guard map != self.versions else { return }
            self.versions = map
            if self.indexLoaded { await self.rebuildIndex() }
        }
    }

    /// Every turn of every earlier version, keyed to the turn it nests under.
    nonisolated static func versionMap(marks: [(String, MessageVersionMark)], groups: [[String: WireValue]]?) -> InspectorVersionMap {
        var map = InspectorVersionMap()
        for (latest, mark) in marks {
            guard let ids = mark.ids else { continue }
            for (offset, id) in ids.enumerated() where id != latest {
                map.earlier[id] = .init(latest: latest, index: offset + 1, count: ids.count, version: id)
            }
        }
        for group in groups ?? [] {
            let versions = group["versions"]?.array?.compactMap(\.object) ?? []
            guard let current = versions.last(where: { $0["live"]?.bool == true }), let latest = current["messageId"]?.string else { continue }
            for version in versions where version["messageId"]?.string != latest {
                guard let id = version["messageId"]?.string, let index = version["index"]?.number.flatMap({ Int(exactly: $0) }) else { continue }
                let entry = InspectorVersionMap.Entry(latest: latest, index: index, count: versions.count, version: id)
                map.earlier[id] = entry
                for turn in version["turns"]?.array?.compactMap(\.string) ?? [] where turn != latest && map.earlier[turn] == nil { map.earlier[turn] = entry }
            }
        }
        return map
    }

    private func refreshSummaries() {
        guard visible, let display else { return }
        let messages = display.presentedMessages, lifecycle = display.taskPresentation
        summarizing?.cancel()
        summarizing = Task { [weak self] in
            let summaries = await Task.detached(priority: .utility) { Self.summaries(messages: messages, lifecycle: lifecycle) }.value
            guard !Task.isCancelled, let self, summaries != self.summaries else { return }
            let recordsChanged = summaries.mapValues(\.accounting.recordLines) != self.summaries.mapValues(\.accounting.recordLines)
            self.summaries = summaries
            self.inputsChanged()
            if recordsChanged, self.indexLoaded { await self.rebuildIndex() }
        }
    }

    nonisolated static func summaries(messages: [TranscriptMessage], lifecycle: TaskPresentationProjection?) -> [String: TurnSummary] {
        var result: [String: TurnSummary] = [:]
        for item in TranscriptActivity.blocks(of: messages, lifecycle: lifecycle) {
            guard case .block(let block) = item, let turn = block.turn else { continue }
            if let id = block.turnID ?? turn.taskRootID ?? turn.requests.compactMap(\.turn).first { result[id] = turn }
        }
        return result
    }

    // MARK: Prompts

    /// A turn's prompt: from the loaded conversation, else read from the
    /// chat's journal once, bounded to the preview the page shows.
    private func loadPrompt(_ turn: String) {
        guard prompts[turn] == nil, !turn.hasPrefix(InspectorTurn.otherID) else { return }
        if let text = display?.messages.first(where: { $0.id == turn && $0.role == "user" })?.text {
            prompts[turn] = RequestDocument.prefix(text as NSString, limit: RequestDocument.previewLimit); return
        }
        loadPrompts(first: turn)
    }

    /// Fills in the prompts the navigator shows, newest turns first, off the
    /// main actor, a batch at a time.
    private func loadPrompts(first: String? = nil) {
        guard visible, let workspace else { return }
        var missing: [String] = []
        let loaded = Dictionary(display?.messages.filter { $0.role == "user" }.map { ($0.id, $0.text) } ?? [], uniquingKeysWith: { first, _ in first })
        var found: [String: String] = [:]
        for turn in index.turns.flatMap({ [$0] + $0.earlier }).reversed() where !turn.isOther && prompts[turn.id] == nil {
            if let text = loaded[turn.id] { found[turn.id] = RequestDocument.prefix(text as NSString, limit: RequestDocument.previewLimit) }
            else if missing.count < 200 { missing.append(turn.id) }
        }
        if let first, let at = missing.firstIndex(of: first) { missing.remove(at: at); missing.insert(first, at: 0) }
        if !found.isEmpty { prompts.merge(found) { $1 } }
        guard !missing.isEmpty, prompting == nil else { return }
        let id = scope.sessionID
        prompting = Task { [weak self] in
            defer { self?.prompting = nil }
            var batch: [String: String] = [:]
            for turn in missing {
                if Task.isCancelled { return }
                let text = (try? await workspace.messagePage(id: turn, field: "text", offset: 0, sessionID: id).0) ?? ""
                batch[turn] = RequestDocument.prefix(text as NSString, limit: RequestDocument.previewLimit)
                if batch.count >= 20 { self?.prompts.merge(batch) { $1 }; batch.removeAll() }
            }
            if !batch.isEmpty { self?.prompts.merge(batch) { $1 } }
        }
    }

    // MARK: Summary requests

    /// What a compaction's summary request is: "earlier history", "part 2
    /// of 2", "start of this turn". Nil until a page of its compaction has
    /// been opened and the bodies read.
    func summaryLabel(_ requestID: String) -> String? {
        guard let group = index.compaction(containing: requestID), let at = group.requests.firstIndex(where: { $0.id == requestID }) else { return nil }
        return SummaryRequestLabel.label(at: at, kinds: group.requests.map { summaryKinds[$0.id] })
    }
    private func learn(_ kind: SummaryRequestKind, for id: String) {
        if summaryKinds[id] != kind { summaryKinds[id] = kind }
    }
    /// A page of a compaction opened: the kinds of all its requests, each read
    /// from its body off the main actor, the way the page reads its own.
    private func readSummaryKinds(_ group: InspectorCompaction) {
        let missing = group.requests.filter { summaryKinds[$0.id] == nil && $0.source != .record }
        guard !missing.isEmpty else { return }
        summaryReads?.cancel()
        let archive = archive, sessionID = scope.sessionID, cache = request.cache, workspace = workspace, override = request.sourceOverride
        summaryReads = Task { [weak self] in
            for row in missing {
                guard !Task.isCancelled else { return }
                let sources = override.map { find in find(row, "request").map { [$0] } ?? [] }
                    ?? InspectorBodies.sources(row, archive: archive, workspace: workspace, sessionID: sessionID)
                guard let summary = try? await InspectorBodies.summary(row, sources: sources, cache: cache) else { continue }
                guard !Task.isCancelled, let self else { return }
                self.learn(summary.kind, for: row.id)
            }
        }
    }

    // MARK: Fork from here

    /// "Fork from here" on a request's page: a new chat that ends at the
    /// reply this request produced, opened in the main window.
    func forkFromRequest(_ attemptID: String) {
        guard let workspace else { return }
        let sessionID = scope.sessionID
        Task { [weak self] in
            guard let reply = await workspace.replyID(forAttempt: attemptID, sessionID: sessionID) else {
                self?.focusNotice = "This request left no reply in the chat to fork from."
                return
            }
            self?.bringMainWindowForward()
            workspace.forkFromReply(sessionID: sessionID, messageID: reply)
        }
    }

    // MARK: Show in chat

    /// The chat, scrolled to what the page is about.
    func showInChat() {
        guard let workspace else { return }
        let sessionID = scope.sessionID
        switch page {
        case .turn(let id): reveal(workspace, sessionID, id)
        case .request(let id):
            let archive = archive, fallback = index.request(id)?.turn
            Task { [weak self] in
                let links = try? await archive.linkedMessages(attemptID: id)
                guard self != nil else { return }
                self?.reveal(workspace, sessionID, links?.output.first ?? fallback)
            }
        case .overview, .nextRequest: reveal(workspace, sessionID, nil)
        }
    }

    private func reveal(_ workspace: WorkspaceModel, _ sessionID: String, _ message: String?) {
        bringMainWindowForward()
        Task { _ = await workspace.revealMessage(sessionID: sessionID, messageID: message) }
    }
    /// The app's main window: the one that is not an Inspector and can be main.
    private func bringMainWindowForward() {
        if let window = NSApp.windows.first(where: { !($0.windowController is SessionInspectorWindowController) && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
