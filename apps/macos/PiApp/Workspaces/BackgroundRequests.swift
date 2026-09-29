import Foundation

// The requests the app asks of a connection's mini model on its own: a
// chat's automatic title, the rename sheet's title suggestions and a
// webhook's notification. Each runs in a chat of its own outside every
// project, with its own journal, captured requests and billing, and is kept
// once it ends: what it produced, how it ended and when. They are listed on
// the Background requests page (`BackgroundRequestsPage`), never in the
// sidebar. docs/Background-Requests.md describes the page.

/// What a background request was for, from its chat's `backgroundTask`.
enum BackgroundRequestKind: Hashable, Sendable {
    case title, suggestions, webhook
    /// A kind this build does not know, written by a newer one: still listed.
    case other(String)
    init(_ raw: String) { self = [Self.title, .suggestions, .webhook].first { $0.raw == raw } ?? .other(raw) }
    /// The kind as a chat record's `backgroundTask` says it, and as the
    /// helper names the utility request it opens (`WorkspaceHosts.open`).
    var raw: String {
        switch self {
        case .title: return "session-title"
        case .suggestions: return "title-suggestions"
        case .webhook: return "webhook"
        case .other(let raw): return raw
        }
    }
    var label: String {
        switch self {
        case .title: return "Chat title"
        case .suggestions: return "Title suggestions"
        case .webhook: return "Webhook"
        case .other(let raw): return raw
        }
    }
    var symbol: String {
        switch self {
        case .title: return "textformat"
        case .suggestions: return "text.badge.plus"
        case .webhook: return "bell"
        case .other: return "sparkles"
        }
    }
}

/// The page's filter: every request, or one kind.
enum BackgroundRequestFilter: String, CaseIterable, Hashable, Sendable {
    case all, titles, suggestions, webhooks
    var title: String {
        switch self {
        case .all: return "All"
        case .titles: return "Chat titles"
        case .suggestions: return "Title suggestions"
        case .webhooks: return "Webhooks"
        }
    }
    func includes(_ kind: BackgroundRequestKind) -> Bool {
        switch self {
        case .all: return true
        case .titles: return kind == .title
        case .suggestions: return kind == .suggestions
        case .webhooks: return kind == .webhook
        }
    }
}

/// How a background request stands.
enum BackgroundRequestStatus: Equatable, Sendable {
    case running, completed
    case failed(String)
    case interrupted(String)
    var label: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
    var reason: String? {
        switch self {
        case .failed(let why), .interrupted(let why): return why
        case .running, .completed: return nil
        }
    }
}

enum BackgroundRequests {
    /// What a request cut short by a quit or crash says.
    static let interruptedNotice = "Interrupted when Bello Agent closed."
    /// What a request stopped by its reader says: the rename sheet closed
    /// before the suggestions came, or the webhook preview did.
    static let stoppedNotice = "Stopped before it finished."

    /// How a request stands, from its record: the outcome it recorded;
    /// running while this launch has it under way; interrupted otherwise.
    /// A record written before outcomes were kept is read from what it left:
    /// its notice, and, for a chat title, whether its chat still waits on it
    /// (a quit left that claim in place) or took a title from it.
    static func status(of record: ChatRecord, running: Bool, source: ChatRecord?) -> BackgroundRequestStatus {
        switch record.backgroundTaskOutcome {
        case "completed"?: return .completed
        case "failed"?: return .failed(record.backgroundTaskNotice ?? "The request failed.")
        case "interrupted"?: return .interrupted(record.backgroundTaskNotice ?? interruptedNotice)
        default: break
        }
        if running { return .running }
        if record.backgroundTaskStartedAt == nil {
            if let notice = record.backgroundTaskNotice {
                return notice.localizedCaseInsensitiveContains("interrupted") ? .interrupted(notice) : .failed(notice)
            }
            if BackgroundRequestKind(record.backgroundTask ?? "") == .title,
               source?.titleTaskSessionID != record.id || source?.titleWasGenerated == true { return .completed }
        }
        return .interrupted(record.backgroundTaskNotice ?? interruptedNotice)
    }

    /// What a finished request produced, read from its reply: the title, the
    /// suggestions one per line, or the notification's parameters.
    static func result(kind: BackgroundRequestKind, messages: [TranscriptMessage]) -> String? {
        switch kind {
        case .title: return TitleGenerationPlan.title(from: messages)
        case .suggestions:
            let titles = TitleGenerationPlan.titles(from: messages, limit: 3)
            return titles.isEmpty ? nil : titles.joined(separator: "\n")
        case .webhook, .other:
            guard let reply = messages.last(where: { $0.role == "assistant" && $0.kind == nil })?.text else { return nil }
            return webhookResult(reply: reply, names: nil)
        }
    }

