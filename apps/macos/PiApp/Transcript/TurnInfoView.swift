import SwiftUI
import AppKit

/// Render the same reported observations inline, in the live dock, and in its
/// details table. Missing reports stay distinct from a reported zero.
enum TurnInfoPresentation {
    static func live(_ turn: TurnSummary, at date: Date, uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) -> TurnSummary {
        guard turn.live else { return turn }
        var current = turn
        if let start = turn.liveStartedUptimeMs { current.elapsedMs = DurationObservation.valid(uptimeMs - start) }
        else if let start = turn.startedAt { current.elapsedMs = DurationObservation.valid(date.timeIntervalSince1970 * 1000 - start) }
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
        case .some(let value): return value.capitalized
        case nil: return turn.live ? "In progress" : "Outcome unavailable"
        }
    }
    static func tokenLabel(_ turn: TurnSummary) -> String {
        TranscriptActivity.tokens(of:turn.accounting).map(TranscriptActivity.formatTokenCount) ?? (turn.live ? "Pending" : "Unreported")
    }
    static func costLabel(_ turn: TurnSummary) -> String {
        turn.accounting.costUSD.map(TranscriptActivity.formatTurnCost) ?? (turn.live ? "Pending" : "Unreported")
    }
    static func inlineFigures(_ turn: TurnSummary) -> [String] {
        var parts = ["\(tokenLabel(turn)) tokens", "Cost \(costLabel(turn))"]
        let a = turn.accounting
        func add(_ value: Double?, _ label: String, _ samples: Int) {
            if let value { parts.append("\(label) \(TranscriptActivity.formatTokenCount(value))" + (samples < a.requests ? " (\(samples)/\(a.requests))" : "")) }
        }
        add(a.input,"In",a.inputSamples); add(a.output,"Out",a.outputSamples)
        add(a.cached,"Cached",a.cachedSamples); add(a.reasoning,"Reasoning",a.reasoningSamples)
        if a.costSamples > 0 && a.costSamples < a.requests { parts[1] += " (\(a.costSamples)/\(a.requests) reported)" }
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
        rows.append(Row(name:"Duration",value:turn.elapsedMs.map(TranscriptActivity.formatDuration) ?? (turn.live ? "In progress" : "Unavailable")))
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

struct TurnInfoButton: View {
    let turn: TurnSummary
    let actions: TranscriptActions
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName:"info.circle").frame(width:20,height:20) }
            .buttonStyle(.plain).help("Show turn info").accessibilityLabel("Show turn info")
            .popover(isPresented:$open) { TurnInfoView(turn:turn,actions:actions) }
    }
}

/// The detailed view remains lazy and separate from the transcript's prose
/// hosts. Expanding it cannot change their geometry or selection.
struct TurnInfoView: View {
    let turn: TurnSummary
    let actions: TranscriptActions
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Turn info").font(.headline)
                Spacer()
                Button("Copy Turn Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TurnLineView.copyText(turn),forType:.string)
                }.buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:16) {
                    if let notice = turn.notice { Text(notice).foregroundStyle(TranscriptPalette.warning).textSelection(.enabled) }
                    if turn.partial { Text("Partial history: usage below covers loaded request records. Load earlier work to include it.").foregroundStyle(TranscriptPalette.warning) }
                    if turn.live { Text("Gateway-reported usage so far. The current request may report its final usage and cost when it finishes.").foregroundStyle(TranscriptPalette.muted) }
                    table(TurnInfoPresentation.rows(turn))
                    Text("Cached tokens are included in input; reasoning tokens and reasoning cost are included in output and total cost. They are not added again.")
                        .foregroundStyle(TranscriptPalette.muted)
                    ForEach(Array(turn.requests.enumerated()),id:\.element.id) { index, reply in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text("Request group \(index + 1)").fontWeight(.semibold)
                                Spacer()
                                Button("Request details") { actions.inspect(reply.id) }.buttonStyle(.plain)
                            }
                            Text("Message: " + reply.id).foregroundStyle(TranscriptPalette.faint).textSelection(.enabled)
                            if let ms = reply.modelMs { Text("Model request: " + TranscriptActivity.formatDuration(ms)) }
                            table(TurnInfoPresentation.usageRows(TranscriptActivity.aggregate([reply])))
                        }
                    }
                }.padding(.trailing,4)
            }
        }.font(.system(size:12)).foregroundStyle(TranscriptPalette.text)
            .padding(16).frame(width:620,height:480).background(TranscriptPalette.surface)
    }
    private func table(_ rows: [TurnInfoPresentation.Row]) -> some View {
        Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:7) {
            GridRow {
                Text("Metric").fontWeight(.semibold)
                Text("Value").fontWeight(.semibold)
                Text("Coverage").fontWeight(.semibold)
            }
            Divider().gridCellColumns(3)
            ForEach(rows) { row in
                GridRow(alignment:.top) {
                    Text(row.name).foregroundStyle(TranscriptPalette.muted).frame(width:150,alignment:.leading)
                    Text(row.value).monospacedDigit().textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Text(row.coverage).foregroundStyle(TranscriptPalette.faint).monospacedDigit().frame(width:115,alignment:.leading)
                }
            }
        }.fixedSize(horizontal:false,vertical:true)
    }
}
