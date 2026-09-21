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

/// Where a call stands, as the transcript reads it.
enum ActionOutcome: String, Sendable { case running, done, failed, cancelled }

enum ActivityState: String, Sendable { case running, failed, completed }

struct DiffRow: Equatable, Sendable {
    enum Kind: String, Sendable { case context, removed, added }
    let kind: Kind
    let text: String
}

/// Gateway-reported usage summed over a turn's (or a reply's) requests; a figure is nil when no request reported it.
struct TurnAccounting: Equatable, Sendable {
    var requests = 0
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
    var toolCountPartial = false
    var taskKey: String? = nil
    var phase: String? = nil
    var outcome: String? = nil
    /// Only a currently running task may compare this with this boot's uptime.
    /// startedAt/endedAt above remain optional Unix-ms calendar observations.
    var liveStartedUptimeMs: Double? = nil
}

/// One prose reply and the work that produced it: the reasoning-only and
/// tool-only replies before it, plus its own reasoning and tool calls. A
/// trailing block with no prose holds work the turn ended on. Tool-result
/// rows disappear; their output lives on the call.
struct TranscriptBlock: Equatable, Sendable, Identifiable {
    enum Presentation: Equatable, Sendable { case reply, work, body, summary }
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
    var replies: [TranscriptMessage] { activity + (message.map { [$0] } ?? []) }
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
        role == "assistant" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!(tools ?? []).isEmpty || !(thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

enum TranscriptActivity {
    // MARK: Tool descriptions

    static func parseInput(_ input: String) -> [String: Any] { decodeArguments(input).values }

    /// A call's arguments as JSON. The host bounds what it sends, which can cut
    /// the JSON in the middle of a string, so a fragment is closed up and read
    /// for whatever survived rather than thrown away: a card that shows part of
    /// a request is worth more than one that shows raw bytes, and `complete`
    /// says which of the two the reader is looking at.
    static func decodeArguments(_ input: String) -> (values: [String: Any], complete: Bool) {
        if let data = input.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return (object, true)
        }
        for candidate in repairedArguments(input) {
            if let data = candidate.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return (object, false)
            }
        }
        return ([:], false)
    }
    /// Ways a cut fragment might be closed, most complete first: close the
    /// string and the containers it was inside, or drop back to the last member
    /// that arrived whole when the cut landed in a key.
    private static func repairedArguments(_ input: String) -> [String] {
        var text = input
        // A cut inside an escape leaves a backslash with nothing to escape.
        while text.hasSuffix("\\") { text.removeLast() }
        guard text.first == "{" else { return [] }
        var stack: [Character] = [], inString = false, escaped = false
        var lastMemberEnd: String.Index? = nil
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if character == "\\" { if inString { escaped = true }; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }
            switch character {
            case "{", "[": stack.append(character)
            case "}", "]": if !stack.isEmpty { stack.removeLast() }
            case ",": if stack.count == 1 { lastMemberEnd = index }
            default: break
            }
        }
        var closed = text
        if inString { closed.append("\"") }
        for opener in stack.reversed() { closed.append(opener == "{" ? "}" : "]") }
        var candidates = [closed]
        if let lastMemberEnd { candidates.append(String(text[text.startIndex..<lastMemberEnd]) + "}") }
        return candidates
    }
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
    }
    static func firstLine(_ text: String, max: Int = 96) -> String {
        let line = (text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
    static func outcome(of tool: ToolView) -> ActionOutcome {
        if ["running", "preparing", "prepared"].contains(tool.state) { return .running }
        if tool.state == "cancelled" { return .cancelled }
        if tool.state == "failed" { return .failed }
        return .done
    }
    /// "Edited" once done, "Editing" under way, "Failed editing" or "Skipped editing" otherwise: the verb never claims work that did not happen.
    private static func conjugate(_ done: String, _ doing: String, _ outcome: ActionOutcome) -> String {
        switch outcome {
        case .running: return doing.prefix(1).uppercased() + doing.dropFirst()
        case .failed: return "Failed " + doing
        case .cancelled: return "Skipped " + doing
        case .done: return done
        }
    }
    /// One verb-and-object line per tool call, like "Ran npm test", "Editing retry.swift" or "Failed reading notes.md".
    static func describe(_ tool: ToolView) -> ActionDescription {
        // Native file tools already report their resolved path. Their input can
        // contain a whole file or edit, and is irrelevant to a collapsed label.
        // Only decode it if a legacy row needs a path, or the tool needs arguments.
        let reportedPath = text(tool.path)
        let isFileTool = ["read", "write", "edit", "ls"].contains(tool.name)
        let input = isFileTool && reportedPath != nil ? [:] : parseInput(tool.input)
        let path = reportedPath ?? text(input["path"])
        let outcome = outcome(of: tool)
        func verb(_ done: String, _ doing: String) -> String { conjugate(done, doing, outcome) }
        switch tool.name {
        case "bash":
            let command = firstLine(text(input["command"]) ?? tool.input)
            return ActionDescription(kind: .command, verb: verb("Ran", "running"), object: command.isEmpty ? "command" : command)
        case "read": return ActionDescription(kind: .read, verb: verb("Read", "reading"), object: path.map(shortPath) ?? "file", path: path)
        case "write":
            let created = tool.added != nil && (tool.removed ?? 0) == 0
            return ActionDescription(kind: .write, verb: verb(created ? "Created" : "Wrote", "writing"), object: path.map(shortPath) ?? "file", path: path)
        case "edit": return ActionDescription(kind: .write, verb: verb("Edited", "editing"), object: path.map(shortPath) ?? "file", path: path)
        case "ls": return ActionDescription(kind: .list, verb: verb("Listed", "listing"), object: path.map(shortPath) ?? "directory", path: path)
        case "find", "grep": return ActionDescription(kind: .search, verb: verb("Searched", "searching"), object: text(input["pattern"]) ?? "files")
        case "mcp":
            // The meta-tool's action says what happened: a server list, schema loads or one invocation.
            let action = text(input["action"]) ?? "invoke", server = text(input["server"])
            if action == "list" { return ActionDescription(kind: .mcp, verb: verb("Listed", "listing"), object: server.map { "tools on \($0)" } ?? "MCP servers") }
            if action == "describe" {
                let count = (input["targets"] as? [Any])?.count ?? 0
                return ActionDescription(kind: .mcp, verb: verb("Loaded", "loading"), object: count > 0 ? "\(count) tool \(count == 1 ? "schema" : "schemas")" : "tool schemas")
            }
            return ActionDescription(kind: .mcp, verb: verb("Called", "calling"), object: "\(server ?? "server") · \(text(input["tool"]) ?? "call")")
        default: return ActionDescription(kind: .other, verb: verb("Used", "using"), object: tool.name)
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
        if tools.contains(where: { ["failed", "cancelled"].contains($0.state) }) { return .failed }
        return .completed
    }
    /// "Reasoned", "Read 1 file" or "Reasoned, read 1 file, ran 2 commands".
    static func summarizeWork(_ tools: [ToolView], reasoned: Bool) -> String? {
        ToolCallSummary(tools: tools).label(reasoned: reasoned)
    }

    static func blockReasoned(_ block: TranscriptBlock) -> Bool {
        block.replies.contains { !($0.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Formatting

    static func formatDuration(_ ms: Double) -> String {
        guard DurationObservation.valid(ms) != nil else { return "" }
        if ms < 1_000 { return String(format: "%.1fs", ms / 1000) }
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
        if value < 1_000 { return grouped(value) }
        if value < 10_000 {
            var text = String(format: "%.1f", value / 1_000)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + "k"
        }
        if value < 1_000_000 { return "\(Int((value / 1_000).rounded()))k" }
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
    /// The card draws at most this many rows, and refuses to diff a request
    /// past these bounds at all — the helper bounds a call's arguments today,
    /// and a preview must stay a preview if it ever stops.
    static let diffDrawLimit = 400
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
    nonisolated(unsafe) private(set) static var editComputationCount = 0

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
        editComputationCount += 1
        var all: [DiffRow]
        if diffable, mode == "edit" || (created && outcome == .done) {
            all = lineDiff(before, after)
        } else {
            all = (new ?? before).components(separatedBy: "\n").map { DiffRow(kind: .context, text: $0) }
        }
        // Where the content stops, as its own line at the end of the hunk.
        if let marker { all.append(DiffRow(kind: .context, text: marker)) }
        return EditRequest(before: before, after: after, mode: mode, rows: Array(all.prefix(diffDrawLimit)),
                           hiddenRows: max(0, all.count - diffDrawLimit), complete: complete,
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

    private static func reported(_ value: Double?) -> Double? {
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
        for message in messages {
            guard let a = message.accounting else { continue }
            sum.requests += a.requests
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
            if let name = a.models?.names.first { sum.model = name; sum.modelMessageID = message.id }
        }
        return sum
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
        let modelLabel = models?.names.first
        let modelDetail: String? = models.map { models in
            [
                "Reported model\(models.nameCount == 1 ? "" : "s"): \(models.names.isEmpty ? "unavailable" : models.names.joined(separator: ", "))\(models.nameCount > models.names.count ? "; \(models.nameCount - models.names.count) more (see Details)" : "").",
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
              displayRequests >= 0, displayRequests <= requests else { return false }
        return m.nameCount <= displayRequests && (displayRequests == 0) == (m.nameCount == 0)
    }

    // MARK: Blocks and turns

    static func patched(_ items: [TranscriptItem], from previous: [TranscriptMessage], to page: [TranscriptMessage]) -> [TranscriptItem]? {
        guard TaskTranscriptPlan.cosmetic(from: previous, to: page) else { return nil }
        return TaskTranscriptPlan.items(page, lifecycle: nil)
    }
    static func blocks(of messages: [TranscriptMessage], lifecycle: TaskPresentationProjection? = nil) -> [TranscriptItem] {
        TaskTranscriptPlan.items(messages, lifecycle: lifecycle)
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
