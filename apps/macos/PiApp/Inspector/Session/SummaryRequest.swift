import SwiftUI

/// What one compaction summary request asked the model to do, read from its
/// body. A compaction can make several: the history before the kept messages
/// (in chained parts when it does not fit one request), then the start of a
/// turn too large to keep whole. Reading them as "two compactions" was the
/// mistake this names away.
enum SummaryRequestKind: String, Sendable, Equatable {
    /// The history before the kept messages, summarized afresh.
    case earlierHistory
    /// New messages folded into a summary so far (`<previous-summary>`): the
    /// next part of a chained history, or a later compaction's update.
    case update
    /// The start of a turn too large to keep whole (pi's turn-prefix prompt).
    case turnStart
}

struct SummaryRequestInfo: Sendable, Equatable {
    var kind: SummaryRequestKind
    /// The prompt's instruction: what follows the conversation, and the
    /// summary so far when there is one. At most `instructionLimit` characters.
    var instruction: String

    static let instructionLimit = 4_000
    /// Pi's summarization system prompt opens with this.
    static let systemMarker = "You are a context summarization assistant."
    /// Pi's turn-prefix prompt, and the helper's turn-prefix update, carry this.
    static let turnPrefixMarker = "This is the PREFIX of a turn that was too large to keep."
    /// Pi's update prompt opens with this.
    static let updateMarker = "The messages above are NEW conversation messages"

    /// Whether a request's system prompt is pi's summarization prompt.
    static func isSummary(system: String?) -> Bool { system?.hasPrefix(systemMarker) == true }

    /// The kind and instruction of a summary request, from the text of its
    /// one user message: `<conversation>…</conversation>`, then
    /// `<previous-summary>…</previous-summary>` when there is a summary so
    /// far, then the instruction. The later of the two closing tags ends
    /// what came before the instruction; either one may occur, quoted, inside
    /// what it closes, and only the last occurrence is the real end.
    static func read(prompt: String) -> SummaryRequestInfo? {
        let conversation = prompt.range(of: "</conversation>", options: .backwards)
        let previous = prompt.range(of: "</previous-summary>", options: .backwards)
        let end: Range<String.Index>, update: Bool
        switch (conversation, previous) {
        case (nil, nil): return nil
        case (let closing?, nil): end = closing; update = false
        case (nil, let closing?): end = closing; update = true
        case (let text?, let summary?): (end, update) = summary.lowerBound > text.lowerBound ? (summary, true) : (text, false)
        }
        let instruction = prompt[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: SummaryRequestKind = instruction.contains(turnPrefixMarker) ? .turnStart
            : update && instruction.hasPrefix(updateMarker) ? .update : .earlierHistory
        return SummaryRequestInfo(kind: kind, instruction: String(instruction.prefix(instructionLimit)))
    }
}

/// The summary requests of one compaction, in the order they were sent,
/// and what each is called.
enum SummaryRequestLabel {
    /// "start of this turn"; an update is "part N of M" when it is a chained
    /// part of one compaction's history, else "update"; anything else is
    /// "earlier history". `kinds` are the compaction's requests in order,
    /// nil where the body has not been read.
    static func label(at index: Int, kinds: [SummaryRequestKind?]) -> String? {
        guard kinds.indices.contains(index), let kind = kinds[index] else { return nil }
        switch kind {
        case .turnStart: return "start of this turn"
        case .earlierHistory: return "earlier history"
        case .update:
            // The history's parts: every request that is not the turn's start.
            // They can only be counted once every body has been read.
            guard !kinds.contains(where: { $0 == nil }) else { return "update" }
            let parts = kinds.indices.filter { kinds[$0] != .turnStart }
            guard parts.count > 1, let position = parts.firstIndex(of: index) else { return "update" }
            return "part \(position + 1) of \(parts.count)"
        }
    }
}

/// The top of a summary request's Conversation tab: which part of its
/// compaction it is, and the instruction its prompt ends with.
struct SummaryInstructionCard: View {
    let summary: SummaryRequestInfo
    /// "part 2 of 2" once the compaction's other requests are read.
    let label: String?
    private var name: String {
        label ?? {
            switch summary.kind {
            case .earlierHistory: return "earlier history"
            case .update: return "update"
            case .turnStart: return "start of this turn"
            }
        }()
    }
    private var subject: String {
        switch summary.kind {
        case .earlierHistory: return "Summarizes the history before the messages the compaction keeps."
        case .update: return "Folds new messages into the summary so far, given in <previous-summary>."
        case .turnStart: return "Summarizes the start of a turn too large to keep whole; its recent work is kept."
        }
    }
    var body: some View {
        PiCard(padding: PiSpacing.md, sunken: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PiIconBadge(symbol: "arrow.down.right.and.arrow.up.left", tone: .accent, size: 22)
                    Text("Summary request").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.piInk)
                    PiBadge(text: name, tone: .accent).accessibilityIdentifier("summary-request-kind")
                    Spacer(minLength: 0)
                }
                Text(subject).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Text("Instruction").font(PiFont.micro).tracking(0.5).foregroundStyle(Color.piInkTertiary)
                ScrollView {
                    Text(summary.instruction).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.piInk)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .accessibilityIdentifier("summary-request-instruction")
            }
        }
        .background(SummaryInstructionMarker(name: name))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary-request-card")
    }
}

/// Marks the summary card in the view tree, with the name it shows, so a
/// check can find it. Draws nothing and takes no clicks.
struct SummaryInstructionMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> SummaryInstructionMarkerView { SummaryInstructionMarkerView() }
    func updateNSView(_ view: SummaryInstructionMarkerView, context: Context) { if view.name != name { view.name = name } }
}
final class SummaryInstructionMarkerView: NSView {
    var name = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
