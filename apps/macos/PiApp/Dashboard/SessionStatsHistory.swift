import Foundation

extension PayloadArchive {
    /// A session's retained requests for the statistics popovers: every
    /// dispatched attempt, oldest first, read on the report reader's own
    /// connection so the capture writer never waits for a chart.
    func sessionStatsHistory(sessionID: String, workspaceID: String, until: Date = Date(),
                             limit: Int = SessionStatsHistory.limit) async throws -> SessionStatsHistory {
        guard [sessionID, workspaceID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }),
              until.timeIntervalSince1970.isFinite, until.timeIntervalSince1970 >= 0, limit > 0 else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "sessionStats") { engine in
            try Self.sessionStatsHistory(sessionID: sessionID, workspaceID: workspaceID, until: until, limit: limit, db: engine.db)
        }
    }

    static func sessionStatsHistory(sessionID: String, workspaceID: String, until: Date, limit: Int, db: CaptureDatabase) throws -> SessionStatsHistory {
        let scope = "session=? AND workspace=? AND metrics_retained=1 AND wall<? AND dispatch IS NOT NULL"
        let values: [CaptureSQLValue] = [.text(sessionID), .text(workspaceID), .real(until.timeIntervalSince1970)]
        try Task.checkCancellation()
        let total = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE \(scope)", values).first?["n"]?.number ?? 0)
        try Task.checkCancellation()
        let rows = try db.rows("SELECT \(sessionRequestColumns) FROM attempts WHERE \(scope) ORDER BY wall DESC,id DESC LIMIT ?",
                               values + [.integer(Int64(limit))])
        let requests = try rows.reversed().map(sessionRequestSample)
        return SessionStatsHistory(requests: requests, olderRequests: max(0, total - requests.count))
    }
}

extension SessionStatsInputs {
    /// The footer's figures as they stand, and the tool calls of each turn
    /// in the loaded conversation. A walk over the loaded page's rows, made
    /// when a popover opens or refreshes — never from a view body.
    @MainActor init(footer: SessionMetrics, session: SessionDisplay) {
        gateway = footer.gateway
        work = WorkSplit(timing: footer.turnTiming)
        var calls: [String: Int] = [:]
        for message in session.messages where message.role == "assistant" {
            guard let turn = message.turn else { continue }
            calls[turn, default: 0] += message.toolCallCount ?? message.tools?.count ?? 0
        }
        toolCallsByTurn = calls
        conversationPartial = session.olderPage.available
    }
}

typealias SessionStatsLoader = @Sendable (SessionUsageScope) async throws -> SessionStatsHistory

/// The two statistics popovers of one session: their figures and charts,
/// the history those were built from, and the popovers themselves.
///
/// Nothing is read until a popover opens. The history is read off the main
/// actor, the charts are built off it too, and both are kept: reopening the
/// popover of a session whose figures have not moved shows the same charts at
/// once, without a read. While a popover is open, a change in the footer's
/// figures — a request settling, a turn ending — reads the history again.
@MainActor final class SessionStatsStore: ObservableObject {
    @Published private(set) var time: SessionTimeCharts
    @Published private(set) var tokens: SessionTokenCharts
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    let timePresenter = PiPopoverPresenter()
    let tokenPresenter = PiPopoverPresenter()
    /// Held, never published: only the parts that follow the pointer watch them.
    let timelineSelection = PiChartSelection()
    let speedSelection = PiChartSelection()
    let tokenSelection = PiChartSelection()
    let costSelection = PiChartSelection()

    private let load: SessionStatsLoader
    private var scope: SessionUsageScope?
    private var inputs: SessionStatsInputs?
    private var history: SessionStatsHistory?
    /// The footer totals `history` was read against.
    private var historyGateway: GatewayTotals?
    private var generation = 0
    private var reading: Task<Void, Never>?
    private var building: Task<Void, Never>?
    /// A change arrived while a read was in flight; read once more after it.
    private var stale = false
    /// Test seams: archive reads started, and chart builds published.
    private(set) var reads = 0
    private(set) var builds = 0
    /// Coalesces a burst of footer updates into one read.
    var settleDelay: Duration = .milliseconds(120)

    init(load: @escaping SessionStatsLoader) {
        self.load = load
        time = SessionTimeCharts(inputs: SessionStatsInputs(), history: nil)
        tokens = SessionTokenCharts(inputs: SessionStatsInputs(), history: nil)
    }
    deinit { reading?.cancel(); building?.cancel() }

    var isShowing: Bool { timePresenter.isShown || tokenPresenter.isShown }

