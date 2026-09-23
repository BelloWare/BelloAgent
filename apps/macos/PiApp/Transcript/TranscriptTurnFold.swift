import SwiftUI

/// How a finished turn reads. While a turn runs its work is loose — every card,
/// every thought, in the order it happened. When it ends with an actual answer,
/// everything that produced that answer folds behind one line, and the answer
/// is what the reader sees.
enum TranscriptDisplayMode: String, CaseIterable, Sendable, Codable {
    /// A finished turn keeps every row it had while it ran.
    case normal
    /// A finished turn's work folds behind one line above its answer.
    case compact
    var label: String { self == .normal ? "Normal" : "Compact" }
    var detail: String {
        self == .normal
            ? "A finished turn keeps every tool call and thought on screen."
            : "A finished turn folds its work behind one line above the answer."
    }
    static let fallback = TranscriptDisplayMode.compact
}

/// The reader's choice, where the planner can reach it.
///
/// The plan runs wherever a page is projected, including off the main actor,
/// and the value is one enum written once when the vault loads or the reader
/// changes it. It is a default for `TaskTranscriptPlan.items`, so a caller —
/// a test, a fixture — can always name the mode it means instead.
///
/// It starts loose rather than at the saved default on purpose: nothing may
/// fold before the vault has answered for what the reader chose. A page
/// planned in that first moment shows everything, and `applyConfiguration`
/// republishes it the instant the saved choice arrives.
enum TranscriptDisplay {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedMode: TranscriptDisplayMode = .normal
    static var mode: TranscriptDisplayMode {
        lock.lock(); defer { lock.unlock() }
        return storedMode
    }
    @MainActor static func use(_ mode: TranscriptDisplayMode) {
        lock.lock(); defer { lock.unlock() }
        storedMode = mode
    }
}

/// What one finished turn folded away, and what its one line says.
struct TurnFoldSpec: Equatable, Sendable {
    /// The id of the reader's message that opened this display turn: the key
    /// the reader's choice is kept under, so opening a turn survives
    /// streaming, paging and a chat switch. It is a row on the page by
    /// construction, so it lives exactly as long as the turn does, and it is
    /// unique even when a steer puts two display turns under one task root.
    var group: String
    /// The response whose words are the answer. Its prose never folds.
    var answerResponseID: String
    var toolCalls = 0
    var messages = 0
    var subagents = 0

    /// "3 tool calls · 1 message", "2 subagents", and — when a turn only
    /// thought — the line that says so without counting anything.
    var label: String {
        var parts: [String] = []
        if toolCalls > 0 { parts.append("\(toolCalls) tool call\(toolCalls == 1 ? "" : "s")") }
        if messages > 0 { parts.append("\(messages) message\(messages == 1 ? "" : "s")") }
        if subagents > 0 { parts.append("\(subagents) subagent\(subagents == 1 ? "" : "s")") }
        return parts.isEmpty ? "Thought for a while" : parts.joined(separator: " · ")
    }
    /// A delegation call is a subagent, not a tool call, wherever its name says so.
    static func isSubagent(_ name: String) -> Bool { name == "subagent" || name.hasPrefix("subagent_") }
}

/// The one line a folded turn reads as, and the control that opens it. It is a
/// button in its own right and it is never itself folded, so the keyboard
/// always has somewhere to stand: closing the fold leaves focus on this row
/// rather than on a row that has just stopped drawing.
struct TurnFoldControlRow: View {
    let spec: TurnFoldSpec
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(spec.label).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.muted)
                    .lineLimit(1).truncationMode(.tail).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.faint)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .animation(reduceMotion ? nil : .easeOut(duration: TranscriptRowChrome.chevronSeconds), value: open)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(TranscriptPalette.hair).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .focusable()
        .onKeyPress { press in
            guard TranscriptRowChrome.activates(press.key) else { return .ignored }
            toggle(); return .handled
        }
        .onHover { hovering = $0 }
        .padding(.bottom, open ? 4 : 8)
        .help(open ? "Hide this turn's work" : "Show this turn's work")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spec.label)
        .accessibilityValue(open ? "Open" : "Closed")
        .accessibilityIdentifier("turn-fold")
    }
}

