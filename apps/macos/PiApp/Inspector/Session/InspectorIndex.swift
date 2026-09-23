import Foundation

/// Where the Session Inspector is asked to open.
enum InspectorFocus: Hashable, Sendable {
    case overview
    case nextRequest
    /// The session's most recent request.
    case latestRequest
    /// A turn, by the id of the message that started it.
    case turn(String)
    /// A request, by its attempt id.
    case request(String)
    /// A transcript message: the request that produced it, else its turn.
    case message(String)
}

/// The page the navigator has open, once a focus is resolved against the index.
enum InspectorPage: Hashable, Sendable {
    case overview
    case nextRequest
    case turn(String)
    case request(String)
}

/// What the transcript knows about a message the reader asked about.
struct InspectorMessageHint: Sendable, Equatable {
    var id: String
    var role: String
    /// The request the helper recorded for an assistant row.
    var attempt: String?
    /// The turn (user message id) the row belongs to.
    var turn: String?
}

/// One request as the navigator reads it: the request log's typed columns,
/// never its metadata blob; the helper's live record while the log has none;
/// or, for a request the log never had, the reply's own record.
struct InspectorRequestRow: Sendable, Equatable, Identifiable {
    enum Source: String, Sendable { case log, live, record }
    var id: String
    /// Dispatch time, seconds since 1970.
    var wall: Double
    var turn: String?
    var purpose: String
    var api: String
    /// The alias the request asked for.
    var alias: String?
    /// The model the response reported.
    var model: String?
    var outcome: String
    var metricsRetained = true
    var dispatched = true
    var input: Double? = nil
    var cached: Double? = nil
    var cacheWrite: Double? = nil
    var output: Double? = nil
    var reasoning: Double? = nil
    var cost: Double? = nil
    var ttft: Double? = nil
    var decode: Double? = nil
    var duration: Double? = nil
    var http: Double? = nil
    var source: Source = .log
    /// Why the log has no row for a request known from its reply's record.
    var logMissing: TurnRequestLine.Missing? = nil
    /// Another model name the gateway reported for this request, when its
    /// reports disagree with the one that answered.
    var routedVia: String? = nil
    /// The figures came from the reply's own record: the log's row has none.
    var recordFigures = false

    var running: Bool { ["running", "streaming"].contains(outcome) }
    var failed: Bool { ["failed", "interrupted", "cancelled", "error"].contains(outcome) }
    var route: GatewayModelRoute { GatewayModelRoute(requested: alias, responded: model, latestWall: wall) }
    /// `18K → 1.1K`, when both halves were reported.
    var tokenFlow: String? {
        guard let input, let output else { return nil }
        return MetricFormat.tokens(input) + " → " + MetricFormat.tokens(output)
    }
    var cachedShare: Double? {
        guard let input, let cached, input > 0, cached <= input else { return nil }
        return cached / input
    }
    var settledRate: Double? { sample.settledTokensPerSecond }
    var sample: SessionTimingSample {
        SessionTimingSample(id: id, wall: Date(timeIntervalSince1970: wall), ttftMilliseconds: ttft, streamingMilliseconds: decode,
                            outputTokens: output, costUSD: cost, requestMilliseconds: duration, outcome: outcome, api: api,
                            model: model ?? alias, inputTokens: input, cacheReadTokens: cached, cacheWriteTokens: cacheWrite,
                            reasoningTokens: reasoning, turn: turn, purpose: purpose)
    }

    /// What the navigator selects from the log: typed columns only.
    static let columns = "id,wall,turn,purpose,api,alias,model,response_model,reported_models,outcome,metrics_retained,dispatch,ttft_ms,stream_ms,request_ms,http_ms,input_tokens,cache_read_tokens,cache_write_tokens,output_tokens,reasoning_tokens,cost_usd"

