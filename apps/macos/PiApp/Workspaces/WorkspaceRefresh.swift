import Foundation

// The snapshot loop. One `status` round trip per chat carries its rows, run
// state, queue, context and metrics; this applies the parts that changed and
// nothing else, and decides when an idle project's helper can go.

extension WorkspaceModel {
    func refresh(_ id: String) {
        guard let item = record(id), let host = hosts[item.workspaceID], opened.contains(id) else { return }
        let view = displays[id] ?? SessionDisplay(id: id); displays[id] = view
        view.dirty = true
        guard !view.snapshotInFlight else { return }
        guard host.isReady, let connection = host.connectionID else { view.dirty = false; return }
        view.snapshotInFlight = true
        Task {
            defer {
                view.snapshotInFlight = false
                let refreshAgain = view.dirty && displays[id] === view
                view.dirty = false
                // A replacement connection can request another refresh while
                // the old one is unwinding. Preserve that request, but never
                // let a retired display restart work for its replacement.
                if refreshAgain { refresh(id) }
            }
            view.dirty = false
            @MainActor func current() -> Bool {
                !Task.isCancelled && !accountingStopped && displays[id] === view &&
                hosts[item.workspaceID] === host && host.isReady && host.connectionID == connection &&
                opened.contains(id) && record(id)?.workspaceID == item.workspaceID &&
                record(id)?.profileID == item.profileID && record(id)?.toolMode == item.toolMode
            }
            do {
                guard current() else { return }
                let visible = id == selectedID || sides[selectedID ?? ""]?.id == id
                var params: [String: WireValue] = ["includeMessages": .bool(!view.browsingHistory)]
                if let epoch = view.monitoringEpoch { params["monitoringEpoch"] = .string(epoch) }
                if let cursor = view.monitoringCursor { params["monitoringCursor"] = .number(cursor) }
                let generation = view.presentationGeneration
                let requestedViewport = view.viewportRequest
                let requestedRevision = view.projectionRevision
                if let requestedRevision { params["displayRevision"] = .string(requestedRevision) }
                // Ask for changes to the page this display holds rather than
                // the page itself. The helper falls back to a whole page for
                // any revision it did not just send, which is also the resync.
                if let revision=view.footer.contextStateRevision { params["contextStateRevision"] = .string(revision) }
                if let revision = view.footer.contextObservationRevision { params["contextObservationRevision"] = .string(revision) }
                if requestedRevision != nil, !view.projectedRows.isEmpty { params["messageDelta"] = .bool(true) }
                // Human-readable footer accounting refreshes at 4 Hz. Decide
                // here, so a poll that will not show those figures does not
                // carry them: they are larger than the token that changed.
                let wantsMetrics = !view.busy || ProcessInfo.processInfo.systemUptime - view.footerUpdatedAt >= 0.25
                params["includeMetrics"] = .bool(wantsMetrics)
                let result = try await host.request(visible ? "session.snapshot" : "session.status", sessionID: id, params: params).object ?? [:]
                guard current() else { return }
                await applySideStatus(id: id, result: result)
                guard current() else { return }
                let sequence = result["seq"]?.number ?? -1
                // Decoding and applying the page happen off the main
                // actor; only the finished rows cross back to it.
                var incoming: [TranscriptMessage]?, resyncNeeded = false
                if !view.browsingHistory, view.presentationGeneration == generation {
                    if let value = result["messages"] {
                        incoming = try await Task.detached { try TranscriptMessage.page(value) }.value
                    } else if let patch = result["messageDelta"] {
                        let held = view.projectedRows
                        let applied = await Task.detached { TranscriptRowUpdates.apply(patch, to: held) }.value
                        if let applied { incoming = applied } else { resyncNeeded = true }
                    }
                }
                guard current() else { return }
                guard view.presentationGeneration == generation else { view.dirty = true; return }
                guard view.browsingHistory || (view.projectionRevision == requestedRevision && view.viewportRequest == requestedViewport) else {
                    view.dirty = true; return
                }
                let lifecycle = result["taskPresentation"].flatMap { value in
                    try? JSONDecoder().decode(TaskPresentationProjection.self, from: JSONEncoder().encode(value))
                }
                if sequence >= view.lastSequence {
                    view.beginTranscriptBatch()
                    defer { view.endTranscriptBatch() }
                    if let lifecycle, lifecycle.valid, lifecycle.sessionID == id, !resyncNeeded,
                       Double(lifecycle.sequence) == sequence, lifecycle.sourceRevision == result["displayRevision"]?.string,
                       lifecycle.epoch == result["monitoring"]?.object?["epoch"]?.string,
                       view.presentation.identity.map({ $0.lineage == lifecycle.timeline }) ?? true {
                        view.taskPresentation = lifecycle
                    }
                    view.lastSequence = sequence
                    observeAssistantOutputs(sessionID: id, snapshot: result)
                    observeSessionCompletion(sessionID: id, snapshot: result)
                    view.observeCompaction(result)
                    let wasBusy = view.busy
                    view.observeRunState(result)
                    if wasBusy, view.state == "error" { markRunFailed(sessionID: id) }
                    view.observeRetry(result)
                    let queue = result["queue"]?.array?.compactMap(\.object) ?? []; if view.queue != queue { view.queue = queue }
                    view.queueCount = Int(result["queueCount"]?.number ?? 0)
                    let now = ProcessInfo.processInfo.systemUptime
                    // Phase changes cannot wait for the footer throttle: a
                    // quiet tool may have no subsequent event until it ends.
                    view.activity = result["activity"]?.object ?? [:]; view.activityObservedAt = now
                    // Phase, queue depth and the last route are plain stored
                    // values: nothing observes them. The status panel used to
                    // find out by recounting every chat once a second.
                    // The same decision that asked the helper for the figures.
                    view.observeContext(result)
                    if let monitoring = result["monitoring"]?.object {
                        liveActivity.ingest(monitoring, workspace: item.workspaceID, session: id, connectionTest: item.connectionTest == true)
                        view.monitoringEpoch = monitoring["epoch"]?.string; view.monitoringCursor = monitoring["cursor"]?.number
                    }
                    if wantsMetrics {
                        view.footerUpdatedAt = now
                        if let timing = result["turnMetrics"]?.object, timing != view.turnTiming { view.turnTiming = timing }
                        if let metrics = result["latestAttempt"]?.object, metrics != view.metrics { view.metrics = metrics }
                    } else if wasBusy && !view.busy {
                        // This reply may be the last event of a fast run. Its
                        // request opted out of metrics while the turn was
                        // still live; fetch the final observations once now,
                        // instead of waiting for another event or tab switch.
                        view.dirty = true
                    }
                    if let mode = result["captureMode"]?.string, mode != view.captureMode { view.captureMode = mode }
                    view.displayObservedAt = result["displayObservedAt"]?.number.map { $0 + host.clockOffset }
                    if let start = view.displayObservedAt { PerformanceProbe.shared.observe("deltaToNativeSnapshotMs", milliseconds: PerformanceProbe.now - start) }
                    if let projected = incoming, !view.browsingHistory, view.presentationGeneration == generation {
                        let incarnation = result["historyIncarnation"]?.string, lineage = result["historyLineage"]?.string
                        if let held = view.presentation.identity, let lineage, held.lineage != lineage {
                            view.newerPage.error = "This conversation's branch changed. Use Latest to reload."
                            view.browsingHistory = true
                        } else {
                        let overlaps = view.messages.isEmpty || projected.contains { row in view.messages.contains { $0.id == row.id } }
                        if !overlaps, let last = view.messages.last, let incarnation, let lineage {
                            view.newerPage = .init(cursor: .init(incarnation: incarnation, lineage: lineage, entry: last.id))
                            view.browsingHistory = true
                        }
                        view.historyRevision = nil
                        view.projectedRows = projected
                        // Rows the reader scrolled up to stay in front of the helper's window.
                        var messages = TranscriptPaging.window(TranscriptPaging.merge(previous: view.messages, live: projected), keepingEarlier: false)
                        var protected = view.pinnedHistoryIDs
                        if let anchor = view.scrollAnchor, !anchor.followsBottom,
                           view.messages.contains(where: { $0.id == anchor.id }) { protected.insert(anchor.id) }
                        if !protected.isEmpty, !protected.isSubset(of: Set(messages.map(\.id))), let last = view.messages.last,
                           let incarnation, let lineage {
                            // Receiving output may fill the resident budget,
                            // but must not evict text the reader is using.
                            view.newerPage = .init(cursor: .init(incarnation: incarnation, lineage: lineage, entry: last.id))
                            view.browsingHistory = true
                            messages = view.messages
                        }
                        // Touch only the rows whose accounting actually moved:
                        // writing every row copies the whole page's storage and
                        // retains every string in it, once per streamed token.
                        for index in messages.indices where messages[index].accounting != view.messageAccounting[messages[index].id] {
                            messages[index].accounting = view.messageAccounting[messages[index].id]
                        }
                        if view.messages != messages {
                            let accountingChanged = Self.accountingTargetsChanged(from: view.messages, to: messages)
                            view.messages = messages
                            // A newly visible answer can take ownership of
                            // a request whose metadata arrived before it.
                            if accountingChanged { scheduleAccounting(id, workspaceID: item.workspaceID) }
                        }
                        view.projectionRevision = result["displayRevision"]?.string
                        if let before = result["before"] { view.hostBefore = before.number }
                        if overlaps, let incarnation, let lineage, let first = messages.first {
                            view.presentation.identity = (incarnation, lineage)
                            let liveOlder = try ConversationHistoryPage.cursor(result["historyOlder"])
                            if messages.first?.id == projected.first?.id { view.olderPage = .init(cursor: liveOlder) }
                            else if view.olderPage.cursor != nil { view.olderPage.cursor = .init(incarnation: incarnation, lineage: lineage, entry: first.id) }
                            view.before = view.olderPage.cursor?.entry
                        }
                        if view.historyState == .dormant || view.historyState == .empty { view.historyState = messages.isEmpty ? .empty : .preparing }
                        }
                    } else if resyncNeeded {
                        // The update does not fit the page held here. Forget
                        // the cursor so the next read is a whole page.
                        view.projectedRows = []; view.projectionRevision = nil; view.dirty = true
                    } else if !view.browsingHistory && view.projectionRevision != requestedRevision {
                        view.dirty = true // An intervening page change needs a fresh full projection.
                    }
                    let notice = item.isBackgroundTask ? (record(id)?.backgroundTaskNotice ?? "Tools disabled · Title generation") : item.connectionTest == true || item.workspaceID == WorkspaceRecord.scratchID ? "Tools disabled · Connection test" : item.toolMode == "read-only" ? "Read-only tools" : ""
                    // An interruption or preflight explanation stays until the
                    // user has reviewed it; the static tool notice must not replace it.
                    if view.notice != notice, !view.uncertain, view.failureMessage == nil { view.notice = notice }
                    if let preflight = result["preflightError"]?.string { if view.failureMessage == nil { view.notice = preflight }; view.uncertain = true }
                }
                if let path = result["path"]?.string, let index = chats.firstIndex(where: { $0.id == id }), chats[index].path != path {
                    chats[index].path = path; try await store?.put(chats[index], kind: "chat", id: id)
                    guard current() else { return }
                }
                let intents = try await store?.list(CommandIntent.self, kind: "pending:\(id)") ?? []
                guard current() else { return }
                for var intent in intents {
                    guard let receipt = result["commands"]?.array?.compactMap(\.object).last(where: { $0["commandId"]?.string == intent.id }), let state = receipt["state"]?.string else { continue }
                    if state != "dispatched" {
                        intent.state = state; intent.text = ""; intent.attachments = nil; intent.skills = nil
                        try await store?.put(intent, kind: "receipt:\(id)", id: intent.id)
                        guard current() else { return }
                        try await store?.remove(kind: "pending:\(id)", id: intent.id)
                        guard current() else { return }
                    }
                }
                let recovered = try await store?.list(CommandIntent.self, kind: "pending:\(id)") ?? []
                guard current() else { return }
                if recovered != view.recovered { view.recovered = recovered }
                if view.recovered.isEmpty { view.uncertain = false }
                updateHostActivity(workspaceID: item.workspaceID)
                scheduleIdle(workspaceID: item.workspaceID, host: host)
            } catch { if current() { view.notice = error.localizedDescription } }
        }
    }
    func cancelIdle(workspaceID: String) { idleTasks.removeValue(forKey: workspaceID)?.cancel() }
    func scheduleIdle(workspaceID: String, host: HostSupervisor) {
        idleTasks[workspaceID]?.cancel(); guard !host.isBusy, !sides.values.contains(where: { $0.workspaceID == workspaceID && !$0.kept && !$0.pending }) else { return }
        let grace = configuration.runtime.idleGraceSeconds
        idleTasks[workspaceID] = Task { try? await Task.sleep(for: .seconds(grace)); guard !Task.isCancelled, !host.isBusy else { return }
            host.shutdown(); opened.subtract(chats.filter { $0.workspaceID == workspaceID }.map(\.id))
        }
    }
    static let archivedNotice = "This chat is archived. Restore it to continue."
    static let recoveredCopy = ChatQuestion(
        title: "Create a recovered copy?",
        detail: "Preserve the entire original in app storage, then omit only its incomplete final record in a new independent chat. Corruption before the final record will still be rejected. Review any interrupted tool effects before continuing.",
        action: "Preserve and Recover Copy")
    static let portableDraft = ChatQuestion(
        title: "Prepare a portable context draft?",
        detail: "Create a new chat with editable text from Pi's compaction-aware context. Thinking, signatures, encrypted data, images, tool arguments and continuation cursors are omitted. A 128 KiB text limit applies. The complete original is preserved. Nothing is sent until you review and press Send.",
        action: "Create Draft")
    static let uncertainOutcome = ChatQuestion(
        title: "Previous command outcome is uncertain",
        detail: "Review the transcript and any file or tool effects. Sending again starts a new command and may repeat effects.",
        action: "I Reviewed It — Send New Command")
}