/// Deciding, for a finished turn, what its fold hides and what its line says.
///
/// The rule is the one the reference uses, and every clause of it is a
/// refusal to hide something the reader might still need: the turn must have
/// ended, it must have ended with actual words, its own beginning must be on
/// the page (a window that starts mid-turn cannot know what it is folding),
/// and the reader must have asked for a compact transcript at all.
///
/// A display turn is what one message of the reader's opened — every visible
/// input, a steer included, as the history window counts turns. A steer keeps
/// its task's root, so a task's root cannot name a fold: two display turns
/// would share it. The reader's message that opened the turn names it.
enum TranscriptTurnFold {
    /// Rows a turn's fold never touches: the reader's own message, the turn's
    /// receipts, and anything that reports a failure.
    static func independent(_ message: TranscriptMessage) -> Bool {
        message.role == "user" || message.role == "system"
            || ["branch", "failure", "notice", "compaction"].contains(message.kind ?? "")
    }

    /// Folds every finished turn of a page. Returns the items unchanged when
    /// the reader asked for the normal transcript.
    ///
    /// A turn only folds when its own first row is on the page: a window that
    /// begins in the middle of a turn cannot know what it would be hiding, so
    /// it hides nothing. That is this method's reading of "never while the
    /// history is incomplete", and it is why the scan starts at a user row.
    /// The same holds at the other end: `complete` says whether the page
    /// reaches the conversation's newest row. When it does not, the page's
    /// last turn folds only on its own receipt that it ended.
    static func apply(_ items: [TranscriptItem], display: TranscriptDisplayMode, running: String? = nil,
                      complete: Bool = true) -> [TranscriptItem] {
        guard display == .compact else { return items }
        var result = items
        var opened: (index: Int, id: String)? = nil
        var inserts: [(at: Int, item: TranscriptItem)] = []
        func close(_ range: Range<Int>, group: String, ended: Bool) {
            guard let spec = fold(&result, range: range, group: group, running: running, ended: ended) else { return }
            inserts.append((spec.at, .block(spec.control)))
        }
        for (index, item) in items.enumerated() {
            guard case .message(let message) = item, message.role == "user", message.kind == nil else { continue }
            // The next message of the reader's ends this display turn.
            if let turn = opened { close(turn.index + 1 ..< index, group: turn.id, ended: true) }
            opened = (index, message.id)
        }
        if let turn = opened, turn.index + 1 < result.count { close(turn.index + 1 ..< result.count, group: turn.id, ended: complete) }
        for insert in inserts.reversed() { result.insert(insert.item, at: insert.at) }
        return result
    }