    /// A webhook reply's parameters, one "name: value" per line in the order
    /// the webhook names them (alphabetical when the names are not known), or
    /// the reply itself when it holds none.
    static func webhookResult(reply: String, names: [String]?) -> String? {
        var object: [String: Any] = [:]
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let parsed = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] { object = parsed }
        let order = names ?? object.keys.sorted()
        let lines: [String] = order.compactMap { name in
            guard let value = object[name], !(value is NSNull) else { return nil }
            let text = value as? String ?? (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : name + ": " + trimmed
        }
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The moment a record written before start times were kept was created:
    /// its sidebar order, which a new record takes from the clock.
    static func createdAt(_ record: ChatRecord) -> Date? {
        record.sidebarOrder.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1_000_000) : nil }
    }
}

/// One request as the page lists it, everything it shows worked out once.
struct BackgroundRequestRow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: BackgroundRequestKind
    let startedAt: Date?
    let endedAt: Date?
    let status: BackgroundRequestStatus
    /// The title, the suggestions or the notification's parameters.
    let result: String?
    let sourceID: String?
    /// Nil when the chat it was for is gone.
    let sourceTitle: String?
    let project: String?
    let connection: String?
    let model: String?
    let path: String?
    let totals: GatewayTotals?

    /// Milliseconds from sent to ended, when both are known.
    var durationMs: Double? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt) * 1000
    }
    /// The result on one line: suggestions and parameters side by side.
    var resultLine: String? { result.map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ") } }

    /// Every background record as a row, newest first. `lookup` finds a chat
    /// by id; `running` holds the requests this launch has under way;
    /// `totals` is the archive's per-session accounting.
    static func rows(records: [ChatRecord], lookup: (String) -> ChatRecord?, workspaces: [WorkspaceRecord], profiles: [ProfileRecord],
                     running: Set<String>, totals: [String: GatewayTotals]) -> [BackgroundRequestRow] {
        let projects = Dictionary(workspaces.map { ($0.id, URL(fileURLWithPath: $0.path).lastPathComponent) }, uniquingKeysWith: { first, _ in first })
        let connections = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rows = records.compactMap { record -> BackgroundRequestRow? in
            guard let task = record.backgroundTask else { return nil }
            let source = record.sourceSessionID.flatMap(lookup)
            return BackgroundRequestRow(
                id: record.id, kind: BackgroundRequestKind(task),
                startedAt: record.backgroundTaskStartedAt ?? BackgroundRequests.createdAt(record), endedAt: record.backgroundTaskEndedAt,
                status: BackgroundRequests.status(of: record, running: running.contains(record.id), source: source),
                result: record.backgroundTaskResult, sourceID: record.sourceSessionID, sourceTitle: source?.title,
                project: source.flatMap { $0.workspaceID == WorkspaceRecord.scratchID ? "No project" : projects[$0.workspaceID] },
                connection: connections[record.profileID], model: record.model, path: record.path,
                totals: totals[record.workspaceID + "\u{0}" + record.id])
        }
        return rows.sorted { lhs, rhs in
            let a = lhs.startedAt ?? .distantPast, b = rhs.startedAt ?? .distantPast
            return a != b ? a > b : lhs.id > rhs.id
        }
    }
}

/// What the requests the filter shows add up to, for the page's caption.
struct BackgroundRequestSummary: Equatable, Sendable {
    var requests = 0
    var running = 0
    var failed = 0
    /// Reported tokens and cost, and how many requests reported them.
    var tokens: Double?
    var cost: Double?
    var costSamples = 0
    var accounted = 0
    init() {}
    init(_ rows: [BackgroundRequestRow]) {
        requests = rows.count
        for row in rows {
            if row.status == .running { running += 1 }
            if case .failed = row.status { failed += 1 }
            guard let totals = row.totals, totals.requests > 0 else { continue }
            accounted += totals.requests
            if let billed = totals.billedTotalTokens { tokens = (tokens ?? 0) + billed }
            if totals.costSamples > 0, let value = totals.costUSD, value.isFinite { cost = (cost ?? 0) + value; costSamples += totals.costSamples }
        }
    }
}

/// What a request sent and got back, read from its journal.
struct BackgroundRequestDetail: Equatable, Sendable {
    var prompt: String?
    var reply: String?
    /// Why nothing could be read.
    var unavailable: String?
}

