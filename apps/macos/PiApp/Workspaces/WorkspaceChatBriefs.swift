import Foundation
import Combine

// Chat briefs (0.1.131, FIND-1): at the end of every run, a chat's
// connection's mini model updates a sentence or two on what the chat is
// about and a few keywords, from the earlier brief and what is new since it
// was written (`ChatBriefPlan`). Sidebar search's Titles & details matches
// them and a row's hover card shows them, or offers to write one. Chats
// without a brief get one only when asked: Write Brief on the chat, or
// Settings' Write Briefs for chats without one, one at a time. Each request
// is a background request of its own ("chat-brief"): on the Background
// requests page, in Usage, and summed beside the setting. A brief is app
// metadata on the chat's record: nothing enters the conversation, its
// journal or any model context, and the chat's text goes only to its own
// connection.

/// Settings → Chats & notifications → Chat briefs.
struct ChatBriefSettings: Codable, Sendable, Equatable {
    /// On unless the reader turns it off (owner, 2026-10-23).
    var enabled = true
    init(enabled: Bool = true) { self.enabled = enabled }
    private enum CodingKeys: String, CodingKey { case enabled }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// How one attempt to write a chat's brief ended.
enum ChatBriefOutcome: Equatable, Sendable {
    case written
    /// Nothing was said since the brief was written: nothing was sent.
    case nothingNew
    /// The chat's connection has no mini model, or is gone: nothing was sent.
    case noMiniModel
    /// The chat's history could not be read: nothing was sent.
    case unreadable(String)
    /// The chat moved to another connection while the request was being
    /// prepared: nothing was sent (it is asked again on the new one).
    case connectionChanged
    case failed(String)
    /// Briefs went off, the request was stopped, the app is closing, or the
    /// chat cannot have a brief.
    case skipped
}

/// Briefs written for the chats that had none, one at a time, on request:
/// how far it got.
struct ChatBriefBatch: Equatable, Sendable {
    /// The chats it was asked for, newest activity first.
    let chats: [String]
    let startedAt: Date
    var total: Int { chats.count }
    /// Chats looked at so far, and of those, briefs written and requests failed.
    var done = 0
    var written = 0
    var failed = 0
    /// Over: every chat looked at, or stopped (`stopped` says why).
    var finished = false
    var stopped: String?
    /// The background requests it made itself: what it spent, and nothing a
    /// run's end asked for in the same chats.
    var requests: [String] = []
}

/// What brief requests came to over a window, from the request archive.
struct ChatBriefUsage: Equatable, Sendable {
    /// Brief requests made, as the Background requests page lists them.
    var requests = 0
    /// What the gateway reported they cost, and how many of those that
    /// reached it and are over reported no cost.
    var costUSD = 0.0
    var unreported = 0

