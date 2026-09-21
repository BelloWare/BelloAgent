import Foundation

/// One grouping rule for cold history and incremental presentation. Work never
/// owns a prose host; immutable source IDs own bodies throughout a stream.
enum TaskTranscriptPlan {
    static func items(_ messages: [TranscriptMessage], lifecycle: TaskPresentationProjection?) -> [TranscriptItem] {
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
            work.task = task; work.live = true; work.taskSummary = summary([],task:task)
            result.append(.block(work))
        }
        func endWork(_ task: TaskPresentationRecord) {
            guard task.terminal, summaries.insert(task.key).inserted else { return }
            var footer = block("summary:" + task.key, [], kind:.summary)
            footer.task = task; footer.turn = summary(groups[task.key] ?? [],task:task)
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
            guard let key = keys[message.id] else {
                result.append(.message(message))
                continue
            }
            if message.role == "user" { result.append(.message(message)) }
            openWork(key)
            if message.role == "tool" { var resultMessage = message; resultMessage.kind = "toolResult"; result.append(.message(resultMessage)) }
            if message.role == "assistant" {
                if let timeline = message.responseTimeline, timeline.supported, !timeline.segments.isEmpty {
                    for part in timeline.segments where !part.text.isEmpty || ["toolArguments","opaque","status"].contains(part.part.kind) {
                        var row = block("part:" + part.id, [], kind: .timeline)
                        var source = message
                        source.responseTimeline = nil; source.text = part.text; source.thinking = nil; source.tools = nil
                        source.accounting = nil; source.at = nil; source.modelMs = nil; source.stopReason = nil; source.toolCallCount = nil
                        source.state = message.isStreaming && part.state == "streaming" ? "streaming" : "complete"
                        source.truncated = part.truncated
                        row.message = source; row.id = message.id; row.part = part; row.live = source.isStreaming
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
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        var body = block(TranscriptRenderIdentity.block(message.id).key, [], kind:.body)
                        var prose = message
                        prose.at = nil; prose.modelMs = nil; prose.tools = nil; prose.thinking = nil; prose.accounting = nil; prose.toolCallCount = nil
                        body.message = prose; body.id = message.id; body.live = message.isStreaming
                        result.append(.block(body))
                    }
                    if message.accounting != nil || message.stopReason != nil {
                        var info = message; info.text = ""; info.thinking = nil; info.tools = nil
                        info.kind = "requestInfo"; info.detail = "Legacy response · exact part order unavailable"
                        result.append(.message(info))
                    }
                }
            }
        }
        return result
    }

    static func summary(_ rows: [TranscriptMessage], task: TaskPresentationRecord?) -> TurnSummary {
        let replies = rows.filter { $0.role == "assistant" }, tools = replies.flatMap { $0.tools ?? [] }
        let calls = ToolCallSummary(rows:replies)
        let partial = task == nil || rows.first?.id != task?.rootID || replies.count < (task?.replies ?? 0)
        let started = task == nil ? rows.first?.at : task?.startedAtUnixMs, ended = task?.endedAtUnixMs
        var summary = TurnSummary(replies:task?.replies ?? replies.count, tools:task?.issuedCalls ?? calls.total,
            startedAt:started, endedAt:ended, elapsedMs:task?.elapsedMilliseconds(),
            modelMs:task?.modelMs ?? replies.reduce(0) { $0 + ($1.modelMs ?? 0) },
            toolMs:task?.toolMs ?? tools.reduce(0) { $0 + ($1.durationMs ?? 0) }, live:task.map { !$0.terminal } ?? false,
            files:TranscriptActivity.changedFiles(tools), partial:partial, accounting:TranscriptActivity.aggregate(rows),
            requests:rows.filter { $0.role == "assistant" || $0.accounting != nil }, current:nil, notice:task?.detail)
        summary.toolCountPartial = task == nil && (calls.partial || partial)
        summary.taskKey = task?.key; summary.phase = task?.phase; summary.outcome = task?.outcome
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
            return summary(rows, task:task)
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
