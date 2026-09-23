import Foundation

public struct CompactionPolicy: Sendable {
    /// Physical requests one summary chunk may use, including transient
    /// retries and a repack after the gateway rejects its size. A long history
    /// takes more chunks; it never fails for its length.
    public var maximumAttempts = 8
    /// Optional explicit cost ceiling, including reasoning.
    public var summaryOutputTokens: Int?
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
    /// The model's output limit: its declared ceiling, else the configured
    /// budget, within any explicit cap. Unknown routes never omit the bound.
    func outputAllowance(for profile: Profile) -> Int {
        let declared=profile.modelOutputLimit ?? profile.maxOutput
        return max(1,min(declared,summaryOutputTokens ?? Int.max,profile.outputCap ?? Int.max))
    }
    /// Pi's summary maxTokens, min(0.8 × reserveTokens, model.maxTokens); a
    /// split turn's prefix gets 0.5 × reserveTokens.
    func summaryTokens(for profile: Profile, turnPrefix: Bool = false) -> Int {
        let reserve=settings(autoCompaction:true,contextWindow:profile.contextWindow).reserveTokens
        return max(1,min(reserve*(turnPrefix ? 5 : 8)/10,outputAllowance(for:profile)))
    }
    func summaryProfile(_ original: Profile, cap: Int) throws -> Profile {
        guard original.raw["compat"]["supportsMaxOutputTokens"].flag != false else {
            throw AgentError("compaction_source_limit","Compaction cannot guarantee bounded generation: this gateway omits output limits. Configure a supported output-limit contract.")
        }
        // Every summary request reserves its whole cap; its source is packed
        // to fit beside it, so the cap is never clipped.
        var raw=original.raw
        raw["maxOutputTokens"]=JSON(cap);raw["outputCap"]=JSON(cap)
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
    /// Current-task inputs before the cut, replayed verbatim ahead of `kept`.
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

    static func protectedInputs(_ context: [ChatMessage], taskRoot: String?) -> [ChatMessage] {
        let users=context.filter { $0.role == "user" && $0.replayEligible }
        guard let taskRoot, users.contains(where: { $0.id == taskRoot }) else { return users }
        // Ambiguous legacy inputs remain protected rather than guessed away.
        return users.filter { $0.id == taskRoot || $0.taskRootID == taskRoot || $0.taskRootID == nil }
    }

    /// What pi's prepareCompaction reads: the previous summary and the
    /// messages since it. Inputs the previous checkpoint replays ahead of its
    /// kept messages (`carried`) are not at their place in the turn.
    struct Source: Sendable {
        let previous: ChatMessage?
        let carried: [ChatMessage]
        let body: [ReplayGroup]
        let protectedIDs: Set<String>
    }
    static func source(context: [ChatMessage], taskRoot: String?) throws -> Source {
        let active=context.filter(\.replayEligible)
        let previous=active.first.flatMap { $0.kind == "compaction" ? $0 : nil }
        let since=Array(active.dropFirst(previous == nil ? 0 : 1))
        let replayed=Set(previous?.compaction?["protectedIDs"].list.compactMap(\.text) ?? [])
        let carried=since.prefix { $0.role == "user" && replayed.contains($0.id) }
        return Source(previous:previous,carried:Array(carried),body:try groups(Array(since.dropFirst(carried.count))),
                      protectedIDs:Set(protectedInputs(active,taskRoot:taskRoot).map(\.id)))
    }

    /// findCutPoint: walking back from the newest message by pi's
    /// estimateTokens, the first group start at or after the message that
    /// reaches `keepRecentTokens`; a tool result stays with its call. 0 keeps
    /// everything. When the newest group alone reaches the target the whole
    /// body is summarized, where pi would keep it and could not compact.
    static func cut(_ body: [ReplayGroup], keepRecentTokens: Int) -> Int {
        var used=0
        for index in body.indices.reversed() {
            for (offset,message) in body[index].messages.enumerated().reversed() {
                let tokens=PiContext.estimateTokens(message)
                guard tokens > 0 else { continue }
                used=PiContext.sum([used,tokens])
                if used >= keepRecentTokens { return offset == 0 ? index : index+1 }
            }
        }
        return 0
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
