import SwiftUI

/// One retained request as the ledger writes it: what it was, where it went,
/// what it consumed and how fast it decoded. Every cell is a reported figure
/// or an explicit gap; nothing is averaged or inferred across requests.
struct SessionRequestLedgerRow: Identifiable, Equatable {
    let id: String
    /// 1 for the oldest request in the displayed history window.
    let number: Int
    let wall: Date
    let status: String
    let model: String
    /// Input as billed, with what of it was served from cache and what was new.
    let input: String
    let inputDetail: String?
    let output: String
    let outputDetail: String?
    let ttft: String
    /// Decode span: first generated token to last.
    let generation: String
    let throughput: String
    let cost: String
    /// True when this request has no decode speed — no completed span of at
    /// least 250 ms, or fewer than two output tokens — so it contributes
    /// nothing to the settled rate.
    let unmeasured: Bool

    init(number: Int, sample: SessionTimingSample) {
        id = sample.id; self.number = number; wall = sample.wall
        status = sample.outcome.isEmpty ? "unknown" : sample.outcome
        model = [sample.model, sample.api.isEmpty ? nil : sample.api].compactMap { $0 }.first ?? "Unreported"
        input = sample.inputTokens.map(MetricFormat.exactTokens) ?? "—"
        // "12,000 cached · 3,800 new" — the two halves of what was billed.
        var parts: [String] = []
        if let cached = sample.cacheReadTokens { parts.append(MetricFormat.exactTokens(cached) + " cached") }
        if let uncached = sample.uncachedInputTokens { parts.append(MetricFormat.exactTokens(uncached) + " new") }
        if let write = sample.cacheWriteTokens, write > 0 { parts.append(MetricFormat.exactTokens(write) + " written") }
        inputDetail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        output = sample.outputTokens.map(MetricFormat.exactTokens) ?? "—"
        outputDetail = sample.reasoningTokens.map { MetricFormat.exactTokens($0) + " reasoning" }
        ttft = sample.ttftMilliseconds.map(MetricFormat.latency) ?? "—"
        generation = sample.streamingMilliseconds.map(MetricFormat.latency) ?? "—"
        throughput = sample.settledTokensPerSecond.map(MetricFormat.throughput) ?? "—"
        cost = sample.costUSD.map { gatewayUSD($0).replacingOccurrences(of: " USD", with: "") } ?? "—"
        unmeasured = sample.settledTokensPerSecond == nil
    }

    /// One line of this row, for a copy action and for the row's accessibility.
    var line: String {
        "Request \(number) · \(status) · \(model) · in \(input) · out \(output) · TTFT \(ttft) · generation \(generation) · \(throughput) · \(cost)"
    }
}

/// The whole ledger, and what it has to say about its own coverage.
struct SessionRequestLedger: Equatable {
    let rows: [SessionRequestLedgerRow]
    let hasOlderRequests: Bool
    let throughput: SettledThroughput

    init(history: SessionTimingHistory) {
        let samples = history.ledgerSamples ?? history.samples
        rows = samples.enumerated().map { SessionRequestLedgerRow(number: $0.offset + 1, sample: $0.element) }
        hasOlderRequests = history.hasOlderLedgerRequests ?? history.hasOlderRequests
        var rate = SettledThroughput()
        for sample in samples {
            rate.add(decodeMilliseconds: sample.outcome == "completed" ? sample.streamingMilliseconds : nil, outputTokens: sample.outputTokens)
        }
        throughput = rate
    }

