// Header and headline stacks frozen from v0.1.119's BackgroundRequestsPage.
// Kept here to validate the original spacer and truncation behavior.
import SwiftUI
@testable import PiApp

struct BackgroundRequestHeaderReference: View {
    let caption: String
    let compact: Bool

    private var filterTabs: some View {
        PiTabs(selection: .constant(BackgroundRequestFilter.all), items: BackgroundRequestFilter.allCases.map { ($0, $0.title) })
            .fixedSize()
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                HStack(spacing: PiSpacing.md) {
                    Button {} label: { Label("Chats", systemImage: "chevron.left") }.buttonStyle(.piGhost)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background requests").font(PiFont.title(17)).foregroundStyle(Color.piInk)
                        Text(caption).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: PiSpacing.sm)
                    if !compact { filterTabs }
                }
                if compact { filterTabs }
            }
            .padding(.horizontal, PiSpacing.lg).padding(.top, 12).padding(.bottom, 10)
            Rectangle().fill(Color.piHairline).frame(height: 1)
        }
    }
}

/// The row's first line, before its independent metadata line.
struct BackgroundRequestHeadlineReference: View {
    let row: BackgroundRequestRow

    private var headline: (text: String, color: Color) {
        switch row.status {
        case .running: return ("Waiting for the mini model…", .piInkSecondary)
        case .completed: return row.resultLine.map { ($0, Color.piInk) } ?? ("No result was kept", .piInkSecondary)
        case .failed(let why): return (why, .piDanger)
        case .interrupted(let why): return (row.resultLine ?? why, .piInkSecondary)
        }
    }
    @ViewBuilder private var badge: some View {
        switch row.status {
        case .running: PiBadge(text: row.status.label, tone: .warning, spinning: true)
        case .completed: PiBadge(text: row.status.label, tone: .success, dot: true)
        case .failed: PiBadge(text: row.status.label, tone: .danger, dot: true)
        case .interrupted: PiBadge(text: row.status.label, tone: .neutral, dot: true)
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: PiSpacing.sm) {
            Text(row.kind.label).font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInkSecondary)
                .lineLimit(1).fixedSize()
            Text(headline.text).font(PiFont.body).foregroundStyle(headline.color)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: PiSpacing.sm)
            if let duration = row.durationMs {
                Text(TranscriptActivity.formatDuration(duration)).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                    .fixedSize()
            }
            badge.fixedSize()
        }
    }
}