    /// Each request's archive totals (nil, or no attempt, for one that never
    /// reached the gateway, or is not in the archive yet) and whether it is
    /// over: one still running has no cost to report yet.
    static func sum(_ requests: [(totals: GatewayTotals?, over: Bool)]) -> ChatBriefUsage {
        var usage = ChatBriefUsage(requests: requests.count)
        for (totals, over) in requests {
            guard let totals, totals.requests > 0 else { continue }
            if totals.costSamples > 0, let cost = totals.costUSD, cost.isFinite { usage.costUSD += max(0, cost) }
            else if over { usage.unreported += 1 }
        }
        return usage
    }
    /// "4 requests · $0.0052".
    var label: String {
        guard requests > 0 else { return "None" }
        return (requests == 1 ? "1 request" : "\(requests) requests") + " · " + Self.dollars(costUSD)
    }
    /// How many of them reached the gateway and came back without a cost.
    var note: String? {
        guard unreported > 0 else { return nil }
        return unreported == 1 ? "1 came back without a reported cost." : "\(unreported) came back without a reported cost."
    }
    /// `$0.0042`; `$0.00` for nothing (`MetricFormat.centsUSD`).
    static func dollars(_ value: Double) -> String {
        value > 0 && value.isFinite ? MetricFormat.centsUSD(value, places: 4, padded: false) : "$0.00"
    }
}

/// Writes chat briefs: at every run's end, on request, and for every chat
/// without one when Settings asks. Never two requests at once for one chat:
/// a run that ends while its chat's brief is being written has one more
/// update written after it. Nothing is written while briefs are off.
@MainActor final class ChatBriefs: ObservableObject {
    private weak var model: WorkspaceModel?
    /// The chats whose brief is being written.
    @Published private(set) var writing: Set<String> = []
    /// The run for chats without a brief: while it goes on, and once over
    /// until the next one.
    @Published private(set) var batch: ChatBriefBatch?
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Chats whose run ended while their brief was being written.
    private(set) var pending: Set<String> = []
    private var batchTask: Task<Void, Never>?
    /// Which batch is the current one: a stopped one's task ends without
    /// touching the next.
    private var batchGeneration: UInt64 = 0
    /// The chat whose request the batch started and is waiting on.
    private var batchCurrent: String?
    private var watch: AnyCancellable?
    private var stopped = false
    /// Brief reads go through a reader of their own, never the one every
    /// chat's opening and paging goes through (`WorkspaceModel.history`): a
    /// long journal's index rebuilt for a brief holds up nothing else.
    let reader = HistoryReader()
    /// Test seams: requests begun, how each chat's last one ended, and a hook
    /// run just before a request is sent.
    private(set) var attempts = 0
    private(set) var outcomes: [String: ChatBriefOutcome] = [:]
    var beforeDispatch: (@MainActor (String) async -> Void)?
    /// Each chat's brief as search compares it, folded once per brief.
    private var searchKeys: [String: (at: Date, key: [UInt8])] = [:]

    init(model: WorkspaceModel) {
        self.model = model
        watch = model.$configuration.map(\.briefSettings).removeDuplicates().dropFirst().sink { [weak self] settings in
            MainActor.assumeIsolated { if !settings.enabled { self?.halt("Stopped: chat briefs were turned off.") } }
        }
    }

    /// A chat's brief as sidebar search compares it (`ChatBrief.searchKey`).
    func searchKey(_ chatID: String, _ brief: ChatBrief) -> [UInt8] {
        if let held = searchKeys[chatID], held.at == brief.at { return held.key }
        let key = brief.searchKey
        searchKeys[chatID] = (brief.at, key)
        return key
    }

    /// A chat finished a run, or the reader asked for its brief: it is
    /// written now, or once the one under way for it is done.
    func write(_ id: String) {
        guard !stopped, let model, model.briefSettings.enabled, let chat = model.chatRecord(id), model.briefEligible(chat) else { return }
        if tasks[id] != nil { pending.insert(id); return }
        start(id)
    }
    func isWriting(_ id: String) -> Bool { tasks[id] != nil }
    /// A brief being prepared or asked for: work under way, which a quit or
    /// an update's idle barrier waits for (`WorkspaceModel.hasActiveWork`).
    var busy: Bool { !tasks.isEmpty }
    /// Why the chat's last request wrote no brief, where the reader can do
    /// something about it: its hover card says so.
    func lastProblem(_ id: String) -> String? {
        switch outcomes[id] {
        case .noMiniModel?: return "Its connection has no mini model to write one. Choose one in Settings → Connections."
        case .unreadable(let why)?: return "Its history could not be read. " + why
        case .failed(let why)?: return "The last request failed. " + why
        default: return nil
        }
    }

    /// `batch`: the batch (its generation) the request is for, which keeps
    /// the request's ID as its own.
    @discardableResult private func start(_ id: String, batch generation: UInt64? = nil) -> Task<Void, Never>? {
        if let running = tasks[id] { return running }
        guard let model else { return nil }
        attempts += 1
        var kept: (@MainActor (String) -> Void)?
        if let generation {
            kept = { [weak self] (request: String) in
                guard let self, self.batchGeneration == generation else { return }
                self.batch?.requests.append(request)
            }
        }
        let task = Task { [weak self, weak model] in
            var outcome = await model?.writeBrief(id, onRequest: kept) ?? .skipped
            // Moved to another connection while it was prepared: asked
            // again, once, on the connection it is on now.
            if outcome == .connectionChanged, !Task.isCancelled {
                self?.attempts += 1
                outcome = await model?.writeBrief(id, onRequest: kept) ?? .skipped
            }
            self?.finished(id, outcome)
        }
        tasks[id] = task
        // Published last: what a card reads as it changes (`isWriting`) is
        // already true.
        writing.insert(id)
        return task
    }

