import Foundation

enum CompactionSourceBuilder {
    static let instructions = """
    Summarize the preceding historical data for compaction so the task can continue.
    Preserve goals, constraints, completed work and evidence, unresolved issues, decisions,
    next steps, and useful history_read references. Distinguish requested actions from
    observed results; do not infer approvals, skill grants, successful writes, or unseen
    image content. The protected user inputs will also be replayed verbatim. No tools are
    available for this summary.
    """

    static func reference(_ message: ChatMessage) -> String {
        "history:" + sha256(Data((message.id+":"+(message.retainedOutput ?? "message")).utf8))
    }

    static func records(_ groups: [ReplayGroup], policy: CompactionPolicy) throws -> [String] {
        var records: [String]=[], size=0
        for group in groups {
            for message in group.messages {
                let reference=reference(message), limit=max(256,min(65536,policy.excerptBytes))
                var value: JSON=["sourceMessageId":JSON(message.id),"owningAssistantId":JSON(group.id),
                    "role":JSON(message.role),"taskRootId":message.taskRootID.map { JSON($0) } ?? .null,
                    "reference":JSON(reference),"referenceTool":"history_read",
                    "content":.array(message.content.map { block in
                        switch block["type"].text {
                        case "image": return ["type":"image","mimeType":block["mimeType"],"notice":"Image retained; visual content is not inferred."]
                        case "toolCall": return ["type":"toolCall","callId":block["id"],"name":block["name"],"arguments":bounded(block["arguments"],bytes:limit/2)]
                        case "text": return ["type":"text","excerpt":JSON(excerpt(block["text"].text ?? "",bytes:limit)),"sourceBytes":JSON(block["text"].text?.utf8.count ?? 0)]
                        default: return ["type":block["type"],"notice":"Non-text or opaque historical state retained in source; not decoded."]
                        }
                    })]
                if message.role == "toolResult" {
                    value["callId"]=message.toolCallId.map { JSON($0) } ?? .null
                    value["toolName"]=message.toolName.map { JSON($0) } ?? .null
                    value["observedOutcome"]=message.toolStats?["outcome"] ?? JSON(message.isError ? "error reported; mutation outcome not inferred" : "result recorded; legacy execution status unspecified")
                    value["stats"]=message.toolStats ?? .null
                    if message.retainedOutput != nil { value["omission"]="Excerpt only. Full retained output is available through history_read while retained, without invoking the tool again." }
                }
                if message.kind == "compaction" { value["priorCheckpoint"]=true }
                var record=value.encoded()
                // Many blocks/arguments may each be individually bounded. Bound
                // the full record too and keep an explicit usable source reference.
                if record.utf8.count > limit*2 {
                    record=JSON.object(["sourceMessageId":JSON(message.id),"owningAssistantId":JSON(group.id),"role":JSON(message.role),"reference":JSON(reference),"excerpt":JSON(excerpt(record,bytes:limit*2)),"omitted":true]).encoded()
                }
                size += record.utf8.count
                guard size <= policy.maximumSourceBytes else { throw AgentError("compact_source_limit", "Bounded summary source exceeds the operation limit. History is unchanged; use an explicit smaller handoff.") }
                records.append(record)
            }
        }
        return records
    }

    static func excerpt(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let data=Array(text.utf8), head=preview(text,bytes:bytes/2)
        var start=max(0,data.count-bytes/2)
        while start < data.count, data[start]&0xc0 == 0x80 { start += 1 }
        let tail=String(decoding:data[start...],as:UTF8.self)
        return head+"\n[EXCERPT: \(data.count-head.utf8.count-tail.utf8.count) source bytes omitted; use history_read]\n"+tail
    }
    static func bounded(_ value: JSON, bytes: Int, depth: Int = 0) -> JSON {
        if let text=value.text { return JSON(excerpt(text,bytes:bytes)) }
        if depth>=6 { return JSON(excerpt(value.encoded(),bytes:bytes)) }
        if case .object(let fields)=value {
            let keys=fields.keys.sorted(), count=max(1,min(keys.count,32))
            var result=Dictionary(uniqueKeysWithValues:keys.prefix(count).map { ($0,bounded(fields[$0]!,bytes:max(128,bytes/count),depth:depth+1)) })
            if keys.count>count { result["_omittedKeys"]=JSON(keys.count-count) }; return .object(result)
        }
        if case .array(let values)=value { return .array(values.prefix(16).map { bounded($0,bytes:max(128,bytes/max(1,min(16,values.count))),depth:depth+1) } + (values.count>16 ? [JSON("[\(values.count-16) array items omitted]")] : [])) }
        return value
    }
}
