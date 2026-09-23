import Foundation

/// One grouping rule for cold history and incremental presentation. Work never
/// owns a prose host; immutable source IDs own bodies throughout a stream.
enum TaskTranscriptPlan {
    /// `complete` says whether the page reaches the conversation's newest row.
    /// A page cut short of it may end in the middle of a turn, and that turn
    /// folds only on its own receipt that it ended.
    static func items(_ messages: [TranscriptMessage], lifecycle: TaskPresentationProjection?,
                      display: TranscriptDisplayMode = TranscriptDisplay.mode, complete: Bool = true) -> [TranscriptItem] {
        runs.lock(); plannedPages += 1; runs.unlock()
        return TranscriptTurnFold.apply(rows(messages, lifecycle: lifecycle), display: display,
                                        running: lifecycle?.active?.rootID, complete: complete)
    }
    /// Pages planned in this process. Test evidence for the readers that must
    /// not plan a whole page just to ask a question of it, such as a menu.
    static var planned: Int { runs.lock(); defer { runs.unlock() }; return plannedPages }
    private static let runs = NSLock()
    nonisolated(unsafe) private static var plannedPages = 0
    /// Whether text holds anything but whitespace: the negation of
    /// `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, without
    /// copying the text. The first visible character answers, where trimming
    /// copied a whole reply — twice more for the fold — on every plan.
    static func visible(_ text: String) -> Bool { text.unicodeScalars.contains { !whitespace.contains($0) } }
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    /// A request shorter than a twentieth of a second says nothing about its
    /// time, as a tool card's clock does not: "0.0s" tells the reader nothing.
    static let shortestShownDurationMs = 50.0
    /// The conversation as rows, before any end-of-turn fold.
    static func rows(_ messages: [TranscriptMessage], lifecycle: TaskPresentationProjection?) -> [TranscriptItem] {
        let sourceIDs = Set(messages.map(\.id))
        let operations = Set(messages.filter { $0.kind == "execution" }.compactMap(\.operationID))
        let messages = messages.filter {
            if $0.kind == "requestLedger", let source = $0.presentationSourceID, sourceIDs.contains(source) { return false }
            if $0.kind == "compaction", let operation = $0.operationID, operations.contains(operation) { return false }
            return true
        }.map { source -> TranscriptMessage in
            guard source.kind == "requestLedger" else { return source }
            var message = source; message.kind=nil; message.role="assistant"
            if message.responseTimeline?.terminal == nil { message.stopReason="interrupted" }
            return message
        }
        let evidence = (lifecycle?.recent ?? []) + (lifecycle?.active.map { [$0] } ?? [])
        let records = Dictionary(evidence.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let anchored = Dictionary(grouping:evidence.filter { $0.anchorSourceID != nil },by:{ $0.anchorSourceID! })
        let ending = Dictionary(grouping:evidence.filter { $0.terminal && $0.lastSourceID != nil },by:{ $0.lastSourceID! })
        var groups: [String: [TranscriptMessage]] = [:], keys: [String: String] = [:]
        var root: String?
        for message in messages {
            if message.role == "user" { root = message.taskRootID ?? message.turn ?? message.id }
            if root == nil, message.role == "assistant", message.kind == nil { root = message.taskRootID ?? message.turn ?? "unresolved-" + message.id }
            guard message.kind == nil, message.role != "system", let taskRoot = message.taskRootID ?? message.turn ?? root else { continue }
            let key = TaskPresentationRecord.identity(taskRoot, message.taskExecutionID ?? "unresolved")
            groups[key, default: []].append(message); keys[message.id] = key
        }
        // A call and its result are one card, in the place the call was made.
        // `cardCalls` are the calls that have such a card at all, so the local
        // record that the call started is not also a row — the card's own
        // status says that. `shownCalls` are the cards that carry the result
        // itself: its output, its outcome and its clock. A result the card
        // cannot show — a page read from a journal, whose cards hold only the
        // request — keeps its own row, and so does a result whose call is not
        // on this page at all.
        //
        // Both are keyed by the reply that made the call as well as the call:
        // providers reuse call ids, and a result belongs to one card — the
        // latest reply before it that made that call, as the helper pairs them
        // — never to every card that shares its id.
        var cardCalls = Set<String>(), shownCalls = Set<String>()
        for message in messages where message.role == "assistant" {
            guard let timeline = message.responseTimeline, timeline.supported else { continue }
            let cards = Dictionary((message.tools ?? []).map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
            for segment in timeline.segments where segment.part.kind == "toolArguments" {
                guard let call = segment.part.callID, let card = cards[call] else { continue }
                let occurrence = ToolOccurrence.key(message.id, call)
                cardCalls.insert(occurrence)
                if !["preparing","prepared","running","recorded"].contains(card.state) { shownCalls.insert(occurrence) }
            }
        }
        var issuers: [String: String] = [:]
        func occurrence(_ call: String) -> String? { issuers[call].map { ToolOccurrence.key($0, call) } }
        var result: [TranscriptItem] = [], opened = Set<String>(), summaries = Set<String>()
        func block(_ key: String, _ rows: [TranscriptMessage], kind: TranscriptBlock.Presentation) -> TranscriptBlock {
            let replies = rows.filter { $0.role == "assistant" }, tools = replies.flatMap { $0.tools ?? [] }
            var block = TranscriptBlock(id:key, key:key, turnID:rows.first?.taskRootID ?? rows.first?.turn,
                message:nil, activity:replies, tools:tools, accounting:TranscriptActivity.aggregate(replies),
                startedAt:rows.first?.at, endedAt:rows.last?.at, modelMs:replies.reduce(0) { $0 + ($1.modelMs ?? 0) },
                toolMs:tools.reduce(0) { $0 + ($1.durationMs ?? 0) }, live:false, turn:nil)
            block.presentation = kind
            return block
        }
        func openWork(_ key: String) {
            // Only an actual accepted task without any response needs a pending
            // marker. Returned work stays at each response's own position.
            guard let task = records[key], !task.terminal,
                  groups[key]?.contains(where: { $0.role == "assistant" }) != true,
                  opened.insert(key).inserted else { return }
            var work = block("work:" + key, [], kind: .work)
            work.task = task; work.live = true; work.taskSummary = summary([],task:task,rootShown:sourceIDs.contains(task.rootID))
            result.append(.block(work))
        }
        func endWork(_ task: TaskPresentationRecord) {
            guard task.terminal, summaries.insert(task.key).inserted else { return }
            var footer = block("summary:" + task.key, [], kind:.summary)
            footer.task = task; footer.turn = summary(groups[task.key] ?? [],task:task,rootShown:sourceIDs.contains(task.rootID))
            result.append(.block(footer))
        }
        for message in messages {
            // Explicit retries have no second user-message source. Their
            // durable anchor keeps a work row present even if dispatch fails
            // before any assistant content arrives.
            defer {
                for task in ending[message.id] ?? [] { endWork(task) }
                for task in anchored[message.id] ?? [] where task.key != keys[message.id] {
                    openWork(task.key)
                    if task.lastSourceID == message.id { endWork(task) }
                }
            }
            // The reply a later result or start record belongs to.
            if message.role == "assistant" { for tool in message.tools ?? [] { issuers[tool.id] = message.id } }
            guard let key = keys[message.id] else {
                // A call and its result are one card, at the position the call
                // was made: a result whose call is shown there is that same
                // result, and the record that the call started is what the
                // card's own status says. Neither becomes a row of its own.
                if message.kind == "toolResult" || message.role == "tool",
                   let call = message.toolCallID, let card = occurrence(call), shownCalls.contains(card) { continue }
                if message.kind == "execution", let call = startedCall(message), let card = occurrence(call), cardCalls.contains(card) { continue }
                result.append(.message(message))
                continue
            }
            if message.role == "user" { result.append(.message(message)) }
            openWork(key)
            if message.role == "tool" {
                if let call = message.toolCallID, let card = occurrence(call), shownCalls.contains(card) { continue }
                var resultMessage = message; resultMessage.kind = "toolResult"; result.append(.message(resultMessage))
            }
            if message.role == "assistant" {
                if let timeline = message.responseTimeline, timeline.supported, !timeline.segments.isEmpty {
                    let shown = timeline.segments.filter { !$0.text.isEmpty || ["toolArguments","opaque","status"].contains($0.part.kind) }
                    // One header line per response, above its parts: what the
                    // response did, and the one control that folds all of it.
                    var header = block("response:" + message.id, [], kind: .response)
                    var line = message; line.text = ""; line.thinking = nil; line.tools = nil; line.responseTimeline = nil
                    header.message = line; header.id = message.id; header.responseID = message.id
                    header.turnID = message.taskRootID ?? message.turn
                    header.live = message.isStreaming
                    header.responseSummary = responseLine(message, parts: shown.count,
                                                         foldable: shown.contains { !["text","refusal"].contains($0.part.kind) })
                    result.append(.block(header))
                    for part in shown {
                        // A call's card belongs to the position the call was
                        // made at. Only that one card travels with the row, so
                        // an unrelated card's output never re-measures it.
                        let card = part.part.callID.flatMap { call in (message.tools ?? []).first { $0.id == call } }
                        // A row holding a card is a work row placed in the
                        // response's own order: what the reader opens in it is
                        // keyed by the reply that made the call, so two
                        // responses that reuse a provider call id do not open
                        // each other's card, and asking for that call's full
                        // arguments still names the reply and the call.
                        var row = block("part:" + part.id, [], kind: card == nil ? .timeline : .work)
                        var source = message
                        source.responseTimeline = nil; source.text = part.text; source.thinking = nil
                        source.tools = card.map { [$0] }
                        source.accounting = nil; source.at = nil; source.modelMs = nil; source.stopReason = nil; source.toolCallCount = nil
                        // Stop keeps the words that had arrived. The last of
                        // them carries the chip that says why they end there,
                        // so the reason sits under the partial answer rather
                        // than in a line about the request.
                        if ["text", "refusal"].contains(part.part.kind), part.id == shown.last(where: { ["text", "refusal"].contains($0.part.kind) })?.id,
                           message.stopReason == "interrupted" || timeline.terminal == "interrupted" {
                            source.stopReason = "interrupted"
                        }
                        source.state = message.isStreaming && part.state == "streaming" ? "streaming" : "complete"
                        source.truncated = part.truncated
                        row.message = source; row.id = message.id; row.part = part; row.live = source.isStreaming
                        row.responseID = message.id; row.turnID = message.taskRootID ?? message.turn
                        result.append(.block(row))
                    }
                    // Request accounting is separate from immutable part bodies.
                    var info = message; info.text = ""; info.thinking = nil; info.tools = nil; info.responseTimeline = nil
                    info.kind = "requestInfo"; info.detail = timeline.omittedEvents > 0 ? "Partial event coverage · \(timeline.omittedEvents) further events omitted" : timeline.coverage == "canonical" ? "Canonical response order · arrival order unavailable" : nil
                    result.append(.message(info))
                } else {
                    // Flat legacy fields cannot establish intra-response order.
                    // Keep one honest local group at this response position.
                    if !(message.thinking ?? "").isEmpty || !(message.tools ?? []).isEmpty {
                        var legacy = block("legacy:" + message.id, [message], kind: .work)
                        legacy.live = message.isStreaming; legacy.taskSummary = summary([message],task:nil)
                        result.append(.block(legacy))
                    }
                    if visible(message.text) {
                        var body = block(TranscriptRenderIdentity.block(message.id).key, [], kind:.body)
                        var prose = message
                        prose.at = nil; prose.modelMs = nil; prose.tools = nil; prose.thinking = nil; prose.accounting = nil; prose.toolCallCount = nil
                        body.message = prose; body.id = message.id; body.live = message.isStreaming
                        result.append(.block(body))
                    }
                    if (message.accounting?.requests ?? 0) > 0 || message.stopReason != nil {
                        var info = message; info.text = ""; info.thinking = nil; info.tools = nil
                        info.kind = "requestInfo"; info.detail = "Legacy response · exact part order unavailable"
                        result.append(.message(info))
                    }
                }
            }
        }
        return result
    }

    /// The call a local tool-start record belongs to, when it names one. Other
    /// operations' execution records — a compaction stage — name none and keep
    /// their own row.
    static func startedCall(_ message: TranscriptMessage) -> String? {
        message.responseTimeline?.segments.compactMap { $0.part.callID }.first
    }

    /// The one line a response reads as when the reader has folded it: what it
    /// did, how long the request took and what the gateway reported. Computed
    /// from the settled fields of the reply, never from a part's growing text,
    /// so a header row keeps its height while the response streams.
    static func responseLine(_ message: TranscriptMessage, parts: Int, foldable: Bool = false) -> ResponseLine {
        let reasoned = visible(message.thinking ?? "")
        let calls = ToolCallSummary(tools: message.tools ?? [])
        let work = calls.label(reasoned: reasoned) ?? (visible(message.text) ? "Answered" : "Response")
        let duration = DurationObservation.valid(message.modelMs).flatMap { $0 >= shortestShownDurationMs ? TranscriptActivity.formatDuration($0) : nil }
        let figures: String? = message.accounting.map { TranscriptActivity.accountingPresentation($0).summary }.flatMap { $0.isEmpty ? nil : $0 }
        return ResponseLine(work: work, duration: duration, figures: figures, parts: parts, foldable: foldable)
    }

    /// `rootShown` says the task's own question is on the page. A retried
    /// execution has no user row of its own — its question is the first
    /// execution's — so its rows alone cannot say whether the page holds it.
    static func summary(_ rows: [TranscriptMessage], task: TaskPresentationRecord?, rootShown: Bool = false) -> TurnSummary {
        let replies = rows.filter { $0.role == "assistant" }, tools = replies.flatMap { $0.tools ?? [] }
        let calls = ToolCallSummary(rows:replies)
        // Partial: the question is above the loaded history, or the page holds
        // fewer of the task's replies than it made.
        let partial = task == nil || !(rootShown || rows.first?.id == task?.rootID) || replies.count < (task?.replies ?? 0)
        let started = task == nil ? rows.first?.at : task?.startedAtUnixMs, ended = task?.endedAtUnixMs
        var summary = TurnSummary(replies:task?.replies ?? replies.count, tools:task?.issuedCalls ?? calls.total,
            startedAt:started, endedAt:ended, elapsedMs:task?.elapsedMilliseconds(),
            modelMs:task?.modelMs ?? replies.reduce(0) { $0 + ($1.modelMs ?? 0) },
            toolMs:task?.toolMs ?? tools.reduce(0) { $0 + ($1.durationMs ?? 0) }, live:task.map { !$0.terminal } ?? false,
            files:TranscriptActivity.changedFiles(tools), partial:partial, accounting:TranscriptActivity.aggregate(rows),
            requests:rows.filter { $0.role == "assistant" || $0.accounting != nil }, current:nil, notice:task?.detail)
        summary.toolCountPartial = task == nil && (calls.partial || partial)
        summary.taskKey = task?.key; summary.taskRootID = task?.rootID
        summary.phase = task?.phase; summary.outcome = task?.outcome; summary.errorCode = task?.errorCode
        summary.liveStartedUptimeMs = task.flatMap { $0.terminal ? nil : $0.startedAt }
        if let name = task?.currentTool { summary.current = ToolView(id:"current", name:name, state:"running", input:"", output:"", truncated:false) }
        return summary
    }

    static func live(_ lifecycle: TaskPresentationProjection?, messages: [TranscriptMessage] = []) -> TurnSummary? {
        if let task = lifecycle?.active {
            // The lifecycle owns execution identity, not accounting. Join only
            // this execution's rows, including interim reports and tool rounds.
            // A retry or another loaded turn must never donate its figures.
            let rows = messages.filter { $0.taskRootID == task.rootID && $0.taskExecutionID == task.executionID }
            return summary(rows, task:task, rootShown:messages.contains { $0.id == task.rootID })
        }
        guard let phase = lifecycle?.utilityPhase else { return nil }
        var result = summary([], task:nil); result.live = true; result.phase = phase
        result.taskKey = "utility:" + (lifecycle?.epoch ?? ""); return result
    }

    /// Fragments can share a single pending presentation. Changes in identity,
    /// phase, outcome, card membership or first real prose flush immediately.
    static func cosmetic(from old: [TranscriptMessage], to new: [TranscriptMessage]) -> Bool {
        guard old.count == new.count else { return false }
        for (lhs, rhs) in zip(old, new) {
            // Streaming usually changes one row. Unchanged history needs no
            // copies, tool/timeline arrays or fragment normalization.
            if lhs == rhs { continue }
            var a = lhs, b = rhs
            guard a.id == b.id, a.state == b.state, a.text.isEmpty == b.text.isEmpty,
                  a.tools?.map(\.id) == b.tools?.map(\.id), a.tools?.map(\.state) == b.tools?.map(\.state) else { return false }
            // Edits and settled-source changes are semantic; only fragments
            // of an ongoing reply/tool may wait for the next presentation.
            if !a.isStreaming && !(a.tools ?? []).contains(where: { ["preparing", "running"].contains($0.state) }), a != b { return false }
            guard a.responseTimeline?.segments.map(\.id) == b.responseTimeline?.segments.map(\.id),
                  a.responseTimeline?.segments.map(\.state) == b.responseTimeline?.segments.map(\.state),
                  a.responseTimeline?.terminal == b.responseTimeline?.terminal else { return false }
            a.responseTimeline = b.responseTimeline
            a.text = b.text; a.thinking = b.thinking
            if a.tools != nil { for index in a.tools!.indices { a.tools![index].input = b.tools![index].input; a.tools![index].output = b.tools![index].output; a.tools![index].inputBytes = b.tools![index].inputBytes } }
            // Equivalence of all remaining fields includes warnings and usage.
            b.accounting = a.accounting
            guard a == b else { return false }
        }
        return true
    }
}
