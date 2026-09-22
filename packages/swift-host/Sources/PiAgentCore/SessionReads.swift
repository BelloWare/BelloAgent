import Foundation

// On-demand reads of retained content: older pages, whole tool inputs,
// long message bodies, the event window and transcript search.

extension AgentSession {
    public func historyPage(before: Int?) -> JSON {
        let end=max(0,min(visible.count,before ?? visible.count));var start=max(0,end-40), messages=visible[start..<end].map(displayMessage)
        while (try? JSON.array(messages).data().count) ?? 0 > 300000, messages.count>1 { messages.removeFirst();start += 1 }
        return ["messages":.array(messages),"before":start>0 ? JSON(start):.null,"total":JSON(visible.count)]
    }
    /// Versioned browsing contract; older numeric callers retain their adapter.
    public func historyWindow(_ params: JSON) throws -> JSON {
        let lineage = presentationTimeline
        let cursor: ConversationCursor? = params["cursor"].isNull ? nil : try JSONDecoder().decode(ConversationCursor.self, from: params["cursor"].data())
        if let cursor, cursor.incarnation != displayEpoch || cursor.lineage != lineage {
            throw AgentError("history_changed", "This conversation changed. Reload the visible history.")
        }
        let entry = cursor?.entry ?? params["entry"].text
        if let oldLineage = params["lineage"].text, oldLineage != lineage { throw AgentError("history_changed", "The conversation branch changed during source handoff") }
        let boundary = entry.flatMap { id in visible.firstIndex { $0.id == id } }
        if entry != nil && boundary == nil { throw AgentError("history_changed", "The history boundary is no longer available. Reload history.") }
        let target = params["around"].text
        let around = target.flatMap { id in visible.firstIndex { $0.id == id } }
        if target != nil && around == nil { throw AgentError("message_missing", "That message is outside the current branch. Its retained content is still inspectable.") }
        let forward = params["direction"].text == "newer" || around != nil
        let range = HistoryWindowPolicy.range(count: visible.count, before: forward ? nil : boundary,
                                              after: forward ? boundary : nil, around: around, isUser: { visible[$0].role == "user" })
        let candidates = visible[range]
        let keys = Set(candidates.compactMap { message in message.taskExecutionID.map { TaskPresentationRecord.identity(message.taskRootID ?? "", $0) } })
        let sourceIDs = Set(candidates.map(\.id))
        let tasks = try JSON.parse(JSONEncoder().encode(recentTaskPresentations.filter { keys.contains($0.key) || $0.anchorSourceID.map(sourceIDs.contains) == true }))
        var rows: [JSON] = [], bytes = HistoryWindowPolicy.metadataAllowance + (try tasks.data().count)
        var start = forward ? range.lowerBound : range.upperBound, end = start
        let positions = forward ? Array(range) : Array(range.reversed())
        for index in positions {
            let row = boundedDisplayRow(displayMessage(visible[index]))
            let size = try row.data().count
            guard rows.isEmpty || bytes + size + 1 <= HistoryWindowPolicy.envelopeBytes else { break }
            bytes += size + 1
            if forward { rows.append(row); end = index + 1 }
            else { rows.insert(row, at: 0); start = index }
        }
        func boundaryValue(_ entry: String) throws -> JSON {
            try JSON.parse(JSONEncoder().encode(ConversationCursor(incarnation: displayEpoch, lineage: lineage, entry: entry)))
        }
        var result: JSON = ["version":2,"messages":.array(rows),"total":JSON(visible.count),
            "incarnation":JSON(displayEpoch),"lineage":JSON(lineage),"start":JSON(start),"end":JSON(end),
            "older": start > 0 && !rows.isEmpty ? try boundaryValue(visible[start].id) : .null,
            "newer": end < visible.count && !rows.isEmpty ? try boundaryValue(visible[end - 1].id) : .null]
        if start < visible.count && visible[start].role != "user", let input = visible[..<start].last(where: { $0.role == "user" }) {
            result["partialTurnInput"] = JSON(input.id)
        }
        result["taskRecords"] = tasks
        return result
    }
    /// Complete tool arguments. Large documents use automatic IPC transfer
    /// paging; expanding a card must not cut an edit or a file's contents.
    public func toolInput(messageID: String, callID: String) throws -> JSON {
        if messageID == partialID, let card = partialTools[callID] {
            // A streaming call has no document yet: its arguments are still
            // arriving as text. Say so rather than hand over unparseable JSON.
            return ["id": JSON(callID), "messageId": JSON(messageID), "name": card["name"], "input": card["input"],
                    "inputTruncated": card["inputTruncated"], "inputBytes": card["inputBytes"], "streaming": true]
        }
        guard let message = history.first(where: { $0.id == messageID }) else { throw AgentError("message_missing", "Message is not retained") }
        guard let block = message.content.first(where: { $0["type"].text == "toolCall" && $0["id"].text == callID }) else {
            throw AgentError("tool_call_missing", "That message does not retain this tool call")
        }
        let input = block["arguments"].encoded()
        return ["id": JSON(callID), "messageId": JSON(messageID), "name": block["name"], "input": JSON(input),
                "inputTruncated": false, "inputBytes": JSON(input.utf8.count), "streaming": false]
    }
    public func messageRead(id: String, field: String, offset: Int) throws -> JSON {
        guard let message=history.first(where:{$0.id == id}) else { throw AgentError("message_missing", "Message is not retained") }; return try textPage(field == "thinking" ? message.thinking : message.retainedDisplayText,offset:offset)
    }
    public func eventPage(since: Int?) -> JSON { let since=since ?? max(0,sequence-128); return ["events":.array(events.filter{($0["seq"].int ?? 0)>since}.prefix(128).map{$0}),"seq":JSON(sequence),"resyncRequired":JSON(since < (events.first?["seq"].int ?? 1)-1)] }
    public func contentSearch(_ params: JSON) throws -> JSON {
        let query=params["query"].text ?? "", start=try boundedInt(params["start"],maximum:100000); guard query.count <= 256 else { throw AgentError("search_limit", "Search query too long") }
        var hits: [JSON]=[], cursor=min(start,visible.count)
        while cursor < visible.count && hits.count < 100 { let m=visible[cursor], text=m.retainedDisplayText; if query.isEmpty || text.localizedCaseInsensitiveContains(query) { hits.append(["id":JSON(m.id),"position":JSON(cursor+1),"preview":JSON(preview(text,bytes:240))]) }; cursor += 1 }
        return ["hits":.array(hits),"total":JSON(visible.count),"next":cursor < visible.count ? JSON(cursor) : .null,"revision":JSON(contentRevision)]
    }
    // A branch shortens the visible timeline, so its count alone cannot identify a selection.
    var contentRevision: String { "\(visible.count):\(history.count)" }
    public func contentPage(_ params: JSON) throws -> JSON {
        guard params["revision"].text == contentRevision else { throw AgentError("history_changed", "History changed; refresh the selection") }
        let first=try boundedInt(params["first"],fallback:1,maximum:100000), last=try boundedInt(params["last"],maximum:100000), index=try boundedInt(params["index"],fallback:1,maximum:100000), offset=try boundedInt(params["offset"],maximum:128*1024*1024)
        guard first>=1,last>=first,last<=visible.count,index>=first,index<=last else { throw AgentError("invalid_range", "Invalid history range") }
        let m=visible[index-1], page=try textPage(m.retainedDisplayText,offset:offset)
        return ["text":page["text"],"next":page["next"].isNull ? (index<last ? ["index":JSON(index+1),"offset":0] : .null) : ["index":JSON(index),"offset":page["next"]]]
    }
}
