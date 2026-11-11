import Foundation

public struct CompactionPolicy: Sendable {
    /// Ours: physical attempts a compaction's one summary request may use,
    /// its transient retries included: room for the most retries Settings
    /// allows (`RetrySettings.retryRange`), so the setting governs.
    public var maximumAttempts = 11
    /// Pi's compaction reserve and recent-context target (settings-manager.ts).
    public var reserveTokens = 16_384
    public var keepRecentTokens = 20_000
    /// Ours: the least a summary request may be allowed when the intact
    /// context leaves no room for the whole allowance (`summaryTokens`):
    /// pi's smallest summary cap, 0.5 x its reserve. Below it nothing is sent.
    public var minimumSummaryTokens = 8_192
    public init() {}
    /// The threshold settings for one window. From 32,768 tokens up this is
    /// pi's reserve; a smaller window keeps half of itself for the
    /// conversation, where pi's fixed reserve would compact after every reply.
    func settings(autoCompaction: Bool, contextWindow: Int) -> PiContext.Settings {
        PiContext.Settings(enabled: autoCompaction, reserveTokens: min(reserveTokens, contextWindow / 2), keepRecentTokens: keepRecentTokens)
    }
    /// Pi's recent tail. A window too small for it keeps at most half of what
    /// triggers compaction, so compacting always frees room.
    func keepRecentTokens(contextWindow: Int) -> Int {
        max(0, min(keepRecentTokens, (contextWindow - settings(autoCompaction: true, contextWindow: contextWindow).reserveTokens) / 2))
    }
    /// One generation allowance, including reasoning; never the normal turn's cap.
    func summaryTokens(for profile: Profile) -> Int {
        min(16_384, profile.modelOutputLimit ?? 16_384, profile.contextWindow / 4)
    }
    func visibleTarget(for profile: Profile, inputTokens: Int? = nil) -> Int {
        min(3_000, max(1, summaryTokens(for: profile) / 4), max(1, (inputTokens ?? 12_000) / 4))
    }
    func summaryProfile(_ original: Profile, cap: Int) throws -> Profile {
        guard cap >= ProviderClient.minimumOutputTokens, cap < original.contextWindow else {
            throw AgentError("compact_budget", "This context window cannot reserve the minimum summary output allowance.")
        }
        var raw = original.raw
        raw["maxOutputTokens"] = JSON(cap)
        raw["outputCap"] = JSON(cap)
        return try original.replacing(raw)
    }
    /// Reserve the appended instruction, summary generation, dispatch margin,
    /// and a growth buffer before the next complete model/tool boundary.
    func trigger(profile: Profile, instructionTokens: Int) throws -> Int {
        let generation = summaryTokens(for: profile)
        let reserved = PiContext.sum([max(profile.maxOutput, PiContext.sum([generation, instructionTokens])),
            RequestContextCount.safetyMargin(contextWindow: profile.contextWindow), min(max(0, reserveTokens), profile.contextWindow / 4)])
        guard instructionTokens >= 0, generation >= ProviderClient.minimumOutputTokens, reserved < profile.contextWindow else {
            throw AgentError("compact_budget", "This context window cannot fit the checkpoint instruction and summary reserves.")
        }
        return profile.contextWindow - reserved
    }

}

struct ReplayGroup: Sendable {
    let messages: [ChatMessage]
    var id: String { messages[0].id }
}

/// Pi's CompactionPreparation over the helper's context.
struct CompactionPlan: Sendable {
    /// The previous checkpoint, whose summary is pi's previousSummary.
    let previous: ChatMessage?
    /// Inputs replayed verbatim ahead of `kept`. Pi replays none; a checkpoint
    /// written before 0.1.90 may have, and its record still lists them.
    let protected: [ChatMessage]
    /// Replaced history, oldest first. The single summary sees the whole context.
    let history: [ChatMessage]
    /// The replaced part of a split turn; no separate summary request is made.
    let turnPrefix: [ChatMessage]
    let kept: [ReplayGroup]
    var keptMessages: [ChatMessage] { protected + kept.flatMap(\.messages) }
    /// What leaves the active context.
    var summarized: [ChatMessage] {
        let replayed=Set(protected.map(\.id))
        return (history+turnPrefix).filter { !replayed.contains($0.id) }
    }
    var previousSummary: String? { previous.map(CompactionCheckpoint.summaryText) }
}

