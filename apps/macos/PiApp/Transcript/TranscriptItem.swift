import Foundation

/// Gateway-reported usage summed over a turn's (or a reply's) requests; a figure is nil when no request reported it.
struct TurnAccounting: Equatable, Sendable {
    var requests = 0
    var inputSplit: GatewayTokenSplit?
    var outputSplit: GatewayTokenSplit?
    var input: Double? = nil, inputSamples = 0
    var cached: Double? = nil, cachedSamples = 0
    var uncached: Double? = nil, uncachedSamples = 0
    var output: Double? = nil, outputSamples = 0
    var reasoning: Double? = nil, reasoningSamples = 0
    var total: Double? = nil, totalSamples = 0
    var costUSD: Double? = nil, costSamples = 0
    var reasoningCostUSD: Double? = nil, reasoningCostSamples = 0
    var cacheWrite: Double? = nil, cacheWriteSamples = 0
    var cacheHits = 0, cacheMisses = 0, cacheUnreported = 0, cacheConflicts = 0
    /// The last reported model name, and the request it came from, for the reply line's model link.
    var model: String? = nil, modelMessageID: String? = nil
    /// Distinct models across retained requests, so a routed turn is not
    /// mislabeled as if every request used only its last model.
    var modelNames: [String] = []
    var reportedModels: [String] { modelNames.isEmpty ? model.map { [$0] } ?? [] : modelNames }
    var modelRoutes: [GatewayModelRoute] = []
    var latestModelRoute: GatewayModelRoute? {
        modelRoutes.reduce(nil) { latest, route in
            guard let latest else { return route }
            return route.latestWall > latest.latestWall || (route.latestWall == latest.latestWall && latest.responded == nil && route.responded != nil) ? route : latest
        }
    }
    var requestedModels: [String] { Array(Set(modelRoutes.compactMap(\.requested))).sorted() }
    /// Output tokens after the first over first → last generated token,
    /// folded over this turn's requests; only the measured ones are in it.
    var throughput = SettledThroughput()
    /// First-token latency over the same requests, for the turn-time dialog.
    var latency = SettledLatency()
    /// Requests the log does not count here, from the replies' own records.
    /// Turn Info lists every request, and reads the log's for that one turn.
    var recordLines: [TurnRequestLine] = []
    /// Requests that reported neither input nor output, by why: the log's
    /// counts and the records'. Nil reasons when an older snapshot has none.
    var missing = TurnMissingUsage()
    /// Requests whose figures come from the replies' own records because the
    /// log, once read, had none for them.
    var recordRequests: Int { recordLines.filter { $0.reportedUsage && [.notCaptured, .expired].contains($0.logMissing) }.count }
    /// Distinct models that answered: the log's, then the records'.
    var answeredModels: [String] {
        var names: [String] = []
        for name in reportedModels + recordLines.compactMap(\.model) where !names.contains(name) { names.append(name) }
        return names
    }

    /// A parent and its subset from the same requests — input and its cached
    /// part, or output and its reasoning part: the paired split the gateway
    /// recorded, or, for a snapshot from before it did, the totals themselves
    /// when every request reported both. A share is only ever drawn from this.
    func split(input: Bool) -> GatewayTokenSplit? {
        if let pair = input ? inputSplit : outputSplit { return pair.valid ? pair : nil }
        let samples = input ? inputSamples : outputSamples, partSamples = input ? cachedSamples : reasoningSamples
        guard requests > 0, samples == requests, partSamples == requests,
              let total = input ? self.input : output, let part = input ? cached : reasoning else { return nil }
        let pair = GatewayTokenSplit(total: total, part: part, samples: requests)
        return pair.valid ? pair : nil
    }
}

/// One request of a turn, from the request log or, for a request the log has
/// no row for, from the reply's own record.
struct TurnRequestLine: Equatable, Sendable, Identifiable {
    enum Source: Equatable, Sendable { case log, record }
    /// Why a request has no usage.
    enum Missing: Equatable, Sendable { case running, stopped, failed, noUsage, notCaptured, expired }
    var id: String
    /// Seconds since 1970, when known.
    var wall: Double?
    var requested: String?
    var model: String?
    var routedVia: String? = nil
    var input: Double? = nil, cached: Double? = nil, output: Double? = nil, reasoning: Double? = nil, cost: Double? = nil
    var source: Source
    var missing: Missing? = nil
    /// Why the log has no row for a request whose figures came from its
    /// reply's record; nil while the log has not been read for the reply.
    var logMissing: Missing? = nil
    /// From the helper's in-memory log: the durable log has no row yet.
    var live = false
    var reportedUsage: Bool { input != nil || output != nil }
    var route: GatewayModelRoute { GatewayModelRoute(requested: requested, responded: model, latestWall: wall ?? 0) }

