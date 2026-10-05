// Frozen ledger UI at 59ef8e0d.
import AppKit
import SwiftUI
@testable import PiApp

/// Every retained request of the session, oldest first, in the order it ran.
/// The figures that the pills fold into one number, one row at a time. In the
/// Inspector a row opens its request.
struct SessionRequestLedgerViewReference: View {
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
                    // Built as they scroll into view. The ledger sits under the
                    // charts, off screen as the Overview opens, and building its
                    // forty rows was most of what opening the page cost.
                    LazyVStack(alignment: .leading, spacing: PiSpacing.sm) {
                        ForEach(shown) { row in
                            Rectangle().fill(Color.piHairline).frame(height: 1)
                            if let open {
                                Button { open(row.id) } label: { line(row).contentShape(Rectangle()) }
                                    .buttonStyle(SessionLedgerRowStyleReference()).help("Open request \(row.number)")
                            } else { line(row) }
                        }
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
        SessionStatsRenderCount.ledgerRowBuilt()
        return HStack(alignment: .top, spacing: PiSpacing.sm) {
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
private struct SessionLedgerRowStyleReference: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? Color.piFill : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .piPointer()
    }
}