    private func finished(_ id: String, _ outcome: ChatBriefOutcome) {
        tasks[id] = nil
        outcomes[id] = outcome
        // Published last: a card reading the chat as it changes finds the
        // request over and how it ended (`lastProblem`).
        writing.remove(id)
        // A run ended meanwhile: one more update, from where this one read to.
        if pending.remove(id) != nil { write(id) }
    }

    // MARK: Chats without a brief

    /// The chats that can have a brief and have none, newest activity first.
    /// Archived chats are left out: only Write Brief writes one for them.
    func chatsWithoutBrief() -> [ChatRecord] {
        guard let model, model.briefSettings.enabled else { return [] }
        return model.chats.filter { $0.brief == nil && !$0.isArchived && model.briefEligible($0) }
            .sorted { $0.activityStamp != $1.activityStamp ? $0.activityStamp > $1.activityStamp : $0.id < $1.id }
    }

    /// Writes a brief for each chat without one, one at a time, newest
    /// first. Three failed requests in a row stop it; so does Stop, and
    /// turning briefs off.
    func startBatch() {
        guard batchTask == nil, !stopped, let model, model.briefSettings.enabled else { return }
        let ids = chatsWithoutBrief().map(\.id)
        guard !ids.isEmpty else { return }
        batch = ChatBriefBatch(chats: ids, startedAt: Date())
        batchGeneration &+= 1
        let generation = batchGeneration
        batchTask = Task { [weak self] in
            var failures = 0
            for id in ids {
                guard let self, !Task.isCancelled, self.batchGeneration == generation else { return }
                var outcome: ChatBriefOutcome?
                if let running = self.tasks[id] {
                    // Being written already (a run's end): that request counts.
                    await running.value
                    outcome = self.outcomes[id]
                } else if let model = self.model, let chat = model.chatRecord(id), chat.brief == nil, !chat.isArchived, model.briefEligible(chat) {
                    // Looked at again as its turn comes: archived, or given a
                    // brief, since the batch began, it is left alone.
                    self.batchCurrent = id
                    await self.start(id, batch: generation)?.value
                    outcome = self.outcomes[id]
                }
                guard !Task.isCancelled, self.batchGeneration == generation else { return }
                self.batchCurrent = nil
                self.batch?.done += 1
                switch outcome {
                case .written?: self.batch?.written += 1; failures = 0
                case .failed?: self.batch?.failed += 1; failures += 1
                default: break
                }
                if failures == 3, case .failed(let why)? = outcome {
                    self.batch?.stopped = "Stopped after three failed requests in a row. " + why
                    break
                }
            }
            guard let self, self.batchGeneration == generation else { return }
            self.batch?.finished = true
            self.batchTask = nil; self.batchCurrent = nil
        }
    }
    /// Stop: the request the batch is waiting on is stopped too; a run's
    /// end that came meanwhile still has its update.
    func stopBatch(_ reason: String = "Stopped.") {
        guard let batchTask else { return }
        batchGeneration &+= 1
        batchTask.cancel()
        if let id = batchCurrent { tasks[id]?.cancel() }
        batch?.stopped = reason
        batch?.finished = true
        self.batchTask = nil; batchCurrent = nil
    }
    var batchRunning: Bool { batchTask != nil }