    /// A popover is opening. The figures the footer has now go up at once;
    /// the charts follow from the history, read only if it is not the one
    /// these figures describe.
    func open(scope: SessionUsageScope, inputs: SessionStatsInputs) {
        if self.scope != scope { self.scope = scope; history = nil; historyGateway = nil }
        Self.touch(self)
        update(inputs, immediately: true)
    }

    /// The footer's figures moved. An open popover follows them; a closed one
    /// catches up when it next opens.
    func footerChanged(_ inputs: SessionStatsInputs) {
        guard isShowing, scope != nil else { return }
        update(inputs, immediately: false)
    }

    private func update(_ inputs: SessionStatsInputs, immediately: Bool) {
        let changed = inputs != self.inputs
        self.inputs = inputs
        if history == nil || historyGateway != inputs.gateway {
            if history == nil, changed {
                // No history yet: the figures alone, built here — they cost
                // nothing without one — so the popover opens with them.
                publish(SessionTimeCharts(inputs: inputs, history: nil), SessionTokenCharts(inputs: inputs, history: nil))
            }
            read(after: immediately ? .zero : settleDelay)
        } else if changed {
            build()
        }
    }

    private func read(after delay: Duration) {
        guard let scope else { return }
        if reading != nil { stale = true; return }
        generation += 1
        let generation = generation, load = load
        let gateway = inputs?.gateway
        loading = true; reads += 1
        reading = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                let history = try await load(scope)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.reading = nil
                self.history = history; self.historyGateway = gateway
                if self.failure != nil { self.failure = nil }
                if self.stale || self.inputs?.gateway != gateway {
                    self.stale = false
                    self.read(after: self.settleDelay)
                }
                self.build()
            } catch is CancellationError {
                guard let self, self.generation == generation else { return }
                self.reading = nil
            } catch {
                guard let self, self.generation == generation else { return }
                self.reading = nil; self.loading = false
                self.failure = "This session's requests could not be read: " + error.localizedDescription
            }
        }
    }

    private func build() {
        guard let inputs else { return }
        let history = history
        building?.cancel()
        let generation = generation
        building = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                (SessionTimeCharts(inputs: inputs, history: history), SessionTokenCharts(inputs: inputs, history: history))
            }.value
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.building = nil
            self.publish(built.0, built.1)
            if self.reading == nil, self.loading { self.loading = false }
        }
    }

    private func publish(_ time: SessionTimeCharts, _ tokens: SessionTokenCharts) {
        var moved = false
        if time != self.time { self.time = time; moved = true }
        if tokens != self.tokens { self.tokens = tokens; moved = true }
        guard moved else { return }
        builds += 1
        // A pointer resting on a chart whose items changed is on a different item now.
        for selection in [timelineSelection, speedSelection, tokenSelection, costSelection] { selection.select(nil) }
    }

    // MARK: One store per session

    private struct Key: Hashable {
        let archive: ObjectIdentifier
        let sessionID: String
    }
    private static var stores: [Key: SessionStatsStore] = [:]
    /// Least recently opened first.
    private static var recency: [Key] = []
    private static let capacity = 12
    private weak var archive: PayloadArchive?
    private var key: Key?

    /// The store of one session of one archive. Every pill row that shows the
    /// session — the footer lays its bar out more than one way — shares it, and
    /// it outlives them, so a closed popover reopens on its last charts. The
    /// footer builds its pills on every figure it publishes, so a lookup
    /// changes nothing; opening a popover is what makes a store recent.
    static func shared(archive: PayloadArchive, sessionID: String) -> SessionStatsStore {
        let key = Key(archive: ObjectIdentifier(archive), sessionID: sessionID)
        if let store = stores[key], store.archive === archive { return store }
        let store = SessionStatsStore(load: { [weak archive] scope in
            guard let archive else { throw CaptureFailure.unavailable }
            return try await archive.sessionStatsHistory(sessionID: scope.sessionID, workspaceID: scope.workspaceID)
        })
        store.archive = archive; store.key = key
        stores[key] = store
        touch(store)
        return store
    }
    private static func touch(_ store: SessionStatsStore) {
        guard let key = store.key, stores[key] === store else { return }
        if recency.last != key { recency.removeAll { $0 == key }; recency.append(key) }
        // The least recently opened session goes first, never one that is open.
        while stores.count > capacity, let evicted = recency.first(where: { stores[$0]?.isShowing == false }) {
            stores[evicted] = nil; recency.removeAll { $0 == evicted }
        }
    }
}