    static func archived(_ row: [String: CaptureSQLValue]) throws -> InspectorRequestRow {
        guard let id = row["id"]?.string, !id.isEmpty, let wall = row["wall"]?.double, wall.isFinite, wall >= 0 else { throw CaptureFailure.corrupt }
        func figure(_ key: String) -> Double? { row[key]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let turn = row["turn"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let model = GatewayModelIdentity.modelName(row["response_model"]?.string) ?? GatewayModelIdentity.modelName(row["model"]?.string)
        let reported = (row["reported_models"]?.string).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        var result = InspectorRequestRow(
            id: id, wall: wall, turn: turn, purpose: row["purpose"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "turn",
            api: row["api"]?.string ?? "", alias: GatewayModelIdentity.modelName(row["alias"]?.string),
            model: model,
            outcome: row["outcome"]?.string ?? "unknown",
            metricsRetained: (row["metrics_retained"]?.number ?? 1) == 1,
            dispatched: row["dispatch"]?.double != nil,
            input: figure("input_tokens"), cached: figure("cache_read_tokens"), cacheWrite: figure("cache_write_tokens"),
            output: figure("output_tokens"), reasoning: figure("reasoning_tokens"), cost: figure("cost_usd"),
            ttft: figure("ttft_ms"), decode: figure("stream_ms"), duration: figure("request_ms"), http: figure("http_ms"))
        result.routedVia = GatewayModelIdentity.routedVia(reported.compactMap(GatewayModelIdentity.modelName), answered: model)
        return result
    }

    /// The helper's own record of a request, from `debug.list`.
    static func live(_ metadata: [String: WireValue]) -> InspectorRequestRow? {
        guard let id = metadata["attemptId"]?.string, !id.isEmpty else { return nil }
        let gateway = GatewayObservation(metadata: metadata), identity = GatewayModelIdentity(metadata: metadata)
        let metrics = metadata["metrics"]?.object ?? [:]
        let timings = metadata["timings"]?.object ?? [:]
        func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let dispatch = valid(timings["dispatch"]?.number)
        let complete = valid(timings["modelComplete"]?.number)
        let wall = valid(metadata["dispatchWallTimestamp"]?.number) ?? valid(metadata["wallTimestamp"]?.number) ?? 0
        var result = InspectorRequestRow(
            id: id, wall: wall, turn: metadata["turnId"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            purpose: metadata["purpose"]?.string ?? "turn", api: metadata["api"]?.string ?? "",
            alias: GatewayModelIdentity.modelName(metadata["requestedModel"]?.string), model: identity.displayName,
            outcome: metadata["outcome"]?.string ?? "running",
            dispatched: dispatch != nil || metadata["dispatchWallTimestamp"]?.number != nil,
            input: gateway.inputTokens, cached: gateway.cacheReadTokens, cacheWrite: gateway.cacheWriteTokens,
            output: gateway.outputTokens, reasoning: gateway.reasoningTokens, cost: gateway.costUSD,
            ttft: valid(metrics["observedTTFTms"]?.number), decode: valid(metrics["streamDurationMs"]?.number),
            duration: dispatch.flatMap { start in complete.flatMap { $0 >= start ? $0 - start : nil } },
            http: valid(metrics["httpDurationMs"]?.number), source: .live)
        result.routedVia = GatewayModelIdentity.routedVia(PayloadArchive.reportedModels(metadata).compactMap(GatewayModelIdentity.modelName), answered: identity.displayName)
        return result
    }

    /// A request the log has no row for, as its reply recorded it.
    static func record(_ line: TurnRequestLine, turn: String) -> InspectorRequestRow {
        let outcome: String
        switch line.missing {
        case .running?: outcome = "running"
        case .failed?: outcome = "failed"
        default: outcome = "completed"
        }
        return InspectorRequestRow(id: line.id, wall: line.wall ?? 0, turn: turn, purpose: "turn", api: "",
                                   alias: line.requested, model: line.model, outcome: outcome, dispatched: false,
                                   input: line.input, cached: line.cached, output: line.output, reasoning: line.reasoning,
                                   cost: line.cost, source: .record, logMissing: line.logMissing, routedVia: line.routedVia, recordFigures: true)
    }
}

/// A turn: the user's message and every request it led to. Requests that
/// belong to no turn gather in one group after the turns.
struct InspectorTurn: Sendable, Equatable, Identifiable {
    static let otherID = "aux"
    var id: String
    /// 1 for the session's first turn; 0 for the group of other requests.
    var number: Int
    var requests: [InspectorRequestRow]
    var isOther: Bool { id == Self.otherID }
    var started: Double? { requests.first { $0.wall > 0 }?.wall }
    var running: Bool { requests.contains(where: \.running) }
    var cost: Double? {
        let reported = requests.compactMap(\.cost)
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }
    var costSamples: Int { requests.filter { $0.cost != nil }.count }
    /// `3 requests · $0.0213`
    var summary: String {
        var parts = ["\(requests.count) request" + (requests.count == 1 ? "" : "s")]
        if let cost { parts.append(compactGatewayUSD(cost)) }
        return parts.joined(separator: " · ")
    }
}

/// The session's requests, grouped into turns in the order they ran.
struct InspectorIndex: Sendable, Equatable {
    private(set) var turns: [InspectorTurn] = []
    /// Every request in navigation order: turn by turn, then the others.
    private(set) var requests: [InspectorRequestRow] = []
    /// Retained requests older than the ones read.
    var olderRequests = 0
    /// Where each request sits: its turn's index in `turns` and its own in that turn.
    private var positions: [String: Location] = [:]
    private var turnIndex: [String: Int] = [:]
    private struct Location: Sendable, Equatable { var turn: Int; var request: Int; var order: Int }
    var isEmpty: Bool { requests.isEmpty }

    init() {}
    init(archived: [InspectorRequestRow], live: [InspectorRequestRow] = [], records: [String: [TurnRequestLine]] = [:], olderRequests: Int = 0) {
        self.olderRequests = olderRequests
        var rows = Self.merge(durable: archived, live: live)
        var listed = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for (turn, lines) in records {
            for line in lines where line.source == .record {
                if let at = listed[line.id] {
                    // A log row with no usage takes the figures its reply recorded.
                    guard rows[at].input == nil, rows[at].output == nil, line.reportedUsage else { continue }
                    rows[at].input = line.input; rows[at].cached = line.cached; rows[at].output = line.output
                    rows[at].reasoning = rows[at].reasoning ?? line.reasoning; rows[at].model = rows[at].model ?? line.model
                    rows[at].routedVia = rows[at].routedVia ?? line.routedVia
                    rows[at].recordFigures = true; rows[at].logMissing = rows[at].metricsRetained ? line.logMissing : .expired
                } else {
                    rows.append(InspectorRequestRow.record(line, turn: turn)); listed[line.id] = rows.count - 1
                }
            }
        }
        rows.sort { ($0.wall, $0.id) < ($1.wall, $1.id) }
        var grouped: [String: [InspectorRequestRow]] = [:], order: [String] = []
        var others: [InspectorRequestRow] = []
        for row in rows {
            guard let turn = row.turn else { others.append(row); continue }
            if grouped[turn] == nil { order.append(turn) }
            grouped[turn, default: []].append(row)
        }
        var turns = order.enumerated().map { InspectorTurn(id: $0.element, number: $0.offset + 1, requests: grouped[$0.element] ?? []) }
        if !others.isEmpty { turns.append(InspectorTurn(id: InspectorTurn.otherID, number: 0, requests: others)) }
        self.turns = turns
        var sequence: [InspectorRequestRow] = []
        for (turnOffset, turn) in turns.enumerated() {
            turnIndex[turn.id] = turnOffset
            for (requestOffset, row) in turn.requests.enumerated() {
                positions[row.id] = Location(turn: turnOffset, request: requestOffset, order: sequence.count)
                sequence.append(row)
            }
        }
        requests = sequence
    }

    /// The log's rows, with the helper's fresher record of any request still
    /// running and the requests only the helper has seen so far.
    static func merge(durable: [InspectorRequestRow], live: [InspectorRequestRow]) -> [InspectorRequestRow] {
        var rows = Dictionary(durable.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for row in live where !row.id.isEmpty {
            if let saved = rows[row.id] {
                // The log carries the finished record; while a request runs the
                // helper's record can be ahead of it.
                if saved.running && (row.running || row.outcome != saved.outcome) { rows[row.id] = row }
            } else { rows[row.id] = row }
        }
        return rows.values.sorted { ($0.wall, $0.id) < ($1.wall, $1.id) }
    }

    func request(_ id: String) -> InspectorRequestRow? { positions[id].map { turns[$0.turn].requests[$0.request] } }
    func turn(_ id: String) -> InspectorTurn? { turnIndex[id].map { turns[$0] } }
    func turn(containing requestID: String) -> InspectorTurn? { positions[requestID].map { turns[$0.turn] } }
    /// `(2, 3)` for the second of a turn's three requests.
    func position(of requestID: String) -> (index: Int, count: Int)? {
        positions[requestID].map { ($0.request + 1, turns[$0.turn].requests.count) }
    }
    /// The request `step` places away in navigation order.
    func adjacent(to requestID: String, step: Int) -> String? {
        guard let location = positions[requestID] else { return nil }
        let target = location.order + step
        return requests.indices.contains(target) ? requests[target].id : nil
    }
    var latestRequestID: String? {
        requests.filter { $0.source != .record }.max { ($0.wall, $0.id) < ($1.wall, $1.id) }?.id
    }
    /// What a request's input is compared with: the turn's previous request,
    /// else the previous turn's last one. A compaction or title request is
    /// compared with the previous request of its own kind.
    func predecessor(of requestID: String) -> InspectorRequestRow? {
        guard let location = positions[requestID] else { return nil }
        let row = turns[location.turn].requests[location.request]
        let conversation = row.purpose == "turn"
        let earlier = requests[..<location.order].reversed().filter { $0.source != .record && $0.api == row.api }
        if conversation { return earlier.first { $0.purpose == "turn" } }
        return earlier.first { $0.purpose == row.purpose }
    }
    /// "first request", "tool round", "retry", "compaction"…
    func kind(of requestID: String) -> String {
        guard let location = positions[requestID] else { return "request" }
        let turn = turns[location.turn], row = turn.requests[location.request]
        switch row.purpose {
        case "turn": break
        case "connection-test": return "connection test"
        default: return row.purpose
        }
        let before = turn.requests[..<location.request].filter { $0.purpose == "turn" }
        guard let previous = before.last else { return turn.isOther ? "request" : "first request" }
        return previous.failed ? "retry" : "tool round"
    }
    /// The page a focus opens, or nil while the index cannot say yet.
    func resolve(_ focus: InspectorFocus, message: InspectorMessageHint? = nil) -> InspectorPage? {
        switch focus {
        case .overview: return .overview
        case .nextRequest: return .nextRequest
        case .latestRequest: return latestRequestID.map(InspectorPage.request) ?? .overview
        case .turn(let id): return turnIndex[id] != nil ? .turn(id) : nil
        case .request(let id): return positions[id] != nil ? .request(id) : nil
        case .message(let id):
            guard let message, message.id == id else { return nil }
            if let attempt = message.attempt, positions[attempt] != nil { return .request(attempt) }
            if message.role == "user", turnIndex[id] != nil { return .turn(id) }
            if let turn = message.turn, turnIndex[turn] != nil { return .turn(turn) }
            return nil
        }
    }
    /// The requests the Overview's charts draw, oldest first.
    var history: SessionStatsHistory {
        let drawn = requests.filter { $0.source != .record && $0.metricsRetained && $0.dispatched }
            .sorted { ($0.wall, $0.id) < ($1.wall, $1.id) }
        return SessionStatsHistory(requests: drawn.map(\.sample), olderRequests: olderRequests)
    }
}

extension InspectorTurn {
    /// The turn's usage summed from its requests, the way the transcript sums
    /// a turn: a figure only from the requests that reported it, and a split
    /// only from the requests that reported both of its halves.
    var accounting: TurnAccounting {
        var a = TurnAccounting()
        a.requests = requests.count
        func sum(_ values: [Double?]) -> (Double?, Int) {
            let reported = values.compactMap { $0 }
            return (reported.isEmpty ? nil : reported.reduce(0, +), reported.count)
        }
        (a.input, a.inputSamples) = sum(requests.map(\.input))
        (a.cached, a.cachedSamples) = sum(requests.map(\.cached))
        (a.output, a.outputSamples) = sum(requests.map(\.output))
        (a.reasoning, a.reasoningSamples) = sum(requests.map(\.reasoning))
        (a.cacheWrite, a.cacheWriteSamples) = sum(requests.map(\.cacheWrite))
        (a.costUSD, a.costSamples) = sum(requests.map(\.cost))
        let both = requests.filter { $0.input != nil && $0.output != nil }
        if !both.isEmpty { a.total = both.reduce(0) { $0 + ($1.input ?? 0) + ($1.output ?? 0) }; a.totalSamples = both.count }
        let inputs = requests.filter { $0.input != nil && $0.cached != nil }
        if !inputs.isEmpty {
            a.inputSplit = GatewayTokenSplit(total: inputs.reduce(0) { $0 + ($1.input ?? 0) }, part: inputs.reduce(0) { $0 + ($1.cached ?? 0) }, samples: inputs.count)
        }
        let outputs = requests.filter { $0.output != nil && $0.reasoning != nil }
        if !outputs.isEmpty {
            a.outputSplit = GatewayTokenSplit(total: outputs.reduce(0) { $0 + ($1.output ?? 0) }, part: outputs.reduce(0) { $0 + ($1.reasoning ?? 0) }, samples: outputs.count)
        }
        a.model = requests.last { $0.model != nil }?.model
        var routes: [GatewayModelRoute] = []
        for row in requests where row.alias != nil || row.model != nil {
            if let index = routes.firstIndex(where: { $0.requested == row.alias && $0.responded == row.model }) {
                routes[index].latestWall = max(routes[index].latestWall, row.wall)
            } else { routes.append(row.route) }
        }
        a.modelRoutes = routes
        a.modelNames = Array(Set(requests.compactMap(\.model))).sorted()
        return a
    }

    /// From the first request's dispatch to the end of the last one, seconds.
    var span: Double? {
        guard let start = requests.first(where: { $0.wall > 0 })?.wall, let last = requests.last(where: { $0.wall > 0 }) else { return nil }
        let end = last.wall + (last.duration ?? last.http ?? 0) / 1_000
        return end >= start ? (end - start) * 1_000 : nil
    }
}

extension TurnRequestLine {
    /// A request of the Inspector's index as the turn table writes it.
    init(row: InspectorRequestRow) {
        id = row.id; wall = row.wall > 0 ? row.wall : nil
        requested = row.alias; model = row.model; routedVia = row.routedVia
        input = row.input; cached = row.cached; output = row.output; reasoning = row.reasoning; cost = row.cost
        source = row.source == .record || row.recordFigures ? .record : .log
        live = row.source == .live
        logMissing = row.recordFigures || row.source == .record ? row.logMissing : nil
        if !reportedUsage {
            missing = !row.metricsRetained ? .expired : row.running ? .running
                : ["completed", "truncated"].contains(row.outcome) ? (row.source == .record ? row.logMissing : .noUsage) : .failed
        }
    }
}
