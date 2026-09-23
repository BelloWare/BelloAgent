import Foundation

/// Displayed durations must have a representable nonnegative millisecond
/// count. Journal/wire numbers remain untouched; invalid observations are n/a.
enum DurationObservation {
    static func valid(_ milliseconds: Double?) -> Double? {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0,
              milliseconds < Double(Int.max) else { return nil }
        return milliseconds
    }
}

// The transcript's reading of a conversation: which tool calls happened and
// how they went, how replies group into blocks and turns, and how usage,
// durations and clocks are written out. Pure functions over the message
// projection, so every rule here is unit-tested without a view.

enum ActionKind: String, Sendable { case command, read, write, search, list, mcp, other }

struct ActionDescription: Equatable, Sendable {
    let kind: ActionKind
    let verb: String
    let object: String
    var path: String? = nil
}

/// Where a call stands, as the transcript reads it. `unknown` is a call that
/// began and never reported — stopped while it ran, or cut off by a crash —
/// so it may have had effects: it is not done, not failed and not skipped.
enum ActionOutcome: String, Sendable { case running, done, failed, cancelled, unknown }

enum ActivityState: String, Sendable { case running, failed, completed }

struct DiffRow: Equatable, Sendable {
    enum Kind: String, Sendable { case context, removed, added }
    let kind: Kind
    let text: String
}

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
    enum Missing: Equatable, Sendable { case running, failed, noUsage, notCaptured, expired }
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
    var running = 0, failed = 0, noUsage = 0, notCaptured = 0, expired = 0, unknown = 0
    /// False when an older snapshot could not say why its requests lack usage.
    var known = true
    var total: Int { running + failed + noUsage + notCaptured + expired + unknown }
    mutating func add(_ reason: TurnRequestLine.Missing?) {
        switch reason {
        case .running?: running += 1
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
        case .message(let id): return ["block:", "message:", "work:", "summary:"].contains(where: id.hasPrefix) ? "message:" + id : id
        case .block(let id): return "block:" + id
        }
    }
}

extension TranscriptMessage {
    var isStreaming: Bool { state == "streaming" }
    /// A reply with no prose: only tool calls, exposed reasoning, or both. It folds into the next reply's block.
    var isActivityOnly: Bool {
        role == "assistant" && !TranscriptActivity.hasVisibleText(text)
            && (!(tools ?? []).isEmpty || TranscriptActivity.hasVisibleText(thinking))
    }
}

enum TranscriptActivity {
    // MARK: Tool descriptions

    static func parseInput(_ input: String) -> [String: Any] { decodeArguments(input).values }

    private static let argumentCountLock = NSLock()
    nonisolated(unsafe) private static var argumentBytes = 0
    /// Bytes of call arguments decoded as JSON so far, as evidence that
    /// drawing a row does not read a growing document again.
    static var argumentBytesDecoded: Int {
        argumentCountLock.lock(); defer { argumentCountLock.unlock() }
        return argumentBytes
    }

