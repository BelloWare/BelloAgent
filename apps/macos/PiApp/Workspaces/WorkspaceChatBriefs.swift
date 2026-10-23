import Foundation
import Combine

// Chat briefs (0.1.131, FIND-1): when a chat finishes a run, its connection's
// mini model updates a sentence or two on what the chat is about and a few
// keywords, from the earlier brief and what is new since it was written
// (`ChatBriefPlan`). Sidebar search's Titles & details matches them and a
// row's hover card shows them. Chats without one are filled in one at a
// time, newest first, under a daily spending cap. Each request is a
// background request of its own ("chat-brief"), kept on the Background
// requests page and in Usage like a title's. A brief is app metadata on the
// chat's record: nothing enters the conversation, its journal or any model
// context, and the chat's text goes only to its own connection.

/// Settings → Chats & notifications → Chat briefs.
struct ChatBriefSettings: Codable, Sendable, Equatable {
    /// Off until the reader turns it on: briefs cost a mini-model request each.
    var enabled = false
    /// The most brief requests may spend in any 24 hours, in US dollars.
    var dailyCapUSD = ChatBriefSettings.defaultCap
    static let defaultCap = 0.25
    static let capChoices: [Double] = [0.10, 0.25, 0.50, 1, 5]
    static func capLabel(_ value: Double) -> String { String(format: "$%.2f a day", value) }
    var isValid: Bool { dailyCapUSD.isFinite && dailyCapUSD > 0 && dailyCapUSD <= 100 }

    init(enabled: Bool = false, dailyCapUSD: Double = ChatBriefSettings.defaultCap) { self.enabled = enabled; self.dailyCapUSD = dailyCapUSD }
    private enum CodingKeys: String, CodingKey { case enabled, dailyCapUSD }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        dailyCapUSD = try c.decodeIfPresent(Double.self, forKey: .dailyCapUSD) ?? Self.defaultCap
    }
}

/// How one attempt to write a chat's brief ended.
enum ChatBriefOutcome: Equatable, Sendable {
    case written
    /// Nothing was said since the brief was written: nothing was sent.
    case nothingNew
    /// The chat's connection has no mini model, or is gone: nothing was sent.
    case noMiniModel
    /// The chat's history could not be read: nothing was sent, and the chat
    /// is set aside until it changes.
    case unreadable(String)
    /// The day's brief requests reached the cap: nothing was sent.
    case capReached
    case failed(String)
    /// Briefs went off, the app is closing, or the chat cannot have one.
    case skipped
}

/// Decides when briefs are written, one request at a time: a chat whose run
/// ended, once it has rested; otherwise, at a slow pace, the chat the reader
/// has open or the most recently active one that has no brief yet or has
/// moved on since. Nothing is sent while briefs are off or past the cap.
@MainActor final class ChatBriefs {
    private weak var model: WorkspaceModel?
    /// How long a chat rests after a run ends before its brief is updated:
    /// a quick follow-up joins the same update.
    var updateDelay: Duration = .seconds(120)
    /// The least time between two updates of one chat's brief.
    var minimumInterval: TimeInterval = 30 * 60
    /// Between two briefs written for chats that have none, or an old one.
    var backfillGap: Duration = .seconds(60)
    /// After launch, before the first of those.
    var startDelay: Duration = .seconds(120)
    /// After a request that failed, before the next one.
    var failurePause: Duration = .seconds(600)
    /// After the cap was reached, before the day's spend is read again.
    var capPause: Duration = .seconds(900)
    /// What a request counts against the cap when the gateway reported no
    /// cost for it (yet): a gateway that reports none still stops.
    nonisolated static let unreportedCost = 0.01
    /// The window the cap counts over.
    nonisolated static let capWindow: TimeInterval = 24 * 60 * 60
    /// Briefs start on their own a little after launch in the app; in tests
    /// a fixture starts them.
    static var startsAutomatically = ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1"