    /// Off: every request under way is stopped, and none waits.
    private func halt(_ reason: String) {
        stopBatch(reason)
        for task in tasks.values { task.cancel() }
        pending = []
    }
    func shutdown() {
        stopped = true
        halt("Stopped.")
        watch = nil
    }
}

extension WorkspaceModel {
    /// Chat briefs, made the first time something asks.
    var chatBriefs: ChatBriefs {
        if let chatBriefsStorage { return chatBriefsStorage }
        let briefs = ChatBriefs(model: self)
        chatBriefsStorage = briefs
        return briefs
    }
    var briefSettings: ChatBriefSettings { configuration.briefSettings }
    /// A chat finished a run (`observeSessionCompletion`). An archived chat
    /// keeps the brief it has; only Write Brief updates it.
    func noteBriefRunFinished(_ id: String) {
        guard briefSettings.enabled, chatRecord(id)?.isArchived != true else { return }
        chatBriefs.write(id)
    }
    /// Write Brief, from a chat's menu or its row's card.
    func writeBriefNow(_ id: String) { chatBriefs.write(id) }

    /// The chats that get a brief: the reader's own saved chats in a project,
    /// main chats and kept sides. Never a sub-agent, an unsaved side,
    /// imported history, a background request or connection test, or a chat
    /// not yet sent.
    func briefEligible(_ chat: ChatRecord) -> Bool {
        !chat.isUtilityChat && !chat.isSubagent && !chat.imported && chat.workspaceID != WorkspaceRecord.scratchID
            && chat.path != nil && !pendingChatIDs.contains(chat.id) && (chat.parentSessionID == nil || !isEphemeral(chat.id))
    }
    /// Whether a chat's row offers a brief (shows it, or offers to write one).
    func offersBrief(_ chat: ChatRecord) -> Bool { briefSettings.enabled && briefEligible(chat) }
    /// The brief sidebar search and the row's hover show: none while briefs are off.
    func sidebarBrief(_ chat: ChatRecord) -> ChatBrief? { offersBrief(chat) ? chat.brief : nil }

    /// Writes or updates one chat's brief: the connection's mini model asked
    /// with the earlier brief and the chat's newest page, read on the briefs'
    /// own reader (`ChatBriefs.reader`), open or not. The chat's connection is held from
    /// the first read until the request is sent: a chat moved to another
    /// connection meanwhile sends nothing through the old one
    /// (`connectionChanged`). The brief lands on the chat's record only.
    func writeBrief(_ id: String, onRequest: (@MainActor (String) -> Void)? = nil) async -> ChatBriefOutcome {
        // A move to another connection under way finishes first: the brief is
        // asked of the connection the chat is on.
        while let change = connectionSwitches[id], !Task.isCancelled { await change.task.value }
        guard briefSettings.enabled, !isShutDown, !installPreparing, !Task.isCancelled, let store, let chat = chatRecord(id), briefEligible(chat),
              let path = chat.path else { return .skipped }
        // A chat whose connection is gone, or going, has no mini model to ask.
        guard let profile = profiles.first(where: { $0.id == chat.profileID }) else { return .noMiniModel }
        let lease: ConnectionLease
        do { lease = try connectionLease(for: chat) } catch { return Self.movedConnection(error) ? .connectionChanged : .noMiniModel }
        _ = await listModels(for: profile)
        // A quit or an update that began meanwhile (`installPreparing`) has
        // stopped, or is stopping, the helpers: nothing more is started.
        guard !Task.isCancelled, briefSettings.enabled, !installPreparing, !isShutDown else { return .skipped }
        let descriptors = catalogEntry(for: profile).descriptors
        guard TitleGenerationPlan.miniModel(profile: profile, descriptors: descriptors) != nil else { return .noMiniModel }
        let activity = chatRecord(id)?.activityStamp ?? chat.activityStamp
        let page: HistoryPage
        do { page = try await chatBriefs.reader.read(path: path) }
        catch { return .unreadable(error.localizedDescription) }
        // A page that starts inside a long turn names the question that opened
        // it by its row: quoted as text, as much of it as a message takes.
        var opening: String?
        if let row = page.partialTurnInput, page.notice == nil {
            opening = try? await chatBriefs.reader.message(path: path, id: row, field: "content", offset: 0).0
        }
        await chatBriefs.beforeDispatch?(id)
        guard !Task.isCancelled, briefSettings.enabled, !installPreparing, !isShutDown else { return .skipped }
        // Everything read was the chat's on this connection: still on it now,
        // and again just before the request is sent, or nothing is sent.
        do { try requireConnection(lease) } catch { return Self.movedConnection(error) ? .connectionChanged : .noMiniModel }
        // A damaged record or a tail cut off mid-write: nothing is summed
        // up from what is left, and the chat says why.
        if let notice = page.notice { return .unreadable(notice) }
        guard let current = chatRecord(id),
              let plan = ChatBriefPlan(profile: profile, descriptors: descriptors, title: current.displayTitle, previous: current.brief,
                                       rows: page.messages, partialTurnInput: opening) else { return .nothingNew }
        let request = MiniModelRequest(model: plan.model, contextWindow: plan.contextWindow, maxOutputTokens: plan.maxOutputTokens,
                                       modelOutputLimit: plan.modelOutputLimit, thinkingLevel: plan.thinkingLevel, prompt: plan.prompt,
                                       task: BackgroundRequestKind.brief.raw, title: "Chat brief", timeout: 60, name: "brief request")
        do {
            let messages = try await askMiniModel(request, profile: profile, sourceID: id, sourceLease: lease, onRecord: onRequest) { messages in
                guard let result = ChatBriefPlan.result(from: messages) else { throw HostError.failure("The mini model did not return a usable brief.") }
                return result
            }
            guard let parsed = ChatBriefPlan.brief(from: messages) else { return .failed("The mini model did not return a usable brief.") }
            let brief = ChatBrief(text: parsed.text, keywords: parsed.keywords, through: plan.through, at: Date(), activity: activity)
            guard !isShutDown, let saved = try await store.applyChatBrief(brief, chatID: id) else { return .skipped }
            if let index = chats.firstIndex(where: { $0.id == id }) { chats[index].brief = saved.brief }
            return .written
        } catch {
            if error is CancellationError || Task.isCancelled { return .skipped }
            if Self.movedConnection(error) { return .connectionChanged }
            return .failed(error.localizedDescription)
        }
    }
    /// The chat moved, or is moving, to another connection (`requireConnection`).
    private static func movedConnection(_ error: any Error) -> Bool {
        if case .rejected("connection_changed", _)? = error as? HostError { return true }
        return false
    }

