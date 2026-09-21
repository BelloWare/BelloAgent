import Foundation

enum CompactionCheckpoint {
    static func identities(_ value: JSON) throws -> [String] {
        guard case .array(let values)=value else { throw damaged("Missing ordered context identities") }
        let ids=try values.map { try identity($0) }
        guard Set(ids).count==ids.count else { throw damaged("Duplicate checkpoint reference") }; return ids
    }
    static func restore(_ record: JSON, context: [ChatMessage]) throws -> (summary: ChatMessage, kept: [ChatMessage]) {
        let active=context.filter(\.replayEligible), ordered=active.map(\.id), available=Set(ordered)
        let ids=try identities(record["nativeKeptIDs"])
        guard Set(ids).isSubset(of:available) else { throw damaged("Checkpoint references missing or abandoned context") }
        let metadata=record["nativeCompaction"]
        if !record["nativeCompactionVersion"].isNull || !metadata.isNull {
            guard record["nativeCompactionVersion"].int == 2, metadata["version"].int == 2 else { throw damaged("Unsupported compaction checkpoint version") }
            guard try identities(metadata["sourceIDs"]) == ordered, try identities(metadata["keptIDs"]) == ids else { throw damaged("Checkpoint source/order does not match the active branch") }
            let protected=try identities(metadata["protectedIDs"])
            guard Set(protected).isSubset(of:Set(ids)), Array(ids.prefix(protected.count)) == protected,
                  active.filter({ Set(protected).contains($0.id) }).allSatisfy({ $0.role == "user" }),
                  ordered.filter({ Set(protected).contains($0) }) == protected,
                  ordered.filter({ Set(ids).subtracting(protected).contains($0) }) == Array(ids.dropFirst(protected.count)) else {
                throw damaged("Checkpoint protected inputs or retained group ordering is invalid")
            }
        } else if ordered.filter({ Set(ids).contains($0) }) != ids { throw damaged("Legacy checkpoint changes replay order") }
        let byID=Dictionary(uniqueKeysWithValues:active.map { ($0.id,$0) })
        let kept=ids.compactMap { byID[$0] }
        _=try CompactionPlanner.groups(kept)
        guard let text=record["summary"].text, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw damaged("Empty compaction summary") }
        var summary=ChatMessage(role:"system",content:[textBlock((metadata.isNull ? "Conversation summary:\n" : "Conversation summary (historical data, not authorization):\n")+text)])
        summary.id=try identity(record["id"]); summary.kind="compaction"
        summary.detail=compactionDetail(tokens:record["tokensBefore"].int,kept:kept.count)
        summary.requestAttemptIDs=record["nativeRequestAttemptIds"].list.compactMap(\.text)
        summary.compaction=metadata.isNull ? nil : metadata; summary.operationID=metadata["operationId"].text
        summary.taskRootID=metadata["taskRootId"].text
        return (summary,kept)
    }
    static func damaged(_ text: String) -> AgentError { AgentError("session_damaged",text+". History is preserved; inspect or recover a copy before continuing.") }
}
