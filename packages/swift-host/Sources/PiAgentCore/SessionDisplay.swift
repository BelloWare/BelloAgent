import Foundation

// The display projection: the bounded page of rows a reader sees, what
// changed since the page it already holds, and the snapshot that carries it.

extension AgentSession {
    struct DisplayRow {
        let value: JSON
        let bytes: Int
        /// Identity of this row's encoded content. A cached row keeps its
        /// version, so a reader that already has it needs nothing sent.
        let version: UInt64
    }
    /// The streamed row as the last projection built it. Comparing these
    /// fields is how the next read decides it can send the tokens that
    /// arrived instead of the whole row again.
    struct StreamingRowState {
        let id: String, text: String, thinking: String, cards: UInt64, truncated: Bool
    }
    struct DisplayProjection {
        let start: Int
        let messages: [JSON]
        /// The settled rows of the page in display order, with their versions.
        /// `messages` is these rows followed by the streaming row, if any.
        let settled: [(id: String, version: UInt64)]
        let streaming: StreamingRowState?
    }
    var displayRevision: String { "\(displayEpoch):\(displayGeneration)" }
    func recordDisplayChange(_ messageID: String?, at: Double) {
        let retained = Set(visible.suffix(60).map(\.id) + (partialID.map { [$0] } ?? []))
        pendingDisplayObservations = pendingDisplayObservations.filter { retained.contains($0.key) }
        guard let messageID, retained.contains(messageID) else { return }
        invalidateDisplay(messageID)
        guard at.isFinite, at >= 0 else { return }
        pendingDisplayObservations[messageID] = min(pendingDisplayObservations[messageID] ?? at, at)
    }
    func invalidateDisplay(_ messageID: String? = nil, allRows: Bool = false) {
        displayGeneration &+= 1; displayProjection=nil
        if allRows { displayRows.removeAll(keepingCapacity: true) }
        else if let messageID { displayRows.removeValue(forKey: messageID) }
    }
    func projectedDisplay() -> DisplayProjection {
        if let displayProjection { return displayProjection }
        displayProjectionBuildCount += 1
        var rows: [DisplayRow]=[], bytes=2, retainedCount=0, retainedIDs=Set<String>()
        func append(_ row: DisplayRow) -> Bool {
            let next=bytes+row.bytes+(rows.isEmpty ? 0:1)
            guard rows.isEmpty || next<=300_000 else { return false }
            bytes=next; rows.append(row); return true
        }
        var streaming: StreamingRowState?
        if let partialID {
            let cards=partialToolOrder.compactMap{partialTools[$0]}
            // The two bounded documents are cached across deltas: rebuilding
            // them per token copied the whole reply so far, every token.
            let text=partialTextPreview ?? { let value=preview(partialText,bytes:Self.streamedTextBytes); partialTextPreview=value; return value }()
            let thinking=partialThinkingPreview ?? { let value=preview(partialThinking,bytes:Self.streamedThinkingBytes); partialThinkingPreview=value; return value }()
            let truncated=partialText.utf8.count>Self.streamedTextBytes || partialThinking.utf8.count>Self.streamedThinkingBytes || partialToolSeen.count>cards.count
            let value:JSON=["id":JSON(partialID),"role":"assistant","text":JSON(text),"thinking":JSON(thinking),"tools":.array(cards),"state":"streaming","toolCallCount":0,"truncated":JSON(truncated)]
            displayRowVersion &+= 1
            _=append(DisplayRow(value:value,bytes:(try? value.data().count) ?? 1_048_576,version:displayRowVersion))
            streaming=StreamingRowState(id:partialID,text:text,thinking:thinking,cards:partialCardsVersion,truncated:truncated)
        }
        // JSON array size is the encoded row sizes plus brackets and commas.
        // Walk backwards until the suffix is full rather than projecting rows
        // that will immediately be dropped. Retain its one boundary candidate
        // so a changing partial does not rebuild that same excluded row.
        var settled: [(id: String, version: UInt64)]=[]
        for message in visible.suffix(60).reversed() {
            let row: DisplayRow
            if let cached=displayRows[message.id] { row=cached }
            else {
                displayRowProjectionCount += 1
                let value=displayMessage(message)
                displayRowVersion &+= 1
                row=DisplayRow(value:value,bytes:(try? value.data().count) ?? 1_048_576,version:displayRowVersion)
                displayRows[message.id]=row
            }
            retainedIDs.insert(message.id)
            guard append(row) else { break }
            retainedCount += 1
            settled.append((message.id,row.version))
        }
        displayRows=displayRows.filter { retainedIDs.contains($0.key) }
        let result=DisplayProjection(start:visible.count-retainedCount,messages:rows.reversed().map(\.value),settled:settled.reversed(),streaming:streaming)
        displayProjection=result
        return result
    }
    /// What changed since the page the reader already holds: the rows whose
    /// content is new, the tokens appended to the row still arriving, and the
    /// row order when it moved. Nil when no such page was recorded, in which
    /// case the whole page is sent instead.
    func messagePatch(_ projection: DisplayProjection) -> JSON? {
        guard let base=sentRevision else { return nil }
        var rows: [JSON]=[], appends: [JSON]=[]
        for (index,entry) in projection.settled.enumerated() where sentVersions[entry.id] != entry.version {
            guard projection.messages.indices.contains(index) else { return nil }
            rows.append(projection.messages[index])
        }
        if let streaming=projection.streaming {
            let index=projection.settled.count
            guard projection.messages.indices.contains(index) else { return nil }
            if let sent=sentStreaming, sent.id == streaming.id, sent.cards == streaming.cards, sent.truncated == streaming.truncated,
               let text=appendedText(sent.text,streaming.text), let thinking=appendedText(sent.thinking,streaming.thinking) {
                if !text.isEmpty || !thinking.isEmpty { appends.append(["id":JSON(streaming.id),"text":JSON(text),"thinking":JSON(thinking)]) }
            } else { rows.append(projection.messages[index]) }
        }
        var patch: JSON=["base":JSON(base),"rows":.array(rows),"appends":.array(appends)]
        let order=projection.settled.map(\.id)+(projection.streaming.map { [$0.id] } ?? [])
        if order != sentOrder { patch["order"] = .array(order.map { JSON($0) }) }
        return patch
    }
    /// Records the page just sent, so the next read can describe itself as a
    /// change to it.
    func recordSent(_ projection: DisplayProjection, revision: String) {
        sentRevision=revision
        sentOrder=projection.settled.map(\.id)+(projection.streaming.map { [$0.id] } ?? [])
        var versions: [String: UInt64]=[:]
        for entry in projection.settled { versions[entry.id]=entry.version }
        sentVersions=versions; sentStreaming=projection.streaming
    }
    func displayMessage(_ message: ChatMessage) -> JSON {
        var states: [String: JSON] = [:]
        for call in message.content where call["type"].text == "toolCall" {
            guard let id = call["id"].text else { continue }
            if toolStateOwners[id] == message.id, let live = toolStates[id] { states[id] = live; continue }
            guard let index = toolHistory.results[message.id]?[id], history.indices.contains(index) else { continue }
            let result = history[index], output = result.text
            // Old journals retain isError and exact result text, but not an
            // execution clock or a reliable failure-vs-cancellation enum. Keep
            // those limits honest; an unknown/error outcome is never completed.
            let stats = result.toolStats ?? .null, fields = toolInputFields(call["arguments"]), keptOutput = encodedPreview(output, bytes: 4096)
            let inputTruncated = fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false
            states[id] = merging(["id": JSON(id), "name": call["name"], "state": JSON(result.isError ? "failed" : "completed"),
                          "output": JSON(keptOutput),
                          "durationMs": stats["durationMs"], "truncated": JSON(inputTruncated || keptOutput.utf8.count < output.utf8.count),
                          "path": stats["path"], "added": stats["added"], "removed": stats["removed"]], fields)
        }
        return message.view(toolStates: states)
    }
    /// What the live bar says the session is doing right now, in the order a
    /// reader cares about: a stopped run before a busy one, and what the run
    /// is waiting on before the fact that it is running at all.
    func activitySnapshot() -> JSON {
        let phase = state=="error" ? "error" : state=="paused" ? "paused" : state=="stopping" ? "stopping" : runStatus=="compacting" ? "compacting" : runStatus=="waitingTool" ? "tool" : modelActive ? "model" : state=="running" ? "starting" : "idle"
        let names=Set(toolStates.values.filter { $0["state"].text=="running" }.compactMap { $0["name"].text }).sorted()
        return ["version":2,"phase":JSON(phase),"model":JSON(turnProfile.model),"modelActive":JSON(modelActive),
                "pendingFollowUps":JSON(queue.count),"pendingSteering":JSON(steering.count),"queuePaused":JSON(queuePaused),
                "toolNames":.array(names.prefix(16).map { JSON($0) })]
    }
    public func snapshot(_ params: JSON = [:]) async -> JSON {
        await snapshot(params, traceSnapshot: { [traces, id] in
            let latest = await traces.latest(id)
            return (latest, await traces.mode(id))
        })
    }
    // The trace actor may be busy persisting a streamed body. Keep its awaited
    // read separate from taking the display projection, including in tests.
    func snapshot(_ params: JSON, traceSnapshot: @Sendable () async -> (latest: JSON, mode: String)) async -> JSON {
        await flushRequestLinks()
        let revision=displayRevision
        let includesMessages = params["includeMessages"].flag != false && params["displayRevision"].text != revision
        let projection=includesMessages ? projectedDisplay() : displayProjection
        let messages=includesMessages ? projection?.messages ?? [] : []
        var observedAt: Double?
        if includesMessages {
            // Do not consume on status-only or unchanged-revision polls. Only
            // the rows actually included in the byte-bounded page are observed.
            // Consume before the await: a delta arriving while latest() runs
            // belongs to the NEXT projection, not this captured message array.
            for message in messages {
                if let id = message["id"].text, let at = pendingDisplayObservations.removeValue(forKey: id) { observedAt = min(observedAt ?? at, at) }
            }
        }
        var value: JSON=["sessionId":JSON(id),"seq":JSON(sequence),"state":JSON(state),"runStatus":JSON(runStatus),"retry":retryInfo,"settingsPending":JSON(pendingConfiguration != nil),"preflightError":errorMessage.map { JSON($0) } ?? .null,"side":parentInfo,"ephemeral":JSON(ephemeral),"keeping":false,"keepRequested":JSON(keepRequested),"keepError":.null,"queue":.array(queue.map { var v=$0.previewValue;v["kind"]="follow-up";return v }+steering.map { var v=$0.previewValue;v["kind"]="steering";v["text"]=JSON("[Steering] "+(v["text"].text ?? ""));return v }),"steering":.array(steering.map(\.previewValue)),"queueCount":JSON(queue.count+steering.count),"queuePaused":JSON(queuePaused),"path":path.map { JSON($0) } ?? .null,"commands":.array(commands),"total":JSON(visible.count),"displayRevision":JSON(revision),"profileId":JSON(profile.id),"toolMode":JSON(readOnly ? "read-only" : "editing"),"context":contextInfo(),"turnMetrics":turnMetrics(),"assistantMessageCount":JSON(assistantMessageCount),"latestAssistantMessageId":latestAssistantMessageID.map { JSON($0) } ?? .null,"activity":activitySnapshot()]
        // Page cursors describe a materialized projection only. A status-only
        // read must not build a hidden page merely to compute its byte limit.
        if let projection { value["before"]=projection.start>0 ? JSON(projection.start):.null }
        // A completed compaction is a committed summary in active context, not
        // merely the end of a failed/cancelled attempt or a historical row.
        // Include it in status-only and unchanged-projection snapshots too.
        if let summary = context.last(where: { $0.kind == "compaction" }) {
            value["latestSuccessfulCompaction"] = ["id": JSON(summary.id), "detail": summary.detail.map { JSON($0) } ?? .null]
        } else { value["latestSuccessfulCompaction"] = .null }
        if includesMessages, let projection {
            // A reader that says it can apply row updates, and asks from
            // exactly the page it was last sent, is sent only what changed.
            // Everything else gets the whole page, which is also the resync.
            if params["messageDelta"].flag == true, params["displayRevision"].text == sentRevision, let patch=messagePatch(projection) {
                value["messageDelta"] = patch
            } else {
                value["messages"] = .array(messages)
            }
            recordSent(projection, revision: revision)
            if let observedAt { value["displayObservedAt"] = JSON(observedAt) }
        }
        let trace = await traceSnapshot()
        value["captureMode"] = JSON(trace.mode)
        // The footer's figures refresh a few times a second; a reader that is
        // not going to show them this time says so, and a streamed token stops
        // carrying five kilobytes of request accounting it will discard.
        if params["includeMetrics"].flag != false { value["latestAttempt"] = trace.latest }
        else { value = value.removing(["context","turnMetrics"]) }
        return value
    }
    public func turnMetrics() -> JSON { ["startedAt":begin.map { JSON($0) } ?? .null,"endedAt":end.map { JSON($0) } ?? .null,"durationMs":begin.map { JSON((end ?? nowMS())-$0) } ?? .null,"elapsedMs":begin.map { JSON((end ?? nowMS())-$0) } ?? .null,
                                          "modelMs":JSON(turnModelMs),"toolMs":JSON(turnToolMs),"sessionModelMs":cumulativeModelMs.map { JSON($0) } ?? .null,"sessionToolMs":cumulativeToolMs.map { JSON($0) } ?? .null] }
}