enum CompactionPlanner {
    /// Occurrence ownership is local to each assistant group. Reused call IDs
    /// on later responses are valid; orphan/duplicate results are not.
    static func groups(_ input: [ChatMessage]) throws -> [ReplayGroup] {
        let messages=input.filter(\.replayEligible)
        guard Set(messages.map(\.id)).count == messages.count else { throw damaged("Duplicate active message identities") }
        var result: [ReplayGroup]=[], index=0
        while index < messages.count {
            let message=messages[index]
            guard message.role != "toolResult" else { throw damaged("Tool result has no owning assistant in active context") }
            index += 1
            let calls=message.role == "assistant" ? message.content.filter { $0["type"].text == "toolCall" } : []
            var pending=Set<String>()
            for call in calls {
                guard let id=call["id"].text, !id.isEmpty, pending.insert(id).inserted else { throw damaged("Invalid call identities in an assistant group") }
            }
            var group=[message]
            while !pending.isEmpty {
                guard index < messages.count, messages[index].role == "toolResult", let id=messages[index].toolCallId,
                      pending.remove(id) != nil else { throw damaged("An assistant/tool batch is incomplete; inspect its effects before compacting") }
                // Recorded outcomes and tool text are historical data for the
                // summary, not prerequisites for compacting a complete group.
                group.append(messages[index]); index += 1
            }
            result.append(ReplayGroup(messages:group))
        }
        return result
    }

    /// What pi's prepareCompaction reads: the previous summary and the
    /// messages since it. Inputs a checkpoint written before 0.1.90 replayed
    /// ahead of its kept messages (`carried`) are not at their place in the
    /// turn; they are history now. `newSince` is the first group appended after
    /// the previous checkpoint, where pi's session path holds that checkpoint.
    struct Source: Sendable {
        let previous: ChatMessage?
        let carried: [ChatMessage]
        let body: [ReplayGroup]
        let protectedIDs: Set<String>
        var newSince: Int?
    }
    /// `taskInputTokens` is how much of the running task's own input is
    /// replayed as written (see below); 0 replays none, as pi does.
    static func source(context: [ChatMessage], taskRoot: String?, taskInputTokens: Int = 0) throws -> Source {
        let active=context.filter(\.replayEligible)
        let previous=active.first.flatMap { $0.kind == "compaction" ? $0 : nil }
        let since=Array(active.dropFirst(previous == nil ? 0 : 1))
        let replayed=Set(previous?.compaction?["protectedIDs"].list.compactMap(\.text) ?? [])
        let carried=since.prefix { $0.role == "user" && replayed.contains($0.id) }
        let body=try groups(Array(since.dropFirst(carried.count)))
        // The rows the previous checkpoint kept come first; the rows after them
        // were appended after it.
        let kept=Set(previous?.compaction?["keptIDs"].list.compactMap(\.text) ?? [])
        let newSince=previous == nil ? nil : body.firstIndex { !kept.contains($0.id) } ?? body.count
        var protected = Set<String>()
        if let latestUser = since.lastIndex(where: { $0.role == "user" }) {
            let input = since[latestUser]
            let answered = since[(latestUser + 1)...].contains { $0.role == "assistant" }
            if !answered || !(input.userInput?["skills"].list.isEmpty ?? true) { protected.insert(input.id) }
        }
        // Steering belongs to the current task and must not replace its
        // original explicit skill selection with summary prose. Preserve every
        // skill-bearing input of that task, even after a later steering message.
        // Ours (owner, 2026-11-11: after a compaction "it stopped"): the
        // running task's request and the messages that steered it stay as
        // written, newest first within `taskInputTokens`, as Codex keeps the
        // recent user messages beside its summary. A summary of a request is
        // not the request: compacted between tool rounds, the model went on
        // (or stopped) without what it had been asked. One too long for the
        // allowance is summarized, as before. Mail from another agent is not
        // the task's request, unless it started the task (a sub-agent's).
        // Only while the task is in flight: once a reply has ended it, its
        // request is history, and replaying it would read as asked again.
        if let taskRoot, since.last.map({ $0.role != "assistant" }) == true {
            var room=taskInputTokens
            for input in since.reversed() where input.role == "user" && (input.taskRootID == taskRoot || input.id == taskRoot) {
                if !(input.userInput?["skills"].list.isEmpty ?? true) { protected.insert(input.id) }
                guard input.id == taskRoot || input.nativeAgentDelivery == nil, !protected.contains(input.id) else { continue }
                let tokens=PiContext.estimateTokens(input)
                if tokens <= room { protected.insert(input.id); room -= tokens }
            }
        }
        if let permission = since.last(where: { $0.contextNote != nil }) { protected.insert(permission.id) }
        return Source(previous:previous,carried:Array(carried),body:body,protectedIDs:protected,newSince:newSince)
    }