    /// A reply the log has no row for, as its own record describes it.
    init(reply message: TranscriptMessage) {
        let record = message.reply
        id = record?.attempt ?? message.id; wall = message.at.map { $0 / 1000 }
        requested = record?.requested; model = record?.model; routedVia = record?.routedVia
        input = record?.input; cached = record?.cached; output = record?.output
        source = .record
        switch message.accounting?.replyLog.flatMap(ReplyLog.init(rawValue:)) {
        case .absent?: logMissing = .notCaptured
        case .expired?: logMissing = .expired
        default: logMissing = message.isStreaming ? .running : nil
        }
        // A record without usage cannot say whether the gateway sent none or
        // the reply predates the record keeping it, so neither is claimed.
        if !reportedUsage { missing = message.isStreaming ? .running : message.stopReason == "interrupted" ? .failed : logMissing }
    }
}

/// A turn's requests without usage, by why.
struct TurnMissingUsage: Equatable, Sendable {
    var running = 0, stopped = 0, failed = 0, noUsage = 0, notCaptured = 0, expired = 0, unknown = 0
    /// False when an older snapshot could not say why its requests lack usage.
    var known = true
    var total: Int { running + stopped + failed + noUsage + notCaptured + expired + unknown }
    mutating func add(_ reason: TurnRequestLine.Missing?) {
        switch reason {
        case .running?: running += 1
        case .stopped?: stopped += 1
        case .failed?: failed += 1
        case .noUsage?: noUsage += 1
        case .notCaptured?: notCaptured += 1
        case .expired?: expired += 1
        case nil: unknown += 1
        }
    }
}

/// One model's share of a turn that several models answered.
struct TurnModelSubtotal: Equatable, Sendable, Identifiable {
    var model: String?
    var requests = 0
    var input: Double? = nil, inputSamples = 0
    var output: Double? = nil, outputSamples = 0
    var id: String { model ?? "" }
    mutating func add(_ line: TurnRequestLine) {
        requests += 1
        if let value = line.input { input = (input ?? 0) + value; inputSamples += 1 }
        if let value = line.output { output = (output ?? 0) + value; outputSamples += 1 }
    }
}

/// Everything the assistant did since the user's message, across every reply of the turn.
struct TurnSummary: Equatable, Sendable {
    var replies: Int
    var tools: Int
    var startedAt: Double?
    var endedAt: Double?
    var elapsedMs: Double?
    var modelMs: Double
    var toolMs: Double
    var live: Bool
    /// Distinct files that completed edits and writes touched.
    var files: Int
    /// True when the host's turn id shows the turn began before the loaded history.
    var partial: Bool
    var accounting: TurnAccounting
    /// The turn's replies that carry gateway accounting, in order, for the expanded per-request rows.
    var requests: [TranscriptMessage]
    /// While live: the tool call under way, if any.
    var current: ToolView?
    /// While live: a status the host attached to the turn, such as a retry in progress.
    var notice: String?
    /// The run's failure card at the foot of the chat says `notice` already,
    /// with Retry beside it, so the report does not say it a second time.
    /// Copy Turn Info still carries it.
    var noticeOnFailureCard = false
    var toolCountPartial = false
    var taskKey: String? = nil
    var taskRootID: String? = nil
    var phase: String? = nil
    var outcome: String? = nil
    /// A failed run's error code; `cost_limit` reads as a stop, not a failure.
    var errorCode: String? = nil
    /// Only a currently running task may compare this with this boot's uptime.
    /// startedAt/endedAt above remain optional Unix-ms calendar observations.
    var liveStartedUptimeMs: Double? = nil
    /// Terminal evidence wins while differently paced presentation updates
    /// settle. An older live flag can never keep a completed clock running.
    var terminal: Bool { outcome != nil || endedAt != nil || phase == "terminal" }
    var isRunning: Bool { live && !terminal }
}