    var subtitle: String {
        let count = "\(rows.count) request\(rows.count == 1 ? "" : "s")"
        return hasOlderRequests ? "Most recent \(count)" : count
    }
    /// Named, not counted away: the requests with no decode speed are listed
    /// but excluded from the rate.
    var coverageNote: String {
        let missing = rows.filter(\.unmeasured).count
        let rate = throughput.label ?? "unavailable"
        if missing == 0 {
            return "Session throughput \(rate) — every listed request was measured: output tokens after the first over first to last token."
        }
        let subject = missing == 1 ? "1 request has" : "\(missing) requests have"
        let verb = missing == 1 ? "is" : "are"
        return "Session throughput \(rate) over \(throughput.samples) of \(rows.count) listed requests. \(subject) no decode speed — no completed span of \(SettledThroughput.floorLabel) or more, or fewer than two output tokens — and \(verb) excluded from the rate rather than counted as zero."
    }
    var copyText: String {
        (["#\tStatus\tModel\tInput\tOutput\tTTFT\tGeneration\tThroughput\tCost"]
         + rows.map { [String($0.number), $0.status, $0.model, $0.input, $0.output, $0.ttft, $0.generation, $0.throughput, $0.cost].joined(separator: "\t") }
         + [coverageNote]).joined(separator: "\n")
    }
}

/// Every retained request of the session, oldest first, in the order it ran.
/// The figures that the pills fold into one number, one row at a time. In the
/// Inspector a row opens its request.
struct SessionRequestLedgerView: View {
    let ledger: SessionRequestLedger
    /// Opens a row's request; nil where rows are read only.
    var open: ((String) -> Void)? = nil
    /// Shows only the latest rows, and says how many there are.
    var limit: Int? = nil
    private var shown: ArraySlice<SessionRequestLedgerRow> { limit.map { ledger.rows.suffix($0) } ?? ledger.rows[...] }

    private static let columns: [(String, CGFloat?)] = [
        ("#", 30), ("Status", 88), ("Model", nil), ("Input", 122), ("Output", 108),
        ("TTFT", 64), ("Generation", 82), ("Throughput", 86), ("Cost", 92),
    ]

    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Requests", subtitle: shown.count < ledger.rows.count ? "Latest \(shown.count) of \(ledger.rows.count) · every request is in the list on the left" : ledger.subtitle) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ledger.copyText, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.piSecondaryCompact).accessibilityIdentifier("session-ledger-copy")
                }
                if ledger.rows.isEmpty {
                    Text("No requests with retained metrics yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    header
                    ForEach(shown) { row in
                        Rectangle().fill(Color.piHairline).frame(height: 1)
                        if let open {
                            Button { open(row.id) } label: { line(row).contentShape(Rectangle()) }
                                .buttonStyle(SessionLedgerRowStyle()).help("Open request \(row.number)")
                        } else { line(row) }
                    }
                }
                Text(ledger.coverageNote).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("session-ledger-coverage")
            }
        }.accessibilityIdentifier("session-request-ledger")
    }

    private var header: some View {
        HStack(spacing: PiSpacing.sm) {
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                Text(column.0).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).lineLimit(1)
                    .frame(width: column.1, alignment: .leading).frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
    }

    private func line(_ row: SessionRequestLedgerRow) -> some View {
        HStack(alignment: .top, spacing: PiSpacing.sm) {
            Text("\(row.number)").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.status).font(PiFont.caption).foregroundStyle(row.status == "completed" ? Color.piInk : Color.piWarning).lineLimit(1)
                Text(row.wall.formatted(date: .omitted, time: .standard)).font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary)
            }.frame(width: 88, alignment: .leading)
            Text(row.model).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).help(row.model)
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(row.input, row.inputDetail, width: 122)
            cell(row.output, row.outputDetail, width: 108)
            cell(row.ttft, nil, width: 64)
            cell(row.generation, nil, width: 82)
            cell(row.throughput, row.unmeasured ? "not measured" : nil, width: 86)
            cell(row.cost, nil, width: 92)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.line)
    }

    private func cell(_ value: String, _ detail: String?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            if let detail { Text(detail).font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary).lineLimit(2) }
        }.frame(width: width, alignment: .leading)
    }
}

/// A ledger row that opens its request: a soft fill under the pointer.
private struct SessionLedgerRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? Color.piFill : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .piPointer()
    }
}