    /// findCutPoint: walking back from the newest message by pi's
    /// estimateTokens, the first group start at or after the message that
    /// reaches `keepRecentTokens`; a tool result stays with its call. 0 keeps
    /// everything. Pi's walk passes the previous checkpoint where its session
    /// path holds it, after the rows it kept, and counts its summary there.
    /// Ours: a tool batch no reply has answered yet is the step in flight,
    /// and is kept even when its results alone pass the target (pi keeps it
    /// too, and then cannot compact). The model asked for those results one
    /// request ago and has not read them: summarizing them with everything
    /// else left the next request a summary and nothing to go on with. The
    /// planner still moves the cut past a batch too large to fit (`prepare`).
    /// `keepUnanswered` is false after a gateway's context rejection, where
    /// the estimate has just been wrong and the most is summarized.
    static func cut(_ body: [ReplayGroup], keepRecentTokens: Int, previous: (index: Int, tokens: Int)? = nil, keepUnanswered: Bool = true) -> Int {
        var used=0
        for index in body.indices.reversed() {
            for (offset,message) in body[index].messages.enumerated().reversed() {
                let tokens=PiContext.estimateTokens(message)
                guard tokens > 0 else { continue }
                used=PiContext.sum([used,tokens])
                guard used >= keepRecentTokens else { continue }
                if offset == 0 { return index }
                let answered = !keepUnanswered || body[(index+1)...].contains { $0.messages[0].role == "assistant" }
                return answered ? index+1 : index
            }
            // The previous checkpoint sits just before the first new group.
            if let previous, previous.index == index, previous.tokens > 0 {
                used=PiContext.sum([used,previous.tokens])
                if used >= keepRecentTokens { return index }
            }
        }
        return 0
    }
    /// The previous checkpoint's place and size in pi's walk: its summary text
    /// over four characters (estimateTokens of a compactionSummary message).
    static func previousPosition(_ source: Source) -> (index: Int, tokens: Int)? {
        guard let previous=source.previous, let index=source.newSince, index < source.body.count else { return nil }
        return (index, PiContext.tokens(chars:CompactionCheckpoint.summaryText(previous).utf16.count))
    }

    /// Pi's split: a cut group that does not start a turn splits the turn
    /// begun by the last turn start before it. Current-task inputs before the
    /// cut are summarized in place for context and also replayed verbatim.
    static func plan(_ source: Source, cut: Int) -> CompactionPlan {
        let body=source.body, cut=min(max(0,cut),body.count)
        func startsTurn(_ group: ReplayGroup) -> Bool { !["assistant","toolResult"].contains(group.messages[0].role) }
        let turnStart=cut < body.count && !startsTurn(body[cut]) ? body[..<cut].lastIndex(where:startsTurn) : nil
        let before=source.carried+body[..<cut].flatMap(\.messages)
        return CompactionPlan(previous:source.previous,protected:before.filter { source.protectedIDs.contains($0.id) },
            history:source.carried.filter { !source.protectedIDs.contains($0.id) }+body[..<(turnStart ?? cut)].flatMap(\.messages),
            turnPrefix:turnStart.map { body[$0..<cut].flatMap(\.messages) } ?? [],kept:Array(body[cut...]))
    }

