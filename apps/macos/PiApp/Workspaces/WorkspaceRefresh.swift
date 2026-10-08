import Foundation

// The snapshot loop. One `status` round trip per chat carries its rows, run
// state, queue, context and metrics; this applies the parts that changed and
// nothing else, and decides when an idle project's helper can go.

/// What a snapshot asks of the rows: a whole page, a patch to the page held,
/// or nothing. Done off the main actor.
enum SnapshotRowWork: Sendable {
    case skip, page(WireValue), patch(WireValue, [TranscriptMessage])
    var needed: Bool { if case .skip = self { return false }; return true }
    func apply() throws -> (rows: [TranscriptMessage]?, resync: Bool) {
        switch self {
        case .skip: return (nil, false)
        case .page(let value): return (try TranscriptMessage.page(value), false)
        case .patch(let patch, let held):
            // A patch that does not fit the page held asks for a whole page.
            guard let applied = TranscriptRowUpdates.apply(patch, to: held) else { return (nil, true) }
            return (applied, false)
        }
    }
}

/// Decodes a snapshot's task presentation, reusing the finished tasks of the
/// last one when they arrive unchanged. They are up to 64 records with
/// details of up to 8 KB each, and nearly every snapshot of a running chat
/// repeats them; the JSON round trip of all of them used to run on the main
/// actor for every token.
struct TaskPresentationDecoder: Sendable {
    private var recentSource: WireValue?
    private var recent: [TaskPresentationRecord] = []
    /// How many times the finished tasks were decoded in full (a test seam).
    private(set) var decodes = 0
    mutating func decode(_ value: WireValue) -> TaskPresentationProjection? {
        guard var object = value.object, let source = object["recent"] else { return nil }
        if source != recentSource {
            guard let records = try? JSONDecoder().decode([TaskPresentationRecord].self, from: JSONEncoder().encode(source)) else { return nil }
            recent = records; recentSource = source; decodes += 1
        }
        object["recent"] = .array([])
        guard var projection = try? JSONDecoder().decode(TaskPresentationProjection.self, from: JSONEncoder().encode(WireValue.object(object))) else { return nil }
        projection.recent = recent
        return projection
    }
}

