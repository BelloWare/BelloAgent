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
    /// A page whose first turn began before the rows a chat opened from its
    /// metadata file loaded: the read loads where the older rows are and
    /// reads again (`historyWindow(_:cancellation:olderLoaded:)`).
    private struct TurnBeganBeforeLoadedRows: Error {}
    private func historyWindow(_ params: JSON, cancellation: BlockingWorkCancellation, olderLoaded: Bool = false) async throws -> JSON {
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
        do { return try withShownRows { shown in
            shown.cancellation = cancellation
            shown.readStep = historyPageStep
            let boundary = entry.flatMap(shown.position)
            if entry != nil && boundary == nil { throw AgentError("history_changed", "The history boundary is no longer available. Reload history.") }
            let target = params["around"].text
            let around = fromStart ? (shown.count > 0 ? 0 : nil)
                : position.map { shown.count > 0 ? min(max(0, $0 - shown.base), shown.count - 1) : nil } ?? target.flatMap(shown.position)
            if !fromStart && target != nil && around == nil { throw AgentError("message_missing", "That message is outside the current branch. Its retained content is still inspectable.") }
            let forward = params["direction"].text == "newer" || around != nil
            // Whole display turns, as the desktop's journal reader pages them.
            // The first loaded row is the chat's own first only when no row
            // before it is left to load: the loaded rows of a chat opened from
            // its metadata file can begin inside a turn.
            let limits = historyPageLimits
            let range = HistoryWindowPolicy.page(count: shown.count, before: forward ? nil : boundary,
                                                 after: forward ? boundary : nil, around: around, limits: limits,
                                                 firstIsStart: shown.base == 0, startsTurn: shown.startsTurn)
            // A page whose first turn began before the loaded rows needs the
            // rows before them, as a row before them does (`HistoryReader.read`
            // does the same): pages hold whole turns, and that turn, shown from
            // its loaded tail, folded once reading earlier completed it.
            if !olderLoaded, shown.base > 0, range.lowerBound < shown.count, !shown.startsTurn(range.lowerBound),
               !(0..<range.lowerBound).contains(where: shown.startsTurn) { throw TurnBeganBeforeLoadedRows() }
            try shown.prefetch(range)
            let candidates = try range.map { try shown.row($0) }
            let keys = Set(candidates.compactMap { message in message.taskExecutionID.map { TaskPresentationRecord.identity(message.taskRootID ?? "", $0) } })
            let sourceIDs = Set(candidates.map(\.id))
            let tasks = try JSON.parse(JSONEncoder().encode(recentTaskPresentations.filter { keys.contains($0.key) || $0.anchorSourceID.map(sourceIDs.contains) == true }))
            let metadata = HistoryWindowPolicy.metadataAllowance + (try tasks.data().count)
            // Fills the page from `first` on (back from the range's end when
            // reading back). A page read around a row from the start of its
            // turn, whose rows before that row are past the budget, starts at
            // the row instead: the page must hold it.
            func filled(from first: Int) throws -> (rows: [JSON], start: Int)? {
                var read: [JSON] = [], fill = HistoryWindowPolicy.PageFill(forward: forward, bytes: metadata, limits: limits)
                for index in forward ? Array(first..<range.upperBound) : Array(range.reversed()) {
                    historyPageStep?("history")
                    try cancellation.checkCancellation()
                    let row = boundedDisplayRow(try displayShown(candidates[index - range.lowerBound], &shown))
                    guard fill.admit(try row.data().count, startsTurn: shown.startsTurn(index)) else {
                        if forward, let around, around > first, index <= around { return nil }
                        break
                    }
                    read.append(row)
                }
                // A page that ran out of room keeps the whole turns it read.
                read.removeLast(read.count - fill.kept)
                return (forward ? read : read.reversed(), forward ? first : range.upperBound - read.count)
            }
            let page = try filled(from: range.lowerBound) ?? filled(from: around ?? range.lowerBound)!
            let rows = page.rows, start = page.start
            let end = forward ? start + rows.count : range.upperBound
            func boundaryValue(_ entry: String) throws -> JSON {
                try JSON.parse(JSONEncoder().encode(ConversationCursor(incarnation: displayEpoch, lineage: lineage, entry: entry)))
            }
            let base = shown.base
            var result: JSON = ["version":2,"messages":.array(rows),"total":JSON(base + shown.count),
                "incarnation":JSON(displayEpoch),"lineage":JSON(lineage),"start":JSON(base + start),"end":JSON(base + end),
                "older": (start > 0 || base > 0) && !rows.isEmpty ? try boundaryValue(shown.id(start)) : .null,
                "newer": end < shown.count && !rows.isEmpty ? try boundaryValue(shown.id(end - 1)) : .null]
            if start < shown.count && !shown.startsTurn(start), let input = (0..<start).last(where: shown.startsTurn) {
                result["partialTurnInput"] = JSON(shown.id(input))
            }
            // The page's last row ends its turn: the next row, if any, opens
            // one. The last turn of a page that stops short of the newest row
            // then reads as the finished turn it is.
            result["endsTurn"] = JSON(end >= shown.count || shown.startsTurn(end))
            result["taskRecords"] = tasks
            try cancellation.checkCancellation()
            return result
        } } catch is TurnBeganBeforeLoadedRows {
            try await loadOlderRows()
            return try await historyWindow(params, cancellation: cancellation, olderLoaded: true)
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
            result["journalID"] = JSON(id)
            if params["knownRevision"].text != content.revision || params["knownIncarnation"].text != displayEpoch {
                result["rowHashes"] = JSON(content.encodedRowHashes)
            }
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
            let step = historyPageStep
            let page = try await BlockingWorkExecutor.shared.run {
                let page = try content.page(first: first, last: last, index: index, offset: offset, digest: digest, cancellation: $0)
                step?("contentPage")
                return page
            }
            try throwIfClosed(); try Task.checkCancellation()
            if digest == nil, content.key != contentKey {
                throw AgentError("history_changed", "History changed; refresh the selection")
            }
            return page
        }
    }
}
