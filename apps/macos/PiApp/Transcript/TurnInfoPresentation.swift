import SwiftUI
import AppKit

/// Render the same reported observations inline, in the live dock, and in its
/// details table. Missing reports stay distinct from a reported zero.
enum TurnInfoPresentation {
    static func workingLabel(_ turn: TurnSummary, state: String = "running") -> String {
        switch state == "stopping" ? "stopping" : turn.phase ?? state {
        case "queued", "preparing": return "Preparing response…"
        case "stopping": return "Stopping…"
        case "compacting": return "Compacting context…"
        case "retrying": return "Waiting to retry…"
        case "tools": return "Running " + (turn.current?.name ?? "tools") + "…"
        case "model": return "Generating response…"
        default: return "Reconciling task status…"
        }
    }
    static func live(_ turn: TurnSummary, at date: Date, uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) -> TurnSummary {
        var current = turn
        current.live = turn.isRunning
        current.elapsedMs = TurnDurationInput(turn).reading(at: date, uptimeMs: uptimeMs).elapsedMs
        return current
    }
    struct Row: Identifiable, Equatable {
        var name: String
        var value: String
        var coverage = ""
        var id: String { name }
    }
    static func outcome(_ turn: TurnSummary) -> String {
        switch turn.outcome {
        case "completed": return "Completed"
        case "cancelled": return "Stopped"
        case "output-limited": return "Output limit reached"
        // A stop at the chat's cost limit is deliberate, not a failure.
        case "failed" where turn.errorCode == SessionDisplay.costLimitCode: return "Stopped · cost limit"
        case .some(let value): return value.capitalized
        case nil: return turn.isRunning ? "In progress" : "Outcome unavailable"
        }
    }
    /// The report's model: the latest route, with how many models answered
    /// when the router sent the turn's requests to more than one.
    /// A request with no model reported adds no "+1": the notice counts it.
    static func modelLabel(_ turn: TurnSummary, fallback: String? = nil) -> String {
        let a = turn.accounting, answered = a.answeredModels, requested = a.requestedModels
        let count = answered.count > 1 ? " · \(answered.count) models" : ""
        // The latest route that named what answered: a later request that
        // reported no model does not hide the one that did.
        if let route = a.modelRoutes.filter({ $0.responded != nil }).max(by: { $0.latestWall < $1.latestWall }) ?? a.latestModelRoute {
            return route.label + (count.isEmpty && requested.count > 1 ? " +\(requested.count - 1)" : count)
        }
        let names = answered.isEmpty ? fallback.map { [$0] } ?? [] : answered
        guard let name = a.model ?? names.last else { return turn.isRunning ? "Model pending" : "Model unreported" }
        return name + (count.isEmpty && names.count > 1 ? " +\(names.count - 1)" : count)
    }
    /// One quiet line: which requests the figures cover, why the others have
    /// none, and how many came from the replies' own record rather than the
    /// request log. Nil when every request reported and the log had them all.
    static func coverageNotice(_ turn: TurnSummary) -> String? {
        let a = turn.accounting, n = a.requests, missing = a.missing
        var parts: [String] = []
        let reported = missing.known ? n - missing.total : max(a.inputSamples, a.outputSamples)
        if n > 0, reported < n {
            var text = "input and output from \(max(0, reported)) of \(n) requests; \(n - max(0, reported)) did not report usage"
            if missing.known {
                let reasons = [(missing.running, "still running", "still running"),
                               (missing.failed, "failed before it finished", "failed before they finished"),
                               (missing.noUsage, "came back with no usage from the gateway", "came back with no usage from the gateway"),
                               (missing.notCaptured, "was not captured", "were not captured"),
                               (missing.expired, "has expired from the request log", "have expired from the request log")]
                    .compactMap { count, one, many in count > 0 ? "\(count) " + (count == 1 ? one : many) : nil }
                if !reasons.isEmpty { text += " (" + reasons.joined(separator: ", ") + ")" }
            }
            parts.append(text)
        }
        let record = a.recordRequests
        if record > 0 { parts.append((record == n ? "all" : "\(record) of \(n)") + " from the chat’s own record") }
        let coverage = parts.isEmpty ? nil : parts.joined(separator: " · ")
        if turn.isRunning { return "Reported so far · " + (coverage ?? "updates as requests finish") }
        if turn.partial { return "Partial history · retained request usage" + (coverage.map { " · " + $0 } ?? "") }
        return coverage.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
    static func subtotals(_ lines: [TurnRequestLine]) -> [TurnModelSubtotal] {
        var order: [String?] = [], totals: [String?: TurnModelSubtotal] = [:]
        for line in lines {
            if totals[line.model] == nil { order.append(line.model); totals[line.model] = TurnModelSubtotal(model: line.model) }
            totals[line.model]?.add(line)
        }
        return order.compactMap { totals[$0] }
    }
    /// A request's route: what it asked for → what answered, and the other
    /// name the gateway gave when its reports disagree.
    static func routeLabel(_ line: TurnRequestLine) -> String {
        line.route.label + (line.routedVia.map { " (gateway header: \($0))" } ?? "")
    }
    static func lineFigures(_ line: TurnRequestLine) -> String {
        var parts: [String] = []
        if let input = line.input { parts.append("in " + TranscriptActivity.grouped(input) + (line.cached.map { $0 > 0 ? " (\(TranscriptActivity.grouped($0)) cached)" : "" } ?? "")) }
        if let output = line.output { parts.append("out " + TranscriptActivity.grouped(output)) }
        if let cost = line.cost { parts.append(compactGatewayUSD(cost)) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch line.missing {
        case .running?: return "running"
        case .failed?: return "failed before finishing"
        case .noUsage?: return "no usage from the gateway"
        case .expired?: return "metrics expired"
        case .notCaptured?: return "not captured"
        default: return "usage unreported"
        }
    }
    static func lineSource(_ line: TurnRequestLine) -> String {
        guard line.source == .record else { return line.live ? "live log" : "request log" }
        switch line.logMissing {
        case .expired?: return "chat record · log expired"
        case .notCaptured?: return "chat record · not in log"
        default: return "chat record"
        }
    }
    static func subtotalLabel(_ subtotal: TurnModelSubtotal) -> String {
        var parts = [(subtotal.model ?? "Model unreported"), "\(subtotal.requests) request\(subtotal.requests == 1 ? "" : "s")"]
        if let input = subtotal.input { parts.append("in " + TranscriptActivity.grouped(input) + (subtotal.inputSamples < subtotal.requests ? " (\(subtotal.inputSamples)/\(subtotal.requests))" : "")) }
        if let output = subtotal.output { parts.append("out " + TranscriptActivity.grouped(output) + (subtotal.outputSamples < subtotal.requests ? " (\(subtotal.outputSamples)/\(subtotal.requests))" : "")) }
        return parts.joined(separator: " · ")
    }
    static func tokenLabel(_ turn: TurnSummary) -> String {
        TranscriptActivity.tokens(of:turn.accounting).map(TranscriptActivity.formatTokenCount) ?? (turn.isRunning ? "Pending" : "Unreported")
    }
    /// The turn's reported cost. A cost only some requests reported is those
    /// requests' cost, and says how many: it must not pass for the turn's.
    static func costLabel(_ turn: TurnSummary) -> String {
        let a = turn.accounting
        guard let cost = a.costUSD, cost.isFinite, cost >= 0 else { return turn.isRunning ? "Pending" : "Unreported" }
        return "$" + MetricFormat.preciseDecimal(cost) + (a.costSamples > 0 && a.costSamples < a.requests ? " (\(a.costSamples)/\(a.requests) reported)" : "")
    }
    static func inlineFigures(_ turn: TurnSummary) -> [String] {
        var parts = ["\(tokenLabel(turn)) tokens", "Cost \(costLabel(turn))"]
        let a = turn.accounting
        func add(_ value: Double?, _ label: String, _ samples: Int) {
            if let value { parts.append("\(label) \(TranscriptActivity.formatTokenCount(value))" + (samples < a.requests ? " (\(samples)/\(a.requests))" : "")) }
        }
        add(a.input,"In",a.inputSamples); add(a.output,"Out",a.outputSamples)
        add(a.cached,"Cached",a.cachedSamples); add(a.reasoning,"Reasoning",a.reasoningSamples)
        if turn.modelMs > 0 { parts.append("Model " + TranscriptActivity.formatDuration(turn.modelMs)) }
        if turn.toolMs > 0 { parts.append("Tools " + TranscriptActivity.formatDuration(turn.toolMs)) }
        if let model = a.model { parts.append(model) }
        if turn.partial { parts.append("Partial history") }
        return parts
    }
    static func rows(_ turn: TurnSummary) -> [Row] {
        var rows = [Row(name:"Status",value:outcome(turn)), Row(name:"Replies / tool calls",value:"\(turn.replies) / \(turn.tools)"),
                    Row(name:"Files changed",value:String(turn.files))]
        if let start = turn.startedAt { rows.append(Row(name:"Started",value:TranscriptActivity.formatClock(start))) }
        if let end = turn.endedAt { rows.append(Row(name:"Finished",value:TranscriptActivity.formatClock(end))) }
        rows.append(Row(name:"Duration",value:turn.elapsedMs.map(TranscriptActivity.formatDuration) ?? (turn.isRunning ? "In progress" : "Unavailable")))
        rows.append(Row(name:"Model request time",value:TranscriptActivity.formatDuration(turn.modelMs)))
        rows.append(Row(name:"Tool time",value:TranscriptActivity.formatDuration(turn.toolMs)))
        rows += usageRows(turn.accounting)
        return rows
    }
    static func usageRows(_ a: TurnAccounting) -> [Row] {
        func observation(_ name: String, _ value: Double?, _ samples: Int, cost: Bool = false) -> Row {
            Row(name:name, value:value.map { cost ? gatewayUSD($0) : TranscriptActivity.grouped($0) } ?? "Unreported",
                coverage:"\(samples)/\(a.requests) requests")
        }
        return [
            Row(name:"Requests with records",value:String(a.requests)),
            observation("Total tokens",a.total,a.totalSamples),
            observation("Input tokens",a.input,a.inputSamples),
            observation("Cached input tokens",a.cached,a.cachedSamples),
            observation("Uncached input tokens",a.uncached,a.uncachedSamples),
            observation("Cache-write tokens",a.cacheWrite,a.cacheWriteSamples),
            observation("Output tokens",a.output,a.outputSamples),
            observation("Reasoning tokens (in output)",a.reasoning,a.reasoningSamples),
            observation("Total cost",a.costUSD,a.costSamples,cost:true),
            observation("Reasoning cost (in total)",a.reasoningCostUSD,a.reasoningCostSamples,cost:true),
            Row(name:"Response cache",value:"\(a.cacheHits) hit · \(a.cacheMisses) miss · \(a.cacheUnreported) unreported · \(a.cacheConflicts) invalid/conflicting"),
            Row(name:"Requested models",value:a.requestedModels.isEmpty ? "Unreported" : a.requestedModels.joined(separator: ", ")),
            Row(name:"Response models",value:a.reportedModels.isEmpty ? "Unreported" : a.reportedModels.joined(separator: ", ")),
            Row(name:"Model routes",value:a.modelRoutes.isEmpty ? "Unreported" : a.modelRoutes.map(\.label).joined(separator: "\n"))
        ]
    }
}

/// The turn report's info button: opens the Session Inspector at this turn.
/// An AppKit button of a fixed size, so the transcript row that holds it
/// never re-measures for it.
struct TurnInfoButton: NSViewRepresentable {
    let turn: TurnSummary
    let actions: TranscriptActions
    func makeCoordinator() -> Coordinator { Coordinator(turn: turn, actions: actions) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Open this turn in the Session Inspector")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.target = context.coordinator; button.action = #selector(Coordinator.open(_:))
        button.isBordered = false; button.imagePosition = .imageOnly; button.contentTintColor = .tertiaryLabelColor
        // Rows never draw the system's focus ring.
        button.focusRingType = .none
        button.toolTip = "Open this turn in the Session Inspector"; button.setAccessibilityLabel("Open this turn in the Session Inspector")
        button.setAccessibilityIdentifier("turn-info-button")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.turn = turn; context.coordinator.actions = actions }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { CGSize(width: 20, height: 20) }

    @MainActor final class Coordinator: NSObject {
        var turn: TurnSummary
        var actions: TranscriptActions
        init(turn: TurnSummary, actions: TranscriptActions) { self.turn = turn; self.actions = actions }
        @objc func open(_ button: NSButton) { actions.inspectTurn?(turn) }
    }
}
