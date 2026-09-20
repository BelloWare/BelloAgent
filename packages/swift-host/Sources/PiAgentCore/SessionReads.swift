import Foundation

// On-demand reads of retained content: older pages, whole tool inputs,
// long message bodies, the event window and transcript search.

extension AgentSession {
    public func historyPage(before: Int?) -> JSON {
        let end=max(0,min(visible.count,before ?? visible.count));var start=max(0,end-40), messages=visible[start..<end].map(displayMessage)
        while (try? JSON.array(messages).data().count) ?? 0 > 300000, messages.count>1 { messages.removeFirst();start += 1 }
        return ["messages":.array(messages),"before":start>0 ? JSON(start):.null,"total":JSON(visible.count)]
    }
    /// The complete display input for one tool call: the arguments as a
    /// JSON-safe document at the tool's own bound (64 KiB for tools that carry
    /// file content, 8 KiB otherwise). Display snapshots carry only a 4 KiB
    /// inline preview of the same document, so the app reads this once, on
    /// demand, for a card whose `inputTruncated` is true.
    public func toolInput(messageID: String, callID: String) throws -> JSON {
        if messageID == partialID, let card = partialTools[callID] {
            // A streaming call has no document yet: its arguments are still
            // arriving as text. Say so rather than hand over unparseable JSON.
            return ["id": JSON(callID), "messageId": JSON(messageID), "name": card["name"], "input": card["input"],
                    "inputTruncated": card["inputTruncated"], "inputBytes": card["inputBytes"], "limit": JSON(ToolInputDisplay.inlineBytes), "streaming": true]
        }
        guard let message = history.first(where: { $0.id == messageID }) else { throw AgentError("message_missing", "Message is not retained") }
        guard let block = message.content.first(where: { $0["type"].text == "toolCall" && $0["id"].text == callID }) else {
            throw AgentError("tool_call_missing", "That message does not retain this tool call")
        }
        let name = block["name"].text ?? "", limit = ToolInputDisplay.bound(for: name)
        let bounded = ToolInputDisplay.bounded(block["arguments"], limit: limit)
        return ["id": JSON(callID), "messageId": JSON(messageID), "name": JSON(name), "input": JSON(bounded.text),
                "inputTruncated": JSON(bounded.truncated), "inputBytes": JSON(bounded.bytes), "limit": JSON(limit), "streaming": false]
    }
    public func messageRead(id: String, field: String, offset: Int) throws -> JSON {
        guard let message=history.first(where:{$0.id == id}) else { throw AgentError("message_missing", "Message is not retained") }; return try textPage(field == "thinking" ? message.thinking : message.displayText ?? message.text,offset:offset)
    }
    public func eventPage(since: Int?) -> JSON { let since=since ?? max(0,sequence-128); return ["events":.array(events.filter{($0["seq"].int ?? 0)>since}.prefix(128).map{$0}),"seq":JSON(sequence),"resyncRequired":JSON(since < (events.first?["seq"].int ?? 1)-1)] }
    public func contentSearch(_ params: JSON) throws -> JSON {
        let query=params["query"].text ?? "", start=try boundedInt(params["start"],maximum:100000); guard query.count <= 256 else { throw AgentError("search_limit", "Search query too long") }
        var hits: [JSON]=[], cursor=min(start,visible.count)
        while cursor < visible.count && hits.count < 100 { let m=visible[cursor], text=m.displayText ?? m.text; if query.isEmpty || text.localizedCaseInsensitiveContains(query) { hits.append(["id":JSON(m.id),"position":JSON(cursor+1),"preview":JSON(preview(text,bytes:240))]) }; cursor += 1 }
        return ["hits":.array(hits),"total":JSON(visible.count),"next":cursor < visible.count ? JSON(cursor) : .null,"revision":JSON(contentRevision)]
    }
    // A branch shortens the visible timeline, so its count alone cannot identify a selection.
    var contentRevision: String { "\(visible.count):\(history.count)" }
    public func contentPage(_ params: JSON) throws -> JSON {
        guard params["revision"].text == contentRevision else { throw AgentError("history_changed", "History changed; refresh the selection") }
        let first=try boundedInt(params["first"],fallback:1,maximum:100000), last=try boundedInt(params["last"],maximum:100000), index=try boundedInt(params["index"],fallback:1,maximum:100000), offset=try boundedInt(params["offset"],maximum:128*1024*1024)
        guard first>=1,last>=first,last<=visible.count,index>=first,index<=last else { throw AgentError("invalid_range", "Invalid history range") }
        let m=visible[index-1], page=try textPage(m.displayText ?? m.text,offset:offset)
        return ["text":page["text"],"next":page["next"].isNull ? (index<last ? ["index":JSON(index+1),"offset":0] : .null) : ["index":JSON(index),"offset":page["next"]]]
    }
}