/// The Background requests page's state: the filter, the selection and the
/// rows, worked out when the records change rather than while the page is
/// drawn; per-session accounting from the archive; the selected request's
/// prompt and reply, read off the main thread. Kept while the app runs, so
/// the page comes back as it was left.
@MainActor final class BackgroundRequestsController: ObservableObject {
    @Published var filter: BackgroundRequestFilter = .all { didSet { if filter != oldValue { applyFilter() } } }
    @Published var selectedID: String? { didSet { if selectedID != oldValue { loadDetail() } } }
    /// The rows the filter shows, newest first.
    @Published private(set) var rows: [BackgroundRequestRow] = []
    @Published private(set) var counts: [BackgroundRequestFilter: Int] = [:]
    @Published private(set) var summary = BackgroundRequestSummary()
    /// Nil while the selected request's journal is read.
    @Published private(set) var detail: BackgroundRequestDetail?
    @Published private(set) var detailLoading = false
    private(set) var all: [BackgroundRequestRow] = []
    private var totals: [String: GatewayTotals] = [:]
    private weak var model: WorkspaceModel?
    private var totalsTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var detailFor: (id: String, status: BackgroundRequestStatus, path: String?)?
    /// Test seam: journals read for results records did not keep.
    private(set) var backfilledResults = 0

    /// The page came up: rows now, then the accounting and any result an
    /// older record did not keep.
    func prepare(_ model: WorkspaceModel) {
        self.model = model
        rebuild()
        loadTotals()
        backfillResults()
    }
    /// The page went away: nothing more is read for it.
    func suspend() {
        totalsTask?.cancel(); totalsTask = nil
        backfillTask?.cancel(); backfillTask = nil
    }
    /// The records changed: the rows again, and the accounting when a request
    /// started or ended.
    func recordsChanged() {
        let before = Dictionary(all.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        rebuild()
        if all.contains(where: { before[$0.id] != $0.status }) { loadTotals() }
    }

    private func rebuild() {
        guard let model else { return }
        all = BackgroundRequestRow.rows(records: model.chats.filter(\.isBackgroundTask), lookup: model.chatRecord, workspaces: model.workspaces,
                                        profiles: model.profiles, running: model.backgroundRequestsRunning, totals: totals)
        applyFilter()
        // The selected request's prompt and reply: read when it was chosen
        // before its row was listed, and again once it ends.
        if let selectedID, let row = all.first(where: { $0.id == selectedID }),
           detailFor?.id != selectedID || detailFor?.status != row.status || detailFor?.path != row.path { loadDetail() }
    }
    private func applyFilter() {
        var counts: [BackgroundRequestFilter: Int] = [:]
        for filter in BackgroundRequestFilter.allCases { counts[filter] = all.filter { filter.includes($0.kind) }.count }
        let shown = all.filter { filter.includes($0.kind) }
        let summary = BackgroundRequestSummary(shown)
        if self.counts != counts { self.counts = counts }
        if rows != shown { rows = shown }
        if self.summary != summary { self.summary = summary }
    }

    private func loadTotals() {
        guard let model else { return }
        totalsTask?.cancel()
        totalsTask = Task { [weak self, traces = model.traces] in
            guard let loaded = try? await traces.allSessionTotals(), !Task.isCancelled, let self else { return }
            self.totals = loaded
            self.rebuild()
        }
    }

    /// Reads the selected request's prompt and reply from its journal.
    private func loadDetail() {
        detailTask?.cancel(); detailTask = nil
        guard let id = selectedID, let row = all.first(where: { $0.id == id }) else { detail = nil; detailLoading = false; detailFor = nil; return }
        detailFor = (id, row.status, row.path)
        guard let path = row.path else {
            detail = BackgroundRequestDetail(unavailable: row.status == .running ? "The request's journal is being written." : "This request left no journal to read.")
            detailLoading = false
            return
        }
        detail = nil; detailLoading = true
        detailTask = Task { [weak self] in
            let read = await BackgroundRequestsController.read(path: path)
            guard !Task.isCancelled, let self, self.selectedID == id else { return }
            self.detail = read; self.detailLoading = false
        }
    }

    /// A request's prompt and reply, in full, from its journal. Its own
    /// reader, so the chats' indexes stay as they are.
    nonisolated static func read(path: String) async -> BackgroundRequestDetail {
        let reader = HistoryReader()
        do {
            let page = try await reader.read(path: path)
            /// A message's whole text: the page's, or every page of a long one.
            func whole(_ message: TranscriptMessage?) async -> String? {
                guard let message else { return nil }
                guard message.truncated == true else { return message.text }
                var text = "", offset = 0
                while !Task.isCancelled, let page = try? await reader.message(path: path, id: message.id, field: "content", offset: offset), !page.0.isEmpty {
                    text += page.0; offset += (page.0 as NSString).length
                    if offset >= page.1 { break }
                }
                return text.isEmpty ? message.text : text
            }
            var detail = BackgroundRequestDetail()
            detail.prompt = await whole(page.messages.first { $0.role == "user" && $0.kind == nil })
            detail.reply = await whole(page.messages.last { $0.role == "assistant" && $0.kind == nil })
            if detail.prompt == nil && detail.reply == nil { detail.unavailable = page.notice ?? "The journal holds no request yet." }
            return detail
        } catch {
            return BackgroundRequestDetail(unavailable: "The request's journal could not be read: " + error.localizedDescription)
        }
    }

    /// Records written before results were kept: their result read from the
    /// reply their journal holds, once, and kept with them.
    private func backfillResults() {
        guard backfillTask == nil, let model else { return }
        let wanting = all.filter { $0.status == .completed && $0.result == nil && $0.path != nil }
        guard !wanting.isEmpty else { return }
        backfillTask = Task { [weak self] in
            var found: [(id: String, result: String)] = []
            for row in wanting {
                guard !Task.isCancelled, let path = row.path else { break }
                let reader = HistoryReader()
                guard let page = try? await reader.read(path: path), let result = BackgroundRequests.result(kind: row.kind, messages: page.messages) else { continue }
                found.append((row.id, result))
                if found.count == 50 { await model.keepBackgroundResults(found); found = [] }
                self?.backfilledResults += 1
            }
            if !found.isEmpty { await model.keepBackgroundResults(found) }
            self?.backfillTask = nil
        }
    }
}

extension WorkspaceModel {
    /// Opens the Background requests page, with one request selected.
    func openBackgroundRequests(selecting id: String? = nil) {
        if let id { backgroundRequests.selectedID = id }
        page = .background
    }
    func toggleBackgroundRequests() { page = page == .background ? .chats : .background }