    /// Validate the actual Responses projection as well as native grouping.
    static func validateRequest(_ request: JSON) throws {
        var pending=Set<String>()
        for item in request["input"].list {
            if item["type"].text == "function_call" {
                guard let id=item["call_id"].text, pending.insert(id).inserted else { throw damaged("Repeated unresolved provider call") }
            } else if item["type"].text == "function_call_output" {
                guard let id=item["call_id"].text, pending.remove(id) != nil else { throw damaged("Orphan provider tool output") }
            }
        }
        guard pending.isEmpty else { throw damaged("Provider replay omits required tool results") }
    }

    static func damaged(_ reason: String) -> AgentError { AgentError("compact_unsafe",reason) }
}

struct PreparedCompaction: Sendable {
    let before: RequestContextCount
    let profile: Profile
    let plan: CompactionPlan
    let messages: [ChatMessage]
    let replacedIDs: [String]
    let fingerprint: String
}
extension CompactionPlanner {
    static func prepare(frozen: [ChatMessage], profile: Profile, instructions: String, definitions: [ToolDefinition],
                        sessionID: String, cacheSessionID: String, taskRoot: String?, policy: CompactionPolicy,
                        reason: String, focus: String?) throws -> PreparedCompaction {
        try Task.checkCancellation()
        func body(_ messages: [ChatMessage]) throws -> JSON {
            try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:definitions,sessionID:sessionID,cacheSessionID:cacheSessionID)
        }
        func count(_ messages: [ChatMessage], reported: Bool = false, request: JSON? = nil) throws -> RequestContextCount {
            try RequestContextCounter().count(messages:messages,profile:profile,request:request ?? body(messages),reportedUsage:reported)
        }
        let frozenBody=try body(frozen)
        let attemptKey=try RequestContextCounter.fingerprint(frozenBody,profile:profile)
        let before=try count(frozen,request:frozenBody)
        let visibleTarget=policy.visibleTarget(for:profile,inputTokens:before.requestTokens)
        let cap=policy.summaryTokens(for:profile)
        let summaryProfile=try policy.summaryProfile(profile,cap:cap)
        let recent=policy.keepRecentTokens(contextWindow:profile.contextWindow), recovering=reason == "context-rejection"
        let keep=recovering ? min(recent,PiContext.messageTokens(frozen)/2) : recent
        // `replaying`: the running task's inputs and the batch in flight stay
        // as written (`source`, `cut`); without it, pi's rules alone.
        func planned(replaying: Bool) throws -> (Source, Int) {
            let source=try CompactionPlanner.source(context:frozen,taskRoot:taskRoot,taskInputTokens:replaying ? recent : 0)
            return (source,CompactionPlanner.cut(source.body,keepRecentTokens:keep,previous:previousPosition(source),keepUnanswered:replaying))
        }
        var replaying = !recovering
        var (source,cut)=try planned(replaying:replaying)
        var plan=CompactionPlanner.plan(source,cut:cut)
        let unchanged=source.previous != nil && (source.newSince ?? 0) >= source.body.count
        var placeholder=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+String(repeating:"s",count:cap*4))])
        placeholder.kind="compaction"
        let projection=try ProviderClient.responsesProjection(frozen,instructions:instructions,profile:profile)
        func hasRoom(_ plan: CompactionPlan) throws -> Bool {
            let full=try count([placeholder]+plan.keptMessages)
            guard full.fits else { return false }
            if reason != "manual" {
                let boundary=try CompactionSourceBuilder.boundary(projection,messages:frozen,keptIDs:Set(plan.keptMessages.map(\.id)))
                let instruction=CompactionSourceBuilder.instruction(boundary:boundary,focus:focus,visibleTarget:visibleTarget)
                let cost=RequestContextCounter.inputTokens([["role":"user","content":.array(ProviderClient.userContent(instruction,images:false))]])
                return full.requestTokens < (try policy.trigger(profile:profile,instructionTokens:cost))
            }
            // Avoid spending a manual summary just to replace a tiny initial
            // user message while retaining every large answer. This is only
            // planning; the actual summary must still pass fit and progress.
            var expected=placeholder
            expected.content=[textBlock(CompactionCheckpoint.replayPrefix+String(repeating:"s",count:visibleTarget*4))]
            return try count([expected]+plan.keptMessages).requestTokens < before.requestTokens
        }
        // What is replayed as written must still leave something to
        // summarize that frees room; where it would not, pi's cut stands.
        func frees(_ plan: CompactionPlan) throws -> Bool {
            guard !plan.summarized.isEmpty else { return false }
            var expected=placeholder
            expected.content=[textBlock(CompactionCheckpoint.replayPrefix+String(repeating:"s",count:visibleTarget*4))]
            let after=try count([expected]+plan.keptMessages).requestTokens
            return PiContext.sum([after,RequestContextCount.safetyMargin(contextWindow:profile.contextWindow)]) <= before.requestTokens
        }
        if replaying, try !frees(plan) { replaying=false; (source,cut)=try planned(replaying:false); plan=CompactionPlanner.plan(source,cut:cut) }
        // Only move the boundary BEFORE the request. The summarizer sees
        // every source, including the unchanged tail, under this exact cut.
        func advance() throws {
            while !unchanged, cut<source.body.count {
                try Task.checkCancellation()
                if try hasRoom(plan) { break }
                cut += 1; plan=CompactionPlanner.plan(source,cut:cut)
            }
        }
        try advance()
        // The task's inputs are replayed by choice, not required: where no
        // cut leaves room beside them (a request near the replay allowance in
        // a small window passes the trigger with the summary alone), pi's
        // rules plan the checkpoint, as before the inputs were replayed.
        if replaying, !unchanged, try plan.summarized.isEmpty || !hasRoom(plan) {
            replaying=false; (source,cut)=try planned(replaying:false); plan=CompactionPlanner.plan(source,cut:cut)
            try advance()
        }
        guard !unchanged, !plan.summarized.isEmpty else {
            throw AgentError("compact_unavailable", unchanged ? "Already compacted: nothing has been added since the last compaction." : "Nothing useful to compact while keeping the recent history and required inputs intact.")
        }
        guard try count([placeholder]+plan.keptMessages).fits else {
            throw AgentError("compact_budget", "Required retained inputs, instructions, tools and the summary allowance cannot fit beside the normal output reserve. Original context is unchanged.")
        }
        guard try hasRoom(plan) else {
            throw AgentError(reason == "manual" ? "compact_unavailable" : "compact_budget", "No useful checkpoint can be planned while preserving required inputs and continuation headroom. Original context is unchanged.")
        }
        guard profile.raw["input"].list.contains("image") || !frozen.contains(where: { $0.content.contains { $0["type"].text == "image" } }) else {
            throw AgentError("unsupported_image", "Compaction cannot replace existing images with placeholders. Select an image-capable model; the context is unchanged.")
        }
        let description=try CompactionSourceBuilder.boundary(projection,messages:frozen,keptIDs:Set(plan.keptMessages.map(\.id)))
        let instruction=CompactionSourceBuilder.instruction(boundary:description,focus:focus,visibleTarget:visibleTarget)
        let summarizedIDs=(plan.previous.map { [$0.id] } ?? [])+plan.summarized.map(\.id)
        return PreparedCompaction(before:before,profile:summaryProfile,plan:plan,messages:frozen+[instruction],replacedIDs:summarizedIDs,fingerprint:attemptKey)
    }
}
