import SwiftUI
import AppKit

// The small pieces every Inspector page is built from. None of them reads or
// formats a body: the strings arrive prepared.

/// A page's heading: what it is, a quiet line of context, badges, and the
/// page's own actions on the right.
struct InspectorPageHeader<Badges: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var badges: Badges
    @ViewBuilder var actions: Actions
    init(_ title: String, subtitle: String? = nil, @ViewBuilder badges: () -> Badges = { EmptyView() }, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.badges = badges(); self.actions = actions()
    }
    var body: some View {
        HStack(alignment: .top, spacing: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(PiFont.title(18)).foregroundStyle(Color.piInk).lineLimit(1).layoutPriority(1)
                    badges
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: 6) { actions }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Show in chat": the one action every page has.
struct InspectorShowInChat: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("Show in chat", systemImage: "arrow.uturn.left.circle") }
            .buttonStyle(.piGhost).help("Bring the chat forward, scrolled to what this page is about")
            .accessibilityIdentifier("inspector-show-in-chat")
    }
}

/// "Fork from here": a new chat that ends at the reply this request produced.
struct InspectorForkFromHere: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("Fork from here", systemImage: "arrow.triangle.branch") }
            .buttonStyle(.piGhost).help("A new chat, nested under this one, that ends at the reply this request produced")
            .accessibilityIdentifier("inspector-fork-from-here")
    }
}

/// A heading inside a page: a title and what it covers.
struct InspectorSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(PiFont.heading).foregroundStyle(Color.piInk)
            if let subtitle { Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// One figure of a strip: a quiet label and its value in ink.
struct InspectorFigure: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    var detail: String? = nil
    var tone: PiTone = .neutral
}