    /// What brief requests made since `start` came to, read from the request
    /// archive: their number, as the Background requests page lists them,
    /// and the cost the gateway reported for them; only `sources`' chats'
    /// when given.
    func briefUsage(since start: Date, for sources: Set<String>? = nil) async -> ChatBriefUsage {
        await briefUsage(of: chats.filter { chat in
            chat.backgroundTask == BackgroundRequestKind.brief.raw && (chat.backgroundTaskStartedAt ?? .distantPast) >= start
                && (sources.map { sources in chat.sourceSessionID.map(sources.contains) == true } ?? true)
        })
    }
    /// What these brief requests came to: a batch's own (`ChatBriefBatch.requests`).
    func briefUsage(requests: Set<String>) async -> ChatBriefUsage {
        await briefUsage(of: chats.filter { $0.backgroundTask == BackgroundRequestKind.brief.raw && requests.contains($0.id) })
    }
    private func briefUsage(of recent: [ChatRecord]) async -> ChatBriefUsage {
        guard !recent.isEmpty else { return ChatBriefUsage() }
        let scopes = recent.map { SessionUsageScope(sessionID: $0.id, workspaceID: $0.workspaceID) }
        var totals: [SessionUsageScope: GatewayTotals] = [:]
        for first in stride(from: 0, to: scopes.count, by: TopicSessionDrag.maximumSessions) {
            let batch = Array(scopes[first..<min(first + TopicSessionDrag.maximumSessions, scopes.count)])
            if let read = try? await traces.sessionReferenceTotals(scopes: batch) { totals.merge(read) { first, _ in first } }
        }
        return ChatBriefUsage.sum(zip(scopes, recent).map { (totals: totals[$0], over: $1.backgroundTaskOutcome != nil) })
    }
}