    /// Chats whose run ended, and when their update is due.
    private(set) var due: [String: ContinuousClock.Instant] = [:]
    /// The chat the request under way is for.
    private(set) var current: String?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    /// When the next chat without a brief may be given one; nil until started.
    private var backfillFrom: ContinuousClock.Instant?
    private var pausedUntil: ContinuousClock.Instant?
    /// The day's brief requests reached the cap.
    private(set) var capReached = false
    /// Nothing is sent before a pause ends (a failure or the cap).
    var paused: Bool { pausedUntil.map { $0 > .now } ?? false }
    /// Chats looked at, at the activity they had: nothing more to do for
    /// them until they change (nothing new, a failure, a reply with no brief).
    private var settled: [String: Int64] = [:]
    /// Connections found without a mini model, until when they are not asked again.
    private var noMiniModel: [String: ContinuousClock.Instant] = [:]
    private var watch: AnyCancellable?
    private var stopped = false
    /// Test seams: requests asked for, and how each chat's last one ended.
    private(set) var attempts = 0
    private(set) var outcomes: [String: ChatBriefOutcome] = [:]
    /// Each chat's brief as search compares it, folded once per brief.
    private var searchKeys: [String: (at: Date, key: [UInt8])] = [:]

    /// A chat's brief as sidebar search compares it (`ChatBrief.searchKey`).
    func searchKey(_ chatID: String, _ brief: ChatBrief) -> [UInt8] {
        if let held = searchKeys[chatID], held.at == brief.at { return held.key }
        let key = brief.searchKey
        searchKeys[chatID] = (brief.at, key)
        return key
    }

    init(model: WorkspaceModel) {
        self.model = model
        watch = model.$configuration.map(\.briefSettings).removeDuplicates().dropFirst().sink { [weak self] settings in
            MainActor.assumeIsolated { self?.settingsChanged(settings) }
        }
    }

    /// Launch: chats without a brief are filled in from `after` on.
    func start(after delay: Duration? = nil) {
        guard backfillFrom == nil, !stopped else { return }
        backfillFrom = .now + (delay ?? startDelay)
        reschedule()
    }

    /// A chat finished a run: its brief is updated once it has rested, and
    /// not sooner than `minimumInterval` after the last update.
    func runFinished(_ id: String) {
        guard !stopped, let model, model.briefSettings.enabled, let chat = model.chatRecord(id), model.briefEligible(chat), !chat.isArchived else { return }
        var at = ContinuousClock.now + updateDelay
        if let brief = chat.brief {
            let since = Date().timeIntervalSince(brief.at)
            if since < minimumInterval { at = max(at, .now + .seconds(minimumInterval - since)) }
        }
        due[id] = at
        reschedule()
    }

    /// Off stops the request under way and drops every update waiting; on
    /// starts again, the cap read afresh. The configuration publishes before
    /// it changes, so scheduling waits for the change to land.
    private func settingsChanged(_ settings: ChatBriefSettings) {
        noMiniModel = [:]
        guard settings.enabled else { halt(); return }
        capReached = false; pausedUntil = nil
        Task { [weak self] in self?.reschedule() }
    }
    private func halt() {
        timer?.cancel(); timer = nil
        work?.cancel()
        due = [:]
    }
    func shutdown() {
        stopped = true
        halt()
        watch = nil
    }

    // MARK: Scheduling

    private func reschedule() {
        timer?.cancel(); timer = nil
        guard work == nil, !stopped, let model, model.briefSettings.enabled, !model.isShutDown else { return }
        var wake = due.values.min()
        if let backfillFrom, wake.map({ backfillFrom < $0 }) ?? true, nextBackfill() != nil { wake = backfillFrom }
        if let pausedUntil, let next = wake { wake = max(next, pausedUntil) }
        guard let wake else { return }
        timer = Task { [weak self] in
            let wait = wake - .now
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            self?.step()
        }
    }