/// One prose reply and the work that produced it: the reasoning-only and
/// tool-only replies before it, plus its own reasoning and tool calls. A
/// trailing block with no prose can hold a terminal task receipt. New ordered
/// responses use local part rows; legacy responses retain a local work group.
struct TranscriptBlock: Equatable, Sendable, Identifiable {
    enum Presentation: Equatable, Sendable { case reply, work, body, summary, timeline, response, turnFold }
    var id: String
    /// Stays the id of the block's first row for its whole life, so the view keeps the block mounted (and open) as its reply arrives.
    var key: String
    /// The host's turn id for the block's rows, when the rows carry one.
    var turnID: String?
    var message: TranscriptMessage?
    var activity: [TranscriptMessage]
    var tools: [ToolView]
    /// The block's own requests' usage: its activity replies plus its reply.
    var accounting: TurnAccounting
    var startedAt: Double?
    var endedAt: Double?
    var modelMs: Double
    var toolMs: Double
    var live: Bool
    /// Set on the last block of every turn: the whole turn's figures, live ones included.
    var turn: TurnSummary?
    var presentation: Presentation = .reply
    var task: TaskPresentationRecord? = nil
    var taskSummary: TurnSummary? = nil
    var part: ResponseTimeline.Segment? = nil
    /// The assistant response this row belongs to, for the rows that make up
    /// one chronological response: its header line, its prose, its reasoning
    /// and its tool cards. One response is one fold, whatever it is made of.
    var responseID: String? = nil
    /// What a response collapsed to one line reads as, computed once by the
    /// planner so a header row does not change while arguments stream.
    var responseSummary: ResponseLine? = nil
    /// The finished turn whose fold hides this row. The row keeps its place,
    /// its identity and everything the reader opened inside it; it simply
    /// draws nothing while its turn is folded.
    var foldGroup: String? = nil
    /// Set on the one row that is a turn's fold control, never on a row the
    /// fold hides: the control has to stay on screen to be opened again.
    var foldControl: String? = nil
    /// What that control's line says, and what it counted.
    var foldSummary: TurnFoldSpec? = nil
    var replies: [TranscriptMessage] { activity + (message.map { [$0] } ?? []) }
}

/// The one line a collapsed response reads as: what it did, how long it took
/// and what it cost. Figures only; the response's own rows hold its content.
struct ResponseLine: Equatable, Sendable {
    /// "Reasoned, ran 2 commands" or "Answered".
    var work: String
    /// The model request's duration, already formatted, when the host measured it.
    var duration: String?
    /// Tokens, cost and model, already formatted, when the gateway reported them.
    var figures: String?
    /// How many rows of content the fold hides, so a closed response says so.
    var parts: Int
    /// Whether the response has anything inside it to fold: a reasoning
    /// segment, a card, a status. A plain answer has only its words, so its
    /// header line stays quiet and offers the one-line fold alone.
    var foldable: Bool = false
}

enum TranscriptItem: Equatable, Sendable, Identifiable {
    case message(TranscriptMessage)
    case block(TranscriptBlock)
    var id: String {
        switch self {
        case .message(let message): return TranscriptRenderIdentity.message(message.id).key
        case .block(let block): return block.key
        }
    }
}

/// Disjoint display namespaces. Journal ids stay opaque even if they contain
/// old rendering prefixes. Escape the escape prefix too to keep this injective.
enum TranscriptRenderIdentity {
    case message(String), block(String)
    var key: String {
        switch self {
        case .message(let id): return Self.reserved.contains(where: id.hasPrefix) ? "message:" + id : id
        case .block(let id): return "block:" + id
        }
    }
    /// Read for every row's id, many times a token: one array, not one per read.
    private static let reserved = ["block:", "message:", "work:", "summary:"]
}

extension TranscriptMessage {
    var isStreaming: Bool { state == "streaming" }
    /// How a reply ended when it failed or was stopped, "error" or "aborted":
    /// the row's state when the app shows the failure itself, else its stop
    /// reason, which is where the helper's rows and the journal's both keep it.
    var failedEnd: String? {
        for value in [state, stopReason] { if let value, ["error", "aborted"].contains(value) { return value } }
        return nil
    }
    /// A reply still being written, or one that ended without finishing.
    var endedUnfinished: Bool {
        let unfinished: Set<String> = ["streaming", "error", "aborted", "failed", "cancelled", "interrupted"]
        return unfinished.contains(state ?? "") || unfinished.contains(stopReason ?? "")
    }
    /// A reply with no prose: only tool calls, exposed reasoning, or both. It folds into the next reply's block.
    var isActivityOnly: Bool {
        role == "assistant" && !TranscriptActivity.hasVisibleText(text)
            && (!(tools ?? []).isEmpty || TranscriptActivity.hasVisibleText(thinking))
    }
}
