import Foundation

public struct CompactionPolicy: Sendable {
    /// Ours: physical attempts a compaction's one summary request may use,
    /// its transient retries included: room for the most retries Settings
    /// allows (`RetrySettings.retryRange`), so the setting governs.
    public var maximumAttempts = 11
    /// Pi's compaction reserve (settings-manager.ts): the least room kept
    /// for growth before the next complete model/tool boundary.
    public var reserveTokens = 16_384
    /// Ours: the least a summary request may be allowed when the intact
    /// context leaves no room for the whole allowance (`summaryTokens`):
    /// pi's smallest summary cap, 0.5 x its reserve. Below it nothing is sent.
    public var minimumSummaryTokens = 8_192
    /// Ours (owner, 2026-11-11: "remove the cap directly"): pi's 20,000-token
    /// recent tail is gone. A compaction keeps the whole task in hand and
    /// summarizes what came before it, so these shares of the usable input
    /// (`usable`) decide when it runs and how much may stay:
    /// - `growthShare` of the window, at least pi's reserve, is kept free
    ///   for one round's growth while a task works;
    /// - a task starts by compacting once `taskStartShare` is in use, so
    ///   the compaction lands before the work rather than inside it;
    /// - what replaces the context may take `replacementShare`, which
    ///   leaves a real gap before the next compaction;
    /// - a task too large for that keeps what it must and its newest
    ///   rounds towards `retainedShare`.
    public var growthShare = 0.15, taskStartShare = 0.70, replacementShare = 0.50, retainedShare = 0.30
    /// The serialized size a planned replacement may have: the gateway's
    /// request limit. A request can fit its token estimate and still pass it
    /// (images, provider state).
    public var maximumRequestBytes = ProviderClient.maximumRequestBytes
    public init() {}
    /// Pi's threshold settings for one window, which the context figures
    /// still show. From 32,768 tokens up this is pi's reserve; a smaller
    /// window keeps half of itself for the conversation.
    func settings(autoCompaction: Bool, contextWindow: Int) -> PiContext.Settings {
        PiContext.Settings(enabled: autoCompaction, reserveTokens: min(reserveTokens, contextWindow / 2))
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
    /// The input a request may use: the window less the dispatch margin and
    /// the larger of the ordinary output reserve and a summary's allowance
    /// with its appended instruction.
    func usable(profile: Profile, instructionTokens: Int) throws -> Int {
        let generation = summaryTokens(for: profile)
        let reserved = PiContext.sum([max(profile.maxOutput, PiContext.sum([generation, instructionTokens])),
            RequestContextCount.safetyMargin(contextWindow: profile.contextWindow)])
        guard instructionTokens >= 0, generation >= ProviderClient.minimumOutputTokens, reserved < profile.contextWindow else {
            throw AgentError("compact_budget", "This context window cannot fit the checkpoint instruction and summary reserves.")
        }
        return profile.contextWindow - reserved
    }
    /// Room for one round's growth: `growthShare` of the window, at least
    /// pi's reserve, and never more than a quarter of what is usable, so a
    /// small window keeps most of itself for the conversation.
    func growthReserve(profile: Profile, usable: Int) -> Int {
        min(max(reserveTokens, Int((Double(profile.contextWindow) * growthShare).rounded(.up))), usable / 4)
    }
    func share(_ usable: Int, _ fraction: Double) -> Int { Int((Double(usable) * fraction).rounded(.down)) }
    /// Where an automatic compaction is due: before a task's first request
    /// at `taskStartShare` of the usable input, and while it works once
    /// less than the growth reserve is left.
    func trigger(profile: Profile, instructionTokens: Int, taskStart: Bool = false) throws -> Int {
        let usable = try usable(profile: profile, instructionTokens: instructionTokens)
        return taskStart ? share(usable, taskStartShare) : usable - growthReserve(profile: profile, usable: usable)
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

    /// What a compaction reads: the previous summary and the messages since
    /// it. Inputs a checkpoint replayed ahead of its kept messages
    /// (`carried`) are not at their place in the turn. `newSince` is the
    /// first group appended after the previous checkpoint.
    ///
    /// Ours (owner, 2026-11-11): what stays is decided by task, not by a
    /// token tail. `whole` is the cut that keeps the task in hand whole;
    /// `required` is the latest cut that still holds what the next request
    /// must answer; `protectedIDs` are the inputs replayed as written
    /// wherever the cut falls. Nothing required is ever dropped to make a
    /// compaction possible.
    struct Source: Sendable {
        let previous: ChatMessage?
        let carried: [ChatMessage]
        let body: [ReplayGroup]
        let protectedIDs: Set<String>
        var newSince: Int?
        var whole = 0
        var required = 0
        /// The task had been answered at least once: it is being worked on.
        var inProgress = false
    }
    /// `taskRoot` names the task in hand by its `taskRootID`: steering and
    /// agent mail join it and do not start another. `taskOpen` is the task's
    /// lifecycle, not the look of its last row: a parent waiting for its
    /// family has an answer in place and is still working.
    /// - Working: every row of the task stays (`whole` is its first group).
    /// - Not yet answered (compaction at send): the message refers to what
    ///   came just before it ("yes, do the second one"), so the preceding
    ///   task's own inputs and its tool-free final reply stay, without its
    ///   tool rounds.
    /// - No task open (a manual compaction of an idle chat): the last
    ///   exchange stays, as at send.
    /// - No usable task metadata (an old context, working, idle or just
    ///   before a new message): the surviving body is kept and the fallback
    ///   applies; nothing is guessed from the last user row.
    static func source(context: [ChatMessage], taskRoot: String?, taskOpen: Bool = true) throws -> Source {
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
        func member(_ message: ChatMessage, _ root: String) -> Bool { message.id == root || message.taskRootID == root }
        // A task's own inputs: what started it (a sub-agent's task is agent
        // mail) and what the owner sent into it. Mail from another agent is
        // the task's material, never the owner's request or consent.
        func protect(inputsOf root: String) {
            for input in since where input.role == "user" && member(input, root) && (input.id == root || input.nativeAgentDelivery == nil) { protected.insert(input.id) }
        }
        func finalReply(_ group: ReplayGroup) -> Bool { group.messages.count == 1 && group.messages[0].role == "assistant" }
        // What the next request has to answer: the batch awaiting a reply
        // with whatever was delivered after it, or the inputs after the last reply.
        let lastReply=body.lastIndex { $0.messages[0].role == "assistant" }
        let unanswered=min(body.count, lastReply.map { body[$0].messages.count > 1 ? $0 : $0 + 1 } ?? 0)
        var whole=0, required=unanswered, inProgress=false
        let root=taskRoot.flatMap { root in since.contains(where: { member($0, root) }) ? root : nil }
        if taskOpen, let root {
            let start=body.firstIndex { member($0.messages[0], root) } ?? body.count
            protect(inputsOf: root)
            let answered=body[start...].contains { $0.messages[0].role == "assistant" }
                || (previous?.taskRootID == root && previous?.compaction?["continuationText"].text != nil)
            if answered {
                inProgress=true; whole=start; required=max(start, unanswered)
            } else {
                let before=start > 0 ? body[start - 1] : nil
                if let before, before.messages[0].taskRootID == nil {
                    // What precedes the message has no task metadata (a chat
                    // from before it, as every chat is at its first compaction
                    // after upgrading): there is no exchange to pick out, so
                    // the surviving body stays and the fallback keeps its
                    // newest rows, the latest request and reply first.
                    whole=0; required=start
                } else {
                    whole=before.map(finalReply) == true ? start - 1 : start; required=whole
                    if let earlier=before?.messages[0].taskRootID, earlier != root { protect(inputsOf: earlier) }
                }
            }
        } else if !taskOpen, let last=body.last?.messages[0].taskRootID ?? root {
            // The last-exchange cut needs the task its rows name. Without
            // one (an idle chat from before task metadata) the reply alone
            // would stay and its request go: the metadata-free rule below
            // applies instead.
            whole=body.last.map(finalReply) == true ? body.count - 1 : body.count; required=whole
            protect(inputsOf: last)
        }
        if let permission = since.last(where: { $0.contextNote != nil }) { protected.insert(permission.id) }
        return Source(previous:previous,carried:Array(carried),body:body,protectedIDs:protected,newSince:newSince,whole:whole,required:required,inProgress:inProgress)
    }

    /// The fallback for a task too large to keep whole: everything required,
    /// then the newest whole groups before it, working backward in one pass,
    /// while what is retained stays within `target` tokens. `tokens` sizes
    /// a row as the request will carry it (pi's estimate by default).
    /// Required material may pass the target; it is never left out.
    static func fallbackCut(_ source: Source, target: Int, tokens: (ChatMessage) -> Int = PiContext.estimateTokens) -> Int {
        var cut=min(max(source.required,source.whole),source.body.count)
        var retained=PiContext.sum(plan(source,cut:cut).keptMessages.map(tokens))
        while cut > source.whole {
            let added=PiContext.sum(source.body[cut - 1].messages.filter { !source.protectedIDs.contains($0.id) }.map(tokens))
            guard PiContext.sum([retained,added]) <= target else { break }
            retained=PiContext.sum([retained,added]); cut -= 1
        }
        return cut
    }

    /// Everything from `cut` on stays, with the protected inputs before it
    /// replayed ahead. Pi's split: a cut group that does not start a turn
    /// splits the turn begun by the last turn start before it. Protected
    /// inputs before the cut are summarized in place for context as well.
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
    /// What the adopted request may measure at most; nil for a manual
    /// compaction, which only has to shrink the context.
    let replacementTarget: Int?
    /// The framing a checkpoint made while its task worked carries.
    let continuationText: String?
    /// After a context rejection, where the ordinary plan could not be made:
    /// only what must stay is kept, and the checkpoint is accepted when it
    /// fits a normal request and saves the safety margin, not by the half.
    var recoveryOnly = false
}
extension CompactionPlanner {
    static func prepare(frozen: [ChatMessage], profile: Profile, instructions: String, definitions: [ToolDefinition],
                        sessionID: String, cacheSessionID: String, taskRoot: String?, taskOpen: Bool = true, policy: CompactionPolicy,
                        reason: String, focus: String?, overWindow: Bool = false) throws -> PreparedCompaction {
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
        let manual=reason == "manual"
        let source=try source(context:frozen,taskRoot:taskRoot,taskOpen:taskOpen)
        let unchanged=source.previous != nil && (source.newSince ?? 0) >= source.body.count
        // A manual compaction is the owner's own interruption: no framing.
        let continuation=source.inProgress && !manual ? CompactionCheckpoint.continuationText : nil
        // The checkpoint as it will be replayed, at its whole allowance.
        var placeholder=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+String(repeating:"s",count:cap*4))])
        placeholder.kind="compaction"
        if let continuation { placeholder.compaction=["continuationText":JSON(continuation)] }
        let projection=try ProviderClient.responsesProjection(frozen,instructions:instructions,profile:profile)
        func instruction(_ plan: CompactionPlan) throws -> ChatMessage {
            let boundary=try CompactionSourceBuilder.boundary(projection,messages:frozen,keptIDs:Set(plan.keptMessages.map(\.id)))
            return CompactionSourceBuilder.instruction(boundary:boundary,focus:focus,visibleTarget:visibleTarget)
        }
        func usable(_ plan: CompactionPlan) throws -> Int {
            let cost=RequestContextCounter.inputTokens([["role":"user","content":.array(ProviderClient.userContent(try instruction(plan),images:false))]])
            return try policy.usable(profile:profile,instructionTokens:cost)
        }
        // The same targets hold after a gateway's context rejection: what
        // the next request must answer is required there too.
        func target(_ plan: CompactionPlan, _ share: Double) throws -> Int { policy.share(try usable(plan),share) }
        // Whether `plan` is worth a summary request: it removes something
        // new, what replaces the context fits a normal request in tokens and
        // bytes, and (automatic) it leaves the gap `replacementShare` asks
        // for. A manual compaction only has to make the context smaller.
        // `expectedSummary` holds the replacement to its limit with the
        // summary at the length it is asked for instead of its whole
        // allowance: see the last resort below.
        // `fitOnly` asks for no more than fitting a normal request, in
        // tokens and bytes, at the whole allowance: recovery's acceptance.
        func acceptable(_ plan: CompactionPlan, expectedSummary: Bool = false, fitOnly: Bool = false) throws -> Bool {
            guard !plan.summarized.isEmpty else { return false }
            let request=try body([placeholder]+plan.keptMessages)
            let full=try count([placeholder]+plan.keptMessages,request:request)
            guard full.fits, try request.data().count <= policy.maximumRequestBytes else { return false }
            if fitOnly { return true }
            var expected=placeholder
            expected.content=[textBlock(CompactionCheckpoint.replayPrefix+String(repeating:"s",count:visibleTarget*4))]
            if manual {
                // Avoid spending a manual summary just to replace a tiny
                // input while retaining every large answer.
                return try count([expected]+plan.keptMessages).requestTokens < before.requestTokens
            }
            let measured=expectedSummary ? try count([expected]+plan.keptMessages).requestTokens : full.requestTokens
            return measured <= (try target(plan,policy.replacementShare))
        }
        // The task whole, or its required material and newest rounds. The
        // boundary is chosen once, BEFORE the request: the summarizer sees
        // every source, including the unchanged tail, under this exact cut.
        var plan=CompactionPlanner.plan(source,cut:source.whole), lastResort=false
        if !unchanged, try !acceptable(plan) {
            try Task.checkCancellation()
            // Sized as the projection sends each row, a reply's replayed
            // reasoning included, like the replacement it has to fit.
            func size(_ message: ChatMessage) -> Int {
                projection.ranges[message.id].map { RequestContextCounter.inputTokens(Array(projection.items[$0])) } ?? PiContext.estimateTokens(message)
            }
            // `retainedShare` is a ceiling on what is retained, not a
            // target that may break the fit: newer rounds are added only
            // into the room the summary's allowance, the request's prefix
            // (instructions, schemas, wrapper, framing) and the required
            // rows leave under `replacementShare`. In a small window that
            // room is little or none, and the required rows alone are the plan.
            let least=min(max(source.required,source.whole),source.body.count), required=CompactionPlanner.plan(source,cut:least)
            var ceiling=try target(required,policy.retainedShare)
            if !manual {
                let room=max(0,try target(required,policy.replacementShare)-(try count([placeholder]+required.keptMessages).requestTokens))
                ceiling=min(ceiling,PiContext.sum([PiContext.sum(required.keptMessages.map(size)),room]))
            }
            var cut=fallbackCut(source,target:ceiling,tokens:size)
            plan=CompactionPlanner.plan(source,cut:cut)
            // Rows are sized from the frozen projection and the candidate
            // is measured whole: where they disagree, a round is given back.
            while cut < least, try !acceptable(plan) { cut += 1; plan=CompactionPlanner.plan(source,cut:cut) }
            // The last resort, for a window where the whole allowance and
            // the request's prefix alone pass half the usable input (32,768
            // tokens with a few thousand of schemas): nothing but what must
            // stay, held to the limit with the summary at its expected
            // length. It still fits beside the whole allowance, and the
            // checkpoint is adopted only if it measures within the limit.
            lastResort=cut == least
        }
        func admitted(_ plan: CompactionPlan) throws -> Bool { try acceptable(plan) || (lastResort && acceptable(plan,expectedSummary:true)) }
        // After a gateway's context rejection the ordinary plan comes first.
        // Where it cannot be made, the request has to shrink all the same:
        // only what must stay is kept with the checkpoint, though that may
        // pass half the usable input, provided the replacement fits a normal
        // request at the whole allowance. Nothing required is dropped.
        // 0.1.138: the same before a request is sent that does not fit beside
        // the reply's reserve (`overWindow`). Until then such a request went
        // out whole and the plan waited for a refusal; a provider whose real
        // window is larger than the declared one never gives it, and a task
        // whose every round is over the half (one large result with the
        // reasoning that asked for it, in a small window) was never compacted.
        var recoveryOnly=false
        if reason == "context-rejection" || overWindow, !unchanged, try !admitted(plan) {
            let required=CompactionPlanner.plan(source,cut:min(max(source.required,source.whole),source.body.count))
            if try acceptable(required,fitOnly:true) { plan=required; recoveryOnly=true }
        }
        guard !unchanged, !plan.summarized.isEmpty else {
            throw AgentError("compact_unavailable", unchanged ? "Already compacted: nothing has been added since the last compaction." : "Nothing useful to compact while keeping the task in hand and required inputs intact.")
        }
        guard try count([placeholder]+plan.keptMessages).fits else {
            throw AgentError("compact_budget", "Required retained inputs, instructions, tools and the summary allowance cannot fit beside the normal output reserve. Original context is unchanged.")
        }
        guard try recoveryOnly || admitted(plan) else {
            throw AgentError("compact_unavailable", "No useful checkpoint can be planned while preserving required inputs and continuation headroom. Original context is unchanged.")
        }
        guard profile.raw["input"].list.contains("image") || !frozen.contains(where: { $0.content.contains { $0["type"].text == "image" } }) else {
            throw AgentError("unsupported_image", "Compaction cannot replace existing images with placeholders. Select an image-capable model; the context is unchanged.")
        }
        let summarizedIDs=(plan.previous.map { [$0.id] } ?? [])+plan.summarized.map(\.id)
        return PreparedCompaction(before:before,profile:summaryProfile,plan:plan,messages:frozen+[try instruction(plan)],replacedIDs:summarizedIDs,fingerprint:attemptKey,
                                  replacementTarget:manual || recoveryOnly ? nil : try target(plan,policy.replacementShare),continuationText:continuation,recoveryOnly:recoveryOnly)
    }
}
