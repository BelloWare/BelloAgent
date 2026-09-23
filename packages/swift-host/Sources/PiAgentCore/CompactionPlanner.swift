import Foundation

/// Bounds apply to the whole operation, including physical retry attempts.
public struct CompactionPolicy: Sendable {
    public var maximumAttempts = 8
    /// Optional explicit cost ceiling, including reasoning. Otherwise request
    /// the model's declared allowance, clipped only to actual request headroom.
    public var summaryOutputTokens: Int?
    public var excerptBytes = 8192
    public var maximumSourceBytes = 2 * 1024 * 1024
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
    func outputAllowance(for profile: Profile) -> Int {
        // Unknown routes conservatively retain their configured budget; never
        // infer a model ceiling from its name or omit the bound on the wire.
        let declared=profile.modelOutputLimit ?? profile.maxOutput
        return max(1,min(declared,summaryOutputTokens ?? Int.max,profile.outputCap ?? Int.max))
    }
    func summaryProfile(_ original: Profile, cap: Int) throws -> Profile {
        guard original.raw["compat"]["supportsMaxOutputTokens"].flag != false else {
            throw AgentError("compaction_source_limit","Compaction cannot guarantee bounded generation: this gateway omits output limits. Configure a supported output-limit contract.")
        }
        var raw=original.raw
        // This is the packing profile. Every dispatched chunk is then recounted
        // with the full feasible wire cap as its reserve (see summarizeBounded).
        raw["maxOutputTokens"]=JSON(min(cap,original.maxOutput));raw["outputCap"]=JSON(cap)
        return try Profile(raw)
    }
}

struct ReplayGroup: Sendable {
    let messages: [ChatMessage]
    var id: String { messages[0].id }
}

struct CompactionPlan: Sendable {
    let protected: [ChatMessage]
    let summarized: [ReplayGroup]
    let kept: [ReplayGroup]
    var keptMessages: [ChatMessage] { protected + kept.flatMap(\.messages) }
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

    static func plan(context: [ChatMessage], taskRoot: String?, recentTarget: Int,
                     cost: ([ChatMessage]) throws -> Int) throws -> CompactionPlan {
        let atomic=try groups(context), protected=protectedInputs(context,taskRoot:taskRoot)
        let protectedIDs=Set(protected.map(\.id))
        let eligible=atomic.filter { !protectedIDs.contains($0.id) }
        guard !eligible.isEmpty else { throw AgentError("compact_unavailable", "No completed work is eligible for compaction; current user instructions are kept verbatim.") }
        var kept: [ReplayGroup]=[], used=0
        // At least the oldest eligible group must be summarized. A giant newest
        // group is eligible too; the recent suffix is a target, not a floor.
        let firstCurrent=taskRoot.flatMap { root in eligible.firstIndex { $0.messages.contains { $0.taskRootID==root } } }
        let minimum=max(1,firstCurrent ?? 1)
        for group in eligible.dropFirst(minimum).reversed() {
            let tokens=try cost(group.messages)
            guard tokens <= max(0,recentTarget-used) else { break }
            used += tokens; kept.insert(group,at:0)
        }
        return CompactionPlan(protected:protected,summarized:Array(eligible.prefix(eligible.count-kept.count)),kept:kept)
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
