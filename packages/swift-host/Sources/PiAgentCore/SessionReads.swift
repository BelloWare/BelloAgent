import Foundation

// On-demand reads of retained content: older pages, whole tool inputs,
// long message bodies, the event window and transcript search.

extension AgentSession {
    public func historyPage(before: Int?) -> JSON {
        let end=max(0,min(visible.count,before ?? visible.count));var start=max(0,end-40), messages=visible[start..<end].map { displayMessage($0) }
        while (try? JSON.array(messages).data().count) ?? 0 > 300000, messages.count>1 { messages.removeFirst();start += 1 }
        return ["messages":.array(messages),"before":start>0 ? JSON(start):.null,"total":JSON(visible.count)]
    }
    /// Versioned browsing contract; older numeric callers retain their adapter.
    public func historyWindow(_ params: JSON) async throws -> JSON {
        let cancellation = BlockingWorkCancellation()
        return try await withTaskCancellationHandler {
            try await historyWindow(params, cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }
    private func historyWindow(_ params: JSON, cancellation: BlockingWorkCancellation) async throws -> JSON {
        try cancellation.checkCancellation()
        let cursor: ConversationCursor? = params["cursor"].isNull ? nil : try JSONDecoder().decode(ConversationCursor.self, from: params["cursor"].data())
        // Retained readers can follow a same-ID runtime replacement using
        // their stable message boundary. Branch and entry checks still apply.
        let rebind = params["rebind"].flag == true
        if let cursor, (!rebind && cursor.incarnation != displayEpoch) || cursor.lineage != presentationTimeline {
            throw AgentError("history_changed", "This conversation changed. Reload the visible history.")
        }
        let entry = cursor?.entry ?? params["entry"].text
        // "edge": "start" reads the chat's first page, wherever the reader is.
        let fromStart = params["edge"].text == "start"
        // "position": the page starting at that row of the timeline shown
        // (0 is the chat's first), where the reader dragged the scroller to.
        let position = params["around"].isNull && !fromStart ? params["position"].int.map { max(0, $0) } : nil
        // A chat opened from its metadata file learns where its older rows
        // are the first time a page reaches past the rows it loaded, without
        // holding the actor: the chat is read again after.
        if olderRows > 0, olderIndex == nil {
            let at = entry.flatMap { id in visible.firstIndex { $0.id == id } }, target = params["around"].text
            let older = params["direction"].text != "newer" && target == nil
            if fromStart || (position.map { $0 < olderRows } ?? false) || (entry != nil && at == nil) || (target.map { id in !visible.contains { $0.id == id } } ?? false) || (older && at == 0) { try await loadOlderRows() }
        }
        try cancellation.checkCancellation()
        let lineage = presentationTimeline
        if let cursor, (!rebind && cursor.incarnation != displayEpoch) || cursor.lineage != lineage {
            throw AgentError("history_changed", "This conversation changed. Reload the visible history.")
        }
        if let oldLineage = params["lineage"].text, oldLineage != lineage { throw AgentError("history_changed", "The conversation branch changed during source handoff") }
        return try withShownRows { shown in
            shown.cancellation = cancellation
            shown.readStep = historyPageStep
            let boundary = entry.flatMap(shown.position)
            if entry != nil && boundary == nil { throw AgentError("history_changed", "The history boundary is no longer available. Reload history.") }
            let target = params["around"].text
            let around = fromStart ? (shown.count > 0 ? 0 : nil)
                : position.map { shown.count > 0 ? min(max(0, $0 - shown.base), shown.count - 1) : nil } ?? target.flatMap(shown.position)
            if !fromStart && target != nil && around == nil { throw AgentError("message_missing", "That message is outside the current branch. Its retained content is still inspectable.") }
            let forward = params["direction"].text == "newer" || around != nil
            let range = HistoryWindowPolicy.range(count: shown.count, before: forward ? nil : boundary,
                                                  after: forward ? boundary : nil, around: around, isUser: shown.isUser)
            try shown.prefetch(range)
            let candidates = try range.map { try shown.row($0) }
            let keys = Set(candidates.compactMap { message in message.taskExecutionID.map { TaskPresentationRecord.identity(message.taskRootID ?? "", $0) } })
            let sourceIDs = Set(candidates.map(\.id))
            let tasks = try JSON.parse(JSONEncoder().encode(recentTaskPresentations.filter { keys.contains($0.key) || $0.anchorSourceID.map(sourceIDs.contains) == true }))
            var rows: [JSON] = [], bytes = HistoryWindowPolicy.metadataAllowance + (try tasks.data().count)
            var start = forward ? range.lowerBound : range.upperBound, end = start
            let positions = forward ? Array(range) : Array(range.reversed())
            for index in positions {
                historyPageStep?("history")
                try cancellation.checkCancellation()
                let row = boundedDisplayRow(try displayShown(candidates[index - range.lowerBound], &shown))
                let size = try row.data().count
                guard rows.isEmpty || bytes + size + 1 <= HistoryWindowPolicy.envelopeBytes else { break }
                bytes += size + 1
                if forward { rows.append(row); end = index + 1 }
                else { rows.insert(row, at: 0); start = index }
            }
            func boundaryValue(_ entry: String) throws -> JSON {
                try JSON.parse(JSONEncoder().encode(ConversationCursor(incarnation: displayEpoch, lineage: lineage, entry: entry)))
            }
            let base = shown.base
            var result: JSON = ["version":2,"messages":.array(rows),"total":JSON(base + shown.count),
                "incarnation":JSON(displayEpoch),"lineage":JSON(lineage),"start":JSON(base + start),"end":JSON(base + end),
                "older": (start > 0 || base > 0) && !rows.isEmpty ? try boundaryValue(shown.id(start)) : .null,
                "newer": end < shown.count && !rows.isEmpty ? try boundaryValue(shown.id(end - 1)) : .null]
            if start < shown.count && !shown.isUser(start), let input = (0..<start).last(where: shown.isUser) {
                result["partialTurnInput"] = JSON(shown.id(input))
            }
            result["taskRecords"] = tasks
            try cancellation.checkCancellation()
            return result
        }
    }
    /// Complete tool arguments. Large documents use automatic IPC transfer
    /// paging; expanding a card must not cut an edit or a file's contents.
    public func toolInput(messageID: String, callID: String) async throws -> JSON {
        if messageID == partialID, let card = partialTools[callID] {
            // A streaming call has no document yet: its arguments are still
            // arriving as text. Say so rather than hand over unparseable JSON.
            let input = partialToolInputs[callID] ?? ""
            return ["id": JSON(callID), "messageId": JSON(messageID), "name": card["name"], "input": JSON(input),
                    "inputTruncated": card["inputTruncated"], "inputBytes": JSON(input.utf8.count), "streaming": true]
        }
        guard let message = try await retainedMessage(messageID) else { throw AgentError("message_missing", "Message is not retained") }
        guard let block = message.content.first(where: { $0["type"].text == "toolCall" && $0["id"].text == callID }) else {
            throw AgentError("tool_call_missing", "That message does not retain this tool call")
        }
        let input = block["arguments"].encoded()
        return ["id": JSON(callID), "messageId": JSON(messageID), "name": block["name"], "input": JSON(input),
                "inputTruncated": false, "inputBytes": JSON(input.utf8.count), "streaming": false]
    }
    public func messageRead(id: String, field: String, offset: Int) async throws -> JSON {
        guard let message=try await retainedMessage(id) else { throw AgentError("message_missing", "Message is not retained") }; return try textPage(field == "thinking" ? message.thinking : message.retainedDisplayText,offset:offset)
    }
    public func eventPage(since: Int?) -> JSON { let since=since ?? max(0,sequence-128); return ["events":.array(events.filter{($0["seq"].int ?? 0)>since}.prefix(128).map{$0}),"seq":JSON(sequence),"resyncRequired":JSON(since < (events.first?["seq"].int ?? 1)-1)] }
    private var contentKey: RetainedContent.Key { .init(generation: contentGeneration, revision: contentRevision) }

    private func retainedContent() async throws -> RetainedContent {
        try throwIfClosed(); try Task.checkCancellation()
        if olderRows > 0 { try await loadOlderRows() }
        let key = contentKey
        if let contentCache, contentCache.key == key { return contentCache }
        let reader: @Sendable () async throws -> Void
        if let pending = contentLoad, pending.key == key, let joined = pending.load.reader() { historyLoadJoins += 1; reader = joined }
        else {
            contentLoad?.load.cancel()
            Discarded.release(contentCache); contentCache = nil
            let load = SharedHistoryLoad()
            guard let first = load.reader() else { throw CancellationError() }
            reader = first; contentLoad = (key, load)
            let older = olderIndex, visible = visible, url = older == nil ? nil : journal?.url, step = historyPageStep
            load.start(Task {
                var made: RetainedContent?
                do {
                    made = try await BlockingWorkExecutor.shared.run { cancellation in
                        try RetainedContent.build(key: key, older: older, visible: visible, url: url, cancellation: cancellation, step: step)
                    }
                    try self.throwIfClosed(); try Task.checkCancellation()
                    guard self.contentKey == key else { throw AgentError("history_changed", "History changed; refresh the selection") }
                    self.contentCache = made
                    load.finish(.success(()))
                } catch {
                    Discarded.release(consume made)
                    load.finish(.failure(error))
                }
                if self.contentLoad?.load === load { self.contentLoad = nil }
            })
        }
        do { try await reader() }
        catch is OlderRows.Unreadable {
            try throwIfClosed(); try Task.checkCancellation()
            // A stale offset is recovered by the existing off-actor full read.
            try await loadFullHistory()
            return try await retainedContent()
        } catch { try throwIfClosed(); throw error }
        try throwIfClosed(); try Task.checkCancellation()
        guard contentKey == key, let contentCache, contentCache.key == key else { throw AgentError("history_changed", "History changed; refresh the selection") }
        return contentCache
    }
    public func contentSearch(_ params: JSON) async throws -> JSON {
        let query = params["query"].text ?? "", start = try boundedInt(params["start"], maximum: 100000)
        guard query.count <= 256 else { throw AgentError("search_limit", "Search query too long") }
        let content = try await retainedContent()
        var result = try await BlockingWorkExecutor.shared.run { try content.search(query: query, start: start, cancellation: $0) }
        try throwIfClosed(); try Task.checkCancellation()
        guard content.key == contentKey else { throw AgentError("history_changed", "History changed; refresh the selection") }
        result["revision"] = JSON(contentRevision)
        if params["retained"].flag == true {
            result["digest"] = JSON(content.digest); result["incarnation"] = JSON(displayEpoch)
            result["rowHashes"] = JSON(content.encodedRowHashes)
            result["revision"] = JSON(content.revision)
        }
        return result
    }
    // A branch shortens the visible timeline, so its count alone cannot
    // identify a selection. Rows not loaded count as a chat holding every row
    // counts them.
    var contentRevision: String {
        guard let olderIndex else { return "\(visible.count):\(history.count)" }
        return "\(olderIndex.shown + visible.count):\(olderIndex.historyRows + history.count)"
    }
    public func contentPage(_ params: JSON) async throws -> JSON {
        if let incarnation = params["incarnation"].text, incarnation != displayEpoch { throw AgentError("history_changed", "The conversation runtime changed; validate the retained selection") }
        let first = try boundedInt(params["first"], fallback: 1, maximum: 100000), last = try boundedInt(params["last"], maximum: 100000)
        let index = try boundedInt(params["index"], fallback: 1, maximum: 100000), offset = try boundedInt(params["offset"], maximum: 128*1024*1024)
        let digest = params["digest"].text
        if digest != nil, params["incarnation"].text != displayEpoch { throw AgentError("history_changed", "The conversation runtime changed; validate the retained selection") }
        while true {
            let key = contentKey
            let content: RetainedContent
            do { content = try await retainedContent() }
            catch let error as AgentError where digest != nil && error.code == "history_changed" { continue }
            catch is CancellationError where digest != nil && !Task.isCancelled && key != contentKey { continue }
            // Legacy readers bind the whole snapshot. Range-aware readers carry
            // their original row identities, so an unrelated row may change.
            if digest == nil, ![contentRevision, content.revision].contains(params["revision"].text ?? "") {
                throw AgentError("history_changed", "History changed; refresh the selection")
            }
            let page = try await BlockingWorkExecutor.shared.run { try content.page(first: first, last: last, index: index, offset: offset, digest: digest, cancellation: $0) }
            try throwIfClosed(); try Task.checkCancellation()
            if content.key != contentKey {
                if digest != nil { continue }
                throw AgentError("history_changed", "History changed; refresh the selection")
            }
            return page
        }
    }
}