    /// Marks one turn's process rows and builds its control, or answers nil
    /// when this turn must not fold.
    private static func fold(_ items: inout [TranscriptItem], range: Range<Int>, group: String, running: String?,
                             ended: Bool) -> (at: Int, control: TranscriptBlock)? {
        guard !range.isEmpty else { return nil }
        // A turn still running keeps every row it has: the fold is what the end
        // of a turn does, never something a reader watches happen mid-reply.
        // Between two model requests of one turn every row is settled, so being
        // settled is not the test — the task the host is running is.
        for index in range {
            switch items[index] {
            case .block(let block): if block.live { return nil }
            case .message(let message): if message.isStreaming { return nil }
            }
            if let running, root(of: items[index]) == running { return nil }
        }
        // A page that stops short of the conversation's newest row may have
        // cut this turn anywhere. Only the task's own receipt, the last thing
        // a finished task writes, says it ended here.
        if !ended {
            let tail = range.last { index in
                if case .message(let message) = items[index], independent(message) { return false }
                return true
            }
            guard let tail, case .block(let receipt) = items[tail], receipt.presentation == .summary else { return nil }
        }
        // The answer is the reply the turn's last content belongs to, and it
        // must have said something and asked for nothing more. A reply that
        // made a call did not end its turn, wherever its words fall: the host
        // runs the call and asks the model again. A turn whose last content is
        // such a reply, or a result, stopped in its work — or the page cut it
        // there — and its narration is not an answer.
        guard let last = range.last(where: { content(items[$0]) }), case .block(let closing) = items[last] else { return nil }
        // A chronological reply is its response id; a legacy reply's rows
        // carry the reply itself.
        let answer = closing.responseID
        guard let answerRow = answer ?? closing.replies.first?.id else { return nil }
        func own(_ block: TranscriptBlock) -> Bool {
            answer.map { block.responseID == $0 } ?? (block.responseID == nil && block.replies.contains { $0.id == answerRow })
        }
        var spoke = false
        for index in range {
            guard case .block(let block) = items[index], own(block) else { continue }
            if block.replies.contains(where: { !($0.tools ?? []).isEmpty }) { return nil }
            if prose(block) { spoke = true }
        }
        guard spoke else { return nil }
        // Only the answer's own accounting line may follow it; another
        // request after it is work that came after the answer.
        for index in last + 1 ..< range.upperBound {
            if case .message(let message) = items[index], message.kind == "requestInfo", message.id != answerRow { return nil }
        }
        var spec = TurnFoldSpec(group: group, answerResponseID: answer ?? "")
        // Everything from the turn's first process row up to the answer, plus
        // whatever the answer itself had to do before it could speak.
        var members: [Int] = []
        var answerHeader: Int? = nil
        var textResponses = Set<String>()
        for index in range {
            switch items[index] {
            case .message(let message):
                if independent(message) { continue }
                if message.kind == "requestInfo", message.id == answerRow { continue }
                members.append(index)
            case .block(let block):
                if block.presentation == .summary || block.presentation == .turnFold { continue }
                // A legacy answer's words never fold.
                if block.presentation == .body, answer == nil, own(block) { continue }
                if let response = block.responseID, response == answer {
                    if block.presentation == .response { answerHeader = index; continue }
                    // The answer's words never fold.
                    if prose(block) { continue }
                }
                // Another reply that said something before the answer.
                if block.part != nil, prose(block), let response = block.responseID { textResponses.insert(response) }
                // A part row carries its call on its own message; a legacy
                // group carries the reply's whole run on the block.
                for tool in block.tools.isEmpty ? (block.message?.tools ?? []) : block.tools {
                    if TurnFoldSpec.isSubagent(tool.name) { spec.subagents += 1 } else { spec.toolCalls += 1 }
                }
                members.append(index)
            }
        }
        // An answer with no work under it has nothing to fold: a line that
        // opened onto the answer's own header would hide nothing.
        guard !members.isEmpty else { return nil }
        // The answer's own header line folds with the work it summarises: a
        // folded turn should read as one line and the answer, not as two
        // lines and the answer.
        if let answerHeader { members.append(answerHeader); members.sort() }
        spec.messages = textResponses.count
        for index in members {
            switch items[index] {
            case .message(var message): message.foldGroup = group; items[index] = .message(message)
            case .block(var block): block.foldGroup = group; items[index] = .block(block)
            }
        }
        var control = TranscriptBlock(id: "fold:" + group, key: "fold:" + group, turnID: group, message: nil,
                                      activity: [], tools: [], accounting: TurnAccounting(), startedAt: nil, endedAt: nil,
                                      modelMs: 0, toolMs: 0, live: false, turn: nil)
        control.presentation = .turnFold
        control.foldControl = group
        control.foldSummary = spec
        return (members[0], control)
    }

    /// A response's words, or a legacy reply's prose: the rows an answer is.
    private static func prose(_ block: TranscriptBlock) -> Bool {
        if let part = block.part { return ["text", "refusal"].contains(part.part.kind) && TaskTranscriptPlan.visible(part.text) }
        return block.presentation == .body && TaskTranscriptPlan.visible(block.message?.text ?? "")
    }
    /// Whether a row is something the turn did or said, as opposed to its
    /// receipts, its accounting and the rows no fold touches. Words that are
    /// only whitespace draw nothing and say nothing.
    private static func content(_ item: TranscriptItem) -> Bool {
        switch item {
        case .message(let message): return !independent(message) && message.kind != "requestInfo"
        case .block(let block):
            if block.presentation == .summary || block.presentation == .turnFold { return false }
            if let part = block.part, ["text", "refusal"].contains(part.part.kind) { return TaskTranscriptPlan.visible(part.text) }
            if block.presentation == .body { return TaskTranscriptPlan.visible(block.message?.text ?? "") }
            return true
        }
    }
    /// The task a row belongs to, from whatever named it.
    private static func root(of item: TranscriptItem) -> String? {
        switch item {
        case .message(let message): return message.taskRootID ?? message.turn
        case .block(let block): return block.turnID ?? block.message?.taskRootID ?? block.message?.turn
        }
    }
}
