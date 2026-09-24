import Foundation

public struct CompactionPolicy: Sendable {
    /// Ours: physical requests one chained summary chunk may use, including
    /// transient retries and a repack after the gateway rejects its size. A
    /// long history takes more chunks; it never fails for its length.
    public var maximumAttempts = 8
    /// Pi's compaction reserve and recent-context target (settings-manager.ts).
    public var reserveTokens = 16_384
    public var keepRecentTokens = 20_000
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
    /// Pi's summary maxTokens (compaction.ts generateSummaryWithUsage):
    /// min(floor(0.8 × reserveTokens), model.maxTokens when known); a split
    /// turn's prefix gets 0.5 × reserveTokens. The chat's output budget and
    /// output cap are not part of it, and an unknown ceiling bounds nothing.
    func summaryTokens(for profile: Profile, turnPrefix: Bool = false) -> Int {
        let reserve=settings(autoCompaction:true,contextWindow:profile.contextWindow).reserveTokens
        return max(1,min(reserve*(turnPrefix ? 5 : 8)/10,profile.modelOutputLimit ?? Int.max))
    }
    /// A summary request's profile. `cap` is the room its request keeps free
    /// for the summary; unlike pi's summary maxTokens it is not sent. The
    /// request carries the model's own output limit, clipped to the window as
    /// any request is, so the chat's reasoning cannot use up a summary's cap
    /// before the summary is written.
    func summaryProfile(_ original: Profile, cap: Int) throws -> Profile {
        var raw=original.raw
        raw["maxOutputTokens"]=JSON(cap)
        return try Profile(raw)
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
    /// Summarized with pi's summarization or update prompt, oldest first.
    let history: [ChatMessage]
    /// A split turn's prefix, summarized with pi's turn-prefix prompt.
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
    static func source(context: [ChatMessage], taskRoot: String?) throws -> Source {
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
        return Source(previous:previous,carried:Array(carried),body:body,protectedIDs:[],newSince:newSince)
    }

    /// findCutPoint: walking back from the newest message by pi's
    /// estimateTokens, the first group start at or after the message that
    /// reaches `keepRecentTokens`; a tool result stays with its call. 0 keeps
    /// everything. Pi's walk passes the previous checkpoint where its session
    /// path holds it, after the rows it kept, and counts its summary there.
    /// Ours: when the newest group alone reaches the target the whole body is
    /// summarized, where pi would keep it and could not compact.
    static func cut(_ body: [ReplayGroup], keepRecentTokens: Int, previous: (index: Int, tokens: Int)? = nil) -> Int {
        var used=0
        for index in body.indices.reversed() {
            for (offset,message) in body[index].messages.enumerated().reversed() {
                let tokens=PiContext.estimateTokens(message)
                guard tokens > 0 else { continue }
                used=PiContext.sum([used,tokens])
                if used >= keepRecentTokens { return offset == 0 ? index : index+1 }
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
