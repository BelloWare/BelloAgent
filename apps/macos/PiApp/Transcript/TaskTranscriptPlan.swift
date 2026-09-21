import Foundation

/// One grouping rule for cold history and incremental presentation. Work never
/// owns a prose host; immutable source IDs own bodies throughout a stream.
enum TaskTranscriptPlan {
    static func items(_ messages: [TranscriptMessage], lifecycle: TaskPresentationProjection?) -> [TranscriptItem] {
        let evidence = (lifecycle?.recent ?? []) + (lifecycle?.active.map { [$0] } ?? [])
        let records = Dictionary(evidence.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let anchored = Dictionary(grouping:evidence.filter { $0.anchorSourceID != nil },by:{ $0.anchorSourceID! })
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
            // A legacy input with no reply is not proof that execution ever
            // began. New accepted tasks carry explicit evidence immediately.
            guard records[key] != nil || groups[key]?.contains(where: { $0.role == "assistant" }) == true else { return }
            guard opened.insert(key).inserted else { return }
            let task = records[key], rows = groups[key] ?? []
            var work = block("work:" + key, rows, kind:.work)
            work.task = task; work.live = task.map { !$0.terminal } ?? false
            work.taskSummary = summary(rows,task:task)
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
                for task in anchored[message.id] ?? [] where task.key != keys[message.id] {
                    openWork(task.key)
                    if task.lastSourceID == message.id { endWork(task) }
                }
            }
            guard let key = keys[message.id] else {
                if message.role != "tool" { result.append(.message(message)) }
                continue
            }
            let task = records[key]
            if message.role == "user" { result.append(.message(message)) }
            openWork(key)
            if message.role == "assistant", !message.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                // Metadata changes cannot invalidate this body or insert a
                // disclosure/action header inside it. Inspect uses its source ID.
                var body = block(TranscriptRenderIdentity.block(message.id).key, [], kind:.body)
                var prose = message
                prose.at = nil; prose.modelMs = nil; prose.tools = nil; prose.thinking = nil; prose.accounting = nil; prose.toolCallCount = nil
                body.message = prose; body.id = message.id; body.live = message.isStreaming
                result.append(.block(body))
            }
            if let task, task.lastSourceID == message.id { endWork(task) }
        }
        return result
    }

    static func summary(_ rows: [TranscriptMessage], task: TaskPresentationRecord?) -> TurnSummary {
        let replies = rows.filter { $0.role == "assistant" }, tools = replies.flatMap { $0.tools ?? [] }
        let calls = ToolCallSummary(rows:replies)
        let partial = task == nil || rows.first?.id != task?.rootID || replies.count < (task?.replies ?? 0)
        let started = task?.startedAt ?? rows.first?.at, ended = task?.endedAt
        var summary = TurnSummary(replies:task?.replies ?? replies.count, tools:task?.issuedCalls ?? calls.total,
            startedAt:started, endedAt:ended, elapsedMs:started.flatMap { s in ended.map { max(0, $0-s) } },
            modelMs:task?.modelMs ?? replies.reduce(0) { $0 + ($1.modelMs ?? 0) },
            toolMs:task?.toolMs ?? tools.reduce(0) { $0 + ($1.durationMs ?? 0) }, live:task.map { !$0.terminal } ?? false,
            files:TranscriptActivity.changedFiles(tools), partial:partial, accounting:TranscriptActivity.aggregate(replies),
            requests:replies, current:nil, notice:task?.detail)
        summary.toolCountPartial = task == nil && (calls.partial || partial)
        summary.taskKey = task?.key; summary.phase = task?.phase; summary.outcome = task?.outcome
        if let name = task?.currentTool { summary.current = ToolView(id:"current", name:name, state:"running", input:"", output:"", truncated:false) }
        return summary
    }

    static func live(_ lifecycle: TaskPresentationProjection?) -> TurnSummary? {
        if let task = lifecycle?.active { return summary([], task:task) }
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
            a.text = b.text; a.thinking = b.thinking
            if a.tools != nil { for index in a.tools!.indices { a.tools![index].input = b.tools![index].input; a.tools![index].output = b.tools![index].output; a.tools![index].inputBytes = b.tools![index].inputBytes } }
            // Equivalence of all remaining fields includes warnings and usage.
            b.accounting = a.accounting
            guard a == b else { return false }
        }
        return true
    }
}