    /// The Session Inspector of a background request: its captured requests.
    func inspectBackgroundRequest(_ id: String) { openInspector(session: id, focus: .latestRequest) }
    /// The chat a background request was for.
    func openBackgroundRequestSource(_ id: String) {
        guard let source = chatRecord(id)?.sourceSessionID, chatRecord(source) != nil else { return }
        Task { await select(source) }
    }

    /// A background request begins: its record, with the moment it was sent.
    func beginBackgroundRequest(_ record: inout ChatRecord) {
        record.backgroundTaskStartedAt = Date()
        backgroundRequestsRunning.insert(record.id)
    }

    /// Records how a background request ended: on its row and in the store.
    func finishBackgroundRequest(_ id: String, outcome: String, result: String? = nil, notice: String? = nil) async {
        backgroundRequestsRunning.remove(id)
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        var record = chats[index]
        record.backgroundTaskOutcome = outcome; record.backgroundTaskEndedAt = Date()
        if let result { record.backgroundTaskResult = result }
        if let notice { record.backgroundTaskNotice = String(notice.prefix(2_000)) }
        chats[index] = record
        try? await store?.put(record, kind: "chat", id: id)
    }

    /// Launch, before anything is sent: a request a quit or crash cut short
    /// ends as interrupted, and a record written before outcomes were kept
    /// gets the outcome it had, from what it left. Nothing is sent again.
    func settleBackgroundRequests() async {
        var settled: [ChatRecord] = []
        for record in chats where record.isBackgroundTask && record.backgroundTaskOutcome == nil && !backgroundRequestsRunning.contains(record.id) {
            var next = record
            switch BackgroundRequests.status(of: record, running: false, source: record.sourceSessionID.flatMap(chatRecord)) {
            case .running: continue
            case .completed: next.backgroundTaskOutcome = "completed"
            case .failed(let why): next.backgroundTaskOutcome = "failed"; next.backgroundTaskNotice = why
            case .interrupted(let why): next.backgroundTaskOutcome = "interrupted"; next.backgroundTaskNotice = why
            }
            if next.backgroundTaskStartedAt == nil { next.backgroundTaskStartedAt = BackgroundRequests.createdAt(record) }
            settled.append(next)
        }
        guard !settled.isEmpty else { return }
        let byID = Dictionary(settled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        chats = chats.map { byID[$0.id] ?? $0 }
        try? await store?.putChats(settled)
    }

    /// Results read back from older records' journals, kept with them.
    func keepBackgroundResults(_ results: [(id: String, result: String)]) async {
        var kept: [ChatRecord] = []
        var next = chats
        for (id, result) in results {
            guard let index = next.firstIndex(where: { $0.id == id }), next[index].backgroundTaskResult == nil else { continue }
            next[index].backgroundTaskResult = result
            kept.append(next[index])
        }
        guard !kept.isEmpty else { return }
        chats = next
        try? await store?.putChats(kept)
    }
}