    private func step() {
        timer = nil
        guard work == nil, !stopped, let model, model.briefSettings.enabled, !model.isShutDown else { return }
        let now = ContinuousClock.now
        if let pausedUntil, pausedUntil > now { reschedule(); return }
        pausedUntil = nil
        if let id = due.filter({ $0.value <= now }).min(by: { $0.value < $1.value })?.key {
            due[id] = nil
            // Still working: the end of its next run asks again. A connection
            // just found without a mini model is not asked about again.
            if model.displays[id]?.hasActiveWork == true || model.chatRecord(id).flatMap({ noMiniModel[$0.profileID] }).map({ $0 > now }) == true {
                reschedule(); return
            }
            begin(id, backfill: false)
        } else if let backfillFrom, backfillFrom <= now, let id = nextBackfill() {
            self.backfillFrom = now + backfillGap
            begin(id, backfill: true)
        } else {
            reschedule()
        }
    }

    private func begin(_ id: String, backfill: Bool) {
        guard let model else { return }
        let activity = model.chatRecord(id)?.activityStamp ?? 0, profile = model.chatRecord(id)?.profileID ?? ""
        current = id; attempts += 1
        work = Task { [weak self, weak model] in
            let outcome = await model?.writeBrief(id, backfill: backfill) ?? .skipped
            self?.finished(id, outcome: outcome, activity: activity, profile: profile)
        }
    }

    private func finished(_ id: String, outcome: ChatBriefOutcome, activity: Int64, profile: String) {
        work = nil; current = nil
        outcomes[id] = outcome
        let now = ContinuousClock.now
        switch outcome {
        case .written, .nothingNew: settled[id] = activity; capReached = false
        case .noMiniModel: noMiniModel[profile] = now + capPause
        case .capReached: capReached = true; pausedUntil = now + capPause
        case .failed: settled[id] = activity; pausedUntil = now + failurePause
        case .unreadable: settled[id] = activity
        case .skipped: break
        }
        reschedule()
    }

    /// The chat to give a brief next, if any: the one the reader has open,
    /// else the one with the newest activity, that has no brief or has moved
    /// on since its brief was written (and that long enough ago).
    private func nextBackfill() -> String? {
        guard let model else { return nil }
        let now = Date(), instant = ContinuousClock.now
        func wants(_ chat: ChatRecord) -> Bool {
            guard model.briefEligible(chat), !chat.isArchived, current != chat.id, due[chat.id] == nil,
                  settled[chat.id] != chat.activityStamp, (noMiniModel[chat.profileID].map { $0 <= instant } ?? true),
                  model.displays[chat.id]?.hasActiveWork != true else { return false }
            guard let brief = chat.brief else { return true }
            return chat.activityStamp > (brief.activity ?? 0) && now.timeIntervalSince(brief.at) >= minimumInterval
        }
        if let open = model.selectedID, let chat = model.chatRecord(open), wants(chat) { return open }
        var best: ChatRecord?
        for chat in model.chats where wants(chat) {
            if best.map({ chat.activityStamp > $0.activityStamp || (chat.activityStamp == $0.activityStamp && chat.id < $0.id) }) ?? true { best = chat }
        }
        return best?.id
    }