    /// A call's arguments as JSON. The host bounds what it sends, which can cut
    /// the JSON in the middle of a string, so a fragment is closed up and read
    /// for whatever survived rather than thrown away: a card that shows part of
    /// a request is worth more than one that shows raw bytes, and `complete`
    /// says which of the two the reader is looking at.
    static func decodeArguments(_ input: String) -> (values: [String: Any], complete: Bool) {
        argumentCountLock.lock(); argumentBytes += input.utf8.count; argumentCountLock.unlock()
        let data = Data(input.utf8)
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return (object, true)
        }
        for candidate in repairedArguments(data) {
            if let object = (try? JSONSerialization.jsonObject(with: candidate)) as? [String: Any] {
                return (object, false)
            }
        }
        return ([:], false)
    }
    /// Ways a cut fragment might be closed, most complete first: close the
    /// string and the containers it was inside, or drop back to the last member
    /// that arrived whole when the cut landed in a key. JSON's structure is
    /// ASCII, so this reads bytes: walking a large fragment by grapheme was
    /// most of what reading it cost.
    private static func repairedArguments(_ input: Data) -> [Data] {
        var bytes = [UInt8](input)
        // A cut inside an escape leaves a backslash with nothing to escape.
        while bytes.last == JSONByte.backslash { bytes.removeLast() }
        guard bytes.first == JSONByte.openObject else { return [] }
        var stack: [UInt8] = [], inString = false, escaped = false
        var lastMemberEnd: Int? = nil
        for (index, byte) in bytes.enumerated() {
            if escaped { escaped = false; continue }
            if byte == JSONByte.backslash { if inString { escaped = true }; continue }
            if byte == JSONByte.quote { inString.toggle(); continue }
            if inString { continue }
            switch byte {
            case JSONByte.openObject, JSONByte.openArray: stack.append(byte)
            case JSONByte.closeObject, JSONByte.closeArray: if !stack.isEmpty { stack.removeLast() }
            case JSONByte.comma: if stack.count == 1 { lastMemberEnd = index }
            default: break
            }
        }
        var closed = bytes
        if inString { closed.append(JSONByte.quote) }
        for opener in stack.reversed() { closed.append(opener == JSONByte.openObject ? JSONByte.closeObject : JSONByte.closeArray) }
        var candidates = [Data(closed)]
        if let lastMemberEnd { candidates.append(Data(bytes[..<lastMemberEnd] + [JSONByte.closeObject])) }
        return candidates
    }
    private enum JSONByte {
        static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), comma = UInt8(ascii: ","), colon = UInt8(ascii: ":")
        static let openObject = UInt8(ascii: "{"), closeObject = UInt8(ascii: "}"), openArray = UInt8(ascii: "["), closeArray = UInt8(ascii: "]")
        static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
    }

    /// One top-level string member of a call's arguments — a file tool's
    /// `path` — read without decoding the rest of the document. A write's
    /// arguments carry the whole file after its path, and while they stream
    /// the row redraws on every delta: reading the path must cost the path,
    /// not the file. A document cut inside the value (as a stream or the
    /// host's bound leaves it) yields the part that arrived, as the repaired
    /// decode does; anything that is not a JSON object, or a member that is
    /// not a string, yields nothing.
    static func argumentString(_ key: String, in input: String) -> String? {
        let name = Array(key.utf8)
        if let found = input.utf8.withContiguousStorageIfAvailable({ member(name, in: $0) }) { return found }
        return Array(input.utf8).withUnsafeBufferPointer { member(name, in: $0) }
    }
    private static func member(_ name: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> String? {
        let count = bytes.count
        var index = 0
        func skipSpace() { while index < count, JSONByte.isSpace(bytes[index]) { index += 1 } }
        /// The index past a string token's closing quote, or nil when the
        /// document ends inside it.
        func stringEnd(from start: Int) -> Int? {
            var cursor = start + 1
            while cursor < count {
                switch bytes[cursor] {
                case JSONByte.backslash: cursor += 2
                case JSONByte.quote: return cursor + 1
                default: cursor += 1
                }
            }
            return nil
        }
        /// Skips one value; false when the document ends inside it.
        func skipValue() -> Bool {
            guard index < count else { return false }
            switch bytes[index] {
            case JSONByte.quote:
                guard let end = stringEnd(from: index) else { return false }
                index = end; return true
            case JSONByte.openObject, JSONByte.openArray:
                var depth = 0
                while index < count {
                    switch bytes[index] {
                    case JSONByte.quote:
                        guard let end = stringEnd(from: index) else { return false }
                        index = end; continue
                    case JSONByte.openObject, JSONByte.openArray: depth += 1
                    case JSONByte.closeObject, JSONByte.closeArray:
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default: break
                    }
                    index += 1
                }
                return false
            default:
                while index < count, bytes[index] != JSONByte.comma, bytes[index] != JSONByte.closeObject, !JSONByte.isSpace(bytes[index]) { index += 1 }
                return index < count
            }
        }
        func decoded(_ token: ArraySlice<UInt8>) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(token), options: .fragmentsAllowed)) as? String
        }
        skipSpace()
        guard index < count, bytes[index] == JSONByte.openObject else { return nil }
        index += 1
        while true {
            skipSpace()
            guard index < count, bytes[index] == JSONByte.quote, let keyEnd = stringEnd(from: index) else { return nil }
            let key = UnsafeBufferPointer(rebasing: bytes[(index + 1)..<(keyEnd - 1)])
            // A key written with escapes is compared as the key it decodes to.
            let matches = key.elementsEqual(name) || (key.contains(JSONByte.backslash) && decoded(ArraySlice(bytes[index..<keyEnd])).map { Array($0.utf8) == name } == true)
            index = keyEnd
            skipSpace()
            guard index < count, bytes[index] == JSONByte.colon else { return nil }
            index += 1
            skipSpace()
            guard index < count else { return nil }
            if matches {
                guard bytes[index] == JSONByte.quote else { return nil }
                if let end = stringEnd(from: index) { return decoded(ArraySlice(bytes[index..<end])) }
                // Cut inside the value: close what arrived, without a
                // backslash left with nothing to escape.
                var partial = Array(bytes[index..<count])
                var trailing = 0
                while partial.count - trailing > 1, partial[partial.count - 1 - trailing] == JSONByte.backslash { trailing += 1 }
                if trailing % 2 == 1 { partial.removeLast() }
                return decoded(ArraySlice(partial + [JSONByte.quote]))
            }
            guard skipValue() else { return nil }
            skipSpace()
            guard index < count, bytes[index] == JSONByte.comma else { return nil }
            index += 1
        }
    }
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
    }
    /// The first line, bounded. It reads up to the first newline and no
    /// further: a streaming part redraws its row on every delta, and splitting
    /// the whole text into lines to keep one of them grew with every delta.
    static func firstLine(_ text: String, max: Int = 96) -> String {
        let scalars = text.unicodeScalars
        let end = scalars.firstIndex(of: "\n") ?? scalars.endIndex
        let line = String(Substring(scalars[..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
    /// Whether a text holds anything but whitespace, without copying it: the
    /// answer is usually its first character.
    static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.unicodeScalars.contains { !blank.contains($0) }
    }
    private static let blank = CharacterSet.whitespacesAndNewlines
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
    static func outcome(of tool: ToolView) -> ActionOutcome {
        if ["running", "preparing", "prepared"].contains(tool.state) { return .running }
        if tool.state == "cancelled" { return .cancelled }
        if tool.state == "failed" { return .failed }
        // Sent only to an app that says it reads it (the hello's
        // `unknownToolOutcomes`); an older app sees "cancelled" or "failed".
        if tool.state == "unknown" { return .unknown }
        return .done
    }
    /// What a reply that ended before its natural end says under itself, from
    /// its stop reason. Only "length" is the output limit; the helper passes
    /// any other reason the provider gave (its content filter, say) through as
    /// the stop reason. Nil for a reply the reader stopped — it has its own
    /// chip — and for the reasons a reply ends on normally, which older
    /// journals record too.
    static func earlyEnd(_ stopReason: String?, toolArguments: Bool = false) -> String? {
        guard let reason = stopReason, !reason.isEmpty, !ordinaryEnds.contains(reason) else { return nil }
        let notice: String
        switch reason {
        case "length": notice = "Output limit reached"
        case "content_filter": notice = "Stopped by the provider's content filter"
        default: notice = "The provider ended this reply early (\(reason))"
        }
        return toolArguments ? notice + "; tool arguments may be incomplete." : notice
    }
    /// Stop reasons that are not an early end: the reader's stop, and the
    /// ends a Pi journal records for a reply that finished or failed.
    private static let ordinaryEnds: Set<String> = ["interrupted", "stop", "toolUse", "tool_use", "end_turn", "stop_sequence", "completed", "aborted", "error"]
    /// "Edited" once done, "Editing" under way, "Failed editing", "Skipped
    /// editing" or "Stopped editing" otherwise: the verb never claims work that
    /// did not happen.
    private static func conjugate(_ done: String, _ doing: String, _ outcome: ActionOutcome) -> String {
        switch outcome {
        case .running: return doing.prefix(1).uppercased() + doing.dropFirst()
        case .failed: return "Failed " + doing
        case .cancelled: return "Skipped " + doing
        case .unknown: return "Stopped " + doing
        case .done: return done
        }
    }
    /// One verb-and-object line per tool call, like "Ran npm test", "Editing retry.swift" or "Failed reading notes.md".
    static func describe(_ tool: ToolView) -> ActionDescription { describe(actionParts(tool), outcome: outcome(of: tool)) }
    static func describe(_ parts: ActionParts, outcome: ActionOutcome) -> ActionDescription {
        ActionDescription(kind: parts.kind, verb: conjugate(parts.done, parts.doing, outcome), object: parts.object, path: parts.path)
    }
    /// A call's line before its outcome is applied: the kind of work, the
    /// verb it reads with once finished and while under way, and what it
    /// names. Worked out once per drawing of a row, because the arguments it
    /// reads can be a whole file still streaming in.
    struct ActionParts: Equatable, Sendable {
        let kind: ActionKind
        let done: String
        let doing: String
        let object: String
        var path: String? = nil
    }
    static func actionParts(_ tool: ToolView) -> ActionParts {
        switch tool.name {
        case "read", "write", "edit", "ls":
            // Native file tools report their resolved path once they run.
            // Until then the path is the one member read out of arguments that
            // can carry a whole file or edit behind it — never the whole document.
            let path = text(tool.path) ?? text(argumentString("path", in: tool.input))
            let object = path.map(shortPath)
            switch tool.name {
            case "read": return ActionParts(kind: .read, done: "Read", doing: "reading", object: object ?? "file", path: path)
            case "write":
                let created = tool.added != nil && (tool.removed ?? 0) == 0
                return ActionParts(kind: .write, done: created ? "Created" : "Wrote", doing: "writing", object: object ?? "file", path: path)
            case "edit": return ActionParts(kind: .write, done: "Edited", doing: "editing", object: object ?? "file", path: path)
            default: return ActionParts(kind: .list, done: "Listed", doing: "listing", object: object ?? "directory", path: path)
            }
        case "bash":
            // A command can carry a whole heredoc; the row shows its first line.
            let command = firstLine(text(argumentString("command", in: tool.input)) ?? tool.input)
            return ActionParts(kind: .command, done: "Ran", doing: "running", object: command.isEmpty ? "command" : command)
        case "find", "grep":
            return ActionParts(kind: .search, done: "Searched", doing: "searching", object: text(argumentString("pattern", in: tool.input)) ?? "files")
        case "mcp":
            // The meta-tool's action says what happened: a server list, schema loads or one invocation.
            let input = parseInput(tool.input)
            let action = text(input["action"]) ?? "invoke", server = text(input["server"])
            if action == "list" { return ActionParts(kind: .mcp, done: "Listed", doing: "listing", object: server.map { "tools on \($0)" } ?? "MCP servers") }
            if action == "describe" {
                let count = (input["targets"] as? [Any])?.count ?? 0
                return ActionParts(kind: .mcp, done: "Loaded", doing: "loading", object: count > 0 ? "\(count) tool \(count == 1 ? "schema" : "schemas")" : "tool schemas")
            }
            return ActionParts(kind: .mcp, done: "Called", doing: "calling", object: "\(server ?? "server") · \(text(input["tool"]) ?? "call")")
        default: return ActionParts(kind: .other, done: "Used", doing: "using", object: tool.name)
        }
    }

    /// A file's identity for counting: its path, else the call itself, so nothing is merged by guesswork.
    private static func fileKey(_ description: ActionDescription, _ tool: ToolView) -> String { description.path ?? "\(description.object)#\(tool.id)" }
    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// The collapsed one-line summary of a run of tool calls: distinct files for
    /// edits, reads and listings, counts for the rest, then what failed or was
    /// skipped. Only completed calls count as work done; a running one waits.
    static func summarize(_ tools: [ToolView]) -> String {
        ToolCallSummary(tools: tools).label ?? ""
    }

    /// Distinct files that completed write or edit calls touched.
    static func changedFiles(_ tools: [ToolView]) -> Int {
        var files = Set<String>()
        for tool in tools where tool.state == "completed" {
            let description = describe(tool)
            if description.kind == .write { files.insert(fileKey(description, tool)) }
        }
        return files.count
    }
    static func state(of tools: [ToolView]) -> ActivityState {
        if tools.contains(where: { ["running", "preparing", "prepared"].contains($0.state) }) { return .running }
        if tools.contains(where: { ["failed", "cancelled", "unknown"].contains($0.state) }) { return .failed }
        return .completed
    }
    /// "Reasoned", "Read 1 file" or "Reasoned, read 1 file, ran 2 commands".
    static func summarizeWork(_ tools: [ToolView], reasoned: Bool) -> String? {
        ToolCallSummary(tools: tools).label(reasoned: reasoned)
    }

    static func blockReasoned(_ block: TranscriptBlock) -> Bool {
        block.replies.contains { hasVisibleText($0.thinking) }
    }

    // MARK: Formatting

    static func formatDuration(_ ms: Double) -> String {
        guard DurationObservation.valid(ms) != nil else { return "" }
        // A tenth that rounds up to the second is written as the second:
        // 990 ms is "1s", never "1.0s".
        if (ms / 100).rounded() < 10 { return String(format: "%.1fs", ms / 1000) }
        // Retained history can contain finite values outside Int's range.
        guard let seconds = Int(exactly: (ms / 1000).rounded()) else { return "" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes < 60 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
        let hours = minutes / 60, restMinutes = minutes % 60
        return restMinutes > 0 ? "\(hours)h \(restMinutes)m" : "\(hours)h"
    }
    /// "21:17:41" in local time, for hover stamps.
    static func formatClock(_ ms: Double) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ms / 1000))
        return [parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0].map { String(format: "%02d", $0) }.joined(separator: ":")
    }
    /// Digits grouped in threes, as en-US writes them: 1,234.
    static func grouped(_ value: Double) -> String {
        guard let whole = Int(exactly: value.rounded()) else { return "—" }
        let digits = String(whole.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (whole < 0 ? "-" : "") + out
    }
    /// Tokens as counted: exact with grouping under ten thousand, compact above.
    static func formatTokenCount(_ value: Double) -> String { value < 10_000 ? grouped(value) : formatCompactTokens(value) }
    static func formatCompactTokens(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        // Each unit ends where its rounding would reach the next one: 999,500
        // tokens is "1M", never "1000k".
        if value.rounded() < 1_000 { return grouped(value) }
        if value < 10_000 {
            var text = String(format: "%.1f", value / 1_000)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + "k"
        }
        if (value / 1_000).rounded() < 1_000 { return "\(Int((value / 1_000).rounded()))k" }
        var text = String(format: "%.2f", value / 1_000_000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "M"
    }
    static func formatTurnCost(_ value: Double) -> String {
        compactGatewayUSD(value)
    }
    /// The first sentence of exposed reasoning, bounded, for the reply line's teaser.
    static func reasoningTeaser(_ text: String, max: Int = 90) -> String? {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        var sentence = flat
        let characters = Array(flat)
        for (index, character) in characters.enumerated() where ".!?".contains(character) {
            if index + 1 == characters.count || characters[index + 1].isWhitespace { sentence = String(characters[0...index]); break }
        }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        guard sentence.count > max else { return sentence }
        return String(sentence.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Diffs

    /// A line diff for an edit's old and new text: a bounded longest-common-subsequence, else a plain replace.
    static func lineDiff(_ before: String, _ after: String, limit: Int = 300) -> [DiffRow] {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        if a.count > limit || b.count > limit { return a.map { DiffRow(kind: .removed, text: $0) } + b.map { DiffRow(kind: .added, text: $0) } }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var rows: [DiffRow] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { rows.append(DiffRow(kind: .context, text: a[i])); i += 1; j += 1 }
            else if lengths[i + 1][j] >= lengths[i][j + 1] { rows.append(DiffRow(kind: .removed, text: a[i])); i += 1 }
            else { rows.append(DiffRow(kind: .added, text: b[j])); j += 1 }
        }
        while i < a.count { rows.append(DiffRow(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { rows.append(DiffRow(kind: .added, text: b[j])); j += 1 }
        return rows
    }
    /// The tool's edit as old and new text, when it is a file edit or write.
    static func editTexts(_ tool: ToolView) -> (before: String, after: String)? {
        guard let request = editRequest(tool) else { return nil }
        return (request.before, request.after)
    }

    /// What a file tool asked for, ready to draw: the rows of the change, how
    /// many the card leaves out, whether the host's bound cut the request short
    /// and whether it is past the size this preview will diff. Worked out once
    /// per call and remembered, so re-rendering an open card never runs the
    /// line diff again and no `body` ever does that work.
    struct EditRequest: Equatable, Sendable {
        var before: String
        var after: String
        /// "edit" shows a diff; "write" shows the requested content.
        var mode: String
        var rows: [DiffRow]
        /// Rows past what the card draws.
        var hiddenRows: Int
        /// The whole request arrived; false when the host bounded it, whether
        /// by cutting the document or by cutting the values inside it.
        var complete: Bool
        /// Past the size this preview diffs; the card says so instead.
        var tooLarge: Bool
        var lines: Int
    }
    /// Bound diff computation, while keeping the full input available in the
    /// card. Ordinary diffs retain every row for the expand action.
    static let diffLineLimit = 4_000
    static let diffByteLimit = 256 << 10

    private final class CachedEdit: Sendable {
        let request: EditRequest?
        init(_ request: EditRequest?) { self.request = request }
    }
    nonisolated(unsafe) private static let editCache: NSCache<NSString, CachedEdit> = {
        let cache = NSCache<NSString, CachedEdit>(); cache.countLimit = 512; cache.totalCostLimit = 32 << 20; return cache
    }()
    /// How many times the line diff has actually run, as evidence that drawing
    /// an open card again does not repeat it.
    private static let editCountLock = NSLock()
    nonisolated(unsafe) private static var editComputations = 0
    static var editComputationCount: Int {
        editCountLock.lock(); defer { editCountLock.unlock() }
        return editComputations
    }

    static func editRequest(_ tool: ToolView) -> EditRequest? {
        guard tool.name == "edit" || tool.name == "write" else { return nil }
        let outcome = outcome(of: tool)
        let created = tool.added != nil && (tool.removed ?? 0) == 0
        let key = "\(tool.name)\u{0}\(outcome.rawValue)\u{0}\(created)\u{0}\(tool.inputTruncated == true)\u{0}\(tool.input)" as NSString
        if let cached = editCache.object(forKey: key) { return cached.request }
        let request = computeEditRequest(tool, outcome: outcome, created: created)
        editCache.setObject(CachedEdit(request), forKey: key, cost: tool.input.utf8.count + 256)
        return request
    }
    /// A value the host cut carries its marker at the end. The card shows that
    /// as its own line at the end of the hunk rather than glued to the last
    /// line of content.
    static func withoutMarker(_ text: String) -> (text: String, marker: String?) {
        guard let range = text.range(of: ToolInputDisplay.truncationMarker, options: .backwards) else { return (text, nil) }
        return (String(text[text.startIndex..<range.lowerBound]), String(text[range.lowerBound...]))
    }
    private static func computeEditRequest(_ tool: ToolView, outcome: ActionOutcome, created: Bool) -> EditRequest? {
        let decoded = decodeArguments(tool.input)
        let oldRaw = decoded.values["oldText"] as? String
        let newRaw = (decoded.values["newText"] ?? decoded.values["content"]) as? String
        guard oldRaw != nil || newRaw != nil else { return nil }
        let oldCut = oldRaw.map(withoutMarker), newCut = newRaw.map(withoutMarker)
        let old = oldCut?.text, new = newCut?.text
        let marker = newCut?.marker ?? oldCut?.marker
        let mode = tool.name == "write" ? "write" : "edit"
        let before = old ?? "", after = new ?? old ?? ""
        // A request whose second half never arrived is not a diff: show the
        // half that did, as itself, and let the card say what happened.
        let diffable = (decoded.complete && marker == nil) || (old != nil && new != nil)
        let complete = decoded.complete && marker == nil && tool.inputTruncated != true
        func lineCount(_ text: String) -> Int { text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
        let lines = max(lineCount(before), lineCount(after))
        guard before.utf8.count + after.utf8.count <= diffByteLimit, lines <= diffLineLimit else {
            return EditRequest(before: before, after: after, mode: mode, rows: [], hiddenRows: 0,
                               complete: complete, tooLarge: true, lines: lines)
        }
        editCountLock.lock(); editComputations += 1; editCountLock.unlock()
        var all: [DiffRow]
        if diffable, mode == "edit" || (created && outcome == .done) {
            all = lineDiff(before, after)
        } else {
            all = (new ?? before).components(separatedBy: "\n").map { DiffRow(kind: .context, text: $0) }
        }
        // Where the content stops, as its own line at the end of the hunk.
        if let marker { all.append(DiffRow(kind: .context, text: marker)) }
        return EditRequest(before: before, after: after, mode: mode, rows: all,
                           hiddenRows: 0, complete: complete,
                           tooLarge: false, lines: all.count)
    }

    /// The arguments of a call as the card shows them: the call's own JSON when
    /// it arrived whole, and what could be read of it when the host's bound cut
    /// it short, so a card never presents a fragment as the whole request.
    static func argumentsText(_ tool: ToolView) -> (text: String, complete: Bool) {
        let decoded = decodeArguments(tool.input)
        if decoded.complete { return (tool.input, tool.inputTruncated != true) }
        guard !decoded.values.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: decoded.values, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ("", false)
        }
        return (text, false)
    }
    static func parseCommand(_ input: String) -> String? { parseInput(input)["command"] as? String }

    // MARK: Accounting

    static func reported(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    /// Do not infer missing cache counters or subtract aggregates with different coverage.
    static func uncachedInput(_ a: GatewayTotals) -> Double? {
        if let samples = a.uncachedInputSamples {
            return samples > 0 ? reported(a.uncachedInputReportedTokens) : nil
        }
        guard let tokens = a.tokens, let input = reported(tokens.input), let read = reported(a.cacheReadTokens),
              tokens.inputSamples == a.requests, a.cacheReadSamples == a.requests, read <= input else { return nil }
        return input - read
    }
    /// Sums only what each request reported; partial coverage stays visible through the sample counts.
    static func aggregate(_ messages: [TranscriptMessage]) -> TurnAccounting {
        var sum = TurnAccounting()
        func add(_ field: WritableKeyPath<TurnAccounting, Double?>, _ samples: WritableKeyPath<TurnAccounting, Int>, _ value: Double?, _ count: Int) {
            guard count > 0, let value = reported(value) else { return }
            sum[keyPath: field] = (sum[keyPath: field] ?? 0) + value
            sum[keyPath: samples] += count
        }
        func addRoute(_ route: GatewayModelRoute) {
            if let index = sum.modelRoutes.firstIndex(where: { $0.requested == route.requested && $0.responded == route.responded }) {
                if route.latestWall > sum.modelRoutes[index].latestWall { sum.modelRoutes[index] = route }
            } else { sum.modelRoutes.append(route) }
        }
        func addFigures(_ line: TurnRequestLine) {
            if let input = line.input {
                add(\.input, \.inputSamples, input, 1)
                if let cached = line.cached, cached <= input {
                    let split = GatewayTokenSplit(total: input, part: cached, samples: 1)
                    sum.inputSplit = sum.inputSplit.map { $0.adding(split) } ?? split
                    add(\.cached, \.cachedSamples, cached, 1); add(\.uncached, \.uncachedSamples, input - cached, 1)
                }
            }
            if let output = line.output { add(\.output, \.outputSamples, output, 1) }
            if let input = line.input, let output = line.output { add(\.total, \.totalSamples, input + output, 1) }
        }
        var modelPosition = -1, filled = GatewayMissingUsage()
        for (position, message) in messages.enumerated() {
            if let line = recordLine(message) {
                sum.requests += 1
                sum.recordLines.append(line)
                addFigures(line)
                if !line.reportedUsage { sum.missing.add(line.missing) }
                if let name = line.model {
                    sum.model = name; sum.modelMessageID = message.id; modelPosition = position
                    if !sum.modelNames.contains(name) { sum.modelNames.append(name) }
                }
                if line.route.valid { addRoute(line.route) }
            } else if let record = message.reply, record.input != nil || record.output != nil,
                      let state = message.accounting?.replyLog.flatMap(ReplyLog.init(rawValue:)), [.running, .failed, .noUsage].contains(state) {
                // The log counts this reply's request, with no usage yet (its
                // final metadata still on the way): the record's figures stand
                // in for that one request, which is not counted again.
                addFigures(TurnRequestLine(reply: message))
                switch state { case .running: filled.running += 1; case .failed: filled.failed += 1; default: filled.noUsage += 1 }
            }
            guard let a = message.accounting else { continue }
            if let missing = a.missingUsage {
                sum.missing.running += missing.running; sum.missing.failed += missing.failed; sum.missing.noUsage += missing.noUsage
            } else if a.requests > 0 { sum.missing.known = false }
            sum.requests += a.requests
            if let split = GatewayTokenSplit.reported(a, input: true) { sum.inputSplit = sum.inputSplit.map { $0.adding(split) } ?? split }
            if let split = GatewayTokenSplit.reported(a, input: false) { sum.outputSplit = sum.outputSplit.map { $0.adding(split) } ?? split }
            add(\.input, \.inputSamples, a.tokens?.input, a.tokens?.inputSamples ?? 0)
            add(\.output, \.outputSamples, a.tokens?.output, a.tokens?.outputSamples ?? 0)
            add(\.reasoning, \.reasoningSamples, a.tokens?.reasoning, a.tokens?.reasoningSamples ?? 0)
            add(\.total, \.totalSamples, a.tokens?.total, a.tokens?.samples ?? 0)
            add(\.cached, \.cachedSamples, a.cacheReadTokens, a.cacheReadSamples)
            if let uncached = uncachedInput(a) { add(\.uncached, \.uncachedSamples, uncached, a.uncachedInputSamples ?? a.requests) }
            add(\.costUSD, \.costSamples, a.costUSD, a.costSamples)
            add(\.reasoningCostUSD, \.reasoningCostSamples, a.reasoningCostUSD, a.reasoningCostSamples ?? 0)
            add(\.cacheWrite, \.cacheWriteSamples, a.cacheWriteTokens, a.cacheWriteSamples)
            sum.cacheHits += a.cacheHits; sum.cacheMisses += a.cacheMisses
            sum.cacheUnreported += a.cacheUnreported; sum.cacheConflicts += a.cacheConflicts
            // Already summed per reply by the archive; adding the sums keeps
            // the turn's rate one division of totals, not an average of rates.
            sum.throughput.add(a.settledThroughput); sum.latency.add(a.settledLatency)
            if let name = a.models?.names.first, position >= modelPosition { sum.model = name; sum.modelMessageID = message.id; modelPosition = position }
            for name in a.models?.names ?? [] where !sum.modelNames.contains(name) { sum.modelNames.append(name) }
            for route in a.models?.routes ?? [] where route.valid { addRoute(route) }
        }
        sum.missing.running = max(0, sum.missing.running - filled.running)
        sum.missing.failed = max(0, sum.missing.failed - filled.failed)
        sum.missing.noUsage = max(0, sum.missing.noUsage - filled.noUsage)
        return sum
    }
    /// A reply the request log has no row for still made a request: its own
    /// record supplies the figures and the model, and says why the log has
    /// none. Nil for a reply the log counts, and for any other row.
    static func recordLine(_ message: TranscriptMessage) -> TurnRequestLine? {
        // Without a record there is no attempt to tell whether the log counts
        // this reply's request elsewhere, so it is left to the log.
        guard message.role == "assistant", message.kind == nil, message.isStreaming || message.reply != nil else { return nil }
        let own = message.accounting.map { $0.requests > 0 } ?? false
        if !message.isStreaming, let state = message.accounting?.replyLog.flatMap(ReplyLog.init(rawValue:)) {
            // The log answered for the record's request.
            guard [.absent, .expired, .elsewhere].contains(state) else { return nil }
        } else if own { return nil }   // An older snapshot, or a streaming row the log counts.
        return TurnRequestLine(reply: message)
    }
    /// The tokens of a summary, preferring the reported total, else input plus output.
    static func tokens(of a: TurnAccounting) -> Double? {
        if let total = a.total { return total }
        if a.input != nil || a.output != nil { return (a.input ?? 0) + (a.output ?? 0) }
        return nil
    }
    /// "in 1,200 · 300 cached · 900 uncached · out 200 · 50 reasoning · $0.0041", each figure with its coverage when partial.
    static func usageBreakdown(_ a: TurnAccounting) -> String {
        func coverage(_ samples: Int) -> String { samples < a.requests ? " (\(samples)/\(a.requests))" : "" }
        var parts: [String] = []
        if let input = a.input { parts.append("in \(formatTokenCount(input))" + coverage(a.inputSamples)) }
        if let cached = a.cached { parts.append("\(formatTokenCount(cached)) cached" + coverage(a.cachedSamples)) }
        if let uncached = a.uncached { parts.append("\(formatTokenCount(uncached)) uncached" + coverage(a.uncachedSamples)) }
        if let output = a.output { parts.append("out \(formatTokenCount(output))" + coverage(a.outputSamples)) }
        if let reasoning = a.reasoning { parts.append("\(formatTokenCount(reasoning)) reasoning" + coverage(a.reasoningSamples)) }
        if let cost = a.costUSD { parts.append(formatTurnCost(cost) + coverage(a.costSamples)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Per-request accounting line

    struct AccountingPresentation: Equatable, Sendable {
        var summary: String
        var detail: String
        var modelLabel: String?
        var usage: String
    }
    private static func formatCost(_ value: Double) -> String {
        if value == 0 { return "$0 USD" }
        if value < 1e-8 {
            // Three significant digits in exponent form, written as JavaScript does: 1.23e-9.
            let exponent = Int(floor(log10(value)))
            let mantissa = value / pow(10, Double(exponent))
            return String(format: "$%.2fe%d USD", mantissa, exponent)
        }
        // Round the shortest decimal form half-up to eight places, as the gateway's
        // figures were shown before: 0.000421875 reads $0.00042188, never …87.
        var decimal = Decimal(string: "\(value)") ?? Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 8, .plain)
        return "$" + NSDecimalNumber(decimal: rounded).stringValue + " USD"
    }
    private static func coverage(_ samples: Int, _ requests: Int) -> String { samples < requests ? " (\(samples)/\(requests))" : "" }
    /// The line shows only what the gateway reported; unreported figures are left out rather than named.
    static func accountingPresentation(_ a: GatewayTotals) -> AccountingPresentation {
        let t = a.tokens
        let input: String? = { guard let t, t.inputSamples > 0, let value = reported(t.input) else { return nil }; return "\(grouped(value)) in" + coverage(t.inputSamples, a.requests) }()
        let reasoning: String? = { guard let t, (t.reasoningSamples ?? 0) > 0, let value = reported(t.reasoning) else { return nil }; return "\(grouped(value)) reasoning" + coverage(t.reasoningSamples ?? 0, a.requests) }()
        let output: String? = { guard let t, t.outputSamples > 0, let value = reported(t.output) else { return nil }; return "\(grouped(value)) out" + coverage(t.outputSamples, a.requests) + (reasoning.map { " (\($0))" } ?? "") }()
        let total: String? = { guard let t, t.samples > 0, let value = reported(t.total) else { return nil }; return "\(grouped(value)) total" + coverage(t.samples, a.requests) }()
        let cached: String? = { guard a.cacheReadSamples > 0, let value = reported(a.cacheReadTokens) else { return nil }; return "\(grouped(value)) cached" + coverage(a.cacheReadSamples, a.requests) }()
        let cost: String? = { guard a.costSamples > 0, let value = reported(a.costUSD) else { return nil }; return formatCost(value) + coverage(a.costSamples, a.requests) }()
        let reasoningCost = (a.reasoningCostSamples ?? 0) > 0 && reported(a.reasoningCostUSD) != nil ? formatCost(a.reasoningCostUSD!) : "unavailable"
        let uncached = uncachedInput(a)
        let responseCache = [a.cacheHits > 0 ? "\(a.cacheHits) hit" : "", a.cacheMisses > 0 ? "\(a.cacheMisses) miss" : "",
                             a.cacheUnreported > 0 ? "\(a.cacheUnreported) unreported" : "", a.cacheConflicts > 0 ? "\(a.cacheConflicts) invalid/conflicting" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let models = a.models
        let modelLabel = models?.routes?.first(where: \.valid)?.label ?? models?.names.first
        let modelDetail: String? = models.map { models in
            [
                "Reported model\(models.nameCount == 1 ? "" : "s"): \(models.names.isEmpty ? "unavailable" : models.names.joined(separator: ", "))\(models.nameCount > models.names.count ? "; \(models.nameCount - models.names.count) more (see Details)" : "").",
                (models.routes ?? []).filter(\.valid).map(\.detail).joined(separator: ". "),
                "The response body supplies the displayed name when available; older captures may retain a verified gateway name. Click the model to see response-body and header reports.",
                "Resolved identity \(models.reportedRequests)/\(a.requests); unreported \(models.unreportedRequests), conflicting \(models.conflictingRequests), incomplete \(models.incompleteRequests). Displaying a body name does not change routing identity or accounting.",
            ].joined(separator: " ")
        }
        let usage = [input, cached, output, total, cost].compactMap { $0 }.joined(separator: " · ")
        let detail = [
            modelDetail,
            "Gateway-reported usage for \(a.requests) request\(a.requests == 1 ? "" : "s"). Each request appears once in the transcript. Details on the user message remain available.",
            "Input includes cached tokens. Uncached input: \(uncached.map { grouped($0) + coverage(a.uncachedInputSamples ?? a.requests, a.requests) } ?? "unavailable"). Output includes reasoning tokens; they are not added again.",
            "Reasoning: \(reasoning ?? "tokens unavailable") (\(t?.reasoningSamples ?? 0)/\(a.requests) requests reported). Reasoning cost: \(reasoningCost) (\(a.reasoningCostSamples ?? 0)/\(a.requests) reported), a per-request output-cost breakdown, never added to total cost. Its reporting coverage may differ.",
            "Input \(t?.inputSamples ?? 0)/\(a.requests), output \(t?.outputSamples ?? 0)/\(a.requests), total \(t?.samples ?? 0)/\(a.requests), cost \(a.costSamples)/\(a.requests) requests reported. Partial totals include only reported requests.",
            "Prompt-cache read \(a.cacheReadSamples > 0 && reported(a.cacheReadTokens) != nil ? grouped(a.cacheReadTokens!) : "unavailable") tokens (\(a.cacheReadSamples)/\(a.requests) reported); write \(a.cacheWriteSamples > 0 && reported(a.cacheWriteTokens) != nil ? grouped(a.cacheWriteTokens!) : "unavailable") tokens (\(a.cacheWriteSamples)/\(a.requests) reported).",
            "Response cache: \(responseCache.isEmpty ? "unreported" : responseCache). Response-cache hits are separate from prompt-cache tokens.",
        ].compactMap { $0 }.joined(separator: "\n")
        return AccountingPresentation(summary: [modelLabel, usage.isEmpty ? nil : usage].compactMap { $0 }.joined(separator: " · "), detail: detail, modelLabel: modelLabel, usage: usage)
    }
    /// Accept only the bounded native identity projection, never arbitrary evidence.
    static func validModelSummary(_ m: GatewayModelSummary, requests: Int) -> Bool {
        let displayRequests = m.displayRequests ?? m.reportedRequests
        let counts = [m.nameCount, m.reportedRequests, m.unreportedRequests, m.conflictingRequests, m.incompleteRequests]
        guard counts.allSatisfy({ $0 >= 0 && $0 <= requests }),
              m.reportedRequests + m.unreportedRequests + m.conflictingRequests + m.incompleteRequests == requests,
              m.names.count == min(8, m.nameCount), Set(m.names).count == m.names.count,
              m.names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }),
              displayRequests >= 0, displayRequests <= requests,
              (m.routes?.count ?? 0) <= min(8, requests), m.routes?.allSatisfy(\.valid) ?? true else { return false }
        return m.nameCount <= displayRequests && (displayRequests == 0) == (m.nameCount == 0)
    }

    // MARK: Blocks and turns

    static func patched(_ items: [TranscriptItem], from previous: [TranscriptMessage], to page: [TranscriptMessage]) -> [TranscriptItem]? {
        guard TaskTranscriptPlan.cosmetic(from: previous, to: page) else { return nil }
        let changed = zip(previous, page).filter { $0 != $1 }.map { $1 }
        guard changed.allSatisfy({ $0.role == "assistant" && $0.kind == nil }),
              zip(previous, page).allSatisfy({ $0.accounting == $1.accounting }) else { return nil }
        if changed.isEmpty { return items }
        let sources = Set(changed.map(\.id))
        var replacements: [String: TranscriptItem] = [:]
        for message in changed {
            // The unfolded planner: a patch replaces rows in place and must
            // not re-decide a turn's fold from one message out of context.
            for item in TaskTranscriptPlan.rows([message], lifecycle: nil) {
                guard replacements.updateValue(item, forKey: item.id) == nil else { return nil }
            }
        }
        var affected = Set<String>()
        for item in items {
            switch item {
            case .message(let message): if sources.contains(message.id) { affected.insert(item.id) }
            case .block(let block):
                let ownsSource = block.message.map { sources.contains($0.id) } == true ||
                    block.activity.contains { sources.contains($0.id) }
                if block.taskSummary?.requests.contains(where: { sources.contains($0.id) }) == true,
                   block.presentation != .work || block.task != nil { return nil }
                if block.turn?.requests.contains(where: { sources.contains($0.id) }) == true { return nil }
                if ownsSource { affected.insert(item.id) }
            }
        }
        // Membership changes, legacy grouping changes and terminal aggregates
        // take the complete planner. Ordinary part fragments touch local rows.
        guard affected == Set(replacements.keys) else { return nil }
        return items.map { replacements[$0.id] ?? $0 }
    }
    /// `complete` says whether the page reaches the conversation's newest
    /// row (see `TaskTranscriptPlan.items`).
    static func blocks(of messages: [TranscriptMessage], lifecycle: TaskPresentationProjection? = nil, complete: Bool = true) -> [TranscriptItem] {
        sayingFailuresOnce(TaskTranscriptPlan.items(messages, lifecycle: lifecycle, complete: complete), in: messages)
    }
    /// A failed turn's notice is the host's error message, and while that run
    /// is the chat's current failure its card at the foot of the page says
    /// the same words with Retry beside them. The turn's report then leaves
    /// them to the card. An older failed turn, whose card is gone, keeps them.
    static func sayingFailuresOnce(_ items: [TranscriptItem], in messages: [TranscriptMessage]) -> [TranscriptItem] {
        let failures = messages.filter { $0.kind == "failure" && $0.id.hasPrefix("failure:run:") }.map(\.text)
        guard !failures.isEmpty else { return items }
        return items.map { item in
            guard case .block(var block) = item, block.presentation == .summary, var turn = block.turn,
                  turn.outcome == "failed", let notice = turn.notice,
                  // The report's copy is the host's bounded preview of the same message.
                  failures.contains(where: { $0 == notice || $0.hasPrefix(notice) }) else { return item }
            turn.noticeOnFailureCard = true
            block.turn = turn
            return .block(block)
        }
    }

    // MARK: Read visibility

    static func latestCompletedAssistant(_ messages: [TranscriptMessage]) -> String? {
        messages.last { $0.role == "assistant" && !$0.isStreaming }?.id
    }
    /// Reaching the end of a long reply counts; merely seeing its first line does not.
    static func replyEndIsVisible(top: Double, bottom: Double, height: Double, viewportHeight: Double) -> Bool {
        [top, bottom, height, viewportHeight].allSatisfy(\.isFinite) && viewportHeight > 0 && height > 0 && top < viewportHeight && bottom > 0 && bottom <= viewportHeight + 1
    }
}