extension WorkspaceModel {
    func refresh(_ id: String) {
        sidebarSearchStorage?.journalChanged()
        guard let item = record(id), let host = hosts[item.workspaceID], opened.contains(id) else { return }
        // Written only when new: every write runs `displays`' observers, which
        // scan every display, and this runs on every event of every chat.
        let view: SessionDisplay
        if let held = displays[id] { view = held } else { view = SessionDisplay(id: id); displays[id] = view }
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
            @MainActor func current() -> Bool { snapshotApplies(id: id, view: view, item: item, host: host, connection: connection) }
            do {
                guard current() else { return }
                let visible = id == selectedID || sides[selectedID ?? ""]?.id == id
                let generation = view.presentationGeneration
                let requestedViewport = view.viewportRequest
                let requestedRevision = view.projectionRevision
                // Human-readable footer accounting refreshes at 4 Hz. Decide
                // here, so a poll that will not show those figures does not
                // carry them: they are larger than the token that changed.
                let wantsMetrics = !view.busy || ProcessInfo.processInfo.systemUptime - view.footerUpdatedAt >= 0.25
                let params = snapshotParams(for: view, requestedRevision: requestedRevision, wantsMetrics: wantsMetrics)
                let result = try await host.request(visible ? "session.snapshot" : "session.status", sessionID: id, params: params).object ?? [:]
                guard current() else { return }
                await applySideStatus(id: id, result: result)
                guard current() else { return }
                let sequence = result["seq"]?.number ?? -1
                // Decoding and applying the page, and decoding the task
                // presentation, happen off the main actor in one hop; only
                // the finished values cross back to it.
                let rows: SnapshotRowWork = !view.browsingHistory && view.presentationGeneration == generation
                    ? result["messages"].map(SnapshotRowWork.page) ?? result["messageDelta"].map { .patch($0, view.projectedRows) } ?? .skip : .skip
                // A snapshot older than the one applied is not applied; its
                // presentation is not worth decoding. A snapshot that leaves
                // it out has an unchanged one: the presentation held stays.
                let presentation = sequence >= view.lastSequence ? result["taskPresentation"] : nil
                var incoming: [TranscriptMessage]?, resyncNeeded = false, lifecycle: TaskPresentationProjection?
                var helperQueue: [[String: WireValue]]?
                if rows.needed || presentation != nil {
                    let decoder = view.taskPresentationDecoder
                    let decoded = try await Task.detached { () throws -> (rows: [TranscriptMessage]?, resync: Bool, lifecycle: TaskPresentationProjection?, decoder: TaskPresentationDecoder) in
                        let applied = try rows.apply()
                        var decoder = decoder
                        let lifecycle = presentation.flatMap { decoder.decode($0) }
                        return (applied.rows, applied.resync, lifecycle, decoder)
                    }.value
                    guard current() else { return }
                    view.taskPresentationDecoder = decoded.decoder
                    incoming = decoded.rows; resyncNeeded = decoded.resync; lifecycle = decoded.lifecycle
                }
                guard current() else { return }
                guard view.presentationGeneration == generation else { view.dirty = true; return }
                guard view.browsingHistory || (view.projectionRevision == requestedRevision && view.viewportRequest == requestedViewport) else {
                    view.dirty = true; return
                }
                if sequence >= view.lastSequence {
                    view.beginTranscriptBatch()
                    defer { view.endTranscriptBatch() }
                    // The reader's own edit landing on its new branch is
                    // adopted here, before anything is matched against the
                    // branch the page holds, and is never reported.
                    if let projected = incoming, !view.browsingHistory, view.presentationGeneration == generation {
                        adoptOwnBranch(view, rows: projected, snapshot: result)
                    }
                    if let lifecycle, lifecycle.valid, lifecycle.sessionID == id, !resyncNeeded,
                       Double(lifecycle.sequence) == sequence, lifecycle.sourceRevision == result["displayRevision"]?.string,
                       lifecycle.epoch == result["monitoring"]?.object?["epoch"]?.string,
                       view.presentation.identity.map({ $0.lineage == lifecycle.timeline }) ?? true {
                        view.adoptTaskPresentation(lifecycle, revision: result["taskPresentationRevision"]?.string)
                    } else if presentation != nil {
                        // Sent but not taken: without a revision held, the
                        // next snapshot carries the presentation again.
                        view.taskPresentationRevision = nil
                    }
                    view.lastSequence = sequence
                    helperQueue = applySnapshotState(result, to: view, id: id, item: item, wantsMetrics: wantsMetrics, clockOffset: host.clockOffset)
                    if let projected = incoming, !view.browsingHistory, view.presentationGeneration == generation {
                        try applySnapshotRows(projected, from: result, to: view, id: id, item: item)
                    } else if resyncNeeded {
                        // The update does not fit the page held here. Forget
                        // the cursor so the next read is a whole page.
                        view.projectedRows = []; view.projectionRevision = nil; view.dirty = true
                    } else if !view.browsingHistory && view.projectionRevision != requestedRevision {
                        view.dirty = true // An intervening page change needs a fresh full projection.
                    }
                    applyToolNotice(result, to: view, id: id, item: item)
                }
                // Looked up by id; finding the index is only needed to write.
                if let path = result["path"]?.string, let known = chatRecord(id), known.path != path, let index = chats.firstIndex(where: { $0.id == id }) {
                    chats[index].path = path; try await store?.put(chats[index], kind: "chat", id: id)
                    guard current() else { return }
                }
                guard try await settleSnapshotIntents(result, view: view, id: id, item: item, host: host, connection: connection, helperQueue: helperQueue) else { return }
                updateHostActivity(workspaceID: item.workspaceID)
                scheduleIdle(workspaceID: item.workspaceID, host: host)
            } catch { if current() { view.notice = error.localizedDescription } }
        }
    }
    /// Whether a snapshot begun for a chat still applies to it: nothing
    /// cancelled it or shut the model down, and the chat still has the same
    /// display, on the same helper and connection, in the same project, with
    /// the same connection and tool mode. Checked after every await.
    private func snapshotApplies(id: String, view: SessionDisplay, item: ChatRecord, host: HostSupervisor, connection: UUID) -> Bool {
        !Task.isCancelled && !isShutDown && displays[id] === view &&
        hosts[item.workspaceID] === host && host.isReady && host.connectionID == connection &&
        opened.contains(id) && record(id)?.workspaceID == item.workspaceID &&
        record(id)?.profileID == item.profileID && record(id)?.toolMode == item.toolMode
    }
    /// What a snapshot asks the helper for. The page this display holds, the
    /// context, receipts and tasks it holds are named by revision, and the
    /// helper leaves out whatever has not changed since.
    private func snapshotParams(for view: SessionDisplay, requestedRevision: String?, wantsMetrics: Bool) -> [String: WireValue] {
        var params: [String: WireValue] = ["includeMessages": .bool(!view.browsingHistory)]
        if let epoch = view.monitoringEpoch { params["monitoringEpoch"] = .string(epoch) }
        if let cursor = view.monitoringCursor { params["monitoringCursor"] = .number(cursor) }
        if let requestedRevision { params["displayRevision"] = .string(requestedRevision) }
        // Ask for changes to the page this display holds rather than
        // the page itself. The helper falls back to a whole page for
        // any revision it did not just send, which is also the resync.
        if let revision=view.footer.contextStateRevision { params["contextStateRevision"] = .string(revision) }
        if let revision = view.footer.contextObservationRevision { params["contextObservationRevision"] = .string(revision) }
        // The receipts and tasks held here, by revision: the helper
        // leaves out whichever has not changed since (up to 128
        // receipts and 64 finished tasks, once per streamed token).
        if view.leavesOutHeldState {
            if let revision = view.commandsRevision { params["commandsRevision"] = .string(revision) }
            if let revision = view.taskPresentationRevision { params["taskPresentationRevision"] = .string(revision) }
        }
        if requestedRevision != nil, !view.projectedRows.isEmpty {
            params["messageDelta"] = .bool(true)
            // Tool arguments still streaming arrive as what was
            // appended to them, not as the whole row again.
            if view.takesToolInputAppends { params["toolInputAppends"] = .bool(true) }
        }
        params["includeMetrics"] = .bool(wantsMetrics)
        return params
    }
    /// A snapshot's run state, cost, retry, queue, activity, context, figures
    /// and capture mode, on the chat's display. Returns the helper's queue,
    /// which the pending submissions are settled against.
    private func applySnapshotState(_ result: [String: WireValue], to view: SessionDisplay, id: String, item: ChatRecord,
                                    wantsMetrics: Bool, clockOffset: Double) -> [[String: WireValue]] {
        observeAssistantOutputs(sessionID: id, snapshot: result)
        observeSessionCompletion(sessionID: id, snapshot: result)
        view.observeCompaction(result)
        let wasBusy = view.busy
        view.observeRunState(result)
        observeCost(result, view: view)
        if wasBusy, view.runState == .error { markRunFailed(sessionID: id) }
        view.observeRetry(result)
        let queued = result["queue"]?.array?.compactMap(\.object) ?? []
        view.observeQueueEdit(result)
        let queue = view.panelQueue(queued); if view.queue != queue { view.queue = queue }
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
        view.displayObservedAt = result["displayObservedAt"]?.number.map { $0 + clockOffset }
        if let start = view.displayObservedAt { PerformanceProbe.shared.observe("deltaToNativeSnapshotMs", milliseconds: PerformanceProbe.now - start) }
        // The helper has said what the run is doing: the chat's hold follows it.
        view.runStateKnown = true; reconcileRunHold(id)
        return queued
    }
    /// A snapshot's rows, merged into the chat's window, and the window's
    /// edges. A branch this display did not make leaves the rows as they are
    /// and says the conversation changed elsewhere.
    private func applySnapshotRows(_ projected: [TranscriptMessage], from result: [String: WireValue], to view: SessionDisplay,
                                   id: String, item: ChatRecord) throws {
        let incarnation = result["historyIncarnation"]?.string, lineage = result["historyLineage"]?.string
        if let held = view.presentation.identity, let lineage, held.lineage != lineage {
            view.newerPage.error = Self.branchChangedElsewhere
            view.browsingHistory = true
        } else {
            let follows = result["historyFollows"]?.string
            let overlaps = view.messages.isEmpty || TranscriptPaging.joins(view.messages, follows: follows)
                || projected.contains { row in view.messages.contains { $0.id == row.id } }
            if !overlaps, let last = view.messages.last, let incarnation, let lineage {
                view.newerPage = .init(cursor: .init(incarnation: incarnation, lineage: lineage, entry: last.id))
                view.browsingHistory = true
                if view.scrollAnchor?.followsBottom != false { fillLiveGap(id) }
            }
            view.historyRevision = nil
            view.projectedRows = projected
            // Rows the reader scrolled up to stay in front of the helper's window.
            let merged = TranscriptPaging.merge(previous: view.messages, live: projected, follows: follows)
            // Rows that do not join the window change nothing in it,
            // and a window with nothing new is not cut.
            var messages = overlaps ? TranscriptPaging.window(merged, keepingEarlier: false) : merged
            let held = heldRows(view)
            // The window is the newest rows of what merged; a held
            // row before its first one would be let go of.
            if !held.isEmpty, let start = merged.firstIndex(where: { held.contains($0.id) }),
               start < merged.count - messages.count {
                // Arriving output may fill the resident budget, but
                // must neither evict text the reader is using — the
                // row they read from, or the one holding their
                // cursor or selection — nor stop arriving. The
                // window runs from the earliest of those rows to the
                // live tail until the reader lets go of it, and the
                // next update trims it again. Before, the chat kept
                // its rows and stopped taking the helper's: the reply
                // being written stopped mid-sentence and stayed that
                // way, behind "Load newer messages", until the chat
                // was left and opened again.
                messages = Array(merged[start...])
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
            // The page cursors below are published on the whole
            // display. Writing them unchanged, once per streamed
            // token, re-evaluated the conversation pane, its
            // composer and its footer for every token.
            if let before = result["before"], view.hostBefore != before.number { view.hostBefore = before.number }
            if overlaps, let incarnation, let lineage, let first = messages.first {
                view.presentation.identity = (incarnation, lineage)
                let liveOlder = try ConversationHistoryPage.cursor(result["historyOlder"])
                // Rows the window let go of at its start are still
                // the chat's: the window then starts at an earlier
                // edge, as one read from the middle of the chat
                // does, and the reader scrolls back to them as to
                // any earlier rows. A chat whose every row was
                // loaded had no edge to keep, so rows that left its
                // start as it grew left none, and came back only
                // when the chat was opened again.
                let edge = ConversationCursor(incarnation: incarnation, lineage: lineage, entry: first.id)
                let trimmed = first.id != merged.first?.id
                let older: ConversationCursor?? = first.id == projected.first?.id ? .some(liveOlder ?? (trimmed ? edge : nil))
                    : view.olderPage.cursor != nil || trimmed ? .some(edge) : .none
                if let older, older != view.olderPage.cursor {
                    if !view.olderPage.loading { view.olderPage = .init(cursor: older) }
                    // An earlier page is being read from the
                    // current boundary: a streamed token must not
                    // end that read or start a second one. Only a
                    // first row that really moved replaces the
                    // cursor, and the read then drops what it got.
                    else if older?.entry != view.olderPage.cursor?.entry { view.olderPage.cursor = older }
                }
                if view.before != view.olderPage.cursor?.entry { view.before = view.olderPage.cursor?.entry }
            }
            if view.historyState == .dormant || view.historyState == .empty { view.historyState = messages.isEmpty ? .empty : .preparing }
        }
    }
    /// The line under the composer that says what the chat's tools may do,
    /// unless something the reader has to review is there instead.
    private func applyToolNotice(_ result: [String: WireValue], to view: SessionDisplay, id: String, item: ChatRecord) {
        let notice = item.isBackgroundTask ? (record(id)?.backgroundTaskNotice ?? "Tools disabled · Title generation") : item.connectionTest == true || item.workspaceID == WorkspaceRecord.scratchID ? "Tools disabled · Connection test" : item.toolMode == ChatRecord.readOnlyTools ? "Read-only tools" : ""
        // An interruption or preflight explanation stays until the
        // user has reviewed it; the static tool notice must not replace it.
        if view.notice != notice, !view.uncertain, view.failureMessage == nil { view.notice = notice }
        if let preflight = result["preflightError"]?.string { if view.failureMessage == nil { view.notice = preflight }; view.uncertain = true }
    }
    /// The chat's receipts, its messages still drawn as sending, and its
    /// pending submissions, settled against what the snapshot says. Returns
    /// false when the snapshot stopped applying during a store write
    /// (`snapshotApplies`), and the snapshot stops there.
    private func settleSnapshotIntents(_ result: [String: WireValue], view: SessionDisplay, id: String, item: ChatRecord,
                                       host: HostSupervisor, connection: UUID, helperQueue: [[String: WireValue]]?) async throws -> Bool {
        func current() -> Bool { snapshotApplies(id: id, view: view, item: item, host: host, connection: connection) }
        // The chat's pending submissions come from the store only when
        // they can have changed since the last read: the app wrote one
        // (`pendingIntentsChanged`), or this snapshot's receipts settle
        // one. Two reads per streamed token held up the next snapshot.
        //
        // A snapshot leaves the receipts out when none changed since the
        // revision sent back; they are then the ones held. Settling runs
        // against those too, so a settle cut short, or a record written
        // after its receipt arrived, still settles without a new receipt.
        if let carried = result["commands"]?.array {
            view.receipts = carried.compactMap(\.object); view.commandsRevision = result["commandsRevision"]?.string
        }
        let receipts = view.receipts
        // A message sent from here that the helper took elsewhere —
        // refused at delivery, removed, or held by a paused queue —
        // leaves the transcript, and the panel shows it at once.
        if view.settleSending(receipts: receipts, queued: Set((helperQueue ?? []).compactMap { $0["turnId"]?.string })), let helperQueue {
            let queue = view.panelQueue(helperQueue); if view.queue != queue { view.queue = queue }
        }
        let revision = view.pendingIntentRevision
        var intents: [CommandIntent]
        if let known = view.pendingIntents, known.revision == revision { intents = known.intents }
        else {
            view.intentReads += 1
            intents = try await store?.list(CommandIntent.self, kind: "pending:\(id)") ?? []
            guard current() else { return false }
        }
        var settled: Set<String> = []
        for var intent in intents {
            guard let receipt = receipts.last(where: { $0["commandId"]?.string == intent.id }), let state = receipt["state"]?.string,
                  state != "dispatched" else { continue }
            intent.state = state; intent.text = ""; intent.attachments = nil; intent.skills = nil
            try await store?.put(intent, kind: "receipt:\(id)", id: intent.id)
            guard current() else { return false }
            try await store?.remove(kind: "pending:\(id)", id: intent.id)
            guard current() else { return false }
            settled.insert(intent.id)
        }
        if !settled.isEmpty { intents.removeAll { settled.contains($0.id) } }
        // Held against the revision read: a write during the awaits
        // above moves the revision on, and the next snapshot reads again.
        view.pendingIntents = (revision, intents)
        if intents != view.recovered { view.recovered = intents }
        if view.recovered.isEmpty { view.uncertain = false }
        return true
    }
    /// The rows the reader holds, which a resident window does not let go
    /// of: the one holding their cursor or selection, and the one they read
    /// from when they are not following the newest row.
    func heldRows(_ view: SessionDisplay) -> Set<String> {
        var held = view.pinnedHistoryIDs
        if let anchor = view.scrollAnchor, !anchor.followsBottom, view.messages.contains(where: { $0.id == anchor.id }) { held.insert(anchor.id) }
        return held
    }
    /// A window a held row stretched past its budget goes back to it once
    /// nothing holds it: a chat that has gone quiet has no next update to cut
    /// it, and one that stopped taking updates (its branch changed elsewhere,
    /// or the helper's window moved past it) has none coming. The rows that
    /// leave its start are reached again through the earlier edge, as any
    /// rows the window lets go of are. With nothing held, a display never
    /// keeps more than its resident window.
    func releaseHeldWindow(_ view: SessionDisplay) {
        guard !view.historyState.loading, let identity = view.presentation.identity else { return }
        let bounded = TranscriptPaging.window(view.messages, keepingEarlier: false)
        guard bounded.count < view.messages.count, let first = bounded.first,
              heldRows(view).isSubset(of: Set(bounded.map(\.id))) else { return }
        let accountingChanged = Self.accountingTargetsChanged(from: view.messages, to: bounded)
        view.messages = bounded
        let edge = ConversationCursor(incarnation: identity.incarnation, lineage: identity.lineage, entry: first.id)
        if !view.olderPage.loading { view.olderPage = .init(cursor: edge) } else { view.olderPage.cursor = edge }
        if view.before != edge.entry { view.before = edge.entry }
        // A read of the figures for the rows before is not for these.
        if accountingChanged, let workspaceID = record(view.id)?.workspaceID { scheduleAccounting(view.id, workspaceID: workspaceID) }
    }
    /// Every write of a chat's pending submissions calls this, so the
    /// snapshot loop reads them again instead of trusting what it holds.
    func pendingIntentsChanged(_ id: String) { displays[id]?.pendingIntentRevision &+= 1 }
    func cancelIdle(workspaceID: String) { idleTasks.removeValue(forKey: workspaceID)?.cancel() }
    func scheduleIdle(workspaceID: String, host: HostSupervisor) {
        idleTasks[workspaceID]?.cancel(); guard !host.isBusy, !sides.values.contains(where: { $0.workspaceID == workspaceID && !$0.kept && !$0.pending }) else { return }
        let grace = configuration.runtime.idleGraceSeconds
        idleTasks[workspaceID] = Task { try? await Task.sleep(for: .seconds(grace)); guard !Task.isCancelled, !host.isBusy else { return }
            // A deliberate stop: its exit is not a crash (see `startHost`).
            retiringHosts.insert(ObjectIdentifier(host))
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