    /// What brief requests came to, each counted at the cost the gateway
    /// reported, or at `unreportedCost` for each attempt (or a request that
    /// has none yet) that reported none.
    nonisolated static func spend(_ totals: [GatewayTotals?]) -> Double {
        totals.reduce(0) { sum, totals in
            guard let totals else { return sum + unreportedCost }
            let reported = totals.costSamples > 0 ? max(0, totals.costUSD ?? 0) : 0
            let missing = max(totals.costSamples > 0 ? 0 : 1, totals.requests - totals.costSamples)
            return sum + reported + Double(missing) * unreportedCost
        }
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
    /// Launch: chats without a brief are filled in, a little after the sidebar is up.
    func startChatBriefs() {
        guard ChatBriefs.startsAutomatically else { return }
        chatBriefs.start()
    }
    /// A chat finished a run (`observeSessionCompletion`).
    func noteBriefRunFinished(_ id: String) {
        guard briefSettings.enabled else { return }
        chatBriefs.runFinished(id)
    }

    /// The chats that get a brief: the reader's own saved main chats in a
    /// project. Never a side, a sub-agent, imported history, a background
    /// request or connection test, or a chat not yet sent.
    func briefEligible(_ chat: ChatRecord) -> Bool {
        !chat.isUtilityChat && !chat.isSubagent && !chat.imported && chat.parentSessionID == nil
            && chat.workspaceID != WorkspaceRecord.scratchID && chat.path != nil && !pendingChatIDs.contains(chat.id)
    }
    /// The brief sidebar search and the row's hover show: none while briefs are off.
    func sidebarBrief(_ chat: ChatRecord) -> ChatBrief? {
        briefSettings.enabled && briefEligible(chat) ? chat.brief : nil
    }

    /// Writes or updates one chat's brief: the day's spend checked first,
    /// then the connection's mini model asked with the earlier brief and the
    /// chat's newest page, read on a reader of its own unless the chat is
    /// open. The brief lands on the chat's record only.
    func writeBrief(_ id: String, backfill: Bool) async -> ChatBriefOutcome {
        guard briefSettings.enabled, !isShutDown, !installPreparing, let store, let chat = chatRecord(id), briefEligible(chat),
              !(backfill && chat.isArchived), let path = chat.path else { return .skipped }
        // A chat whose connection is gone has no mini model to ask.
        guard let profile = profiles.first(where: { $0.id == chat.profileID }) else { return .noMiniModel }
        let spent = await briefSpend()
        guard !Task.isCancelled, briefSettings.enabled else { return .skipped }
        guard spent < briefSettings.dailyCapUSD else { return .capReached }
        _ = await listModels(for: profile)
        guard !Task.isCancelled, briefSettings.enabled, profiles.contains(profile) else { return .skipped }
        let descriptors = catalogEntry(for: profile).descriptors
        guard TitleGenerationPlan.miniModel(profile: profile, descriptors: descriptors) != nil else { return .noMiniModel }
        let activity = chatRecord(id)?.activityStamp ?? chat.activityStamp
        let page: HistoryPage
        do { page = displays[id] != nil ? try await history.read(path: path) : try await HistoryReader().read(path: path) }
        catch { return .unreadable(error.localizedDescription) }
        guard !Task.isCancelled, briefSettings.enabled else { return .skipped }
        guard page.notice == nil, let current = chatRecord(id),
              let plan = ChatBriefPlan(profile: profile, descriptors: descriptors, title: current.displayTitle, previous: current.brief,
                                       rows: page.messages, partialTurnInput: page.partialTurnInput) else { return .nothingNew }
        let request = MiniModelRequest(model: plan.model, contextWindow: plan.contextWindow, maxOutputTokens: plan.maxOutputTokens,
                                       modelOutputLimit: plan.modelOutputLimit, thinkingLevel: plan.thinkingLevel, prompt: plan.prompt,
                                       task: BackgroundRequestKind.brief.raw, title: "Chat brief", timeout: 60, name: "brief request")
        do {
            let messages = try await askMiniModel(request, profile: profile, sourceID: id) { messages in
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
            return .failed(error.localizedDescription)
        }
    }

    /// What brief requests sent in the last 24 hours came to, read from the
    /// request archive (`ChatBriefs.spend`).
    func briefSpend(now: Date = Date()) async -> Double {
        let since = now.addingTimeInterval(-ChatBriefs.capWindow)
        let recent = chats.filter { $0.backgroundTask == BackgroundRequestKind.brief.raw && ($0.backgroundTaskStartedAt ?? now) >= since }
        guard !recent.isEmpty else { return 0 }
        let scopes = recent.map { SessionUsageScope(sessionID: $0.id, workspaceID: $0.workspaceID) }
        var totals: [SessionUsageScope: GatewayTotals] = [:]
        for start in stride(from: 0, to: scopes.count, by: TopicSessionDrag.maximumSessions) {
            let batch = Array(scopes[start..<min(start + TopicSessionDrag.maximumSessions, scopes.count)])
            if let read = try? await traces.sessionReferenceTotals(scopes: batch) { totals.merge(read) { first, _ in first } }
        }
        return ChatBriefs.spend(scopes.map { totals[$0] })
    }
}