/// A strip of figures that wraps like a sentence on a narrow page.
struct InspectorFigureStrip: View {
    let figures: [InspectorFigure]
    var body: some View {
        PiFlow(spacing: 16, rowSpacing: 6) {
            ForEach(figures) { figure in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(figure.label).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                    Text(figure.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(figure.tone == .neutral ? Color.piInk : figure.tone.color)
                    if let detail = figure.detail {
                        Text(detail).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A banner over a list: what changed, in accent or warning ink.
struct InspectorBanner: View {
    let symbol: String
    let text: String
    var notes: [String] = []
    var tone: PiTone = .accent
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.piInk).fixedSize(horizontal: false, vertical: true)
                ForEach(notes, id: \.self) { note in
                    Text(note).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone == .accent ? Color.piAccentSoft : tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector-banner")
    }
}

/// A calm, centered message where a page has nothing to show yet.
struct InspectorPlaceholder: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var progress: Double? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(Color.piInkTertiary)
            Text(title).font(PiFont.heading).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center)
            // Drawn by SwiftUI: an AppKit progress bar would size itself on every update.
            if let progress { UsageShareBar(fraction: progress, tone: .piBrandOrange).frame(width: 220, height: 4) }
            if let message {
                Text(message).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PiSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The whole text of one item, read on the capture worker when asked for.
@MainActor final class InspectorFullText: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var text = ""
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private var task: Task<Void, Never>?
    private var generation = 0

    func open(title: String, render: @escaping @Sendable () throws -> String) {
        task?.cancel(); generation += 1
        let generation = generation
        self.title = title; text = ""; failure = nil; loading = true
        task = Task { [weak self] in
            do {
                let value = try await CapturedBodyWorker.shared.run(render)
                guard let self, self.generation == generation else { return }
                self.text = value; self.loading = false
            } catch {
                guard let self, self.generation == generation, !(error is CancellationError) else { return }
                self.failure = error.localizedDescription; self.loading = false
            }
        }
    }
    /// Text the app has to ask for (a prompt from the chat's journal).
    func open(title: String, load: @escaping @MainActor () async throws -> String) {
        task?.cancel(); generation += 1
        let generation = generation
        self.title = title; text = ""; failure = nil; loading = true
        task = Task { [weak self] in
            do {
                let value = try await load()
                guard let self, self.generation == generation else { return }
                self.text = value; self.loading = false
            } catch {
                guard let self, self.generation == generation, !(error is CancellationError) else { return }
                self.failure = error.localizedDescription; self.loading = false
            }
        }
    }
    func close() { task?.cancel(); generation += 1; title = nil; text = ""; loading = false; failure = nil }
}

/// The pane under an outline that holds one item's whole text: a native text
/// view, so a long tool result scrolls without SwiftUI laying it out.
struct InspectorFullTextPane: View {
    @ObservedObject var full: InspectorFullText
    var body: some View {
        if let title = full.title {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.plaintext").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary)
                    Text(title).font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk).lineLimit(1)
                    if !full.text.isEmpty {
                        Text(RequestDocument.charactersLabel((full.text as NSString).length)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    }
                    Spacer(minLength: 0)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(full.text, forType: .string) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.buttonStyle(.piGhost).disabled(full.text.isEmpty)
                    PiIconButton(symbol: "xmark", label: "Close", size: 22) { full.close() }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Rectangle().fill(Color.piHairline).frame(height: 1)
                ZStack {
                    PagedTextView(text: full.text, accessibilityLabel: title)
                    if full.loading { PiSpinner(size: 16, lineWidth: 2) }
                    if let failure = full.failure { Text(failure).font(PiFont.caption).foregroundStyle(Color.piWarning).padding() }
                }
            }
            .frame(height: 220)
            .background(Color.piSurfaceSunken)
            .overlay(alignment: .top) { Rectangle().fill(Color.piHairline).frame(height: 1) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("inspector-full-text")
        }
    }
}

/// A small status mark: a dot or a shimmer for a request still running.
struct InspectorStatusMark: View {
    let outcome: String
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay { if running { Circle().stroke(color.opacity(0.35), lineWidth: 3) } }
            .accessibilityLabel(outcome)
    }
    private var running: Bool { ["running", "streaming"].contains(outcome) }
    private var color: Color {
        switch outcome {
        case "completed", "truncated": return .piSuccess
        case "running", "streaming": return .piBrandOrange
        case "failed", "interrupted", "error": return .piDanger
        case "cancelled": return .piWarning
        default: return .piInkTertiary
        }
    }
}

extension InspectorRequestRow {
    /// `Completed`, `Running`, `Failed`.
    var outcomeLabel: String {
        switch outcome {
        case "completed": return "Completed"
        case "truncated": return "Output limit"
        case "running", "streaming": return "Running"
        case "interrupted": return "Interrupted"
        case "cancelled": return "Stopped"
        case "failed", "error": return "Failed"
        default: return outcome.isEmpty ? "Unknown" : outcome.prefix(1).uppercased() + outcome.dropFirst()
        }
    }
    var outcomeTone: PiTone {
        switch outcome {
        case "completed": return .success
        case "running", "streaming", "truncated", "cancelled": return .warning
        case "failed", "interrupted", "error": return .danger
        default: return .neutral
        }
    }
    /// `In 18,240 (15,112 cached) · Out 1,104 · reasoning 640 · $0.0213 · TTFT 820 ms · 96 tok/s · 3.4 s`
    var figures: [InspectorFigure] {
        var figures: [InspectorFigure] = []
        if let input { figures.append(InspectorFigure(label: "In", value: MetricFormat.exactTokens(input), detail: cached.map { "(" + MetricFormat.exactTokens($0) + " cached)" })) }
        if let output { figures.append(InspectorFigure(label: "Out", value: MetricFormat.exactTokens(output))) }
        if let reasoning { figures.append(InspectorFigure(label: "reasoning", value: MetricFormat.exactTokens(reasoning))) }
        if let cost { figures.append(InspectorFigure(label: "Cost", value: compactGatewayUSD(cost))) }
        if let ttft { figures.append(InspectorFigure(label: "TTFT", value: MetricFormat.latency(ttft))) }
        if let settledRate { figures.append(InspectorFigure(label: "Speed", value: MetricFormat.throughput(settledRate))) }
        if let duration = duration ?? http { figures.append(InspectorFigure(label: "Time", value: SessionStatsFormat.duration(duration))) }
        return figures
    }
}
